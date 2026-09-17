class_name WorkspacePanel
extends CockpitPanel

var _body: RichTextLabel = null


func _init() -> void:
	panel_title = "COCKPIT // WORKSPACE"
	horizontal_offset = -0.62
	vertical_offset = 0.05


func _connect_state() -> void:
	AppState.workspaces_changed.connect(_on_state_changed)
	AppState.tool_catalog_changed.connect(_on_state_changed)
	AppState.run_workspace_changed.connect(_on_run_workspace_changed)
	AppState.thread_updated.connect(_on_thread_updated)
	AppState.focused_thread_changed.connect(_on_focused_thread_changed)


func _build_ui(root: Control) -> void:
	make_title(root, panel_title, "git worktree isolation · one branch per agent run")
	_body = make_body(root, Rect2(Vector2(22, 80), Vector2(viewport_size.x - 44, viewport_size.y - 104)))


func refresh() -> void:
	if _body == null:
		return
	var lines: PackedStringArray = []
	lines.append("[color=#55f5ff]WORKSPACES[/color]")
	if AppState.workspaces.is_empty():
		lines.append("[color=#6b9aa5]No workspaces are registered on this daemon.[/color]")
	else:
		for workspace in AppState.workspaces:
			var workspace_id := str(workspace.get("id", ""))
			lines.append(
				"• [b]%s[/b]  [color=#6b9aa5]%s · %s[/color]   [color=#55f5ff]%s[/color]"
				% [
					workspace.get("name", workspace_id),
					workspace.get("path", ""),
					workspace.get("base_branch", "main"),
					workspace_id,
				]
			)
	var thread := AppState.get_thread(AppState.focused_thread_id)
	lines.append("")
	lines.append("[color=#55f5ff]FOCUSED THREAD[/color]")
	if thread == null:
		lines.append("[color=#6b9aa5]No thread is focused.[/color]")
	else:
		var bound_id := str(thread.metadata.get("workspace_id", ""))
		var bound := AppState.get_workspace(bound_id)
		if bound.is_empty():
			lines.append(
				"[color=#6b9aa5]%s is not bound; runs stay in the simulator.[/color]"
				% thread.title
			)
		else:
			lines.append("• %s → [b]%s[/b]" % [thread.title, bound.get("name", bound_id)])
		var worktree := AppState.get_run_workspace(thread.id)
		if not worktree.is_empty():
			lines.append(
				"• branch [color=#55f5ff]%s[/color]  base %s"
				% [
					str(worktree.get("branch", "")),
					str(worktree.get("base_commit", "")).left(10),
				]
			)
	lines.append("")
	lines.append("[color=#55f5ff]MCP SERVERS[/color]")
	if AppState.mcp_servers.is_empty():
		lines.append("[color=#6b9aa5]No MCP servers are connected.[/color]")
	else:
		for server in AppState.mcp_servers:
			var tool_count := 0
			for tool in AppState.tool_catalog:
				if str(tool.get("server_id", "")) == str(server):
					tool_count += 1
			lines.append("• %s  [color=#6b9aa5](%d tools)[/color]" % [server, tool_count])
	_body.text = "\n".join(lines)


func _on_state_changed(_value: Variant = null) -> void:
	if visible:
		refresh()


func _on_run_workspace_changed(_thread_id: String) -> void:
	if visible:
		refresh()


func _on_thread_updated(_thread: AgentThread) -> void:
	if visible:
		refresh()


func _on_focused_thread_changed(_thread_id: String) -> void:
	if visible:
		refresh()
