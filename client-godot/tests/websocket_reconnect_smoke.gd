extends Node

const TEST_PORT := 18789
const TIMEOUT_SECONDS := 6.0

var _client: BackendClient = null
var _elapsed: float = 0.0
var _failed := false
var _snapshot_count: int = 0
var _session_ids: Array[String] = []


func _ready() -> void:
	_client = BackendClient.new()
	_client.websocket_url = "ws://127.0.0.1:%d/ws" % TEST_PORT
	_client.reconnect_initial_delay_seconds = 0.05
	_client.reconnect_max_delay_seconds = 0.1
	_client.backend_event_received.connect(_on_backend_event_received)
	add_child(_client)
	_client.start()


func _process(delta: float) -> void:
	_elapsed += delta
	if _elapsed < TIMEOUT_SECONDS:
		return
	_check(false, "timed out waiting for the reconnect snapshot")
	_finish()


func _on_backend_event_received(event: BackendEvent) -> void:
	if event.type == "session.ready":
		_session_ids.append(event.session_id)
	elif event.type == "thread.snapshot":
		_snapshot_count += 1
		if _snapshot_count == 2:
			_check(_session_ids.size() == 2, "both reconnect handshakes complete")
			_check(_session_ids[0] != _session_ids[1], "reconnect replaces the expired session")
			_check(_client.get_connection_state() == BackendTransport.STATE_CONNECTED, "client is connected after recovery")
			_finish()


func _finish() -> void:
	set_process(false)
	_client.stop()
	if not _failed:
		print("[TEST] WebSocket reconnect and snapshot checks passed")
	get_tree().quit(1 if _failed else 0)


func _check(condition: bool, description: String) -> void:
	if condition:
		return
	_failed = true
	push_error("[TEST] Failed: %s" % description)
