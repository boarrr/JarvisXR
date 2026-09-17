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
	var mission_target := main.get_node("PalmConsole/MissionTarget") as SpatialActionTarget
	_check(mission_target.target_id == "palm:mission_toggle", "mission map is a hand-only palm action")
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
