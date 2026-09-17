class_name DesktopInteractionSource
extends InteractionSource

enum PointerMode {
	CENTER_RAY,
	CURSOR_RAY,
}

@export var pointer_mode: PointerMode = PointerMode.CENTER_RAY
@export var camera_path: NodePath

var _camera: Camera3D = null
var _pointer_state := PointerState.new()


func _ready() -> void:
	source_name = "desktop"
	_camera = get_node_or_null(camera_path) as Camera3D
	if _camera == null:
		push_warning("[INPUT] Desktop source has no Camera3D at %s" % camera_path)
	set_process(true)


func _process(_delta: float) -> void:
	if _camera == null or AppState.text_input_active:
		return

	_pointer_state.origin = _camera.global_position
	_pointer_state.direction = -_camera.global_transform.basis.z.normalized()

	var selecting := Input.is_action_pressed("pointer_select")
	if selecting != _pointer_state.is_selecting:
		_pointer_state.is_selecting = selecting
		pointer_state_changed.emit(_pointer_state.copy())


func _input(event: InputEvent) -> void:
	if AppState.text_input_active:
		return
	if event.is_action_pressed("pointer_secondary") or event.is_action_pressed("ui_cancel"):
		var dismiss_event := InteractionEvent.new(
			InteractionEvent.Type.DISMISS,
			"",
			InteractionEvent.Source.DESKTOP
		)
		interaction_event.emit(dismiss_event)
	elif event.is_action_pressed("focus_next"):
		interaction_event.emit(InteractionEvent.new(
			InteractionEvent.Type.FOCUS,
			"",
			InteractionEvent.Source.DESKTOP
		))
	elif event.is_action_pressed("approval_accept"):
		interaction_event.emit(InteractionEvent.new(
			InteractionEvent.Type.APPROVE,
			"",
			InteractionEvent.Source.DESKTOP
		))
	elif event.is_action_pressed("approval_deny"):
		interaction_event.emit(InteractionEvent.new(
			InteractionEvent.Type.DENY,
			"",
			InteractionEvent.Source.DESKTOP
		))
	elif event.is_action_pressed("push_to_talk") and not event.is_echo():
		interaction_event.emit(InteractionEvent.new(
			InteractionEvent.Type.VOICE_BEGIN,
			"",
			InteractionEvent.Source.VOICE
		))
	elif event.is_action_released("push_to_talk") and not event.is_echo():
		interaction_event.emit(InteractionEvent.new(
			InteractionEvent.Type.VOICE_END,
			"",
			InteractionEvent.Source.VOICE
		))
	elif event.is_action_pressed("code_view_toggle") and not event.is_echo():
		interaction_event.emit(InteractionEvent.new(
			InteractionEvent.Type.CODE_TOGGLE,
			"",
			InteractionEvent.Source.DESKTOP
		))
	elif event.is_action_pressed("code_scroll_up") and not event.is_echo():
		interaction_event.emit(InteractionEvent.new(
			InteractionEvent.Type.CODE_SCROLL_UP,
			"",
			InteractionEvent.Source.DESKTOP
		))
	elif event.is_action_pressed("code_scroll_down") and not event.is_echo():
		interaction_event.emit(InteractionEvent.new(
			InteractionEvent.Type.CODE_SCROLL_DOWN,
			"",
			InteractionEvent.Source.DESKTOP
		))
	elif event.is_action_pressed("code_go_top") and not event.is_echo():
		interaction_event.emit(InteractionEvent.new(
			InteractionEvent.Type.CODE_GO_TOP,
			"",
			InteractionEvent.Source.DESKTOP
		))
	elif event.is_action_pressed("code_go_bottom") and not event.is_echo():
		interaction_event.emit(InteractionEvent.new(
			InteractionEvent.Type.CODE_GO_BOTTOM,
			"",
			InteractionEvent.Source.DESKTOP
		))


func is_available() -> bool:
	return _camera != null


func get_pointer_state() -> PointerState:
	return _pointer_state.copy()


func get_camera() -> Camera3D:
	return _camera
