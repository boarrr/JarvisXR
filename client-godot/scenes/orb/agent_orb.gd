class_name AgentOrb
extends Area3D

@export var idle_color := Color(0.04, 0.82, 0.92, 1.0)
@export var listening_color := Color(0.18, 1.0, 0.72, 1.0)
@export var working_color := Color(0.08, 0.62, 1.0, 1.0)
@export var waiting_color := Color(1.0, 0.58, 0.12, 1.0)
@export var complete_color := Color(0.20, 0.95, 0.62, 1.0)
@export var error_color := Color(1.0, 0.17, 0.19, 1.0)
@export_range(1.0, 30.0, 0.5) var animation_speed: float = 12.0
@export_range(1.0, 20.0, 0.5) var movement_speed: float = 7.0

@onready var _visual_root: Node3D = $VisualRoot
@onready var _shell: MeshInstance3D = $VisualRoot/HoloShell
@onready var _core: MeshInstance3D = $VisualRoot/Core
@onready var _core_dot: MeshInstance3D = $VisualRoot/CoreDot
@onready var _outer_ring: MeshInstance3D = $VisualRoot/OuterRing
@onready var _orbit_gimbal: Node3D = $VisualRoot/OrbitGimbal
@onready var _orbit_ring: MeshInstance3D = $VisualRoot/OrbitGimbal/OrbitRing
@onready var _inner_gimbal: Node3D = $VisualRoot/InnerGimbal
@onready var _inner_ring: MeshInstance3D = $VisualRoot/InnerGimbal/InnerRing
@onready var _tick_ring: MultiMeshInstance3D = $VisualRoot/TickRing
@onready var _status_segments: MultiMeshInstance3D = $VisualRoot/StatusSegments
@onready var _needle_pivot: Node3D = $VisualRoot/NeedlePivot
@onready var _needle: MeshInstance3D = $VisualRoot/NeedlePivot/Needle
@onready var _selection_ring: MeshInstance3D = $VisualRoot/SelectionRing
@onready var _title_label: Label3D = $TitleLabel
@onready var _status_label: Label3D = $StatusLabel
@onready var _telemetry_label: Label3D = $TelemetryLabel

var _thread: AgentThread = null
var _shell_material: ShaderMaterial
var _core_material: ShaderMaterial
var _detail_material: StandardMaterial3D
var _line_material: StandardMaterial3D
var _selection_material: StandardMaterial3D
var _is_hovered: bool = false
var _is_selected: bool = false
var _target_scale := Vector3.ONE
var _target_global_position := Vector3.ZERO
var _has_position_target := false
var _activity_time := 0.0
var _kinetic := false


func _ready() -> void:
	_shell_material = ShaderMaterial.new()
	_shell_material.shader = preload("res://shaders/agent_plasma.gdshader")
	_shell_material.set_shader_parameter("shell", true)
	_shell_material.set_shader_parameter("surface_opacity", 0.4)
	_core_material = ShaderMaterial.new()
	_core_material.shader = _shell_material.shader
	_core_material.set_shader_parameter("surface_opacity", 0.9)
	_detail_material = _make_hologram_material(0.88, 3.0)
	_line_material = _make_hologram_material(0.72, 2.1)
	_selection_material = _make_hologram_material(0.96, 4.0)
	_shell.material_override = _shell_material
	_core.material_override = _core_material
	_core_dot.material_override = _detail_material
	_outer_ring.material_override = _line_material
	_orbit_ring.material_override = _line_material
	_inner_ring.material_override = _detail_material
	_needle.material_override = _detail_material
	_selection_ring.material_override = _selection_material
	_build_tick_ring()
	_build_status_segments()

	AppState.hovered_target_changed.connect(_on_hovered_target_changed)
	AppState.focused_thread_changed.connect(_on_focused_thread_changed)
	AppState.thread_updated.connect(_on_thread_updated)
	_refresh_visuals()


func _process(delta: float) -> void:
	_activity_time += delta
	var blend := 1.0 - exp(-animation_speed * delta)
	var activity_scale := _get_activity_scale()
	scale = scale.lerp(_target_scale * activity_scale, blend)
	if _has_position_target:
		if _kinetic:
			global_position = _target_global_position
		else:
			var movement_blend := 1.0 - exp(-movement_speed * delta)
			global_position = global_position.lerp(_target_global_position, movement_blend)

	var rotation_speed := _get_rotation_speed()
	_orbit_gimbal.rotate_z(delta * rotation_speed)
	_inner_gimbal.rotate_z(-delta * rotation_speed * 0.72)
	_tick_ring.rotate_z(delta * rotation_speed * 0.10)
	_status_segments.rotate_z(-delta * rotation_speed * 0.42)
	_needle_pivot.rotation.z = sin(_activity_time * maxf(0.35, rotation_speed)) * 0.72
	_core_dot.scale = Vector3.ONE * (1.0 + sin(_activity_time * 3.2) * 0.12)
	if _is_selected:
		_selection_ring.scale = Vector3.ONE * (1.0 + sin(_activity_time * 2.4) * 0.022)


func bind_thread(thread: AgentThread) -> void:
	if thread == null or thread.id.is_empty():
		push_warning("[STATE] AgentOrb rejected a thread without an ID")
		return
	_thread = thread
	_on_hovered_target_changed(AppState.hovered_target_id)
	_on_focused_thread_changed(AppState.focused_thread_id)
	_refresh_visuals()


func get_thread() -> AgentThread:
	return _thread


func get_interaction_target_id() -> String:
	return _thread.id if _thread != null and is_visible_in_tree() else ""


func set_target_global_position(value: Vector3) -> void:
	_target_global_position = value
	_has_position_target = true


func set_kinetic(value: bool) -> void:
	# Kinetic orbs are positioned directly each frame (throw physics, attract)
	# instead of easing toward a layout target.
	_kinetic = value


func collapse_and_free() -> void:
	var tween := create_tween()
	tween.tween_property(self, "scale", Vector3.ZERO, 0.28).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_IN)
	tween.parallel().tween_property(self, "rotation", rotation + Vector3(0.0, 1.4, 0.0), 0.28)
	tween.tween_callback(queue_free)


func get_target_global_position() -> Vector3:
	return _target_global_position


func set_hovered(value: bool) -> void:
	if _is_hovered == value:
		return
	_is_hovered = value
	_refresh_visuals()


func set_selected(value: bool) -> void:
	if _is_selected == value:
		return
	_is_selected = value
	_refresh_visuals()


func _make_hologram_material(alpha: float, energy: float) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.emission_enabled = true
	material.albedo_color = Color(0.0, 0.85, 1.0, alpha)
	material.emission = Color(0.0, 0.85, 1.0, 1.0)
	material.emission_energy_multiplier = energy
	return material


func _build_tick_ring() -> void:
	var tick_mesh := BoxMesh.new()
	tick_mesh.size = Vector3(0.004, 0.025, 0.004)
	tick_mesh.material = _line_material
	var multimesh := MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.instance_count = 36
	multimesh.mesh = tick_mesh
	for index in range(multimesh.instance_count):
		var angle := TAU * float(index) / float(multimesh.instance_count)
		var is_major := index % 3 == 0
		var tick_scale := Vector3(1.25, 1.85 if is_major else 0.8, 1.0)
		var radius := 0.312
		var position := Vector3(sin(angle) * radius, cos(angle) * radius, 0.0)
		var basis := Basis(Vector3.FORWARD, -angle).scaled(tick_scale)
		multimesh.set_instance_transform(index, Transform3D(basis, position))
	_tick_ring.multimesh = multimesh


func _build_status_segments() -> void:
	var segment_mesh := BoxMesh.new()
	segment_mesh.size = Vector3(0.008, 0.048, 0.005)
	segment_mesh.material = _detail_material
	var multimesh := MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.instance_count = 14
	multimesh.mesh = segment_mesh
	for index in range(multimesh.instance_count):
		var progress := float(index) / float(multimesh.instance_count - 1)
		var angle := deg_to_rad(-112.0 + progress * 224.0)
		var radius := 0.252
		var position := Vector3(sin(angle) * radius, cos(angle) * radius, 0.0)
		var basis := Basis(Vector3.FORWARD, -angle)
		multimesh.set_instance_transform(index, Transform3D(basis, position))
	_status_segments.multimesh = multimesh


func _refresh_visuals() -> void:
	if not is_node_ready():
		return

	var color := _status_color()
	if _is_selected:
		color = color.lerp(Color.WHITE, 0.18)
	elif _is_hovered:
		color = color.lerp(Color.WHITE, 0.10)

	_shell_material.set_shader_parameter("tint", color)
	_shell_material.set_shader_parameter("surface_opacity", 0.65 if _is_selected else 0.4)
	_core_material.set_shader_parameter("tint", color)
	_core_material.set_shader_parameter("activity", 1.0 if _thread != null and _thread.status == AgentThread.Status.WORKING else 0.2)
	_set_material_color(_detail_material, color, 0.92)
	_set_material_color(_line_material, color, 0.78 if _is_hovered or _is_selected else 0.48)
	_set_material_color(_selection_material, Color(0.46, 0.96, 1.0), 0.95)
	_selection_ring.visible = _is_selected

	_target_scale = Vector3.ONE * (1.16 if _is_selected else (1.07 if _is_hovered else 1.0))
	_title_label.text = _thread.title if _thread != null else "Unbound agent"
	_status_label.text = AgentThread.status_label(_thread.status) if _thread != null else "NO THREAD"
	_telemetry_label.text = _telemetry_text()
	_title_label.modulate = Color(0.82, 0.96, 1.0, 1.0) if _is_hovered or _is_selected else Color(0.55, 0.76, 0.82, 1.0)
	_status_label.modulate = color
	_telemetry_label.modulate = Color(color.r, color.g, color.b, 0.58)


func _set_material_color(material: StandardMaterial3D, color: Color, alpha: float) -> void:
	material.albedo_color = Color(color.r, color.g, color.b, alpha)
	material.emission = color


func _telemetry_text() -> String:
	if _thread == null:
		return "A-00 // NO LINK"
	var short_id := _thread.id.right(4).to_upper()
	return "%s // %02d MSG" % [short_id, _thread.messages.size()]


func _status_color() -> Color:
	if _thread == null:
		return idle_color
	match _thread.status:
		AgentThread.Status.LISTENING:
			return listening_color
		AgentThread.Status.WORKING:
			return working_color
		AgentThread.Status.WAITING_USER:
			return waiting_color
		AgentThread.Status.COMPLETE:
			return complete_color
		AgentThread.Status.ERROR:
			return error_color
		_:
			return idle_color


func _get_activity_scale() -> float:
	if _thread == null:
		return 1.0
	match _thread.status:
		AgentThread.Status.LISTENING:
			return 1.0 + sin(_activity_time * 5.0) * 0.032
		AgentThread.Status.WORKING:
			return 1.0 + sin(_activity_time * 3.5) * 0.020
		AgentThread.Status.WAITING_USER:
			return 1.0 + sin(_activity_time * 2.5) * 0.026
		_:
			return 1.0


func _get_rotation_speed() -> float:
	if _thread == null:
		return 0.25
	match _thread.status:
		AgentThread.Status.WORKING:
			return 1.7
		AgentThread.Status.LISTENING:
			return 1.1
		AgentThread.Status.WAITING_USER:
			return 0.75
		AgentThread.Status.ERROR:
			return 0.18
		_:
			return 0.32


func _on_hovered_target_changed(target_id: String) -> void:
	set_hovered(_thread != null and _thread.id == target_id)


func _on_focused_thread_changed(thread_id: String) -> void:
	set_selected(_thread != null and _thread.id == thread_id)


func _on_thread_updated(thread: AgentThread) -> void:
	if _thread != null and thread.id == _thread.id:
		_thread = thread
		_refresh_visuals()
