class_name PalmConsole
extends Node3D

@export var hand_source_path: NodePath = ^"../XRRuntime/OpenXRInteractionSource"
@export var user_rig_path: NodePath = ^"../UserRig"
@export_range(0.01, 0.3, 0.01) var palm_offset_metres: float = 0.11
@export_range(0.05, 1.0, 0.05) var pose_smoothing: float = 0.38
@export_range(0.3, 1.0, 0.01) var console_scale: float = 0.55
@export_range(0.15, 0.8, 0.01) var min_display_distance: float = 0.24
@export_range(0.3, 1.2, 0.01) var max_display_distance: float = 0.68
@export_range(0.0, 0.4, 0.01) var below_eye_minimum: float = 0.06
@export_range(0.0, 1.0, 0.05) var facing_threshold: float = 0.45
@export_range(0.0, 1.5, 0.05) var show_delay_seconds: float = 0.35

@onready var _status_label: Label3D = $StatusLabel
@onready var _provider_label: Label3D = $ProviderLabel
@onready var _summary_label: Label3D = $SummaryLabel

var _hand_source: OpenXRInteractionSource = null
var _user_rig: UserRig = null
var _dwell := 0.0


func _ready() -> void:
	_hand_source = get_node_or_null(hand_source_path) as OpenXRInteractionSource
	_user_rig = get_node_or_null(user_rig_path) as UserRig
	AppState.connection_state_changed.connect(_refresh_telemetry)
	AppState.provider_identity_changed.connect(_on_provider_identity_changed)
	AppState.listening_state_changed.connect(_refresh_telemetry)
	AppState.focused_thread_changed.connect(_on_focus_changed)
	AppState.thread_updated.connect(_on_thread_updated)
	AppState.orb_layout_changed.connect(_on_orb_layout_changed)
	scale = Vector3.ONE * console_scale
	visible = false
	_refresh_telemetry()
	_refresh_summary()


func _physics_process(delta: float) -> void:
	if (
		AppState.ui_mode not in ["xr_hands", "hand_lab"]
		or _hand_source == null
		or _user_rig == null
		or AppState.privacy_veil_active
	):
		_dwell = 0.0
		visible = false
		return
	var sample := _hand_source.get_latest_hand_sample("left")
	if sample.is_empty():
		_dwell = 0.0
		visible = false
		return
	var camera := _user_rig.get_camera()
	if camera == null:
		_dwell = 0.0
		visible = false
		return
	var camera_position := camera.global_position
	var palm_transform := sample.get("palm_transform", Transform3D.IDENTITY) as Transform3D
	var target_position := palm_transform.origin + Vector3.UP * palm_offset_metres
	var to_target := target_position - camera_position
	var distance_to_user := to_target.length()

	if AppState.ui_mode == "hand_lab":
		# The desktop simulator keeps the original always-near-the-palm behaviour.
		if distance_to_user < 0.12 or distance_to_user > 1.35:
			_dwell = 0.0
			visible = false
			return
		_dwell = show_delay_seconds
	else:
		var camera_forward := -camera.global_transform.basis.z.normalized()
		var in_front := to_target.normalized().dot(camera_forward) if distance_to_user > 0.001 else 0.0
		var below_eye := camera_position.y - target_position.y >= below_eye_minimum
		var conditions_met := (
			distance_to_user >= min_display_distance
			and distance_to_user <= max_display_distance
			and below_eye
			and in_front >= facing_threshold
		)
		if not conditions_met:
			_dwell = 0.0
			visible = false
			return
		_dwell += delta
		if _dwell < show_delay_seconds:
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


func _on_focus_changed(_thread_id: String) -> void:
	_refresh_summary()


func _on_thread_updated(_thread: AgentThread) -> void:
	_refresh_summary()


func _on_orb_layout_changed(_thread_id: String) -> void:
	_refresh_summary()


func _refresh_summary() -> void:
	if _summary_label == null:
		return
	var thread := AppState.get_thread(AppState.focused_thread_id)
	if thread == null:
		_summary_label.text = "NO AGENT FOCUSED\nTouch an orb and pinch to select"
		return
	var excerpt := ""
	for index in range(thread.messages.size() - 1, -1, -1):
		var message := thread.messages[index]
		if (
			message.role in [AgentMessage.Role.ASSISTANT, AgentMessage.Role.TOOL]
			and not message.content.strip_edges().is_empty()
		):
			excerpt = message.content.strip_edges().replace("\n", " ")
			break
	if excerpt.length() > 150:
		excerpt = excerpt.substr(0, 147) + "..."
	if excerpt.is_empty():
		excerpt = "No summary yet."
	var parent_id := AppState.get_orb_parent(thread.id)
	var combined := ""
	if not parent_id.is_empty():
		var parent_thread := AppState.get_thread(parent_id)
		combined = "\nlinked to %s" % (parent_thread.title if parent_thread != null else parent_id)
	_summary_label.text = "%s · %s%s\n%s" % [
		thread.title,
		AgentThread.status_label(thread.status),
		combined,
		excerpt,
	]
