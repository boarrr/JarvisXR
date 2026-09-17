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
	var source := rig.get_interaction_source()
	_check(panel != null and not panel.is_open(), "thread panel starts closed")
	_check(AppState.get_thread("thread_demo").messages.size() == 1, "fake thread has seeded history")

	source._process(0.0)
	manager._physics_process(0.0)
	Input.action_press("pointer_select")
	source._process(0.0)
	manager._physics_process(0.0)
	Input.action_release("pointer_select")
	source._process(0.0)
	manager._physics_process(0.0)

	_check(panel.is_open(), "selecting an orb opens the panel")
	_check(panel.get_displayed_thread_id() == "thread_demo", "panel displays the selected thread")
	_check(panel.get_rendered_body_text().contains("Research Agent"), "panel renders the correct transcript")
	_check(transport.get_active_stream_count() == 1, "focus starts one fake transport stream")
	_check(panel.global_position.distance_to(rig.get_camera().global_position) < 2.0, "panel is positioned in a spatial reading zone")

	transport.advance_streams(0.5)
	var demo_thread := AppState.get_thread("thread_demo")
	var streaming_message: AgentMessage = demo_thread.messages.back()
	_check(streaming_message.is_streaming, "assistant message remains partial during streaming")
	_check(not streaming_message.content.is_empty(), "streaming appends incremental content")
	_check(panel.get_rendered_body_text().contains("▌"), "panel marks a partial response")

	AppState.focus_thread("thread_debug_02")
	_check(panel.get_displayed_thread_id() == "thread_debug_02", "changing focus swaps panel transcript")
	_check(panel.get_rendered_body_text().contains("Planning"), "second thread shows its own history")
	_check(transport.get_active_stream_count() == 2, "independent thread streams can coexist")

	transport.advance_streams(10.0)
	var planning_thread := AppState.get_thread("thread_debug_02")
	var completed_message: AgentMessage = planning_thread.messages.back()
	_check(not completed_message.is_streaming, "fake stream completes")
	_check(planning_thread.status == AgentThread.Status.COMPLETE, "completion updates thread status")
	_check(panel.get_rendered_body_text().contains("simulated update from Planning"), "completed response remains readable")
	_check(not panel.get_rendered_body_text().contains("▌"), "streaming cursor clears on completion")

	var dismiss_event := InputEventAction.new()
	dismiss_event.action = "pointer_secondary"
	dismiss_event.pressed = true
	source._input(dismiss_event)
	_check(AppState.focused_thread_id.is_empty(), "semantic dismiss clears focus")
	_check(not panel.is_open(), "semantic dismiss closes the panel")
	_check(AppState.get_thread("thread_debug_02") != null, "dismiss does not remove the thread")

	if not _failed:
		print("[TEST] Milestone 3 panel and streaming checks passed")
	main.queue_free()
	get_tree().quit(1 if _failed else 0)


func _check(condition: bool, description: String) -> void:
	if condition:
		return
	_failed = true
	push_error("[TEST] Failed: %s" % description)
