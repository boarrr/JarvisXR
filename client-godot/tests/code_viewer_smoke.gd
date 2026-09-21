extends Node

var _failed := false


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	var main := (load("res://scenes/app/main.tscn") as PackedScene).instantiate()
	add_child(main)
	var viewer := main.get_node("CodeViewer") as CodeViewer
	var source := (main.get_node("UserRig") as UserRig).get_interaction_source()
	var code_orb := (main.get_node("OrbManager") as OrbManager).get_orb("thread_debug_03")
	_check(viewer != null and not viewer.is_open(), "code viewer starts closed")
	_check(code_orb.get_node("VisualRoot/TickRing").multimesh.instance_count == 36, "orb exposes calibrated holographic ticks")
	_check(code_orb.get_node("VisualRoot/StatusSegments").multimesh.instance_count == 14, "orb exposes segmented status arc")
	_check(AppState.focus_thread("thread_debug_03"), "code agent can be focused")

	var toggle_event := InputEventAction.new()
	toggle_event.action = "code_view_toggle"
	toggle_event.pressed = true
	source._input(toggle_event)
	_check(viewer.is_open(), "semantic code toggle opens a world-space viewer")
	_check(viewer.get_rendered_code().contains("func route_agent_delta"), "viewer extracts fenced agent code")
	_check(viewer.get_rendered_code().contains("last_sequence"), "viewer preserves code content")
	_check(not viewer.get_diff_sculptor().visible, "ordinary code does not create a misleading diff sculpture")
	_check(viewer.get_node("SurfaceTarget").get_interaction_target_id() == "ui:code_surface", "code surface is a hand-ray pinch-drag target")
	var thread_panel := main.get_node("ThreadPanel") as ThreadPanel
	# The transcript panel no longer auto-presents on focus; open it explicitly
	# so its collapsed-code rendering and targets are covered.
	thread_panel.open_thread("thread_debug_03")
	var expected_lines := viewer.get_rendered_code().count("\n") + 1
	_check(expected_lines > 60, "offline demo is long enough to exercise scrolling")
	_check(thread_panel.get_rendered_body_text().contains("[CODE TRACE // GDSCRIPT // %02d LINES]" % expected_lines), "transcript collapses code duplicated by the spatial viewer")
	_check(thread_panel.get_node("CodeTraceTarget").get_interaction_target_id() == "ui:code_toggle", "transcript exposes a world-space code pinch target")
	_check(thread_panel.get_node("DismissTarget").get_interaction_target_id() == "ui:dismiss", "transcript exposes a world-space dismiss pinch target")
	var start_scale := viewer.scale
	var transform_center := viewer.global_position + Vector3(0.2, 0.0, 0.0)
	_check(viewer.begin_bimanual_transform(transform_center), "two-hand manipulation can claim the open code surface")
	_check(viewer.apply_bimanual_transform(transform_center, 1.25, 0.12), "two-hand distance and yaw update the code surface")
	_check(viewer.scale.x > start_scale.x, "two-hand spread scales the entire floating viewer")
	viewer.end_bimanual_transform()
	_check(not viewer.is_being_manipulated(), "releasing either hand ends manipulation")

	var focused_thread := AppState.get_thread("thread_debug_03")
	focused_thread.add_message(AgentMessage.new(
		"msg_diff",
		focused_thread.id,
		AgentMessage.Role.ASSISTANT,
		"```diff\n--- a/agent.gd\n+++ b/agent.gd\n-old_route()\n+safe_route()\n context\n```"
	))
	AppState.update_thread(focused_thread)
	var sculpture := viewer.get_diff_sculptor()
	_check(sculpture.visible, "a fenced diff becomes a spatial change sculpture")
	_check(sculpture.get_added_count() == 1 and sculpture.get_removed_count() == 1, "additions and removals occupy distinct holographic lanes")
	_check(sculpture.get_bar_count() <= 48, "diff geometry is bounded for standalone headset rendering")

	for action in ["code_scroll_up", "code_scroll_down", "code_go_top", "code_go_bottom"]:
		_check(InputMap.has_action(action), "code viewer action exists: %s" % action)
	var scroll_event := InputEventAction.new()
	scroll_event.action = "code_scroll_down"
	scroll_event.pressed = true
	source._input(scroll_event)
	source._input(toggle_event)
	_check(not viewer.is_open(), "semantic code toggle closes the viewer")

	if not _failed:
		print("[TEST] Holographic orb and Vim code viewer checks passed")
	main.queue_free()
	get_tree().quit(1 if _failed else 0)


func _check(condition: bool, description: String) -> void:
	if condition:
		return
	_failed = true
	push_error("[TEST] Failed: %s" % description)
