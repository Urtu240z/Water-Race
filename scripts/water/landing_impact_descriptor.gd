class_name LandingImpactDescriptor
extends RefCounted

var event_id: int = 0
var position: Vector3 = Vector3.ZERO
var normal_speed: float = 0.0
var airtime: float = 0.0
var strength: float = 0.0
var contact_mask: int = 0
var contact_count: int = 0
var entry_type: JetSkiTypes.LandingEntryType = (
	JetSkiTypes.LandingEntryType.UNKNOWN
)
var forward: Vector3 = Vector3.FORWARD
var right: Vector3 = Vector3.RIGHT
var half_extents: Vector2 = Vector2(0.55, 1.35)
var front_left_position: Vector3 = Vector3.ZERO
var front_right_position: Vector3 = Vector3.ZERO
var rear_left_position: Vector3 = Vector3.ZERO
var rear_right_position: Vector3 = Vector3.ZERO
var secondary_a_offset: Vector2 = Vector2.ZERO
var secondary_b_offset: Vector2 = Vector2.ZERO
var secondary_weights: Vector2 = Vector2.ZERO


static func calculate_strength(
	landing_normal_speed: float,
	landing_airtime: float,
	landing_contact_count: int,
	minimum_normal_speed: float,
	full_normal_speed: float,
	minimum_airtime: float,
	full_airtime: float,
	minimum_visible_strength: float,
	confirmed_jump: bool = true
) -> float:
	var normal_factor := smoothstep(
		minimum_normal_speed,
		maxf(full_normal_speed, minimum_normal_speed + 0.001),
		maxf(landing_normal_speed, 0.0)
	)
	var airtime_factor := smoothstep(
		minimum_airtime,
		maxf(full_airtime, minimum_airtime + 0.001),
		maxf(landing_airtime, 0.0)
	)
	var contact_factor := lerpf(
		0.94,
		1.04,
		clampf((float(landing_contact_count) - 1.0) / 3.0, 0.0, 1.0)
	)
	var measured_strength := maxf(
		normal_factor,
		normal_factor * 0.82 + airtime_factor * 0.18
	) * contact_factor
	if confirmed_jump:
		measured_strength = maxf(
			measured_strength,
			maxf(minimum_visible_strength, 0.0)
		)
	return clampf(measured_strength, 0.0, 1.0)
