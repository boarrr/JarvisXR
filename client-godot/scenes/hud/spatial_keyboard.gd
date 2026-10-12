class_name SpatialKeyboard
extends Node3D

## Cockpit-styled on-screen keyboard, shown only when no hardware keyboard is
## detected. Keys are world-space pinch targets; main routes them to the palm
## composer.

signal key_input(text: String)
signal special(name: String)

const TARGET_SCRIPT := preload("res://interaction/spatial_action_target.gd")
const VIEWPORT_SIZE := Vector2i(760, 380)
const SCREEN_SIZE := Vector2(0.72, 0.36)
const ROWS := ["1234567890", "qwertyuiop", "asdfghjkl", "zxcvbnm"]
const GAP := 6.0
const PAD := 16.0
const KEY_H := 60.0
const ROW_GAP := 8.0
const TOP := 14.0

@export var user_rig_path: NodePath = ^"../UserRig"
@export_range(0.25, 1.2, 0.01) var distance_from_user: float = 0.40
@export_range(-1.0, 0.0, 0.01) var vertical_offset: float = -0.34
# Tilt the top edge away from the user so it reads like a desk keyboard. Negative
# tips the readable face up toward the user.
@export_range(-60.0, 20.0, 1.0) var tilt_degrees: float = -22.0

var _camera: Camera3D = null
var _viewport: SubViewport = null
var _screen: MeshInstance3D = null
var _key_nodes: Dictionary = {}


func _ready() -> void:
	var rig := get_node_or_null(user_rig_path) as UserRig
	if rig != null:
		_camera = rig.get_camera()
	_build()
	_build_touch_surface()
	visible = false


func _build_touch_surface() -> void:
	# Hand-stop surface so fingers rest on the keys instead of passing through.
	var surface := Area3D.new()
	surface.name = "KeyboardSurface"
	surface.collision_layer = 2
	surface.collision_mask = 0
	surface.monitoring = false
	surface.add_to_group("touch_surface")
	var box := BoxShape3D.new()
	box.size = Vector3(SCREEN_SIZE.x, SCREEN_SIZE.y, 0.03)
	var collision := CollisionShape3D.new()
	collision.shape = box
	surface.add_child(collision)
	add_child(surface)


func is_open() -> bool:
	return visible


func open() -> bool:
	if _camera == null:
		var rig := get_node_or_null(user_rig_path) as UserRig
		_camera = rig.get_camera() if rig != null else null
	if _camera == null:
		return false
	_place_in_reading_zone()
	visible = true
	return true


func close() -> void:
	visible = false


func handle_key(target_id: String) -> void:
	if not target_id.begins_with("kbd:"):
		return
	var parts := target_id.split(":", false, 3)
	if parts.size() < 3:
		return
	var kind := parts[1]
	var value := parts[2]
	match kind:
		"k":
			key_input.emit(value)
		"special":
			special.emit(value)


func _build() -> void:
	_viewport = SubViewport.new()
	_viewport.size = VIEWPORT_SIZE
	_viewport.transparent_bg = true
	_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	add_child(_viewport)

	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_viewport.add_child(root)

	var background := PanelContainer.new()
	background.set_anchors_preset(Control.PRESET_FULL_RECT)
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.03, 0.09, 0.13, 0.96)
	style.border_color = Color(0.15, 0.95, 1.0, 1.0)
	style.set_border_width_all(4)
	style.set_corner_radius_all(10)
	background.add_theme_stylebox_override("panel", style)
	background.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(background)

	var row_y := TOP
	for row_text_variant in ROWS:
		var row_text := str(row_text_variant)
		var count := row_text.length()
		var available := float(VIEWPORT_SIZE.x) - PAD * 2.0 - GAP * float(count - 1)
		var key_w := available / float(count)
		for index in range(count):
			var character := row_text.substr(index, 1)
			var rect := Rect2(PAD + float(index) * (key_w + GAP), row_y, key_w, KEY_H)
			_add_key(root, rect, character.to_upper(), "kbd:k:%s" % character)
		row_y += KEY_H + ROW_GAP

	# Bottom row: SPACE / backspace / enter / close.
	var inner := float(VIEWPORT_SIZE.x) - PAD * 2.0
	var space_w := inner * 0.58
	var small_w := (inner - space_w - GAP * 3.0) / 3.0
	var bx := PAD
	_add_key(root, Rect2(bx, row_y, space_w, KEY_H), "SPACE", "kbd:special:space")
	bx += space_w + GAP
	_add_key(root, Rect2(bx, row_y, small_w, KEY_H), "⌫", "kbd:special:backspace")
	bx += small_w + GAP
	_add_key(root, Rect2(bx, row_y, small_w, KEY_H), "ENTER", "kbd:special:enter")
	bx += small_w + GAP
	_add_key(root, Rect2(bx, row_y, small_w, KEY_H), "HIDE", "kbd:special:close")

	_add_screen()


func _add_key(root: Control, rect: Rect2, label_text: String, target_id: String) -> void:
	var panel := PanelContainer.new()
	panel.position = rect.position
	panel.size = rect.size
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.05, 0.32, 0.4, 1.0)
	style.border_color = Color(0.15, 0.6, 0.68, 1.0)
	style.set_border_width_all(2)
	style.set_corner_radius_all(6)
	panel.add_theme_stylebox_override("panel", style)
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(panel)
	var label := Label.new()
	label.text = label_text
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", 20)
	label.add_theme_color_override("font_color", Color(0.9, 1.0, 1.0))
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(label)

	var area := Area3D.new()
	area.set_script(TARGET_SCRIPT)
	area.set("target_id", target_id)
	area.collision_layer = 2
	area.collision_mask = 0
	area.monitoring = false
	area.add_to_group("interactable")
	var scale_x := SCREEN_SIZE.x / float(VIEWPORT_SIZE.x)
	var scale_y := SCREEN_SIZE.y / float(VIEWPORT_SIZE.y)
	var shape := BoxShape3D.new()
	shape.size = Vector3(rect.size.x * scale_x, rect.size.y * scale_y, 0.006)
	var collision := CollisionShape3D.new()
	collision.shape = shape
	area.add_child(collision)
	area.position = _rect_to_local(rect)
	add_child(area)
	_key_nodes[target_id] = area


func _add_screen() -> void:
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.albedo_texture = _viewport.get_texture()
	material.no_depth_test = false
	_screen = MeshInstance3D.new()
	var quad := QuadMesh.new()
	quad.size = SCREEN_SIZE
	quad.material = material
	_screen.mesh = quad
	_screen.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_screen)


func _rect_to_local(rect: Rect2) -> Vector3:
	var center := rect.position + rect.size * 0.5
	var scale_x := SCREEN_SIZE.x / float(VIEWPORT_SIZE.x)
	var scale_y := SCREEN_SIZE.y / float(VIEWPORT_SIZE.y)
	return Vector3(
		(center.x - float(VIEWPORT_SIZE.x) * 0.5) * scale_x,
		-(center.y - float(VIEWPORT_SIZE.y) * 0.5) * scale_y,
		0.004
	)


func _place_in_reading_zone() -> void:
	# Face the user with a level yaw only (the full camera basis made the keyboard
	# inherit head pitch/roll and sit at a bad angle), then tilt it like a desk
	# keyboard. Placed lower than the palm console so the two never clip.
	var forward := -_camera.global_transform.basis.z
	forward.y = 0.0
	if forward.length_squared() < 0.0001:
		forward = Vector3.FORWARD
	forward = forward.normalized()
	var yaw := atan2(-forward.x, -forward.z)
	var basis := Basis(Vector3.UP, yaw) * Basis(Vector3.RIGHT, deg_to_rad(tilt_degrees))
	var position := _camera.global_position + forward * distance_from_user
	position.y += vertical_offset
	global_transform = Transform3D(basis, position)
