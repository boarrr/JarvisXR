extends Node

signal connection_state_changed(value: String)
signal backend_mode_changed(value: String)
signal provider_identity_changed(provider_name: String, model_name: String)
signal session_changed(value: String)
signal focused_thread_changed(thread_id: String)
signal hovered_target_changed(target_id: String)
signal listening_state_changed(value: String)
signal transcript_changed(value: String)
signal ui_mode_changed(value: String)
signal update_banner_changed(value: String)
signal text_input_active_changed(value: bool)
signal approval_requested(request: Dictionary)
signal approval_resolved(approval_id: String)
signal thread_added(thread: AgentThread)
signal thread_updated(thread: AgentThread)
signal thread_removed(thread_id: String)
signal workspaces_changed(workspaces: Array)
signal run_workspace_changed(thread_id: String)
signal diff_changed(run_id: String)
signal diff_resolved(run_id: String)
signal file_tree_changed(thread_id: String)
signal file_content_changed(thread_id: String)
signal tool_catalog_changed()
signal pairing_changed(device_id: String, device_name: String)
signal orb_layout_changed(thread_id: String)
signal undo_changed(count: int)
signal hitbox_debug_changed(value: bool)

var connection_state: String = "offline":
	set(value):
		if connection_state == value:
			return
		connection_state = value
		connection_state_changed.emit(value)

var backend_mode: String = "fake":
	set(value):
		if backend_mode == value:
			return
		backend_mode = value
		backend_mode_changed.emit(value)

var provider_name: String = "fake"
var model_name: String = "local-deterministic"

var session_id: String = "":
	set(value):
		if session_id == value:
			return
		session_id = value
		session_changed.emit(value)

var focused_thread_id: String = "":
	set(value):
		if focused_thread_id == value:
			return
		focused_thread_id = value
		focused_thread_changed.emit(value)

var hovered_target_id: String = "":
	set(value):
		if hovered_target_id == value:
			return
		hovered_target_id = value
		hovered_target_changed.emit(value)

var listening_state: String = "idle":
	set(value):
		if listening_state == value:
			return
		listening_state = value
		listening_state_changed.emit(value)

var current_transcript: String = "":
	set(value):
		if current_transcript == value:
			return
		current_transcript = value
		transcript_changed.emit(value)

var palm_console_open := false
var update_banner := ""

var hitbox_debug_visible := false:
	set(value):
		if hitbox_debug_visible == value:
			return
		hitbox_debug_visible = value
		hitbox_debug_changed.emit(value)


func set_update_banner(value: String) -> void:
	if update_banner == value:
		return
	update_banner = value
	update_banner_changed.emit(value)
var ui_mode: String = "xr_hands":
	set(value):
		if ui_mode == value:
			return
		ui_mode = value
		ui_mode_changed.emit(value)

var text_input_active: bool = false:
	set(value):
		if text_input_active == value:
			return
		text_input_active = value
		text_input_active_changed.emit(value)

var threads_by_id: Dictionary = {}
var ordered_thread_ids: Array[String] = []
var approval_requests: Dictionary = {}
var workspaces: Array = []
var worktrees_by_thread: Dictionary = {}
var diffs_by_run: Dictionary = {}
var file_tree: Array = []
var file_tree_path: String = ""
var file_tree_thread_id: String = ""
var file_tree_scope: String = ""
var file_content: Dictionary = {}
var tool_catalog: Array = []
var mcp_servers: Array[String] = []
var paired_device: Dictionary = {}
var orb_offsets: Dictionary = {}
var orb_links: Dictionary = {}
var undo_stack: Array = []


func push_undo(
	thread_id: String,
	title: String,
	position: Variant,
	kind: String = "crush"
) -> void:
	# Physical undo: the last few crushed agents can be brought back.
	undo_stack.append({
		"thread_id": thread_id,
		"title": title,
		"position": position,
		"kind": kind,
	})
	while undo_stack.size() > 3:
		undo_stack.pop_front()
	undo_changed.emit(undo_stack.size())


func pop_undo() -> Dictionary:
	if undo_stack.is_empty():
		return {}
	var entry: Dictionary = undo_stack.pop_back()
	undo_changed.emit(undo_stack.size())
	return entry


func undo_count() -> int:
	return undo_stack.size()


func set_orb_offset(thread_id: String, position: Vector3) -> void:
	if thread_id.is_empty():
		return
	orb_offsets[thread_id] = position
	orb_layout_changed.emit(thread_id)


func clear_orb_offset(thread_id: String) -> void:
	if orb_offsets.erase(thread_id):
		orb_layout_changed.emit(thread_id)


func get_orb_offset(thread_id: String) -> Variant:
	return orb_offsets.get(thread_id)


func link_orbs(child_id: String, parent_id: String) -> bool:
	if child_id.is_empty() or parent_id.is_empty() or child_id == parent_id:
		return false
	var cursor := parent_id
	var guard := 0
	while not cursor.is_empty() and guard < 64:
		if cursor == child_id:
			return false
		cursor = str(orb_links.get(cursor, ""))
		guard += 1
	orb_links[child_id] = parent_id
	orb_offsets.erase(child_id)
	orb_layout_changed.emit(child_id)
	return true


func unlink_orb(child_id: String) -> bool:
	if orb_links.erase(child_id):
		orb_layout_changed.emit(child_id)
		return true
	return false


func get_orb_parent(thread_id: String) -> String:
	return str(orb_links.get(thread_id, ""))


func set_workspaces(values: Array) -> void:
	workspaces.clear()
	for value in values:
		if value is Dictionary:
			workspaces.append((value as Dictionary).duplicate(true))
	workspaces_changed.emit(workspaces)


func get_workspace(workspace_id: String) -> Dictionary:
	for workspace in workspaces:
		if str(workspace.get("id", "")) == workspace_id:
			return workspace
	return {}


func set_run_workspace(thread_id: String, payload: Dictionary) -> void:
	worktrees_by_thread[thread_id] = payload.duplicate(true)
	run_workspace_changed.emit(thread_id)


func get_run_workspace(thread_id: String) -> Dictionary:
	if not worktrees_by_thread.has(thread_id):
		return {}
	return (worktrees_by_thread[thread_id] as Dictionary).duplicate(true)


func set_diff(payload: Dictionary) -> void:
	var run_id := str(payload.get("run_id", ""))
	if run_id.is_empty():
		return
	diffs_by_run[run_id] = payload.duplicate(true)
	diff_changed.emit(run_id)


func get_diff(run_id: String) -> Dictionary:
	if not diffs_by_run.has(run_id):
		return {}
	return (diffs_by_run[run_id] as Dictionary).duplicate(true)


func get_latest_diff_for_thread(thread_id: String) -> Dictionary:
	for run_id in diffs_by_run.keys():
		var diff: Dictionary = diffs_by_run[run_id]
		if str(diff.get("thread_id", "")) == thread_id:
			return diff.duplicate(true)
	return {}


func resolve_diff(run_id: String, payload: Dictionary) -> void:
	if not diffs_by_run.has(run_id):
		return
	diffs_by_run.erase(run_id)
	diff_resolved.emit(run_id)
	EventBus.debug_message.emit(
		"Diff %s %s" % [run_id, str(payload.get("decision", "resolved"))]
	)


func set_file_tree(thread_id: String, path: String, entries: Array, scope: String = "") -> void:
	file_tree_thread_id = thread_id
	file_tree_path = path
	file_tree = entries.duplicate(true)
	file_tree_scope = scope
	file_tree_changed.emit(thread_id)


func set_file_content(thread_id: String, payload: Dictionary) -> void:
	file_content = payload.duplicate(true)
	file_content_changed.emit(thread_id)


func set_tool_catalog(payload: Dictionary) -> void:
	tool_catalog = (payload.get("tools", []) as Array).duplicate(true)
	mcp_servers.clear()
	for server in payload.get("mcp_servers", []):
		mcp_servers.append(str(server))
	tool_catalog_changed.emit()


func set_paired_device(device_id: String, device_name: String) -> void:
	paired_device = {"device_id": device_id, "device_name": device_name}
	pairing_changed.emit(device_id, device_name)


func set_provider_identity(provider: String, model: String) -> void:
	var normalized_provider := provider.strip_edges().to_lower()
	var normalized_model := model.strip_edges()
	if normalized_provider.is_empty():
		normalized_provider = "unknown"
	if normalized_model.is_empty():
		normalized_model = "unspecified"
	if provider_name == normalized_provider and model_name == normalized_model:
		return
	provider_name = normalized_provider
	model_name = normalized_model
	provider_identity_changed.emit(provider_name, model_name)


func add_thread(thread: AgentThread) -> bool:
	if thread == null or thread.id.is_empty():
		push_warning("[STATE] Ignored thread without a stable ID")
		return false

	var already_exists := threads_by_id.has(thread.id)
	threads_by_id[thread.id] = thread
	if not already_exists:
		ordered_thread_ids.append(thread.id)
		print("[STATE] add_thread %s (total=%d)" % [thread.id, ordered_thread_ids.size()])
		thread_added.emit(thread)
	else:
		thread_updated.emit(thread)
	return true


func get_thread(thread_id: String) -> AgentThread:
	return threads_by_id.get(thread_id) as AgentThread


func update_thread(thread: AgentThread) -> bool:
	if thread == null or not threads_by_id.has(thread.id):
		return false
	threads_by_id[thread.id] = thread
	thread.updated_at = Time.get_datetime_string_from_system(true, false)
	thread_updated.emit(thread)
	return true


func focus_thread(thread_id: String) -> bool:
	if not thread_id.is_empty() and not threads_by_id.has(thread_id):
		push_warning("[STATE] Cannot focus unknown thread: %s" % thread_id)
		return false
	focused_thread_id = thread_id
	if not thread_id.is_empty():
		var thread := threads_by_id.get(thread_id) as AgentThread
		if thread != null and thread.unread_count > 0:
			thread.unread_count = 0
			update_thread(thread)
	return true


func remove_thread(thread_id: String) -> bool:
	if not threads_by_id.has(thread_id):
		return false
	threads_by_id.erase(thread_id)
	ordered_thread_ids.erase(thread_id)
	orb_offsets.erase(thread_id)
	orb_links.erase(thread_id)
	for child_id in orb_links.keys():
		if str(orb_links[child_id]) == thread_id:
			orb_links.erase(child_id)
	if focused_thread_id == thread_id:
		focused_thread_id = ""
	if hovered_target_id == thread_id:
		hovered_target_id = ""
	var approval_ids_to_remove: Array[String] = []
	for approval_id_variant in approval_requests:
		var approval_id: String = approval_id_variant
		var request: Dictionary = approval_requests[approval_id]
		if str(request.get("thread_id", "")) == thread_id:
			approval_ids_to_remove.append(approval_id)
	for approval_id in approval_ids_to_remove:
		resolve_approval(approval_id)
	thread_removed.emit(thread_id)
	return true


func add_approval(request: Dictionary) -> bool:
	var approval_id := str(request.get("approval_id", ""))
	if approval_id.is_empty():
		return false
	approval_requests[approval_id] = request.duplicate(true)
	approval_requested.emit(approval_requests[approval_id])
	return true


func resolve_approval(approval_id: String) -> bool:
	if not approval_requests.has(approval_id):
		return false
	approval_requests.erase(approval_id)
	approval_resolved.emit(approval_id)
	return true


func get_next_approval() -> Dictionary:
	if approval_requests.is_empty():
		return {}
	var approval_id: String = approval_requests.keys().front()
	return (approval_requests[approval_id] as Dictionary).duplicate(true)
