class_name HandRayVisualizer
extends Node3D

@export var hand_source_path: NodePath = ^"../XRRuntime/OpenXRInteractionSource"
@export_range(0.25, 5.0, 0.05) var beam_length: float = 1.4

@onready var _beam: MeshInstance3D = $Beam
@onready var _finger_light: MeshInstance3D = $FingerLight
@onready var _aim_light: MeshInstance3D = $AimLight

var _source: OpenXRInteractionSource = null
var _beam_material: StandardMaterial3D = null
var _finger_material: StandardMaterial3D = null
var _aim_material: StandardMaterial3D = null


func _ready() -> void:
	_source = get_node_or_null(hand_source_path) as OpenXRInteractionSource
	_beam_material = _make_unique_material(_beam)
	_finger_material = _make_unique_material(_finger_light)
	_aim_material = _make_unique_material(_aim_light)
	visible = false


func _process(_delta: float) -> void:
	if _source == null or AppState.ui_mode not in ["xr_hands", "hand_lab"] or not _source.has_tracking_data():
		visible = false
		return
	var pointer := _source.get_pointer_state()
	if pointer == null or pointer.direction.is_zero_approx():
		visible = false
		return

	visible = true
	# The lab ray is collinear with the cursor. A beam adds no aiming cue and
	# can intersect the near plane; keep the destination marker instead.
	_beam.visible = AppState.ui_mode != "hand_lab"
	_finger_light.visible = AppState.ui_mode != "hand_lab"
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

	var color := Color(1.0, 0.48, 0.12, 0.92) if pointer.is_selecting else Color(0.02, 0.92, 1.0, 0.78)
	_set_material_color(_beam_material, color)
	_set_material_color(_finger_material, color)
	_set_material_color(_aim_material, color)
	var pulse := 1.0 + sin(float(Time.get_ticks_msec()) * 0.012) * 0.14
	_aim_light.scale = Vector3.ONE * pulse


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
