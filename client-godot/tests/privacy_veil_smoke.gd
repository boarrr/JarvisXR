extends Node

var _failed := false


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	var main := (load("res://scenes/app/main.tscn") as PackedScene).instantiate()
	add_child(main)
	var viewer := main.get_node("CodeViewer") as CodeViewer
	var cognition := main.get_node("CognitionLayer") as CognitionLayer
	var mission := main.get_node("MissionTopology") as MissionTopology
	var veil := main.get_node("PrivacyVeil") as PrivacyVeil
	_check(AppState.focus_thread("thread_debug_03"), "privacy test can focus sensitive work")
	_check(viewer.open_focused_thread(), "code is visible before privacy mode")
	mission.toggle_enabled()
	cognition._process(0.1)
	var focus_before := AppState.focused_thread_id
	var privacy_event := InteractionEvent.new(
		InteractionEvent.Type.SELECT,
		"palm:privacy_toggle",
		InteractionEvent.Source.HAND,
		null,
		{"gesture": "pinch"}
	)
	main._on_interaction_event(privacy_event)
	_check(AppState.privacy_veil_active and veil.is_active(), "one palm pinch activates the privacy veil")
	_check(not main.get_node("OrbManager").visible, "privacy veil conceals agent identities")
	_check(not viewer.visible and not main.get_node("ThreadPanel").visible, "privacy veil conceals transcript and code")
	_check(not cognition.visible and not mission.visible, "privacy veil suppresses derived cognition geometry")
	_check(not veil.get_display_text().contains("route_agent_delta"), "veil itself contains no sensitive workspace text")
	main._on_interaction_event(InteractionEvent.new(
		InteractionEvent.Type.SELECT,
		"palm:focus_next",
		InteractionEvent.Source.HAND
	))
	_check(AppState.focused_thread_id == focus_before, "non-privacy hand actions are locked while veiled")
	var privacy_target := main.get_node("PalmConsole/PrivacyTarget") as SpatialActionTarget
	_check(privacy_target.target_id == "palm:privacy_toggle", "privacy veil remains reachable from the hand-only palm console")
	main._on_interaction_event(privacy_event)
	_check(not AppState.privacy_veil_active and not veil.is_active(), "a second deliberate pinch clears the veil")
	_check(main.get_node("OrbManager").visible and viewer.visible, "agent field and prior code surface restore after clearing")
	_check(cognition.visible and mission.visible, "derived spatial layers restore to their prior enabled modes")

	var router := main.get_node("CommandRouter") as CommandRouter
	var approval_panel := main.get_node("ApprovalPanel") as ApprovalPanel
	(main.get_node("BackendBridge/FakeBackendTransport") as FakeBackendTransport).advance_streams(10.0)
	_check(router.submit_text("/tool highly sensitive words"), "privacy test can open the consent gate")
	_check(approval_panel.is_open(), "consent gate is visible before emergency concealment")
	main._on_interaction_event(privacy_event)
	_check(veil.is_active() and not approval_panel.visible, "privacy veil remains reachable and conceals a pending approval")
	main._on_interaction_event(privacy_event)
	_check(approval_panel.is_open(), "clearing the veil restores the unresolved consent decision")
	main._on_interaction_event(InteractionEvent.new(
		InteractionEvent.Type.SELECT,
		"approval:deny",
		InteractionEvent.Source.HAND,
		null,
		{"gesture": "explicit_pinch"}
	))
	_check(AppState.approval_requests.is_empty(), "restored consent gate remains explicitly deniable")

	if not _failed:
		print("[TEST] Fail-closed hand privacy veil checks passed")
	main.queue_free()
	get_tree().quit(1 if _failed else 0)


func _check(condition: bool, description: String) -> void:
	if condition:
		return
	_failed = true
	push_error("[TEST] Failed: %s" % description)
