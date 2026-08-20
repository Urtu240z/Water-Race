shader_type canvas_item;
// RGBA is simulation state, not transparency. In particular A is allowed to
// be zero at birth, so normal CanvasItem alpha blending would corrupt R/G/B.
render_mode blend_disabled;

// Persistent Foam V2 - HISTORY MAP state update.
//
// Advances the per-pixel foam state by one step of ratio dt_ratio and merges
// any newly deposited stamps from deposit_texture. Writes to the opposite
// ping-pong history viewport, so it never samples and writes the same texture.
//
// State RGBA:
//   R = footprint (max future coverage gradient, 0..1)
//   G = growth-reveal progress (monotonic, 0..1)
//   B = age ratio (0 fresh .. 1 dead)
//   A = established life alpha (monotonic, remembers fade-in peak)
//
// Deposit RGBA:
//   R = footprint * intensity
//   G = freshness flag (1 inside a stamp)
//   B/A unused
//
// Formulas mirror persistent_foam_history_state.gd exactly.

uniform sampler2D history_texture : repeat_disable, filter_linear;
uniform sampler2D deposit_texture : repeat_disable, filter_linear;
uniform float dt_ratio : hint_range(0.0, 1.0, 0.001) = 0.1;
uniform float fade_in_ratio : hint_range(0.0, 1.0, 0.001) = 0.10;
uniform vec2 remap_delta_uv = vec2(0.0);


float smooth01(float value) {
	float t = clamp(value, 0.0, 1.0);
	return t * t * (3.0 - 2.0 * t);
}

float smoothrange(float edge0, float edge1, float value) {
	float t = clamp((value - edge0) / max(edge1 - edge0, 1e-6), 0.0, 1.0);
	return t * t * (3.0 - 2.0 * t);
}


void fragment() {
	vec4 old_state = vec4(0.0);
	vec2 old_uv = UV + remap_delta_uv;
	if (old_uv.x >= 0.0 && old_uv.y >= 0.0 && old_uv.x <= 1.0 && old_uv.y <= 1.0) {
		old_state = texture(history_texture, old_uv);
	}
	vec4 dep = texture(deposit_texture, UV);
	const float STATE_EPSILON = 0.001;
	bool has_old_foam = old_state.r > STATE_EPSILON;
	bool has_new_deposit = dep.g > STATE_EPSILON && dep.r > STATE_EPSILON;
	if (!has_old_foam && !has_new_deposit) {
		// Empty texels are not simulation state. Keeping all channels zero
		// prevents an empty pixel from entering and restarting the lifecycle.
		COLOR = vec4(0.0);
	} else {
		float age = min(old_state.b + max(dt_ratio, 0.0), 1.0);
		if (has_new_deposit) {
			age = min(age, 0.0);
		}
		if (age >= 1.0) {
			COLOR = vec4(0.0);
		} else {
			// Reveal progress and established alpha are monotonic so a second pass
			// can refresh a location without making existing foam less visible.
			float reveal = max(old_state.g, smooth01(age));
			float established = max(
				old_state.a,
				smoothrange(0.0, max(fade_in_ratio, 1e-5), age)
			);
			// DepositViewport uses additive blending for overlapping new stamps.
			// Clamp the merged coverage so it remains bounded in [0, 1].
			float footprint = max(clamp(old_state.r, 0.0, 1.0), clamp(dep.r, 0.0, 1.0));

			COLOR = vec4(
				clamp(footprint, 0.0, 1.0),
				clamp(reveal, 0.0, 1.0),
				clamp(age, 0.0, 1.0),
				clamp(established, 0.0, 1.0)
			);
		}
	}
}
