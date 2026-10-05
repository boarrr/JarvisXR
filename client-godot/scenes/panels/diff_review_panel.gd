class_name DiffReviewPanel
extends CockpitPanel

@export var backend_bridge_path: NodePath = ^"../BackendBridge"

var _body: RichTextLabel = null
var _pending_thread_id: String = ""
var _run_id: String = ""


func _init() -> void:
	panel_title = "AGENT // CHANGES"
	horizontal_offset = 0.0
	vertical_offset = 0.02


func _connect_state() -> void:
	AppState.diff_changed.connect(_on_diff_changed)
	AppState.diff_resolved.connect(_on_diff_resolved)


func _build_ui(root: Control) -> void:
	make_title(root, panel_title, "agent changes stay on an isolated branch until you decide")
	_body = make_body(root, Rect2(Vector2(22, 80), Vector2(viewport_size.x - 44, 330)))
	make_button(root, Rect2(Vector2(56, 424), Vector2(300, 52)), "APPLY // COMMIT BRANCH", "diff:apply", COLOR_ADDED)
	make_button(root, Rect2(Vector2(404, 424), Vector2(300, 52)), "REJECT // DISCARD", "diff:reject", COLOR_REMOVED)


func open_focused_thread() -> bool:
	var thread := AppState.get_thread(AppState.focused_thread_id)
	if thread == null:
		return false
	_pending_thread_id = thread.id
	_run_id = ""
	var bridge := _backend_bridge()
	if bridge != null:
		bridge.send_command("diff.get", {}, thread.id)
	return open()


func decide(decision: String) -> bool:
	if _run_id.is_empty() or _pending_thread_id.is_empty():
		return false
	var bridge := _backend_bridge()
	if bridge == null:
		return false
	var accepted := bridge.send_command(
		"diff.decision",
		{"run_id": _run_id, "decision": decision},
		_pending_thread_id
	)
	if accepted:
		EventBus.debug_message.emit("Diff %s requested for %s" % [decision, _run_id])
	return accepted


func get_run_id() -> String:
	return _run_id


func refresh() -> void:
	if _body == null:
		return
	if _run_id.is_empty():
		_render_empty()
		return
	var diff := AppState.get_diff(_run_id)
	if diff.is_empty():
		_run_id = ""
		_render_empty()
		return
	_render_diff(diff)


func _render_empty() -> void:
	_body.text = (
		"[color=#6b9aa5]No changes to review yet.[/color]\n\n"
		+ "Ask this agent to edit a file, then tap [b]REVIEW[/b] again. Agent edits "
		+ "stay in an isolated worktree until you APPLY or REJECT."
	)


func _render_diff(diff: Dictionary) -> void:
	var lines: PackedStringArray = []
	lines.append(
		"run [color=#55f5ff]%s[/color]   workspace [b]%s[/b]"
		% [str(diff.get("run_id", "")), str(diff.get("workspace_id", ""))]
	)
	lines.append("")
	var files: Array = diff.get("files", [])
	if files.is_empty():
		lines.append("[color=#6b9aa5]The worktree is clean; there are no changes to review.[/color]")
	else:
		for file_variant in files:
			var file: Dictionary = file_variant
			lines.append(
				"[b]%s[/b]  [color=#6b9aa5]%s[/color]  [color=#7bf58f]+%d[/color] [color=#f97a6d]-%d[/color]"
				% [
					str(file.get("path", "")),
					str(file.get("change", "modified")),
					int(file.get("additions", 0)),
					int(file.get("deletions", 0)),
				]
			)
			for hunk_variant in file.get("hunks", []):
				var hunk: Dictionary = hunk_variant
				for line_variant in hunk.get("lines", []):
					lines.append(_colorize(str(line_variant)))
			lines.append("")
	if bool(diff.get("truncated", false)):
		lines.append("[color=#ffd166]Preview truncated; the full diff stays on the daemon.[/color]")
	_body.text = "\n".join(lines)


func _colorize(line: String) -> String:
	var escaped := line.replace("[", "[lb]")
	if line.begins_with("+"):
		return "[color=#7bf58f]%s[/color]" % escaped
	if line.begins_with("-"):
		return "[color=#f97a6d]%s[/color]" % escaped
	return escaped


func _on_diff_changed(run_id: String) -> void:
	var diff := AppState.get_diff(run_id)
	if _pending_thread_id.is_empty():
		return
	if str(diff.get("thread_id", "")) != _pending_thread_id:
		return
	_run_id = run_id
	if not visible:
		_place_in_reading_zone()
		visible = true
	refresh()


func _on_diff_resolved(run_id: String) -> void:
	if run_id == _run_id:
		_run_id = ""
		refresh()


func _backend_bridge() -> BackendBridge:
	return get_node_or_null(backend_bridge_path) as BackendBridge
