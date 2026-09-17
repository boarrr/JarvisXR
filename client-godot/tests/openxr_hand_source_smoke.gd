extends Node

var _failed := false


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	_check(OpenXRInteractionSource.evaluate_pinch(0.02, false), "pinch begins inside the close threshold")
	_check(not OpenXRInteractionSource.evaluate_pinch(0.03, false), "open fingers do not begin a pinch in the hysteresis band")
	_check(OpenXRInteractionSource.evaluate_pinch(0.03, true), "an active pinch survives hand-tracking jitter")
	_check(not OpenXRInteractionSource.evaluate_pinch(0.04, true), "pinch releases beyond the open threshold")

	var source := OpenXRInteractionSource.new()
	add_child(source)
	var events: Array[InteractionEvent] = []
	var tracking_changes: Array[bool] = []
	source.interaction_event.connect(func(event: InteractionEvent) -> void: events.append(event))
	source.tracking_changed.connect(func(value: bool) -> void: tracking_changes.append(value))
	source.set_hand_tracking_active(true)
	source.set_hover_target_id("ui:code_surface")

	var palm := Transform3D(Basis.IDENTITY, Vector3(0.2, 1.2, -0.5))
	_check(source.submit_joint_sample(
		"right",
		palm,
		Vector3(0.02, 1.22, -0.75),
		Vector3(0.0, 1.2, -0.7),
		Vector3(0.0, 1.22, -0.75)
	), "a normalized tracked-joint sample is accepted")
	_check(source.has_tracking_data(), "joint input marks optical tracking as available")
	_check(source.get_pointer_state().is_selecting, "thumb-index distance drives semantic selection")
	_check(source.get_pointer_state().direction.z < -0.9, "distal-to-tip vector drives the hand ray")

	# Keep pinching and lift more than one scroll step. Pinch-drag produces a
	# semantic Vim viewer event only while that surface is hovered.
	source.submit_joint_sample(
		"right",
		palm,
		Vector3(0.02, 1.25, -0.75),
		Vector3(0.0, 1.23, -0.7),
		Vector3(0.0, 1.25, -0.75)
	)
	_check(events.size() == 1, "pinch-drag emits one quantized scroll action")
	_check(events[0].type == InteractionEvent.Type.CODE_SCROLL_UP, "lifting a pinched hand scrolls code upward")
	_check(events[0].source == InteractionEvent.Source.HAND, "tracked scroll is attributed to a hand")

	source.submit_joint_sample(
		"right",
		palm,
		Vector3(0.06, 1.25, -0.75),
		Vector3(0.0, 1.23, -0.7),
		Vector3(0.0, 1.25, -0.75)
	)
	_check(not source.get_pointer_state().is_selecting, "opening the hand releases selection")
	_check(tracking_changes == [true], "tracking availability changes are stable")

	source.set_hand_tracking_active(false)
	_check(not source.is_available(), "ending the XR session disables the source")
	_check(tracking_changes == [true, false], "session shutdown publishes tracking loss")

	if not _failed:
		print("[TEST] OpenXR tracked-hand source checks passed")
	source.queue_free()
	get_tree().quit(1 if _failed else 0)


func _check(condition: bool, description: String) -> void:
	if condition:
		return
	_failed = true
	push_error("[TEST] Failed: %s" % description)
