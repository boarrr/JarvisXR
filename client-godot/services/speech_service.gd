class_name SpeechService
extends Node

signal listening_changed(state: String)
signal partial_transcript(text: String)
signal final_transcript(text: String)
signal failed(code: String, message: String)

const STATE_IDLE := "idle"
const STATE_LISTENING := "listening"
const STATE_TRANSCRIBING := "transcribing"
const STATE_UNAVAILABLE := "unavailable"
const STATE_ERROR := "error"

var _state: String = STATE_IDLE


func is_available() -> bool:
	return false


func get_unavailable_reason() -> String:
	return "Speech service is not configured"


func get_state() -> String:
	return _state


func start_listening() -> bool:
	return false


func stop_listening() -> bool:
	return false


func cancel() -> void:
	_set_state(STATE_IDLE)


func _set_state(value: String) -> void:
	if _state == value:
		return
	_state = value
	listening_changed.emit(value)


func _fail(code: String, message: String) -> void:
	_set_state(STATE_ERROR)
	failed.emit(code, message)
