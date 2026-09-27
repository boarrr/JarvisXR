class_name ApprovalPanel
extends Node3D

## The approval gate: a small, always-facing 2D surface rendered through a
## SubViewport (like the palm panel) so every element reads from one angle, with
## two large poke targets for APPROVE / DENY.

const SPATIAL_TARGET_SCRIPT := preload("res://interaction/spatial_action_target.gd")

const VIEWPORT_SIZE := Vector2i(720, 420)
const SCREEN_CENTER := Vector2(0.0, 0.0)
const SCREEN_SIZE := Vector2(0.9, 0.525)

const RECT_APPROVE := Rect2(28, 322, 316, 72)
const RECT_DENY := Rect2(376, 322, 316, 72)

@export var user_rig_path: NodePath = ^"../UserRig"
@export_range(0.4, 1.5, 0.05) var park_distance: float = 0.72
@export_range(-0.5, 0.5, 0.01) var park_side_offset: float = -0.04
@export_range(0.0, 0.6, 0.01) var park_drop: float = 0.16
@export var room_anchor_registry_path: NodePath = ^"../RoomAnchorRegistry"

@onready var _impact_preview: ApprovalImpactPreview = $ImpactPreview

var _camera: Camera3D = null
var _room_anchors: RoomAnchorRegistry = null
var _viewport: SubViewport = null
var _screen: MeshInstance3D = null
var _title_label: Label = null
var _summary_label: Label = null
var _impact_label: Label = null
var _permission_label: Label = null
var _approval_id: String = ""


func _ready() -> void:
	var rig := get_node_or_null(user_rig_path) as UserRig
	if rig != null:
		_camera = rig.get_camera()
	_room_anchors = get_node_or_null(room_anchor_registry_path) as RoomAnchorRegistry
	_build_screen()
	AppState.approval_requested.connect(_on_approval_requested)
	AppState.approval_resolved.connect(_on_approval_resolved)
	visible = false
	_show_next_approval()


func get_approval_id() -> String:
	return _approval_id


func is_open() -> bool:
	return visible and not _approval_id.is_empty()


func get_impact_preview() -> ApprovalImpactPreview:
	return _impact_preview


func _build_screen() -> void:
	_viewport = SubViewport.new()
	_viewport.size = VIEWPORT_SIZE
	_viewport.transparent_bg = true
	_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child(_viewport)

	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_viewport.add_child(root)

	var background := PanelContainer.new()
	background.set_anchors_preset(Control.PRESET_FULL_RECT)
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.09, 0.02, 0.012, 0.97)
	style.border_color = Color(1.0, 0.42, 0.12, 0.95)
	style.set_border_width_all(4)
	style.set_corner_radius_all(10)
	background.add_theme_stylebox_override("panel", style)
	background.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(background)

	var eyebrow := _label(root, "SECURITY GATE  //  ACTION PAUSED", Vector2(30, 18), 700.0, 16)
	eyebrow.add_theme_color_override("font_color", Color(1.0, 0.5, 0.2))

	_title_label = _label(root, "APPROVAL REQUIRED", Vector2(30, 46), 664.0, 36)
	_title_label.add_theme_color_override("font_color", Color(1.0, 0.82, 0.5))

	_summary_label = _label(root, "", Vector2(30, 108), 664.0, 21)
	_summary_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_summary_label.max_lines_visible = 6
	_summary_label.add_theme_color_override("font_color", Color(0.97, 0.92, 0.86))

	_impact_label = _label(root, "", Vector2(30, 250), 664.0, 16)
	_impact_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_impact_label.max_lines_visible = 3
	_impact_label.add_theme_color_override("font_color", Color(0.35, 1.0, 0.78))

	_permission_label = _label(root, "", Vector2(30, 292), 664.0, 16)
	_permission_label.add_theme_color_override("font_color", Color(1.0, 0.62, 0.24))

	_make_button(root, RECT_APPROVE, "APPROVE", Color(0.06, 0.5, 0.34), Color(0.5, 1, 0.82))
	_make_button(root, RECT_DENY, "DENY", Color(0.5, 0.07, 0.05), Color(1, 0.72, 0.66))

	_make_target("ApproveTarget", "approval:approve", RECT_APPROVE)
	_make_target("DenyTarget", "approval:deny", RECT_DENY)

	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.albedo_texture = _viewport.get_texture()
	material.no_depth_test = true
	_screen = MeshInstance3D.new()
	var quad := QuadMesh.new()
	quad.size = SCREEN_SIZE
	quad.material = material
	_screen.mesh = quad
	add_child(_screen)


func _label(root: Control, text: String, position: Vector2, width: float, size: int) -> Label:
	var label := Label.new()
	label.text = text
	label.position = position
	label.size = Vector2(width, 40)
	label.add_theme_font_size_override("font_size", size)
	label.add_theme_color_override("font_color", Color(0.9, 0.95, 0.98))
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(label)
	return label


func _make_button(root: Control, rect: Rect2, text: String, fill: Color, ink: Color) -> void:
	var panel := PanelContainer.new()
	panel.position = rect.position
	panel.size = rect.size
	var style := StyleBoxFlat.new()
	style.bg_color = fill
	style.border_color = ink
	style.set_border_width_all(3)
	style.set_corner_radius_all(8)
	panel.add_theme_stylebox_override("panel", style)
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(panel)
	var label := Label.new()
	label.text = text
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", 30)
	label.add_theme_color_override("font_color", ink)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(label)


func _make_target(target_name: String, target_id: String, rect: Rect2) -> void:
	var area := Area3D.new()
	area.name = target_name
	area.set_script(SPATIAL_TARGET_SCRIPT)
	area.set("target_id", target_id)
	area.collision_layer = 2
	area.collision_mask = 0
	area.monitoring = false
	area.add_to_group("interactable")
	var shape := BoxShape3D.new()
	var scale_x := SCREEN_SIZE.x / float(VIEWPORT_SIZE.x)
	var scale_y := SCREEN_SIZE.y / float(VIEWPORT_SIZE.y)
	shape.size = Vector3(rect.size.x * scale_x, rect.size.y * scale_y, 0.05)
	var collision := CollisionShape3D.new()
	collision.shape = shape
	area.add_child(collision)
	area.position = _rect_to_local(rect)
	add_child(area)


func _rect_to_local(rect: Rect2) -> Vector3:
	var center := rect.position + rect.size * 0.5
	var scale_x := SCREEN_SIZE.x / float(VIEWPORT_SIZE.x)
	var scale_y := SCREEN_SIZE.y / float(VIEWPORT_SIZE.y)
	return Vector3(
		SCREEN_CENTER.x + (center.x - VIEWPORT_SIZE.x * 0.5) * scale_x,
		SCREEN_CENTER.y - (center.y - VIEWPORT_SIZE.y * 0.5) * scale_y,
		0.03
	)


func _show_next_approval() -> void:
	var request := AppState.get_next_approval()
	if request.is_empty():
		visible = false
		_approval_id = ""
		return
	_approval_id = str(request.get("approval_id", ""))
	_title_label.text = str(request.get("tool_name", "Action")) + "  ·  APPROVAL REQUIRED"
	var summary := str(request.get("summary", "The agent requested an action."))
	if summary.length() > 260:
		summary = summary.substr(0, 257) + "..."
	_summary_label.text = summary
	_permission_label.text = "permission: %s" % str(
		request.get("permission_level", "explicit approval")
	)
	_impact_preview.visible = false
	_impact_preview.configure(request.get("impact_preview", {}) as Dictionary)
	_impact_label.text = _impact_preview.get_description()
	_place()
	visible = true
	_render()


func _place() -> void:
	if _camera == null:
		return
	var camera_position := _camera.global_position
	var camera_forward := -_camera.global_transform.basis.z
	camera_forward.y = 0.0
	if camera_forward.length_squared() < 0.0001:
		camera_forward = Vector3.FORWARD
	camera_forward = camera_forward.normalized()
	var camera_right := _camera.global_transform.basis.x
	camera_right.y = 0.0
	if camera_right.length_squared() < 0.0001:
		camera_right = Vector3.RIGHT
	camera_right = camera_right.normalized()
	global_position = (
		camera_position
		+ camera_forward * park_distance
		+ camera_right * park_side_offset
		+ Vector3.DOWN * park_drop
	)
	_face_user(0.0)
	if _room_anchors != null:
		_room_anchors.register_anchor("approval_surface", "approval_gate", global_transform)


func _process(delta: float) -> void:
	if not visible or _camera == null:
		return
	_face_user(delta)


func _face_user(delta: float) -> void:
	var to_user := _camera.global_position - global_position
	if to_user.length_squared() < 0.0001:
		return
	var forward := to_user.normalized()
	forward.y = clampf(forward.y, -0.55, 0.55)
	forward = forward.normalized()
	var up := Vector3.UP
	var right := up.cross(forward)
	if right.length_squared() < 0.0001:
		right = Vector3.RIGHT
	right = right.normalized()
	up = forward.cross(right).normalized()
	var desired := Basis(right, up, forward)
	if delta <= 0.0:
		basis = desired
	else:
		basis = basis.slerp(desired, 1.0 - exp(-9.0 * delta))
	global_transform = Transform3D(basis.orthonormalized(), global_position)


func _render() -> void:
	if _viewport != null:
		_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE


func _on_approval_requested(_request: Dictionary) -> void:
	if not is_open():
		_show_next_approval()


func _on_approval_resolved(approval_id: String) -> void:
	if approval_id == _approval_id:
		_show_next_approval()
