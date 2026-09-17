class_name DebugThreadController
extends Node

const THREAD_TITLES := [
	"Research Agent",
	"Planning",
	"Code",
	"Design",
	"Operations",
	"Notes",
	"Data",
	"Writing",
	"Review",
	"Personal",
	"QA",
	"Archive",
]

const INITIAL_STATUSES := [
	AgentThread.Status.IDLE,
	AgentThread.Status.WORKING,
	AgentThread.Status.WAITING_USER,
	AgentThread.Status.COMPLETE,
	AgentThread.Status.ERROR,
	AgentThread.Status.LISTENING,
]

@export_range(1, 12, 1) var initial_thread_count: int = 8
@export var backend_bridge_path: NodePath = ^"../BackendBridge"

var _next_thread_number: int = 1


func seed_initial_threads() -> void:
	while AppState.ordered_thread_ids.size() < initial_thread_count:
		create_fake_thread()


func create_fake_thread() -> AgentThread:
	var number := _claim_next_thread_number()
	var thread_id := "thread_demo" if number == 1 else "thread_debug_%02d" % number
	var title: String = THREAD_TITLES[(number - 1) % THREAD_TITLES.size()]
	var status: AgentThread.Status = INITIAL_STATUSES[(number - 1) % INITIAL_STATUSES.size()]
	var bridge := _get_backend_bridge()
	if bridge == null or not bridge.send_command(
		"thread.create",
		{"id": thread_id, "title": title, "status": _status_to_wire(status)},
		thread_id
	):
		return null
	var thread := AppState.get_thread(thread_id)
	EventBus.debug_message.emit("Created: %s" % title)
	return thread


func remove_latest_thread() -> bool:
	if AppState.ordered_thread_ids.is_empty():
		return false
	var thread_id: String = AppState.ordered_thread_ids.back()
	var thread := AppState.get_thread(thread_id)
	var bridge := _get_backend_bridge()
	if bridge == null or not bridge.send_command("thread.archive", {}, thread_id):
		return false
	EventBus.debug_message.emit("Removed: %s" % (thread.title if thread != null else thread_id))
	return true


func cycle_target_status() -> bool:
	if AppState.ordered_thread_ids.is_empty():
		return false
	var thread_id := AppState.focused_thread_id
	if thread_id.is_empty():
		thread_id = AppState.ordered_thread_ids.front()
	var thread := AppState.get_thread(thread_id)
	if thread == null:
		return false
	var next_status := _next_status(thread.status)
	var bridge := _get_backend_bridge()
	if bridge == null or not bridge.send_command(
		"debug.thread.status",
		{"status": _status_to_wire(next_status)},
		thread_id
	):
		return false
	EventBus.debug_message.emit("%s: %s" % [thread.title, AgentThread.status_label(thread.status)])
	return true


func _get_backend_bridge() -> BackendBridge:
	return get_node_or_null(backend_bridge_path) as BackendBridge


func _claim_next_thread_number() -> int:
	var thread_id := "thread_demo" if _next_thread_number == 1 else "thread_debug_%02d" % _next_thread_number
	while AppState.get_thread(thread_id) != null:
		_next_thread_number += 1
		thread_id = "thread_demo" if _next_thread_number == 1 else "thread_debug_%02d" % _next_thread_number
	var claimed := _next_thread_number
	_next_thread_number += 1
	return claimed


func _next_status(current: AgentThread.Status) -> AgentThread.Status:
	match current:
		AgentThread.Status.IDLE:
			return AgentThread.Status.LISTENING
		AgentThread.Status.LISTENING:
			return AgentThread.Status.WORKING
		AgentThread.Status.WORKING:
			return AgentThread.Status.WAITING_USER
		AgentThread.Status.WAITING_USER:
			return AgentThread.Status.COMPLETE
		AgentThread.Status.COMPLETE:
			return AgentThread.Status.ERROR
		_:
			return AgentThread.Status.IDLE


func _status_to_wire(status: AgentThread.Status) -> String:
	match status:
		AgentThread.Status.LISTENING:
			return "listening"
		AgentThread.Status.WORKING:
			return "working"
		AgentThread.Status.WAITING_USER:
			return "waiting_user"
		AgentThread.Status.COMPLETE:
			return "complete"
		AgentThread.Status.ERROR:
			return "error"
		_:
			return "idle"


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("debug_add_thread"):
		create_fake_thread()
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("debug_remove_thread"):
		remove_latest_thread()
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("debug_cycle_status"):
		cycle_target_status()
		get_viewport().set_input_as_handled()
