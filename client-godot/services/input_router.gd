class_name InputRouter
extends RefCounted

signal source_changed(source_name: String)

var _active_source: InteractionSource = null


func register_source(source: InteractionSource) -> bool:
	if source == null:
		push_warning("[INPUT] Ignored a null interaction source")
		return false
	if _active_source == source:
		return true

	_active_source = source
	source_changed.emit(source.source_name)
	print("[INPUT] Active interaction source: %s" % source.source_name)
	return true


func get_active_source() -> InteractionSource:
	return _active_source


func get_active_source_name() -> String:
	if _active_source == null:
		return "none"
	return _active_source.source_name


func clear_source() -> void:
	if _active_source == null:
		return
	_active_source = null
	source_changed.emit("none")

