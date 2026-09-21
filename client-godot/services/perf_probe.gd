class_name PerfProbe
extends Node

## Collects frame-time statistics and prints one machine-readable line per
## window so a headset session can be measured from logcat:
##   adb logcat -d | grep "PERF "

@export_range(1.0, 60.0, 1.0) var report_interval_seconds: float = 10.0
@export_range(30, 1024, 1) var max_samples: int = 900

var _enabled := false
var _elapsed := 0.0
var _samples: PackedFloat32Array = PackedFloat32Array()
var _fps_sum := 0.0
var _fps_count := 0
var _reports := 0
var _last_report: Dictionary = {}


func _ready() -> void:
	_enabled = bool(ProjectSettings.get_setting("spatial_agent/perf_probe", true))
	set_process(_enabled)


func _process(delta: float) -> void:
	var frame_ms := delta * 1000.0
	if _samples.size() >= max_samples:
		_samples.remove_at(0)
	_samples.append(frame_ms)
	_fps_sum += float(Engine.get_frames_per_second())
	_fps_count += 1
	_elapsed += delta
	if _elapsed >= report_interval_seconds:
		_elapsed = 0.0
		_emit_report()


func _emit_report() -> void:
	if _samples.is_empty():
		return
	var sorted := _samples.duplicate()
	sorted.sort()
	var p95_index := clampi(int(ceil(float(sorted.size()) * 0.95)) - 1, 0, sorted.size() - 1)
	var average_fps := _fps_sum / maxf(1.0, float(_fps_count))
	var payload := {
		"fps_avg": snappedf(average_fps, 0.1),
		"frame_ms_p95": snappedf(sorted[p95_index], 0.01),
		"draw_calls": int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)),
		"static_mem_mb": snappedf(Performance.get_monitor(Performance.MEMORY_STATIC) / 1048576.0, 0.1),
		"interactables": get_tree().get_nodes_in_group("interactable").size(),
		"threads": AppState.ordered_thread_ids.size(),
		"ui_mode": AppState.ui_mode,
	}
	_last_report = payload
	_reports += 1
	print("PERF %s" % JSON.stringify(payload))
	_samples.clear()
	_fps_sum = 0.0
	_fps_count = 0


func get_summary_line() -> String:
	if _last_report.is_empty():
		return "PERF: waiting for the first window"
	return "PERF: %s fps · %s ms p95 · %s draws" % [
		str(_last_report.get("fps_avg", "?")),
		str(_last_report.get("frame_ms_p95", "?")),
		str(_last_report.get("draw_calls", "?")),
	]


func sample_count() -> int:
	return _samples.size()


func report_count() -> int:
	return _reports
