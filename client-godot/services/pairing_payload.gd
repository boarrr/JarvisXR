class_name PairingPayload
extends RefCounted

## Parses a QR join payload like:
##   spatialagent://pair?url=wss%3A%2F%2F192.168.0.17%3A8787%2Fws&code=ABCD1234&ca=deadbeef

const SCHEMES := ["spatialagent://", "spatial-agent://"]


static func parse(text: String) -> Dictionary:
	var trimmed := text.strip_edges()
	var query_at := trimmed.find("?")
	if query_at < 0:
		return {}
	var scheme := trimmed.substr(0, query_at)
	var matched := false
	for candidate in SCHEMES:
		if scheme.begins_with(candidate):
			matched = true
			break
	if not matched:
		return {}
	var query := trimmed.substr(query_at + 1)
	var fields: Dictionary = {}
	for pair in query.split("&", false):
		var equals_at := pair.find("=")
		if equals_at < 0:
			continue
		var key := pair.substr(0, equals_at).uri_decode()
		var value := pair.substr(equals_at + 1).uri_decode()
		fields[key] = value
	if not fields.has("url") or not fields.has("code"):
		return {}
	return {
		"url": str(fields.get("url", "")),
		"code": str(fields.get("code", "")),
		"ca": str(fields.get("ca", "")),
	}
