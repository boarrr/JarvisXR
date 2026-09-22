class_name PalmConsole
extends Node3D

## Left-hand master panel.
##
## Pages (swipe horizontally on the screen, or pull the fingertip off and
## re-contact): CHAT shows the focused agent conversation, CODE shows the latest
## fenced code, SYSTEM keeps the original hand-only actions. All controls are
## physical-touch targets handled by OpenXRInteractionSource poke input.

const SPATIAL_TARGET_SCRIPT := preload("res://interaction/spatial_action_target.gd")

const PAGE_CHAT := 0
const PAGE_CODE := 1
const PAGE_SYSTEM := 2
const PAGE_COUNT := 3
const PAGE_TITLES := ["CHAT", "CODE", "SYSTEM"]

const SCREEN_CENTER := Vector2(0.0, 0.0)
const SCREEN_SIZE := Vector2(0.56, 0.42)
const VIEWPORT_SIZE := Vector2i(640, 480)
const BUTTON_HEIGHT_PX := 62.0
const HEADER_HEIGHT_PX := 52.0
const FOOTER_ROWS := 2
const FOOTER_HEIGHT_PX := BUTTON_HEIGHT_PX * FOOTER_ROWS + 22.0

# Label, semantic target, and the existing Area3D node that carries it (empty
# node means the panel creates its own touch target).
const SYSTEM_BUTTONS := [
	["NEXT AGENT", "palm:focus_next", "FocusTarget"],
	["NEW AGENT", "palm:new_agent", ""],
	["DISMISS", "palm:dismiss", "DismissTarget"],
	["UNDO", "palm:undo", ""],
	["COGNITION", "palm:cognition_toggle", "CognitionTarget"],
	["MISSION MAP", "palm:mission_toggle", "MissionTarget"],
	["PRIVACY VEIL", "palm:privacy_toggle", "PrivacyTarget"],
]

const CHAT_BUTTONS := [
	["CONTINUE", "quick:continue"],
	["SUMMARIZE", "quick:summarize"],
	["EXPLAIN", "quick:explain_code"],
	["PRIVACY", "quick:privacy_review"],
]

@export var hand_source_path: NodePath = ^"../XRRuntime/OpenXRInteractionSource"
@export var user_rig_path: NodePath = ^"../UserRig"
@export_range(0.01, 0.35, 0.01) var palm_offset_metres: float = 0.20
@export_range(0.05, 1.0, 0.05) var pose_smoothing: float = 0.38
@export_range(0.3, 1.0, 0.01) var console_scale: float = 0.8
@export_range(0.15, 0.8, 0.01) var min_display_distance: float = 0.25
@export_range(0.3, 1.2, 0.01) var max_display_distance: float = 0.7
@export_range(0.0, 0.4, 0.01) var below_eye_minimum: float = 0.05
@export_range(0.5, 1.0, 0.01) var gaze_threshold: float = 0.86
@export_range(0.0, 1.5, 0.05) var show_delay_seconds: float = 0.3
# Once summoned the panel parks in front of the user instead of following the
# hand, so a single (right) hand can operate it without close-range tracking.
@export_range(0.3, 1.2, 0.01) var parked_distance: float = 0.62
@export_range(-0.6, 0.6, 0.01) var parked_side_offset: float = -0.14
@export_range(0.0, 0.8, 0.01) var parked_drop: float = 0.30
@export_range(0.0, 1.0, 0.05) var parked_keep_gaze: float = 0.35
@export_range(0.5, 10.0, 0.5) var parked_ignore_seconds: float = 2.5

@onready var _status_label: Label3D = $StatusLabel
@onready var _provider_label: Label3D = $ProviderLabel
@onready var _summary_label: Label3D = $SummaryLabel

var _hand_source: OpenXRInteractionSource = null
var _user_rig: UserRig = null
var _camera: Camera3D = null
var _dwell := 0.0

var _viewport: SubViewport = null
var _screen: MeshInstance3D = null
var _page_title: Label = null
var _body: RichTextLabel = null
var _page_label: Label = null
var _buttons: Dictionary = {}
var _dynamic_targets: Array[Area3D] = []
var _system_targets: Array[Area3D] = []
var _page_buttons: Dictionary = {PAGE_CHAT: [], PAGE_CODE: [], PAGE_SYSTEM: []}
var _panel_ignored := 0.0
var _page := PAGE_CHAT
var _chat_offset := 0
var _code_offset := 0
var _swipe_active := false
var _swipe_start := Vector2.ZERO
var _swipe_last := Vector2.ZERO


func _ready() -> void:
	_hand_source = get_node_or_null(hand_source_path) as OpenXRInteractionSource
	_user_rig = get_node_or_null(user_rig_path) as UserRig
	if _user_rig != null:
		_camera = _user_rig.get_camera()
	_build_screen()
	_prepare_system_targets()
	AppState.connection_state_changed.connect(_refresh_telemetry)
	AppState.provider_identity_changed.connect(_on_provider_identity_changed)
	AppState.listening_state_changed.connect(_refresh_telemetry)
	AppState.focused_thread_changed.connect(_on_state_changed)
	AppState.thread_updated.connect(_on_thread_updated)
	AppState.orb_layout_changed.connect(_on_layout_changed)
	AppState.privacy_veil_changed.connect(_on_veil_changed)
	scale = Vector3.ONE * console_scale
	_set_console_visible(false)
	_summary_label.visible = false
	_refresh_telemetry()
	_refresh_screen()


func _physics_process(delta: float) -> void:
	if (
		AppState.ui_mode not in ["xr_hands", "hand_lab"]
		or _hand_source == null
		or _user_rig == null
		or AppState.privacy_veil_active
	):
		_dwell = 0.0
		_hide_panel()
		return
	if _camera == null:
		_camera = _user_rig.get_camera()
	if _camera == null:
		_hide_panel()
		return

	var camera_position := _camera.global_position
	var camera_forward := -_camera.global_transform.basis.z
	camera_forward.y = 0.0
	if camera_forward.length_squared() < 0.0001:
		camera_forward = Vector3.FORWARD
	camera_forward = camera_forward.normalized()

	if not visible:
		# The console opens only on the deliberate double-pinch (the SUMMON
		# event). Auto-summon from an open palm was removed: a flickering
		# tracker made it appear on its own and it fought the user.
		_dwell = 0.0
		return

	# Parked: hold position until closed or ignored for a while.
	var to_panel := global_position - camera_position
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
	_update_swipe()


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
	_panel_ignored = 0.0
	_set_console_visible(false)
	if _viewport != null:
		_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED


func get_screen_viewport() -> SubViewport:
	return _viewport


func summon_now() -> void:
	# Deliberate summon (double-pinch) or a repeat press closes the console.
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
	if _viewport != null:
		_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	_refresh_screen()


func handle_screen_action(target_id: String) -> void:
	match target_id:
		"palm_screen:code_up":
			_code_offset = maxi(0, _code_offset - 4)
		"palm_screen:code_down":
			_code_offset += 4
		"palm_screen:code_top":
			_code_offset = 0
		"palm_screen:code_bottom":
			_code_offset = 100000
		"palm_screen:next_page":
			_change_page(1)
			return
		"palm_screen:previous_page":
			_change_page(-1)
			return
	_refresh_screen()


func _build_screen() -> void:
	_viewport = SubViewport.new()
	_viewport.size = VIEWPORT_SIZE
	_viewport.transparent_bg = true
	# The palm page only changes on focus/thread/page events, so render on
	# demand instead of every frame to protect the headset frame budget.
	_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child(_viewport)

	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_viewport.add_child(root)

	var background := PanelContainer.new()
	background.set_anchors_preset(Control.PRESET_FULL_RECT)
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.006, 0.03, 0.045, 0.94)
	style.border_color = Color(0.02, 0.8, 0.98, 0.9)
	style.set_border_width_all(3)
	style.set_corner_radius_all(6)
	background.add_theme_stylebox_override("panel", style)
	background.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(background)

	_page_title = Label.new()
	_page_title.position = Vector2(18, 10)
	_page_title.size = Vector2(VIEWPORT_SIZE.x - 120, 34)
	_page_title.add_theme_font_size_override("font_size", 26)
	_page_title.add_theme_color_override("font_color", Color(0.33, 0.96, 1.0))
	_page_title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(_page_title)

	_page_label = Label.new()
	_page_label.position = Vector2(VIEWPORT_SIZE.x - 100, 14)
	_page_label.size = Vector2(84, 26)
	_page_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_page_label.add_theme_font_size_override("font_size", 18)
	_page_label.add_theme_color_override("font_color", Color(0.42, 0.62, 0.68))
	_page_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(_page_label)

	_body = RichTextLabel.new()
	_body.position = Vector2(16, HEADER_HEIGHT_PX)
	_body.size = Vector2(VIEWPORT_SIZE.x - 32, VIEWPORT_SIZE.y - HEADER_HEIGHT_PX - FOOTER_HEIGHT_PX)
	_body.bbcode_enabled = true
	_body.scroll_active = false
	_body.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_body.add_theme_font_size_override("normal_font_size", 19)
	_body.add_theme_color_override("default_color", Color(0.82, 0.94, 0.98))
	root.add_child(_body)

	# A slim dark backing gives the panel depth and keeps text legible against
	# a bright passthrough room without restoring the old glass instrument look.
	var backing_material := StandardMaterial3D.new()
	backing_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	backing_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	backing_material.albedo_color = Color(0.01, 0.03, 0.05, 0.92)
	backing_material.no_depth_test = true
	var backing := MeshInstance3D.new()
	var backing_quad := QuadMesh.new()
	backing_quad.size = SCREEN_SIZE * Vector2(1.06, 1.08)
	backing_quad.material = backing_material
	backing.mesh = backing_quad
	backing.position = Vector3(SCREEN_CENTER.x, SCREEN_CENTER.y, 0.015)
	backing.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(backing)

	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.albedo_texture = _viewport.get_texture()
	material.no_depth_test = true
	_screen = MeshInstance3D.new()
	var quad := QuadMesh.new()
	quad.size = SCREEN_SIZE
	quad.material = material
	_screen.mesh = quad
	_screen.position = Vector3(SCREEN_CENTER.x, SCREEN_CENTER.y, 0.02)
	_screen.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_screen)

	_build_chat_targets()
	_build_code_targets()
	_build_system_buttons()
	# The screen is the panel: retire the legacy 3D glass, glyph buttons and
	# label layers so the palm shows one clean surface.
	for child in get_children():
		if child == _screen or child == backing:
			continue
		if child is MeshInstance3D or child is Label3D:
			child.visible = false


func _build_system_buttons() -> void:
	for index in range(SYSTEM_BUTTONS.size()):
		var entry: Array = SYSTEM_BUTTONS[index]
		var rect := _grid_rect(index, 4, FOOTER_ROWS)
		var button := _make_button(rect, str(entry[0]))
		(_page_buttons[PAGE_SYSTEM] as Array).append(button)
		if str(entry[2]).is_empty():
			_system_targets.append(_make_target(str(entry[1]), rect))


func _grid_rect(index: int, columns: int, rows: int) -> Rect2:
	var column := index % columns
	var row := index / columns
	var width := (VIEWPORT_SIZE.x - 32.0 - (columns - 1) * 8.0) / float(columns)
	var top := VIEWPORT_SIZE.y - (rows - row) * BUTTON_HEIGHT_PX
	return Rect2(
		Vector2(16.0 + column * (width + 8.0), top + 4.0),
		Vector2(width, BUTTON_HEIGHT_PX - 8.0)
	)


func _build_chat_targets() -> void:
	for index in range(CHAT_BUTTONS.size()):
		var entry: Array = CHAT_BUTTONS[index]
		var rect := _grid_rect(
			index + (FOOTER_ROWS - 1) * CHAT_BUTTONS.size(),
			CHAT_BUTTONS.size(),
			FOOTER_ROWS
		)
		var button := _make_button(rect, str(entry[0]))
		(_page_buttons[PAGE_CHAT] as Array).append(button)
		_dynamic_targets.append(_make_target(str(entry[1]), rect))


func _build_code_targets() -> void:
	var labels := ["UP", "DOWN", "TOP", "BOTTOM"]
	var ids := [
		"palm_screen:code_up",
		"palm_screen:code_down",
		"palm_screen:code_top",
		"palm_screen:code_bottom",
	]
	for index in range(labels.size()):
		var rect := _grid_rect(
			index + (FOOTER_ROWS - 1) * labels.size(),
			labels.size(),
			FOOTER_ROWS
		)
		var button := _make_button(rect, labels[index])
		(_page_buttons[PAGE_CODE] as Array).append(button)
		_dynamic_targets.append(_make_target(ids[index], rect))


func _make_button(rect: Rect2, text: String) -> PanelContainer:
	if _viewport == null:
		return null
	var root := _viewport.get_child(0) as Control
	if root == null:
		return null
	var panel := PanelContainer.new()
	panel.position = rect.position
	panel.size = rect.size
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.02, 0.29, 0.35, 0.95)
	style.border_color = Color(0.33, 0.96, 1.0, 0.9)
	style.set_border_width_all(2)
	style.set_corner_radius_all(4)
	panel.add_theme_stylebox_override("panel", style)
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(panel)
	var label := Label.new()
	label.text = text
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", 17)
	label.add_theme_color_override("font_color", Color(0.85, 1, 1, 1))
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(label)
	_buttons[text] = panel
	return panel


func _prepare_system_targets() -> void:
	for entry in SYSTEM_BUTTONS:
		var node_name := str(entry[2])
		if node_name.is_empty():
			continue
		var target := get_node_or_null(node_name) as Area3D
		if target == null:
			continue
		for child in target.get_children():
			if child is MeshInstance3D or child is Label3D:
				child.visible = false


func _refresh_screen() -> void:
	if _body == null:
		return
	_page_title.text = "%s  ·  %s" % [PAGE_TITLES[_page], _focused_label()]
	_page_label.text = "%d/%d" % [_page + 1, PAGE_COUNT]
	match _page:
		PAGE_CHAT:
			_render_chat()
		PAGE_CODE:
			_render_code()
		_:
			_render_system()
	_refresh_target_visibility()
	if _viewport != null and visible:
		_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE


func _render_chat() -> void:
	var thread := AppState.get_thread(AppState.focused_thread_id)
	if thread == null:
		_body.text = "[color=#6b9aa5]Touch an agent orb to select it.[/color]"
		return
	var lines: PackedStringArray = []
	var messages := thread.messages
	var start := clampi(messages.size() - 8 - _chat_offset, 0, messages.size())
	var end := clampi(messages.size() - _chat_offset, 0, messages.size())
	if start >= end and messages.size() > 0:
		start = maxi(0, end - 8)
	for index in range(start, end):
		var message := messages[index]
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
		if content.length() > 320:
			content = content.substr(0, 317) + "..."
		lines.append("[color=%s]%s[/color] %s" % [color, speaker, content])
	if lines.is_empty():
		lines.append("[color=#6b9aa5]No messages yet. Use a quick action below.[/color]")
	if _chat_offset > 0:
		lines.append("")
		lines.append("[color=#6b9aa5]swipe up for newer messages[/color]")
	_body.text = "\n\n".join(lines)


func _render_code() -> void:
	var thread := AppState.get_thread(AppState.focused_thread_id)
	var code := ""
	if thread != null:
		for message_index in range(thread.messages.size() - 1, -1, -1):
			var message := thread.messages[message_index]
			if message.role not in [AgentMessage.Role.ASSISTANT, AgentMessage.Role.TOOL]:
				continue
			var content := message.content
			var marker := content.rfind("```")
			if marker < 0:
				continue
			var opening := content.rfind("```", marker - 1)
			if opening < 0:
				continue
			var header_end := content.find("\n", opening + 3)
			if header_end < 0:
				continue
			var candidate := content.substr(header_end + 1, marker - header_end - 1).strip_edges()
			if not candidate.is_empty():
				code = candidate
				break
	if code.is_empty():
		_body.text = "[color=#6b9aa5]No fenced code has been emitted for this agent yet.[/color]"
		return
	var raw_lines := code.split("\n")
	var max_lines := 12
	_code_offset = clampi(_code_offset, 0, maxi(0, raw_lines.size() - max_lines))
	var lines: PackedStringArray = []
	for index in range(_code_offset, mini(raw_lines.size(), _code_offset + max_lines)):
		lines.append(
			"[color=#6b9aa5]%02d[/color]  %s" % [index + 1, raw_lines[index].replace("[", "[lb]")]
		)
	if raw_lines.size() > max_lines:
		lines.append("[color=#6b9aa5]--- %d of %d lines ---[/color]" % [
			mini(raw_lines.size(), _code_offset + max_lines), raw_lines.size()
		])
	_body.text = "\n".join(lines)


func _render_system() -> void:
	var lines: PackedStringArray = []
	lines.append("[color=#55f5ff]Hand-only actions[/color]")
	lines.append("Touch a button below with your right index finger.")
	lines.append("")
	if not AppState.mcp_servers.is_empty():
		lines.append("MCP: %s" % ", ".join(PackedStringArray(AppState.mcp_servers)))
	var worktree := AppState.get_run_workspace(AppState.focused_thread_id)
	if not worktree.is_empty():
		lines.append("branch: %s" % str(worktree.get("branch", "")))
	lines.append("workspaces: %d · tools: %d" % [AppState.workspaces.size(), AppState.tool_catalog.size()])
	_body.text = "\n".join(lines)


func _refresh_target_visibility() -> void:
	var system_page := _page == PAGE_SYSTEM
	for entry in SYSTEM_BUTTONS:
		var node_name := str(entry[2])
		if node_name.is_empty():
			continue
		var target := get_node_or_null(node_name) as Area3D
		if target == null:
			continue
		if system_page:
			target.position = _button_local_position(str(entry[0]), target.position)
			target.visible = true
		else:
			target.visible = false
	for target in _system_targets:
		target.visible = system_page
	for page in _page_buttons:
		var page_visible: bool = page == _page
		for button in _page_buttons[page]:
			if is_instance_valid(button):
				button.visible = page_visible
	for index in range(_dynamic_targets.size()):
		var target := _dynamic_targets[index]
		var chat_target := index < CHAT_BUTTONS.size()
		target.visible = (_page == PAGE_CHAT) if chat_target else (_page == PAGE_CODE)


func _button_local_position(button_text: String, fallback: Vector3) -> Vector3:
	var panel: PanelContainer = _buttons.get(button_text)
	if panel == null:
		return fallback
	return _rect_to_local(Rect2(panel.position, panel.size))


func _rect_to_local(rect: Rect2) -> Vector3:
	var center := rect.position + rect.size * 0.5
	var scale_x := SCREEN_SIZE.x / float(VIEWPORT_SIZE.x)
	var scale_y := SCREEN_SIZE.y / float(VIEWPORT_SIZE.y)
	return Vector3(
		SCREEN_CENTER.x + (center.x - VIEWPORT_SIZE.x * 0.5) * scale_x,
		SCREEN_CENTER.y - (center.y - VIEWPORT_SIZE.y * 0.5) * scale_y,
		0.03
	)


func _make_target(target_id: String, rect: Rect2) -> Area3D:
	var target := Area3D.new()
	target.set_script(SPATIAL_TARGET_SCRIPT)
	target.set("target_id", target_id)
	target.collision_layer = 2
	target.collision_mask = 0
	target.monitoring = false
	target.add_to_group("interactable")
	var shape := BoxShape3D.new()
	var scale_x := SCREEN_SIZE.x / float(VIEWPORT_SIZE.x)
	var scale_y := SCREEN_SIZE.y / float(VIEWPORT_SIZE.y)
	shape.size = Vector3(
		maxf(rect.size.x * scale_x, 0.01),
		maxf(rect.size.y * scale_y, 0.01),
		0.05
	)
	var collision := CollisionShape3D.new()
	collision.shape = shape
	target.add_child(collision)
	target.position = _rect_to_local(rect)
	target.visible = false
	add_child(target)
	return target


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
	if on_surface:
		if not _swipe_active:
			_swipe_active = true
			_swipe_start = position_2d
		_swipe_last = position_2d
		return
	if not _swipe_active:
		return
	_swipe_active = false
	var delta := _swipe_last - _swipe_start
	if absf(delta.x) > 0.05 and absf(delta.x) > absf(delta.y):
		_change_page(-1 if delta.x > 0.0 else 1)
	elif absf(delta.y) > 0.05:
		_scroll_page(1 if delta.y > 0.0 else -1)


func _change_page(direction: int) -> void:
	_page = posmod(_page + direction, PAGE_COUNT)
	_chat_offset = 0
	_code_offset = 0
	_refresh_screen()


func _scroll_page(direction: int) -> void:
	if _page == PAGE_CHAT:
		_chat_offset = maxi(0, _chat_offset + direction)
	elif _page == PAGE_CODE:
		_code_offset = maxi(0, _code_offset + direction)
	_refresh_screen()


func _focused_label() -> String:
	var thread := AppState.get_thread(AppState.focused_thread_id)
	if thread == null:
		return "NO AGENT"
	return "%s / %s" % [thread.title.to_upper(), AgentThread.status_label(thread.status).to_upper()]


func _refresh_telemetry(_unused: Variant = null) -> void:
	var link := AppState.connection_state.to_upper()
	var speech := "MIC %s" % AppState.listening_state.to_upper()
	_status_label.text = "LINK %s  //  %s" % [link, speech]
	_provider_label.text = "%s  //  %s" % [
		AppState.provider_name.to_upper(),
		AppState.model_name.to_upper(),
	]


func _on_provider_identity_changed(_provider: String, _model: String) -> void:
	_refresh_telemetry()


func _on_state_changed(_thread_id: String) -> void:
	_chat_offset = 0
	_refresh_screen()


func _on_thread_updated(_thread: AgentThread) -> void:
	_refresh_screen()


func _on_layout_changed(_thread_id: String) -> void:
	_refresh_screen()


func _on_veil_changed(_value: bool) -> void:
	_refresh_telemetry()
