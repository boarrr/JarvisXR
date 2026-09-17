extends Node

var _failed := false
var _emitted_cue: Dictionary = {}


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	var main := (load("res://scenes/app/main.tscn") as PackedScene).instantiate()
	add_child(main)
	var audio := main.get_node("SpatialAudioCueService") as SpatialAudioCueService
	audio.cue_emitted.connect(func(cue: Dictionary) -> void: _emitted_cue = cue)
	_check(audio.emit_cue("approval", Vector3(1.0, 1.5, -2.0)), "procedural approval sonification can be emitted")
	_check(audio.get_generated_sample_count() > 1000, "spatial cue is synthesized locally without an audio asset")
	_check(str(audio.get_last_cue().get("name", "")) == "approval", "semantic cue identity is observable")
	_check(audio.get_last_cue().get("world_position") == Vector3(1.0, 1.5, -2.0), "cue retains its 3D source position")
	_check(not str(_emitted_cue).contains("Give me a concise update"), "sonification telemetry contains no thread content")

	var anchors := main.get_node("RoomAnchorRegistry") as RoomAnchorRegistry
	_check(anchors.get_capabilities().get("stores_scene_mesh") == false, "anchor boundary refuses raw room-mesh storage")
	_check(anchors.register_anchor("mission_header", "mission_header", Transform3D.IDENTITY), "session-only semantic anchor can be registered")
	_check(not anchors.register_anchor("bad", "raw_scene_mesh", Transform3D.IDENTITY), "unbounded scene data classifications are rejected")
	AppState.focus_thread("thread_debug_03")
	(main.get_node("CodeViewer") as CodeViewer).open_focused_thread()
	_check(anchors.has_anchor("code_surface"), "floating code surface publishes a semantic room anchor")
	_check(not anchors.get_content_blind_summary().contains("route_agent_delta"), "anchor registry remains content-blind")

	if not _failed:
		print("[TEST] Procedural spatial audio and privacy-safe anchor boundary checks passed")
	main.queue_free()
	get_tree().quit(1 if _failed else 0)


func _check(condition: bool, description: String) -> void:
	if condition:
		return
	_failed = true
	push_error("[TEST] Failed: %s" % description)
