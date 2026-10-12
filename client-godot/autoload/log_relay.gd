extends Node

## Relays the headset's Godot logs (engine messages, print() output, and script
## errors) to the daemon over the authenticated WebSocket, so the daemon host can
## debug a wireless headset without USB/adb.
##
## The engine can call the logger from any thread, so the buffer is mutex-guarded.
## A rolling tail is persisted to user://logs/last_session.log so the previous
## session's logs can be sent as a "breadcrumb" after a crash or reconnect.

const FLUSH_INTERVAL_SECONDS := 0.5
const PERSIST_INTERVAL_SECONDS := 20.0
const MAX_BUFFER_LINES := 400
const MAX_RING_LINES := 400
const MAX_LINE_LENGTH := 3800
const MAX_LINES_PER_FLUSH := 40
const BREADCRUMB_LINES := 120
const LOG_DIR := "user://logs"
const LAST_SESSION_PATH := "user://logs/last_session.log"

var _buffer: Array = []
var _ring: Array = []
var _mutex := Mutex.new()
var _seq := 0
var _accumulator := 0.0
var _persist_accumulator := 0.0
var _previous_tail := ""
var _breadcrumb_sent := false
var _last_disconnect := ""
var _signal_connected := false


class RelayLogger:
	extends Logger

	var _relay: Node

	func _init(relay: Node) -> void:
		_relay = relay

	func _log_message(message: String, error: bool) -> void:
		if _relay != null:
			_relay.push_line(message, "error" if error else "info")

	func _log_error(
		function: String,
		file: String,
		line: int,
		code: String,
		rationale: String,
		editor_notify: bool,
		error_type: int,
		script_backtraces: Array[ScriptBacktrace]
	) -> void:
		if _relay != null:
			var level := "warn" if error_type == 1 else "error"
			_relay.push_line("%s (%s:%d) %s" % [function, file, line, rationale], level)


func _init() -> void:
	if OS.has_method("add_logger"):
		OS.add_logger(RelayLogger.new(self))


func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(LOG_DIR))
	_load_previous_tail()


func _ensure_signal() -> void:
	if _signal_connected:
		return
	var transport = ServiceRegistry.backend_transport
	if transport == null or not transport.has_signal("backend_event_received"):
		return
	if not transport.is_connected("backend_event_received", _on_backend_event):
		transport.backend_event_received.connect(_on_backend_event)
	_signal_connected = true


func info(message: String, tags: String = "") -> void:
	push_line(message, "info", tags)


func warn(message: String, tags: String = "") -> void:
	push_line(message, "warn", tags)


func error(message: String, tags: String = "") -> void:
	push_line(message, "error", tags)


func note_disconnect(reason: String) -> void:
	_last_disconnect = reason


func push_line(line: String, level: String = "info", tags: String = "") -> void:
	var text := line.strip_edges()
	if text.is_empty():
		return
	if text.length() > MAX_LINE_LENGTH:
		text = text.substr(0, MAX_LINE_LENGTH)
	_mutex.lock()
	_seq += 1
	var entry := "%s [%s] %s" % [String.num(_seq), level, text]
	_buffer.append({"seq": _seq, "level": level, "tags": tags, "text": text})
	if _buffer.size() > MAX_BUFFER_LINES:
		_buffer = _buffer.slice(_buffer.size() - MAX_BUFFER_LINES)
	_ring.append(entry)
	if _ring.size() > MAX_RING_LINES:
		_ring = _ring.slice(_ring.size() - MAX_RING_LINES)
	_mutex.unlock()


func _process(delta: float) -> void:
	_ensure_signal()
	_accumulator += delta
	if _accumulator >= FLUSH_INTERVAL_SECONDS:
		_accumulator = 0.0
		_flush()
	_persist_accumulator += delta
	if _persist_accumulator >= PERSIST_INTERVAL_SECONDS:
		_persist_accumulator = 0.0
		_persist_ring()


func _flush() -> void:
	var transport = ServiceRegistry.backend_transport
	if transport == null or not transport.has_method("send_command"):
		return
	var batch := _drain()
	if batch.is_empty():
		return
	var lines: Array = []
	var level := "info"
	for entry in batch:
		lines.append(entry["text"])
		if entry["level"] == "error":
			level = "error"
		elif entry["level"] == "warn" and level != "error":
			level = "warn"
	var payload := {"level": level, "source": "headset", "message": "\n".join(lines)}
	if not transport.send_command("client.log", payload):
		_requeue(batch)


func _on_backend_event(event: BackendEvent) -> void:
	if event == null or event.type != "session.ready" or _breadcrumb_sent:
		return
	_breadcrumb_sent = true
	_send_breadcrumb()


func _send_breadcrumb() -> void:
	var transport = ServiceRegistry.backend_transport
	if transport == null or not transport.has_method("send_command"):
		return
	var parts: Array = []
	if not _last_disconnect.is_empty():
		parts.append("previous disconnect: %s" % _last_disconnect)
	if not _previous_tail.is_empty():
		parts.append("previous session tail:\n%s" % _previous_tail)
	if parts.is_empty():
		return
	transport.send_command("client.log", {
		"level": "info",
		"source": "breadcrumb",
		"message": "\n".join(parts),
	})


func _drain() -> Array:
	_mutex.lock()
	var batch: Array = _buffer.slice(0, MAX_LINES_PER_FLUSH)
	_buffer = _buffer.slice(batch.size())
	_mutex.unlock()
	return batch


func _requeue(batch: Array) -> void:
	_mutex.lock()
	var combined: Array = batch.duplicate()
	combined.append_array(_buffer)
	_buffer = combined.slice(-MAX_BUFFER_LINES)
	_mutex.unlock()


func _persist_ring() -> void:
	_mutex.lock()
	var tail: Array = _ring.slice(_ring.size() - MAX_RING_LINES)
	_mutex.unlock()
	var file := FileAccess.open(LAST_SESSION_PATH, FileAccess.WRITE)
	if file == null:
		return
	file.store_string("\n".join(tail))
	file.close()


func _load_previous_tail() -> void:
	if not FileAccess.file_exists(LAST_SESSION_PATH):
		return
	var file := FileAccess.open(LAST_SESSION_PATH, FileAccess.READ)
	if file == null:
		return
	var contents := file.get_as_text()
	file.close()
	var lines := contents.split("\n")
	var tail := lines.slice(max(0, lines.size() - BREADCRUMB_LINES))
	_previous_tail = "\n".join(tail)


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST or what == NOTIFICATION_PREDELETE:
		_persist_ring()
