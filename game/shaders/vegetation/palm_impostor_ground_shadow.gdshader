shader_type spatial;
render_mode blend_mix, depth_draw_never, cull_disabled, unshaded, shadows_disabled;

uniform vec4 shadow_color : source_color = vec4(0.035, 0.026, 0.016, 0.48);
uniform float edge_softness : hint_range(0.05, 0.45, 0.01) = 0.24;
uniform float breakup : hint_range(0.0, 1.0, 0.01) = 0.52;


float hash_21(vec2 position) {
	return fract(sin(dot(position, vec2(127.1, 311.7))) * 43758.5453123);
}


float value_noise(vec2 position) {
	vec2 cell = floor(position);
	vec2 local = fract(position);
	local = local * local * (3.0 - 2.0 * local);

	float a = hash_21(cell);
	float b = hash_21(cell + vec2(1.0, 0.0));
	float c = hash_21(cell + vec2(0.0, 1.0));
	float d = hash_21(cell + vec2(1.0, 1.0));
	return mix(mix(a, b, local.x), mix(c, d, local.x), local.y);
}


void fragment() {
	float broad_noise = value_noise(vec2(UV.y * 0.23, UV.x * 2.7));
	float detail_noise = value_noise(vec2(UV.y * 0.91 + 13.4, UV.x * 8.2));
	float irregularity = mix(broad_noise, detail_noise, 0.34);

	float varying_edge = (irregularity - 0.5) * 0.13;
	float left_fade = smoothstep(
		0.02 + varying_edge,
		edge_softness + varying_edge,
		UV.x
	);
	float right_fade = smoothstep(
		0.02 - varying_edge,
		edge_softness - varying_edge,
		1.0 - UV.x
	);
	float edge_mask = left_fade * right_fade;

	float density = mix(0.58, 1.0, irregularity);
	density *= mix(1.0, smoothstep(0.18, 0.82, detail_noise), breakup);

	ALBEDO = shadow_color.rgb;
	ROUGHNESS = 1.0;
	ALPHA = shadow_color.a * edge_mask * density;
}
