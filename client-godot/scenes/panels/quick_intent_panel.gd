class_name QuickIntentPanel
extends Node3D

const PROMPTS := {
	"quick:continue": "Continue the current task and report the next concrete result.",
	"quick:summarize": "Summarize progress, blockers, and next actions.",
	"quick:explain_code": "Explain the latest code changes and their risks.",
	"quick:privacy_review": "Review this thread for privacy and security concerns.",
	"quick:explore": "Explore this repository: run `ls -la`, then `cat scripts/run_builder.sh`, one command at a time and show each result. Then give me a 3-bullet summary of what this repo is and what run_builder.sh launches.",
}

@export var user_rig_path: NodePath = ^"../UserRig"
@export_range(0.8, 3.0, 0.05) var distance_from_user: float = 1.35
@export_range(-1.2, 1.2, 0.05) var vertical_offset: float = -0.05

var _camera: Camera3D = null


func _ready() -> void:
	var rig := get_node_or_null(user_rig_path) as UserRig
	if rig != null:
		_camera = rig.get_camera()
	AppState.focused_thread_changed.connect(_on_focused_thread_changed)
	visible = false


func toggle() -> bool:
	if visible:
		close()
		return false
	return open()


func open() -> bool:
	if AppState.focused_thread_id.is_empty():
		return false
	_place_in_reading_zone()
	visible = true
	return true


func close() -> void:
	visible = false


func get_prompt(target_id: String) -> String:
	return str(PROMPTS.get(target_id, ""))


func _place_in_reading_zone() -> void:
	if _camera == null:
		return
	var camera_basis := _camera.global_transform.basis.orthonormalized()
	var offset := Vector3(0.0, vertical_offset, -distance_from_user)
	global_transform = Transform3D(camera_basis, _camera.global_position + camera_basis * offset)


func _on_focused_thread_changed(thread_id: String) -> void:
	if thread_id.is_empty():
		close()
