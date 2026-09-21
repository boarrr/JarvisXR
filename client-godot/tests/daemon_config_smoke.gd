extends Node

const DAEMON_CONFIG_PATH := "user://daemon.cfg"

var _failed := false
var _original_config := ""
var _had_original := false


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	if FileAccess.file_exists(DAEMON_CONFIG_PATH):
		_original_config = FileAccess.get_file_as_string(DAEMON_CONFIG_PATH)
		_had_original = true

	# A daemon.cfg URL wins over the baked project default.
	var configured := ConfigFile.new()
	configured.set_value("daemon", "websocket_url", "wss://192.168.0.50:8787/ws")
	configured.set_value("daemon", "auth_token", "token_from_config")
	configured.set_value("daemon", "ca_certificate_path", "dev_ca.crt")
	configured.save(DAEMON_CONFIG_PATH)

	var client := BackendClient.new()
	add_child(client)
	_check(
		client.websocket_url == "wss://192.168.0.50:8787/ws",
		"daemon.cfg overrides the baked websocket URL"
	)
	_check(client.auth_token == "token_from_config", "daemon.cfg restores the device token")
	_check(client.ca_certificate_path == "dev_ca.crt", "daemon.cfg carries the CA path")
	client.set_default_url("ws://127.0.0.1:8787/ws")
	_check(
		client.websocket_url == "wss://192.168.0.50:8787/ws",
		"baked defaults never overwrite a configured daemon"
	)

	# TLS options: no TLS for ws://, CA trust for a loadable certificate,
	# unsafe only when explicitly allowed, and no silent trust otherwise.
	_check(client.build_tls_options("ws://127.0.0.1:8787/ws") == null, "ws:// needs no TLS options")
	client.ca_certificate_path = "res://tests/support/test_ca.crt"
	_check(
		client.build_tls_options("wss://example.local/ws") != null,
		"a configured CA produces verified TLS options"
	)
	client.ca_certificate_path = ""
	client.allow_unsafe_tls = false
	ProjectSettings.set_setting("spatial_agent/allow_unsafe_tls", false)
	_check(
		client.build_tls_options("wss://example.local/ws") == null,
		"wss without a CA and without the dev flag is not trusted"
	)
	client.allow_unsafe_tls = true
	_check(
		client.build_tls_options("wss://example.local/ws") != null,
		"the dev flag enables the unsafe client explicitly"
	)

	# Token persistence: pairing saves URL, token and CA together.
	client.allow_unsafe_tls = false
	client.auth_token = "paired_token"
	client.ca_certificate_path = "res://tests/support/test_ca.crt"
	client._save_daemon_config()
	var saved := ConfigFile.new()
	_check(saved.load(DAEMON_CONFIG_PATH) == OK, "daemon.cfg is written on pairing")
	_check(
		str(saved.get_value("daemon", "auth_token", "")) == "paired_token",
		"paired token persists"
	)

	client.queue_free()
	_restore_original_config()
	if not _failed:
		print("[TEST] Daemon configuration and TLS option checks passed")
	get_tree().quit(1 if _failed else 0)


func _restore_original_config() -> void:
	if _had_original:
		var file := FileAccess.open(DAEMON_CONFIG_PATH, FileAccess.WRITE)
		if file != null:
			file.store_string(_original_config)
	else:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(DAEMON_CONFIG_PATH))


func _check(condition: bool, description: String) -> void:
	if condition:
		return
	_failed = true
	push_error("[TEST] Failed: %s" % description)
