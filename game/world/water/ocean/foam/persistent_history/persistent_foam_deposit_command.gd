class_name PersistentFoamDepositCommand
extends RefCounted

## A single NEW foam deposit submitted by a water vehicle. Represents only an
## un-consumed stamp request: after the history update consumes it, the command
## is discarded. The GPU history texture becomes the sole authority; no CPU
## object journals this deposit afterward.
##
## Per-deposit visual randomness (rotation, scale_x, scale_y, jittered XZ) is
## rolled ONCE here during submission and exists only for the stamp's lifetime.

var source_id: int
var world_xz := Vector2.ZERO
var forward_xz := Vector2.ZERO
var radius: float
var intensity: float
var rotation: float
var scale_x: float
var scale_y: float


static func roll_randomness(
	rng: RandomNumberGenerator,
	base_position: Vector2,
	travel_forward_xz: Vector2,
	jitter: float,
	rotation_random_deg: float,
	scale_min: float,
	scale_max: float,
	aspect_min: float,
	aspect_max: float
) -> Dictionary:
	var jittered := base_position
	if jitter > 0.0001:
		if travel_forward_xz.length_squared() > 0.0001:
			var forward := travel_forward_xz.normalized()
			var lateral := Vector2(-forward.y, forward.x)
			jittered = base_position + (
				lateral * rng.randf_range(-1.0, 1.0) * jitter
				+ forward * rng.randf_range(-1.0, 1.0) * jitter * 0.35
			)
		else:
			jittered = base_position + Vector2(
				rng.randf_range(-1.0, 1.0) * jitter,
				rng.randf_range(-1.0, 1.0) * jitter * 0.35
			)
	var scale_factor := rng.randf_range(scale_min, scale_max)
	var aspect := rng.randf_range(aspect_min, aspect_max)
	return {
		&"position": jittered,
		&"rotation": deg_to_rad(rng.randf_range(-rotation_random_deg, rotation_random_deg)),
		&"scale_x": scale_factor * aspect,
		&"scale_y": scale_factor,
	}
