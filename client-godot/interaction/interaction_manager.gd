class_name InteractionManager
extends Node3D

signal interaction_event(event: InteractionEvent)

@export_range(0.5, 100.0, 0.5) var ray_distance: float = 20.0
@export_flags_3d_physics var interaction_mask: int = 2

var _interaction_source: InteractionSource = null
var _hovered_target_id: String = ""
var _was_selecting: bool = false


func set_interaction_source(source: InteractionSource) -> bool:
	if source == null or not source.is_available():
		push_warning("[INPUT] InteractionManager rejected an unavailable source")
		return false
	if _interaction_source != null and _interaction_source.interaction_event.is_connected(_on_source_interaction_event):
		_interaction_source.interaction_event.disconnect(_on_source_interaction_event)
	_interaction_source = source
	_interaction_source.interaction_event.connect(_on_source_interaction_event)
	var pointer_state := source.get_pointer_state()
	_was_selecting = pointer_state.is_selecting if pointer_state != null else false
	_interaction_source.set_hover_target_id("")
	return true


func get_interaction_source() -> InteractionSource:
	return _interaction_source


func _physics_process(_delta: float) -> void:
	if _interaction_source == null or not _interaction_source.is_available():
		_update_hover_target("", null)
		_was_selecting = false
		return
	if _interaction_source is OpenXRInteractionSource and not _interaction_source.has_tracking_data():
		_update_hover_target("", null)
		_was_selecting = false
		return

	var pointer_state := _interaction_source.get_pointer_state()
	if pointer_state == null:
		_update_hover_target("", null)
		_was_selecting = false
		return

	var hit := _cast_pointer_ray(pointer_state)
	var target_id := _target_id_from_hit(hit)
	var hit_position: Variant = hit.get("position") if not hit.is_empty() else null
	_update_hover_target(target_id, hit_position)

	if (
		pointer_state.is_selecting
		and not _was_selecting
		and not pointer_state.is_grabbing
		and not target_id.is_empty()
	):
		_emit_event(InteractionEvent.Type.SELECT, target_id, hit_position)
	_was_selecting = pointer_state.is_selecting


func _cast_pointer_ray(pointer_state: PointerState) -> Dictionary:
	var ray_end := pointer_state.origin + pointer_state.direction * ray_distance
	var query := PhysicsRayQueryParameters3D.create(
		pointer_state.origin,
		ray_end,
		interaction_mask
	)
	query.collide_with_areas = true
	query.collide_with_bodies = false
	query.hit_from_inside = true
	var excluded: Array[RID] = []
	# Invisible menus still have collision shapes. Skip them so closing a
	# surface cannot leave an invisible wall between the hand and an agent.
	for _attempt in range(64):
		var hit := get_world_3d().direct_space_state.intersect_ray(query)
		if hit.is_empty():
			return {}
		if not _target_id_from_hit(hit).is_empty():
			return hit
		var collider := hit.get("collider") as CollisionObject3D
		if collider == null:
			return {}
		excluded.append(collider.get_rid())
		query.exclude = excluded
	return {}


func _target_id_from_hit(hit: Dictionary) -> String:
	if hit.is_empty():
		return ""
	var collider := hit.get("collider") as Node
	if collider == null or not collider.is_in_group("interactable"):
		return ""
	if not collider.has_method("get_interaction_target_id"):
		return ""
	return str(collider.call("get_interaction_target_id"))


func _update_hover_target(target_id: String, world_position: Variant) -> void:
	if target_id == _hovered_target_id:
		return
	if not _hovered_target_id.is_empty():
		_emit_event(InteractionEvent.Type.HOVER_EXIT, _hovered_target_id, null)
	_hovered_target_id = target_id
	if _interaction_source != null:
		_interaction_source.set_hover_target_id(target_id)
	if not _hovered_target_id.is_empty():
		_emit_event(InteractionEvent.Type.HOVER_ENTER, _hovered_target_id, world_position)


func _emit_event(event_type: InteractionEvent.Type, target_id: String, world_position: Variant) -> void:
	var event_source := InteractionEvent.Source.DESKTOP
	if _interaction_source is OpenXRInteractionSource:
		event_source = InteractionEvent.Source.HAND
	var event := InteractionEvent.new(event_type, target_id, event_source, world_position)
	interaction_event.emit(event)


func _on_source_interaction_event(event: InteractionEvent) -> void:
	interaction_event.emit(event)
