extends Node

var _failed := false


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	var main := (load("res://scenes/app/main.tscn") as PackedScene).instantiate()
	add_child(main)
	var panel := main.get_node("QuickIntentPanel") as QuickIntentPanel
	var palm_console := main.get_node("PalmConsole") as PalmConsole
	_check(panel != null and not panel.visible, "quick intent panel starts hidden")
	_check(palm_console != null and not palm_console.visible, "palm console stays hidden in desktop mode")
	_check((palm_console.get_node("CognitionTarget") as SpatialActionTarget).target_id == "palm:cognition_toggle", "palm console exposes the cognition lens as a hand target")
	_check(AppState.focus_thread("thread_demo"), "a thread can be focused before a hand intent")

	var palm_event := InteractionEvent.new(
		InteractionEvent.Type.SELECT,
		"palm:voice_toggle",
		InteractionEvent.Source.HAND,
		null,
		{"gesture": "pinch"}
	)
	# Force the hand-only fallback deterministically: swap in an unavailable
	# speech service so ASK/VOICE reveals the quick intent panel.
	var unavailable := SpeechService.new()
	unavailable.name = "UnavailableSpeechService"
	main.add_child(unavailable)
	main._speech_service = unavailable
	main._on_interaction_event(palm_event)
	_check(panel.visible, "ASK / VOICE falls back to hand-only quick intents when speech is unavailable")

	var expected_targets := {
		"ContinueTarget": "quick:continue",
		"SummarizeTarget": "quick:summarize",
		"ExplainTarget": "quick:explain_code",
		"PrivacyTarget": "quick:privacy_review",
	}
	for node_name in expected_targets:
		var target := panel.get_node(node_name) as SpatialActionTarget
		var target_id := str(expected_targets[node_name])
		_check(target.get_interaction_target_id() == target_id, "%s is a semantic pinch target" % target_id)
		_check(not panel.get_prompt(target_id).is_empty(), "%s resolves to a fixed labeled intent" % target_id)

	panel.close()
	_check(not panel.visible, "quick intent panel dismisses without changing the thread")
	_check(AppState.focused_thread_id == "thread_demo", "dismissing quick intents preserves focus")

	if not _failed:
		print("[TEST] Hand-only quick intent checks passed")
	main.queue_free()
	get_tree().quit(1 if _failed else 0)


func _check(condition: bool, description: String) -> void:
	if condition:
		return
	_failed = true
	push_error("[TEST] Failed: %s" % description)
