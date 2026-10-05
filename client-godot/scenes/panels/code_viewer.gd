class_name CodeViewer
extends Node3D

const NAV_TARGET_SCRIPT := preload("res://interaction/spatial_action_target.gd")

@export var user_rig_path: NodePath = ^"../UserRig"
@export var backend_bridge_path: NodePath = ^"../BackendBridge"
@export_range(0.8, 3.0, 0.05) var distance_from_user: float = 1.55
@export_range(-1.8, 1.8, 0.05) var horizontal_offset: float = -0.88
@export_range(-1.0, 1.0, 0.05) var vertical_offset: float = 0.03
@export_range(1, 20, 1) var scroll_step_lines: int = 4
@export var room_anchor_registry_path: NodePath = ^"../RoomAnchorRegistry"

const SCREEN_SIZE := Vector2(1.445, 0.865)
const VIEW_SIZE := Vector2(920.0, 560.0)
const NAV_Z := 0.03
const SCROLL_LINES_PER_METER := 22.0

@onready var _viewport: SubViewport = $CodeViewport
@onready var _screen: MeshInstance3D = $Screen
@onready var _mode_label: Label = $CodeViewport/Root/Frame/VBox/TopBar/Mode
@onready var _path_label: Label = $CodeViewport/Root/Frame/VBox/TopBar/Path
@onready var _code_edit: CodeEdit = $CodeViewport/Root/Frame/VBox/Code
@onready var _position_label: Label = $CodeViewport/Root/Frame/VBox/StatusBar/Position
@onready var _hint_label: Label = $CodeViewport/Root/Frame/VBox/StatusBar/Hint
@onready var _diff_sculptor: DiffSculptor = $DiffSculptor
@onready var _diff_label: Label3D = $DiffLabel

var _camera: Camera3D = null
var _room_anchors: RoomAnchorRegistry = null
var _bridge: BackendBridge = null
var _displayed_thread_id: String = ""
var _language: String = "text"
var _files: Array[String] = []
var _file_index: int = 0
var _pending_path: String = ""
var _source_mode: String = "empty"
var _bimanual_active := false
var _bimanual_base_basis := Basis.IDENTITY
var _bimanual_base_scale := Vector3.ONE
var _bimanual_center_offset := Vector3.ZERO
var _scroll_active := false
var _scroll_origin_y := 0.0
var _scroll_start_lines := 0.0


func _ready() -> void:
	var rig := get_node_or_null(user_rig_path) as UserRig
	if rig != null:
		_camera = rig.get_camera()
	_room_anchors = get_node_or_null(room_anchor_registry_path) as RoomAnchorRegistry
	_bridge = get_node_or_null(backend_bridge_path) as BackendBridge
	_configure_screen_material()
	_configure_syntax_highlighter()
	_build_nav_controls()
	AppState.focused_thread_changed.connect(_on_focused_thread_changed)
	AppState.thread_updated.connect(_on_thread_updated)
	AppState.diff_changed.connect(_on_diff_changed)
	AppState.file_content_changed.connect(_on_file_content_changed)
	visible = false


func toggle() -> bool:
	if visible:
		close()
		return false
	return open_focused_thread()


func open_focused_thread() -> bool:
	var thread := AppState.get_thread(AppState.focused_thread_id)
	if thread == null:
		return false
	_displayed_thread_id = thread.id
	_files.clear()
	_file_index = 0
	_pending_path = ""
	_place_in_reading_zone()
	visible = true
	# Show the latest fenced snippet immediately (so the surface is never blank),
	# then upgrade to the agent's real changed files when the diff arrives.
	_show_fallback_code(thread)
	if _bridge != null:
		_bridge.send_command("diff.get", {}, thread.id)
	return true


func close() -> void:
	_bimanual_active = false
	_scroll_active = false
	visible = false
	_displayed_thread_id = ""
	_pending_path = ""


func is_open() -> bool:
	return visible and not _displayed_thread_id.is_empty()


func get_surface_target_id() -> String:
	return "ui:code_surface"


func get_rendered_code() -> String:
	return _code_edit.text


func get_diff_sculptor() -> DiffSculptor:
	return _diff_sculptor


func next_file() -> void:
	if _files.is_empty():
		return
	_file_index = (_file_index + 1) % _files.size()
	_request_current_file()


func prev_file() -> void:
	if _files.is_empty():
		return
	_file_index = (_file_index - 1 + _files.size()) % _files.size()
	_request_current_file()


func scroll_lines(lines: int) -> void:
	if not is_open():
		return
	_code_edit.scroll_vertical = clampf(
		_code_edit.scroll_vertical + float(lines),
		0.0,
		maxf(0.0, float(_code_edit.get_line_count() - 1))
	)
	_refresh_position()


func go_top() -> void:
	if not is_open():
		return
	_code_edit.scroll_vertical = 0.0
	_refresh_position()


func go_bottom() -> void:
	if not is_open():
		return
	_code_edit.scroll_vertical = maxf(0.0, float(_code_edit.get_line_count() - 1))
	_refresh_position()


func begin_bimanual_transform(center: Vector3) -> bool:
	if not is_open():
		return false
	_scroll_active = false
	_bimanual_active = true
	_bimanual_base_basis = global_transform.basis.orthonormalized()
	_bimanual_base_scale = scale
	_bimanual_center_offset = global_position - center
	return true


func apply_bimanual_transform(center: Vector3, scale_factor: float, rotation_radians: float) -> bool:
	if not _bimanual_active:
		return false
	var safe_scale := clampf(scale_factor, 0.55, 1.8)
	var rotation_basis := Basis(Vector3.UP, rotation_radians)
	global_transform = Transform3D(
		rotation_basis * _bimanual_base_basis,
		center + rotation_basis * _bimanual_center_offset * safe_scale
	)
	scale = _bimanual_base_scale * safe_scale
	return true


func end_bimanual_transform() -> void:
	_bimanual_active = false


func is_being_manipulated() -> bool:
	return _bimanual_active


func begin_scroll(world_position: Vector3) -> bool:
	if not is_open() or _bimanual_active:
		return false
	_scroll_active = true
	_scroll_origin_y = world_position.y
	_scroll_start_lines = _code_edit.scroll_vertical
	return true


func update_scroll(world_position: Vector3) -> bool:
	if not _scroll_active or _bimanual_active:
		return false
	# Raise the hand to pull earlier lines into view (natural inverted grab).
	var delta := world_position.y - _scroll_origin_y
	var target := _scroll_start_lines - delta * SCROLL_LINES_PER_METER
	_code_edit.scroll_vertical = clampf(
		target, 0.0, maxf(0.0, float(_code_edit.get_line_count() - 1))
	)
	_refresh_position()
	return true


func end_scroll() -> void:
	_scroll_active = false


func _configure_screen_material() -> void:
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.albedo_texture = _viewport.get_texture()
	material.albedo_color = Color.WHITE
	_screen.material_override = material


func _configure_syntax_highlighter() -> void:
	var highlighter := CodeHighlighter.new()
	highlighter.number_color = Color(0.98, 0.66, 0.26)
	highlighter.symbol_color = Color(0.38, 0.78, 0.94)
	highlighter.function_color = Color(0.45, 0.96, 0.83)
	highlighter.member_variable_color = Color(0.56, 0.76, 0.98)
	highlighter.add_color_region("#", "", Color(0.34, 0.53, 0.58), true)
	highlighter.add_color_region("//", "", Color(0.34, 0.53, 0.58), true)
	highlighter.add_color_region("\"", "\"", Color(0.58, 0.92, 0.66))
	highlighter.add_color_region("'", "'", Color(0.58, 0.92, 0.66))
	for keyword in [
		"class", "class_name", "extends", "func", "var", "const", "signal", "enum",
		"if", "elif", "else", "for", "while", "match", "return", "await", "async",
		"def", "from", "import", "try", "except", "finally", "with", "yield",
		"true", "false", "null", "True", "False", "None",
	]:
		highlighter.add_keyword_color(keyword, Color(0.16, 0.93, 1.0))
	_code_edit.syntax_highlighter = highlighter


func _build_nav_controls() -> void:
	var status := $CodeViewport/Root/Frame/VBox/StatusBar
	_hint_label.offset_right = 690.0
	_hint_label.text = ""
	_add_nav_label(status, "◀ PREV", Vector2(700, 5), Vector2(90, 34))
	_add_nav_label(status, "NEXT ▶", Vector2(800, 5), Vector2(90, 34))
	_add_nav_target("code:prev_file", Rect2(Vector2(700, 2), Vector2(90, 36)))
	_add_nav_target("code:next_file", Rect2(Vector2(800, 2), Vector2(90, 36)))


func _add_nav_label(parent: Control, text: String, position: Vector2, size: Vector2) -> void:
	var label := Label.new()
	label.text = text
	label.position = position
	label.size = size
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", 14)
	label.add_theme_color_override("font_color", Color(0.46, 0.92, 1.0, 1.0))
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(label)


func _add_nav_target(target_id: String, rect: Rect2) -> void:
	var target := Area3D.new()
	target.set_script(NAV_TARGET_SCRIPT)
	target.set("target_id", target_id)
	target.collision_layer = 2
	target.collision_mask = 0
	target.monitoring = false
	target.add_to_group("interactable")
	var center := rect.position + rect.size * 0.5
	var scale_x := SCREEN_SIZE.x / VIEW_SIZE.x
	var scale_y := SCREEN_SIZE.y / VIEW_SIZE.y
	target.position = Vector3(
		(center.x - VIEW_SIZE.x * 0.5) * scale_x,
		-(center.y - VIEW_SIZE.y * 0.5) * scale_y,
		NAV_Z
	)
	var shape := BoxShape3D.new()
	shape.size = Vector3(
		maxf(rect.size.x * scale_x, 0.03),
		maxf(rect.size.y * scale_y, 0.03),
		0.05
	)
	var collision := CollisionShape3D.new()
	collision.shape = shape
	target.add_child(collision)
	add_child(target)


func _place_in_reading_zone() -> void:
	if _camera == null:
		return
	var camera_basis := _camera.global_transform.basis.orthonormalized()
	var offset := Vector3(horizontal_offset, vertical_offset, -distance_from_user)
	global_transform = Transform3D(camera_basis, _camera.global_position + camera_basis * offset)
	if _room_anchors != null:
		_room_anchors.register_anchor("code_surface", "reading_zone", global_transform)


func _on_diff_changed(run_id: String) -> void:
	if not visible or _displayed_thread_id.is_empty():
		return
	var diff := AppState.get_diff(run_id)
	if str(diff.get("thread_id", "")) != _displayed_thread_id:
		return
	_files.clear()
	for file_variant in diff.get("files", []):
		var file: Dictionary = file_variant
		var path := str(file.get("path", ""))
		if not path.is_empty():
			_files.append(path)
	if _files.is_empty():
		_show_fallback_code(AppState.get_thread(_displayed_thread_id))
		return
	_source_mode = "files"
	_file_index = clampi(_file_index, 0, _files.size() - 1)
	_request_current_file()


func _request_current_file() -> void:
	if _files.is_empty():
		return
	_pending_path = _files[_file_index]
	_update_file_header(_pending_path)
	_code_edit.text = "# Loading %s …" % _pending_path
	_refresh_position()
	if _bridge != null:
		_bridge.send_command("file.read", {"path": _pending_path}, _displayed_thread_id)


func _on_file_content_changed(thread_id: String) -> void:
	if not visible or thread_id != _displayed_thread_id:
		return
	if str(AppState.file_content.get("scope", "")) == "host":
		# The host file browser shares the file.content event; ignore its loads.
		return
	if _source_mode != "files":
		return
	var payload := AppState.file_content
	var path := str(payload.get("path", ""))
	if not _pending_path.is_empty() and not path.is_empty() and path != _pending_path:
		return
	_render_file_content(payload)


func _render_file_content(payload: Dictionary) -> void:
	var path := str(payload.get("path", _pending_path))
	var content := str(payload.get("content", ""))
	if bool(payload.get("binary", false)):
		content = "# Binary file ({} bytes) - not shown.".format([int(payload.get("size", 0))])
	if bool(payload.get("truncated", false)):
		content += "\n\n# … truncated by the daemon."
	_language = _language_for_path(path)
	var previous_scroll := _code_edit.scroll_vertical
	_code_edit.text = content
	_code_edit.scroll_vertical = previous_scroll
	_diff_sculptor.visible = false
	_diff_label.visible = false
	_update_file_header(path)
	_refresh_position()


func _update_file_header(path: String) -> void:
	_path_label.text = path
	_mode_label.text = " %d/%d " % [_file_index + 1, _files.size()]
	if _files.size() > 1:
		_hint_label.text = "Tap PREV / NEXT to move through %d changed files" % _files.size()
	else:
		_hint_label.text = "Pinch-drag the surface to scroll"


func _show_fallback_code(thread: AgentThread) -> void:
	if thread == null:
		return
	var result := _extract_latest_code(thread)
	if result.is_empty():
		_source_mode = "empty"
		_language = "text"
		_code_edit.text = (
			"# No file changes yet.\n"
			+ "# Ask %s to edit a file, then reopen CODE to read the result." % thread.title
		)
		_path_label.text = "workspace://no-changes"
		_mode_label.text = " EMPTY "
		_hint_label.text = "This agent has not changed any files yet"
		_diff_sculptor.visible = false
		_diff_label.visible = false
		_refresh_position()
		return
	_source_mode = "snippet"
	_language = str(result.get("language", "text"))
	var code := str(result.get("code", ""))
	_code_edit.text = code
	_diff_sculptor.sculpt(code, _language)
	_diff_label.visible = _diff_sculptor.visible
	if _diff_sculptor.visible:
		_diff_label.text = "DIFF SCULPTURE  +%02d  -%02d" % [
			_diff_sculptor.get_added_count(),
			_diff_sculptor.get_removed_count(),
		]
	_path_label.text = "agent://%s/snippet.%s" % [
		_safe_path(thread.title),
		_extension_for_language(_language),
	]
	_mode_label.text = " SNIPPET "
	_hint_label.text = "Latest code block from this agent"
	_refresh_position()


func _extract_latest_code(thread: AgentThread) -> Dictionary:
	for message_index in range(thread.messages.size() - 1, -1, -1):
		var message := thread.messages[message_index]
		if message.role not in [AgentMessage.Role.ASSISTANT, AgentMessage.Role.TOOL]:
			continue
		var content := message.content
		var marker := content.rfind("```")
		if marker < 0:
			continue
		var opening := content.rfind("```", marker - 1)
		if opening < 0:
			opening = marker
			marker = -1
		var header_end := content.find("\n", opening + 3)
		if header_end < 0:
			continue
		var language := content.substr(opening + 3, header_end - opening - 3).strip_edges()
		var code_end := marker if marker > header_end else content.length()
		var code := content.substr(header_end + 1, code_end - header_end - 1).strip_edges()
		if not code.is_empty():
			return {"language": language if not language.is_empty() else "text", "code": code}
	return {}


func _refresh_position() -> void:
	var total_lines := maxi(1, _code_edit.get_line_count())
	var top_line := clampi(floori(_code_edit.scroll_vertical) + 1, 1, total_lines)
	var percentage := clampi(roundi(float(top_line) / float(total_lines) * 100.0), 0, 100)
	_position_label.text = "%d/%d  %3d%%  %s" % [top_line, total_lines, percentage, _language.to_upper()]


func _safe_path(value: String) -> String:
	return value.to_lower().replace(" ", "-").replace("/", "-")


func _language_for_path(path: String) -> String:
	var extension := path.get_extension().to_lower()
	match extension:
		"gd":
			return "gdscript"
		"py":
			return "python"
		"js":
			return "javascript"
		"ts":
			return "typescript"
		"rs":
			return "rust"
		"sh", "bash":
			return "shell"
		"json", "toml", "yaml", "yml", "cfg", "ini":
			return "config"
		"md":
			return "markdown"
		_:
			return extension if not extension.is_empty() else "text"


func _extension_for_language(value: String) -> String:
	match value.to_lower():
		"gdscript", "gd":
			return "gd"
		"python", "py":
			return "py"
		"javascript", "js":
			return "js"
		"typescript", "ts":
			return "ts"
		"rust", "rs":
			return "rs"
		_:
			return "txt"


func _on_focused_thread_changed(thread_id: String) -> void:
	if thread_id.is_empty():
		close()
	elif visible:
		open_focused_thread()


func _on_thread_updated(thread: AgentThread) -> void:
	# Only the streaming snippet fallback refreshes on every token; the real-file
	# view would re-request the diff on every delta and flood the daemon.
	if visible and _source_mode == "snippet" and thread.id == _displayed_thread_id:
		_show_fallback_code(thread)
