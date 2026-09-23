class_name UpdaterService
extends Node

## Pulls a newly published APK from the daemon over the authenticated channel
## and hands it to the Android package installer.
##
## The daemon serves `update.check` (manifest) and `update.fetch` (base64
## chunks). The client writes user://updates/update.apk, verifies its sha256,
## then calls the optional AndroidUpdater plugin. Nothing installs silently:
## the OS still shows its confirmation prompt.

signal update_available(version: String, sha256: String, size_bytes: int)
signal update_up_to_date(version: String)
signal download_progress(received: int, total: int)
signal install_launched(version: String)
signal update_failed(reason: String)

const UPDATE_DIR := "user://updates"
const UPDATE_PATH := "user://updates/update.apk"
const INSTALLED_SHA_PATH := "user://installed_sha"
const PLUGIN_NAME := "AndroidUpdater"

@export var backend_bridge_path: NodePath = ^"../BackendBridge"
@export var chunk_bytes: int = 524288
@export var auto_check: bool = true
@export var auto_install: bool = true

var _bridge: Node = null
var _manifest: Dictionary = {}
var _file: FileAccess = null
var _hasher: HashingContext = null
var _received := 0
var _install_requested := false
var _downloading := false
var _check_timer: Timer = null


func _ready() -> void:
	if _bridge == null:
		_bridge = get_node_or_null(backend_bridge_path)
	_connect_bridge()
	set_process(false)
	_check_timer = Timer.new()
	_check_timer.wait_time = 45.0
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


func check_for_update() -> void:
	if _bridge == null:
		print("[UPDATER] no backend bridge; cannot check")
		return
	print("[UPDATER] sending update.check")
	_bridge.send_command("update.check", {})


func has_pending_update() -> bool:
	return not _manifest.is_empty()


func request_update() -> void:
	if _downloading:
		return
	print("[UPDATER] request_update; connection=%s manifest=%s" % [
		AppState.connection_state, not _manifest.is_empty()
	])
	_install_requested = true
	if not _manifest.is_empty():
		if str(_manifest.get("sha256", "")) == _read_installed_sha():
			print("[UPDATER] already on %s" % str(_manifest.get("version", "")))
			EventBus.debug_message.emit("Already on the latest build")
			_install_requested = false
			return
		begin_install()
	else:
		check_for_update()


func begin_install() -> void:
	if _downloading:
		return
	_downloading = true
	if _manifest.is_empty():
		print("[UPDATER] begin_install without a manifest")
		update_failed.emit("no_manifest")
		return
	var dir_path := ProjectSettings.globalize_path(UPDATE_DIR)
	DirAccess.make_dir_recursive_absolute(dir_path)
	print("[UPDATER] downloading %s bytes to %s" % [
		str(_manifest.get("size_bytes", 0)), ProjectSettings.globalize_path(UPDATE_PATH)
	])
	_file = FileAccess.open(UPDATE_PATH, FileAccess.WRITE)
	if _file == null:
		print("[UPDATER] cannot open target file: error %d" % FileAccess.get_open_error())
		_downloading = false
		update_failed.emit("cannot_write")
		return
	_hasher = HashingContext.new()
	_hasher.start(HashingContext.HASH_SHA256)
	_received = 0
	_request_chunk(0)


func _request_chunk(offset: int) -> void:
	if _bridge == null:
		return
	var length := int(_manifest.get("chunk_bytes", chunk_bytes))
	_bridge.send_command("update.fetch", {"offset": offset, "length": length})


func _on_backend_event(event: BackendEvent) -> void:
	if event == null or event.type != "session.ready":
		return
	if not auto_check:
		return
	print("[UPDATER] session ready; checking for updates")
	check_for_update()


func _on_check_timer() -> void:
	if auto_check and not _downloading:
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
			if str(_manifest.get("sha256", "")) == installed and not installed.is_empty():
				update_up_to_date.emit(str(_manifest.get("version", "")))
				_install_requested = false
				return
			update_available.emit(
				str(_manifest.get("version", "")),
				str(_manifest.get("sha256", "")),
				int(_manifest.get("size_bytes", 0))
			)
			if auto_install or _install_requested:
				begin_install()
		"update.none":
			update_up_to_date.emit("")
		"update.chunk":
			_on_chunk(payload)


func _on_chunk(payload: Dictionary) -> void:
	if _file == null:
		return
	var data := Marshalls.base64_to_raw(str(payload.get("data", "")))
	if data.is_empty() and not bool(payload.get("eof", false)):
		_downloading = false
		update_failed.emit("empty_chunk")
		return
	_file.store_buffer(data)
	_hasher.update(data)
	_received += data.size()
	download_progress.emit(_received, int(_manifest.get("size_bytes", _received)))
	if bool(payload.get("eof", false)):
		_file.close()
		_file = null
		_finish_download()
		return
	_request_chunk(int(payload.get("offset", 0)) + data.size())


func _finish_download() -> void:
	var computed := _hasher.finish().hex_encode()
	_hasher = null
	var expected := str(_manifest.get("sha256", ""))
	print("[UPDATER] download complete; sha %s expected %s" % [computed.left(12), expected.left(12)])
	if computed != expected:
		_downloading = false
		update_failed.emit("checksum_mismatch")
		return
	_launch_installer()


func _launch_installer() -> void:
	print("[UPDATER] launching installer; singleton=%s" % Engine.has_singleton(PLUGIN_NAME))
	if not Engine.has_singleton(PLUGIN_NAME):
		update_failed.emit("plugin_missing")
		return
	var updater := Engine.get_singleton(PLUGIN_NAME)
	if not updater.has_method("installApk"):
		update_failed.emit("plugin_incompatible")
		return
	var callable := Callable(self, "_on_install_result")
	if not updater.is_connected("install_result", callable):
		updater.connect("install_result", callable)
	_write_installed_sha(str(_manifest.get("sha256", "")))
	updater.call("installApk", ProjectSettings.globalize_path(UPDATE_PATH))
	install_launched.emit(str(_manifest.get("version", "")))
	EventBus.debug_message.emit("Update downloaded · confirm install on the headset")


func _on_install_result(success: bool, message: String) -> void:
	_downloading = false
	if not success:
		update_failed.emit(message)


func _read_installed_sha() -> String:
	if not FileAccess.file_exists(INSTALLED_SHA_PATH):
		return ""
	var file := FileAccess.open(INSTALLED_SHA_PATH, FileAccess.READ)
	if file == null:
		return ""
	return file.get_as_text().strip_edges()


func _write_installed_sha(sha: String) -> void:
	var file := FileAccess.open(INSTALLED_SHA_PATH, FileAccess.WRITE)
	if file != null:
		file.store_string(sha)
