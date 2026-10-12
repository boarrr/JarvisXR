class_name UpdaterService
extends Node

## Pulls a newly published APK from the daemon and hands it to the Android
## package installer.
##
## The APK is fetched over HTTPS from the same host/port as the control websocket
## (GET /update/<sha>.apk). It is split into N parallel byte-range streams, each
## written to its own part file and independently resumed from its last byte, so
## a lossy Wi-Fi link keeps making progress (while one stream stalls, the others
## advance). The parts are concatenated, sha256-verified, then installed.

signal update_available(version: String, sha256: String, size_bytes: int)
signal update_up_to_date(version: String)
signal download_progress(received: int, total: int)
signal install_launched(version: String)
signal update_failed(reason: String)

const UPDATE_DIR := "user://updates"
const UPDATE_PATH := "user://updates/update.apk"
const PART_PATH := "user://updates/update.apk.part"
const META_PATH := "user://updates/update.meta"
const INSTALLED_SHA_PATH := "user://installed_sha"
const PLUGIN_NAME := "AndroidUpdater"
const CHECK_INTERVAL_SECONDS := 45.0
const STALL_TIMEOUT_MSEC := 25000
const RETRY_DELAY_MSEC := 800
const MAX_ATTEMPTS := 60

@export var backend_bridge_path: NodePath = ^"../BackendBridge"
@export var auto_check: bool = true
@export var auto_install: bool = false
@export_range(1, 8, 1) var stream_count: int = 4

var _bridge: Node = null
var _manifest: Dictionary = {}
var _install_requested := false
var _auto_attempted := false
var _check_timer: Timer = null

var _expected_sha := ""
var _total := 0
var _download_path := ""
var _http_base := ""
var _auth_token := ""
var _seg_length := 0
var _streams: Array = []
var _active := false
var _phase := "idle"
var _last_progress_msec := 0
var _next_log_bytes := 0
var _last_banner_percent := -1
var _attempts := 0
var _retry_at_msec := 0
var _last_rx_total := 0


class Stream:
	var index: int
	var start: int
	var length: int
	var received: int = 0
	var client: HTTPClient = null
	var file: FileAccess = null
	var phase: String = "idle"
	var path: String = ""
	var last_progress_msec: int = 0
	var attempts: int = 0


func _build_version() -> String:
	return str(ProjectSettings.get_setting("application/config/version", "dev"))


func _ready() -> void:
	if _bridge == null:
		_bridge = get_node_or_null(backend_bridge_path)
	_connect_bridge()
	download_progress.connect(_on_download_progress)
	update_failed.connect(func(reason: String): print("[UPDATER] failed: %s" % reason))
	update_up_to_date.connect(func(version: String): print("[UPDATER] up to date: %s" % version))
	set_process(false)
	_check_timer = Timer.new()
	_check_timer.wait_time = CHECK_INTERVAL_SECONDS
	_check_timer.one_shot = false
	_check_timer.autostart = true
	_check_timer.timeout.connect(_on_check_timer)
	add_child(_check_timer)


func set_bridge(bridge: Node) -> void:
	_bridge = bridge
	_connect_bridge()


func _connect_bridge() -> void:
	if _bridge == null:
		return
	if _bridge.has_signal("update_message") and not _bridge.is_connected("update_message", _on_update_message):
		_bridge.update_message.connect(_on_update_message)
	if _bridge.has_signal("backend_event_applied") and not _bridge.is_connected("backend_event_applied", _on_backend_event):
		_bridge.backend_event_applied.connect(_on_backend_event)


func _on_check_timer() -> void:
	if auto_check:
		check_for_update()


func check_for_update() -> void:
	if _bridge == null:
		print("[UPDATER] no backend bridge; cannot check")
		return
	_bridge.send_command("update.check", {})


func has_pending_update() -> bool:
	return not _manifest.is_empty()


func request_update() -> void:
	if _active:
		return
	if not _manifest.is_empty() and str(_manifest.get("version", "")) == _build_version():
		AppState.set_update_banner("Up to date - BUILD %s" % _build_version())
		return
	print("[UPDATER] request_update; connection=%s" % AppState.connection_state)
	_install_requested = true
	AppState.set_update_banner("Requesting update...")
	_apply_via_daemon()


func _apply_via_daemon() -> void:
	if _bridge != null:
		_bridge.send_command("update.apply", {})
	else:
		check_for_update()


func begin_download() -> void:
	if _active:
		return
	if _manifest.is_empty():
		print("[UPDATER] begin_download without a manifest")
		update_failed.emit("no_manifest")
		return
	_expected_sha = str(_manifest.get("sha256", ""))
	_total = int(_manifest.get("size_bytes", 0))
	_download_path = str(_manifest.get("path", ""))
	if _download_path.is_empty() and not _expected_sha.is_empty():
		_download_path = "/update/%s.apk" % _expected_sha
	if _total <= 0:
		update_failed.emit("bad_manifest")
		return
	var transport = ServiceRegistry.backend_transport
	if transport == null or not transport.has_method("get_http_base"):
		_fail_download("no_transport")
		return
	_http_base = transport.get_http_base()
	var token = transport.get("auth_token")
	_auth_token = str(token) if token != null else ""
	if _http_base.is_empty():
		_fail_download("no_http_base")
		return
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(UPDATE_DIR))
	if _read_meta_sha() != _expected_sha:
		_clear_parts()
		_write_meta_sha(_expected_sha)
	var count: int = max(1, int(stream_count))
	_seg_length = int(ceil(float(_total) / float(count)))
	_streams.clear()
	for index in range(count):
		var start: int = index * _seg_length
		if start >= _total:
			break
		var length: int = min(_seg_length, _total - start)
		var stream := Stream.new()
		stream.index = index
		stream.start = start
		stream.length = length
		stream.path = "%s.%d" % [PART_PATH, index]
		_streams.append(stream)
	print("[UPDATER] downloading %d bytes over %d streams" % [_total, _streams.size()])
	_attempts = 0
	_active = true
	_phase = "downloading"
	_last_progress_msec = Time.get_ticks_msec()
	_next_log_bytes = 0
	_last_banner_percent = -1
	AppState.set_update_banner("Updating 0%")
	for stream in _streams:
		_open_stream(stream)
	set_process(true)


func _open_stream(stream: Stream) -> void:
	# Resume this segment from whatever is already on disk for it.
	var exists := FileAccess.file_exists(stream.path)
	if exists:
		var probe := FileAccess.open(stream.path, FileAccess.READ)
		stream.received = probe.get_length() if probe != null else 0
		if probe != null:
			probe.close()
		stream.received = min(stream.received, stream.length)
	else:
		stream.received = 0
	var mode := FileAccess.READ_WRITE if exists else FileAccess.WRITE
	stream.file = FileAccess.open(stream.path, mode)
	if stream.file == null:
		print("[UPDATER] cannot open %s: %d" % [stream.path, FileAccess.get_open_error()])
		stream.phase = "failed"
		return
	stream.file.seek_end()
	stream.client = HTTPClient.new()
	var host := ""
	var port := 443
	var hostport := _http_base.substr(_http_base.find("://") + 3)
	var colon := hostport.find(":")
	if colon >= 0:
		host = hostport.substr(0, colon)
		port = int(hostport.substr(colon + 1))
	else:
		host = hostport
	var tls_url := _http_base.replace("https://", "wss://").replace("http://", "ws://")
	var tls_options: TLSOptions = null
	var transport = ServiceRegistry.backend_transport
	if tls_url.begins_with("wss://") and transport != null and transport.has_method("build_tls_options"):
		tls_options = transport.build_tls_options(tls_url)
	var error := stream.client.connect_to_host(host, port, tls_options)
	if error != OK:
		stream.phase = "failed"
		return
	stream.phase = "connecting"
	stream.last_progress_msec = Time.get_ticks_msec()


func _process(_delta: float) -> void:
	if not _active:
		if _retry_at_msec > 0 and Time.get_ticks_msec() >= _retry_at_msec:
			_retry_at_msec = 0
			begin_download()
		return
	var received := 0
	var finished := 0
	var now := Time.get_ticks_msec()
	for stream in _streams:
		_drive_stream(stream)
		received += stream.received
		if stream.phase == "done":
			finished += 1
	download_progress.emit(received, _total)
	_maybe_log_progress(received)
	if received > _last_rx_total:
		_last_rx_total = received
		_last_progress_msec = now
	if finished == _streams.size():
		_finalize()
		return
	if now - _last_progress_msec > STALL_TIMEOUT_MSEC:
		_fail_download("stalled")


func _drive_stream(stream: Stream) -> void:
	if stream.client == null or stream.phase in ["done", "failed"]:
		return
	stream.client.poll()
	var status := stream.client.get_status()
	match stream.phase:
		"connecting":
			if status == HTTPClient.STATUS_CONNECTED:
				_send_stream_request(stream)
			elif status in [HTTPClient.STATUS_CONNECTION_ERROR, HTTPClient.STATUS_TLS_HANDSHAKE_ERROR]:
				_restart_stream(stream)
		"requesting":
			if stream.client.has_response():
				var code := stream.client.get_response_code()
				if code == 200 and stream.received > 0:
					# Server ignored the range: restart this segment from scratch.
					stream.received = 0
					if stream.file != null:
						stream.file.seek(0)
				if code == 200 or code == 206:
					stream.phase = "body"
					stream.last_progress_msec = Time.get_ticks_msec()
				elif code == 416:
					_reset_stream(stream)
				else:
					_restart_stream(stream)
			elif status in [HTTPClient.STATUS_CONNECTION_ERROR, HTTPClient.STATUS_TLS_HANDSHAKE_ERROR]:
				_restart_stream(stream)
		"body":
			if status == HTTPClient.STATUS_BODY:
				var chunk := stream.client.read_response_body_chunk()
				var wrote := false
				while chunk.size() > 0:
					stream.file.store_buffer(chunk)
					stream.received += chunk.size()
					wrote = true
					chunk = stream.client.read_response_body_chunk()
				if wrote:
					stream.last_progress_msec = Time.get_ticks_msec()
				if stream.received >= stream.length:
					_complete_stream(stream)
			else:
				# Body ended early (drop) or complete.
				if stream.received >= stream.length:
					_complete_stream(stream)
				else:
					_restart_stream(stream)
	if stream.phase not in ["done", "failed"] and Time.get_ticks_msec() - stream.last_progress_msec > STALL_TIMEOUT_MSEC:
		_restart_stream(stream)


func _send_stream_request(stream: Stream) -> void:
	var headers := PackedStringArray()
	if not _auth_token.is_empty():
		headers.append("Authorization: Bearer %s" % _auth_token)
	# Every stream must request its own sub-range, including the first request
	# (otherwise the server returns the whole file and segments overlap).
	var first := stream.start + stream.received
	var last := stream.start + stream.length - 1
	headers.append("Range: bytes=%d-%d" % [first, last])
	var error := stream.client.request(HTTPClient.METHOD_GET, _download_path, headers)
	if error != OK:
		_restart_stream(stream)
		return
	stream.phase = "requesting"


func _complete_stream(stream: Stream) -> void:
	if stream.file != null:
		stream.file.close()
		stream.file = null
	if stream.client != null:
		stream.client.close()
		stream.client = null
	stream.phase = "done"


func _reset_stream(stream: Stream) -> void:
	if stream.file != null:
		stream.file.close()
		stream.file = null
	DirAccess.remove_absolute(ProjectSettings.globalize_path(stream.path))
	stream.received = 0
	_open_stream(stream)


func _restart_stream(stream: Stream) -> void:
	if stream.file != null:
		stream.file.close()
		stream.file = null
	if stream.client != null:
		stream.client.close()
		stream.client = null
	stream.attempts += 1
	if stream.attempts > MAX_ATTEMPTS:
		stream.phase = "failed"
		return
	_open_stream(stream)


func _finalize() -> void:
	for stream in _streams:
		if stream.file != null:
			stream.file.close()
			stream.file = null
		if stream.client != null:
			stream.client.close()
			stream.client = null
	set_process(false)
	# Concatenate the parts into the single .part file.
	var out := FileAccess.open(PART_PATH, FileAccess.WRITE)
	if out == null:
		_fail_download("cannot_concat")
		return
	for stream in _streams:
		var part := FileAccess.open(stream.path, FileAccess.READ)
		if part == null:
			out.close()
			_fail_download("missing_part")
			return
		while part.get_position() < part.get_length():
			out.store_buffer(part.get_buffer(1 << 20))
		part.close()
	out.close()
	var computed := _hash_file(PART_PATH)
	if computed != _expected_sha:
		print("[UPDATER] checksum %s != %s" % [computed.left(12), _expected_sha.left(12)])
		_clear_parts()
		_fail_download("checksum")
		return
	var apk_abs := ProjectSettings.globalize_path(UPDATE_PATH)
	var part_abs := ProjectSettings.globalize_path(PART_PATH)
	DirAccess.remove_absolute(apk_abs)
	if DirAccess.rename_absolute(part_abs, apk_abs) != OK:
		_fail_download("promote_failed")
		return
	_clear_segment_parts()
	_write_installed_sha(_expected_sha)
	_active = false
	_phase = "done"
	AppState.set_update_banner("Verified - installing")
	print("[UPDATER] download complete (%d bytes); launching installer" % _total)
	_launch_installer()


func _fail_download(reason: String) -> void:
	_close_all()
	_active = false
	_phase = "idle"
	_attempts += 1
	if _attempts > MAX_ATTEMPTS:
		set_process(false)
		AppState.set_update_banner("Update failed (%s)" % reason)
		update_failed.emit(reason)
		return
	# Keep processing so the scheduled retry can fire.
	AppState.set_update_banner("Update interrupted - retrying")
	_retry_at_msec = Time.get_ticks_msec() + RETRY_DELAY_MSEC


func _close_all() -> void:
	for stream in _streams:
		if stream.file != null:
			stream.file.close()
			stream.file = null
		if stream.client != null:
			stream.client.close()
			stream.client = null


func _launch_installer() -> void:
	_install_requested = false
	AppState.set_update_banner("Confirm install in the headset")
	print("[UPDATER] launching installer; singleton=%s" % Engine.has_singleton(PLUGIN_NAME))
	if not Engine.has_singleton(PLUGIN_NAME):
		update_failed.emit("plugin_missing")
		return
	var updater := Engine.get_singleton(PLUGIN_NAME)
	var callable := Callable(self, "_on_install_result")
	if not updater.is_connected("install_result", callable):
		updater.connect("install_result", callable)
	updater.call("installApk", ProjectSettings.globalize_path(UPDATE_PATH))
	install_launched.emit(str(_manifest.get("version", "")))
	EventBus.debug_message.emit("Update downloaded - confirm install on the headset")


func _on_install_result(success: bool, message: String) -> void:
	_install_requested = false
	print("[UPDATER] install_result success=%s message=%s" % [success, message])
	if success and message == "installed":
		_write_installed_sha(_expected_sha)
		AppState.set_update_banner("Updated - relaunching")
		return
	if message in ["user_action_required", "installer_opened", "session_committed"]:
		AppState.set_update_banner("Confirm install in the headset")
		return
	if not success:
		AppState.set_update_banner("Update failed - check settings")
		update_failed.emit(message)


func _on_download_progress(received: int, total: int) -> void:
	if total <= 0:
		return
	var percent := int(clampf(float(received) / float(total) * 100.0, 0.0, 100.0))
	if percent == _last_banner_percent:
		return
	_last_banner_percent = percent
	AppState.set_update_banner("Updating %d%%" % percent)


func _maybe_log_progress(received: int) -> void:
	if received >= _next_log_bytes:
		_next_log_bytes = received + 8 * 1024 * 1024
		print("[UPDATER] progress %d / %d" % [received, _total])


func _on_backend_event(event: BackendEvent) -> void:
	if event == null or event.type != "session.ready":
		return
	if _install_requested and not _active:
		check_for_update()


func _on_update_message(event_type: String, payload: Dictionary) -> void:
	match event_type:
		"update.available":
			_manifest = payload
			var installed := _read_installed_sha()
			print("[UPDATER] available version=%s installed_sha=%s manifest_sha=%s" % [
				str(_manifest.get("version", "")), installed.left(12),
				str(_manifest.get("sha256", "")).left(12)
			])
			if str(_manifest.get("version", "")) == _build_version():
				update_up_to_date.emit(str(_manifest.get("version", "")))
				AppState.set_update_banner("")
				_install_requested = false
				return
			if not _install_requested:
				AppState.set_update_banner("Update available - pinch UPDATE")
			update_available.emit(
				str(_manifest.get("version", "")),
				str(_manifest.get("sha256", "")),
				int(_manifest.get("size_bytes", 0))
			)
			if ((auto_install and not _auto_attempted) or _install_requested) and not _active:
				_auto_attempted = true
				_apply_via_daemon()
		"update.fallback":
			for key in ["sha256", "size_bytes", "version", "path"]:
				if payload.has(key):
					_manifest[key] = payload[key]
			if not _active:
				begin_download()
		"update.none":
			update_up_to_date.emit("")
		"update.progress":
			if str(payload.get("stage", "")) == "installing":
				AppState.set_update_banner("Installing...")
		"update.applied":
			print("[UPDATER] daemon installed %s over adb" % str(payload.get("version", "")))
			_write_installed_sha(str(_manifest.get("sha256", "")))
			AppState.set_update_banner("Updated - relaunching")
			install_launched.emit(str(payload.get("version", "")))
		"update.chunk":
			pass


func _read_meta_sha() -> String:
	if not FileAccess.file_exists(META_PATH):
		return ""
	var file := FileAccess.open(META_PATH, FileAccess.READ)
	if file == null:
		return ""
	var value := file.get_as_text().strip_edges()
	file.close()
	return value


func _write_meta_sha(sha: String) -> void:
	var file := FileAccess.open(META_PATH, FileAccess.WRITE)
	if file != null:
		file.store_string(sha)
		file.close()


func _clear_segment_parts() -> void:
	for index in range(max(1, int(stream_count))):
		DirAccess.remove_absolute(ProjectSettings.globalize_path("%s.%d" % [PART_PATH, index]))


func _clear_parts() -> void:
	DirAccess.remove_absolute(ProjectSettings.globalize_path(PART_PATH))
	_clear_segment_parts()


func _hash_file(path: String) -> String:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return ""
	var hasher := HashingContext.new()
	hasher.start(HashingContext.HASH_SHA256)
	while file.get_position() < file.get_length():
		hasher.update(file.get_buffer(1 << 20))
	file.close()
	return hasher.finish().hex_encode()


func _read_installed_sha() -> String:
	if not FileAccess.file_exists(INSTALLED_SHA_PATH):
		return ""
	var file := FileAccess.open(INSTALLED_SHA_PATH, FileAccess.READ)
	if file == null:
		return ""
	var value := file.get_as_text().strip_edges()
	file.close()
	return value


func _write_installed_sha(sha: String) -> void:
	var file := FileAccess.open(INSTALLED_SHA_PATH, FileAccess.WRITE)
	if file != null:
		file.store_string(sha)
		file.flush()
		file.close()
