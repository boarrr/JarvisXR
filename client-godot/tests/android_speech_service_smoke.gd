extends Node

var _failed := false
var _partials: Array[String] = []
var _finals: Array[String] = []
var _failures: Array[String] = []


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	var unavailable := AndroidSpeechService.new()
	add_child(unavailable)
	_check(not unavailable.is_available(), "adapter is unavailable without the native plugin")
	_check(
		unavailable.get_state() == SpeechService.STATE_UNAVAILABLE,
		"unavailable adapter reports its state"
	)
	_check(not unavailable.start_listening(), "start is rejected when unavailable")
	unavailable.queue_free()

	var stub := DictationStub.new()
	var service := AndroidSpeechService.new()
	service.bridge = stub
	add_child(service)
	service.partial_transcript.connect(_on_partial)
	service.final_transcript.connect(_on_final)
	service.failed.connect(_on_failure)

	_check(service.is_available(), "adapter is available with an injected bridge")
	_check(service.start_listening(), "start_listening reaches the bridge")
	_check(stub.started == 1, "native start was invoked once")
	_check(service.get_state() == SpeechService.STATE_LISTENING, "listening state is reported")

	stub.emit_partial("planned the")
	_check(_partials.size() == 1 and _partials[0] == "planned the", "partial transcripts stream through")

	_check(service.stop_listening(), "stop_listening reaches the bridge")
	_check(stub.stopped == 1, "native stop was invoked once")
	_check(service.get_state() == SpeechService.STATE_TRANSCRIBING, "stop enters transcribing state")

	stub.emit_final("planned the refactor")
	_check(_finals.size() == 1, "final transcript is emitted")
	_check(_finals[0] == "planned the refactor", "final transcript text is preserved")
	_check(service.get_state() == SpeechService.STATE_IDLE, "final transcript returns to idle")

	_check(service.start_listening(), "a second session can start")
	stub.emit_failure("dictation_error", "recognizer unavailable")
	_check(_failures.size() == 1, "native failure is surfaced")
	_check(service.get_state() == SpeechService.STATE_ERROR, "failure moves the adapter to error")

	_check(not _failed, "android dictation adapter checks completed")
	if not _failed:
		print("[TEST] Android dictation adapter checks passed")
	service.queue_free()
	get_tree().quit(1 if _failed else 0)


func _on_partial(text: String) -> void:
	_partials.append(text)


func _on_final(text: String) -> void:
	_finals.append(text)


func _on_failure(code: String, _message: String) -> void:
	_failures.append(code)


func _check(condition: bool, description: String) -> void:
	if condition:
		return
	_failed = true
	push_error("[TEST] Failed: %s" % description)
