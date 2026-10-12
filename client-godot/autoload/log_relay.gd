extends Node

## Relays the headset's Godot logs (engine messages, print() output, and script
## errors) to the daemon over the authenticated WebSocket, so the daemon host can
## debug a wireless headset without USB/adb.
##
## The engine can call the logger from any thread, so the buffer is mutex-guarded;
## batched lines are flushed to the daemon on the main thread every ~0.5s.

const FLUSH_INTERVAL_SECONDS := 0.5
const MAX_BUFFER_LINES := 400
const MAX_LINE_LENGTH := 3800
const MAX_LINES_PER_FLUSH := 40

var _buffer: Array = []
var _mutex := Mutex.new()
var _accumulator := 0.0


class RelayLogger:
	extends Logger

	var _relay: Node

	func _init(relay: Node) -> void:
		_relay = relay

	func _log_message(message: String, error: bool) -> void:
		if _relay != null:
			_relay.push_line(("ERR " if error else "") + message)

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
			_relay.push_line("ERROR %s (%s:%d) %s" % [function, file, line, rationale])


func _init() -> void:
	if OS.has_method("add_logger"):
		OS.add_logger(RelayLogger.new(self))


func push_line(line: String) -> void:
	var text := line.strip_edges()
	if text.is_empty():
		return
	if text.length() > MAX_LINE_LENGTH:
		text = text.substr(0, MAX_LINE_LENGTH)
	_mutex.lock()
	_buffer.append(text)
	if _buffer.size() > MAX_BUFFER_LINES:
		_buffer = _buffer.slice(_buffer.size() - MAX_BUFFER_LINES)
	_mutex.unlock()


func _process(delta: float) -> void:
	_accumulator += delta
	if _accumulator < FLUSH_INTERVAL_SECONDS:
		return
	_accumulator = 0.0
	var transport = ServiceRegistry.backend_transport
	if transport == null or not transport.has_method("send_command"):
		return
	var batch := _drain()
	if batch.is_empty():
		return
	var payload := {
		"level": "info",
		"source": "headset",
		"message": "\n".join(batch),
	}
	if not transport.send_command("client.log", payload):
		_requeue(batch)


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
