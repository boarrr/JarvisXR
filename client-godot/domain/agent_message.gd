class_name AgentMessage
extends RefCounted

enum Role {
	USER,
	ASSISTANT,
	SYSTEM,
	TOOL,
}

var id: String
var thread_id: String
var role: Role = Role.USER
var content: String
var created_at: String
var is_streaming: bool = false
var metadata: Dictionary = {}


func _init(
	message_id: String = "",
	owner_thread_id: String = "",
	message_role: Role = Role.USER,
	message_content: String = ""
) -> void:
	id = message_id
	thread_id = owner_thread_id
	role = message_role
	content = message_content
	created_at = Time.get_datetime_string_from_system(true, false)

