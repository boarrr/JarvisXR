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

const DEMO_WORKSPACE_ID := "ws_demo"

var _session_id: String = ""
var _focused_thread_id: String = ""
var _threads_by_id: Dictionary = {}
var _ordered_thread_ids: Array[String] = []
var _streams: Dictionary = {}
var _pending_approvals: Dictionary = {}
var _worktrees_by_thread: Dictionary = {}
var _diffs_by_run: Dictionary = {}
var _archived_threads: Dictionary = {}
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
		"protocol_version": BackendEvent.PROTOCOL_VERSION,
		"auth": "open-loopback",
		"workspaces": [DEMO_WORKSPACE_ID],
	})
	_emit_thread_snapshot()
	_emit_workspace_snapshot()
	_emit_tool_catalog()


func stop() -> void:
	set_process(false)
	_streams.clear()
	_focused_thread_id = ""
	super.stop()


func pair_with_payload(payload: String) -> bool:
	return not PairingPayload.parse(payload).is_empty()


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
		"workspace.list":
			_emit_workspace_snapshot()
			return true
		"workspace.bind":
			return _bind_workspace(thread_id, str(payload.get("workspace_id", "")))
		"file.list":
			return _emit_file_tree(thread_id, str(payload.get("path", "")))
		"file.read":
			return _emit_file_content(thread_id, str(payload.get("path", "")))
		"fs.list":
			return _emit_host_tree(thread_id, str(payload.get("path", "")))
		"fs.read":
			return _emit_host_content(thread_id, str(payload.get("path", "")))
		"diff.get":
			return _emit_diff(thread_id)
		"diff.decision":
			return _decide_diff(thread_id, payload)
		"tool.catalog":
			_emit_tool_catalog()
			return true
		"thread.combine":
			return _combine_threads(payload)
		"thread.restore":
			return _restore_thread(thread_id)
		"thread.separate":
			return _separate_thread(thread_id)
		"debug.workspace.diff":
			return _inject_workspace_diff(thread_id, payload)
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
	_worktrees_by_thread.clear()
	_diffs_by_run.clear()
	_archived_threads.clear()
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
		if number == 1:
			var thread: Dictionary = _threads_by_id[thread_id]
			var metadata: Dictionary = thread["metadata"]
			metadata["workspace_id"] = DEMO_WORKSPACE_ID
			thread["metadata"] = metadata
			_threads_by_id[thread_id] = thread
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


func _combine_threads(payload: Dictionary) -> bool:
	var source_ids: Array = payload.get("thread_ids", [])
	if source_ids.size() < 2:
		return false
	var titles: PackedStringArray = []
	var excerpts: PackedStringArray = []
	for source_variant in source_ids:
		var source_id := str(source_variant)
		if not _threads_by_id.has(source_id):
			_emit_error("thread_not_found", "Unknown thread: %s" % source_id, source_id)
			return false
		var source: Dictionary = _threads_by_id[source_id]
		titles.append(str(source.get("title", source_id)))
		var messages: Array = source.get("messages", [])
		var text := "No messages yet."
		for index in range(messages.size() - 1, -1, -1):
			var message: Dictionary = messages[index]
			if (
				str(message.get("role", "")) in ["user", "assistant", "tool"]
				and not str(message.get("content", "")).strip_edges().is_empty()
			):
				text = str(message.get("content", "")).strip_edges().substr(0, 900)
				break
		excerpts.append("[%s]\n%s" % [source.get("title", source_id), text])
	var number := _claim_thread_number()
	var new_id := "thread_demo" if number == 1 else "thread_debug_%02d" % number
	var combined := _make_thread(
		new_id,
		("%s (combined)" % " + ".join(titles)).left(120),
		"idle",
		number
	)
	combined["parent_thread_id"] = str(source_ids[0])
	var metadata: Dictionary = combined.get("metadata", {})
	metadata["combined_from"] = source_ids.duplicate()
	combined["metadata"] = metadata
	_message_counter += 1
	var messages: Array = combined.get("messages", [])
	messages.append({
		"id": "msg_fake_combined_%03d" % _message_counter,
		"thread_id": new_id,
		"role": "user",
		"content": "Combined context from two agents:\n\n" + "\n\n---\n\n".join(excerpts),
		"created_at": _timestamp(),
		"is_streaming": false,
		"metadata": {},
	})
	combined["messages"] = messages
	_insert_thread(combined)
	_emit_event("thread.created", new_id, {"thread": combined.duplicate(true)})
	# The originals are absorbed into the combined agent; separate restores them.
	for source_variant in source_ids:
		_archive_thread(str(source_variant))
	return true


func _separate_thread(combined_id: String) -> bool:
	if not _threads_by_id.has(combined_id):
		_emit_error("thread_not_found", "Unknown thread: %s" % combined_id, combined_id)
		return false
	var combined: Dictionary = _threads_by_id[combined_id]
	var source_ids: Array = combined.get("metadata", {}).get("combined_from", [])
	if source_ids.is_empty():
		_emit_error("thread_not_found", "Not a combined thread: %s" % combined_id, combined_id)
		return false
	_archive_thread(combined_id)
	for source_variant in source_ids:
		_restore_thread(str(source_variant))
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
	_archived_threads[thread_id] = _threads_by_id[thread_id]
	_threads_by_id.erase(thread_id)
	_ordered_thread_ids.erase(thread_id)
	if _focused_thread_id == thread_id:
		_focused_thread_id = ""
	_emit_event("thread.archived", thread_id, {})
	return true


func _restore_thread(thread_id: String) -> bool:
	if _threads_by_id.has(thread_id):
		return true
	if not _archived_threads.has(thread_id):
		_emit_error("thread_not_found", "Unknown thread: %s" % thread_id, thread_id)
		return false
	var thread: Dictionary = _archived_threads[thread_id]
	_archived_threads.erase(thread_id)
	_insert_thread(thread)
	_emit_event("thread.created", thread_id, {"thread": thread.duplicate(true)})
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
	var metadata: Dictionary = thread.get("metadata", {})
	var workspace_id := str(metadata.get("workspace_id", ""))
	if not workspace_id.is_empty():
		_worktrees_by_thread[thread_id] = {
			"run_id": run_id,
			"workspace_id": workspace_id,
			"branch": "spatial/agent-%s" % run_id,
			"base_commit": "fake_base_commit",
			"files": _sample_diff_files(),
		}
		_emit_event("run.workspace", thread_id, {
			"run_id": run_id,
			"workspace_id": workspace_id,
			"branch": "spatial/agent-%s" % run_id,
			"base_commit": "fake_base_commit",
		})
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


func _emit_workspace_snapshot() -> void:
	_emit_event("workspace.snapshot", "", {
		"workspaces": [{
			"id": DEMO_WORKSPACE_ID,
			"name": "Demo Workspace",
			"path": "~/Projects/demo",
			"base_branch": "main",
		}],
	})


func _emit_tool_catalog() -> void:
	_emit_event("tool.catalog", "", {
		"mcp_servers": ["demo.filesystem"],
		"tools": [
			{
				"id": "system.clock",
				"description": "Read the backend's current UTC clock.",
				"permission_level": "safe_read",
				"source": "native",
				"server_id": "",
				"annotations": {},
			},
			{
				"id": "system.diagnostics",
				"description": "Read non-sensitive service health and uptime.",
				"permission_level": "safe_read",
				"source": "native",
				"server_id": "",
				"annotations": {},
			},
			{
				"id": "demo.write_note",
				"description": "Simulate writing a note without changing any external system.",
				"permission_level": "write_reversible",
				"source": "native",
				"server_id": "",
				"annotations": {},
			},
			{
				"id": "mcp.demo.filesystem.read_file",
				"description": "Read a file from the demo workspace.",
				"permission_level": "safe_read",
				"source": "mcp",
				"server_id": "demo.filesystem",
				"annotations": {"readOnlyHint": true},
			},
			{
				"id": "mcp.demo.filesystem.write_file",
				"description": "Write a file in the demo workspace.",
				"permission_level": "write_reversible",
				"source": "mcp",
				"server_id": "demo.filesystem",
				"annotations": {},
			},
		],
	})


func _bind_workspace(thread_id: String, workspace_id: String) -> bool:
	if not _threads_by_id.has(thread_id):
		return false
	var thread: Dictionary = _threads_by_id[thread_id]
	var metadata: Dictionary = thread.get("metadata", {})
	metadata["workspace_id"] = workspace_id
	thread["metadata"] = metadata
	thread["updated_at"] = _timestamp()
	_threads_by_id[thread_id] = thread
	_emit_event("thread.updated", thread_id, {"thread": thread.duplicate(true)})
	return true


func _emit_file_tree(thread_id: String, path: String) -> bool:
	if not _threads_by_id.has(thread_id):
		return false
	var entries: Array = []
	if path.is_empty():
		entries = [
			{"name": "services", "path": "services", "type": "dir", "size": 0},
			{"name": "README.md", "path": "README.md", "type": "file", "size": 64},
			{"name": "app.py", "path": "app.py", "type": "file", "size": 16},
		]
	elif path == "services":
		entries = [
			{"name": "agent_client.gd", "path": "services/agent_client.gd", "type": "file", "size": 320},
			{"name": "protocol.gd", "path": "services/protocol.gd", "type": "file", "size": 180},
		]
	_emit_event("file.tree", thread_id, {"path": path, "entries": entries})
	return true


func _emit_file_content(thread_id: String, path: String) -> bool:
	if not _threads_by_id.has(thread_id):
		return false
	if path.is_empty():
		_emit_error("invalid_path", "A file path is required", thread_id)
		return false
	var content := _fake_file_content(path)
	_emit_event("file.content", thread_id, {
		"path": path,
		"size": content.length(),
		"binary": false,
		"truncated": false,
		"content": content,
	})
	return true


func _emit_host_tree(thread_id: String, path: String) -> bool:
	var entries: Array = []
	if path.is_empty():
		entries = [
			{"name": "Documents", "path": "Documents", "type": "dir", "size": 0},
			{"name": "Projects", "path": "Projects", "type": "dir", "size": 0},
			{"name": "notes.txt", "path": "notes.txt", "type": "file", "size": 24},
		]
	elif path == "Documents":
		entries = [
			{"name": "readme.txt", "path": "Documents/readme.txt", "type": "file", "size": 40},
			{"name": "todo.md", "path": "Documents/todo.md", "type": "file", "size": 30},
		]
	_emit_event("file.tree", thread_id, {"path": path, "entries": entries, "scope": "host"})
	return true


func _emit_host_content(thread_id: String, path: String) -> bool:
	if path.is_empty():
		_emit_error("invalid_path", "A file path is required", thread_id)
		return false
	var content := "host file: %s\nhello from the host filesystem\n" % path
	_emit_event("file.content", thread_id, {
		"path": path,
		"size": content.length(),
		"binary": false,
		"truncated": false,
		"content": content,
		"scope": "host",
	})
	return true


func _fake_file_content(path: String) -> String:
	match path:
		"app.py":
			return "print('hello')\n"
		"README.md":
			return "# Demo workspace\n\nOffline fake workspace used by the cockpit.\n"
		"services/agent_client.gd":
			return preload("res://services/demo_code.gd").SOURCE
		"services/protocol.gd":
			return "class_name Protocol\n\nconst VERSION := 2\n"
		_:
			return "// %s\n" % path


func _emit_diff(thread_id: String) -> bool:
	var worktree := _worktrees_by_thread.get(thread_id, {}) as Dictionary
	if worktree.is_empty():
		_emit_error("workspace_unavailable", "No agent worktree is available for this thread", thread_id)
		return false
	var run_id := str(worktree.get("run_id", ""))
	var files: Array = worktree.get("files", [])
	_diffs_by_run[run_id] = {"thread_id": thread_id, "files": files.duplicate(true)}
	_emit_event("diff.proposed", thread_id, {
		"run_id": run_id,
		"truncated": false,
		"files": files,
	})
	return true


func _inject_workspace_diff(thread_id: String, payload: Dictionary) -> bool:
	if not _threads_by_id.has(thread_id):
		return false
	var worktree := _worktrees_by_thread.get(thread_id, {}) as Dictionary
	if worktree.is_empty():
		_event_counter += 1
		worktree = {
			"run_id": "run_fake_diff_%03d" % _event_counter,
			"workspace_id": DEMO_WORKSPACE_ID,
			"branch": "spatial/agent-fake",
			"base_commit": "fake_base_commit",
		}
		_worktrees_by_thread[thread_id] = worktree
	var files: Array = payload.get("files", _sample_diff_files())
	worktree["files"] = files.duplicate(true)
	_worktrees_by_thread[thread_id] = worktree
	return _emit_diff(thread_id)


func _decide_diff(thread_id: String, payload: Dictionary) -> bool:
	var run_id := str(payload.get("run_id", ""))
	var decision := str(payload.get("decision", ""))
	if not _diffs_by_run.has(run_id) or decision not in ["apply", "reject"]:
		return false
	_diffs_by_run.erase(run_id)
	if worktree_exists_for_run(run_id):
		_worktrees_by_thread.erase(thread_id)
	if decision == "apply":
		_emit_event("diff.applied", thread_id, {
			"run_id": run_id,
			"decision": "apply",
			"branch": "spatial/agent-%s" % run_id,
			"commit": "fakecommit%s" % run_id.replace("run_", ""),
		})
	else:
		_emit_event("diff.rejected", thread_id, {
			"run_id": run_id,
			"decision": "reject",
			"branch": "spatial/agent-%s" % run_id,
		})
	if _threads_by_id.has(thread_id):
		var thread: Dictionary = _threads_by_id[thread_id]
		thread["updated_at"] = _timestamp()
		_threads_by_id[thread_id] = thread
		_emit_event("thread.updated", thread_id, {"thread": thread.duplicate(true)})
	return true


func worktree_exists_for_run(run_id: String) -> bool:
	for worktree_variant in _worktrees_by_thread.values():
		var worktree: Dictionary = worktree_variant
		if str(worktree.get("run_id", "")) == run_id:
			return true
	return false


func _sample_diff_files() -> Array:
	return [{
		"path": "services/agent_client.gd",
		"change": "modified",
		"additions": 3,
		"deletions": 1,
		"hunks": [{
			"header": "@@ -1,5 +1,7 @@",
			"old_start": 1,
			"new_start": 1,
			"lines": [
				" func route_agent_delta(event: BackendEvent) -> void:",
				'-    if event.type == "agent.message.delta":',
				"+    if event.sequence <= last_sequence:",
				"+        return",
				"+    transcript.append(event.delta)",
				'     status_changed.emit("streaming")',
			],
		}],
	}]


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
