class_name ApprovalPanel
extends Node3D

@export var user_rig_path: NodePath = ^"../UserRig"
@export_range(0.7, 2.0, 0.05) var park_distance: float = 1.0
@export_range(-1.0, 1.0, 0.05) var park_side_offset: float = -0.12
@export_range(0.0, 0.6, 0.01) var park_drop: float = 0.16
@export var room_anchor_registry_path: NodePath = ^"../RoomAnchorRegistry"

@onready var _title_label: Label3D = $TitleLabel
@onready var _summary_label: Label3D = $SummaryLabel
@onready var _permission_label: Label3D = $PermissionLabel
@onready var _impact_preview: ApprovalImpactPreview = $ImpactPreview

var _camera: Camera3D = null
var _room_anchors: RoomAnchorRegistry = null
var _approval_id: String = ""


func _ready() -> void:
	var rig := get_node_or_null(user_rig_path) as UserRig
	if rig != null:
		_camera = rig.get_camera()
	_room_anchors = get_node_or_null(room_anchor_registry_path) as RoomAnchorRegistry
	AppState.approval_requested.connect(_on_approval_requested)
	AppState.approval_resolved.connect(_on_approval_resolved)
	visible = false
	_show_next_approval()


func get_approval_id() -> String:
	return _approval_id


func is_open() -> bool:
	return visible and not _approval_id.is_empty()


func _show_next_approval() -> void:
	var request := AppState.get_next_approval()
	if request.is_empty():
		visible = false
		_approval_id = ""
		return
	_approval_id = str(request.get("approval_id", ""))
	_title_label.text = "APPROVAL REQUIRED  ·  %s" % request.get("tool_name", "Tool")
	var summary := str(request.get("summary", "The agent requested an action."))
	if summary.length() > 220:
		summary = summary.substr(0, 217) + "..."
	_summary_label.text = summary
	_permission_label.text = "%s // EXPLICIT HAND CONFIRMATION" % str(
		request.get("permission_level", "explicit approval")
	).to_upper()
	_impact_preview.configure(request.get("impact_preview", {}) as Dictionary)
	_place_in_reading_zone()
	visible = true


func _place_in_reading_zone() -> void:
	# Mirror the palm panel's parking: spawn relative to the user's view (so it
	# always lands comfortably in front of them), then stay put in the room.
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
	# Yaw-billboard: stay put in the room but keep the face turned toward the
	# user so the text and buttons never go edge-on and vanish.
	if not visible or _camera == null:
		return
	_face_user(delta)


func _face_user(delta: float) -> void:
	var to_user := _camera.global_position - global_position
	if to_user.length_squared() < 0.0001:
		return
	var forward := to_user.normalized()
	# Clamp pitch so the panel tilts up/down toward the user's head (readable
	# from any height) but never flips over.
	forward.y = clampf(forward.y, -0.6, 0.6)
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
		basis = basis.slerp(desired, 1.0 - exp(-8.0 * delta))
	global_transform = Transform3D(basis.orthonormalized(), global_position)


func _on_approval_requested(_request: Dictionary) -> void:
	if not is_open():
		_show_next_approval()


func _on_approval_resolved(approval_id: String) -> void:
	if approval_id == _approval_id:
		_show_next_approval()


func get_impact_preview() -> ApprovalImpactPreview:
	return _impact_preview
