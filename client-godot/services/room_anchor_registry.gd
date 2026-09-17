class_name RoomAnchorRegistry
extends Node

signal anchor_changed(anchor_id: String)

const MAX_ANCHORS := 16
const ALLOWED_CLASSIFICATIONS := [
	"reading_zone",
	"approval_gate",
	"mission_header",
	"privacy_gate",
	"floor",
]

var _anchors: Dictionary = {}


func register_anchor(
	anchor_id: String,
	classification: String,
	transform: Transform3D,
	source: String = "local_frame"
) -> bool:
	var safe_id := anchor_id.strip_edges()
	if safe_id.is_empty() or safe_id.length() > 48 or "\n" in safe_id:
		return false
	if classification not in ALLOWED_CLASSIFICATIONS:
		return false
	if not _anchors.has(safe_id) and _anchors.size() >= MAX_ANCHORS:
		return false
	_anchors[safe_id] = {
		"classification": classification,
		"transform": transform,
		"source": source,
		"persistence": "session_only",
	}
	anchor_changed.emit(safe_id)
	return true


func has_anchor(anchor_id: String) -> bool:
	return _anchors.has(anchor_id)


func get_anchor_transform(anchor_id: String) -> Transform3D:
	if not _anchors.has(anchor_id):
		return Transform3D.IDENTITY
	return (_anchors[anchor_id] as Dictionary).get("transform", Transform3D.IDENTITY) as Transform3D


func get_anchor_count() -> int:
	return _anchors.size()


func get_capabilities() -> Dictionary:
	return {
		"provider": "local_frame",
		"session_only": true,
		"stores_scene_mesh": false,
		"vendor_scene_api_connected": false,
	}


func get_content_blind_summary() -> String:
	var summaries: Array[String] = []
	for anchor_id in _anchors:
		var record: Dictionary = _anchors[anchor_id]
		summaries.append("%s:%s" % [anchor_id, record.get("classification", "unknown")])
	summaries.sort()
	return "|".join(summaries)


func clear_session() -> void:
	_anchors.clear()
