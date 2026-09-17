class_name DesktopComposer
extends CanvasLayer

@export var command_router_path: NodePath = ^"../CommandRouter"

@onready var _panel: PanelContainer = $Panel
@onready var _thread_label: Label = $Panel/Margin/VBox/ThreadLabel
@onready var _line_edit: LineEdit = $Panel/Margin/VBox/InputRow/MessageInput
@onready var _send_button: Button = $Panel/Margin/VBox/InputRow/SendButton
@onready var _feedback_label: Label = $Panel/Margin/VBox/Feedback

var _router: CommandRouter = null
var _editing: bool = false


func _ready() -> void:
	_router = get_node_or_null(command_router_path) as CommandRouter
	AppState.focused_thread_changed.connect(_on_focused_thread_changed)
	AppState.listening_state_changed.connect(_on_listening_state_changed)
	if _router != null:
		_router.feedback.connect(_on_router_feedback)
	_line_edit.text_submitted.connect(_on_text_submitted)
	_send_button.pressed.connect(_submit_current_text)
	_refresh_focus(AppState.focused_thread_id)


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("message_compose") and not AppState.focused_thread_id.is_empty():
		if _editing:
			_submit_current_text()
		else:
			begin_editing()
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("ui_cancel") and _editing:
		end_editing()
		get_viewport().set_input_as_handled()


func begin_editing() -> bool:
	if AppState.focused_thread_id.is_empty() or AppState.privacy_veil_active or not AppState.approval_requests.is_empty() or AppState.ui_mode == "xr_hands":
		return false
	_editing = true
	_panel.visible = true
	AppState.text_input_active = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_line_edit.grab_focus()
	_line_edit.caret_column = _line_edit.text.length()
	_feedback_label.text = _router.get_help_text() if _router != null else "Type a message"
	return true


func end_editing() -> void:
	_editing = false
	_panel.visible = false
	AppState.text_input_active = false
	_line_edit.release_focus()
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE if AppState.ui_mode == "hand_lab" else Input.MOUSE_MODE_CAPTURED


func is_editing() -> bool:
	return _editing


func set_draft(text: String) -> void:
	_line_edit.text = text


func get_draft() -> String:
	return _line_edit.text


func _submit_current_text() -> void:
	if _router == null:
		return
	var text := _line_edit.text.strip_edges()
	if text.is_empty():
		return
	if _router.submit_text(text):
		_line_edit.clear()
		end_editing()


func _on_text_submitted(_text: String) -> void:
	_submit_current_text()


func _on_focused_thread_changed(thread_id: String) -> void:
	if thread_id.is_empty() and _editing:
		end_editing()
	_refresh_focus(thread_id)


func _refresh_focus(thread_id: String) -> void:
	_panel.visible = _editing and not thread_id.is_empty()
	if thread_id.is_empty():
		_thread_label.text = "No focused thread"
		return
	var thread := AppState.get_thread(thread_id)
	_thread_label.text = "DESKTOP SIM // ENTER MESSAGE // %s" % (thread.title if thread != null else thread_id)


func _on_router_feedback(message: String) -> void:
	_feedback_label.text = message


func _on_listening_state_changed(state: String) -> void:
	if state == SpeechService.STATE_LISTENING:
		_feedback_label.text = "Listening locally — release V to transcribe"
	elif state == SpeechService.STATE_TRANSCRIBING:
		_feedback_label.text = "Transcribing locally — microphone audio is not uploaded"
	elif state == SpeechService.STATE_UNAVAILABLE:
		_feedback_label.text = "Local voice is off; typed input remains available"
