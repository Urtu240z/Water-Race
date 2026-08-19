class_name PersistentFoamSplat
extends RefCounted

## A single persistent foam deposit anchored to fixed world XZ.
## position_xz is immutable after creation; only an explicit world rebase may
## shift it (apply_world_rebase on the owning mask).
##
## Per-splat visual randomness (rotation, scale_x, scale_y, random_seed) is
## generated ONCE at creation and stored permanently. Repaints must never
## regenerate these: only age-driven size growth and fade are allowed to
## change the rendered output.

var position_xz: Vector2
var base_position_xz: Vector2
var radius: float
var intensity: float
var birth_time: float
var serial: int
var rotation: float
var scale_x: float
var scale_y: float
var random_seed: float


func _init(
	init_position_xz: Vector2 = Vector2.ZERO,
	init_radius: float = 0.6,
	init_intensity: float = 1.0,
	init_birth_time: float = 0.0,
	init_serial: int = 0
) -> void:
	position_xz = init_position_xz
	base_position_xz = init_position_xz
	radius = init_radius
	intensity = init_intensity
	birth_time = init_birth_time
	serial = init_serial
	rotation = 0.0
	scale_x = 1.0
	scale_y = 1.0
	random_seed = 0.0