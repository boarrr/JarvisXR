class_name PointerState
extends RefCounted

var origin: Vector3 = Vector3.ZERO
var direction: Vector3 = Vector3.FORWARD
var target_id: String = ""
var hit_position: Variant = null
var is_selecting: bool = false
var is_grabbing: bool = false


func copy() -> PointerState:
	var duplicate_state := PointerState.new()
	duplicate_state.origin = origin
	duplicate_state.direction = direction
	duplicate_state.target_id = target_id
	duplicate_state.hit_position = hit_position
	duplicate_state.is_selecting = is_selecting
	duplicate_state.is_grabbing = is_grabbing
	return duplicate_state

