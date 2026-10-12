class_name HitboxDebug
extends Node3D

## Draws a red, slightly translucent marker over every interactable hitbox so the
## touch targets are visible while still seeing the panels underneath. Toggled
## from the palm console (DEBUG button) or with F4.

@export var color := Color(1.0, 0.16, 0.16, 0.42)
@export var enabled := false

var _pool: Array[MeshInstance3D] = []
var _material: StandardMaterial3D = null


func _ready() -> void:
	_material = StandardMaterial3D.new()
	_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_material.albedo_color = color
	_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_material.blend_mode = BaseMaterial3D.BLEND_MODE_MIX
	# Always draw on top so the targets are visible even behind/through panels.
	_material.no_depth_test = true
	_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	_material.disable_receive_shadows = true
	_material.render_priority = 10
	if AppState != null and AppState.hitbox_debug_changed.is_connected(_on_toggled) == false:
		AppState.hitbox_debug_changed.connect(_on_toggled)
		enabled = AppState.hitbox_debug_visible


func toggle() -> void:
	if AppState != null:
		AppState.hitbox_debug_visible = not AppState.hitbox_debug_visible
	else:
		enabled = not enabled


func _on_toggled(value: bool) -> void:
	enabled = value


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_F4:
		toggle()
		get_viewport().set_input_as_handled()


func _process(_delta: float) -> void:
	var index := 0
	if enabled:
		for node in get_tree().get_nodes_in_group("interactable"):
			var area := node as Area3D
			if area == null or not area.is_visible_in_tree():
				continue
			for child in area.get_children():
				if not (child is CollisionShape3D):
					continue
				var collision := child as CollisionShape3D
				var shape := collision.shape
				if not (shape is BoxShape3D):
					continue
				var instance := _acquire(index)
				index += 1
				(instance.mesh as BoxMesh).size = (shape as BoxShape3D).size
				instance.global_transform = collision.global_transform
				instance.visible = true
	for i in range(index, _pool.size()):
		_pool[i].visible = false


func _acquire(i: int) -> MeshInstance3D:
	if i < _pool.size():
		return _pool[i]
	var instance := MeshInstance3D.new()
	instance.mesh = BoxMesh.new()
	instance.material_override = _material
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(instance)
	_pool.append(instance)
	return instance
