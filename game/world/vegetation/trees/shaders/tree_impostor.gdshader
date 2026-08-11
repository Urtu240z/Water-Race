shader_type spatial;

render_mode cull_disabled, diffuse_burley, specular_schlick_ggx;


group_uniforms Textures;

uniform sampler2D tree_tex : source_color;
uniform sampler2D tree_mask;
uniform sampler2D tree_normal;
uniform sampler2D volume_normal;


group_uniforms Cutout;

uniform float alpha_cutoff : hint_range(0.0, 1.0, 0.01) = 0.45;


group_uniforms FakeVolume;

uniform float normal_strength : hint_range(0.0, 8.0, 0.05) = 4.0;


group_uniforms LeafVariation;

uniform float color_variation : hint_range(0.0, 1.0, 0.01) = 0.5;
uniform float variation_strength : hint_range(0.0, 1.0, 0.01) = 0.8;

uniform vec3 variation_a : source_color = vec3(1.08, 1.03, 0.82);
uniform vec3 variation_b : source_color = vec3(0.78, 0.93, 0.72);


group_uniforms Surface;

uniform float roughness : hint_range(0.0, 1.0, 0.01) = 0.85;
uniform float specular : hint_range(0.0, 1.0, 0.01) = 0.15;


// Blender MixRGB -> Overlay.
// Los valores entran y salen en rango 0..1.
vec3 overlay_blend(vec3 base, vec3 blend) {
	vec3 low = 2.0 * base * blend;
	vec3 high = 1.0 - 2.0 * (1.0 - base) * (1.0 - blend);

	return mix(
		low,
		high,
		step(vec3(0.5), base)
	);
}


void fragment() {
	vec4 tex = texture(tree_tex, UV);

	// Alpha Scissor manual.
	// Así evitamos alpha blending y mantenemos el árbol como cutout.
	if (tex.a < alpha_cutoff) {
		discard;
	}

	// ------------------------------------------------
	// VARIACIÓN DE COLOR
	// ------------------------------------------------

	float leaf_mask = texture(tree_mask, UV).r;

	vec3 variant_a = tex.rgb * variation_a;
	vec3 variant_b = tex.rgb * variation_b;

	vec3 varied_color = mix(
		variant_a,
		variant_b,
		color_variation
	);

	vec3 final_color = mix(
		tex.rgb,
		varied_color,
		leaf_mask * variation_strength
	);

	ALBEDO = final_color;


	// ------------------------------------------------
	// NORMAL FALSA 3D
	// ------------------------------------------------

	vec3 volume_n = texture(volume_normal, UV).rgb;
	vec3 detail_n = texture(tree_normal, UV).rgb;

	// Igual que el Overlay del material de Blender:
	// normal de volumen + normal particular del árbol.
	vec3 combined_normal = overlay_blend(
		volume_n,
		detail_n
	);

	NORMAL_MAP = combined_normal;
	NORMAL_MAP_DEPTH = normal_strength;


	ROUGHNESS = roughness;
	SPECULAR = specular;
}