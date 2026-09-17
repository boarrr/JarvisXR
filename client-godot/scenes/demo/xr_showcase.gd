extends Node


func _ready() -> void:
	call_deferred("_compose_showcase")


func _compose_showcase() -> void:
	var main := $Main
	var rig := main.get_node("UserRig") as UserRig
	var camera := rig.get_camera()
	AppState.set_provider_identity("openai", "gpt-6-astra")
	AppState.focus_thread("thread_debug_03")

	var quick_panel := main.get_node("QuickIntentPanel") as QuickIntentPanel
	quick_panel.open()
	var quick_basis := camera.global_transform.basis.orthonormalized()
	quick_panel.global_transform = Transform3D(
		quick_basis,
		camera.global_position + quick_basis * Vector3(0.0, -0.05, -1.28)
	)

	var palm_console := main.get_node("PalmConsole") as PalmConsole
	palm_console.set_physics_process(false)
	palm_console.global_transform = Transform3D(
		quick_basis,
		camera.global_position + quick_basis * Vector3(-0.73, -0.36, -0.95)
	)
	palm_console.visible = true
	palm_console._refresh_telemetry()

	var hand_ray := main.get_node("HandRayVisualizer") as HandRayVisualizer
	hand_ray.set_process(false)
	hand_ray.visible = true
	var ray_origin := camera.global_position + quick_basis * Vector3(0.62, -0.48, -0.5)
	var aim_target := (quick_panel.get_node("ContinueTarget") as Node3D).global_position
	_place_hand_ray(hand_ray, ray_origin, aim_target)
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


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
