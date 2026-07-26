shader_type spatial;
render_mode blend_mix, world_vertex_coords, cull_back, diffuse_burley, specular_schlick_ggx;

const int MAX_WAVE_COMPONENTS = 12;
const int MAX_ACTIVE_WAVE_SETS = 3;
const int CARRIERS_PER_SET = 3;

uniform float base_height = 0.0;
uniform float simulation_time = 0.0;
uniform int active_wave_count = 4;
uniform vec2 wave_directions[12];
uniform float wave_amplitudes[12];
uniform float wave_numbers[12];
uniform float wave_angular_frequencies[12];
// Always receives the finite, TAU-reduced effective phase. No growing world
// origin coordinate is transported to the GPU.
uniform float wave_effective_phases[12];
uniform float wave_crest_shapes[12];
uniform float wave_crest_normalizations[12];
uniform float wave_horizontal_amplitudes[12];
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
uniform float wave_set_total_amplitudes[3];
uniform int wave_set_strength_categories[3];
uniform float wave_set_carrier_amplitudes[9];
uniform float wave_set_carrier_wave_numbers[9];
uniform float wave_set_carrier_angular_frequencies[9];
uniform float wave_set_carrier_phases[9];
uniform float wave_set_crest_sharpnesses[3];
uniform float wave_set_front_face_skews[3];
uniform float wave_set_third_harmonics[3];
uniform float wave_set_shape_normalizations[3];

uniform sampler2D screen_texture : hint_screen_texture, repeat_disable, filter_linear_mipmap;
uniform sampler2D depth_texture : hint_depth_texture, repeat_disable, filter_nearest;

uniform vec4 shallow_water_color : source_color = vec4(0.055, 0.42, 0.56, 1.0);
uniform vec4 deep_water_color : source_color = vec4(0.012, 0.085, 0.15, 1.0);
uniform vec4 horizon_water_color : source_color = vec4(0.12, 0.46, 0.62, 1.0);
uniform vec4 reflection_tint : source_color = vec4(0.62, 0.82, 0.96, 1.0);
uniform float absorption_density : hint_range(0.01, 2.0, 0.01) = 0.18;
uniform float maximum_optical_depth : hint_range(1.0, 100.0, 0.5) = 25.0;
uniform float shallow_depth_range : hint_range(0.1, 20.0, 0.1) = 5.0;
uniform float seabed_fade_start : hint_range(0.0, 20.0, 0.1) = 1.5;
uniform float seabed_fade_end : hint_range(0.1, 70.0, 0.1) = 5.0;
uniform float near_water_alpha : hint_range(0.50, 1.0, 0.01) = 0.84;
uniform float deep_water_alpha : hint_range(0.50, 1.0, 0.01) = 0.98;
uniform float horizon_water_alpha : hint_range(0.90, 1.0, 0.01) = 1.0;
uniform float opacity_distance_start : hint_range(0.0, 200.0, 1.0) = 10.0;
uniform float opacity_distance_end : hint_range(1.0, 500.0, 1.0) = 45.0;
uniform float fresnel_power : hint_range(0.5, 12.0, 0.1) = 3.5;
uniform float fresnel_opacity_strength : hint_range(0.0, 1.0, 0.01) = 0.95;
uniform float reflection_strength : hint_range(0.0, 1.0, 0.01) = 0.72;
uniform float refraction_strength : hint_range(0.0, 0.05, 0.0005) = 0.008;
uniform float refraction_depth_range : hint_range(0.1, 20.0, 0.1) = 4.5;
uniform float refraction_distance_fade : hint_range(0.0, 1.0, 0.01) = 0.90;
uniform float refraction_fresnel_fade : hint_range(0.0, 1.0, 0.01) = 0.85;
uniform float near_water_roughness : hint_range(0.02, 0.8, 0.01) = 0.12;
uniform float horizon_water_roughness : hint_range(0.02, 0.8, 0.01) = 0.22;
uniform float water_specular : hint_range(0.0, 1.0, 0.01) = 0.85;
uniform float crest_scattering_strength : hint_range(0.0, 1.0, 0.01) = 0.18;
uniform float crest_scattering_power : hint_range(0.5, 8.0, 0.1) = 2.2;
uniform vec4 crest_scattering_color : source_color = vec4(0.38, 0.82, 0.88, 1.0);
uniform int water_optics_debug_mode : hint_range(0, 6, 1) = 0;

uniform bool foam_enabled = true;
uniform sampler2D foam_noise_texture : repeat_enable, filter_linear_mipmap;
uniform vec4 foam_color : source_color = vec4(0.82, 0.94, 0.98, 1.0);
uniform float foam_amount : hint_range(0.0, 1.0, 0.01) = 0.72;
uniform float foam_roughness : hint_range(0.0, 1.0, 0.01) = 0.86;
uniform float foam_specular : hint_range(0.0, 1.0, 0.01) = 0.18;
uniform float breaking_threshold = 0.62;
uniform float breaking_softness = 0.14;
uniform float foam_macro_noise_scale = 0.055;
uniform float foam_detail_noise_scale = 0.19;
uniform float foam_noise_scroll_speed = 0.16;
uniform float foam_breakup_strength = 0.78;
uniform float base_ocean_foam_amount = 0.04;
uniform float wave_set_foam_amount = 0.90;
uniform vec2 foam_logical_origin_xz = vec2(0.0);
uniform vec2 foam_dominant_direction = vec2(1.0, 0.0);

// Organic, non-pixelated surface detail inspired by Taillight Games' layered
// water normals. The macro geometry and physics remain driven by the analytic
// Water Race wave system above; these textures only enrich the optical surface.
group_uniforms OrganicSurface;
uniform int surface_detail_mode : hint_enum("Off", "Crossed", "Stochastic") = 2;
uniform sampler2D surface_normal_texture_a : hint_normal, repeat_enable, filter_linear_mipmap_anisotropic;
uniform sampler2D surface_normal_texture_b : hint_normal, repeat_enable, filter_linear_mipmap_anisotropic;
uniform sampler2D surface_warp_texture : repeat_enable, filter_linear_mipmap;
uniform float surface_normal_strength : hint_range(0.0, 2.0, 0.01) = 0.72;
uniform float surface_normal_world_size_a : hint_range(0.25, 80.0, 0.05) = 7.5;
uniform float surface_normal_world_size_b : hint_range(0.25, 80.0, 0.05) = 3.25;
uniform vec2 surface_flow_direction_a = vec2(0.82, 0.57);
uniform vec2 surface_flow_direction_b = vec2(-0.46, 0.89);
uniform float surface_flow_speed_a : hint_range(-3.0, 3.0, 0.01) = 0.38;
uniform float surface_flow_speed_b : hint_range(-3.0, 3.0, 0.01) = -0.26;
uniform float surface_warp_world_size : hint_range(2.0, 300.0, 0.5) = 46.0;
uniform float surface_warp_strength : hint_range(0.0, 12.0, 0.05) = 2.4;
uniform vec2 surface_warp_direction = vec2(0.31, -0.95);
uniform float surface_warp_speed : hint_range(-1.0, 1.0, 0.005) = 0.055;
uniform float surface_stochastic_cell_size : hint_range(2.0, 120.0, 0.5) = 26.0;
uniform float surface_stochastic_rotation : hint_range(0.0, 1.0, 0.01) = 0.90;
uniform float surface_detail_fade_start : hint_range(0.0, 1000.0, 1.0) = 150.0;
uniform float surface_detail_fade_end : hint_range(1.0, 2000.0, 1.0) = 620.0;
uniform float surface_roughness_variation : hint_range(0.0, 0.35, 0.005) = 0.075;
uniform float surface_refraction_detail_strength : hint_range(0.0, 2.0, 0.01) = 1.0;

group_uniforms WaveColor;
uniform bool wave_height_color_enabled = true;
uniform vec4 wave_trough_color : source_color = vec4(0.006, 0.050, 0.105, 1.0);
uniform vec4 wave_crest_color : source_color = vec4(0.090, 0.500, 0.610, 1.0);
uniform float wave_height_color_strength : hint_range(0.0, 1.0, 0.01) = 0.24;
uniform float wave_height_color_range : hint_range(0.05, 8.0, 0.05) = 1.35;
uniform float wave_height_color_bias : hint_range(-2.0, 2.0, 0.01) = 0.0;
uniform float wave_compression_color_strength : hint_range(0.0, 1.0, 0.01) = 0.18;
group_uniforms;

// Optional geometry LOD used by OceanClipmap3D. Disabled by default so the
// original WaterBody3D plane retains its exact rendering behavior.
// With world_vertex_coords, VERTEX.xz already contains local mesh coordinates
// plus the snapped physical origin. WaterBody3D folds the accumulated logical
// origin into wave_effective_phases, so adding either origin here would double it.
uniform bool ocean_clipmap_enabled = false;
uniform vec2 ocean_snapped_origin_xz = vec2(0.0);
uniform vec2 ocean_logical_origin_offset_xz = vec2(0.0);
uniform vec2 ocean_detail_center_xz = vec2(0.0);
uniform float ocean_detailed_wave_fade_start = 170.0;
uniform float ocean_detailed_wave_fade_end = 280.0;
uniform float ocean_medium_wave_fade_end = 680.0;
uniform float ocean_middle_wave_amplitude_ratio = 0.55;
uniform float ocean_far_wave_amplitude_ratio = 0.08;
uniform bool ocean_debug_show_rings = false;

varying float interpolated_wave_height;
varying float interpolated_wave_slope;
varying vec2 interpolated_world_xz;
varying float interpolated_wave_set_breaking;
varying float interpolated_surface_vertical_velocity;
varying float interpolated_surface_curvature;
varying float interpolated_constructive_interference;
varying float interpolated_surface_compression;
varying float interpolated_ocean_ring_id;


float ocean_wave_lod_factor(int wave_index, vec2 world_xz) {
	if (!ocean_clipmap_enabled) {
		return 1.0;
	}
	float distance_to_detail = length(world_xz - ocean_detail_center_xz);
	float detailed_factor = 1.0 - smoothstep(
		ocean_detailed_wave_fade_start,
		ocean_detailed_wave_fade_end,
		distance_to_detail
	);
	float medium_factor = 1.0 - smoothstep(
		ocean_detailed_wave_fade_end,
		max(ocean_medium_wave_fade_end, ocean_detailed_wave_fade_end + 0.001),
		distance_to_detail
	);
	float large_target = mix(
		ocean_far_wave_amplitude_ratio,
		ocean_middle_wave_amplitude_ratio,
		medium_factor
	);
	if (wave_index < 4) {
		return mix(large_target, 1.0, detailed_factor);
	}
	if (wave_index < 8) {
		return mix(
			ocean_middle_wave_amplitude_ratio * medium_factor,
			1.0,
			detailed_factor
		);
	}
	return detailed_factor;
}


vec3 ocean_debug_ring_color(float ring_id) {
	if (ring_id < 0.25) {
		return vec3(0.08, 0.78, 1.0);
	}
	if (ring_id < 0.75) {
		return vec3(1.0, 0.62, 0.08);
	}
	return vec3(0.84, 0.18, 0.92);
}


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


void sample_waves(
	vec2 world_xz,
	out float height,
	out vec2 derivatives,
	out vec2 horizontal_displacement,
	out vec2 horizontal_derivative_x,
	out vec2 horizontal_derivative_z,
	out float vertical_velocity,
	out float curvature_concentration,
	out float positive_height_sum,
	out float strongest_positive_height
) {
	height = 0.0;
	derivatives = vec2(0.0);
	horizontal_displacement = vec2(0.0);
	horizontal_derivative_x = vec2(0.0);
	horizontal_derivative_z = vec2(0.0);
	vertical_velocity = 0.0;
	curvature_concentration = 0.0;
	positive_height_sum = 0.0;
	strongest_positive_height = 0.0;
	float psi_0 = 0.0;
	float psi_1 = 0.0;
	float sin_psi_0 = 0.0;
	float sin_psi_1 = 0.0;
	float cos_psi_0 = 0.0;
	float cos_psi_1 = 0.0;
	vec2 dpsi_0 = vec2(0.0);
	vec2 dpsi_1 = vec2(0.0);
	float dpsi_0_dt = 0.0;
	float dpsi_1_dt = 0.0;
	if (natural_variation_enabled) {
		psi_0 = (
			modulation_wave_numbers[0]
			* dot(modulation_directions[0], world_xz)
			- modulation_angular_frequencies[0] * simulation_time
			+ modulation_effective_phases[0]
		);
		psi_1 = (
			modulation_wave_numbers[1]
			* dot(modulation_directions[1], world_xz)
			- modulation_angular_frequencies[1] * simulation_time
			+ modulation_effective_phases[1]
		);
		sin_psi_0 = sin(psi_0);
		sin_psi_1 = sin(psi_1);
		cos_psi_0 = cos(psi_0);
		cos_psi_1 = cos(psi_1);
		dpsi_0 = modulation_wave_numbers[0] * modulation_directions[0];
		dpsi_1 = modulation_wave_numbers[1] * modulation_directions[1];
		dpsi_0_dt = -modulation_angular_frequencies[0];
		dpsi_1_dt = -modulation_angular_frequencies[1];
	}
	for (int index = 0; index < MAX_WAVE_COMPONENTS; index++) {
		if (index >= active_wave_count) {
			break;
		}
		vec2 direction = wave_directions[index];
		float theta = (
			wave_numbers[index] * dot(direction, world_xz)
			- wave_angular_frequencies[index] * simulation_time
			+ wave_effective_phases[index]
		);
		float phase_warp_scale = (
			phase_warp_strength * wave_phase_warp_weights[index]
		);
		float phase_warp = phase_warp_scale * (
			0.62 * sin_psi_0 + 0.38 * sin_psi_1
		);
		vec2 phase_warp_derivatives = phase_warp_scale * (
			0.62 * cos_psi_0 * dpsi_0
			+ 0.38 * cos_psi_1 * dpsi_1
		);
		float phase_warp_dt = phase_warp_scale * (
			0.62 * cos_psi_0 * dpsi_0_dt
			+ 0.38 * cos_psi_1 * dpsi_1_dt
		);
		float warped_theta = theta + phase_warp;
		vec2 warped_theta_derivatives = (
			wave_numbers[index] * direction
			+ phase_warp_derivatives
		);
		float group_scale = wave_group_strength * wave_group_weights[index];
		float group_offset = wave_group_phase_offsets[index];
		float group_phase_0 = psi_0 + group_offset;
		float group_phase_1 = psi_1 - group_offset * 0.7;
		float group_value = group_scale * (
			0.58 * sin(group_phase_0) + 0.42 * sin(group_phase_1)
		);
		vec2 group_derivatives = group_scale * (
			0.58 * cos(group_phase_0) * dpsi_0
			+ 0.42 * cos(group_phase_1) * dpsi_1
		);
		float group_dt = group_scale * (
			0.58 * cos(group_phase_0) * dpsi_0_dt
			+ 0.42 * cos(group_phase_1) * dpsi_1_dt
		);
		float envelope_normalization = group_normalization(group_scale);
		float envelope = envelope_normalization * (1.0 + group_value);
		vec2 envelope_derivatives = (
			envelope_normalization * group_derivatives
		);
		float envelope_dt = envelope_normalization * group_dt;
		float phase_2 = 2.0 * warped_theta;
		float crest_shape = wave_crest_shapes[index];
		float normalization = wave_crest_normalizations[index];
		float shape = normalization * (
			sin(warped_theta) - crest_shape * cos(phase_2)
		);
		float shape_derivative = normalization * (
			cos(warped_theta) + 2.0 * crest_shape * sin(phase_2)
		);
		float shape_second_derivative = normalization * (
			-sin(warped_theta) + 4.0 * crest_shape * cos(phase_2)
		);
		float wave_lod_factor = ocean_wave_lod_factor(
			index,
			world_xz
		);
		float amplitude = wave_amplitudes[index] * wave_lod_factor;
		float carrier_height = amplitude * envelope * shape;
		float warped_theta_dt = -wave_angular_frequencies[index] + phase_warp_dt;
		float horizontal_amplitude = (
			wave_horizontal_amplitudes[index] * wave_lod_factor
		);
		float fundamental_cosine = cos(warped_theta);
		float fundamental_sine = sin(warped_theta);
		horizontal_displacement += direction * (
			horizontal_amplitude * envelope * fundamental_cosine
		);
		horizontal_derivative_x += direction * horizontal_amplitude * (
			envelope_derivatives.x * fundamental_cosine
			- envelope * fundamental_sine * warped_theta_derivatives.x
		);
		horizontal_derivative_z += direction * horizontal_amplitude * (
			envelope_derivatives.y * fundamental_cosine
			- envelope * fundamental_sine * warped_theta_derivatives.y
		);
		height += carrier_height;
		derivatives += amplitude * (
			envelope_derivatives * shape
			+ envelope * shape_derivative * warped_theta_derivatives
		);
		vertical_velocity += amplitude * (
			envelope_dt * shape
			+ envelope * shape_derivative * warped_theta_dt
		);
		curvature_concentration += max(
			-amplitude * envelope * shape_second_derivative
				* dot(warped_theta_derivatives, warped_theta_derivatives),
			0.0
		);
		float positive_height = max(carrier_height, 0.0);
		positive_height_sum += positive_height;
		strongest_positive_height = max(strongest_positive_height, positive_height);
	}
}


void sample_wave_sets(
	vec2 world_xz,
	out float height,
	out vec2 derivatives,
	out float vertical_velocity,
	out float breaking_metric,
	out float curvature_concentration,
	out float positive_height_sum,
	out float strongest_positive_height
) {
	height = 0.0;
	derivatives = vec2(0.0);
	vertical_velocity = 0.0;
	breaking_metric = 0.0;
	curvature_concentration = 0.0;
	positive_height_sum = 0.0;
	strongest_positive_height = 0.0;
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
		vec2 envelope_exponent_derivatives =
			-4.0 * normalized_along * along_squared * direction / half_length
			- 4.0 * normalized_across * across_squared * right_direction / half_width;
		float envelope_exponent_dt = -4.0 * normalized_along * along_squared
			* (-wave_set_group_speeds[slot] / half_length);
		vec2 envelope_derivatives = envelope * envelope_exponent_derivatives;
		float envelope_dt = envelope * envelope_exponent_dt;
		float set_height = 0.0;
		float set_vertical_velocity = 0.0;
		float curvature_signal = 0.0;
		float front_face_signal = 0.0;
		float amplitude_scale = max(wave_set_total_amplitudes[slot], 0.001);
		for (int carrier = 0; carrier < CARRIERS_PER_SET; carrier++) {
			int index = slot * CARRIERS_PER_SET + carrier;
			float wave_number = wave_set_carrier_wave_numbers[index];
			float angular_frequency = wave_set_carrier_angular_frequencies[index];
			float theta = wave_number * dot(direction, world_xz)
				- angular_frequency * simulation_time
				+ wave_set_carrier_phases[index];
			float normalization = wave_set_shape_normalizations[slot];
			float crest_sharpness = wave_set_crest_sharpnesses[slot];
			float front_face_skew = wave_set_front_face_skews[slot];
			float third_harmonic = wave_set_third_harmonics[slot];
			float shape = normalization * (
				sin(theta) - crest_sharpness * cos(2.0 * theta)
				+ front_face_skew * sin(2.0 * theta)
				+ third_harmonic * sin(3.0 * theta)
			);
			float shape_derivative = normalization * (
				cos(theta) + 2.0 * crest_sharpness * sin(2.0 * theta)
				+ 2.0 * front_face_skew * cos(2.0 * theta)
				+ 3.0 * third_harmonic * cos(3.0 * theta)
			);
			float shape_second_derivative = normalization * (
				-sin(theta) + 4.0 * crest_sharpness * cos(2.0 * theta)
				- 4.0 * front_face_skew * sin(2.0 * theta)
				- 9.0 * third_harmonic * sin(3.0 * theta)
			);
			float amplitude = wave_set_carrier_amplitudes[index];
			float carrier_height = amplitude * envelope * shape;
			float carrier_vertical_velocity = amplitude * (
				envelope_dt * shape - envelope * shape_derivative * angular_frequency
			);
			height += carrier_height;
			derivatives += amplitude * (
				envelope_derivatives * shape
				+ envelope * shape_derivative * wave_number * direction
			);
			vertical_velocity += carrier_vertical_velocity;
			curvature_concentration += max(
				-amplitude * envelope * shape_second_derivative
					* wave_number * wave_number,
				0.0
			);
			float positive_height = max(carrier_height, 0.0);
			positive_height_sum += positive_height;
			strongest_positive_height = max(
				strongest_positive_height,
				positive_height
			);
			set_height += carrier_height;
			set_vertical_velocity += carrier_vertical_velocity;
			curvature_signal += amplitude * max(-shape_second_derivative, 0.0)
				/ amplitude_scale;
			front_face_signal += max(-amplitude * shape_derivative * wave_number, 0.0)
				/ amplitude_scale;
		}
		float softness = max(breaking_softness, 0.01);
		float crest_factor = smoothstep(
			breaking_threshold - softness,
			breaking_threshold + softness,
			max(set_height / amplitude_scale, 0.0)
		);
		float curvature_factor = smoothstep(0.18, 0.85, curvature_signal);
		float front_face_factor = smoothstep(0.02, 0.18, front_face_signal);
		float rise_factor = smoothstep(0.02, 0.55, max(set_vertical_velocity, 0.0));
		float strength_factor = mix(
			0.75,
			1.0,
			float(wave_set_strength_categories[slot]) / 2.0
		);
		float metric = envelope * crest_factor
			* max(curvature_factor, front_face_factor)
			* mix(0.75, 1.0, rise_factor) * strength_factor;
		breaking_metric = max(breaking_metric, metric);
	}
	breaking_metric = clamp(breaking_metric, 0.0, 1.0);
}


void vertex() {
	vec2 source_xz = VERTEX.xz;
	float wave_height;
	vec2 wave_derivatives;
	vec2 wave_horizontal_displacement;
	vec2 wave_horizontal_derivative_x;
	vec2 wave_horizontal_derivative_z;
	float wave_vertical_velocity;
	float wave_curvature;
	float wave_positive_height_sum;
	float wave_strongest_positive_height;
	sample_waves(
		source_xz,
		wave_height,
		wave_derivatives,
		wave_horizontal_displacement,
		wave_horizontal_derivative_x,
		wave_horizontal_derivative_z,
		wave_vertical_velocity,
		wave_curvature,
		wave_positive_height_sum,
		wave_strongest_positive_height
	);
	float wave_set_height;
	vec2 wave_set_derivatives;
	float wave_set_vertical_velocity;
	float wave_set_breaking;
	float wave_set_curvature;
	float wave_set_positive_height_sum;
	float wave_set_strongest_positive_height;
	sample_wave_sets(
		source_xz,
		wave_set_height,
		wave_set_derivatives,
		wave_set_vertical_velocity,
		wave_set_breaking,
		wave_set_curvature,
		wave_set_positive_height_sum,
		wave_set_strongest_positive_height
	);
	float wave_set_lod_factor = ocean_wave_lod_factor(0, source_xz);
	wave_set_height *= wave_set_lod_factor;
	wave_set_derivatives *= wave_set_lod_factor;
	wave_set_vertical_velocity *= wave_set_lod_factor;
	wave_set_breaking *= wave_set_lod_factor;
	wave_set_curvature *= wave_set_lod_factor;
	wave_set_positive_height_sum *= wave_set_lod_factor;
	wave_set_strongest_positive_height *= wave_set_lod_factor;
	wave_height += wave_set_height;
	wave_derivatives += wave_set_derivatives;
	VERTEX.xz = source_xz + wave_horizontal_displacement;
	VERTEX.y = base_height + wave_height;
	vec3 tangent_x = vec3(
		1.0 + wave_horizontal_derivative_x.x,
		wave_derivatives.x,
		wave_horizontal_derivative_x.y
	);
	vec3 tangent_z = vec3(
		wave_horizontal_derivative_z.x,
		wave_derivatives.y,
		1.0 + wave_horizontal_derivative_z.y
	);
	vec3 surface_normal = normalize(cross(tangent_z, tangent_x));
	if (surface_normal.y < 0.0) {
		surface_normal = -surface_normal;
	}
	NORMAL = surface_normal;
	interpolated_wave_height = wave_height;
	float safe_normal_y = max(surface_normal.y, 0.001);
	interpolated_wave_slope = length(vec2(
		-surface_normal.x / safe_normal_y,
		-surface_normal.z / safe_normal_y
	));
	interpolated_world_xz = VERTEX.xz;
	interpolated_wave_set_breaking = wave_set_breaking;
	interpolated_surface_vertical_velocity = (
		wave_vertical_velocity + wave_set_vertical_velocity
	);
	interpolated_surface_curvature = wave_curvature + wave_set_curvature;
	float horizontal_jacobian_determinant = (
		(1.0 + wave_horizontal_derivative_x.x)
		* (1.0 + wave_horizontal_derivative_z.y)
		- wave_horizontal_derivative_z.x
			* wave_horizontal_derivative_x.y
	);
	interpolated_surface_compression = clamp(
		1.0 - horizontal_jacobian_determinant,
		0.0,
		1.0
	);
	float total_positive_height = (
		wave_positive_height_sum + wave_set_positive_height_sum
	);
	float strongest_positive_height = max(
		wave_strongest_positive_height,
		wave_set_strongest_positive_height
	);
	interpolated_constructive_interference = smoothstep(
		0.06,
		0.38,
		max(total_positive_height - strongest_positive_height, 0.0)
	);
	interpolated_ocean_ring_id = COLOR.r;
}


float surface_hash_12(vec2 value) {
	vec3 p = fract(vec3(value.xyx) * 0.1031);
	p += dot(p, p.yzx + 33.33);
	return fract((p.x + p.y) * p.z);
}


vec2 surface_hash_22(vec2 value) {
	float first = surface_hash_12(value);
	float second = surface_hash_12(value + vec2(19.19, 73.73));
	return vec2(first, second);
}


mat2 surface_rotation(float angle) {
	float sine_value = sin(angle);
	float cosine_value = cos(angle);
	return mat2(
		vec2(cosine_value, sine_value),
		vec2(-sine_value, cosine_value)
	);
}


vec3 decode_surface_normal(vec3 packed_normal) {
	return normalize(packed_normal * 2.0 - 1.0);
}


vec3 sample_surface_normal_cell(
	sampler2D normal_texture,
	vec2 world_xz,
	float world_size,
	vec2 flow_offset,
	vec2 cell,
	float seed
) {
	vec2 random_value = surface_hash_22(cell + vec2(seed, seed * 0.371));
	float angle = (
		random_value.x * 2.0 - 1.0
	) * 3.14159265 * surface_stochastic_rotation;
	mat2 texture_rotation = surface_rotation(angle);
	vec2 base_uv = world_xz / max(world_size, 0.001);
	vec2 texture_uv = (
		texture_rotation * base_uv
		+ random_value * 37.17
		+ flow_offset
	);
	vec2 texture_gradient_x = texture_rotation * dFdx(base_uv);
	vec2 texture_gradient_y = texture_rotation * dFdy(base_uv);
	vec3 sampled_normal = decode_surface_normal(
		textureGrad(
			normal_texture,
			texture_uv,
			texture_gradient_x,
			texture_gradient_y
		).rgb
	);
	// Rotating the UV basis also rotates the encoded tangent slope. Bring it
	// back to the world XZ basis before neighbouring cells are blended.
	sampled_normal.xy = surface_rotation(-angle) * sampled_normal.xy;
	return normalize(sampled_normal);
}


vec3 sample_surface_normal_stochastic(
	sampler2D normal_texture,
	vec2 world_xz,
	float world_size,
	vec2 flow_offset,
	float seed
) {
	vec2 cell_position = world_xz / max(surface_stochastic_cell_size, 0.001);
	vec2 base_cell = floor(cell_position);
	vec2 fraction = fract(cell_position);
	vec2 blend = fraction * fraction * (3.0 - 2.0 * fraction);

	vec3 normal_00 = sample_surface_normal_cell(
		normal_texture,
		world_xz,
		world_size,
		flow_offset,
		base_cell,
		seed
	);
	vec3 normal_10 = sample_surface_normal_cell(
		normal_texture,
		world_xz,
		world_size,
		flow_offset,
		base_cell + vec2(1.0, 0.0),
		seed
	);
	vec3 normal_01 = sample_surface_normal_cell(
		normal_texture,
		world_xz,
		world_size,
		flow_offset,
		base_cell + vec2(0.0, 1.0),
		seed
	);
	vec3 normal_11 = sample_surface_normal_cell(
		normal_texture,
		world_xz,
		world_size,
		flow_offset,
		base_cell + vec2(1.0, 1.0),
		seed
	);

	vec3 lower = mix(normal_00, normal_10, blend.x);
	vec3 upper = mix(normal_01, normal_11, blend.x);
	return normalize(mix(lower, upper, blend.y));
}


vec3 sample_surface_normal_crossed(
	sampler2D normal_texture,
	vec2 world_xz,
	float world_size,
	vec2 flow_offset
) {
	vec2 base_uv = world_xz / max(world_size, 0.001);
	return decode_surface_normal(
		textureGrad(
			normal_texture,
			base_uv + flow_offset,
			dFdx(base_uv),
			dFdy(base_uv)
		).rgb
	);
}


vec2 sample_surface_domain_warp(vec2 logical_xz) {
	vec2 safe_direction = normalize(
		surface_warp_direction + vec2(0.000001, 0.0)
	);
	vec2 base_uv = (
		logical_xz / max(surface_warp_world_size, 0.001)
		+ safe_direction * simulation_time * surface_warp_speed
	);
	const mat2 SECOND_WARP_ROTATION = mat2(
		vec2(0.537300, 0.843391),
		vec2(-0.843391, 0.537300)
	);
	float first = texture(surface_warp_texture, base_uv).r;
	float second = texture(
		surface_warp_texture,
		SECOND_WARP_ROTATION * base_uv + vec2(0.371, 0.619)
	).r;
	return (vec2(first, second) * 2.0 - 1.0) * surface_warp_strength;
}


vec3 sample_organic_surface_normal(
	vec2 logical_xz,
	out float detail_amount
) {
	if (surface_detail_mode == 0 || surface_normal_strength <= 0.0001) {
		detail_amount = 0.0;
		return vec3(0.0, 0.0, 1.0);
	}

	vec2 warped_xz = logical_xz + sample_surface_domain_warp(logical_xz);
	vec2 direction_a = normalize(surface_flow_direction_a + vec2(0.000001, 0.0));
	vec2 direction_b = normalize(surface_flow_direction_b + vec2(0.000001, 0.0));
	vec2 flow_a = direction_a * simulation_time * surface_flow_speed_a;
	vec2 flow_b = direction_b * simulation_time * surface_flow_speed_b;

	vec3 normal_a;
	vec3 normal_b;
	if (surface_detail_mode == 2) {
		normal_a = sample_surface_normal_stochastic(
			surface_normal_texture_a,
			warped_xz,
			surface_normal_world_size_a,
			flow_a,
			17.0
		);
		normal_b = sample_surface_normal_stochastic(
			surface_normal_texture_b,
			warped_xz,
			surface_normal_world_size_b,
			flow_b,
			53.0
		);
	} else {
		normal_a = sample_surface_normal_crossed(
			surface_normal_texture_a,
			warped_xz,
			surface_normal_world_size_a,
			flow_a
		);
		normal_b = sample_surface_normal_crossed(
			surface_normal_texture_b,
			warped_xz,
			surface_normal_world_size_b,
			flow_b
		);
	}

	vec3 combined = normalize(vec3(
		normal_a.xy * 0.64 + normal_b.xy * 0.36,
		max(normal_a.z * 0.64 + normal_b.z * 0.36, 0.08)
	));
	detail_amount = clamp(length(combined.xy), 0.0, 1.0);
	return combined;
}


float linear_depth_from_buffer(
	vec2 screen_uv,
	float raw_depth,
	mat4 inverse_projection
) {
	vec4 view_position = inverse_projection * vec4(
		screen_uv * 2.0 - 1.0,
		raw_depth,
		1.0
	);
	return max(-view_position.z / view_position.w, 0.0);
}


void fragment() {
	vec3 world_fragment_position = vec3(
		interpolated_world_xz.x,
		base_height + interpolated_wave_height,
		interpolated_world_xz.y
	);
	float camera_distance = length(CAMERA_POSITION_WORLD - world_fragment_position);
	float valid_detail_fade_end = max(
		surface_detail_fade_end,
		surface_detail_fade_start + 0.001
	);
	float detail_distance_factor = 1.0 - smoothstep(
		surface_detail_fade_start,
		valid_detail_fade_end,
		camera_distance
	);
	float surface_detail_amount = 0.0;
	vec3 organic_normal = sample_organic_surface_normal(
		interpolated_world_xz + foam_logical_origin_xz,
		surface_detail_amount
	);
	vec2 organic_slope = organic_normal.xy / max(organic_normal.z, 0.08);
	vec3 organic_normal_offset_view = mat3(VIEW_MATRIX) * vec3(
		organic_slope.x,
		0.0,
		organic_slope.y
	);
	vec3 visual_normal = normalize(
		NORMAL
		+ organic_normal_offset_view
			* surface_normal_strength
			* detail_distance_factor
	);
	float slope_mix = clamp(interpolated_wave_slope * 0.8, 0.0, 1.0);
	float crest_height_factor = smoothstep(0.0, 1.25, interpolated_wave_height);
	float crest_slope_factor = smoothstep(0.06, 0.32, interpolated_wave_slope);
	float crest_metric = crest_height_factor * mix(0.72, 1.0, crest_slope_factor);
	vec2 logical_xz = interpolated_world_xz + foam_logical_origin_xz;
	vec2 foam_direction = normalize(foam_dominant_direction + vec2(0.000001, 0.0));
	vec2 uv_macro = logical_xz * foam_macro_noise_scale
		+ foam_direction * simulation_time * foam_noise_scroll_speed;
	const mat2 FOAM_ROTATION = mat2(
		vec2(0.819152, 0.573576),
		vec2(-0.573576, 0.819152)
	);
	vec2 uv_detail = FOAM_ROTATION * logical_xz * foam_detail_noise_scale
		- foam_direction * simulation_time * foam_noise_scroll_speed * 0.63;
	float noise_value = texture(foam_noise_texture, uv_macro).r * 0.65
		+ texture(foam_noise_texture, uv_detail).r * 0.35;
	float edge_width = max(fwidth(noise_value) * 1.5, 0.01);
	float breakup_mask = smoothstep(0.52 - edge_width, 0.52 + edge_width, noise_value);
	float total_crest_factor = smoothstep(0.20, 0.92, interpolated_wave_height);
	float total_slope_factor = smoothstep(0.08, 0.30, interpolated_wave_slope);
	float total_curvature_factor = smoothstep(
		0.004,
		0.035,
		interpolated_surface_curvature
	);
	float upward_motion_factor = smoothstep(
		0.02,
		0.58,
		max(interpolated_surface_vertical_velocity, 0.0)
	);
	float compression_factor = smoothstep(
		0.08,
		0.42,
		interpolated_surface_compression
	);
	float combined_crest_breaking = total_crest_factor
		* max(
			max(total_slope_factor, total_curvature_factor),
			compression_factor
		)
		* mix(0.70, 1.0, upward_motion_factor);
	float base_breaking = smoothstep(0.34, 0.72, combined_crest_breaking)
		* base_ocean_foam_amount * 0.55;
	float reinforced_breaking = smoothstep(0.22, 0.68, combined_crest_breaking)
		* smoothstep(0.10, 0.78, interpolated_constructive_interference)
		* wave_set_foam_amount;
	float packet_support = interpolated_wave_set_breaking
		* total_crest_factor * wave_set_foam_amount * 0.24;
	float foam_signal = base_breaking + reinforced_breaking + packet_support;
	float textured_foam_mask = clamp(
		foam_signal * mix(1.0, breakup_mask, foam_breakup_strength) * foam_amount,
		0.0,
		1.0
	);
	float foam_mask = foam_enabled ? textured_foam_mask : 0.0;
	float foam_factor = foam_mask;

	float scene_raw_depth = textureLod(depth_texture, SCREEN_UV, 0.0).r;
	float scene_linear_depth = linear_depth_from_buffer(
		SCREEN_UV,
		scene_raw_depth,
		INV_PROJECTION_MATRIX
	);
	float water_linear_depth = linear_depth_from_buffer(
		SCREEN_UV,
		FRAGCOORD.z,
		INV_PROJECTION_MATRIX
	);
	float water_thickness = clamp(
		scene_linear_depth - water_linear_depth,
		0.0,
		maximum_optical_depth
	);
	float absorption = 1.0 - exp(-water_thickness * absorption_density);
	float depth_factor = clamp(
		water_thickness / max(shallow_depth_range, 0.0001),
		0.0,
		1.0
	);
	float water_density = max(absorption, depth_factor * 0.5);
	float valid_seabed_fade_end = max(
		seabed_fade_end,
		seabed_fade_start + 0.001
	);
	float seabed_occlusion = smoothstep(
		seabed_fade_start,
		valid_seabed_fade_end,
		water_thickness
	);
	vec3 body_water_color = mix(
		shallow_water_color.rgb,
		deep_water_color.rgb,
		water_density
	);
	if (wave_height_color_enabled) {
		float height_color_position = clamp(
			0.5 + 0.5 * (
				interpolated_wave_height + wave_height_color_bias
			) / max(wave_height_color_range, 0.001),
			0.0,
			1.0
		);
		height_color_position = height_color_position
			* height_color_position
			* (3.0 - 2.0 * height_color_position);
		vec3 height_color = mix(
			wave_trough_color.rgb,
			wave_crest_color.rgb,
			height_color_position
		);
		float effective_height_color_strength = clamp(
			wave_height_color_strength
			+ interpolated_surface_compression
				* wave_compression_color_strength,
			0.0,
			1.0
		);
		body_water_color = mix(
			body_water_color,
			height_color,
			effective_height_color_strength
		);
	}

	vec3 view_direction = normalize(VIEW);
	float facing = clamp(dot(visual_normal, view_direction), 0.0, 1.0);
	float fresnel = pow(1.0 - facing, fresnel_power);
	float distance_opacity = smoothstep(
		opacity_distance_start,
		opacity_distance_end,
		camera_distance
	);
	float horizon_factor = max(
		distance_opacity,
		fresnel * fresnel_opacity_strength
	);
	float local_alpha = mix(near_water_alpha, deep_water_alpha, water_density);
	float final_alpha = clamp(
		mix(local_alpha, horizon_water_alpha, horizon_factor),
		0.55,
		1.0
	);
	final_alpha = mix(final_alpha, 1.0, seabed_occlusion);

	float refraction_depth_factor = clamp(
		water_thickness / max(refraction_depth_range, 0.0001),
		0.0,
		1.0
	);
	float refraction_visibility = refraction_depth_factor
		* (1.0 - distance_opacity * refraction_distance_fade)
		* (1.0 - fresnel * refraction_fresnel_fade)
		* (1.0 - foam_factor);
	vec2 refraction_offset = visual_normal.xy
		* refraction_strength
		* mix(1.0, surface_refraction_detail_strength, detail_distance_factor);
	vec2 refracted_uv_unclamped = SCREEN_UV
		+ refraction_offset * refraction_visibility;
	bool refracted_uv_in_bounds = all(greaterThanEqual(
		refracted_uv_unclamped,
		vec2(0.001)
	)) && all(lessThanEqual(refracted_uv_unclamped, vec2(0.999)));
	vec2 refracted_uv_candidate = clamp(
		refracted_uv_unclamped,
		vec2(0.001),
		vec2(0.999)
	);
	float refracted_raw_depth = textureLod(
		depth_texture,
		refracted_uv_candidate,
		0.0
	).r;
	float refracted_scene_depth = linear_depth_from_buffer(
		refracted_uv_candidate,
		refracted_raw_depth,
		INV_PROJECTION_MATRIX
	);
	bool refracted_geometry_is_behind_water = refracted_scene_depth
		> water_linear_depth + 0.02;
	bool refracted_depth_is_continuous = abs(
		refracted_scene_depth - scene_linear_depth
	) <= max(1.0, refraction_depth_range * 2.0);
	bool refraction_is_valid = refracted_uv_in_bounds
		&& refracted_geometry_is_behind_water
		&& refracted_depth_is_continuous;
	vec2 valid_refracted_uv = refraction_is_valid
		? refracted_uv_candidate
		: SCREEN_UV;
	vec3 refracted_scene_color = textureLod(
		screen_texture,
		valid_refracted_uv,
		0.0
	).rgb;
	vec3 transmitted_scene = refracted_scene_color * mix(
		vec3(1.0),
		shallow_water_color.rgb,
		absorption * 0.30
	);
	float reflection_factor = clamp(
		fresnel * reflection_strength + distance_opacity * 0.30,
		0.0,
		1.0
	);
	vec3 surface_water_color = mix(
		body_water_color,
		horizon_water_color.rgb,
		reflection_factor
	);
	surface_water_color = mix(
		surface_water_color,
		reflection_tint.rgb,
		reflection_factor * 0.20
	);
	float body_mix = clamp(
		max(water_density + horizon_factor * 0.75, seabed_occlusion),
		0.0,
		1.0
	);
	vec3 final_water_color = mix(
		transmitted_scene,
		surface_water_color,
		body_mix
	);
	float crest_scattering = pow(
		clamp(crest_metric, 0.0, 1.0),
		crest_scattering_power
	) * crest_scattering_strength * (1.0 - water_density);
	final_water_color += crest_scattering_color.rgb * crest_scattering;
	final_water_color = mix(final_water_color, foam_color.rgb, foam_mask);
	final_alpha = max(final_alpha, foam_factor * 0.98);

	NORMAL = visual_normal;
	ALBEDO = final_water_color;
	float legacy_water_roughness = clamp(
		mix(
			near_water_roughness,
			horizon_water_roughness,
			max(fresnel, distance_opacity)
		)
		+ slope_mix * 0.04
		+ surface_detail_amount
			* surface_roughness_variation
			* detail_distance_factor,
		0.0,
		1.0
	);
	ROUGHNESS = mix(legacy_water_roughness, foam_roughness, foam_mask);
	METALLIC = 0.0;
	SPECULAR = mix(water_specular, foam_specular, foam_mask);
	ALPHA = final_alpha;

	vec3 debug_output = vec3(-1.0);
	if (water_optics_debug_mode == 1) {
		debug_output = vec3(clamp(water_thickness / maximum_optical_depth, 0.0, 1.0));
	} else if (water_optics_debug_mode == 2) {
		debug_output = vec3(absorption);
	} else if (water_optics_debug_mode == 3) {
		debug_output = vec3(fresnel);
	} else if (water_optics_debug_mode == 4) {
		debug_output = vec3(distance_opacity);
	} else if (water_optics_debug_mode == 5) {
		debug_output = vec3(final_alpha);
	} else if (water_optics_debug_mode == 6) {
		float refraction_magnitude = length(
			valid_refracted_uv - SCREEN_UV
		) / max(refraction_strength, 0.0005);
		debug_output = vec3(clamp(refraction_magnitude, 0.0, 1.0));
	}
	if (water_optics_debug_mode > 0) {
		ALBEDO = vec3(0.0);
		EMISSION = debug_output;
		ROUGHNESS = 1.0;
		SPECULAR = 0.0;
		ALPHA = 1.0;
	}
	if (ocean_debug_show_rings) {
		vec3 ring_color = ocean_debug_ring_color(interpolated_ocean_ring_id);
		ALBEDO = ring_color;
		EMISSION = ring_color * 0.15;
		ROUGHNESS = 0.9;
		SPECULAR = 0.1;
		ALPHA = 1.0;
	}
}
