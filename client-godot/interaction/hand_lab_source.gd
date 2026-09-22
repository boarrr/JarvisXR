class_name HandLabSource
extends OpenXRInteractionSource

# Synthetic world-space joints enter the same gesture interpreter as optical
# tracking. This source never registers a tracker or replaces a live XR source.
var camera: Camera3D
var palm_visible := true
var tracking_enabled := true
var cursor := Vector2.ZERO
var pinching := false
var two_hands := false
var spread := 0.28
var twist := 0.0
var _window_focused := true
var _button_edges: Array[Vector2i] = []


func _ready() -> void:
	super._ready()
	source_name = "hand_lab"
	origin_smoothing = 1.0
	direction_smoothing = 1.0
	process_physics_priority = -10


func _physics_process(delta: float) -> void:
	if not _session_active:
		return
	cursor = get_viewport().get_mouse_position()
	if AppState.text_input_active or not _window_focused:
		release_gestures()
	elif not _button_edges.is_empty():
		# Preserve quick clicks that press and release between physics ticks.
		# Each edge is presented for a full tick before the manager raycasts.
		var edge: Vector2i = _button_edges.pop_front()
		pinching = edge.x == 1
		two_hands = pinching and edge.y == 1
		if not pinching:
			spread = 0.28
			twist = 0.0
	elif pinching and not Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		release_gestures()
	super._physics_process(delta)


func _sample_for_hand(hand_name: String) -> Dictionary:
	if camera == null or not tracking_enabled or not _window_focused:
		return {}
	if hand_name == "left" and not palm_visible and not two_hands:
		return {}
	var ray := camera.project_ray_normal(cursor).normalized()
	var tip := camera.project_position(cursor, 0.6)
	var basis := camera.global_basis
	var palm := camera.global_transform * Vector3(-0.48, -0.40, -1.05)
	if two_hands:
		var offset := basis * (Vector3.RIGHT.rotated(Vector3.UP, twist) * spread * 0.5)
		tip += offset * (-1.0 if hand_name == "left" else 1.0)
		# Both fingertips continue aiming at the cursor's scene point.
		ray = (camera.project_position(cursor, 2.0) - tip).normalized()
		palm = tip - ray * 0.08
	elif hand_name == "left":
		tip = palm + basis * Vector3(0.06, 0.05, -0.04)
	else:
		palm = tip - ray * 0.08
	var closed := pinching and (hand_name == "right" or two_hands)
	return {
		"hand_name": hand_name,
		"palm_transform": Transform3D(basis, palm),
		"index_tip": tip,
		"index_distal": tip - ray * 0.035,
		"thumb_tip": tip + basis.x * (0.014 if closed else 0.065),
	}


func _unhandled_input(event: InputEvent) -> void:
	if not _session_active or AppState.text_input_active:
		return
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			if _button_edges.size() < 16:
				_button_edges.append(Vector2i(int(event.pressed), int(event.shift_pressed)))
			else:
				release_gestures()
			get_viewport().set_input_as_handled()
		elif event.pressed and event.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
			var direction := 1.0 if event.button_index == MOUSE_BUTTON_WHEEL_UP else -1.0
			if two_hands:
				if event.alt_pressed:
					twist += direction * 0.08
				else:
					spread = clampf(spread * (1.0 + direction * 0.08), 0.12, 0.7)
			elif _hover_target_id == "ui:code_surface":
				submit_pinch_scroll(direction)
			get_viewport().set_input_as_handled()


func _update_pinch_scroll(position: Vector3, was_pinching: bool, is_pinching: bool) -> void:
	if two_hands:
		_scroll_accumulator = 0.0
		_last_pinch_position = position
		return
	super._update_pinch_scroll(position, was_pinching, is_pinching)


func release_gestures() -> void:
	_button_edges.clear()
	pinching = false
	two_hands = false
	spread = 0.28
	twist = 0.0


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT:
		_window_focused = false
		release_gestures()
		_reset_tracking()
	elif what == NOTIFICATION_APPLICATION_FOCUS_IN:
		_window_focused = true


func send_action(target: String) -> void:
	# Same application routing and privacy/approval checks as a palm pinch.
	submit_direct_touch(target, Vector3.ZERO)


func _begin_grab_if_touching(_position: Vector3) -> bool:
	# The lab synthesizes a fingertip inside the target, so it would always
	# read as a grab; keep pinch-to-focus here and let the headset grab.
	return false
