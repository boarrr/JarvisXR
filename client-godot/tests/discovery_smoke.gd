extends Node

var _failed := false
var _received: Dictionary = {}


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	var service := DiscoveryService.new()
	service.discovery_port = 18790
	add_child(service)
	service.daemon_found.connect(func(payload: Dictionary) -> void: _received = payload)
	service.start()
	_check(service.is_active(), "discovery service binds a UDP port")
	if not service.is_active():
		_finish()
		return

	var sender := PacketPeerUDP.new()
	sender.set_dest_address("127.0.0.1", 18790)
	var beacon := {
		"app": "spatial-agent",
		"protocol": 2,
		"ws_port": 8787,
		"discovery_port": 18790,
		"host": "Midnight-2.local",
		"ips": ["192.168.0.202"],
		"ca_fingerprint": "deadbeef",
		"version": "0.0.0-test",
	}
	sender.put_packet(JSON.stringify(beacon).to_utf8_buffer())

	for _attempt in range(60):
		service._process(0.05)
		if not _received.is_empty():
			break
		await get_tree().process_frame

	_check(not _received.is_empty(), "discovery parses a daemon beacon")
	if not _received.is_empty():
		var urls := DiscoveryService.websocket_urls(_received)
		_check(not urls.is_empty(), "beacon yields websocket urls")
		if not urls.is_empty():
			_check(
				urls[0] == "wss://192.168.0.202:8787/ws",
				"first candidate is the advertised IP"
			)

	_check(
		DiscoveryService._parse('{"app":"someone-else"}'.to_utf8_buffer()).is_empty(),
		"foreign beacons are ignored"
	)

	service.stop()
	_finish()


func _check(condition: bool, description: String) -> void:
	if condition:
		return
	_failed = true
	push_error("[TEST] Failed: %s" % description)


func _finish() -> void:
	if not _failed:
		print("[TEST] Discovery service checks passed")
	get_tree().quit(1 if _failed else 0)
