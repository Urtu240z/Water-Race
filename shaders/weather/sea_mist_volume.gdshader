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
float mist_hash13(vec3 value) { value = fract(value * 0.1031); value += dot(value, value.yzx + 33.33); return fract((value.x + value.y) * value.z); }
float mist_value_noise(vec3 value) { vec3 cell = floor(value); vec3 f = fract(value); f = f * f * (3.0 - 2.0 * f); return mix(mix(mix(mist_hash13(cell), mist_hash13(cell + vec3(1,0,0)), f.x), mix(mist_hash13(cell + vec3(0,1,0)), mist_hash13(cell + vec3(1,1,0)), f.x), f.y), mix(mix(mist_hash13(cell + vec3(0,0,1)), mist_hash13(cell + vec3(1,0,1)), f.x), mix(mist_hash13(cell + vec3(0,1,1)), mist_hash13(cell + vec3(1,1,1)), f.x), f.y), f.z); }
float mist_fbm(vec3 value) { float result = mist_value_noise(value) * 0.57; value = value * 2.03 + vec3(17.13,7.71,11.37); result += mist_value_noise(value) * 0.285; value = value * 2.11 + vec3(-9.17,13.91,5.73); return result + mist_value_noise(value) * 0.1425; }
void fog() { vec2 wind = length(mist_wind_direction) <= 0.0001 ? vec2(1.0,0.0) : normalize(mist_wind_direction); vec3 world_sample_position = WORLD_POSITION + vec3(wind.x,0.0,wind.y) * TIME * mist_wind_speed; float masses = mist_fbm(vec3(world_sample_position.x / max(mist_noise_scale,0.05), world_sample_position.y / max(mist_noise_scale * 0.55,0.05), world_sample_position.z / max(mist_noise_scale,0.05))); float detail = mist_value_noise(world_sample_position / max(mist_detail_scale,0.05) + vec3(19.17,7.31,-13.73)); float combined_noise = clamp(masses * 0.74 + detail * 0.26, 0.0, 1.0); float volume_bottom_y = OBJECT_POSITION.y - SIZE.y * 0.5; float top = max(mist_height + (combined_noise - 0.5) * 2.0 * mist_height_noise_strength, 0.05); float height_mask = pow(clamp(1.0 - smoothstep(0.38, 1.0, max(WORLD_POSITION.y - volume_bottom_y, 0.0) / top), 0.0, 1.0), max(mist_height_falloff, 0.01)); DENSITY = max(mist_density * mist_opacity * height_mask * smoothstep(0.27,0.72,combined_noise) * smoothstep(0.0,0.75,-SDF), 0.0); ALBEDO = mist_color.rgb; EMISSION = vec3(0.0); }
