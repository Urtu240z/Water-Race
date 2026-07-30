// Texture-driven ocean surface.
// The macro displacement and CPU sampling model are adapted from the
// texture-driven approach in Taillight Games' MIT-licensed texture-driven water shader.
shader_type spatial;
render_mode blend_mix, world_vertex_coords, cull_disabled, depth_draw_always, diffuse_burley, specular_schlick_ggx, fog_disabled;

const int MAX_RIPPLES = 12;
const float TAU_VALUE = 6.28318530718;
const int CUSTOM_SSR_MAX_STEPS = 32;
const int CUSTOM_SSR_MAX_REFINEMENT_STEPS = 5;

uniform bool ocean_enabled = true;
uniform float water_level = 0.0;
uniform float simulation_time = 0.0;

group_uniforms MacroWaves;
uniform sampler2D wave_height_texture_a : repeat_enable, filter_linear;
uniform sampler2D wave_height_texture_b : repeat_enable, filter_linear;
uniform float wave_world_size_a : hint_range(8.0, 600.0, 0.5) = 180.0;
uniform float wave_world_size_b : hint_range(8.0, 600.0, 0.5) = 72.0;
uniform float wave_amplitude_a : hint_range(0.0, 4.0, 0.01) = 1.35;
uniform float wave_amplitude_b : hint_range(0.0, 4.0, 0.01) = 0.42;
uniform vec2 wave_direction_a = vec2(0.86, 0.51);
uniform vec2 wave_direction_b = vec2(-0.38, 0.92);
uniform float wave_travel_speed_a : hint_range(-20.0, 20.0, 0.05) = 4.6;
uniform float wave_travel_speed_b : hint_range(-20.0, 20.0, 0.05) = 2.3;
uniform float wave_mean_a : hint_range(0.0, 1.0, 0.001) = 0.50;
uniform float wave_mean_b : hint_range(0.0, 1.0, 0.001) = 0.47;
uniform float geometry_normal_step : hint_range(0.05, 2.0, 0.05) = 0.40;

group_uniforms Ripples;
uniform int ripple_active[12];
uniform vec2 ripple_positions[12];
uniform float ripple_start_times[12];
uniform float ripple_amplitudes[12];
uniform float ripple_speeds[12];
uniform float ripple_wavelengths[12];
uniform float ripple_decays[12];
uniform float ripple_lifetimes[12];

#include "res://shaders/includes/ocean_vehicle_interaction_uniforms.gdshaderinc"

group_uniforms SurfaceDetail;
uniform sampler2D surface_normal_texture_a : hint_normal, repeat_enable, filter_linear_mipmap_anisotropic;
uniform sampler2D surface_normal_texture_b : hint_normal, repeat_enable, filter_linear_mipmap_anisotropic;
uniform sampler2D surface_warp_texture : repeat_enable, filter_linear_mipmap;
uniform float surface_normal_world_size_a : hint_range(0.25, 100.0, 0.05) = 7.5;
uniform float surface_normal_world_size_b : hint_range(0.25, 100.0, 0.05) = 3.25;
uniform float surface_normal_strength : hint_range(0.0, 2.0, 0.01) = 0.62;
uniform vec2 surface_flow_direction_a = vec2(0.82, 0.57);
uniform vec2 surface_flow_direction_b = vec2(-0.46, 0.89);
uniform float surface_flow_speed_a : hint_range(-3.0, 3.0, 0.01) = 0.24;
uniform float surface_flow_speed_b : hint_range(-3.0, 3.0, 0.01) = -0.17;
uniform float surface_warp_world_size : hint_range(2.0, 300.0, 0.5) = 46.0;
uniform float surface_warp_strength : hint_range(0.0, 12.0, 0.05) = 2.4;
uniform float surface_detail_fade_start : hint_range(0.0, 1000.0, 1.0) = 130.0;
uniform float surface_detail_fade_end : hint_range(1.0, 2000.0, 1.0) = 520.0;

group_uniforms Optics;
uniform sampler2D screen_texture : hint_screen_texture, repeat_disable, filter_linear_mipmap;
uniform sampler2D depth_texture : hint_depth_texture, repeat_disable, filter_nearest;
uniform sampler2D normal_roughness_texture : hint_normal_roughness_texture, repeat_disable, filter_nearest;
uniform vec4 shallow_water_color : source_color = vec4(0.035, 0.43, 0.55, 1.0);
uniform vec4 deep_water_color : source_color = vec4(0.004, 0.055, 0.115, 1.0);
uniform vec4 horizon_water_color : source_color = vec4(0.025, 0.22, 0.34, 1.0);
uniform vec4 reflection_tint : source_color = vec4(0.36, 0.70, 0.86, 1.0);
uniform vec4 trough_tint : source_color = vec4(0.002, 0.025, 0.075, 1.0);
uniform vec4 crest_tint : source_color = vec4(0.11, 0.62, 0.68, 1.0);
uniform float absorption_density : hint_range(0.01, 2.0, 0.01) = 0.13;
uniform float maximum_optical_depth : hint_range(1.0, 100.0, 0.5) = 38.0;
uniform float shallow_depth_range : hint_range(0.1, 20.0, 0.1) = 5.5;
uniform float near_water_alpha : hint_range(0.5, 1.0, 0.01) = 0.77;
uniform float deep_water_alpha : hint_range(0.5, 1.0, 0.01) = 0.92;
uniform float horizon_water_alpha : hint_range(0.8, 1.0, 0.01) = 0.98;
uniform float opacity_distance_start : hint_range(0.0, 500.0, 1.0) = 80.0;
uniform float opacity_distance_end : hint_range(1.0, 1000.0, 1.0) = 220.0;
uniform float fresnel_power : hint_range(0.5, 12.0, 0.1) = 4.8;
uniform float reflection_strength : hint_range(0.0, 1.0, 0.01) = 0.82;
uniform float refraction_strength : hint_range(0.0, 0.05, 0.0005) = 0.009;
uniform float near_roughness : hint_range(0.0, 1.0, 0.01) = 0.055;
uniform float horizon_roughness : hint_range(0.0, 1.0, 0.01) = 0.23;
uniform float water_specular : hint_range(0.0, 1.0, 0.01) = 0.88;

group_uniforms UnderwaterView;
uniform vec4 underwater_surface_fog_color : source_color = vec4(0.10, 0.40, 0.50, 1.0);
uniform float underwater_surface_fog_density : hint_range(0.0, 0.1, 0.001) = 0.009;
uniform float underwater_surface_fog_start_distance : hint_range(0.0, 500.0, 0.5) = 5.0;
uniform float underwater_visibility_radius : hint_range(5.0, 300.0, 1.0) = 80.0;
uniform float underwater_visibility_blend : hint_range(1.0, 150.0, 1.0) = 20.0;
uniform float underwater_surface_alpha : hint_range(0.0, 1.0, 0.01) = 0.82;

group_uniforms Foam;
uniform bool foam_enabled = true;
uniform sampler2D foam_noise_texture : repeat_enable, filter_linear_mipmap;
uniform vec4 foam_color : source_color = vec4(0.82, 0.95, 1.0, 1.0);
uniform float shore_foam_width : hint_range(0.1, 8.0, 0.05) = 2.15;
uniform float shore_foam_strength : hint_range(0.0, 2.0, 0.01) = 1.05;
uniform float vehicle_material_tag_roughness : hint_range(0.0, 1.0, 0.001) = 0.019608;
uniform float vehicle_material_tag_tolerance : hint_range(0.001, 0.05, 0.001) = 0.006;
uniform float crest_foam_start : hint_range(0.0, 2.0, 0.01) = 0.46;
uniform float crest_foam_end : hint_range(0.0, 3.0, 0.01) = 0.94;
uniform float crest_foam_strength : hint_range(0.0, 2.0, 0.01) = 0.82;
uniform float ripple_foam_strength : hint_range(0.0, 2.0, 0.01) = 0.18;
uniform float foam_macro_scale : hint_range(0.001, 1.0, 0.001) = 0.055;
uniform float foam_detail_scale : hint_range(0.001, 2.0, 0.001) = 0.19;
uniform float foam_scroll_speed : hint_range(0.0, 2.0, 0.01) = 0.13;
uniform float foam_roughness : hint_range(0.0, 1.0, 0.01) = 0.88;

group_uniforms Clipmap;
uniform bool ocean_surface_enabled = false;
uniform vec2 ocean_snapped_origin_xz = vec2(0.0);
uniform vec2 ocean_logical_origin_offset_xz = vec2(0.0);
uniform vec2 ocean_detail_center_xz = vec2(0.0);
uniform float ocean_detailed_wave_fade_start = 170.0;
uniform float ocean_detailed_wave_fade_end = 280.0;
uniform float ocean_medium_wave_fade_end = 680.0;
uniform float ocean_middle_wave_amplitude_ratio = 0.55;
uniform float ocean_far_wave_amplitude_ratio = 0.08;
uniform bool ocean_debug_show_rings = false;

group_uniforms CustomSSR;
uniform bool custom_ssr_enabled = true;
uniform int custom_ssr_steps : hint_range(4, 32, 1) = 24;
uniform int custom_ssr_refinement_steps : hint_range(0, 5, 1) = 2;
uniform float custom_ssr_strength : hint_range(0.0, 1.5, 0.01) = 0.85;
uniform float custom_ssr_max_distance : hint_range(10.0, 500.0, 1.0) = 280.0;
uniform float custom_ssr_start_bias : hint_range(0.01, 3.0, 0.01) = 0.20;
uniform float custom_ssr_base_step : hint_range(0.02, 5.0, 0.01) = 0.35;
uniform float custom_ssr_step_growth : hint_range(1.0, 1.5, 0.01) = 1.10;
uniform float custom_ssr_thickness : hint_range(0.01, 5.0, 0.01) = 1.10;
uniform float custom_ssr_min_fresnel : hint_range(0.0, 1.0, 0.01) = 0.0;
uniform float custom_ssr_edge_fade : hint_range(0.001, 0.25, 0.001) = 0.04;
uniform float custom_ssr_distance_fade_start : hint_range(0.0, 500.0, 1.0) = 190.0;
uniform float custom_ssr_distance_fade_end : hint_range(1.0, 600.0, 1.0) = 300.0;
uniform float custom_ssr_blur_lod : hint_range(0.0, 5.0, 0.05) = 0.15;
uniform float custom_ssr_upward_rejection : hint_range(-1.0, 1.0, 0.01) = -0.50;
uniform float custom_ssr_trace_normal_flatten : hint_range(0.0, 1.0, 0.01) = 0.72;
uniform float custom_ssr_hit_distortion : hint_range(0.0, 0.03, 0.0001) = 0.0035;
uniform float custom_ssr_minimum_hit_visibility : hint_range(0.0, 1.0, 0.01) = 0.55;
uniform float custom_ssr_hit_contrast : hint_range(0.5, 2.0, 0.01) = 1.10;
uniform float custom_ssr_hit_brightness : hint_range(0.25, 2.0, 0.01) = 1.05;
uniform int custom_ssr_debug_mode : hint_range(0, 9, 1) = 0;
group_uniforms;

group_uniforms MirroredReflection;
uniform bool mirrored_reflection_enabled = true;
uniform float mirrored_reflection_strength : hint_range(0.0, 1.5, 0.01) = 0.82;
uniform float mirrored_reflection_vertical_scale : hint_range(0.5, 2.0, 0.01) = 1.0;
uniform float mirrored_reflection_geometry_strength : hint_range(0.0, 1.5, 0.01) = 1.0;
uniform float mirrored_reflection_sky_strength : hint_range(0.0, 1.0, 0.01) = 0.15;
uniform float mirrored_reflection_reference_distance : hint_range(20.0, 1000.0, 1.0) = 220.0;
uniform float mirrored_reflection_macro_distortion : hint_range(0.0, 0.05, 0.0001) = 0.008;
uniform float mirrored_reflection_detail_distortion : hint_range(0.0, 0.02, 0.0001) = 0.002;
uniform float mirrored_reflection_blur_lod : hint_range(0.0, 5.0, 0.05) = 0.20;
uniform float mirrored_reflection_edge_fade : hint_range(0.001, 0.25, 0.001) = 0.04;
uniform float mirrored_reflection_near_fade : hint_range(0.0, 1.0, 0.01) = 0.05;
uniform float mirrored_reflection_far_fade_start : hint_range(0.0, 1000.0, 1.0) = 250.0;
uniform float mirrored_reflection_far_fade_end : hint_range(1.0, 1500.0, 1.0) = 600.0;
uniform vec3 mirrored_reflection_tint : source_color = vec3(0.78, 0.90, 0.96);
uniform float mirrored_reflection_saturation : hint_range(0.0, 2.0, 0.01) = 0.82;
uniform float mirrored_reflection_contrast : hint_range(0.5, 2.0, 0.01) = 1.08;
uniform float mirrored_reflection_brightness : hint_range(0.25, 2.0, 0.01) = 0.92;
group_uniforms;

group_uniforms ReflectionWaveDistortion;
uniform bool reflection_wave_distortion_enabled = true;
uniform float reflection_macro_distortion_x : hint_range(0.0, 0.15, 0.0005) = 0.028;
uniform float reflection_macro_distortion_y : hint_range(0.0, 0.15, 0.0005) = 0.060;
uniform float reflection_macro_slope_influence : hint_range(0.0, 4.0, 0.01) = 1.65;
uniform float reflection_macro_height_influence : hint_range(0.0, 4.0, 0.01) = 0.80;
uniform float reflection_micro_distortion : hint_range(0.0, 0.03, 0.0001) = 0.0035;
uniform float reflection_micro_breakup : hint_range(0.0, 2.0, 0.01) = 0.70;
uniform float reflection_vertical_stretch : hint_range(0.5, 2.0, 0.01) = 1.06;
uniform float reflection_horizontal_shear : hint_range(0.0, 1.0, 0.01) = 0.22;
uniform float reflection_wave_phase_influence : hint_range(0.0, 2.0, 0.01) = 0.75;
uniform float reflection_coast_breakup_strength : hint_range(0.0, 1.0, 0.01) = 0.20;
uniform float reflection_coast_breakup_distance : hint_range(0.0, 50.0, 0.1) = 10.0;
group_uniforms;

group_uniforms HybridReflection;
uniform float custom_reflection_minimum_surface_weight : hint_range(0.0, 1.0, 0.01) = 0.34;
uniform float custom_reflection_maximum_surface_weight : hint_range(0.0, 1.0, 0.01) = 0.88;
uniform float custom_reflection_emission_strength : hint_range(0.0, 2.0, 0.01) = 1.0;
group_uniforms;

varying float interpolated_wave_height;
varying float interpolated_wave_slope;
varying float interpolated_ripple_energy;
varying vec2 interpolated_world_xz;
varying float interpolated_ocean_ring_id;


vec2 safe_direction(vec2 direction, vec2 fallback) {
	float magnitude = length(direction);
	return magnitude > 0.00001 ? direction / magnitude : fallback;
}


float sample_macro_height(vec2 logical_xz) {
	float safe_size_a = max(wave_world_size_a, 0.001);
	float safe_size_b = max(wave_world_size_b, 0.001);
	vec2 uv_a = logical_xz / safe_size_a
		+ safe_direction(wave_direction_a, vec2(1.0, 0.0))
			* simulation_time * wave_travel_speed_a / safe_size_a;
	vec2 uv_b = logical_xz / safe_size_b
		+ safe_direction(wave_direction_b, vec2(0.0, -1.0))
			* simulation_time * wave_travel_speed_b / safe_size_b
		+ vec2(0.307, 0.476);
	float height_a = (
		textureLod(wave_height_texture_a, uv_a, 0.0).r - wave_mean_a
	) * wave_amplitude_a;
	float height_b = (
		textureLod(wave_height_texture_b, uv_b, 0.0).r - wave_mean_b
	) * wave_amplitude_b;
	return height_a + height_b;
}


// x: height, yz: spatial derivatives, w: envelope energy.
vec4 sample_ripple_state(vec2 logical_xz) {
	float height = 0.0;
	vec2 derivatives = vec2(0.0);
	float energy = 0.0;
	for (int index = 0; index < MAX_RIPPLES; index++) {
		if (ripple_active[index] == 0) {
			continue;
		}
		float age = simulation_time - ripple_start_times[index];
		if (age < 0.0 || age > ripple_lifetimes[index]) {
			continue;
		}
		vec2 center_delta = logical_xz - ripple_positions[index];
		float center_distance = length(center_delta);
		float radius = age * ripple_speeds[index];
		float wavelength = max(ripple_wavelengths[index], 0.05);
		float shell_width = max(wavelength * 1.35, 0.1);
		float shell_offset = center_distance - radius;
		float normalized_shell = shell_offset / shell_width;
		float envelope = exp(-normalized_shell * normalized_shell)
			* exp(-age * ripple_decays[index])
			* smoothstep(0.0, 0.18, age);
		float wave_number = TAU_VALUE / wavelength;
		float sine_phase = sin(shell_offset * wave_number);
		float cosine_phase = cos(shell_offset * wave_number);
		float amplitude = ripple_amplitudes[index];
		height += sine_phase * amplitude * envelope;
		float derivative_distance = amplitude * envelope * (
			wave_number * cosine_phase
			- 2.0 * shell_offset / (shell_width * shell_width) * sine_phase
		);
		if (center_distance > 0.0001) {
			derivatives += center_delta / center_distance * derivative_distance;
		}
		energy = max(energy, envelope * min(abs(amplitude) * 8.0, 1.0));
	}
	return vec4(height, derivatives, energy);
}

#include "res://shaders/includes/ocean_vehicle_interaction_functions.gdshaderinc"


float clipmap_wave_scale(vec2 world_xz) {
	if (!ocean_surface_enabled) {
		return 1.0;
	}
	float detail_distance = length(world_xz - ocean_detail_center_xz);
	float detailed_factor = 1.0 - smoothstep(
		ocean_detailed_wave_fade_start,
		max(ocean_detailed_wave_fade_end, ocean_detailed_wave_fade_start + 0.001),
		detail_distance
	);
	float medium_factor = 1.0 - smoothstep(
		ocean_detailed_wave_fade_end,
		max(ocean_medium_wave_fade_end, ocean_detailed_wave_fade_end + 0.001),
		detail_distance
	);
	float distant_scale = mix(
		ocean_far_wave_amplitude_ratio,
		ocean_middle_wave_amplitude_ratio,
		medium_factor
	);
	return mix(distant_scale, 1.0, detailed_factor);
}


vec4 sample_wave_state(vec2 world_xz) {
	vec2 logical_xz = world_xz + ocean_logical_origin_offset_xz;
	float step_size = max(geometry_normal_step, 0.05);
	float macro_height = sample_macro_height(logical_xz);
	vec2 macro_derivatives = vec2(
		(
			sample_macro_height(logical_xz + vec2(step_size, 0.0))
			- sample_macro_height(logical_xz - vec2(step_size, 0.0))
		) / (2.0 * step_size),
		(
			sample_macro_height(logical_xz + vec2(0.0, step_size))
			- sample_macro_height(logical_xz - vec2(0.0, step_size))
		) / (2.0 * step_size)
	);
	vec4 ripple = sample_ripple_state(logical_xz);
	float macro_scale = vehicle_interaction_exaggerated_debug
		? 0.0
		: clipmap_wave_scale(world_xz);
	float ripple_distance = length(world_xz - ocean_detail_center_xz);
	float ripple_scale = 1.0 - smoothstep(70.0, 130.0, ripple_distance);
	float interaction_scale = 1.0 - smoothstep(
		vehicle_interaction_clipmap_distance * 0.82,
		vehicle_interaction_clipmap_distance,
		ripple_distance
	);
	vec4 interaction = interaction_scale > 0.0001
		? sample_vehicle_interaction_state(logical_xz)
		: vec4(0.0);
	float ripple_weight = interaction_ripple_weight();
	return vec4(
		macro_height * macro_scale
			+ ripple.x * ripple_scale * ripple_weight
			+ interaction.x * interaction_scale,
		macro_derivatives * macro_scale
			+ ripple.yz * ripple_scale * ripple_weight
			+ interaction.yz * interaction_scale,
		max(
			ripple.w * ripple_scale * ripple_weight,
			interaction.w * interaction_scale
		)
	);
}


void vertex() {
	vec2 world_xz = VERTEX.xz;
	vec4 wave_state = sample_wave_state(world_xz);
	VERTEX.y = water_level + wave_state.x;
	NORMAL = normalize(vec3(-wave_state.y, 1.0, -wave_state.z));
	interpolated_wave_height = wave_state.x;
	interpolated_wave_slope = length(wave_state.yz);
	interpolated_ripple_energy = wave_state.w;
	interpolated_world_xz = world_xz;
	interpolated_ocean_ring_id = COLOR.r;
}


vec3 sample_surface_detail(vec2 logical_xz, float camera_distance) {
	vec2 warp_uv = logical_xz / max(surface_warp_world_size, 0.001)
		+ vec2(0.31, -0.95) * simulation_time * 0.035;
	vec2 warp = (
		texture(surface_warp_texture, warp_uv).rg * 2.0 - 1.0
	) * surface_warp_strength;
	vec2 uv_a = (logical_xz + warp) / max(surface_normal_world_size_a, 0.001)
		+ safe_direction(surface_flow_direction_a, vec2(1.0, 0.0))
			* simulation_time * surface_flow_speed_a
			/ max(surface_normal_world_size_a, 0.001);
	vec2 uv_b = (logical_xz - warp * 0.57) / max(surface_normal_world_size_b, 0.001)
		+ safe_direction(surface_flow_direction_b, vec2(0.0, 1.0))
			* simulation_time * surface_flow_speed_b
			/ max(surface_normal_world_size_b, 0.001);
	vec3 normal_a = texture(surface_normal_texture_a, uv_a).xyz * 2.0 - 1.0;
	vec3 normal_b = texture(surface_normal_texture_b, uv_b).xyz * 2.0 - 1.0;
	vec3 combined = normalize(vec3(
		normal_a.xy * 0.58 + normal_b.xy * 0.42,
		max(normal_a.z * 0.58 + normal_b.z * 0.42, 0.08)
	));
	float detail_fade = 1.0 - smoothstep(
		surface_detail_fade_start,
		max(surface_detail_fade_end, surface_detail_fade_start + 0.001),
		camera_distance
	);
	return vec3(combined.xy * detail_fade, combined.z);
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


vec3 reconstruct_view_position(
	vec2 screen_uv,
	float raw_depth,
	mat4 inverse_projection
) {
	if (raw_depth <= 0.000001) {
		return vec3(0.0);
	}
	vec4 homogeneous_position = inverse_projection * vec4(
		screen_uv * 2.0 - 1.0,
		raw_depth,
		1.0
	);
	if (abs(homogeneous_position.w) <= 0.000001) {
		return vec3(0.0);
	}
	return homogeneous_position.xyz / homogeneous_position.w;
}


vec2 project_view_position_to_uv(
	vec3 view_position,
	mat4 projection
) {
	vec4 clip_position = projection * vec4(view_position, 1.0);
	if (clip_position.w <= 0.000001) {
		return vec2(-1.0);
	}
	return clip_position.xy / clip_position.w * 0.5 + 0.5;
}


float calculate_screen_edge_fade(vec2 screen_uv, float fade_width) {
	vec2 edge_distance = min(screen_uv, vec2(1.0) - screen_uv);
	float nearest_edge = min(edge_distance.x, edge_distance.y);
	return smoothstep(0.0, max(fade_width, 0.000001), nearest_edge);
}


bool is_valid_screen_uv(vec2 screen_uv) {
	return (
		screen_uv.x > 0.0
		&& screen_uv.y > 0.0
		&& screen_uv.x < 1.0
		&& screen_uv.y < 1.0
	);
}


bool is_valid_view_position(vec3 view_position) {
	return (
		view_position.z < -0.000001
		&& all(lessThan(abs(view_position), vec3(1000000.0)))
	);
}


float calculate_projected_waterline_uv_y(
	vec3 camera_position_world,
	mat4 inverse_view,
	mat4 view,
	mat4 projection
) {
	vec3 camera_forward_world = -normalize(inverse_view[2].xyz);
	vec2 horizontal_forward = camera_forward_world.xz;
	float horizontal_length = length(horizontal_forward);
	if (horizontal_length <= 0.00001) {
		horizontal_forward = vec2(0.0, -1.0);
	} else {
		horizontal_forward /= horizontal_length;
	}
	vec3 reference_position_world = vec3(
		camera_position_world.x
			+ horizontal_forward.x
				* mirrored_reflection_reference_distance,
		water_level,
		camera_position_world.z
			+ horizontal_forward.y
				* mirrored_reflection_reference_distance
	);
	vec4 reference_position_view = view * vec4(
		reference_position_world,
		1.0
	);
	vec4 reference_position_clip = projection * reference_position_view;
	if (reference_position_clip.w <= 0.000001) {
		return -1.0;
	}
	return (
		reference_position_clip.y
			/ reference_position_clip.w
			* 0.5
			+ 0.5
	);
}


vec3 grade_reflection_color(
	vec3 input_color,
	vec3 tint,
	float saturation,
	float contrast_value,
	float brightness
) {
	float luminance = dot(
		input_color,
		vec3(0.2126, 0.7152, 0.0722)
	);
	vec3 saturated = mix(
		vec3(luminance),
		input_color,
		saturation
	);
	vec3 contrasted = (
		(saturated - vec3(0.5)) * contrast_value
		+ vec3(0.5)
	);
	return max(
		contrasted * tint * brightness,
		vec3(0.0)
	);
}


bool custom_ssr_trace(
	vec3 origin_view,
	vec3 direction_view,
	mat4 projection,
	mat4 inverse_projection,
	out vec2 hit_uv,
	out float hit_distance,
	out float hit_confidence
) {
	hit_uv = vec2(0.0);
	hit_distance = 0.0;
	hit_confidence = 0.0;

	float traveled_distance = max(custom_ssr_start_bias, 0.01);
	float step_length = max(custom_ssr_base_step, 0.02);
	float previous_distance = 0.0;
	float previous_depth_delta = 0.0;
	bool has_previous_sample = false;

	for (
		int step_index = 0;
		step_index < CUSTOM_SSR_MAX_STEPS;
		step_index++
	) {
		if (step_index >= custom_ssr_steps) {
			break;
		}
		if (traveled_distance > custom_ssr_max_distance) {
			break;
		}

		vec3 ray_position = origin_view
			+ direction_view * traveled_distance;
		if (!is_valid_view_position(ray_position)) {
			break;
		}
		vec2 ray_uv = project_view_position_to_uv(
			ray_position,
			projection
		);
		if (!is_valid_screen_uv(ray_uv)) {
			break;
		}

		float raw_depth = textureLod(depth_texture, ray_uv, 0.0).r;
		if (raw_depth <= 0.000001) {
			has_previous_sample = false;
			traveled_distance += step_length;
			step_length = (
				step_length * max(custom_ssr_step_growth, 1.0)
				+ custom_ssr_base_step
			);
			continue;
		}

		vec3 scene_position = reconstruct_view_position(
			ray_uv,
			raw_depth,
			inverse_projection
		);
		if (!is_valid_view_position(scene_position)) {
			has_previous_sample = false;
			traveled_distance += step_length;
			step_length = (
				step_length * max(custom_ssr_step_growth, 1.0)
				+ custom_ssr_base_step
			);
			continue;
		}

		float ray_depth = -ray_position.z;
		float scene_depth = -scene_position.z;
		float depth_delta = ray_depth - scene_depth;
		if (
			has_previous_sample
			&& previous_depth_delta < 0.0
			&& depth_delta >= 0.0
		) {
			float lower_distance = previous_distance;
			float upper_distance = traveled_distance;
			float best_distance = traveled_distance;
			float best_depth_delta = depth_delta;
			vec2 best_uv = ray_uv;

			for (
				int refinement_index = 0;
				refinement_index < CUSTOM_SSR_MAX_REFINEMENT_STEPS;
				refinement_index++
			) {
				if (
					refinement_index
					>= custom_ssr_refinement_steps
				) {
					break;
				}
				float midpoint_distance = (
					lower_distance + upper_distance
				) * 0.5;
				vec3 midpoint_position = origin_view
					+ direction_view * midpoint_distance;
				vec2 midpoint_uv = project_view_position_to_uv(
					midpoint_position,
					projection
				);
				if (!is_valid_screen_uv(midpoint_uv)) {
					break;
				}
				float midpoint_raw_depth = textureLod(
					depth_texture,
					midpoint_uv,
					0.0
				).r;
				if (midpoint_raw_depth <= 0.000001) {
					break;
				}
				vec3 midpoint_scene_position = reconstruct_view_position(
					midpoint_uv,
					midpoint_raw_depth,
					inverse_projection
				);
				if (!is_valid_view_position(midpoint_scene_position)) {
					break;
				}
				float midpoint_depth_delta = (
					-midpoint_position.z
					+ midpoint_scene_position.z
				);
				if (
					abs(midpoint_depth_delta)
					< abs(best_depth_delta)
				) {
					best_distance = midpoint_distance;
					best_depth_delta = midpoint_depth_delta;
					best_uv = midpoint_uv;
				}
				if (midpoint_depth_delta >= 0.0) {
					upper_distance = midpoint_distance;
				} else {
					lower_distance = midpoint_distance;
				}
			}

			float safe_thickness = max(custom_ssr_thickness, 0.000001);
			if (abs(best_depth_delta) <= safe_thickness) {
				float edge_fade = calculate_screen_edge_fade(
					best_uv,
					custom_ssr_edge_fade
				);
				float distance_fade = 1.0 - smoothstep(
					custom_ssr_distance_fade_start,
					max(
						custom_ssr_distance_fade_end,
						custom_ssr_distance_fade_start + 0.001
					),
					best_distance
				);
				float thickness_confidence = 1.0 - smoothstep(
					0.0,
					safe_thickness,
					abs(best_depth_delta)
				);
				hit_uv = best_uv;
				hit_distance = best_distance;
				hit_confidence = clamp(
					edge_fade
						* distance_fade
						* thickness_confidence,
					0.0,
					1.0
				);
				return hit_confidence > 0.0;
			}
		}

		has_previous_sample = true;
		previous_distance = traveled_distance;
		previous_depth_delta = depth_delta;
		traveled_distance += step_length;
		step_length = (
			step_length * max(custom_ssr_step_growth, 1.0)
			+ custom_ssr_base_step
		);
	}
	return false;
}


vec3 debug_ring_color(float ring_id) {
	if (ring_id < 0.25) {
		return vec3(0.08, 0.78, 1.0);
	}
	if (ring_id < 0.75) {
		return vec3(1.0, 0.62, 0.08);
	}
	return vec3(0.84, 0.18, 0.92);
}


void fragment() {
	vec3 world_fragment_position = vec3(
		interpolated_world_xz.x,
		water_level + interpolated_wave_height,
		interpolated_world_xz.y
	);
	float camera_distance = length(CAMERA_POSITION_WORLD - world_fragment_position);
	float camera_underwater_factor = 1.0 - smoothstep(
		-0.05,
		0.05,
		CAMERA_POSITION_WORLD.y - water_level
	);
	float underwater_surface_fog_distance = max(
		camera_distance - underwater_surface_fog_start_distance,
		0.0
	);
	float underwater_surface_fog_amount = camera_underwater_factor * (
		1.0 - exp(
			-underwater_surface_fog_density
				* underwater_surface_fog_distance
		)
	);
	float safe_underwater_visibility_radius = max(
		underwater_visibility_radius,
		0.001
	);
	float safe_underwater_visibility_blend = clamp(
		underwater_visibility_blend,
		0.001,
		safe_underwater_visibility_radius
	);
	float underwater_radius_extinction = camera_underwater_factor * smoothstep(
		safe_underwater_visibility_radius - safe_underwater_visibility_blend,
		safe_underwater_visibility_radius,
		camera_distance
	);
	underwater_surface_fog_amount = max(
		underwater_surface_fog_amount,
		underwater_radius_extinction
	);
	vec2 logical_xz = interpolated_world_xz + ocean_logical_origin_offset_xz;
	vec3 detail_normal = sample_surface_detail(logical_xz, camera_distance);
	vec2 detail_slope = detail_normal.xy / max(detail_normal.z, 0.08);
	vec3 detail_offset_view = mat3(VIEW_MATRIX) * vec3(
		detail_slope.x,
		0.0,
		detail_slope.y
	);
	vec3 geometric_normal = normalize(NORMAL);
	vec3 world_up_view = normalize(
		mat3(VIEW_MATRIX) * vec3(0.0, 1.0, 0.0)
	);
	vec3 visual_normal = normalize(
		geometric_normal
			+ detail_offset_view * surface_normal_strength
	);
	vec3 ssr_trace_normal = normalize(
		mix(
			geometric_normal,
			world_up_view,
			custom_ssr_trace_normal_flatten
		)
	);

	float scene_raw_depth = textureLod(depth_texture, SCREEN_UV, 0.0).r;
	bool scene_is_sky = scene_raw_depth <= 0.000001;
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
	float water_thickness = scene_is_sky
		? maximum_optical_depth
		: clamp(
			scene_linear_depth - water_linear_depth,
			0.0,
			maximum_optical_depth
		);
	float absorption = 1.0 - exp(-water_thickness * absorption_density);
	float depth_factor = clamp(
		water_thickness / max(shallow_depth_range, 0.001),
		0.0,
		1.0
	);
	float water_density = max(absorption, depth_factor * 0.48);

	float height_position = clamp(
		0.5 + interpolated_wave_height / max(
			2.0 * (wave_amplitude_a + wave_amplitude_b),
			0.001
		),
		0.0,
		1.0
	);
	height_position = height_position * height_position * (3.0 - 2.0 * height_position);
	vec3 body_color = mix(shallow_water_color.rgb, deep_water_color.rgb, water_density);
	body_color = mix(
		body_color,
		mix(trough_tint.rgb, crest_tint.rgb, height_position),
		0.24
	);

	vec3 view_direction = normalize(VIEW);
	float facing = clamp(dot(visual_normal, view_direction), 0.0, 1.0);
	float fresnel = pow(1.0 - facing, fresnel_power);
	float distance_opacity = smoothstep(
		opacity_distance_start,
		max(opacity_distance_end, opacity_distance_start + 0.001),
		camera_distance
	);
	float reflection_factor = clamp(
		fresnel * reflection_strength + distance_opacity * 0.30,
		0.0,
		1.0
	);
	vec3 surface_color = mix(body_color, horizon_water_color.rgb, reflection_factor);
	surface_color = mix(
		surface_color,
		reflection_tint.rgb,
		reflection_factor * 0.19
	);

	vec2 refraction_offset = visual_normal.xy
		* refraction_strength
		* (1.0 - fresnel)
		* (1.0 - distance_opacity);
	vec2 refracted_uv = clamp(
		SCREEN_UV + refraction_offset,
		vec2(0.001),
		vec2(0.999)
	);
	vec3 refracted_scene = textureLod(screen_texture, refracted_uv, 0.0).rgb;
	vec3 transmitted_scene = refracted_scene * mix(
		vec3(1.0),
		shallow_water_color.rgb,
		absorption * 0.30
	);
	float body_mix = clamp(
		water_density + max(fresnel, distance_opacity) * 0.72,
		0.0,
		1.0
	);
	vec3 final_color = mix(transmitted_scene, surface_color, body_mix);

	vec2 foam_direction = safe_direction(wave_direction_a, vec2(1.0, 0.0));
	vec2 foam_uv_a = logical_xz * foam_macro_scale
		+ foam_direction * simulation_time * foam_scroll_speed;
	const mat2 FOAM_ROTATION = mat2(
		vec2(0.819152, 0.573576),
		vec2(-0.573576, 0.819152)
	);
	vec2 foam_uv_b = FOAM_ROTATION * logical_xz * foam_detail_scale
		- foam_direction * simulation_time * foam_scroll_speed * 0.61;
	float foam_noise = texture(foam_noise_texture, foam_uv_a).r * 0.64
		+ texture(foam_noise_texture, foam_uv_b).r * 0.36;
	float noise_width = max(fwidth(foam_noise) * 1.5, 0.015);
	float foam_breakup = smoothstep(
		0.46 - noise_width,
		0.55 + noise_width,
		foam_noise
	);
	float vehicle_material_mask = 0.0;
	if (
		!scene_is_sky
		&& water_thickness < shore_foam_width
	) {
		float scene_roughness = texture(
			normal_roughness_texture,
			SCREEN_UV
		).a;
		float tag_distance = abs(
			scene_roughness - vehicle_material_tag_roughness
		);
		vehicle_material_mask = 1.0 - smoothstep(
			vehicle_material_tag_tolerance * 0.45,
			vehicle_material_tag_tolerance,
			tag_distance
		);
	}
	float shoreline = scene_is_sky
		? 0.0
		: (1.0 - smoothstep(0.06, shore_foam_width, water_thickness))
			* shore_foam_strength
			* (1.0 - vehicle_material_mask);
	float crest_height = smoothstep(
		crest_foam_start,
		max(crest_foam_end, crest_foam_start + 0.001),
		interpolated_wave_height
	);
	float crest_slope = smoothstep(0.06, 0.32, interpolated_wave_slope);
	float crest_foam = crest_height
		* mix(0.54, 1.0, crest_slope)
		* crest_foam_strength;
	float ripple_foam = interpolated_ripple_energy * ripple_foam_strength;
	float foam_mask = foam_enabled
		? clamp(
			(shoreline + crest_foam + ripple_foam)
				* mix(0.42, 1.0, foam_breakup),
			0.0,
			1.0
		)
		: 0.0;

	float reflection_waterline_uv_y = calculate_projected_waterline_uv_y(
		CAMERA_POSITION_WORLD,
		INV_VIEW_MATRIX,
		VIEW_MATRIX,
		PROJECTION_MATRIX
	);
	float distance_below_waterline = (
		SCREEN_UV.y - reflection_waterline_uv_y
	);
	float mirrored_vertical_distance = max(
		distance_below_waterline,
		0.0
	);
	float normalized_wave_height = clamp(
		interpolated_wave_height / max(
			abs(wave_amplitude_a) + abs(wave_amplitude_b),
			0.001
		),
		-1.0,
		1.0
	);
	float macro_wave_signal = (
		normalized_wave_height * reflection_macro_height_influence
			+ normalized_wave_height
				* reflection_wave_phase_influence
				* 0.24
	);
	float shallow_reflection_breakup = scene_is_sky
		? 0.0
		: 1.0 - smoothstep(
			0.0,
			max(reflection_coast_breakup_distance, 0.001),
			water_thickness
		);
	float coast_breakup_signal = max(
		shallow_reflection_breakup,
		foam_mask * 0.65
	);
	float coast_breakup_factor = coast_breakup_signal
		* reflection_coast_breakup_strength;
	float reflection_distortion_multiplier = 1.0 + coast_breakup_factor;
	vec2 macro_normal_offset = (
		geometric_normal - world_up_view
	).xy;
	float macro_distance_moderation = mix(
		1.0,
		0.62,
		smoothstep(180.0, 620.0, camera_distance)
	);
	vec2 macro_wave_offset = vec2(
		macro_normal_offset.x
			* reflection_macro_distortion_x
			* reflection_macro_slope_influence
			+ macro_wave_signal
				* reflection_macro_distortion_x
				* reflection_horizontal_shear,
		-macro_normal_offset.y
			* reflection_macro_distortion_y
			* reflection_macro_slope_influence
			+ macro_wave_signal
				* reflection_macro_distortion_y
				* 0.20
	) * macro_distance_moderation * reflection_distortion_multiplier;
	vec2 micro_wave_offset = detail_offset_view.xy
		* reflection_micro_distortion
		* reflection_micro_breakup
		* reflection_distortion_multiplier;
	float slope_stretch = 1.0 + clamp(
		interpolated_wave_slope * reflection_macro_slope_influence,
		0.0,
		1.0
	) * 0.06;
	float active_vertical_stretch = reflection_wave_distortion_enabled
		? reflection_vertical_stretch * slope_stretch
		: 1.0;
	vec2 mirrored_uv_unclamped = vec2(
		SCREEN_UV.x,
		reflection_waterline_uv_y
			- mirrored_vertical_distance
				* mirrored_reflection_vertical_scale
				* active_vertical_stretch
	);
	if (reflection_wave_distortion_enabled) {
		mirrored_uv_unclamped += macro_wave_offset + micro_wave_offset;
	} else {
		mirrored_uv_unclamped += (
			macro_normal_offset
				* mirrored_reflection_macro_distortion
			+ detail_offset_view.xy
				* mirrored_reflection_detail_distortion
		);
	}
	bool mirrored_uv_is_valid = is_valid_screen_uv(
		mirrored_uv_unclamped
	);
	vec2 viewport_pixel = 1.0 / VIEWPORT_SIZE;
	vec2 mirrored_uv = clamp(
		mirrored_uv_unclamped,
		viewport_pixel,
		vec2(1.0) - viewport_pixel
	);
	float mirrored_raw_depth = textureLod(
		depth_texture,
		mirrored_uv,
		0.0
	).r;
	float mirrored_geometry_mask = (
		mirrored_raw_depth > 0.000001 ? 1.0 : 0.0
	);
	vec3 mirrored_color = grade_reflection_color(
		textureLod(
			screen_texture,
			mirrored_uv,
			mirrored_reflection_blur_lod
		).rgb,
		mirrored_reflection_tint,
		mirrored_reflection_saturation,
		mirrored_reflection_contrast,
		mirrored_reflection_brightness
	);
	float mirrored_domain = smoothstep(
		-0.02,
		0.002,
		distance_below_waterline
	);
	float mirrored_near_fade = smoothstep(
		0.0,
		max(mirrored_reflection_near_fade, 0.0001),
		mirrored_vertical_distance
	);
	float mirrored_far_fade = 1.0 - smoothstep(
		mirrored_reflection_far_fade_start,
		max(
			mirrored_reflection_far_fade_end,
			mirrored_reflection_far_fade_start + 0.001
		),
		camera_distance
	);
	float mirrored_edge_visibility = calculate_screen_edge_fade(
		mirrored_uv,
		mirrored_reflection_edge_fade
	);
	float mirrored_source_strength = mix(
		mirrored_reflection_sky_strength,
		mirrored_reflection_geometry_strength,
		mirrored_geometry_mask
	);
	float mirrored_weight = (
		mirrored_reflection_enabled
		&& mirrored_reflection_strength > 0.0
		&& mirrored_uv_is_valid
	)
		? clamp(
			mirrored_reflection_strength
				* mirrored_source_strength
				* mirrored_domain
				* mirrored_near_fade
				* mirrored_far_fade
				* mirrored_edge_visibility,
			0.0,
			1.0
		)
		: 0.0;

	float custom_ssr_hit_mask = 0.0;
	float custom_ssr_hit_confidence = 0.0;
	float raymarched_weight = 0.0;
	vec3 custom_ssr_color = vec3(0.0);
	if (
		custom_ssr_enabled
		&& custom_ssr_strength > 0.0
		&& fresnel >= custom_ssr_min_fresnel
		&& foam_mask < 0.98
	) {
		vec3 reflection_direction_view = normalize(
			reflect(-view_direction, ssr_trace_normal)
		);
		vec3 reflection_direction_world = normalize(
			mat3(INV_VIEW_MATRIX) * reflection_direction_view
		);
		if (
			is_valid_view_position(
				VERTEX + reflection_direction_view * custom_ssr_start_bias
			)
			&& reflection_direction_world.y
				>= custom_ssr_upward_rejection
		) {
			vec2 custom_ssr_hit_uv = vec2(0.0);
			float custom_ssr_hit_distance = 0.0;
			float trace_confidence = 0.0;
			bool custom_ssr_hit = custom_ssr_trace(
				VERTEX,
				reflection_direction_view,
				PROJECTION_MATRIX,
				INV_PROJECTION_MATRIX,
				custom_ssr_hit_uv,
				custom_ssr_hit_distance,
				trace_confidence
			);
			if (custom_ssr_hit) {
				custom_ssr_hit_mask = 1.0;
				custom_ssr_hit_uv += (
					detail_offset_view.xy
						* custom_ssr_hit_distortion
				);
				if (reflection_wave_distortion_enabled) {
					custom_ssr_hit_uv += (
						macro_wave_offset * 0.12
							+ micro_wave_offset * 0.35
					);
				}
				bool distorted_hit_is_valid = is_valid_screen_uv(
					custom_ssr_hit_uv
				);
				custom_ssr_hit_uv = clamp(
					custom_ssr_hit_uv,
					viewport_pixel,
					vec2(1.0) - viewport_pixel
				);
				vec3 raw_raymarched_color = textureLod(
					screen_texture,
					custom_ssr_hit_uv,
					custom_ssr_blur_lod
				).rgb;
				custom_ssr_color = grade_reflection_color(
					raw_raymarched_color,
					vec3(1.0),
					1.0,
					custom_ssr_hit_contrast,
					custom_ssr_hit_brightness
				);
				custom_ssr_hit_confidence = (
					trace_confidence
					* (distorted_hit_is_valid ? 1.0 : 0.0)
				);
				float angular_visibility = mix(
					custom_ssr_minimum_hit_visibility,
					1.0,
					fresnel
				);
				raymarched_weight = clamp(
					custom_ssr_hit_confidence
						* custom_ssr_strength
						* angular_visibility,
					0.0,
					1.0
				);
			}
		}
	}

	float raymarched_blend = clamp(
		custom_ssr_hit_confidence * 0.35,
		0.0,
		1.0
	);
	vec3 hybrid_reflection_color = mix(
		mirrored_color,
		custom_ssr_color,
		raymarched_blend
	);
	float hybrid_source_weight = max(
		mirrored_weight,
		raymarched_weight
	);
	float surface_reflection_weight = mix(
		custom_reflection_minimum_surface_weight,
		custom_reflection_maximum_surface_weight,
		fresnel
	);
	float final_reflection_weight = clamp(
		hybrid_source_weight
			* surface_reflection_weight
			* (1.0 - foam_mask),
		0.0,
		1.0
	);
	final_reflection_weight *= mix(
		1.0,
		0.08,
		camera_underwater_factor
	);
	final_color *= 1.0 - final_reflection_weight;
	vec3 underwater_surface_color = mix(
		refracted_scene,
		shallow_water_color.rgb,
		0.18
	);
	final_color = mix(
		final_color,
		underwater_surface_color,
		camera_underwater_factor
	);
	final_color = mix(final_color, foam_color.rgb, foam_mask);
	final_color = mix(
		final_color,
		underwater_surface_fog_color.rgb,
		underwater_surface_fog_amount
	);

	float local_alpha = mix(near_water_alpha, deep_water_alpha, water_density);
	float final_alpha = clamp(
		mix(
			local_alpha,
			horizon_water_alpha,
			max(distance_opacity, fresnel)
		),
		0.55,
		1.0
	);
	final_alpha = mix(
		final_alpha,
		0.96,
		clamp(final_reflection_weight * 0.75, 0.0, 1.0)
	);
	final_alpha = mix(
		final_alpha,
		underwater_surface_alpha,
		camera_underwater_factor
	);
	final_alpha = max(final_alpha, foam_mask * 0.98);

	NORMAL = visual_normal;
	ALBEDO = final_color;
	ROUGHNESS = mix(
		mix(
			near_roughness,
			horizon_roughness,
			max(distance_opacity, fresnel)
		),
		foam_roughness,
		foam_mask
	);
	METALLIC = 0.0;
	float reflection_aware_specular = mix(
		water_specular,
		0.05,
		final_reflection_weight
	);
	SPECULAR = mix(
		reflection_aware_specular,
		0.16,
		foam_mask
	);
	ALPHA = final_alpha;
	EMISSION = hybrid_reflection_color
		* final_reflection_weight
		* custom_reflection_emission_strength
		* (1.0 - underwater_surface_fog_amount);

	if (custom_ssr_debug_mode == 1) {
		ALBEDO = vec3(custom_ssr_hit_mask);
		ROUGHNESS = 1.0;
		SPECULAR = 0.0;
		ALPHA = 1.0;
	} else if (custom_ssr_debug_mode == 2) {
		ALBEDO = custom_ssr_color;
		ROUGHNESS = 1.0;
		SPECULAR = 0.0;
		ALPHA = 1.0;
	} else if (custom_ssr_debug_mode == 3) {
		ALBEDO = vec3(custom_ssr_hit_confidence);
		ROUGHNESS = 1.0;
		SPECULAR = 0.0;
		ALPHA = 1.0;
	} else if (custom_ssr_debug_mode == 4) {
		ALBEDO = mirrored_color * mirrored_domain;
		ROUGHNESS = 1.0;
		SPECULAR = 0.0;
		ALPHA = 1.0;
	} else if (custom_ssr_debug_mode == 5) {
		ALBEDO = vec3(
			clamp(
				0.5 + macro_wave_offset.x
					/ max(reflection_macro_distortion_x * 0.35, 0.001),
				0.0,
				1.0
			),
			clamp(
				0.5 + macro_wave_offset.y
					/ max(reflection_macro_distortion_y * 0.35, 0.001),
				0.0,
				1.0
			),
			0.5
		);
		ROUGHNESS = 1.0;
		SPECULAR = 0.0;
		ALPHA = 1.0;
	} else if (custom_ssr_debug_mode == 6) {
		ALBEDO = vec3(
			clamp(
				0.5 + micro_wave_offset.x
					/ max(reflection_micro_distortion * 0.35, 0.001),
				0.0,
				1.0
			),
			clamp(
				0.5 + micro_wave_offset.y
					/ max(reflection_micro_distortion * 0.35, 0.001),
				0.0,
				1.0
			),
			0.5
		);
		ROUGHNESS = 1.0;
		SPECULAR = 0.0;
		ALPHA = 1.0;
	} else if (custom_ssr_debug_mode == 7) {
		float hybrid_debug_validity = max(
			mirrored_domain,
			custom_ssr_hit_mask
		);
		ALBEDO = hybrid_reflection_color
			* hybrid_debug_validity;
		ROUGHNESS = 1.0;
		SPECULAR = 0.0;
		ALPHA = 1.0;
	} else if (custom_ssr_debug_mode == 8) {
		ALBEDO = vec3(final_reflection_weight);
		ROUGHNESS = 1.0;
		SPECULAR = 0.0;
		ALPHA = 1.0;
	} else if (custom_ssr_debug_mode == 9) {
		ALBEDO = vec3(coast_breakup_signal);
		ROUGHNESS = 1.0;
		SPECULAR = 0.0;
		ALPHA = 1.0;
	}
	if (custom_ssr_debug_mode != 0) {
		EMISSION = vec3(0.0);
	}

	if (ocean_debug_show_rings) {
		vec3 ring_color = debug_ring_color(interpolated_ocean_ring_id);
		ALBEDO = ring_color;
		EMISSION = ring_color * 0.15;
		ROUGHNESS = 0.9;
		SPECULAR = 0.1;
		ALPHA = 1.0;
	}
}
