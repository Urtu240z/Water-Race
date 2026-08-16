extends Node

const GOLD_CITY_SCENE := "res://levels/gold_city/gold_city.tscn"
const WARMUP_FRAMES := 45
const MEASURED_FRAMES := 180


func _ready() -> void:
	call_deferred(&"_run")


func _run() -> void:
	Engine.max_fps = 0
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	var packed := load(GOLD_CITY_SCENE) as PackedScene
	if packed == null:
		push_error("Could not load Gold City for the traffic-wake benchmark.")
		get_tree().quit(1)
		return
	# Keep this runner outside current_scene, then let Godot install Gold City as
	# the actual current scene so path-derived baked resources resolve normally.
	get_tree().current_scene = null
	var scene_error := get_tree().change_scene_to_packed(packed)
	if scene_error != OK:
		push_error("Could not switch to Gold City for the traffic-wake benchmark.")
		get_tree().quit(1)
		return
	await get_tree().scene_changed
	var city := get_tree().current_scene
	for _frame in 8:
		await get_tree().process_frame
	var ocean := city.get_node_or_null("WaterIntegration/Ocean") as Ocean3D
	var actor := city.get_node_or_null(
		"BoatTraffic/Path3D/PathFollow3D/BoatTrafficActor"
	) as BoatTrafficActor
	var camera := city.get_node_or_null(
		"CameraSystem/ChaseCamera/Camera3D"
	) as Camera3D
	var wake := (
		actor.get_node_or_null("WakeRoot/BoatWake") as WakeTrail3D
		if actor != null
		else null
	)
	if ocean == null or actor == null or camera == null or wake == null:
		push_error("Gold City benchmark could not resolve Ocean, boat, camera, or wake.")
		city.free()
		get_tree().quit(1)
		return
	actor.camera_visibility_optimization_enabled = false
	actor.call(&"_set_camera_effects_active", true)
	for _frame in 180:
		await get_tree().physics_frame
	_position_camera(camera, actor, wake)
	# Freeze the boat and its history so every phase renders identical geometry.
	actor.process_mode = Node.PROCESS_MODE_DISABLED
	_benchmark_cpu_surface_sampling(ocean, wake)
	var results := {}
	results["A_LOCAL_OFF"] = await _measure_phase(ocean, wake, false, false, false)
	_save_benchmark_screenshot("res://.godot/traffic_wake_v2_off.png")
	results["B_RIBBON_ONLY"] = await _measure_phase(ocean, wake, true, false, false)
	results["C_RIBBON_LOCAL_PHYSICS"] = await _measure_phase(
		ocean,
		wake,
		true,
		true,
		false
	)
	for _frame in 2:
		await get_tree().process_frame
	_save_benchmark_screenshot("res://.godot/traffic_wake_v2_visual.png")
	results["D_RIBBON_BOUNDED_OCEAN"] = await _measure_phase(
		ocean,
		wake,
		true,
		false,
		true
	)
	for _frame in 2:
		await get_tree().process_frame
	_save_benchmark_screenshot("res://.godot/traffic_wake_bounded_ocean.png")
	results["E_ALL_ENABLED"] = await _measure_phase(ocean, wake, true, true, true)
	# Isolate deposited foam from the young physical Kelvin packet so the
	# diagnostic image can prove its width, breakup and final-quarter fade.
	wake.directional_deformation_active = false
	ocean.request_directional_wake_refresh()
	ocean.call(&"_update_directional_wake_segments")
	_position_top_down_camera(camera, actor, wake)
	for _frame in 2:
		await get_tree().process_frame
	_save_benchmark_screenshot("res://.godot/traffic_wake_foam_topdown.png")
	for label: String in results:
		var frame_msec := float(results[label])
		print(
			"TRAFFIC_WAKE_%s_FRAME_MSEC=%.3f FPS=%.1f"
			% [label, frame_msec, 1000.0 / maxf(frame_msec, 0.001)]
		)
	print(
		"TRAFFIC_WAKE_RIBBON_DELTA_MSEC=%.3f"
		% (float(results["B_RIBBON_ONLY"]) - float(results["A_LOCAL_OFF"]))
	)
	print(
		"TRAFFIC_WAKE_BOUNDED_OCEAN_DELTA_MSEC=%.3f"
		% (
			float(results["D_RIBBON_BOUNDED_OCEAN"])
			- float(results["B_RIBBON_ONLY"])
		)
	)
	print("TRAFFIC_WAKE_V2_BENCHMARK=PASS")
	get_tree().current_scene = null
	city.free()
	packed = null
	await get_tree().process_frame
	get_tree().quit(0)


func _save_benchmark_screenshot(screenshot_path: String) -> void:
	var screenshot_error := get_tree().root.get_texture().get_image().save_png(
		screenshot_path
	)
	print(
		"TRAFFIC_WAKE_V2_SCREENSHOT=%s"
		% (
			ProjectSettings.globalize_path(screenshot_path)
			if screenshot_error == OK
			else "ERROR_%d" % screenshot_error
		)
	)


func _benchmark_cpu_surface_sampling(ocean: Ocean3D, wake: WakeTrail3D) -> void:
	const ITERATIONS := 30
	var positions := wake.get_sample_positions()
	if positions.is_empty():
		return
	wake.physics_enabled = true
	wake.set("_runtime_physics_active", false)
	wake.legacy_global_deformation_enabled = true
	wake.directional_source_active = true
	ocean.call(&"_update_directional_wake_segments")
	var old_start_usec := Time.get_ticks_usec()
	for _iteration in ITERATIONS:
		for sample_position: Vector3 in positions:
			# Previous mesh path: center height + four normal samples + six rails.
			for _surface_evaluation in 11:
				ocean.sample_height(sample_position)
	var old_usec := Time.get_ticks_usec() - old_start_usec
	var scratch := WaterSample3D.new()
	var new_start_usec := Time.get_ticks_usec()
	for _iteration in ITERATIONS:
		for sample_position: Vector3 in positions:
			ocean.sample_base_surface(sample_position, scratch)
	var new_usec := Time.get_ticks_usec() - new_start_usec
	var old_msec := float(old_usec) / 1000.0 / float(ITERATIONS)
	var new_msec := float(new_usec) / 1000.0 / float(ITERATIONS)
	print("TRAFFIC_WAKE_CPU_OLD_SURFACE_PATH_MSEC=%.3f" % old_msec)
	print("TRAFFIC_WAKE_CPU_V2_SURFACE_PATH_MSEC=%.3f" % new_msec)
	print(
		"TRAFFIC_WAKE_CPU_SURFACE_SPEEDUP=%.2fx"
		% (old_msec / maxf(new_msec, 0.0001))
	)


func _measure_phase(
	ocean: Ocean3D,
	wake: WakeTrail3D,
	visual_active: bool,
	physics_active: bool,
	legacy_global_active: bool
) -> float:
	wake.visual_enabled = visual_active
	wake.physics_enabled = physics_active
	wake.set("_runtime_physics_active", physics_active)
	wake.legacy_global_deformation_enabled = legacy_global_active
	wake.directional_source_active = legacy_global_active
	var wake_mesh := wake.get_node_or_null("WakeMesh") as MeshInstance3D
	if wake_mesh != null:
		wake_mesh.visible = visual_active
	ocean.clear_ripples()
	ocean.request_directional_wake_refresh()
	ocean.call(&"_update_directional_wake_segments")
	var phase_status := ocean.get_graphics_quality_debug_status()
	print(
		"TRAFFIC_WAKE_PHASE legacy=%s samples=%d segments=%d ripples=%d"
		% [
			legacy_global_active,
			wake.sample_count,
			int(phase_status.get("active_directional_segments", 0)),
			int(phase_status.get("active_ripples", 0)),
		]
	)
	for _frame in WARMUP_FRAMES:
		await get_tree().process_frame
	var start_usec := Time.get_ticks_usec()
	for _frame in MEASURED_FRAMES:
		await get_tree().process_frame
	return (
		float(Time.get_ticks_usec() - start_usec)
		/ 1000.0
		/ float(MEASURED_FRAMES)
	)


func _position_camera(
	camera: Camera3D,
	actor: BoatTrafficActor,
	wake: WakeTrail3D
) -> void:
	var camera_rig := camera.get_parent()
	if camera_rig != null:
		camera_rig.process_mode = Node.PROCESS_MODE_DISABLED
	var focus := actor.global_position
	var trail_direction := actor.global_basis.z
	if wake != null:
		var positions := wake.get_sample_positions()
		if positions.size() >= 2:
			focus = (positions[0] + positions[-1]) * 0.5
			trail_direction = positions[-1] - positions[0]
	trail_direction.y = 0.0
	if trail_direction.length_squared() <= 0.0001:
		trail_direction = Vector3.FORWARD
	else:
		trail_direction = trail_direction.normalized()
	var trail_right := trail_direction.cross(Vector3.UP).normalized()
	camera.global_position = focus + trail_right * 12.0 + Vector3.UP * 3.8
	camera.fov = 58.0
	camera.look_at(focus, Vector3.UP)
	camera.current = true


func _position_top_down_camera(
	camera: Camera3D,
	actor: BoatTrafficActor,
	wake: WakeTrail3D
) -> void:
	var focus := actor.global_position
	var trail_direction := actor.global_basis.z
	var height := 34.0
	var positions := wake.get_sample_positions()
	if positions.size() >= 2:
		focus = (positions[0] + positions[-1]) * 0.5
		trail_direction = positions[-1] - positions[0]
		height = maxf(34.0, trail_direction.length() * 0.82)
	trail_direction.y = 0.0
	if trail_direction.length_squared() <= 0.0001:
		trail_direction = Vector3.FORWARD
	else:
		trail_direction = trail_direction.normalized()
	camera.global_position = focus + Vector3.UP * height
	camera.fov = 52.0
	camera.look_at(focus, trail_direction)
	camera.current = true
