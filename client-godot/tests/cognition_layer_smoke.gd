extends Node

var _failed := false


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	var main := (load("res://scenes/app/main.tscn") as PackedScene).instantiate()
	add_child(main)
	var layer := main.get_node("CognitionLayer") as CognitionLayer
	_check(layer != null, "main workspace owns a cognition layer")
	_check(layer.get_visual_node_count() == 10, "neural constellation uses a bounded mobile-friendly node field")
	_check(AppState.focus_thread("thread_demo"), "cognition test can focus an agent")
	layer._process(0.1)
	_check(layer.visible, "cognition layer materializes around the focused agent")
	var palm_toggle := InteractionEvent.new(
		InteractionEvent.Type.SELECT,
		"palm:cognition_toggle",
		InteractionEvent.Source.HAND,
		null,
		{"gesture": "pinch"}
	)
	main._on_interaction_event(palm_toggle)
	_check(not layer.is_enabled(), "palm cognition command can collapse the visualization")
	_check(not layer.visible, "collapsed cognition leaves a calm workspace")
	main._on_interaction_event(palm_toggle)
	_check(layer.is_enabled(), "palm cognition command can summon the visualization")
	_check(layer.visible, "summoned cognition restores the spatial event field")

	var secret_event := BackendEvent.new(
		"agent.message.delta",
		{"delta": "SENSITIVE_PAYLOAD_MUST_NOT_RENDER", "sequence": 1},
		"evt_cognition_secret",
		"sess_cognition",
		"thread_demo",
		"2026-09-15T12:00:00Z"
	)
	layer.ingest_backend_event(secret_event)
	_check(layer.get_current_event_summary().contains("TOKEN STREAM"), "stream activity becomes a semantic event pulse")
	_check(not layer.get_debug_text().contains("SENSITIVE_PAYLOAD_MUST_NOT_RENDER"), "cognition visuals never retain prompt or token content")

	for index in range(40):
		var event := BackendEvent.new(
			"agent.status",
			{"status": "working" if index % 2 == 0 else "idle"},
			"evt_cognition_%02d" % index,
			"sess_cognition",
			"thread_demo",
			"2026-09-15T12:00:00Z"
		)
		layer.ingest_backend_event(event)
	_check(layer.get_event_count() == 32, "temporal black box has a strict bounded history")
	var latest_summary := layer.get_current_event_summary()
	_check(layer.select_previous_event(), "rewind gesture moves into event history")
	_check(layer.get_current_event_summary() != latest_summary, "rewind changes the inspected causal event")
	_check(layer.select_next_event(), "forward gesture advances the event lens")
	_check(layer.get_current_event_summary() == latest_summary, "forward returns to the latest event")

	AppState.set_provider_identity("openai", "gpt-6-astra")
	_check(layer.get_privacy_status().contains("HOSTED EGRESS"), "privacy field exposes hosted provider routing")
	layer.record_command("message.send", "thread_demo")
	_check(layer.get_current_event_summary().contains("MESSAGE / SEND"), "outbound intent appears without its content")
	_check(not layer.get_debug_text().contains("SENSITIVE_PAYLOAD_MUST_NOT_RENDER"), "event history remains content-blind after routing")
	AppState.set_provider_identity("council", "openai-test + claude-test")
	_check(layer.get_privacy_status().contains("DUAL HOSTED EGRESS"), "council mode cannot masquerade as local or single-provider routing")
	AppState.set_provider_identity("fake", "local-deterministic")
	_check(layer.get_privacy_status().contains("NO PROVIDER EGRESS"), "privacy field distinguishes offline mode")

	var expected_targets := {
		"TemporalRibbon/PreviousTarget": "cognition:previous",
		"TemporalRibbon/ModeTarget": "cognition:mode",
		"TemporalRibbon/NextTarget": "cognition:next",
	}
	for node_path in expected_targets:
		var target := layer.get_node(node_path) as SpatialActionTarget
		_check(target.get_interaction_target_id() == str(expected_targets[node_path]), "%s is a hand-addressable temporal control" % node_path)

	layer.set_blocked(true)
	_check(not layer.visible, "approval mode can physically suppress the cognition surface")
	layer.set_blocked(false)
	_check(layer.visible, "cognition surface returns after the safety gate resolves")

	if not _failed:
		print("[TEST] Spatial cognition, temporal lens, and privacy field checks passed")
	main.queue_free()
	get_tree().quit(1 if _failed else 0)


func _check(condition: bool, description: String) -> void:
	if condition:
		return
	_failed = true
	push_error("[TEST] Failed: %s" % description)
