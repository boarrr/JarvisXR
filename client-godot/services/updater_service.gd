class_name UpdaterService
extends Node

## Pulls a newly published APK from the daemon and hands it to the Android
## package installer.
##
## The APK is fetched over HTTPS from the same host/port as the control
## websocket (GET /update/<sha>.apk) using HTTPClient with Range requests, so a
## dropped Wi-Fi link resumes from the last byte instead of restarting. The
## daemon still chooses the transport: when a USB/adb device is attached it
## installs directly, otherwise it replies update.fallback and we stream here.

signal update_available(version: String, sha256: String, size_bytes: int)
signal update_up_to_date(version: String)
signal download_progress(received: int, total: int)
signal install_launched(version: String)
signal update_failed(reason: String)

const UPDATE_DIR := "user://updates"
const UPDATE_PATH := "user://updates/update.apk"
const PART_PATH := "user://updates/update.apk.part"
const META_PATH := "user://updates/update.part.meta"
const INSTALLED_SHA_PATH := "user://installed_sha"
const PLUGIN_NAME := "AndroidUpdater"
const CHECK_INTERVAL_SECONDS := 45.0
const CONNECT_TIMEOUT_MSEC := 20000
const STALL_TIMEOUT_MSEC := 20000
const RETRY_DELAY_MSEC := 1500
const MAX_RETRIES := 12

@export var backend_bridge_path: NodePath = ^"../BackendBridge"
@export var auto_check: bool = true
@export var auto_install: bool = false

var _bridge: Node = null
var _manifest: Dictionary = {}
var _install_requested := false
var _auto_attempted := false
var _check_timer: Timer = null

var _http: HTTPClient = null
var _file: FileAccess = null
var _http_base := ""
var _download_path := ""
var _auth_token := ""
var _expected_sha := ""
var _total := 0
var _received := 0
var _retries := 0
var _phase := "idle"
var _active := false
var _retry_at_msec := 0
var _last_progress_msec := 0
var _next_log_bytes := 0
var _last_banner_percent := -1


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
	_retries = 0
	_received = 0
	print("[UPDATER] starting HTTPS download of %s (%d bytes)" % [_download_path, _total])
	_start_http()


func _start_http() -> void:
	var transport = ServiceRegistry.backend_transport
	if transport == null or not transport.has_method("get_http_base"):
		_fail_attempt("no_transport")
		return
	_http_base = transport.get_http_base()
	var token = transport.get("auth_token")
	_auth_token = str(token) if token != null else ""
	if _http_base.is_empty():
		_fail_attempt("no_http_base")
		return
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(UPDATE_DIR))
	var resume_ok := FileAccess.file_exists(PART_PATH) and _read_part_sha() == _expected_sha
	if resume_ok:
		var probe := FileAccess.open(PART_PATH, FileAccess.READ)
		_received = probe.get_length() if probe != null else 0
		if probe != null:
			probe.close()
	else:
		_reset_partial()
		_received = 0
	_file = FileAccess.open(PART_PATH, FileAccess.READ_WRITE)
	if _file == null:
		print("[UPDATER] cannot open target: %d" % FileAccess.get_open_error())
		_fail_attempt("cannot_write")
		return
	_file.seek_end()
	if _received == 0:
		_write_part_sha(_expected_sha)
		AppState.set_update_banner("Updating 0%")
	var host := ""
	var port := 443
	var hostport := _http_base.substr(_http_base.find("://") + 3)
	var colon := hostport.find(":")
	if colon >= 0:
		host = hostport.substr(0, colon)
		port = int(hostport.substr(colon + 1))
	else:
		host = hostport
	_http = HTTPClient.new()
	var tls_url := _http_base.replace("https://", "wss://").replace("http://", "ws://")
	var tls_options: TLSOptions = null
	if tls_url.begins_with("wss://") and transport.has_method("build_tls_options"):
		tls_options = transport.build_tls_options(tls_url)
	var error := _http.connect_to_host(host, port, tls_options)
	if error != OK:
		_close_http()
		_fail_attempt("connect_error")
		return
	_phase = "connecting"
	_active = true
	_last_progress_msec = Time.get_ticks_msec()
	set_process(true)


func _process(_delta: float) -> void:
	if _http == null:
		if _retry_at_msec > 0 and Time.get_ticks_msec() >= _retry_at_msec:
			_retry_at_msec = 0
			_start_http()
		return
	_http.poll()
	var status := _http.get_status()
	match _phase:
		"connecting":
			if status == HTTPClient.STATUS_CONNECTED:
				_send_request()
			elif status in [HTTPClient.STATUS_CONNECTION_ERROR, HTTPClient.STATUS_TLS_HANDSHAKE_ERROR]:
				_fail_attempt("connect_failed")
		"requesting":
			if _http.has_response():
				_handle_response(_http.get_response_code())
			elif status in [HTTPClient.STATUS_CONNECTION_ERROR, HTTPClient.STATUS_TLS_HANDSHAKE_ERROR]:
				_fail_attempt("request_failed")
		"body":
			_pump_body(status)
	if _phase in ["connecting", "requesting", "body"]:
		if Time.get_ticks_msec() - _last_progress_msec > STALL_TIMEOUT_MSEC:
			_fail_attempt("stalled")
	else:
		if Time.get_ticks_msec() - _last_progress_msec > CONNECT_TIMEOUT_MSEC:
			_fail_attempt("connect_timeout")


func _send_request() -> void:
	var headers := PackedStringArray()
	if not _auth_token.is_empty():
		headers.append("Authorization: Bearer %s" % _auth_token)
	if _received > 0:
		headers.append("Range: bytes=%d-" % _received)
	var error := _http.request(HTTPClient.METHOD_GET, _download_path, headers)
	if error != OK:
		_fail_attempt("request_error")
		return
	_phase = "requesting"
	_last_progress_msec = Time.get_ticks_msec()


func _handle_response(code: int) -> void:
	if code == 200:
		_received = 0
		if _file != null:
			_file.seek(0)
		_write_part_sha(_expected_sha)
		_update_banner(0)
		_phase = "body"
	elif code == 206:
		_phase = "body"
	elif code == 416:
		_reset_partial()
		_fail_attempt("restart")
	elif code == 401 or code == 403:
		_fail_attempt("unauthorized")
	elif code == 409:
		_reset_partial()
		_fail_attempt("stale_update")
	else:
		_fail_attempt("http_%d" % code)


func _pump_body(status: int) -> void:
	if status == HTTPClient.STATUS_BODY:
		var chunk := _http.read_response_body_chunk()
		var wrote := false
		while chunk.size() > 0:
			_file.store_buffer(chunk)
			_received += chunk.size()
			wrote = true
			chunk = _http.read_response_body_chunk()
		if wrote:
			_last_progress_msec = Time.get_ticks_msec()
			_update_banner(_received)
			_maybe_log_progress()
		return
	# Body finished (keep-alive -> CONNECTED, or -> DISCONNECTED).
	_finish_download()


func _finish_download() -> void:
	_close_http()
	if _file != null:
		_file.close()
		_file = null
	if _received < _total:
		_fail_attempt("incomplete")
		return
	var computed := _hash_file(PART_PATH)
	if computed != _expected_sha:
		print("[UPDATER] checksum %s != %s" % [computed.left(12), _expected_sha.left(12)])
		_reset_partial()
		_fail_attempt("checksum")
		return
	var apk_abs := ProjectSettings.globalize_path(UPDATE_PATH)
	var part_abs := ProjectSettings.globalize_path(PART_PATH)
	DirAccess.remove_absolute(apk_abs)
	if DirAccess.rename_absolute(part_abs, apk_abs) != OK:
		_fail_attempt("promote_failed")
		return
	_write_installed_sha(_expected_sha)
	_active = false
	_phase = "done"
	set_process(false)
	AppState.set_update_banner("Verified - installing")
	print("[UPDATER] download complete (%d bytes); launching installer" % _received)
	_launch_installer()


func _fail_attempt(reason: String) -> void:
	_close_http()
	if _file != null:
		_file.close()
		_file = null
	_retries += 1
	print("[UPDATER] attempt failed (%s); retry %d at offset %d" % [reason, _retries, _received])
	if _retries > MAX_RETRIES:
		_active = false
		_phase = "idle"
		set_process(false)
		AppState.set_update_banner("Update failed (%s)" % reason)
		update_failed.emit(reason)
		return
	AppState.set_update_banner("Update interrupted - retry %d" % _retries)
	_retry_at_msec = Time.get_ticks_msec() + RETRY_DELAY_MSEC


func _close_http() -> void:
	if _http != null:
		_http.close()
		_http = null
	_phase = "idle"


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


func _update_banner(received: int) -> void:
	download_progress.emit(received, _total)


func _maybe_log_progress() -> void:
	if _received >= _next_log_bytes:
		_next_log_bytes = _received + 8 * 1024 * 1024
		print("[UPDATER] progress %d / %d" % [_received, _total])


func _on_backend_event(event: BackendEvent) -> void:
	if event == null or event.type != "session.ready":
		return
	# A fresh session after a reconnect: re-drive an in-flight update request.
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
			# The daemon has no USB device: stream the APK ourselves over HTTPS.
			for key in ["sha256", "size_bytes", "version", "path"]:
				if payload.has(key):
					_manifest[key] = payload[key]
			if not _active:
				begin_download()
		"update.none":
			update_up_to_date.emit("")
		"update.progress":
			var stage := str(payload.get("stage", ""))
			if stage == "installing":
				AppState.set_update_banner("Installing...")
		"update.applied":
			print("[UPDATER] daemon installed %s over adb" % str(payload.get("version", "")))
			_write_installed_sha(str(_manifest.get("sha256", "")))
			AppState.set_update_banner("Updated - relaunching")
			install_launched.emit(str(payload.get("version", "")))
		"update.chunk":
			pass


func _read_part_sha() -> String:
	if not FileAccess.file_exists(META_PATH):
		return ""
	var file := FileAccess.open(META_PATH, FileAccess.READ)
	if file == null:
		return ""
	var value := file.get_as_text().strip_edges()
	file.close()
	return value


func _write_part_sha(sha: String) -> void:
	var file := FileAccess.open(META_PATH, FileAccess.WRITE)
	if file != null:
		file.store_string(sha)
		file.close()


func _reset_partial() -> void:
	if _file != null:
		_file.close()
		_file = null
	DirAccess.remove_absolute(ProjectSettings.globalize_path(PART_PATH))
	_received = 0


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
