class_name HolographicReticle
extends Control

var _phase: float = 0.0


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	AppState.hovered_target_changed.connect(_on_visual_state_changed)
	AppState.listening_state_changed.connect(_on_visual_state_changed)
	queue_redraw()


func _process(delta: float) -> void:
	_phase = fmod(_phase + delta * 0.65, TAU)
	queue_redraw()


func _draw() -> void:
	var center := size * 0.5
	var has_target := not AppState.hovered_target_id.is_empty()
	var listening := AppState.listening_state == SpeechService.STATE_LISTENING
	var color := Color(0.18, 1.0, 0.74, 0.96) if listening else Color(0.06, 0.88, 1.0, 0.94)
	if has_target:
		color = Color(0.48, 0.98, 1.0, 1.0)
	var radius := 8.0 if has_target else 10.0
	draw_circle(center, 1.5, color)
	draw_arc(center, radius, 0.0, TAU, 48, Color(color.r, color.g, color.b, 0.72), 1.2, true)
	for quadrant in range(4):
		var start := _phase + float(quadrant) * TAU / 4.0
		draw_arc(center, radius + 6.0, start, start + 0.42, 10, Color(color.r, color.g, color.b, 0.78), 1.5, true)
	for axis in [Vector2.LEFT, Vector2.RIGHT, Vector2.UP, Vector2.DOWN]:
		draw_line(center + axis * (radius + 2.0), center + axis * (radius + 6.0), color, 1.0, true)


func _on_visual_state_changed(_value: Variant) -> void:
	queue_redraw()
