class_name QrScanService
extends Node3D

## Pairing by QR. When the daemon reports the device is unpaired, a minimal
## crosshair appears and prompts the user to aim at the QR in the Spatial Agent
## app. Camera frames (native "PassthroughCamera" plugin, else CameraServer) are
## streamed to the daemon, which decodes the QR and returns the pairing payload.

@export var user_rig_path: NodePath = ^"../UserRig"
@export var backend_bridge_path: NodePath = ^"../BackendBridge"
@export_range(0.8, 3.0, 0.05) var scan_distance: float = 1.8
@export_range(2, 30, 1) var scan_every_frames: int = 6

const PROMPT_SCAN := "AIM AT THE QR IN THE SPATIAL AGENT APP"
const PROMPT_NO_CAMERA := "NO CAMERA - ENTER THE CODE IN THE PALM FIELD"

var _camera: Camera3D = null
var _bridge: BackendBridge = null
var _viewport: SubViewport = null
var _capture_rect: TextureRect = null
var _reticle: Node3D = null
var _reticle_material: StandardMaterial3D = null
var _prompt: Label3D = null
var _camera_texture: CameraTexture = null
var _feed_index := -1
var _scanning := false
var _camera_ok := false
var _use_plugin := false
var _plugin_started := false
var _permission_requested := false
var _frame := 0


func _ready() -> void:
	var rig := get_node_or_null(user_rig_path) as UserRig
	if rig != null:
		_camera = rig.get_camera()
	_bridge = get_node_or_null(backend_bridge_path) as BackendBridge
	_build()
	if Engine.has_singleton("PassthroughCamera"):
		_use_plugin = true
	EventBus.qr_pairing_payload.connect(_on_payload)
	EventBus.pairing_required.connect(_on_pairing_required)
	visible = false


func is_scanning() -> bool:
	return _scanning


func camera_available() -> bool:
	if _use_plugin:
		var plugin := Engine.get_singleton("PassthroughCamera")
		if plugin != null and bool(plugin.call("hasPermission")) and int(plugin.call("cameraCount")) > 0:
			return true
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
	_set_prompt(PROMPT_SCAN)

	if _use_plugin:
		var plugin := Engine.get_singleton("PassthroughCamera")
		if plugin != null:
			if not bool(plugin.call("hasPermission")):
				if not _permission_requested:
					_permission_requested = true
					plugin.call("requestPermission")
				AppState.set_update_banner("Allow camera access to scan")
				return true
			if int(plugin.call("cameraCount")) > 0:
				plugin.call("start")
				_plugin_started = true
				_camera_ok = true
				AppState.set_update_banner("Aim at the pairing QR")
				return true

	_camera_ok = camera_available()
	if _camera_ok:
		_feed_index = 0
		var feed := CameraServer.get_feed(_feed_index)
		feed.feed_is_active = true
		_camera_texture = feed.get_texture(CameraServer.FEED_RGBA_IMAGE)
		if _capture_rect != null:
			_capture_rect.texture = _camera_texture
		AppState.set_update_banner("Aim at the pairing QR")
	else:
		_set_prompt(PROMPT_NO_CAMERA)
		AppState.set_update_banner("No passthrough camera; enter the code")
	return true


func stop_scan() -> void:
	if _use_plugin and _plugin_started:
		var plugin := Engine.get_singleton("PassthroughCamera")
		if plugin != null:
			plugin.call("stop")
		_plugin_started = false
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
	if _use_plugin:
		_poll_plugin()
		return
	if not _camera_ok:
		return
	_frame += 1
	if _frame % scan_every_frames == 0:
		_capture_viewport()


func _poll_plugin() -> void:
	var plugin := Engine.get_singleton("PassthroughCamera")
	if plugin == null:
		return
	if not _plugin_started:
		if not bool(plugin.call("hasPermission")):
			if not _permission_requested:
				_permission_requested = true
				plugin.call("requestPermission")
			return
		if int(plugin.call("cameraCount")) <= 0:
			_set_prompt(PROMPT_NO_CAMERA)
			return
		plugin.call("start")
		_plugin_started = true
		_camera_ok = true
	_frame += 1
	if _frame % scan_every_frames != 0:
		return
	var bytes: PackedByteArray = plugin.call("frameJpeg")
	if bytes.is_empty():
		return
	if _bridge != null:
		_bridge.send_command("pair.decode", {"image": Marshalls.raw_to_base64(bytes)})


func _capture_viewport() -> void:
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
	_set_reticle_detected(true)
	_set_prompt("QR DETECTED - PAIRING…")
	var transport = ServiceRegistry.backend_transport
	var paired := false
	if transport != null and transport.has_method("pair_with_payload"):
		paired = bool(transport.call("pair_with_payload", payload))
	if paired:
		stop_scan()
		AppState.set_update_banner("Paired - welcome")
	else:
		_set_reticle_detected(false)
		_set_prompt(PROMPT_SCAN)
		AppState.set_update_banner("QR read but pairing failed; try again")


func _set_reticle_detected(detected: bool) -> void:
	if _reticle_material == null:
		return
	_reticle_material.albedo_color = (
		Color(0.25, 1.0, 0.45) if detected else Color(1.0, 0.22, 0.2)
	)


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
	_reticle_material = StandardMaterial3D.new()
	_reticle_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_reticle_material.albedo_color = Color(1.0, 0.22, 0.2)
	_reticle_material.no_depth_test = true

	# A red square (frame) reticle to aim the QR inside.
	_reticle = Node3D.new()
	add_child(_reticle)
	var half := 0.075
	var edge := 0.006
	for spec in [
		[Vector3(half * 2.0 + edge, edge, edge), Vector3(0.0, half, 0.0)],
		[Vector3(half * 2.0 + edge, edge, edge), Vector3(0.0, -half, 0.0)],
		[Vector3(edge, half * 2.0 + edge, edge), Vector3(-half, 0.0, 0.0)],
		[Vector3(edge, half * 2.0 + edge, edge), Vector3(half, 0.0, 0.0)],
	]:
		var bar := MeshInstance3D.new()
		var bar_mesh := BoxMesh.new()
		bar_mesh.size = spec[0]
		bar.mesh = bar_mesh
		bar.material_override = _reticle_material
		bar.position = spec[1]
		_reticle.add_child(bar)

	_prompt = Label3D.new()
	_prompt.text = PROMPT_SCAN
	_prompt.font_size = 22
	_prompt.outline_size = 10
	_prompt.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_prompt.modulate = Color(0.8, 0.99, 1.0)
	_prompt.position = Vector3(0.0, 0.12, 0.01)
	_prompt.no_depth_test = true
	add_child(_prompt)

	# Offscreen capture target for the CameraServer fallback.
	_viewport = SubViewport.new()
	_viewport.size = Vector2i(480, 360)
	_viewport.transparent_bg = false
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(_viewport)
	_capture_rect = TextureRect.new()
	_capture_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	_capture_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_capture_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	_capture_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_viewport.add_child(_capture_rect)
