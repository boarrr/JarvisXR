class_name QrScanService
extends Node3D

## Pairing by QR. When the daemon reports the device is unpaired, this dialog
## appears automatically: it frames the passthrough camera and prompts the user
## to scan the QR shown in the Spatial Agent desktop app. It streams frames to
## the daemon (which decodes the QR) and pairs from the decoded payload.

@export var user_rig_path: NodePath = ^"../UserRig"
@export var backend_bridge_path: NodePath = ^"../BackendBridge"
@export_range(0.6, 2.0, 0.05) var scan_distance: float = 1.2
@export_range(2, 30, 1) var scan_every_frames: int = 8

const PROMPT_SCAN := "SCAN THE QR CODE IN THE\nSPATIAL AGENT APP"
const PROMPT_NO_CAMERA := "NO CAMERA FEED\nENTER THE PAIRING CODE IN THE PALM FIELD"

var _camera: Camera3D = null
var _bridge: BackendBridge = null
var _viewport: SubViewport = null
var _capture_rect: TextureRect = null
var _quad: MeshInstance3D = null
var _prompt: Label3D = null
var _camera_texture: CameraTexture = null
var _feed_index := -1
var _scanning := false
var _camera_ok := false
var _frame := 0


func _ready() -> void:
	var rig := get_node_or_null(user_rig_path) as UserRig
	if rig != null:
		_camera = rig.get_camera()
	_bridge = get_node_or_null(backend_bridge_path) as BackendBridge
	_build()
	EventBus.qr_pairing_payload.connect(_on_payload)
	EventBus.pairing_required.connect(_on_pairing_required)
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


func _on_pairing_required() -> void:
	if not _scanning:
		start_scan()


func start_scan() -> bool:
	_scanning = true
	_frame = 0
	visible = true
	_place()
	_camera_ok = camera_available()
	if _camera_ok:
		_feed_index = 0
		var feed := CameraServer.get_feed(_feed_index)
		feed.feed_is_active = true
		_camera_texture = feed.get_texture(CameraServer.FEED_RGBA_IMAGE)
		if _quad != null and _quad.material_override is StandardMaterial3D:
			(_quad.material_override as StandardMaterial3D).albedo_texture = _camera_texture
			_quad.visible = true
		if _capture_rect != null:
			_capture_rect.texture = _camera_texture
		_set_prompt(PROMPT_SCAN)
		AppState.set_update_banner("Scan the pairing QR from the app")
	else:
		if _quad != null:
			_quad.visible = false
		_set_prompt(PROMPT_NO_CAMERA)
		AppState.set_update_banner("No passthrough camera; enter the code")
		EventBus.debug_message.emit("QR scan unavailable: no camera feed")
	return true


func stop_scan() -> void:
	if _feed_index >= 0:
		var feed := CameraServer.get_feed(_feed_index)
		if feed != null:
			feed.feed_is_active = false
	_feed_index = -1
	_camera_ok = false
	_scanning = false
	visible = false


func _process(_delta: float) -> void:
	if not _scanning:
		return
	_place()
	if not _camera_ok:
		return
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
		AppState.set_update_banner("QR read but pairing failed; try again")


func _set_prompt(text: String) -> void:
	if _prompt != null:
		_prompt.text = text


func _place() -> void:
	if _camera == null:
		return
	var basis := _camera.global_transform.basis.orthonormalized()
	global_transform = Transform3D(
		basis, _camera.global_position + basis * Vector3(0.0, -0.05, -scan_distance)
	)


func _build() -> void:
	# Frame: a slightly larger dark panel behind the camera view.
	var frame_material := StandardMaterial3D.new()
	frame_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	frame_material.albedo_color = Color(0.02, 0.09, 0.13, 0.96)
	var frame := MeshInstance3D.new()
	var frame_mesh := QuadMesh.new()
	frame_mesh.size = Vector2(0.78, 0.66)
	frame.mesh = frame_mesh
	frame.material_override = frame_material
	frame.position = Vector3(0.0, 0.0, -0.01)
	frame.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(frame)

	var camera_material := StandardMaterial3D.new()
	camera_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	camera_material.albedo_color = Color(0.03, 0.07, 0.1)
	_quad = MeshInstance3D.new()
	var mesh := QuadMesh.new()
	mesh.size = Vector2(0.7, 0.5)
	_quad.mesh = mesh
	_quad.material_override = camera_material
	_quad.visible = false
	_quad.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_quad)

	_prompt = Label3D.new()
	_prompt.text = PROMPT_SCAN
	_prompt.font_size = 40
	_prompt.modulate = Color(0.7, 0.98, 1.0)
	_prompt.position = Vector3(0.0, 0.46, 0.02)
	add_child(_prompt)

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
