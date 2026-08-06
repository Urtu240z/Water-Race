shader_type spatial;
render_mode cull_disabled;

uniform sampler2D albedo_texture : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform vec4 albedo_tint : source_color = vec4(1.0);
uniform float roughness : hint_range(0.0, 1.0, 0.01) = 0.5;

uniform bool use_uv2 = false;
uniform bool swap_uv_axes = false;
uniform vec2 uv_scale = vec2(1.0);
uniform vec2 uv_offset = vec2(0.0);
uniform float uv_speed : hint_range(-4.0, 4.0, 0.01) = -0.6;

uniform float emission_min : hint_range(0.0, 32.0, 0.1) = 4.0;
uniform float emission_max : hint_range(0.0, 32.0, 0.1) = 12.0;
uniform float pulse_speed : hint_range(0.0, 20.0, 0.01) = 4.48799;


void fragment() {
	vec2 source_uv = use_uv2 ? UV2 : UV;
	if (swap_uv_axes) {
		source_uv = source_uv.yx;
	}

	vec2 moving_uv = source_uv * uv_scale + uv_offset;
	moving_uv.x += TIME * uv_speed;
	vec4 texture_color = texture(albedo_texture, moving_uv);

	float pulse = sin(TIME * pulse_speed) * 0.5 + 0.5;
	float emission_strength = mix(emission_min, emission_max, pulse);
	vec3 tinted_color = texture_color.rgb * albedo_tint.rgb;

	ALBEDO = tinted_color;
	ROUGHNESS = roughness;
	EMISSION = tinted_color * emission_strength;
}
