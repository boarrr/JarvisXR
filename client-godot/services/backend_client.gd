class_name BackendClient
extends BackendTransport

const TOKEN_CONFIG_PATH := "user://daemon_auth.cfg"
const DAEMON_CONFIG_PATH := "user://daemon.cfg"
const TELEMETRY_INTERVAL_SECONDS := 5.0
const LINK_TIMEOUT_MSEC := 20000

@export var websocket_url: String = "ws://127.0.0.1:8787/ws"
@export var auth_token: String = ""
@export var ca_certificate_path: String = ""
@export var allow_unsafe_tls: bool = false
@export_range(1024, 4_194_304, 1024) var max_packet_bytes: int = 1_048_576
@export var auto_reconnect: bool = true
@export var discovery_enabled: bool = true
@export_range(1, 65535, 1) var discovery_port: int = 8789
@export_range(0.05, 30.0, 0.05) var reconnect_initial_delay_seconds: float = 0.25
@export_range(0.1, 60.0, 0.1) var reconnect_max_delay_seconds: float = 5.0
@export_range(0.05, 3.0, 0.05) var candidate_retry_delay_seconds: float = 0.35

var _socket: WebSocketPeer = null
var _session_id: String = ""
var _command_counter: int = 0
var _local_event_counter: int = 0
var _has_opened: bool = false
var _stopping: bool = false
var _reconnect_attempt: int = 0
var _reconnect_remaining_seconds: float = -1.0
var _protocol_version: int = BackendEvent.PROTOCOL_VERSION
var _url_from_config: bool = false
var _pending_pair_code: String = ""
# Link fallback: keep the configured name first, then a remembered working URL
# and any baked fallbacks (an IP), so a failed .local lookup does not brick the
# headset when a direct IP still works.
var _primal_url: String = ""
var _last_good_url: String = ""
var _fallback_urls: PackedStringArray = []
var _candidate_urls: PackedStringArray = []
var _candidate_index: int = 0
var _discovered_urls: PackedStringArray = []
var _discovery: DiscoveryService = null
# Connection health: heartbeats + telemetry so both sides know the link state.
var _telemetry_accum: float = 0.0
var _last_rx_msec: int = 0
var _last_rtt_msec: int = -1


func _ready() -> void:
	_load_daemon_config()
	_rebuild_candidates()
	set_process(false)
	if discovery_enabled:
		_start_discovery()


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
		_record_last_good()
		_set_connection_state(STATE_CONNECTED)
		_send_command_envelope("session.hello", _hello_payload(), "")
		if not _pending_pair_code.is_empty():
			_send_command_envelope(
				"session.pair",
				{"code": _pending_pair_code, "device_name": OS.get_model_name()},
				""
			)
			_pending_pair_code = ""
	if _socket.get_available_packet_count() > 0:
		_receive_available_packets()
	if _socket == null:
		return
	if _socket.get_ready_state() == WebSocketPeer.STATE_CLOSED:
		_handle_socket_closed()
		return
	if _socket.get_ready_state() == WebSocketPeer.STATE_OPEN:
		_maybe_send_telemetry(delta)
		_check_link_alive()


func _maybe_send_telemetry(delta: float) -> void:
	_telemetry_accum += delta
	if _telemetry_accum < TELEMETRY_INTERVAL_SECONDS:
		return
	_telemetry_accum = 0.0
	var now := Time.get_ticks_msec()
	var payload := {
		"client_ts": now,
		"free_mem": OS.get_static_memory_usage(),
		"version": str(ProjectSettings.get_setting("application/config/version", "")),
	}
	if _last_rtt_msec >= 0:
		payload["rtt_ms"] = _last_rtt_msec
	if _last_rx_msec > 0:
		payload["last_rx_age"] = now - _last_rx_msec
	_send_command_envelope("client.telemetry", payload, "")


func _check_link_alive() -> void:
	if _last_rx_msec <= 0:
		return
	var silent := Time.get_ticks_msec() - _last_rx_msec
	if silent > LINK_TIMEOUT_MSEC:
		print("[BACKEND] link silent for %d ms; reconnecting" % silent)
		_last_rx_msec = 0
		reconnect()


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
	_rebuild_candidates()
	_candidate_index = 0
	_apply_candidate(0)
	if not _is_valid_websocket_url(websocket_url):
		_set_connection_state(STATE_ERROR)
		_emit_local_error("invalid_url", "Backend URL must begin with ws:// or wss://")
		return

	_connect_socket()


func _connect_socket() -> void:
	if _stopping:
		return
	_socket = WebSocketPeer.new()
	# The self-update streams large base64 chunks; the default 64 KB inbound
	# buffer silently drops frames that big (the manifest is small, so it works).
	_socket.set("inbound_buffer_size", 4 * 1024 * 1024)
	_socket.set("outbound_buffer_size", 2 * 1024 * 1024)
	_has_opened = false
	_session_id = ""
	_set_connection_state(STATE_CONNECTING)
	var result := _socket.connect_to_url(websocket_url, build_tls_options(websocket_url))
	if result != OK:
		_socket = null
		_set_connection_state(STATE_ERROR)
		_emit_local_error("connect_failed", "WebSocket connect failed with code %d" % result)
		if _discovery != null:
			_discovery.probe_now()
		_schedule_next_attempt()
		return
	set_process(true)


func stop() -> void:
	_stopping = true
	set_process(false)
	if _discovery != null:
		_discovery.stop()
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


func pair(code: String) -> bool:
	if _socket == null or _socket.get_ready_state() != WebSocketPeer.STATE_OPEN:
		return false
	if code.strip_edges().is_empty():
		return false
	return _send_command_envelope(
		"session.pair",
		{"code": code.strip_edges(), "device_name": OS.get_model_name()},
		""
	)


func is_pairing_supported() -> bool:
	return true


func pair_with_payload(payload_text: String) -> bool:
	# QR pairing: point the payload at this daemon and pair with its code.
	var parsed := PairingPayload.parse(payload_text)
	if parsed.is_empty():
		return false
	var url := str(parsed.get("url", ""))
	if _is_valid_websocket_url(url) and url != websocket_url:
		set_manual_url(url)
	_pending_pair_code = str(parsed.get("code", ""))
	if _socket != null and _socket.get_ready_state() == WebSocketPeer.STATE_OPEN:
		var code := _pending_pair_code
		_pending_pair_code = ""
		return pair(code)
	return not _pending_pair_code.is_empty()


func get_protocol_version() -> int:
	return _protocol_version


func set_default_url(url: String) -> void:
	# Project settings supply the wiring default; a daemon.cfg URL wins so a
	# headset can be repointed at a LAN daemon without a re-export.
	if not _url_from_config and not url.is_empty():
		websocket_url = url
		_primal_url = url
	_rebuild_candidates()


func set_default_fallbacks(value: String) -> void:
	if value.strip_edges().is_empty():
		return
	_fallback_urls = _dedupe_urls(Array(_fallback_urls) + Array(value.split(",", false)))
	_rebuild_candidates()


func set_manual_url(url: String) -> bool:
	var trimmed := url.strip_edges()
	if not _is_valid_websocket_url(trimmed):
		return false
	_primal_url = trimmed
	_url_from_config = true
	_rebuild_candidates()
	reconnect()
	return true


func reconnect() -> void:
	stop()
	start()


func get_candidate_urls() -> PackedStringArray:
	return _candidate_urls.duplicate()


func get_last_good_url() -> String:
	return _last_good_url


func get_http_base() -> String:
	# The daemon serves the update APK + /health over HTTP on the same host/port
	# as the control websocket. Derive an http(s) base from the live URL.
	var source := websocket_url
	if not _last_good_url.is_empty():
		source = _last_good_url
	var base := source.replace("wss://", "https://").replace("ws://", "http://")
	var scheme_end := base.find("://")
	if scheme_end < 0:
		return ""
	var path_start := base.find("/", scheme_end + 3)
	if path_start >= 0:
		base = base.substr(0, path_start)
	return base


func get_protocol_version_value() -> int:
	return BackendEvent.PROTOCOL_VERSION


func build_tls_options(url: String) -> TLSOptions:
	if not url.begins_with("wss://"):
		return null
	# Unsafe TLS takes precedence: the daemon's self-signed cert is issued for a
	# specific IP, so pinning it by CA breaks whenever the network (and IP)
	# changes. For a roaming LAN dev tool we skip verification instead.
	if (
		allow_unsafe_tls
		or bool(ProjectSettings.get_setting("spatial_agent/allow_unsafe_tls", false))
	):
		return TLSOptions.client_unsafe()
	var certificate := _load_certificate()
	if certificate != null:
		return TLSOptions.client(certificate)
	return null


func _load_certificate() -> X509Certificate:
	var candidates := PackedStringArray()
	if not ca_certificate_path.is_empty():
		var path := ca_certificate_path
		if not (path.begins_with("user://") or path.begins_with("res://")):
			path = "user://%s" % path.get_file()
		candidates.append(path)
	# Baked dev CA (shipped in the APK) is the no-push fallback; only present in
	# exported builds (gated by a setting) so headless tests stay CA-free.
	candidates.append("user://dev_ca.crt")
	var baked := str(ProjectSettings.get_setting("spatial_agent/baked_ca_path", ""))
	if not baked.is_empty():
		candidates.append(baked)
	for candidate in candidates:
		var certificate := X509Certificate.new()
		if certificate.load(candidate) == OK:
			return certificate
	return null


func _hello_payload() -> Dictionary:
	var payload := {
		"client": "godot",
		"protocol_version": BackendEvent.PROTOCOL_VERSION,
	}
	if not auth_token.is_empty():
		payload["auth_token"] = auth_token
	return payload


func _load_daemon_config() -> void:
	var config := ConfigFile.new()
	if config.load(DAEMON_CONFIG_PATH) == OK:
		var configured_url := str(config.get_value("daemon", "websocket_url", ""))
		if not configured_url.is_empty():
			websocket_url = configured_url
			_primal_url = configured_url
			_url_from_config = true
		_last_good_url = str(config.get_value("daemon", "last_good_url", ""))
		var fallbacks := str(config.get_value("daemon", "fallbacks", ""))
		if not fallbacks.strip_edges().is_empty():
			_fallback_urls = _dedupe_urls(Array(fallbacks.split(",", false)))
		auth_token = str(config.get_value("daemon", "auth_token", auth_token))
		ca_certificate_path = str(
			config.get_value("daemon", "ca_certificate_path", ca_certificate_path)
		)
		return
	_load_auth_token()


func _save_daemon_config() -> void:
	var config := ConfigFile.new()
	config.set_value(
		"daemon",
		"websocket_url",
		_primal_url if not _primal_url.is_empty() else websocket_url
	)
	config.set_value("daemon", "last_good_url", _last_good_url)
	if not _fallback_urls.is_empty():
		config.set_value("daemon", "fallbacks", ",".join(_fallback_urls))
	config.set_value("daemon", "auth_token", auth_token)
	config.set_value("daemon", "ca_certificate_path", ca_certificate_path)
	config.save(DAEMON_CONFIG_PATH)


func _load_auth_token() -> void:
	var config := ConfigFile.new()
	if config.load(TOKEN_CONFIG_PATH) == OK:
		auth_token = str(config.get_value("daemon", "token", ""))


func _save_auth_token() -> void:
	_save_daemon_config()


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
		_last_rx_msec = Time.get_ticks_msec()
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
		_emit_local_error("invalid_envelope", "Backend packet does not match protocol v1 or v2")
		return
	if event.type == "session.ready":
		_session_id = event.session_id
		_protocol_version = int(event.payload.get("protocol_version", 1))
	if event.type == "server.heartbeat":
		var client_ts := int(event.payload.get("client_ts", 0))
		if client_ts > 0:
			_last_rtt_msec = Time.get_ticks_msec() - client_ts
	backend_event_received.emit(event)
	if event.type == "session.paired":
		var token := str(event.payload.get("token", ""))
		if not token.is_empty():
			auth_token = token
			_save_auth_token()
		_send_command_envelope("session.hello", _hello_payload(), "")
	elif event.type == "session.ready":
		_send_command_envelope("thread.list", {}, "")
		if _protocol_version >= 2:
			_send_command_envelope("workspace.list", {}, "")
			_send_command_envelope("tool.catalog", {}, "")


func _handle_socket_closed() -> void:
	if _socket == null:
		return
	var close_code := _socket.get_close_code()
	var close_reason := _socket.get_close_reason()
	var opened_before_close := _has_opened
	if LogRelay != null:
		LogRelay.note_disconnect("code=%d reason=%s" % [close_code, close_reason])
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
	if opened_before_close:
		_schedule_reconnect()
	else:
		# Never opened: most likely the hostname did not resolve or the host is
		# unreachable. Try the next candidate (e.g. a direct IP) before backing off.
		if _discovery != null:
			_discovery.probe_now()
		_schedule_next_attempt()


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


func _rebuild_candidates() -> void:
	var values: Array = []
	for url in _discovered_urls:
		values.append(url)
	var primary := _primal_url if not _primal_url.is_empty() else websocket_url
	if not primary.is_empty():
		values.append(primary)
	values.append(_last_good_url)
	for fallback in _fallback_urls:
		values.append(fallback)
	_candidate_urls = _dedupe_urls(values)


func _start_discovery() -> void:
	if _discovery != null:
		return
	var script := load("res://services/discovery_service.gd")
	if script == null:
		return
	_discovery = script.new()
	_discovery.name = "DiscoveryService"
	_discovery.discovery_port = discovery_port
	add_child(_discovery)
	_discovery.daemon_found.connect(_on_daemon_found)
	_discovery.start()


func _on_daemon_found(payload: Dictionary) -> void:
	if _discovery == null:
		return
	var urls := DiscoveryService.websocket_urls(payload)
	if urls.is_empty() or urls == _discovered_urls:
		return
	_discovered_urls = urls
	if get_connection_state() == STATE_CONNECTED:
		return
	# A beacon arrived (or the address changed): prefer it immediately.
	if get_connection_state() == STATE_CONNECTING:
		return
	_rebuild_candidates()
	_candidate_index = 0
	_apply_candidate(0)
	reconnect()


func _dedupe_urls(values: Array) -> PackedStringArray:
	var out := PackedStringArray()
	for value in values:
		var url := str(value).strip_edges()
		if url.is_empty() or out.has(url):
			continue
		out.append(url)
	return out


func _apply_candidate(index: int) -> void:
	if _candidate_urls.is_empty():
		return
	_candidate_index = clampi(index, 0, _candidate_urls.size() - 1)
	websocket_url = _candidate_urls[_candidate_index]


func _schedule_next_attempt() -> void:
	if _stopping or not auto_reconnect:
		set_process(false)
		return
	if _candidate_index + 1 < _candidate_urls.size():
		# Another address to try (e.g. the direct IP after a failed name lookup).
		_candidate_index += 1
		_apply_candidate(_candidate_index)
		_reconnect_attempt = 0
		_reconnect_remaining_seconds = candidate_retry_delay_seconds
		set_process(true)
		return
	# Every candidate failed: start over and back off exponentially.
	_candidate_index = 0
	_apply_candidate(0)
	_schedule_reconnect()


func _record_last_good() -> void:
	# Only remember a working *fallback* (i.e. not the configured primary). This
	# keeps daemon.cfg from being rewritten on every normal connection.
	if _primal_url.is_empty() or websocket_url.is_empty() or websocket_url == _primal_url:
		return
	if websocket_url == _last_good_url:
		return
	_last_good_url = websocket_url
	_save_daemon_config()


func _timestamp() -> String:
	return Time.get_datetime_string_from_system(true, false) + "Z"
