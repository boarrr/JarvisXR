class_name UserRig
extends Node3D

## XR-only player rig. In OpenXR the camera is driven by the runtime; the rig
## only mirrors the XR camera into the scene so layout anchors can follow.

@onready var _yaw_pivot: Node3D = $YawPivot
@onready var _pitch_pivot: Node3D = $YawPivot/PitchPivot
@onready var _camera: Camera3D = $YawPivot/PitchPivot/Camera3D

var _xr_tracking_active := false


func get_camera() -> Camera3D:
	return _camera


func set_xr_tracking_active(value: bool) -> void:
	_xr_tracking_active = value
	_camera.current = not value


func sync_from_xr_camera(xr_camera: XRCamera3D) -> void:
	if not _xr_tracking_active or xr_camera == null:
		return
	global_transform = xr_camera.global_transform
