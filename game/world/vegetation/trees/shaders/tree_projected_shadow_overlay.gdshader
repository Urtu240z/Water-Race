shader_type spatial;

render_mode
	blend_mul,
	unshaded,
	depth_draw_never,
	cull_back,
	fog_disabled;


// ============================================================
// SHADOW MULTIPLIER MAP
// ============================================================

// DATA texture.
// WHITE = no change.
// DARK = multiply the already rendered terrain.
uniform sampler2D shadow_multiplier_map
	: repeat_disable, filter_linear;

uniform vec2 shadow_world_min = vec2(0.0, 0.0);

uniform vec2 shadow_world_size = vec2(1.0, 1.0);


// ============================================================
// ART DIRECTION
// ============================================================

// 1.0 = baked strength.
// > 1.0 = stronger/darker.
uniform float shadow_strength
	: hint_range(0.0, 3.0, 0.01) = 1.35;

// < 1.0 makes medium/light shadows stronger.
// 1.0 preserves the baked response.
uniform float shadow_gamma
	: hint_range(0.10, 3.0, 0.01) = 0.75;

// Ignores tiny differences/noise from the capture.
uniform float shadow_threshold
	: hint_range(0.0, 0.20, 0.001) = 0.005;

// Prevents the multiplier from ever reaching absolute black.
// 0.05 = darkest shadow can leave 5 % of the original result.
uniform float minimum_multiplier
	: hint_range(0.0, 1.0, 0.01) = 0.05;

// Avoids fighting with the original terrain depth.
// Very small displacement along the terrain normal.
uniform float surface_offset
	: hint_range(0.0, 0.20, 0.001) = 0.025;


// ============================================================
// WORLD POSITION
// ============================================================

varying vec3 world_position;


void vertex() {

	VERTEX += NORMAL * surface_offset;

	world_position = (
		MODEL_MATRIX
		* vec4(
			VERTEX,
			1.0
		)
	).xyz;
}


// ============================================================
// MULTIPLY PASS
// ============================================================

void fragment() {

	vec2 shadow_uv = (
		(world_position.xz - shadow_world_min)
		/ max(
			shadow_world_size,
			vec2(0.001)
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


	float baked_multiplier = texture(
		shadow_multiplier_map,
		shadow_uv
	).r;


	baked_multiplier = clamp(
		baked_multiplier,
		0.0,
		1.0
	);


	float shadow_amount = (
		1.0 - baked_multiplier
	);


	if (shadow_amount <= shadow_threshold) {
		discard;
	}


	shadow_amount = pow(
		shadow_amount,
		max(
			shadow_gamma,
			0.001
		)
	);


	shadow_amount = clamp(
		shadow_amount * shadow_strength,
		0.0,
		1.0
	);


	float final_multiplier = max(
		1.0 - shadow_amount,
		minimum_multiplier
	);


	// blend_mul performs:
	//
	// final framebuffer =
	// framebuffer * ALBEDO
	//
	// Therefore:
	//
	// vec3(1.0) = terrain unchanged.
	// vec3(0.5) = terrain half as bright.
	// vec3(0.0) = black.
	ALBEDO = vec3(
		final_multiplier
	);
}