class_name ThreadPanel
extends Node3D

@export var user_rig_path: NodePath = ^"../UserRig"
@export var auto_present: bool = true
@export_range(0.8, 3.0, 0.05) var distance_from_user: float = 1.5
@export_range(-1.5, 1.5, 0.05) var horizontal_offset: float = 0.88
@export_range(-1.0, 1.0, 0.05) var vertical_offset: float = 0.04
@export_range(1, 20, 1) var max_visible_messages: int = 7
@export var room_anchor_registry_path: NodePath = ^"../RoomAnchorRegistry"

@onready var _title_label: Label3D = $TitleLabel
@onready var _body_label: Label3D = $BodyLabel
@onready var _hint_label: Label3D = $HintLabel
@onready var _eyebrow_label: Label3D = $EyebrowLabel
@onready var _sequence_label: Label3D = $SequenceLabel

var _user_rig: UserRig = null
var _camera: Camera3D = null
var _room_anchors: RoomAnchorRegistry = null
var _displayed_thread_id: String = ""
var _pages: Array[String] = []
var _page_index := 0
var _page_label: Label3D


func _ready() -> void:
	_user_rig = get_node_or_null(user_rig_path) as UserRig
	if _user_rig != null:
		_camera = _user_rig.get_camera()
	_room_anchors = get_node_or_null(room_anchor_registry_path) as RoomAnchorRegistry
	AppState.focused_thread_changed.connect(_on_focused_thread_changed)
	AppState.thread_updated.connect(_on_thread_updated)
	AppState.privacy_veil_changed.connect(_on_privacy_veil_changed)
	visible = false
	_build_pager()
	for child in get_children():
		if child is Label3D:
			child.render_priority = 4
			child.outline_render_priority = 3
	if not AppState.focused_thread_id.is_empty():
		open_thread(AppState.focused_thread_id)


func open_thread(thread_id: String) -> bool:
	if AppState.privacy_veil_active:
		visible = false
		return false
	var thread := AppState.get_thread(thread_id)
	if thread == null:
		return false
	if _displayed_thread_id != thread_id:
		_page_index = 0
	_displayed_thread_id = thread_id
	_place_in_reading_zone()
	_render_thread(thread)
	visible = true
	return true


func dismiss_panel() -> void:
	visible = false
	_displayed_thread_id = ""


func is_open() -> bool:
	return visible and not _displayed_thread_id.is_empty()


func get_displayed_thread_id() -> String:
	return _displayed_thread_id


func get_rendered_body_text() -> String:
	return _body_label.text


func _place_in_reading_zone() -> void:
	if _camera == null:
		return
	var camera_basis := _camera.global_transform.basis.orthonormalized()
	var local_offset := Vector3(horizontal_offset, vertical_offset, -distance_from_user)
	var panel_position := _camera.global_position + camera_basis * local_offset
	global_transform = Transform3D(camera_basis, panel_position)
	if _room_anchors != null:
		_room_anchors.register_anchor("thread_surface", "reading_zone", global_transform)


func _render_thread(thread: AgentThread) -> void:
	var status_text := AgentThread.status_label(thread.status)
	_title_label.text = "%s  ·  %s" % [thread.title, status_text]
	_eyebrow_label.text = "THREAD LINK // %s // %s" % [thread.id.right(6).to_upper(), status_text]
	_hint_label.text = "CODE TRACE // PINCH"
	_sequence_label.text = "MSG %02d // RX" % thread.messages.size()

	if thread.messages.is_empty():
		_body_label.text = "No messages yet."
		_pages = ["No messages yet."]
		_show_page()
		return

	var rendered_messages := PackedStringArray()
	var start_index := maxi(0, thread.messages.size() - max_visible_messages)
	for index in range(start_index, thread.messages.size()):
		var message := thread.messages[index]
		var content := _compact_code_blocks(message.content)
		if content.is_empty() and message.is_streaming:
			content = "…"
		if message.is_streaming:
			content += "  ▌"
		rendered_messages.append("%s\n%s" % [_role_label(message.role), content])
	_paginate("\n\n".join(rendered_messages))


func turn_page(direction: int) -> void:
	if not visible or AppState.privacy_veil_active:
		return
	_page_index = clampi(_page_index + direction, 0, maxi(0, _pages.size() - 1))
	_show_page()


func _paginate(text: String) -> void:
	var paragraph := TextParagraph.new()
	paragraph.width = _body_label.width
	paragraph.break_flags = TextServer.BREAK_MANDATORY | TextServer.BREAK_WORD_BOUND | TextServer.BREAK_ADAPTIVE
	var font := _body_label.font if _body_label.font != null else ThemeDB.fallback_font
	paragraph.add_string(text, font, _body_label.font_size)
	_pages.clear()
	var page_start := 0
	var page_end := 0
	var height := 0.0
	# The text region ends above the pager, so messages never cross controls.
	var available_height := 0.44 / _body_label.pixel_size
	for line in range(paragraph.get_line_count()):
		var line_range := paragraph.get_line_range(line)
		var line_height := paragraph.get_line_size(line).y
		if height + line_height > available_height and page_end > page_start:
			_pages.append(text.substr(page_start, page_end - page_start).strip_edges())
			page_start = line_range.x
			height = 0.0
		page_end = line_range.y
		height += line_height
	if page_end > page_start:
		_pages.append(text.substr(page_start, page_end - page_start).strip_edges())
	_page_index = clampi(_page_index, 0, maxi(0, _pages.size() - 1))
	_show_page()


func _show_page() -> void:
	_body_label.text = _pages[_page_index] if not _pages.is_empty() else "No messages yet."
	if _page_label != null:
		_page_label.text = "PAGE %d / %d" % [_page_index + 1, maxi(1, _pages.size())]


func _build_pager() -> void:
	_page_label = Label3D.new()
	_page_label.position = Vector3(0.0, -0.267, 0.08)
	_page_label.pixel_size = 0.0025
	_page_label.font_size = 9
	_page_label.modulate = Color(0.3, 0.8, 0.88)
	_page_label.no_depth_test = true
	add_child(_page_label)
	for direction in [-1, 1]:
		var target := SpatialActionTarget.new()
		target.target_id = "ui:transcript_previous" if direction < 0 else "ui:transcript_next"
		target.collision_layer = 2
		target.collision_mask = 0
		target.monitoring = false
		target.position = Vector3(float(direction) * 0.35, -0.267, 0.07)
		var collision := CollisionShape3D.new()
		var shape := BoxShape3D.new()
		shape.size = Vector3(0.25, 0.06, 0.035)
		collision.shape = shape
		target.add_child(collision)
		var label := Label3D.new()
		label.text = "< PREVIOUS" if direction < 0 else "NEXT >"
		label.pixel_size = 0.0025
		label.font_size = 10
		label.modulate = Color(0.3, 0.95, 1.0)
		label.no_depth_test = true
		label.render_priority = 4
		label.outline_render_priority = 3
		target.add_child(label)
		add_child(target)


func _compact_code_blocks(content: String) -> String:
	var compacted := content
	var search_from := 0
	while true:
		var opening := compacted.find("```", search_from)
		if opening < 0:
			break
		var header_end := compacted.find("\n", opening + 3)
		if header_end < 0:
			break
		var language := compacted.substr(opening + 3, header_end - opening - 3).strip_edges()
		var closing := compacted.find("```", header_end + 1)
		var code_end := closing if closing >= 0 else compacted.length()
		var code := compacted.substr(header_end + 1, code_end - header_end - 1).strip_edges()
		var line_count := 0 if code.is_empty() else code.count("\n") + 1
		var marker := "[CODE TRACE // %s // %02d LINES]" % [
			language.to_upper() if not language.is_empty() else "TEXT",
			line_count,
		]
		var replace_end := closing + 3 if closing >= 0 else compacted.length()
		compacted = compacted.substr(0, opening) + marker + compacted.substr(replace_end)
		search_from = opening + marker.length()
	return compacted.strip_edges()


func _role_label(role: AgentMessage.Role) -> String:
	match role:
		AgentMessage.Role.ASSISTANT:
			return "AGENT"
		AgentMessage.Role.SYSTEM:
			return "SYSTEM"
		AgentMessage.Role.TOOL:
			return "TOOL"
		_:
			return "YOU"


func _on_focused_thread_changed(thread_id: String) -> void:
	if thread_id.is_empty():
		dismiss_panel()
	elif auto_present:
		open_thread(thread_id)


func _on_thread_updated(thread: AgentThread) -> void:
	if visible and thread.id == _displayed_thread_id:
		_render_thread(thread)


func _on_privacy_veil_changed(value: bool) -> void:
	if value:
		visible = false
	elif not AppState.focused_thread_id.is_empty():
		open_thread(AppState.focused_thread_id)
