shader_type spatial;

render_mode skip_vertex_transform, cull_disabled, diffuse_burley, specular_schlick_ggx;


// ============================================================
// TEXTURES
// ============================================================

group_uniforms Textures;

uniform sampler2D tree_tex : source_color;
uniform sampler2D tree_mask;
uniform sampler2D tree_normal;
uniform sampler2D volume_normal;


// ============================================================
// CUTOUT
// ============================================================

group_uniforms Cutout;

uniform float alpha_cutoff : hint_range(0.0, 1.0, 0.01) = 0.45;


// ============================================================
// FAKE VOLUME
// ============================================================

group_uniforms FakeVolume;

uniform float normal_strength : hint_range(0.0, 8.0, 0.05) = 4.0;


// ============================================================
// LEAF COLOR VARIATION
// ============================================================

group_uniforms LeafVariation;

uniform bool invert_leaf_mask = true;

/*
 * OFF:
 *   usa Color Variation manual.
 *
 * ON:
 *   usa INSTANCE_CUSTOM.r.
 *
 * Para tree_impostor.tscn individual -> OFF
 * Para MultiMesh -> ON
 */
uniform bool use_instance_variation = false;

uniform float color_variation : hint_range(0.0, 1.0, 0.01) = 0.5;

uniform float variation_strength :
	hint_range(0.0, 1.0, 0.01) = 0.8;

uniform vec3 variation_a : source_color =
	vec3(1.08, 1.03, 0.82);

uniform vec3 variation_b : source_color =
	vec3(0.78, 0.93, 0.72);


// ============================================================
// TRANSLUCENCY
// ============================================================

group_uniforms Translucency;

uniform float translucency_strength :
	hint_range(0.0, 4.0, 0.01) = 1.25;

uniform float translucency_color_mix :
	hint_range(0.0, 1.0, 0.01) = 0.65;

uniform vec3 translucency_tint : source_color =
	vec3(0.85, 1.0, 0.72);


// ============================================================
// SURFACE
// ============================================================

group_uniforms Surface;

uniform float roughness :
	hint_range(0.0, 1.0, 0.01) = 0.88;

uniform float specular :
	hint_range(0.0, 1.0, 0.01) = 0.08;


// ============================================================
// VARYINGS
// ============================================================

// Base del billboard en View Space.
varying vec3 bb_right_vs;
varying vec3 bb_up_vs;
varying vec3 bb_forward_vs;

// Normales falsas para iluminación.
varying vec3 front_normal_vs_v;
varying vec3 back_normal_vs_v;

// Translucencia.
varying vec3 translucency_color_v;
varying float translucency_mask_v;

// INSTANCE_CUSTOM solo puede leerse directamente en vertex().
varying float instance_variation_v;


// ============================================================
// BLENDER OVERLAY
// ============================================================

vec3 overlay_blend(vec3 base, vec3 blend) {
	vec3 low =
		2.0 * base * blend;

	vec3 high =
		1.0
		- 2.0
		* (1.0 - base)
		* (1.0 - blend);

	return mix(
		low,
		high,
		step(vec3(0.5), base)
	);
}


// ============================================================
// VERTEX
// ============================================================

void vertex() {

	// --------------------------------------------------------
	// CUSTOM DATA DEL MULTIMESH
	// --------------------------------------------------------

	instance_variation_v = INSTANCE_CUSTOM.r;


	// --------------------------------------------------------
	// ORIGEN DE ESTA INSTANCIA
	// --------------------------------------------------------

	vec3 origin_ws = (
		MODEL_MATRIX
		* vec4(0.0, 0.0, 0.0, 1.0)
	).xyz;


	// --------------------------------------------------------
	// CONSERVAR ESCALA INDIVIDUAL
	// --------------------------------------------------------

	/*
	 * MODEL_MATRIX ya contiene el transform de cada instancia
	 * del MultiMesh.
	 *
	 * Como reconstruimos manualmente el billboard,
	 * debemos recuperar su escala.
	 */

	float instance_scale_x =
		length(MODEL_MATRIX[0].xyz);

	float instance_scale_y =
		length(MODEL_MATRIX[1].xyz);


	// --------------------------------------------------------
	// Y-BILLBOARD
	// --------------------------------------------------------

	vec3 world_up =
		vec3(0.0, 1.0, 0.0);

	vec3 to_camera_ws =
		CAMERA_POSITION_WORLD - origin_ws;

	// Solo giramos alrededor de Y.
	to_camera_ws.y = 0.0;

	float flat_length =
		length(to_camera_ws);

	if (flat_length < 0.0001) {
		to_camera_ws =
			vec3(0.0, 0.0, 1.0);
	} else {
		to_camera_ws /=
			flat_length;
	}


	vec3 right_ws = normalize(
		cross(
			world_up,
			to_camera_ws
		)
	);

	vec3 forward_ws = normalize(
		cross(
			right_ws,
			world_up
		)
	);


	// --------------------------------------------------------
	// POSICIÓN DEL QUAD
	// --------------------------------------------------------

	vec3 world_vertex_position =
		origin_ws
		+ right_ws
			* VERTEX.x
			* instance_scale_x
		+ world_up
			* VERTEX.y
			* instance_scale_y;


	vec4 view_position =
		VIEW_MATRIX
		* vec4(
			world_vertex_position,
			1.0
		);

	VERTEX =
		view_position.xyz;


	// --------------------------------------------------------
	// BASE DEL BILLBOARD EN VIEW SPACE
	// --------------------------------------------------------

	bb_right_vs = normalize(
		(
			VIEW_MATRIX
			* vec4(
				right_ws,
				0.0
			)
		).xyz
	);

	bb_up_vs = normalize(
		(
			VIEW_MATRIX
			* vec4(
				world_up,
				0.0
			)
		).xyz
	);

	bb_forward_vs = normalize(
		(
			VIEW_MATRIX
			* vec4(
				forward_ws,
				0.0
			)
		).xyz
	);
}


// ============================================================
// FRAGMENT
// ============================================================

void fragment() {

	// --------------------------------------------------------
	// TEXTURA BASE + CUTOUT
	// --------------------------------------------------------

	vec4 tex =
		texture(
			tree_tex,
			UV
		);

	if (tex.a < alpha_cutoff) {
		discard;
	}


	// --------------------------------------------------------
	// MÁSCARA DE HOJAS
	// --------------------------------------------------------

	float leaf_mask_raw =
		texture(
			tree_mask,
			UV
		).r;

	float leaf_mask =
		invert_leaf_mask
		? 1.0 - leaf_mask_raw
		: leaf_mask_raw;


	// --------------------------------------------------------
	// VARIACIÓN POR INSTANCIA
	// --------------------------------------------------------

	float applied_variation =
		use_instance_variation
		? instance_variation_v
		: color_variation;


	vec3 variant_a =
		tex.rgb
		* variation_a;

	vec3 variant_b =
		tex.rgb
		* variation_b;


	vec3 varied_color =
		mix(
			variant_a,
			variant_b,
			applied_variation
		);


	vec3 final_color =
		mix(
			tex.rgb,
			varied_color,
			leaf_mask
			* variation_strength
		);


	ALBEDO =
		final_color;


	// ========================================================
	// NORMAL FALSA 3D
	// ========================================================

	vec3 volume_n =
		texture(
			volume_normal,
			UV
		).rgb;

	vec3 detail_n =
		texture(
			tree_normal,
			UV
		).rgb;


	/*
	 * Equivalente al MixRGB -> Overlay
	 * del material original de Blender.
	 */
	vec3 combined_rgb =
		overlay_blend(
			volume_n,
			detail_n
		);


	// --------------------------------------------------------
	// NORMAL FRONTAL
	// --------------------------------------------------------

	vec3 front_ts =
		combined_rgb
		* 2.0
		- 1.0;

	front_ts.xy *=
		normal_strength;

	front_ts =
		normalize(front_ts);


	// --------------------------------------------------------
	// NORMAL PARA TRANSLUCENCIA
	//
	// Blender:
	// R = 1 - R
	// G = 1 - G
	// B = B
	// --------------------------------------------------------

	vec3 back_rgb =
		vec3(
			1.0 - combined_rgb.r,
			1.0 - combined_rgb.g,
			combined_rgb.b
		);


	vec3 back_ts =
		back_rgb
		* 2.0
		- 1.0;

	back_ts.xy *=
		normal_strength;

	back_ts =
		normalize(back_ts);


	// --------------------------------------------------------
	// TANGENT SPACE -> VIEW SPACE
	// --------------------------------------------------------

	mat3 tbn_vs =
		mat3(
			normalize(bb_right_vs),
			normalize(bb_up_vs),
			normalize(bb_forward_vs)
		);


	vec3 front_normal_vs =
		normalize(
			tbn_vs
			* front_ts
		);

	vec3 back_normal_vs =
		normalize(
			tbn_vs
			* back_ts
		);


	NORMAL =
		front_normal_vs;

	front_normal_vs_v =
		front_normal_vs;

	back_normal_vs_v =
		back_normal_vs;


	// ========================================================
	// TRANSLUCENCIA
	// ========================================================

	float luminance =
		dot(
			final_color,
			vec3(
				0.299,
				0.587,
				0.114
			)
		);


	/*
	 * Aproximación inicial a la máscara procedural
	 * del Blender.
	 *
	 * Evitamos que la parte inferior/tronco tenga tanta
	 * transmisión como la copa.
	 */
	float canopy_mask =
		smoothstep(
			0.18,
			0.65,
			UV.y
		);


	float trans_mask =
		clamp(
			luminance
			* canopy_mask
			* leaf_mask,
			0.0,
			1.0
		);


	translucency_mask_v =
		trans_mask;


	translucency_color_v =
		mix(
			final_color,
			translucency_tint,
			translucency_color_mix
		);


	// --------------------------------------------------------
	// SURFACE
	// --------------------------------------------------------

	ROUGHNESS =
		roughness;

	SPECULAR =
		specular;
}


// ============================================================
// LIGHT
// ============================================================

void light() {

	vec3 normal_front =
		normalize(
			front_normal_vs_v
		);

	vec3 normal_back =
		normalize(
			back_normal_vs_v
		);


	// --------------------------------------------------------
	// ILUMINACIÓN FRONTAL
	// --------------------------------------------------------

	float front_term =
		max(
			dot(
				normal_front,
				LIGHT
			),
			0.0
		);


	vec3 diffuse_contribution =
		ALBEDO
		* LIGHT_COLOR.rgb
		* ATTENUATION
		* front_term;


	// --------------------------------------------------------
	// TRANSLUCENCIA / CONTRALUZ
	// --------------------------------------------------------

	float back_term =
		max(
			dot(
				normal_back,
				-LIGHT
			),
			0.0
		);


	vec3 translucency_contribution =
		translucency_color_v
		* LIGHT_COLOR.rgb
		* ATTENUATION
		* back_term
		* translucency_mask_v
		* translucency_strength;


	DIFFUSE_LIGHT +=
		diffuse_contribution
		+ translucency_contribution;
}