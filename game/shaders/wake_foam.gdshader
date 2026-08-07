shader_type spatial;
render_mode blend_mix, depth_prepass_alpha, cull_disabled;

uniform vec4 foam_color : source_color = vec4(0.76, 0.92, 0.98, 0.58);
uniform sampler2D foam_noise_texture : repeat_enable, filter_linear_mipmap;
uniform float simulation_time = 0.0;
uniform vec2 ocean_logical_origin_offset_xz = vec2(0.0);
uniform float foam_intensity = 0.0;
uniform float macro_noise_scale = 0.055;
uniform float detail_noise_scale = 0.19;
uniform float noise_scroll_speed = 0.16;
uniform float breakup_strength = 0.78;
uniform float edge_softness : hint_range(0.01, 0.49, 0.01) = 0.16;
uniform float opacity_boost : hint_range(0.0, 4.0, 0.01) = 1.0;
uniform float core_opacity : hint_range(0.0, 1.0, 0.01) = 0.22;
uniform float emission_strength : hint_range(0.0, 2.0, 0.01) = 0.05;

#include "res://world/water/ocean/shaders/includes/ocean_vehicle_interaction_uniforms.gdshaderinc"
#include "res://world/water/ocean/shaders/includes/ocean_vehicle_interaction_functions.gdshaderinc"


void vertex() {
	vec3 world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	vec2 logical_xz = world_position.xz + ocean_logical_origin_offset_xz;
	float interaction_height = sample_vehicle_interaction_state(logical_xz).x;
	vec3 local_displacement = inverse(mat3(MODEL_MATRIX))
		* vec3(0.0, interaction_height, 0.0);
	VERTEX += local_displacement;
}


float hash21(vec2 value) {
	value = fract(value * vec2(123.34, 456.21));
	value += dot(value, value + 45.32);
	return fract(value.x * value.y);
}


float value_noise(vec2 value) {
	vec2 cell = floor(value);
	vec2 fraction_value = fract(value);
	fraction_value = fraction_value * fraction_value
		* (3.0 - 2.0 * fraction_value);
	float a = hash21(cell);
	float b = hash21(cell + vec2(1.0, 0.0));
	float c = hash21(cell + vec2(0.0, 1.0));
	float d = hash21(cell + vec2(1.0, 1.0));
	return mix(mix(a, b, fraction_value.x), mix(c, d, fraction_value.x), fraction_value.y);
}


void fragment() {
	float lateral_distance = abs(UV.x * 2.0 - 1.0);
	vec2 trail_coordinates = vec2(UV.y, UV.x * 3.7);
	vec2 uv_macro = trail_coordinates * macro_noise_scale
		- vec2(1.0, 0.17) * simulation_time * noise_scroll_speed;
	vec2 uv_detail = vec2(
		trail_coordinates.y * 0.819152 - trail_coordinates.x * 0.573576,
		trail_coordinates.x * 0.819152 + trail_coordinates.y * 0.573576
	) * detail_noise_scale
		+ vec2(1.0, -0.17) * simulation_time * noise_scroll_speed * 0.63;
	float noise_value = texture(foam_noise_texture, uv_macro).r * 0.65
		+ texture(foam_noise_texture, uv_detail).r * 0.35;
	float age_ratio = clamp(COLOR.r, 0.0, 1.0);
	float speed_density = mix(0.78, 1.0, clamp(COLOR.g, 0.0, 1.0));
	float procedural_macro = value_noise(vec2(
		UV.y * 0.44 - simulation_time * 0.18,
		UV.x * 2.8 + simulation_time * 0.07
	));
	float procedural_detail = value_noise(vec2(
		UV.y * 1.38 + simulation_time * 0.31,
		UV.x * 6.2 - simulation_time * 0.16
	));
	float patch_noise = procedural_macro * 0.64
		+ procedural_detail * 0.36;
	float island_noise = value_noise(vec2(
		UV.y * 0.82 + simulation_time * 0.11,
		UV.x * 4.4 - simulation_time * 0.09
	));
	float threshold = mix(0.34, 0.66, age_ratio);
	float noise_edge = max(fwidth(patch_noise) * 1.35, 0.035);
	float foam_patches = smoothstep(
		threshold - noise_edge,
		threshold + noise_edge,
		patch_noise
	);
	float age_breakup = smoothstep(0.16, 0.82, age_ratio);
	foam_patches *= mix(
		1.0,
		smoothstep(0.42, 0.68, island_noise),
		age_breakup
	);
	float edge_irregularity = (patch_noise - 0.5)
		* mix(0.08, 0.46, age_ratio);
	float wake_edge = 1.0 - smoothstep(
		0.82 + edge_irregularity - edge_softness,
		1.0 + edge_irregularity,
		lateral_distance
	);
	float continuous_near_field = 1.0 - smoothstep(0.04, 0.18, age_ratio);
	float center_profile = pow(
		max(1.0 - lateral_distance, 0.0),
		mix(1.65, 1.10, age_ratio)
	);
	float center_churn = 1.0 - smoothstep(
		mix(0.30, 0.20, age_ratio),
		mix(0.76, 0.62, age_ratio),
		lateral_distance
	);
	float turbulent_fill = smoothstep(
		mix(0.24, 0.40, age_ratio),
		mix(0.62, 0.76, age_ratio),
		patch_noise * 0.64 + island_noise * 0.36
	);
	float wake_structure = wake_edge
		* center_profile
		* mix(
			1.0,
			max(turbulent_fill, center_churn * 0.72),
			smoothstep(0.10, 0.88, age_ratio)
		);
	wake_structure = max(
		wake_structure,
		center_churn * continuous_near_field
	);
	float age_fragmentation = mix(
		foam_patches,
		1.0,
		continuous_near_field * (1.0 - breakup_strength * 0.48)
	);
	float detail_density = mix(0.72, 1.0, noise_value);
	float core_density = mix(0.52, 1.0, center_profile) * detail_density;
	if (age_ratio > 0.24 && foam_patches < 0.025) {
		discard;
	}
	float bright_core = center_profile
		* wake_structure
		* mix(1.0, 0.42, age_ratio)
		* detail_density;
	vec3 core_color = mix(foam_color.rgb, vec3(1.0), 0.30);
	ALBEDO = mix(foam_color.rgb, core_color, bright_core);
	EMISSION = core_color
		* emission_strength
		* bright_core
		* foam_intensity;
	ROUGHNESS = 0.88;
	float base_alpha = COLOR.a * wake_edge * age_fragmentation
		* core_density
		* speed_density
		* foam_color.a
		* foam_intensity
		* wake_structure;
	float core_alpha = COLOR.a
		* wake_edge
		* age_fragmentation
		* speed_density
		* bright_core
		* core_opacity
		* foam_intensity;
	ALPHA = clamp(max(base_alpha * opacity_boost, core_alpha), 0.0, 0.94);
}
