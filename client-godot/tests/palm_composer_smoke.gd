extends Node

var _failed := false


func _ready() -> void:
	call_deferred("_run")


func _key(unicode: int, keycode: int) -> InputEventKey:
	var event := InputEventKey.new()
	event.pressed = true
	event.keycode = keycode
	event.unicode = unicode
	return event


func _run() -> void:
	var main_scene := load("res://scenes/app/main.tscn") as PackedScene
	var main := main_scene.instantiate()
	add_child(main)
	var palm := main.get_node("PalmConsole") as PalmConsole
	var transport := main.get_node("BackendBridge/FakeBackendTransport") as FakeBackendTransport
	AppState.focus_thread("thread_demo")
	transport.advance_streams(10.0)

	# Selecting the field begins typing.
	main._on_interaction_event(InteractionEvent.new(
		InteractionEvent.Type.SELECT, "palm:input_focus", InteractionEvent.Source.HAND, null, {}
	))
	_check(palm.is_typing(), "selecting the input field starts typing mode")
	_check(AppState.text_input_active, "typing mode raises the global text-input gate")

	# Typing appends; backspace removes.
	palm._unhandled_input(_key(104, KEY_H))
	palm._unhandled_input(_key(105, KEY_I))
	_check(palm.get_draft() == "hi", "hardware keys append to the composer field")
	palm._unhandled_input(_key(0, KEY_BACKSPACE))
	_check(palm.get_draft() == "h", "backspace edits the composer field")

	# Enter submits through the router to the focused thread.
	var before := AppState.get_thread("thread_demo").messages.size()
	palm._unhandled_input(_key(0, KEY_ENTER))
	_check(not palm.is_typing(), "submitting leaves typing mode")
	_check(not AppState.text_input_active, "submitting clears the text-input gate")
	_check(palm.get_draft() == "", "composer clears after submit")
	transport.advance_streams(10.0)
	var thread := AppState.get_thread("thread_demo")
	_check(thread.messages.size() > before, "submitted text reaches the agent thread")

	# Escape cancels.
	main._on_interaction_event(InteractionEvent.new(
		InteractionEvent.Type.SELECT, "palm:input_focus", InteractionEvent.Source.HAND, null, {}
	))
	palm._unhandled_input(_key(0, KEY_ESCAPE))
	_check(not palm.is_typing(), "escape exits typing mode")

	# SPEAK target still routes to voice.
	var speak := palm.get_node("TalkTarget") as SpatialActionTarget
	_check(speak != null and speak.target_id == "palm:voice_toggle", "SPEAK target still drives voice")

	# On-screen keyboard appears when no hardware keyboard has been seen.
	var keyboard := main.get_node("SpatialKeyboard") as SpatialKeyboard
	main._on_interaction_event(InteractionEvent.new(
		InteractionEvent.Type.SELECT, "palm:input_focus", InteractionEvent.Source.HAND, null, {}
	))
	_check(keyboard.is_open(), "on-screen keyboard opens when no hardware keyboard is present")
	_click(main, "kbd:k:q")
	_click(main, "kbd:special:space")
	_click(main, "kbd:k:w")
	_check(palm.get_draft() == "q w", "on-screen keys append to the composer")
	_click(main, "kbd:special:backspace")
	_check(palm.get_draft() == "q ", "on-screen backspace edits the composer")
	_click(main, "kbd:special:enter")
	_check(not keyboard.is_open(), "on-screen ENTER submits and hides the keyboard")

	if not _failed:
		print("[TEST] Palm composer checks passed")
	main.queue_free()
	get_tree().quit(1 if _failed else 0)


func _click(main: Node, target_id: String) -> void:
	main._on_interaction_event(InteractionEvent.new(
		InteractionEvent.Type.SELECT, target_id, InteractionEvent.Source.HAND, null, {}
	))


func _check(condition: bool, description: String) -> void:
	if condition:
		return
	_failed = true
	push_error("[TEST] Failed: %s" % description)
