class_name XRRuntime
extends Node3D

signal mode_changed(is_xr_active: bool)

@export var user_rig_path: NodePath = ^"../UserRig"
@export var world_environment_path: NodePath = ^"../WorldEnvironment"

@onready var _origin: XROrigin3D = $XROrigin3D
@onready var _camera: XRCamera3D = $XROrigin3D/XRCamera3D
@onready var _hand_source: OpenXRInteractionSource = $OpenXRInteractionSource

var _user_rig: UserRig = null
var _world_environment: WorldEnvironment = null
var _is_active := false
var _desktop_background_color := Color(0.002, 0.008, 0.014, 1.0)
var _desktop_transparent_background := false
var _desktop_vsync_mode := DisplayServer.VSYNC_ENABLED


func _ready() -> void:
	_user_rig = get_node_or_null(user_rig_path) as UserRig
	_world_environment = get_node_or_null(world_environment_path) as WorldEnvironment
	_hand_source.set_xr_origin(_origin)
	set_process(false)


func activate_if_available() -> bool:
	if _is_active:
		return true
	var openxr_interface := XRServer.find_interface("OpenXR") as OpenXRInterface
	if openxr_interface == null or not openxr_interface.is_initialized():
		return false

	_is_active = true
	_desktop_transparent_background = get_viewport().transparent_bg
	_desktop_vsync_mode = DisplayServer.window_get_vsync_mode()
	get_viewport().use_xr = true
	get_viewport().transparent_bg = true
	get_viewport().vrs_mode = Viewport.VRS_XR
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	_configure_passthrough_background(true)
	var target_rate := float(ProjectSettings.get_setting("spatial_agent/xr_refresh_rate", 72.0))
	if target_rate > 0.0:
		openxr_interface.set_display_refresh_rate(target_rate)
		print("[XR] requested display refresh rate: %.0f Hz" % target_rate)
	if _user_rig != null:
		_user_rig.set_xr_tracking_active(true)
	_hand_source.set_hand_tracking_active(true)
	set_process(true)
	mode_changed.emit(true)
	return true


func deactivate() -> void:
	if not _is_active:
		return
	_is_active = false
	set_process(false)
	_hand_source.set_hand_tracking_active(false)
	if _user_rig != null:
		_user_rig.set_xr_tracking_active(false)
	get_viewport().use_xr = false
	get_viewport().transparent_bg = _desktop_transparent_background
	get_viewport().vrs_mode = Viewport.VRS_DISABLED
	DisplayServer.window_set_vsync_mode(_desktop_vsync_mode)
	_configure_passthrough_background(false)
	mode_changed.emit(false)


func _process(_delta: float) -> void:
	if _is_active and _user_rig != null:
		_user_rig.sync_from_xr_camera(_camera)


func is_xr_active() -> bool:
	return _is_active


func get_hand_source() -> OpenXRInteractionSource:
	return _hand_source


func get_xr_camera() -> XRCamera3D:
	return _camera


func get_xr_origin() -> XROrigin3D:
	return _origin


func _configure_passthrough_background(enabled: bool) -> void:
	if _world_environment == null or _world_environment.environment == null:
		return
	var environment := _world_environment.environment
	if enabled:
		_desktop_background_color = environment.background_color
		var passthrough_color := environment.background_color
		passthrough_color.a = 0.0
		environment.background_color = passthrough_color
	else:
		environment.background_color = _desktop_background_color
