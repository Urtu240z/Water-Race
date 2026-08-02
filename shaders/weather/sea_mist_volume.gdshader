shader_type fog;

uniform float mist_density : hint_range(0.0, 1.0, 0.01) = 0.42;
uniform float mist_opacity : hint_range(0.0, 1.0, 0.01) = 0.0;
uniform vec4 mist_color : source_color = vec4(0.66, 0.74, 0.80, 1.0);
uniform float mist_height : hint_range(0.0, 2.0, 0.01) = 0.75;
uniform float mist_height_noise_strength : hint_range(0.0, 1.5, 0.01) = 0.28;
uniform float mist_height_falloff : hint_range(0.1, 4.0, 0.01) = 1.45;
uniform float mist_noise_scale : hint_range(0.1, 20.0, 0.1) = 2.6;
uniform float mist_detail_scale : hint_range(0.1, 40.0, 0.1) = 9.0;
uniform float mist_wind_speed : hint_range(0.0, 4.0, 0.05) = 0.55;
uniform vec2 mist_wind_direction = vec2(0.92, 0.38);
uniform float mist_near_strength : hint_range(0.0, 1.0, 0.01) = 1.0;
uniform float mist_far_strength : hint_range(0.0, 1.0, 0.01) = 0.55;

float hash(vec3 p) { return fract(sin(dot(p, vec3(127.1, 311.7, 74.7))) * 43758.5453); }
float noise(vec3 p) {
	vec3 i = floor(p); vec3 f = fract(p); f = f * f * (3.0 - 2.0 * f);
	return mix(mix(mix(hash(i), hash(i + vec3(1,0,0)), f.x), mix(hash(i + vec3(0,1,0)), hash(i + vec3(1,1,0)), f.x), f.y), mix(mix(hash(i + vec3(0,0,1)), hash(i + vec3(1,0,1)), f.x), mix(hash(i + vec3(0,1,1)), hash(i + vec3(1)), f.x), f.y), f.z);
}
void fog() {
	vec2 wind = normalize(mist_wind_direction + vec2(0.0001));
	vec3 p = WORLD_POSITION * 0.08 + vec3(wind.x, 0.0, wind.y) * TIME * mist_wind_speed * 0.04;
	float masses = noise(p * mist_noise_scale * 0.12);
	float detail = noise(p * mist_detail_scale * 0.05 + vec3(17.3, 0.0, 9.1));
	float top = mist_height + (masses - 0.5) * mist_height_noise_strength;
	float height_mask = 1.0 - smoothstep(top * 0.55, max(top, 0.001), WORLD_POSITION.y - CAMERA_POSITION_WORLD.y + mist_height * 0.5);
	float broken = smoothstep(0.30, 0.75, masses * 0.72 + detail * 0.28);
	DENSITY = mist_density * mist_opacity * height_mask * broken;
	ALBEDO = mist_color.rgb;
}
