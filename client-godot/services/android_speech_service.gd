class_name AndroidSpeechService
extends SpeechService

## Android on-device dictation adapter.
##
## Speaks to the optional "AndroidDictation" Godot Android plugin, which wraps
## android.speech.SpeechRecognizer. Only finalized text crosses into the
## protocol; raw audio never leaves the OS speech service. When the plugin is
## not installed (for example on desktop builds) this adapter reports itself
## unavailable and the workspace falls back to quick intents.

const SINGLETON_NAME := "AndroidDictation"

## Injectable native bridge. Defaults to the engine singleton when present.
var bridge: Object = null


func _ready() -> void:
	if bridge == null and Engine.has_singleton(SINGLETON_NAME):
		bridge = Engine.get_singleton(SINGLETON_NAME)
	if bridge != null:
		if bridge.has_signal("partial_transcript"):
			bridge.connect("partial_transcript", _on_native_partial)
		if bridge.has_signal("final_transcript"):
			bridge.connect("final_transcript", _on_native_final)
		if bridge.has_signal("dictation_failed"):
			bridge.connect("dictation_failed", _on_native_failed)
	ServiceRegistry.speech_service = self
	if not is_available():
		_set_state(STATE_UNAVAILABLE)


func _exit_tree() -> void:
	if ServiceRegistry.speech_service == self:
		ServiceRegistry.speech_service = null


func is_available() -> bool:
	return bridge != null


func get_unavailable_reason() -> String:
	return "Android on-device dictation is not installed in this build"


func start_listening() -> bool:
	if not is_available() or _state in [STATE_LISTENING, STATE_TRANSCRIBING]:
		if not is_available():
			_set_state(STATE_UNAVAILABLE)
			failed.emit("speech_unavailable", get_unavailable_reason())
		return false
	_invoke_bridge(["startDictation", "start_dictation"])
	_set_state(STATE_LISTENING)
	return true


func stop_listening() -> bool:
	if _state != STATE_LISTENING:
		return false
	_set_state(STATE_TRANSCRIBING)
	_invoke_bridge(["stopDictation", "stop_dictation"])
	return true


func cancel() -> void:
	if _state in [STATE_LISTENING, STATE_TRANSCRIBING]:
		_invoke_bridge(["cancelDictation", "cancel_dictation"])
	_set_state(STATE_IDLE)


func _invoke_bridge(method_names: Array) -> bool:
	if bridge == null:
		return false
	for method_name in method_names:
		if bridge.has_method(str(method_name)):
			bridge.call(str(method_name))
			return true
	return false


func _on_native_partial(text: String) -> void:
	if _state == STATE_LISTENING:
		partial_transcript.emit(text)


func _on_native_final(text: String) -> void:
	if _state not in [STATE_LISTENING, STATE_TRANSCRIBING]:
		return
	_set_state(STATE_IDLE)
	if text.strip_edges().is_empty():
		_fail("empty_recording", "The speech service returned no transcript")
		return
	final_transcript.emit(text.strip_edges())


func _on_native_failed(code: String, message: String) -> void:
	_fail(code if not code.is_empty() else "dictation_error", message)
