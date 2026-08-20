shader_type canvas_item;
render_mode blend_premul_alpha, unshaded;

// Premultiplied-alpha blending uses a source factor of one. R/G therefore reach
// the target without being scaled by A, while destination attenuation provides
// a bounded saturating union for overlaps. A itself becomes bounded intensity
// reinforcement: new + old * (1 - new).
void fragment() {
	vec4 stamp = texture(TEXTURE, UV);
	float source_intensity = clamp(COLOR.b, 0.0, 1.0);
	if (stamp.g <= 0.001 || source_intensity <= 0.0) {
		COLOR = vec4(0.0);
	} else {
		COLOR = vec4(
			stamp.r,
			stamp.g,
			0.0,
			source_intensity
		);
	}
}
