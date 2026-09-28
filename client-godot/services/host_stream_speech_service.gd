class_name HostStreamSpeechService
extends SpeechService

## Streams microphone PCM to the daemon, which transcribes it with whisper and
## returns the final text. Only text crosses back; audio stays on the LAN.

const TARGET_RATE := 16000
const CHUNK_SAMPLES := 1600  # ~100 ms at 16 kHz
const MAX_LISTEN_MSEC := 30000
const MIC_BUS := "SpatialAgentMic"

@export var backend_bridge_path: NodePath = ^"../BackendBridge"
@export var auto_endpoint: bool = true
@export_range(300, 3000, 50) var silence_ms: int = 900
@export_range(0.005, 0.2, 0.005) var speech_rms_threshold: float = 0.02
@export var barge_in: bool = true

var _bridge: Node = null
var _mic_player: AudioStreamPlayer = null
var _capture: AudioEffectCapture = null
var _source := PackedFloat32Array()
var _resample_pos := 0.0
var _pending := PackedByteArray()
var _sequence := 0
var _mix_rate := 44100.0
var _listen_started_msec := 0
var _last_voice_msec := 0
var _speech_activity := false


func _ready() -> void:
	_bridge = get_node_or_null(backend_bridge_path)
	if _bridge != null and _bridge.has_signal("backend_event_applied"):
		_bridge.backend_event_applied.connect(_on_backend_event)
	_setup_capture()
	ServiceRegistry.speech_service = self
	if not is_available():
		_set_state(STATE_UNAVAILABLE)
	set_process(false)


func _exit_tree() -> void:
	if ServiceRegistry.speech_service == self:
		ServiceRegistry.speech_service = null


func is_available() -> bool:
	return _bridge != null and _capture != null


func get_unavailable_reason() -> String:
	return "Host speech needs an audio capture bus and a daemon link"


func start_listening() -> bool:
	if not is_available():
		_set_state(STATE_UNAVAILABLE)
		failed.emit("speech_unavailable", get_unavailable_reason())
		return false
	if _state in [STATE_LISTENING, STATE_TRANSCRIBING]:
		return false
	_sequence = 0
	_source = PackedFloat32Array()
	_resample_pos = 0.0
	_pending = PackedByteArray()
	_speech_activity = false
	_listen_started_msec = Time.get_ticks_msec()
	_last_voice_msec = _listen_started_msec
	if _capture != null:
		_capture.clear_buffer()
	# Barge-in: talking cancels the agent's current run.
	if barge_in:
		var thread := AppState.get_thread(AppState.focused_thread_id)
		if thread != null and thread.status == AgentThread.Status.WORKING:
			_bridge.send_command("run.cancel", {}, AppState.focused_thread_id)
	_bridge.send_command(
		"voice.audio.start",
		{"sample_rate": TARGET_RATE, "channels": 1},
		AppState.focused_thread_id
	)
	_mic_player.play()
	_set_state(STATE_LISTENING)
	set_process(true)
	return true


func stop_listening() -> bool:
	if _state != STATE_LISTENING:
		return false
	_flush_pending(true)
	set_process(false)
	_mic_player.stop()
	if _bridge != null:
		_bridge.send_command("voice.audio.end", {}, AppState.focused_thread_id)
	_set_state(STATE_TRANSCRIBING)
	return true


func cancel() -> void:
	set_process(false)
	if _mic_player != null:
		_mic_player.stop()
	if _bridge != null and _state in [STATE_LISTENING, STATE_TRANSCRIBING]:
		_bridge.send_command("voice.audio.cancel", {}, AppState.focused_thread_id)
	_set_state(STATE_IDLE)


func _process(_delta: float) -> void:
	if _state != STATE_LISTENING or _capture == null:
		return
	var available := _capture.get_frames_available()
	if available > 0:
		_append_frames(_capture.get_buffer(available))
		_flush_pending(false)
	var now := Time.get_ticks_msec()
	if now - _listen_started_msec > MAX_LISTEN_MSEC:
		stop_listening()
		return
	if not _speech_activity and now - _listen_started_msec > 6000:
		# Nothing said: end quietly instead of holding the mic forever.
		stop_listening()
		return
	# Endpoint on silence so a single TALK tap ends the turn naturally.
	if auto_endpoint and _speech_activity and now - _last_voice_msec > silence_ms:
		stop_listening()


func _setup_capture() -> void:
	_mix_rate = float(AudioServer.get_mix_rate())
	var mic_bus_index := AudioServer.get_bus_index(MIC_BUS)
	if mic_bus_index < 0:
		mic_bus_index = AudioServer.bus_count
		AudioServer.add_bus(mic_bus_index)
		AudioServer.set_bus_name(mic_bus_index, MIC_BUS)
		var effect := AudioEffectCapture.new()
		effect.buffer_length = 2.0
		AudioServer.add_bus_effect(mic_bus_index, effect)
	# Do not play the microphone back to the user (avoid feedback).
	AudioServer.set_bus_volume_db(mic_bus_index, -80.0)
	AudioServer.set_bus_mute(mic_bus_index, true)
	_capture = AudioServer.get_bus_effect(mic_bus_index, 0) as AudioEffectCapture

	_mic_player = AudioStreamPlayer.new()
	_mic_player.stream = AudioStreamMicrophone.new()
	_mic_player.bus = MIC_BUS
	add_child(_mic_player)


func _append_frames(frames: PackedVector2Array) -> void:
	for frame in frames:
		_source.append((frame.x + frame.y) * 0.5)
	# Resample the accumulated mono buffer to 16 kHz.
	var ratio := _mix_rate / float(TARGET_RATE)
	while _resample_pos + 1.0 < float(_source.size()):
		var index := int(_resample_pos)
		var fraction := _resample_pos - float(index)
		var sample := lerpf(_source[index], _source[index + 1], fraction)
		var clamped := int(round(clampf(sample, -1.0, 1.0) * 32767.0))
		_pending.append(clamped & 0xFF)
		_pending.append((clamped >> 8) & 0xFF)
		_resample_pos += ratio
	var consumed := int(_resample_pos)
	if consumed > 0:
		_source = _source.slice(consumed)
		_resample_pos -= float(consumed)


func _flush_pending(force: bool) -> void:
	if _pending.is_empty():
		return
	var chunk_bytes := CHUNK_SAMPLES * 2
	if not force and _pending.size() < chunk_bytes:
		return
	while _pending.size() > 0:
		var take := mini(chunk_bytes, _pending.size())
		var chunk := _pending.slice(0, take)
		_pending = _pending.slice(take)
		_track_activity(chunk)
		_sequence += 1
		_bridge.send_command(
			"voice.audio.chunk",
			{"data": Marshalls.raw_to_base64(chunk), "seq": _sequence},
			AppState.focused_thread_id
		)


func _track_activity(chunk: PackedByteArray) -> void:
	var count := chunk.size() / 2
	if count <= 0:
		return
	var sum := 0.0
	for index in range(count):
		var raw := chunk[index * 2] | (chunk[index * 2 + 1] << 8)
		if raw > 32767:
			raw -= 65536
		var sample := float(raw) / 32768.0
		sum += sample * sample
	var rms := sqrt(sum / float(count))
	if rms >= speech_rms_threshold:
		_speech_activity = true
		_last_voice_msec = Time.get_ticks_msec()


func _on_backend_event(event: BackendEvent) -> void:
	if event == null:
		return
	match event.type:
		"voice.final":
			if _state not in [STATE_LISTENING, STATE_TRANSCRIBING]:
				return
			_set_state(STATE_IDLE)
			var text := str(event.payload.get("transcript", "")).strip_edges()
			if text.is_empty():
				failed.emit("empty_transcript", "The recognizer returned no text")
			else:
				final_transcript.emit(text)
		"voice.error":
			if _state in [STATE_LISTENING, STATE_TRANSCRIBING]:
				_set_state(STATE_ERROR)
				failed.emit(
					str(event.payload.get("code", "voice_error")),
					str(event.payload.get("message", "Voice failed"))
				)
