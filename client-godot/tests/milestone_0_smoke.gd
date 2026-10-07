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
	var xr_runtime := main.get_node("XRRuntime") as XRRuntime
	_check(rig != null, "UserRig exists")
	_check(overlay != null, "DebugOverlay exists")
	_check(absf(rig.global_position.y - 1.65) < EPSILON, "eye height is 1.65 m")

	var hand_source := xr_runtime.get_hand_source()
	_check(hand_source != null, "XR runtime exposes an OpenXR hand source")
	_check(not hand_source.is_available(), "OpenXR hand source stays inactive without hand tracking")
	_check(
		ServiceRegistry.input_router.get_active_source() == hand_source,
		"OpenXR hand source is registered as the active source"
	)

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
