class_name DaemonSettingsPanel
extends CockpitPanel

const PAIRING_ALPHABET := "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
const PAIRING_CODE_LENGTH := 8
const KEY_COLUMNS := 8
const KEY_ROWS := 4
const KEY_HEIGHT := 50.0
const KEY_GAP := 6.0
const GRID_TOP := 204.0

@export var backend_bridge_path: NodePath = ^"../BackendBridge"

var _body: RichTextLabel = null
var _pairing := false
var _code := ""
var _status := ""
var _keypad_nodes: Array[Node] = []
var _keypad_targets: Array[Area3D] = []
var _body_rect := Rect2()
var _body_rect_pairing := Rect2()


func _init() -> void:
	panel_title = "COCKPIT // DAEMON"
	horizontal_offset = 0.62
	vertical_offset = -0.4


func _connect_state() -> void:
	AppState.connection_state_changed.connect(_on_state_changed)
	AppState.pairing_changed.connect(_on_pairing_changed)
	AppState.tool_catalog_changed.connect(_on_state_changed)
	AppState.workspaces_changed.connect(_on_state_changed)
	AppState.provider_identity_changed.connect(_on_provider_changed)
	EventBus.debug_message.connect(_on_debug_message)


func _build_ui(root: Control) -> void:
	make_title(root, panel_title, "local daemon link, authorization, and tool sources")
	_body_rect = Rect2(Vector2(22, 80), Vector2(viewport_size.x - 44, 180))
	_body_rect_pairing = Rect2(Vector2(22, 96), Vector2(viewport_size.x - 44, 92))
	_body = make_body(root, _body_rect)
	make_button(root, Rect2(Vector2(110, 430), Vector2(240, 46)), "REFRESH", "daemon:refresh", COLOR_MUTED)
	make_button(root, Rect2(Vector2(410, 430), Vector2(240, 46)), "PAIR WITH CODE", "daemon:pair_mode", COLOR_TITLE)


func handle_action(target_id: String) -> void:
	match target_id:
		"daemon:refresh":
			var bridge := get_node_or_null(backend_bridge_path) as BackendBridge
			if bridge != null:
				bridge.send_command("workspace.list", {})
				bridge.send_command("tool.catalog", {})
			refresh()
		"daemon:pair_mode":
			_enter_pairing()
		"daemon:pair_cancel":
			_exit_pairing()
		"daemon:key_clear":
			_code = ""
			refresh()
		"daemon:pair_submit":
			_submit_pairing()
		_:
			if target_id.begins_with("daemon:key:"):
				_append_code(target_id.trim_prefix("daemon:key:"))
			else:
				refresh()


func refresh() -> void:
	if _body == null:
		return
	_body.size = _body_rect_pairing.size if _pairing else _body_rect.size
	if _pairing:
		_render_pairing()
	else:
		_render_status()


func _render_status() -> void:
	var transport = ServiceRegistry.backend_transport
	var protocol_version := 2
	if transport != null and transport.has_method("get_protocol_version"):
		protocol_version = int(transport.call("get_protocol_version"))
	var url := "unconfigured"
	if transport != null:
		var url_value = transport.get("websocket_url")
		if url_value != null:
			url = str(url_value)
	var auth_state := "open loopback"
	if not AppState.paired_device.is_empty():
		auth_state = "paired · %s" % str(AppState.paired_device.get("device_name", "device"))
	elif AppState.backend_mode == "websocket":
		auth_state = "pairing required · poke PAIR WITH CODE"
	var lines: PackedStringArray = []
	lines.append("[color=#55f5ff]LINK[/color]")
	lines.append("• addr %s" % url)
	lines.append("• mode [b]%s[/b] · state [b]%s[/b] · protocol v%d" % [
		AppState.backend_mode, AppState.connection_state, protocol_version
	])
	lines.append("• provider [b]%s[/b] · model %s" % [AppState.provider_name, AppState.model_name])
	lines.append("• authorization [color=#55f5ff]%s[/color]" % auth_state)
	lines.append("")
	lines.append("[color=#55f5ff]SOURCES[/color]")
	lines.append("• workspaces %d · MCP servers %d · catalogued tools %d" % [
		AppState.workspaces.size(), AppState.mcp_servers.size(), AppState.tool_catalog.size()
	])
	for server in AppState.mcp_servers:
		lines.append("  · %s" % server)
	_body.text = "\n".join(lines)


func _render_pairing() -> void:
	var shown := ""
	for index in range(PAIRING_CODE_LENGTH):
		shown += (_code[index] + " ") if index < _code.length() else "_ "
	var lines: PackedStringArray = []
	lines.append("[color=#55f5ff]PAIR THIS HEADSET[/color]")
	lines.append("Read the 8-character code from the daemon console")
	lines.append("(or run ./scripts/run_backend.sh --pair).")
	lines.append("")
	lines.append("[font_size=30][color=#ffffff]%s[/color][/font_size]" % shown.strip_edges())
	if not _status.is_empty():
		lines.append("[color=#ffd166]%s[/color]" % _status)
	_body.text = "\n".join(lines)


func _enter_pairing() -> void:
	_pairing = true
	_code = ""
	_status = ""
	_build_keypad()
	refresh()


func _exit_pairing() -> void:
	_pairing = false
	_status = ""
	_clear_keypad()
	refresh()


func _append_code(character: String) -> void:
	if _code.length() >= PAIRING_CODE_LENGTH:
		return
	var normalized := character.strip_edges().to_upper()
	if normalized.is_empty() or not PAIRING_ALPHABET.contains(normalized):
		return
	_code += normalized
	refresh()


func _submit_pairing() -> void:
	if _code.length() != PAIRING_CODE_LENGTH:
		_status = "Enter all %d characters" % PAIRING_CODE_LENGTH
		refresh()
		return
	var transport = ServiceRegistry.backend_transport
	if transport == null or not transport.has_method("pair"):
		_status = "The active transport does not support pairing"
		refresh()
		return
	if bool(transport.call("pair", _code)):
		_status = "Pairing… waiting for the daemon"
	else:
		_status = "Pairing request was not accepted"
	refresh()


func _build_keypad() -> void:
	var root := _viewport.get_child(0) as Control
	if root == null:
		return
	var grid_width := viewport_size.x - 44.0
	var key_width := (grid_width - (KEY_COLUMNS - 1) * KEY_GAP) / float(KEY_COLUMNS)
	for index in range(PAIRING_ALPHABET.length()):
		var column := index % KEY_COLUMNS
		var row := index / KEY_COLUMNS
		var rect := Rect2(
			Vector2(22.0 + column * (key_width + KEY_GAP), GRID_TOP + row * (KEY_HEIGHT + KEY_GAP)),
			Vector2(key_width, KEY_HEIGHT)
		)
		_add_key(root, rect, PAIRING_ALPHABET[index], "daemon:key:%s" % PAIRING_ALPHABET[index])
	var action_y := GRID_TOP + KEY_ROWS * (KEY_HEIGHT + KEY_GAP)
	_add_key(root, Rect2(Vector2(22, action_y), Vector2(220, 46)), "CLEAR", "daemon:key_clear", COLOR_MUTED)
	_add_key(root, Rect2(Vector2(270, action_y), Vector2(220, 46)), "PAIR", "daemon:pair_submit", COLOR_ADDED)
	_add_key(root, Rect2(Vector2(518, action_y), Vector2(220, 46)), "CANCEL", "daemon:pair_cancel", COLOR_REMOVED)


func _add_key(root: Control, rect: Rect2, text: String, target_id: String, accent: Color = COLOR_TITLE) -> void:
	var panel := make_button(root, rect, text, target_id, accent)
	_keypad_nodes.append(panel)
	var target := panel.get_meta("interaction_target") as Area3D
	if target != null:
		_keypad_targets.append(target)


func _clear_keypad() -> void:
	for node in _keypad_nodes:
		if is_instance_valid(node):
			node.queue_free()
	_keypad_nodes.clear()
	for target in _keypad_targets:
		if is_instance_valid(target):
			target.queue_free()
	_keypad_targets.clear()


func _on_state_changed(_value: Variant = null) -> void:
	if visible:
		refresh()


func _on_pairing_changed(_device_id: String, device_name: String) -> void:
	_status = "Paired as %s" % device_name
	if _pairing:
		_exit_pairing()
	elif visible:
		refresh()


func _on_provider_changed(_provider: String, _model: String) -> void:
	if visible:
		refresh()


func _on_debug_message(message: String) -> void:
	if not _pairing:
		return
	var lowered := message.to_lower()
	if lowered.contains("pairing") or lowered.contains("auth") or lowered.contains("backend error"):
		_status = message
		refresh()
