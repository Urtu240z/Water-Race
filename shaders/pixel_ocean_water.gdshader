// Pixel Ocean for Water Race.
// The macro displacement and CPU sampling model are adapted from the
// texture-driven approach in Taillight Games' MIT-licensed pixel water shader.
shader_type spatial;
render_mode blend_mix, world_vertex_coords, cull_disabled, depth_draw_always, diffuse_burley, specular_schlick_ggx;

const int MAX_RIPPLES = 12;
const float TAU_VALUE = 6.28318530718;

uniform bool pixel_ocean_enabled = true;
uniform float base_height = 0.0;
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

group_uniforms Foam;
uniform bool foam_enabled = true;
uniform sampler2D foam_noise_texture : repeat_enable, filter_linear_mipmap;
uniform vec4 foam_color : source_color = vec4(0.82, 0.95, 1.0, 1.0);
uniform float shore_foam_width : hint_range(0.1, 8.0, 0.05) = 2.15;
uniform float shore_foam_strength : hint_range(0.0, 2.0, 0.01) = 1.05;
uniform float crest_foam_start : hint_range(0.0, 2.0, 0.01) = 0.46;
uniform float crest_foam_end : hint_range(0.0, 3.0, 0.01) = 0.94;
uniform float crest_foam_strength : hint_range(0.0, 2.0, 0.01) = 0.82;
uniform float ripple_foam_strength : hint_range(0.0, 2.0, 0.01) = 0.18;
uniform float foam_macro_scale : hint_range(0.001, 1.0, 0.001) = 0.055;
uniform float foam_detail_scale : hint_range(0.001, 2.0, 0.001) = 0.19;
uniform float foam_scroll_speed : hint_range(0.0, 2.0, 0.01) = 0.13;
uniform float foam_roughness : hint_range(0.0, 1.0, 0.01) = 0.88;

group_uniforms Clipmap;
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


float clipmap_wave_scale(vec2 world_xz) {
	if (!ocean_clipmap_enabled) {
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
	float macro_scale = clipmap_wave_scale(world_xz);
	float ripple_distance = length(world_xz - ocean_detail_center_xz);
	float ripple_scale = 1.0 - smoothstep(70.0, 130.0, ripple_distance);
	return vec4(
		macro_height * macro_scale + ripple.x * ripple_scale,
		macro_derivatives * macro_scale + ripple.yz * ripple_scale,
		ripple.w * ripple_scale
	);
}


void vertex() {
	vec2 world_xz = VERTEX.xz;
	vec4 wave_state = sample_wave_state(world_xz);
	VERTEX.y = base_height + wave_state.x;
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
		base_height + interpolated_wave_height,
		interpolated_world_xz.y
	);
	float camera_distance = length(CAMERA_POSITION_WORLD - world_fragment_position);
	vec2 logical_xz = interpolated_world_xz + ocean_logical_origin_offset_xz;
	vec3 detail_normal = sample_surface_detail(logical_xz, camera_distance);
	vec2 detail_slope = detail_normal.xy / max(detail_normal.z, 0.08);
	vec3 detail_offset_view = mat3(VIEW_MATRIX) * vec3(
		detail_slope.x,
		0.0,
		detail_slope.y
	);
	vec3 visual_normal = normalize(
		NORMAL + detail_offset_view * surface_normal_strength
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
	float shoreline = scene_is_sky
		? 0.0
		: (1.0 - smoothstep(0.06, shore_foam_width, water_thickness))
			* shore_foam_strength;
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
	final_color = mix(final_color, foam_color.rgb, foam_mask);

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
	SPECULAR = mix(water_specular, 0.16, foam_mask);
	ALPHA = final_alpha;

	if (ocean_debug_show_rings) {
		vec3 ring_color = debug_ring_color(interpolated_ocean_ring_id);
		ALBEDO = ring_color;
		EMISSION = ring_color * 0.15;
		ROUGHNESS = 0.9;
		SPECULAR = 0.1;
		ALPHA = 1.0;
	}
}

