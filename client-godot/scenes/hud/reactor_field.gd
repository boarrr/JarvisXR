class_name ReactorField
extends Node3D

# Bounded GPU animation: two draw primitives, no per-mote scene nodes or updates.
const MAX_MOTES := 3200
var _motes: MultiMeshInstance3D
var _floor_material: ShaderMaterial
var _mote_material: ShaderMaterial
var _clock := 0.0
var _activity := 0.0
var _focus_pulse := 0.0


func _ready() -> void:
	_floor_material = ShaderMaterial.new()
	_floor_material.shader = preload("res://shaders/reactor_floor.gdshader")
	var plane := PlaneMesh.new()
	plane.size = Vector2(6.0, 6.0)
	plane.material = _floor_material
	var floor_ring := MeshInstance3D.new()
	floor_ring.mesh = plane
	floor_ring.position = Vector3(0.0, 0.018, -1.2)
	floor_ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(floor_ring)
	_mote_material = ShaderMaterial.new()
	_mote_material.render_priority = -10
	_mote_material.shader = preload("res://shaders/reactor_motes.gdshader")
	var quad := QuadMesh.new()
	quad.size = Vector2(0.014, 0.014)
	quad.material = _mote_material
	var batch := MultiMesh.new()
	batch.transform_format = MultiMesh.TRANSFORM_3D
	batch.use_custom_data = true
	batch.mesh = quad
	batch.instance_count = MAX_MOTES
	batch.custom_aabb = AABB(Vector3(-6, -0.1, -6), Vector3(12, 4.2, 12))
	var random := RandomNumberGenerator.new()
	random.seed = 470205
	for index in range(MAX_MOTES):
		batch.set_instance_transform(index, Transform3D.IDENTITY)
		batch.set_instance_custom_data(index, Color(random.randf(), random.randf(), random.randf(), random.randf()))
	_motes = MultiMeshInstance3D.new()
	_motes.multimesh = batch
	_motes.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_motes)
	set_quality(1)
	AppState.ui_mode_changed.connect(_update_visibility)
	AppState.privacy_veil_changed.connect(_update_visibility)
	AppState.focused_thread_changed.connect(func(_id: String) -> void: _focus_pulse = 1.0)
	_update_visibility()


func _process(delta: float) -> void:
	_clock += delta
	_focus_pulse = maxf(0.0, _focus_pulse - delta * 0.5)
	_activity = lerpf(_activity, (0.45 if not AppState.focused_thread_id.is_empty() else 0.0) + _focus_pulse * 0.55, minf(delta * 3.0, 1.0))
	for material in [_floor_material, _mote_material]:
		material.set_shader_parameter("clock_time", _clock)
		material.set_shader_parameter("activity", _activity)


func _update_visibility(_unused: Variant = null) -> void:
	visible = AppState.ui_mode != "xr_hands" and not AppState.privacy_veil_active
	set_process(visible)


func set_quality(level: int) -> void:
	if _motes != null:
		_motes.multimesh.visible_instance_count = [384, 1200, MAX_MOTES][clampi(level, 0, 2)]
