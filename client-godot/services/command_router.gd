class_name CommandRouter
extends Node

signal feedback(message: String)

@export var backend_bridge_path: NodePath = ^"../BackendBridge"

var _last_feedback: String = ""


func submit_text(raw_text: String, as_voice: bool = false) -> bool:
	var text := raw_text.strip_edges()
	if text.is_empty():
		return _report(false, "Nothing to send")
	if text.begins_with("/"):
		return _route_command(text)
	var thread_id := AppState.focused_thread_id
	if thread_id.is_empty():
		return _report(false, "Focus a thread before sending a message")
	var bridge := _get_backend_bridge()
	if bridge == null:
		return _report(false, "Backend bridge is unavailable")
	var accepted := false
	if as_voice:
		accepted = bridge.send_command("voice.transcript.final", {"transcript": text}, thread_id)
	else:
		accepted = bridge.send_command("message.send", {"content": text}, thread_id)
	return _report(accepted, "Sent to %s" % _thread_label(thread_id) if accepted else "Message was not accepted")


func get_last_feedback() -> String:
	return _last_feedback


func get_help_text() -> String:
	return (
		"/new TITLE · /focus NAME · /rename TITLE · /archive · /cancel · /list\n"
		+ "/pair CODE · /workspaces · /workspace NAME · /files · /diff · /daemon\n"
		+ "/apply · /reject · /tools · /tool status|clock|note · /mission GOAL"
	)


func _route_command(text: String) -> bool:
	var parts := text.split(" ", false, 1)
	var command := parts[0].to_lower()
	var argument := parts[1].strip_edges() if parts.size() > 1 else ""
	var bridge := _get_backend_bridge()
	if bridge == null:
		return _report(false, "Backend bridge is unavailable")

	match command:
		"/help":
			return _report(true, get_help_text())
		"/list":
			var titles := PackedStringArray()
			for thread_id in AppState.ordered_thread_ids:
				titles.append(_thread_label(thread_id))
			return _report(true, "Threads: %s" % ", ".join(titles))
		"/new":
			var title := argument if not argument.is_empty() else "New thread"
			return _report(
				bridge.send_command("thread.create", {"title": title}),
				"Creating thread: %s" % title
			)
		"/focus":
			var focus_id := _resolve_thread(argument)
			if focus_id.is_empty():
				return _report(false, "No matching thread")
			return _report(AppState.focus_thread(focus_id), "Focused: %s" % _thread_label(focus_id))
		"/rename":
			if AppState.focused_thread_id.is_empty() or argument.is_empty():
				return _report(false, "Usage: /rename NEW TITLE")
			return _report(
				bridge.send_command("thread.rename", {"title": argument}, AppState.focused_thread_id),
				"Renaming focused thread"
			)
		"/archive":
			var archive_id := _resolve_thread(argument) if not argument.is_empty() else AppState.focused_thread_id
			if archive_id.is_empty():
				return _report(false, "Focus or name a thread to archive")
			return _report(
				bridge.send_command("thread.archive", {}, archive_id),
				"Archived: %s" % _thread_label(archive_id)
			)
		"/cancel":
			var cancel_id := _resolve_thread(argument) if not argument.is_empty() else AppState.focused_thread_id
			if cancel_id.is_empty():
				return _report(false, "Focus or name a thread to cancel")
			return _report(
				bridge.send_command("run.cancel", {}, cancel_id),
				"Cancel requested: %s" % _thread_label(cancel_id)
			)
		"/tool":
			if AppState.focused_thread_id.is_empty():
				return _report(false, "Focus a thread before requesting a tool")
			return _report(
				bridge.send_command("message.send", {"content": text}, AppState.focused_thread_id),
				"Approval-gated tool requested"
			)
		"/mission":
			if argument.is_empty():
				return _report(false, "Usage: /mission GOAL")
			return _report(
				bridge.send_command("mission.create", {"goal": argument, "agent_count": 3}),
				"Fleet launched for: %s" % argument
			)
		"/pair":
			if argument.is_empty():
				return _report(false, "Usage: /pair CODE")
			var pair_transport = ServiceRegistry.backend_transport
			if pair_transport == null or not pair_transport.has_method("pair"):
				return _report(false, "The active transport does not support pairing")
			return _report(
				bool(pair_transport.call("pair", argument)),
				"Pairing requested for this device"
			)
		"/workspaces":
			EventBus.cockpit_panel_requested.emit("workspace")
			return _report(true, "Workspace panel toggled")
		"/workspace":
			if argument.is_empty():
				EventBus.cockpit_panel_requested.emit("workspace")
				return _report(true, "Workspace panel toggled")
			if AppState.focused_thread_id.is_empty():
				return _report(false, "Focus a thread before binding a workspace")
			var workspace := _resolve_workspace(argument)
			if workspace.is_empty():
				return _report(false, "No matching workspace")
			return _report(
				bridge.send_command(
					"workspace.bind",
					{"workspace_id": str(workspace.get("id", ""))},
					AppState.focused_thread_id
				),
				"Bound workspace: %s" % str(workspace.get("name", ""))
			)
		"/files":
			EventBus.cockpit_panel_requested.emit("files")
			return _report(true, "File viewer toggled")
		"/diff":
			EventBus.cockpit_panel_requested.emit("diff")
			return _report(true, "Diff review toggled")
		"/daemon":
			EventBus.cockpit_panel_requested.emit("daemon")
			return _report(true, "Daemon panel toggled")
		"/apply", "/reject":
			if AppState.focused_thread_id.is_empty():
				return _report(false, "Focus a thread before deciding a diff")
			var pending := AppState.get_latest_diff_for_thread(AppState.focused_thread_id)
			if pending.is_empty():
				return _report(false, "No pending diff for the focused thread")
			var decision := "apply" if command == "/apply" else "reject"
			return _report(
				bridge.send_command(
					"diff.decision",
					{"run_id": str(pending.get("run_id", "")), "decision": decision},
					AppState.focused_thread_id
				),
				"Diff %s requested" % decision
			)
		"/tools":
			bridge.send_command("tool.catalog", {})
			return _report(
				true,
				"Tool catalog: %d tools · %d MCP servers" % [
					AppState.tool_catalog.size(), AppState.mcp_servers.size()
				]
			)
		_:
			return _report(false, "Unknown command. Use /help")


func _resolve_workspace(query: String) -> Dictionary:
	var normalized := query.strip_edges().to_lower()
	if normalized.is_empty():
		return {}
	for workspace in AppState.workspaces:
		if str(workspace.get("id", "")).to_lower() == normalized:
			return workspace
	for workspace in AppState.workspaces:
		if str(workspace.get("name", "")).to_lower() == normalized:
			return workspace
	for workspace in AppState.workspaces:
		if normalized in str(workspace.get("name", "")).to_lower():
			return workspace
	return {}


func _resolve_thread(query: String) -> String:
	var normalized := query.strip_edges().to_lower()
	if normalized.is_empty():
		return ""
	for thread_id in AppState.ordered_thread_ids:
		var thread := AppState.get_thread(thread_id)
		if thread_id.to_lower() == normalized or (thread != null and thread.title.to_lower() == normalized):
			return thread_id
	for thread_id in AppState.ordered_thread_ids:
		var thread := AppState.get_thread(thread_id)
		if normalized in thread_id.to_lower() or (thread != null and normalized in thread.title.to_lower()):
			return thread_id
	return ""


func _thread_label(thread_id: String) -> String:
	var thread := AppState.get_thread(thread_id)
	return thread.title if thread != null else thread_id


func _get_backend_bridge() -> BackendBridge:
	return get_node_or_null(backend_bridge_path) as BackendBridge


func _report(success: bool, message: String) -> bool:
	_last_feedback = message
	feedback.emit(message)
	EventBus.debug_message.emit(message)
	return success
