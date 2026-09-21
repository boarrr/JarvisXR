extends Node

var _failed := false


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	var main := (load("res://scenes/app/main.tscn") as PackedScene).instantiate()
	add_child(main)
	var probe := main.get_node_or_null("PerfProbe") as PerfProbe
	_check(probe != null, "perf probe composes into Main")
	if probe == null:
		_finish(main)
		return

	var palm := main.get_node("PalmConsole") as PalmConsole
	_check(palm != null, "palm console exists")
	if palm != null:
		_check(
			palm.get_screen_viewport().render_target_update_mode != SubViewport.UPDATE_ALWAYS,
			"palm screen renders on demand instead of every frame"
		)

	await get_tree().process_frame
	await get_tree().process_frame
	_check(probe.sample_count() > 0, "perf probe samples frame times")
	_check(probe.get_summary_line().begins_with("PERF"), "perf summary line is printable")
	_check(probe.has_log_file(), "perf probe keeps an on-device session log")
	_check(
		float(ProjectSettings.get_setting("spatial_agent/xr_refresh_rate", 0.0)) == 72.0,
		"72 Hz refresh target is configured"
	)
	_finish(main)


func _finish(main: Node) -> void:
	if not _failed:
		print("[TEST] Performance probe checks passed")
	if main != null:
		main.queue_free()
	get_tree().quit(1 if _failed else 0)


func _check(condition: bool, description: String) -> void:
	if condition:
		return
	_failed = true
	push_error("[TEST] Failed: %s" % description)
