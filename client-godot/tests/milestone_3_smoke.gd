extends Node

var _failed := false


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	var main_scene := load("res://scenes/app/main.tscn") as PackedScene
	_check(main_scene != null, "main scene loads")
	var main := main_scene.instantiate()
	add_child(main)
	await get_tree().physics_frame

	var panel := main.get_node("ThreadPanel") as ThreadPanel
	var transport := main.get_node("BackendBridge/FakeBackendTransport") as FakeBackendTransport
	var manager := main.get_node("InteractionManager") as InteractionManager
	var rig := main.get_node("UserRig") as UserRig
	var source := (main.get_node("XRRuntime") as XRRuntime).get_hand_source()
	source.set_hand_tracking_active(true)
	var orb := (main.get_node("OrbManager") as OrbManager).get_orb("thread_demo")
	_check(panel != null and not panel.is_open(), "thread panel starts closed")
	_check(AppState.get_thread("thread_demo").messages.size() == 1, "fake thread has seeded history")

	# Point the tracked hand at the orb, then pinch to focus it.
	_aim_at(source, orb.global_position, false)
	manager._physics_process(0.0)
	_aim_at(source, orb.global_position, true)
	manager._physics_process(0.0)

	_check(not panel.is_open(), "selecting an orb does not open a floating transcript window")
	_check(AppState.focused_thread_id == "thread_demo", "selection focuses the agent for the palm panel")
	_check(transport.get_active_stream_count() == 1, "focus starts one fake transport stream")
	# The transcript surface remains available on demand (the palm panel is the
	# primary presentation), so its rendering stays covered here.
	panel.open_thread("thread_demo")
	_check(panel.get_displayed_thread_id() == "thread_demo", "panel displays the selected thread when opened")
	_check(panel.get_rendered_body_text().contains("Research Agent"), "panel renders the correct transcript")
	_check(panel.global_position.distance_to(rig.get_camera().global_position) < 2.0, "panel is positioned in a spatial reading zone")

	transport.advance_streams(0.5)
	var demo_thread := AppState.get_thread("thread_demo")
	var streaming_message: AgentMessage = demo_thread.messages.back()
	_check(streaming_message.is_streaming, "assistant message remains partial during streaming")
	_check(not streaming_message.content.is_empty(), "streaming appends incremental content")
	_check(panel.get_rendered_body_text().contains("▌"), "panel marks a partial response")

	AppState.focus_thread("thread_debug_02")
	_check(
		panel.get_displayed_thread_id() == "thread_demo",
		"an open transcript panel does not follow focus automatically"
	)
	panel.open_thread("thread_debug_02")
	_check(panel.get_displayed_thread_id() == "thread_debug_02", "opening the panel swaps its transcript")
	_check(panel.get_rendered_body_text().contains("Planning"), "second thread shows its own history")
	_check(transport.get_active_stream_count() == 2, "independent thread streams can coexist")

	transport.advance_streams(10.0)
	var planning_thread := AppState.get_thread("thread_debug_02")
	var completed_message: AgentMessage = planning_thread.messages.back()
	_check(not completed_message.is_streaming, "fake stream completes")
	_check(planning_thread.status == AgentThread.Status.COMPLETE, "completion updates thread status")
	_check(panel.get_rendered_body_text().contains("simulated update from Planning"), "completed response remains readable")
	_check(not panel.get_rendered_body_text().contains("▌"), "streaming cursor clears on completion")

	_check(
		source.submit_explicit_pinch_action(InteractionEvent.Type.DISMISS),
		"hand pinch emits a semantic dismiss action"
	)
	_check(AppState.focused_thread_id.is_empty(), "semantic dismiss clears focus")
	_check(not panel.is_open(), "semantic dismiss closes the panel")
	_check(AppState.get_thread("thread_debug_02") != null, "dismiss does not remove the thread")

	if not _failed:
		print("[TEST] Milestone 3 panel and streaming checks passed")
	main.queue_free()
	get_tree().quit(1 if _failed else 0)


func _aim_at(source: OpenXRInteractionSource, target: Vector3, pinching: bool) -> void:
	var origin := target + Vector3(0.0, 0.12, 0.9)
	var forward := (target - origin).normalized()
	var index_tip := origin
	var index_distal := origin - forward * 0.05
	var thumb_tip := index_tip + forward * (0.015 if pinching else 0.08)
	var palm := Transform3D(Basis.IDENTITY, origin + Vector3(0.0, -0.08, 0.05))
	source.submit_joint_sample("right", palm, thumb_tip, index_distal, index_tip)


func _check(condition: bool, description: String) -> void:
	if condition:
		return
	_failed = true
	push_error("[TEST] Failed: %s" % description)
