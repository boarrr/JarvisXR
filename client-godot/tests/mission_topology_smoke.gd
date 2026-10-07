extends Node

var _failed := false


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	var main := (load("res://scenes/app/main.tscn") as PackedScene).instantiate()
	add_child(main)
	var topology := main.get_node("MissionTopology") as MissionTopology
	_check(topology != null and not topology.is_enabled(), "mission topology starts intentionally collapsed")
	_check(AppState.focus_thread("thread_demo"), "mission map can anchor on a focused agent")
	main._on_interaction_event(InteractionEvent.new(
		InteractionEvent.Type.SELECT,
		"palm:mission_toggle",
		InteractionEvent.Source.HAND,
		null,
		{"gesture": "pinch"}
	))
	_check(topology.is_enabled() and topology.visible, "palm pinch summons the room-scale mission topology")
	_check(topology.get_link_count() > 0, "active agents create live correlation paths")
	_check(topology.get_link_count() <= 12, "mission topology enforces a standalone headset geometry budget")
	_check(topology.get_pulse_count() == topology.get_link_count(), "each link carries one animated status pulse")
	_check(not topology.get_debug_text().contains("Give me a concise update"), "mission links remain content-blind")
	# Fleet: two agents sharing a mission form a star.
	var ids := AppState.ordered_thread_ids
	if ids.size() >= 2:
		var hub_id := str(ids[0])
		var spoke_id := str(ids[1])
		var hub_thread := AppState.get_thread(hub_id)
		var spoke_thread := AppState.get_thread(spoke_id)
		hub_thread.metadata["mission_id"] = "mission_test"
		spoke_thread.metadata["mission_id"] = "mission_test"
		AppState.update_thread(hub_thread)
		AppState.update_thread(spoke_thread)
		topology.refresh()
		_check(topology.mission_count() == 1, "agents sharing a mission report one fleet")
		_check(
			topology.get_debug_text().contains("%s>%s" % [hub_id, spoke_id]),
			"a fleet renders a hub-to-agent constellation link"
		)
	topology.set_blocked(true)
	_check(not topology.visible, "approval safety mode suppresses the mission topology")
	topology.set_blocked(false)
	_check(topology.visible, "mission topology restores after the safety gate")

	if not _failed:
		print("[TEST] Hand-only mission topology checks passed")
	main.queue_free()
	get_tree().quit(1 if _failed else 0)


func _check(condition: bool, description: String) -> void:
	if condition:
		return
	_failed = true
	push_error("[TEST] Failed: %s" % description)
