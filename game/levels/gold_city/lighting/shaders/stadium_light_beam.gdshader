shader_type spatial;
render_mode blend_add, depth_draw_never, cull_disabled, unshaded, shadows_disabled;


group_uniforms Beam;
uniform vec4 light_color : source_color = vec4(0.8128, 0.8308, 0.6756, 1.0);
uniform float beam_opacity : hint_range(0.0, 1.0, 0.005) = 0.14;
uniform float emission_energy : hint_range(0.0, 12.0, 0.05) = 2.2;
uniform float base_density : hint_range(0.0, 1.0, 0.01) = 0.32;


group_uniforms SoftEdges;
uniform float edge_fade_start : hint_range(0.0, 0.9, 0.01) = 0.02;
uniform float edge_fade_end : hint_range(0.01, 1.0, 0.01) = 0.34;
uniform float edge_fade_power : hint_range(0.25, 4.0, 0.05) = 1.25;
uniform float near_fade_end : hint_range(0.001, 0.4, 0.005) = 0.055;
uniform float far_fade_start : hint_range(0.4, 0.999, 0.005) = 0.73;
uniform float length_falloff : hint_range(0.0, 4.0, 0.05) = 0.75;


group_uniforms SoftIntersection;
uniform sampler2D scene_depth_texture : hint_depth_texture, repeat_disable, filter_nearest;
uniform float intersection_fade_strength : hint_range(0.0, 1.0, 0.01) = 1.0;
uniform float intersection_fade_distance : hint_range(0.05, 20.0, 0.05) = 4.0;
uniform float intersection_fade_power : hint_range(0.25, 4.0, 0.05) = 1.0;


/*
 * El agua transparente no aparece de forma fiable en scene_depth_texture.
 *
 * Por eso hacemos un segundo soft intersection usando la altura mundial
 * del agua.
 *
 * water_surface_y debe coincidir con el water_level del Ocean.
 *
 * water_surface_margin permite subir ligeramente el punto de corte para
 * compensar las olas sin tener que duplicar todo el cálculo de oleaje.
 */
group_uniforms WaterIntersection;
uniform bool water_intersection_enabled = true;
uniform float water_surface_y : hint_range(-20.0, 20.0, 0.05) = 0.0;
uniform float water_surface_margin : hint_range(-5.0, 5.0, 0.05) = 0.0;
uniform float water_intersection_fade_strength : hint_range(0.0, 1.0, 0.01) = 1.0;
uniform float water_intersection_fade_distance : hint_range(0.05, 20.0, 0.05) = 2.5;
uniform float water_intersection_fade_power : hint_range(0.25, 4.0, 0.05) = 1.0;


group_uniforms MovingDust;
uniform float dust_strength : hint_range(0.0, 4.0, 0.05) = 1.35;
uniform float dust_scale : hint_range(0.01, 2.0, 0.01) = 0.16;
uniform float dust_detail : hint_range(0.1, 8.0, 0.05) = 2.65;
uniform float dust_threshold : hint_range(0.0, 0.95, 0.01) = 0.56;
uniform float dust_softness : hint_range(0.01, 0.5, 0.01) = 0.22;
uniform vec3 dust_velocity = vec3(0.10, -0.34, -0.16);

group_uniforms;


varying vec3 beam_local_position;
varying vec3 beam_world_position;


// Cheap, texture-free pseudo-volume.
// It stays continuous across the cone UV seam.
float drifting_field(vec3 position) {
	float wave_a = sin(
		dot(position, vec3(1.31, 2.17, 0.73))
	);

	float wave_b = sin(
		dot(position, vec3(-0.83, 1.71, 2.41))
		+ wave_a * 1.65
	);

	float wave_c = sin(
		dot(position, vec3(2.31, -0.57, 1.19))
		+ wave_b * 1.25
	);

	return clamp(
		0.5
		+ 0.5
		* (
			wave_a * 0.38
			+ wave_b * 0.37
			+ wave_c * 0.25
		),
		0.0,
		1.0
	);
}


// Soft-particle style depth fade.
//
// The beam becomes transparent before its geometry reaches the first
// opaque surface stored in the scene depth buffer.
float scene_linear_depth(
	vec2 screen_uv,
	mat4 inverse_projection
) {
	float raw_depth = texture(
		scene_depth_texture,
		screen_uv
	).r;

	vec3 ndc_position = vec3(
		screen_uv * 2.0 - 1.0,
		raw_depth
	);

	vec4 view_position =
		inverse_projection
		* vec4(ndc_position, 1.0);

	view_position.xyz /= view_position.w;

	return -view_position.z;
}


void vertex() {
	// Position used by the moving volumetric dust.
	beam_local_position = VERTEX;

	// Keep the original world-space position of the beam geometry.
	// This is what lets us compare the beam directly against water Y.
	beam_world_position = (
		MODEL_MATRIX
		* vec4(VERTEX, 1.0)
	).xyz;
}


void fragment() {
	float longitudinal = clamp(
		UV.y,
		0.0,
		1.0
	);


	// ------------------------------------------------------------
	// LENGTH FADES
	// ------------------------------------------------------------

	// Fade the emitter and, especially, the open end so neither cut
	// is visible.
	float near_fade = smoothstep(
		0.0,
		max(near_fade_end, 0.0001),
		longitudinal
	);

	float far_fade =
		1.0
		- smoothstep(
			far_fade_start,
			1.0,
			longitudinal
		);

	float distance_fade = pow(
		max(
			1.0 - longitudinal,
			0.0
		),
		length_falloff
	);


	// ------------------------------------------------------------
	// SILHOUETTE SOFTENING
	// ------------------------------------------------------------

	// Removes the hard polygonal outline from every camera angle.
	float facing = abs(
		dot(
			normalize(NORMAL),
			normalize(VIEW)
		)
	);

	float soft_edge = smoothstep(
		edge_fade_start,
		max(
			edge_fade_end,
			edge_fade_start + 0.001
		),
		facing
	);

	soft_edge = pow(
		max(
			soft_edge,
			0.0
		),
		edge_fade_power
	);


	// ------------------------------------------------------------
	// MOVING DUST
	// ------------------------------------------------------------

	vec3 movement =
		dust_velocity
		* TIME;

	vec3 coarse_position =
		beam_local_position
		* dust_scale
		+ movement;

	vec3 fine_position =
		beam_local_position
		* dust_scale
		* dust_detail
		- movement * 1.37;

	float coarse_dust =
		drifting_field(
			coarse_position
		);

	float fine_dust =
		drifting_field(
			fine_position
		);

	float dust_field = mix(
		coarse_dust,
		fine_dust,
		0.34
	);

	float dust = smoothstep(
		dust_threshold,
		min(
			dust_threshold
			+ max(
				dust_softness,
				0.001
			),
			1.0
		),
		dust_field
	);

	float density =
		base_density
		+ dust * dust_strength;


	// ------------------------------------------------------------
	// OPAQUE SCENE SOFT INTERSECTION
	// ------------------------------------------------------------

	float opaque_depth =
		scene_linear_depth(
			SCREEN_UV,
			INV_PROJECTION_MATRIX
		);

	// VERTEX is view-space position in fragment().
	float beam_depth = max(
		-VERTEX.z,
		0.0
	);

	float surface_gap =
		opaque_depth
		- beam_depth;

	float intersection_fade = smoothstep(
		0.0,
		max(
			intersection_fade_distance,
			0.0001
		),
		surface_gap
	);

	intersection_fade = pow(
		clamp(
			intersection_fade,
			0.0,
			1.0
		),
		intersection_fade_power
	);

	intersection_fade = mix(
		1.0,
		intersection_fade,
		intersection_fade_strength
	);


	// ------------------------------------------------------------
	// WATER SOFT INTERSECTION
	// ------------------------------------------------------------

	float water_intersection_fade = 1.0;

	if (water_intersection_enabled) {
		float effective_water_height =
			water_surface_y
			+ water_surface_margin;

		/*
		 * Positive:
		 * beam fragment is above the water.
		 *
		 * Zero:
		 * beam reaches the water.
		 *
		 * Negative:
		 * beam is underneath the water.
		 */
		float water_gap =
			beam_world_position.y
			- effective_water_height;

		water_intersection_fade = smoothstep(
			0.0,
			max(
				water_intersection_fade_distance,
				0.0001
			),
			water_gap
		);

		water_intersection_fade = pow(
			clamp(
				water_intersection_fade,
				0.0,
				1.0
			),
			water_intersection_fade_power
		);

		water_intersection_fade = mix(
			1.0,
			water_intersection_fade,
			water_intersection_fade_strength
		);
	}


	// ------------------------------------------------------------
	// FINAL ALPHA
	// ------------------------------------------------------------

	float alpha = (
		beam_opacity
		* light_color.a
		* near_fade
		* far_fade
		* distance_fade
		* soft_edge
		* intersection_fade
		* water_intersection_fade
		* density
	);


	ALBEDO =
		light_color.rgb;

	EMISSION =
		light_color.rgb
		* emission_energy
		* (
			0.72
			+ dust * 0.55
		);

	ALPHA = clamp(
		alpha,
		0.0,
		1.0
	);
}