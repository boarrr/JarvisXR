class_name QrScanService
extends Node3D

## Pairing by QR: shows the passthrough camera, streams frames to the daemon
## (which decodes the QR), then completes pairing from the decoded payload.

@export var user_rig_path: NodePath = ^"../UserRig"
@export var backend_bridge_path: NodePath = ^"../BackendBridge"
@export_range(0.6, 2.0, 0.05) var scan_distance: float = 1.0
@export_range(2, 30, 1) var scan_every_frames: int = 8

var _camera: Camera3D = null
var _bridge: BackendBridge = null
var _viewport: SubViewport = null
var _capture_rect: TextureRect = null
var _quad: MeshInstance3D = null
var _camera_texture: CameraTexture = null
var _feed_index := -1
var _scanning := false
var _frame := 0


func _ready() -> void:
	var rig := get_node_or_null(user_rig_path) as UserRig
	if rig != null:
		_camera = rig.get_camera()
	_bridge = get_node_or_null(backend_bridge_path) as BackendBridge
	_build()
	EventBus.qr_pairing_payload.connect(_on_payload)
	visible = false


func is_scanning() -> bool:
	return _scanning


func camera_available() -> bool:
	return CameraServer.get_feed_count() > 0


func toggle_scan() -> bool:
	if _scanning:
		stop_scan()
		return false
	return start_scan()


func start_scan() -> bool:
	if not camera_available():
		AppState.set_update_banner("No passthrough camera available")
		EventBus.debug_message.emit("QR scan unavailable: no camera feed")
		return false
	_feed_index = 0
	var feed := CameraServer.get_feed(_feed_index)
	feed.feed_is_active = true
	_camera_texture = feed.get_texture(CameraServer.FEED_RGBA_IMAGE)
	if _quad != null and _quad.material_override is StandardMaterial3D:
		(_quad.material_override as StandardMaterial3D).albedo_texture = _camera_texture
	if _capture_rect != null:
		_capture_rect.texture = _camera_texture
	_scanning = true
	_frame = 0
	visible = true
	_place()
	AppState.set_update_banner("Scan the daemon's pairing QR")
	return true


func stop_scan() -> void:
	if _feed_index >= 0:
		var feed := CameraServer.get_feed(_feed_index)
		if feed != null:
			feed.feed_is_active = false
	_scanning = false
	visible = false


func _process(_delta: float) -> void:
	if not _scanning:
		return
	_place()
	_frame += 1
	if _frame % scan_every_frames == 0:
		_capture_and_send()


func _capture_and_send() -> void:
	if _viewport == null or _bridge == null:
		return
	var image := _viewport.get_texture().get_image()
	if image == null:
		return
	var bytes := image.save_jpg_to_buffer(0.6)
	if bytes.is_empty():
		bytes = image.save_png_to_buffer()
	if bytes.is_empty():
		return
	_bridge.send_command("pair.decode", {"image": Marshalls.raw_to_base64(bytes)})


func _on_payload(payload: String) -> void:
	if not _scanning or payload.strip_edges().is_empty():
		return
	var transport = ServiceRegistry.backend_transport
	var paired := false
	if transport != null and transport.has_method("pair_with_payload"):
		paired = bool(transport.call("pair_with_payload", payload))
	if paired:
		stop_scan()
		AppState.set_update_banner("Paired - welcome")
	else:
		AppState.set_update_banner("QR read but pairing failed")


func _place() -> void:
	if _camera == null:
		return
	var basis := _camera.global_transform.basis.orthonormalized()
	global_transform = Transform3D(
		basis, _camera.global_position + basis * Vector3(0.0, 0.0, -scan_distance)
	)


func _build() -> void:
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = Color.WHITE
	_quad = MeshInstance3D.new()
	var mesh := QuadMesh.new()
	mesh.size = Vector2(0.9, 0.68)
	_quad.mesh = mesh
	_quad.material_override = material
	_quad.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_quad)

	var title := Label3D.new()
	title.text = "SCAN PAIRING QR"
	title.font_size = 48
	title.position = Vector3(0.0, 0.42, 0.02)
	title.modulate = Color(0.7, 0.98, 1.0)
	add_child(title)

	_viewport = SubViewport.new()
	_viewport.size = Vector2i(360, 270)
	_viewport.transparent_bg = false
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(_viewport)
	_capture_rect = TextureRect.new()
	_capture_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	_capture_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_capture_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	_capture_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_viewport.add_child(_capture_rect)
