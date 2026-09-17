class_name BackendEvent
extends RefCounted

const PROTOCOL_VERSION := 1

var version: int = PROTOCOL_VERSION
var type: String
var event_id: String
var session_id: String
var thread_id: String
var timestamp: String
var payload: Dictionary


func _init(
	event_type: String = "",
	event_payload: Dictionary = {},
	event_identifier: String = "",
	event_session_id: String = "",
	event_thread_id: String = "",
	event_timestamp: String = ""
) -> void:
	type = event_type
	payload = event_payload.duplicate(true)
	event_id = event_identifier
	session_id = event_session_id
	thread_id = event_thread_id
	timestamp = event_timestamp


func is_valid() -> bool:
	return (
		version == PROTOCOL_VERSION
		and not type.is_empty()
		and not event_id.is_empty()
		and payload != null
	)


func to_envelope() -> Dictionary:
	return {
		"v": version,
		"type": type,
		"event_id": event_id,
		"session_id": session_id,
		"thread_id": thread_id,
		"timestamp": timestamp,
		"payload": payload.duplicate(true),
	}


static func from_envelope(envelope: Dictionary) -> BackendEvent:
	if int(envelope.get("v", 0)) != PROTOCOL_VERSION:
		return null
	if not envelope.get("type", null) is String or str(envelope.get("type", "")).is_empty():
		return null
	if not envelope.get("event_id", null) is String or str(envelope.get("event_id", "")).is_empty():
		return null
	if not envelope.get("session_id", null) is String:
		return null
	if not envelope.get("thread_id", null) is String:
		return null
	if not envelope.get("timestamp", null) is String or str(envelope.get("timestamp", "")).is_empty():
		return null
	if not envelope.get("payload", null) is Dictionary:
		return null

	var event := BackendEvent.new(
		str(envelope["type"]),
		envelope["payload"],
		str(envelope["event_id"]),
		str(envelope["session_id"]),
		str(envelope["thread_id"]),
		str(envelope["timestamp"])
	)
	event.version = int(envelope["v"])
	return event
