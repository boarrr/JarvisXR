class_name PrivacyVeil
extends Node3D

@export var user_rig_path: NodePath = ^"../UserRig"
@export_range(0.5, 2.0, 0.05) var distance_from_user := 0.85

@onready var _status_label: Label3D = $StatusLabel
var _camera: Camera3D = null


func _ready() -> void:
	var rig := get_node_or_null(user_rig_path) as UserRig
	if rig != null:
		_camera = rig.get_camera()
	AppState.privacy_veil_changed.connect(set_active)
	set_active(AppState.privacy_veil_active)


func _process(_delta: float) -> void:
	if not visible or _camera == null:
		return
	var basis := _camera.global_basis.orthonormalized()
	global_transform = Transform3D(
		basis,
		_camera.global_position + basis * Vector3(0.0, 0.08, -distance_from_user)
	)


func set_active(value: bool) -> void:
	visible = value
	set_process(value)


func is_active() -> bool:
	return visible


func get_display_text() -> String:
	return _status_label.text
