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
# Meta's hand-interaction profile exposes a curated aim pose and pinch signal on
# these controller paths; they are steadier than raw joint geometry.
const LEFT_CONTROLLER_PATH := &"/user/hand/left"
const RIGHT_CONTROLLER_PATH := &"/user/hand/right"
const TOUCH_CONTACT_DISTANCE := 0.03
const TOUCH_RELEASE_DISTANCE := 0.07
const TOUCH_TAP_HOLD_MSEC := 45
const TOUCH_DRAG_CANCEL_DISTANCE := 0.025
# OpenXR joints drop out for single frames routinely (occlusion, edge of the
# camera FOV). Hold the last state briefly so a blink does not cancel a touch,
# grab, or the aim ray.
const TRACKING_GRACE_SECONDS := 0.45
const FIST_CLOSE_DISTANCE := 0.07
const FIST_OPEN_DISTANCE := 0.10
const FIST_MIN_CURLED := 3
const DOUBLE_PINCH_WINDOW_MSEC := 800
const TAP_MIN_DURATION_MSEC := 90
const TAP_GAP_MIN_MSEC := 80
const SUMMON_COOLDOWN_MSEC := 700
const ATTRACT_MEMORY_MSEC := 700
const CRUSH_HOLD_SECONDS := 0.4
const CRUSH_CORE_RADIUS := 0.24
const FIST_JOINTS := ["index_tip", "middle_tip", "ring_tip", "pinky_tip"]
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
var _touch_target_id := {"left": "", "right": ""}
var _touch_area := {"left": null, "right": null}
var _touch_release_needed := {"left": false, "right": false}
var _touch_candidate_id := {"left": "", "right": ""}
var _touch_candidate_position := {"left": Vector3.ZERO, "right": Vector3.ZERO}
var _touch_candidate_start_msec := {"left": 0, "right": 0}
var _touch_dragged := {"left": false, "right": false}
var _touch_tap_fired := {"left": false, "right": false}
var _hand_stop_offset := {"left": Vector3.ZERO, "right": Vector3.ZERO}
var _telemetry_enabled := false
var _telemetry_elapsed := 0.0
var _tracking_losses := 0
var _missing_seconds := 0.0
var _pointer_missing_seconds := 0.0
var _telemetry_file: FileAccess = null
var _fist_states := {"left": false, "right": false}
var _crush_seconds := 0.0
var _crush_latched := false
var _attract_target := ""
var _fist_prev := false
var _crush_candidate := ""
var _last_orb_hover_id := ""
var _last_orb_hover_msec := 0
var _last_ui_touch_msec := 0
var _tap_prev_pinch := {"left": false, "right": false}
var _tap_begin_msec := {"left": 0, "right": 0}
var _tap_prev_release_msec := {"left": 0, "right": 0}
var _tap_pending := {"left": 0, "right": 0}
var _single_tap_due := {"left": 0, "right": 0}
var _summon_blocked_until_msec := 0
var _clock_override_msec := -1
const GESTURE_LOG_PATH := "user://gesture_session.jsonl"
const GESTURE_LOG_LIMIT_BYTES := 512 * 1024


func _ready() -> void:
	source_name = "openxr_hands"
	if not xr_origin_path.is_empty():
		_xr_origin = get_node_or_null(xr_origin_path) as Node3D
	_telemetry_enabled = bool(
		ProjectSettings.get_setting("spatial_agent/gesture_telemetry", false)
	) or ("--gesture-telemetry" in OS.get_cmdline_args())
	if _telemetry_enabled:
		var absolute := ProjectSettings.globalize_path(GESTURE_LOG_PATH)
		var exists := FileAccess.file_exists(GESTURE_LOG_PATH)
		if exists and FileAccess.get_file_as_string(GESTURE_LOG_PATH).length() > GESTURE_LOG_LIMIT_BYTES:
			DirAccess.remove_absolute(absolute)
			exists = false
		_telemetry_file = FileAccess.open(
			GESTURE_LOG_PATH, FileAccess.READ_WRITE if exists else FileAccess.WRITE
		)
		if _telemetry_file != null:
			_telemetry_file.seek_end()
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
	if not target_id.is_empty() and not ":" in target_id:
		# Remember the last agent under the ray: closing a fist swings the
		# index-derived ray off the target before the fist is detected.
		_last_orb_hover_id = target_id
		_last_orb_hover_msec = _now_msec()


func _physics_process(_delta: float) -> void:
	if not _session_active:
		return
	_collect_hand_samples(_delta)
	# Stop the hand at any touch surface (Meta-style panel collision) before
	# computing the pointer/touch so the visual and the hit both land on it.
	for hand_name in ["left", "right"]:
		var stop_sample: Dictionary = _latest_hand_samples.get(hand_name, {})
		if stop_sample.is_empty():
			_hand_stop_offset[hand_name] = Vector3.ZERO
		else:
			_hand_stop_offset[hand_name] = _compute_surface_stop(
				stop_sample.get("index_tip", Vector3.ZERO) as Vector3
			)
	var pointer_sample: Dictionary = _latest_hand_samples.get(preferred_hand, {})
	if pointer_sample.is_empty():
		_pointer_missing_seconds += _delta
		if _pointer_missing_seconds >= TRACKING_GRACE_SECONDS:
			_clear_pointer()
	else:
		_pointer_missing_seconds = 0.0
		_apply_pointer_sample(pointer_sample, _delta)
	# Touch/poke is handled for BOTH hands so the left-hand palm panel works
	# whichever hand reaches for it.
	for hand_name in ["left", "right"]:
		var hand_sample: Dictionary = _latest_hand_samples.get(hand_name, {})
		if hand_sample.is_empty():
			continue
		var tip: Vector3 = (
			hand_sample.get("index_tip", Vector3.ZERO) as Vector3
		) + _hand_stop_offset[hand_name]
		_update_touch_interaction(hand_name, tip)
	_update_bimanual_gesture()
	_flush_single_taps()
	if _telemetry_enabled:
		_telemetry_elapsed += _delta
		if _telemetry_elapsed >= 1.0:
			_telemetry_elapsed = 0.0
			_emit_gesture_telemetry()


func _emit_gesture_telemetry() -> void:
	# Distances only: no positions, prompts, or transcript content.
	var payload := {
		"event": "sample",
		"right": _hand_telemetry("right"),
		"left": _hand_telemetry("left"),
		"tracking_losses": _tracking_losses,
		"touch": _touch_target_id[preferred_hand],
		"grab": _grab_target_id,
		"pinching": _pointer_state.is_selecting,
	}
	print("GEST %s" % JSON.stringify(payload))
	if _telemetry_file != null:
		_telemetry_file.store_line(JSON.stringify(payload))
		_telemetry_file.flush()


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


func simulate_tick(delta: float = 0.016) -> bool:
	# Deterministic single step used by tests and the desktop lab.
	_collect_hand_samples(delta)
	var pointer_sample: Dictionary = _latest_hand_samples.get(preferred_hand, {})
	if pointer_sample.is_empty():
		_clear_pointer()
		return false
	var applied := _apply_pointer_sample(pointer_sample, delta)
	_update_bimanual_gesture()
	return applied


func _collect_hand_samples(delta: float) -> void:
	_latest_hand_samples.clear()
	for hand_name in ["left", "right"]:
		var sample := _sample_for_hand(hand_name)
		if sample.is_empty():
			_hand_pinch_states[hand_name] = false
			_cancel_tap(hand_name)
			continue
		_latest_hand_samples[hand_name] = sample
		var thumb_tip := sample.get("thumb_tip", Vector3.ZERO) as Vector3
		var index_tip := sample.get("index_tip", Vector3.ZERO) as Vector3
		var meta := _read_meta_hand(hand_name)
		if not meta.is_empty():
			sample["meta"] = meta
		var was_pinching := bool(_hand_pinch_states.get(hand_name, false))
		if meta.has("click"):
			_hand_pinch_states[hand_name] = bool(meta["click"])
		else:
			_hand_pinch_states[hand_name] = evaluate_pinch(
				thumb_tip.distance_to(index_tip),
				was_pinching,
				pinch_begin_distance,
				pinch_release_distance
			)
		_track_tap(hand_name)
	if _latest_hand_samples.is_empty():
		_missing_seconds += delta
		if _missing_seconds >= TRACKING_GRACE_SECONDS:
			_set_tracking_available(false)
		return
	_missing_seconds = 0.0
	_set_tracking_available(true)


func _clear_pointer() -> void:
	var had_state := _pointer_state.is_selecting or _pointer_state.is_grabbing
	if not _grab_target_id.is_empty():
		_finish_grab(_pointer_state.origin)
	_pointer_state.is_selecting = false
	_pointer_state.is_grabbing = false
	_pointer_state.direction = Vector3.ZERO
	_active_hand_name = ""
	_cancel_tap("left")
	_cancel_tap("right")
	_has_smoothed_ray = false
	_hand_pinch_states[preferred_hand] = false
	_touch_target_id = {"left": "", "right": ""}
	_touch_area = {"left": null, "right": null}
	_touch_release_needed = {"left": false, "right": false}
	_touch_candidate_id = {"left": "", "right": ""}
	_touch_dragged = {"left": false, "right": false}
	_touch_tap_fired = {"left": false, "right": false}
	_crush_seconds = 0.0
	_crush_latched = false
	_crush_candidate = ""
	_fist_prev = false
	if not _attract_target.is_empty():
		interaction_event.emit(InteractionEvent.new(
			InteractionEvent.Type.ATTRACT_END, _attract_target, InteractionEvent.Source.HAND
		))
		_attract_target = ""
	_fist_states["left"] = false
	_fist_states["right"] = false
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
	var distal_index := XRHandTracker.HAND_JOINT_INDEX_FINGER_PHALANX_DISTAL
	var index_distal := Vector3.ZERO
	if _joint_has_tracked_position(tracker, distal_index):
		index_distal = (origin_transform * tracker.get_hand_joint_transform(distal_index)).origin
	return {
		"hand_name": hand_name,
		"palm_transform": origin_transform * tracker.get_hand_joint_transform(XRHandTracker.HAND_JOINT_PALM),
		"thumb_tip": origin_transform * tracker.get_hand_joint_transform(XRHandTracker.HAND_JOINT_THUMB_TIP).origin,
		"index_tip": origin_transform * tracker.get_hand_joint_transform(XRHandTracker.HAND_JOINT_INDEX_FINGER_TIP).origin,
		"index_distal": index_distal,
		"index_proximal": joints.get("index_proximal", Vector3.ZERO),
		"joints": joints,
	}


const FULL_HAND_JOINTS := {
	"palm": XRHandTracker.HAND_JOINT_PALM,
	"wrist": XRHandTracker.HAND_JOINT_WRIST,
	"thumb_metacarpal": XRHandTracker.HAND_JOINT_THUMB_METACARPAL,
	"thumb_proximal": XRHandTracker.HAND_JOINT_THUMB_PHALANX_PROXIMAL,
	"thumb_distal": XRHandTracker.HAND_JOINT_THUMB_PHALANX_DISTAL,
	"thumb_tip": XRHandTracker.HAND_JOINT_THUMB_TIP,
	"index_metacarpal": XRHandTracker.HAND_JOINT_INDEX_FINGER_METACARPAL,
	"index_proximal": XRHandTracker.HAND_JOINT_INDEX_FINGER_PHALANX_PROXIMAL,
	"index_distal": XRHandTracker.HAND_JOINT_INDEX_FINGER_PHALANX_DISTAL,
	"index_tip": XRHandTracker.HAND_JOINT_INDEX_FINGER_TIP,
	"middle_metacarpal": XRHandTracker.HAND_JOINT_MIDDLE_FINGER_METACARPAL,
	"middle_proximal": XRHandTracker.HAND_JOINT_MIDDLE_FINGER_PHALANX_PROXIMAL,
	"middle_distal": XRHandTracker.HAND_JOINT_MIDDLE_FINGER_PHALANX_DISTAL,
	"middle_tip": XRHandTracker.HAND_JOINT_MIDDLE_FINGER_TIP,
	"ring_metacarpal": XRHandTracker.HAND_JOINT_RING_FINGER_METACARPAL,
	"ring_proximal": XRHandTracker.HAND_JOINT_RING_FINGER_PHALANX_PROXIMAL,
	"ring_distal": XRHandTracker.HAND_JOINT_RING_FINGER_PHALANX_DISTAL,
	"ring_tip": XRHandTracker.HAND_JOINT_RING_FINGER_TIP,
	"pinky_metacarpal": XRHandTracker.HAND_JOINT_PINKY_FINGER_METACARPAL,
	"pinky_proximal": XRHandTracker.HAND_JOINT_PINKY_FINGER_PHALANX_PROXIMAL,
	"pinky_distal": XRHandTracker.HAND_JOINT_PINKY_FINGER_PHALANX_DISTAL,
	"pinky_tip": XRHandTracker.HAND_JOINT_PINKY_FINGER_TIP,
}


func get_hand_joint_positions(hand_name: String) -> Dictionary:
	"""World-space positions for every tracked joint, for glove rendering."""
	var tracker_path := RIGHT_TRACKER_PATH if hand_name == "right" else LEFT_TRACKER_PATH
	var tracker := XRServer.get_tracker(tracker_path) as XRHandTracker
	if not _tracker_is_usable(tracker):
		return {}
	var origin_transform := _xr_origin.global_transform if _xr_origin != null else Transform3D.IDENTITY
	var stop_offset: Vector3 = _hand_stop_offset.get(hand_name, Vector3.ZERO)
	var result: Dictionary = {}
	for joint_name in FULL_HAND_JOINTS:
		var joint_index: int = FULL_HAND_JOINTS[joint_name]
		if _joint_has_tracked_position(tracker, joint_index):
			result[joint_name] = (
				origin_transform * tracker.get_hand_joint_transform(joint_index)
			).origin + stop_offset
	return result


func _compute_surface_stop(position: Vector3) -> Vector3:
	"""Push the hand out of a touch surface so it visually rests on the panel."""
	var best_push := 0.0
	var best_offset := Vector3.ZERO
	for node in get_tree().get_nodes_in_group("touch_surface"):
		var area := node as Area3D
		if area == null or not area.is_visible_in_tree():
			continue
		var shape_node := _box_shape_node(area)
		if shape_node == null:
			continue
		var box := shape_node.shape as BoxShape3D
		if box == null:
			continue
		var transform := shape_node.global_transform
		var local := transform.affine_inverse() * position
		var half := box.size * 0.5
		if absf(local.x) > half.x + 0.04 or absf(local.y) > half.y + 0.04:
			continue
		var front := half.z
		var margin := 0.012
		if local.z > front + margin or local.z < -half.z - 0.06:
			continue
		var push := clampf(front + margin - local.z, 0.0, 0.08)
		if push > best_push:
			best_push = push
			best_offset = transform.basis.z.normalized() * push
	return best_offset


func _box_shape_node(area: Area3D) -> CollisionShape3D:
	for child in area.get_children():
		var shape_node := child as CollisionShape3D
		if shape_node != null and shape_node.shape is BoxShape3D:
			return shape_node
	return null


func _read_meta_hand(hand_name: String) -> Dictionary:
	# Reads Meta's curated aim pose and pinch signal from the hand-interaction
	# profile action map (trigger = pinch strength, trigger_click = pinch).
	var tracker := XRServer.get_tracker(
		RIGHT_CONTROLLER_PATH if hand_name == "right" else LEFT_CONTROLLER_PATH
	)
	if tracker == null:
		return {}
	var result := {}
	if tracker.has_method("get_input"):
		var strength: Variant = tracker.call("get_input", &"trigger")
		if strength is float or strength is int:
			result["strength"] = float(strength)
	if tracker.has_method("is_button_pressed"):
		result["click"] = bool(tracker.call("is_button_pressed", &"trigger_click"))
	if tracker.has_method("get_pose"):
		var pose: Variant = tracker.call("get_pose", &"aim_pose")
		if pose is Transform3D:
			var origin_transform := (
				_xr_origin.global_transform if _xr_origin != null else Transform3D.IDENTITY
			)
			result["aim"] = origin_transform * (pose as Transform3D)
	return result


func get_latest_hand_sample(hand_name: String) -> Dictionary:
	var sample: Dictionary = _latest_hand_samples.get(hand_name, {})
	return sample.duplicate(true)


func is_hand_pinching(hand_name: String) -> bool:
	return bool(_hand_pinch_states.get(hand_name, false))


func cancel_touch_taps() -> void:
	# A surface drag (e.g. scrolling the palm) must not fire a button tap.
	for hand_name in ["left", "right"]:
		_touch_dragged[hand_name] = true
		_touch_candidate_id[hand_name] = ""
		_touch_tap_fired[hand_name] = true


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


func _apply_pointer_sample(sample: Dictionary, delta: float = 0.016) -> bool:
	var index_tip := sample.get("index_tip", Vector3.ZERO) as Vector3
	index_tip += _hand_stop_offset.get(preferred_hand, Vector3.ZERO)
	var index_distal := sample.get("index_distal", Vector3.ZERO) as Vector3
	var index_proximal := sample.get("index_proximal", Vector3.ZERO) as Vector3
	var thumb_tip := sample.get("thumb_tip", Vector3.ZERO) as Vector3
	var palm_transform := sample.get("palm_transform", Transform3D.IDENTITY) as Transform3D
	# A longer baseline (proximal to tip) is far more stable than the ~2 cm
	# distal-to-tip segment, which amplifies joint jitter into ray noise.
	# Fall back through shorter baselines when a joint is momentarily missing.
	var joints: Dictionary = sample.get("joints", {})
	var direction := Vector3.ZERO
	if joints.has("index_proximal"):
		direction = index_tip - index_proximal
	if direction.length_squared() < 0.0004 and not index_distal.is_zero_approx():
		direction = index_tip - index_distal
	if direction.length_squared() < 0.0004:
		var palm: Vector3 = joints.get("palm", Vector3.ZERO)
		direction = index_tip - palm if not palm.is_zero_approx() else Vector3.ZERO
	if direction.length_squared() < 0.000016:
		_pointer_missing_seconds = 0.0
		_clear_pointer()
		return false

	_set_tracking_available(true)
	if preferred_hand != _active_hand_name:
		_active_hand_name = preferred_hand
		_has_smoothed_ray = false
		active_hand_changed.emit(preferred_hand)

	var was_pinching := _pointer_state.is_selecting
	var meta: Dictionary = sample.get("meta", {})
	# Meta's pinch click is the commit gate when the hand-interaction profile is
	# active; otherwise fall back to the geometric pinch in `_hand_pinch_states`.
	var is_pinching := bool(_hand_pinch_states.get(preferred_hand, false))
	if meta.has("click"):
		is_pinching = bool(meta["click"])
	var ray_direction := direction.normalized()
	if meta.has("aim"):
		ray_direction = (-(meta["aim"] as Transform3D).basis.z).normalized()
	if _has_smoothed_ray:
		_pointer_state.origin = _pointer_state.origin.lerp(index_tip, origin_smoothing)
		_pointer_state.direction = _pointer_state.direction.lerp(ray_direction, direction_smoothing).normalized()
	else:
		_pointer_state.origin = index_tip
		_pointer_state.direction = ray_direction
		_has_smoothed_ray = true
	_pointer_state.is_selecting = is_pinching

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

	_pointer_state.is_grabbing = not _grab_target_id.is_empty()
	_update_fist_interaction(sample, index_tip, delta)
	_update_pinch_scroll(index_tip, was_pinching, is_pinching)
	pointer_state_changed.emit(_pointer_state.copy())
	hand_pose_changed.emit(preferred_hand, palm_transform, index_tip, is_pinching)
	return true


func _hand_is_fist(hand_name: String) -> bool:
	var sample: Dictionary = _latest_hand_samples.get(hand_name, {})
	if sample.is_empty():
		_fist_states[hand_name] = false
		return false
	var joints: Dictionary = sample.get("joints", {})
	if not joints.has("palm"):
		_fist_states[hand_name] = false
		return false
	var palm: Vector3 = joints["palm"]
	var curled_count := 0
	var extended_count := 0
	for joint_name in FIST_JOINTS:
		if not joints.has(joint_name):
			continue
		var distance: float = palm.distance_to(joints[joint_name])
		if distance <= FIST_CLOSE_DISTANCE:
			curled_count += 1
		if distance >= FIST_OPEN_DISTANCE:
			extended_count += 1
	var index_curled := (
		joints.has("index_tip")
		and palm.distance_to(joints["index_tip"]) <= FIST_CLOSE_DISTANCE
	)
	var was_fist: bool = _fist_states.get(hand_name, false)
	var is_fist: bool = (
		extended_count == 0
		if was_fist
		else curled_count >= FIST_MIN_CURLED and index_curled
	)
	_fist_states[hand_name] = is_fist
	return is_fist


func _update_fist_interaction(sample: Dictionary, index_tip: Vector3, delta: float) -> void:
	var is_fist := _hand_is_fist(preferred_hand)
	var palm_position := (sample.get("palm_transform", Transform3D.IDENTITY) as Transform3D).origin

	if not is_fist:
		_crush_latched = false
		_crush_candidate = ""
		_crush_seconds = 0.0
		_fist_prev = false
		if not _attract_target.is_empty():
			interaction_event.emit(InteractionEvent.new(
				InteractionEvent.Type.ATTRACT_END, _attract_target, InteractionEvent.Source.HAND
			))
			_attract_target = ""
		return
	_fist_prev = true

	# A fist physically inside an agent's core crushes it. Checked continuously
	# (not only at the instant the fist closes) so closing the hand first and then
	# reaching into an agent still deletes it, even with imprecise tracking.
	var core_orb := _nearest_orb_core(index_tip, CRUSH_CORE_RADIUS)
	if core_orb.is_empty():
		core_orb = _nearest_orb_core(palm_position, CRUSH_CORE_RADIUS)
	if not core_orb.is_empty():
		if not _attract_target.is_empty():
			interaction_event.emit(InteractionEvent.new(
				InteractionEvent.Type.ATTRACT_END, _attract_target, InteractionEvent.Source.HAND
			))
			_attract_target = ""
		if _crush_candidate != core_orb:
			_crush_candidate = core_orb
			_crush_seconds = 0.0
		_crush_seconds += delta
		if _crush_seconds >= CRUSH_HOLD_SECONDS and not _crush_latched:
			_crush_latched = true
			interaction_event.emit(InteractionEvent.new(
				InteractionEvent.Type.CRUSH,
				_crush_candidate,
				InteractionEvent.Source.HAND,
				index_tip,
				{"gesture": "crush"}
			))
		return

	# Not inside any agent: a fist summoned toward an agent pulls it to the palm.
	_crush_candidate = ""
	_crush_seconds = 0.0
	var hovered := _hover_target_id
	var valid_new := not hovered.is_empty() and not ":" in hovered
	if _attract_target.is_empty():
		var candidate := hovered if valid_new else _remembered_orb_hover()
		if candidate.is_empty():
			return
		_attract_target = candidate
		interaction_event.emit(InteractionEvent.new(
			InteractionEvent.Type.ATTRACT_BEGIN,
			_attract_target,
			InteractionEvent.Source.HAND,
			palm_position,
			{"gesture": "attract"}
		))
		return
	interaction_event.emit(InteractionEvent.new(
		InteractionEvent.Type.ATTRACT_MOVE,
		_attract_target,
		InteractionEvent.Source.HAND,
		palm_position,
		{"gesture": "attract"}
	))


func _nearest_orb_core(position: Vector3, radius: float) -> String:
	var best := ""
	var best_distance := radius
	for node in get_tree().get_nodes_in_group("interactable"):
		var area := node as Area3D
		if area == null or not area.is_visible_in_tree():
			continue
		if not area.has_method("get_interaction_target_id"):
			continue
		var target: String = str(area.call("get_interaction_target_id"))
		if target.is_empty() or ":" in target:
			continue
		var distance := position.distance_to(area.global_position)
		if distance <= best_distance:
			best_distance = distance
			best = target
	return best


func submit_joint_sample(
	hand_name: String,
	palm_transform: Transform3D,
	thumb_tip: Vector3,
	index_distal: Vector3,
	index_tip: Vector3,
	joints: Dictionary = {}
) -> bool:
	if not _session_active:
		return false
	var sample := {
		"hand_name": hand_name,
		"palm_transform": palm_transform,
		"thumb_tip": thumb_tip,
		"index_distal": index_distal,
		"index_tip": index_tip,
		"joints": joints,
	}
	_latest_hand_samples[hand_name] = sample
	_hand_pinch_states[hand_name] = evaluate_pinch(
		thumb_tip.distance_to(index_tip),
		bool(_hand_pinch_states.get(hand_name, false)),
		pinch_begin_distance,
		pinch_release_distance
	)
	_track_tap(hand_name)
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
		var surface := _bimanual_surface_target()
		if surface.is_empty():
			return
		_bimanual_active = true
		_bimanual_target_id = surface
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


func _bimanual_surface_target() -> String:
	# Prefer whatever surface the active ray hovers; else use whichever hand is
	# touching a grabbable pane surface. Any pane surface (id ends in _surface)
	# can be two-hand moved/scaled.
	if _hover_target_id.ends_with("_surface"):
		return _hover_target_id
	for hand_name in ["left", "right"]:
		var area: Area3D = _touch_area.get(hand_name, null)
		if area != null and area.is_in_group("grabbable") and area.has_method("get_interaction_target_id"):
			var target: String = str(area.call("get_interaction_target_id"))
			if target.ends_with("_surface"):
				return target
	return ""


func _set_tracking_available(value: bool) -> void:
	if _has_tracking_data == value:
		return
	_has_tracking_data = value
	if not value:
		_tracking_losses += 1
	tracking_changed.emit(value)


func _update_touch_interaction(hand_name: String, position: Vector3) -> void:
	# Physical touch behaves like the headset's system keyboard: the fingertip
	# presses a control on contact and latches until it pulls away.
	if _touch_release_needed[hand_name]:
		if _touch_area[hand_name] == null or _distance_to_area(_touch_area[hand_name], position) > TOUCH_RELEASE_DISTANCE:
			# Touch ended, but a missed release must not lose the tap: fire here
			# if the hold never got the chance to.
			if (
				not _touch_candidate_id[hand_name].is_empty()
				and not _touch_dragged[hand_name]
				and not _touch_tap_fired[hand_name]
			):
				submit_direct_touch(_touch_candidate_id[hand_name], _touch_candidate_position[hand_name])
			_touch_release_needed[hand_name] = false
			_touch_target_id[hand_name] = ""
			_touch_area[hand_name] = null
			_touch_candidate_id[hand_name] = ""
			_touch_dragged[hand_name] = false
			_touch_tap_fired[hand_name] = false
		elif not _touch_candidate_id[hand_name].is_empty():
			if _touch_candidate_position[hand_name].distance_to(position) > TOUCH_DRAG_CANCEL_DISTANCE:
				# The fingertip moved: this is a scroll, not a tap.
				_touch_dragged[hand_name] = true
			elif (
				not _touch_dragged[hand_name]
				and not _touch_tap_fired[hand_name]
				and _now_msec() - _touch_candidate_start_msec[hand_name] >= TOUCH_TAP_HOLD_MSEC
			):
				# Short hold with a steady fingertip counts as a tap. Firing on
				# contact+hold (not on release) survives hand-tracking dropouts.
				submit_direct_touch(_touch_candidate_id[hand_name], _touch_candidate_position[hand_name])
				_touch_tap_fired[hand_name] = true
			return
		else:
			return
	var contact := _nearest_touch_target(position)
	if contact.is_empty():
		return
	var target_id := str((contact as Dictionary)["target_id"])
	_touch_target_id[hand_name] = target_id
	_touch_area[hand_name] = contact["area"] as Area3D
	_touch_release_needed[hand_name] = true
	if ":" in target_id:
		# Screen controls arm a tap candidate; a scroll cancels it before it fires.
		_last_ui_touch_msec = _now_msec()
		_touch_candidate_id[hand_name] = target_id
		_touch_candidate_position[hand_name] = position
		_touch_candidate_start_msec[hand_name] = _now_msec()
		_touch_dragged[hand_name] = false
		_touch_tap_fired[hand_name] = false
	else:
		_touch_candidate_id[hand_name] = ""
		_touch_dragged[hand_name] = false
		_touch_tap_fired[hand_name] = false


func set_clock_override_msec(value: int) -> void:
	_clock_override_msec = value


func _now_msec() -> int:
	if _clock_override_msec >= 0:
		return _clock_override_msec
	return Time.get_ticks_msec()


func _cancel_tap(hand_name: String) -> void:
	# Tracking loss must never look like a pinch release, or a flickering
	# tracker turns into phantom double-pinches that toggle the console.
	_tap_begin_msec[hand_name] = 0
	_tap_prev_pinch[hand_name] = false
	_tap_pending[hand_name] = 0
	_single_tap_due[hand_name] = 0


func _track_tap(hand_name: String) -> void:
	var pinching := bool(_hand_pinch_states.get(hand_name, false))
	var was := bool(_tap_prev_pinch.get(hand_name, false))
	if pinching == was:
		return
	_tap_prev_pinch[hand_name] = pinching
	var now := _now_msec()
	if pinching:
		var prev_release := int(_tap_prev_release_msec.get(hand_name, 0))
		if prev_release > 0 and now - prev_release < TAP_GAP_MIN_MSEC:
			_tap_begin_msec[hand_name] = 0
			return
		_tap_begin_msec[hand_name] = now
		return
	var began := int(_tap_begin_msec.get(hand_name, 0))
	_tap_begin_msec[hand_name] = 0
	if began <= 0 or now - began < TAP_MIN_DURATION_MSEC:
		return
	_tap_prev_release_msec[hand_name] = now
	var empty_tap := hand_name != preferred_hand
	if hand_name == preferred_hand:
		empty_tap = _hover_target_id.is_empty() and _touch_target_id[preferred_hand].is_empty()
	if not empty_tap:
		_tap_pending[hand_name] = 0
		return
	_register_tap(hand_name, now)


func _register_tap(hand_name: String, now: int) -> void:
	if now < _summon_blocked_until_msec:
		return
	var pending := int(_tap_pending.get(hand_name, 0))
	if pending > 0 and now - pending <= DOUBLE_PINCH_WINDOW_MSEC:
		_tap_pending[hand_name] = 0
		_single_tap_due[hand_name] = 0
		_summon_blocked_until_msec = now + SUMMON_COOLDOWN_MSEC
		interaction_event.emit(InteractionEvent.new(
			InteractionEvent.Type.SUMMON,
			"ui:summon",
			InteractionEvent.Source.HAND,
			Vector3.ZERO,
			{"gesture": "double_pinch", "hand": hand_name}
		))
		return
	_tap_pending[hand_name] = now
	if hand_name != preferred_hand:
		return
	# Do not dismiss on the first tap: it may be the opening tap of a
	# double-pinch. Defer the "empty pinch drops focus" action until the
	# double-pinch window has elapsed (see _flush_single_taps).
	_single_tap_due[hand_name] = now


func _flush_single_taps() -> void:
	var hand_name := preferred_hand
	var due := int(_single_tap_due.get(hand_name, 0))
	if due <= 0:
		return
	if _now_msec() - due <= DOUBLE_PINCH_WINDOW_MSEC:
		return
	_single_tap_due[hand_name] = 0
	_tap_pending[hand_name] = 0
	if _ui_owns_pointer():
		# Poking the console must not drop the agent you selected.
		return
	# A single pinch in empty space drops focus so nothing stays stuck.
	interaction_event.emit(InteractionEvent.new(
		InteractionEvent.Type.DISMISS,
		"",
		InteractionEvent.Source.HAND,
		null,
		{"gesture": "empty_pinch", "hand": hand_name}
	))


func get_tracking_flags() -> Dictionary:
	return {
		"left": _latest_hand_samples.has("left"),
		"right": _latest_hand_samples.has("right"),
	}


func get_fist_state(hand_name: String) -> bool:
	return bool(_fist_states.get(hand_name, false))


func _ui_owns_pointer() -> bool:
	if AppState.palm_console_open:
		return true
	return _now_msec() - _last_ui_touch_msec <= 400


func _remembered_orb_hover() -> String:
	if _last_orb_hover_id.is_empty():
		return ""
	if _now_msec() - _last_orb_hover_msec > ATTRACT_MEMORY_MSEC:
		return ""
	return _last_orb_hover_id


func _begin_grab_if_touching(position: Vector3) -> bool:
	var target: String = str(_touch_target_id[preferred_hand])
	if target.is_empty():
		return false
	var area: Area3D = _touch_area[preferred_hand]
	var grabbable := area != null and area.is_in_group("grabbable")
	# Namespaced ids (ui:…) are normally tap-only, but marked grabbable surfaces
	# (floating panes) can be directly grabbed.
	if ":" in target and not grabbable:
		return false
	_grab_target_id = target
	_grab_origin_position = position
	interaction_event.emit(InteractionEvent.new(
		InteractionEvent.Type.GRAB_BEGIN,
		_grab_target_id,
		InteractionEvent.Source.HAND,
		position,
		{"gesture": "orb_grab", "phase": "begin"}
	))
	return true


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
	_cancel_tap("left")
	_cancel_tap("right")
	_fist_prev = false
	_crush_candidate = ""
	_last_orb_hover_id = ""
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
