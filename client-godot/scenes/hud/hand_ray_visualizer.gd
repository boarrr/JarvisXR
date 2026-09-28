class_name HandRayVisualizer
extends Node3D

@export var hand_source_path: NodePath = ^"../XRRuntime/OpenXRInteractionSource"
@export_range(0.25, 5.0, 0.05) var beam_length: float = 1.6
@export_range(0.004, 0.02, 0.001) var marker_radius: float = 0.009

const HANDS := ["left", "right"]
const FULL_JOINT_NAMES := [
	"palm", "wrist",
	"thumb_metacarpal", "thumb_proximal", "thumb_distal", "thumb_tip",
	"index_metacarpal", "index_proximal", "index_distal", "index_tip",
	"middle_metacarpal", "middle_proximal", "middle_distal", "middle_tip",
	"ring_metacarpal", "ring_proximal", "ring_distal", "ring_tip",
	"pinky_metacarpal", "pinky_proximal", "pinky_distal", "pinky_tip",
]
const GLOVE_CHAINS := [
	["wrist", "palm"],
	["palm", "thumb_metacarpal"], ["thumb_metacarpal", "thumb_proximal"],
	["thumb_proximal", "thumb_distal"], ["thumb_distal", "thumb_tip"],
	["palm", "index_metacarpal"], ["index_metacarpal", "index_proximal"],
	["index_proximal", "index_distal"], ["index_distal", "index_tip"],
	["palm", "middle_metacarpal"], ["middle_metacarpal", "middle_proximal"],
	["middle_proximal", "middle_distal"], ["middle_distal", "middle_tip"],
	["palm", "ring_metacarpal"], ["ring_metacarpal", "ring_proximal"],
	["ring_proximal", "ring_distal"], ["ring_distal", "ring_tip"],
	["palm", "pinky_metacarpal"], ["pinky_metacarpal", "pinky_proximal"],
	["pinky_proximal", "pinky_distal"], ["pinky_distal", "pinky_tip"],
]
const GLOVE_RADII := {
	"wrist": 0.026, "palm": 0.024,
	"thumb_metacarpal": 0.013, "thumb_proximal": 0.012, "thumb_distal": 0.011, "thumb_tip": 0.010,
	"index_metacarpal": 0.012, "index_proximal": 0.011, "index_distal": 0.010, "index_tip": 0.009,
	"middle_metacarpal": 0.012, "middle_proximal": 0.011, "middle_distal": 0.010, "middle_tip": 0.009,
	"ring_metacarpal": 0.011, "ring_proximal": 0.010, "ring_distal": 0.009, "ring_tip": 0.008,
	"pinky_metacarpal": 0.010, "pinky_proximal": 0.009, "pinky_distal": 0.008, "pinky_tip": 0.008,
}
const BONE_RADIUS := 0.009
const RAY_LENGTH := 6.0
const COLOR_IDLE := Color(0.02, 0.92, 1, 0.9)
const COLOR_HOVER := Color(0.45, 1.0, 0.55, 0.95)
const COLOR_PINCH := Color(1.0, 0.48, 0.12, 0.95)
const HINT_TEXT := (
	"HAND TRACKING: NO DATA\n"
	+ "Put the controllers down, or enable\n"
	+ "Settings > Movement Tracking > Hand and Body Tracking"
)

@onready var _beam: MeshInstance3D = $Beam
@onready var _finger_light: MeshInstance3D = $FingerLight
@onready var _aim_light: MeshInstance3D = $AimLight

var _source: OpenXRInteractionSource = null
var _beam_material: StandardMaterial3D = null
var _finger_material: StandardMaterial3D = null
var _aim_material: StandardMaterial3D = null
var _glove_joints: Dictionary = {"left": {}, "right": {}}
var _glove_bones: Dictionary = {"left": [], "right": []}
var _glove_materials: Dictionary = {}
var _hint: Label3D = null
var _gesture_hud: Label3D = null
var _gesture_hud_enabled := false


func _ready() -> void:
	_source = get_node_or_null(hand_source_path) as OpenXRInteractionSource
	_beam_material = _make_unique_material(_beam)
	_finger_material = _make_unique_material(_finger_light)
	_aim_material = _make_unique_material(_aim_light)
	_build_glove()
	_build_hint()
	_gesture_hud_enabled = bool(ProjectSettings.get_setting("spatial_agent/gesture_hud", false))
	if _gesture_hud_enabled:
		_build_gesture_hud()
	visible = false


func _build_glove() -> void:
	var sphere := SphereMesh.new()
	sphere.radius = 1.0
	sphere.height = 2.0
	sphere.radial_segments = 12
	sphere.rings = 8
	var cylinder := CylinderMesh.new()
	cylinder.top_radius = 1.0
	cylinder.bottom_radius = 1.0
	cylinder.height = 1.0
	cylinder.radial_segments = 8
	for hand_name in HANDS:
		var material := StandardMaterial3D.new()
		material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		material.albedo_color = COLOR_IDLE
		material.emission_enabled = true
		material.emission = Color(COLOR_IDLE.r, COLOR_IDLE.g, COLOR_IDLE.b, 1.0)
		material.emission_energy_multiplier = 1.6
		material.no_depth_test = true
		_glove_materials[hand_name] = material
		var joint_nodes: Dictionary = {}
		for joint_name in FULL_JOINT_NAMES:
			var node := MeshInstance3D.new()
			node.mesh = sphere
			node.material_override = material
			node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			node.visible = false
			add_child(node)
			joint_nodes[joint_name] = node
		_glove_joints[hand_name] = joint_nodes
		var bone_nodes: Array = []
		for _chain in GLOVE_CHAINS:
			var bone := MeshInstance3D.new()
			bone.mesh = cylinder
			bone.material_override = material
			bone.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			bone.visible = false
			add_child(bone)
			bone_nodes.append(bone)
		_glove_bones[hand_name] = bone_nodes


func _build_hint() -> void:
	_hint = Label3D.new()
	_hint.text = HINT_TEXT
	_hint.font_size = 40
	_hint.outline_size = 8
	_hint.pixel_size = 0.0016
	_hint.modulate = Color(1.0, 0.78, 0.35, 1.0)
	_hint.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_hint.no_depth_test = true
	_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hint.visible = false
	add_child(_hint)


func _process(_delta: float) -> void:
	if _source == null or AppState.ui_mode not in ["xr_hands", "hand_lab"]:
		visible = false
		return

	var any_visible := false
	any_visible = _update_glove(any_visible)
	any_visible = _update_pointer(any_visible)

	var show_hint := AppState.ui_mode == "xr_hands" and not _source.has_tracking_data()
	_hint.visible = show_hint
	if show_hint:
		_place_hint()
		any_visible = true
	if _gesture_hud != null:
		_update_gesture_hud()
		_gesture_hud.visible = AppState.ui_mode == "xr_hands" or AppState.ui_mode == "hand_lab"
		if _gesture_hud.visible:
			any_visible = true
	visible = any_visible


func _update_glove(any_visible: bool) -> bool:
	for hand_name in HANDS:
		var positions := _source.get_hand_joint_positions(hand_name)
		var pinching := _source.is_hand_pinching(hand_name)
		var color := COLOR_PINCH if pinching else COLOR_IDLE
		var material: StandardMaterial3D = _glove_materials.get(hand_name)
		if material != null:
			material.albedo_color = color
			material.emission = Color(color.r, color.g, color.b, 1.0)
		var joint_nodes: Dictionary = _glove_joints[hand_name]
		for joint_name in FULL_JOINT_NAMES:
			var node: MeshInstance3D = joint_nodes[joint_name]
			if positions.has(joint_name):
				node.global_position = positions[joint_name]
				node.scale = Vector3.ONE * float(GLOVE_RADII.get(joint_name, 0.010))
				node.visible = true
				any_visible = true
			else:
				node.visible = false
		var bone_nodes: Array = _glove_bones[hand_name]
		for index in range(GLOVE_CHAINS.size()):
			var bone: MeshInstance3D = bone_nodes[index]
			var chain: Array = GLOVE_CHAINS[index]
			if positions.has(chain[0]) and positions.has(chain[1]):
				_orient_bone(bone, positions[chain[0]], positions[chain[1]])
				any_visible = true
			else:
				bone.visible = false
	return any_visible


func _orient_bone(node: MeshInstance3D, a: Vector3, b: Vector3) -> void:
	var delta := b - a
	var length := delta.length()
	if length < 0.0005:
		node.visible = false
		return
	var direction := delta / length
	var up := Vector3.UP
	if absf(direction.dot(up)) > 0.95:
		up = Vector3.RIGHT
	# Explicit orthonormal basis with local +Y along the bone so the Y-aligned
	# cylinder capsule lies exactly between the two joints.
	var x_axis := direction.cross(up).normalized()
	var z_axis := x_axis.cross(direction).normalized()
	var basis := Basis(x_axis, direction, z_axis)
	var transform := Transform3D(basis, (a + b) * 0.5)
	transform = transform.scaled_local(Vector3(BONE_RADIUS, length, BONE_RADIUS))
	node.global_transform = transform
	node.visible = true


func _update_pointer(any_visible: bool) -> bool:
	if not _source.has_tracking_data():
		_beam.visible = false
		_finger_light.visible = false
		_aim_light.visible = false
		return any_visible
	var pointer := _source.get_pointer_state()
	if pointer == null or pointer.direction.is_zero_approx():
		_beam.visible = false
		_finger_light.visible = false
		_aim_light.visible = false
		return any_visible

	var direction := pointer.direction.normalized()
	var cursor_position := pointer.origin + direction * beam_length
	var visual_length := beam_length
	var hit := _raycast(pointer.origin, direction)
	if not hit.is_empty():
		cursor_position = hit.get("position", cursor_position) as Vector3
		visual_length = maxf(0.05, pointer.origin.distance_to(cursor_position))

	var side := direction.cross(Vector3.UP)
	if side.length_squared() < 0.0001:
		side = direction.cross(Vector3.RIGHT)
	side = side.normalized()
	var forward := side.cross(direction).normalized()
	var beam_basis := Basis(side, direction, forward).orthonormalized()
	_beam.global_transform = Transform3D(
		beam_basis,
		pointer.origin + direction * visual_length * 0.5
	)
	_beam.scale = Vector3(1.0, visual_length, 1.0)
	_finger_light.global_position = pointer.origin
	_aim_light.global_position = cursor_position
	_beam.visible = true
	_finger_light.visible = true
	_aim_light.visible = true

	var color := COLOR_IDLE
	if pointer.is_selecting:
		color = COLOR_PINCH
	elif not AppState.hovered_target_id.is_empty():
		color = COLOR_HOVER
	_set_material_color(_beam_material, color)
	_set_material_color(_finger_material, color)
	_set_material_color(_aim_material, color)
	var pulse := 1.0 + sin(float(Time.get_ticks_msec()) * 0.012) * 0.14
	_aim_light.scale = Vector3.ONE * pulse
	return true


func _raycast(origin: Vector3, direction: Vector3) -> Dictionary:
	var query := PhysicsRayQueryParameters3D.create(origin, origin + direction * RAY_LENGTH, 2)
	query.collide_with_areas = true
	query.collide_with_bodies = false
	query.hit_from_inside = true
	var excluded: Array[RID] = []
	# Mirror InteractionManager: skip hidden surfaces without semantic targets so
	# the cursor snaps to what a pinch would actually select.
	for _attempt in range(32):
		var hit := get_world_3d().direct_space_state.intersect_ray(query)
		if hit.is_empty():
			return {}
		var collider := hit.get("collider") as Node
		if collider == null:
			return {}
		if (
			collider.is_in_group("interactable")
			and collider.has_method("get_interaction_target_id")
			and not str(collider.call("get_interaction_target_id")).is_empty()
		):
			return hit
		excluded.append(collider.get_rid())
		query.exclude = excluded
	return {}


func _build_gesture_hud() -> void:
	_gesture_hud = Label3D.new()
	_gesture_hud.font_size = 26
	_gesture_hud.outline_size = 6
	_gesture_hud.pixel_size = 0.0016
	_gesture_hud.modulate = Color(0.75, 0.95, 1.0, 1.0)
	_gesture_hud.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_gesture_hud.no_depth_test = true
	_gesture_hud.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	_gesture_hud.visible = false
	add_child(_gesture_hud)


func _update_gesture_hud() -> void:
	if _source == null or _gesture_hud == null:
		return
	var flags := _source.get_tracking_flags()
	var lines: PackedStringArray = []
	lines.append("GESTURES  hover=%s" % (AppState.hovered_target_id if not AppState.hovered_target_id.is_empty() else "-"))
	for hand_name in ["right", "left"]:
		var tracked := bool(flags.get(hand_name, false))
		var sample := _source.get_latest_hand_sample(hand_name)
		var pinch_mm := 0.0
		if not sample.is_empty():
			var thumb: Vector3 = sample.get("thumb_tip", Vector3.ZERO)
			var index: Vector3 = sample.get("index_tip", Vector3.ZERO)
			pinch_mm = thumb.distance_to(index) * 1000.0
		lines.append("%s %s pinch=%.0fmm fist=%s select=%s" % [
			hand_name.to_upper(),
			"tracked" if tracked else "MISSING",
			pinch_mm,
			_source.get_fist_state(hand_name),
			_source.is_hand_pinching(hand_name),
		])
	_gesture_hud.text = "\n".join(lines)
	var camera := get_viewport().get_camera_3d()
	if camera != null:
		var basis := camera.global_transform.basis.orthonormalized()
		_gesture_hud.global_position = camera.global_position + basis * Vector3(-0.42, 0.30, -1.1)


func _place_hint() -> void:
	var camera := get_viewport().get_camera_3d()
	if camera == null:
		_hint.global_position = Vector3(0, 1.6, -1.4)
		return
	var basis := camera.global_transform.basis.orthonormalized()
	_hint.global_position = camera.global_position + basis * Vector3(0, -0.15, -1.4)


func _make_unique_material(mesh_instance: MeshInstance3D) -> StandardMaterial3D:
	var material := mesh_instance.get_active_material(0) as StandardMaterial3D
	if material == null:
		return null
	var unique_material := material.duplicate() as StandardMaterial3D
	mesh_instance.material_override = unique_material
	return unique_material


func _set_material_color(material: StandardMaterial3D, color: Color) -> void:
	if material == null:
		return
	material.albedo_color = color
	material.emission = Color(color.r, color.g, color.b, 1.0)
