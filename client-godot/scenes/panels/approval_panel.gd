class_name ApprovalPanel
extends Node3D

@export var user_rig_path: NodePath = ^"../UserRig"
@export_range(0.8, 2.5, 0.05) var distance_from_user: float = 1.15
@export_range(-1.5, 1.5, 0.05) var horizontal_offset: float = 0.0
@export_range(-1.0, 1.0, 0.05) var vertical_offset: float = 0.1
@export_range(0.0, 1.2, 0.05) var center_offset: float = 0.45
@export var room_anchor_registry_path: NodePath = ^"../RoomAnchorRegistry"
@export var standing_center_path: NodePath = ^"../XRRuntime/XROrigin3D"

@onready var _title_label: Label3D = $TitleLabel
@onready var _summary_label: Label3D = $SummaryLabel
@onready var _permission_label: Label3D = $PermissionLabel
@onready var _impact_preview: ApprovalImpactPreview = $ImpactPreview

var _camera: Camera3D = null
var _room_anchors: RoomAnchorRegistry = null
var _standing_center: Node3D = null
var _approval_id: String = ""


func _ready() -> void:
	var rig := get_node_or_null(user_rig_path) as UserRig
	if rig != null:
		_camera = rig.get_camera()
	_room_anchors = get_node_or_null(room_anchor_registry_path) as RoomAnchorRegistry
	_standing_center = get_node_or_null(standing_center_path) as Node3D
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
	# A fixed gate the user can walk to, parked near the centre of the play
	# boundary (not head-locked). It faces where the user was when it appeared.
	if _camera == null:
		return
	var camera_basis := _camera.global_transform.basis.orthonormalized()
	var user_position := _camera.global_position
	var center := user_position
	if _standing_center != null and _standing_center.is_inside_tree():
		center = _standing_center.global_position
	var forward := Vector3(-camera_basis.z.x, 0.0, -camera_basis.z.z)
	if forward.length() < 0.05:
		forward = Vector3.FORWARD
	forward = forward.normalized()
	var panel_position := center + forward * center_offset
	panel_position.x += horizontal_offset
	panel_position.y = user_position.y - 0.08 + vertical_offset
	if _room_anchors != null:
		_room_anchors.register_anchor("approval_surface", "approval_gate", Transform3D(camera_basis, panel_position))
	global_transform = Transform3D(camera_basis, panel_position)


func _on_approval_requested(_request: Dictionary) -> void:
	if not is_open():
		_show_next_approval()


func _on_approval_resolved(approval_id: String) -> void:
	if approval_id == _approval_id:
		_show_next_approval()


func get_impact_preview() -> ApprovalImpactPreview:
	return _impact_preview
