extends Node

var _failed := false


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	var main_scene := load("res://scenes/app/main.tscn") as PackedScene
	var main := main_scene.instantiate()
	add_child(main)

	var threads := AppState.ordered_thread_ids
	_check(threads.size() >= 2, "snapshot provides threads for orbit tests")
	var first_id: String = threads[0]
	var second_id: String = threads[1]
	var manager := main.get_node("OrbManager") as OrbManager

	var first_orb := manager.get_orb(first_id)
	var second_orb := manager.get_orb(second_id)
	_check(first_orb != null and second_orb != null, "orbs exist for both threads")

	# Manual placement: a dragged orb stores its world position.
	var grab_position := Vector3(5.0, 1.4, 5.0)
	_check(manager.begin_grab(first_id), "orb grab begins")
	manager.update_grab(first_id, grab_position)
	_check(
		AppState.get_orb_offset(first_id) is Vector3,
		"dragging stores a manual orbit offset"
	)
	manager.end_grab(first_id)
	_check(
		AppState.get_orb_parent(first_id).is_empty(),
		"releasing in free space keeps the orb independent"
	)

	# Combining: drop one orb onto another and the child links to the parent.
	AppState.set_orb_offset(second_id, second_orb.global_position)
	manager.update_grab(first_id, second_orb.global_position + Vector3(0.1, 0.0, 0.0))
	var result := manager.end_grab(first_id)
	_check(str(result.get("linked_to", "")) == second_id, "dropping onto another orb combines them")
	_check(AppState.get_orb_parent(first_id) == second_id, "combined orb records its parent")
	_check(not (AppState.get_orb_offset(first_id) is Vector3), "combined orb drops its manual offset")

	# Cycle prevention: the parent cannot be re-linked under its own child.
	_check(not AppState.link_orbs(second_id, first_id), "orb links reject cycles")
	_check(AppState.unlink_orb(first_id), "combined orb can be detached again")

	# Combining through the transport creates a new agent seeded with both contexts.
	var bridge := main.get_node("BackendBridge") as BackendBridge
	var thread_count_before := AppState.ordered_thread_ids.size()
	_check(
		bridge.send_command("thread.combine", {"thread_ids": [first_id, second_id]}),
		"combine command is accepted by the transport"
	)
	_check(
		AppState.ordered_thread_ids.size() == thread_count_before + 1,
		"combining creates a new agent thread"
	)
	var combined_thread: AgentThread = AppState.get_thread(AppState.ordered_thread_ids.back())
	_check(
		combined_thread != null and combined_thread.title.contains("combined"),
		"combined thread carries a combined title"
	)

	# Standing centre: in XR the layout anchors to the play-space origin, so the
	# agent ring does not follow the user as they walk.
	AppState.ui_mode = "xr_hands"
	var ground := (main.get_node("XRRuntime/XROrigin3D") as Node3D).global_position
	var origin := manager._get_layout_origin()
	_check(
		absf(origin.x - ground.x) < 0.001
		and absf(origin.z - ground.z) < 0.001
		and origin.y > ground.y + 0.5,
		"XR layout anchors to the standing centre at head height"
	)
	AppState.ui_mode = "desktop"

	# Right-hand-only pointer: the left hand informs markers and bimanual input
	# but must not drive the aim ray (it holds the palm panel).
	var source := OpenXRInteractionSource.new()
	add_child(source)
	source.set_hand_tracking_active(true)
	var palm := Transform3D(Basis.IDENTITY, Vector3(-0.2, 1.2, -0.5))
	_check(
		source.submit_joint_sample(
			"left",
			palm,
			Vector3(-0.18, 1.22, -0.75),
			Vector3(-0.2, 1.2, -0.7),
			Vector3(-0.2, 1.22, -0.75)
		),
		"left hand samples are accepted for tracking"
	)
	_check(source.has_tracking_data(), "left hand alone still publishes tracking")
	_check(
		source._active_hand_name.is_empty(),
		"left hand never drives the aim pointer"
	)
	_check(
		source.get_pointer_state().origin.is_zero_approx(),
		"left hand leaves the pointer unused"
	)
	_check(
		source.submit_joint_sample(
			"right",
			Transform3D(Basis.IDENTITY, Vector3(0.2, 1.2, -0.5)),
			Vector3(0.18, 1.22, -0.75),
			Vector3(0.2, 1.2, -0.7),
			Vector3(0.2, 1.22, -0.75)
		),
		"right hand samples are accepted"
	)
	_check(
		source._active_hand_name == "right",
		"right hand drives the aim pointer"
	)
	_check(
		not source.get_pointer_state().direction.is_zero_approx(),
		"right hand publishes a usable aim direction"
	)

	# Throw physics: a fast release gives the orb inertia and it coasts to rest.
	_check(manager.begin_grab(first_id), "grab for a throw begins")
	manager.update_grab(first_id, Vector3(5.0, 1.4, 5.0))
	manager.update_grab(first_id, Vector3(5.7, 1.5, 5.0))
	var throw_result := manager.end_grab(first_id)
	_check(bool(throw_result.get("thrown", false)), "a fast release throws the orb")
	var thrown_start := (manager.get_orb(first_id) as AgentOrb).global_position
	for _frame in range(90):
		manager._update_kinetics(0.05)
	_check(
		(manager.get_orb(first_id) as AgentOrb).global_position.distance_to(thrown_start) > 0.1,
		"a thrown orb keeps moving with inertia"
	)
	_check(AppState.get_orb_offset(first_id) is Vector3, "the orb settles into a saved resting position")

	# Attract: a fist aimed at a distant orb pulls it toward the anchor.
	AppState.clear_orb_offset(first_id)
	manager.attract_begin(first_id)
	var attract_start := (manager.get_orb(first_id) as AgentOrb).global_position
	var attract_anchor := attract_start + Vector3(0.0, 0.0, 0.8)
	for _frame in range(240):
		manager.attract_to(first_id, attract_anchor)
	manager.attract_end(first_id)
	_check(
		(manager.get_orb(first_id) as AgentOrb).global_position.distance_to(attract_start) > 0.1,
		"fist attraction brings the orb toward the palm"
	)

	# Crush and undo through the product path (archive, then restore).
	var victim_id: String = threads[2]
	main._crush_agent(victim_id)
	_check(AppState.get_thread(victim_id) == null, "crush removes the agent")
	_check(AppState.undo_count() == 1, "crush leaves one undo entry")
	main._undo_last_agent()
	_check(AppState.get_thread(victim_id) != null, "undo restores the crushed agent")

	# Summon gesture: pinch in empty space and pull to request a new agent.
	var summon_source := OpenXRInteractionSource.new()
	add_child(summon_source)
	summon_source.set_hand_tracking_active(true)
	var summon_events: Array[InteractionEvent] = []
	summon_source.interaction_event.connect(
		func(event: InteractionEvent) -> void: summon_events.append(event)
	)
	var summon_palm := Transform3D(Basis.IDENTITY, Vector3(3.0, 1.4, -0.4))
	summon_source.submit_joint_sample(
		"right", summon_palm,
		Vector3(3.02, 1.42, -0.65), Vector3(3.0, 1.4, -0.6), Vector3(3.0, 1.42, -0.65)
	)
	summon_source.submit_joint_sample(
		"right", summon_palm,
		Vector3(3.02, 1.42, -0.75), Vector3(3.0, 1.4, -0.7), Vector3(3.0, 1.42, -0.75)
	)
	summon_source.submit_joint_sample(
		"right", summon_palm,
		Vector3(3.09, 1.42, -0.75), Vector3(3.0, 1.4, -0.7), Vector3(3.0, 1.42, -0.75)
	)
	var summon_begins := summon_events.filter(
		func(event: InteractionEvent) -> bool:
			return event.type == InteractionEvent.Type.GRAB_BEGIN and event.target_id == "ui:summon"
	)
	var summon_ends := summon_events.filter(
		func(event: InteractionEvent) -> bool:
			return event.type == InteractionEvent.Type.GRAB_END and event.target_id == "ui:summon"
	)
	_check(summon_begins.size() == 1, "pinching in empty space starts a summon")
	_check(
		summon_ends.size() == 1
		and not bool(summon_ends[0].gesture_data.get("cancelled", true)),
		"pulling past the threshold confirms the summon"
	)

	# A fist aimed at a hovered agent requests attraction.
	var fist_joints := {
		"palm": Vector3(3.0, 1.4, -0.6),
		"index_tip": Vector3(3.03, 1.42, -0.62),
		"middle_tip": Vector3(3.01, 1.43, -0.62),
		"ring_tip": Vector3(2.99, 1.43, -0.62),
		"pinky_tip": Vector3(2.97, 1.42, -0.62),
	}
	summon_events.clear()
	summon_source.set_hover_target_id(victim_id)
	summon_source.submit_joint_sample(
		"right", summon_palm,
		Vector3(3.02, 1.42, -0.65), Vector3(3.0, 1.4, -0.6), Vector3(3.0, 1.42, -0.65),
		fist_joints
	)
	var attract_begins := summon_events.filter(
		func(event: InteractionEvent) -> bool:
			return event.type == InteractionEvent.Type.ATTRACT_BEGIN
	)
	_check(
		attract_begins.size() == 1 and attract_begins[0].target_id == victim_id,
		"a fist aimed at an agent starts attraction"
	)

	if not _failed:
		print("[TEST] Standing orbit and two-hand role checks passed")
	main.queue_free()
	source.queue_free()
	get_tree().quit(1 if _failed else 0)


func _check(condition: bool, description: String) -> void:
	if condition:
		return
	_failed = true
	push_error("[TEST] Failed: %s" % description)
