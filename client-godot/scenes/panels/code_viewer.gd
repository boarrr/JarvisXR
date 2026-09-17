class_name CodeViewer
extends Node3D

@export var user_rig_path: NodePath = ^"../UserRig"
@export_range(0.8, 3.0, 0.05) var distance_from_user: float = 1.55
@export_range(-1.8, 1.8, 0.05) var horizontal_offset: float = -0.88
@export_range(-1.0, 1.0, 0.05) var vertical_offset: float = 0.03
@export_range(1, 20, 1) var scroll_step_lines: int = 4
@export var room_anchor_registry_path: NodePath = ^"../RoomAnchorRegistry"

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
var _displayed_thread_id: String = ""
var _language: String = "text"
var _bimanual_active := false
var _bimanual_base_basis := Basis.IDENTITY
var _bimanual_base_scale := Vector3.ONE
var _bimanual_center_offset := Vector3.ZERO


func _ready() -> void:
	var rig := get_node_or_null(user_rig_path) as UserRig
	if rig != null:
		_camera = rig.get_camera()
	_room_anchors = get_node_or_null(room_anchor_registry_path) as RoomAnchorRegistry
	_configure_screen_material()
	_configure_syntax_highlighter()
	AppState.focused_thread_changed.connect(_on_focused_thread_changed)
	AppState.thread_updated.connect(_on_thread_updated)
	AppState.privacy_veil_changed.connect(_on_privacy_veil_changed)
	visible = false


func toggle() -> bool:
	if visible:
		close()
		return false
	return open_focused_thread()


func open_focused_thread() -> bool:
	if AppState.privacy_veil_active:
		visible = false
		return false
	var thread := AppState.get_thread(AppState.focused_thread_id)
	if thread == null:
		return false
	_displayed_thread_id = thread.id
	_place_in_reading_zone()
	_render_thread_code(thread)
	visible = true
	return true


func close() -> void:
	_bimanual_active = false
	visible = false
	_displayed_thread_id = ""


func is_open() -> bool:
	return visible and not _displayed_thread_id.is_empty()


func get_rendered_code() -> String:
	return _code_edit.text


func get_diff_sculptor() -> DiffSculptor:
	return _diff_sculptor


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
	_bimanual_active = true
	_bimanual_base_basis = global_transform.basis.orthonormalized()
	_bimanual_base_scale = scale
	_bimanual_center_offset = global_position - center
	_mode_label.text = " MANIPULATE "
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
	_mode_label.text = " NORMAL "


func is_being_manipulated() -> bool:
	return _bimanual_active


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


func _place_in_reading_zone() -> void:
	if _camera == null:
		return
	var camera_basis := _camera.global_transform.basis.orthonormalized()
	var offset := Vector3(horizontal_offset, vertical_offset, -distance_from_user)
	global_transform = Transform3D(camera_basis, _camera.global_position + camera_basis * offset)
	if _room_anchors != null:
		_room_anchors.register_anchor("code_surface", "reading_zone", global_transform)


func _render_thread_code(thread: AgentThread) -> void:
	var result := _extract_latest_code(thread)
	_language = str(result.get("language", "text"))
	var code := str(result.get("code", ""))
	if code.is_empty():
		code = _activity_placeholder(thread)
		_language = "trace"
	var previous_scroll := _code_edit.scroll_vertical
	_code_edit.text = code
	_diff_sculptor.sculpt(code, _language)
	_diff_label.visible = _diff_sculptor.visible
	if _diff_sculptor.visible:
		_diff_label.text = "DIFF SCULPTURE  +%02d  -%02d" % [
			_diff_sculptor.get_added_count(),
			_diff_sculptor.get_removed_count(),
		]
	_code_edit.scroll_vertical = previous_scroll
	_mode_label.text = " NORMAL "
	_path_label.text = "agent://%s/live.%s" % [_safe_path(thread.title), _extension_for_language(_language)]
	_hint_label.text = "PINCH-DRAG SCROLL  //  DESKTOP SIM: J/K · g/G · C"
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


func _activity_placeholder(thread: AgentThread) -> String:
	return (
		"# No code block has been emitted by this agent yet.\n"
		+ "# This trace updates when a streaming assistant message contains fenced code.\n\n"
		+ "thread = {\n"
		+ "    \"id\": \"%s\",\n" % thread.id
		+ "    \"status\": \"%s\",\n" % AgentThread.status_label(thread.status).to_lower()
		+ "    \"messages\": %d,\n" % thread.messages.size()
		+ "}\n\n"
		+ "await agent.next_code_delta()"
	)


func _refresh_position() -> void:
	var total_lines := maxi(1, _code_edit.get_line_count())
	var top_line := clampi(floori(_code_edit.scroll_vertical) + 1, 1, total_lines)
	var percentage := clampi(roundi(float(top_line) / float(total_lines) * 100.0), 0, 100)
	_position_label.text = "%d/%d  %3d%%  %s" % [top_line, total_lines, percentage, _language.to_upper()]


func _safe_path(value: String) -> String:
	return value.to_lower().replace(" ", "-").replace("/", "-")


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
	if visible and thread.id == _displayed_thread_id:
		_render_thread_code(thread)


func _on_privacy_veil_changed(value: bool) -> void:
	if value:
		visible = false
	elif not _displayed_thread_id.is_empty() and AppState.get_thread(_displayed_thread_id) != null:
		open_focused_thread()
