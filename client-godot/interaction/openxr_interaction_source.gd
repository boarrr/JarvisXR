class_name OpenXRInteractionSource
extends InteractionSource

signal tracking_changed(has_tracking_data: bool)
signal active_hand_changed(hand_name: String)
signal hand_pose_changed(
	hand_name: String,
	palm_transform: Transform3D,
	index_tip: Vector3,
	is_pinching: bool
)

# The source consumes XRHandTracker joint data only. Controller-inferred hand
# skeletons are intentionally rejected: the production interaction path is bare
# hands, with no controller, keyboard, or mouse requirement.

const CAPABILITIES := [
	"hand_ray",
	"direct_touch",
	"pinch_select",
	"pinch_grab",
	"pinch_scroll",
	"palm_menu",
	"bimanual_transform",
]

const PALM_ACTIONS := [
	InteractionEvent.Type.FOCUS,
	InteractionEvent.Type.DISMISS,
	InteractionEvent.Type.VOICE_BEGIN,
	InteractionEvent.Type.VOICE_END,
	InteractionEvent.Type.CODE_TOGGLE,
]

const LEFT_TRACKER_PATH := &"/user/hand_tracker/left"
const RIGHT_TRACKER_PATH := &"/user/hand_tracker/right"
const TOUCH_CONTACT_DISTANCE := 0.012
const TOUCH_RELEASE_DISTANCE := 0.05
const REQUIRED_POSITION_FLAGS := (
	XRHandTracker.HAND_JOINT_FLAG_POSITION_VALID
	| XRHandTracker.HAND_JOINT_FLAG_POSITION_TRACKED
)

# Optional joints rendered as hand markers and used to stabilize the index ray.
const MARKER_JOINTS := {
	"wrist": XRHandTracker.HAND_JOINT_WRIST,
	"palm": XRHandTracker.HAND_JOINT_PALM,
	"thumb_tip": XRHandTracker.HAND_JOINT_THUMB_TIP,
	"index_proximal": XRHandTracker.HAND_JOINT_INDEX_FINGER_PHALANX_PROXIMAL,
	"index_tip": XRHandTracker.HAND_JOINT_INDEX_FINGER_TIP,
	"middle_tip": XRHandTracker.HAND_JOINT_MIDDLE_FINGER_TIP,
	"ring_tip": XRHandTracker.HAND_JOINT_RING_FINGER_TIP,
	"pinky_tip": XRHandTracker.HAND_JOINT_PINKY_FINGER_TIP,
}

@export var xr_origin_path: NodePath
@export_enum("right", "left") var preferred_hand: String = "right"
@export_range(0.008, 0.06, 0.001) var pinch_begin_distance: float = 0.028
@export_range(0.012, 0.08, 0.001) var pinch_release_distance: float = 0.040
@export_range(0.002, 0.05, 0.001) var scroll_step_metres: float = 0.012
@export_range(0.1, 0.9, 0.01) var origin_smoothing: float = 0.4
@export_range(0.1, 0.9, 0.01) var direction_smoothing: float = 0.22

var _session_active: bool = false
var _has_tracking_data: bool = false
var _pointer_state := PointerState.new()
var _xr_origin: Node3D = null
var _active_hand_name := ""
var _hover_target_id := ""
var _last_pinch_position := Vector3.ZERO
var _scroll_accumulator := 0.0
var _has_smoothed_ray := false
var _latest_hand_samples: Dictionary = {}
var _hand_pinch_states := {"left": false, "right": false}
var _bimanual_active := false
var _bimanual_target_id := ""
var _bimanual_initial_center := Vector3.ZERO
var _bimanual_initial_vector := Vector3.RIGHT
var _bimanual_initial_distance := 1.0
var _grab_target_id := ""
var _grab_origin_position := Vector3.ZERO
var _touch_target_id := ""
var _touch_area: Area3D = null
var _touch_release_needed := false
var _telemetry_enabled := false
var _telemetry_elapsed := 0.0
var _tracking_losses := 0


func _ready() -> void:
	source_name = "openxr_hands"
	if not xr_origin_path.is_empty():
		_xr_origin = get_node_or_null(xr_origin_path) as Node3D
	_telemetry_enabled = bool(
		ProjectSettings.get_setting("spatial_agent/gesture_telemetry", false)
	)
	set_physics_process(false)


func is_available() -> bool:
	return _session_active


func get_pointer_state() -> PointerState:
	return _pointer_state.copy() if _session_active else null


func get_capabilities() -> Array[String]:
	return CAPABILITIES.duplicate()


func set_hand_tracking_active(value: bool) -> void:
	_session_active = value
	set_physics_process(value)
	if not value:
		_reset_tracking()


func has_tracking_data() -> bool:
	return _has_tracking_data


func get_active_hand_name() -> String:
	return _active_hand_name


func set_xr_origin(origin: Node3D) -> void:
	_xr_origin = origin


func set_hover_target_id(target_id: String) -> void:
	_hover_target_id = target_id
	if target_id != "ui:code_surface":
		_scroll_accumulator = 0.0


func _physics_process(_delta: float) -> void:
	if not _session_active:
		return
	_collect_hand_samples()
	var pointer_sample: Dictionary = _latest_hand_samples.get(preferred_hand, {})
	if pointer_sample.is_empty():
		_clear_pointer()
	else:
		_apply_pointer_sample(pointer_sample)
	_update_bimanual_gesture()
	if _telemetry_enabled:
		_telemetry_elapsed += _delta
		if _telemetry_elapsed >= 0.25:
			_telemetry_elapsed = 0.0
			_emit_gesture_telemetry()


func _emit_gesture_telemetry() -> void:
	# Distances only: no positions, prompts, or transcript content.
	var payload := {
		"event": "sample",
		"right": _hand_telemetry("right"),
		"left": _hand_telemetry("left"),
		"tracking_losses": _tracking_losses,
		"touch": _touch_target_id,
		"grab": _grab_target_id,
		"pinching": _pointer_state.is_selecting,
	}
	print("GEST %s" % JSON.stringify(payload))


func _hand_telemetry(hand_name: String) -> Variant:
	var sample: Dictionary = _latest_hand_samples.get(hand_name, {})
	if sample.is_empty():
		return null
	var joints: Dictionary = sample.get("joints", {})
	var palm: Vector3 = joints.get("palm", Vector3.ZERO)
	var index_tip := sample.get("index_tip", Vector3.ZERO) as Vector3
	var thumb_tip := sample.get("thumb_tip", Vector3.ZERO) as Vector3
	var fist: Array[float] = []
	if not palm.is_zero_approx():
		for joint_name in ["index_tip", "middle_tip", "ring_tip", "pinky_tip"]:
			if joints.has(joint_name):
				fist.append(snappedf(palm.distance_to(joints[joint_name]), 0.001))
	return {
		"pinch_mm": snappedf(thumb_tip.distance_to(index_tip) * 1000.0, 0.5),
		"fist_mm": fist,
	}


func simulate_tick() -> bool:
	# Deterministic single step used by tests and the desktop lab.
	_collect_hand_samples()
	var pointer_sample: Dictionary = _latest_hand_samples.get(preferred_hand, {})
	if pointer_sample.is_empty():
		_clear_pointer()
		return false
	var applied := _apply_pointer_sample(pointer_sample)
	_update_bimanual_gesture()
	return applied


func _collect_hand_samples() -> void:
	_latest_hand_samples.clear()
	for hand_name in ["left", "right"]:
		var sample := _sample_for_hand(hand_name)
		if sample.is_empty():
			_hand_pinch_states[hand_name] = false
			continue
		_latest_hand_samples[hand_name] = sample
		var thumb_tip := sample.get("thumb_tip", Vector3.ZERO) as Vector3
		var index_tip := sample.get("index_tip", Vector3.ZERO) as Vector3
		_hand_pinch_states[hand_name] = evaluate_pinch(
			thumb_tip.distance_to(index_tip),
			bool(_hand_pinch_states.get(hand_name, false)),
			pinch_begin_distance,
			pinch_release_distance
		)
	_set_tracking_available(not _latest_hand_samples.is_empty())


func _clear_pointer() -> void:
	var had_state := _pointer_state.is_selecting or _pointer_state.is_grabbing
	if not _grab_target_id.is_empty():
		_finish_grab(_pointer_state.origin)
	_pointer_state.is_selecting = false
	_pointer_state.is_grabbing = false
	_pointer_state.direction = Vector3.ZERO
	_active_hand_name = ""
	_has_smoothed_ray = false
	_hand_pinch_states[preferred_hand] = false
	_touch_target_id = ""
	_touch_area = null
	_touch_release_needed = false
	if had_state:
		pointer_state_changed.emit(_pointer_state.copy())


func _sample_for_hand(hand_name: String) -> Dictionary:
	var tracker_path := RIGHT_TRACKER_PATH if hand_name == "right" else LEFT_TRACKER_PATH
	var tracker := XRServer.get_tracker(tracker_path) as XRHandTracker
	if not _tracker_is_usable(tracker):
		return {}
	var required_joints := [
		XRHandTracker.HAND_JOINT_PALM,
		XRHandTracker.HAND_JOINT_THUMB_TIP,
		XRHandTracker.HAND_JOINT_INDEX_FINGER_PHALANX_DISTAL,
		XRHandTracker.HAND_JOINT_INDEX_FINGER_TIP,
	]
	var all_joints_valid := true
	for joint in required_joints:
		if not _joint_has_tracked_position(tracker, joint):
			all_joints_valid = false
			break
	if not all_joints_valid:
		return {}

	var origin_transform := _xr_origin.global_transform if _xr_origin != null else Transform3D.IDENTITY
	var joints: Dictionary = {}
	for joint_name in MARKER_JOINTS:
		var joint_index: int = MARKER_JOINTS[joint_name]
		if _joint_has_tracked_position(tracker, joint_index):
			joints[joint_name] = (
				origin_transform * tracker.get_hand_joint_transform(joint_index)
			).origin
	return {
		"hand_name": hand_name,
		"palm_transform": origin_transform * tracker.get_hand_joint_transform(XRHandTracker.HAND_JOINT_PALM),
		"thumb_tip": origin_transform * tracker.get_hand_joint_transform(XRHandTracker.HAND_JOINT_THUMB_TIP).origin,
		"index_distal": origin_transform * tracker.get_hand_joint_transform(XRHandTracker.HAND_JOINT_INDEX_FINGER_PHALANX_DISTAL).origin,
		"index_tip": origin_transform * tracker.get_hand_joint_transform(XRHandTracker.HAND_JOINT_INDEX_FINGER_TIP).origin,
		"index_proximal": joints.get("index_proximal", Vector3.ZERO),
		"joints": joints,
	}


func get_latest_hand_sample(hand_name: String) -> Dictionary:
	var sample: Dictionary = _latest_hand_samples.get(hand_name, {})
	return sample.duplicate(true)


func is_hand_pinching(hand_name: String) -> bool:
	return bool(_hand_pinch_states.get(hand_name, false))


func _tracker_is_usable(tracker: XRHandTracker) -> bool:
	return (
		tracker != null
		and tracker.has_tracking_data
		and tracker.hand_tracking_source != XRHandTracker.HAND_TRACKING_SOURCE_CONTROLLER
		and tracker.hand_tracking_source != XRHandTracker.HAND_TRACKING_SOURCE_NOT_TRACKED
	)


func _joint_has_tracked_position(tracker: XRHandTracker, joint: int) -> bool:
	var flags := tracker.get_hand_joint_flags(joint)
	return (flags & REQUIRED_POSITION_FLAGS) == REQUIRED_POSITION_FLAGS


func _apply_pointer_sample(sample: Dictionary) -> bool:
	var index_tip := sample.get("index_tip", Vector3.ZERO) as Vector3
	var index_distal := sample.get("index_distal", Vector3.ZERO) as Vector3
	var index_proximal := sample.get("index_proximal", Vector3.ZERO) as Vector3
	var thumb_tip := sample.get("thumb_tip", Vector3.ZERO) as Vector3
	var palm_transform := sample.get("palm_transform", Transform3D.IDENTITY) as Transform3D
	# A longer baseline (proximal to tip) is far more stable than the ~2 cm
	# distal-to-tip segment, which amplifies joint jitter into ray noise.
	# Synthetic samples without tracked joints keep the distal baseline.
	var joints: Dictionary = sample.get("joints", {})
	var direction := index_tip - index_distal
	if joints.has("index_proximal"):
		var candidate := index_tip - index_proximal
		if candidate.length_squared() >= 0.0004:
			direction = candidate
	if direction.length_squared() < 0.000016:
		_clear_pointer()
		return false

	_set_tracking_available(true)
	if preferred_hand != _active_hand_name:
		_active_hand_name = preferred_hand
		_has_smoothed_ray = false
		active_hand_changed.emit(preferred_hand)

	var was_pinching := _pointer_state.is_selecting
	var pinch_distance := thumb_tip.distance_to(index_tip)
	var is_pinching := evaluate_pinch(
		pinch_distance,
		was_pinching,
		pinch_begin_distance,
		pinch_release_distance
	)
	var ray_direction := direction.normalized()
	if _has_smoothed_ray:
		_pointer_state.origin = _pointer_state.origin.lerp(index_tip, origin_smoothing)
		_pointer_state.direction = _pointer_state.direction.lerp(ray_direction, direction_smoothing).normalized()
	else:
		_pointer_state.origin = index_tip
		_pointer_state.direction = ray_direction
		_has_smoothed_ray = true
	_pointer_state.is_selecting = is_pinching
	_pointer_state.is_grabbing = not _grab_target_id.is_empty()

	_update_touch_interaction(index_tip)
	if is_pinching and not was_pinching:
		_begin_grab_if_touching(index_tip)
	elif is_pinching and not _grab_target_id.is_empty():
		if index_tip.distance_to(_grab_origin_position) > 0.012:
			interaction_event.emit(InteractionEvent.new(
				InteractionEvent.Type.GRAB_MOVE,
				_grab_target_id,
				InteractionEvent.Source.HAND,
				index_tip,
				{"gesture": "orb_grab", "phase": "move"}
			))
	elif not is_pinching and was_pinching and not _grab_target_id.is_empty():
		_finish_grab(index_tip)

	_update_pinch_scroll(index_tip, was_pinching, is_pinching)
	pointer_state_changed.emit(_pointer_state.copy())
	hand_pose_changed.emit(preferred_hand, palm_transform, index_tip, is_pinching)
	return true


func submit_joint_sample(
	hand_name: String,
	palm_transform: Transform3D,
	thumb_tip: Vector3,
	index_distal: Vector3,
	index_tip: Vector3
) -> bool:
	if not _session_active:
		return false
	var sample := {
		"hand_name": hand_name,
		"palm_transform": palm_transform,
		"thumb_tip": thumb_tip,
		"index_distal": index_distal,
		"index_tip": index_tip,
	}
	_latest_hand_samples[hand_name] = sample
	_hand_pinch_states[hand_name] = evaluate_pinch(
		thumb_tip.distance_to(index_tip),
		bool(_hand_pinch_states.get(hand_name, false)),
		pinch_begin_distance,
		pinch_release_distance
	)
	_set_tracking_available(true)
	if hand_name != preferred_hand:
		return true
	return _apply_pointer_sample(sample)


static func evaluate_pinch(
	distance: float,
	was_pinching: bool,
	begin_distance: float = 0.024,
	release_distance: float = 0.036
) -> bool:
	if release_distance <= begin_distance:
		return distance <= begin_distance
	return distance < release_distance if was_pinching else distance <= begin_distance


func _update_pinch_scroll(position: Vector3, was_pinching: bool, is_pinching: bool) -> void:
	if not is_pinching:
		_scroll_accumulator = 0.0
		return
	if not was_pinching:
		_last_pinch_position = position
		_scroll_accumulator = 0.0
		return

	var vertical_delta := position.y - _last_pinch_position.y
	_last_pinch_position = position
	if _hover_target_id != "ui:code_surface":
		return
	_scroll_accumulator += vertical_delta
	if absf(_scroll_accumulator) < scroll_step_metres:
		return
	var scroll_direction := signf(_scroll_accumulator)
	_scroll_accumulator -= scroll_direction * scroll_step_metres
	submit_pinch_scroll(scroll_direction)


func _update_bimanual_gesture() -> void:
	var both_pinching := (
		bool(_hand_pinch_states.get("left", false))
		and bool(_hand_pinch_states.get("right", false))
		and _latest_hand_samples.has("left")
		and _latest_hand_samples.has("right")
	)
	if not both_pinching:
		if _bimanual_active:
			submit_bimanual_transform(
				_bimanual_target_id,
				_bimanual_initial_center,
				1.0,
				0.0,
				"end"
			)
		_bimanual_active = false
		_bimanual_target_id = ""
		return

	var left_position := (_latest_hand_samples["left"] as Dictionary).get("index_tip", Vector3.ZERO) as Vector3
	var right_position := (_latest_hand_samples["right"] as Dictionary).get("index_tip", Vector3.ZERO) as Vector3
	var center := (left_position + right_position) * 0.5
	var hand_vector := right_position - left_position
	var hand_distance := hand_vector.length()
	if hand_distance < 0.06:
		return

	if not _bimanual_active:
		if _hover_target_id != "ui:code_surface":
			return
		_bimanual_active = true
		_bimanual_target_id = _hover_target_id
		_bimanual_initial_center = center
		_bimanual_initial_vector = hand_vector
		_bimanual_initial_distance = hand_distance
		submit_bimanual_transform(_bimanual_target_id, center, 1.0, 0.0, "begin")
		return

	var scale_factor := hand_distance / _bimanual_initial_distance
	var rotation_radians := _bimanual_initial_vector.signed_angle_to(hand_vector, Vector3.UP)
	submit_bimanual_transform(
		_bimanual_target_id,
		center,
		scale_factor,
		rotation_radians,
		"move"
	)


func _set_tracking_available(value: bool) -> void:
	if _has_tracking_data == value:
		return
	_has_tracking_data = value
	if not value:
		_tracking_losses += 1
	tracking_changed.emit(value)


func _update_touch_interaction(position: Vector3) -> void:
	# Physical touch behaves like the headset's system keyboard: the fingertip
	# presses a control on contact and latches until it pulls away.
	if _touch_release_needed:
		if _touch_area == null or _distance_to_area(_touch_area, position) > TOUCH_RELEASE_DISTANCE:
			_touch_release_needed = false
			_touch_target_id = ""
			_touch_area = null
		else:
			return
	var contact := _nearest_touch_target(position)
	if contact.is_empty():
		return
	_touch_target_id = str((contact as Dictionary)["target_id"])
	_touch_area = contact["area"] as Area3D
	_touch_release_needed = true
	submit_direct_touch(_touch_target_id, position)


func _begin_grab_if_touching(position: Vector3) -> void:
	if _touch_target_id.is_empty() or ":" in _touch_target_id:
		return
	_grab_target_id = _touch_target_id
	_grab_origin_position = position
	interaction_event.emit(InteractionEvent.new(
		InteractionEvent.Type.GRAB_BEGIN,
		_grab_target_id,
		InteractionEvent.Source.HAND,
		position,
		{"gesture": "orb_grab", "phase": "begin"}
	))


func _finish_grab(position: Vector3) -> void:
	interaction_event.emit(InteractionEvent.new(
		InteractionEvent.Type.GRAB_END,
		_grab_target_id,
		InteractionEvent.Source.HAND,
		position,
		{"gesture": "orb_grab", "phase": "end"}
	))
	_grab_target_id = ""


func _nearest_touch_target(position: Vector3) -> Dictionary:
	var best_target := ""
	var best_area: Area3D = null
	var best_distance := TOUCH_CONTACT_DISTANCE
	for node in get_tree().get_nodes_in_group("interactable"):
		var area := node as Area3D
		if area == null or not area.is_visible_in_tree():
			continue
		if not area.has_method("get_interaction_target_id"):
			continue
		var target_id := str(area.call("get_interaction_target_id"))
		if target_id.is_empty():
			continue
		var distance := _distance_to_area(area, position)
		if distance <= best_distance:
			best_distance = distance
			best_target = target_id
			best_area = area
	if best_target.is_empty():
		return {}
	return {"target_id": best_target, "area": best_area}


func _distance_to_area(area: Area3D, point: Vector3) -> float:
	var best := INF
	for child in area.get_children():
		if not (child is CollisionShape3D):
			continue
		var collision := child as CollisionShape3D
		var shape := collision.shape
		var local := collision.global_transform.affine_inverse() * point
		var distance := INF
		if shape is SphereShape3D:
			distance = local.length() - (shape as SphereShape3D).radius
		elif shape is BoxShape3D:
			var half := (shape as BoxShape3D).size * 0.5
			var outside := Vector3(
				maxf(absf(local.x) - half.x, 0.0),
				maxf(absf(local.y) - half.y, 0.0),
				maxf(absf(local.z) - half.z, 0.0)
			)
			var inside := minf(
				maxf(absf(local.x) - half.x, maxf(absf(local.y) - half.y, absf(local.z) - half.z)),
				0.0
			)
			distance = outside.length() + inside
		elif shape is CylinderShape3D:
			var cylinder := shape as CylinderShape3D
			var horizontal := Vector2(local.x, local.z).length() - cylinder.radius
			var vertical := absf(local.y) - cylinder.height * 0.5
			distance = (
				Vector2(maxf(horizontal, 0.0), maxf(vertical, 0.0)).length()
				+ minf(maxf(horizontal, vertical), 0.0)
			)
		best = minf(best, distance)
	return best


func _reset_tracking() -> void:
	var had_pointer_state := _pointer_state.is_selecting or _pointer_state.is_grabbing
	if _bimanual_active and not _bimanual_target_id.is_empty():
		interaction_event.emit(InteractionEvent.new(
			InteractionEvent.Type.GRAB_END,
			_bimanual_target_id,
			InteractionEvent.Source.HAND,
			_bimanual_initial_center,
			{"gesture": "bimanual_transform", "phase": "end"}
		))
	_pointer_state.is_selecting = false
	_pointer_state.is_grabbing = false
	_active_hand_name = ""
	_latest_hand_samples.clear()
	_hand_pinch_states["left"] = false
	_hand_pinch_states["right"] = false
	_bimanual_active = false
	_bimanual_target_id = ""
	_grab_target_id = ""
	_hover_target_id = ""
	_scroll_accumulator = 0.0
	_has_smoothed_ray = false
	_set_tracking_available(false)
	if had_pointer_state:
		pointer_state_changed.emit(_pointer_state.copy())


func update_hand_ray(
	origin: Vector3,
	direction: Vector3,
	is_pinching: bool,
	is_grabbing: bool = false
) -> bool:
	if not _session_active or direction.is_zero_approx():
		return false
	_set_tracking_available(true)
	_pointer_state.origin = origin
	_pointer_state.direction = direction.normalized()
	_pointer_state.is_selecting = is_pinching
	_pointer_state.is_grabbing = is_grabbing
	pointer_state_changed.emit(_pointer_state.copy())
	return true


func submit_pinch_scroll(vertical_delta: float) -> bool:
	if not _session_active or is_zero_approx(vertical_delta):
		return false
	var event_type := (
		InteractionEvent.Type.CODE_SCROLL_UP
		if vertical_delta > 0.0
		else InteractionEvent.Type.CODE_SCROLL_DOWN
	)
	interaction_event.emit(InteractionEvent.new(
		event_type,
		"",
		InteractionEvent.Source.HAND
	))
	return true


func submit_direct_touch(target_id: String, world_position: Vector3) -> bool:
	if not _session_active or target_id.is_empty():
		return false
	interaction_event.emit(InteractionEvent.new(
		InteractionEvent.Type.SELECT,
		target_id,
		InteractionEvent.Source.HAND,
		world_position,
		{"gesture": "direct_touch"}
	))
	return true


func submit_palm_action(event_type: InteractionEvent.Type) -> bool:
	if not _session_active or event_type not in PALM_ACTIONS:
		return false
	interaction_event.emit(InteractionEvent.new(
		event_type,
		"",
		InteractionEvent.Source.HAND,
		null,
		{"gesture": "palm_menu"}
	))
	return true


func submit_explicit_pinch_action(event_type: InteractionEvent.Type, target_id: String = "") -> bool:
	if not _session_active or event_type not in [
		InteractionEvent.Type.APPROVE,
		InteractionEvent.Type.DENY,
		InteractionEvent.Type.DISMISS,
		InteractionEvent.Type.CODE_TOGGLE,
	]:
		return false
	interaction_event.emit(InteractionEvent.new(
		event_type,
		target_id,
		InteractionEvent.Source.HAND,
		null,
		{"gesture": "explicit_pinch"}
	))
	return true


func submit_bimanual_transform(
	target_id: String,
	center: Vector3,
	scale_factor: float,
	rotation_radians: float,
	phase: String = "move"
) -> bool:
	if not _session_active or target_id.is_empty() or phase not in ["begin", "move", "end"]:
		return false
	var event_type := InteractionEvent.Type.GRAB_MOVE
	if phase == "begin":
		event_type = InteractionEvent.Type.GRAB_BEGIN
	elif phase == "end":
		event_type = InteractionEvent.Type.GRAB_END
	interaction_event.emit(InteractionEvent.new(
		event_type,
		target_id,
		InteractionEvent.Source.HAND,
		center,
		{
			"gesture": "bimanual_transform",
			"scale_factor": clampf(scale_factor, 0.4, 2.5),
			"rotation_radians": rotation_radians,
			"phase": phase,
		}
	))
	return true
