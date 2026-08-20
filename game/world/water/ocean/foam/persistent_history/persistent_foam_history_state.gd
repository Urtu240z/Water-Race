class_name PersistentFoamHistoryState
extends RefCounted

const MAX_REFRESH_AGE_REWIND_PER_PASS := 0.01

## CPU-side reference for the GPU history state math.
##
## The RGBA state layout used for the history texture:
##   R = pure footprint field (monotonic geometric union, 0..1)
##   G = maximum growth/establishment progress reached (monotonic, 0..1)
##   B = age ratio (0 fresh .. 1 dead)
##   A = foam intensity (bounded reinforcement, 0..1)
##
## Deposit map layout (separate single-use viewport):
##   R = pure footprint field
##   G = freshness flag (1 inside the stamp)
##   B = unused
##   A = source intensity
##
## The GPU update shader transliterates these formulas exactly; this class lets
## headless tests validate the state transitions without reading GPU pixels.


static func smooth(edge0: float, edge1: float, value: float) -> float:
	var t := clampf((value - edge0) / maxf(edge1 - edge0, 0.000001), 0.0, 1.0)
	return t * t * (3.0 - 2.0 * t)


## State written by a fresh deposit stamp at a pixel with the given footprint
## gradient (0 at edge, ~1 at center) and overall intensity. Matches the
## deposit canvas channel layout: G is a hard freshness flag (1 inside the
## stamp footprint, 0 outside).
static func deposit_state(footprint: float, intensity: float) -> Vector4:
	var foot := clampf(footprint, 0.0, 1.0)
	var fresh := 1.0 if footprint > 0.001 else 0.0
	return Vector4(foot, fresh, 0.0, clampf(intensity, 0.0, 1.0))


## One history update step. Matches persistent_foam_history_update.gdshader.
static func advance(
	old: Vector4,
	dep: Vector4,
	dt_ratio: float,
	fade_out_start_ratio: float,
	refresh_blend: float = 0.0
) -> Vector4:
	const STATE_EPSILON := 0.001
	var has_old_foam := old.x > STATE_EPSILON
	var has_new_deposit := dep.y > STATE_EPSILON and dep.x > STATE_EPSILON
	var is_birth := has_new_deposit and not has_old_foam
	var is_live_refresh := has_new_deposit and has_old_foam
	## Empty texels are not active simulation state. This must match the GPU
	## guard exactly so a dead pixel cannot begin a new lifecycle by itself.
	if not has_old_foam and not has_new_deposit:
		return Vector4.ZERO
	var positive_dt := maxf(dt_ratio, 0.0)
	var age := minf(old.z + positive_dt, 1.0)
	if is_birth:
		age = 0.0
	elif is_live_refresh:
		## A living refresh rewinds at most one normal temporal step rather than
		## snapping age to zero. The hard cap protects against a stalled frame
		## turning a refresh into a large one-pass opacity jump.
		age = maxf(
			old.z - minf(positive_dt, MAX_REFRESH_AGE_REWIND_PER_PASS),
			0.0
		)
	if age >= 1.0:
		return Vector4.ZERO
	## Growth completes exactly when fade-out begins and never decreases when a
	## later pass refreshes age back to zero.
	var progress_age := maxf(age, positive_dt) if is_birth else age
	var progress := maxf(
		old.y,
		clampf(progress_age / maxf(fade_out_start_ratio, 0.00001), 0.0, 1.0)
	)
	var reinforce := clampf(refresh_blend, 0.0, 1.0)
	var target_footprint := maxf(old.x, dep.x)
	var target_intensity := maxf(old.w, dep.w)
	var footprint := dep.x if is_birth else old.x
	var intensity := dep.w if is_birth else old.w
	if is_live_refresh:
		## Shape and intensity approach their reinforced targets over several GPU
		## updates. This prevents the contact edge from appearing as a new hard
		## patch over already-visible, fading foam.
		footprint = lerpf(old.x, target_footprint, reinforce)
		intensity = lerpf(old.w, target_intensity, reinforce)
	return Vector4(footprint, progress, age, intensity)


## Geometric reveal only. The transition starts at the requested radius and
## softens inward, so the exact outer extent is zero instead of a half-white
## iso-contour.
static func geometric_reveal(
	state: Vector4,
	size_min: float,
	size_max: float,
	edge_softness: float = 0.22
) -> float:
	var radius_frac := lerpf(
		clampf(size_min / maxf(size_max, 0.001), 0.02, 1.0),
		1.0,
		clampf(state.y, 0.0, 1.0)
	)
	var threshold := 1.0 - radius_frac * radius_frac
	var reveal_width := minf(
		maxf(edge_softness, 0.00001),
		maxf(1.0 - threshold, 0.00001)
	)
	return smooth(threshold, threshold + reveal_width, state.x)


## World-space breakup reference shared with the ocean shader. Irregularity
## moves the threshold instead of mixing against white, so a real noise hole
## can reach zero for every nonzero artistic breakup setting.
static func breakup(
	combined_noise: float,
	irregularity: float,
	noise_threshold: float,
	breakup_softness: float = 0.08
) -> float:
	var width := maxf(breakup_softness, 0.00001)
	var effective_threshold := lerpf(
		-width,
		noise_threshold,
		clampf(irregularity, 0.0, 1.0)
	)
	return smooth(
		effective_threshold - width,
		effective_threshold + width,
		combined_noise
	)


## Final coverage read by the ocean shader.
static func coverage(
	state: Vector4,
	size_min: float,
	size_max: float,
	fade_in_ratio: float,
	fade_out_start_ratio: float,
	edge_softness: float = 0.22
) -> float:
	var revealed := geometric_reveal(state, size_min, size_max, edge_softness)
	var fade_in_progress := clampf(
		fade_in_ratio / maxf(fade_out_start_ratio, 0.00001),
		0.0,
		1.0
	)
	var fade_in := smooth(0.0, maxf(fade_in_progress, 0.00001), state.y)
	var fade_out := 1.0 - smooth(fade_out_start_ratio, 1.0, state.z)
	var life_alpha := fade_in * fade_out
	return clampf(
		revealed * life_alpha * clampf(state.w, 0.0, 1.0),
		0.0,
		1.0
	)
