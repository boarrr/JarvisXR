extends Node

var _failed := false


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	var main_scene := load("res://scenes/app/main.tscn") as PackedScene
	_check(main_scene != null, "main scene loads")

	var main := main_scene.instantiate()
	add_child(main)
	await get_tree().physics_frame

	var orb_manager := main.get_node("OrbManager") as OrbManager
	var orb := orb_manager.get_orb("thread_demo")
	var manager := main.get_node("InteractionManager") as InteractionManager
	var source := (main.get_node("XRRuntime") as XRRuntime).get_hand_source()
	source.set_hand_tracking_active(true)
	_check(orb != null, "AgentOrb exists")
	_check(orb_manager.get_orb_count() >= 1, "OrbManager spawned thread views")
	_check(manager != null, "InteractionManager exists")
	_check(orb.is_in_group("interactable"), "AgentOrb exposes an interactable target")
	_check(orb.get_interaction_target_id() == "thread_demo", "orb identity comes from thread data")
	_check(AppState.get_thread("thread_demo") == orb.get_thread(), "AppState owns the bound thread")

	# Point the tracked right hand at the orb so the index ray lands on it.
	_aim_at(source, orb.global_position, false)
	manager._physics_process(0.0)
	_check(AppState.hovered_target_id == "thread_demo", "hand ray hovers the orb")

	_aim_at(source, orb.global_position, true)
	manager._physics_process(0.0)
	_check(AppState.focused_thread_id == "thread_demo", "hand pinch selects the thread")
	_check(orb.get_node("VisualRoot/SelectionRing").visible, "selected state displays its ring")

	_look_away(source)
	manager._physics_process(0.0)
	_check(AppState.hovered_target_id.is_empty(), "looking away emits hover exit")

	if not _failed:
		print("[TEST] Milestone 1 interaction checks passed")
	main.queue_free()
	get_tree().quit(1 if _failed else 0)


func _aim_at(source: OpenXRInteractionSource, target: Vector3, pinching: bool) -> void:
	# Index tip in front of the target and the distal joint trailing straight
	# behind it, so the source derives a ray aimed at the agent.
	var origin := target + Vector3(0.0, 0.12, 0.9)
	var forward := (target - origin).normalized()
	var index_tip := origin
	var index_distal := origin - forward * 0.05
	var thumb_tip := index_tip + forward * (0.015 if pinching else 0.08)
	var palm := Transform3D(Basis.IDENTITY, origin + Vector3(0.0, -0.08, 0.05))
	source.submit_joint_sample("right", palm, thumb_tip, index_distal, index_tip)


func _look_away(source: OpenXRInteractionSource) -> void:
	var origin := Vector3(0.0, 5.0, 0.0)
	source.submit_joint_sample(
		"right",
		Transform3D(Basis.IDENTITY, origin),
		origin + Vector3.UP * 0.08,
		origin - Vector3.UP * 0.05,
		origin
	)


func _check(condition: bool, description: String) -> void:
	if condition:
		return
	_failed = true
	push_error("[TEST] Failed: %s" % description)
