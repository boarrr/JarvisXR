class_name DictationStub
extends RefCounted

signal partial_transcript(text: String)
signal final_transcript(text: String)
signal dictation_failed(code: String, message: String)

var started: int = 0
var stopped: int = 0
var cancelled: int = 0


func start_dictation() -> void:
	started += 1


func stop_dictation() -> void:
	stopped += 1


func cancel_dictation() -> void:
	cancelled += 1


func emit_partial(text: String) -> void:
	partial_transcript.emit(text)


func emit_final(text: String) -> void:
	final_transcript.emit(text)


func emit_failure(code: String, message: String) -> void:
	dictation_failed.emit(code, message)
