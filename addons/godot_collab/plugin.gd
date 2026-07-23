@tool
extends EditorPlugin

const PORT := 27999
const TARGET_PEER_BROADCAST := 0
const TARGET_PEER_SERVER := 1
const HOST_ID := 1
const SESSION_FILE := "res://addons/godot_collab/last_session.cfg"
const TRACKED_PROPERTIES := ["position", "rotation", "scale"]

var tracked_values: Dictionary = {}  # "caminho:propriedade" -> valor
var hello_sent := false
var peer: ENetMultiplayerPeer
var is_host := false
var my_name := ""
var host_password := ""
var peers: Dictionary = {}  # id -> nome
var startup_window: Window
var startup_name_field: LineEdit
var startup_ip_field: LineEdit
var startup_password_field: LineEdit

var dock: VBoxContainer
var name_field: LineEdit
var ip_field: LineEdit
var password_field: LineEdit
var status_label: Label
var peer_list: ItemList
var kick_button: Button

var applying_remote := false
var applying_remote_node_op := false


func _enter_tree() -> void:
	dock = VBoxContainer.new()
	dock.name = "Collab"

	name_field = LineEdit.new()
	name_field.placeholder_text = "Seu nome"
	dock.add_child(name_field)

	ip_field = LineEdit.new()
	ip_field.placeholder_text = "IP do host (vazio = eu sou o host)"
	dock.add_child(ip_field)

	password_field = LineEdit.new()
	password_field.placeholder_text = "Senha"
	password_field.secret = true  # se der erro nessa linha, apaga ela — não é essencial
	dock.add_child(password_field)

	var btn := Button.new()
	btn.text = "Conectar"
	btn.pressed.connect(_on_connect_pressed)
	dock.add_child(btn)

	status_label = Label.new()
	status_label.text = "Desconectado"
	dock.add_child(status_label)

	peer_list = ItemList.new()
	peer_list.custom_minimum_size = Vector2(0, 100)
	dock.add_child(peer_list)

	kick_button = Button.new()
	kick_button.text = "Kickar selecionado"
	kick_button.visible = false
	kick_button.pressed.connect(_on_kick_pressed)
	dock.add_child(kick_button)

	add_control_to_dock(DOCK_SLOT_RIGHT_UL, dock)

	add_undo_redo_inspector_hook_callback(Callable(self, "_on_property_changed"))

	var sel := get_editor_interface().get_selection()
	sel.selection_changed.connect(_on_selection_changed)

	get_tree().node_added.connect(_on_tree_node_added)
	get_tree().node_removed.connect(_on_tree_node_removed)

	set_process(true)
	
	_load_last_session()
	_show_startup_window()


func _exit_tree() -> void:
	remove_control_from_docks(dock)
	dock.queue_free()
	remove_undo_redo_inspector_hook_callback(Callable(self, "_on_property_changed"))
	if get_tree().node_added.is_connected(_on_tree_node_added):
		get_tree().node_added.disconnect(_on_tree_node_added)
	if get_tree().node_removed.is_connected(_on_tree_node_removed):
		get_tree().node_removed.disconnect(_on_tree_node_removed)
	if peer:
		peer.close()
	if startup_window:
		startup_window.queue_free()
	if peer:
		peer.close()

# --- janela inicial (criar/entrar) ---
func _show_startup_window() -> void:
	startup_window = Window.new()
	startup_window.title = "GodotCollab"
	startup_window.size = Vector2i(320, 240)
	startup_window.close_requested.connect(func(): startup_window.hide())

	var vb := VBoxContainer.new()
	vb.custom_minimum_size = Vector2(300, 0)

	var lbl := Label.new()
	lbl.text = "Criar uma sala nova ou entrar numa existente:"
	vb.add_child(lbl)

	startup_name_field = LineEdit.new()
	startup_name_field.placeholder_text = "Seu nome"
	startup_name_field.text = name_field.text
	vb.add_child(startup_name_field)

	startup_ip_field = LineEdit.new()
	startup_ip_field.placeholder_text = "IP do host (só pra entrar numa sala)"
	startup_ip_field.text = ip_field.text
	vb.add_child(startup_ip_field)

	startup_password_field = LineEdit.new()
	startup_password_field.placeholder_text = "Senha (opcional)"
	startup_password_field.secret = true  # se der erro, apaga essa linha
	vb.add_child(startup_password_field)

	var create_btn := Button.new()
	create_btn.text = "Criar Sala"
	create_btn.pressed.connect(_on_startup_create_pressed)
	vb.add_child(create_btn)

	var join_btn := Button.new()
	join_btn.text = "Entrar em Sala"
	join_btn.pressed.connect(_on_startup_join_pressed)
	vb.add_child(join_btn)

	startup_window.add_child(vb)
	add_child(startup_window)
	startup_window.popup_centered()


func _on_startup_create_pressed() -> void:
	name_field.text = startup_name_field.text
	ip_field.text = ""
	password_field.text = startup_password_field.text
	_on_connect_pressed()
	startup_window.hide()


func _on_startup_join_pressed() -> void:
	name_field.text = startup_name_field.text
	ip_field.text = startup_ip_field.text
	password_field.text = startup_password_field.text
	_on_connect_pressed()
	startup_window.hide()


# --- lembrar última sessão (fica salvo dentro do projeto) ---
func _save_last_session() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("session", "name", my_name)
	cfg.set_value("session", "ip", ip_field.text)
	cfg.save(SESSION_FILE)


func _load_last_session() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(SESSION_FILE) == OK:
		name_field.text = cfg.get_value("session", "name", "")
		ip_field.text = cfg.get_value("session", "ip", "")


# --- conexão ---
func _on_connect_pressed() -> void:
	my_name = name_field.text.strip_edges()
	if my_name == "":
		my_name = "Anonimo"
	_save_last_session()


	peer = ENetMultiplayerPeer.new()
	peer.peer_connected.connect(_on_peer_connected)
	peer.peer_disconnected.connect(_on_peer_disconnected)

	var err: Error
	if ip_field.text.strip_edges() == "":
		err = peer.create_server(PORT, 8)
		is_host = true
		host_password = password_field.text
		peers = {HOST_ID: my_name}
		_refresh_peer_list_ui()
		kick_button.visible = true
		status_label.text = "Host na porta %d (err=%s)" % [PORT, err]
	else:
		hello_sent = false
		err = peer.create_client(ip_field.text.strip_edges(), PORT)
		is_host = false
		kick_button.visible = false
		status_label.text = "Conectando em %s (err=%s)" % [ip_field.text, err]





func _on_peer_connected(id: int) -> void:
	print("Peer conectou (transporte): ", id)


func _on_peer_disconnected(id: int) -> void:
	print("Peer desconectou: ", id)
	if peers.has(id):
		peers.erase(id)
		_refresh_peer_list_ui()
		if is_host:
			_broadcast_to_all({"type": "peer_list", "peers": peers})
	if not is_host and id == HOST_ID:
		_reset_connection_state()


func _reset_connection_state() -> void:
	if peer:
		peer.close()
	peer = null
	is_host = false
	hello_sent = false
	peers.clear()
	tracked_values.clear()
	_refresh_peer_list_ui()
	kick_button.visible = false
	status_label.text = "Desconectado (perdeu conexão com o host)"

func _poll_selected_transforms() -> void:
	if peer == null:
		return
	var scene_root := get_editor_interface().get_edited_scene_root()
	if scene_root == null:
		return
	var sel := get_editor_interface().get_selection()
	for node in sel.get_selected_nodes():
		var path_str := str(scene_root.get_path_to(node))
		for prop in TRACKED_PROPERTIES:
			if not (prop in node):
				continue
			var key := path_str + ":" + str(prop)
			var current_value = node.get(prop)
			if tracked_values.has(key) and tracked_values[key] != current_value:
				tracked_values[key] = current_value
				_send_update({
					"type": "prop",
					"node_path": path_str,
					"property": prop,
					"value": current_value,
				})
			else:
				tracked_values[key] = current_value

# --- loop principal ---
func _process(_delta: float) -> void:
	if peer == null:
		return
	peer.poll()

	if not is_host and not hello_sent and peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED:
		hello_sent = true
		peer.set_target_peer(TARGET_PEER_SERVER)
		peer.put_packet(var_to_bytes({
			"type": "hello",
			"name": my_name,
			"password": password_field.text,
		}))
		status_label.text = "Conectado, autenticando..."

	while peer.get_available_packet_count() > 0:
		var sender_id := peer.get_packet_peer()
		var raw: PackedByteArray = peer.get_packet()
		var msg = bytes_to_var(raw)
		if typeof(msg) == TYPE_DICTIONARY:
			_handle_remote_message(msg, sender_id)

	_poll_selected_transforms()

func _handle_remote_message(msg: Dictionary, sender_id: int) -> void:
	match msg.get("type"):
		"hello":
			if is_host:
				_handle_hello(msg, sender_id)
		"peer_list":
			peers = msg.get("peers", {})
			_refresh_peer_list_ui()
			status_label.text = "Conectado (%d peers)" % peers.size()
		"prop":
			_apply_remote_property(msg)
			_relay_if_host(msg, sender_id)
		"selection":
			_show_remote_selection(msg)
			_relay_if_host(msg, sender_id)
		"node_add":
			_apply_remote_node_add(msg)
			_relay_if_host(msg, sender_id)
		"node_remove":
			_apply_remote_node_remove(msg)
			_relay_if_host(msg, sender_id)


func _handle_hello(msg: Dictionary, sender_id: int) -> void:
	if host_password != "" and msg.get("password", "") != host_password:
		print("Senha errada de peer ", sender_id, ", desconectando")
		peer.disconnect_peer(sender_id)
		return
	peers[sender_id] = msg.get("name", "Anonimo")
	_refresh_peer_list_ui()
	_broadcast_to_all({"type": "peer_list", "peers": peers})


# --- retransmissão (host relaya pros outros clients) ---
func _relay_if_host(msg: Dictionary, sender_id: int) -> void:
	if not is_host:
		return
	for id in peers.keys():
		if id == sender_id or id == HOST_ID:
			continue
		peer.set_target_peer(id)
		peer.put_packet(var_to_bytes(msg))


func _broadcast_to_all(msg: Dictionary) -> void:
	if peer == null:
		return
	peer.set_target_peer(TARGET_PEER_BROADCAST)
	peer.put_packet(var_to_bytes(msg))


func _send_update(msg: Dictionary) -> void:
	if peer == null:
		return
	if is_host:
		peer.set_target_peer(TARGET_PEER_BROADCAST)
	else:
		peer.set_target_peer(TARGET_PEER_SERVER)
	peer.put_packet(var_to_bytes(msg))


# --- UI de peers / kick ---
func _refresh_peer_list_ui() -> void:
	peer_list.clear()
	for id in peers.keys():
		var idx := peer_list.add_item("%s (id %d)" % [peers[id], id])
		peer_list.set_item_metadata(idx, id)


func _on_kick_pressed() -> void:
	if not is_host:
		return
	var selected := peer_list.get_selected_items()
	if selected.is_empty():
		return
	var id: int = peer_list.get_item_metadata(selected[0])
	if id == HOST_ID:
		print("Não dá pra kickar o host (você).")
		return
	peer.disconnect_peer(id)


# --- propriedade (Inspector) ---
func _on_property_changed(_undo_redo, modified_object, property: String, new_value) -> void:
	if applying_remote:
		return
	if not (modified_object is Node):
		return
	var scene_root := get_editor_interface().get_edited_scene_root()
	if scene_root == null:
		return
	var node := modified_object as Node
	if node != scene_root and not scene_root.is_ancestor_of(node):
		return
	var node_path := scene_root.get_path_to(node)
	_send_update({
		"type": "prop",
		"node_path": str(node_path),
		"property": property,
		"value": new_value,
	})


func _apply_remote_property(msg: Dictionary) -> void:
	var scene_root := get_editor_interface().get_edited_scene_root()
	if scene_root == null:
		return
	var node := scene_root.get_node_or_null(msg["node_path"])
	if node == null:
		return
	applying_remote = true
	node.set_indexed(msg["property"], msg["value"])
	var key := str(msg["node_path"]) + ":" + str(msg["property"])
	tracked_values[key] = msg["value"]
	applying_remote = false


# --- seleção / presença ---
func _on_selection_changed() -> void:
	var sel := get_editor_interface().get_selection()
	var scene_root := get_editor_interface().get_edited_scene_root()
	if scene_root == null:
		return
	var paths := []
	for node in sel.get_selected_nodes():
		paths.append(str(scene_root.get_path_to(node)))
	_send_update({
		"type": "selection",
		"peer_id": peer.get_unique_id() if peer else -1,
		"paths": paths,
	})


func _show_remote_selection(msg: Dictionary) -> void:
	print("Peer ", msg.get("peer_id"), " selecionou: ", msg.get("paths"))


# --- node add/remove ---
func _on_tree_node_added(node: Node) -> void:
	if applying_remote_node_op:
		return
	var scene_root := get_editor_interface().get_edited_scene_root()
	if scene_root == null or node == scene_root:
		return
	if not scene_root.is_ancestor_of(node):
		return
	var parent := node.get_parent()
	if parent == null:
		return

	# Se esse node é a raiz de uma cena instanciada (ex: arrastou "carro.tscn"
	# pra dentro da viewport), manda o caminho do arquivo pra replicar a cena inteira.
	if node.scene_file_path != "":
		_send_update({
			"type": "node_add",
			"parent_path": str(scene_root.get_path_to(parent)),
			"scene_path": node.scene_file_path,
			"node_name": str(node.name),
		})
		return

	# Se o PAI já é raiz de uma cena instanciada, esse node é peça interna dela
	# (ex: uma roda dentro do carro) — já foi mandado junto com a cena acima.
	if parent.scene_file_path != "":
		return

	_send_update({
		"type": "node_add",
		"parent_path": str(scene_root.get_path_to(parent)),
		"class_name": node.get_class(),
		"node_name": str(node.name),
	})


func _on_tree_node_removed(node: Node) -> void:
	if applying_remote_node_op:
		return
	var scene_root := get_editor_interface().get_edited_scene_root()
	if scene_root == null or node == scene_root:
		return
	if not scene_root.is_ancestor_of(node):
		return
	_send_update({
		"type": "node_remove",
		"node_path": str(scene_root.get_path_to(node)),
	})


func _apply_remote_node_add(msg: Dictionary) -> void:
	var scene_root := get_editor_interface().get_edited_scene_root()
	if scene_root == null:
		return
	var parent := scene_root.get_node_or_null(msg["parent_path"])
	if parent == null:
		return
	applying_remote_node_op = true

	var new_node: Node
	if msg.has("scene_path"):
		var packed: PackedScene = load(msg["scene_path"])
		if packed == null:
			print("Não achei a cena '", msg["scene_path"], "' — os dois projetos precisam ter esse arquivo no mesmo caminho.")
			applying_remote_node_op = false
			return
		new_node = packed.instantiate()
	else:
		new_node = ClassDB.instantiate(msg["class_name"])

	new_node.name = msg["node_name"]
	parent.add_child(new_node)
	new_node.owner = scene_root
	applying_remote_node_op = false


func _apply_remote_node_remove(msg: Dictionary) -> void:
	var scene_root := get_editor_interface().get_edited_scene_root()
	if scene_root == null:
		return
	var node := scene_root.get_node_or_null(msg["node_path"])
	if node == null:
		return
	applying_remote_node_op = true
	node.get_parent().remove_child(node)
	node.queue_free()
	applying_remote_node_op = false
