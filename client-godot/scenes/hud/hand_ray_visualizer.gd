class_name HandRayVisualizer
extends Node3D

@export var hand_source_path: NodePath = ^"../XRRuntime/OpenXRInteractionSource"
@export_range(0.25, 5.0, 0.05) var beam_length: float = 1.6
@export_range(0.004, 0.02, 0.001) var marker_radius: float = 0.009

const HANDS := ["left", "right"]
const MARKER_JOINT_ORDER := [
	"wrist",
	"palm",
	"thumb_tip",
	"index_proximal",
	"index_tip",
	"middle_tip",
	"ring_tip",
	"pinky_tip",
]
const COLOR_IDLE := Color(0.02, 0.92, 1, 0.9)
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
var _markers: Dictionary = {"left": {}, "right": {}}
var _marker_materials: Dictionary = {}
var _hint: Label3D = null


func _ready() -> void:
	_source = get_node_or_null(hand_source_path) as OpenXRInteractionSource
	_beam_material = _make_unique_material(_beam)
	_finger_material = _make_unique_material(_finger_light)
	_aim_material = _make_unique_material(_aim_light)
	_build_markers()
	_build_hint()
	visible = false


func _build_markers() -> void:
	var sphere := SphereMesh.new()
	sphere.radius = marker_radius
	sphere.height = marker_radius * 2.0
	sphere.radial_segments = 10
	sphere.rings = 6
	for hand_name in HANDS:
		var material := StandardMaterial3D.new()
		material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		material.albedo_color = COLOR_IDLE
		material.emission_enabled = true
		material.emission = Color(COLOR_IDLE.r, COLOR_IDLE.g, COLOR_IDLE.b, 1.0)
		material.emission_energy_multiplier = 2.2
		material.no_depth_test = true
		_marker_materials[hand_name] = material
		for joint_name in MARKER_JOINT_ORDER:
			var marker := MeshInstance3D.new()
			marker.mesh = sphere
			marker.material_override = material
			marker.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			marker.visible = false
			add_child(marker)
			(_markers[hand_name] as Dictionary)[joint_name] = marker


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
	any_visible = _update_markers(any_visible)
	any_visible = _update_pointer(any_visible)

	var show_hint := AppState.ui_mode == "xr_hands" and not _source.has_tracking_data()
	_hint.visible = show_hint
	if show_hint:
		_place_hint()
		any_visible = true
	visible = any_visible


func _update_markers(any_visible: bool) -> bool:
	for hand_name in HANDS:
		var sample := _source.get_latest_hand_sample(hand_name)
		var joints: Dictionary = sample.get("joints", {})
		var pinching := _source.is_hand_pinching(hand_name)
		var color := COLOR_PINCH if pinching else COLOR_IDLE
		var material: StandardMaterial3D = _marker_materials.get(hand_name)
		if material != null:
			material.albedo_color = color
			material.emission = Color(color.r, color.g, color.b, 1.0)
		for joint_name in MARKER_JOINT_ORDER:
			var marker: MeshInstance3D = (_markers[hand_name] as Dictionary).get(joint_name)
			if marker == null:
				continue
			if joints.has(joint_name):
				marker.global_position = joints[joint_name]
				marker.visible = true
				any_visible = true
			else:
				marker.visible = false
	return any_visible


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
	var side := direction.cross(Vector3.UP)
	if side.length_squared() < 0.0001:
		side = direction.cross(Vector3.RIGHT)
	side = side.normalized()
	var forward := side.cross(direction).normalized()
	var beam_basis := Basis(side, direction, forward).orthonormalized()
	_beam.global_transform = Transform3D(
		beam_basis,
		pointer.origin + direction * beam_length * 0.5
	)
	_beam.scale = Vector3(1.0, beam_length, 1.0)
	_finger_light.global_position = pointer.origin
	_aim_light.global_position = pointer.origin + direction * beam_length
	_beam.visible = true
	_finger_light.visible = true
	_aim_light.visible = true

	var color := COLOR_PINCH if pointer.is_selecting else Color(COLOR_IDLE.r, COLOR_IDLE.g, COLOR_IDLE.b, 0.72)
	_set_material_color(_beam_material, color)
	_set_material_color(_finger_material, color)
	_set_material_color(_aim_material, color)
	var pulse := 1.0 + sin(float(Time.get_ticks_msec()) * 0.012) * 0.14
	_aim_light.scale = Vector3.ONE * pulse
	return true


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
