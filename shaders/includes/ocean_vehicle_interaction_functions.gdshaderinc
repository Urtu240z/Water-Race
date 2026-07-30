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
	float wave_number = TAU_VALUE / safe_wavelength;
	float maximum_distance = max(directional_wake_maximum_distance, 0.1);
	float duration = max(directional_wake_duration, 0.05);
	float sample_normalization = inversesqrt(
		max(float(directional_wake_active_count), 1.0)
	);
	for (int index = 0; index < MAX_DIRECTIONAL_WAKE_SAMPLES; index++) {
		if (index >= directional_wake_active_count) {
			break;
		}
		float age = simulation_time - directional_wake_start_times[index];
		if (age < 0.0 || age > duration) {
			continue;
		}
		vec2 direction = interaction_safe_direction(
			directional_wake_directions[index],
			vec2(0.0, -1.0)
		);
		vec2 right = vec2(-direction.y, direction.x);
		vec2 delta = logical_xz - directional_wake_positions[index];
		float behind = -dot(delta, direction);
		if (behind < -0.75 || behind > maximum_distance) {
			continue;
		}
		float lateral = dot(delta, right);
		float initial_width = max(directional_wake_widths[index], 0.15);
		float opening = max(behind, 0.0) * directional_wake_opening_slope;
		float propagation = age * directional_wake_propagation_speed * 0.08;
		float preliminary_arm_offset = initial_width + opening + propagation;
		float preliminary_arm_width = max(
			directional_wake_arm_width * mix(
				0.82,
				1.28,
				clamp(behind / maximum_distance, 0.0, 1.0)
			),
			0.08
		);
		if (
			abs(lateral)
			> preliminary_arm_offset
				+ preliminary_arm_width * 3.35
				+ safe_wavelength * 0.05
		) {
			continue;
		}
		float stable_irregularity = sin(
			dot(logical_xz, vec2(0.071, -0.053))
				+ dot(directional_wake_positions[index], vec2(0.037, 0.061))
		) * safe_wavelength * 0.045;
		float arm_offset = preliminary_arm_offset + stable_irregularity;
		float left_distance = lateral + arm_offset;
		float right_distance = lateral - arm_offset;
		float arm_width = preliminary_arm_width;
		float distance_fade = exp(
			-max(behind, 0.0) * directional_wake_attenuation
		) * (1.0 - smoothstep(maximum_distance * 0.72, maximum_distance, behind));
		float age_fade = 1.0 - smoothstep(duration * 0.42, duration, age);
		float forward_gate = smoothstep(-0.75, 0.35, behind);
		float base_amplitude = directional_wake_amplitude
			* clamp(directional_wake_intensities[index], 0.0, 1.0)
			* distance_fade * age_fade * forward_gate * sample_normalization;
		if (base_amplitude <= 0.00001) {
			continue;
		}
		float turn_bias = clamp(
			directional_wake_biases[index] * directional_wake_turn_strength,
			-0.65,
			0.65
		);
		float left_amplitude = base_amplitude * (1.0 + turn_bias);
		float right_amplitude = base_amplitude * (1.0 - turn_bias);
		float phase_travel = age * directional_wake_propagation_speed;
		float left_phase = (left_distance - phase_travel) * wave_number;
		float right_phase = (right_distance + phase_travel) * wave_number;
		float left_gaussian = exp(
			-left_distance * left_distance / (arm_width * arm_width)
		);
		float right_gaussian = exp(
			-right_distance * right_distance / (arm_width * arm_width)
		);
		float left_sine = sin(left_phase);
		float right_sine = sin(right_phase);
		height += left_sine * left_amplitude * left_gaussian;
		height += right_sine * right_amplitude * right_gaussian;
		vec2 opening_gradient = -direction * directional_wake_opening_slope;
		vec2 left_gradient = right + opening_gradient;
		vec2 right_gradient = right - opening_gradient;
		float left_derivative = left_amplitude * left_gaussian * (
			wave_number * cos(left_phase)
				- 2.0 * left_distance / (arm_width * arm_width) * left_sine
		);
		float right_derivative = right_amplitude * right_gaussian * (
			wave_number * cos(right_phase)
				- 2.0 * right_distance / (arm_width * arm_width) * right_sine
		);
		derivatives += left_gradient * left_derivative;
		derivatives += right_gradient * right_derivative;

		float center_width = max(arm_offset * 0.74, initial_width);
		float shifted_lateral = lateral - turn_bias * initial_width * 0.32;
		float center_gaussian = exp(
			-shifted_lateral * shifted_lateral / (center_width * center_width)
		);
		float center_envelope = smoothstep(0.0, 2.0, behind)
			* (1.0 - smoothstep(maximum_distance * 0.48, maximum_distance, behind));
		float depression = directional_wake_center_depression
			* clamp(directional_wake_intensities[index], 0.0, 1.0)
			* center_gaussian * center_envelope * age_fade * sample_normalization;
		height -= depression;
		derivatives += right * (
			depression * 2.0 * shifted_lateral / (center_width * center_width)
		);
		float recovery = depression * 0.24 * smoothstep(
			maximum_distance * 0.34,
			maximum_distance * 0.72,
			behind
		);
		height += recovery;
		energy = max(
			energy,
			clamp(
				(abs(left_amplitude) * left_gaussian
					+ abs(right_amplitude) * right_gaussian
					+ depression) * 5.0,
				0.0,
				1.0
			)
		);
	}
	return vec4(height, derivatives, energy);
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
	vec4 wake_state = include_wake
		? sample_directional_wake_state(logical_xz)
		: vec4(0.0);
	vec4 hull_state = include_hull
		? sample_hull_pressure_state(logical_xz)
		: vec4(0.0);
	vec4 state = wake_state + hull_state;
	float displacement_limit = max(vehicle_interaction_maximum_displacement, 0.01);
	float requested_height = state.x;
	float clamp_scale = abs(requested_height) > displacement_limit
		? displacement_limit / max(abs(requested_height), 0.00001)
		: 1.0;
	state.xyz *= clamp_scale;
	state.w = max(wake_state.w, hull_state.w);
	return state;
}


float interaction_ripple_weight() {
	return (
		ocean_interaction_debug_mode == 2
		|| ocean_interaction_debug_mode == 3
	) ? 0.0 : 1.0;
}
