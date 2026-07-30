extends SceneTree

const MAIN_SCENE := "res://scenes/levels/island_test/island_test_BLENDER.tscn"
const WARMUP_FRAMES := 20
const MEASURED_FRAMES := 120

# Reproducible same-scene render-submission proxy. It compares identical
# high-quality wake geometry with the analytic interaction uniforms disabled
# and enabled; it is not a hardware-independent GPU timing.


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var packed := load(MAIN_SCENE) as PackedScene
	if packed == null:
		push_error("No se pudo cargar la escena principal.")
		quit(1)
		return
	var island := packed.instantiate()
	root.add_child(island)
	for _index in 3:
		await process_frame
	var ocean := island.get_node_or_null("WaterIntegration/Ocean") as Ocean3D
	var vehicle := island.get_node_or_null("Gameplay/JetSki") as JetSkiController
	var wake := (
		vehicle.find_child("WakeTrail3D", true, false) as WakeTrail3D
		if vehicle != null
		else null
	)
	if ocean == null or vehicle == null or wake == null:
		push_error("Faltan Ocean3D, JetSkiController o WakeTrail3D.")
		island.free()
		quit(1)
		return
	vehicle.freeze = true
	vehicle.process_mode = Node.PROCESS_MODE_DISABLED
	wake.process_mode = Node.PROCESS_MODE_DISABLED
	ocean.process_mode = Node.PROCESS_MODE_DISABLED
	_prepare_high_quality_wake(ocean, vehicle, wake)
	_position_benchmark_camera(island, vehicle)

	_set_interactions(ocean, false)
	var disabled_msec := await _measure_frames()
	_set_interactions(ocean, true)
	var enabled_msec := await _measure_frames()
	print("OCEAN_INTERACTION_RENDER_PROXY_DISABLED_FRAME_MSEC=%.3f" % disabled_msec)
	print("OCEAN_INTERACTION_RENDER_PROXY_ENABLED_FRAME_MSEC=%.3f" % enabled_msec)
	print(
		"OCEAN_INTERACTION_RENDER_PROXY_DELTA_MSEC=%.3f"
		% (enabled_msec - disabled_msec)
	)
	var screenshot := root.get_texture().get_image()
	var screenshot_path := "res://.godot/ocean_vehicle_interaction_benchmark.png"
	var screenshot_error := screenshot.save_png(screenshot_path)
	print(
		"OCEAN_INTERACTION_SCREENSHOT=%s"
		% (
			ProjectSettings.globalize_path(screenshot_path)
			if screenshot_error == OK
			else "ERROR_%d" % screenshot_error
		)
	)
	print("OCEAN_INTERACTION_BENCHMARK=PASS")
	island.free()
	packed = null
	await process_frame
	quit(0)


func _prepare_high_quality_wake(
	ocean: Ocean3D,
	vehicle: JetSkiController,
	wake: WakeTrail3D
) -> void:
	vehicle.navigation_system.state.navigation_state = (
		JetSkiTypes.NavigationState.IN_WATER
	)
	vehicle.navigation_system.state.current_contact_mask = 15
	vehicle.water_physics_system.state.raw_contact_mask = 15
	vehicle.water_physics_system.state.submerged_ratio = 1.0
	vehicle.water_physics_system.state.front_submerged_ratio = 1.0
	vehicle.water_physics_system.state.rear_submerged_ratio = 1.0
	vehicle.water_physics_system.state.average_depth = 0.25
	vehicle.water_physics_system.state.average_water_velocity = Vector3.ZERO
	vehicle.water_physics_system.state.water_relative_forward_speed = 24.0
	vehicle.drive_system.state.propulsion_contact_factor = 1.0
	vehicle.linear_velocity = Vector3(0.0, 0.0, -24.0)
	wake.clear_trail(false)
	for _index in 24:
		wake.call("_try_add_sample")
		wake.call("_age_samples", 0.04)
		vehicle.global_position += Vector3(0.0, 0.0, -2.0)
	ocean.set_vehicle_interaction_quality(2)
	ocean.call("_update_vehicle_interactions", 0.05)


func _set_interactions(ocean: Ocean3D, enabled: bool) -> void:
	ocean.directional_wake_enabled = enabled
	ocean.hull_pressure_enabled = enabled
	ocean.apply_ocean_settings()
	ocean.call("_update_vehicle_interactions", 0.05)
	ocean.call("_push_vehicle_interaction_parameters_to_all_materials")


func _position_benchmark_camera(
	island: Node,
	vehicle: JetSkiController
) -> void:
	var camera := island.get_node_or_null(
		"CameraSystem/ChaseCamera/Camera3D"
	) as Camera3D
	if camera == null:
		return
	camera.get_parent().process_mode = Node.PROCESS_MODE_DISABLED
	var wake_midpoint := vehicle.global_position + Vector3(0.0, 0.0, 24.0)
	camera.global_position = wake_midpoint + Vector3(19.0, 18.0, 2.0)
	camera.look_at(wake_midpoint, Vector3.UP)


func _measure_frames() -> float:
	for _index in WARMUP_FRAMES:
		await process_frame
	var start_usec := Time.get_ticks_usec()
	for _index in MEASURED_FRAMES:
		await process_frame
	var elapsed_usec := Time.get_ticks_usec() - start_usec
	return float(elapsed_usec) / 1000.0 / float(MEASURED_FRAMES)
