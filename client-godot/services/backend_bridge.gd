class_name BackendBridge
extends Node

signal backend_event_applied(event: BackendEvent)
signal backend_command_sent(command_type: String, thread_id: String)

var _transport: BackendTransport = null
var _last_event_type: String = ""


func _ready() -> void:
	AppState.focused_thread_changed.connect(_on_focused_thread_changed)


func _exit_tree() -> void:
	if AppState.focused_thread_changed.is_connected(_on_focused_thread_changed):
		AppState.focused_thread_changed.disconnect(_on_focused_thread_changed)
	if _transport != null:
		_transport.stop()
		if ServiceRegistry.backend_transport == _transport:
			ServiceRegistry.backend_transport = null


func bind_transport(transport: BackendTransport) -> bool:
	if transport == null:
		return false
	if _transport != null:
		if _transport.backend_event_received.is_connected(_on_backend_event_received):
			_transport.backend_event_received.disconnect(_on_backend_event_received)
		if _transport.connection_state_changed.is_connected(_on_connection_state_changed):
			_transport.connection_state_changed.disconnect(_on_connection_state_changed)
	_transport = transport
	_transport.backend_event_received.connect(_on_backend_event_received)
	_transport.connection_state_changed.connect(_on_connection_state_changed)
	ServiceRegistry.backend_transport = _transport
	AppState.backend_mode = _transport.get_mode()
	AppState.connection_state = _transport.get_connection_state()
	return true


func start() -> bool:
	if _transport == null:
		push_error("[BACKEND] BackendBridge has no configured transport")
		return false
	_transport.start()
	return true


func stop() -> void:
	if _transport != null:
		_transport.stop()


func send_command(command_type: String, payload: Dictionary = {}, thread_id: String = "") -> bool:
	if _transport == null:
		return false
	var accepted := _transport.send_command(command_type, payload, thread_id)
	if accepted:
		backend_command_sent.emit(command_type, thread_id)
	return accepted


func get_transport() -> BackendTransport:
	return _transport


func get_last_event_type() -> String:
	return _last_event_type


func _on_connection_state_changed(state: String) -> void:
	AppState.connection_state = state


func _on_focused_thread_changed(thread_id: String) -> void:
	if _transport != null and _transport.get_connection_state() == BackendTransport.STATE_CONNECTED:
		_transport.send_command("thread.focus", {}, thread_id)


func _on_backend_event_received(event: BackendEvent) -> void:
	if event == null or not event.is_valid():
		push_warning("[BACKEND] Ignored an invalid backend event")
		return
	_last_event_type = event.type
	match event.type:
		"session.ready":
			AppState.session_id = event.session_id
			AppState.set_provider_identity(
				str(event.payload.get("provider", event.payload.get("transport", AppState.backend_mode))),
				str(event.payload.get("model", "local-deterministic"))
			)
		"thread.snapshot":
			_apply_thread_snapshot(event.payload)
		"thread.created", "thread.updated":
			var thread_payload: Dictionary = event.payload.get("thread", {})
			_upsert_thread(thread_payload)
		"thread.archived":
			AppState.remove_thread(event.thread_id)
		"agent.status":
			_apply_agent_status(event)
		"agent.message.started":
			_apply_message_started(event)
		"agent.message.delta":
			_apply_message_delta(event)
		"agent.message.completed":
			_apply_message_completed(event)
		"run.failed":
			_set_thread_status(event.thread_id, AgentThread.Status.ERROR)
		"approval.required":
			var approval := event.payload.duplicate(true)
			approval["thread_id"] = event.thread_id
			AppState.add_approval(approval)
			EventBus.debug_message.emit("Approval requested: %s" % event.payload.get("tool_name", "tool"))
		"tool.running", "tool.completed", "tool.failed":
			var approval_id := str(event.payload.get("approval_id", ""))
			if not approval_id.is_empty():
				AppState.resolve_approval(approval_id)
		"session.paired":
			AppState.set_paired_device(
				str(event.payload.get("device_id", "")),
				str(event.payload.get("device_name", ""))
			)
		"workspace.snapshot":
			AppState.set_workspaces(event.payload.get("workspaces", []))
		"run.workspace":
			AppState.set_run_workspace(event.thread_id, event.payload)
		"diff.proposed":
			AppState.set_diff(event.payload)
		"diff.applied", "diff.rejected":
			AppState.resolve_diff(str(event.payload.get("run_id", "")), event.payload)
		"file.tree":
			AppState.set_file_tree(
				event.thread_id,
				str(event.payload.get("path", "")),
				event.payload.get("entries", [])
			)
		"file.content":
			AppState.set_file_content(event.thread_id, event.payload)
		"tool.catalog":
			AppState.set_tool_catalog(event.payload)
		"error":
			EventBus.debug_message.emit("Backend error: %s" % event.payload.get("message", "unknown error"))
	if event.type != "agent.message.delta":
		EventBus.debug_message.emit("Backend event: %s" % event.type)
	backend_event_applied.emit(event)


func _apply_thread_snapshot(payload: Dictionary) -> void:
	var authoritative_ids: Dictionary = {}
	var thread_payloads: Array = payload.get("threads", [])
	for thread_variant in thread_payloads:
		if not thread_variant is Dictionary:
			continue
		var thread_payload: Dictionary = thread_variant
		var thread_id: String = str(thread_payload.get("id", ""))
		if thread_id.is_empty():
			continue
		authoritative_ids[thread_id] = true
		_upsert_thread(thread_payload)

	var local_ids := AppState.ordered_thread_ids.duplicate()
	for thread_id in local_ids:
		if not authoritative_ids.has(thread_id):
			AppState.remove_thread(thread_id)


func _upsert_thread(payload: Dictionary) -> AgentThread:
	var thread_id: String = str(payload.get("id", ""))
	if thread_id.is_empty():
		return null
	var thread := AppState.get_thread(thread_id)
	var is_new := thread == null
	if is_new:
		thread = AgentThread.new(thread_id, str(payload.get("title", "Untitled thread")))

	thread.title = str(payload.get("title", thread.title))
	thread.status = _status_from_wire(str(payload.get("status", "idle")))
	thread.unread_count = int(payload.get("unread_count", thread.unread_count))
	thread.parent_thread_id = str(payload.get("parent_thread_id", thread.parent_thread_id))
	thread.is_pinned = bool(payload.get("is_pinned", thread.is_pinned))
	thread.metadata = (payload.get("metadata", {}) as Dictionary).duplicate(true)
	thread.tags.clear()
	for tag in payload.get("tags", []):
		thread.tags.append(str(tag))
	var created_at: String = str(payload.get("created_at", ""))
	if not created_at.is_empty():
		thread.created_at = created_at
	var updated_at: String = str(payload.get("updated_at", ""))
	if not updated_at.is_empty():
		thread.updated_at = updated_at

	if payload.has("messages"):
		thread.messages.clear()
		for message_variant in payload.get("messages", []):
			if not message_variant is Dictionary:
				continue
			var message_payload: Dictionary = message_variant
			var message := AgentMessage.new(
				str(message_payload.get("id", "")),
				thread_id,
				_role_from_wire(str(message_payload.get("role", "user"))),
				str(message_payload.get("content", ""))
			)
			message.created_at = str(message_payload.get("created_at", message.created_at))
			message.is_streaming = bool(message_payload.get("is_streaming", false))
			message.metadata = (message_payload.get("metadata", {}) as Dictionary).duplicate(true)
			thread.messages.append(message)

	if is_new:
		AppState.add_thread(thread)
	else:
		AppState.update_thread(thread)
	return thread


func _apply_agent_status(event: BackendEvent) -> void:
	_set_thread_status(event.thread_id, _status_from_wire(str(event.payload.get("status", "idle"))))


func _set_thread_status(thread_id: String, status: AgentThread.Status) -> void:
	var thread := AppState.get_thread(thread_id)
	if thread == null:
		return
	thread.status = status
	AppState.update_thread(thread)


func _apply_message_started(event: BackendEvent) -> void:
	var thread := AppState.get_thread(event.thread_id)
	if thread == null:
		return
	var message_id: String = str(event.payload.get("message_id", ""))
	if message_id.is_empty() or _find_message(thread, message_id) != null:
		return
	var message := AgentMessage.new(
		message_id,
		event.thread_id,
		_role_from_wire(str(event.payload.get("role", "assistant"))),
		str(event.payload.get("content", ""))
	)
	message.is_streaming = true
	message.metadata["last_delta_sequence"] = 0
	thread.add_message(message)
	AppState.update_thread(thread)


func _apply_message_delta(event: BackendEvent) -> void:
	var thread := AppState.get_thread(event.thread_id)
	if thread == null:
		return
	var message := _find_message(thread, str(event.payload.get("message_id", "")))
	if message == null:
		return
	var sequence := int(event.payload.get("sequence", 0))
	var last_sequence := int(message.metadata.get("last_delta_sequence", 0))
	if sequence > 0 and sequence <= last_sequence:
		return
	message.content += str(event.payload.get("delta", ""))
	if sequence > 0:
		message.metadata["last_delta_sequence"] = sequence
	AppState.update_thread(thread)


func _apply_message_completed(event: BackendEvent) -> void:
	var thread := AppState.get_thread(event.thread_id)
	if thread == null:
		return
	var message := _find_message(thread, str(event.payload.get("message_id", "")))
	if message == null or bool(message.metadata.get("backend_completed", false)):
		return
	message.is_streaming = false
	message.metadata["backend_completed"] = true
	message.metadata["cancelled"] = bool(event.payload.get("cancelled", false))
	if event.payload.has("unread_count"):
		thread.unread_count = int(event.payload["unread_count"])
	elif AppState.focused_thread_id != event.thread_id:
		thread.unread_count += 1
	AppState.update_thread(thread)


func _find_message(thread: AgentThread, message_id: String) -> AgentMessage:
	for message in thread.messages:
		if message.id == message_id:
			return message
	return null


func _status_from_wire(value: String) -> AgentThread.Status:
	match value.to_lower():
		"listening":
			return AgentThread.Status.LISTENING
		"working":
			return AgentThread.Status.WORKING
		"waiting_user":
			return AgentThread.Status.WAITING_USER
		"complete":
			return AgentThread.Status.COMPLETE
		"error":
			return AgentThread.Status.ERROR
		_:
			return AgentThread.Status.IDLE


func _role_from_wire(value: String) -> AgentMessage.Role:
	match value.to_lower():
		"assistant":
			return AgentMessage.Role.ASSISTANT
		"system":
			return AgentMessage.Role.SYSTEM
		"tool":
			return AgentMessage.Role.TOOL
		_:
			return AgentMessage.Role.USER
