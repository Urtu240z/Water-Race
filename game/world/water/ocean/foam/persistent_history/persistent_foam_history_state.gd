class_name PersistentFoamHistoryState
extends RefCounted

## CPU-side reference for the GPU history state math.
##
## The RGBA state layout used for the history texture:
##   R = footprint (max-future coverage gradient left by deposits, 0..1)
##   G = growth-reveal progress (monotonic, never decreases)
##   B = age ratio (0 fresh .. 1 dead)
##   A = established life alpha (monotonic, remembers the fade-in peak so that
##       refreshing a deposit never makes existing foam temporarily disappear)
##
## Deposit map layout (separate single-use viewport):
##   R = footprint * intensity (the stamp's max footprint gradient)
##   G = freshness flag (1 inside the stamp)
##
## The GPU update shader transliterates these formulas exactly; this class lets
## headless tests validate the state transitions without reading GPU pixels.


static func smoothstep01(value: float) -> float:
	var t := clampf(value, 0.0, 1.0)
	return t * t * (3.0 - 2.0 * t)


static func smooth(edge0: float, edge1: float, value: float) -> float:
	var t := clampf((value - edge0) / maxf(edge1 - edge0, 0.000001), 0.0, 1.0)
	return t * t * (3.0 - 2.0 * t)


## State written by a fresh deposit stamp at a pixel with the given footprint
## gradient (0 at edge, ~1 at center) and overall intensity. Matches the
## deposit canvas channel layout: G is a hard freshness flag (1 inside the
## stamp footprint, 0 outside).
static func deposit_state(footprint: float, intensity: float) -> Vector4:
	var foot := clampf(footprint * maxf(intensity, 0.0), 0.0, 1.0)
	var fresh := 1.0 if footprint > 0.001 else 0.0
	return Vector4(foot, fresh, 0.0, 0.0)


## One history update step. Matches persistent_foam_history_update.gdshader.
static func advance(
	old: Vector4,
	dep: Vector4,
	dt_ratio: float,
	fade_in_ratio: float
) -> Vector4:
	const STATE_EPSILON := 0.001
	var has_old_foam := old.x > STATE_EPSILON
	var has_new_deposit := dep.y > STATE_EPSILON and dep.x > STATE_EPSILON
	## Empty texels are not active simulation state. This must match the GPU
	## guard exactly so a dead pixel cannot begin a new lifecycle by itself.
	if not has_old_foam and not has_new_deposit:
		return Vector4.ZERO
	var age := minf(old.z + maxf(dt_ratio, 0.0), 1.0)
	if has_new_deposit:
		age = minf(age, 0.0)
	if age >= 1.0:
		return Vector4.ZERO
	## Reveal progress is monotonic: refreshing never shrinks grown foam.
	var reveal := maxf(old.y, smoothstep01(age))
	## Established life alpha is monotonic: a refresh cannot dip visibility.
	var established := maxf(
		old.w,
		smooth(0.0, maxf(fade_in_ratio, 0.00001), age)
	)
	var footprint := maxf(old.x, dep.x)
	return Vector4(footprint, reveal, age, established)


## Final coverage read by the ocean shader.
static func coverage(
	state: Vector4,
	size_min: float,
	size_max: float,
	fade_out_start_ratio: float
) -> float:
	var radius_frac := lerpf(
		clampf(size_min / maxf(size_max, 0.001), 0.02, 1.0),
		1.0,
		clampf(state.y, 0.0, 1.0)
	)
	## The stored brush is a center-high radial footprint. Reveal its inner
	## radius with the complementary squared-radius threshold so size_min and
	## size_max remain true geometric multipliers on the GPU.
	var threshold := 1.0 - radius_frac * radius_frac
	var revealed := smooth(threshold - 0.05, threshold + 0.05, state.x)
	var fade_out := 1.0 - smooth(fade_out_start_ratio, 1.0, state.z)
	return clampf(revealed * clampf(state.w, 0.0, 1.0) * fade_out, 0.0, 1.0)
