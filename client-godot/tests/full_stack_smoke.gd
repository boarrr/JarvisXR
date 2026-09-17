extends Node

const TEST_PORT := 18788
const TIMEOUT_SECONDS := 8.0

enum Phase {
	WAITING_FOR_THREAD,
	WAITING_FOR_MESSAGE,
	WAITING_FOR_APPROVAL,
	WAITING_FOR_TOOL,
	FINISHED,
}

var _main: Node = null
var _router: CommandRouter = null
var _source: DesktopInteractionSource = null
var _thread_id: String = ""
var _phase: Phase = Phase.WAITING_FOR_THREAD
var _elapsed: float = 0.0
var _failed := false


func _ready() -> void:
	ProjectSettings.set_setting("spatial_agent/backend_mode", "websocket")
	ProjectSettings.set_setting(
		"spatial_agent/backend_websocket_url",
		"ws://127.0.0.1:%d/ws" % TEST_PORT
	)
	var main_scene := load("res://scenes/app/main.tscn") as PackedScene
	_main = main_scene.instantiate()
	add_child(_main)
	_router = _main.get_node("CommandRouter") as CommandRouter
	_source = (_main.get_node("UserRig") as UserRig).get_interaction_source()


func _process(delta: float) -> void:
	_elapsed += delta
	if _elapsed >= TIMEOUT_SECONDS:
		_check(false, "full-stack workflow timed out in phase %d" % _phase)
		_finish()
		return

	match _phase:
		Phase.WAITING_FOR_THREAD:
			if AppState.connection_state != BackendTransport.STATE_CONNECTED or AppState.ordered_thread_ids.is_empty():
				return
			_thread_id = AppState.ordered_thread_ids.front()
			_check(AppState.focus_thread(_thread_id), "real snapshot thread can be focused")
			_check(_router.submit_text("Full stack Godot message"), "Godot sends message through the real backend")
			_phase = Phase.WAITING_FOR_MESSAGE
		Phase.WAITING_FOR_MESSAGE:
			var thread := AppState.get_thread(_thread_id)
			if thread == null or thread.status != AgentThread.Status.COMPLETE:
				return
			_check(thread.messages.size() >= 2, "real backend returns message history")
			_check(thread.messages.back().content.contains("Full stack Godot message"), "real streamed content reaches the panel model")
			_check(_router.submit_text("/tool integration note"), "Godot requests approval-gated backend tool")
			_phase = Phase.WAITING_FOR_APPROVAL
		Phase.WAITING_FOR_APPROVAL:
			if AppState.approval_requests.is_empty():
				return
			_check((_main.get_node("ApprovalPanel") as ApprovalPanel).is_open(), "real approval event opens the spatial panel")
			var approval_event := InputEventAction.new()
			approval_event.action = "approval_accept"
			approval_event.pressed = true
			_source._input(approval_event)
			_phase = Phase.WAITING_FOR_TOOL
		Phase.WAITING_FOR_TOOL:
			var thread := AppState.get_thread(_thread_id)
			if thread == null or thread.status != AgentThread.Status.COMPLETE or not AppState.approval_requests.is_empty():
				return
			_check(thread.messages.back().role == AgentMessage.Role.TOOL, "approved backend tool result reaches transcript state")
			_check(thread.messages.back().content.contains("Approved simulated note"), "tool result is preserved")
			_finish()


func _finish() -> void:
	if _phase == Phase.FINISHED:
		return
	_phase = Phase.FINISHED
	set_process(false)
	ProjectSettings.set_setting("spatial_agent/backend_mode", "fake")
	ProjectSettings.set_setting("spatial_agent/backend_websocket_url", "ws://127.0.0.1:8787/ws")
	if not _failed:
		print("[TEST] Full-stack Godot/backend checks passed")
	if _main != null:
		_main.queue_free()
	get_tree().quit(1 if _failed else 0)


func _check(condition: bool, description: String) -> void:
	if condition:
		return
	_failed = true
	push_error("[TEST] Failed: %s" % description)
