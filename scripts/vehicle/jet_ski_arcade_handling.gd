extends Node

## Adds selective arcade grip to the JetSki without replacing its water physics.
## Lateral drift and residual yaw are reduced while roll, pitch, wave response
## and physical impacts remain controlled by JetSkiController.

@export_group("Arcade Handling")
@export var arcade_handling_enabled: bool = true
@export_range(0.0, 12.0, 0.1, "suffix:1/s") var lateral_grip_rate: float = 3.5
@export_range(0.0, 1.0, 0.01) var lateral_grip_while_steering: float = 0.35
@export_range(0.0, 50.0, 0.5, "suffix:m/s²") var maximum_lateral_acceleration: float = 18.0
@export_range(0.0, 12.0, 0.1, "suffix:1/s") var yaw_damping_rate: float = 3.0
@export_range(0.0, 1.0, 0.01) var yaw_damping_while_steering: float = 0.12
@export_range(0.0, 5.0, 0.1, "suffix:m/s") var minimum_handling_speed: float = 1.5
@export_range(0.0, 0.5, 0.01) var steering_dead_zone: float = 0.08

var _vehicle: JetSkiController


func _ready() -> void:
	_vehicle = get_parent() as JetSkiController

	if _vehicle == null:
		push_warning("JetSkiArcadeHandling must be a child of a JetSkiController.")
		set_physics_process(false)


func _physics_process(delta: float) -> void:
	if not arcade_handling_enabled or not is_instance_valid(_vehicle):
		return
	if _vehicle.freeze or get_tree().paused:
		return
	if _vehicle.submerged_ratio <= 0.0:
		return
	if _vehicle.submarine_dive_active:
		return
	if _vehicle.navigation_state == JetSkiController.NavigationState.DEEP_SUBMERGED:
		return

	var ocean := _vehicle.get_ocean()
	if not is_instance_valid(ocean):
		return

	var water_normal := ocean.sample_normal(_vehicle.global_position)
	var water_velocity := ocean.sample_water_velocity(_vehicle.global_position)

	if not water_normal.is_finite() or water_normal.length_squared() <= 0.000001:
		water_normal = Vector3.UP
	else:
		water_normal = water_normal.normalized()

	if water_normal.y < 0.0:
		water_normal = -water_normal
	if not water_velocity.is_finite():
		water_velocity = Vector3.ZERO

	var body_forward := -_vehicle.global_basis.z
	var forward_tangent := body_forward - water_normal * body_forward.dot(water_normal)

	if forward_tangent.length_squared() <= 0.000001:
		return

	forward_tangent = forward_tangent.normalized()
	var right_tangent := forward_tangent.cross(water_normal)

	if right_tangent.length_squared() <= 0.000001:
		return

	right_tangent = right_tangent.normalized()

	var relative_velocity := _vehicle.linear_velocity - water_velocity
	var tangential_velocity := relative_velocity - water_normal * relative_velocity.dot(water_normal)
	var tangential_speed := tangential_velocity.length()

	var steering_amount := clampf(absf(_vehicle.steering_input), 0.0, 1.0)
	var steering_blend := smoothstep(steering_dead_zone, 1.0, steering_amount)
	var centered_blend := 1.0 - steering_blend
	var contact_factor := smoothstep(0.0, 0.75, _vehicle.submerged_ratio)
	var speed_factor := smoothstep(
		minimum_handling_speed,
		minimum_handling_speed + 3.0,
		tangential_speed
	)
	var handling_authority := contact_factor * speed_factor

	if handling_authority <= 0.0:
		return

	_apply_lateral_grip(
		delta,
		right_tangent,
		tangential_velocity,
		centered_blend,
		handling_authority
	)
	_apply_yaw_damping(
		delta,
		water_normal,
		centered_blend,
		handling_authority
	)


func _apply_lateral_grip(
	delta: float,
	right_tangent: Vector3,
	tangential_velocity: Vector3,
	centered_blend: float,
	handling_authority: float
) -> void:
	var lateral_speed := tangential_velocity.dot(right_tangent)

	if absf(lateral_speed) <= 0.001:
		return

	var steering_grip := lerpf(lateral_grip_while_steering, 1.0, centered_blend)
	var effective_grip_rate := lateral_grip_rate * steering_grip * handling_authority
	var safe_delta := maxf(delta, 0.0001)
	var removal_fraction := 1.0 - exp(-effective_grip_rate * safe_delta)
	var correction_velocity := -right_tangent * lateral_speed * removal_fraction
	var correction_acceleration := correction_velocity / safe_delta

	if correction_acceleration.length() > maximum_lateral_acceleration:
		correction_acceleration = (
			correction_acceleration.normalized() * maximum_lateral_acceleration
		)

	_vehicle.apply_central_force(correction_acceleration * _vehicle.mass)


func _apply_yaw_damping(
	delta: float,
	water_normal: Vector3,
	centered_blend: float,
	handling_authority: float
) -> void:
	var yaw_speed := _vehicle.angular_velocity.dot(water_normal)

	if absf(yaw_speed) <= 0.0001:
		return

	var steering_damping := lerpf(yaw_damping_while_steering, 1.0, centered_blend)
	var effective_damping_rate := yaw_damping_rate * steering_damping * handling_authority
	var removal_fraction := 1.0 - exp(-effective_damping_rate * maxf(delta, 0.0001))

	_vehicle.angular_velocity -= water_normal * yaw_speed * removal_fraction
