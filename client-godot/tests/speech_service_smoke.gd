extends Node

var _failed := false
var _transcript := ""
var _failure_code := ""


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	ProjectSettings.set_setting("spatial_agent/speech_enabled", true)
	ProjectSettings.set_setting(
		"spatial_agent/whisper_cli_path",
		ProjectSettings.globalize_path("res://tests/support/fake_whisper_cli.sh")
	)
	ProjectSettings.set_setting(
		"spatial_agent/whisper_model_path",
		ProjectSettings.globalize_path("res://tests/support/fake_whisper_model.bin")
	)
	var service := LocalWhisperSpeechService.new()
	service.final_transcript.connect(_on_final_transcript)
	service.failed.connect(_on_failure)
	add_child(service)
	_check(service.is_available(), "configured local speech service is available")
	_check(
		service.transcribe_audio_file("res://tests/support/fake_audio.bin"),
		"audio transcription starts asynchronously"
	)
	_check(service.get_state() == SpeechService.STATE_TRANSCRIBING, "service enters transcribing state")
	var deadline := Time.get_ticks_msec() + 5000
	while _transcript.is_empty() and _failure_code.is_empty() and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
	_check(_failure_code.is_empty(), "local transcription does not fail")
	_check(_transcript == "Private local speech transcript", "final local transcript is emitted")
	_check(service.get_state() == SpeechService.STATE_IDLE, "service returns to idle")
	_check(FileAccess.file_exists("res://tests/support/fake_audio.bin"), "caller-owned audio is retained")

	var voice_begin := InputEventAction.new()
	voice_begin.action = "push_to_talk"
	voice_begin.pressed = true
	var voice_end := InputEventAction.new()
	voice_end.action = "push_to_talk"
	voice_end.pressed = false
	var interaction_source := DesktopInteractionSource.new()
	interaction_source.interaction_event.connect(_on_interaction_event)
	interaction_source._input(voice_begin)
	interaction_source._input(voice_end)
	_check(_voice_events == [InteractionEvent.Type.VOICE_BEGIN, InteractionEvent.Type.VOICE_END], "push-to-talk maps to semantic voice events")
	interaction_source.free()
	voice_begin = null
	voice_end = null
	_voice_events.clear()

	if not _failed:
		print("[TEST] Local speech boundary checks passed")
	service.queue_free()
	await get_tree().process_frame
	get_tree().quit(1 if _failed else 0)


var _voice_events: Array[InteractionEvent.Type] = []


func _on_final_transcript(value: String) -> void:
	_transcript = value


func _on_failure(code: String, _message: String) -> void:
	_failure_code = code


func _on_interaction_event(event: InteractionEvent) -> void:
	_voice_events.append(event.type)


func _check(condition: bool, description: String) -> void:
	if condition:
		return
	_failed = true
	push_error("[TEST] Failed: %s" % description)
