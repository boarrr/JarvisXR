extends Node

var _failed := false


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	var payload := (
		"spatialagent://pair?url=wss%3A%2F%2F192.168.0.17%3A8787%2Fws"
		+ "&code=CODE123&ca=abc123"
	)
	var parsed := PairingPayload.parse(payload)
	_check(parsed.get("url", "") == "wss://192.168.0.17:8787/ws", "payload URL is decoded")
	_check(parsed.get("code", "") == "CODE123", "payload code is parsed")
	_check(parsed.get("ca", "") == "abc123", "payload CA fingerprint is parsed")
	_check(PairingPayload.parse("just some text").is_empty(), "non-payload text is rejected")
	_check(PairingPayload.parse("spatialagent://pair?url=x").is_empty(), "missing code is rejected")

	var fake := FakeBackendTransport.new()
	add_child(fake)
	_check(fake.pair_with_payload(payload), "transport pairs from a valid payload")
	_check(not fake.pair_with_payload("garbage"), "transport rejects an invalid payload")

	if not _failed:
		print("[TEST] QR pairing checks passed")
	get_tree().quit(1 if _failed else 0)


func _check(condition: bool, description: String) -> void:
	if condition:
		return
	_failed = true
	push_error("[TEST] Failed: %s" % description)
