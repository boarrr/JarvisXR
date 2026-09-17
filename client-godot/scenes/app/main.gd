extends Node

@onready var _user_rig: UserRig = $UserRig
@onready var _xr_runtime: XRRuntime = $XRRuntime
@onready var _interaction_manager: InteractionManager = $InteractionManager
@onready var _backend_bridge: BackendBridge = $BackendBridge
@onready var _fake_backend_transport: FakeBackendTransport = $BackendBridge/FakeBackendTransport
@onready var _websocket_backend_client: BackendClient = $BackendBridge/WebSocketBackendClient
@onready var _command_router: CommandRouter = $CommandRouter
@onready var _speech_service: LocalWhisperSpeechService = $LocalWhisperSpeechService
@onready var _code_viewer: CodeViewer = $CodeViewer
@onready var _cognition_layer: CognitionLayer = $CognitionLayer
@onready var _mission_topology: MissionTopology = $MissionTopology
@onready var _quick_intent_panel: QuickIntentPanel = $QuickIntentPanel
@onready var _thread_panel: ThreadPanel = $ThreadPanel
@onready var _desktop_composer: DesktopComposer = $DesktopComposer
@onready var _pointer_hud: CanvasLayer = $PointerHUD
@onready var _privacy_veil: PrivacyVeil = $PrivacyVeil

var _approval_mode_active := false
var _restore_code_viewer := false
var _restore_thread_panel := false
var _restore_quick_intent_panel := false
var _restore_quick_after_privacy := false
var _restore_composer_after_privacy := false


func _ready() -> void:
	if ServiceRegistry.input_router == null:
		push_error("[APP] InputRouter is not available from ServiceRegistry")
		return

	var interaction_source: InteractionSource = _user_rig.get_interaction_source()
	var xr_active := _xr_runtime.activate_if_available()
	if not xr_active:
		# XRCamera3D can claim the viewport while the scene enters the tree,
		# even without a running XR session. Restore the camera we raycast from.
		_user_rig.set_xr_tracking_active(false)
	var lab_active := not xr_active and (
		"--hand-lab" in OS.get_cmdline_user_args()
		or (DisplayServer.get_name() != "headless" and bool(ProjectSettings.get_setting("spatial_agent/desktop_hand_lab", true)))
	) and "--classic-desktop" not in OS.get_cmdline_user_args()
	if xr_active:
		interaction_source = _xr_runtime.get_hand_source()
	elif lab_active:
		interaction_source = ($HandLab as HandLab).start(self)
	if not ServiceRegistry.input_router.register_source(interaction_source):
		push_error("[APP] Failed to register the interaction source")
		return
	if not _interaction_manager.set_interaction_source(interaction_source):
		push_error("[APP] Failed to connect InteractionManager to the interaction source")
		return
	_interaction_manager.interaction_event.connect(_on_interaction_event)
	_speech_service.listening_changed.connect(_on_speech_state_changed)
	_speech_service.partial_transcript.connect(_on_partial_transcript)
	_speech_service.final_transcript.connect(_on_final_transcript)
	_speech_service.failed.connect(_on_speech_failed)
	AppState.approval_requested.connect(_on_approval_requested)
	AppState.approval_resolved.connect(_on_approval_resolved)
	AppState.listening_state = _speech_service.get_state()

	AppState.ui_mode = "xr_hands" if xr_active else ("hand_lab" if lab_active else "desktop")
	_pointer_hud.visible = not xr_active and not lab_active
	$DevelopmentFloor.visible = not xr_active
	$HolographicGrid.visible = not xr_active
	_desktop_composer.visible = false if xr_active else _desktop_composer.visible
	if not _configure_backend_transport():
		return
	if not _backend_bridge.start():
		push_error("[APP] Failed to start the configured backend transport")
		return

	EventBus.interaction_source_changed.emit(interaction_source.source_name)
	EventBus.app_ready.emit()

	var ready_message := "Spatial Agent client ready — mode=%s backend=%s/%s" % [
		AppState.ui_mode,
		AppState.backend_mode,
		AppState.connection_state,
	]
	print("[APP] %s" % ready_message)
	EventBus.debug_message.emit(ready_message)


func _configure_backend_transport() -> bool:
	var configured_mode := str(ProjectSettings.get_setting("spatial_agent/backend_mode", "fake")).to_lower()
	var transport: BackendTransport = _fake_backend_transport
	match configured_mode:
		"websocket":
			_websocket_backend_client.websocket_url = str(ProjectSettings.get_setting(
				"spatial_agent/backend_websocket_url",
				"ws://127.0.0.1:8787/ws"
			))
			transport = _websocket_backend_client
		"fake":
			transport = _fake_backend_transport
		_:
			push_warning("[APP] Unknown backend mode '%s'; using fake transport" % configured_mode)
			transport = _fake_backend_transport
	if not _backend_bridge.bind_transport(transport):
		push_error("[APP] Failed to configure backend transport")
		return false
	return true


func _on_interaction_event(event: InteractionEvent) -> void:
	match event.type:
		InteractionEvent.Type.HOVER_ENTER:
			AppState.hovered_target_id = event.target_id
			EventBus.debug_message.emit("Hover: %s" % event.target_id)
		InteractionEvent.Type.HOVER_EXIT:
			if AppState.hovered_target_id == event.target_id:
				AppState.hovered_target_id = ""
		InteractionEvent.Type.SELECT:
			if (
				_approval_mode_active
				and not event.target_id.begins_with("approval:")
				and event.target_id != "palm:privacy_toggle"
			):
				EventBus.debug_message.emit("Resolve the approval gate before continuing")
			elif AppState.privacy_veil_active and event.target_id != "palm:privacy_toggle":
				EventBus.debug_message.emit("Privacy veil active")
			elif event.target_id == "approval:approve":
				_respond_to_next_approval("approve")
			elif event.target_id == "approval:deny":
				_respond_to_next_approval("deny")
			elif event.target_id == "approval:modal":
				EventBus.debug_message.emit("Approval decision required")
			elif event.target_id == "ui:code_toggle":
				_code_viewer.toggle()
			elif event.target_id == "ui:transcript_previous":
				_thread_panel.turn_page(-1)
			elif event.target_id == "ui:transcript_next":
				_thread_panel.turn_page(1)
			elif event.target_id == "ui:dismiss":
				AppState.focus_thread("")
			elif event.target_id == "ui:code_surface":
				EventBus.debug_message.emit("Pinch-drag the code surface to scroll")
			elif event.target_id == "cognition:previous":
				_cognition_layer.select_previous_event()
			elif event.target_id == "cognition:next":
				_cognition_layer.select_next_event()
			elif event.target_id == "cognition:mode":
				_cognition_layer.toggle_live_mode()
			elif event.target_id == "palm:focus_next":
				_focus_next_thread()
			elif event.target_id == "palm:code_toggle":
				_code_viewer.toggle()
			elif event.target_id == "palm:cognition_toggle":
				_cognition_layer.toggle_enabled()
			elif event.target_id == "palm:mission_toggle":
				_mission_topology.toggle_enabled()
			elif event.target_id == "palm:privacy_toggle":
				_toggle_privacy_veil()
			elif event.target_id == "palm:voice_toggle":
				if _speech_service.is_available():
					_toggle_voice_input()
				else:
					_quick_intent_panel.toggle()
			elif event.target_id == "palm:dismiss":
				_quick_intent_panel.close()
				AppState.focus_thread("")
			elif event.target_id.begins_with("quick:"):
				_submit_quick_intent(event.target_id)
			elif AppState.focus_thread(event.target_id):
				EventBus.debug_message.emit("Focused: %s" % event.target_id)
		InteractionEvent.Type.FOCUS:
			_focus_next_thread()
		InteractionEvent.Type.DISMISS:
			if not AppState.focused_thread_id.is_empty():
				AppState.focus_thread("")
				EventBus.debug_message.emit("Thread panel dismissed")
		InteractionEvent.Type.APPROVE:
			_respond_to_next_approval("approve")
		InteractionEvent.Type.DENY:
			_respond_to_next_approval("deny")
		InteractionEvent.Type.VOICE_BEGIN:
			_begin_voice_input()
		InteractionEvent.Type.VOICE_END:
			_speech_service.stop_listening()
		InteractionEvent.Type.CODE_TOGGLE:
			if not _code_viewer.toggle():
				EventBus.debug_message.emit("Code trace closed or no thread is focused")
		InteractionEvent.Type.CODE_SCROLL_UP:
			_code_viewer.scroll_lines(-_code_viewer.scroll_step_lines)
		InteractionEvent.Type.CODE_SCROLL_DOWN:
			_code_viewer.scroll_lines(_code_viewer.scroll_step_lines)
		InteractionEvent.Type.CODE_GO_TOP:
			_code_viewer.go_top()
		InteractionEvent.Type.CODE_GO_BOTTOM:
			_code_viewer.go_bottom()
		InteractionEvent.Type.GRAB_BEGIN:
			if event.target_id == "ui:code_surface" and event.world_position is Vector3:
				_code_viewer.begin_bimanual_transform(event.world_position)
		InteractionEvent.Type.GRAB_MOVE:
			if event.target_id == "ui:code_surface" and event.world_position is Vector3:
				_code_viewer.apply_bimanual_transform(
					event.world_position,
					float(event.gesture_data.get("scale_factor", 1.0)),
					float(event.gesture_data.get("rotation_radians", 0.0))
				)
		InteractionEvent.Type.GRAB_END:
			if event.target_id == "ui:code_surface":
				_code_viewer.end_bimanual_transform()


func _focus_next_thread() -> void:
	if AppState.ordered_thread_ids.is_empty():
		return
	var current_index := AppState.ordered_thread_ids.find(AppState.focused_thread_id)
	var next_index := (current_index + 1) % AppState.ordered_thread_ids.size()
	AppState.focus_thread(AppState.ordered_thread_ids[next_index])


func _respond_to_next_approval(decision: String) -> bool:
	var request := AppState.get_next_approval()
	if request.is_empty():
		return false
	var approval_id := str(request.get("approval_id", ""))
	var thread_id := str(request.get("thread_id", ""))
	var accepted := _backend_bridge.send_command(
		"approval.respond",
		{"approval_id": approval_id, "decision": decision},
		thread_id
	)
	if accepted:
		EventBus.debug_message.emit("Approval %s: %s" % [decision, approval_id])
	return accepted


func _toggle_privacy_veil() -> bool:
	var next_value := not AppState.privacy_veil_active
	if next_value and AppState.listening_state == SpeechService.STATE_LISTENING:
		_speech_service.stop_listening()
	if next_value:
		_restore_quick_after_privacy = _quick_intent_panel.visible
		_restore_composer_after_privacy = _desktop_composer.visible
	AppState.privacy_veil_active = next_value
	_quick_intent_panel.visible = (
		false
		if next_value
		else _restore_quick_after_privacy and not _approval_mode_active
	)
	_desktop_composer.visible = (
		false
		if next_value
		else _restore_composer_after_privacy and not _approval_mode_active
	)
	_cognition_layer.set_blocked(next_value or _approval_mode_active)
	_mission_topology.set_blocked(next_value or _approval_mode_active)
	EventBus.debug_message.emit("Privacy veil %s" % ("active" if next_value else "cleared"))
	if not next_value:
		_restore_quick_after_privacy = false
		_restore_composer_after_privacy = false
	return next_value


func _begin_voice_input() -> void:
	if AppState.focused_thread_id.is_empty():
		EventBus.debug_message.emit("Focus a thread before using push-to-talk")
		return
	AppState.current_transcript = ""
	_speech_service.start_listening()


func _toggle_voice_input() -> void:
	if AppState.listening_state == SpeechService.STATE_LISTENING:
		_speech_service.stop_listening()
	else:
		_begin_voice_input()


func _submit_quick_intent(target_id: String) -> bool:
	var prompt := _quick_intent_panel.get_prompt(target_id)
	if prompt.is_empty() or AppState.focused_thread_id.is_empty():
		return false
	var accepted := _backend_bridge.send_command(
		"message.send",
		{"content": prompt},
		AppState.focused_thread_id
	)
	if accepted:
		_quick_intent_panel.close()
		if AppState.ui_mode == "hand_lab":
			($HandLab as HandLab)._checks.ask = true
		EventBus.debug_message.emit("Quick intent sent: %s" % target_id.trim_prefix("quick:"))
	return accepted


func _on_speech_state_changed(state: String) -> void:
	AppState.listening_state = state
	EventBus.debug_message.emit("Speech: %s" % state)


func _on_partial_transcript(transcript: String) -> void:
	AppState.current_transcript = transcript


func _on_final_transcript(transcript: String) -> void:
	AppState.current_transcript = transcript
	if not _command_router.submit_text(transcript, true):
		EventBus.debug_message.emit("Voice transcript could not be routed")


func _on_speech_failed(_code: String, message: String) -> void:
	EventBus.debug_message.emit("Speech unavailable: %s" % message)


func _on_approval_requested(_request: Dictionary) -> void:
	if _approval_mode_active:
		return
	_approval_mode_active = true
	_restore_code_viewer = _code_viewer.visible
	_restore_thread_panel = _thread_panel.visible
	_restore_quick_intent_panel = _quick_intent_panel.visible
	_code_viewer.visible = false
	_thread_panel.visible = false
	_quick_intent_panel.visible = false
	_cognition_layer.set_blocked(true)
	_mission_topology.set_blocked(true)
	_desktop_composer.visible = false


func _on_approval_resolved(_approval_id: String) -> void:
	if not _approval_mode_active or not AppState.approval_requests.is_empty():
		return
	_approval_mode_active = false
	if AppState.privacy_veil_active:
		_code_viewer.visible = false
		_thread_panel.visible = false
		_quick_intent_panel.visible = false
		_cognition_layer.set_blocked(true)
		_mission_topology.set_blocked(true)
		_desktop_composer.visible = false
		return
	_code_viewer.visible = _restore_code_viewer
	_thread_panel.visible = _restore_thread_panel
	_quick_intent_panel.visible = _restore_quick_intent_panel
	_cognition_layer.set_blocked(false)
	_mission_topology.set_blocked(false)
	_desktop_composer.visible = AppState.ui_mode == "desktop"
	_restore_code_viewer = false
	_restore_thread_panel = false
	_restore_quick_intent_panel = false
