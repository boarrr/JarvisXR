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
const TOUCH_MARGIN := 0.12
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


func _ready() -> void:
	source_name = "openxr_hands"
	if not xr_origin_path.is_empty():
		_xr_origin = get_node_or_null(xr_origin_path) as Node3D
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

	if is_pinching and not was_pinching:
		_start_touch_interaction(index_tip)
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
	tracking_changed.emit(value)


func _start_touch_interaction(position: Vector3) -> void:
	var target_id := _nearest_touch_target(position)
	if target_id.is_empty():
		return
	submit_direct_touch(target_id, position)
	# Bare thread IDs are orbs: pinching one starts a grab so it can be moved
	# or dropped onto another orb to combine them.
	if not ":" in target_id:
		_grab_target_id = target_id
		_grab_origin_position = position
		interaction_event.emit(InteractionEvent.new(
			InteractionEvent.Type.GRAB_BEGIN,
			target_id,
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


func _nearest_touch_target(position: Vector3) -> String:
	var best_target := ""
	var best_slack := 0.0
	for node in get_tree().get_nodes_in_group("interactable"):
		var area := node as Area3D
		if area == null or not area.is_visible_in_tree():
			continue
		if not area.has_method("get_interaction_target_id"):
			continue
		var target_id := str(area.call("get_interaction_target_id"))
		if target_id.is_empty():
			continue
		var slack := position.distance_to(area.global_position) - _shape_radius(area) - TOUCH_MARGIN
		if slack < 0.0 and (best_target.is_empty() or slack < best_slack):
			best_slack = slack
			best_target = target_id
	return best_target


func _shape_radius(area: Area3D) -> float:
	for child in area.get_children():
		if child is CollisionShape3D:
			var shape := (child as CollisionShape3D).shape
			if shape is SphereShape3D:
				return (shape as SphereShape3D).radius
	return 0.0


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
