shader_type spatial;
render_mode blend_mix, depth_prepass_alpha, cull_disabled;

uniform sampler2D screen_texture : hint_screen_texture, repeat_disable, filter_linear_mipmap;
uniform vec4 water_tint : source_color = vec4(0.12, 0.62, 0.72, 1.0);
uniform vec4 foam_tint : source_color = vec4(0.82, 0.95, 1.0, 1.0);
uniform float water_alpha : hint_range(0.0, 1.0, 0.01) = 0.34;
uniform float roughness : hint_range(0.02, 0.8, 0.01) = 0.10;
uniform float fresnel_power : hint_range(0.5, 8.0, 0.1) = 3.2;
uniform float refraction_strength : hint_range(0.0, 0.03, 0.0005) = 0.004;
uniform float simulation_time = 0.0;
uniform bool refraction_enabled = true;
uniform bool sheet_mode = false;
uniform float foam_core_strength : hint_range(0.0, 2.0, 0.01) = 0.82;
uniform float foam_core_opacity : hint_range(0.0, 1.0, 0.01) = 0.76;
uniform float foam_emission_strength : hint_range(0.0, 2.0, 0.01) = 0.20;


float hash21(vec2 value) {
	value = fract(value * vec2(123.34, 456.21));
	value += dot(value, value + 45.32);
	return fract(value.x * value.y);
}


float value_noise(vec2 value) {
	vec2 cell = floor(value);
	vec2 fraction_value = fract(value);
	fraction_value = fraction_value * fraction_value * (3.0 - 2.0 * fraction_value);
	float a = hash21(cell);
	float b = hash21(cell + vec2(1.0, 0.0));
	float c = hash21(cell + vec2(0.0, 1.0));
	float d = hash21(cell + vec2(1.0, 1.0));
	return mix(mix(a, b, fraction_value.x), mix(c, d, fraction_value.x), fraction_value.y);
}


void fragment() {
	float facing = clamp(dot(normalize(NORMAL), normalize(VIEW)), 0.0, 1.0);
	float fresnel = pow(1.0 - facing, fresnel_power);
	float age = clamp(UV.y, 0.0, 1.0);
	float breakup_noise = value_noise(
		vec2(UV.x * 8.0, UV.y * 17.0 - simulation_time * 2.8)
	);
	float tip_fade = 1.0 - smoothstep(0.72, 1.0, age);
	float lateral_edge = 1.0;
	if (sheet_mode) {
		float lateral = abs(UV.x * 2.0 - 1.0);
		float edge_offset = (breakup_noise - 0.5) * mix(0.05, 0.28, age);
		lateral_edge = 1.0 - smoothstep(0.76 + edge_offset, 1.0 + edge_offset, lateral);
	}
	float breakup = mix(
		1.0,
		smoothstep(0.32, 0.66, breakup_noise),
		smoothstep(0.24, 0.76, age) * 0.92
	);
	float stream_noise = value_noise(vec2(
		UV.x * 15.0 + age * 4.0,
		age * 31.0 - simulation_time * 3.7
	));
	if (!sheet_mode) {
		float stream_breakup = smoothstep(0.40, 0.70, stream_noise);
		breakup *= mix(
			1.0,
			stream_breakup,
			smoothstep(0.32, 0.82, age) * 0.92
		);
	}
	float foam_edge = smoothstep(0.50, 0.92, age)
		* smoothstep(0.48, 0.82, breakup_noise);
	if (!sheet_mode) {
		foam_edge = max(
			foam_edge,
			smoothstep(0.42, 0.88, age)
				* smoothstep(0.64, 0.84, stream_noise) * 0.62
		);
	}
	vec3 refracted_color = textureLod(
		screen_texture,
		SCREEN_UV + NORMAL.xy * refraction_strength * (1.0 - fresnel),
		0.0
	).rgb;
	vec3 clear_water = water_tint.rgb;
	if (refraction_enabled) {
		clear_water = mix(refracted_color, water_tint.rgb, 0.54 + fresnel * 0.30);
	}
	float lateral_distance = abs(UV.x * 2.0 - 1.0);
	float transverse_core = 1.0 - smoothstep(0.18, 0.82, lateral_distance);
	float near_source = 1.0 - smoothstep(
		sheet_mode ? 0.46 : 0.58,
		0.96,
		age
	);
	float core_breakup = mix(
		1.0,
		smoothstep(0.22, 0.58, breakup_noise),
		smoothstep(0.30, 0.88, age) * 0.72
	);
	float foam_core = clamp(
		transverse_core
			* near_source
			* core_breakup
			* foam_core_strength,
		0.0,
		1.0
	);
	float foam_mix = clamp(max(foam_edge * 0.62, foam_core * 0.88), 0.0, 1.0);
	vec3 bright_foam = mix(foam_tint.rgb, vec3(1.0), 0.38);
	ALBEDO = mix(clear_water, bright_foam, foam_mix);
	EMISSION = bright_foam * foam_emission_strength * foam_core;
	ROUGHNESS = mix(roughness, 0.72, foam_edge);
	SPECULAR = mix(0.92, 0.22, foam_edge);
	float optical_alpha = water_alpha + fresnel * 0.34 + foam_edge * 0.24;
	if (sheet_mode) {
		float sheet_edge = smoothstep(0.16, 0.92, abs(UV.x * 2.0 - 1.0));
		optical_alpha = water_alpha + fresnel * 0.08 + foam_edge * 0.16;
		optical_alpha *= mix(0.10, 1.0, sheet_edge);
	}
	float transparent_alpha = COLOR.a
		* lateral_edge
		* tip_fade
		* breakup
		* optical_alpha;
	float core_alpha = sqrt(clamp(COLOR.a, 0.0, 1.0))
		* lateral_edge
		* tip_fade
		* foam_core
		* foam_core_opacity;
	ALPHA = clamp(max(transparent_alpha, core_alpha), 0.0, 0.96);
}
