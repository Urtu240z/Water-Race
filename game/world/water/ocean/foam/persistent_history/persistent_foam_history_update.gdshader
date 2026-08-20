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
//   R = pure footprint field (monotonic geometric union, 0..1)
//   G = maximum growth/establishment progress reached (monotonic, 0..1)
//   B = age ratio (0 fresh .. 1 dead)
//   A = foam intensity (bounded reinforcement, 0..1)
//
// Deposit RGBA:
//   R = pure footprint field
//   G = freshness flag (1 inside a stamp)
//   B = unused
//   A = source intensity
//
// Formulas mirror persistent_foam_history_state.gd exactly.

uniform sampler2D history_texture : repeat_disable, filter_linear;
uniform sampler2D deposit_texture : repeat_disable, filter_linear;
uniform float dt_ratio : hint_range(0.0, 1.0, 0.001) = 0.1;
uniform float fade_out_start_ratio : hint_range(0.0, 1.0, 0.001) = 0.70;
uniform vec2 remap_delta_uv = vec2(0.0);


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
			// Growth is complete before fade-out and is monotonic across refreshes.
			float progress_age = has_new_deposit ? max(age, max(dt_ratio, 0.0)) : age;
			float progress = max(
				old_state.g,
				clamp(progress_age / max(fade_out_start_ratio, 1e-5), 0.0, 1.0)
			);
			// The LDR deposit viewport saturates overlaps; clamp again at the
			// consumption boundary to keep every state channel strictly bounded.
			float footprint = max(clamp(old_state.r, 0.0, 1.0), clamp(dep.r, 0.0, 1.0));
			float intensity = max(clamp(old_state.a, 0.0, 1.0), clamp(dep.a, 0.0, 1.0));

			COLOR = vec4(
				clamp(footprint, 0.0, 1.0),
				clamp(progress, 0.0, 1.0),
				clamp(age, 0.0, 1.0),
				clamp(intensity, 0.0, 1.0)
			);
		}
	}
}
