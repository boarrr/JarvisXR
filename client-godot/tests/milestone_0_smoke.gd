extends Node

const EPSILON := 0.001
var _failed := false


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	var main_scene := load("res://scenes/app/main.tscn") as PackedScene
	_check(main_scene != null, "main scene loads")

	var main := main_scene.instantiate()
	add_child(main)

	var rig := main.get_node("UserRig") as UserRig
	var overlay := main.get_node("DebugOverlay") as DebugOverlay
	_check(rig != null, "UserRig exists")
	_check(overlay != null, "DebugOverlay exists")
	_check(absf(rig.global_position.y - 1.65) < EPSILON, "eye height is 1.65 m")
	_check(rig.get_interaction_source().is_available(), "desktop source is available")
	_check(ServiceRegistry.input_router.get_active_source() == rig.get_interaction_source(), "desktop source is active through InputRouter")

	var start_position := rig.global_position
	Input.action_press("move_forward")
	rig._process(1.0)
	Input.action_release("move_forward")
	_check(rig.global_position.z < start_position.z - 3.0, "forward movement follows camera yaw basis")

	rig._apply_mouse_look(Vector2(-deg_to_rad(90.0) / rig.mouse_sensitivity, 0.0))
	var turned_position := rig.global_position
	Input.action_press("move_forward")
	rig._process(1.0)
	Input.action_release("move_forward")
	var turned_displacement := rig.global_position - turned_position
	_check(absf(turned_displacement.x) > 3.0 and absf(turned_displacement.z) < 0.01, "movement rotates with yaw")

	rig._apply_mouse_look(Vector2(0.0, -100000.0))
	_check(rig.get_pitch_degrees() <= 85.001, "pitch is clamped")

	for action in ["move_forward", "move_back", "move_left", "move_right", "move_up", "move_down", "ui_cancel", "pointer_select", "pointer_secondary", "push_to_talk", "focus_next", "debug_toggle"]:
		_check(InputMap.has_action(action), "input action exists: %s" % action)

	var toggle_event := InputEventAction.new()
	toggle_event.action = "debug_toggle"
	toggle_event.pressed = true
	var overlay_was_visible := overlay.visible
	overlay._unhandled_input(toggle_event)
	_check(overlay.visible != overlay_was_visible, "F3 toggles the debug overlay")

	var openxr_source := OpenXRInteractionSource.new()
	_check(not openxr_source.is_available(), "OpenXR hand source remains inactive without tracking")
	_check(openxr_source.get_capabilities().has("pinch_scroll"), "OpenXR seam targets hand-only interaction")
	_check(openxr_source.get_capabilities().has("direct_touch"), "OpenXR seam declares direct touch")
	_check(openxr_source.get_capabilities().has("bimanual_transform"), "OpenXR seam declares two-hand manipulation")
	var hand_events: Array[InteractionEvent] = []
	openxr_source.interaction_event.connect(func(event: InteractionEvent) -> void: hand_events.append(event))
	openxr_source.set_hand_tracking_active(true)
	_check(openxr_source.update_hand_ray(Vector3.ZERO, Vector3.FORWARD, true), "synthetic hand ray reaches the adapter seam")
	_check(openxr_source.get_pointer_state().is_selecting, "pinch maps to semantic selection state")
	_check(openxr_source.submit_direct_touch("thread_demo", Vector3(0.0, 1.0, -1.0)), "direct touch emits through hand seam")
	_check(openxr_source.submit_palm_action(InteractionEvent.Type.CODE_TOGGLE), "palm action emits through hand seam")
	_check(openxr_source.submit_explicit_pinch_action(InteractionEvent.Type.APPROVE), "approval requires an explicit pinch action")
	_check(openxr_source.submit_bimanual_transform("code_viewer", Vector3.ZERO, 1.2, 0.1), "two-hand transform emits through hand seam")
	_check(hand_events.size() == 4, "hand-only semantic events are observable")
	_check(hand_events[0].source == InteractionEvent.Source.HAND, "direct touch event is attributed to a hand")
	openxr_source.free()

	if not _failed:
		print("[TEST] Milestone 0 smoke checks passed")
	main.queue_free()
	get_tree().quit(1 if _failed else 0)


func _check(condition: bool, description: String) -> void:
	if condition:
		return
	_failed = true
	push_error("[TEST] Failed: %s" % description)
