extends Node

var _failed := false


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	var main_scene := load("res://scenes/app/main.tscn") as PackedScene
	var main := main_scene.instantiate()
	add_child(main)
	var router := main.get_node("CommandRouter") as CommandRouter
	var composer := main.get_node("DesktopComposer") as DesktopComposer
	var approval_panel := main.get_node("ApprovalPanel") as ApprovalPanel
	var code_viewer := main.get_node("CodeViewer") as CodeViewer
	var transport := main.get_node("BackendBridge/FakeBackendTransport") as FakeBackendTransport
	var source := (main.get_node("UserRig") as UserRig).get_interaction_source()

	_check(router != null and composer != null, "desktop command workflow is composed")
	_check(InputMap.has_action("message_compose"), "message composer action exists")
	_check(InputMap.has_action("approval_accept") and InputMap.has_action("approval_deny"), "approval actions exist")

	AppState.focus_thread("thread_demo")
	transport.advance_streams(10.0)
	_check(not composer.get_node("Panel").visible, "composer stays hidden until explicitly summoned")
	_check(composer.begin_editing(), "composer enters text mode")
	_check(composer.get_node("Panel").visible, "summoning the composer reveals desktop text input")
	_check(AppState.text_input_active and composer.is_editing(), "text mode suppresses spatial input")
	composer.set_draft("A typed follow-up")
	composer._submit_current_text()
	_check(not AppState.text_input_active and composer.get_draft().is_empty(), "successful submit exits text mode")
	_check(transport.get_active_stream_count() == 1, "typed message starts a transport run")
	transport.advance_streams(10.0)
	_check(AppState.get_thread("thread_demo").messages.back().content.contains("typed follow-up"), "typed message streams a reply")

	_check(router.submit_text("/new Workflow"), "create command is accepted")
	var created_id: String = AppState.ordered_thread_ids.back()
	_check(AppState.get_thread(created_id).title == "Workflow", "create command adds the named thread")
	_check(router.submit_text("/focus Workflow"), "focus command resolves by title")
	_check(AppState.focused_thread_id == created_id, "focus command updates focus")
	_check(router.submit_text("/rename Workflow Renamed"), "rename command is accepted")
	_check(AppState.get_thread(created_id).title == "Workflow Renamed", "rename event updates the thread")
	_check(router.submit_text("/cancel"), "cancel command stops the focus-triggered run")
	_check(transport.get_active_stream_count() == 0, "cancel releases the fake run")
	_check(code_viewer.open_focused_thread(), "code surface can be present before an approval")

	_check(router.submit_text("/tool remember milk"), "tool request is accepted")
	_check(AppState.approval_requests.size() == 1, "tool request creates authoritative approval state")
	_check(approval_panel.is_open(), "approval request opens the spatial confirmation panel")
	var impact := approval_panel.get_impact_preview()
	_check(impact.get_route_node_count() == 3, "approval renders a bounded ghost-future action route")
	_check(not impact.is_external_impact(), "ghost future marks the simulated write as local-only")
	_check(not impact.get_description().contains("remember milk"), "ghost future never repeats sensitive tool arguments")
	_check(not code_viewer.visible and not composer.visible, "approval mode hides lower-priority work surfaces")
	_check(approval_panel.get_node("ApproveTarget").get_interaction_target_id() == "approval:approve", "approval exposes a world-space pinch target")
	_check(approval_panel.get_node("DenyTarget").get_interaction_target_id() == "approval:deny", "denial exposes a world-space pinch target")
	var approval_id := approval_panel.get_approval_id()
	main._on_interaction_event(InteractionEvent.new(
		InteractionEvent.Type.SELECT,
		"approval:approve",
		InteractionEvent.Source.HAND,
		null,
		{"gesture": "explicit_pinch"}
	))
	_check(not AppState.approval_requests.has(approval_id), "hand pinch approve resolves the request")
	_check(not approval_panel.is_open(), "approval panel closes after resolution")
	_check(code_viewer.visible and composer.visible, "work surfaces restore after the modal resolves")
	_check(AppState.get_thread(created_id).status == AgentThread.Status.COMPLETE, "approved tool reaches COMPLETE")
	_check(AppState.get_thread(created_id).messages.back().role == AgentMessage.Role.TOOL, "approved tool result enters transcript")

	_check(router.submit_text("/tool second request"), "second tool request is accepted")
	var deny_event := InputEventAction.new()
	deny_event.action = "approval_deny"
	deny_event.pressed = true
	source._input(deny_event)
	_check(AppState.approval_requests.is_empty(), "semantic deny resolves the request")
	_check(AppState.get_thread(created_id).status == AgentThread.Status.IDLE, "denied tool returns to IDLE")

	_check(router.submit_text("Voice transcript simulation", true), "voice transcript routes to the focused thread")
	transport.advance_streams(10.0)
	_check(
		AppState.get_thread(created_id).messages[-2].content == "Voice transcript simulation",
		"voice transcript is preserved as a user message"
	)

	var previous_focus := AppState.focused_thread_id
	var focus_event := InputEventAction.new()
	focus_event.action = "focus_next"
	focus_event.pressed = true
	source._input(focus_event)
	_check(AppState.focused_thread_id != previous_focus, "semantic focus-next cycles threads")
	AppState.focus_thread(created_id)
	_check(router.submit_text("/archive"), "explicit archive command is accepted")
	_check(AppState.get_thread(created_id) == null, "archive removes the thread")

	if not _failed:
		print("[TEST] Command, composer, and approval checks passed")
	main.queue_free()
	get_tree().quit(1 if _failed else 0)


func _check(condition: bool, description: String) -> void:
	if condition:
		return
	_failed = true
	push_error("[TEST] Failed: %s" % description)
