class_name BackendClient
extends BackendTransport

@export var websocket_url: String = "ws://127.0.0.1:8787/ws"
@export_range(1024, 4_194_304, 1024) var max_packet_bytes: int = 1_048_576
@export var auto_reconnect: bool = true
@export_range(0.05, 30.0, 0.05) var reconnect_initial_delay_seconds: float = 0.25
@export_range(0.1, 60.0, 0.1) var reconnect_max_delay_seconds: float = 5.0

var _socket: WebSocketPeer = null
var _session_id: String = ""
var _command_counter: int = 0
var _local_event_counter: int = 0
var _has_opened: bool = false
var _stopping: bool = false
var _reconnect_attempt: int = 0
var _reconnect_remaining_seconds: float = -1.0


func _ready() -> void:
	set_process(false)


func _process(delta: float) -> void:
	if _socket == null:
		if _reconnect_remaining_seconds >= 0.0:
			_reconnect_remaining_seconds -= delta
			if _reconnect_remaining_seconds <= 0.0:
				_reconnect_remaining_seconds = -1.0
				_connect_socket()
		return
	_socket.poll()
	var state := _socket.get_ready_state()
	if state == WebSocketPeer.STATE_OPEN and not _has_opened:
		_has_opened = true
		_reconnect_attempt = 0
		_reconnect_remaining_seconds = -1.0
		_set_connection_state(STATE_CONNECTED)
		_send_command_envelope("session.hello", {"client": "godot", "protocol_version": 1}, "")
	if _socket.get_available_packet_count() > 0:
		_receive_available_packets()
	if _socket == null:
		return
	if _socket.get_ready_state() == WebSocketPeer.STATE_CLOSED:
		_handle_socket_closed()


func get_mode() -> String:
	return "websocket"


func start() -> void:
	if get_connection_state() in [STATE_CONNECTING, STATE_CONNECTED]:
		return
	_session_id = ""
	_has_opened = false
	_stopping = false
	_reconnect_attempt = 0
	_reconnect_remaining_seconds = -1.0
	if not _is_valid_websocket_url(websocket_url):
		_set_connection_state(STATE_ERROR)
		_emit_local_error("invalid_url", "Backend URL must begin with ws:// or wss://")
		return

	_connect_socket()


func _connect_socket() -> void:
	if _stopping:
		return
	_socket = WebSocketPeer.new()
	_has_opened = false
	_session_id = ""
	_set_connection_state(STATE_CONNECTING)
	var result := _socket.connect_to_url(websocket_url)
	if result != OK:
		_socket = null
		_set_connection_state(STATE_ERROR)
		_emit_local_error("connect_failed", "WebSocket connect failed with code %d" % result)
		_schedule_reconnect()
		return
	set_process(true)


func stop() -> void:
	_stopping = true
	set_process(false)
	if _socket != null and _socket.get_ready_state() in [WebSocketPeer.STATE_CONNECTING, WebSocketPeer.STATE_OPEN]:
		_socket.close(1000, "Client shutdown")
	_socket = null
	_has_opened = false
	_session_id = ""
	_reconnect_attempt = 0
	_reconnect_remaining_seconds = -1.0
	super.stop()


func send_command(command_type: String, payload: Dictionary = {}, thread_id: String = "") -> bool:
	if _socket == null or _socket.get_ready_state() != WebSocketPeer.STATE_OPEN:
		return false
	return _send_command_envelope(command_type, payload, thread_id)


func build_command_envelope(command_type: String, payload: Dictionary = {}, thread_id: String = "") -> Dictionary:
	_command_counter += 1
	return {
		"v": BackendEvent.PROTOCOL_VERSION,
		"type": command_type,
		"event_id": "cmd_godot_%06d" % _command_counter,
		"session_id": _session_id,
		"thread_id": thread_id,
		"timestamp": _timestamp(),
		"payload": payload.duplicate(true),
	}


func _send_command_envelope(command_type: String, payload: Dictionary, thread_id: String) -> bool:
	if _socket == null or _socket.get_ready_state() != WebSocketPeer.STATE_OPEN:
		return false
	var envelope := build_command_envelope(command_type, payload, thread_id)
	var result := _socket.send_text(JSON.stringify(envelope))
	if result != OK:
		_emit_local_error("send_failed", "WebSocket send failed with code %d" % result, thread_id)
		return false
	return true


func _receive_available_packets() -> void:
	while _socket != null and _socket.get_available_packet_count() > 0:
		var packet := _socket.get_packet()
		if packet.size() > max_packet_bytes:
			_emit_local_error("packet_too_large", "Backend packet exceeded the configured size limit")
			continue
		if not _socket.was_string_packet():
			_emit_local_error("binary_packet", "Binary backend packets are not supported")
			continue
		_handle_text_packet(packet.get_string_from_utf8())


func _handle_text_packet(text: String) -> void:
	var parser := JSON.new()
	if parser.parse(text) != OK:
		_emit_local_error("invalid_json", "Backend packet is not valid JSON")
		return
	var parsed: Variant = parser.data
	if not parsed is Dictionary:
		_emit_local_error("invalid_json", "Backend packet is not a JSON object")
		return
	var event := BackendEvent.from_envelope(parsed)
	if event == null:
		_emit_local_error("invalid_envelope", "Backend packet does not match protocol v1")
		return
	if event.type == "session.ready":
		_session_id = event.session_id
	backend_event_received.emit(event)
	if event.type == "session.ready":
		_send_command_envelope("thread.list", {}, "")


func _handle_socket_closed() -> void:
	if _socket == null:
		return
	var close_code := _socket.get_close_code()
	var close_reason := _socket.get_close_reason()
	var opened_before_close := _has_opened
	_socket = null
	_has_opened = false
	_session_id = ""
	if _stopping:
		set_process(false)
		_set_connection_state(STATE_OFFLINE)
		return
	_set_connection_state(STATE_ERROR)
	var detail := "WebSocket closed before opening" if not opened_before_close else "WebSocket connection closed"
	_emit_local_error(
		"connection_closed",
		"%s (code=%d reason=%s)" % [detail, close_code, close_reason]
	)
	_schedule_reconnect()


func _schedule_reconnect() -> void:
	if _stopping or not auto_reconnect:
		set_process(false)
		return
	var delay := minf(
		reconnect_initial_delay_seconds * pow(2.0, float(_reconnect_attempt)),
		reconnect_max_delay_seconds
	)
	_reconnect_attempt += 1
	_reconnect_remaining_seconds = delay
	set_process(true)


func _emit_local_error(code: String, message: String, thread_id: String = "") -> void:
	_local_event_counter += 1
	var event := BackendEvent.new(
		"error",
		{"code": code, "message": message, "source": "godot_websocket_client"},
		"evt_client_%06d" % _local_event_counter,
		_session_id,
		thread_id,
		_timestamp()
	)
	backend_event_received.emit(event)


func _is_valid_websocket_url(value: String) -> bool:
	return value.begins_with("ws://") or value.begins_with("wss://")


func _timestamp() -> String:
	return Time.get_datetime_string_from_system(true, false) + "Z"
