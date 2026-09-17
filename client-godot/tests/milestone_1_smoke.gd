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
	var rig := main.get_node("UserRig") as UserRig
	var source := rig.get_interaction_source()
	_check(orb != null, "AgentOrb exists")
	_check(orb_manager.get_orb_count() >= 1, "OrbManager spawned thread views")
	_check(manager != null, "InteractionManager exists")
	_check(orb.is_in_group("interactable"), "AgentOrb exposes an interactable target")
	_check(orb.get_interaction_target_id() == "thread_demo", "orb identity comes from thread data")
	_check(AppState.get_thread("thread_demo") == orb.get_thread(), "AppState owns the bound thread")

	source._process(0.0)
	manager._physics_process(0.0)
	_check(AppState.hovered_target_id == "thread_demo", "center ray hovers the orb")

	Input.action_press("pointer_select")
	source._process(0.0)
	manager._physics_process(0.0)
	Input.action_release("pointer_select")
	source._process(0.0)
	manager._physics_process(0.0)
	_check(AppState.focused_thread_id == "thread_demo", "select focuses the thread")
	_check(orb.get_node("VisualRoot/SelectionRing").visible, "selected state displays its ring")

	rig._apply_mouse_look(Vector2(0.0, -deg_to_rad(60.0) / rig.mouse_sensitivity))
	source._process(0.0)
	manager._physics_process(0.0)
	_check(AppState.hovered_target_id.is_empty(), "looking away emits hover exit")

	if not _failed:
		print("[TEST] Milestone 1 interaction checks passed")
	main.queue_free()
	get_tree().quit(1 if _failed else 0)


func _check(condition: bool, description: String) -> void:
	if condition:
		return
	_failed = true
	push_error("[TEST] Failed: %s" % description)
