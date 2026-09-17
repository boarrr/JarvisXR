class_name InteractionEvent
extends RefCounted

enum Type {
	HOVER_ENTER,
	HOVER_EXIT,
	SELECT,
	FOCUS,
	GRAB_BEGIN,
	GRAB_MOVE,
	GRAB_END,
	DISMISS,
	APPROVE,
	DENY,
	VOICE_BEGIN,
	VOICE_END,
	CODE_TOGGLE,
	CODE_SCROLL_UP,
	CODE_SCROLL_DOWN,
	CODE_GO_TOP,
	CODE_GO_BOTTOM,
}

enum Source {
	DESKTOP,
	HAND,
	GAZE,
	VOICE,
}

var type: Type
var target_id: String
var world_position: Variant = null
var source: Source
var timestamp_msec: int
var gesture_data: Dictionary


func _init(
	event_type: Type = Type.SELECT,
	event_target_id: String = "",
	event_source: Source = Source.DESKTOP,
	event_world_position: Variant = null,
	event_gesture_data: Dictionary = {}
) -> void:
	type = event_type
	target_id = event_target_id
	source = event_source
	world_position = event_world_position
	gesture_data = event_gesture_data.duplicate(true)
	timestamp_msec = Time.get_ticks_msec()
