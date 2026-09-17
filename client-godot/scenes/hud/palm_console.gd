class_name PalmConsole
extends Node3D

@export var hand_source_path: NodePath = ^"../XRRuntime/OpenXRInteractionSource"
@export var user_rig_path: NodePath = ^"../UserRig"
@export_range(0.01, 0.3, 0.01) var palm_offset_metres: float = 0.12
@export_range(0.05, 1.0, 0.05) var pose_smoothing: float = 0.38

@onready var _status_label: Label3D = $StatusLabel
@onready var _provider_label: Label3D = $ProviderLabel

var _hand_source: OpenXRInteractionSource = null
var _user_rig: UserRig = null


func _ready() -> void:
	_hand_source = get_node_or_null(hand_source_path) as OpenXRInteractionSource
	_user_rig = get_node_or_null(user_rig_path) as UserRig
	AppState.connection_state_changed.connect(_refresh_telemetry)
	AppState.provider_identity_changed.connect(_on_provider_identity_changed)
	AppState.listening_state_changed.connect(_refresh_telemetry)
	visible = false
	_refresh_telemetry()


func _physics_process(_delta: float) -> void:
	if AppState.ui_mode not in ["xr_hands", "hand_lab"] or _hand_source == null or _user_rig == null:
		visible = false
		return
	var sample := _hand_source.get_latest_hand_sample("left")
	if sample.is_empty():
		visible = false
		return
	var palm_transform := sample.get("palm_transform", Transform3D.IDENTITY) as Transform3D
	var camera_position := _user_rig.get_camera().global_position
	var target_position := palm_transform.origin + Vector3.UP * palm_offset_metres
	var distance_to_user := target_position.distance_to(camera_position)
	if distance_to_user < 0.12 or distance_to_user > 1.35:
		visible = false
		return

	if not visible:
		global_position = target_position
	else:
		global_position = global_position.lerp(target_position, pose_smoothing)
	look_at(camera_position, Vector3.UP, true)
	visible = true


func _refresh_telemetry(_unused: Variant = null) -> void:
	var link := AppState.connection_state.to_upper()
	var speech := "MIC %s" % AppState.listening_state.to_upper()
	_status_label.text = "LINK %s  //  %s" % [link, speech]
	_provider_label.text = "%s  //  %s" % [
		AppState.provider_name.to_upper(),
		AppState.model_name.to_upper(),
	]


func _on_provider_identity_changed(_provider: String, _model: String) -> void:
	_refresh_telemetry()
