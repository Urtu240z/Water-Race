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

	_validate_straight_quality_and_speed(ocean, vehicle, wake)
	_validate_turn_and_drift(ocean, vehicle, wake)
	_validate_air_and_submarine(ocean, vehicle, wake)
	_validate_impacts_and_physical_separation(ocean, vehicle)
	_validate_rebase(ocean, vehicle, wake)
	_validate_shader_and_uniform_contract(ocean)
	_benchmark_cpu_updates(ocean)

	island.free()
	packed = null
	await process_frame
	await process_frame
	_finish()


func _validate_straight_quality_and_speed(
	ocean: Ocean3D,
	vehicle: JetSkiController,
	wake: WakeTrail3D
) -> void:
	wake.clear_trail(false)
	vehicle.global_transform = Transform3D(Basis.IDENTITY, Vector3.ZERO)
	vehicle.linear_velocity = Vector3(0.0, 0.0, -5.0)
	vehicle.water_physics_system.state.water_relative_forward_speed = 5.0
	_add_linear_samples(vehicle, wake, Vector3(0.0, 0.0, -0.8), 20)
	ocean.set_vehicle_interaction_quality(2)
	ocean.call("_update_vehicle_interactions", 0.05)
	var slow_intensities := ocean.get(
		"_directional_wake_intensities"
	) as PackedFloat32Array
	var slow_intensity := slow_intensities[0]
	_expect(
		ocean.directional_wake_active_samples > 0
		and ocean.directional_wake_active_samples <= 16,
		"La recta lenta produce una estela direccional limitada a 16 muestras."
	)

	wake.clear_trail(false)
	vehicle.global_transform = Transform3D(Basis.IDENTITY, Vector3.ZERO)
	vehicle.linear_velocity = Vector3(0.0, 0.0, -24.0)
	vehicle.water_physics_system.state.water_relative_forward_speed = 24.0
	_add_linear_samples(vehicle, wake, Vector3(0.0, 0.0, -2.2), 24)
	ocean.set_vehicle_interaction_quality(2)
	ocean.call("_update_vehicle_interactions", 0.05)
	var high_count := ocean.directional_wake_active_samples
	var fast_intensities := ocean.get(
		"_directional_wake_intensities"
	) as PackedFloat32Array
	_expect(
		fast_intensities[0] > slow_intensity,
		"La recta rápida solicita más intensidad que la lenta."
	)
	ocean.set_vehicle_interaction_quality(1)
	ocean.call("_update_vehicle_interactions", 0.05)
	var medium_count := ocean.directional_wake_active_samples
	ocean.set_vehicle_interaction_quality(0)
	ocean.call("_update_vehicle_interactions", 0.05)
	var low_count := ocean.directional_wake_active_samples
	_expect(
		high_count <= 16
		and medium_count <= 12
		and low_count <= 8
		and high_count >= medium_count
		and medium_count >= low_count,
		"LOW/MEDIUM/HIGH limitan el shader a 8/12/16 muestras."
	)


func _validate_turn_and_drift(
	ocean: Ocean3D,
	vehicle: JetSkiController,
	wake: WakeTrail3D
) -> void:
	wake.clear_trail(false)
	vehicle.global_transform = Transform3D(Basis.IDENTITY, Vector3.ZERO)
	vehicle.linear_velocity = Vector3(15.0, 0.0, -3.0)
	vehicle.water_physics_system.state.water_relative_forward_speed = 3.0
	vehicle.water_physics_system.state.water_relative_lateral_speed = 15.0
	vehicle.input_system.state.steering = 0.85
	for index in 14:
		var angle := float(index) * 0.085
		var position := Vector3(
			sin(angle) * 13.0,
			0.0,
			-cos(angle) * 13.0 + 13.0
		)
		vehicle.global_position = position
		wake.call("_try_add_sample")
		wake.call("_age_samples", 0.04)
	ocean.set_vehicle_interaction_quality(2)
	ocean.call("_update_vehicle_interactions", 0.05)
	var directions := ocean.get(
		"_directional_wake_directions"
	) as PackedVector2Array
	var biases := ocean.get("_directional_wake_biases") as PackedFloat32Array
	var count := ocean.directional_wake_active_samples
	var follows_trajectory := (
		count > 1
		and directions[0].x > 0.25
		and directions[0].y > 0.4
	)
	var curved_history := (
		count > 2
		and directions[0].dot(directions[count - 1]) < 0.995
	)
	_expect(
		follows_trajectory and curved_history,
		"El giro y el derrape siguen el desplazamiento real y curvan el historial."
	)
	_expect(
		absf(biases[0]) > 0.1,
		"El giro conserva bias asimétrico por muestra."
	)
	for _iteration in 12:
		ocean.call("_update_hull_pressure_state", 0.05)
	_expect(
		absf(
			ocean.hull_pressure_left_force
			- ocean.hull_pressure_right_force
		) > 0.05,
		"El campo del casco refuerza un costado y reduce el otro."
	)


func _validate_air_and_submarine(
	ocean: Ocean3D,
	vehicle: JetSkiController,
	wake: WakeTrail3D
) -> void:
	var sample_count_before := wake.sample_count
	vehicle.navigation_system.state.navigation_state = (
		JetSkiTypes.NavigationState.AIRBORNE
	)
	vehicle.global_position += Vector3(3.0, 4.0, -3.0)
	wake.call("_try_add_sample")
	for _iteration in 24:
		ocean.call("_update_hull_pressure_state", 0.05)
	_expect(
		wake.sample_count == sample_count_before,
		"En el aire no se añaden muestras nuevas."
	)
	_expect(
		ocean.hull_pressure_field_intensity < 0.01,
		"En el aire el campo de presión desaparece suavemente."
	)

	vehicle.navigation_system.state.navigation_state = (
		JetSkiTypes.NavigationState.DEEP_SUBMERGED
	)
	vehicle.water_physics_system.state.submerged_ratio = 1.0
	vehicle.water_physics_system.state.average_depth = 2.0
	vehicle.submarine_system.state.water_mode = (
		JetSkiTypes.RiderStuntWaterMode.SUBMARINE_DIVE
	)
	for _iteration in 20:
		ocean.call("_update_hull_pressure_state", 0.05)
	_expect(
		ocean.hull_pressure_field_intensity < 0.01,
		"El modo submarino no deja deformación pegada a la moto."
	)
	vehicle.submarine_system.reset_runtime_state(false)
	_prepare_contact_state(vehicle)


func _validate_impacts_and_physical_separation(
	ocean: Ocean3D,
	vehicle: JetSkiController
) -> void:
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
		active_count == 3,
		"Un aterrizaje fuerte crea un ripple principal y dos laterales."
	)
	_expect(
		ocean.merged_impact_count == merged_before + 1,
		"water_entered/hard_landing se agrupan mediante cooldown."
	)

	ocean.clear_ripples()
	var probe := vehicle.global_position + Vector3(1.2, 0.0, -1.0)
	var physical_height_before := ocean.sample_height(probe)
	for _iteration in 10:
		ocean.call("_update_hull_pressure_state", 0.05)
	var physical_height_after := ocean.sample_height(probe)
	_expect(
		absf(physical_height_after - physical_height_before) <= EPSILON,
		"Campo del casco y estela no entran en sample_height()."
	)
	ocean.add_ripple(probe, 0.25, 3.4, 2.6, 0.72, 4.6)
	ocean.set(
		"_simulation_time",
		float(ocean.get("_simulation_time")) + 0.45
	)
	_expect(
		absf(ocean.sample_height(probe) - physical_height_before) > EPSILON,
		"Los ripples de impacto conservan respuesta física."
	)


func _validate_rebase(
	ocean: Ocean3D,
	vehicle: JetSkiController,
	wake: WakeTrail3D
) -> void:
	ocean.clear_ripples()
	ocean.set_vehicle_interaction_quality(2)
	ocean.call("_update_vehicle_interactions", 0.05)
	var before := (
		ocean.get("_directional_wake_positions") as PackedVector2Array
	).duplicate()
	var count := ocean.directional_wake_active_samples
	var shift := Vector3(256.0, 0.0, -256.0)
	ocean.apply_world_rebase(shift, 256.0, -256.0)
	vehicle.global_position -= shift
	wake.apply_world_rebase(shift)
	ocean.call("_update_vehicle_interactions", 0.05)
	var after := ocean.get(
		"_directional_wake_positions"
	) as PackedVector2Array
	var stable := count == ocean.directional_wake_active_samples
	for index in count:
		stable = stable and before[index].distance_to(after[index]) <= EPSILON
	_expect(stable, "El rebase conserva las posiciones lógicas de la estela.")
	_expect(
		_packed_vectors_are_finite(after, ocean.directional_wake_active_samples),
		"El rebase no produce NaN ni INF."
	)


func _validate_shader_and_uniform_contract(ocean: Ocean3D) -> void:
	var base_source := FileAccess.get_file_as_string(
		"res://shaders/ocean_water.gdshader"
	)
	var ssr_source := FileAccess.get_file_as_string(
		"res://shaders/ocean_water_custom_ssr.gdshader"
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
		"Shader base y SSR comparten una única implementación analítica."
	)
	ocean.call("_push_vehicle_interaction_parameters_to_all_materials")
	var material := ocean.get_active_water_material()
	var positions := material.get_shader_parameter(
		&"directional_wake_positions"
	) as PackedVector2Array
	_expect(
		positions.size() == 16
		and ocean.interaction_uniform_update_count > 0
		and ocean.interaction_uniform_write_count > 0,
		"Ocean3D sincroniza buffers fijos y expone métricas de uniforms."
	)
	_expect(
		ocean.vehicle_interaction_update_interval >= 0.05 - EPSILON,
		"La actualización completa queda limitada aproximadamente a 20 Hz."
	)


func _benchmark_cpu_updates(ocean: Ocean3D) -> void:
	const ITERATIONS := 400
	var wake_enabled_before := ocean.directional_wake_enabled
	var hull_enabled_before := ocean.hull_pressure_enabled
	ocean.directional_wake_enabled = false
	ocean.hull_pressure_enabled = false
	var baseline_start := Time.get_ticks_usec()
	for _iteration in ITERATIONS:
		ocean.call("_update_vehicle_interactions", 0.05)
		ocean.call("_push_vehicle_interaction_parameters_to_all_materials")
	var baseline_usec := Time.get_ticks_usec() - baseline_start
	ocean.directional_wake_enabled = true
	ocean.hull_pressure_enabled = true
	var enabled_start := Time.get_ticks_usec()
	for _iteration in ITERATIONS:
		ocean.call("_update_vehicle_interactions", 0.05)
		ocean.call("_push_vehicle_interaction_parameters_to_all_materials")
	var enabled_usec := Time.get_ticks_usec() - enabled_start
	ocean.directional_wake_enabled = wake_enabled_before
	ocean.hull_pressure_enabled = hull_enabled_before
	print(
		"INTERACTION_CPU_UPDATE_BASELINE_USEC=%.2f"
		% (float(baseline_usec) / float(ITERATIONS))
	)
	print(
		"INTERACTION_CPU_UPDATE_ENABLED_USEC=%.2f"
		% (float(enabled_usec) / float(ITERATIONS))
	)
	print(
		"INTERACTION_CPU_UPDATE_DELTA_USEC=%.2f"
		% (float(enabled_usec - baseline_usec) / float(ITERATIONS))
	)


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


func _add_linear_samples(
	vehicle: JetSkiController,
	wake: WakeTrail3D,
	step: Vector3,
	count: int
) -> void:
	for _index in count:
		wake.call("_try_add_sample")
		wake.call("_age_samples", 0.04)
		vehicle.global_position += step


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
