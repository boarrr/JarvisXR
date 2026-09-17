class_name AgentThread
extends RefCounted

enum Status {
	IDLE,
	LISTENING,
	WORKING,
	WAITING_USER,
	COMPLETE,
	ERROR,
}

var id: String
var title: String
var status: Status = Status.IDLE
var messages: Array[AgentMessage] = []
var unread_count: int = 0
var created_at: String
var updated_at: String
var parent_thread_id: String = ""
var tags: Array[String] = []
var metadata: Dictionary = {}
var spatial_slot: int = -1
var is_pinned: bool = false


func _init(thread_id: String = "", thread_title: String = "Untitled thread") -> void:
	id = thread_id
	title = thread_title
	created_at = Time.get_datetime_string_from_system(true, false)
	updated_at = created_at


func add_message(message: AgentMessage) -> void:
	if message == null or message.thread_id != id:
		return
	messages.append(message)
	updated_at = Time.get_datetime_string_from_system(true, false)


static func status_label(value: Status) -> String:
	match value:
		Status.LISTENING:
			return "LISTENING"
		Status.WORKING:
			return "WORKING"
		Status.WAITING_USER:
			return "WAITING"
		Status.COMPLETE:
			return "COMPLETE"
		Status.ERROR:
			return "ERROR"
		_:
			return "IDLE"

