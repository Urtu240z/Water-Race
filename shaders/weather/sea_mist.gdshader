shader_type spatial;
render_mode unshaded, blend_mix, cull_disabled, depth_draw_never, fog_disabled;

uniform sampler2D depth_texture : hint_depth_texture, repeat_disable, filter_nearest;
uniform vec4 mist_color : source_color = vec4(0.68, 0.78, 0.86, 1.0);
uniform float mist_intensity : hint_range(0.0, 1.0, 0.01) = 0.0;
uniform float mist_opacity : hint_range(0.0, 1.0, 0.01) = 0.22;
uniform float microdrop_strength : hint_range(0.0, 1.0, 0.01) = 0.38;
uniform float mist_noise_scale : hint_range(0.5, 10.0, 0.1) = 3.2;
uniform float mist_detail_scale : hint_range(1.0, 30.0, 0.1) = 11.0;
uniform float soft_depth_distance : hint_range(0.01, 3.0, 0.01) = 0.45;
varying float particle_phase;
varying float particle_seed;

float mist_hash12(vec2 value) {
	vec3 value3 = fract(vec3(value.xyx) * 0.1031);
	value3 += dot(value3, value3.yzx + 33.33);
	return fract((value3.x + value3.y) * value3.z);
}

float mist_value_noise(vec2 value) {
	vec2 cell = floor(value);
	vec2 local_position = fract(value);
	local_position = local_position * local_position * (3.0 - 2.0 * local_position);
	return mix(mix(mist_hash12(cell), mist_hash12(cell + vec2(1.0, 0.0)), local_position.x), mix(mist_hash12(cell + vec2(0.0, 1.0)), mist_hash12(cell + vec2(1.0)), local_position.x), local_position.y);
}

float mist_fbm(vec2 value) {
	float result = mist_value_noise(value) * 0.56;
	value = value * 2.07 + vec2(13.17, 7.91);
	result += mist_value_noise(value) * 0.28;
	value = value * 2.11 + vec2(-5.73, 19.31);
	return result + mist_value_noise(value) * 0.14;
}

float reconstruct_linear_depth(vec2 screen_uv, float raw_depth) {
	vec4 view_position = INV_PROJECTION_MATRIX * vec4(screen_uv * 2.0 - 1.0, raw_depth, 1.0);
	if (abs(view_position.w) <= 0.000001) return 1000000.0;
	return -view_position.z / view_position.w;
}

void vertex() {
	vec3 camera_right = INV_VIEW_MATRIX[0].xyz;
	camera_right.y = 0.0;
	camera_right = length(camera_right) <= 0.00001 ? vec3(1.0, 0.0, 0.0) : normalize(camera_right);
	vec3 world_up = vec3(0.0, 1.0, 0.0);
	vec3 camera_forward = normalize(cross(camera_right, world_up));
	float instance_scale_x = max(length(MODEL_MATRIX[0].xyz), 0.0001);
	float instance_scale_y = max(length(MODEL_MATRIX[1].xyz), 0.0001);
	float instance_scale_z = max(length(MODEL_MATRIX[2].xyz), 0.0001);
	mat4 billboard_model = mat4(vec4(camera_right * instance_scale_x, 0.0), vec4(world_up * instance_scale_y, 0.0), vec4(camera_forward * instance_scale_z, 0.0), MODEL_MATRIX[3]);
	MODELVIEW_MATRIX = VIEW_MATRIX * billboard_model;
	particle_phase = clamp(INSTANCE_CUSTOM.y, 0.0, 1.0);
	particle_seed = mist_hash12(MODEL_MATRIX[3].xz + vec2(17.31, 43.77));
}

void fragment() {
	vec2 centered_uv = UV * 2.0 - 1.0;
	float horizontal_shape = 1.0 - smoothstep(0.42, 1.0, length(vec2(centered_uv.x, centered_uv.y * 0.72)));
	float bottom_fade = smoothstep(-1.0, -0.68, centered_uv.y);
	vec2 noise_position = UV * vec2(2.45, 1.75) * mist_noise_scale + vec2(particle_seed * 17.71, particle_seed * 9.37);
	float broad_noise = mist_fbm(noise_position);
	float detail_noise = mist_value_noise(noise_position * mist_detail_scale + vec2(31.17, -13.91));
	float top_limit = mix(0.05, 0.72, broad_noise);
	float irregular_top = 1.0 - smoothstep(top_limit - 0.18, top_limit + 0.12, centered_uv.y);
	float density_noise = smoothstep(0.25, 0.72, broad_noise * 0.76 + detail_noise * 0.24);
	float mist_mask = horizontal_shape * bottom_fade * irregular_top * density_noise;
	vec2 micro_uv = UV * vec2(82.0, 46.0) + vec2(particle_seed * 71.0, particle_seed * 37.0);
	vec2 micro_cell = floor(micro_uv);
	vec2 micro_local = fract(micro_uv) - 0.5;
	float micro_random = mist_hash12(micro_cell + vec2(particle_seed * 113.0, particle_seed * 59.0));
	float micro_radius = mix(0.045, 0.105, mist_hash12(micro_cell + vec2(19.17, 47.31)));
	float micro_distance = length(micro_local);
	float micro_antialias = max(fwidth(micro_distance), 0.008);
	float micro_dot = (1.0 - smoothstep(micro_radius - micro_antialias, micro_radius + micro_antialias, micro_distance)) * smoothstep(0.84, 0.97, micro_random);
	float micro_mask = micro_dot * horizontal_shape * bottom_fade * irregular_top;
	float life_fade = smoothstep(0.0, 0.13, particle_phase) * (1.0 - smoothstep(0.70, 1.0, particle_phase));
	float depth_fade = 1.0;
	float scene_raw_depth = texture(depth_texture, SCREEN_UV).r;
	if (scene_raw_depth > 0.000001) {
		depth_fade = clamp((reconstruct_linear_depth(SCREEN_UV, scene_raw_depth) - reconstruct_linear_depth(SCREEN_UV, FRAGCOORD.z)) / max(soft_depth_distance, 0.001), 0.0, 1.0);
	}
	float final_alpha = (mist_mask * mist_opacity + micro_mask * microdrop_strength * 0.58) * mist_intensity * life_fade * depth_fade;
	if (final_alpha <= 0.002) discard;
	ALBEDO = mix(mist_color.rgb, vec3(0.88, 0.94, 1.0), clamp(micro_mask * 0.75, 0.0, 1.0));
	ALPHA = final_alpha;
}
