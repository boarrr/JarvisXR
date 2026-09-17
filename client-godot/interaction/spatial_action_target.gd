class_name SpatialActionTarget
extends Area3D

@export var target_id: String = ""


func get_interaction_target_id() -> String:
	if not is_visible_in_tree():
		return ""
	return target_id
