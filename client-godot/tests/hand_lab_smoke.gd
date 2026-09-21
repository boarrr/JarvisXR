extends Node

var _failed := false


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	var main := (load("res://scenes/app/main.tscn") as PackedScene).instantiate()
	add_child(main)
	var lab := main.get_node("HandLab") as HandLab
	if lab.source == null:
		var hand_source := lab.start(main)
		AppState.ui_mode = "hand_lab"
		ServiceRegistry.input_router.register_source(hand_source)
		(main.get_node("InteractionManager") as InteractionManager).set_interaction_source(hand_source)
	var source := lab.source
	source.set_physics_process(false)
	var manager := main.get_node("InteractionManager") as InteractionManager
	manager.set_physics_process(false)
	var viewer := main.get_node("CodeViewer") as CodeViewer
	var camera := source.camera
	_check(get_viewport().get_camera_3d() == camera, "visible desktop camera is the same camera used for hand rays")
	source.cursor = get_viewport().get_visible_rect().size * 0.5
	source.simulate_tick()
	_check(source.has_tracking_data() and not source.get_pointer_state().is_selecting, "open synthetic joints establish tracking")
	_check(source.get_latest_hand_sample("left").has("palm_transform"), "left palm pose reaches the real console")
	source.pinching = true
	source.simulate_tick()
	_check(source.get_pointer_state().is_selecting, "synthetic thumb-index distance triggers production pinch logic")
	source.release_gestures()
	var down := InputEventMouseButton.new()
	down.button_index = MOUSE_BUTTON_LEFT
	down.pressed = true
	var up := InputEventMouseButton.new()
	up.button_index = MOUSE_BUTTON_LEFT
	up.pressed = false
	source._unhandled_input(down)
	source._unhandled_input(up)
	source._physics_process(0.016)
	_check(source.get_pointer_state().is_selecting, "sub-frame click remains pinched for one physics tick")
	source._physics_process(0.016)
	_check(not source.get_pointer_state().is_selecting, "queued click release reaches the next tick")

	# Pick a real collision target with the synthesized camera ray.
	var orb := (main.get_node("OrbManager") as OrbManager).get_orb("thread_demo")
	for frame in range(50):
		await get_tree().physics_frame
	source.cursor = camera.unproject_position(orb.global_position)
	source.simulate_tick()
	manager._physics_process(0.016)
	source.pinching = true
	source.simulate_tick()
	manager._physics_process(0.016)
	_check(AppState.focused_thread_id == "thread_demo", "raycast plus pinch focuses an actual orb")
	source.release_gestures()
	# An invisible panel between the hand and the orb must not eat the ray.
	var blocker := SpatialActionTarget.new()
	blocker.target_id = "test:hidden"
	blocker.collision_layer = 2
	blocker.collision_mask = 0
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(0.2, 0.2, 0.05)
	shape.shape = box
	blocker.add_child(shape)
	main.add_child(blocker)
	blocker.global_position = camera.global_position.lerp(orb.global_position, 0.6)
	blocker.visible = false
	await get_tree().physics_frame
	var hit := manager._cast_pointer_ray(source.get_pointer_state())
	_check(manager._target_id_from_hit(hit) == "thread_demo", "hidden collision geometry does not occlude an agent")
	blocker.queue_free()
	source.tracking_enabled = false
	# Tracking loss is debounced: hold for the grace window before the hover
	# and pointer state are cleared.
	for _frame in range(32):
		source._physics_process(0.016)
	manager._physics_process(0.016)
	_check(AppState.hovered_target_id.is_empty(), "tracking loss clears the old target after the grace window")
	source.tracking_enabled = true
	source.send_action("palm:focus_next")
	source.send_action("palm:focus_next")
	# The palm toolbar no longer exposes a code-trace button; the viewer opens
	# on demand so scroll and two-hand manipulation stay covered.
	viewer.open_focused_thread()
	_check(viewer.is_open(), "code trace opens on demand")
	await get_tree().process_frame
	await get_tree().process_frame
	source.submit_pinch_scroll(-1.0)
	_check(viewer._code_edit.scroll_vertical > 0.0, "long demo allows real code scrolling")
	viewer.go_top()
	var code_transform := viewer.global_transform
	source.set_hover_target_id("ui:code_surface")
	source.cursor = camera.unproject_position(viewer.global_position)
	source.pinching = true
	source.two_hands = true
	source.simulate_tick()
	source._update_bimanual_gesture()
	source.cursor += Vector2(70, -25)
	source.spread = 0.42
	source.twist = 0.2
	source.simulate_tick()
	source._update_bimanual_gesture()
	_check(viewer.global_position.distance_to(code_transform.origin) > 0.01, "paired joints move the code surface")
	_check(viewer.scale.x > 1.1, "increased hand separation scales the code surface")
	source._notification(NOTIFICATION_APPLICATION_FOCUS_OUT)
	_check(not source.get_pointer_state().is_selecting and not viewer._bimanual_active, "window focus loss ends the grab and releases pinch")
	source._notification(NOTIFICATION_APPLICATION_FOCUS_IN)
	source.send_action("palm:privacy_toggle")
	var focus_before := AppState.focused_thread_id
	source.send_action("palm:focus_next")
	_check(AppState.focused_thread_id == focus_before and not viewer.visible, "lab toolbar cannot bypass privacy")
	_check(not main.get_node("ReactorField").visible, "privacy conceals reactive field")
	_check(not (main.get_node("DesktopComposer") as DesktopComposer).begin_editing(), "typing cannot reopen hidden content during privacy")
	source.send_action("palm:privacy_toggle")
	(main.get_node("BackendBridge/FakeBackendTransport") as FakeBackendTransport).advance_streams(10.0)
	var router := main.get_node("CommandRouter") as CommandRouter
	_check(router.submit_text("/tool note Hand Lab test"), "local demo requests explicit tool consent")
	source.send_action("palm:focus_next")
	_check(AppState.focused_thread_id == focus_before, "lab shortcut cannot bypass an approval gate")
	_check(not (main.get_node("DesktopComposer") as DesktopComposer).begin_editing(), "approval blocks composer")
	source.send_action("approval:deny")
	_check(AppState.approval_requests.is_empty(), "explicit denial still works through the hand source")
	var panel := main.get_node("ThreadPanel") as ThreadPanel
	panel._paginate("Long transcript with preserved words and explicit paging. ".repeat(80))
	_check(panel._pages.size() > 1, "long transcripts paginate instead of overflowing the glass")
	for page in panel._pages:
		var paragraph := TextParagraph.new()
		paragraph.width = panel._body_label.width
		paragraph.add_string(page, ThemeDB.fallback_font, panel._body_label.font_size)
		_check(paragraph.get_size().y <= 0.44 / panel._body_label.pixel_size + 1.0, "every transcript page fits above its controls")
	source.send_action("ui:transcript_next")
	_check(panel._page_index == 1, "hand action turns transcript pages")
	source.send_action("ui:transcript_previous")
	_check(panel._page_index == 0, "previous hand action restores the prior page")
	panel._render_thread(AppState.get_thread(AppState.focused_thread_id))
	var cognition := main.get_node("CognitionLayer") as CognitionLayer
	cognition._follow_focused_orb(1.0)
	_check(cognition.global_basis.z.dot((camera.global_position - cognition.global_position).normalized()) > 0.9, "cognition labels face the user with their readable side")
	var composer := main.get_node("DesktopComposer") as DesktopComposer
	composer.begin_editing()
	composer.end_editing()
	_check(Input.mouse_mode == Input.MOUSE_MODE_VISIBLE, "closing composer preserves lab cursor")
	var field := main.get_node("ReactorField") as ReactorField
	field.set_quality(2)
	_check(field._motes.multimesh.visible_instance_count == 3200, "ultra density is bounded")
	AppState.ui_mode = "xr_hands"
	_check(not field.visible and not field.is_processing(), "desktop effects stop in real XR")
	AppState.ui_mode = "hand_lab"
	lab._adapt_quality(40.0)
	lab._adapt_quality(40.0)
	lab._adapt_quality(40.0)
	lab._adapt_quality(40.0)
	_check(get_viewport().scaling_3d_scale < 1.0, "sustained slow frames lower desktop resolution")

	if "--capture-lab" in OS.get_cmdline_user_args():
		source.set_physics_process(true)
		manager.set_physics_process(true)
		lab._apply_quality(1)
		viewer.close()
		AppState.focus_thread("")
		for frame in range(90):
			await get_tree().process_frame
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png(ProjectSettings.globalize_path("res://../hand-lab-preview.png"))
		print("[PERF] Idle lab: %s" % lab._metrics.text)
		AppState.focus_thread("thread_debug_03")
		viewer.open_focused_thread()
		source.palm_visible = false
		lab._guide_panel.visible = false
		(main.get_node("MissionTopology") as MissionTopology).toggle_enabled()
		for frame in range(600):
			await get_tree().process_frame
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png(ProjectSettings.globalize_path("res://../hand-lab-code-preview.png"))
		print("[PERF] Code/cognition/mission workspace: %s" % lab._metrics.text)
		print("[TEST] Hand Lab screenshot saved")
	if not _failed:
		print("[TEST] Hand Lab joint input, raycast, bimanual, privacy and performance checks passed")
	main.queue_free()
	await get_tree().process_frame
	get_tree().quit(1 if _failed else 0)


func _check(condition: bool, description: String) -> void:
	if not condition:
		_failed = true
		push_error("[TEST] Failed: %s" % description)
