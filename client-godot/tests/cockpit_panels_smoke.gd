extends Node

var _failed := false


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	var main_scene := load("res://scenes/app/main.tscn") as PackedScene
	var main := main_scene.instantiate()
	add_child(main)

	var bridge := main.get_node("BackendBridge") as BackendBridge
	var transport := main.get_node("BackendBridge/FakeBackendTransport") as FakeBackendTransport
	var workspace_panel := main.get_node("WorkspacePanel") as WorkspacePanel
	var diff_panel := main.get_node("DiffReviewPanel") as DiffReviewPanel
	var file_viewer := main.get_node("FileViewer") as FileViewer
	var daemon_panel := main.get_node("DaemonSettingsPanel") as DaemonSettingsPanel

	_check(workspace_panel != null, "workspace panel composes into Main")
	_check(diff_panel != null, "diff review panel composes into Main")
	_check(file_viewer != null, "file viewer composes into Main")
	_check(daemon_panel != null, "daemon settings panel composes into Main")
	_check(not workspace_panel.visible, "cockpit panels start closed")

	_check(AppState.focus_thread("thread_demo"), "demo thread can be focused")
	transport.advance_streams(10.0)
	var worktree := AppState.get_run_workspace("thread_demo")
	_check(not worktree.is_empty(), "demo run exposes a worktree")
	var run_id := str(worktree.get("run_id", ""))
	_check(bridge.send_command("diff.get", {}, "thread_demo"), "diff.get reaches the fake transport")
	_check(not AppState.get_diff(run_id).is_empty(), "pending diff is available to panels")

	_check(workspace_panel.toggle(), "workspace panel opens")
	_check(workspace_panel.visible, "workspace panel is visible")
	workspace_panel.refresh()
	var workspace_text := workspace_panel.get_body_text()
	_check(workspace_text.contains("Demo Workspace"), "workspace panel lists registered workspaces")
	_check(workspace_text.contains("spatial/agent-"), "workspace panel reports the active branch")
	_check(workspace_text.contains("demo.filesystem"), "workspace panel lists MCP servers")

	_check(diff_panel.open_focused_thread(), "diff review opens for the focused thread")
	diff_panel.refresh()
	var diff_text := diff_panel.get_body_text()
	_check(diff_text.contains(run_id), "diff review shows the pending run")
	_check(diff_text.contains("services/agent_client.gd"), "diff review lists changed files")
	_check(diff_text.contains("+"), "diff review renders hunk lines")
	_check(diff_panel.get_run_id() == run_id, "diff review tracks the pending run")
	_check(diff_panel.decide("reject"), "diff reject is dispatched")
	_check(AppState.get_diff(run_id).is_empty(), "reject clears review state")
	_check(diff_panel.get_run_id().is_empty(), "panel resets after resolution")

	_check(file_viewer.open_focused_thread(), "file viewer opens")
	var rows := file_viewer.get_rows()
	_check(rows.size() >= 3, "file viewer shows workspace entries")
	_check(file_viewer.activate_entry("services", true), "directory navigation is accepted")
	rows = file_viewer.get_rows()
	_check(rows.size() == 2, "directory listing updates")
	_check(file_viewer.activate_entry("services/agent_client.gd", false), "file read is accepted")
	_check(file_viewer.is_showing_content(), "file viewer switches to content mode")
	_check(file_viewer.get_body_text().contains("route_agent_delta"), "file content renders")

	_check(daemon_panel.toggle(), "daemon panel opens")
	daemon_panel.refresh()
	var daemon_text := daemon_panel.get_body_text()
	_check(daemon_text.contains("fake"), "daemon panel reports the link mode")
	_check(daemon_text.contains("open loopback"), "daemon panel reports authorization state")

	daemon_panel.handle_action("daemon:pair_mode")
	daemon_panel.refresh()
	_check(
		daemon_panel.get_body_text().contains("PAIR THIS HEADSET"),
		"pairing mode shows the code entry surface"
	)
	daemon_panel.handle_action("daemon:key:A")
	daemon_panel.handle_action("daemon:key:2")
	_check(
		daemon_panel.get_body_text().contains("A 2"),
		"poked keypad characters appear in the code"
	)
	daemon_panel.handle_action("daemon:pair_cancel")
	_check(
		not daemon_panel.get_body_text().contains("PAIR THIS HEADSET"),
		"cancelling pairing returns to the daemon status page"
	)

	_check(
		bridge.send_command("debug.approval.request", {"tool_name": "demo.safe_tool"}, "thread_demo"),
		"approval request can be injected"
	)
	_check(
		not workspace_panel.visible and not file_viewer.visible and not daemon_panel.visible,
		"approval gate hides cockpit panels"
	)
	var approval := AppState.get_next_approval()
	if not approval.is_empty():
		bridge.send_command(
			"approval.respond",
			{"approval_id": str(approval.get("approval_id", "")), "decision": "deny"},
			"thread_demo"
		)

	_check(workspace_panel.toggle(), "workspace panel reopens after approval")

	if not _failed:
		print("[TEST] Cockpit panel checks passed")
	main.queue_free()
	get_tree().quit(1 if _failed else 0)


func _check(condition: bool, description: String) -> void:
	if condition:
		return
	_failed = true
	push_error("[TEST] Failed: %s" % description)
