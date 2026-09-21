extends Node

@onready var _user_rig: UserRig = $UserRig
@onready var _xr_runtime: XRRuntime = $XRRuntime
@onready var _interaction_manager: InteractionManager = $InteractionManager
@onready var _backend_bridge: BackendBridge = $BackendBridge
@onready var _fake_backend_transport: FakeBackendTransport = $BackendBridge/FakeBackendTransport
@onready var _websocket_backend_client: BackendClient = $BackendBridge/WebSocketBackendClient
@onready var _command_router: CommandRouter = $CommandRouter
@onready var _desktop_speech_service: LocalWhisperSpeechService = $LocalWhisperSpeechService
var _speech_service: SpeechService = null
@onready var _code_viewer: CodeViewer = $CodeViewer
@onready var _cognition_layer: CognitionLayer = $CognitionLayer
@onready var _mission_topology: MissionTopology = $MissionTopology
@onready var _quick_intent_panel: QuickIntentPanel = $QuickIntentPanel
@onready var _thread_panel: ThreadPanel = $ThreadPanel
@onready var _desktop_composer: DesktopComposer = $DesktopComposer
@onready var _pointer_hud: CanvasLayer = $PointerHUD
@onready var _privacy_veil: PrivacyVeil = $PrivacyVeil
@onready var _orb_manager: OrbManager = $OrbManager
@onready var _palm_console: PalmConsole = $PalmConsole
@onready var _workspace_panel: WorkspacePanel = $WorkspacePanel
@onready var _diff_review_panel: DiffReviewPanel = $DiffReviewPanel
@onready var _file_viewer: FileViewer = $FileViewer
@onready var _daemon_settings_panel: DaemonSettingsPanel = $DaemonSettingsPanel

var _approval_mode_active := false
var _restore_code_viewer := false
var _restore_thread_panel := false
var _restore_quick_intent_panel := false
var _restore_quick_after_privacy := false
var _restore_composer_after_privacy := false
var _pending_spawn_position: Variant = null
var _pending_restore_offsets: Dictionary = {}
var _pending_bind_thread := false


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
	_speech_service = _select_speech_service()
	if _speech_service == null:
		push_error("[APP] No speech service adapter is available")
		return
	_speech_service.listening_changed.connect(_on_speech_state_changed)
	_speech_service.partial_transcript.connect(_on_partial_transcript)
	_speech_service.final_transcript.connect(_on_final_transcript)
	_speech_service.failed.connect(_on_speech_failed)
	AppState.approval_requested.connect(_on_approval_requested)
	AppState.approval_resolved.connect(_on_approval_resolved)
	EventBus.cockpit_panel_requested.connect(_on_cockpit_panel_requested)
	EventBus.debug_message.connect(_on_debug_message)
	AppState.thread_added.connect(_on_thread_added_for_layout)
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

	var ready_message := "Spatial Agent client ready — mode=%s backend=%s/%s url=%s" % [
		AppState.ui_mode,
		AppState.backend_mode,
		AppState.connection_state,
		_websocket_backend_client.websocket_url if AppState.backend_mode == "websocket" else "n/a",
	]
	print("[APP] %s" % ready_message)
	EventBus.debug_message.emit(ready_message)


func _configure_backend_transport() -> bool:
	var configured_mode := str(ProjectSettings.get_setting("spatial_agent/backend_mode", "fake")).to_lower()
	# A standalone headset must talk to a daemon: the Android feature-tag
	# override in project.godot is unreliable, so select it from the platform.
	# Desktop keeps the offline fake transport for simulator work.
	if OS.get_name() == "Android" and configured_mode == "fake":
		configured_mode = "websocket"
	var transport: BackendTransport = _fake_backend_transport
	match configured_mode:
		"websocket":
			_websocket_backend_client.set_default_url(str(ProjectSettings.get_setting(
				"spatial_agent/backend_websocket_url",
				"ws://127.0.0.1:8787/ws"
			)))
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
			elif event.target_id == "palm:new_agent":
				_create_agent_at(_spawn_position_in_front())
			elif event.target_id == "palm:undo":
				_undo_last_agent()
			elif event.target_id == "palm:cognition_toggle":
				_cognition_layer.toggle_enabled()
			elif event.target_id == "palm:mission_toggle":
				_mission_topology.toggle_enabled()
			elif event.target_id == "palm:cockpit_toggle":
				_toggle_cockpit_review()
			elif event.target_id == "diff:apply":
				_diff_review_panel.decide("apply")
			elif event.target_id == "diff:reject":
				_diff_review_panel.decide("reject")
			elif event.target_id == "file:up":
				_file_viewer.navigate_up()
			elif event.target_id == "file:refresh":
				_file_viewer.refresh_listing()
			elif event.target_id == "file:back":
				_file_viewer.go_back()
			elif event.target_id.begins_with("file:dir:"):
				_file_viewer.activate_entry(event.target_id.trim_prefix("file:dir:"), true)
			elif event.target_id.begins_with("file:file:"):
				_file_viewer.activate_entry(event.target_id.trim_prefix("file:file:"), false)
			elif event.target_id.begins_with("daemon:"):
				_daemon_settings_panel.handle_action(event.target_id)
			elif event.target_id.begins_with("palm_screen:"):
				_palm_console.handle_screen_action(event.target_id)
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
			if event.target_id == "ui:summon" and event.world_position is Vector3:
				_orb_manager.show_summon(event.world_position)
			elif event.target_id == "ui:code_surface" and event.world_position is Vector3:
				_code_viewer.begin_bimanual_transform(event.world_position)
			elif AppState.get_thread(event.target_id) != null:
				_orb_manager.begin_grab(event.target_id)
		InteractionEvent.Type.GRAB_MOVE:
			if event.target_id == "ui:summon" and event.world_position is Vector3:
				_orb_manager.move_summon(event.world_position)
			elif event.target_id == "ui:code_surface" and event.world_position is Vector3:
				_code_viewer.apply_bimanual_transform(
					event.world_position,
					float(event.gesture_data.get("scale_factor", 1.0)),
					float(event.gesture_data.get("rotation_radians", 0.0))
				)
			elif AppState.get_thread(event.target_id) != null and event.world_position is Vector3:
				_orb_manager.update_grab(event.target_id, event.world_position)
		InteractionEvent.Type.GRAB_END:
			if event.target_id == "ui:summon":
				_orb_manager.hide_summon()
				if (
					not bool(event.gesture_data.get("cancelled", true))
					and event.world_position is Vector3
				):
					_create_agent_at(event.world_position)
			elif event.target_id == "ui:code_surface":
				_code_viewer.end_bimanual_transform()
			elif AppState.get_thread(event.target_id) != null:
				var grab_result := _orb_manager.end_grab(event.target_id)
				var linked_to := str(grab_result.get("linked_to", ""))
				if not linked_to.is_empty():
					# Combining two agents starts a new agent with both contexts.
					_backend_bridge.send_command(
						"thread.combine",
						{"thread_ids": [event.target_id, linked_to]}
					)
					var parent_thread := AppState.get_thread(linked_to)
					EventBus.debug_message.emit(
						"Combining with %s" % (parent_thread.title if parent_thread != null else linked_to)
					)
		InteractionEvent.Type.CRUSH:
			_crush_agent(event.target_id)
		InteractionEvent.Type.ATTRACT_BEGIN:
			_orb_manager.attract_begin(event.target_id)
		InteractionEvent.Type.ATTRACT_MOVE:
			if event.world_position is Vector3:
				_orb_manager.attract_to(event.target_id, event.world_position)
		InteractionEvent.Type.ATTRACT_END:
			_orb_manager.attract_end(event.target_id)


func _focus_next_thread() -> void:
	if AppState.ordered_thread_ids.is_empty():
		return
	var current_index := AppState.ordered_thread_ids.find(AppState.focused_thread_id)
	var next_index := (current_index + 1) % AppState.ordered_thread_ids.size()
	AppState.focus_thread(AppState.ordered_thread_ids[next_index])


func _select_speech_service() -> SpeechService:
	if OS.get_name() == "Android" and Engine.has_singleton(AndroidSpeechService.SINGLETON_NAME):
		var android_speech := AndroidSpeechService.new()
		android_speech.name = "AndroidSpeechService"
		add_child(android_speech)
		return android_speech
	return _desktop_speech_service


func _toggle_cockpit_review() -> void:
	if _diff_review_panel.visible:
		_diff_review_panel.close()
		return
	if _file_viewer.visible:
		_file_viewer.close()
		return
	var focused_thread_id := AppState.focused_thread_id
	if not focused_thread_id.is_empty() and not AppState.get_latest_diff_for_thread(focused_thread_id).is_empty():
		_diff_review_panel.open_focused_thread()
		return
	_file_viewer.open_focused_thread()


func _create_agent_at(position: Vector3) -> void:
	_pending_spawn_position = position
	_pending_bind_thread = AppState.workspaces.size() == 1
	if not _backend_bridge.send_command("thread.create", {"title": "New agent"}):
		_pending_spawn_position = null
		_pending_bind_thread = false
		EventBus.debug_message.emit("Could not create an agent")


func _crush_agent(thread_id: String) -> void:
	var thread := AppState.get_thread(thread_id)
	if thread == null:
		return
	AppState.push_undo(thread_id, thread.title, AppState.get_orb_offset(thread_id))
	_orb_manager.remove_orb(thread_id)
	_backend_bridge.send_command("thread.archive", {}, thread_id)
	EventBus.debug_message.emit("Crushed %s · undo available" % thread.title)


func _undo_last_agent() -> void:
	var entry := AppState.pop_undo()
	if entry.is_empty():
		EventBus.debug_message.emit("Nothing to undo")
		return
	var thread_id := str(entry.get("thread_id", ""))
	if thread_id.is_empty():
		return
	var position: Variant = entry.get("position")
	if position is Vector3:
		_pending_restore_offsets[thread_id] = position
	_backend_bridge.send_command("thread.restore", {}, thread_id)
	EventBus.debug_message.emit("Restoring %s" % str(entry.get("title", "agent")))


func _spawn_position_in_front() -> Vector3:
	var camera := _user_rig.get_camera() if _user_rig != null else null
	if camera == null:
		return _orb_manager._get_layout_origin() + Vector3(0.0, 0.0, -1.2)
	var forward := -camera.global_transform.basis.z
	forward.y = 0.0
	if forward.length_squared() < 0.0001:
		forward = Vector3.FORWARD
	return camera.global_position + forward.normalized() * 1.2 + Vector3(0.0, -0.1, 0.0)


func _on_thread_added_for_layout(thread: AgentThread) -> void:
	if thread == null:
		return
	if _pending_spawn_position is Vector3:
		AppState.set_orb_offset(thread.id, _pending_spawn_position)
		_pending_spawn_position = null
	elif _pending_restore_offsets.has(thread.id):
		AppState.set_orb_offset(thread.id, _pending_restore_offsets[thread.id])
		_pending_restore_offsets.erase(thread.id)
	if _pending_bind_thread and AppState.workspaces.size() == 1:
		_backend_bridge.send_command(
			"workspace.bind",
			{"workspace_id": str(AppState.workspaces[0].get("id", ""))},
			thread.id
		)
	_pending_bind_thread = false


func _on_debug_message(message: String) -> void:
	# A daemon that requires pairing answers its first hello with an auth error;
	# surface the keypad immediately so the headset can recover hands-only.
	if message.contains("Pair this device") or message.contains("auth_required"):
		_daemon_settings_panel.open_pairing()


func _on_cockpit_panel_requested(panel: String) -> void:	match panel:
		"workspace":
			_workspace_panel.toggle()
		"diff":
			if _diff_review_panel.visible:
				_diff_review_panel.close()
			else:
				_diff_review_panel.open_focused_thread()
		"files":
			if _file_viewer.visible:
				_file_viewer.close()
			else:
				_file_viewer.open_focused_thread()
		"daemon":
			_daemon_settings_panel.toggle()


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
	_workspace_panel.visible = false
	_diff_review_panel.visible = false
	_file_viewer.visible = false
	_daemon_settings_panel.visible = false
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
