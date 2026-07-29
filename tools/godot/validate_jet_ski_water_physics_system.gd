extends SceneTree

const JET_SKI_SCENE := "res://scenes/vehicle/jet_ski.tscn"
const MAIN_SCENE := "res://scenes/levels/island_test/island_test_BLENDER.tscn"
const POINT_NAMES: Array[StringName] = [
	&"FrontLeft",
	&"FrontRight",
	&"RearLeft",
	&"RearRight",
]
const POINT_COUNT := 4
const SCALAR_EPSILON := 0.02
const VECTOR_EPSILON := 0.03

var _failed := false


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var jet_ski_packed := load(JET_SKI_SCENE) as PackedScene
	var main_packed := load(MAIN_SCENE) as PackedScene
	_expect(jet_ski_packed != null, "jet_ski.tscn loads.")
	_expect(main_packed != null, "The main scene loads.")
	if jet_ski_packed == null or main_packed == null:
		_finish()
		return

	await _validate_isolated_fixture(jet_ski_packed)
	await _validate_main_runtime(main_packed)
	jet_ski_packed = null
	main_packed = null
	await physics_frame
	await process_frame
	await process_frame
	_finish()


func _validate_isolated_fixture(jet_ski_packed: PackedScene) -> void:
	var fixture := Node3D.new()
	fixture.name = "WaterPhysicsFixture"
	var ocean := Ocean3D.new()
	ocean.name = "Ocean"
	ocean.water_level = 0.0
	ocean.wave_amplitude_a = 0.0
	ocean.wave_amplitude_b = 0.0
	ocean.process_mode = Node.PROCESS_MODE_DISABLED
	fixture.add_child(ocean)

	var vehicle := jet_ski_packed.instantiate() as JetSkiController
	_expect(vehicle != null, "jet_ski.tscn instantiates as JetSkiController.")
	if vehicle == null:
		fixture.free()
		return
	vehicle.name = "JetSki"
	vehicle.ocean_path = NodePath("../Ocean")
	vehicle.gravity_scale = 0.0
	vehicle.collision_layer = 0
	vehicle.collision_mask = 0
	fixture.add_child(vehicle)
	root.add_child(fixture)
	await process_frame

	var water_system := vehicle.get_node_or_null(
		"Systems/WaterPhysicsSystem"
	) as JetSkiWaterPhysicsSystem
	_expect(water_system != null, "Systems/WaterPhysicsSystem exists.")
	if water_system == null:
		fixture.queue_free()
		await process_frame
		return
	_expect(
		not _script_declares_method(water_system.get_script(), &"_process")
		and not _script_declares_method(
			water_system.get_script(),
			&"_physics_process"
		)
		and not _script_declares_method(
			water_system.get_script(),
			&"_integrate_forces"
		),
		"WaterPhysicsSystem has no autonomous processing."
	)

	var persistent_state := water_system.state
	var resize_count := water_system.get_runtime_array_resize_count()
	var sample_valid_array := water_system.point_sample_valid
	_expect(
		water_system.has_valid_buoyancy_points(),
		"Exactly four buoyancy markers are configured."
	)
	_validate_point_order(vehicle, water_system)
	_validate_array_sizes(water_system)

	vehicle.global_transform = Transform3D(
		Basis.IDENTITY,
		Vector3(0.0, 2.0, 0.0)
	)
	vehicle.linear_velocity = Vector3.ZERO
	vehicle.angular_velocity = Vector3.ZERO
	vehicle.sleeping = false
	await _wait_physics_frames(3)
	_expect(
		water_system.state == persistent_state,
		"JetSkiWaterState remains a single persistent object."
	)
	_expect(
		water_system.get_runtime_array_resize_count() == resize_count,
		"Runtime arrays are not resized during physical steps."
	)
	_expect(
		is_same(sample_valid_array, water_system.point_sample_valid),
		"The reference-backed sample-valid array keeps its identity."
	)
	_validate_dry_state(water_system)

	vehicle.global_transform = Transform3D(
		Basis.IDENTITY,
		Vector3.ZERO
	)
	vehicle.linear_velocity = Vector3(2.0, -1.0, -6.0)
	vehicle.angular_velocity = Vector3(0.1, -0.2, 0.15)
	vehicle.sleeping = false
	await _wait_physics_frames(2)
	_validate_legacy_equivalence(vehicle, ocean, 1.0)
	_validate_proxies_and_public_arrays(vehicle, water_system)
	_expect(
		vehicle.current_contact_mask == water_system.state.raw_contact_mask,
		"The raw water-contact mask reaches existing navigation."
	)

	Input.action_press(&"rider_shift_forward", 1.0)
	vehicle.submarine_buoyancy_factor = 0.5
	vehicle.submarine_system.buoyancy_factor = 0.5
	vehicle.submarine_system.state.water_mode = (
		JetSkiController.RiderStuntWaterMode.SUBMARINE_DIVE
	)
	vehicle.submarine_system.state.buoyancy_factor_current = 0.5
	vehicle.submarine_system.state.current_depth = 0.0
	vehicle.submarine_system.state.duration = 0.0
	vehicle.global_transform = Transform3D(
		Basis.IDENTITY,
		Vector3.ZERO
	)
	vehicle.linear_velocity = Vector3(2.0, -1.0, -6.0)
	vehicle.angular_velocity = Vector3(0.1, -0.2, 0.15)
	vehicle.sleeping = false
	await _wait_physics_frames(2)
	_validate_legacy_equivalence(vehicle, ocean, 0.5)
	_expect(
		water_system.state.total_buoyancy_force > 0.0,
		"Submarine factor still produces finite scaled buoyancy."
	)
	Input.action_release(&"rider_shift_forward")
	vehicle.submarine_system.reset_runtime_state(false)

	var local_points_before := water_system.get_buoyancy_local_points()
	water_system.reset_runtime_state()
	_expect(
		water_system.state == persistent_state,
		"Reset preserves the persistent water-state object."
	)
	_expect(
		_state_metrics_are_zero(water_system.state),
		"Reset clears aggregate water metrics."
	)
	_validate_array_sizes(water_system)
	_expect(
		water_system.get_runtime_array_resize_count() == resize_count,
		"Reset does not resize runtime arrays."
	)
	_expect(
		water_system.get_buoyancy_local_points() == local_points_before,
		"Reset preserves cached local buoyancy points."
	)

	vehicle.apply_world_rebase(Vector3(20.0, 4.0, -13.0))
	vehicle.sleeping = false
	await _wait_physics_frames(2)
	_expect(
		water_system.has_valid_buoyancy_points()
		and water_system.get_buoyancy_local_points() == local_points_before,
		"World rebase preserves references and local-point cache."
	)
	_expect(
		_vector_array_is_finite(water_system.point_world_positions),
		"World telemetry is refreshed with finite values after rebase."
	)

	fixture.free()
	await physics_frame
	await process_frame


func _validate_point_order(
	vehicle: JetSkiController,
	water_system: JetSkiWaterPhysicsSystem
) -> void:
	var point_root := vehicle.get_node("BuoyancyPoints") as Node3D
	var cached_points := water_system.get_buoyancy_local_points()
	var order_valid := cached_points.size() == POINT_COUNT
	for index in POINT_COUNT:
		var marker := point_root.get_node(
			NodePath(POINT_NAMES[index])
		) as Marker3D
		var expected_point := (
			point_root.transform * marker.transform
		).origin
		order_valid = (
			order_valid
			and cached_points[index].distance_to(expected_point)
			<= VECTOR_EPSILON
		)
	_expect(
		order_valid,
		"Point order remains FrontLeft, FrontRight, RearLeft, RearRight."
	)


func _validate_array_sizes(
	water_system: JetSkiWaterPhysicsSystem
) -> void:
	var sizes_valid := (
		water_system.get_buoyancy_local_points().size() == POINT_COUNT
		and water_system.point_depths.size() == POINT_COUNT
		and water_system.point_normal_forces.size() == POINT_COUNT
		and water_system.point_buoyancy_force_vectors.size() == POINT_COUNT
		and water_system.point_water_normals.size() == POINT_COUNT
		and water_system.point_world_positions.size() == POINT_COUNT
		and water_system.point_water_surface_positions.size() == POINT_COUNT
		and water_system.point_water_velocities.size() == POINT_COUNT
		and water_system.point_physical_velocities.size() == POINT_COUNT
		and water_system.point_relative_velocities.size() == POINT_COUNT
		and water_system.point_relative_normal_speeds.size() == POINT_COUNT
		and water_system.point_sample_valid.size() == POINT_COUNT
		and water_system.point_forward_drag_forces.size() == POINT_COUNT
		and water_system.point_lateral_drag_forces.size() == POINT_COUNT
	)
	_expect(sizes_valid, "All persistent water arrays contain four elements.")


func _validate_dry_state(
	water_system: JetSkiWaterPhysicsSystem
) -> void:
	var all_points_dry := true
	var all_forces_zero := true
	for index in POINT_COUNT:
		all_points_dry = (
			all_points_dry
			and water_system.point_depths[index] <= 0.0
		)
		all_forces_zero = (
			all_forces_zero
			and is_zero_approx(water_system.point_normal_forces[index])
			and water_system.point_buoyancy_force_vectors[index].is_zero_approx()
			and water_system.point_forward_drag_forces[index].is_zero_approx()
			and water_system.point_lateral_drag_forces[index].is_zero_approx()
		)
	_expect(all_points_dry, "Controlled dry fixture places all points above water.")
	_expect(all_forces_zero, "A point outside water generates no water force.")
	_expect(
		water_system.state.raw_contact_mask == 0,
		"Dry fixture produces an empty raw contact mask."
	)


func _validate_legacy_equivalence(
	vehicle: JetSkiController,
	ocean: Ocean3D,
	buoyancy_factor: float
) -> void:
	var water_system := vehicle.water_physics_system
	var water_state := water_system.state
	var depth_sum := 0.0
	var expected_maximum_depth := 0.0
	var expected_maximum_signed_depth := -INF
	var expected_contact_mask := 0
	var expected_submerged_count := 0
	var expected_front_count := 0
	var expected_rear_count := 0
	var expected_total_buoyancy := 0.0
	var expected_total_forward_drag := 0.0
	var expected_total_lateral_drag := 0.0
	var expected_maximum_buoyancy := 0.0
	var expected_maximum_forward_drag := 0.0
	var expected_maximum_lateral_drag := 0.0
	var expected_active_count := 0
	var water_normal_sum := Vector3.ZERO
	var water_velocity_sum := Vector3.ZERO
	var per_point_equivalent := true

	for index in POINT_COUNT:
		var world_point := water_system.point_world_positions[index]
		var expected_depth := (
			ocean.sample_height(world_point) - world_point.y
		)
		expected_maximum_signed_depth = maxf(
			expected_maximum_signed_depth,
			expected_depth
		)
		per_point_equivalent = (
			per_point_equivalent
			and _scalar_close(
				water_system.point_depths[index],
				expected_depth
			)
		)
		if expected_depth <= 0.0:
			per_point_equivalent = (
				per_point_equivalent
				and is_zero_approx(
					water_system.point_normal_forces[index]
				)
			)
			continue
		expected_contact_mask |= 1 << index
		var water_normal := ocean.sample_normal(world_point)
		var water_velocity := ocean.sample_water_velocity(world_point)
		if (
			not water_normal.is_finite()
			or not water_velocity.is_finite()
			or water_normal.length_squared() <= 0.000001
		):
			continue
		water_normal = water_normal.normalized()
		if water_normal.y < 0.0:
			water_normal = -water_normal
		var relative_velocity := (
			water_system.point_relative_velocities[index]
		)
		var normal_speed := relative_velocity.dot(water_normal)
		var depth_ratio := clampf(
			expected_depth / water_system.max_submersion_depth,
			0.0,
			1.0
		)
		var clamped_depth := minf(
			expected_depth,
			water_system.max_submersion_depth
		)
		var excess_submersion := maxf(
			expected_depth - water_system.deep_buoyancy_start_depth,
			0.0
		)
		var raw_buoyancy := (
			clamped_depth * water_system.buoyancy_strength_per_point
			+ excess_submersion
			* water_system.deep_buoyancy_strength_per_point
		)
		var maximum_buoyancy_force := (
			water_system.max_buoyancy_force_per_point
			+ excess_submersion
			* water_system.deep_buoyancy_force_limit_per_meter
		)
		var damping_magnitude := (
			-normal_speed
			* water_system.buoyancy_damping_per_point
			* depth_ratio
		)
		var expected_normal_force := clampf(
			raw_buoyancy + damping_magnitude,
			0.0,
			maximum_buoyancy_force
		) * buoyancy_factor
		var expected_buoyancy_vector := (
			water_normal * expected_normal_force
		)
		per_point_equivalent = (
			per_point_equivalent
			and _scalar_close(
				water_system.point_normal_forces[index],
				expected_normal_force
			)
			and _vector_close(
				water_system.point_buoyancy_force_vectors[index],
				expected_buoyancy_vector
			)
		)
		expected_total_buoyancy += expected_buoyancy_vector.length()
		expected_maximum_buoyancy = maxf(
			expected_maximum_buoyancy,
			expected_buoyancy_vector.length()
		)

		var normal_component := (
			water_normal * relative_velocity.dot(water_normal)
		)
		var tangential_velocity := relative_velocity - normal_component
		var forward_tangent := (
			water_state.sampled_body_forward
			- water_normal
			* water_state.sampled_body_forward.dot(water_normal)
		)
		if forward_tangent.length_squared() <= 0.000001:
			continue
		forward_tangent = forward_tangent.normalized()
		var right_tangent := forward_tangent.cross(water_normal)
		if right_tangent.length_squared() <= 0.000001:
			continue
		right_tangent = right_tangent.normalized()
		var forward_speed := tangential_velocity.dot(forward_tangent)
		var lateral_speed := tangential_velocity.dot(right_tangent)
		var immersion_factor := pow(
			depth_ratio,
			water_system.drag_depth_exponent
		)
		var forward_drag_scalar := clampf(
			_drag_scalar(
				forward_speed,
				water_system.forward_drag_linear_per_point,
				water_system.forward_drag_quadratic_per_point
			) * immersion_factor,
			-water_system.maximum_forward_drag_force_per_point,
			water_system.maximum_forward_drag_force_per_point
		)
		var lateral_drag_scalar := clampf(
			_drag_scalar(
				lateral_speed,
				water_system.lateral_drag_linear_per_point,
				water_system.lateral_drag_quadratic_per_point
			) * immersion_factor,
			-water_system.maximum_lateral_drag_force_per_point,
			water_system.maximum_lateral_drag_force_per_point
		)
		var expected_forward_drag := (
			-forward_tangent * forward_drag_scalar
		)
		var expected_lateral_drag := (
			-right_tangent * lateral_drag_scalar
		)
		per_point_equivalent = (
			per_point_equivalent
			and _vector_close(
				water_system.point_forward_drag_forces[index],
				expected_forward_drag
			)
			and _vector_close(
				water_system.point_lateral_drag_forces[index],
				expected_lateral_drag
			)
		)
		expected_total_forward_drag += absf(forward_drag_scalar)
		expected_total_lateral_drag += absf(lateral_drag_scalar)
		expected_maximum_forward_drag = maxf(
			expected_maximum_forward_drag,
			absf(forward_drag_scalar)
		)
		expected_maximum_lateral_drag = maxf(
			expected_maximum_lateral_drag,
			absf(lateral_drag_scalar)
		)
		expected_active_count += 1
		water_normal_sum += water_normal
		water_velocity_sum += water_velocity
		expected_submerged_count += 1
		depth_sum += expected_depth
		expected_maximum_depth = maxf(
			expected_maximum_depth,
			expected_depth
		)
		if index < 2:
			expected_front_count += 1
		else:
			expected_rear_count += 1

	var expected_average_depth := 0.0
	if expected_submerged_count > 0:
		expected_average_depth = (
			depth_sum / float(expected_submerged_count)
		)
	var aggregate_equivalent := (
		water_state.raw_contact_mask == expected_contact_mask
		and water_state.submerged_point_count == expected_submerged_count
		and water_state.front_submerged_count == expected_front_count
		and water_state.rear_submerged_count == expected_rear_count
		and _scalar_close(
			water_state.average_depth,
			expected_average_depth
		)
		and _scalar_close(
			water_state.maximum_depth,
			expected_maximum_depth
		)
		and _scalar_close(
			water_state.maximum_signed_point_depth,
			expected_maximum_signed_depth
		)
		and _scalar_close(
			water_state.total_buoyancy_force,
			expected_total_buoyancy
		)
		and _scalar_close(
			water_state.total_forward_drag_force,
			expected_total_forward_drag
		)
		and _scalar_close(
			water_state.total_lateral_drag_force,
			expected_total_lateral_drag
		)
		and _scalar_close(
			water_state.maximum_point_buoyancy_force,
			expected_maximum_buoyancy
		)
		and _scalar_close(
			water_state.maximum_point_forward_drag,
			expected_maximum_forward_drag
		)
		and _scalar_close(
			water_state.maximum_point_lateral_drag,
			expected_maximum_lateral_drag
		)
		and water_state.hydrodynamic_active_point_count
		== expected_active_count
	)
	var expected_forward_speed := 0.0
	var expected_lateral_speed := 0.0
	if expected_active_count > 0:
		var average_water_normal := water_normal_sum.normalized()
		var average_water_velocity := (
			water_velocity_sum / float(expected_active_count)
		)
		var center_forward_tangent := (
			water_state.sampled_body_forward
			- average_water_normal
			* water_state.sampled_body_forward.dot(
				average_water_normal
			)
		)
		if center_forward_tangent.length_squared() > 0.000001:
			center_forward_tangent = (
				center_forward_tangent.normalized()
			)
			var center_right_tangent := (
				center_forward_tangent.cross(
					average_water_normal
				).normalized()
			)
			var relative_center_velocity := (
				water_state.sampled_body_linear_velocity
				- average_water_velocity
			)
			var tangential_center_velocity := (
				relative_center_velocity
				- average_water_normal
				* relative_center_velocity.dot(
					average_water_normal
				)
			)
			expected_forward_speed = (
				tangential_center_velocity.dot(
					center_forward_tangent
				)
			)
			expected_lateral_speed = (
				tangential_center_velocity.dot(
					center_right_tangent
				)
			)
	aggregate_equivalent = (
		aggregate_equivalent
		and _scalar_close(
			water_state.water_relative_forward_speed,
			expected_forward_speed
		)
		and _scalar_close(
			water_state.water_relative_lateral_speed,
			expected_lateral_speed
		)
	)
	_expect(
		per_point_equivalent and aggregate_equivalent,
		"Delegated water formulas match the previous implementation "
		+ "at buoyancy factor %.2f." % buoyancy_factor
	)
	_expect(
		_water_data_is_finite(water_system),
		"All delegated forces and hydrodynamic metrics are finite."
	)


func _validate_proxies_and_public_arrays(
	vehicle: JetSkiController,
	water_system: JetSkiWaterPhysicsSystem
) -> void:
	var water_state := water_system.state
	var proxies_match := (
		vehicle.submerged_point_count
		== water_state.submerged_point_count
		and vehicle.submerged_ratio == water_state.submerged_ratio
		and vehicle.front_submerged_ratio
		== water_state.front_submerged_ratio
		and vehicle.rear_submerged_ratio
		== water_state.rear_submerged_ratio
		and vehicle.average_depth == water_state.average_depth
		and vehicle.maximum_depth == water_state.maximum_depth
		and vehicle.water_relative_forward_speed
		== water_state.water_relative_forward_speed
		and vehicle.water_relative_lateral_speed
		== water_state.water_relative_lateral_speed
		and vehicle.total_buoyancy_force
		== water_state.total_buoyancy_force
		and vehicle.total_forward_drag_force
		== water_state.total_forward_drag_force
		and vehicle.total_lateral_drag_force
		== water_state.total_lateral_drag_force
		and vehicle.maximum_point_buoyancy_force
		== water_state.maximum_point_buoyancy_force
		and vehicle.maximum_point_forward_drag
		== water_state.maximum_point_forward_drag
		and vehicle.maximum_point_lateral_drag
		== water_state.maximum_point_lateral_drag
		and vehicle.hydrodynamic_active_point_count
		== water_state.hydrodynamic_active_point_count
	)
	_expect(proxies_match, "All public water-metric proxies match system state.")

	var depth_copy := vehicle.get_buoyancy_point_depths()
	var internal_depth := water_system.point_depths[0]
	depth_copy[0] = internal_depth + 1000.0
	var public_arrays_work := (
		vehicle.get_buoyancy_local_points().size() == POINT_COUNT
		and vehicle.get_buoyancy_point_normal_forces().size()
		== POINT_COUNT
		and vehicle.get_buoyancy_point_water_normals().size()
		== POINT_COUNT
		and vehicle.get_point_forward_drag_forces().size()
		== POINT_COUNT
		and vehicle.get_point_lateral_drag_forces().size()
		== POINT_COUNT
		and is_equal_approx(
			water_system.point_depths[0],
			internal_depth
		)
	)
	_expect(
		public_arrays_work,
		"Public array methods return safe four-element duplicates."
	)


func _validate_main_runtime(main_packed: PackedScene) -> void:
	var island := main_packed.instantiate()
	root.add_child(island)
	await _wait_physics_frames(30)
	var vehicle := island.get_node_or_null(
		"Gameplay/JetSki"
	) as JetSkiController
	_expect(vehicle != null, "The main scene contains its JetSkiController.")
	if vehicle == null:
		island.queue_free()
		await process_frame
		return
	var runtime_nodes_exist := (
		island.get_node_or_null("CameraSystem/ChaseCamera") != null
		and island.get_node_or_null("Debug") != null
		and vehicle.get_node_or_null("EngineAudio") != null
		and vehicle.get_node_or_null("WaterAudio") != null
		and vehicle.get_node_or_null("Effects/VehicleWaterEffects3D")
		!= null
		and vehicle.get_node_or_null("VisualRoot/RiderMount") != null
	)
	_expect(
		runtime_nodes_exist,
		"Camera, debug, audio, effects, and rider consumers remain present."
	)

	var initial_horizontal_speed := Vector2(
		vehicle.linear_velocity.x,
		vehicle.linear_velocity.z
	).length()
	var maximum_horizontal_speed := initial_horizontal_speed
	var maximum_propulsion_force := 0.0
	var maximum_steering_angle := 0.0
	var maximum_buoyancy_force := 0.0
	var saw_water_contact := false
	Input.action_press(&"throttle", 1.0)
	Input.action_press(&"steer_right", 0.65)
	for _index in 90:
		await physics_frame
		maximum_horizontal_speed = maxf(
			maximum_horizontal_speed,
			Vector2(
				vehicle.linear_velocity.x,
				vehicle.linear_velocity.z
			).length()
		)
		maximum_propulsion_force = maxf(
			maximum_propulsion_force,
			vehicle.current_propulsion_force
		)
		maximum_steering_angle = maxf(
			maximum_steering_angle,
			absf(vehicle.current_steering_angle_degrees)
		)
		maximum_buoyancy_force = maxf(
			maximum_buoyancy_force,
			vehicle.total_buoyancy_force
		)
		saw_water_contact = (
			saw_water_contact
			or vehicle.water_physics_system.state.raw_contact_mask != 0
		)
	Input.action_release(&"throttle")
	Input.action_release(&"steer_right")
	_expect(
		saw_water_contact and maximum_buoyancy_force > 0.0,
		"Main-scene JetSki remains supported by waves and buoyancy."
	)
	_expect(
		maximum_propulsion_force > 0.0
		and maximum_horizontal_speed > initial_horizontal_speed,
		"Main-scene JetSki accelerates without water-system errors."
	)
	_expect(
		maximum_steering_angle > 0.0,
		"Main-scene steering remains active."
	)
	if DisplayServer.get_name() != "headless":
		await process_frame
		RenderingServer.force_draw()
		var viewport_texture := root.get_texture()
		if viewport_texture != null:
			var runtime_image := viewport_texture.get_image()
			if runtime_image != null and not runtime_image.is_empty():
				runtime_image.save_png(
					"res://.godot/jet_ski_water_physics_runtime.png"
				)

	vehicle.linear_velocity += Vector3.UP * 12.0
	var saw_dry_contact := false
	var saw_landing_after_dry := false
	for _index in 240:
		await physics_frame
		var has_water_contact := (
			vehicle.water_physics_system.state.raw_contact_mask != 0
		)
		if not has_water_contact:
			saw_dry_contact = true
		elif saw_dry_contact:
			saw_landing_after_dry = true
			break
	_expect(
		saw_dry_contact,
		"Main-scene JetSki can lose water contact."
	)
	_expect(
		saw_landing_after_dry,
		"Main-scene JetSki can regain contact and land."
	)
	_expect(
		vehicle.global_transform.is_finite()
		and vehicle.linear_velocity.is_finite()
		and _water_data_is_finite(vehicle.water_physics_system),
		"Main-scene runtime remains finite after acceleration and landing."
	)

	island.free()
	await physics_frame
	await process_frame


func _water_data_is_finite(
	water_system: JetSkiWaterPhysicsSystem
) -> bool:
	var water_state := water_system.state
	var metrics_finite := (
		is_finite(water_state.submerged_ratio)
		and is_finite(water_state.average_depth)
		and is_finite(water_state.maximum_depth)
		and is_finite(water_state.maximum_signed_point_depth)
		and is_finite(water_state.water_relative_forward_speed)
		and is_finite(water_state.water_relative_lateral_speed)
		and is_finite(water_state.total_buoyancy_force)
		and is_finite(water_state.total_forward_drag_force)
		and is_finite(water_state.total_lateral_drag_force)
		and water_state.support_normal.is_finite()
		and water_state.average_water_velocity.is_finite()
	)
	return (
		metrics_finite
		and _float_array_is_finite(water_system.point_depths)
		and _float_array_is_finite(
			water_system.point_normal_forces
		)
		and _vector_array_is_finite(
			water_system.point_buoyancy_force_vectors
		)
		and _vector_array_is_finite(
			water_system.point_forward_drag_forces
		)
		and _vector_array_is_finite(
			water_system.point_lateral_drag_forces
		)
	)


func _state_metrics_are_zero(state: JetSkiWaterState) -> bool:
	return (
		state.raw_contact_mask == 0
		and state.submerged_point_count == 0
		and is_zero_approx(state.average_depth)
		and is_zero_approx(state.maximum_depth)
		and is_zero_approx(state.total_buoyancy_force)
		and is_zero_approx(state.total_forward_drag_force)
		and is_zero_approx(state.total_lateral_drag_force)
	)


func _float_array_is_finite(values: PackedFloat32Array) -> bool:
	for value in values:
		if not is_finite(value):
			return false
	return true


func _vector_array_is_finite(values: PackedVector3Array) -> bool:
	for value in values:
		if not value.is_finite():
			return false
	return true


func _script_declares_method(
	script: Script,
	method_name: StringName
) -> bool:
	if script == null:
		return false
	for method in script.get_script_method_list():
		if StringName(method.name) == method_name:
			return true
	return false


func _wait_physics_frames(frame_count: int) -> void:
	for _index in frame_count:
		await physics_frame


func _drag_scalar(
	speed: float,
	linear_coefficient: float,
	quadratic_coefficient: float
) -> float:
	return (
		linear_coefficient * speed
		+ quadratic_coefficient * speed * absf(speed)
	)


func _scalar_close(actual: float, expected: float) -> bool:
	return absf(actual - expected) <= maxf(
		SCALAR_EPSILON,
		absf(expected) * 0.0001
	)


func _vector_close(actual: Vector3, expected: Vector3) -> bool:
	return actual.distance_to(expected) <= maxf(
		VECTOR_EPSILON,
		expected.length() * 0.0001
	)


func _expect(condition: bool, message: String) -> void:
	if condition:
		print("PASS: ", message)
		return
	_failed = true
	push_error("FAIL: %s" % message)


func _finish() -> void:
	Input.action_release(&"throttle")
	Input.action_release(&"steer_right")
	Input.action_release(&"rider_shift_forward")
	quit(1 if _failed else 0)
