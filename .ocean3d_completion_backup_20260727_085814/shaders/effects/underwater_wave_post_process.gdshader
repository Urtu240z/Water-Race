shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, depth_test_disabled, fog_disabled;

const int MAX_WAVE_COMPONENTS = 12;
const int MAX_ACTIVE_WAVE_SETS = 3;
const int CARRIERS_PER_SET = 3;

uniform sampler2D screen_texture : hint_screen_texture, repeat_disable, filter_linear;
uniform sampler2D depth_texture : hint_depth_texture, repeat_disable, filter_nearest;

// WaterBody3D owns and updates this canonical simulation state, including the
// finite phases corrected for floating-origin rebases.
uniform float base_height = 0.0;
uniform float simulation_time = 0.0;
uniform int active_wave_count = 0;
uniform vec2 wave_directions[12];
uniform float wave_amplitudes[12];
uniform float wave_numbers[12];
uniform float wave_angular_frequencies[12];
uniform float wave_effective_phases[12];
uniform float wave_crest_shapes[12];
uniform float wave_crest_normalizations[12];
uniform bool natural_variation_enabled = false;
uniform float phase_warp_strength = 0.0;
uniform float wave_group_strength = 0.0;
uniform vec2 modulation_directions[2];
uniform float modulation_wave_numbers[2];
uniform float modulation_angular_frequencies[2];
uniform float modulation_effective_phases[2];
uniform float wave_phase_warp_weights[12];
uniform float wave_group_weights[12];
uniform float wave_group_phase_offsets[12];

uniform int wave_set_active[3];
uniform vec2 wave_set_focus_positions[3];
uniform float wave_set_focus_times[3];
uniform vec2 wave_set_directions[3];
uniform vec2 wave_set_right_directions[3];
uniform float wave_set_group_speeds[3];
uniform float wave_set_packet_lengths[3];
uniform float wave_set_packet_widths[3];
uniform float wave_set_carrier_amplitudes[9];
uniform float wave_set_carrier_wave_numbers[9];
uniform float wave_set_carrier_angular_frequencies[9];
uniform float wave_set_carrier_phases[9];
uniform float wave_set_crest_sharpnesses[3];
uniform float wave_set_front_face_skews[3];
uniform float wave_set_third_harmonics[3];
uniform float wave_set_shape_normalizations[3];

// Optional texture-driven surface used by Ocean3D. The legacy
// analytic arrays above remain available for every other WaterBody3D scene.
const int MAX_PIXEL_OCEAN_RIPPLES = 12;
const float PIXEL_OCEAN_TAU = 6.28318530718;
uniform bool ocean_enabled = false;
uniform sampler2D wave_height_texture_a : repeat_enable, filter_linear;
uniform sampler2D wave_height_texture_b : repeat_enable, filter_linear;
uniform float wave_world_size_a = 180.0;
uniform float wave_world_size_b = 72.0;
uniform float wave_amplitude_a = 1.35;
uniform float wave_amplitude_b = 0.42;
uniform vec2 wave_direction_a = vec2(0.86, 0.51);
uniform vec2 wave_direction_b = vec2(-0.38, 0.92);
uniform float wave_travel_speed_a = 4.6;
uniform float wave_travel_speed_b = 2.3;
uniform float wave_mean_a = 0.50;
uniform float wave_mean_b = 0.47;
uniform vec2 ocean_logical_origin_offset_xz = vec2(0.0);
uniform int ripple_active[12];
uniform vec2 ripple_positions[12];
uniform float ripple_start_times[12];
uniform float ripple_amplitudes[12];
uniform float ripple_speeds[12];
uniform float ripple_wavelengths[12];
uniform float ripple_decays[12];
uniform float ripple_lifetimes[12];

uniform float camera_submersion : hint_range(0.0, 1.0) = 0.0;
uniform float camera_depth = -1.0;
uniform vec4 underwater_tint : source_color = vec4(0.18, 0.58, 0.68, 1.0);
uniform float tint_strength : hint_range(0.0, 1.0) = 0.24;
uniform float contrast : hint_range(0.25, 1.5) = 0.86;
uniform vec4 fog_color : source_color = vec4(0.025, 0.22, 0.29, 1.0);
uniform float fog_density : hint_range(0.0, 0.5) = 0.0325;
uniform float absorption_density : hint_range(0.0, 0.5) = 0.055;
uniform float distortion_strength : hint_range(0.0, 0.01) = 0.0014;
uniform float distortion_speed : hint_range(0.0, 5.0) = 0.7;
uniform float waterline_blend_width : hint_range(0.01, 1.0) = 0.12;
uniform float maximum_effect_strength : hint_range(0.0, 1.0) = 1.0;
uniform bool debug_mask_enabled = false;


float group_normalization(float group_scale) {
	float energy_normalization = inversesqrt(
		1.0 + group_scale * group_scale * 0.2564
	);
	float positive_envelope_normalization = 0.651 / max(
		1.0 - group_scale,
		0.001
	);
	return max(energy_normalization, positive_envelope_normalization);
}


float sample_regular_wave_height(vec2 world_xz) {
	float psi_0 = 0.0;
	float psi_1 = 0.0;
	float sin_psi_0 = 0.0;
	float sin_psi_1 = 0.0;
	if (natural_variation_enabled) {
		psi_0 = (
			modulation_wave_numbers[0] * dot(modulation_directions[0], world_xz)
			- modulation_angular_frequencies[0] * simulation_time
			+ modulation_effective_phases[0]
		);
		psi_1 = (
			modulation_wave_numbers[1] * dot(modulation_directions[1], world_xz)
			- modulation_angular_frequencies[1] * simulation_time
			+ modulation_effective_phases[1]
		);
		sin_psi_0 = sin(psi_0);
		sin_psi_1 = sin(psi_1);
	}

	float height = 0.0;
	for (int index = 0; index < MAX_WAVE_COMPONENTS; index++) {
		if (index >= active_wave_count) {
			break;
		}
		float theta = (
			wave_numbers[index] * dot(wave_directions[index], world_xz)
			- wave_angular_frequencies[index] * simulation_time
			+ wave_effective_phases[index]
		);
		float phase_warp = (
			phase_warp_strength * wave_phase_warp_weights[index]
			* (0.62 * sin_psi_0 + 0.38 * sin_psi_1)
		);
		float group_scale = wave_group_strength * wave_group_weights[index];
		float group_offset = wave_group_phase_offsets[index];
		float group_value = group_scale * (
			0.58 * sin(psi_0 + group_offset)
			+ 0.42 * sin(psi_1 - group_offset * 0.7)
		);
		float envelope = group_normalization(group_scale) * (1.0 + group_value);
		float warped_theta = theta + phase_warp;
		float shape = wave_crest_normalizations[index] * (
			sin(warped_theta)
			- wave_crest_shapes[index] * cos(2.0 * warped_theta)
		);
		height += wave_amplitudes[index] * envelope * shape;
	}
	return height;
}


float sample_focused_wave_height(vec2 world_xz) {
	float height = 0.0;
	for (int slot = 0; slot < MAX_ACTIVE_WAVE_SETS; slot++) {
		if (wave_set_active[slot] == 0) {
			continue;
		}
		vec2 direction = wave_set_directions[slot];
		vec2 right_direction = wave_set_right_directions[slot];
		float half_length = max(wave_set_packet_lengths[slot] * 0.5, 0.001);
		float half_width = max(wave_set_packet_widths[slot] * 0.5, 0.001);
		vec2 packet_center = wave_set_focus_positions[slot]
			+ direction * wave_set_group_speeds[slot]
				* (simulation_time - wave_set_focus_times[slot]);
		vec2 relative = world_xz - packet_center;
		float normalized_along = dot(relative, direction) / half_length;
		float normalized_across = dot(relative, right_direction) / half_width;
		float along_squared = normalized_along * normalized_along;
		float across_squared = normalized_across * normalized_across;
		float envelope = exp(
			-along_squared * along_squared - across_squared * across_squared
		);
		for (int carrier = 0; carrier < CARRIERS_PER_SET; carrier++) {
			int index = slot * CARRIERS_PER_SET + carrier;
			float theta = (
				wave_set_carrier_wave_numbers[index] * dot(direction, world_xz)
				- wave_set_carrier_angular_frequencies[index] * simulation_time
				+ wave_set_carrier_phases[index]
			);
			float shape = wave_set_shape_normalizations[slot] * (
				sin(theta)
				- wave_set_crest_sharpnesses[slot] * cos(2.0 * theta)
				+ wave_set_front_face_skews[slot] * sin(2.0 * theta)
				+ wave_set_third_harmonics[slot] * sin(3.0 * theta)
			);
			height += wave_set_carrier_amplitudes[index] * envelope * shape;
		}
	}
	return height;
}


vec2 pixel_ocean_safe_direction(vec2 direction, vec2 fallback) {
	float magnitude = length(direction);
	return magnitude > 0.00001 ? direction / magnitude : fallback;
}


float sample_pixel_ocean_height(vec2 world_xz) {
	vec2 logical_xz = world_xz + ocean_logical_origin_offset_xz;
	float safe_size_a = max(wave_world_size_a, 0.001);
	float safe_size_b = max(wave_world_size_b, 0.001);
	vec2 uv_a = logical_xz / safe_size_a
		+ pixel_ocean_safe_direction(wave_direction_a, vec2(1.0, 0.0))
			* simulation_time * wave_travel_speed_a / safe_size_a;
	vec2 uv_b = logical_xz / safe_size_b
		+ pixel_ocean_safe_direction(wave_direction_b, vec2(0.0, -1.0))
			* simulation_time * wave_travel_speed_b / safe_size_b
		+ vec2(0.307, 0.476);
	float height = (
		texture(wave_height_texture_a, uv_a).r - wave_mean_a
	) * wave_amplitude_a;
	height += (
		texture(wave_height_texture_b, uv_b).r - wave_mean_b
	) * wave_amplitude_b;
	for (int index = 0; index < MAX_PIXEL_OCEAN_RIPPLES; index++) {
		if (ripple_active[index] == 0) {
			continue;
		}
		float age = simulation_time - ripple_start_times[index];
		if (age < 0.0 || age > ripple_lifetimes[index]) {
			continue;
		}
		float radius = age * ripple_speeds[index];
		float distance_to_center = length(
			logical_xz - ripple_positions[index]
		);
		float wavelength = max(ripple_wavelengths[index], 0.05);
		float shell_width = max(wavelength * 1.35, 0.1);
		float shell_offset = distance_to_center - radius;
		float normalized_shell = shell_offset / shell_width;
		float envelope = exp(-normalized_shell * normalized_shell)
			* exp(-age * ripple_decays[index])
			* smoothstep(0.0, 0.18, age);
		height += sin(shell_offset * PIXEL_OCEAN_TAU / wavelength)
			* ripple_amplitudes[index] * envelope;
	}
	return height;
}


float sample_surface_height(vec2 world_xz) {
	if (ocean_enabled) {
		return base_height + sample_pixel_ocean_height(world_xz);
	}
	return (
		base_height
		+ sample_regular_wave_height(world_xz)
		+ sample_focused_wave_height(world_xz)
	);
}


void vertex() {
	// Godot 4.3+ uses reverse-Z: put the full-screen quad on the near plane.
	POSITION = vec4(VERTEX.xy, 1.0, 1.0);
}


void fragment() {
	float raw_depth = texture(depth_texture, SCREEN_UV).x;
	bool is_sky = raw_depth <= 0.000001;
	float underwater_mask = 1.0;
	float scene_distance = max(camera_depth, 0.0);
	float submerged_distance = max(camera_depth, 0.0);

	if (!is_sky) {
		vec3 ndc = vec3(SCREEN_UV * 2.0 - 1.0, raw_depth);
		vec4 view_position = INV_PROJECTION_MATRIX * vec4(ndc, 1.0);
		view_position.xyz /= view_position.w;
		vec3 world_position = (
			INV_VIEW_MATRIX * vec4(view_position.xyz, 1.0)
		).xyz;
		float surface_height = sample_surface_height(world_position.xz);
		submerged_distance = surface_height - world_position.y;
		underwater_mask = smoothstep(
			-waterline_blend_width,
			waterline_blend_width,
			submerged_distance
		);
		scene_distance = length(view_position.xyz);
	}

	// The reconstructed surface only shapes the effect after the camera itself
	// has crossed the wave. Geometry below water must never tint an air camera.
	underwater_mask *= camera_submersion * maximum_effect_strength;
	vec2 pixel_size = 1.0 / VIEWPORT_SIZE;
	float ripple_x = sin(
		SCREEN_UV.y * 74.0 + SCREEN_UV.x * 13.0
		+ simulation_time * distortion_speed * 2.1
	);
	float ripple_y = cos(
		SCREEN_UV.x * 67.0 - SCREEN_UV.y * 9.0
		- simulation_time * distortion_speed * 1.7
	);
	vec2 warped_uv = clamp(
		SCREEN_UV
			+ vec2(ripple_x, ripple_y) * distortion_strength * underwater_mask,
		pixel_size,
		vec2(1.0) - pixel_size
	);
	vec3 scene_color = texture(screen_texture, warped_uv).rgb;
	vec3 tinted_color = mix(
		scene_color,
		scene_color * underwater_tint.rgb,
		tint_strength
	);
	float luminance = dot(tinted_color, vec3(0.2126, 0.7152, 0.0722));
	tinted_color = mix(vec3(luminance), tinted_color, contrast);

	float water_distance = mix(
		max(submerged_distance, 0.0),
		scene_distance,
		camera_submersion
	);
	float absorption = 1.0 - exp(
		-absorption_density * max(water_distance, 0.0)
	);
	float fog_amount = 1.0 - exp(
		-fog_density * max(water_distance, 0.0)
	);
	tinted_color = mix(
		tinted_color,
		tinted_color * vec3(0.52, 0.88, 0.92),
		absorption * 0.55
	);
	tinted_color = mix(tinted_color, fog_color.rgb, fog_amount);
	ALBEDO = debug_mask_enabled
		? vec3(underwater_mask)
		: mix(scene_color, tinted_color, underwater_mask);
}
