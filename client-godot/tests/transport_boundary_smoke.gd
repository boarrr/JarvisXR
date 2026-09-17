extends Node

var _failed := false


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	var main_scene := load("res://scenes/app/main.tscn") as PackedScene
	_check(main_scene != null, "main scene loads")
	var main := main_scene.instantiate()
	add_child(main)

	var bridge := main.get_node("BackendBridge") as BackendBridge
	var transport := main.get_node("BackendBridge/FakeBackendTransport") as FakeBackendTransport
	var debug_controller := main.get_node("DebugThreadController") as DebugThreadController
	_check(bridge != null, "BackendBridge exists")
	_check(transport != null, "FakeBackendTransport exists")
	_check(ServiceRegistry.backend_transport == transport, "transport is registered as a replaceable service")
	_check(AppState.backend_mode == "fake", "fake mode is reported through AppState")
	_check(AppState.connection_state == BackendTransport.STATE_CONNECTED, "fake transport reaches connected state")
	_check(not AppState.session_id.is_empty(), "session.ready establishes a session ID")
	_check(AppState.ordered_thread_ids.size() == 8, "thread.snapshot populates authoritative state")

	var created := debug_controller.create_fake_thread()
	_check(created != null and created.id == "thread_debug_09", "thread.create flows through the transport")
	_check(AppState.ordered_thread_ids.size() == 9, "thread.created is reduced into AppState")

	_check(
		bridge.send_command("message.send", {"content": "Exercise the transport boundary."}, created.id),
		"message.send is accepted"
	)
	_check(created.status == AgentThread.Status.WORKING, "agent.status enters WORKING")
	_check(transport.get_active_stream_count() == 1, "the fake transport owns the active stream")
	var assistant_message: AgentMessage = created.messages.back()
	_check(assistant_message.role == AgentMessage.Role.ASSISTANT, "message.started creates an assistant message")
	_check(assistant_message.is_streaming, "started message is marked streaming")

	transport.advance_streams(0.5)
	_check(not assistant_message.content.is_empty(), "message.delta appends partial content")
	_check(assistant_message.is_streaming, "partial content remains streaming")
	transport.advance_streams(10.0)
	_check(not assistant_message.is_streaming, "message.completed ends streaming")
	_check(created.status == AgentThread.Status.COMPLETE, "normal run reaches COMPLETE")
	_check(transport.get_active_stream_count() == 0, "completed stream is released")

	var content_before_duplicate := assistant_message.content
	var last_sequence := int(assistant_message.metadata.get("last_delta_sequence", 0))
	var duplicate_delta := BackendEvent.new(
		"agent.message.delta",
		{
			"message_id": assistant_message.id,
			"delta": "DUPLICATE",
			"sequence": last_sequence,
		},
		"evt_test_duplicate",
		AppState.session_id,
		created.id,
		Time.get_datetime_string_from_system(true, false) + "Z"
	)
	transport.backend_event_received.emit(duplicate_delta)
	_check(assistant_message.content == content_before_duplicate, "duplicate delta sequence is idempotently ignored")

	var cancel_thread := AppState.get_thread("thread_debug_02")
	_check(
		bridge.send_command("message.send", {"content": "Start then cancel."}, cancel_thread.id),
		"a cancellable run starts"
	)
	var cancelled_message: AgentMessage = cancel_thread.messages.back()
	_check(bridge.send_command("run.cancel", {}, cancel_thread.id), "run.cancel is accepted")
	_check(not cancelled_message.is_streaming, "cancel terminates the active message")
	_check(bool(cancelled_message.metadata.get("cancelled", false)), "cancel is represented in message metadata")
	_check(cancel_thread.status == AgentThread.Status.IDLE, "cancel returns the thread to IDLE")

	var waiting_thread := AppState.get_thread("thread_debug_03")
	_check(
		bridge.send_command(
			"message.send",
			{"content": "Need clarification.", "scenario": "waiting_user"},
			waiting_thread.id
		),
		"WAITING_USER scenario starts"
	)
	transport.advance_streams(10.0)
	_check(waiting_thread.status == AgentThread.Status.WAITING_USER, "fake transport simulates WAITING_USER")

	var error_thread := AppState.get_thread("thread_debug_04")
	_check(
		bridge.send_command(
			"message.send",
			{"content": "Simulate failure.", "scenario": "error"},
			error_thread.id
		),
		"error scenario starts"
	)
	transport.advance_streams(10.0)
	_check(error_thread.status == AgentThread.Status.ERROR, "fake transport simulates ERROR")

	_check(
		bridge.send_command(
			"debug.approval.request",
			{"tool_name": "demo.safe_tool"},
			"thread_debug_05"
		),
		"fake approval request can be injected"
	)
	_check(bridge.get_last_event_type() == "approval.required", "approval.required crosses the transport boundary")

	var unknown_event := BackendEvent.new(
		"future.event",
		{},
		"evt_test_future",
		AppState.session_id,
		"",
		Time.get_datetime_string_from_system(true, false) + "Z"
	)
	transport.backend_event_received.emit(unknown_event)
	_check(bridge.get_last_event_type() == "future.event", "unknown valid events are ignored without crashing")

	_check(bridge.send_command("thread.archive", {}, created.id), "thread.archive is accepted")
	_check(AppState.get_thread(created.id) == null, "thread.archived removes authoritative presentation state")
	_check(bridge.send_command("thread.list"), "thread.list requests a fresh snapshot")
	_check(AppState.ordered_thread_ids.size() == 8, "snapshot reconciliation keeps transport and AppState aligned")

	if not _failed:
		print("[TEST] Transport boundary smoke checks passed")
	main.queue_free()
	get_tree().quit(1 if _failed else 0)


func _check(condition: bool, description: String) -> void:
	if condition:
		return
	_failed = true
	push_error("[TEST] Failed: %s" % description)
