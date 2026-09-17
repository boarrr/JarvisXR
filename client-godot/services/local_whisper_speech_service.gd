class_name LocalWhisperSpeechService
extends SpeechService

const CAPTURE_DIRECTORY := "user://spatial_agent_voice"
const CAPTURE_BUS_NAME := "SpatialAgentSpeechCapture"

@export var enabled: bool = false
@export var whisper_cli_path: String = "whisper-cli"
@export var whisper_model_path: String = ""
@export var language: String = "auto"
@export_range(1.0, 60.0, 1.0) var max_recording_seconds: float = 20.0
@export var retain_recordings: bool = false

var _capture_player: AudioStreamPlayer = null
var _record_effect: AudioEffectRecord = null
var _capture_bus_index: int = -1
var _recording_started_msec: int = 0
var _transcription_pid: int = -1
var _active_wav_path: String = ""
var _active_output_base: String = ""
var _owns_active_wav: bool = false
var _resolved_cli_path: String = ""


func _ready() -> void:
	enabled = bool(ProjectSettings.get_setting("spatial_agent/speech_enabled", enabled))
	whisper_cli_path = str(ProjectSettings.get_setting(
		"spatial_agent/whisper_cli_path",
		whisper_cli_path
	))
	whisper_model_path = str(ProjectSettings.get_setting(
		"spatial_agent/whisper_model_path",
		whisper_model_path
	))
	if whisper_model_path.begins_with("res://") or whisper_model_path.begins_with("user://"):
		whisper_model_path = ProjectSettings.globalize_path(whisper_model_path)
	retain_recordings = bool(ProjectSettings.get_setting(
		"spatial_agent/speech_retain_recordings",
		retain_recordings
	))
	max_recording_seconds = float(ProjectSettings.get_setting(
		"spatial_agent/speech_max_recording_seconds",
		max_recording_seconds
	))
	_resolved_cli_path = _resolve_executable(whisper_cli_path)
	ServiceRegistry.speech_service = self
	if not is_available():
		_set_state(STATE_UNAVAILABLE)
	set_process(false)


func _exit_tree() -> void:
	if ServiceRegistry.speech_service == self:
		ServiceRegistry.speech_service = null
	_cleanup_capture_graph()
	_cleanup_temporary_files()


func _process(_delta: float) -> void:
	if _state == STATE_LISTENING:
		var elapsed_seconds := float(Time.get_ticks_msec() - _recording_started_msec) / 1000.0
		if elapsed_seconds >= max_recording_seconds:
			stop_listening()
		return
	if _state != STATE_TRANSCRIBING or _transcription_pid <= 0:
		return
	if OS.is_process_running(_transcription_pid):
		return
	var exit_code := OS.get_process_exit_code(_transcription_pid)
	_transcription_pid = -1
	_finish_transcription(exit_code)


func is_available() -> bool:
	return (
		enabled
		and not _resolved_cli_path.is_empty()
		and not whisper_model_path.is_empty()
		and FileAccess.file_exists(whisper_model_path)
	)


func get_unavailable_reason() -> String:
	if not enabled:
		return "Local speech is disabled in project settings"
	if _resolved_cli_path.is_empty():
		return "whisper-cli was not found"
	if whisper_model_path.is_empty():
		return "No local Whisper model is configured"
	if not FileAccess.file_exists(whisper_model_path):
		return "Configured Whisper model does not exist"
	return "Local speech is unavailable"


func start_listening() -> bool:
	if _state in [STATE_LISTENING, STATE_TRANSCRIBING]:
		return false
	if not is_available():
		_set_state(STATE_UNAVAILABLE)
		failed.emit("speech_unavailable", get_unavailable_reason())
		return false
	if not _ensure_capture_graph():
		_fail("microphone_setup_failed", "Godot could not initialize microphone capture")
		return false
	_capture_player.play()
	_record_effect.set_recording_active(true)
	_recording_started_msec = Time.get_ticks_msec()
	_set_state(STATE_LISTENING)
	set_process(true)
	return true


func stop_listening() -> bool:
	if _state != STATE_LISTENING or _record_effect == null:
		return false
	_record_effect.set_recording_active(false)
	_capture_player.stop()
	var recording := _record_effect.get_recording()
	if recording == null or recording.data.is_empty():
		_fail("empty_recording", "The microphone did not provide any audio")
		set_process(false)
		return false
	var capture_root := ProjectSettings.globalize_path(CAPTURE_DIRECTORY)
	var mkdir_error := DirAccess.make_dir_recursive_absolute(capture_root)
	if mkdir_error != OK and mkdir_error != ERR_ALREADY_EXISTS:
		_fail("capture_directory_failed", "Could not create the private speech working directory")
		set_process(false)
		return false
	var capture_id := "%d_%d" % [Time.get_unix_time_from_system(), Time.get_ticks_msec()]
	var wav_base := "%s/capture_%s" % [capture_root, capture_id]
	var save_error := recording.save_to_wav(wav_base)
	if save_error != OK:
		_fail("capture_save_failed", "Could not save the microphone recording")
		set_process(false)
		return false
	_active_wav_path = wav_base + ".wav"
	_owns_active_wav = true
	_active_output_base = "%s/transcript_%s" % [capture_root, capture_id]
	return _begin_transcription()


func transcribe_audio_file(path: String) -> bool:
	if _state in [STATE_LISTENING, STATE_TRANSCRIBING]:
		return false
	if not is_available():
		_set_state(STATE_UNAVAILABLE)
		failed.emit("speech_unavailable", get_unavailable_reason())
		return false
	var absolute_path := ProjectSettings.globalize_path(path) if path.begins_with("res://") or path.begins_with("user://") else path
	if not FileAccess.file_exists(absolute_path):
		_fail("audio_missing", "Audio file does not exist")
		return false
	var capture_root := ProjectSettings.globalize_path(CAPTURE_DIRECTORY)
	var mkdir_error := DirAccess.make_dir_recursive_absolute(capture_root)
	if mkdir_error != OK and mkdir_error != ERR_ALREADY_EXISTS:
		_fail("capture_directory_failed", "Could not create the private speech working directory")
		return false
	var capture_id := "%d_%d" % [Time.get_unix_time_from_system(), Time.get_ticks_msec()]
	_active_wav_path = absolute_path
	_owns_active_wav = false
	_active_output_base = "%s/transcript_%s" % [capture_root, capture_id]
	return _begin_transcription()


func cancel() -> void:
	if _state == STATE_LISTENING and _record_effect != null:
		_record_effect.set_recording_active(false)
		if _capture_player != null:
			_capture_player.stop()
	if _transcription_pid > 0 and OS.is_process_running(_transcription_pid):
		OS.kill(_transcription_pid)
	_transcription_pid = -1
	_cleanup_temporary_files()
	_set_state(STATE_IDLE if is_available() else STATE_UNAVAILABLE)
	set_process(false)


func _begin_transcription() -> bool:
	var arguments := PackedStringArray([
		"-m", whisper_model_path,
		"-f", _active_wav_path,
		"-l", language,
		"-np",
		"-nt",
		"-otxt",
		"-of", _active_output_base,
	])
	_transcription_pid = OS.create_process(_resolved_cli_path, arguments)
	if _transcription_pid <= 0:
		_fail("transcriber_start_failed", "Could not start the local Whisper process")
		_cleanup_temporary_files()
		set_process(false)
		return false
	_set_state(STATE_TRANSCRIBING)
	set_process(true)
	return true


func _finish_transcription(exit_code: int) -> void:
	var output_path := _active_output_base + ".txt"
	if exit_code != 0:
		_fail("transcription_failed", "Local Whisper exited with code %d" % exit_code)
		_cleanup_temporary_files()
		set_process(false)
		return
	if not FileAccess.file_exists(output_path):
		_fail("transcript_missing", "Local Whisper did not produce a transcript")
		_cleanup_temporary_files()
		set_process(false)
		return
	var transcript := FileAccess.get_file_as_string(output_path).strip_edges()
	_cleanup_temporary_files()
	if transcript.is_empty():
		_fail("empty_transcript", "No speech was recognized")
		set_process(false)
		return
	partial_transcript.emit(transcript)
	final_transcript.emit(transcript)
	_set_state(STATE_IDLE)
	set_process(false)


func _ensure_capture_graph() -> bool:
	if _capture_player != null and _record_effect != null:
		return true
	_capture_bus_index = AudioServer.get_bus_index(CAPTURE_BUS_NAME)
	if _capture_bus_index < 0:
		AudioServer.add_bus()
		_capture_bus_index = AudioServer.bus_count - 1
		AudioServer.set_bus_name(_capture_bus_index, CAPTURE_BUS_NAME)
	if _capture_bus_index < 0:
		return false
	AudioServer.set_bus_mute(_capture_bus_index, true)
	_record_effect = AudioEffectRecord.new()
	_record_effect.format = AudioStreamWAV.FORMAT_16_BITS
	AudioServer.add_bus_effect(_capture_bus_index, _record_effect)
	_capture_player = AudioStreamPlayer.new()
	_capture_player.name = "PrivateMicrophoneCapture"
	_capture_player.stream = AudioStreamMicrophone.new()
	_capture_player.bus = CAPTURE_BUS_NAME
	add_child(_capture_player)
	return true


func _cleanup_capture_graph() -> void:
	if _record_effect != null and _record_effect.is_recording_active():
		_record_effect.set_recording_active(false)
	if _capture_player != null:
		_capture_player.stop()
		_capture_player.queue_free()
		_capture_player = null
	if _capture_bus_index >= 0:
		var effect_count := AudioServer.get_bus_effect_count(_capture_bus_index)
		for effect_index in range(effect_count - 1, -1, -1):
			if AudioServer.get_bus_effect(_capture_bus_index, effect_index) == _record_effect:
				AudioServer.remove_bus_effect(_capture_bus_index, effect_index)
	_record_effect = null


func _cleanup_temporary_files() -> void:
	if _owns_active_wav and not retain_recordings and not _active_wav_path.is_empty() and FileAccess.file_exists(_active_wav_path):
		DirAccess.remove_absolute(_active_wav_path)
	var output_path := _active_output_base + ".txt"
	if not _active_output_base.is_empty() and FileAccess.file_exists(output_path):
		DirAccess.remove_absolute(output_path)
	_active_wav_path = ""
	_active_output_base = ""
	_owns_active_wav = false


func _resolve_executable(candidate: String) -> String:
	if candidate.is_absolute_path():
		return candidate if FileAccess.file_exists(candidate) else ""
	for directory in OS.get_environment("PATH").split(":", false):
		var path := directory.path_join(candidate)
		if FileAccess.file_exists(path):
			return path
	return ""
