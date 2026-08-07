shader_type spatial;
render_mode blend_mix, depth_prepass_alpha, cull_disabled;

uniform vec4 particle_color : source_color = vec4(0.76, 0.94, 1.0, 0.88);
uniform float edge_softness : hint_range(0.01, 0.49, 0.01) = 0.16;
uniform float core_opacity : hint_range(0.0, 1.0, 0.01) = 0.64;
uniform float emission_strength : hint_range(0.0, 2.0, 0.01) = 0.12;


void vertex() {
	mat4 particle_modelview = VIEW_MATRIX * MODEL_MATRIX;
	vec3 velocity_axis = normalize(particle_modelview[1].xyz);
	vec3 view_axis = vec3(0.0, 0.0, 1.0);
	vec3 width_axis = cross(velocity_axis, view_axis);
	if (length(width_axis) < 0.001) {
		width_axis = vec3(1.0, 0.0, 0.0);
	} else {
		width_axis = normalize(width_axis);
	}
	vec3 depth_axis = normalize(cross(width_axis, velocity_axis));
	float particle_scale = max(length(particle_modelview[0].xyz), 0.0001);
	MODELVIEW_MATRIX = mat4(
		vec4(width_axis * particle_scale, 0.0),
		vec4(velocity_axis * particle_scale, 0.0),
		vec4(depth_axis * particle_scale, 0.0),
		particle_modelview[3]
	);
	MODELVIEW_NORMAL_MATRIX = mat3(width_axis, velocity_axis, depth_axis);
}


void fragment() {
	vec2 centered_uv = UV * 2.0 - 1.0;
	float tapered_width = mix(0.40, 1.0, smoothstep(-1.0, 0.20, centered_uv.y));
	tapered_width *= mix(1.0, 0.46, smoothstep(0.20, 1.0, centered_uv.y));
	float normalized_x = centered_uv.x / max(tapered_width, 0.08);
	float shape_distance = length(vec2(normalized_x, centered_uv.y));
	float irregularity = sin(centered_uv.y * 19.0 + centered_uv.x * 11.0) * 0.025;
	float shape = 1.0 - smoothstep(
		1.0 - edge_softness,
		1.0,
		shape_distance + irregularity
	);
	float highlight = pow(max(1.0 - abs(normalized_x), 0.0), 5.0) * 0.34;
	float core = shape * pow(max(1.0 - shape_distance, 0.0), 0.65);
	vec3 bright_color = mix(particle_color.rgb, vec3(1.0), highlight + core * 0.28);
	ALBEDO = bright_color;
	EMISSION = bright_color * emission_strength * core;
	ALPHA = shape * max(
		particle_color.a * COLOR.a,
		core * core_opacity * COLOR.a
	);
}
