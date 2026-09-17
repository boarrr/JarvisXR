class_name DiffSculptor
extends Node3D

const MAX_BARS := 48
const ADDED := 1
const REMOVED := -1
const CONTEXT := 0
const ADDED_COLOR := Color(0.08, 1.0, 0.62, 0.92)
const REMOVED_COLOR := Color(1.0, 0.18, 0.16, 0.92)
const CONTEXT_COLOR := Color(0.08, 0.64, 0.9, 0.38)

var _bar_count := 0
var _added_count := 0
var _removed_count := 0
var _context_count := 0
var _bars: Array[MeshInstance3D] = []
var _elapsed := 0.0


func _process(delta: float) -> void:
	if not visible:
		return
	_elapsed += delta
	for index in range(_bars.size()):
		var bar := _bars[index]
		bar.position.z = -0.025 + sin(_elapsed * 1.65 + float(index) * 0.44) * 0.018


func sculpt(source: String, language: String) -> void:
	_clear_bars()
	var lines := source.split("\n")
	var diff_like := language.to_lower() in ["diff", "patch"]
	if not diff_like:
		for line in lines:
			if (line.begins_with("+") and not line.begins_with("+++")) or (
				line.begins_with("-") and not line.begins_with("---")
			):
				diff_like = true
				break
	if not diff_like:
		visible = false
		return

	for line_index in range(mini(lines.size(), MAX_BARS)):
		var line: String = lines[line_index]
		var kind := CONTEXT
		if line.begins_with("+") and not line.begins_with("+++"):
			kind = ADDED
			_added_count += 1
		elif line.begins_with("-") and not line.begins_with("---"):
			kind = REMOVED
			_removed_count += 1
		else:
			_context_count += 1
		_add_bar(line_index, line.length(), kind)
	_bar_count = _bars.size()
	visible = _bar_count > 0


func get_bar_count() -> int:
	return _bar_count


func get_added_count() -> int:
	return _added_count


func get_removed_count() -> int:
	return _removed_count


func get_context_count() -> int:
	return _context_count


func _clear_bars() -> void:
	_bar_count = 0
	_added_count = 0
	_removed_count = 0
	_context_count = 0
	_bars.clear()
	for child in get_children():
		child.queue_free()


func _add_bar(index: int, character_count: int, kind: int) -> void:
	var bar := MeshInstance3D.new()
	bar.name = "DiffBar%02d" % index
	var width := clampf(0.035 + float(character_count) * 0.0019, 0.05, 0.24)
	var x_offset := 0.06 * float(kind)
	bar.position = Vector3(x_offset, 0.31 - float(index) * 0.014, -0.025)
	bar.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var mesh := BoxMesh.new()
	mesh.size = Vector3(width, 0.006, 0.012)
	var color := CONTEXT_COLOR
	if kind == ADDED:
		color = ADDED_COLOR
	elif kind == REMOVED:
		color = REMOVED_COLOR
	mesh.material = _material(color)
	bar.mesh = mesh
	add_child(bar)
	_bars.append(bar)


func _material(color: Color) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = color
	material.emission_enabled = true
	material.emission = Color(color.r, color.g, color.b, 1.0)
	material.emission_energy_multiplier = 1.8
	material.no_depth_test = true
	return material
