class_name MissionTopology
extends Node3D

const MAX_LINKS := 12
const ACTIVE_STATUSES := [
	AgentThread.Status.LISTENING,
	AgentThread.Status.WORKING,
	AgentThread.Status.WAITING_USER,
	AgentThread.Status.ERROR,
]

@export var orb_manager_path: NodePath = ^"../OrbManager"
@export var user_rig_path: NodePath = ^"../UserRig"

@onready var _legend: Node3D = $Legend
@onready var _count_label: Label3D = $Legend/CountLabel

var _orb_manager: OrbManager = null
var _camera: Camera3D = null
var _enabled := false
var _blocked := false
var _elapsed := 0.0
var _edges: Array[Dictionary] = []
var _beams: Array[MeshInstance3D] = []
var _pulses: Array[MeshInstance3D] = []


func _ready() -> void:
	_orb_manager = get_node_or_null(orb_manager_path) as OrbManager
	var rig := get_node_or_null(user_rig_path) as UserRig
	if rig != null:
		_camera = rig.get_camera()
	AppState.focused_thread_changed.connect(_on_topology_changed)
	AppState.thread_added.connect(_on_thread_changed)
	AppState.thread_updated.connect(_on_thread_changed)
	AppState.thread_removed.connect(_on_topology_changed)
	visible = false


func _process(delta: float) -> void:
	if not visible:
		return
	_elapsed += delta
	_place_legend()
	for index in range(_edges.size()):
		var edge := _edges[index]
		var source := _orb_manager.get_orb(str(edge.get("source", ""))) if _orb_manager != null else null
		var target := _orb_manager.get_orb(str(edge.get("target", ""))) if _orb_manager != null else null
		if source == null or target == null:
			continue
		var start := source.global_position
		var finish := target.global_position
		_update_beam(_beams[index], start, finish)
		var travel := fmod(_elapsed * 0.28 + float(index) * 0.173, 1.0)
		_pulses[index].global_position = start.lerp(finish, travel)


func toggle_enabled() -> bool:
	_enabled = not _enabled
	if _enabled:
		refresh()
	_refresh_visibility()
	return _enabled


func is_enabled() -> bool:
	return _enabled


func set_blocked(value: bool) -> void:
	_blocked = value
	_refresh_visibility()


func refresh() -> void:
	_clear_links()
	if _orb_manager == null:
		return
	var pairs := _derive_pairs()
	for pair in pairs:
		_add_link(str(pair.get("source", "")), str(pair.get("target", "")))
	_count_label.text = "%02d LINKS · %02d MISSIONS // CONTENT-BLIND" % [_edges.size(), mission_count()]


func get_link_count() -> int:
	return _edges.size()


func get_pulse_count() -> int:
	return _pulses.size()


func get_debug_text() -> String:
	var parts: Array[String] = []
	for edge in _edges:
		parts.append("%s>%s" % [edge.get("source", ""), edge.get("target", "")])
	return "|".join(parts)


func _derive_pairs() -> Array[Dictionary]:
	var pairs: Array[Dictionary] = []
	var seen: Dictionary = {}

	# Fleet constellation: star each mission from its first agent.
	var missions: Dictionary = {}
	for thread_id in AppState.ordered_thread_ids:
		var thread := AppState.get_thread(thread_id)
		if thread == null:
			continue
		var mission_id := str(thread.metadata.get("mission_id", ""))
		if mission_id.is_empty():
			continue
		if not missions.has(mission_id):
			missions[mission_id] = []
		(missions[mission_id] as Array).append(thread_id)
	for mission_id in missions.keys():
		var members: Array = missions[mission_id]
		if members.size() < 2:
			continue
		var hub := str(members[0])
		for index in range(1, members.size()):
			_append_pair(pairs, seen, hub, str(members[index]))
			if pairs.size() >= MAX_LINKS:
				break

	# Combined-thread parentage.
	for thread_id in AppState.ordered_thread_ids:
		var thread := AppState.get_thread(thread_id)
		if thread == null or thread.parent_thread_id.is_empty():
			continue
		if AppState.get_thread(thread.parent_thread_id) != null:
			_append_pair(pairs, seen, thread.parent_thread_id, thread.id)

	# Focus star fallback so the map stays useful without missions.
	var focus_id := AppState.focused_thread_id
	if focus_id.is_empty() and not AppState.ordered_thread_ids.is_empty():
		focus_id = AppState.ordered_thread_ids.front()
	if not focus_id.is_empty():
		for thread_id in AppState.ordered_thread_ids:
			if thread_id == focus_id:
				continue
			var thread := AppState.get_thread(thread_id)
			if thread != null and thread.status in ACTIVE_STATUSES:
				_append_pair(pairs, seen, focus_id, thread_id)
				if pairs.size() >= MAX_LINKS:
					break
	return pairs


func mission_count() -> int:
	var missions: Dictionary = {}
	for thread_id in AppState.ordered_thread_ids:
		var thread := AppState.get_thread(thread_id)
		if thread == null:
			continue
		if not str(thread.metadata.get("mission_id", "")).is_empty():
			missions[str(thread.metadata.get("mission_id", ""))] = true
	return missions.size()


func _append_pair(pairs: Array[Dictionary], seen: Dictionary, source: String, target: String) -> void:
	if pairs.size() >= MAX_LINKS or source == target:
		return
	var key := "%s>%s" % [source, target]
	if seen.has(key):
		return
	seen[key] = true
	pairs.append({"source": source, "target": target})


func _add_link(source_id: String, target_id: String) -> void:
	var target_thread := AppState.get_thread(target_id)
	var color := _status_color(target_thread)
	var beam := MeshInstance3D.new()
	beam.name = "MissionBeam%02d" % _edges.size()
	beam.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var beam_mesh := BoxMesh.new()
	beam_mesh.size = Vector3(0.008, 0.008, 1.0)
	beam_mesh.material = _material(Color(color, 0.36), 1.4)
	beam.mesh = beam_mesh
	add_child(beam)
	_beams.append(beam)

	var pulse := MeshInstance3D.new()
	pulse.name = "MissionPulse%02d" % _edges.size()
	pulse.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var pulse_mesh := SphereMesh.new()
	pulse_mesh.radius = 0.025
	pulse_mesh.height = 0.05
	pulse_mesh.radial_segments = 10
	pulse_mesh.rings = 5
	pulse_mesh.material = _material(Color(color, 0.95), 3.2)
	pulse.mesh = pulse_mesh
	add_child(pulse)
	_pulses.append(pulse)
	_edges.append({"source": source_id, "target": target_id})


func _update_beam(beam: MeshInstance3D, start: Vector3, finish: Vector3) -> void:
	var difference := finish - start
	var length := difference.length()
	if length < 0.001:
		return
	var up := Vector3.UP
	if absf(difference.normalized().dot(up)) > 0.98:
		up = Vector3.RIGHT
	beam.global_transform = Transform3D(
		Basis.looking_at(difference.normalized(), up).scaled(Vector3(1.0, 1.0, length)),
		start.lerp(finish, 0.5)
	)


func _place_legend() -> void:
	if _camera == null:
		return
	var basis := _camera.global_basis.orthonormalized()
	_legend.global_transform = Transform3D(
		basis,
		_camera.global_position + basis * Vector3(0.0, 0.55, -1.25)
	)


func _clear_links() -> void:
	_edges.clear()
	_beams.clear()
	_pulses.clear()
	for child in get_children():
		if child != _legend:
			child.queue_free()


func _refresh_visibility() -> void:
	visible = _enabled and not _blocked


func _status_color(thread: AgentThread) -> Color:
	if thread == null:
		return Color(0.08, 0.72, 0.92)
	match thread.status:
		AgentThread.Status.WAITING_USER:
			return Color(1.0, 0.55, 0.08)
		AgentThread.Status.ERROR:
			return Color(1.0, 0.12, 0.16)
		AgentThread.Status.COMPLETE:
			return Color(0.12, 1.0, 0.62)
		_:
			return Color(0.02, 0.8, 1.0)


func _material(color: Color, energy: float) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = color
	material.emission_enabled = true
	material.emission = Color(color.r, color.g, color.b, 1.0)
	material.emission_energy_multiplier = energy
	return material


func _on_topology_changed(_unused: Variant = null) -> void:
	if _enabled:
		refresh()


func _on_thread_changed(_thread: AgentThread) -> void:
	if _enabled:
		refresh()
