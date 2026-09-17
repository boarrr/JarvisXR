extends Node

const TEST_PORT := 18787
const TIMEOUT_SECONDS := 4.0

var _client: BackendClient = null
var _elapsed: float = 0.0
var _failed := false
var _received_ready := false


func _ready() -> void:
	_client = BackendClient.new()
	_client.websocket_url = "ws://127.0.0.1:%d/ws" % TEST_PORT
	_client.backend_event_received.connect(_on_backend_event_received)
	add_child(_client)
	_client.start()


func _process(delta: float) -> void:
	_elapsed += delta
	if _elapsed < TIMEOUT_SECONDS:
		return
	_check(false, "timed out waiting for loopback thread.snapshot")
	_finish()


func _on_backend_event_received(event: BackendEvent) -> void:
	if event.type == "error":
		_check(false, "client emitted error: %s" % event.payload.get("message", "unknown"))
		_finish()
		return
	if event.type == "session.ready":
		_received_ready = true
		_check(event.session_id == "sess_loopback", "session.ready survives the real socket path")
	elif event.type == "thread.snapshot":
		_check(_received_ready, "session.ready arrives before the snapshot")
		_check(event.session_id == "sess_loopback", "snapshot keeps session identity")
		_check(event.payload.get("threads", null) is Array, "snapshot payload crosses the socket")
		_finish()


func _finish() -> void:
	set_process(false)
	_client.stop()
	if not _failed:
		print("[TEST] WebSocket loopback smoke checks passed")
	get_tree().quit(1 if _failed else 0)


func _check(condition: bool, description: String) -> void:
	if condition:
		return
	_failed = true
	push_error("[TEST] Failed: %s" % description)
