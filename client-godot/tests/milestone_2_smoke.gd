extends Node

var _failed := false


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	var main_scene := load("res://scenes/app/main.tscn") as PackedScene
	_check(main_scene != null, "main scene loads")
	var main := main_scene.instantiate()
	add_child(main)

	var orb_manager := main.get_node("OrbManager") as OrbManager
	var debug_controller := main.get_node("DebugThreadController") as DebugThreadController
	var rig := main.get_node("UserRig") as UserRig
	_check(AppState.ordered_thread_ids.size() == 8, "eight fake threads are seeded")
	_check(orb_manager.get_orb_count() == 8, "eight orbs are data-spawned")

	var original_slots: Dictionary = {}
	var used_slots: Dictionary = {}
	for thread_id in AppState.ordered_thread_ids:
		var thread := AppState.get_thread(thread_id)
		var orb := orb_manager.get_orb(thread_id)
		_check(thread != null and orb != null, "thread has an orb: %s" % thread_id)
		_check(not used_slots.has(thread.spatial_slot), "spatial slot is unique: %d" % thread.spatial_slot)
		used_slots[thread.spatial_slot] = true
		original_slots[thread_id] = thread.spatial_slot
		_check(
			orb.get_target_global_position().is_equal_approx(orb_manager.calculate_slot_global_position(thread.spatial_slot)),
			"orb target matches deterministic slot: %s" % thread_id
		)

	var added_thread := debug_controller.create_fake_thread()
	var added_orb := orb_manager.get_orb(added_thread.id)
	_check(AppState.ordered_thread_ids.size() == 9, "debug create adds a thread")
	_check(orb_manager.get_orb_count() == 9, "debug create spawns an orb")
	_check(added_thread.spatial_slot == 8, "new thread takes the lowest free slot")
	var initial_target_distance := added_orb.global_position.distance_to(added_orb.get_target_global_position())
	_check(
		initial_target_distance > 0.1,
		"new orb begins away from its target for smooth movement"
	)
	added_orb._process(0.1)
	_check(
		added_orb.global_position.distance_to(added_orb.get_target_global_position()) < initial_target_distance,
		"new orb moves smoothly toward its target"
	)
	for thread_id in original_slots:
		_check(AppState.get_thread(thread_id).spatial_slot == original_slots[thread_id], "existing slot remains stable: %s" % thread_id)

	_check(debug_controller.remove_latest_thread(), "debug remove succeeds")
	_check(orb_manager.get_orb_count() == 8, "removing a thread despawns its orb mapping")
	var replacement := debug_controller.create_fake_thread()
	_check(replacement.spatial_slot == 8, "a freed slot is reused without reshuffling")

	while AppState.ordered_thread_ids.size() < 12:
		debug_controller.create_fake_thread()
	_check(orb_manager.get_orb_count() == 12, "twelve active orbs are supported")
	var secondary_thread_id: String = AppState.ordered_thread_ids[10]
	var secondary_thread := AppState.get_thread(secondary_thread_id)
	var secondary_target := orb_manager.calculate_slot_global_position(secondary_thread.spatial_slot)
	_check(secondary_thread.spatial_slot >= 10, "overflow thread uses a secondary-ring slot")
	_check(secondary_target.y > rig.global_position.y, "secondary ring is vertically separated")

	AppState.focus_thread("thread_demo")
	var focused_thread := AppState.get_thread("thread_demo")
	var previous_status := focused_thread.status
	_check(debug_controller.cycle_target_status(), "status cycling succeeds")
	_check(focused_thread.status != previous_status, "focused thread status changes")
	var focused_orb := orb_manager.get_orb("thread_demo")
	_check(
		focused_orb.get_node("StatusLabel").text == AgentThread.status_label(focused_thread.status),
		"orb renders updated thread status"
	)

	if not _failed:
		print("[TEST] Milestone 2 layout checks passed")
	main.queue_free()
	get_tree().quit(1 if _failed else 0)


func _check(condition: bool, description: String) -> void:
	if condition:
		return
	_failed = true
	push_error("[TEST] Failed: %s" % description)
