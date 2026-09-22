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
		AppState.ordered_thread_ids.size() == thread_count_before - 1,
		"combining replaces two agents with one"
	)
	var combined_thread: AgentThread = AppState.get_thread(AppState.ordered_thread_ids.back())
	_check(
		combined_thread != null and combined_thread.title.contains("combined"),
		"combined thread carries a combined title"
	)
	_check(
		AppState.get_thread(first_id) == null and AppState.get_thread(second_id) == null,
		"combining absorbs the originals into one agent"
	)
	# Separate to bring both originals back for the checks that follow.
	bridge.send_command("thread.separate", {}, combined_thread.id)
	_check(
		AppState.get_thread(combined_thread.id) == null
		and AppState.get_thread(first_id) != null
		and AppState.get_thread(second_id) != null,
		"separating restores the original agents"
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
	manager.attract_to(first_id, attract_anchor)
	var attract_step := (
		(manager.get_orb(first_id) as AgentOrb).global_position.distance_to(attract_start)
	)
	_check(attract_step < 0.05, "fist attraction creeps toward the palm instead of snapping")
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

	# Creation: the palm NEW AGENT action spawns an agent through the transport
	# and places its orb where the action was requested.
	var before_count := AppState.ordered_thread_ids.size()
	main._create_agent_at(Vector3(4.0, 1.4, 4.0))
	_check(AppState.ordered_thread_ids.size() == before_count + 1, "creating an agent adds a thread")
	var created_id: String = AppState.ordered_thread_ids.back()
	_check(
		AppState.get_orb_offset(created_id) is Vector3,
		"a created agent spawns at the requested position"
	)
	_check(
		AppState.get_thread(created_id).title.contains("New agent"),
		"a created agent carries a default title"
	)

	# Fist attraction needs a tracked hand with joint data.
	var summon_source := OpenXRInteractionSource.new()
	add_child(summon_source)
	summon_source.set_hand_tracking_active(true)
	var summon_events: Array[InteractionEvent] = []
	summon_source.interaction_event.connect(
		func(event: InteractionEvent) -> void: summon_events.append(event)
	)
	var summon_palm := Transform3D(Basis.IDENTITY, Vector3(3.0, 1.4, -0.4))

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

	# Panel pages gate both visuals and touch targets so what is drawn is what
	# can actually be poked.
	var palm_panel := main.get_node("PalmConsole") as PalmConsole
	palm_panel.handle_screen_action("palm_screen:next_page")
	_check(palm_panel._page == PalmConsole.PAGE_CODE, "panel advances to the code page")
	var chat_buttons: Array = palm_panel._page_buttons[PalmConsole.PAGE_CHAT]
	_check(chat_buttons.size() > 0, "chat page registers its buttons")
	_check(not (chat_buttons[0] as Node).visible, "chat buttons hide while the code page shows")
	var code_buttons: Array = palm_panel._page_buttons[PalmConsole.PAGE_CODE]
	_check((code_buttons[0] as Node).visible, "code buttons show on the code page")
	_check(
		not palm_panel._dynamic_targets[0].visible,
		"chat touch targets deactivate on the code page"
	)

	# A deliberate double-pinch summons; a fast flinch or a tracking dropout
	# must never look like one.
	var tap_source := OpenXRInteractionSource.new()
	add_child(tap_source)
	tap_source.set_hand_tracking_active(true)
	tap_source.set_physics_process(false)
	var tap_events: Array[InteractionEvent] = []
	tap_source.interaction_event.connect(
		func(event: InteractionEvent) -> void: tap_events.append(event)
	)
	var tap_palm := Transform3D(Basis.IDENTITY, Vector3(5.0, 1.4, -0.4))
	var closed_thumb := Vector3(5.02, 1.42, -0.6)
	var open_thumb := Vector3(5.0, 1.42, -0.5)
	var tap_index := Vector3(5.0, 1.42, -0.6)
	var tap_distal := Vector3(5.0, 1.42, -0.55)

	# Flinch: pinched for 40 ms, below the tap floor.
	tap_source.set_clock_override_msec(1000)
	tap_source.submit_joint_sample("left", tap_palm, closed_thumb, tap_distal, tap_index)
	tap_source.set_clock_override_msec(1040)
	tap_source.submit_joint_sample("left", tap_palm, open_thumb, tap_distal, tap_index)
	_check(_summon_count(tap_events) == 0, "a flinch pinch does not summon")

	# Real double pinch: two 200 ms pinches 100 ms apart.
	tap_source.set_clock_override_msec(1100)
	tap_source.submit_joint_sample("left", tap_palm, closed_thumb, tap_distal, tap_index)
	tap_source.set_clock_override_msec(1300)
	tap_source.submit_joint_sample("left", tap_palm, open_thumb, tap_distal, tap_index)
	tap_source.set_clock_override_msec(1400)
	tap_source.submit_joint_sample("left", tap_palm, closed_thumb, tap_distal, tap_index)
	tap_source.set_clock_override_msec(1600)
	tap_source.submit_joint_sample("left", tap_palm, open_thumb, tap_distal, tap_index)
	_check(_summon_count(tap_events) == 1, "double pinch summons the console once")
	_check(not tap_source.get_pointer_state().is_selecting, "pinch state settles after summon")

	# A single empty pinch on the pointer hand drops focus instead of summoning.
	var dismiss_source := OpenXRInteractionSource.new()
	add_child(dismiss_source)
	dismiss_source.set_hand_tracking_active(true)
	dismiss_source.set_physics_process(false)
	var dismiss_events: Array[InteractionEvent] = []
	dismiss_source.interaction_event.connect(
		func(event: InteractionEvent) -> void: dismiss_events.append(event)
	)
	var right_palm := Transform3D(Basis.IDENTITY, Vector3(6.0, 1.4, -0.4))
	var right_closed_thumb := Vector3(6.02, 1.42, -0.6)
	var right_open_thumb := Vector3(6.0, 1.42, -0.5)
	var right_index := Vector3(6.0, 1.42, -0.6)
	var right_distal := Vector3(6.0, 1.42, -0.55)
	dismiss_source.set_clock_override_msec(2000)
	dismiss_source.submit_joint_sample("right", right_palm, right_closed_thumb, right_distal, right_index)
	dismiss_source.set_clock_override_msec(2250)
	dismiss_source.submit_joint_sample("right", right_palm, right_open_thumb, right_distal, right_index)
	var dismiss_count := dismiss_events.filter(
		func(event: InteractionEvent) -> bool: return event.type == InteractionEvent.Type.DISMISS
	).size()
	_check(dismiss_count == 1, "a single empty pinch clears focus")
	_check(_summon_count(dismiss_events) == 0, "a single empty pinch does not summon")

	# An open console owns hand input, so poking it cannot drop the selection.
	AppState.palm_console_open = true
	var guarded_source := OpenXRInteractionSource.new()
	add_child(guarded_source)
	guarded_source.set_hand_tracking_active(true)
	guarded_source.set_physics_process(false)
	var guarded_events: Array[InteractionEvent] = []
	guarded_source.interaction_event.connect(
		func(event: InteractionEvent) -> void: guarded_events.append(event)
	)
	guarded_source.set_clock_override_msec(4000)
	guarded_source.submit_joint_sample("right", right_palm, right_closed_thumb, right_distal, right_index)
	guarded_source.set_clock_override_msec(4250)
	guarded_source.submit_joint_sample("right", right_palm, right_open_thumb, right_distal, right_index)
	var guarded_dismiss := guarded_events.filter(
		func(event: InteractionEvent) -> bool: return event.type == InteractionEvent.Type.DISMISS
	).size()
	_check(guarded_dismiss == 0, "an open console suppresses the deselect pinch")
	AppState.palm_console_open = false

	# Tracking loss must not fabricate the second tap.
	var loss_source := OpenXRInteractionSource.new()
	add_child(loss_source)
	loss_source.set_hand_tracking_active(true)
	loss_source.set_physics_process(false)
	var loss_events: Array[InteractionEvent] = []
	loss_source.interaction_event.connect(
		func(event: InteractionEvent) -> void: loss_events.append(event)
	)
	loss_source.set_clock_override_msec(3000)
	loss_source.submit_joint_sample("left", tap_palm, closed_thumb, tap_distal, tap_index)
	loss_source.set_clock_override_msec(3250)
	loss_source.submit_joint_sample("left", tap_palm, open_thumb, tap_distal, tap_index)
	loss_source.set_hand_tracking_active(false)
	loss_source.set_hand_tracking_active(true)
	loss_source.set_physics_process(false)
	loss_source.set_clock_override_msec(3400)
	loss_source.submit_joint_sample("left", tap_palm, closed_thumb, tap_distal, tap_index)
	loss_source.set_clock_override_msec(3650)
	loss_source.submit_joint_sample("left", tap_palm, open_thumb, tap_distal, tap_index)
	_check(_summon_count(loss_events) == 0, "tracking loss cannot fabricate a summon")

	# Pinching at a hovered agent selects it; selecting must not carry it away.
	var select_source := OpenXRInteractionSource.new()
	add_child(select_source)
	select_source.set_hand_tracking_active(true)
	select_source.set_physics_process(false)
	select_source.set_hover_target_id("thread_probe")
	var select_events: Array[InteractionEvent] = []
	select_source.interaction_event.connect(
		func(event: InteractionEvent) -> void: select_events.append(event)
	)
	var far_palm := Transform3D(Basis.IDENTITY, Vector3(7.0, 1.4, -0.4))
	select_source.submit_joint_sample(
		"right", far_palm, Vector3(7.02, 1.42, -0.6), Vector3(7.0, 1.42, -0.55), Vector3(7.0, 1.42, -0.6)
	)
	var grabs := select_events.filter(
		func(event: InteractionEvent) -> bool: return event.type == InteractionEvent.Type.GRAB_BEGIN
	)
	_check(grabs.is_empty(), "pinching a hovered agent selects instead of grabbing")
	_check(
		not select_source.get_pointer_state().is_grabbing,
		"a pointed pinch leaves the agent in place"
	)

	# Closing a fist after the ray drifted off still pulls the last agent.
	var attract_fist_source := OpenXRInteractionSource.new()
	add_child(attract_fist_source)
	attract_fist_source.set_hand_tracking_active(true)
	attract_fist_source.set_physics_process(false)
	var attract_fist_events: Array[InteractionEvent] = []
	attract_fist_source.interaction_event.connect(
		func(event: InteractionEvent) -> void: attract_fist_events.append(event)
	)
	attract_fist_source.set_clock_override_msec(5000)
	attract_fist_source.set_hover_target_id("thread_probe")
	attract_fist_source.set_clock_override_msec(5150)
	attract_fist_source.set_hover_target_id("")
	var attract_fist_palm := Transform3D(Basis.IDENTITY, Vector3(8.0, 1.4, -0.4))
	var attract_palm_joint := Vector3(8.0, 1.4, -0.4)
	var attract_fist_joints := {
		"palm": attract_palm_joint,
		"index_tip": attract_palm_joint + Vector3(0.0, 0.0, -0.05),
		"middle_tip": attract_palm_joint + Vector3(0.0, 0.03, -0.05),
		"ring_tip": attract_palm_joint + Vector3(0.0, -0.03, -0.05),
		"pinky_tip": attract_palm_joint + Vector3(0.02, 0.0, -0.05),
		"index_proximal": attract_palm_joint + Vector3(0.0, 0.0, -0.08),
		"index_distal": attract_palm_joint + Vector3(0.0, 0.0, -0.06),
	}
	attract_fist_source.submit_joint_sample(
		"right",
		attract_fist_palm,
		attract_palm_joint + Vector3(0.03, 0.03, -0.06),
		attract_palm_joint + Vector3(0.0, 0.0, -0.06),
		attract_palm_joint + Vector3(0.0, 0.0, -0.05),
		attract_fist_joints
	)
	var memory_attract_begins := attract_fist_events.filter(
		func(event: InteractionEvent) -> bool: return event.type == InteractionEvent.Type.ATTRACT_BEGIN
	)
	_check(
		memory_attract_begins.size() == 1 and memory_attract_begins[0].target_id == "thread_probe",
		"a fist still pulls the agent the ray last touched"
	)

	var palm_console := main.get_node("PalmConsole") as PalmConsole
	palm_console.summon_now()
	_check(palm_console.visible, "summon_now parks and shows the console")

	# The open console captures agent selection; closing restores it.
	AppState.focus_thread("")
	main._on_interaction_event(InteractionEvent.new(
		InteractionEvent.Type.SELECT, first_id, InteractionEvent.Source.HAND, null, {}
	))
	_check(AppState.focused_thread_id.is_empty(), "the open console ignores agent ray selection")
	palm_console.summon_now()
	_check(not palm_console.visible, "a repeat summon hides the console")
	main._on_interaction_event(InteractionEvent.new(
		InteractionEvent.Type.SELECT, first_id, InteractionEvent.Source.HAND, null, {}
	))
	_check(
		AppState.focused_thread_id == first_id,
		"closing the console restores agent selection"
	)

	if not _failed:
		print("[TEST] Standing orbit and two-hand role checks passed")
	# Combining absorbs both originals into one agent; separating restores them.
	main._create_agent_at(Vector3(2.5, 1.4, 2.0))
	main._create_agent_at(Vector3(3.0, 1.4, 2.0))
	var combine_bridge := main.get_node("BackendBridge")
	var combine_ordered := AppState.ordered_thread_ids
	var combine_ids: Array[String] = [combine_ordered[combine_ordered.size() - 2], combine_ordered[combine_ordered.size() - 1]]
	combine_bridge.send_command("thread.combine", {"thread_ids": combine_ids})
	var combined_id := ""
	for thread_id in AppState.ordered_thread_ids:
		var candidate := AppState.get_thread(thread_id)
		if candidate != null and not (candidate.metadata.get("combined_from", []) as Array).is_empty():
			combined_id = thread_id
			break
	_check(not combined_id.is_empty(), "combining creates one combined agent")
	_check(
		AppState.get_thread(combine_ids[0]) == null and AppState.get_thread(combine_ids[1]) == null,
		"combining absorbs the two originals"
	)
	main._uncombine_agent(combined_id)
	_check(AppState.get_thread(combined_id) == null, "separating removes the combined agent")
	_check(
		AppState.get_thread(combine_ids[0]) != null and AppState.get_thread(combine_ids[1]) != null,
		"separating restores both original agents"
	)

	main.queue_free()
	source.queue_free()
	get_tree().quit(1 if _failed else 0)


func _summon_count(events: Array[InteractionEvent]) -> int:
	var total := 0
	for event in events:
		if event.type == InteractionEvent.Type.SUMMON:
			total += 1
	return total


func _check(condition: bool, description: String) -> void:
	if condition:
		return
	_failed = true
	push_error("[TEST] Failed: %s" % description)
