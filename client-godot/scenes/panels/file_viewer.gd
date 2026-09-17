class_name FileViewer
extends CockpitPanel

const MAX_ROWS := 9

@export var backend_bridge_path: NodePath = ^"../BackendBridge"

var _body: RichTextLabel = null
var _current_path: String = ""
var _entries: Array = []
var _showing_content: bool = false
var _row_nodes: Array[Node] = []
var _row_targets: Array[Area3D] = []


func _init() -> void:
	panel_title = "COCKPIT // FILES"
	horizontal_offset = -0.62
	vertical_offset = -0.4


func _connect_state() -> void:
	AppState.file_tree_changed.connect(_on_file_tree_changed)
	AppState.file_content_changed.connect(_on_file_content_changed)
	AppState.focused_thread_changed.connect(_on_focused_thread_changed)


func _build_ui(root: Control) -> void:
	make_title(root, panel_title, "read-only view of the workspace and the active worktree")
	_body = make_body(root, Rect2(Vector2(22, 80), Vector2(viewport_size.x - 44, viewport_size.y - 180)))
	make_button(root, Rect2(Vector2(22, 428), Vector2(150, 46)), "UP", "file:up", COLOR_MUTED)
	make_button(root, Rect2(Vector2(186, 428), Vector2(150, 46)), "REFRESH", "file:refresh", COLOR_MUTED)
	make_button(root, Rect2(Vector2(350, 428), Vector2(150, 46)), "BACK", "file:back", COLOR_MUTED)


func open_focused_thread() -> bool:
	var thread := AppState.get_thread(AppState.focused_thread_id)
	if thread == null:
		return false
	_current_path = ""
	_showing_content = false
	var bridge := _backend_bridge()
	if bridge != null:
		bridge.send_command("file.list", {"path": ""}, thread.id)
	return open()


func refresh_listing() -> bool:
	var thread := AppState.get_thread(AppState.focused_thread_id)
	if thread == null:
		return false
	var bridge := _backend_bridge()
	if bridge == null:
		return false
	_showing_content = false
	return bridge.send_command("file.list", {"path": _current_path}, thread.id)


func activate_entry(path: String, is_directory: bool) -> bool:
	var thread := AppState.get_thread(AppState.focused_thread_id)
	if thread == null:
		return false
	var bridge := _backend_bridge()
	if bridge == null:
		return false
	if is_directory:
		_showing_content = false
		_current_path = path
		return bridge.send_command("file.list", {"path": path}, thread.id)
	_showing_content = true
	return bridge.send_command("file.read", {"path": path}, thread.id)


func navigate_up() -> bool:
	var thread := AppState.get_thread(AppState.focused_thread_id)
	if thread == null:
		return false
	var bridge := _backend_bridge()
	if bridge == null:
		return false
	if _showing_content:
		_showing_content = false
		refresh()
		return true
	var parts := _current_path.split("/", false)
	parts.remove_at(parts.size() - 1)
	_current_path = "/".join(parts)
	return bridge.send_command("file.list", {"path": _current_path}, thread.id)


func go_back() -> void:
	_showing_content = false
	refresh()


func get_current_path() -> String:
	return _current_path


func is_showing_content() -> bool:
	return _showing_content


func get_rows() -> Array:
	return _entries


func refresh() -> void:
	if _body == null:
		return
	if _showing_content:
		_render_content()
	else:
		_render_listing()


func _render_listing() -> void:
	var lines: PackedStringArray = []
	lines.append(
		"[color=#55f5ff]%s[/color]" % ("/" + _current_path if not _current_path.is_empty() else "/")
	)
	lines.append("[color=#6b9aa5]Pinch a row to open it. Directories navigate; files open read-only.[/color]")
	lines.append("")
	if _entries.is_empty():
		lines.append("[color=#6b9aa5]No entries loaded. Open a bound thread, then press REFRESH.[/color]")
	else:
		for entry_variant in _entries:
			var entry: Dictionary = entry_variant
			var prefix := "▸" if str(entry.get("type", "file")) == "dir" else "·"
			lines.append(
				"%s [b]%s[/b]  [color=#6b9aa5]%s[/color]"
				% [prefix, str(entry.get("name", "")), _size_label(entry)]
			)
	_body.text = "\n".join(lines)
	_rebuild_rows()


func _render_content() -> void:
	var content := str(AppState.file_content.get("content", ""))
	var path := str(AppState.file_content.get("path", _current_path))
	var truncated := bool(AppState.file_content.get("truncated", false))
	if bool(AppState.file_content.get("binary", false)):
		_body.text = "[color=#ffd166]%s is binary; the cockpit does not render it.[/color]" % path
		_clear_rows()
		return
	var bounded := content
	if bounded.length() > 8000:
		bounded = bounded.substr(0, 8000)
		truncated = true
	var lines: PackedStringArray = []
	lines.append("[color=#55f5ff]%s[/color]" % path)
	if truncated:
		lines.append("[color=#ffd166]Preview truncated to 8,000 characters.[/color]")
	lines.append("")
	lines.append(bounded.replace("[", "[lb]"))
	_body.text = "\n".join(lines)
	_clear_rows()


func _rebuild_rows() -> void:
	_clear_rows()
	var row_height := 34.0
	var index := 0
	for entry_variant in _entries:
		if index >= MAX_ROWS:
			break
		var entry: Dictionary = entry_variant
		var is_directory := str(entry.get("type", "file")) == "dir"
		var target_id := "file:%s:%s" % [
			"dir" if is_directory else "file",
			str(entry.get("path", "")),
		]
		var rect := Rect2(
			Vector2(30, 92 + index * (row_height + 6)),
			Vector2(viewport_size.x - 60, row_height)
		)
		var panel := PanelContainer.new()
		panel.position = rect.position
		panel.size = rect.size
		var style := StyleBoxFlat.new()
		style.bg_color = Color(0.012, 0.16, 0.2, 0.92)
		style.border_color = COLOR_MUTED
		style.set_border_width_all(1)
		panel.add_theme_stylebox_override("panel", style)
		panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_ui_root.add_child(panel)
		var label := Label.new()
		label.text = "%s  %s" % [
			"▸" if is_directory else "·",
			str(entry.get("name", "")),
		]
		label.position = Vector2(12, 0)
		label.size = Vector2(rect.size.x - 24, row_height)
		label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		label.add_theme_font_size_override("font_size", 14)
		label.add_theme_color_override("font_color", COLOR_TEXT)
		label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		panel.add_child(label)
		_row_nodes.append(panel)
		_row_targets.append(add_screen_target(target_id, rect))
		index += 1


func _clear_rows() -> void:
	for node in _row_nodes:
		if is_instance_valid(node):
			node.queue_free()
	_row_nodes.clear()
	for target in _row_targets:
		if is_instance_valid(target):
			target.queue_free()
	_row_targets.clear()


func _size_label(entry: Dictionary) -> String:
	if str(entry.get("type", "file")) == "dir":
		return "dir"
	return "%d B" % int(entry.get("size", 0))


func _on_file_tree_changed(thread_id: String) -> void:
	if thread_id != AppState.focused_thread_id:
		return
	_entries = AppState.file_tree.duplicate(true)
	_current_path = AppState.file_tree_path
	_showing_content = false
	if not visible:
		_place_in_reading_zone()
		visible = true
	refresh()


func _on_file_content_changed(thread_id: String) -> void:
	if thread_id != AppState.focused_thread_id:
		return
	_showing_content = true
	if not visible:
		_place_in_reading_zone()
		visible = true
	refresh()


func _on_focused_thread_changed(_thread_id: String) -> void:
	if visible:
		_current_path = ""
		_showing_content = false
		refresh()


func _backend_bridge() -> BackendBridge:
	return get_node_or_null(backend_bridge_path) as BackendBridge
