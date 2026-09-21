class_name DebugOverlay
extends CanvasLayer

@export_range(0.05, 1.0, 0.05) var refresh_interval: float = 0.1
@export var user_rig_path: NodePath = ^"../UserRig"
@export var backend_bridge_path: NodePath = ^"../BackendBridge"

@onready var _metrics_label: Label = $Panel/Margin/VBox/Metrics
@onready var _last_message_label: Label = $Panel/Margin/VBox/LastMessage

var _user_rig: UserRig = null
var _backend_bridge: BackendBridge = null
var _refresh_elapsed: float = 0.0


func _ready() -> void:
	_user_rig = get_node_or_null(user_rig_path) as UserRig
	_backend_bridge = get_node_or_null(backend_bridge_path) as BackendBridge
	EventBus.debug_message.connect(_on_debug_message)
	_refresh_metrics()


func _process(delta: float) -> void:
	if not visible:
		return
	_refresh_elapsed += delta
	if _refresh_elapsed < refresh_interval:
		return
	_refresh_elapsed = 0.0
	_refresh_metrics()


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("debug_toggle"):
		visible = not visible
		get_viewport().set_input_as_handled()


func _refresh_metrics() -> void:
	var source_name := "none"
	if ServiceRegistry.input_router != null:
		source_name = ServiceRegistry.input_router.get_active_source_name()

	var user_position := Vector3.ZERO
	var yaw_degrees := 0.0
	var pitch_degrees := 0.0
	if _user_rig != null:
		user_position = _user_rig.global_position
		yaw_degrees = _user_rig.get_yaw_degrees()
		pitch_degrees = _user_rig.get_pitch_degrees()

	var focused := AppState.focused_thread_id if not AppState.focused_thread_id.is_empty() else "none"
	var hovered := AppState.hovered_target_id if not AppState.hovered_target_id.is_empty() else "none"
	var mouse_captured := "yes" if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED else "no"
	var protocol_event := _backend_bridge.get_last_event_type() if _backend_bridge != null else "none"
	if protocol_event.is_empty():
		protocol_event = "none"
	var transcript := AppState.current_transcript
	if transcript.length() > 64:
		transcript = transcript.left(61) + "..."
	if transcript.is_empty():
		transcript = "none"

	_metrics_label.text = (
		"FPS: %d\nMode: %s\nInteraction: %s\nBackend: %s/%s\nThreads: %d\n"
		+ "Position: %.2f, %.2f, %.2f\nYaw/Pitch: %.1f / %.1f deg\n"
		+ "Mouse captured: %s\nFocused thread: %s\nHovered target: %s\nListening: %s\n"
		+ "Transcript: %s\nApprovals: %d\nProtocol event: %s\n"
		+ "Keys: Enter message | C code | J/K scroll | V speak\nDebug: 1 add | 2 remove | 3 status"
	) % [
		Engine.get_frames_per_second(),
		AppState.ui_mode.capitalize(),
		source_name.capitalize(),
		AppState.backend_mode,
		AppState.connection_state,
		AppState.ordered_thread_ids.size(),
		user_position.x,
		user_position.y,
		user_position.z,
		yaw_degrees,
		pitch_degrees,
		mouse_captured,
		focused,
		hovered,
		AppState.listening_state,
		transcript,
		AppState.approval_requests.size(),
		protocol_event,
	]
	var probe := get_node_or_null("../PerfProbe") as PerfProbe
	if probe != null:
		_metrics_label.text += "\n%s" % probe.get_summary_line()
	var source := get_node_or_null("../XRRuntime/OpenXRInteractionSource") as OpenXRInteractionSource
	if source != null and source.is_available():
		_metrics_label.text += "\nHands: %s | tracked=%s | pinch=%s | touch=%s" % [
			source.get_active_hand_name() if not source.get_active_hand_name().is_empty() else "none",
			source.has_tracking_data(),
			source.get_pointer_state().is_selecting if source.get_pointer_state() != null else false,
			AppState.hovered_target_id if not AppState.hovered_target_id.is_empty() else "none",
		]


func _on_debug_message(message: String) -> void:
	_last_message_label.text = "Last event: %s" % message
