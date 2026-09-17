class_name HandLab
extends CanvasLayer

var source: HandLabSource
var _main: Node
var _rig: UserRig
var _metrics: Label
var _hint: Label
var _guide: Label
var _guide_panel: PanelContainer
var _quality_button: Button
var _frames: Array[float] = []
var _elapsed := 0.0
var _quality := 1
var _auto := true
var _slow_windows := 0
var _fast_windows := 0
var _checks := {"focus": false, "code": false, "scroll": false, "grab": false, "privacy": false, "ask": false}
var _previous_scroll := 0.0
var _previous_max_fps := 0


func start(main: Node) -> HandLabSource:
	_main = main
	_rig = main.get_node("UserRig") as UserRig
	source = HandLabSource.new()
	source.name = "SyntheticHands"
	add_child(source)
	source.camera = _rig.get_camera()
	source.set_hand_tracking_active(true)
	_rig.set_hand_lab_active(true)
	(main.get_node("PalmConsole") as PalmConsole)._hand_source = source
	(main.get_node("HandRayVisualizer") as HandRayVisualizer)._source = source
	main.get_node("PointerHUD").visible = false
	_previous_max_fps = Engine.max_fps
	Engine.max_fps = 60
	layer = 15
	_build_ui()
	_apply_quality(1)
	source.interaction_event.connect(_observe_gesture)
	AppState.privacy_veil_changed.connect(func(value: bool) -> void: _checks.privacy = _checks.privacy or value)
	return source


func _exit_tree() -> void:
	if source != null:
		Engine.max_fps = _previous_max_fps


func _build_ui() -> void:
	var root := Control.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)
	var theme := Theme.new()
	theme.default_font_size = 14
	root.theme = theme
	var top := _panel(root)
	top.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	top.offset_left = 20
	top.offset_right = -20
	top.offset_top = 16
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 20)
	top.add_child(row)
	var title := Label.new()
	title.text = "J A R V I S   /   H A N D   L A B"
	title.modulate = Color(0.26, 0.94, 1.0)
	row.add_child(title)
	_metrics = Label.new()
	_metrics.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_metrics.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	row.add_child(_metrics)
	_quality_button = _button(row, "AUTO", _cycle_quality)
	_button(row, "Guide · F1", func() -> void: _guide_panel.visible = not _guide_panel.visible)
	_button(row, "Reset view", _rig.reset_desktop_view)
	_guide_panel = _panel(root)
	_guide_panel.position = Vector2(20, 76)
	_guide = Label.new()
	_guide.add_theme_font_size_override("font_size", 13)
	_guide_panel.add_child(_guide)
	var bottom := _panel(root)
	bottom.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	bottom.offset_left = 20
	bottom.offset_right = -20
	bottom.offset_top = -108
	bottom.offset_bottom = -16
	var stack := VBoxContainer.new()
	bottom.add_child(stack)
	_hint = Label.new()
	_hint.modulate = Color(0.5, 0.88, 0.91)
	stack.add_child(_hint)
	var scroll := ScrollContainer.new()
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	stack.add_child(scroll)
	var actions := HBoxContainer.new()
	actions.add_theme_constant_override("separation", 8)
	scroll.add_child(actions)
	for entry in [
		["Next agent", "palm:focus_next"], ["Code", "palm:code_toggle"],
		["Ask", "palm:voice_toggle"], ["Cognition", "palm:cognition_toggle"],
		["Mission map", "palm:mission_toggle"], ["Privacy", "palm:privacy_toggle"],
		["Dismiss", "palm:dismiss"],
	]:
		_button(actions, entry[0], source.send_action.bind(entry[1]))
	_button(actions, "Palm · P", _toggle_palm)
	_button(actions, "Tracking · T", _toggle_tracking)
	_refresh_ui()


func _panel(parent: Control) -> PanelContainer:
	var panel := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.008, 0.027, 0.04, 0.96)
	style.border_color = Color(0.04, 0.43, 0.51, 0.8)
	style.set_border_width_all(1)
	style.set_corner_radius_all(6)
	style.content_margin_left = 14
	style.content_margin_right = 14
	style.content_margin_top = 10
	style.content_margin_bottom = 10
	panel.add_theme_stylebox_override("panel", style)
	parent.add_child(panel)
	return panel


func _button(parent: Node, caption: String, action: Callable) -> Button:
	var button := Button.new()
	button.text = caption
	button.focus_mode = Control.FOCUS_NONE
	button.custom_minimum_size.y = 32
	button.pressed.connect(action)
	parent.add_child(button)
	return button


func _process(delta: float) -> void:
	if source == null:
		return
	_frames.append(delta * 1000.0)
	if _frames.size() > 180:
		_frames.pop_front()
	_elapsed += delta
	if _elapsed < 0.5:
		return
	_elapsed = 0.0
	var viewer := _main.get_node("CodeViewer") as CodeViewer
	_checks.focus = _checks.focus or not AppState.focused_thread_id.is_empty()
	if viewer.is_open() and not _checks.code:
		_guide_panel.visible = false
		source.palm_visible = false
	_checks.code = _checks.code or viewer.is_open()
	var scroll := float(viewer._code_edit.scroll_vertical)
	if viewer.is_open() and not is_equal_approx(scroll, _previous_scroll):
		_checks.scroll = true
	_previous_scroll = scroll
	var ordered := _frames.duplicate()
	ordered.sort()
	var p95: float = ordered[clampi(ceili(ordered.size() * 0.95) - 1, 0, ordered.size() - 1)]
	if _auto and _frames.size() >= 120:
		_adapt_quality(p95)
	_metrics.text = "%d FPS  /  %.1f ms p95  /  %d draws  /  %d%% 3D" % [
		Engine.get_frames_per_second(), p95,
		Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME),
		roundi(get_viewport().scaling_3d_scale * 100.0),
	]
	_refresh_ui()


func _refresh_ui() -> void:
	var status := "TRACKING LOST · T to recover" if not source.tracking_enabled else (
		"TWO-HAND GRAB · wheel scales · Alt+wheel rotates" if source.two_hands else (
		"PINCH · drag code vertically to scroll" if source.pinching else "AIM · click an orb or palm button"
	))
	_hint.text = "%s    /    RMB look · WASD move · Enter type · Tab next · C code" % status
	if AppState.privacy_veil_active:
		_guide.text = "PRIVACY VEIL ACTIVE\nUse Privacy to reveal the workspace.\nBackground agents may still be running."
		return
	_guide.text = "NO HEADSET REQUIRED\nMouse = right hand · left click = pinch\nShift + left drag = two-hand code move\nWhile grabbing: wheel = scale · Alt+wheel = yaw\nP = palm menu · T = tracking loss · Home = reset\nF1 = hide this guide\n\nPRACTICE CIRCUIT  (synthetic input)"
	for entry in [["focus", "Select an agent"], ["code", "Open Code Trace"], ["scroll", "Scroll the code"], ["grab", "Move with two hands"], ["privacy", "Try Privacy Veil"], ["ask", "Send a quick intent"]]:
		_guide.text += "\n%s  %s" % ["✓" if _checks[entry[0]] else "○", entry[1]]


func _observe_gesture(event: InteractionEvent) -> void:
	if event.type == InteractionEvent.Type.GRAB_MOVE:
		_checks.grab = true


func _unhandled_input(event: InputEvent) -> void:
	if source == null or AppState.text_input_active or not event is InputEventKey or not event.pressed or event.echo:
		return
	match event.keycode:
		KEY_F1: _guide_panel.visible = not _guide_panel.visible
		KEY_HOME: _rig.reset_desktop_view()
		KEY_P: _toggle_palm()
		KEY_T: _toggle_tracking()
		KEY_TAB: source.send_action("palm:focus_next")
		KEY_C: source.send_action("palm:code_toggle")
		KEY_ESCAPE: source.send_action("palm:dismiss")
		KEY_J: source.submit_pinch_scroll(-1.0)
		KEY_K: source.submit_pinch_scroll(1.0)
		_: return
	get_viewport().set_input_as_handled()


func _toggle_palm() -> void:
	source.palm_visible = not source.palm_visible


func _toggle_tracking() -> void:
	source.tracking_enabled = not source.tracking_enabled
	source.release_gestures()
	if not source.tracking_enabled:
		source._reset_tracking()


func _cycle_quality() -> void:
	if _auto:
		_auto = false
		_apply_quality(0)
	elif _quality < 2:
		_apply_quality(_quality + 1)
	else:
		_auto = true
		_apply_quality(1)


func _apply_quality(level: int) -> void:
	_quality = level
	_slow_windows = 0
	_fast_windows = 0
	get_viewport().scaling_3d_scale = 0.75 if level == 0 else 1.0
	get_viewport().msaa_3d = [Viewport.MSAA_DISABLED, Viewport.MSAA_2X, Viewport.MSAA_4X][level]
	_quality_button.text = "AUTO" if _auto else ["ECO", "BALANCED", "ULTRA"][level]
	var field := _main.get_node_or_null("ReactorField")
	if field != null:
		field.set_quality(level)


func _adapt_quality(p95: float) -> void:
	_slow_windows = _slow_windows + 1 if p95 > 23.0 else 0
	_fast_windows = _fast_windows + 1 if p95 < 18.0 else 0
	if _slow_windows >= 4:
		get_viewport().scaling_3d_scale = maxf(0.65, get_viewport().scaling_3d_scale - 0.1)
		_slow_windows = 0
	elif _fast_windows >= 12:
		get_viewport().scaling_3d_scale = minf(1.0, get_viewport().scaling_3d_scale + 0.05)
		_fast_windows = 0
