class_name UserRig
extends Node3D

@export_range(0.1, 20.0, 0.1, "or_greater") var move_speed: float = 3.5
@export_range(0.0001, 0.02, 0.0001) var mouse_sensitivity: float = 0.0012
@export_range(1.0, 89.0, 1.0) var pitch_limit_degrees: float = 85.0

@onready var _yaw_pivot: Node3D = $YawPivot
@onready var _pitch_pivot: Node3D = $YawPivot/PitchPivot
@onready var _camera: Camera3D = $YawPivot/PitchPivot/Camera3D
@onready var _desktop_interaction_source: DesktopInteractionSource = $DesktopInteractionSource

var _yaw_radians: float = 0.0
var _pitch_radians: float = 0.0
var _xr_tracking_active := false
var hand_lab_active := false


func _ready() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _process(delta: float) -> void:
	if _xr_tracking_active or AppState.text_input_active:
		return
	var local_direction := Vector3(
		Input.get_axis("move_left", "move_right"),
		Input.get_axis("move_down", "move_up"),
		Input.get_axis("move_forward", "move_back")
	)
	if local_direction.length_squared() > 1.0:
		local_direction = local_direction.normalized()

	var horizontal_local := Vector3(local_direction.x, 0.0, local_direction.z)
	var world_direction := _yaw_pivot.global_transform.basis * horizontal_local
	world_direction.y = local_direction.y
	if world_direction.length_squared() > 1.0:
		world_direction = world_direction.normalized()
	global_position += world_direction * move_speed * delta


func _unhandled_input(event: InputEvent) -> void:
	if _xr_tracking_active or AppState.text_input_active:
		return
	if hand_lab_active:
		if event is InputEventMouseMotion and Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT):
			_apply_mouse_look(event.relative)
			get_viewport().set_input_as_handled()
		return
	if event.is_action_pressed("ui_cancel"):
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		get_viewport().set_input_as_handled()
		return

	if event.is_action_pressed("pointer_select") and Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		get_viewport().set_input_as_handled()
		return

	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		_apply_mouse_look(event.relative)
		get_viewport().set_input_as_handled()


func _apply_mouse_look(relative_motion: Vector2) -> void:
	_yaw_radians -= relative_motion.x * mouse_sensitivity
	_pitch_radians -= relative_motion.y * mouse_sensitivity
	var pitch_limit := deg_to_rad(pitch_limit_degrees)
	_pitch_radians = clampf(_pitch_radians, -pitch_limit, pitch_limit)

	_yaw_pivot.rotation.y = _yaw_radians
	_pitch_pivot.rotation.x = _pitch_radians


func get_interaction_source() -> DesktopInteractionSource:
	return _desktop_interaction_source


func set_hand_lab_active(value: bool) -> void:
	hand_lab_active = value
	_desktop_interaction_source.set_process(not value)
	_desktop_interaction_source.set_process_input(not value)
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE if value else Input.MOUSE_MODE_CAPTURED


func reset_desktop_view() -> void:
	if _xr_tracking_active:
		return
	global_position = Vector3(0.0, 1.65, 0.0)
	_yaw_radians = 0.0
	_pitch_radians = 0.0
	_yaw_pivot.rotation = Vector3.ZERO
	_pitch_pivot.rotation = Vector3.ZERO


func get_camera() -> Camera3D:
	return _camera


func set_xr_tracking_active(value: bool) -> void:
	_xr_tracking_active = value
	_camera.current = not value
	if value:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	else:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func sync_from_xr_camera(xr_camera: XRCamera3D) -> void:
	if not _xr_tracking_active or xr_camera == null:
		return
	global_transform = xr_camera.global_transform


func get_yaw_degrees() -> float:
	return rad_to_deg(_yaw_radians)


func get_pitch_degrees() -> float:
	return rad_to_deg(_pitch_radians)
