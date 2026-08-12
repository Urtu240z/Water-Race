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
// SPECIES
// ============================================================

group_uniforms Species;

uniform bool use_instance_species = true;

uniform float manual_species :
	hint_range(0.0, 8.0, 1.0) = 0.0;

uniform float weight_beech_a :
	hint_range(0.0, 100.0, 0.1) = 15.0;

uniform float weight_beech_b :
	hint_range(0.0, 100.0, 0.1) = 10.0;

uniform float weight_fir_a :
	hint_range(0.0, 100.0, 0.1) = 10.0;

uniform float weight_fir_b :
	hint_range(0.0, 100.0, 0.1) = 5.0;

uniform float weight_linden_a :
	hint_range(0.0, 100.0, 0.1) = 20.0;

uniform float weight_linden_b :
	hint_range(0.0, 100.0, 0.1) = 10.0;

uniform float weight_linden_c :
	hint_range(0.0, 100.0, 0.1) = 10.0;

uniform float weight_oak_a :
	hint_range(0.0, 100.0, 0.1) = 15.0;

uniform float weight_oak_b :
	hint_range(0.0, 100.0, 0.1) = 5.0;


// ============================================================
// IMPOSTOR DEPTH
// ============================================================

group_uniforms ImpostorDepth;

uniform bool use_impostor_depth = true;

uniform float depth_strength :
	hint_range(0.0, 1.5, 0.01) = 0.55;

uniform float depth_curve :
	hint_range(0.20, 3.0, 0.05) = 0.50;

uniform float trunk_depth_factor :
	hint_range(0.0, 1.0, 0.01) = 0.20;


// ============================================================
// CUTOUT
// ============================================================

group_uniforms Cutout;

uniform float alpha_cutoff :
	hint_range(0.0, 1.0, 0.01) = 0.45;


// ============================================================
// FAKE VOLUME
// ============================================================

group_uniforms FakeVolume;

uniform float normal_strength :
	hint_range(0.0, 8.0, 0.05) = 4.0;


// ============================================================
// LEAF COLOR VARIATION
// ============================================================

group_uniforms LeafVariation;

uniform bool invert_leaf_mask = true;

uniform bool use_instance_variation = false;

uniform float color_variation :
	hint_range(0.0, 1.0, 0.01) = 0.5;

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
// FINAL COLOR
// ============================================================

group_uniforms FinalColor;

uniform float final_saturation :
	hint_range(0.0, 2.0, 0.01) = 1.0;

uniform float final_brightness :
	hint_range(0.0, 2.0, 0.01) = 1.0;

uniform float final_contrast :
	hint_range(0.0, 2.0, 0.01) = 1.0;


// ============================================================
// VARYINGS
// ============================================================

varying vec3 bb_right_vs;
varying vec3 bb_up_vs;
varying vec3 bb_forward_vs;

varying vec3 front_normal_vs_v;
varying vec3 back_normal_vs_v;

varying vec3 translucency_color_v;
varying float translucency_mask_v;

varying float instance_variation_v;

varying vec2 atlas_cell_v;

varying float instance_radius_v;


// ============================================================
// HELPERS
// ============================================================

vec3 overlay_blend(
	vec3 base,
	vec3 blend
) {
	vec3 low =
		2.0
		* base
		* blend;

	vec3 high =
		1.0
		- 2.0
		* (1.0 - base)
		* (1.0 - blend);

	return mix(
		low,
		high,
		step(
			vec3(0.5),
			base
		)
	);
}


float hash11(
	float value
) {
	float p =
		fract(
			value
			* 0.1031
		);

	p *=
		p
		+ 33.33;

	p *=
		p
		+ p;

	return fract(p);
}


float choose_weighted_species(
	float random_value
) {
	float w0 =
		max(
			weight_beech_a,
			0.0
		);

	float w1 =
		max(
			weight_beech_b,
			0.0
		);

	float w2 =
		max(
			weight_fir_a,
			0.0
		);

	float w3 =
		max(
			weight_fir_b,
			0.0
		);

	float w4 =
		max(
			weight_linden_a,
			0.0
		);

	float w5 =
		max(
			weight_linden_b,
			0.0
		);

	float w6 =
		max(
			weight_linden_c,
			0.0
		);

	float w7 =
		max(
			weight_oak_a,
			0.0
		);

	float w8 =
		max(
			weight_oak_b,
			0.0
		);

	float total =
		w0
		+ w1
		+ w2
		+ w3
		+ w4
		+ w5
		+ w6
		+ w7
		+ w8;

	if (total <= 0.00001) {
		return 0.0;
	}

	float target =
		clamp(
			random_value,
			0.0,
			0.999999
		)
		* total;

	float cumulative =
		w0;

	if (target < cumulative) {
		return 0.0;
	}

	cumulative +=
		w1;

	if (target < cumulative) {
		return 1.0;
	}

	cumulative +=
		w2;

	if (target < cumulative) {
		return 2.0;
	}

	cumulative +=
		w3;

	if (target < cumulative) {
		return 3.0;
	}

	cumulative +=
		w4;

	if (target < cumulative) {
		return 4.0;
	}

	cumulative +=
		w5;

	if (target < cumulative) {
		return 5.0;
	}

	cumulative +=
		w6;

	if (target < cumulative) {
		return 6.0;
	}

	cumulative +=
		w7;

	if (target < cumulative) {
		return 7.0;
	}

	return 8.0;
}


vec2 species_to_cell(
	float species_index
) {
	float safe_index =
		clamp(
			floor(
				species_index
				+ 0.5
			),
			0.0,
			8.0
		);

	float column =
		mod(
			safe_index,
			3.0
		);

	float row =
		floor(
			safe_index
			/ 3.0
		);

	return vec2(
		column,
		row
	);
}


vec2 get_atlas_uv(
	vec2 local_uv
) {
	const float padding_ratio =
		1.0
		/ 32.0;

	vec2 padded_uv =
		mix(
			vec2(
				padding_ratio
			),
			vec2(
				1.0
				- padding_ratio
			),
			local_uv
		);

	return (
		atlas_cell_v
		+ padded_uv
	) / 3.0;
}


float get_round_depth_profile(
	vec2 local_uv
) {
	float normalized_x =
		local_uv.x
		* 2.0
		- 1.0;

	float radius_squared =
		normalized_x
		* normalized_x;

	float inside =
		max(
			1.0
				- radius_squared,
			0.0
		);

	return pow(
		inside,
		max(
			depth_curve,
			0.001
		)
	);
}


float view_position_to_depth(
	vec3 view_position,
	mat4 projection_matrix
) {
	vec4 clip_position =
		projection_matrix
		* vec4(
			view_position,
			1.0
		);

	return clamp(
		clip_position.z
			/ clip_position.w,
		0.0,
		1.0
	);
}


vec3 apply_final_color_adjustments(
	vec3 color
) {
	float color_luminance =
		dot(
			color,
			vec3(
				0.2126,
				0.7152,
				0.0722
			)
		);

	vec3 grayscale =
		vec3(
			color_luminance
		);

	color =
		mix(
			grayscale,
			color,
			final_saturation
		);

	color =
		(
			color
			- vec3(0.5)
		)
		* final_contrast
		+ vec3(0.5);

	color *=
		final_brightness;

	return max(
		color,
		vec3(0.0)
	);
}


// ============================================================
// VERTEX
// ============================================================

void vertex() {
	instance_variation_v =
		INSTANCE_CUSTOM.r;

	float species_index =
		clamp(
			manual_species,
			0.0,
			8.0
		);

	if (use_instance_species) {
		float species_random =
			hash11(
				INSTANCE_CUSTOM.r
				+ 0.3719
			);

		species_index =
			choose_weighted_species(
				species_random
			);
	}

	atlas_cell_v =
		species_to_cell(
			species_index
		);

	vec3 origin_ws = (
		MODEL_MATRIX
		* vec4(
			0.0,
			0.0,
			0.0,
			1.0
		)
	).xyz;

	float instance_scale_x =
		length(
			MODEL_MATRIX[
				0
			].xyz
		);

	float instance_scale_y =
		length(
			MODEL_MATRIX[
				1
			].xyz
		);

	instance_radius_v =
		instance_scale_x;

	vec3 world_up =
		vec3(
			0.0,
			1.0,
			0.0
		);

	vec3 to_camera_ws =
		CAMERA_POSITION_WORLD
		- origin_ws;

	to_camera_ws.y =
		0.0;

	float flat_length =
		length(
			to_camera_ws
		);

	if (flat_length < 0.0001) {
		to_camera_ws =
			vec3(
				0.0,
				0.0,
				1.0
			);
	} else {
		to_camera_ws /=
			flat_length;
	}

	vec3 right_ws =
		normalize(
			cross(
				world_up,
				to_camera_ws
			)
		);

	vec3 forward_ws =
		normalize(
			cross(
				right_ws,
				world_up
			)
		);

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

	bb_right_vs =
		normalize(
			(
				VIEW_MATRIX
				* vec4(
					right_ws,
					0.0
				)
			).xyz
		);

	bb_up_vs =
		normalize(
			(
				VIEW_MATRIX
				* vec4(
					world_up,
					0.0
				)
			).xyz
		);

	bb_forward_vs =
		normalize(
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
	vec2 atlas_uv =
		get_atlas_uv(
			UV
		);

	vec4 tex =
		texture(
			tree_tex,
			atlas_uv
		);

	if (tex.a < alpha_cutoff) {
		discard;
	}


	// ========================================================
	// LEAF MASK
	// ========================================================

	float leaf_mask_raw =
		texture(
			tree_mask,
			atlas_uv
		).r;

	float leaf_mask =
		invert_leaf_mask
		? 1.0
			- leaf_mask_raw
		: leaf_mask_raw;


	// ========================================================
	// IMPOSTOR DEPTH
	// ========================================================

	if (use_impostor_depth) {
		float round_profile =
			get_round_depth_profile(
				UV
			);

		float vegetation_depth_factor =
			mix(
				trunk_depth_factor,
				1.0,
				leaf_mask
			);

		float depth_offset =
			round_profile
			* instance_radius_v
			* depth_strength
			* vegetation_depth_factor;

		vec3 pseudo_surface_position =
			VERTEX
			+ normalize(
				VIEW
			)
			* depth_offset;

		DEPTH =
			view_position_to_depth(
				pseudo_surface_position,
				PROJECTION_MATRIX
			);
	} else {
		DEPTH =
			FRAGCOORD.z;
	}


	// ========================================================
	// LEAF COLOR VARIATION
	// ========================================================

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

	final_color =
		apply_final_color_adjustments(
			final_color
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
			atlas_uv
		).rgb;

	vec3 combined_rgb =
		overlay_blend(
			volume_n,
			detail_n
		);

	vec3 front_ts =
		combined_rgb
		* 2.0
		- 1.0;

	front_ts.xy *=
		normal_strength;

	front_ts =
		normalize(
			front_ts
		);

	vec3 back_rgb =
		vec3(
			1.0
				- combined_rgb.r,
			1.0
				- combined_rgb.g,
			combined_rgb.b
		);

	vec3 back_ts =
		back_rgb
		* 2.0
		- 1.0;

	back_ts.xy *=
		normal_strength;

	back_ts =
		normalize(
			back_ts
		);

	mat3 tbn_vs =
		mat3(
			normalize(
				bb_right_vs
			),
			normalize(
				bb_up_vs
			),
			normalize(
				bb_forward_vs
			)
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
	// TRANSLUCENCY
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


	// ========================================================
	// SURFACE
	// ========================================================

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