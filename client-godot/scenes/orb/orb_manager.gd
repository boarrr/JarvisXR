class_name OrbManager
extends Node3D

const DEFAULT_ORB_SCENE := preload("res://scenes/orb/agent_orb.tscn")

@export var user_rig_path: NodePath = ^"../UserRig"
@export var standing_center_path: NodePath = ^"../XRRuntime/XROrigin3D"
@export var orb_scene: PackedScene = DEFAULT_ORB_SCENE
@export_range(0.5, 5.0, 0.05) var radius_from_user: float = 1.75
@export_range(-1.0, 1.0, 0.05) var vertical_offset: float = 0.0
@export_range(90.0, 240.0, 1.0) var arc_degrees: float = 150.0
@export_range(1, 20, 1) var max_primary_orbs: int = 10
@export_range(0.1, 2.0, 0.05) var secondary_ring_radius_step: float = 0.55
@export_range(0.1, 1.5, 0.05) var secondary_ring_height_step: float = 0.45
@export_range(0.1, 1.5, 0.05) var spawn_distance: float = 0.65
@export_range(0.2, 1.5, 0.05) var combine_distance: float = 0.6
@export_range(0.15, 1.2, 0.05) var child_orbit_radius: float = 0.5

const THROW_MIN_SPEED := 0.55
const THROW_DAMPING := 1.7
const KINETIC_STOP_SPEED := 0.08
const STAGE_MAX_RADIUS := 3.2
const ATTRACT_SPEED := 0.9

var _user_rig: UserRig = null
var _standing_center: Node3D = null
var _orbs_by_thread_id: Dictionary = {}
var _last_layout_origin := Vector3.ZERO
var _grab_position := Vector3.ZERO
var _grab_velocity := Vector3.ZERO
var _grab_speed_peak := 0.0
var _grab_last_msec := 0
var _velocities: Dictionary = {}
var _kinetic_threads: Dictionary = {}
var _attract_target := ""
var _standing_height := 1.4
var _stage_center := Vector3.ZERO
var _height_captured := false


func _ready() -> void:
	_user_rig = get_node_or_null(user_rig_path) as UserRig
	_standing_center = get_node_or_null(standing_center_path) as Node3D
	AppState.thread_added.connect(_on_thread_added)
	AppState.thread_updated.connect(_on_thread_updated)
	AppState.thread_removed.connect(_on_thread_removed)
	AppState.orb_layout_changed.connect(_on_orb_layout_changed)
	visible = true

	for thread_id in AppState.ordered_thread_ids:
		var thread := AppState.get_thread(thread_id)
		if thread != null:
			_spawn_or_update_orb(thread)
	_refresh_layout()


func _process(_delta: float) -> void:
	# Desktop movement and XR recentering move the layout origin; refresh when it
	# actually changes so standing users keep a stable agent ring.
	if AppState.ui_mode == "xr_hands":
		if not _height_captured and _user_rig != null:
			var camera := _user_rig.get_camera()
			if camera != null:
				# Anchor the stage where the user is actually standing, not at
				# the play-space centre chosen during boundary setup.
				_standing_height = camera.global_position.y
				_stage_center = Vector3(camera.global_position.x, 0.0, camera.global_position.z)
				_height_captured = true
				_refresh_layout()
	else:
		_height_captured = false
	var origin := _get_layout_origin()
	if origin.distance_squared_to(_last_layout_origin) > 0.000004:
		_refresh_layout()
	_update_kinetics(_delta)


func _update_kinetics(delta: float) -> void:
	for thread_id in _kinetic_threads.keys():
		var orb := get_orb(thread_id)
		if orb == null:
			_kinetic_threads.erase(thread_id)
			_velocities.erase(thread_id)
			continue
		var velocity: Vector3 = _velocities.get(thread_id, Vector3.ZERO)
		velocity *= exp(-THROW_DAMPING * delta)
		var position := orb.global_position + velocity * delta
		var origin := _get_layout_origin()
		var offset := position - origin
		if offset.length() > STAGE_MAX_RADIUS:
			position = origin + offset.normalized() * STAGE_MAX_RADIUS
			velocity *= 0.4
		_velocities[thread_id] = velocity
		orb.set_kinetic(true)
		orb.set_target_global_position(position)
		orb.global_position = position
		if velocity.length() < KINETIC_STOP_SPEED:
			_kinetic_threads.erase(thread_id)
			_velocities.erase(thread_id)
			orb.set_kinetic(false)
			AppState.set_orb_offset(thread_id, position)


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
		# Just refresh its visuals. Re-running the whole layout on every token
		# re-targets and re-orients the orbs constantly (they appear to drift
		# and it burns frame budget while streaming).
		existing_orb.bind_thread(thread)
		return

	_assign_stable_slot(thread)
	var orb := orb_scene.instantiate() as AgentOrb
	if orb == null:
		push_error("[APP] Orb scene did not instantiate as AgentOrb")
		return
	add_child(orb)
	orb.bind_thread(thread)
	_orbs_by_thread_id[thread.id] = orb
	print("[ORB] spawned %s" % thread.id)

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
	_kinetic_threads.erase(thread_id)
	_velocities.erase(thread_id)
	_grab_position = orb.global_position
	_grab_velocity = Vector3.ZERO
	_grab_speed_peak = 0.0
	_grab_last_msec = 0
	orb.set_kinetic(true)
	AppState.set_orb_offset(thread_id, _grab_position)
	return true


func update_grab(thread_id: String, world_position: Vector3) -> void:
	var orb := get_orb(thread_id)
	if orb == null:
		return
	# Use real elapsed time: hand tracking and physics run at different rates, so
	# a fixed physics delta would mis-scale the release velocity.
	var now := Time.get_ticks_msec()
	var dt := 0.0
	if _grab_last_msec > 0:
		dt = float(now - _grab_last_msec) / 1000.0
	_grab_last_msec = now
	dt = clampf(dt, 0.004, 0.08)
	var instantaneous := (world_position - _grab_position) / dt
	_grab_velocity = _grab_velocity.lerp(instantaneous, 0.5)
	# Keep the recent peak so a quick flick registers even if the frame the user
	# lets go happens to be a calm one.
	_grab_speed_peak = maxf(_grab_speed_peak * 0.9, instantaneous.length())
	_grab_position = world_position
	orb.set_kinetic(true)
	orb.set_target_global_position(world_position)
	orb.global_position = world_position
	AppState.set_orb_offset(thread_id, world_position)


func end_grab(thread_id: String) -> Dictionary:
	var result := {"linked_to": "", "thrown": false}
	var orb := get_orb(thread_id)
	if orb == null:
		_grab_velocity = Vector3.ZERO
		_grab_speed_peak = 0.0
		return result
	var release_speed := maxf(_grab_velocity.length(), _grab_speed_peak)
	var nearest := _nearest_orb_within(thread_id, _grab_position, combine_distance)
	if not nearest.is_empty() and AppState.link_orbs(thread_id, nearest):
		result["linked_to"] = nearest
		orb.set_kinetic(false)
	elif release_speed >= THROW_MIN_SPEED:
		# Release with momentum: the orb floats outward and slows to rest.
		var direction := _grab_velocity.normalized()
		if direction.length() < 0.01:
			direction = _grab_position - _get_layout_origin()
			direction.y = 0.0
			direction = direction.normalized()
		_kinetic_threads[thread_id] = true
		_velocities[thread_id] = (direction * release_speed).limit_length(3.0)
		result["thrown"] = true
	else:
		orb.set_kinetic(false)
		AppState.set_orb_offset(thread_id, orb.global_position)
	_grab_velocity = Vector3.ZERO
	_grab_speed_peak = 0.0
	_refresh_layout()
	return result


func remove_orb(thread_id: String) -> void:
	var orb := get_orb(thread_id)
	if orb != null:
		orb.collapse_and_free()
	_orbs_by_thread_id.erase(thread_id)
	_kinetic_threads.erase(thread_id)
	_velocities.erase(thread_id)
	_refresh_layout()


func attract_begin(thread_id: String) -> bool:
	if get_orb(thread_id) == null:
		return false
	_attract_target = thread_id
	_kinetic_threads.erase(thread_id)
	_velocities.erase(thread_id)
	return true


func attract_to(thread_id: String, anchor: Vector3) -> void:
	if _attract_target != thread_id:
		return
	var orb := get_orb(thread_id)
	if orb == null:
		return
	var to_anchor := anchor - orb.global_position
	var distance := to_anchor.length()
	if distance < 0.05:
		return
	var speed := clampf(distance * ATTRACT_SPEED, 0.15, 1.2)
	var step_delta := 1.0 / maxf(float(Engine.get_physics_ticks_per_second()), 1.0)
	var step := minf(speed * step_delta, distance)
	var position := orb.global_position + to_anchor.normalized() * step
	orb.set_kinetic(true)
	orb.set_target_global_position(position)
	orb.global_position = position


func attract_end(thread_id: String) -> void:
	if _attract_target == thread_id:
		_attract_target = ""
	var orb := get_orb(thread_id)
	if orb != null:
		orb.set_kinetic(false)
		AppState.set_orb_offset(thread_id, orb.global_position)


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
	if AppState.ui_mode == "xr_hands" and _height_captured:
		return Vector3(_stage_center.x, _standing_height, _stage_center.z)
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

