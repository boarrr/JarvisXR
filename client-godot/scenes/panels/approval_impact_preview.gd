class_name ApprovalImpactPreview
extends Node3D

const MAX_ROUTE_NODES := 4
const SAFE_COLOR := Color(0.08, 1.0, 0.68, 0.95)
const EXTERNAL_COLOR := Color(1.0, 0.27, 0.08, 0.98)

var _route_count := 0
var _is_external := false
var _description := "IMPACT UNKNOWN"


func configure(impact: Dictionary) -> void:
	_clear_preview()
	var route_value: Variant = impact.get("route", [])
	var route: Array = route_value if route_value is Array else []
	_route_count = mini(route.size(), MAX_ROUTE_NODES)
	_is_external = bool(impact.get("external", true))
	var color := EXTERNAL_COLOR if _is_external else SAFE_COLOR

	for index in range(_route_count):
		var x := (float(index) - float(_route_count - 1) * 0.5) * 0.105
		if index > 0:
			_add_link(x - 0.0525, color)
		_add_route_node(Vector3(x, 0.035, 0.0), str(route[index]), color, index)

	var scope := str(impact.get("scope", "unspecified scope"))
	var side_effect := str(impact.get("side_effect", "unknown side effect"))
	var reversibility := str(impact.get("reversibility", "unknown reversibility"))
	_description = "%s // %s // %s" % [scope, side_effect, reversibility]
	_add_caption(_description, color)


func get_route_node_count() -> int:
	return _route_count


func is_external_impact() -> bool:
	return _is_external


func get_description() -> String:
	return _description


func _clear_preview() -> void:
	for child in get_children():
		child.queue_free()


func _add_route_node(position_value: Vector3, route_label: String, color: Color, index: int) -> void:
	var mesh_instance := MeshInstance3D.new()
	mesh_instance.name = "ImpactNode%d" % index
	mesh_instance.position = position_value
	mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var sphere := SphereMesh.new()
	sphere.radius = 0.018
	sphere.height = 0.036
	sphere.radial_segments = 12
	sphere.rings = 6
	sphere.material = _material(color)
	mesh_instance.mesh = sphere
	add_child(mesh_instance)

	var label := Label3D.new()
	label.name = "ImpactLabel%d" % index
	label.position = position_value + Vector3(0.0, -0.042, 0.006)
	label.pixel_size = 0.0015
	label.font_size = 8
	label.outline_size = 3
	label.width = 76.0
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.text = route_label.to_upper()
	label.modulate = Color(color, 1.0)
	label.no_depth_test = true
	add_child(label)


func _add_link(x: float, color: Color) -> void:
	var mesh_instance := MeshInstance3D.new()
	mesh_instance.position = Vector3(x, 0.035, -0.002)
	mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var box := BoxMesh.new()
	box.size = Vector3(0.07, 0.004, 0.004)
	box.material = _material(Color(color, 0.62))
	mesh_instance.mesh = box
	add_child(mesh_instance)


func _add_caption(caption: String, color: Color) -> void:
	var label := Label3D.new()
	label.name = "ImpactCaption"
	label.position = Vector3(0.0, -0.09, 0.008)
	label.pixel_size = 0.0017
	label.font_size = 8
	label.outline_size = 3
	label.width = 245.0
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.text = caption.to_upper()
	label.modulate = Color(color, 0.9)
	label.no_depth_test = true
	add_child(label)


func _material(color: Color) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = color
	material.emission_enabled = true
	material.emission = Color(color.r, color.g, color.b, 1.0)
	material.emission_energy_multiplier = 2.0
	material.no_depth_test = true
	return material
