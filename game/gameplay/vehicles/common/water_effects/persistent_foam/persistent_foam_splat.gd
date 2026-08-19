class_name PersistentFoamSplat
extends RefCounted

## A single persistent foam deposit anchored to fixed world XZ.
## position_xz is immutable after creation; only an explicit world rebase may
## shift it (apply_world_rebase on the owning mask).

var position_xz: Vector2
var radius: float
var intensity: float
var birth_time: float
var serial: int


func _init(
	init_position_xz: Vector2 = Vector2.ZERO,
	init_radius: float = 0.6,
	init_intensity: float = 1.0,
	init_birth_time: float = 0.0,
	init_serial: int = 0
) -> void:
	position_xz = init_position_xz
	radius = init_radius
	intensity = init_intensity
	birth_time = init_birth_time
	serial = init_serial