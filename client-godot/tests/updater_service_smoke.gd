extends Node

var _failed := false


class FakeBridge:
	extends Node

	signal update_message(event_type: String, payload: Dictionary)

	var payload_bytes := PackedByteArray()
	var manifest := {}
	var chunk := 4096

	func send_command(command_type: String, command_payload: Dictionary = {}, _thread_id: String = "") -> bool:
		if command_type == "update.check":
			update_message.emit("update.available", manifest)
		elif command_type == "update.fetch":
			var offset := int(command_payload.get("offset", 0))
			var length := int(command_payload.get("length", chunk))
			var end := mini(offset + length, payload_bytes.size())
			var data := payload_bytes.slice(offset, end)
			update_message.emit("update.chunk", {
				"offset": offset,
				"data": Marshalls.raw_to_base64(data),
				"eof": end >= payload_bytes.size(),
			})
		return true


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	var payload := PackedByteArray()
	for index in range(20000):
		payload.append(index % 251)
	var digest := HashingContext.new()
	digest.start(HashingContext.HASH_SHA256)
	digest.update(payload)
	var sha := digest.finish().hex_encode()

	var bridge := FakeBridge.new()
	add_child(bridge)
	bridge.payload_bytes = payload
	bridge.manifest = {
		"version": "test-rev",
		"sha256": sha,
		"size_bytes": payload.size(),
		"chunk_bytes": 4096,
	}

	var updater := UpdaterService.new()
	updater.auto_check = false
	updater.auto_install = false
	var events := {"available": 0, "failed": [], "progress": 0}
	updater.update_available.connect(func(_version, _sha, _size): events["available"] += 1)
	updater.update_failed.connect(func(reason): events["failed"].append(reason))
	updater.download_progress.connect(func(_received, total): events["progress"] = total)
	updater.set_bridge(bridge)
	add_child(updater)

	updater.check_for_update()
	_check(events["available"] == 1, "update.check surfaces an available update")
	updater.begin_install()
	_check(events["progress"] == payload.size(), "download assembles the full package")
	_check(
		events["failed"] == ["plugin_missing"],
		"a verified package reaches the installer boundary"
	)

	# A checksum mismatch must be rejected before any install attempt.
	var bad_bridge := FakeBridge.new()
	add_child(bad_bridge)
	bad_bridge.payload_bytes = payload
	bad_bridge.manifest = {
		"version": "bad",
		"sha256": "00",
		"size_bytes": payload.size(),
		"chunk_bytes": 4096,
	}
	var bad_updater := UpdaterService.new()
	bad_updater.auto_check = false
	var bad_failed: Array = []
	bad_updater.update_failed.connect(func(reason): bad_failed.append(reason))
	bad_updater.set_bridge(bad_bridge)
	add_child(bad_updater)
	bad_updater.check_for_update()
	bad_updater.begin_install()
	_check(bad_failed == ["checksum_mismatch"], "checksum mismatch blocks installation")

	if not _failed:
		print("[TEST] Updater service checks passed")
	get_tree().quit(1 if _failed else 0)


func _check(condition: bool, label: String) -> void:
	if not condition:
		_failed = true
		push_error("[TEST] Failed: %s" % label)
