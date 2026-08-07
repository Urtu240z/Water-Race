shader_type spatial;
render_mode blend_add, depth_draw_never, cull_disabled, unshaded, shadows_disabled;

group_uniforms Beam;
uniform vec4 light_color : source_color = vec4(0.8128, 0.8308, 0.6756, 1.0);
uniform float beam_opacity : hint_range(0.0, 1.0, 0.005) = 0.14;
uniform float emission_energy : hint_range(0.0, 12.0, 0.05) = 2.2;
uniform float base_density : hint_range(0.0, 1.0, 0.01) = 0.32;

group_uniforms SoftEdges;
uniform float edge_fade_start : hint_range(0.0, 0.9, 0.01) = 0.02;
uniform float edge_fade_end : hint_range(0.01, 1.0, 0.01) = 0.34;
uniform float edge_fade_power : hint_range(0.25, 4.0, 0.05) = 1.25;
uniform float near_fade_end : hint_range(0.001, 0.4, 0.005) = 0.055;
uniform float far_fade_start : hint_range(0.4, 0.999, 0.005) = 0.73;
uniform float length_falloff : hint_range(0.0, 4.0, 0.05) = 0.75;

group_uniforms MovingDust;
uniform float dust_strength : hint_range(0.0, 4.0, 0.05) = 1.35;
uniform float dust_scale : hint_range(0.01, 2.0, 0.01) = 0.16;
uniform float dust_detail : hint_range(0.1, 8.0, 0.05) = 2.65;
uniform float dust_threshold : hint_range(0.0, 0.95, 0.01) = 0.56;
uniform float dust_softness : hint_range(0.01, 0.5, 0.01) = 0.22;
uniform vec3 dust_velocity = vec3(0.10, -0.34, -0.16);
group_uniforms;

varying vec3 beam_local_position;

// Cheap, texture-free pseudo-volume. It stays continuous across the cone UV seam.
float drifting_field(vec3 position) {
	float wave_a = sin(dot(position, vec3(1.31, 2.17, 0.73)));
	float wave_b = sin(dot(position, vec3(-0.83, 1.71, 2.41)) + wave_a * 1.65);
	float wave_c = sin(dot(position, vec3(2.31, -0.57, 1.19)) + wave_b * 1.25);
	return clamp(0.5 + 0.5 * (wave_a * 0.38 + wave_b * 0.37 + wave_c * 0.25), 0.0, 1.0);
}

void vertex() {
	beam_local_position = VERTEX;
}

void fragment() {
	float longitudinal = clamp(UV.y, 0.0, 1.0);

	// Fade the emitter and, especially, the open end so neither cut is visible.
	float near_fade = smoothstep(0.0, max(near_fade_end, 0.0001), longitudinal);
	float far_fade = 1.0 - smoothstep(far_fade_start, 1.0, longitudinal);
	float distance_fade = pow(max(1.0 - longitudinal, 0.0), length_falloff);

	// Silhouette fade removes the hard polygonal outline from every camera angle.
	float facing = abs(dot(normalize(NORMAL), normalize(VIEW)));
	float soft_edge = smoothstep(edge_fade_start, max(edge_fade_end, edge_fade_start + 0.001), facing);
	soft_edge = pow(max(soft_edge, 0.0), edge_fade_power);

	vec3 movement = dust_velocity * TIME;
	vec3 coarse_position = beam_local_position * dust_scale + movement;
	vec3 fine_position = beam_local_position * dust_scale * dust_detail - movement * 1.37;
	float coarse_dust = drifting_field(coarse_position);
	float fine_dust = drifting_field(fine_position);
	float dust_field = mix(coarse_dust, fine_dust, 0.34);
	float dust = smoothstep(
		dust_threshold,
		min(dust_threshold + max(dust_softness, 0.001), 1.0),
		dust_field
	);

	float density = base_density + dust * dust_strength;
	float alpha = beam_opacity * light_color.a * near_fade * far_fade * distance_fade * soft_edge * density;

	ALBEDO = light_color.rgb;
	EMISSION = light_color.rgb * emission_energy * (0.72 + dust * 0.55);
	ALPHA = clamp(alpha, 0.0, 1.0);
}
