class_name PalmConsole
extends Node3D

## Left-hand master panel, redesigned voice-first.
##
## One scrollable surface: a header (agent + link), a continuously scrolling
## conversation log, a live voice indicator, and a compact footer whose primary
## action is TALK. No pages, no legacy instrument controls.

const SPATIAL_TARGET_SCRIPT := preload("res://interaction/spatial_action_target.gd")

const VIEWPORT_SIZE := Vector2i(640, 860)
const SCREEN_CENTER := Vector2(0.0, 0.0)
const SCREEN_SIZE := Vector2(0.5, 0.672)
const HEADER_HEIGHT_PX := 104.0
const FOOTER_HEIGHT_PX := 172.0
const CHAT_RENDER_INTERVAL := 0.1
const CHAT_SCROLL_LINES_PER_METRE := 55.0

const RECT_TALK := Rect2(16, 690, 608, 80)
const RECT_SECONDARY := Rect2(16, 778, 608, 62)
const SECONDARY := [
	["NEW", "palm:new_agent", "NewTarget"],
	["NEXT", "palm:focus_next", "NextTarget"],
	["UNDO", "palm:undo", "UndoTarget"],
	["UPDATE", "palm:update", "UpdateTarget"],
	["CLOSE", "palm:dismiss", "CloseTarget"],
]

@export var hand_source_path: NodePath = ^"../XRRuntime/OpenXRInteractionSource"
@export var user_rig_path: NodePath = ^"../UserRig"
@export_range(-0.6, 0.6, 0.01) var parked_side_offset: float = -0.12
@export_range(0.3, 1.2, 0.01) var parked_distance: float = 0.52
@export_range(0.0, 0.8, 0.01) var parked_drop: float = 0.14
@export_range(0.0, 1.0, 0.05) var parked_keep_gaze: float = 0.35
@export_range(0.5, 10.0, 0.5) var parked_ignore_seconds: float = 3.0
@export_range(0.3, 1.0, 0.01) var console_scale: float = 0.7
@export var grab_enabled: bool = true
@export_range(0.05, 0.35, 0.01) var grab_margin: float = 0.16

var _hand_source: OpenXRInteractionSource = null
var _user_rig: UserRig = null
var _camera: Camera3D = null
var _viewport: SubViewport = null
var _screen: MeshInstance3D = null
var _title_label: Label = null
var _subtitle_label: Label = null
var _build_label: Label = null
var _body: RichTextLabel = null
var _voice_label: Label = null
var _buttons: Dictionary = {}
var _targets: Array[Area3D] = []
var _button_rects: Array[Rect2] = []
var _panel_ignored := 0.0
var _grabbing := false
var _grab_offset := Vector3.ZERO
var _chat_follow := true
var _chat_dirty := false
var _chat_elapsed := 0.0
var _chat_scroll_line := 0
var _swipe_active := false
var _swipe_start := Vector2.ZERO
var _swipe_last := Vector2.ZERO
var _scroll_anchor_y := 0.0
var _scroll_accumulator := 0.0


func _ready() -> void:
	_hand_source = get_node_or_null(hand_source_path) as OpenXRInteractionSource
	_user_rig = get_node_or_null(user_rig_path) as UserRig
	if _user_rig != null:
		_camera = _user_rig.get_camera()
	_build_screen()
	AppState.connection_state_changed.connect(_refresh_all)
	AppState.provider_identity_changed.connect(_on_provider_identity_changed)
	AppState.listening_state_changed.connect(_refresh_all)
	AppState.update_banner_changed.connect(_refresh_all)
	AppState.focused_thread_changed.connect(_on_focus_changed)
	AppState.thread_updated.connect(_on_thread_updated)
	scale = Vector3.ONE * console_scale
	_set_console_visible(false)
	_refresh_all()


func get_screen_viewport() -> SubViewport:
	return _viewport


func summon_now() -> void:
	if visible:
		_hide_panel()
		return
	if _camera == null and _user_rig != null:
		_camera = _user_rig.get_camera()
	if _camera == null:
		return
	var camera_position := _camera.global_position
	var camera_forward := -_camera.global_transform.basis.z
	camera_forward.y = 0.0
	if camera_forward.length_squared() < 0.0001:
		camera_forward = Vector3.FORWARD
	_park_panel(camera_position, camera_forward.normalized())
	_set_console_visible(true)
	_panel_ignored = 0.0
	_chat_follow = true
	_refresh_all()


func handle_screen_action(target_id: String) -> void:
	match target_id:
		"palm_screen:scroll_up":
			_scroll_chat_lines(6)
		"palm_screen:scroll_down":
			_scroll_chat_lines(-6)
		_:
			pass


func _build_screen() -> void:
	_viewport = SubViewport.new()
	_viewport.size = VIEWPORT_SIZE
	_viewport.transparent_bg = true
	_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child(_viewport)

	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_viewport.add_child(root)

	var background := PanelContainer.new()
	background.set_anchors_preset(Control.PRESET_FULL_RECT)
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.03, 0.09, 0.13, 1.0)
	style.border_color = Color(0.15, 0.95, 1.0, 1.0)
	style.set_border_width_all(5)
	style.set_corner_radius_all(10)
	background.add_theme_stylebox_override("panel", style)
	background.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(background)

	_title_label = _label(root, Vector2(20, 14), Vector2(VIEWPORT_SIZE.x - 40, 36), 27, Color(0.55, 0.99, 1.0))
	_subtitle_label = _label(root, Vector2(20, 56), Vector2(VIEWPORT_SIZE.x - 40, 30), 16, Color(0.72, 0.9, 0.96))
	_build_label = _label(root, Vector2(VIEWPORT_SIZE.x - 240, 18), Vector2(220, 26), 14, Color(0.5, 0.8, 0.86))
	_build_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT

	_body = RichTextLabel.new()
	_body.position = Vector2(16, HEADER_HEIGHT_PX)
	_body.size = Vector2(
		VIEWPORT_SIZE.x - 32,
		VIEWPORT_SIZE.y - HEADER_HEIGHT_PX - FOOTER_HEIGHT_PX
	)
	_body.bbcode_enabled = true
	_body.scroll_active = true
	_body.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_body.add_theme_font_size_override("normal_font_size", 20)
	_body.add_theme_color_override("default_color", Color(0.93, 0.99, 1.0))
	root.add_child(_body)

	_voice_label = _label(
		root,
		Vector2(16, VIEWPORT_SIZE.y - FOOTER_HEIGHT_PX - 36),
		Vector2(VIEWPORT_SIZE.x - 32, 32),
		18,
		Color(0.6, 1.0, 0.72)
	)
	_voice_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER

	_make_button(root, RECT_TALK, "TALK", Color(0.05, 0.55, 0.36), Color(0.7, 1, 0.85), "TalkTarget", "palm:voice_toggle")
	var count := SECONDARY.size()
	var gap := 8.0
	var width := (RECT_SECONDARY.size.x - gap * float(count - 1)) / float(count)
	for index in range(count):
		var entry: Array = SECONDARY[index]
		var rect := Rect2(
			Vector2(RECT_SECONDARY.position.x + float(index) * (width + gap), RECT_SECONDARY.position.y),
			Vector2(width, RECT_SECONDARY.size.y)
		)
		_make_button(root, rect, str(entry[0]), Color(0.05, 0.4, 0.5), Color(0.9, 1.0, 1.0), str(entry[2]), str(entry[1]))

	_build_backing_and_screen(root)


func _build_backing_and_screen(root: Control) -> void:
	var backing_material := StandardMaterial3D.new()
	backing_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	backing_material.albedo_color = Color(0.015, 0.05, 0.075, 1.0)
	backing_material.no_depth_test = false
	var backing := MeshInstance3D.new()
	var backing_quad := QuadMesh.new()
	backing_quad.size = SCREEN_SIZE * Vector2(1.07, 1.06)
	backing_quad.material = backing_material
	backing.mesh = backing_quad
	# Behind the screen quad (the screen faces +Z toward the user).
	backing.position = Vector3(SCREEN_CENTER.x, SCREEN_CENTER.y, -0.012)
	backing.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(backing)

	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.albedo_texture = _viewport.get_texture()
	# Depth-tested so the user's hands render in front of the panel.
	material.no_depth_test = false
	_screen = MeshInstance3D.new()
	var quad := QuadMesh.new()
	quad.size = SCREEN_SIZE
	quad.material = material
	_screen.mesh = quad
	_screen.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_screen)


func _label(root: Control, position: Vector2, size: Vector2, font_size: int, color: Color) -> Label:
	var label := Label.new()
	label.position = position
	label.size = size
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(label)
	return label


func _make_button(
	root: Control,
	rect: Rect2,
	text: String,
	fill: Color,
	ink: Color,
	node_name: String,
	target_id: String
) -> void:
	var panel := PanelContainer.new()
	panel.position = rect.position
	panel.size = rect.size
	var style := StyleBoxFlat.new()
	style.bg_color = fill
	style.border_color = ink
	style.set_border_width_all(2)
	style.set_corner_radius_all(6)
	panel.add_theme_stylebox_override("panel", style)
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(panel)
	var label := Label.new()
	label.text = text
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", 22)
	label.add_theme_color_override("font_color", ink)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(label)
	_buttons[text] = panel
	_button_rects.append(rect)

	var area := Area3D.new()
	area.name = node_name
	area.set_script(SPATIAL_TARGET_SCRIPT)
	area.set("target_id", target_id)
	area.collision_layer = 2
	area.collision_mask = 0
	area.monitoring = false
	area.add_to_group("interactable")
	var scale_x := SCREEN_SIZE.x / float(VIEWPORT_SIZE.x)
	var scale_y := SCREEN_SIZE.y / float(VIEWPORT_SIZE.y)
	var shape := BoxShape3D.new()
	shape.size = Vector3(rect.size.x * scale_x, rect.size.y * scale_y, 0.08)
	var collision := CollisionShape3D.new()
	collision.shape = shape
	area.add_child(collision)
	area.position = _rect_to_local(rect)
	add_child(area)
	_targets.append(area)


func _rect_to_local(rect: Rect2) -> Vector3:
	var center := rect.position + rect.size * 0.5
	var scale_x := SCREEN_SIZE.x / float(VIEWPORT_SIZE.x)
	var scale_y := SCREEN_SIZE.y / float(VIEWPORT_SIZE.y)
	return Vector3(
		SCREEN_CENTER.x + (center.x - VIEWPORT_SIZE.x * 0.5) * scale_x,
		SCREEN_CENTER.y - (center.y - VIEWPORT_SIZE.y * 0.5) * scale_y,
		0.03
	)


func _physics_process(delta: float) -> void:
	if AppState.ui_mode not in ["xr_hands", "hand_lab"] or _hand_source == null or _user_rig == null:
		_hide_panel()
		return
	if _camera == null:
		_camera = _user_rig.get_camera()
	if _camera == null:
		_hide_panel()
		return
	if not visible:
		return
	if not _grabbing:
		var camera_forward := -_camera.global_transform.basis.z
		camera_forward.y = 0.0
		if camera_forward.length_squared() < 0.0001:
			camera_forward = Vector3.FORWARD
		camera_forward = camera_forward.normalized()
		var to_panel := global_position - _camera.global_position
		var distance_to_panel := to_panel.length()
		var panel_gaze := (
			to_panel.normalized().dot(camera_forward) if distance_to_panel > 0.001 else 0.0
		)
		if panel_gaze >= parked_keep_gaze:
			_panel_ignored = 0.0
		else:
			_panel_ignored += delta
			if _panel_ignored >= parked_ignore_seconds:
				_hide_panel()
				return
	_update_grab()
	_update_swipe()
	_face_user(delta)


func _face_user(delta: float) -> void:
	# Always turn the readable face toward the user, wherever the panel ends up.
	if _camera == null:
		return
	var to_user := _camera.global_position - global_position
	to_user.y = 0.0
	if to_user.length_squared() < 0.0001:
		return
	var desired := atan2(to_user.x, to_user.z)
	if delta <= 0.0:
		global_rotation = Vector3(0.0, desired, 0.0)
	else:
		global_rotation = Vector3(
			0.0,
			lerp_angle(global_rotation.y, desired, 1.0 - exp(-10.0 * delta)),
			0.0
		)


func _update_grab() -> void:
	if not grab_enabled or _hand_source == null:
		return
	var sample := _hand_source.get_latest_hand_sample("right")
	if sample.is_empty():
		_grabbing = false
		return
	var tip := sample.get("index_tip", Vector3.ZERO) as Vector3
	var pinching := _hand_source.is_hand_pinching("right")
	if _grabbing:
		if not pinching:
			_grabbing = false
			return
		global_position = tip + _grab_offset
		_panel_ignored = 0.0
		return
	if not pinching:
		return
	var local := to_local(tip)
	var within := (
		absf(local.z) < grab_margin
		and absf(local.x) < SCREEN_SIZE.x * 0.5 + grab_margin
		and absf(local.y) < SCREEN_SIZE.y * 0.5 + grab_margin
	)
	if within and not _over_footer(local):
		_grabbing = true
		_grab_offset = global_position - tip
		_panel_ignored = 0.0


func _over_footer(local: Vector3) -> bool:
	var scale_y := SCREEN_SIZE.y / float(VIEWPORT_SIZE.y)
	var footer_top_local := SCREEN_SIZE.y * 0.5 - FOOTER_HEIGHT_PX * scale_y
	return local.y <= footer_top_local


func _process(delta: float) -> void:
	if not _chat_dirty or not visible:
		return
	_chat_elapsed += delta
	if _chat_elapsed < CHAT_RENDER_INTERVAL:
		return
	_chat_elapsed = 0.0
	_chat_dirty = false
	_render_conversation()
	if _viewport != null:
		_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE


func _park_panel(camera_position: Vector3, camera_forward: Vector3) -> void:
	var camera_right := _camera.global_transform.basis.x
	camera_right.y = 0.0
	if camera_right.length_squared() < 0.0001:
		camera_right = Vector3.RIGHT
	camera_right = camera_right.normalized()
	global_position = (
		camera_position
		+ camera_forward * parked_distance
		+ camera_right * parked_side_offset
		+ Vector3.DOWN * parked_drop
	)
	look_at(camera_position, Vector3.UP, true)


func _set_console_visible(value: bool) -> void:
	visible = value
	AppState.palm_console_open = value


func _hide_panel() -> void:
	if visible:
		_set_console_visible(false)
		_swipe_active = false


func _refresh_all(_unused: Variant = null) -> void:
	_refresh_header()
	_render_conversation()
	if _viewport != null and visible:
		_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE


func _refresh_header() -> void:
	var thread := AppState.get_thread(AppState.focused_thread_id)
	if thread == null:
		_title_label.text = "NO AGENT"
		_subtitle_label.text = "Focus an agent, then tap TALK"
	else:
		_title_label.text = thread.title.to_upper()
		_subtitle_label.text = "%s  ·  %s  ·  %s" % [
			AgentThread.status_label(thread.status),
			AppState.provider_name.to_upper(),
			AppState.connection_state.to_upper(),
		]
	var build := str(ProjectSettings.get_setting("application/config/version", "dev"))
	_build_label.text = "BUILD %s" % build
	var banner := AppState.update_banner.strip_edges()
	if not banner.is_empty():
		_subtitle_label.text += "  ·  %s" % banner.to_upper()


func _render_conversation() -> void:
	if _body == null:
		return
	var thread := AppState.get_thread(AppState.focused_thread_id)
	if thread == null:
		_body.text = "[center][color=#6b9aa5]Focus an agent to begin.[/color][/center]"
		return
	var lines: PackedStringArray = []
	for message in thread.messages:
		var speaker := "AGENT"
		var color := "#7bf58f"
		match message.role:
			AgentMessage.Role.USER:
				speaker = "YOU"
				color = "#55f5ff"
			AgentMessage.Role.TOOL:
				speaker = "TOOL"
				color = "#ffd166"
			AgentMessage.Role.SYSTEM:
				speaker = "SYS"
				color = "#6b9aa5"
		var content := message.content.strip_edges().replace("[", "[lb]")
		if message.is_streaming:
			content += " ▌"
		lines.append("[color=%s][b]%s[/b][/color]  %s" % [color, speaker, content])
	if lines.is_empty():
		lines.append("[color=#6b9aa5]No messages yet. Tap TALK and speak.[/color]")
	_body.text = "\n\n".join(lines)
	_refresh_voice_label()
	var working := thread.status == AgentThread.Status.WORKING
	if not thread.messages.is_empty() and thread.messages.back().is_streaming:
		working = true
	if working:
		_chat_follow = true
	if _chat_follow:
		_chat_scroll_line = maxi(0, _body.get_line_count() - 1)
		_body.scroll_to_line(_chat_scroll_line)


func _refresh_voice_label() -> void:
	if _voice_label == null:
		return
	match AppState.listening_state:
		SpeechService.STATE_LISTENING:
			_voice_label.text = "● LISTENING — speak, then pause"
			_voice_label.add_theme_color_override("font_color", Color(1.0, 0.45, 0.4))
		SpeechService.STATE_TRANSCRIBING:
			_voice_label.text = "… transcribing"
			_voice_label.add_theme_color_override("font_color", Color(1.0, 0.85, 0.4))
		_:
			_voice_label.text = ""


func _update_swipe() -> void:
	var sample := _hand_source.get_latest_hand_sample("right")
	if sample.is_empty():
		_swipe_active = false
		return
	var tip := sample.get("index_tip", Vector3.ZERO) as Vector3
	var local := to_local(tip)
	var half := SCREEN_SIZE * 0.6
	var on_surface := (
		absf(local.z) < 0.08
		and absf(local.x - SCREEN_CENTER.x) <= half.x
		and absf(local.y - SCREEN_CENTER.y) <= half.y
	)
	var position_2d := Vector2(local.x, local.y)
	# The footer is a button band: never treat touches there as scrolls, or a
	# poke's natural finger travel would cancel the tap.
	if _over_footer(local):
		_swipe_active = false
		return
	if on_surface:
		if not _swipe_active:
			_swipe_active = true
			_swipe_start = position_2d
			_scroll_anchor_y = position_2d.y
			_scroll_accumulator = 0.0
		else:
			# Once the finger is clearly dragging, cancel any pending button tap
			# so a scroll swipe can never trigger the footer controls.
			if position_2d.distance_to(_swipe_start) > 0.02 and _hand_source != null:
				_hand_source.cancel_touch_taps()
			var frame_dy := position_2d.y - _scroll_anchor_y
			_scroll_anchor_y = position_2d.y
			_scroll_chat_lines(frame_dy * CHAT_SCROLL_LINES_PER_METRE)
		_swipe_last = position_2d
		return
	_swipe_active = false


func _scroll_chat_lines(line_delta: float) -> void:
	if is_zero_approx(line_delta) or _body == null:
		return
	_scroll_accumulator += line_delta
	var whole := int(_scroll_accumulator)
	if whole == 0:
		return
	_scroll_accumulator -= float(whole)
	var last_line := maxi(0, _body.get_line_count() - 1)
	_chat_scroll_line = clampi(_chat_scroll_line + whole, 0, last_line)
	_body.scroll_to_line(_chat_scroll_line)
	_chat_follow = _chat_scroll_line >= last_line
	if _viewport != null and visible:
		_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE


func _on_focus_changed(_thread_id: String) -> void:
	_chat_follow = true
	_refresh_all()


func _on_thread_updated(_thread: AgentThread) -> void:
	if visible:
		_chat_dirty = true


func _on_provider_identity_changed(_provider: String, _model: String) -> void:
	_refresh_header()
