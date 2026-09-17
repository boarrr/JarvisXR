class_name BackendTransport
extends Node

signal backend_event_received(event: BackendEvent)
signal connection_state_changed(state: String)

const STATE_OFFLINE := "offline"
const STATE_CONNECTING := "connecting"
const STATE_CONNECTED := "connected"
const STATE_ERROR := "error"

var _connection_state: String = STATE_OFFLINE


func get_mode() -> String:
	return "unknown"


func get_connection_state() -> String:
	return _connection_state


func start() -> void:
	push_warning("[BACKEND] start() is not implemented by this transport")


func stop() -> void:
	_set_connection_state(STATE_OFFLINE)


func send_command(_command_type: String, _payload: Dictionary = {}, _thread_id: String = "") -> bool:
	return false


func _set_connection_state(state: String) -> void:
	if _connection_state == state:
		return
	_connection_state = state
	connection_state_changed.emit(state)
