shader_type spatial;
render_mode unshaded, blend_mix, depth_prepass_alpha, cull_disabled;

uniform vec4 spray_color : source_color = vec4(0.78, 0.95, 1.0, 0.94);
uniform vec4 edge_color : source_color = vec4(0.96, 1.0, 1.0, 1.0);
uniform float edge_softness : hint_range(0.01, 0.4, 0.01) = 0.10;
uniform float irregularity : hint_range(0.0, 1.0, 0.01) = 0.58;
uniform float core_opacity : hint_range(0.0, 1.0, 0.01) = 0.82;
uniform float emission_strength : hint_range(0.0, 3.0, 0.01) = 0.38;

varying flat float particle_seed;


float hash11(float value) {
	return fract(sin(value * 127.1) * 43758.5453123);
}


float hash21(vec2 value) {
	vec3 value3 = fract(vec3(value.xyx) * 0.1031);
	value3 += dot(value3, value3.yzx + 33.33);
	return fract((value3.x + value3.y) * value3.z);
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


void vertex() {
	float instance_seed = hash11(float(INSTANCE_ID) + 4.17);
	particle_seed = instance_seed;
	float rotation = INSTANCE_CUSTOM.x + (instance_seed - 0.5) * 1.1;
	float cosine = cos(rotation);
	float sine = sin(rotation);
	VERTEX.xy = mat2(vec2(cosine, sine), vec2(-sine, cosine)) * VERTEX.xy;

	mat4 particle_modelview = VIEW_MATRIX * MODEL_MATRIX;
	float scale_x = max(length(particle_modelview[0].xyz), 0.0001);
	float scale_y = max(length(particle_modelview[1].xyz), 0.0001);
	float scale_z = max(length(particle_modelview[2].xyz), 0.0001);
	MODELVIEW_MATRIX = mat4(
		vec4(scale_x, 0.0, 0.0, 0.0),
		vec4(0.0, scale_y, 0.0, 0.0),
		vec4(0.0, 0.0, scale_z, 0.0),
		particle_modelview[3]
	);
}


void fragment() {
	float instance_seed = particle_seed;
	vec2 centered_uv = UV * 2.0 - 1.0;
	float radial_distance = length(centered_uv);
	float radial_angle = atan(centered_uv.y, centered_uv.x);

	float lobe_a = sin(radial_angle * 5.0 + instance_seed * 19.0);
	float lobe_b = sin(radial_angle * 9.0 - instance_seed * 31.0);
	float lobe_c = sin(radial_angle * 14.0 + instance_seed * 11.0);
	float boundary = 0.72 + irregularity * (
		lobe_a * 0.105
		+ lobe_b * 0.065
		+ lobe_c * 0.035
	);
	float edge_width = max(edge_softness, fwidth(radial_distance) * 1.5);
	float silhouette = 1.0 - smoothstep(
		boundary - edge_width,
		boundary + edge_width,
		radial_distance
	);

	vec2 noise_uv = centered_uv * 3.8
		+ vec2(instance_seed * 17.0, instance_seed * 29.0);
	float breakup_noise = value_noise(noise_uv)
		* 0.62
		+ value_noise(noise_uv * 2.13 + 7.0) * 0.38;
	float edge_breakup = smoothstep(
		0.30,
		0.58,
		breakup_noise + (1.0 - radial_distance) * 0.42
	);
	float center_fill = 1.0 - smoothstep(0.18, 0.56, radial_distance);
	float shape = silhouette * max(edge_breakup, center_fill);
	if (shape < 0.01) {
		discard;
	}

	float foam_core = shape
		* pow(max(1.0 - radial_distance / max(boundary, 0.01), 0.0), 0.48);
	float rim = shape * smoothstep(0.24, 0.86, radial_distance / max(boundary, 0.01));
	vec3 final_color = mix(spray_color.rgb, edge_color.rgb, rim * 0.72 + foam_core * 0.22);
	ALBEDO = final_color;
	EMISSION = final_color
		* emission_strength
		* (foam_core * 0.72 + rim * 0.28);
	ROUGHNESS = 0.88;
	ALPHA = clamp(
		shape
		* max(spray_color.a * COLOR.a, foam_core * core_opacity * COLOR.a),
		0.0,
		0.98
	);
}
