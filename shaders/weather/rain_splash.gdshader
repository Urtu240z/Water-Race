shader_type spatial;
render_mode unshaded, blend_mix, cull_disabled, depth_draw_never, fog_disabled;

uniform vec4 splash_color : source_color = vec4(0.76, 0.88, 0.96, 0.62);

void vertex() {
	MODELVIEW_MATRIX = VIEW_MATRIX * mat4(INV_VIEW_MATRIX[0], INV_VIEW_MATRIX[1], INV_VIEW_MATRIX[2], MODEL_MATRIX[3]);
}

void fragment() {
	float radius = length(UV - vec2(0.5)) * 2.0;
	float ring = smoothstep(0.42, 0.50, radius) * (1.0 - smoothstep(0.78, 0.96, radius));
	float alpha = ring * splash_color.a * COLOR.a;
	if (alpha < 0.01) discard;
	ALBEDO = splash_color.rgb;
	ALPHA = alpha;
}
