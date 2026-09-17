extends Node


func _ready() -> void:
	call_deferred("_compose_showcase")


func _compose_showcase() -> void:
	var main := $Main
	var rig := main.get_node("UserRig") as UserRig
	var camera := rig.get_camera()
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	rig.set_process(false)
	rig.set_process_unhandled_input(false)
	(rig.get_node("YawPivot") as Node3D).rotation = Vector3.ZERO
	(rig.get_node("YawPivot/PitchPivot") as Node3D).rotation = Vector3.ZERO
	AppState.set_provider_identity("openai", "gpt-6-astra")
	AppState.focus_thread("thread_demo")

	var orb_manager := main.get_node("OrbManager") as OrbManager
	for thread_id in AppState.ordered_thread_ids:
		var orb := orb_manager.get_orb(thread_id)
		if orb != null:
			orb.global_position = orb.get_target_global_position()
			orb.set_process(false)
	var layer := main.get_node("CognitionLayer") as CognitionLayer
	_seed_causal_trace(layer)
	layer._process(1.0)
	var viewer := main.get_node("CodeViewer") as CodeViewer
	viewer.open_focused_thread()

	var palm_console := main.get_node("PalmConsole") as PalmConsole
	palm_console.set_physics_process(false)
	var camera_basis := camera.global_transform.basis.orthonormalized()
	palm_console.global_transform = Transform3D(
		camera_basis,
		camera.global_position + camera_basis * Vector3(-0.71, -0.38, -0.92)
	)
	palm_console.visible = true
	palm_console._refresh_telemetry()

	var hand_ray := main.get_node("HandRayVisualizer") as HandRayVisualizer
	hand_ray.set_process(false)
	hand_ray.visible = true
	var ray_origin := camera.global_position + camera_basis * Vector3(0.62, -0.48, -0.48)
	var aim_target := (layer.get_node("TemporalRibbon/ModeTarget") as Node3D).global_position
	_place_hand_ray(hand_ray, ray_origin, aim_target)


func _seed_causal_trace(layer: CognitionLayer) -> void:
	layer.record_command("message.send", "thread_demo")
	for event_type in [
		"agent.status",
		"agent.message.started",
		"agent.message.delta",
		"tool.running",
		"tool.completed",
		"agent.message.completed",
		"run.completed",
	]:
		var payload := {"status": "working"} if event_type == "agent.status" else {}
		layer.ingest_backend_event(BackendEvent.new(
			event_type,
			payload,
			"evt_showcase_%s" % event_type.replace(".", "_"),
			"sess_showcase",
			"thread_demo",
			"2026-09-15T12:00:00Z"
		))


func _place_hand_ray(hand_ray: HandRayVisualizer, origin: Vector3, target: Vector3) -> void:
	var direction := (target - origin).normalized()
	var length := origin.distance_to(target)
	var side := direction.cross(Vector3.UP)
	if side.length_squared() < 0.0001:
		side = direction.cross(Vector3.RIGHT)
	side = side.normalized()
	var forward := side.cross(direction).normalized()
	var beam := hand_ray.get_node("Beam") as MeshInstance3D
	beam.global_transform = Transform3D(
		Basis(side, direction, forward).orthonormalized(),
		origin + direction * length * 0.5
	)
	beam.scale = Vector3(1.0, length, 1.0)
	(hand_ray.get_node("FingerLight") as MeshInstance3D).global_position = origin
	(hand_ray.get_node("AimLight") as MeshInstance3D).global_position = target
