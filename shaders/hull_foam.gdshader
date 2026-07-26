shader_type spatial;
render_mode unshaded, blend_mix, depth_prepass_alpha, cull_disabled;

uniform sampler2D foam_noise_texture : repeat_enable, filter_linear_mipmap;
uniform vec4 foam_color : source_color = vec4(0.82, 0.94, 0.98, 0.82);
uniform float simulation_time = 0.0;
uniform float foam_intensity = 0.0;
uniform float macro_noise_scale = 0.055;
uniform float detail_noise_scale = 0.19;
uniform float noise_scroll_speed = 0.16;
uniform float breakup_strength = 0.78;
uniform vec2 foam_flow_direction = vec2(0.0, 1.0);
uniform float foam_flow_speed = 0.5;
uniform float opacity_boost : hint_range(0.0, 4.0, 0.01) = 1.25;
uniform float core_opacity : hint_range(0.0, 1.0, 0.01) = 0.58;
uniform float emission_strength : hint_range(0.0, 2.0, 0.01) = 0.08;


void fragment() {
	vec2 flow_direction = normalize(foam_flow_direction + vec2(0.000001, 0.0));
	vec2 uv_macro = UV * macro_noise_scale
		- flow_direction * simulation_time * noise_scroll_speed * foam_flow_speed;
	vec2 uv_detail = vec2(
		UV.y * 0.819152 - UV.x * 0.573576,
		UV.x * 0.819152 + UV.y * 0.573576
	) * detail_noise_scale
		+ flow_direction * simulation_time * noise_scroll_speed * foam_flow_speed * 0.63;
	float noise_value = texture(foam_noise_texture, uv_macro).r * 0.65
		+ texture(foam_noise_texture, uv_detail).r * 0.35;
	float edge_width = max(fwidth(noise_value) * 1.5, 0.015);
	float breakup = smoothstep(0.40 - edge_width, 0.54 + edge_width, noise_value);
	float lateral_distance = abs(UV2.x * 2.0 - 1.0);
	float lateral_edge = 1.0 - smoothstep(0.68, 1.0, lateral_distance);
	float nose_fade = smoothstep(0.0, 0.12, UV2.y);
	float stern_fade = 1.0 - smoothstep(0.72, 1.0, UV2.y);
	float under_hull_core = 1.0 - smoothstep(0.08, 0.88, lateral_distance);
	float stern_agitation = smoothstep(0.32, 0.68, UV2.y)
		* (1.0 - smoothstep(0.82, 1.0, UV2.y));
	float internal_holes = smoothstep(
		0.28 - edge_width,
		0.47 + edge_width,
		texture(foam_noise_texture, uv_detail * 1.73 + vec2(0.19, -0.27)).r
	);
	float fragment_mask = mix(0.68 + 0.32 * noise_value, breakup, breakup_strength)
		* mix(0.76, 1.0, internal_holes);
	float density = mix(0.58, 1.0, under_hull_core)
		* mix(0.82, 1.0, stern_agitation);
	float bright_core = under_hull_core
		* mix(0.72, 1.0, stern_agitation)
		* mix(0.72, 1.0, noise_value);
	vec3 core_color = mix(foam_color.rgb, vec3(1.0), 0.46);
	ALBEDO = mix(foam_color.rgb, core_color, bright_core);
	EMISSION = core_color
		* emission_strength
		* bright_core
		* foam_intensity;
	ROUGHNESS = 0.86;
	float base_alpha = COLOR.a * foam_color.a * foam_intensity
		* lateral_edge * nose_fade * stern_fade * density * fragment_mask;
	float core_alpha = COLOR.a
		* foam_intensity
		* lateral_edge
		* nose_fade
		* stern_fade
		* bright_core
		* core_opacity;
	ALPHA = clamp(max(base_alpha * opacity_boost, core_alpha), 0.0, 0.96);
}
