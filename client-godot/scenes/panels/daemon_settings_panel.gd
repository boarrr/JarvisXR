class_name DaemonSettingsPanel
extends CockpitPanel

@export var backend_bridge_path: NodePath = ^"../BackendBridge"

var _body: RichTextLabel = null


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


func _build_ui(root: Control) -> void:
	make_title(root, panel_title, "local daemon link, authorization, and tool sources")
	_body = make_body(root, Rect2(Vector2(22, 80), Vector2(viewport_size.x - 44, viewport_size.y - 180)))
	make_button(root, Rect2(Vector2(256, 428), Vector2(248, 46)), "REFRESH", "daemon:refresh", COLOR_MUTED)


func refresh() -> void:
	if _body == null:
		return
	var transport = ServiceRegistry.backend_transport
	var protocol_version := 2
	if transport != null and transport.has_method("get_protocol_version"):
		protocol_version = int(transport.call("get_protocol_version"))
	var auth_state := "open loopback"
	if not AppState.paired_device.is_empty():
		auth_state = "paired · %s" % str(AppState.paired_device.get("device_name", "device"))
	elif not AppState.connection_state.is_empty() and AppState.backend_mode == "websocket":
		auth_state = "pairing required (use /pair CODE)"
	var lines: PackedStringArray = []
	lines.append("[color=#55f5ff]LINK[/color]")
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
	lines.append("")
	lines.append("[color=#6b9aa5]Pair a LAN daemon with /pair CODE. Workspace bindings live in the workspace panel.[/color]")
	lines.append("[color=#6b9aa5]Run a daemon-side pairing code with: spatial-agent-pair[/color]")
	_body.text = "\n".join(lines)


func _on_state_changed(_value: Variant = null) -> void:
	if visible:
		refresh()


func _on_pairing_changed(_device_id: String, _device_name: String) -> void:
	if visible:
		refresh()


func _on_provider_changed(_provider: String, _model: String) -> void:
	if visible:
		refresh()
