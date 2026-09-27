class_name DiscoveryService
extends Node

## Finds the daemon on the local network over UDP so the headset needs no
## hand-pushed address. The beacon carries only addresses + the CA fingerprint.

signal daemon_found(payload: Dictionary)

const APP_ID := "spatial-agent"
const DISCOVER_MAGIC := "spatial-agent-discover"

@export var discovery_port: int = 8789
@export_range(0.2, 10.0, 0.1) var probe_interval_seconds: float = 2.0

var _peer: PacketPeerUDP = null
var _active := false
var _probe_elapsed := 0.0


func start() -> void:
	if _active:
		return
	_peer = PacketPeerUDP.new()
	_peer.set_broadcast_enabled(true)
	var error := _peer.bind(discovery_port, "0.0.0.0")
	if error != OK:
		push_warning("[DISCOVERY] UDP bind failed (%d); discovery disabled" % error)
		_peer = null
		return
	_active = true
	_probe_elapsed = probe_interval_seconds
	set_process(true)


func stop() -> void:
	_active = false
	set_process(false)
	if _peer != null:
		_peer.close()
	_peer = null


func is_active() -> bool:
	return _active


func _process(delta: float) -> void:
	if _peer == null:
		return
	_probe_elapsed += delta
	if _probe_elapsed >= probe_interval_seconds:
		_probe_elapsed = 0.0
		_send_probe()
	while _peer.get_available_packet_count() > 0:
		var packet := _peer.get_packet()
		var payload := _parse(packet)
		if payload.is_empty():
			continue
		payload["source_ip"] = _peer.get_packet_ip()
		daemon_found.emit(payload)


func _send_probe() -> void:
	for target in _broadcast_targets():
		_peer.set_dest_address(target, discovery_port)
		_peer.put_packet(DISCOVER_MAGIC.to_utf8_buffer())


func _broadcast_targets() -> PackedStringArray:
	var targets := PackedStringArray(["255.255.255.255"])
	var subnet := _subnet_broadcast()
	if not subnet.is_empty() and not targets.has(subnet):
		targets.append(subnet)
	return targets


func _subnet_broadcast() -> String:
	for address in IP.get_local_addresses():
		if address.contains(":") or address.begins_with("127."):
			continue
		var parts := address.split(".")
		if parts.size() == 4:
			return "%s.%s.%s.255" % [parts[0], parts[1], parts[2]]
	return ""


static func _parse(packet: PackedByteArray) -> Dictionary:
	var parsed: Variant = JSON.parse_string(packet.get_string_from_utf8())
	if typeof(parsed) != TYPE_DICTIONARY:
		return {}
	var payload: Dictionary = parsed
	if str(payload.get("app", "")) != APP_ID:
		return {}
	return payload


static func websocket_urls(payload: Dictionary) -> PackedStringArray:
	var urls := PackedStringArray()
	var port := int(payload.get("ws_port", 0))
	if port <= 0:
		return urls
	for ip in payload.get("ips", []):
		var url := "wss://%s:%d/ws" % [str(ip), port]
		if not urls.has(url):
			urls.append(url)
	var host := str(payload.get("host", "")).strip_edges()
	if not host.is_empty():
		var host_url := "wss://%s:%d/ws" % [host, port]
		if not urls.has(host_url):
			urls.append(host_url)
	return urls
