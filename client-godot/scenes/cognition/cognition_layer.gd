class_name CognitionLayer
extends Node3D

const MAX_EVENT_RECORDS := 32
const EVENT_NODE_COUNT := 10
const STREAM_AGGREGATION_WINDOW_MSEC := 450

const COLOR_CYAN := Color(0.02, 0.88, 1.0, 1.0)
const COLOR_BLUE := Color(0.12, 0.48, 1.0, 1.0)
const COLOR_GREEN := Color(0.18, 1.0, 0.62, 1.0)
const COLOR_AMBER := Color(1.0, 0.58, 0.12, 1.0)
const COLOR_RED := Color(1.0, 0.16, 0.22, 1.0)
const COLOR_MAGENTA := Color(0.86, 0.24, 1.0, 1.0)

@export var user_rig_path: NodePath = ^"../UserRig"
@export var orb_manager_path: NodePath = ^"../OrbManager"
@export var backend_bridge_path: NodePath = ^"../BackendBridge"
@export_range(1.0, 30.0, 0.5) var follow_speed: float = 12.0

var _user_rig: UserRig = null
var _orb_manager: OrbManager = null
var _backend_bridge: BackendBridge = null
var _constellation_root: Node3D = null
var _temporal_ribbon: Node3D = null
var _privacy_root: Node3D = null
var _link_mesh_instance: MeshInstance3D = null
var _event_nodes: Array[MeshInstance3D] = []
var _event_materials: Array[StandardMaterial3D] = []
var _event_positions: Array[Vector3] = []
var _pulse_nodes: Array[MeshInstance3D] = []
var _button_meshes: Dictionary = {}
var _events: Array[Dictionary] = []
var _selected_event_index := -1
var _live_mode := true
var _enabled := true
var _blocked := false
var _activity_time := 0.0
var _current_label: Label3D = null
var _timeline_label: Label3D = null
var _privacy_label: Label3D = null
var _route_label: Label3D = null
var _mode_button_label: Label3D = null
var _provider_node: MeshInstance3D = null
var _provider_material: StandardMaterial3D = null
var _risk_halo: MeshInstance3D = null
var _risk_material: StandardMaterial3D = null


func _ready() -> void:
	_user_rig = get_node_or_null(user_rig_path) as UserRig
	_orb_manager = get_node_or_null(orb_manager_path) as OrbManager
	_backend_bridge = get_node_or_null(backend_bridge_path) as BackendBridge
	_build_visual_system()
	AppState.focused_thread_changed.connect(_on_focused_thread_changed)
	AppState.provider_identity_changed.connect(_on_provider_identity_changed)
	AppState.hovered_target_changed.connect(_on_hovered_target_changed)
	if _backend_bridge != null:
		_backend_bridge.backend_event_applied.connect(ingest_backend_event)
		_backend_bridge.backend_command_sent.connect(_on_backend_command_sent)
	_refresh_privacy_field()
	_refresh_event_visuals()
	_sync_visibility()


func _process(delta: float) -> void:
	_activity_time += delta
	_sync_visibility()
	if not visible:
		return
	_follow_focused_orb(delta)
	_animate_constellation(delta)


func ingest_backend_event(event: BackendEvent) -> void:
	if event == null:
		return
	if event.type == "agent.message.delta" and _aggregate_stream_delta(event):
		return
	var classification := _classify_event(event.type)
	var summary := _event_summary(event)
	_record_event(
		event.type,
		event.thread_id,
		summary,
		str(classification.get("category", "SYSTEM")),
		classification.get("color", COLOR_CYAN) as Color,
		str(classification.get("risk", "OBSERVE"))
	)


func record_command(command_type: String, thread_id: String = "") -> void:
	var hosted := AppState.provider_name in ["openai", "claude", "council"]
	var summary := "COMMAND // %s" % command_type.to_upper().replace(".", " / ")
	var risk := "HOSTED EGRESS" if hosted and command_type in ["message.send", "voice.transcript.final"] else "LOCAL COMMAND"
	_record_event(
		"command.%s" % command_type,
		thread_id,
		summary,
		"INTENT",
		COLOR_MAGENTA if hosted else COLOR_CYAN,
		risk
	)


func select_previous_event() -> bool:
	if _events.is_empty():
		return false
	_live_mode = false
	if _selected_event_index < 0:
		_selected_event_index = _events.size() - 1
	_selected_event_index = maxi(0, _selected_event_index - 1)
	_refresh_event_visuals()
	return true


func select_next_event() -> bool:
	if _events.is_empty():
		return false
	_selected_event_index = mini(_events.size() - 1, _selected_event_index + 1)
	_live_mode = _selected_event_index == _events.size() - 1
	_refresh_event_visuals()
	return true


func toggle_live_mode() -> bool:
	if _events.is_empty():
		return false
	_live_mode = not _live_mode
	if _live_mode:
		_selected_event_index = _events.size() - 1
	_refresh_event_visuals()
	return _live_mode


func toggle_enabled() -> bool:
	_enabled = not _enabled
	_sync_visibility()
	return _enabled


func is_enabled() -> bool:
	return _enabled


func set_blocked(value: bool) -> void:
	_blocked = value
	_sync_visibility()


func get_event_count() -> int:
	return _events.size()


func get_visual_node_count() -> int:
	return _event_nodes.size()


func get_current_event_summary() -> String:
	if _events.is_empty() or _selected_event_index < 0:
		return "NO EVENTS"
	return str(_events[_selected_event_index].get("summary", "NO EVENTS"))


func get_privacy_status() -> String:
	if not AppState.approval_requests.is_empty():
		return "CONSENT LOCK // WRITE BOUNDARY"
	match AppState.provider_name:
		"openai":
			return "HOSTED EGRESS // OPENAI"
		"claude":
			return "HOSTED EGRESS // CLAUDE"
		"council":
			return "DUAL HOSTED EGRESS // OPENAI + CLAUDE"
		_:
			return "LOCAL SANDBOX // NO PROVIDER EGRESS"


func get_debug_text() -> String:
	var parts: Array[String] = [get_privacy_status(), get_current_event_summary()]
	for record in _events:
		parts.append(str(record.get("summary", "")))
	return "\n".join(parts)


func _record_event(
	event_type: String,
	thread_id: String,
	summary: String,
	category: String,
	color: Color,
	risk: String
) -> void:
	_events.append({
		"type": event_type,
		"thread_id": thread_id,
		"summary": summary.left(96),
		"category": category,
		"color": color,
		"risk": risk,
		"timestamp_msec": Time.get_ticks_msec(),
		"clock": Time.get_time_string_from_system(),
		"bursts": 1,
	})
	if _events.size() > MAX_EVENT_RECORDS:
		_events.pop_front()
		_selected_event_index = maxi(-1, _selected_event_index - 1)
	if _live_mode or _selected_event_index < 0:
		_selected_event_index = _events.size() - 1
	_refresh_event_visuals()


func _aggregate_stream_delta(event: BackendEvent) -> bool:
	if _events.is_empty():
		return false
	var latest: Dictionary = _events.back()
	if str(latest.get("type", "")) != event.type or str(latest.get("thread_id", "")) != event.thread_id:
		return false
	var age := Time.get_ticks_msec() - int(latest.get("timestamp_msec", 0))
	if age > STREAM_AGGREGATION_WINDOW_MSEC:
		return false
	latest["bursts"] = int(latest.get("bursts", 1)) + 1
	latest["timestamp_msec"] = Time.get_ticks_msec()
	latest["clock"] = Time.get_time_string_from_system()
	latest["summary"] = "TOKEN STREAM // %02d PULSES" % int(latest["bursts"])
	_events[_events.size() - 1] = latest
	if _live_mode:
		_selected_event_index = _events.size() - 1
	_refresh_event_visuals()
	return true


func _classify_event(event_type: String) -> Dictionary:
	if event_type.begins_with("approval."):
		return {"category": "CONSENT", "color": COLOR_AMBER, "risk": "WRITE BOUNDARY"}
	if event_type == "tool.failed" or event_type == "run.failed" or event_type == "error":
		return {"category": "FAULT", "color": COLOR_RED, "risk": "ATTENTION"}
	if event_type.begins_with("tool."):
		return {"category": "TOOL", "color": COLOR_AMBER, "risk": "CAPABILITY"}
	if event_type == "agent.message.delta":
		return {"category": "STREAM", "color": COLOR_CYAN, "risk": "OBSERVE"}
	if event_type.begins_with("agent.") or event_type.begins_with("run."):
		return {"category": "COGNITION", "color": COLOR_BLUE, "risk": "OBSERVE"}
	if event_type.begins_with("thread."):
		return {"category": "MEMORY", "color": COLOR_GREEN, "risk": "LOCAL STATE"}
	return {"category": "SYSTEM", "color": COLOR_CYAN, "risk": "OBSERVE"}


func _event_summary(event: BackendEvent) -> String:
	match event.type:
		"session.ready":
			return "COGNITION LINK ESTABLISHED"
		"thread.snapshot":
			return "MEMORY SNAPSHOT SYNCHRONIZED"
		"thread.created":
			return "NEW AGENT THREAD MATERIALIZED"
		"thread.updated":
			return "THREAD STATE RECONCILED"
		"thread.archived":
			return "THREAD MOVED TO ARCHIVE"
		"agent.status":
			return "AGENT STATE // %s" % str(event.payload.get("status", "UPDATED")).to_upper()
		"agent.message.started":
			return "RESPONSE SYNTHESIS STARTED"
		"agent.message.delta":
			return "TOKEN STREAM // 01 PULSE"
		"agent.message.completed":
			return "RESPONSE SYNTHESIS COMPLETE"
		"run.completed":
			return "EXECUTION LOOP COMPLETE"
		"run.failed":
			return "EXECUTION LOOP FAILED"
		"approval.required":
			return "CONSENT REQUIRED // TOOL BOUNDARY"
		"tool.running":
			return "APPROVED CAPABILITY EXECUTING"
		"tool.completed":
			return "CAPABILITY COMPLETE"
		"tool.failed":
			return "CAPABILITY FAILED"
		"error":
			return "BACKEND FAULT DETECTED"
		_:
			return event.type.to_upper().replace(".", " // ")


func _build_visual_system() -> void:
	_constellation_root = Node3D.new()
	_constellation_root.name = "NeuralConstellation"
	add_child(_constellation_root)
	_build_halos()
	_build_event_nodes()
	_build_pulses()
	_build_temporal_ribbon()
	_build_privacy_field()


func _build_halos() -> void:
	var ring_specs := [
		{"radius": 0.42, "width": 0.005, "color": COLOR_CYAN, "alpha": 0.18, "tilt": Vector3(90.0, 0.0, 0.0)},
		{"radius": 0.54, "width": 0.004, "color": COLOR_BLUE, "alpha": 0.12, "tilt": Vector3(90.0, 18.0, -8.0)},
		{"radius": 0.63, "width": 0.003, "color": COLOR_CYAN, "alpha": 0.08, "tilt": Vector3(90.0, -15.0, 12.0)},
	]
	for index in range(ring_specs.size()):
		var spec: Dictionary = ring_specs[index]
		var torus := TorusMesh.new()
		var radius := float(spec["radius"])
		var width := float(spec["width"])
		torus.inner_radius = radius - width
		torus.outer_radius = radius + width
		torus.rings = 64
		torus.ring_segments = 4
		var ring := MeshInstance3D.new()
		ring.name = "CausalRing%d" % (index + 1)
		ring.mesh = torus
		ring.rotation_degrees = spec["tilt"]
		ring.position.z = 0.04 + float(index) * 0.012
		ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		ring.material_override = _make_material(spec["color"], float(spec["alpha"]), 1.8)
		_constellation_root.add_child(ring)

	var core_mesh := SphereMesh.new()
	core_mesh.radius = 0.12
	core_mesh.height = 0.24
	core_mesh.radial_segments = 20
	core_mesh.rings = 10
	var core := MeshInstance3D.new()
	core.name = "InferenceField"
	core.mesh = core_mesh
	core.position.z = -0.08
	core.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	core.material_override = _make_material(COLOR_CYAN, 0.055, 0.8)
	_constellation_root.add_child(core)

	var risk_torus := TorusMesh.new()
	risk_torus.inner_radius = 0.655
	risk_torus.outer_radius = 0.665
	risk_torus.rings = 72
	risk_torus.ring_segments = 5
	_risk_material = _make_material(COLOR_CYAN, 0.13, 2.0)
	_risk_halo = MeshInstance3D.new()
	_risk_halo.name = "RiskHalo"
	_risk_halo.mesh = risk_torus
	_risk_halo.rotation_degrees.x = 90.0
	_risk_halo.position.z = 0.07
	_risk_halo.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_risk_halo.material_override = _risk_material
	_constellation_root.add_child(_risk_halo)


func _build_event_nodes() -> void:
	var node_mesh := SphereMesh.new()
	node_mesh.radius = 0.022
	node_mesh.height = 0.044
	node_mesh.radial_segments = 12
	node_mesh.rings = 6
	for index in range(EVENT_NODE_COUNT):
		var angle := -PI * 0.82 + PI * 1.64 * float(index) / float(EVENT_NODE_COUNT - 1)
		var radius := 0.49 + (0.055 if index % 2 == 0 else -0.018)
		var position := Vector3(sin(angle) * radius, cos(angle) * radius, -0.105)
		var material := _make_material(COLOR_CYAN, 0.12, 1.0)
		var node := MeshInstance3D.new()
		node.name = "EventNode%02d" % index
		node.mesh = node_mesh
		node.position = position
		node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		node.material_override = material
		_constellation_root.add_child(node)
		_event_nodes.append(node)
		_event_materials.append(material)
		_event_positions.append(position)

	_link_mesh_instance = MeshInstance3D.new()
	_link_mesh_instance.name = "CausalLinks"
	_link_mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_constellation_root.add_child(_link_mesh_instance)
	_rebuild_causal_links()


func _build_pulses() -> void:
	var pulse_mesh := SphereMesh.new()
	pulse_mesh.radius = 0.012
	pulse_mesh.height = 0.024
	pulse_mesh.radial_segments = 10
	pulse_mesh.rings = 5
	for index in range(4):
		var pulse := MeshInstance3D.new()
		pulse.name = "InferencePulse%d" % (index + 1)
		pulse.mesh = pulse_mesh
		pulse.position.z = -0.13
		pulse.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		pulse.material_override = _make_material(COLOR_CYAN, 0.8, 3.5)
		_constellation_root.add_child(pulse)
		_pulse_nodes.append(pulse)


func _build_temporal_ribbon() -> void:
	_temporal_ribbon = Node3D.new()
	_temporal_ribbon.name = "TemporalRibbon"
	_temporal_ribbon.position = Vector3(0.0, -0.70, 0.08)
	add_child(_temporal_ribbon)

	var border := _make_quad(Vector2(1.22, 0.34), _make_material(COLOR_CYAN, 0.68, 1.8))
	border.name = "Border"
	border.position.z = -0.025
	_temporal_ribbon.add_child(border)
	var glass := _make_quad(Vector2(1.195, 0.315), _make_material(Color(0.006, 0.025, 0.04), 0.94, 0.05))
	glass.name = "Glass"
	glass.material_override.render_priority = 1
	_temporal_ribbon.add_child(glass)

	_timeline_label = _make_label(
		"TEMPORAL BLACK BOX // LIVE",
		Vector3(-0.55, 0.112, -0.035), 0.0017, 10, 645.0, COLOR_CYAN
	)
	_timeline_label.name = "TimelineLabel"
	_temporal_ribbon.add_child(_timeline_label)
	_current_label = _make_label(
		"NO EVENTS",
		Vector3(-0.55, 0.04, -0.04), 0.0017, 12, 645.0, Color(0.76, 0.98, 1.0)
	)
	_current_label.name = "CurrentEventLabel"
	_temporal_ribbon.add_child(_current_label)
	_privacy_label = _make_label(
		"LOCAL SANDBOX // NO PROVIDER EGRESS",
		Vector3(-0.55, -0.035, -0.04), 0.0017, 9, 645.0, COLOR_GREEN
	)
	_privacy_label.name = "PrivacyLabel"
	_temporal_ribbon.add_child(_privacy_label)

	_make_action_target(
		_temporal_ribbon, "PreviousTarget", "cognition:previous",
		Vector3(-0.40, -0.112, -0.045), Vector2(0.25, 0.065), "‹ REWIND"
	)
	var mode_target := _make_action_target(
		_temporal_ribbon, "ModeTarget", "cognition:mode",
		Vector3(0.0, -0.112, -0.045), Vector2(0.31, 0.065), "FREEZE LENS"
	)
	_mode_button_label = mode_target.get_node("Label") as Label3D
	_make_action_target(
		_temporal_ribbon, "NextTarget", "cognition:next",
		Vector3(0.40, -0.112, -0.045), Vector2(0.25, 0.065), "FORWARD ›"
	)


func _build_privacy_field() -> void:
	_privacy_root = Node3D.new()
	_privacy_root.name = "PrivacyRoute"
	_privacy_root.position = Vector3(0.0, 0.71, 0.08)
	add_child(_privacy_root)

	_route_label = _make_label(
		"HAND  →  LOCAL CORE  →  SEALED",
		Vector3(-0.48, 0.02, -0.035), 0.0015, 9, 570.0, COLOR_CYAN
	)
	_route_label.name = "RouteLabel"
	_privacy_root.add_child(_route_label)

	var route_positions := [Vector3(-0.39, -0.052, -0.035), Vector3(0.0, -0.052, -0.035), Vector3(0.39, -0.052, -0.035)]
	var route_colors := [COLOR_CYAN, COLOR_GREEN, COLOR_MAGENTA]
	for index in range(route_positions.size()):
		var route_mesh := SphereMesh.new()
		route_mesh.radius = 0.018 if index != 1 else 0.026
		route_mesh.height = route_mesh.radius * 2.0
		route_mesh.radial_segments = 12
		route_mesh.rings = 6
		var route_material := _make_material(route_colors[index], 0.9 if index != 2 else 0.16, 2.5)
		var route_node := MeshInstance3D.new()
		route_node.name = ["HandNode", "LocalCoreNode", "ProviderNode"][index]
		route_node.mesh = route_mesh
		route_node.position = route_positions[index]
		route_node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		route_node.material_override = route_material
		_privacy_root.add_child(route_node)
		if index == 2:
			_provider_node = route_node
			_provider_material = route_material

	for x_position in [-0.195, 0.195]:
		var beam_mesh := BoxMesh.new()
		beam_mesh.size = Vector3(0.33, 0.006, 0.006)
		var beam := MeshInstance3D.new()
		beam.name = "RouteBeam"
		beam.mesh = beam_mesh
		beam.position = Vector3(x_position, -0.052, -0.03)
		beam.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		beam.material_override = _make_material(COLOR_CYAN, 0.3, 1.5)
		_privacy_root.add_child(beam)


func _make_action_target(
	parent: Node3D,
	node_name: String,
	target_id: String,
	position: Vector3,
	size: Vector2,
	label_text: String
) -> SpatialActionTarget:
	var target := SpatialActionTarget.new()
	target.name = node_name
	target.position = position
	target.position.z *= -1.0
	target.collision_layer = 2
	target.collision_mask = 0
	target.monitoring = false
	target.target_id = target_id
	target.add_to_group("interactable")
	parent.add_child(target)

	var button_material := _make_material(Color(0.015, 0.24, 0.30), 0.94, 1.0)
	button_material.render_priority = 2
	var mesh := _make_quad(size, button_material)
	mesh.name = "Mesh"
	mesh.position.z = -0.012
	target.add_child(mesh)
	_button_meshes[target_id] = mesh

	var shape := BoxShape3D.new()
	shape.size = Vector3(size.x, size.y, 0.04)
	var collision := CollisionShape3D.new()
	collision.name = "CollisionShape3D"
	collision.shape = shape
	target.add_child(collision)

	var label := _make_label(label_text, Vector3(-size.x * 0.46, 0.0, -0.014), 0.0015, 9, size.x / 0.0015 * 0.92, Color(0.72, 1.0, 1.0))
	label.name = "Label"
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	target.add_child(label)
	return target


func _make_quad(size: Vector2, material: StandardMaterial3D) -> MeshInstance3D:
	var quad := QuadMesh.new()
	quad.size = size
	var instance := MeshInstance3D.new()
	instance.mesh = quad
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	instance.material_override = material
	return instance


func _make_label(
	text_value: String,
	position_value: Vector3,
	pixel_size_value: float,
	font_size_value: int,
	width_value: float,
	color: Color
) -> Label3D:
	var label := Label3D.new()
	label.text = text_value
	label.position = position_value
	label.position.z *= -1.0
	label.pixel_size = pixel_size_value
	label.font_size = font_size_value
	label.outline_size = 4
	label.width = width_value
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	label.modulate = color
	label.no_depth_test = true
	label.render_priority = 4
	label.outline_render_priority = 3
	return label


func _make_material(color: Color, alpha: float, energy: float) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.no_depth_test = true
	material.albedo_color = Color(color.r, color.g, color.b, alpha)
	material.emission_enabled = true
	material.emission = color
	material.emission_energy_multiplier = energy
	material.vertex_color_use_as_albedo = true
	return material


func _rebuild_causal_links() -> void:
	var mesh := ImmediateMesh.new()
	var material := _make_material(COLOR_CYAN, 0.22, 1.2)
	mesh.surface_begin(Mesh.PRIMITIVE_LINES, material)
	for index in range(_event_positions.size()):
		var fade := 0.18 + float(index) / float(maxi(1, EVENT_NODE_COUNT - 1)) * 0.42
		mesh.surface_set_color(Color(COLOR_CYAN.r, COLOR_CYAN.g, COLOR_CYAN.b, fade))
		mesh.surface_add_vertex(Vector3(0.0, 0.0, -0.10))
		mesh.surface_add_vertex(_event_positions[index])
		if index > 0:
			mesh.surface_add_vertex(_event_positions[index - 1])
			mesh.surface_add_vertex(_event_positions[index])
	mesh.surface_end()
	_link_mesh_instance.mesh = mesh


func _refresh_event_visuals() -> void:
	if _event_nodes.is_empty():
		return
	var first_visible_event := maxi(0, _events.size() - EVENT_NODE_COUNT)
	for node_index in range(EVENT_NODE_COUNT):
		var event_index := first_visible_event + node_index
		var node := _event_nodes[node_index]
		var material := _event_materials[node_index]
		if event_index >= _events.size():
			node.visible = false
			continue
		node.visible = true
		var record: Dictionary = _events[event_index]
		var color := record.get("color", COLOR_CYAN) as Color
		var is_selected := event_index == _selected_event_index
		material.albedo_color = Color(color.r, color.g, color.b, 0.98 if is_selected else 0.42)
		material.emission = color
		material.emission_energy_multiplier = 4.0 if is_selected else 1.8
		node.scale = Vector3.ONE * (1.9 if is_selected else 1.0)

	if _events.is_empty() or _selected_event_index < 0:
		_timeline_label.text = "TEMPORAL BLACK BOX // IDLE"
		_current_label.text = "NO EVENTS"
	else:
		var record: Dictionary = _events[_selected_event_index]
		var mode := "LIVE" if _live_mode else "REWIND"
		_timeline_label.text = "TEMPORAL BLACK BOX // %02d/%02d // %s" % [
			_selected_event_index + 1, _events.size(), mode
		]
		_current_label.text = "%s  ·  %s\n%s // %s" % [
			str(record.get("clock", "--:--:--")),
			str(record.get("category", "SYSTEM")),
			str(record.get("summary", "EVENT")),
			_short_thread_id(str(record.get("thread_id", "")))
		]
		var event_color := record.get("color", COLOR_CYAN) as Color
		_current_label.modulate = event_color.lerp(Color.WHITE, 0.28)
	if _mode_button_label != null:
		_mode_button_label.text = "FREEZE LENS" if _live_mode else "RETURN LIVE"
	_refresh_privacy_field()


func _refresh_privacy_field() -> void:
	if _privacy_label == null:
		return
	var status := get_privacy_status()
	_privacy_label.text = status
	var hosted := AppState.provider_name in ["openai", "claude", "council"]
	var consent_locked := not AppState.approval_requests.is_empty()
	var color := COLOR_AMBER if consent_locked else (COLOR_MAGENTA if hosted else COLOR_GREEN)
	_privacy_label.modulate = color
	_route_label.text = "HAND  →  LOCAL CORE  →  %s" % (
		AppState.provider_name.to_upper() if hosted else "SEALED"
	)
	_route_label.modulate = COLOR_MAGENTA if hosted else COLOR_CYAN
	if _provider_material != null:
		_provider_material.albedo_color = Color(color.r, color.g, color.b, 0.95 if hosted else 0.12)
		_provider_material.emission = color
		_provider_material.emission_energy_multiplier = 3.2 if hosted else 0.4
	if _risk_material != null:
		_risk_material.albedo_color = Color(color.r, color.g, color.b, 0.42 if consent_locked else 0.14)
		_risk_material.emission = color


func _follow_focused_orb(delta: float) -> void:
	if _orb_manager == null or _user_rig == null:
		return
	var orb := _orb_manager.get_orb(AppState.focused_thread_id)
	if orb == null:
		return
	var blend := 1.0 - exp(-follow_speed * delta)
	global_position = global_position.lerp(orb.global_position, blend)
	var camera_position := _user_rig.get_camera().global_position
	if global_position.distance_squared_to(camera_position) > 0.001:
		look_at(camera_position, Vector3.UP, true)


func _animate_constellation(delta: float) -> void:
	var thread := AppState.get_thread(AppState.focused_thread_id)
	var speed := 0.08
	if thread != null:
		match thread.status:
			AgentThread.Status.WORKING:
				speed = 0.34
			AgentThread.Status.LISTENING:
				speed = 0.24
			AgentThread.Status.WAITING_USER:
				speed = 0.14
	_constellation_root.rotate_z(delta * speed)
	_risk_halo.scale = Vector3.ONE * (1.0 + sin(_activity_time * 2.2) * 0.018)
	var active_node_count := mini(_events.size(), EVENT_NODE_COUNT)
	for pulse_index in range(_pulse_nodes.size()):
		var pulse := _pulse_nodes[pulse_index]
		if active_node_count <= 0:
			pulse.visible = false
			continue
		pulse.visible = true
		var target_index := (active_node_count - 1 - pulse_index + EVENT_NODE_COUNT) % active_node_count
		var target := _event_positions[target_index]
		var phase := fmod(_activity_time * (0.42 + float(pulse_index) * 0.025) + float(pulse_index) * 0.24, 1.0)
		var eased_phase := phase * phase * (3.0 - 2.0 * phase)
		pulse.position = Vector3(0.0, 0.0, -0.13).lerp(target + Vector3(0.0, 0.0, -0.025), eased_phase)
		pulse.scale = Vector3.ONE * (0.55 + sin(phase * PI) * 0.8)


func _sync_visibility() -> void:
	visible = (
		_enabled
		and not _blocked
		and not AppState.focused_thread_id.is_empty()
	)


func _short_thread_id(thread_id: String) -> String:
	if thread_id.is_empty():
		return "GLOBAL"
	return "AGENT %s" % thread_id.right(6).to_upper()


func _on_focused_thread_changed(thread_id: String) -> void:
	if not thread_id.is_empty():
		_record_event("focus.changed", thread_id, "FOCUS VECTOR ACQUIRED", "ATTENTION", COLOR_CYAN, "LOCAL COMMAND")
	_sync_visibility()


func _on_provider_identity_changed(_provider: String, _model: String) -> void:
	_refresh_privacy_field()


func _on_hovered_target_changed(target_id: String) -> void:
	for button_id_variant in _button_meshes:
		var button_id := str(button_id_variant)
		var mesh := _button_meshes[button_id] as MeshInstance3D
		var material := mesh.material_override as StandardMaterial3D
		var hovered := button_id == target_id
		material.emission_energy_multiplier = 2.8 if hovered else 1.0
		material.albedo_color.a = 1.0 if hovered else 0.94


func _on_backend_command_sent(command_type: String, thread_id: String) -> void:
	record_command(command_type, thread_id)
