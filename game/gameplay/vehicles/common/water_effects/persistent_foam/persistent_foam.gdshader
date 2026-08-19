shader_type spatial;
render_mode blend_mix, depth_prepass_alpha, cull_disabled;

// World-anchored persistent foam. Noise is sampled at the fixed world XZ of the
// stored ribbon vertices, so nothing scrolls or slides horizontally. The foam
// only ages, fades and dissolves in place.

uniform vec4 foam_color : source_color = vec4(0.80, 0.94, 1.0, 0.85);
uniform sampler2D foam_noise_texture : repeat_enable, filter_linear_mipmap;
uniform float simulation_time = 0.0;
uniform float macro_noise_scale = 0.055;
uniform float detail_noise_scale = 0.19;
uniform float breakup_strength = 0.78;
uniform float edge_softness : hint_range(0.01, 0.49, 0.01) = 0.16;
uniform float opacity_boost : hint_range(0.0, 4.0, 0.01) = 1.0;
uniform float core_opacity : hint_range(0.0, 1.0, 0.01) = 0.22;
uniform float emission_strength : hint_range(0.0, 2.0, 0.01) = 0.05;
uniform float foam_roughness : hint_range(0.0, 1.0, 0.01) = 0.88;
uniform float fade_start_ratio : hint_range(0.0, 1.0, 0.01) = 0.70;
uniform float birth_fade_ratio : hint_range(0.0, 0.5, 0.005) = 0.06;

varying vec3 world_vertex;


void vertex() {
	world_vertex = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
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
	float age_ratio = clamp(COLOR.r, 0.0, 1.0);
	float density = clamp(COLOR.g, 0.0, 1.0);
	float lateral_distance = abs(UV.x * 2.0 - 1.0);

	// Stable plateau up to fade_start_ratio, then a clean fade to the end.
	float life_fade = 1.0 - smoothstep(fade_start_ratio, 1.0, age_ratio);
	float birth_fade = smoothstep(0.0, birth_fade_ratio, age_ratio);
	float life_alpha = life_fade * birth_fade;

	// World-anchored noise: coordinates are meters, scaled to the same tile
	// density the vehicle foam shaders use.
	vec2 macro_uv = world_vertex.xz * macro_noise_scale;
	vec2 detail_uv = world_vertex.xz * detail_noise_scale;
	float texture_noise = texture(foam_noise_texture, macro_uv).r * 0.62
		+ texture(foam_noise_texture, detail_uv).r * 0.38;

	// Procedural breakup anchored to world meters (no translation).
	float breakup_macro = value_noise(world_vertex.xz * 1.55);
	float breakup_detail = value_noise(world_vertex.xz * 4.3);
	float breakup_fine = value_noise(world_vertex.xz * 9.1);
	float patch_noise = breakup_macro * 0.56
		+ breakup_detail * 0.34
		+ breakup_fine * 0.10;

	// Shimmer that never moves the foam (threshold flicker only).
	float flicker = 0.5 + 0.5 * sin(
		simulation_time * 0.9 + world_vertex.x * 0.13 + world_vertex.y * 0.05
	);

	float age_breakup = smoothstep(0.18, 1.0, age_ratio);
	float breakup_strength_effect = mix(
		0.55,
		1.0,
		clamp(breakup_strength, 0.0, 1.0)
	);
	float threshold = mix(0.30, 0.62, age_breakup)
		- flicker * 0.06 * breakup_strength_effect;
	float noise_edge = max(fwidth(patch_noise) * 1.15, 0.03);
	float foam_patches = smoothstep(
		threshold - noise_edge,
		threshold + noise_edge,
		patch_noise * mix(0.72, 1.0, texture_noise)
	);
	if (age_ratio > 0.22 && foam_patches < 0.03) {
		discard;
	}

	float edge_irregularity = (patch_noise - 0.5)
		* mix(0.06, 0.34, age_breakup);
	float ribbon_edge = 1.0 - smoothstep(
		0.84 + edge_irregularity - edge_softness,
		1.0 + edge_irregularity,
		lateral_distance
	);

	float core_profile = smoothstep(0.85, 0.20, lateral_distance);
	float bright_core = core_profile
		* mix(1.0, 0.35, age_ratio)
		* mix(0.6, 1.0, texture_noise);

	vec3 core_color = mix(foam_color.rgb, vec3(1.0), 0.34);
	ALBEDO = mix(foam_color.rgb, core_color, bright_core);
	EMISSION = core_color
		* emission_strength
		* bright_core
		* life_alpha
		* density;
	ROUGHNESS = foam_roughness;

	float base_alpha = ribbon_edge
		* foam_patches
		* life_alpha
		* density
		* foam_color.a
		* opacity_boost;
	float core_alpha = ribbon_edge
		* foam_patches
		* bright_core
		* life_alpha
		* density
		* core_opacity;
	ALPHA = clamp(max(base_alpha, core_alpha), 0.0, 0.94);
}