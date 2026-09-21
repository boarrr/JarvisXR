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

	# Standing centre: in XR the layout anchors to the play-space origin, so the
	# agent ring does not follow the user as they walk.
	AppState.ui_mode = "xr_hands"
	var origin := manager._get_layout_origin()
	_check(
		origin.distance_to(main.get_node("XRRuntime/XROrigin3D").global_position) < 0.001,
		"XR layout anchors to the standing centre"
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
