shader_type spatial;
render_mode unshaded, blend_mix, cull_disabled, depth_draw_never, fog_disabled;

uniform vec4 streak_color : source_color = vec4(0.70, 0.82, 0.92, 0.70);

void vertex() {
	MODELVIEW_MATRIX = VIEW_MATRIX * mat4(INV_VIEW_MATRIX[0], INV_VIEW_MATRIX[1], INV_VIEW_MATRIX[2], MODEL_MATRIX[3]);
}

void fragment() {
	float lateral = smoothstep(0.0, 0.28, UV.x) * (1.0 - smoothstep(0.72, 1.0, UV.x));
	float ends = smoothstep(0.0, 0.10, UV.y) * (1.0 - smoothstep(0.82, 1.0, UV.y));
	float alpha = lateral * ends * streak_color.a;
	if (alpha < 0.01) discard;
	ALBEDO = streak_color.rgb;
	ALPHA = alpha;
}
