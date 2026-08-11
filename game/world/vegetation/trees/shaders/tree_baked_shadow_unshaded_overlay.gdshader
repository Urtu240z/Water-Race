shader_type spatial;

render_mode
	blend_mix,
	unshaded,
	depth_draw_never,
	cull_disabled,
	fog_disabled;


// ============================================================
// STATIC SHADOW TEXTURE
// ============================================================

uniform sampler2D shadow_texture
	: source_color, repeat_disable, filter_linear;


// ============================================================
// SUN-SPACE PROJECTION
// ============================================================

uniform vec3 mask_center = vec3(
	134.9561,
	-55.96886,
	114.5202
);

uniform vec3 mask_right = vec3(
	0.829735,
	0.0,
	0.558158
);

uniform vec3 mask_up = vec3(
	0.408467,
	0.681505,
	-0.607211
);

uniform float capture_size = 1567.5691;


// ============================================================
// SUN DIRECTION
//
// Direction FROM scene TOWARDS sun.
// This is the value already printed by the baker:
//
// Mask +Z / to sun:
// (-0.380387, 0.731813, 0.565468)
// ============================================================

uniform vec3 to_sun_direction = vec3(
	-0.380387,
	0.731813,
	0.565468
);


// ============================================================
// SHADOW
// ============================================================

uniform float shadow_strength
	: hint_range(0.0, 1.0, 0.01) = 1.0;


uniform float shadow_gamma
	: hint_range(0.05, 4.0, 0.01) = 0.40;


uniform float shadow_threshold
	: hint_range(0.0, 1.0, 0.001) = 0.01;


uniform bool solid_shadow = false;


uniform float solid_threshold
	: hint_range(0.0, 1.0, 0.001) = 0.05;


// ============================================================
// STRETCH FADE
//
// A projected shadow stretches approximately as:
//
//     1 / dot(surface_normal, sun_direction)
//
// When dot approaches zero, projection becomes extremely
// stretched.
//
// stretch_fade_start:
// below this NdotL we start reducing the shadow.
//
// stretch_fade_end:
// below this NdotL the shadow disappears completely.
//
// Example:
//
// horizontal-ish terrain:
// NdotL ~ 0.73 -> full shadow
//
// steep/grazing wall:
// NdotL ~ 0.10-0.30 -> faded shadow
// ============================================================

uniform bool use_stretch_fade = true;


uniform float stretch_fade_start
	: hint_range(0.0, 1.0, 0.01) = 0.55;


uniform float stretch_fade_end
	: hint_range(0.0, 1.0, 0.01) = 0.20;


// Controls the shape of the fade.
//
// > 1.0 makes the transition stronger.
// < 1.0 makes it softer.
uniform float stretch_fade_power
	: hint_range(0.10, 5.0, 0.05) = 1.50;


// Optional minimum visibility.
//
// 0.0 = can disappear completely.
// 0.15 = always retain at least 15 %.
uniform float minimum_stretch_visibility
	: hint_range(0.0, 1.0, 0.01) = 0.0;


// ============================================================
// WORLD DATA
// ============================================================

varying vec3 world_position;
varying vec3 world_normal;


// ============================================================
// VERTEX
// ============================================================

void vertex() {

	world_position = (
		MODEL_MATRIX
		* vec4(
			VERTEX,
			1.0
		)
	).xyz;


	world_normal = normalize(
		MODEL_NORMAL_MATRIX
		* NORMAL
	);
}


// ============================================================
// FRAGMENT
// ============================================================

void fragment() {

	// --------------------------------------------------------
	// SUN-SPACE UV
	// --------------------------------------------------------

	vec3 relative_position = (
		world_position
		- mask_center
	);


	vec2 projected_position = vec2(

		dot(
			relative_position,
			mask_right
		),

		-dot(
			relative_position,
			mask_up
		)
	);


	vec2 shadow_uv = (
		projected_position
		/ max(
			capture_size,
			0.001
		)
		+ vec2(
			0.5
		)
	);


	if (
		shadow_uv.x < 0.0
		|| shadow_uv.x > 1.0
		|| shadow_uv.y < 0.0
		|| shadow_uv.y > 1.0
	) {
		discard;
	}


	// --------------------------------------------------------
	// BAKED SHADOW
	// --------------------------------------------------------

	float shadow_alpha = texture(
		shadow_texture,
		shadow_uv
	).a;


	if (
		shadow_alpha
		<= shadow_threshold
	) {
		discard;
	}


	shadow_alpha = pow(
		clamp(
			shadow_alpha,
			0.0,
			1.0
		),
		max(
			shadow_gamma,
			0.001
		)
	);


	if (solid_shadow) {

		shadow_alpha = step(
			solid_threshold,
			shadow_alpha
		);
	}


	// --------------------------------------------------------
	// PROJECTION-STRETCH FADE
	//
	// Large NdotL:
	// sun hits surface directly -> short/natural projection.
	//
	// Small NdotL:
	// grazing angle -> projected shadow becomes extremely long.
	// --------------------------------------------------------

	if (use_stretch_fade) {

		vec3 normalized_sun_direction = normalize(
			to_sun_direction
		);


		vec3 normalized_world_normal = normalize(
			world_normal
		);


		float receiver_ndotl = max(
			dot(
				normalized_world_normal,
				normalized_sun_direction
			),
			0.0
		);


		float stretch_visibility = smoothstep(
			stretch_fade_end,
			stretch_fade_start,
			receiver_ndotl
		);


		stretch_visibility = pow(
			clamp(
				stretch_visibility,
				0.0,
				1.0
			),
			max(
				stretch_fade_power,
				0.001
			)
		);


		stretch_visibility = max(
			stretch_visibility,
			minimum_stretch_visibility
		);


		shadow_alpha *= (
			stretch_visibility
		);
	}


	// --------------------------------------------------------
	// FINAL STRENGTH
	// --------------------------------------------------------

	shadow_alpha *= (
		shadow_strength
	);


	shadow_alpha = clamp(
		shadow_alpha,
		0.0,
		1.0
	);


	if (
		shadow_alpha
		<= 0.001
	) {
		discard;
	}


	// Completely independent from DirectionalLight3D.
	ALBEDO = vec3(
		0.0
	);


	ALPHA = (
		shadow_alpha
	);
}