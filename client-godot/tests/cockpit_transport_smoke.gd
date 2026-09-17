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

	_check(AppState.workspaces.size() == 1, "fake workspace snapshot populates AppState")
	_check(str(AppState.workspaces[0].get("id", "")) == "ws_demo", "demo workspace identity")
	_check(AppState.mcp_servers.size() == 1, "MCP server list crosses the transport boundary")
	_check(str(AppState.mcp_servers[0]) == "demo.filesystem", "MCP server identity is preserved")
	_check(not AppState.tool_catalog.is_empty(), "tool catalog is available offline")

	_check(AppState.focus_thread("thread_demo"), "demo thread can be focused")
	transport.advance_streams(10.0)
	var worktree := AppState.get_run_workspace("thread_demo")
	_check(not worktree.is_empty(), "bound thread receives a run worktree")
	var run_id := str(worktree.get("run_id", ""))
	_check(run_id.begins_with("run_"), "worktree carries the run identity")
	_check(str(worktree.get("branch", "")).begins_with("spatial/agent-"), "worktree branch is namespaced")

	_check(bridge.send_command("diff.get", {}, "thread_demo"), "diff.get is accepted")
	var diff := AppState.get_diff(run_id)
	_check(not diff.is_empty(), "diff.proposed reaches AppState")
	var files: Array = diff.get("files", [])
	_check(files.size() == 1, "sample diff has one file")
	_check(str((files[0] as Dictionary).get("change", "")) == "modified", "diff change classification")
	var hunks: Array = (files[0] as Dictionary).get("hunks", [])
	_check(hunks.size() == 1, "diff hunks cross the boundary")

	_check(bridge.send_command("file.list", {}, "thread_demo"), "file.list is accepted")
	_check(AppState.file_tree.size() >= 2, "file tree entries arrive")
	_check(bridge.send_command("file.read", {"path": "services/agent_client.gd"}, "thread_demo"), "file.read is accepted")
	_check(
		str(AppState.file_content.get("content", "")).contains("route_agent_delta"),
		"file content is readable"
	)

	_check(
		bridge.send_command("diff.decision", {"run_id": run_id, "decision": "reject"}, "thread_demo"),
		"diff.decision is accepted"
	)
	_check(AppState.get_diff(run_id).is_empty(), "rejected diff leaves review state")

	var unbound_thread := AppState.get_thread("thread_debug_02")
	_check(unbound_thread != null, "unbound thread exists")
	_check(AppState.get_run_workspace("thread_debug_02").is_empty(), "unbound thread has no worktree")

	_check(
		bridge.send_command("workspace.bind", {"workspace_id": "ws_demo"}, "thread_debug_02"),
		"workspace.bind is accepted"
	)
	_check(
		str(unbound_thread.metadata.get("workspace_id", "")) == "ws_demo",
		"workspace binding lands in thread metadata"
	)
	_check(
		bridge.send_command("message.send", {"content": "Bound run"}, "thread_debug_02"),
		"bound run starts"
	)
	transport.advance_streams(10.0)
	_check(
		not AppState.get_run_workspace("thread_debug_02").is_empty(),
		"bound run receives a worktree"
	)

	if not _failed:
		print("[TEST] Cockpit transport smoke checks passed")
	main.queue_free()
	get_tree().quit(1 if _failed else 0)


func _check(condition: bool, description: String) -> void:
	if condition:
		return
	_failed = true
	push_error("[TEST] Failed: %s" % description)
