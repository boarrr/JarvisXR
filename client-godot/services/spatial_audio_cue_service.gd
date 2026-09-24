class_name SpatialAudioCueService
extends Node3D

signal cue_emitted(cue: Dictionary)

const SAMPLE_RATE := 22050
const CUES := {
	"focus": {"frequency_hz": 620.0, "end_frequency_hz": 780.0, "duration": 0.10, "gain_db": -17.0},
	"working": {"frequency_hz": 390.0, "end_frequency_hz": 455.0, "duration": 0.08, "gain_db": -22.0},
	"complete": {"frequency_hz": 540.0, "end_frequency_hz": 880.0, "duration": 0.16, "gain_db": -15.0},
	"attention": {"frequency_hz": 310.0, "end_frequency_hz": 310.0, "duration": 0.19, "gain_db": -13.0},
	"approval": {"frequency_hz": 220.0, "end_frequency_hz": 660.0, "duration": 0.24, "gain_db": -11.0},
	"error": {"frequency_hz": 190.0, "end_frequency_hz": 120.0, "duration": 0.26, "gain_db": -10.0},
	"veil_on": {"frequency_hz": 720.0, "end_frequency_hz": 180.0, "duration": 0.18, "gain_db": -14.0},
	"veil_off": {"frequency_hz": 260.0, "end_frequency_hz": 760.0, "duration": 0.18, "gain_db": -16.0},
}

@export var orb_manager_path: NodePath = ^"../OrbManager"
@onready var _player: AudioStreamPlayer3D = $CuePlayer

var _orb_manager: OrbManager = null
var _last_status_by_thread: Dictionary = {}
var _last_cue: Dictionary = {}
var _cue_streams: Dictionary = {}


func _ready() -> void:
	_orb_manager = get_node_or_null(orb_manager_path) as OrbManager
	AppState.focused_thread_changed.connect(_on_focused_thread_changed)
	AppState.thread_updated.connect(_on_thread_updated)
	AppState.approval_requested.connect(_on_approval_requested)
	for thread_id in AppState.ordered_thread_ids:
		var thread := AppState.get_thread(thread_id)
		if thread != null:
			_last_status_by_thread[thread.id] = thread.status


func emit_cue(cue_name: String, world_position: Vector3 = Vector3.ZERO) -> bool:
	if not bool(ProjectSettings.get_setting("spatial_agent/spatial_audio_enabled", true)):
		return false
	if not CUES.has(cue_name):
		return false
	var definition: Dictionary = CUES[cue_name]
	if not _cue_streams.has(cue_name):
		_cue_streams[cue_name] = _synthesize(
			float(definition["frequency_hz"]),
			float(definition["end_frequency_hz"]),
			float(definition["duration"])
		)
	var stream: AudioStreamWAV = _cue_streams[cue_name]
	_player.global_position = world_position
	_player.volume_db = float(definition["gain_db"])
	_player.stream = stream
	if DisplayServer.get_name() != "headless":
		_player.play()
	_last_cue = {
		"name": cue_name,
		"frequency_hz": definition["frequency_hz"],
		"end_frequency_hz": definition["end_frequency_hz"],
		"duration": definition["duration"],
		"world_position": world_position,
	}
	cue_emitted.emit(_last_cue.duplicate(true))
	return true


func get_last_cue() -> Dictionary:
	return _last_cue.duplicate(true)


func _exit_tree() -> void:
	_player.stop()
	_player.stream = null
	_cue_streams.clear()


func get_generated_sample_count() -> int:
	var wave := _player.stream as AudioStreamWAV
	return 0 if wave == null else wave.data.size() / 2


func _synthesize(start_frequency: float, end_frequency: float, duration: float) -> AudioStreamWAV:
	var sample_count := maxi(1, roundi(duration * SAMPLE_RATE))
	var bytes := PackedByteArray()
	bytes.resize(sample_count * 2)
	var phase := 0.0
	for index in range(sample_count):
		var progress := float(index) / float(maxi(1, sample_count - 1))
		var frequency := lerpf(start_frequency, end_frequency, progress)
		phase += TAU * frequency / float(SAMPLE_RATE)
		var envelope := pow(sin(PI * progress), 1.6)
		var harmonic := sin(phase) * 0.78 + sin(phase * 2.01) * 0.22
		var sample := clampi(roundi(harmonic * envelope * 23500.0), -32768, 32767)
		bytes.encode_s16(index * 2, sample)
	var wave := AudioStreamWAV.new()
	wave.format = AudioStreamWAV.FORMAT_16_BITS
	wave.mix_rate = SAMPLE_RATE
	wave.stereo = false
	wave.data = bytes
	return wave


func _orb_position(thread_id: String) -> Vector3:
	if _orb_manager != null:
		var orb := _orb_manager.get_orb(thread_id)
		if orb != null:
			return orb.global_position
	return global_position


func _on_focused_thread_changed(thread_id: String) -> void:
	if not thread_id.is_empty():
		emit_cue("focus", _orb_position(thread_id))


func _on_thread_updated(thread: AgentThread) -> void:
	var previous := int(_last_status_by_thread.get(thread.id, -1))
	_last_status_by_thread[thread.id] = thread.status
	if previous == thread.status:
		return
	var cue_name := ""
	match thread.status:
		AgentThread.Status.WORKING:
			cue_name = "working"
		AgentThread.Status.WAITING_USER:
			cue_name = "attention"
		AgentThread.Status.COMPLETE:
			cue_name = "complete"
		AgentThread.Status.ERROR:
			cue_name = "error"
	if not cue_name.is_empty():
		emit_cue(cue_name, _orb_position(thread.id))


func _on_approval_requested(request: Dictionary) -> void:
	emit_cue("approval", _orb_position(str(request.get("thread_id", ""))))

