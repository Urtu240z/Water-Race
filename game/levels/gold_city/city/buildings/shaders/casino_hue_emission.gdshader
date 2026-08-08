shader_type spatial;
render_mode diffuse_burley, specular_schlick_ggx;

group_uniforms Surface;
uniform vec4 albedo_color : source_color = vec4(1.0, 1.0, 1.0, 1.0);
uniform float roughness : hint_range(0.0, 1.0, 0.01) = 0.5;
uniform float metallic : hint_range(0.0, 1.0, 0.01) = 0.0;

group_uniforms AnimatedEmission;
uniform vec4 emission_color : source_color = vec4(1.0, 0.1904, 0.7563, 1.0);
uniform float emission_energy : hint_range(0.0, 32.0, 0.05) = 5.87;
// Complete hue rotations per second. 0.05 gives one revolution every 20 seconds.
uniform float hue_speed : hint_range(-1.0, 1.0, 0.005) = 0.05;
uniform float hue_offset : hint_range(0.0, 1.0, 0.005) = 0.0;
uniform float saturation_multiplier : hint_range(0.0, 2.0, 0.01) = 1.0;
uniform float brightness_multiplier : hint_range(0.0, 4.0, 0.01) = 1.0;
group_uniforms;

vec3 rgb_to_hsv(vec3 color) {
	vec4 k = vec4(0.0, -1.0 / 3.0, 2.0 / 3.0, -1.0);
	vec4 p = mix(vec4(color.bg, k.wz), vec4(color.gb, k.xy), step(color.b, color.g));
	vec4 q = mix(vec4(p.xyw, color.r), vec4(color.r, p.yzx), step(p.x, color.r));
	float delta = q.x - min(q.w, q.y);
	float epsilon = 1.0e-10;
	return vec3(abs(q.z + (q.w - q.y) / (6.0 * delta + epsilon)), delta / (q.x + epsilon), q.x);
}

vec3 hsv_to_rgb(vec3 color) {
	vec3 rgb = clamp(abs(mod(color.x * 6.0 + vec3(0.0, 4.0, 2.0), 6.0) - 3.0) - 1.0, 0.0, 1.0);
	return color.z * mix(vec3(1.0), rgb, color.y);
}

void fragment() {
	vec3 hsv = rgb_to_hsv(emission_color.rgb);
	hsv.x = fract(hsv.x + hue_offset + TIME * hue_speed);
	hsv.y = clamp(hsv.y * saturation_multiplier, 0.0, 1.0);
	hsv.z *= brightness_multiplier;
	vec3 animated_emission = hsv_to_rgb(hsv);

	ALBEDO = albedo_color.rgb;
	METALLIC = metallic;
	ROUGHNESS = roughness;
	EMISSION = animated_emission * emission_energy;
}
