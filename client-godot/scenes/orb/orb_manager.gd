class_name OrbManager
extends Node3D

const DEFAULT_ORB_SCENE := preload("res://scenes/orb/agent_orb.tscn")

@export var user_rig_path: NodePath = ^"../UserRig"
@export var standing_center_path: NodePath = ^"../XRRuntime/XROrigin3D"
@export var orb_scene: PackedScene = DEFAULT_ORB_SCENE
@export_range(0.5, 5.0, 0.05) var radius_from_user: float = 2.2
@export_range(-1.0, 1.0, 0.05) var vertical_offset: float = 0.0
@export_range(90.0, 240.0, 1.0) var arc_degrees: float = 200.0
@export_range(1, 20, 1) var max_primary_orbs: int = 10
@export_range(0.1, 2.0, 0.05) var secondary_ring_radius_step: float = 0.55
@export_range(0.1, 1.5, 0.05) var secondary_ring_height_step: float = 0.45
@export_range(0.1, 1.5, 0.05) var spawn_distance: float = 0.65
@export_range(0.2, 1.5, 0.05) var combine_distance: float = 0.6
@export_range(0.15, 1.2, 0.05) var child_orbit_radius: float = 0.5

var _user_rig: UserRig = null
var _standing_center: Node3D = null
var _orbs_by_thread_id: Dictionary = {}
var _last_layout_origin := Vector3.ZERO
var _grab_position := Vector3.ZERO
var _standing_height := 1.4
var _height_captured := false


func _ready() -> void:
	_user_rig = get_node_or_null(user_rig_path) as UserRig
	_standing_center = get_node_or_null(standing_center_path) as Node3D
	AppState.thread_added.connect(_on_thread_added)
	AppState.thread_updated.connect(_on_thread_updated)
	AppState.thread_removed.connect(_on_thread_removed)
	AppState.privacy_veil_changed.connect(_on_privacy_veil_changed)
	AppState.orb_layout_changed.connect(_on_orb_layout_changed)
	visible = not AppState.privacy_veil_active

	for thread_id in AppState.ordered_thread_ids:
		var thread := AppState.get_thread(thread_id)
		if thread != null:
			_spawn_or_update_orb(thread)
	_refresh_layout()


func _process(_delta: float) -> void:
	# Desktop movement and XR recentering move the layout origin; refresh when it
	# actually changes so standing users keep a stable agent ring.
	if AppState.ui_mode == "xr_hands":
		if not _height_captured:
			var camera := _user_rig.get_camera() if _user_rig != null else null
			if camera != null:
				_standing_height = camera.global_position.y
				_height_captured = true
				_refresh_layout()
	else:
		_height_captured = false
	var origin := _get_layout_origin()
	if origin.distance_squared_to(_last_layout_origin) > 0.000004:
		_refresh_layout()


func get_orb(thread_id: String) -> AgentOrb:
	return _orbs_by_thread_id.get(thread_id) as AgentOrb


func get_orb_count() -> int:
	return _orbs_by_thread_id.size()


func calculate_slot_global_position(slot: int) -> Vector3:
	var origin := _get_layout_origin()
	var ring := floori(float(slot) / float(max_primary_orbs))
	var local_slot := slot % max_primary_orbs
	var angle := deg_to_rad(_angle_for_local_slot(local_slot))
	var radius := radius_from_user + float(ring) * secondary_ring_radius_step
	var height := vertical_offset + float(ring) * secondary_ring_height_step
	return origin + Vector3(sin(angle) * radius, height, -cos(angle) * radius)


func _spawn_or_update_orb(thread: AgentThread) -> void:
	var existing_orb := get_orb(thread.id)
	if existing_orb != null:
		existing_orb.bind_thread(thread)
		_refresh_layout()
		return

	_assign_stable_slot(thread)
	var orb := orb_scene.instantiate() as AgentOrb
	if orb == null:
		push_error("[APP] Orb scene did not instantiate as AgentOrb")
		return
	add_child(orb)
	orb.bind_thread(thread)
	_orbs_by_thread_id[thread.id] = orb

	var origin := _get_layout_origin()
	var target := calculate_slot_global_position(thread.spatial_slot)
	var spawn_direction := (target - origin).normalized()
	orb.global_position = origin + spawn_direction * spawn_distance
	_refresh_layout()


func _assign_stable_slot(thread: AgentThread) -> void:
	if thread.spatial_slot >= 0 and not _slot_is_owned_by_another_thread(thread.spatial_slot, thread.id):
		return
	var candidate := 0
	while _slot_is_owned_by_another_thread(candidate, thread.id):
		candidate += 1
	thread.spatial_slot = candidate


func _slot_is_owned_by_another_thread(slot: int, thread_id: String) -> bool:
	for candidate_id in AppState.ordered_thread_ids:
		if candidate_id == thread_id:
			continue
		var candidate := AppState.get_thread(candidate_id)
		if candidate != null and candidate.spatial_slot == slot:
			return true
	return false


func _refresh_layout() -> void:
	var origin := _get_layout_origin()
	_last_layout_origin = origin
	for thread_id in _orbs_by_thread_id:
		var orb := get_orb(thread_id)
		if orb == null:
			continue
		var target := _target_for_thread(thread_id)
		orb.set_target_global_position(target)
		if not orb.global_position.is_equal_approx(origin):
			orb.look_at(origin, Vector3.UP)


func _target_for_thread(thread_id: String) -> Vector3:
	var offset: Variant = AppState.get_orb_offset(thread_id)
	if offset is Vector3:
		return offset
	var parent_id := AppState.get_orb_parent(thread_id)
	if not parent_id.is_empty():
		var parent_orb := get_orb(parent_id)
		if parent_orb != null:
			var angle := _child_angle(thread_id)
			return (
				parent_orb.global_position
				+ Vector3(cos(angle), -0.14, sin(angle)) * child_orbit_radius
			)
	var thread := AppState.get_thread(thread_id)
	return calculate_slot_global_position(thread.spatial_slot if thread != null else 0)


func _child_angle(thread_id: String) -> float:
	return float(abs(thread_id.hash() % 360)) * PI / 180.0


func begin_grab(thread_id: String) -> bool:
	var orb := get_orb(thread_id)
	if orb == null:
		return false
	AppState.unlink_orb(thread_id)
	_grab_position = orb.global_position
	AppState.set_orb_offset(thread_id, _grab_position)
	return true


func update_grab(thread_id: String, world_position: Vector3) -> void:
	if get_orb(thread_id) == null:
		return
	_grab_position = world_position
	AppState.set_orb_offset(thread_id, world_position)


func end_grab(thread_id: String) -> Dictionary:
	var result := {"linked_to": ""}
	if get_orb(thread_id) == null:
		return result
	# Combine against the drop point (the hand position), not the orb's eased
	# position, so the intent is honoured even while the orb is still catching up.
	var nearest := _nearest_orb_within(thread_id, _grab_position, combine_distance)
	if not nearest.is_empty() and AppState.link_orbs(thread_id, nearest):
		result["linked_to"] = nearest
	_refresh_layout()
	return result


func _nearest_orb_within(thread_id: String, position: Vector3, radius: float) -> String:
	var nearest := ""
	var best := radius
	for candidate_id in _orbs_by_thread_id:
		if candidate_id == thread_id:
			continue
		var orb := get_orb(candidate_id)
		if orb == null:
			continue
		var distance := position.distance_to(orb.global_position)
		if distance < best:
			best = distance
			nearest = candidate_id
	return nearest


func _angle_for_local_slot(local_slot: int) -> float:
	if local_slot == 0:
		return 0.0
	var step_index := ceili(float(local_slot) / 2.0)
	var side := -1.0 if local_slot % 2 == 1 else 1.0
	var angle_step := arc_degrees / float(max_primary_orbs)
	return float(step_index) * angle_step * side


func _get_layout_origin() -> Vector3:
	if (
		AppState.ui_mode == "xr_hands"
		and _standing_center != null
		and _standing_center.is_inside_tree()
	):
		var ground := _standing_center.global_position
		return Vector3(ground.x, ground.y + _standing_height, ground.z)
	if _user_rig == null:
		return global_position
	return _user_rig.global_position


func _on_orb_layout_changed(_thread_id: String) -> void:
	_refresh_layout()


func _on_thread_added(thread: AgentThread) -> void:
	_spawn_or_update_orb(thread)


func _on_thread_updated(thread: AgentThread) -> void:
	_spawn_or_update_orb(thread)


func _on_thread_removed(thread_id: String) -> void:
	var orb := get_orb(thread_id)
	if orb != null:
		orb.queue_free()
	_orbs_by_thread_id.erase(thread_id)
	_refresh_layout()


func _on_privacy_veil_changed(value: bool) -> void:
	visible = not value
