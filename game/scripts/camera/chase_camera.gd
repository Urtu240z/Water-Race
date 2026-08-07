class_name ChaseCamera
extends Node3D

enum CameraMode {
	ARCADE,
	FIRST_PERSON,
}

enum ArcadeCameraState {
	NORMAL,
	STUNT,
	RECOVERING,
}

@export_group("References")
@export_node_path("RigidBody3D") var vehicle_body_path: NodePath
@export_node_path("Node3D") var camera_target_path: NodePath
@export_node_path("Node3D") var first_person_socket_path: NodePath
@export var first_person_hidden_visual_paths: Array[NodePath] = []

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

@export_group("Arcade Stunt")
@export_range(0.1, 50.0, 0.1, "or_greater", "suffix:m") var stunt_arcade_distance: float = 5.0
@export_range(0.0, 20.0, 0.1, "or_greater", "suffix:m") var stunt_arcade_height: float = 1.8
@export_range(0.0, 30.0, 0.1, "or_greater", "suffix:m") var stunt_arcade_look_ahead: float = 0.4
@export_range(1.0, 179.0, 0.1, "degrees") var stunt_arcade_fov: float = 57.0
@export_range(0.01, 60.0, 0.1, "or_greater") var stunt_entry_sharpness: float = 10.0
@export_range(0.01, 60.0, 0.1, "or_greater") var stunt_exit_sharpness: float = 6.0
@export_range(0.05, 3.0, 0.05, "or_greater", "suffix:s") var stunt_recovery_duration: float = 0.4
@export_range(0.05, 0.5, 0.01, "or_greater", "suffix:s") var stunt_exit_confirmation_duration: float = 0.12
@export_range(-1.0, 1.0, 0.05) var stunt_exit_minimum_up_dot: float = 0.25

@export_group("First Person")
@export_range(1.0, 179.0, 0.1, "degrees") var first_person_fov: float = 80.0
@export_range(0.01, 1.0, 0.01, "or_greater", "suffix:m") var first_person_near: float = 0.04
@export_range(0.01, 60.0, 0.1, "or_greater") var first_person_position_sharpness: float = 18.0
@export_range(0.01, 60.0, 0.1, "or_greater") var first_person_rotation_sharpness: float = 24.0
@export var first_person_local_position_offset: Vector3 = Vector3.ZERO
@export var first_person_local_rotation_offset_degrees: Vector3 = Vector3.ZERO

@export_group("Camera Mode Transition")
@export_range(0.0, 2.0, 0.01, "or_greater", "suffix:s") var camera_mode_transition_duration: float = 0.25

@export_group("Manual Look")
@export_range(0.0, 180.0, 0.1, "degrees") var maximum_manual_yaw_degrees: float = 60.0
@export_range(0.0, 720.0, 1.0, "or_greater", "suffix:deg/s") var manual_yaw_speed_degrees: float = 110.0
@export_range(0.0, 720.0, 1.0, "or_greater", "suffix:deg/s") var manual_return_speed_degrees: float = 140.0
@export_range(0.01, 30.0, 0.1, "or_greater") var manual_look_sharpness: float = 8.0

@export_group("Reset")
@export_range(0.1, 100.0, 0.1, "or_greater", "suffix:m") var target_teleport_snap_distance: float = 4.0

var current_camera_mode: CameraMode = CameraMode.ARCADE

var is_first_person: bool:
	get:
		return current_camera_mode == CameraMode.FIRST_PERSON

var arcade_camera_state: ArcadeCameraState = ArcadeCameraState.NORMAL

var is_stunt_camera_active: bool:
	get:
		return arcade_camera_state == ArcadeCameraState.STUNT

var camera_mode_transition_ratio: float = 1.0

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
var _first_person_socket: Node3D
var _reference_warning_emitted: bool = false
var _first_person_socket_warning_emitted: bool = false
var _current_camera_distance: float = 0.0
var _target_camera_distance: float = 0.0
var _current_camera_height: float = 0.0
var _target_camera_height: float = 0.0
var _current_look_ahead: float = 0.0
var _target_look_ahead: float = 0.0
var _target_fov: float = 0.0
var _arcade_near: float = 0.05
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
var _stunt_horizontal_forward: Vector3 = Vector3.FORWARD
var _stunt_locked_basis: Basis = Basis.IDENTITY
var _stunt_has_been_airborne: bool = false
var _stunt_grounded_confirmation_elapsed: float = 0.0
var _stunt_recovery_elapsed: float = 0.0
var _recovery_start_distance: float = 0.0
var _recovery_start_height: float = 0.0
var _recovery_start_look_ahead: float = 0.0
var _recovery_start_fov: float = 0.0
var _camera_target_vehicle_local_position: Vector3 = Vector3.ZERO
var _last_target_position: Vector3 = Vector3.ZERO
var _has_last_target_position: bool = false
var _snap_requested: bool = false
var _teleport_fallback_ignore_frames: int = 0
var _last_camera_toggle_frame: int = -1
var _mode_transition_active: bool = false
var _mode_transition_elapsed: float = 0.0
var _mode_transition_from: CameraMode = CameraMode.ARCADE
var _mode_transition_start_transform: Transform3D = Transform3D.IDENTITY
var _mode_transition_start_fov: float = 65.0
var _mode_transition_start_near: float = 0.05
var _mode_transition_anchor_position: Vector3 = Vector3.ZERO
var _first_person_hidden_visuals: Array[Node3D] = []
var _first_person_original_visibility: Dictionary = {}


func _ready() -> void:
	process_priority = 50
	physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	if _camera != null:
		_camera.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
		_arcade_near = _camera.near
	_resolve_references()
	if not _has_valid_references():
		_warn_about_invalid_references_once()
		set_process(false)
		return
	if not _vehicle_body.reset_completed.is_connected(_on_vehicle_reset_completed):
		_vehicle_body.reset_completed.connect(_on_vehicle_reset_completed)
	if not _vehicle_body.rider_trick_launched.is_connected(_on_rider_trick_launched):
		_vehicle_body.rider_trick_launched.connect(_on_rider_trick_launched)
	if current_camera_mode == CameraMode.FIRST_PERSON and not _has_first_person_socket():
		current_camera_mode = CameraMode.ARCADE
		_warn_about_missing_first_person_socket_once()
	_set_first_person_visibility(current_camera_mode == CameraMode.FIRST_PERSON)
	snap_to_target()


func _process(delta: float) -> void:
	if not _has_valid_references() or delta <= 0.0:
		return
	if get_tree() != null and get_tree().paused:
		return
	_update_camera_mode_input()
	if current_camera_mode == CameraMode.FIRST_PERSON and not _has_first_person_socket():
		_fallback_to_arcade_for_missing_socket()
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
		and _has_last_target_position
		and target_position.distance_to(_last_target_position) > target_teleport_snap_distance
	):
		snap_to_target()
		return
	_update_vehicle_camera_state(delta)
	_update_arcade_camera_state(delta)
	_update_manual_look(delta)
	var arcade_target := _update_arcade_camera(delta, target_transform)
	var first_person_target := _update_first_person_camera()
	var desired_transform := arcade_target
	var desired_fov := _target_fov
	var desired_near := _arcade_near
	if current_camera_mode == CameraMode.FIRST_PERSON:
		desired_transform = first_person_target
		desired_fov = first_person_fov
		desired_near = first_person_near
	if not desired_transform.is_finite():
		_snap_requested = true
		return
	if _mode_transition_active:
		_update_mode_transition(
			delta,
			desired_transform,
			desired_fov,
			desired_near,
			target_position
		)
	elif current_camera_mode == CameraMode.FIRST_PERSON:
		_apply_smoothed_transform(
			desired_transform,
			first_person_position_sharpness,
			first_person_rotation_sharpness,
			delta
		)
		_update_camera_lens(
			desired_fov,
			desired_near,
			first_person_position_sharpness,
			delta
		)
	else:
		_apply_smoothed_arcade_transform(desired_transform, delta)
		_update_camera_lens(
			desired_fov,
			desired_near,
			_get_arcade_fov_sharpness(),
			delta
		)
	_update_first_person_transition_visibility()
	_position_follow_error = (
		global_position.distance_to(arcade_target.origin)
		if current_camera_mode == CameraMode.ARCADE
		else global_position.distance_to(first_person_target.origin)
	)
	_last_target_position = target_position
	_has_last_target_position = true


func snap_to_target() -> void:
	if not _has_valid_references():
		return
	if current_camera_mode == CameraMode.FIRST_PERSON and not _has_first_person_socket():
		current_camera_mode = CameraMode.ARCADE
		_warn_about_missing_first_person_socket_once()
	_update_vehicle_camera_state(0.0)
	_target_manual_yaw_degrees = 0.0
	_current_manual_yaw_degrees = 0.0
	var target_transform := _get_camera_target_transform()
	_set_arcade_dynamic_targets()
	_current_camera_distance = _target_camera_distance
	_current_camera_height = _target_camera_height
	_current_look_ahead = _target_look_ahead
	var horizontal_forward := _get_arcade_horizontal_forward(target_transform.basis)
	var arcade_target_position := _get_arcade_target_position(target_transform)
	var desired_position := _calculate_desired_position(
		arcade_target_position,
		horizontal_forward
	)
	_current_look_position = _calculate_desired_look_position(
		arcade_target_position,
		horizontal_forward
	)
	var desired_transform := Transform3D(
		_calculate_upright_look_basis(desired_position, _current_look_position),
		desired_position
	)
	var desired_fov := _target_fov
	var desired_near := _arcade_near
	if current_camera_mode == CameraMode.FIRST_PERSON:
		desired_transform = _get_first_person_target_transform()
		desired_fov = first_person_fov
		desired_near = first_person_near
	if desired_transform.is_finite():
		global_transform = desired_transform
	if _camera != null:
		_camera.fov = desired_fov
		_camera.near = desired_near
	_position_follow_error = 0.0
	_look_follow_error = 0.0
	_last_target_position = target_transform.origin
	_has_last_target_position = true
	_snap_requested = false
	_cancel_mode_transition()
	_set_first_person_visibility(current_camera_mode == CameraMode.FIRST_PERSON)
	_camera_snap_count += 1


func get_camera_node() -> Camera3D:
	return _camera


func get_vehicle_body() -> JetSkiController:
	return _vehicle_body


func get_camera_target() -> Node3D:
	return _camera_target


func get_first_person_socket() -> Node3D:
	return _first_person_socket


func apply_world_rebase(shift: Vector3) -> void:
	var horizontal_shift := Vector3(shift.x, 0.0, shift.z)
	if horizontal_shift.is_zero_approx() or not horizontal_shift.is_finite():
		return
	global_position -= horizontal_shift
	_current_look_position -= horizontal_shift
	if _has_last_target_position:
		_last_target_position -= horizontal_shift
	if _mode_transition_active:
		_mode_transition_start_transform.origin -= horizontal_shift
		_mode_transition_anchor_position -= horizontal_shift
	if is_instance_valid(_camera_target):
		_camera_target.reset_physics_interpolation()
	if is_instance_valid(_first_person_socket):
		_first_person_socket.reset_physics_interpolation()
	_teleport_fallback_ignore_frames = 2
	_camera_rebase_count += 1


func _update_camera_mode_input() -> void:
	if not Input.is_action_just_pressed(&"camera_toggle"):
		return
	var process_frame := Engine.get_process_frames()
	if process_frame == _last_camera_toggle_frame:
		return
	_last_camera_toggle_frame = process_frame
	var next_mode := (
		CameraMode.FIRST_PERSON
		if current_camera_mode == CameraMode.ARCADE
		else CameraMode.ARCADE
	)
	_enter_camera_mode(next_mode)


func _enter_camera_mode(next_mode: CameraMode) -> void:
	if next_mode == current_camera_mode:
		return
	if next_mode == CameraMode.FIRST_PERSON and not _has_first_person_socket():
		_warn_about_missing_first_person_socket_once()
		return
	_mode_transition_from = current_camera_mode
	current_camera_mode = next_mode
	_mode_transition_elapsed = 0.0
	camera_mode_transition_ratio = 0.0
	_mode_transition_start_transform = global_transform
	_mode_transition_start_fov = _camera.fov
	_mode_transition_start_near = _camera.near
	_mode_transition_anchor_position = _get_camera_target_transform().origin
	_mode_transition_active = camera_mode_transition_duration > 0.0001
	if not _mode_transition_active:
		camera_mode_transition_ratio = 1.0
	_set_first_person_visibility(_should_hide_first_person_visuals())


func _update_arcade_camera(
	delta: float,
	target_transform: Transform3D
) -> Transform3D:
	_set_arcade_dynamic_targets()
	var parameter_factor := _exponential_factor(
		_get_arcade_parameter_sharpness(),
		delta
	)
	_current_camera_distance = lerpf(
		_current_camera_distance,
		_target_camera_distance,
		parameter_factor
	)
	_current_camera_height = lerpf(
		_current_camera_height,
		_target_camera_height,
		parameter_factor
	)
	_current_look_ahead = lerpf(
		_current_look_ahead,
		_target_look_ahead,
		parameter_factor
	)
	var horizontal_forward := _get_arcade_horizontal_forward(target_transform.basis)
	var arcade_target_position := _get_arcade_target_position(target_transform)
	var camera_forward := horizontal_forward.rotated(
		Vector3.UP,
		deg_to_rad(_current_manual_yaw_degrees)
	).normalized()
	var desired_position := _calculate_desired_position(
		arcade_target_position,
		camera_forward
	)
	var desired_look_position := _calculate_desired_look_position(
		arcade_target_position,
		camera_forward
	)
	_current_look_position = _current_look_position.lerp(
		desired_look_position,
		_exponential_factor(_get_arcade_follow_sharpness(), delta)
	)
	_look_follow_error = _current_look_position.distance_to(desired_look_position)
	var desired_basis := _calculate_upright_look_basis(
		desired_position,
		desired_look_position
	)
	if arcade_camera_state == ArcadeCameraState.STUNT:
		desired_basis = _stunt_locked_basis
	return Transform3D(desired_basis, desired_position)


func _update_first_person_camera() -> Transform3D:
	if not _has_first_person_socket():
		return global_transform
	return _get_first_person_target_transform()


func _begin_arcade_stunt() -> void:
	_stunt_horizontal_forward = _get_stable_stunt_launch_forward(
		_get_camera_target_transform().basis
	)
	_stunt_locked_basis = _calculate_locked_stunt_basis()
	arcade_camera_state = ArcadeCameraState.STUNT
	_stunt_has_been_airborne = (
		_vehicle_body.navigation_state == JetSkiController.NavigationState.AIRBORNE
	)
	_stunt_grounded_confirmation_elapsed = 0.0
	_stunt_recovery_elapsed = 0.0


func _end_arcade_stunt() -> void:
	if arcade_camera_state != ArcadeCameraState.STUNT:
		return
	arcade_camera_state = ArcadeCameraState.RECOVERING
	_stunt_recovery_elapsed = 0.0
	_recovery_start_distance = _current_camera_distance
	_recovery_start_height = _current_camera_height
	_recovery_start_look_ahead = _current_look_ahead
	_recovery_start_fov = _target_fov


func _update_arcade_camera_state(delta: float) -> void:
	if arcade_camera_state == ArcadeCameraState.STUNT:
		if _is_airborne_camera_active:
			_stunt_has_been_airborne = true
			_stunt_grounded_confirmation_elapsed = 0.0
			return
		if _stunt_has_been_airborne:
			if not _has_stable_stunt_exit_orientation():
				_stunt_grounded_confirmation_elapsed = 0.0
				return
			_stunt_grounded_confirmation_elapsed += delta
			if (
				_stunt_grounded_confirmation_elapsed
				>= stunt_exit_confirmation_duration
			):
				_end_arcade_stunt()
			return
		# Some ramp contacts keep navigation out of AIRBORNE for a few visual
		# frames. Never time out the stunt camera while a signalled rotation may
		# be starting; arm its landing check as soon as body rotation is visible.
		var body_up := _vehicle_body.global_basis.y.normalized()
		if absf(body_up.dot(Vector3.UP)) < 0.95:
			_stunt_has_been_airborne = true
	elif arcade_camera_state == ArcadeCameraState.RECOVERING:
		_stunt_recovery_elapsed += delta
		if _stunt_recovery_elapsed >= maxf(stunt_recovery_duration, 0.0001):
			arcade_camera_state = ArcadeCameraState.NORMAL
			_stunt_recovery_elapsed = stunt_recovery_duration


func _update_mode_transition(
	delta: float,
	desired_transform: Transform3D,
	desired_fov: float,
	desired_near: float,
	target_position: Vector3
) -> void:
	var anchor_delta := target_position - _mode_transition_anchor_position
	if anchor_delta.is_finite():
		_mode_transition_start_transform.origin += anchor_delta
	_mode_transition_anchor_position = target_position
	_mode_transition_elapsed += delta
	var duration := maxf(camera_mode_transition_duration, 0.0001)
	camera_mode_transition_ratio = clampf(
		_mode_transition_elapsed / duration,
		0.0,
		1.0
	)
	var eased_ratio := _smoothstep_ratio(camera_mode_transition_ratio)
	var blended_transform := _interpolate_transform(
		_mode_transition_start_transform,
		desired_transform,
		eased_ratio
	)
	if blended_transform.is_finite():
		global_transform = blended_transform
	_camera.fov = lerpf(_mode_transition_start_fov, desired_fov, eased_ratio)
	_camera.near = lerpf(_mode_transition_start_near, desired_near, eased_ratio)
	if camera_mode_transition_ratio >= 1.0:
		_mode_transition_active = false
		global_transform = desired_transform
		_camera.fov = desired_fov
		_camera.near = desired_near
		_set_first_person_visibility(current_camera_mode == CameraMode.FIRST_PERSON)


func _set_first_person_visibility(hidden: bool) -> void:
	for visual: Node3D in _first_person_hidden_visuals:
		if not is_instance_valid(visual):
			continue
		if hidden:
			if not _first_person_original_visibility.has(visual):
				_first_person_original_visibility[visual] = visual.visible
			visual.visible = false
		elif _first_person_original_visibility.has(visual):
			visual.visible = bool(_first_person_original_visibility[visual])
	if not hidden:
		_first_person_original_visibility.clear()


func _update_first_person_transition_visibility() -> void:
	_set_first_person_visibility(_should_hide_first_person_visuals())


func _should_hide_first_person_visuals() -> bool:
	if not _mode_transition_active:
		return current_camera_mode == CameraMode.FIRST_PERSON
	if current_camera_mode == CameraMode.FIRST_PERSON:
		return camera_mode_transition_ratio >= 0.45
	return (
		_mode_transition_from == CameraMode.FIRST_PERSON
		and camera_mode_transition_ratio < 0.55
	)


func _update_vehicle_camera_state(_delta: float) -> void:
	_horizontal_speed = Vector2(
		_vehicle_body.linear_velocity.x,
		_vehicle_body.linear_velocity.z
	).length()
	_is_airborne_camera_active = (
		_vehicle_body.navigation_state == JetSkiController.NavigationState.AIRBORNE
	)


func _set_arcade_dynamic_targets() -> void:
	var normal_targets := _calculate_normal_arcade_targets()
	if arcade_camera_state == ArcadeCameraState.STUNT:
		_target_camera_distance = stunt_arcade_distance
		_target_camera_height = stunt_arcade_height
		_target_look_ahead = stunt_arcade_look_ahead
		_target_fov = stunt_arcade_fov
		return
	if arcade_camera_state == ArcadeCameraState.RECOVERING:
		var recovery_ratio := _smoothstep_ratio(
			clampf(
				_stunt_recovery_elapsed / maxf(stunt_recovery_duration, 0.0001),
				0.0,
				1.0
			)
		)
		_target_camera_distance = lerpf(
			_recovery_start_distance,
			float(normal_targets[&"distance"]),
			recovery_ratio
		)
		_target_camera_height = lerpf(
			_recovery_start_height,
			float(normal_targets[&"height"]),
			recovery_ratio
		)
		_target_look_ahead = lerpf(
			_recovery_start_look_ahead,
			float(normal_targets[&"look_ahead"]),
			recovery_ratio
		)
		_target_fov = lerpf(
			_recovery_start_fov,
			float(normal_targets[&"fov"]),
			recovery_ratio
		)
		return
	_target_camera_distance = float(normal_targets[&"distance"])
	_target_camera_height = float(normal_targets[&"height"])
	_target_look_ahead = float(normal_targets[&"look_ahead"])
	_target_fov = float(normal_targets[&"fov"])


func _calculate_normal_arcade_targets() -> Dictionary:
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
	return {
		&"distance": (
			base_distance
			+ maximum_speed_distance_extension * distance_ratio
			+ (airborne_extra_distance if _is_airborne_camera_active else 0.0)
		),
		&"height": (
			base_height
			+ (airborne_extra_height if _is_airborne_camera_active else 0.0)
		),
		&"look_ahead": (
			base_look_ahead
			+ (airborne_extra_look_ahead if _is_airborne_camera_active else 0.0)
		),
		&"fov": lerpf(base_fov, maximum_speed_fov, fov_ratio),
	}


func _get_arcade_horizontal_forward(target_basis: Basis) -> Vector3:
	if arcade_camera_state == ArcadeCameraState.STUNT:
		return _stunt_horizontal_forward
	var live_forward := _get_horizontal_forward(target_basis)
	if arcade_camera_state != ArcadeCameraState.RECOVERING:
		return live_forward
	var recovery_ratio := _smoothstep_ratio(
		clampf(
			_stunt_recovery_elapsed / maxf(stunt_recovery_duration, 0.0001),
			0.0,
			1.0
		)
	)
	return _interpolate_horizontal_direction(
		_stunt_horizontal_forward,
		live_forward,
		recovery_ratio
	)


func _get_arcade_target_position(target_transform: Transform3D) -> Vector3:
	if arcade_camera_state == ArcadeCameraState.NORMAL:
		return target_transform.origin
	var stabilized_position := _get_stabilized_stunt_target_position()
	if arcade_camera_state == ArcadeCameraState.STUNT:
		return stabilized_position
	var recovery_ratio := _smoothstep_ratio(
		clampf(
			_stunt_recovery_elapsed / maxf(stunt_recovery_duration, 0.0001),
			0.0,
			1.0
		)
	)
	return stabilized_position.lerp(target_transform.origin, recovery_ratio)


func _get_stabilized_stunt_target_position() -> Vector3:
	var vehicle_transform := _get_vehicle_visual_transform()
	var upright_basis := Basis.looking_at(
		_stunt_horizontal_forward,
		Vector3.UP
	).scaled(vehicle_transform.basis.get_scale())
	return (
		vehicle_transform.origin
		+ upright_basis * _camera_target_vehicle_local_position
	)


func _calculate_locked_stunt_basis() -> Basis:
	var horizontal_span := maxf(
		_current_camera_distance + _current_look_ahead,
		0.001
	)
	var vertical_span := look_height_offset - _current_camera_height
	var locked_forward := (
		_stunt_horizontal_forward * horizontal_span
		+ Vector3.UP * vertical_span
	).normalized()
	if locked_forward.length_squared() <= 0.000001:
		locked_forward = _stunt_horizontal_forward
	return Basis.looking_at(locked_forward, Vector3.UP)


func _has_stable_stunt_exit_orientation() -> bool:
	var body_up := _vehicle_body.global_basis.y
	if body_up.length_squared() <= 0.000001:
		return false
	if body_up.normalized().dot(Vector3.UP) < stunt_exit_minimum_up_dot:
		return false
	var body_forward := -_vehicle_body.global_basis.z
	var horizontal_forward := Vector3(body_forward.x, 0.0, body_forward.z)
	if horizontal_forward.length_squared() <= 0.000001:
		return false
	return horizontal_forward.normalized().dot(_stunt_horizontal_forward) > 0.0


func _get_stable_stunt_launch_forward(target_basis: Basis) -> Vector3:
	var remembered_forward := _last_horizontal_forward
	if remembered_forward.length_squared() <= 0.000001:
		remembered_forward = Vector3.FORWARD
	var horizontal_velocity := Vector3(
		_vehicle_body.linear_velocity.x,
		0.0,
		_vehicle_body.linear_velocity.z
	)
	if horizontal_velocity.length_squared() > 0.25:
		var velocity_forward := horizontal_velocity.normalized()
		if velocity_forward.dot(remembered_forward) >= -0.1:
			return velocity_forward
	var body_forward := -target_basis.z
	var projected_forward := Vector3(body_forward.x, 0.0, body_forward.z)
	if projected_forward.length_squared() > 0.04:
		projected_forward = projected_forward.normalized()
		if projected_forward.dot(remembered_forward) > 0.0:
			return projected_forward
	return remembered_forward.normalized()


func _get_horizontal_forward(target_basis: Basis) -> Vector3:
	var body_forward := -target_basis.z
	var horizontal_forward := Vector3(body_forward.x, 0.0, body_forward.z)
	if horizontal_forward.length_squared() <= 0.000001:
		return _last_horizontal_forward
	_last_horizontal_forward = horizontal_forward.normalized()
	return _last_horizontal_forward


func _get_first_person_target_transform() -> Transform3D:
	var socket_transform := _get_first_person_socket_transform()
	var offset_basis := Basis.from_euler(
		Vector3(
			deg_to_rad(first_person_local_rotation_offset_degrees.x),
			deg_to_rad(first_person_local_rotation_offset_degrees.y),
			deg_to_rad(first_person_local_rotation_offset_degrees.z)
		)
	)
	return socket_transform * Transform3D(
		offset_basis,
		first_person_local_position_offset
	)


func _get_camera_target_transform() -> Transform3D:
	if _teleport_fallback_ignore_frames > 0:
		return _camera_target.global_transform
	return _camera_target.get_global_transform_interpolated()


func _get_vehicle_visual_transform() -> Transform3D:
	if _teleport_fallback_ignore_frames > 0:
		return _vehicle_body.global_transform
	return _vehicle_body.get_global_transform_interpolated()


func _get_first_person_socket_transform() -> Transform3D:
	if _teleport_fallback_ignore_frames > 0:
		return _first_person_socket.global_transform
	return _first_person_socket.get_global_transform_interpolated()


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


func _calculate_upright_look_basis(from: Vector3, to: Vector3) -> Basis:
	var look_direction := to - from
	if look_direction.length_squared() <= 0.000001:
		look_direction = _last_horizontal_forward
	return Basis.looking_at(look_direction.normalized(), Vector3.UP)


func _apply_smoothed_transform(
	desired_transform: Transform3D,
	position_response: float,
	rotation_response: float,
	delta: float
) -> void:
	var next_position := global_position.lerp(
		desired_transform.origin,
		_exponential_factor(position_response, delta)
	)
	var current_quaternion := global_basis.orthonormalized().get_rotation_quaternion()
	var desired_quaternion := (
		desired_transform.basis.orthonormalized().get_rotation_quaternion()
	)
	var next_quaternion := current_quaternion.slerp(
		desired_quaternion,
		_exponential_factor(rotation_response, delta)
	).normalized()
	var next_transform := Transform3D(Basis(next_quaternion), next_position)
	if next_transform.is_finite():
		global_transform = next_transform


func _apply_smoothed_arcade_transform(
	desired_transform: Transform3D,
	delta: float
) -> void:
	var next_position := global_position.lerp(
		desired_transform.origin,
		_exponential_factor(_get_arcade_follow_sharpness(), delta)
	)
	if not next_position.is_finite():
		return
	global_position = next_position
	if arcade_camera_state == ArcadeCameraState.STUNT:
		# Position remains smoothly filtered, but orientation is immutable for
		# the entire trick. No rider-relative look vector can flip this basis.
		global_basis = _stunt_locked_basis
		return
	var look_direction := _current_look_position - global_position
	if look_direction.length_squared() <= 0.000001:
		return
	var desired_basis := Basis.looking_at(look_direction.normalized(), Vector3.UP)
	var current_quaternion := global_basis.orthonormalized().get_rotation_quaternion()
	var desired_quaternion := desired_basis.get_rotation_quaternion()
	var smoothed_quaternion := current_quaternion.slerp(
		desired_quaternion,
		_exponential_factor(_get_arcade_rotation_sharpness(), delta)
	).normalized()
	var smoothed_forward := -Basis(smoothed_quaternion).z
	if smoothed_forward.length_squared() <= 0.000001:
		return
	# Rebuilding with world up preserves the chase-camera horizon and prevents
	# vehicle pitch/roll from leaking into normal third-person framing.
	global_basis = Basis.looking_at(smoothed_forward.normalized(), Vector3.UP)


func _update_camera_lens(
	desired_fov: float,
	desired_near: float,
	sharpness: float,
	delta: float
) -> void:
	var factor := _exponential_factor(sharpness, delta)
	_camera.fov = lerpf(_camera.fov, desired_fov, factor)
	_camera.near = lerpf(_camera.near, desired_near, factor)


func _interpolate_transform(
	from: Transform3D,
	to: Transform3D,
	weight: float
) -> Transform3D:
	var from_quaternion := from.basis.orthonormalized().get_rotation_quaternion()
	var to_quaternion := to.basis.orthonormalized().get_rotation_quaternion()
	return Transform3D(
		Basis(from_quaternion.slerp(to_quaternion, weight).normalized()),
		from.origin.lerp(to.origin, weight)
	)


func _interpolate_horizontal_direction(
	from: Vector3,
	to: Vector3,
	weight: float
) -> Vector3:
	var from_angle := atan2(from.x, from.z)
	var to_angle := atan2(to.x, to.z)
	var angle := lerp_angle(from_angle, to_angle, weight)
	return Vector3(sin(angle), 0.0, cos(angle)).normalized()


func _update_manual_look(delta: float) -> void:
	var manual_look_input := 0.0
	if current_camera_mode == CameraMode.ARCADE:
		manual_look_input = clampf(
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


func _get_arcade_parameter_sharpness() -> float:
	match arcade_camera_state:
		ArcadeCameraState.STUNT:
			return stunt_entry_sharpness
		ArcadeCameraState.RECOVERING:
			return stunt_exit_sharpness
		_:
			return distance_sharpness


func _get_arcade_follow_sharpness() -> float:
	match arcade_camera_state:
		ArcadeCameraState.STUNT:
			return stunt_entry_sharpness
		ArcadeCameraState.RECOVERING:
			return stunt_exit_sharpness
		_:
			return position_sharpness


func _get_arcade_rotation_sharpness() -> float:
	match arcade_camera_state:
		ArcadeCameraState.STUNT:
			return stunt_entry_sharpness
		ArcadeCameraState.RECOVERING:
			return stunt_exit_sharpness
		_:
			return rotation_sharpness


func _get_arcade_fov_sharpness() -> float:
	match arcade_camera_state:
		ArcadeCameraState.STUNT:
			return stunt_entry_sharpness
		ArcadeCameraState.RECOVERING:
			return stunt_exit_sharpness
		_:
			return fov_sharpness


func _resolve_references() -> void:
	_vehicle_body = get_node_or_null(vehicle_body_path) as JetSkiController
	_camera_target = get_node_or_null(camera_target_path) as Node3D
	_first_person_socket = get_node_or_null(first_person_socket_path) as Node3D
	if is_instance_valid(_vehicle_body) and is_instance_valid(_camera_target):
		_camera_target_vehicle_local_position = (
			_vehicle_body.global_transform.affine_inverse()
			* _camera_target.global_transform
		).origin
	_first_person_hidden_visuals.clear()
	for visual_path: NodePath in first_person_hidden_visual_paths:
		var visual := get_node_or_null(visual_path) as Node3D
		if visual != null:
			_first_person_hidden_visuals.append(visual)


func _has_valid_references() -> bool:
	return (
		is_instance_valid(_vehicle_body)
		and is_instance_valid(_camera_target)
		and is_instance_valid(_camera)
	)


func _has_first_person_socket() -> bool:
	return is_instance_valid(_first_person_socket)


func _warn_about_invalid_references_once() -> void:
	if _reference_warning_emitted:
		return
	_reference_warning_emitted = true
	push_warning(
		"ChaseCamera follow is disabled because vehicle_body, camera_target, or Camera3D is invalid."
	)


func _warn_about_missing_first_person_socket_once() -> void:
	if _first_person_socket_warning_emitted:
		return
	_first_person_socket_warning_emitted = true
	push_warning(
		"ChaseCamera cannot enter first person because FirstPersonSocket is invalid; arcade mode remains active."
	)


func _fallback_to_arcade_for_missing_socket() -> void:
	_warn_about_missing_first_person_socket_once()
	current_camera_mode = CameraMode.ARCADE
	_cancel_mode_transition()
	_set_first_person_visibility(false)


func _cancel_mode_transition() -> void:
	_mode_transition_active = false
	_mode_transition_elapsed = 0.0
	camera_mode_transition_ratio = 1.0


func _cancel_arcade_stunt() -> void:
	arcade_camera_state = ArcadeCameraState.NORMAL
	_stunt_has_been_airborne = false
	_stunt_grounded_confirmation_elapsed = 0.0
	_stunt_recovery_elapsed = 0.0


func _on_rider_trick_launched(
	_trick_type: JetSkiTypes.RiderTrickLaunchType,
	_charge: Vector2,
	_release_strength: Vector2
) -> void:
	_begin_arcade_stunt()


func _on_vehicle_reset_completed(_reason: StringName) -> void:
	_cancel_arcade_stunt()
	_cancel_mode_transition()
	if is_instance_valid(_camera_target):
		_camera_target.reset_physics_interpolation()
	if is_instance_valid(_first_person_socket):
		_first_person_socket.reset_physics_interpolation()
	_teleport_fallback_ignore_frames = 2
	_set_first_person_visibility(current_camera_mode == CameraMode.FIRST_PERSON)
	_snap_requested = true


func _smoothstep_ratio(value: float) -> float:
	var clamped_value := clampf(value, 0.0, 1.0)
	return clamped_value * clamped_value * (3.0 - 2.0 * clamped_value)


func _exponential_factor(sharpness: float, delta: float) -> float:
	return 1.0 - exp(-maxf(sharpness, 0.0) * maxf(delta, 0.0))


func _inverse_lerp_clamped(from: float, to: float, value: float) -> float:
	if to <= from:
		return 1.0 if value >= to else 0.0
	return clampf(inverse_lerp(from, to, value), 0.0, 1.0)
