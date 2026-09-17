class_name FakeBackendTransport
extends BackendTransport

const THREAD_TITLES := [
	"Research Agent",
	"Planning",
	"Code",
	"Design",
	"Operations",
	"Notes",
	"Data",
	"Writing",
	"Review",
	"Personal",
	"QA",
	"Archive",
]

const INITIAL_STATUSES := [
	"idle",
	"working",
	"waiting_user",
	"complete",
	"error",
	"listening",
]

@export_range(1, 12, 1) var initial_thread_count: int = 8
@export_range(0.0, 2.0, 0.01) var stream_start_latency_seconds: float = 0.18
@export_range(5.0, 200.0, 1.0) var characters_per_second: float = 52.0

var _session_id: String = ""
var _focused_thread_id: String = ""
var _threads_by_id: Dictionary = {}
var _ordered_thread_ids: Array[String] = []
var _streams: Dictionary = {}
var _pending_approvals: Dictionary = {}
var _event_counter: int = 0
var _message_counter: int = 0
var _run_counter: int = 0
var _next_thread_number: int = 1


func _ready() -> void:
	set_process(false)


func _process(delta: float) -> void:
	advance_streams(delta)


func get_mode() -> String:
	return "fake"


func start() -> void:
	if get_connection_state() == STATE_CONNECTED:
		return
	_set_connection_state(STATE_CONNECTING)
	_reset_fake_state()
	_session_id = "sess_fake_%d" % Time.get_ticks_msec()
	_seed_initial_threads()
	_set_connection_state(STATE_CONNECTED)
	set_process(true)
	_emit_event("session.ready", "", {
		"transport": get_mode(),
		"provider": "fake",
		"model": "local-deterministic",
	})
	_emit_thread_snapshot()


func stop() -> void:
	set_process(false)
	_streams.clear()
	_focused_thread_id = ""
	super.stop()


func send_command(command_type: String, payload: Dictionary = {}, thread_id: String = "") -> bool:
	if get_connection_state() != STATE_CONNECTED:
		return false
	match command_type:
		"session.hello":
			_emit_event("session.ready", "", {
				"transport": get_mode(),
				"provider": "fake",
				"model": "local-deterministic",
			})
			return true
		"thread.list":
			_emit_thread_snapshot()
			return true
		"thread.create":
			return _create_thread(payload)
		"thread.focus":
			return _focus_thread(thread_id)
		"thread.rename":
			return _rename_thread(thread_id, payload)
		"thread.archive":
			return _archive_thread(thread_id)
		"message.send":
			return _send_message(thread_id, payload)
		"voice.transcript.final":
			return _send_message(thread_id, {"content": str(payload.get("transcript", ""))})
		"run.cancel":
			return _cancel_run(thread_id)
		"approval.respond":
			return _respond_fake_approval(payload)
		"debug.thread.status":
			return _inject_status(thread_id, str(payload.get("status", "idle")))
		"debug.approval.request":
			return _request_fake_approval(thread_id, payload)
		_:
			_emit_error("unknown_command", "Unknown command: %s" % command_type, thread_id)
			return false


func get_active_stream_count() -> int:
	return _streams.size()


func advance_streams(delta: float) -> void:
	var completed_ids: Array[String] = []
	for thread_id_variant in _streams.keys():
		var thread_id: String = thread_id_variant
		var stream: Dictionary = _streams[thread_id]
		var stream_delta := delta
		var latency: float = stream["latency"]
		if latency > 0.0:
			if stream_delta <= latency:
				stream["latency"] = latency - stream_delta
				_streams[thread_id] = stream
				continue
			stream_delta -= latency
			stream["latency"] = 0.0

		var response: String = stream["text"]
		var cursor: int = stream["cursor"]
		var accumulator: float = stream["accumulator"] + stream_delta * characters_per_second
		var character_count := mini(floori(accumulator), response.length() - cursor)
		if character_count <= 0:
			stream["accumulator"] = accumulator
			_streams[thread_id] = stream
			continue

		var delta_text := response.substr(cursor, character_count)
		cursor += character_count
		stream["cursor"] = cursor
		stream["accumulator"] = accumulator - float(character_count)
		stream["sequence"] = int(stream["sequence"]) + 1
		_streams[thread_id] = stream
		_append_stream_content(thread_id, str(stream["message_id"]), delta_text)
		_emit_event(
			"agent.message.delta",
			thread_id,
			{
				"message_id": stream["message_id"],
				"delta": delta_text,
				"sequence": stream["sequence"],
				"run_id": stream["run_id"],
			}
		)

		if cursor >= response.length():
			completed_ids.append(thread_id)

	for thread_id in completed_ids:
		_complete_stream(thread_id)


func _reset_fake_state() -> void:
	_threads_by_id.clear()
	_ordered_thread_ids.clear()
	_streams.clear()
	_pending_approvals.clear()
	_focused_thread_id = ""
	_event_counter = 0
	_message_counter = 0
	_run_counter = 0
	_next_thread_number = 1


func _seed_initial_threads() -> void:
	for number in range(1, initial_thread_count + 1):
		var thread_id := "thread_demo" if number == 1 else "thread_debug_%02d" % number
		var title: String = THREAD_TITLES[(number - 1) % THREAD_TITLES.size()]
		var status: String = INITIAL_STATUSES[(number - 1) % INITIAL_STATUSES.size()]
		_insert_thread(_make_thread(thread_id, title, status, number))
	_next_thread_number = initial_thread_count + 1


func _make_thread(thread_id: String, title: String, status: String, number: int) -> Dictionary:
	var now := _timestamp()
	var messages: Array = [
		{
			"id": "msg_%02d_user_1" % number,
			"thread_id": thread_id,
			"role": "user",
			"content": "Give me a concise update for the %s thread." % title,
			"created_at": now,
			"is_streaming": false,
			"metadata": {},
		}
	]
	if title == "Code":
		messages.append({
			"id": "msg_%02d_assistant_1" % number,
			"thread_id": thread_id,
			"role": "assistant",
			"content": "Illustrative Hand Lab routing adapter (not a live agent edit):\n```gdscript\n" + preload("res://services/demo_code.gd").SOURCE + "\n```",
			"created_at": now,
			"is_streaming": false,
			"metadata": {"artifact": "live_code"},
		})
	return {
		"id": thread_id,
		"title": title,
		"status": _normalize_status(status),
		"messages": messages,
		"unread_count": 0,
		"created_at": now,
		"updated_at": now,
		"parent_thread_id": "",
		"tags": [],
		"metadata": {"fake_stream_started": false},
		"is_pinned": false,
	}


func _insert_thread(thread: Dictionary) -> void:
	var thread_id: String = thread["id"]
	_threads_by_id[thread_id] = thread
	if not _ordered_thread_ids.has(thread_id):
		_ordered_thread_ids.append(thread_id)


func _create_thread(payload: Dictionary) -> bool:
	var number := _claim_thread_number()
	var thread_id: String = str(payload.get("id", "thread_debug_%02d" % number))
	if thread_id.is_empty() or _threads_by_id.has(thread_id):
		_emit_error("duplicate_thread", "Thread already exists: %s" % thread_id, thread_id)
		return false
	var title: String = str(payload.get("title", THREAD_TITLES[(number - 1) % THREAD_TITLES.size()]))
	var status: String = str(payload.get("status", INITIAL_STATUSES[(number - 1) % INITIAL_STATUSES.size()]))
	var thread := _make_thread(thread_id, title, status, number)
	_insert_thread(thread)
	_emit_event("thread.created", thread_id, {"thread": thread.duplicate(true)})
	return true


func _focus_thread(thread_id: String) -> bool:
	_focused_thread_id = thread_id
	if thread_id.is_empty():
		return true
	if not _threads_by_id.has(thread_id):
		_emit_error("thread_not_found", "Unknown thread: %s" % thread_id, thread_id)
		return false
	var thread: Dictionary = _threads_by_id[thread_id]
	if int(thread.get("unread_count", 0)) > 0:
		thread["unread_count"] = 0
		thread["updated_at"] = _timestamp()
		_threads_by_id[thread_id] = thread
		_emit_event("thread.updated", thread_id, {"thread": thread.duplicate(true)})
	var metadata: Dictionary = thread.get("metadata", {})
	if bool(metadata.get("fake_stream_started", false)):
		return true
	metadata["fake_stream_started"] = true
	thread["metadata"] = metadata
	_threads_by_id[thread_id] = thread
	return _start_response(thread_id, "focus")


func _archive_thread(thread_id: String) -> bool:
	if not _threads_by_id.has(thread_id):
		return false
	if _streams.has(thread_id):
		_streams.erase(thread_id)
	_threads_by_id.erase(thread_id)
	_ordered_thread_ids.erase(thread_id)
	if _focused_thread_id == thread_id:
		_focused_thread_id = ""
	_emit_event("thread.archived", thread_id, {})
	return true


func _rename_thread(thread_id: String, payload: Dictionary) -> bool:
	if not _threads_by_id.has(thread_id):
		return false
	var title := str(payload.get("title", "")).strip_edges()
	if title.is_empty():
		return false
	var thread: Dictionary = _threads_by_id[thread_id]
	thread["title"] = title.left(120)
	thread["updated_at"] = _timestamp()
	_threads_by_id[thread_id] = thread
	_emit_event("thread.updated", thread_id, {"thread": thread.duplicate(true)})
	return true


func _send_message(thread_id: String, payload: Dictionary) -> bool:
	if not _threads_by_id.has(thread_id) or _streams.has(thread_id):
		return false
	var content := str(payload.get("content", "")).strip_edges()
	if content.is_empty():
		return false
	_message_counter += 1
	var message := {
		"id": "msg_fake_user_%03d" % _message_counter,
		"thread_id": thread_id,
		"role": "user",
		"content": content,
		"created_at": _timestamp(),
		"is_streaming": false,
		"metadata": {},
	}
	var thread: Dictionary = _threads_by_id[thread_id]
	var messages: Array = thread["messages"]
	messages.append(message)
	thread["messages"] = messages
	thread["updated_at"] = _timestamp()
	_threads_by_id[thread_id] = thread
	_emit_event("thread.updated", thread_id, {"thread": thread.duplicate(true)})
	if content.to_lower().begins_with("/tool"):
		var tool_request := content.substr(5).strip_edges().to_lower()
		if tool_request in ["status", "diagnostics", "clock"]:
			return _complete_fake_safe_tool(thread_id, tool_request)
		return _request_fake_approval(
			thread_id,
			{
				"tool_name": "Simulated note write",
				"summary": "Allow one in-memory simulated note action (%d characters)?" % content.trim_prefix("/tool").strip_edges().length(),
				"impact_preview": {
					"route": ["gesture", "local backend", "simulation buffer"],
					"scope": "one in-memory demonstration note",
					"side_effect": "no external write",
					"reversibility": "discarded with process state",
					"external": false,
				},
			}
		)
	return _start_response(thread_id, str(payload.get("scenario", "normal")), content)


func _complete_fake_safe_tool(thread_id: String, request: String) -> bool:
	var tool_id := "system.clock" if request == "clock" else "system.diagnostics"
	var message_text := (
		"Chronometer synchronized: %s" % _timestamp()
		if request == "clock"
		else "System scan nominal: protocol=v1, transport=fake, tools=3, uptime=simulated"
	)
	_run_counter += 1
	_message_counter += 1
	var run_id := "run_fake_%03d" % _run_counter
	var thread: Dictionary = _threads_by_id[thread_id]
	var messages: Array = thread["messages"]
	messages.append({
		"id": "msg_fake_tool_%03d" % _message_counter,
		"thread_id": thread_id,
		"role": "tool",
		"content": message_text,
		"created_at": _timestamp(),
		"is_streaming": false,
		"metadata": {"tool_id": tool_id},
	})
	thread["messages"] = messages
	thread["status"] = "complete"
	thread["updated_at"] = _timestamp()
	_threads_by_id[thread_id] = thread
	_emit_event("agent.status", thread_id, {"status": "working", "run_id": run_id})
	_emit_event("tool.running", thread_id, {
		"run_id": run_id,
		"tool_id": tool_id,
		"permission_level": "safe_read",
	})
	_emit_event("tool.completed", thread_id, {
		"run_id": run_id,
		"tool_id": tool_id,
		"output": {
			"status": "ok",
			"message": message_text,
			"external_side_effect": false,
		},
	})
	_emit_event("thread.updated", thread_id, {"thread": thread.duplicate(true)})
	_emit_event("agent.status", thread_id, {"status": "complete", "run_id": run_id})
	_emit_event("run.completed", thread_id, {"run_id": run_id})
	return true


func _start_response(thread_id: String, scenario: String, prompt: String = "") -> bool:
	if not _threads_by_id.has(thread_id) or _streams.has(thread_id):
		return false
	var thread: Dictionary = _threads_by_id[thread_id]
	var title: String = thread["title"]
	var response := ""
	var terminal_status := "complete"
	match scenario:
		"waiting_user":
			response = "I need one more detail before the simulated run can continue."
			terminal_status = "waiting_user"
		"error":
			response = "The simulated run encountered a recoverable backend error."
			terminal_status = "error"
		"focus":
			response = (
				"This is a simulated update from %s. The response is arriving incrementally, "
				+ "while the spatial interface remains responsive and focused on this thread."
			) % title
		_:
			response = "The fake backend received your message: %s" % prompt

	_message_counter += 1
	_run_counter += 1
	var message_id := "msg_fake_assistant_%03d" % _message_counter
	var run_id := "run_fake_%03d" % _run_counter
	var assistant_message := {
		"id": message_id,
		"thread_id": thread_id,
		"role": "assistant",
		"content": "",
		"created_at": _timestamp(),
		"is_streaming": true,
		"metadata": {"run_id": run_id},
	}
	var messages: Array = thread["messages"]
	messages.append(assistant_message)
	thread["messages"] = messages
	thread["status"] = "working"
	thread["updated_at"] = _timestamp()
	_threads_by_id[thread_id] = thread
	_streams[thread_id] = {
		"message_id": message_id,
		"run_id": run_id,
		"text": response,
		"cursor": 0,
		"accumulator": 0.0,
		"latency": stream_start_latency_seconds,
		"sequence": 0,
		"terminal_status": terminal_status,
	}
	_emit_event("agent.status", thread_id, {"status": "working", "run_id": run_id})
	_emit_event(
		"agent.message.started",
		thread_id,
		{"message_id": message_id, "role": "assistant", "run_id": run_id}
	)
	return true


func _append_stream_content(thread_id: String, message_id: String, delta: String) -> void:
	var thread: Dictionary = _threads_by_id[thread_id]
	var messages: Array = thread["messages"]
	for index in range(messages.size()):
		var message: Dictionary = messages[index]
		if str(message.get("id", "")) == message_id:
			message["content"] = str(message.get("content", "")) + delta
			messages[index] = message
			break
	thread["messages"] = messages
	thread["updated_at"] = _timestamp()
	_threads_by_id[thread_id] = thread


func _complete_stream(thread_id: String) -> void:
	if not _streams.has(thread_id) or not _threads_by_id.has(thread_id):
		return
	var stream: Dictionary = _streams[thread_id]
	var thread: Dictionary = _threads_by_id[thread_id]
	var messages: Array = thread["messages"]
	for index in range(messages.size()):
		var message: Dictionary = messages[index]
		if str(message.get("id", "")) == str(stream["message_id"]):
			message["is_streaming"] = false
			messages[index] = message
			break
	var unread_count := int(thread.get("unread_count", 0))
	if _focused_thread_id != thread_id:
		unread_count += 1
	var terminal_status: String = stream["terminal_status"]
	thread["messages"] = messages
	thread["status"] = terminal_status
	thread["unread_count"] = unread_count
	thread["updated_at"] = _timestamp()
	_threads_by_id[thread_id] = thread
	_emit_event(
		"agent.message.completed",
		thread_id,
		{
			"message_id": stream["message_id"],
			"run_id": stream["run_id"],
			"unread_count": unread_count,
		}
	)
	_emit_event("agent.status", thread_id, {"status": terminal_status, "run_id": stream["run_id"]})
	if terminal_status == "error":
		_emit_event("run.failed", thread_id, {"run_id": stream["run_id"], "message": "Simulated failure"})
	else:
		_emit_event("run.completed", thread_id, {"run_id": stream["run_id"]})
	_streams.erase(thread_id)


func _cancel_run(thread_id: String) -> bool:
	if not _streams.has(thread_id) or not _threads_by_id.has(thread_id):
		return false
	var stream: Dictionary = _streams[thread_id]
	var thread: Dictionary = _threads_by_id[thread_id]
	var messages: Array = thread["messages"]
	for index in range(messages.size()):
		var message: Dictionary = messages[index]
		if str(message.get("id", "")) == str(stream["message_id"]):
			message["is_streaming"] = false
			messages[index] = message
			break
	thread["messages"] = messages
	thread["status"] = "idle"
	thread["updated_at"] = _timestamp()
	_threads_by_id[thread_id] = thread
	_emit_event(
		"agent.message.completed",
		thread_id,
		{"message_id": stream["message_id"], "run_id": stream["run_id"], "cancelled": true}
	)
	_emit_event("agent.status", thread_id, {"status": "idle", "run_id": stream["run_id"]})
	_emit_event("run.completed", thread_id, {"run_id": stream["run_id"], "cancelled": true})
	_streams.erase(thread_id)
	return true


func _inject_status(thread_id: String, status: String) -> bool:
	if not _threads_by_id.has(thread_id):
		return false
	var normalized_status := _normalize_status(status)
	var thread: Dictionary = _threads_by_id[thread_id]
	thread["status"] = normalized_status
	thread["updated_at"] = _timestamp()
	_threads_by_id[thread_id] = thread
	_emit_event("agent.status", thread_id, {"status": normalized_status})
	return true


func _request_fake_approval(thread_id: String, payload: Dictionary) -> bool:
	if not _threads_by_id.has(thread_id):
		return false
	var approval_id := "approval_fake_%03d" % (_event_counter + 1)
	var run_id := "run_fake_approval_%03d" % (_event_counter + 1)
	_pending_approvals[approval_id] = {
		"thread_id": thread_id,
		"run_id": run_id,
		"tool_name": str(payload.get("tool_name", "demo.safe_tool")),
	}
	var thread: Dictionary = _threads_by_id[thread_id]
	thread["status"] = "waiting_user"
	thread["updated_at"] = _timestamp()
	_threads_by_id[thread_id] = thread
	_emit_event("agent.status", thread_id, {"status": "waiting_user", "run_id": run_id})
	_emit_event(
		"approval.required",
		thread_id,
		{
			"approval_id": approval_id,
			"run_id": run_id,
			"tool_id": "demo.write_note",
			"tool_name": str(payload.get("tool_name", "demo.safe_tool")),
			"summary": str(payload.get("summary", "Allow the simulated tool to run?")),
			"permission_level": "write_reversible",
			"impact_preview": (payload.get("impact_preview", {}) as Dictionary).duplicate(true),
		}
	)
	return true


func _respond_fake_approval(payload: Dictionary) -> bool:
	var approval_id := str(payload.get("approval_id", ""))
	var decision := str(payload.get("decision", ""))
	if not _pending_approvals.has(approval_id) or decision not in ["approve", "deny"]:
		return false
	var approval: Dictionary = _pending_approvals[approval_id]
	_pending_approvals.erase(approval_id)
	var thread_id: String = approval["thread_id"]
	var run_id: String = approval["run_id"]
	var thread: Dictionary = _threads_by_id[thread_id]
	_message_counter += 1
	var messages: Array = thread["messages"]
	if decision == "deny":
		messages.append({
			"id": "msg_fake_tool_%03d" % _message_counter,
			"thread_id": thread_id,
			"role": "tool",
			"content": "User denied the simulated tool.",
			"created_at": _timestamp(),
			"is_streaming": false,
			"metadata": {"approval_id": approval_id},
		})
		thread["messages"] = messages
		thread["status"] = "idle"
		thread["updated_at"] = _timestamp()
		_threads_by_id[thread_id] = thread
		_emit_event("tool.failed", thread_id, {
			"approval_id": approval_id,
			"run_id": run_id,
			"tool_id": "demo.write_note",
			"message": "Denied by user",
		})
		_emit_event("thread.updated", thread_id, {"thread": thread.duplicate(true)})
		_emit_event("agent.status", thread_id, {"status": "idle", "run_id": run_id})
		return true

	_emit_event("agent.status", thread_id, {"status": "working", "run_id": run_id})
	_emit_event("tool.running", thread_id, {
		"approval_id": approval_id,
		"run_id": run_id,
		"tool_id": "demo.write_note",
	})
	messages.append({
		"id": "msg_fake_tool_%03d" % _message_counter,
		"thread_id": thread_id,
		"role": "tool",
		"content": "Approved simulated note; no external system was changed.",
		"created_at": _timestamp(),
		"is_streaming": false,
		"metadata": {"approval_id": approval_id},
	})
	thread["messages"] = messages
	thread["status"] = "complete"
	thread["updated_at"] = _timestamp()
	_threads_by_id[thread_id] = thread
	_emit_event("tool.completed", thread_id, {
		"approval_id": approval_id,
		"run_id": run_id,
		"tool_id": "demo.write_note",
		"output": {"external_side_effect": false},
	})
	_emit_event("thread.updated", thread_id, {"thread": thread.duplicate(true)})
	_emit_event("agent.status", thread_id, {"status": "complete", "run_id": run_id})
	_emit_event("run.completed", thread_id, {"run_id": run_id})
	return true


func _emit_thread_snapshot() -> void:
	var threads: Array = []
	for thread_id in _ordered_thread_ids:
		var thread: Dictionary = _threads_by_id[thread_id]
		threads.append(thread.duplicate(true))
	_emit_event("thread.snapshot", "", {"threads": threads})


func _emit_event(event_type: String, thread_id: String, payload: Dictionary) -> void:
	_event_counter += 1
	var event := BackendEvent.new(
		event_type,
		payload,
		"evt_fake_%04d" % _event_counter,
		_session_id,
		thread_id,
		_timestamp()
	)
	backend_event_received.emit(event)


func _emit_error(code: String, message: String, thread_id: String = "") -> void:
	_emit_event("error", thread_id, {"code": code, "message": message})


func _claim_thread_number() -> int:
	var number := _next_thread_number
	var candidate_id := "thread_demo" if number == 1 else "thread_debug_%02d" % number
	while _threads_by_id.has(candidate_id):
		number += 1
		candidate_id = "thread_demo" if number == 1 else "thread_debug_%02d" % number
	_next_thread_number = number + 1
	return number


func _normalize_status(status: String) -> String:
	var normalized := status.to_lower()
	if normalized in ["idle", "listening", "working", "waiting_user", "complete", "error"]:
		return normalized
	return "idle"


func _timestamp() -> String:
	return Time.get_datetime_string_from_system(true, false) + "Z"
