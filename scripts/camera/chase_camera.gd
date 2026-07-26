class_name ChaseCamera
extends Node3D

@export_group("References")
@export_node_path("RigidBody3D") var vehicle_body_path: NodePath
@export_node_path("Node3D") var camera_target_path: NodePath

@export_group("Follow")
@export_range(0.1, 50.0, 0.1, "or_greater", "suffix:m") var base_distance: float = 8.0
@export_range(0.0, 20.0, 0.1, "or_greater", "suffix:m") var base_height: float = 3.0
@export_range(0.0, 30.0, 0.1, "or_greater", "suffix:m") var base_look_ahead: float = 4.5
@export_range(-10.0, 10.0, 0.1, "suffix:m") var look_height_offset: float = 0.4
@export_range(0.01, 30.0, 0.1, "or_greater") var position_sharpness: float = 5.5
@export_range(0.01, 30.0, 0.1, "or_greater") var rotation_sharpness: float = 7.0
@export_range(0.01, 30.0, 0.1, "or_greater") var distance_sharpness: float = 4.0

@export_group("Speed Response")
@export_range(0.0, 100.0, 0.1, "or_greater", "suffix:m/s") var distance_extension_start_speed: float = 5.0
@export_range(0.0, 100.0, 0.1, "or_greater", "suffix:m/s") var distance_extension_end_speed: float = 24.0
@export_range(0.0, 10.0, 0.1, "or_greater", "suffix:m") var maximum_speed_distance_extension: float = 2.0
@export_range(1.0, 179.0, 0.1, "degrees") var base_fov: float = 65.0
@export_range(1.0, 179.0, 0.1, "degrees") var maximum_speed_fov: float = 72.0
@export_range(0.0, 100.0, 0.1, "or_greater", "suffix:m/s") var fov_start_speed: float = 5.0
@export_range(0.0, 100.0, 0.1, "or_greater", "suffix:m/s") var fov_end_speed: float = 24.0
@export_range(0.01, 30.0, 0.1, "or_greater") var fov_sharpness: float = 4.0

@export_group("Airborne")
@export_range(0.0, 10.0, 0.1, "or_greater", "suffix:m") var airborne_extra_height: float = 1.0
@export_range(0.0, 10.0, 0.1, "or_greater", "suffix:m") var airborne_extra_distance: float = 1.0
@export_range(0.0, 10.0, 0.1, "or_greater", "suffix:m") var airborne_extra_look_ahead: float = 1.0

@export_group("Manual Look")
@export_range(0.0, 180.0, 0.1, "degrees") var maximum_manual_yaw_degrees: float = 60.0
@export_range(0.0, 720.0, 1.0, "or_greater", "suffix:deg/s") var manual_yaw_speed_degrees: float = 110.0
@export_range(0.0, 720.0, 1.0, "or_greater", "suffix:deg/s") var manual_return_speed_degrees: float = 140.0
@export_range(0.01, 30.0, 0.1, "or_greater") var manual_look_sharpness: float = 8.0

@export_group("Reset")
@export_range(0.1, 100.0, 0.1, "or_greater", "suffix:m") var target_teleport_snap_distance: float = 4.0

var current_camera_distance: float:
	get:
		return _current_camera_distance

var target_camera_distance: float:
	get:
		return _target_camera_distance

var current_camera_height: float:
	get:
		return _current_camera_height

var target_camera_height: float:
	get:
		return _target_camera_height

var current_manual_yaw_degrees: float:
	get:
		return _current_manual_yaw_degrees

var current_fov: float:
	get:
		return _camera.fov if _camera != null else 0.0

var target_fov: float:
	get:
		return _target_fov

var horizontal_speed: float:
	get:
		return _horizontal_speed

var position_follow_error: float:
	get:
		return _position_follow_error

var look_follow_error: float:
	get:
		return _look_follow_error

var is_airborne_camera_active: bool:
	get:
		return _is_airborne_camera_active

var camera_snap_count: int:
	get:
		return _camera_snap_count

var camera_rebase_count: int:
	get:
		return _camera_rebase_count

@onready var _camera: Camera3D = $Camera3D as Camera3D

var _vehicle_body: JetSkiController
var _camera_target: Node3D
var _reference_warning_emitted: bool = false
var _current_camera_distance: float = 0.0
var _target_camera_distance: float = 0.0
var _current_camera_height: float = 0.0
var _target_camera_height: float = 0.0
var _current_look_ahead: float = 0.0
var _target_look_ahead: float = 0.0
var _target_fov: float = 0.0
var _horizontal_speed: float = 0.0
var _position_follow_error: float = 0.0
var _look_follow_error: float = 0.0
var _is_airborne_camera_active: bool = false
var _camera_snap_count: int = 0
var _camera_rebase_count: int = 0
var _target_manual_yaw_degrees: float = 0.0
var _current_manual_yaw_degrees: float = 0.0
var _current_look_position: Vector3 = Vector3.ZERO
var _last_horizontal_forward: Vector3 = Vector3.FORWARD
var _last_target_position: Vector3 = Vector3.ZERO
var _has_last_target_position: bool = false
var _snap_requested: bool = false
var _teleport_fallback_ignore_frames: int = 0


func _ready() -> void:
	process_priority = 50
	physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	if _camera != null:
		_camera.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	_resolve_references()
	if not _has_valid_references():
		_warn_about_invalid_references_once()
		set_process(false)
		return
	if not _vehicle_body.reset_completed.is_connected(_on_vehicle_reset_completed):
		_vehicle_body.reset_completed.connect(_on_vehicle_reset_completed)
	snap_to_target()


func _process(delta: float) -> void:
	if not _has_valid_references() or delta <= 0.0:
		return
	if _snap_requested:
		_snap_requested = false
		snap_to_target()
		return
	var target_transform := _get_camera_target_transform()
	var target_position := target_transform.origin
	var ignore_teleport_fallback := _teleport_fallback_ignore_frames > 0
	_teleport_fallback_ignore_frames = maxi(_teleport_fallback_ignore_frames - 1, 0)
	if (
		not ignore_teleport_fallback
		and
		_has_last_target_position
		and target_position.distance_to(_last_target_position) > target_teleport_snap_distance
	):
		snap_to_target()
		return
	_horizontal_speed = Vector2(
		_vehicle_body.linear_velocity.x,
		_vehicle_body.linear_velocity.z
	).length()
	_is_airborne_camera_active = (
		_vehicle_body.navigation_state == JetSkiController.NavigationState.AIRBORNE
	)
	var horizontal_forward := _get_horizontal_forward(target_transform.basis)
	_update_manual_look(delta)
	var camera_forward := horizontal_forward.rotated(
		Vector3.UP,
		deg_to_rad(_current_manual_yaw_degrees)
	).normalized()
	_update_dynamic_targets()
	var distance_factor := _exponential_factor(distance_sharpness, delta)
	_current_camera_distance = lerpf(
		_current_camera_distance,
		_target_camera_distance,
		distance_factor
	)
	_current_camera_height = lerpf(
		_current_camera_height,
		_target_camera_height,
		distance_factor
	)
	_current_look_ahead = lerpf(
		_current_look_ahead,
		_target_look_ahead,
		distance_factor
	)
	var desired_position := _calculate_desired_position(target_position, camera_forward)
	var position_factor := _exponential_factor(position_sharpness, delta)
	global_position = global_position.lerp(desired_position, position_factor)
	var desired_look_position := _calculate_desired_look_position(
		target_position,
		camera_forward
	)
	_current_look_position = _current_look_position.lerp(
		desired_look_position,
		position_factor
	)
	_update_rotation(delta)
	if _camera != null:
		_camera.fov = lerpf(
			_camera.fov,
			_target_fov,
			_exponential_factor(fov_sharpness, delta)
		)
	_position_follow_error = global_position.distance_to(desired_position)
	_look_follow_error = _current_look_position.distance_to(desired_look_position)
	_last_target_position = target_position
	_has_last_target_position = true


func snap_to_target() -> void:
	if not _has_valid_references():
		return
	var target_transform := _get_camera_target_transform()
	var target_position := target_transform.origin
	_horizontal_speed = Vector2(
		_vehicle_body.linear_velocity.x,
		_vehicle_body.linear_velocity.z
	).length()
	_is_airborne_camera_active = (
		_vehicle_body.navigation_state == JetSkiController.NavigationState.AIRBORNE
	)
	_target_manual_yaw_degrees = 0.0
	_current_manual_yaw_degrees = 0.0
	var horizontal_forward := _get_horizontal_forward(target_transform.basis)
	_update_dynamic_targets()
	_current_camera_distance = _target_camera_distance
	_current_camera_height = _target_camera_height
	_current_look_ahead = _target_look_ahead
	var desired_position := _calculate_desired_position(
		target_position,
		horizontal_forward
	)
	_current_look_position = _calculate_desired_look_position(
		target_position,
		horizontal_forward
	)
	global_transform = Transform3D(
		_calculate_upright_look_basis(desired_position, _current_look_position),
		desired_position
	)
	if _camera != null:
		_camera.fov = _target_fov
	_position_follow_error = 0.0
	_look_follow_error = 0.0
	_last_target_position = target_position
	_has_last_target_position = true
	_snap_requested = false
	_camera_snap_count += 1


func get_camera_node() -> Camera3D:
	return _camera


func get_vehicle_body() -> JetSkiController:
	return _vehicle_body


func get_camera_target() -> Node3D:
	return _camera_target


func _get_camera_target_transform() -> Transform3D:
	# A reset/rebase clears interpolation histories during the physics step. For
	# the next visual frames the direct transform is the authoritative one; using
	# a stale interpolated child transform here could pull the rig back toward the
	# pre-reset world position after the one intentional snap.
	if _teleport_fallback_ignore_frames > 0:
		return _camera_target.global_transform
	return _camera_target.get_global_transform_interpolated()


func apply_world_rebase(shift: Vector3) -> void:
	var horizontal_shift := Vector3(shift.x, 0.0, shift.z)
	if horizontal_shift.is_zero_approx() or not horizontal_shift.is_finite():
		return
	global_position -= horizontal_shift
	_current_look_position -= horizontal_shift
	if _has_last_target_position:
		_last_target_position -= horizontal_shift
	if is_instance_valid(_camera_target):
		_camera_target.reset_physics_interpolation()
	_teleport_fallback_ignore_frames = 2
	_camera_rebase_count += 1


func _resolve_references() -> void:
	_vehicle_body = get_node_or_null(vehicle_body_path) as JetSkiController
	_camera_target = get_node_or_null(camera_target_path) as Node3D


func _has_valid_references() -> bool:
	return (
		is_instance_valid(_vehicle_body)
		and is_instance_valid(_camera_target)
		and is_instance_valid(_camera)
	)


func _warn_about_invalid_references_once() -> void:
	if _reference_warning_emitted:
		return
	_reference_warning_emitted = true
	push_warning(
		"ChaseCamera follow is disabled because vehicle_body, camera_target, or Camera3D is invalid."
	)


func _update_manual_look(delta: float) -> void:
	var manual_look_input := clampf(
		Input.get_action_strength("camera_look_right")
		- Input.get_action_strength("camera_look_left"),
		-1.0,
		1.0
	)
	if not is_zero_approx(manual_look_input):
		var input_target := manual_look_input * maximum_manual_yaw_degrees
		_target_manual_yaw_degrees = move_toward(
			_target_manual_yaw_degrees,
			input_target,
			manual_yaw_speed_degrees * absf(manual_look_input) * delta
		)
	else:
		_target_manual_yaw_degrees = move_toward(
			_target_manual_yaw_degrees,
			0.0,
			manual_return_speed_degrees * delta
		)
	_current_manual_yaw_degrees = lerpf(
		_current_manual_yaw_degrees,
		_target_manual_yaw_degrees,
		_exponential_factor(manual_look_sharpness, delta)
	)
	_current_manual_yaw_degrees = clampf(
		_current_manual_yaw_degrees,
		-maximum_manual_yaw_degrees,
		maximum_manual_yaw_degrees
	)


func _update_dynamic_targets() -> void:
	var distance_ratio := _inverse_lerp_clamped(
		distance_extension_start_speed,
		distance_extension_end_speed,
		_horizontal_speed
	)
	var fov_ratio := _inverse_lerp_clamped(
		fov_start_speed,
		fov_end_speed,
		_horizontal_speed
	)
	_target_camera_distance = (
		base_distance
		+ maximum_speed_distance_extension * distance_ratio
		+ (airborne_extra_distance if _is_airborne_camera_active else 0.0)
	)
	_target_camera_height = (
		base_height
		+ (airborne_extra_height if _is_airborne_camera_active else 0.0)
	)
	_target_look_ahead = (
		base_look_ahead
		+ (airborne_extra_look_ahead if _is_airborne_camera_active else 0.0)
	)
	_target_fov = lerpf(base_fov, maximum_speed_fov, fov_ratio)


func _get_horizontal_forward(target_basis: Basis) -> Vector3:
	var body_forward := -target_basis.z
	var horizontal_forward := (
		body_forward - Vector3.UP * body_forward.dot(Vector3.UP)
	)
	if horizontal_forward.length_squared() <= 0.000001:
		return _last_horizontal_forward
	_last_horizontal_forward = horizontal_forward.normalized()
	return _last_horizontal_forward


func _calculate_desired_position(
	target_position: Vector3,
	camera_forward: Vector3
) -> Vector3:
	return (
		target_position
		- camera_forward * _current_camera_distance
		+ Vector3.UP * _current_camera_height
	)


func _calculate_desired_look_position(
	target_position: Vector3,
	camera_forward: Vector3
) -> Vector3:
	return (
		target_position
		+ camera_forward * _current_look_ahead
		+ Vector3.UP * look_height_offset
	)


func _update_rotation(delta: float) -> void:
	var look_direction := _current_look_position - global_position
	if look_direction.length_squared() <= 0.000001:
		return
	var desired_basis := Basis.looking_at(look_direction.normalized(), Vector3.UP)
	var current_quaternion := global_basis.orthonormalized().get_rotation_quaternion()
	var desired_quaternion := desired_basis.get_rotation_quaternion()
	var smoothed_quaternion := current_quaternion.slerp(
		desired_quaternion,
		_exponential_factor(rotation_sharpness, delta)
	).normalized()
	var smoothed_forward := -Basis(smoothed_quaternion).z
	if smoothed_forward.length_squared() <= 0.000001:
		return
	global_basis = Basis.looking_at(smoothed_forward.normalized(), Vector3.UP)


func _calculate_upright_look_basis(from: Vector3, to: Vector3) -> Basis:
	var look_direction := to - from
	if look_direction.length_squared() <= 0.000001:
		look_direction = _last_horizontal_forward
	return Basis.looking_at(look_direction.normalized(), Vector3.UP)


func _on_vehicle_reset_completed(_reason: StringName) -> void:
	# The rigid body clears its own interpolation history during reset. Clearing
	# the visual target as well prevents one stale child transform on long jumps.
	if is_instance_valid(_camera_target):
		_camera_target.reset_physics_interpolation()
	_teleport_fallback_ignore_frames = 2
	_snap_requested = true


func _exponential_factor(sharpness: float, delta: float) -> float:
	return 1.0 - exp(-maxf(sharpness, 0.0) * maxf(delta, 0.0))


func _inverse_lerp_clamped(from: float, to: float, value: float) -> float:
	if to <= from:
		return 1.0 if value >= to else 0.0
	return clampf(inverse_lerp(from, to, value), 0.0, 1.0)
