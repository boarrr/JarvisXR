class_name InteractionManager
extends Node3D

signal interaction_event(event: InteractionEvent)

@export_range(0.5, 100.0, 0.5) var ray_distance: float = 20.0
@export_flags_3d_physics var interaction_mask: int = 2
# Forgiving selection for inexperienced users: if the exact ray misses, snap to
# the nearest interactable within a small cone, and optionally select by dwell.
@export_range(0.0, 20.0, 0.5) var snap_cone_degrees: float = 4.0
@export_range(0.5, 20.0, 0.5) var snap_max_distance: float = 8.0
@export var dwell_enabled: bool = true
@export_range(0.2, 2.0, 0.05) var dwell_seconds: float = 0.8
@export_range(1.0, 20.0, 0.5) var dwell_stability_degrees: float = 5.0
@export var dwell_ui_targets: bool = false

var _interaction_source: InteractionSource = null
var _hovered_target_id: String = ""
var _was_selecting: bool = false
var _dwell_target_id: String = ""
var _dwell_accum: float = 0.0
var _dwell_direction := Vector3.ZERO


func set_interaction_source(source: InteractionSource) -> bool:
	if source == null:
		push_warning("[INPUT] InteractionManager rejected a null source")
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


func _physics_process(delta: float) -> void:
	if _interaction_source == null or not _interaction_source.is_available():
		_update_hover_target("", null)
		_was_selecting = false
		_reset_dwell()
		return
	if _interaction_source is OpenXRInteractionSource and not _interaction_source.has_tracking_data():
		_update_hover_target("", null)
		_was_selecting = false
		_reset_dwell()
		return

	var pointer_state := _interaction_source.get_pointer_state()
	if pointer_state == null:
		_update_hover_target("", null)
		_was_selecting = false
		_reset_dwell()
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
		# Panels are touch-only: a pinch ray must never press a button. UI ids
		# contain ":" (world/agent targets do not). Move a pane close and touch it.
		and not ":" in target_id
	):
		_emit_event(InteractionEvent.Type.SELECT, target_id, hit_position)
		_reset_dwell()
	elif (
		dwell_enabled
		and not pointer_state.is_selecting
		and not pointer_state.is_grabbing
		and _dwell_eligible(target_id)
	):
		if target_id == _dwell_target_id:
			# Require a steady aim: wandering the ray restarts the dwell so a
			# sweep across agents never selects one.
			if (
				not _dwell_direction.is_zero_approx()
				and rad_to_deg(pointer_state.direction.angle_to(_dwell_direction))
					> dwell_stability_degrees
			):
				_dwell_accum = 0.0
				_dwell_direction = pointer_state.direction
			else:
				_dwell_accum += delta
		else:
			_dwell_target_id = target_id
			_dwell_direction = pointer_state.direction
			_dwell_accum = 0.0
		if _dwell_accum >= dwell_seconds:
			_emit_event(InteractionEvent.Type.SELECT, target_id, hit_position)
			_dwell_target_id = ""
			_dwell_accum = 0.0
	else:
		_reset_dwell()
	_was_selecting = pointer_state.is_selecting


func _dwell_eligible(target_id: String) -> bool:
	if target_id.is_empty():
		return false
	# Dwell only for world targets (agents) unless UI dwell is explicitly enabled;
	# resting a ray on a button should not fire it.
	return dwell_ui_targets or not ":" in target_id


func _reset_dwell() -> void:
	_dwell_target_id = ""
	_dwell_accum = 0.0
	_dwell_direction = Vector3.ZERO


func get_dwell_progress() -> float:
	if not dwell_enabled or _dwell_target_id.is_empty():
		return 0.0
	return clampf(_dwell_accum / maxf(dwell_seconds, 0.001), 0.0, 1.0)


func _cast_pointer_ray(pointer_state: PointerState) -> Dictionary:
	var hit := _direct_ray(pointer_state)
	if not hit.is_empty():
		return hit
	return _snap_candidate(pointer_state)


func _direct_ray(pointer_state: PointerState) -> Dictionary:
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
	var first_target: Dictionary = {}
	# Invisible menus still have collision shapes. Skip them so closing a
	# surface cannot leave an invisible wall between the hand and an agent. A
	# pending approval gate is modal, so it wins even when something occludes it.
	for _attempt in range(64):
		var hit := get_world_3d().direct_space_state.intersect_ray(query)
		if hit.is_empty():
			return first_target
		var hit_target := _target_id_from_hit(hit)
		if hit_target.begins_with("approval:"):
			return hit
		if not hit_target.is_empty() and first_target.is_empty():
			first_target = hit
		var collider := hit.get("collider") as CollisionObject3D
		if collider == null:
			return first_target
		excluded.append(collider.get_rid())
		query.exclude = excluded
	return first_target


func _snap_candidate(pointer_state: PointerState) -> Dictionary:
	if snap_cone_degrees <= 0.0:
		return {}
	var origin := pointer_state.origin
	var direction := pointer_state.direction.normalized()
	if direction.is_zero_approx():
		return {}
	var cos_limit := cos(deg_to_rad(snap_cone_degrees))
	var best := {}
	var best_angle := TAU
	for node in get_tree().get_nodes_in_group("interactable"):
		var area := node as Node3D
		if area == null or not area.visible:
			continue
		var to_target := area.global_position - origin
		var distance := to_target.length()
		if distance < 0.05 or distance > snap_max_distance:
			continue
		var dot := (to_target / distance).dot(direction)
		if dot < cos_limit:
			continue
		var angle := acos(clampf(dot, -1.0, 1.0))
		if angle < best_angle:
			best_angle = angle
			best = {"collider": area, "position": area.global_position, "snapped": true}
	return best


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
