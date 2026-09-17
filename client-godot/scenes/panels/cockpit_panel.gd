class_name CockpitPanel
extends Node3D

const SPATIAL_TARGET_SCRIPT := preload("res://interaction/spatial_action_target.gd")

const COLOR_BG := Color(0.008, 0.03, 0.045, 0.94)
const COLOR_BORDER := Color(0.02, 0.75, 0.95, 0.9)
const COLOR_TITLE := Color(0.33, 0.96, 1, 1)
const COLOR_TEXT := Color(0.78, 0.92, 0.96, 1)
const COLOR_MUTED := Color(0.42, 0.62, 0.68, 1)
const COLOR_ADDED := Color(0.48, 0.95, 0.62, 1)
const COLOR_REMOVED := Color(0.98, 0.45, 0.4, 1)
const COLOR_ACTION := Color(0.02, 0.29, 0.35, 0.95)

@export var user_rig_path: NodePath = ^"../UserRig"
@export_range(0.8, 3.0, 0.05) var distance_from_user: float = 1.58
@export_range(-1.8, 1.8, 0.05) var horizontal_offset: float = 0.0
@export_range(-1.0, 1.0, 0.05) var vertical_offset: float = 0.0
@export var room_anchor_registry_path: NodePath = ^"../RoomAnchorRegistry"
@export var panel_title: String = "COCKPIT"
@export var viewport_size: Vector2i = Vector2i(760, 500)
@export var panel_size: Vector2 = Vector2(1.0, 0.66)

var _camera: Camera3D = null
var _room_anchors: RoomAnchorRegistry = null
var _viewport: SubViewport = null
var _screen: MeshInstance3D = null
var _ui_root: Control = null
var _primary_body: RichTextLabel = null
var _restore_after_veil := false
var _action_targets: Array[Area3D] = []


func _ready() -> void:
	var rig := get_node_or_null(user_rig_path) as UserRig
	if rig != null:
		_camera = rig.get_camera()
	_room_anchors = get_node_or_null(room_anchor_registry_path) as RoomAnchorRegistry
	_build_surface()
	_build_ui(_ui_root)
	_connect_state()
	AppState.privacy_veil_changed.connect(_on_privacy_veil_changed)
	visible = false


func _connect_state() -> void:
	pass


func _build_ui(_root: Control) -> void:
	pass


func open() -> bool:
	if AppState.privacy_veil_active:
		return false
	_place_in_reading_zone()
	refresh()
	visible = true
	return true


func refresh() -> void:
	pass


func close() -> void:
	visible = false
	_restore_after_veil = false


func toggle() -> bool:
	if visible:
		close()
		return false
	return open()


func is_open() -> bool:
	return visible


func get_cockpit_viewport() -> SubViewport:
	return _viewport


func get_body_text() -> String:
	return _primary_body.text if _primary_body != null else ""


func make_title(root: Control, title: String, subtitle: String = "") -> void:
	var title_label := Label.new()
	title_label.text = title
	title_label.position = Vector2(22, 14)
	title_label.size = Vector2(float(viewport_size.x) - 44.0, 30)
	title_label.add_theme_font_size_override("font_size", 22)
	title_label.add_theme_color_override("font_color", COLOR_TITLE)
	title_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(title_label)
	if not subtitle.is_empty():
		var subtitle_label := Label.new()
		subtitle_label.text = subtitle
		subtitle_label.position = Vector2(22, 46)
		subtitle_label.size = Vector2(float(viewport_size.x) - 44.0, 22)
		subtitle_label.add_theme_font_size_override("font_size", 13)
		subtitle_label.add_theme_color_override("font_color", COLOR_MUTED)
		subtitle_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		root.add_child(subtitle_label)


func make_body(root: Control, rect: Rect2) -> RichTextLabel:
	var body := RichTextLabel.new()
	body.position = rect.position
	body.size = rect.size
	body.bbcode_enabled = true
	body.scroll_active = false
	body.mouse_filter = Control.MOUSE_FILTER_IGNORE
	body.add_theme_font_size_override("normal_font_size", 14)
	body.add_theme_color_override("default_color", COLOR_TEXT)
	root.add_child(body)
	_primary_body = body
	return body


func make_button(root: Control, rect: Rect2, text: String, target_id: String, accent: Color = COLOR_TITLE) -> PanelContainer:
	var panel := PanelContainer.new()
	panel.position = rect.position
	panel.size = rect.size
	var style := StyleBoxFlat.new()
	style.bg_color = COLOR_ACTION
	style.border_color = accent
	style.set_border_width_all(2)
	style.set_corner_radius_all(4)
	panel.add_theme_stylebox_override("panel", style)
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(panel)
	var label := Label.new()
	label.text = text
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", 15)
	label.add_theme_color_override("font_color", Color(0.85, 1, 1, 1))
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(label)
	add_screen_target(target_id, rect)
	return panel


func add_screen_target(target_id: String, rect: Rect2) -> Area3D:
	var target := Area3D.new()
	target.set_script(SPATIAL_TARGET_SCRIPT)
	target.set("target_id", target_id)
	target.collision_layer = 2
	target.collision_mask = 0
	target.monitoring = false
	target.add_to_group("interactable")
	var center := rect.position + rect.size * 0.5
	var scale_x := panel_size.x / float(viewport_size.x)
	var scale_y := panel_size.y / float(viewport_size.y)
	target.position = Vector3(
		(center.x - float(viewport_size.x) * 0.5) * scale_x,
		-(center.y - float(viewport_size.y) * 0.5) * scale_y,
		0.03
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
	_action_targets.append(target)
	return target


func clear_screen_targets() -> void:
	for target in _action_targets:
		target.queue_free()
	_action_targets.clear()


func set_target_visible(target_id: String, target_visible: bool) -> void:
	for target in _action_targets:
		if str(target.get("target_id")) == target_id:
			target.visible = target_visible
			target.collision_layer = 2 if target_visible else 0


func _build_surface() -> void:
	_viewport = SubViewport.new()
	_viewport.size = viewport_size
	_viewport.transparent_bg = true
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(_viewport)
	_ui_root = Control.new()
	_ui_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_ui_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_viewport.add_child(_ui_root)
	var background := PanelContainer.new()
	background.set_anchors_preset(Control.PRESET_FULL_RECT)
	var style := StyleBoxFlat.new()
	style.bg_color = COLOR_BG
	style.border_color = COLOR_BORDER
	style.set_border_width_all(3)
	style.set_corner_radius_all(6)
	background.add_theme_stylebox_override("panel", style)
	background.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_ui_root.add_child(background)
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.albedo_texture = _viewport.get_texture()
	material.no_depth_test = true
	_screen = MeshInstance3D.new()
	var quad := QuadMesh.new()
	quad.size = panel_size
	quad.material = material
	_screen.mesh = quad
	_screen.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_screen)
	add_screen_target("ui:%s_surface" % name.to_lower(), Rect2(Vector2.ZERO, Vector2(viewport_size)))


func _place_in_reading_zone() -> void:
	if _camera == null:
		return
	var camera_basis := _camera.global_transform.basis.orthonormalized()
	var offset := Vector3(horizontal_offset, vertical_offset, -distance_from_user)
	global_transform = Transform3D(camera_basis, _camera.global_position + camera_basis * offset)
	if _room_anchors != null:
		_room_anchors.register_anchor(
			"cockpit_%s" % name.to_lower(), "reading_zone", global_transform
		)


func _on_privacy_veil_changed(value: bool) -> void:
	if value:
		_restore_after_veil = visible
		visible = false
	elif _restore_after_veil:
		_restore_after_veil = false
		open()
