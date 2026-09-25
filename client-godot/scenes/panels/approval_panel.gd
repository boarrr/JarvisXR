class_name ApprovalPanel
extends Node3D

@export var user_rig_path: NodePath = ^"../UserRig"
@export_range(0.4, 1.6, 0.05) var park_distance: float = 0.8
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
	_summary_label.text = str(request.get("summary", "The agent requested an action."))
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
	look_at(camera_position, Vector3.UP, true)
	if _room_anchors != null:
		_room_anchors.register_anchor("approval_surface", "approval_gate", global_transform)


func _on_approval_requested(_request: Dictionary) -> void:
	if not is_open():
		_show_next_approval()


func _on_approval_resolved(approval_id: String) -> void:
	if approval_id == _approval_id:
		_show_next_approval()


func get_impact_preview() -> ApprovalImpactPreview:
	return _impact_preview
