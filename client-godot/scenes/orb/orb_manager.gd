class_name OrbManager
extends Node3D

const DEFAULT_ORB_SCENE := preload("res://scenes/orb/agent_orb.tscn")

@export var user_rig_path: NodePath = ^"../UserRig"
@export var orb_scene: PackedScene = DEFAULT_ORB_SCENE
@export_range(0.5, 5.0, 0.05) var radius_from_user: float = 2.2
@export_range(-1.0, 1.0, 0.05) var vertical_offset: float = 0.0
@export_range(90.0, 240.0, 1.0) var arc_degrees: float = 200.0
@export_range(1, 20, 1) var max_primary_orbs: int = 10
@export_range(0.1, 2.0, 0.05) var secondary_ring_radius_step: float = 0.55
@export_range(0.1, 1.5, 0.05) var secondary_ring_height_step: float = 0.45
@export_range(0.1, 1.5, 0.05) var spawn_distance: float = 0.65

var _user_rig: UserRig = null
var _orbs_by_thread_id: Dictionary = {}


func _ready() -> void:
	_user_rig = get_node_or_null(user_rig_path) as UserRig
	AppState.thread_added.connect(_on_thread_added)
	AppState.thread_updated.connect(_on_thread_updated)
	AppState.thread_removed.connect(_on_thread_removed)
	AppState.privacy_veil_changed.connect(_on_privacy_veil_changed)
	visible = not AppState.privacy_veil_active

	for thread_id in AppState.ordered_thread_ids:
		var thread := AppState.get_thread(thread_id)
		if thread != null:
			_spawn_or_update_orb(thread)
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
	for thread_id in _orbs_by_thread_id:
		var thread := AppState.get_thread(thread_id)
		var orb := get_orb(thread_id)
		if thread == null or orb == null:
			continue
		var target := calculate_slot_global_position(thread.spatial_slot)
		orb.set_target_global_position(target)
		if not orb.global_position.is_equal_approx(origin):
			orb.look_at(origin, Vector3.UP)


func _angle_for_local_slot(local_slot: int) -> float:
	if local_slot == 0:
		return 0.0
	var step_index := ceili(float(local_slot) / 2.0)
	var side := -1.0 if local_slot % 2 == 1 else 1.0
	var angle_step := arc_degrees / float(max_primary_orbs)
	return float(step_index) * angle_step * side


func _get_layout_origin() -> Vector3:
	if _user_rig == null:
		return global_position
	return _user_rig.global_position


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
