shader_type spatial;
render_mode unshaded, blend_mix, cull_front, depth_draw_never, fog_disabled;

uniform float storm_intensity : hint_range(0.0, 1.0) = 0.0;
uniform vec2 wind_direction = vec2(0.92, 0.38);
uniform float wind_speed : hint_range(0.0, 0.1) = 0.012;
uniform int quality_octaves : hint_range(1, 4, 1) = 4;
uniform vec3 clear_cloud_color : source_color = vec3(0.52, 0.58, 0.68);
uniform vec3 storm_cloud_color : source_color = vec3(0.055, 0.075, 0.11);
uniform float maximum_opacity : hint_range(0.0, 1.0) = 0.92;

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453123);
}

float value_noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash(i), hash(i + vec2(1.0, 0.0)), f.x), mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0)), f.x), f.y);
}

float fbm(vec2 p) {
	float value = 0.0;
	float amplitude = 0.5;
	for (int octave = 0; octave < 4; octave++) {
		if (octave >= quality_octaves) {
			break;
		}
		value += value_noise(p) * amplitude;
		p = p * 2.03 + vec2(17.3, 9.2);
		amplitude *= 0.5;
	}
	return value;
}

void fragment() {
	vec3 local_direction = normalize(VERTEX);
	vec2 horizontal_direction = normalize(local_direction.xz + vec2(0.0001));
	vec2 wind = normalize(wind_direction);
	vec2 drift = wind * TIME * wind_speed;
	float large_noise = fbm(horizontal_direction * 2.2 + drift);
	float detail_noise = fbm(horizontal_direction * 6.4 - drift * 0.43);
	float cloud_noise = large_noise * 0.78 + detail_noise * 0.22;
	float front_coordinate = dot(horizontal_direction, wind);
	float front_threshold = mix(1.03, -1.05, storm_intensity);
	float front_mask = smoothstep(front_threshold, front_threshold + 0.24, front_coordinate);
	float coverage_threshold = mix(0.78, 0.40, storm_intensity);
	float cloud_mask = smoothstep(coverage_threshold, coverage_threshold + 0.18, cloud_noise);
	float vertical_mask = smoothstep(-0.04, 0.18, local_direction.y);
	float alpha = cloud_mask * front_mask * vertical_mask * maximum_opacity;
	vec3 color = mix(clear_cloud_color, storm_cloud_color, storm_intensity);
	color *= mix(0.78, 1.08, cloud_noise);
	ALBEDO = color;
	ALPHA = alpha;
}
