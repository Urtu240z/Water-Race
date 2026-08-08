extends SceneTree

const MAIN_SCENE := "res://levels/paradise_island/island_test_BLENDER.tscn"
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
	var effects := (
		vehicle.find_child("VehicleWaterEffects3D", true, false)
			as VehicleWaterEffects3D
		if vehicle != null
		else null
	)
	_expect(ocean != null, "Ocean3D sigue siendo la autoridad de agua.")
	_expect(vehicle != null, "La moto de agua principal existe.")
	_expect(wake != null, "WakeTrail3D existente se reutiliza.")
	_expect(effects != null, "VehicleWaterEffects3D comparte el impacto.")
	if ocean == null or vehicle == null or wake == null or effects == null:
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
	_validate_landing_impact_system(ocean, vehicle, wake, effects)
	_validate_landing_foam_controls(ocean, effects)
	_validate_rebase(ocean, vehicle, wake)
	_validate_foam_gpu_alignment(ocean, wake)
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
		"Los impactos genéricos submarinos conservan su agrupación anterior."
	)


func _validate_landing_impact_system(
	ocean: Ocean3D,
	vehicle: JetSkiController,
	wake: WakeTrail3D,
	effects: VehicleWaterEffects3D
) -> void:
	var small_strength := vehicle.calculate_landing_wave_strength(
		2.0, 1.00, 1, true
	)
	var medium_strength := vehicle.calculate_landing_wave_strength(
		6.0, 1.30, 2, true
	)
	var large_strength := vehicle.calculate_landing_wave_strength(
		11.0, 1.60, 4, true
	)
	_expect(
		small_strength < medium_strength
		and medium_strength < large_strength,
		"La fuerza autoritativa crece de forma monótona con el salto."
	)
	var effects_root := vehicle.get_node_or_null("Effects") as Node3D
	_expect(
		effects_root != null and effects_root.visible,
		"Gameplay/JetSki/Effects permanece visible en la escena real."
	)
	var original_wake_enabled := wake.wake_enabled
	var original_effects_visible := effects_root.visible
	wake.wake_enabled = false
	effects_root.visible = false
	vehicle.input_system.state.throttle = 0.0
	vehicle.linear_velocity = Vector3(0.0, -9.0, 0.15)
	var geometric_before := ocean.landing_impact_count
	var particle_before := effects.impact_burst_count
	var physical_ripple_before := _count_active_ripples(ocean)
	_expect(
		vehicle.water_entered.is_connected(ocean._on_landing_water_entered)
		and vehicle.water_entered.is_connected(effects._on_ocean_entered),
		"Ocean3D y VehicleWaterEffects3D escuchan el evento autoritativo."
	)
	_expect(
		bool(effects.get("_impact_valid")),
		"El pool de partículas de impacto está configurado en la escena real."
	)
	var audio := vehicle.get_node_or_null("WaterAudio") as VehicleWaterAudio
	_expect(audio != null, "El audio de agua real participa en el contrato.")
	var rejected_geometry_before := ocean.landing_impact_count
	var rejected_particles_before := effects.impact_burst_count
	var rejected_ripples_before := _count_active_ripples(ocean)
	if audio != null:
		audio.set("_splash_cooldown_remaining", 0.0)
	_emit_test_landing(
		vehicle,
		9.0,
		0.99,
		2,
		JetSkiTypes.LandingEntryType.FLAT,
		vehicle.global_position,
		true
	)
	var short_descriptor := vehicle.last_landing_impact_descriptor
	_expect(
		not short_descriptor.special_impact_eligible
		and short_descriptor.confirmed_airborne
		and short_descriptor.rejection_reason
			== LandingImpactDescriptor.REJECTION_AIRTIME_TOO_SHORT
		and ocean.landing_impact_count == rejected_geometry_before
		and effects.impact_burst_count == rejected_particles_before
		and _count_active_ripples(ocean) == rejected_ripples_before
		and ocean.last_landing_foam_energy <= EPSILON,
		"0,99 s confirmado no crea paquete, espuma, ripple especial ni burst."
	)
	_expect(
		audio == null or audio.last_splash_category != &"HEAVY",
		"Un impacto rechazado nunca selecciona el audio fuerte."
	)
	_emit_test_landing(
		vehicle,
		9.0,
		1.20,
		2,
		JetSkiTypes.LandingEntryType.FLAT,
		vehicle.global_position,
		false
	)
	var unconfirmed_descriptor := vehicle.last_landing_impact_descriptor
	_expect(
		not unconfirmed_descriptor.special_impact_eligible
		and unconfirmed_descriptor.rejection_reason
			== LandingImpactDescriptor.REJECTION_AIRBORNE_NOT_CONFIRMED
		and ocean.landing_impact_count == rejected_geometry_before
		and effects.impact_burst_count == rejected_particles_before,
		"El tiempo suficiente sin AIRBORNE confirmado sigue rechazado."
	)
	_emit_test_landing(
		vehicle,
		3.0,
		0.20,
		1,
		JetSkiTypes.LandingEntryType.SINGLE_POINT,
		vehicle.global_position,
		true
	)
	_expect(
		not vehicle.last_landing_impact_descriptor.special_impact_eligible
		and ocean.landing_impact_count == rejected_geometry_before
		and effects.impact_burst_count == rejected_particles_before,
		"Un rebote breve sobre una ola pequeña no crea impacto especial."
	)
	_emit_test_landing(
		vehicle,
		7.0,
		1.20,
		0,
		JetSkiTypes.LandingEntryType.SINGLE_POINT,
		vehicle.global_position,
		true
	)
	_expect(
		vehicle.last_landing_impact_descriptor.rejection_reason
			== LandingImpactDescriptor.REJECTION_INVALID_DATA,
		"Los datos de contacto inválidos tienen una causa de rechazo estable."
	)
	var original_minimum_airtime := vehicle.landing_impact_minimum_airtime
	vehicle.landing_impact_minimum_airtime = 0.50
	var configurable_geometry_before := ocean.landing_impact_count
	_emit_test_landing(
		vehicle,
		7.0,
		0.60,
		2,
		JetSkiTypes.LandingEntryType.FLAT,
		vehicle.global_position,
		true
	)
	_expect(
		vehicle.last_landing_impact_descriptor.special_impact_eligible
		and ocean.landing_impact_count == configurable_geometry_before + 1,
		"El mínimo exportado acepta 0,60 s cuando se configura en 0,50 s."
	)
	vehicle.landing_impact_minimum_airtime = original_minimum_airtime
	var exact_geometry_before := ocean.landing_impact_count
	_emit_test_landing(
		vehicle,
		7.0,
		1.00,
		2,
		JetSkiTypes.LandingEntryType.FLAT,
		vehicle.global_position,
		true
	)
	_expect(
		vehicle.last_landing_impact_descriptor.special_impact_eligible
		and vehicle.last_landing_impact_descriptor.rejection_reason
			== LandingImpactDescriptor.REJECTION_ACCEPTED
		and ocean.landing_impact_count == exact_geometry_before + 1,
		"1,00 s confirmado se acepta con tolerancia decimal segura."
	)
	var confirmation_debug := vehicle.get_landing_impact_debug_status()
	_expect(
		bool(confirmation_debug["last_landing_confirmed_airborne"])
		and bool(confirmation_debug["last_landing_special_impact_eligible"])
		and int(confirmation_debug["accepted_landing_impact_count"]) >= 2
		and int(confirmation_debug["rejected_landing_impact_count"]) >= 4
		and not vehicle.landing_impact_allow_short_hard_impacts,
		"El diagnóstico cuenta aceptados/rechazados y conserva el bypass apagado."
	)
	_expect(
		LandingImpactDescriptor.calculate_strength(
			0.0,
			0.0,
			2,
			1.5,
			11.0,
			0.1,
			1.8,
			0.1
		) <= EPSILON,
		"El descriptor nunca asume confirmed_jump=true."
	)

	geometric_before = ocean.landing_impact_count
	particle_before = effects.impact_burst_count
	physical_ripple_before = _count_active_ripples(ocean)
	_emit_test_landing(
		vehicle,
		9.0,
		1.10,
		1,
		JetSkiTypes.LandingEntryType.SINGLE_POINT,
		vehicle.global_position
	)
	_expect(
		ocean.landing_impact_count == geometric_before + 1
		and ocean.last_landing_wave_strength > 0.0
		and ocean.last_landing_foam_energy > 0.0,
		"El impacto geométrico existe sin acelerador, estela ni Effects visibles."
	)
	_expect(
		_count_active_ripples(ocean) == physical_ripple_before + 1,
		"El aterrizaje añade un solo ripple físico pequeño."
	)
	_expect(
		effects.impact_burst_count == particle_before + 1
		and absf(
			effects.last_impact_visual_intensity
				- ocean.last_landing_wave_strength
		) <= EPSILON,
		"Partículas y geometría consumen exactamente la misma fuerza."
	)
	var descriptor_id := vehicle.last_landing_impact_descriptor.event_id
	var geometry_after_entry := ocean.landing_impact_count
	var particles_after_entry := effects.impact_burst_count
	var physical_ripples_after_entry := _count_active_ripples(ocean)
	vehicle.call(
		"_on_navigation_system_hard_landing",
		vehicle.last_landing_intensity,
		vehicle.last_landing_position
	)
	_expect(
		ocean.landing_impact_count == geometry_after_entry
		and effects.impact_burst_count == particles_after_entry
		and _count_active_ripples(ocean) == physical_ripples_after_entry
		and vehicle.last_landing_impact_descriptor.event_id == descriptor_id,
		"water_entered + hard_landing producen un solo descriptor, onda y burst."
	)

	effects_root.visible = true
	var amplitudes := PackedFloat32Array()
	var initial_radii := PackedFloat32Array()
	var speeds := PackedFloat32Array()
	var durations := PackedFloat32Array()
	var particles := PackedInt32Array()
	for profile in [
		[2.0, 1.00, 1],
		[6.0, 1.30, 2],
		[11.0, 1.60, 4],
	]:
		_emit_test_landing(
			vehicle,
			float(profile[0]),
			float(profile[1]),
			int(profile[2]),
			JetSkiTypes.LandingEntryType.FLAT,
			vehicle.global_position
		)
		amplitudes.append(ocean.last_landing_wave_amplitude)
		speeds.append(ocean.last_landing_wave_speed)
		var descriptor := vehicle.last_landing_impact_descriptor
		var slot := _find_landing_slot_for_event(ocean, descriptor.event_id)
		initial_radii.append(
			(ocean.get("_landing_impact_initial_radii") as PackedFloat32Array)[
				slot
			]
		)
		durations.append(
			(ocean.get("_landing_impact_durations") as PackedFloat32Array)[slot]
		)
		particles.append(effects.last_impact_particle_amount)
	_expect(
		_is_non_decreasing(amplitudes),
		"La amplitud respeta la curva artística configurada: %s."
		% [amplitudes]
	)
	_expect(
		_is_strictly_increasing(initial_radii),
		"El radio inicial del landing escala monótonamente."
	)
	_expect(
		_is_strictly_increasing(speeds),
		"La velocidad del frente escala monótonamente."
	)
	_expect(
		_is_strictly_increasing(durations),
		"La duración del landing escala monótonamente."
	)
	_expect(
		_is_strictly_increasing_int(particles),
		"La cantidad de partículas escala monótonamente."
	)

	var radius_before := ocean.last_landing_wave_radius
	var active_before := ocean.active_landing_impact_count
	var persistent_descriptor := vehicle.last_landing_impact_descriptor
	var persistent_slot := _find_landing_slot_for_event(
		ocean,
		persistent_descriptor.event_id
	)
	var fixed_position := (
		ocean.get("_landing_impact_positions") as PackedVector2Array
	)[persistent_slot]
	var original_vehicle_position := vehicle.global_position
	vehicle.global_position += Vector3(18.0, 0.0, -11.0)
	ocean.set("_simulation_time", float(ocean.get("_simulation_time")) + 1.0)
	ocean.call("_expire_landing_impacts")
	_expect(
		ocean.active_landing_impact_count == active_before
		and ocean.last_landing_wave_radius
			> radius_before + ocean.last_landing_wave_speed * 0.9,
		"Sin eventos nuevos, el frente queda fijo y continúa propagándose."
	)
	_expect(
		(
			ocean.get("_landing_impact_positions") as PackedVector2Array
		)[persistent_slot].is_equal_approx(fixed_position),
		"La onda permanece en el contacto aunque la moto se aleje."
	)
	vehicle.global_position = original_vehicle_position

	for entry_type in [
		JetSkiTypes.LandingEntryType.FLAT,
		JetSkiTypes.LandingEntryType.FRONT,
		JetSkiTypes.LandingEntryType.REAR,
		JetSkiTypes.LandingEntryType.LEFT,
		JetSkiTypes.LandingEntryType.RIGHT,
		JetSkiTypes.LandingEntryType.DIAGONAL,
	]:
		_emit_test_landing(
			vehicle,
			7.0,
			1.1,
			2,
			entry_type,
			vehicle.global_position
		)
		_expect(
			ocean.last_landing_entry_type == int(entry_type),
			"El perfil de entrada %d llega al paquete GPU." % int(entry_type)
		)
		var descriptor := vehicle.last_landing_impact_descriptor
		var slot := _find_landing_slot_for_event(ocean, descriptor.event_id)
		var secondary_weights := (
			ocean.get("_landing_impact_secondary_weights")
				as PackedVector2Array
		)[slot]
		var expects_two_secondaries: bool = (
			entry_type == JetSkiTypes.LandingEntryType.FLAT
			or entry_type == JetSkiTypes.LandingEntryType.DIAGONAL
		)
		_expect(
			secondary_weights.x > 0.0
			and (
				secondary_weights.y > 0.0
				if expects_two_secondaries
				else true
			),
			"El perfil %d conserva secundarios derivados del contacto real."
			% int(entry_type)
		)
	wake.wake_enabled = original_wake_enabled
	effects_root.visible = original_effects_visible
	_prepare_contact_state(vehicle)


func _validate_landing_foam_controls(
	ocean: Ocean3D,
	effects: VehicleWaterEffects3D
) -> void:
	_expect(
		ocean.landing_foam_enabled
		and absf(ocean.landing_foam_strength - 0.035) <= EPSILON
		and absf(
			ocean.landing_foam_minimum_impact_strength - 0.35
		) <= EPSILON
		and absf(ocean.landing_foam_energy_threshold - 0.18) <= EPSILON
		and absf(ocean.landing_foam_energy_softness - 0.12) <= EPSILON
		and absf(
			ocean.landing_foam_generic_crest_suppression - 1.0
		) <= EPSILON,
		"Los seis controles de Landing Impact Foam tienen sus valores por defecto."
	)
	ocean.call("_push_static_parameters_to_all_materials")
	var materials := ocean.call("_all_ocean_materials") as Array
	_expect(
		not materials.is_empty()
		and _materials_have_landing_foam_settings(materials, ocean),
		"El material principal y los externos reciben los seis uniforms de landing."
	)
	var geometry_before := ocean.landing_impact_count
	var active_before := ocean.active_landing_impact_count
	var bursts_before := effects.impact_burst_count
	var amplitude_before := ocean.last_landing_wave_amplitude
	for strength in [0.0, 0.035, 0.15]:
		ocean.landing_foam_strength = float(strength)
		_expect(
			_materials_have_landing_foam_strength(
				materials,
				float(strength)
			),
			"Landing Foam Strength %.3f llega a todos los materiales."
			% float(strength)
		)
	_expect(
		ocean.landing_impact_count == geometry_before
		and ocean.active_landing_impact_count == active_before
		and effects.impact_burst_count == bursts_before
		and absf(ocean.last_landing_wave_amplitude - amplitude_before) <= EPSILON,
		"Cambiar la espuma no altera onda geométrica, pool ni salpicadura."
	)
	var manager := root.get_node_or_null("GraphicsQualityManager")
	_expect(manager != null, "GraphicsQualityManager está activo en la escena real.")
	if manager != null:
		ocean.landing_foam_strength = 0.15
		for quality in [2, 1, 0, 2]:
			manager.call("set_quality", quality, false)
			_expect(
				absf(ocean.landing_foam_strength - 0.15) <= EPSILON
				and _materials_have_landing_foam_strength(
					materials,
					0.15
				),
				"El preset %d conserva la intensidad artística configurada."
				% quality
			)
	ocean.landing_foam_strength = 0.035

	var base_source := FileAccess.get_file_as_string(
		"res://world/water/ocean/shaders/ocean_water.gdshader"
	)
	var ssr_source := FileAccess.get_file_as_string(
		"res://world/water/ocean/shaders/ocean_water_custom_ssr.gdshader"
	)
	var function_source := FileAccess.get_file_as_string(
		"res://world/water/ocean/shaders/includes/ocean_vehicle_interaction_functions.gdshaderinc"
	)
	var uniform_source := FileAccess.get_file_as_string(
		"res://world/water/ocean/shaders/includes/ocean_vehicle_interaction_uniforms.gdshaderinc"
	)
	var wake_source := FileAccess.get_file_as_string(
		"res://gameplay/vehicles/common/water_effects/wake/wake_foam.gdshader"
	)
	var landing_loop := (
		"for (int index = 0; index < MAX_LANDING_IMPACTS; index++)"
	)
	_expect(
		function_source.count(landing_loop) == 1
		and function_source.contains(
			"sample_vehicle_interaction_state_with_landing"
		)
		and base_source.count(
			"sample_vehicle_interaction_state_with_landing("
		) == 1
		and ssr_source.count(
			"sample_vehicle_interaction_state_with_landing("
		) == 1,
		"Base y SSR obtienen energía/fuerza sin duplicar el loop de impactos."
	)
	_expect(
		_base_shader_has_separate_landing_foam(base_source)
		and _base_shader_has_separate_landing_foam(ssr_source),
		"Shader base y SSR separan ripple foam, landing foam y supresión de cresta."
	)
	_expect(
		uniform_source.contains("uniform bool landing_foam_enabled = true;")
		and uniform_source.contains(
			"uniform float landing_foam_strength : hint_range(0.0, 2.0, 0.01) = 0.035;"
		)
		and uniform_source.contains(
			"uniform float landing_foam_generic_crest_suppression"
		)
		and wake_source.contains(
			"sample_vehicle_interaction_state(logical_xz).x"
		)
		and not wake_source.contains("interpolated_landing_impact_energy"),
		"Los uniforms son compartidos y wake_foam solo acompaña la geometría GPU."
	)
	var profile_source := FileAccess.get_file_as_string(
		"res://systems/graphics/graphics_quality_profile.gd"
	)
	_expect(
		not profile_source.contains("landing_foam_strength"),
		"Los perfiles gráficos no pueden sobrescribir Landing Foam Strength."
	)


func _materials_have_landing_foam_strength(
	materials: Array,
	expected: float
) -> bool:
	for value in materials:
		var material := value as ShaderMaterial
		if material == null:
			return false
		var actual: Variant = material.get_shader_parameter(
			&"landing_foam_strength"
		)
		if actual == null or absf(float(actual) - expected) > EPSILON:
			return false
	return true


func _materials_have_landing_foam_settings(
	materials: Array,
	ocean: Ocean3D
) -> bool:
	for value in materials:
		var material := value as ShaderMaterial
		if material == null:
			return false
		if bool(material.get_shader_parameter(&"landing_foam_enabled")) != (
			ocean.landing_foam_enabled
		):
			return false
		if absf(
			float(material.get_shader_parameter(
				&"landing_foam_minimum_impact_strength"
			)) - ocean.landing_foam_minimum_impact_strength
		) > EPSILON:
			return false
		if absf(
			float(material.get_shader_parameter(
				&"landing_foam_energy_threshold"
			)) - ocean.landing_foam_energy_threshold
		) > EPSILON:
			return false
		if absf(
			float(material.get_shader_parameter(
				&"landing_foam_energy_softness"
			)) - ocean.landing_foam_energy_softness
		) > EPSILON:
			return false
		if absf(
			float(material.get_shader_parameter(
				&"landing_foam_generic_crest_suppression"
			)) - ocean.landing_foam_generic_crest_suppression
		) > EPSILON:
			return false
	return _materials_have_landing_foam_strength(
		materials,
		ocean.landing_foam_strength
	)


func _base_shader_has_separate_landing_foam(source: String) -> bool:
	return (
		source.contains("varying float interpolated_landing_impact_energy;")
		and source.contains(
			"float ripple_foam = interpolated_ripple_energy * ripple_foam_strength;"
		)
		and source.contains(
			"interpolated_landing_impact_energy\n"
				+ "\t\t\t* landing_foam_strength"
		)
		and source.contains("float landing_region = landing_energy_gate;")
		and source.contains(
			"landing_foam_generic_crest_suppression"
		)
		and source.contains("ripple_foam_suppressed[index]")
	)


func _emit_test_landing(
	vehicle: JetSkiController,
	normal_speed: float,
	airtime: float,
	contact_count: int,
	entry_type: JetSkiTypes.LandingEntryType,
	position: Vector3,
	confirmed_airborne: bool = true
) -> void:
	var state := vehicle.navigation_system.state
	state.last_landing_position = position
	state.last_landing_normal_speed = normal_speed
	state.last_landing_intensity = clampf(
		inverse_lerp(1.0, 12.0, normal_speed),
		0.0,
		1.0
	)
	state.last_airtime = airtime
	state.last_landing_contact_count = contact_count
	state.last_landing_contact_mask = _contact_mask_for_entry(
		entry_type,
		contact_count
	)
	state.last_landing_entry_type = entry_type
	vehicle.set(
		"_airborne_state_confirmed_for_landing",
		confirmed_airborne
	)
	vehicle.call(
		"_on_navigation_system_water_entered",
		state.last_landing_intensity,
		position
	)


func _contact_mask_for_entry(
	entry_type: JetSkiTypes.LandingEntryType,
	contact_count: int
) -> int:
	match entry_type:
		JetSkiTypes.LandingEntryType.FLAT:
			return 15
		JetSkiTypes.LandingEntryType.FRONT:
			return 3
		JetSkiTypes.LandingEntryType.REAR:
			return 12
		JetSkiTypes.LandingEntryType.LEFT:
			return 5
		JetSkiTypes.LandingEntryType.RIGHT:
			return 10
		JetSkiTypes.LandingEntryType.DIAGONAL:
			return 9
		JetSkiTypes.LandingEntryType.SINGLE_POINT:
			return 1
	return (
		1 if contact_count <= 1
		else 3 if contact_count == 2
		else 7 if contact_count == 3
		else 15
	)


func _find_landing_slot_for_event(ocean: Ocean3D, event_id: int) -> int:
	var event_ids := ocean.get("_landing_impact_event_ids") as PackedInt32Array
	for index in event_ids.size():
		if event_ids[index] == event_id:
			return index
	return 0


func _count_active_ripples(ocean: Ocean3D) -> int:
	var count: int = 0
	for active in ocean.get("_ripple_active") as PackedInt32Array:
		count += active
	return count


func _is_strictly_increasing(values: PackedFloat32Array) -> bool:
	for index in range(1, values.size()):
		if values[index] <= values[index - 1]:
			return false
	return true


func _is_non_decreasing(values: PackedFloat32Array) -> bool:
	for index in range(1, values.size()):
		if values[index] + EPSILON < values[index - 1]:
			return false
	return true


func _is_strictly_increasing_int(values: PackedInt32Array) -> bool:
	for index in range(1, values.size()):
		if values[index] <= values[index - 1]:
			return false
	return true


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
		"res://world/water/ocean/shaders/ocean_water.gdshader"
	)
	var ssr_source := FileAccess.get_file_as_string(
		"res://world/water/ocean/shaders/ocean_water_custom_ssr.gdshader"
	)
	var function_source := FileAccess.get_file_as_string(
		"res://world/water/ocean/shaders/includes/ocean_vehicle_interaction_functions.gdshaderinc"
	)
	var shared_uniform_include := (
		"res://world/water/ocean/shaders/includes/ocean_vehicle_interaction_uniforms.gdshaderinc"
	)
	var shared_function_include := (
		"res://world/water/ocean/shaders/includes/ocean_vehicle_interaction_functions.gdshaderinc"
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
	_expect(
		function_source.contains("sample_landing_impact_state")
		and function_source.contains(
			"initial_radius + age * propagation_speed"
		)
		and function_source.contains("depression_time")
		and function_source.contains(
			"ocean_interaction_debug_mode == 1"
		),
		"El impacto compuesto comparte depresión, propagación y modos debug."
	)
	ocean.call("_push_vehicle_interaction_parameters_to_all_materials")
	var material := ocean.get_active_water_material()
	var starts := material.get_shader_parameter(
		&"directional_wake_start_positions"
	) as PackedVector2Array
	var ends := material.get_shader_parameter(
		&"directional_wake_end_positions"
	) as PackedVector2Array
	var landing_positions := material.get_shader_parameter(
		&"landing_impact_positions"
	) as PackedVector2Array
	_expect(
		starts.size() == 16
		and ends.size() == 16
		and landing_positions.size() == 4
		and ocean.interaction_uniform_write_count > 0,
		"Ocean3D sincroniza 16 segmentos y 4 impactos fijos."
	)
	_expect(
		ocean.vehicle_interaction_update_interval >= 0.05 - EPSILON,
		"Solo el historial queda limitado aproximadamente a 20 Hz."
	)


func _validate_foam_gpu_alignment(
	ocean: Ocean3D,
	wake: WakeTrail3D
) -> void:
	wake.call("_rebuild_mesh")
	var vertices := wake.get("_vertices") as PackedVector3Array
	var base_height_matches := not vertices.is_empty()
	if base_height_matches:
		var first_vertex := vertices[0]
		base_height_matches = absf(
			first_vertex.y
				- (
					ocean.sample_height(first_vertex)
					+ wake.wake_surface_offset
				)
		) <= EPSILON
	_expect(
		base_height_matches,
		"Cada vértice lateral parte de su propia altura macro/ripple CPU."
	)
	var foam_source := FileAccess.get_file_as_string(
		"res://gameplay/vehicles/common/water_effects/wake/wake_foam.gdshader"
	)
	_expect(
		foam_source.contains(
			"ocean_vehicle_interaction_functions.gdshaderinc"
		)
		and foam_source.contains(
			"sample_vehicle_interaction_state(logical_xz).x"
		)
		and foam_source.contains("void vertex()"),
		"La espuma suma en GPU la misma deformación direccional que el océano."
	)
	var material := wake.get("_normal_material") as ShaderMaterial
	var external_materials := ocean.get("_external_materials") as Array
	var starts := (
		material.get_shader_parameter(
			&"directional_wake_start_positions"
		) as PackedVector2Array
		if material != null
		else PackedVector2Array()
	)
	_expect(
		material != null
		and external_materials.has(material)
		and starts.size() == 16,
		"Ocean3D sincroniza tiempo, origen y segmentos con el material de espuma."
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
