extends SceneTree

const MAIN_SCENE := "res://scenes/levels/island_test/island_test_BLENDER.tscn"
const EPSILON := 0.0005

var _failed := false


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var packed := load(MAIN_SCENE) as PackedScene
	_expect(packed != null, "La escena principal carga.")
	if packed == null:
		_finish()
		return
	var island := packed.instantiate()
	root.add_child(island)
	await _wait_frames(4)
	var ocean := island.get_node_or_null("WaterIntegration/Ocean") as Ocean3D
	var vehicle := island.get_node_or_null("Gameplay/JetSki") as JetSkiController
	var wake := (
		vehicle.find_child("WakeTrail3D", true, false) as WakeTrail3D
		if vehicle != null
		else null
	)
	_expect(ocean != null, "Ocean3D sigue siendo la autoridad de agua.")
	_expect(vehicle != null, "La moto de agua principal existe.")
	_expect(wake != null, "WakeTrail3D existente se reutiliza.")
	if ocean == null or vehicle == null or wake == null:
		island.free()
		_finish()
		return
	vehicle.freeze = true
	vehicle.process_mode = Node.PROCESS_MODE_DISABLED
	wake.process_mode = Node.PROCESS_MODE_DISABLED
	ocean.process_mode = Node.PROCESS_MODE_DISABLED
	_prepare_contact_state(vehicle)

	_validate_segment_quality_and_trajectory(ocean, vehicle, wake)
	_validate_propagation_and_persistence(ocean, vehicle, wake)
	_validate_symmetry(ocean)
	_validate_jump_discontinuity(ocean, vehicle, wake)
	_validate_hull_tick_update(ocean, vehicle)
	_validate_air_submarine_and_impacts(ocean, vehicle, wake)
	_validate_rebase(ocean, vehicle, wake)
	_validate_shader_and_uniform_contract(ocean)
	_benchmark_cpu_updates(ocean)

	island.free()
	packed = null
	await process_frame
	await process_frame
	_finish()


func _validate_segment_quality_and_trajectory(
	ocean: Ocean3D,
	vehicle: JetSkiController,
	wake: WakeTrail3D
) -> void:
	_seed_linear_wake(vehicle, wake, 5.0, Vector3(0.0, 0.0, -0.25), 20)
	ocean.set_vehicle_interaction_quality(2)
	ocean.call("_update_directional_wake_segments")
	var slow_intensity := (
		ocean.get("_directional_wake_intensities") as PackedFloat32Array
	)[0]
	_seed_linear_wake(vehicle, wake, 24.0, Vector3(0.0, 0.0, -1.1), 25)
	ocean.call("_update_directional_wake_segments")
	var high_count := ocean.directional_wake_active_segments
	var fast_intensity := (
		ocean.get("_directional_wake_intensities") as PackedFloat32Array
	)[0]
	var starts := ocean.get(
		"_directional_wake_start_positions"
	) as PackedVector2Array
	var ends := ocean.get(
		"_directional_wake_end_positions"
	) as PackedVector2Array
	_expect(
		high_count > 0 and high_count <= 16,
		"La trayectoria recta exporta como máximo 16 segmentos."
	)
	_expect(
		starts[0].distance_to(ends[0]) > 0.5,
		"Cada entrada del shader contiene un tramo inicio-fin real."
	)
	_expect(
		fast_intensity > slow_intensity,
		"La recta rápida libera más energía que la recta lenta."
	)
	ocean.set_vehicle_interaction_quality(1)
	ocean.call("_update_directional_wake_segments")
	var medium_count := ocean.directional_wake_active_segments
	ocean.set_vehicle_interaction_quality(0)
	ocean.call("_update_directional_wake_segments")
	var low_count := ocean.directional_wake_active_segments
	_expect(
		high_count <= 16
		and medium_count <= 12
		and low_count <= 8
		and high_count >= medium_count
		and medium_count >= low_count,
		"LOW/MEDIUM/HIGH limitan el coste a 8/12/16 segmentos."
	)

	wake.clear_trail(false)
	_prepare_contact_state(vehicle)
	vehicle.linear_velocity = Vector3(15.0, 0.0, -3.0)
	vehicle.water_physics_system.state.water_relative_forward_speed = 3.0
	vehicle.water_physics_system.state.water_relative_lateral_speed = 15.0
	vehicle.input_system.state.steering = 0.85
	for index in 18:
		var angle := float(index) * 0.075
		vehicle.global_position = Vector3(
			sin(angle) * 14.0,
			0.0,
			-cos(angle) * 14.0 + 14.0
		)
		wake.call("_try_add_sample")
		wake.call("_age_samples", 0.04)
	ocean.set_vehicle_interaction_quality(2)
	ocean.call("_update_directional_wake_segments")
	starts = ocean.get("_directional_wake_start_positions") as PackedVector2Array
	ends = ocean.get("_directional_wake_end_positions") as PackedVector2Array
	var first_direction := (ends[0] - starts[0]).normalized()
	var last_index := ocean.directional_wake_active_segments - 1
	var old_direction := (ends[last_index] - starts[last_index]).normalized()
	var biases := ocean.get("_directional_wake_biases") as PackedFloat32Array
	_expect(
		first_direction.dot(old_direction) < 0.995,
		"Los giros siguen el desplazamiento horizontal real de la trayectoria."
	)
	_expect(
		absf(biases[0]) > 0.1,
		"El derrape conserva bias lateral por segmento."
	)


func _validate_propagation_and_persistence(
	ocean: Ocean3D,
	vehicle: JetSkiController,
	wake: WakeTrail3D
) -> void:
	var delta_time := 0.75
	var first_front := ocean.calculate_directional_front_distance(0.6, 1.0, 0.0)
	var second_front := ocean.calculate_directional_front_distance(
		0.6,
		1.0 + delta_time,
		0.0
	)
	_expect(
		absf(
			(second_front - first_front)
				- ocean.directional_wake_propagation_speed * delta_time
		) <= EPSILON,
		"El frente se desplaza propagation_speed * delta_time en metros."
	)

	_seed_linear_wake(vehicle, wake, 20.0, Vector3(0.0, 0.0, -1.0), 12)
	ocean.call("_update_directional_wake_segments")
	var count_before := ocean.directional_wake_active_segments
	var positions_before := (
		ocean.get("_directional_wake_start_positions") as PackedVector2Array
	).duplicate()
	ocean.set("_simulation_time", float(ocean.get("_simulation_time")) + 1.0)
	wake.call("_age_samples", 1.0)
	ocean.call("_update_directional_wake_segments")
	ocean.call("_update_interaction_metrics")
	var positions_after := ocean.get(
		"_directional_wake_start_positions"
	) as PackedVector2Array
	var persistent := count_before == ocean.directional_wake_active_segments
	for index in mini(count_before, ocean.directional_wake_active_segments):
		persistent = (
			persistent
			and positions_before[index].distance_to(positions_after[index]) <= EPSILON
		)
	_expect(
		persistent and ocean.average_propagated_wake_distance > 1.0,
		"Sin muestras nuevas, el paquete permanece fijo y su frente sigue avanzando."
	)
	wake.call("_age_samples", ocean.directional_wake_duration + 0.2)
	ocean.set(
		"_simulation_time",
		float(ocean.get("_simulation_time"))
			+ ocean.directional_wake_duration + 0.2
	)
	ocean.call("_update_directional_wake_segments")
	_expect(
		ocean.directional_wake_active_segments == 0,
		"Los paquetes expiran solo después de completar su vida útil."
	)


func _validate_symmetry(ocean: Ocean3D) -> void:
	var front := ocean.calculate_directional_front_distance(0.55, 1.2, 0.0)
	var left_offset := absf(-front) - front
	var right_offset := absf(front) - front
	var left_profile := ocean.calculate_directional_packet_profile(left_offset)
	var right_profile := ocean.calculate_directional_packet_profile(right_offset)
	_expect(
		absf(left_profile.x - right_profile.x) <= EPSILON,
		"Con bias cero, las alturas izquierda y derecha son iguales."
	)
	_expect(
		absf(-left_profile.y + right_profile.y) <= EPSILON,
		"Con bias cero, las derivadas laterales son especulares."
	)


func _validate_jump_discontinuity(
	ocean: Ocean3D,
	vehicle: JetSkiController,
	wake: WakeTrail3D
) -> void:
	_seed_linear_wake(vehicle, wake, 18.0, Vector3(0.0, 0.0, -0.9), 6)
	wake.mark_segment_break()
	vehicle.global_position += Vector3(45.0, 5.0, -35.0)
	_prepare_contact_state(vehicle)
	for _index in 6:
		wake.call("_try_add_sample")
		wake.call("_age_samples", 0.04)
		vehicle.global_position += Vector3(0.0, 0.0, -0.9)
	wake.call("_rebuild_mesh")
	ocean.call("_update_directional_wake_segments")
	var starts := ocean.get(
		"_directional_wake_start_positions"
	) as PackedVector2Array
	var ends := ocean.get(
		"_directional_wake_end_positions"
	) as PackedVector2Array
	var no_shader_bridge := true
	for index in ocean.directional_wake_active_segments:
		no_shader_bridge = (
			no_shader_bridge
			and starts[index].distance_to(ends[index]) < 4.0
		)
	var indices := wake.get("_indices") as PackedInt32Array
	var expected_connected_pairs := wake.sample_count - 2
	_expect(
		wake.jump_discontinuity_count == 1 and no_shader_bridge,
		"El salto crea una discontinuidad y ningún segmento cruza por el aire."
	)
	_expect(
		indices.size() == maxi(expected_connected_pairs, 0) * 18,
		"La espuma central y lateral tampoco conecta despegue con aterrizaje."
	)


func _validate_hull_tick_update(
	ocean: Ocean3D,
	vehicle: JetSkiController
) -> void:
	_prepare_contact_state(vehicle)
	vehicle.linear_velocity = Vector3.ZERO
	ocean.call("_update_hull_pressure_state", 1.0 / 60.0)
	var before := ocean.last_hull_pressure_center
	vehicle.global_position += Vector3(1.0, 0.0, 0.0)
	ocean.call("_update_hull_pressure_state", 1.0 / 60.0)
	var after := ocean.last_hull_pressure_center
	_expect(
		after.x - before.x > 0.8,
		"El centro del casco responde cada tick y no queda ~1 m retrasado."
	)


func _validate_air_submarine_and_impacts(
	ocean: Ocean3D,
	vehicle: JetSkiController,
	wake: WakeTrail3D
) -> void:
	var count_before := wake.sample_count
	vehicle.navigation_system.state.navigation_state = (
		JetSkiTypes.NavigationState.AIRBORNE
	)
	wake.call("_update_segment_continuity")
	wake.call("_try_add_sample")
	for _iteration in 24:
		ocean.call("_update_hull_pressure_state", 0.05)
	_expect(
		wake.sample_count == count_before,
		"En el aire no se liberan muestras nuevas."
	)
	_expect(
		ocean.hull_pressure_field_intensity < 0.01,
		"En el aire desaparece el campo instantáneo del casco."
	)
	vehicle.navigation_system.state.navigation_state = (
		JetSkiTypes.NavigationState.DEEP_SUBMERGED
	)
	vehicle.water_physics_system.state.average_depth = 2.0
	vehicle.submarine_system.state.water_mode = (
		JetSkiTypes.RiderStuntWaterMode.SUBMARINE_DIVE
	)
	for _iteration in 20:
		ocean.call("_update_hull_pressure_state", 0.05)
	_expect(
		ocean.hull_pressure_field_intensity < 0.01,
		"El modo submarino no arrastra una depresión superficial."
	)
	vehicle.submarine_system.reset_runtime_state(false)
	_prepare_contact_state(vehicle)

	ocean.clear_ripples()
	var impact_position := vehicle.global_position
	var merged_before := ocean.merged_impact_count
	ocean.call("_on_water_impact", 1.0, impact_position)
	ocean.call("_on_water_impact", 1.0, impact_position)
	var active := ocean.get("_ripple_active") as PackedInt32Array
	var active_count := 0
	for value in active:
		active_count += value
	_expect(
		active_count == 3
		and ocean.merged_impact_count == merged_before + 1,
		"El aterrizaje conserva ripple principal, laterales y cooldown."
	)


func _validate_rebase(
	ocean: Ocean3D,
	vehicle: JetSkiController,
	wake: WakeTrail3D
) -> void:
	_seed_linear_wake(vehicle, wake, 20.0, Vector3(0.0, 0.0, -1.0), 10)
	ocean.call("_update_directional_wake_segments")
	var before := (
		ocean.get("_directional_wake_start_positions") as PackedVector2Array
	).duplicate()
	var count := ocean.directional_wake_active_segments
	var shift := Vector3(256.0, 0.0, -256.0)
	ocean.apply_world_rebase(shift, 256.0, -256.0)
	vehicle.global_position -= shift
	wake.apply_world_rebase(shift)
	ocean.call("_update_directional_wake_segments")
	var after := ocean.get(
		"_directional_wake_start_positions"
	) as PackedVector2Array
	var stable := count == ocean.directional_wake_active_segments
	for index in count:
		stable = stable and before[index].distance_to(after[index]) <= EPSILON
	_expect(
		stable and _packed_vectors_are_finite(after, count),
		"El rebase conserva segmentos lógicos finitos."
	)


func _validate_shader_and_uniform_contract(ocean: Ocean3D) -> void:
	var base_source := FileAccess.get_file_as_string(
		"res://shaders/ocean_water.gdshader"
	)
	var ssr_source := FileAccess.get_file_as_string(
		"res://shaders/ocean_water_custom_ssr.gdshader"
	)
	var function_source := FileAccess.get_file_as_string(
		"res://shaders/includes/ocean_vehicle_interaction_functions.gdshaderinc"
	)
	var shared_uniform_include := (
		"res://shaders/includes/ocean_vehicle_interaction_uniforms.gdshaderinc"
	)
	var shared_function_include := (
		"res://shaders/includes/ocean_vehicle_interaction_functions.gdshaderinc"
	)
	_expect(
		base_source.contains(shared_uniform_include)
		and ssr_source.contains(shared_uniform_include)
		and base_source.contains(shared_function_include)
		and ssr_source.contains(shared_function_include),
		"Shader base y SSR comparten la misma implementación analítica."
	)
	_expect(
		function_source.contains("front_distance = initial_width + age * front_speed")
		and function_source.contains("closest_point")
		and not function_source.contains("* 0.08")
		and not function_source.contains("inversesqrt"),
		"El shader usa frentes liberados sin anclaje ni normalización global."
	)
	ocean.call("_push_vehicle_interaction_parameters_to_all_materials")
	var material := ocean.get_active_water_material()
	var starts := material.get_shader_parameter(
		&"directional_wake_start_positions"
	) as PackedVector2Array
	var ends := material.get_shader_parameter(
		&"directional_wake_end_positions"
	) as PackedVector2Array
	_expect(
		starts.size() == 16
		and ends.size() == 16
		and ocean.interaction_uniform_write_count > 0,
		"Ocean3D sincroniza buffers fijos de segmentos."
	)
	_expect(
		ocean.vehicle_interaction_update_interval >= 0.05 - EPSILON,
		"Solo el historial queda limitado aproximadamente a 20 Hz."
	)


func _benchmark_cpu_updates(ocean: Ocean3D) -> void:
	const ITERATIONS := 300
	var start := Time.get_ticks_usec()
	for _iteration in ITERATIONS:
		ocean.call("_update_directional_wake_segments")
		ocean.call("_push_directional_wake_parameters_to_all_materials")
	var elapsed := Time.get_ticks_usec() - start
	print(
		"SEGMENT_WAKE_CPU_UPDATE_USEC=%.2f"
		% (float(elapsed) / float(ITERATIONS))
	)


func _seed_linear_wake(
	vehicle: JetSkiController,
	wake: WakeTrail3D,
	speed: float,
	step: Vector3,
	count: int
) -> void:
	wake.clear_trail(false)
	_prepare_contact_state(vehicle)
	vehicle.global_transform = Transform3D(Basis.IDENTITY, Vector3.ZERO)
	vehicle.linear_velocity = step.normalized() * speed
	vehicle.water_physics_system.state.water_relative_forward_speed = speed
	for _index in count:
		wake.call("_try_add_sample")
		wake.call("_age_samples", 0.04)
		vehicle.global_position += step


func _prepare_contact_state(vehicle: JetSkiController) -> void:
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
	vehicle.drive_system.state.propulsion_contact_factor = 1.0


func _packed_vectors_are_finite(
	values: PackedVector2Array,
	count: int
) -> bool:
	for index in mini(count, values.size()):
		if not values[index].is_finite():
			return false
	return true


func _wait_frames(count: int) -> void:
	for _index in count:
		await process_frame


func _expect(condition: bool, message: String) -> void:
	if condition:
		print("PASS: %s" % message)
	else:
		_failed = true
		push_error("FAIL: %s" % message)


func _finish() -> void:
	print(
		"OCEAN_VEHICLE_INTERACTION_VALIDATION=%s"
		% ("FAIL" if _failed else "PASS")
	)
	quit(1 if _failed else 0)
