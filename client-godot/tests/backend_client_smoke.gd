extends Node

var _failed := false
var _received_events: Array[BackendEvent] = []


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	var client := BackendClient.new()
	add_child(client)
	client.backend_event_received.connect(_on_backend_event_received)

	_check(client.get_mode() == "websocket", "real client reports websocket mode")
	_check(client.get_connection_state() == BackendTransport.STATE_OFFLINE, "client starts offline")
	_check(not client.send_command("thread.list"), "commands are rejected while disconnected")

	var initial_command := client.build_command_envelope("thread.focus", {}, "thread_demo")
	_check(initial_command["v"] == 2, "commands use protocol v2")
	_check(initial_command["type"] == "thread.focus", "command type is preserved")
	_check(str(initial_command["event_id"]).begins_with("cmd_godot_"), "command has a stable identifier")
	_check(initial_command["session_id"] == "", "pre-session command has an empty session ID")
	_check(initial_command["thread_id"] == "thread_demo", "command carries thread identity")
	_check(initial_command["payload"] is Dictionary, "command payload is an object")

	var hello_payload := client._hello_payload()
	_check(int(hello_payload["protocol_version"]) == 2, "hello requests protocol v2")
	_check(not hello_payload.has("auth_token"), "hello omits an empty auth token")
	client.auth_token = "token_smoke"
	_check(client._hello_payload()["auth_token"] == "token_smoke", "hello carries a stored auth token")
	client.auth_token = ""

	var ready_envelope := {
		"v": 1,
		"type": "session.ready",
		"event_id": "evt_server_001",
		"session_id": "sess_test",
		"thread_id": "",
		"timestamp": "2026-09-14T12:00:00Z",
		"payload": {"server": "smoke"},
	}
	var ready_event := BackendEvent.from_envelope(ready_envelope)
	_check(ready_event != null and ready_event.is_valid(), "valid v1 envelope decodes")
	_check(ready_event.to_envelope() == ready_envelope, "BackendEvent round-trips without field drift")
	client._handle_text_packet(JSON.stringify(ready_envelope))
	_check(_received_events.size() == 1, "valid text packet emits one backend event")
	_check(_received_events.back().type == "session.ready", "decoded event type is preserved")
	var scoped_command := client.build_command_envelope("thread.list")
	_check(scoped_command["session_id"] == "sess_test", "session.ready scopes later commands")

	var invalid_version := ready_envelope.duplicate(true)
	invalid_version["v"] = 3
	_check(BackendEvent.from_envelope(invalid_version) == null, "unsupported versions are rejected")
	client._handle_text_packet(JSON.stringify(invalid_version))
	_check(_received_events.back().type == "error", "invalid envelope emits a normalized error")
	_check(_received_events.back().payload["code"] == "invalid_envelope", "invalid envelope error is classified")

	client._handle_text_packet("[]")
	_check(_received_events.back().payload["code"] == "invalid_json", "non-object JSON is rejected")
	client._handle_text_packet("not-json")
	_check(_received_events.back().payload["code"] == "invalid_json", "malformed JSON is rejected")

	client.websocket_url = "https://not-a-websocket.example"
	client.start()
	_check(client.get_connection_state() == BackendTransport.STATE_ERROR, "invalid URL moves the client to error")
	_check(_received_events.back().payload["code"] == "invalid_url", "invalid URL emits a classified error")
	_check(not client.send_command("thread.list"), "error state cannot send commands")
	client.stop()
	_check(client.get_connection_state() == BackendTransport.STATE_OFFLINE, "stop restores offline state")

	ProjectSettings.set_setting("spatial_agent/backend_mode", "websocket")
	ProjectSettings.set_setting("spatial_agent/backend_websocket_url", "invalid://test")
	var main_scene := load("res://scenes/app/main.tscn") as PackedScene
	var main := main_scene.instantiate()
	add_child(main)
	_check(
		ServiceRegistry.backend_transport is BackendClient,
		"Main selects the WebSocket transport from configuration"
	)
	_check(AppState.backend_mode == "websocket", "configured mode reaches AppState")
	_check(AppState.connection_state == BackendTransport.STATE_ERROR, "configuration failure is visible to presentation state")
	main.queue_free()
	ProjectSettings.set_setting("spatial_agent/backend_mode", "fake")
	ProjectSettings.set_setting("spatial_agent/backend_websocket_url", "ws://127.0.0.1:8787/ws")

	if not _failed:
		print("[TEST] Backend WebSocket client smoke checks passed")
	client.queue_free()
	get_tree().quit(1 if _failed else 0)


func _on_backend_event_received(event: BackendEvent) -> void:
	_received_events.append(event)


func _check(condition: bool, description: String) -> void:
	if condition:
		return
	_failed = true
	push_error("[TEST] Failed: %s" % description)
