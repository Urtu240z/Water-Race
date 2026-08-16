#ifdef OCEAN_INTERACTION_CONTEXT
vec2 interaction_safe_direction(vec2 direction, vec2 fallback) {
	float magnitude = length(direction);
	return magnitude > 0.00001 ? direction / magnitude : fallback;
}


// x: height, yz: spatial derivatives, w: deformation energy.
vec4 sample_directional_wake_state(vec2 logical_xz) {
	if (!directional_wake_enabled || directional_wake_active_count <= 0) {
		return vec4(0.0);
	}
	float height = 0.0;
	vec2 derivatives = vec2(0.0);
	float energy = 0.0;
	float safe_wavelength = max(directional_wake_wavelength, 0.05);
	float duration = max(directional_wake_duration, 0.05);
	float arm_width = max(directional_wake_arm_width, 0.08);
	float local_weight_sum = 0.0;
	for (int index = 0; index < MAX_DIRECTIONAL_WAKE_SAMPLES; index++) {
		if (
			index >= directional_wake_active_count
			|| index >= directional_wake_effective_count
		) {
			break;
		}
		vec2 segment = directional_wake_end_positions[index]
			- directional_wake_start_positions[index];
		float segment_length_squared = dot(segment, segment);
		if (segment_length_squared <= 0.0001) {
			continue;
		}
		float segment_length = sqrt(segment_length_squared);
		vec2 direction = segment / segment_length;
		vec2 right = vec2(-direction.y, direction.x);
		vec2 from_start = logical_xz
			- directional_wake_start_positions[index];
		float raw_segment_ratio = dot(from_start, segment)
			/ segment_length_squared;
		float segment_ratio = clamp(raw_segment_ratio, 0.0, 1.0);
		vec2 closest_point = directional_wake_start_positions[index]
			+ segment * segment_ratio;
		float endpoint_distance = raw_segment_ratio < 0.0
			? -raw_segment_ratio * segment_length
			: (
				raw_segment_ratio > 1.0
				? (raw_segment_ratio - 1.0) * segment_length
				: 0.0
			);
		float endpoint_fade_distance = max(safe_wavelength * 0.8, arm_width * 2.0);
		float endpoint_gate = 1.0 - smoothstep(
			0.0,
			endpoint_fade_distance,
			endpoint_distance
		);
		if (endpoint_gate <= 0.0001) {
			continue;
		}
		float local_creation_time = mix(
			directional_wake_start_times[index],
			directional_wake_end_times[index],
			segment_ratio
		);
		float age = simulation_time - local_creation_time;
		if (age < 0.0 || age > duration) {
			continue;
		}
		vec2 closest_delta = logical_xz - closest_point;
		float lateral = dot(closest_delta, right);
		float initial_width = max(directional_wake_widths[index], 0.15);
		float source_speed = max(directional_wake_speeds[index], 0.0);
		float front_speed = directional_wake_propagation_speed
			+ source_speed * directional_wake_opening_slope;
		float front_distance = initial_width + age * front_speed;
		float absolute_lateral = abs(lateral);
		float front_offset = absolute_lateral - front_distance;
		float crest_x = front_offset;
		float valley_x = front_offset + safe_wavelength * 0.72;
		float recovery_x = front_offset + safe_wavelength * 1.45;
		float valley_width = arm_width * 1.15;
		float recovery_width = arm_width * 1.35;
		float crest = exp(-crest_x * crest_x / (arm_width * arm_width));
		float valley = exp(
			-valley_x * valley_x / (valley_width * valley_width)
		);
		float recovery = exp(
			-recovery_x * recovery_x / (recovery_width * recovery_width)
		);
		float packet_profile = crest - valley * 0.55 + recovery * 0.20;
		float packet_derivative =
			crest * -2.0 * crest_x / (arm_width * arm_width)
			- valley * 0.55 * -2.0 * valley_x
				/ (valley_width * valley_width)
			+ recovery * 0.20 * -2.0 * recovery_x
				/ (recovery_width * recovery_width);
		float age_fade = exp(-age * directional_wake_attenuation)
			* (1.0 - smoothstep(duration * 0.62, duration, age));
		float wake_intensity = clamp(
			directional_wake_intensities[index],
			0.0,
			2.0
		);
		float base_amplitude = directional_wake_amplitude
			* wake_intensity
			* age_fade * endpoint_gate;
		if (base_amplitude <= 0.00001) {
			continue;
		}
		float turn_bias = clamp(
			directional_wake_biases[index] * directional_wake_turn_strength,
			-0.65,
			0.65
		);
		float side_sign = lateral >= 0.0 ? 1.0 : -1.0;
		float side_amplitude = 1.0 - turn_bias * side_sign;
		height += packet_profile * base_amplitude * side_amplitude;
		float creation_time_gradient = (
			directional_wake_end_times[index]
				- directional_wake_start_times[index]
		) / segment_length;
		vec2 age_gradient = -direction * creation_time_gradient;
		vec2 front_gradient = age_gradient * front_speed;
		vec2 offset_gradient = right * side_sign - front_gradient;
		derivatives += offset_gradient * packet_derivative
			* base_amplitude * side_amplitude;

		float center_width = max(initial_width * 0.72, 0.22);
		float center_gaussian = exp(
			-lateral * lateral / (center_width * center_width)
		);
		float depression = directional_wake_center_depression
			* wake_intensity
			* center_gaussian
			* exp(-age * 1.65)
			* (1.0 - smoothstep(0.75, 1.8, age))
			* endpoint_gate;
		height -= depression;
		derivatives += right * (
			depression * 2.0 * lateral / (center_width * center_width)
		);

		// A continuous, overlapping wave field fills the water between both
		// Kelvin arms. It is driven by sample age, so it moves smoothly without
		// spawning discrete rings or resetting at segment boundaries.
		float center_span = max(front_distance * 0.82, center_width);
		float center_mask = 1.0 - smoothstep(
			center_span * 0.58,
			center_span,
			absolute_lateral
		);
		float turbulence_age_gate = smoothstep(0.04, 0.24, age)
			* (1.0 - smoothstep(duration * 0.70, duration, age));
		float turbulence_wave_number = 6.28318530718 / max(
			safe_wavelength * directional_wake_center_turbulence_wavelength_scale,
			0.25
		);
		float turbulence_phase_speed = max(
			source_speed * 0.72 + directional_wake_propagation_speed * 0.85,
			0.1
		);
		float primary_phase = age * turbulence_phase_speed
			* turbulence_wave_number + lateral * turbulence_wave_number * 0.32;
		float secondary_phase = age * (turbulence_phase_speed * 1.61 + 0.37)
			* turbulence_wave_number - lateral * turbulence_wave_number * 0.53;
		float turbulence_signal = sin(primary_phase) * 0.68
			+ sin(secondary_phase) * 0.32;
		float turbulence_amplitude = directional_wake_center_turbulence
			* wake_intensity * age_fade * turbulence_age_gate
			* endpoint_gate * center_mask;
		height += turbulence_signal * turbulence_amplitude;
		vec2 primary_phase_gradient = age_gradient * turbulence_phase_speed
			* turbulence_wave_number + right * turbulence_wave_number * 0.32;
		vec2 secondary_phase_gradient = age_gradient
			* (turbulence_phase_speed * 1.61 + 0.37)
			* turbulence_wave_number - right * turbulence_wave_number * 0.53;
		derivatives += (
			cos(primary_phase) * primary_phase_gradient * 0.68
			+ cos(secondary_phase) * secondary_phase_gradient * 0.32
		) * turbulence_amplitude;
		float closure_front = initial_width * 0.55
			+ age * directional_wake_propagation_speed * 0.38;
		float closure_width = max(center_width * 0.72, 0.16);
		float closure_offset = absolute_lateral - closure_front;
		float closure_gaussian = exp(
			-closure_offset * closure_offset
				/ (closure_width * closure_width)
		);
		float closure_age_gate = smoothstep(0.08, 0.42, age)
			* (1.0 - smoothstep(0.82, 1.75, age));
		float closure_recovery = directional_wake_center_depression
			* 0.30 * wake_intensity
			* closure_gaussian * closure_age_gate * endpoint_gate;
		height += closure_recovery;
		float closure_derivative = closure_recovery
			* -2.0 * closure_offset / (closure_width * closure_width);
		vec2 closure_front_gradient = age_gradient
			* directional_wake_propagation_speed * 0.38;
		derivatives += (
			right * side_sign - closure_front_gradient
		) * closure_derivative;
		float relevance = max(
			max(crest, max(valley, recovery)),
			max(center_gaussian * exp(-age * 1.65), closure_gaussian * closure_age_gate)
		);
		local_weight_sum += endpoint_gate * relevance;
		energy = max(
			energy,
			clamp(
				(
					crest * base_amplitude
					+ abs(packet_derivative) * base_amplitude
						* arm_width * 0.18
					+ depression * 0.35
					+ closure_recovery
					+ abs(turbulence_signal * turbulence_amplitude) * 1.8
				) * 1.35,
				0.0,
				1.0
			)
		);
	}
	float local_normalization = max(local_weight_sum, 1.0);
	height /= local_normalization;
	derivatives /= local_normalization;
	return vec4(height, derivatives, energy);
}


// x: profile height, yz: spatial derivatives.
vec3 sample_landing_radial_packet(
	vec2 delta,
	float radius,
	float wavelength,
	float arm_width
) {
	float distance_to_center = length(delta);
	float front_offset = distance_to_center - radius;
	float crest_x = front_offset;
	float valley_x = front_offset + wavelength * 0.48;
	float recovery_x = front_offset + wavelength * 0.96;
	float valley_width = arm_width * 1.18;
	float recovery_width = arm_width * 1.42;
	float crest = exp(-crest_x * crest_x / (arm_width * arm_width));
	float valley = exp(
		-valley_x * valley_x / (valley_width * valley_width)
	);
	float recovery = exp(
		-recovery_x * recovery_x / (recovery_width * recovery_width)
	);
	float profile = crest - valley * 0.52 + recovery * 0.18;
	float profile_derivative =
		crest * -2.0 * crest_x / (arm_width * arm_width)
		- valley * 0.52 * -2.0 * valley_x
			/ (valley_width * valley_width)
		+ recovery * 0.18 * -2.0 * recovery_x
			/ (recovery_width * recovery_width);
	vec2 gradient = distance_to_center > 0.0001
		? delta / distance_to_center
		: vec2(0.0);
	return vec3(profile, gradient * profile_derivative);
}


// x: height, yz: spatial derivatives, w: deformation energy.
vec4 sample_landing_impact_state(vec2 logical_xz) {
	if (!landing_impacts_enabled) {
		return vec4(0.0);
	}
	float height = 0.0;
	vec2 derivatives = vec2(0.0);
	float energy = 0.0;
	float overlap_weight = 0.0;
	float impact_multiplier = landing_impact_exaggerated_debug
		? max(landing_impact_debug_multiplier, 1.0)
		: 1.0;
	for (int index = 0; index < MAX_LANDING_IMPACTS; index++) {
		if (index >= landing_impact_effective_count) {
			break;
		}
		if (landing_impact_active[index] == 0) {
			continue;
		}
		float age = simulation_time - landing_impact_start_times[index];
		float duration = max(landing_impact_durations[index], 0.05);
		if (age < 0.0 || age > duration) {
			continue;
		}
		vec2 forward = interaction_safe_direction(
			landing_impact_directions[index],
			vec2(0.0, -1.0)
		);
		vec2 right = vec2(-forward.y, forward.x);
		vec2 delta = logical_xz - landing_impact_positions[index];
		float local_forward = dot(delta, forward);
		float local_lateral = dot(delta, right);
		float strength = clamp(landing_impact_strengths[index], 0.0, 1.0);
		float initial_radius = max(landing_impact_initial_radii[index], 0.1);
		float propagation_speed = max(landing_impact_speeds[index], 0.1);
		float wavelength = max(landing_impact_wavelengths[index], 0.25);
		float radius = initial_radius + age * propagation_speed;
		float maximum_reach = radius + wavelength * 1.35;
		if (length(delta) > maximum_reach * 1.4) {
			continue;
		}
		int entry_type = landing_impact_entry_types[index];
		int contact_mask = landing_impact_contact_masks[index];
		float longitudinal_scale = 1.0;
		float lateral_scale = 1.0;
		if (entry_type == 4) {
			longitudinal_scale = 1.12;
			lateral_scale = 1.24;
		} else if (entry_type == 0 || entry_type == 1) {
			longitudinal_scale = 1.18;
			lateral_scale = 0.96;
		} else if (entry_type == 2 || entry_type == 3) {
			longitudinal_scale = 0.96;
			lateral_scale = 1.14;
		}
		vec2 elliptical_coordinates = vec2(
			local_forward / longitudinal_scale,
			local_lateral / lateral_scale
		);
		float elliptical_distance = length(elliptical_coordinates);
		float front_offset = elliptical_distance - radius;
		float arm_width = max(wavelength * 0.16, 0.24);
		if (front_offset > arm_width * 3.2
			|| front_offset < -wavelength * 1.35) {
			continue;
		}
		vec3 packet = sample_landing_radial_packet(
			elliptical_coordinates,
			radius,
			wavelength,
			arm_width
		);
		vec2 elliptical_gradient = vec2(0.0);
		float packet_derivative = 0.0;
		if (elliptical_distance > 0.0001) {
			packet_derivative = dot(
				packet.yz,
				elliptical_coordinates / elliptical_distance
			);
			elliptical_gradient =
				forward * (
					elliptical_coordinates.x
					/ (elliptical_distance * longitudinal_scale)
				)
				+ right * (
					elliptical_coordinates.y
					/ (elliptical_distance * lateral_scale)
				);
		}
		float directional_coordinate = clamp(
			(local_forward + local_lateral) / max(radius, 0.5),
			-1.0,
			1.0
		);
		float directional_weight = 1.0;
		if (entry_type == 0) {
			directional_weight += clamp(local_forward / max(radius, 0.5), -1.0, 1.0) * 0.24;
		} else if (entry_type == 1) {
			directional_weight -= clamp(local_forward / max(radius, 0.5), -1.0, 1.0) * 0.24;
		} else if (entry_type == 2) {
			directional_weight -= clamp(local_lateral / max(radius, 0.5), -1.0, 1.0) * 0.28;
		} else if (entry_type == 3) {
			directional_weight += clamp(local_lateral / max(radius, 0.5), -1.0, 1.0) * 0.28;
		} else if (entry_type == 5 || entry_type == 6) {
			directional_weight += directional_coordinate * 0.16;
		}
		if (entry_type == 5 || entry_type == 6) {
			float contact_forward = float(
				((contact_mask & 1) != 0 ? 1 : 0)
				+ ((contact_mask & 2) != 0 ? 1 : 0)
				- ((contact_mask & 4) != 0 ? 1 : 0)
				- ((contact_mask & 8) != 0 ? 1 : 0)
			);
			float contact_lateral = float(
				((contact_mask & 2) != 0 ? 1 : 0)
				+ ((contact_mask & 8) != 0 ? 1 : 0)
				- ((contact_mask & 1) != 0 ? 1 : 0)
				- ((contact_mask & 4) != 0 ? 1 : 0)
			);
			directional_weight += clamp(
				contact_forward * local_forward
					+ contact_lateral * local_lateral,
				-radius,
				radius
			) / max(radius, 0.5) / 11.75;
		}
		float age_fade = exp(-age * mix(0.20, 0.11, strength))
			* (1.0 - smoothstep(duration * 0.68, duration, age));
		float amplitude = landing_impact_amplitudes[index]
			* directional_weight * age_fade * impact_multiplier;
		height += packet.x * amplitude;
		derivatives += elliptical_gradient * packet_derivative * amplitude;

		vec2 half_extents = max(
			landing_impact_half_extents[index],
			vec2(0.25, 0.5)
		);
		float depression_lateral_radius = half_extents.x
			* mix(1.05, 1.38, strength);
		float depression_longitudinal_radius = half_extents.y
			* mix(1.02, 1.30, strength);
		float depression_gaussian = exp(
			-local_forward * local_forward
				/ (
					depression_longitudinal_radius
					* depression_longitudinal_radius
				)
			-local_lateral * local_lateral
				/ (
					depression_lateral_radius
					* depression_lateral_radius
				)
		);
		float depression_time = smoothstep(0.0, 0.035, age)
			* (1.0 - smoothstep(
				mix(0.14, 0.22, strength),
				mix(0.30, 0.45, strength),
				age
			));
		float depression = landing_impact_depressions[index]
			* depression_gaussian * depression_time * impact_multiplier;
		height -= depression;
		derivatives += depression * (
			forward * 2.0 * local_forward
				/ (
					depression_longitudinal_radius
					* depression_longitudinal_radius
				)
			+ right * 2.0 * local_lateral
				/ (
					depression_lateral_radius
					* depression_lateral_radius
				)
		);

		vec2 secondary_weights = landing_impact_secondary_weights[index];
		vec3 secondary_a = sample_landing_radial_packet(
			delta - landing_impact_secondary_a_offsets[index],
			radius * 0.88,
			wavelength * 0.80,
			arm_width * 0.87
		);
		vec3 secondary_b = sample_landing_radial_packet(
			delta - landing_impact_secondary_b_offsets[index],
			radius * 0.84,
			wavelength * 0.76,
			arm_width * 0.84
		);
		height += (
			secondary_a.x * secondary_weights.x
			+ secondary_b.x * secondary_weights.y
		) * amplitude;
		derivatives += (
			secondary_a.yz * secondary_weights.x
			+ secondary_b.yz * secondary_weights.y
		) * amplitude;
		float relevance = max(
			abs(packet.x),
			depression_gaussian * depression_time
		);
		overlap_weight += relevance;
		energy = max(
			energy,
			clamp(
				(
					max(packet.x, 0.0) * abs(amplitude)
					+ length(packet.yz) * abs(amplitude)
						* arm_width * 0.12
				) * 1.55,
				0.0,
				1.0
			)
		);
	}
	float normalization = max(overlap_weight, 1.0);
	return vec4(
		height / normalization,
		derivatives / normalization,
		energy
	);
}

// Returns height and XZ derivatives for one oriented elliptical Gaussian.
vec3 sample_hull_gaussian_lobe(
	vec2 delta,
	vec2 forward,
	vec2 right,
	float center_longitudinal,
	float center_lateral,
	float longitudinal_radius,
	float lateral_radius,
	float amplitude
) {
	float local_longitudinal = dot(delta, forward) - center_longitudinal;
	float local_lateral = dot(delta, right) - center_lateral;
	float safe_longitudinal_radius = max(longitudinal_radius, 0.05);
	float safe_lateral_radius = max(lateral_radius, 0.05);
	float gaussian = exp(
		-local_longitudinal * local_longitudinal
			/ (safe_longitudinal_radius * safe_longitudinal_radius)
		-local_lateral * local_lateral
			/ (safe_lateral_radius * safe_lateral_radius)
	);
	float height = amplitude * gaussian;
	vec2 derivative = height * (
		-2.0 * local_longitudinal
			/ (safe_longitudinal_radius * safe_longitudinal_radius) * forward
		-2.0 * local_lateral
			/ (safe_lateral_radius * safe_lateral_radius) * right
	);
	return vec3(height, derivative);
}


// x: height, yz: spatial derivatives, w: deformation energy.
vec4 sample_hull_pressure_state(vec2 logical_xz) {
	if (
		!hull_pressure_enabled
		|| hull_pressure_contact <= 0.0001
		|| hull_pressure_intensity <= 0.0001
	) {
		return vec4(0.0);
	}
	vec2 forward = interaction_safe_direction(
		hull_pressure_forward,
		vec2(0.0, -1.0)
	);
	vec2 right = vec2(-forward.y, forward.x);
	vec2 delta = logical_xz - hull_pressure_center;
	if (length(delta) > hull_pressure_maximum_distance) {
		return vec4(0.0);
	}
	float half_width = max(hull_pressure_half_extents.x, 0.25);
	float half_length = max(hull_pressure_half_extents.y, 0.5);
	float amplitude = hull_pressure_amplitude
		* hull_pressure_intensity * hull_pressure_contact;
	float turn_bias = clamp(hull_pressure_turn_bias, -0.75, 0.75);
	float pitch_bias = clamp(hull_pressure_pitch, -0.6, 0.6);
	vec3 bow = sample_hull_gaussian_lobe(
		delta,
		forward,
		right,
		half_length * (0.92 + pitch_bias * 0.18),
		0.0,
		half_length * 0.58,
		half_width * 0.88,
		amplitude * (0.82 + abs(pitch_bias) * 0.18)
	);
	vec3 left_side = sample_hull_gaussian_lobe(
		delta,
		forward,
		right,
		half_length * 0.06,
		-half_width * 0.96,
		half_length * 1.18,
		half_width * 0.54,
		amplitude * 0.62 * hull_pressure_left_strength
	);
	vec3 right_side = sample_hull_gaussian_lobe(
		delta,
		forward,
		right,
		half_length * 0.06,
		half_width * 0.96,
		half_length * 1.18,
		half_width * 0.54,
		amplitude * 0.62 * hull_pressure_right_strength
	);
	vec3 center_depression = sample_hull_gaussian_lobe(
		delta,
		forward,
		right,
		-half_length * 0.24,
		turn_bias * half_width * 0.32,
		half_length * 1.05,
		half_width * 0.86,
		-amplitude * hull_pressure_depression_strength
	);
	vec3 stern_recovery = sample_hull_gaussian_lobe(
		delta,
		forward,
		right,
		-half_length * 1.16,
		turn_bias * half_width * 0.16,
		half_length * 0.62,
		half_width * 0.76,
		amplitude * 0.22
	);
	vec3 total = bow + left_side + right_side + center_depression + stern_recovery;
	float energy = clamp(
		(abs(bow.x) + abs(left_side.x) + abs(right_side.x)
			+ abs(center_depression.x) + abs(stern_recovery.x)) * 4.0,
		0.0,
		1.0
	);
	return vec4(total.x, total.yz, energy);
}


vec4 sample_vehicle_interaction_state(vec2 logical_xz) {
	bool include_wake = ocean_interaction_debug_mode == 0
		|| ocean_interaction_debug_mode == 2
		|| ocean_interaction_debug_mode == 4;
	bool include_hull = ocean_interaction_debug_mode == 0
		|| ocean_interaction_debug_mode == 3
		|| ocean_interaction_debug_mode == 4;
	bool include_landing = ocean_interaction_debug_mode == 0
		|| ocean_interaction_debug_mode == 1
		|| ocean_interaction_debug_mode == 4;
	vec4 wake_state = include_wake
		? sample_directional_wake_state(logical_xz)
		: vec4(0.0);
	vec4 hull_state = include_hull
		? sample_hull_pressure_state(logical_xz)
		: vec4(0.0);
	vec4 landing_state = include_landing
		? sample_landing_impact_state(logical_xz)
		: vec4(0.0);
	vec4 state = wake_state + hull_state + landing_state;
	float debug_multiplier = vehicle_interaction_exaggerated_debug
		? max(vehicle_interaction_debug_multiplier, 1.0)
		: 1.0;
	state.xyz *= debug_multiplier;
	float debug_limit_scale = vehicle_interaction_exaggerated_debug
		? min(debug_multiplier, 2.5)
		: (
			landing_impact_exaggerated_debug
				? min(max(landing_impact_debug_multiplier, 1.0), 2.5)
				: 1.0
		);
	float displacement_limit = max(
		vehicle_interaction_maximum_displacement * debug_limit_scale,
		0.01
	);
	float requested_height = state.x;
	state.x = clamp(requested_height, -displacement_limit, displacement_limit);
	float derivative_limit = max(
		vehicle_interaction_maximum_derivative * debug_limit_scale,
		0.05
	);
	float derivative_magnitude = length(state.yz);
	float derivative_blend = smoothstep(
		derivative_limit * 0.75,
		derivative_limit,
		derivative_magnitude
	);
	float derivative_scale = derivative_magnitude > 0.00001
		? min(derivative_limit / derivative_magnitude, 1.0)
		: 1.0;
	state.yz *= mix(1.0, derivative_scale, derivative_blend);
	state.w = max(max(wake_state.w, hull_state.w), landing_state.w);
	return state;
}

#ifdef OCEAN_INTERACTION_FULL_OCEAN

float interaction_ripple_weight() {
	return vehicle_interaction_exaggerated_debug ? 0.0 : (
		ocean_interaction_debug_mode == 2
		|| ocean_interaction_debug_mode == 3
	) ? 0.0 : 1.0;
}

#endif

#endif
