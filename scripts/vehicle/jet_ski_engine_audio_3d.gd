extends AudioStreamPlayer3D

## Keeps the JetSki engine loop spatialized and responsive without affecting physics.

@export_group("Engine Response")
@export_range(0.25, 2.0, 0.01) var idle_pitch: float = 0.72
@export_range(0.25, 2.0, 0.01) var full_throttle_pitch: float = 1.38
@export_range(0.25, 2.5, 0.01) var free_rev_pitch: float = 1.90
@export_range(-40.0, 6.0, 0.5) var idle_volume_db: float = -14.0
@export_range(-40.0, 6.0, 0.5) var full_throttle_volume_db: float = -2.0
@export_range(1.0, 50.0, 0.5) var speed_for_full_load: float = 24.0
@export_range(0.0, 1.0, 0.01) var coasting_speed_influence: float = 0.28
@export_range(0.0, 1.0, 0.01) var reverse_load_scale: float = 0.72
@export_range(0.1, 20.0, 0.1) var response_speed: float = 5.5
@export_range(0.0, 1.0, 0.01) var turbine_contact_threshold: float = 0.05
@export_range(0.1, 20.0, 0.1) var free_rev_rise_speed: float = 7.5
@export_range(0.1, 20.0, 0.1) var free_rev_fall_speed: float = 10.0

@export_group("Wave Load Modulation")
@export var wave_load_modulation_enabled: bool = true
@export_range(0.0, 0.99, 0.01) var wave_load_activation_throttle: float = 0.82
@export_range(0.0, 30.0, 0.1, "suffix:m/s") var wave_load_minimum_speed: float = 4.0
@export_range(0.1, 15.0, 0.1, "suffix:°") var wave_load_maximum_angle: float = 10.0
@export_range(0.0, 5.0, 0.1, "suffix:°") var wave_load_angle_dead_zone: float = 1.5
@export_range(0.0, 0.25, 0.005) var nose_down_pitch_boost: float = 0.06
@export_range(0.0, 0.25, 0.005) var nose_up_pitch_drop: float = 0.09
@export_range(0.1, 30.0, 0.1) var wave_load_response_speed: float = 7.0

var _vehicle: RigidBody3D
var _free_rev_blend: float = 0.0
var _base_pitch: float = 1.0
var _wave_load_pitch_offset: float = 0.0


func _ready() -> void:
	_vehicle = get_parent() as RigidBody3D
	if _vehicle == null:
		push_warning("JetSki engine audio must be a child of a RigidBody3D.")
		set_physics_process(false)
		return
	if stream == null:
		push_warning("JetSki engine audio has no stream assigned.")
		set_physics_process(false)
		return

	_base_pitch = idle_pitch
	_wave_load_pitch_offset = 0.0
	pitch_scale = _base_pitch
	volume_db = idle_volume_db
	if not playing:
		play()


func _physics_process(delta: float) -> void:
	if not is_instance_valid(_vehicle):
		return
	if not playing:
		play()

	var throttle := clampf(float(_vehicle.get("throttle_input")), 0.0, 1.0)
	var reverse := clampf(float(_vehicle.get("brake_input")), 0.0, 1.0)
	var horizontal_speed := Vector2(
		_vehicle.linear_velocity.x,
		_vehicle.linear_velocity.z
	).length()
	var speed_load := clampf(horizontal_speed / maxf(speed_for_full_load, 0.001), 0.0, 1.0)
	var control_load := maxf(throttle, reverse * reverse_load_scale)
	var engine_load := clampf(
		maxf(control_load, speed_load * coasting_speed_influence),
		0.0,
		1.0
	)
	var hull_has_contact := float(_vehicle.get("submerged_ratio")) > 0.0
	var turbine_has_contact := (
		float(_vehicle.get("propulsion_contact_factor")) > turbine_contact_threshold
	)
	var free_rev_target := 0.0 if hull_has_contact or turbine_has_contact else 1.0
	var free_rev_speed := (
		free_rev_rise_speed if free_rev_target > _free_rev_blend else free_rev_fall_speed
	)
	var free_rev_response := 1.0 - exp(-free_rev_speed * maxf(delta, 0.0))
	_free_rev_blend = lerpf(_free_rev_blend, free_rev_target, free_rev_response)
	var blend := 1.0 - exp(-response_speed * maxf(delta, 0.0))
	var loaded_pitch := lerpf(idle_pitch, full_throttle_pitch, engine_load)
	var loaded_volume := lerpf(idle_volume_db, full_throttle_volume_db, engine_load)
	var free_rev_amount := _free_rev_blend * control_load
	var target_pitch := lerpf(loaded_pitch, free_rev_pitch, free_rev_amount)
	var target_wave_load_offset: float = _calculate_wave_load_pitch_offset(
		throttle,
		horizontal_speed,
		hull_has_contact or turbine_has_contact
	)

	_base_pitch = lerpf(
		_base_pitch,
		target_pitch,
		blend
	)
	var wave_load_blend: float = 1.0 - exp(
		-wave_load_response_speed * maxf(delta, 0.0)
	)
	_wave_load_pitch_offset = lerpf(
		_wave_load_pitch_offset,
		target_wave_load_offset,
		wave_load_blend
	)
	pitch_scale = maxf(_base_pitch + _wave_load_pitch_offset, 0.01)
	volume_db = lerpf(
		volume_db,
		loaded_volume,
		blend
	)


func _calculate_wave_load_pitch_offset(
	throttle: float,
	horizontal_speed: float,
	has_water_contact: bool
) -> float:
	if (
		not wave_load_modulation_enabled
		or not has_water_contact
		or not is_instance_valid(_vehicle)
	):
		return 0.0

	var vehicle_forward: Vector3 = -_vehicle.global_basis.z
	if not vehicle_forward.is_finite() or vehicle_forward.length_squared() <= 0.000001:
		return 0.0
	vehicle_forward = vehicle_forward.normalized()

	# The controller uses forward=-Z: positive physical pitch raises the bow.
	# Negating it makes nose-down positive for the requested engine-load response.
	var physical_pitch: float = asin(clampf(vehicle_forward.y, -1.0, 1.0))
	var nose_down_angle: float = -physical_pitch
	var maximum_angle: float = maxf(deg_to_rad(wave_load_maximum_angle), 0.001)
	var dead_zone: float = clampf(
		deg_to_rad(wave_load_angle_dead_zone),
		0.0,
		maximum_angle - 0.001
	)
	var effective_angle: float = move_toward(
		nose_down_angle,
		0.0,
		dead_zone
	)
	var normalized_tilt: float = clampf(
		effective_angle / maxf(maximum_angle - dead_zone, 0.001),
		-1.0,
		1.0
	)
	var orientation_offset: float = (
		maxf(normalized_tilt, 0.0) * nose_down_pitch_boost
		- maxf(-normalized_tilt, 0.0) * nose_up_pitch_drop
	)
	var high_rev_blend: float = smoothstep(
		wave_load_activation_throttle,
		1.0,
		throttle
	)
	var moving_blend: float = smoothstep(
		wave_load_minimum_speed,
		wave_load_minimum_speed + 3.0,
		horizontal_speed
	)
	var loaded_water_blend: float = 1.0 - _free_rev_blend
	return orientation_offset * high_rev_blend * moving_blend * loaded_water_blend
