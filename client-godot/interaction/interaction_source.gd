class_name InteractionSource
extends Node

signal pointer_state_changed(state: PointerState)
signal interaction_event(event: Variant)

@export var source_name: String = "unknown"


func is_available() -> bool:
	return false


func get_pointer_state() -> PointerState:
	return null


func set_hover_target_id(_target_id: String) -> void:
	pass
