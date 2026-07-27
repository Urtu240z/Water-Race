@tool
class_name RiderImpactResponseController
extends Node

enum ResponseMode {
	AUTOMATIC,
	MANUAL_PREVIEW,
	DISABLED,
}

@export var response_mode: ResponseMode = ResponseMode.AUTOMATIC:
	set(value):
		var previous_mode := response_mode
		response_mode = value
		if is_node_ready() and response_mode != previous_mode:
			_on_response_mode_changed()

@export_range(-1.0, 1.0, 0.01) var debug_preview_compression: float = 0.0:
	set(value):
		debug_preview_compression = clampf(value, -1.0, 1.0)
		if is_node_ready() and response_mode == ResponseMode.MANUAL_PREVIEW:
			_apply_manual_preview()

@export_group("Automatic Response - Acceleration")
@export_range(0.0, 20.0, 0.1, "suffix:m/s²") var acceleration_dead_zone: float = 1.8
@export_range(1.0, 60.0, 0.5, "suffix:m/s²") var compression_acceleration_for_full: float = 20.0
@export_range(1.0, 60.0, 0.5, "suffix:m/s²") var extension_acceleration_for_full: float = 13.0
@export_range(0.0, 1.0, 0.01) var extension_strength: float = 0.50
@export_range(0.1, 40.0, 0.1, "suffix:1/s") var acceleration_filter_speed: float = 16.0

@export_group("Automatic Response - Airborne")
@export_range(-1.0, 0.0, 0.01) var airborne_extension_target: float = -0.28

@export_group("Automatic Response - Landing")
@export_range(0.0, 1.5, 0.01) var normal_landing_impulse: float = 0.42
@export_range(0.0, 2.0, 0.01) var hard_landing_impulse: float = 0.78
@export_range(0.1, 30.0, 0.1, "suffix:1/s") var landing_impulse_decay_speed: float = 8.0

@export_group("Automatic Response - Smoothing")
@export_range(0.1, 40.0, 0.1, "suffix:1/s") var compression_rise_speed: float = 14.0
@export_range(0.1, 40.0, 0.1, "suffix:1/s") var compression_release_speed: float = 7.0
@export_range(0.1, 40.0, 0.1, "suffix:1/s") var extension_response_speed: float = 6.0

@export_group("Handle Response")
@export var compression_handle_offset_degrees: float = -2.5:
	set(value):
		compression_handle_offset_degrees = value
		if is_node_ready():
			_apply_compression(_current_compression)

@export var extension_handle_offset_degrees: float = 2.0:
	set(value):
		extension_handle_offset_degrees = value
		if is_node_ready():
			_apply_compression(_current_compression)

@export_group("Node Paths")
@export_node_path("SkeletonModifier3D") var rider_impact_pose_path := NodePath(
	"../VisualRoot/RiderMount/RiderAssetRoot/RiderRig/"
	+ "RiderModelRoot/Rider_Bot/SKEL_Rider/Skeleton3D/RiderImpactPose"
)
@export_node_path("Node3D") var jet_ski_visual_controller_path := NodePath(
	"../VisualRoot/JetSkiVisual"
)
@export_node_path("Node3D") var rider_mount_path := NodePath(
	"../VisualRoot/RiderMount"
)

var seat_point_velocity: Vector3:
	get:
		return _seat_point_velocity

var raw_seat_acceleration: Vector3:
	get:
		return _raw_seat_acceleration

var support_normal: Vector3:
	get:
		return _support_normal

var raw_support_acceleration: float:
	get:
		return _raw_support_acceleration

var filtered_support_acceleration: float:
	get:
		return _filtered_support_acceleration

var contact_authority: float:
	get:
		return _contact_authority

var acceleration_compression: float:
	get:
		return _acceleration_compression

var landing_impulse_current: float:
	get:
		return _landing_impulse

var target_compression: float:
	get:
		return _target_compression

var current_compression: float:
	get:
		return _current_compression

var airborne_extension_active: bool:
	get:
		return _airborne_extension_active

var _vehicle: JetSkiController
var _impact_pose: RiderImpactPoseModifier3D
var _visual_controller: JetSkiVisualController
var _rider_mount: Node3D

var _seat_point_velocity := Vector3.ZERO
var _previous_seat_point_velocity := Vector3.ZERO
var _raw_seat_acceleration := Vector3.ZERO
var _support_normal := Vector3.UP
var _raw_support_acceleration: float = 0.0
var _filtered_support_acceleration: float = 0.0
var _contact_authority: float = 0.0
var _acceleration_compression: float = 0.0
var _landing_impulse: float = 0.0
var _target_compression: float = 0.0
var _current_compression: float = 0.0
var _airborne_extension_active: bool = false
var _velocity_history_valid: bool = false


func _enter_tree() -> void:
	_velocity_history_valid = false


func _ready() -> void:
	_vehicle = get_parent() as JetSkiController
	_resolve_targets()
	if not is_instance_valid(_vehicle):
		push_error(
			"RiderImpactResponseController requires a JetSkiController parent."
		)
		set_physics_process(false)
		return
	if (
		not is_instance_valid(_impact_pose)
		or not is_instance_valid(_visual_controller)
		or not is_instance_valid(_rider_mount)
	):
		push_error(
			"RiderImpactResponseController could not resolve its rider targets."
		)
		set_physics_process(false)
		return
	if not Engine.is_editor_hint():
		_connect_vehicle_signals()
	_on_response_mode_changed()


func _physics_process(delta: float) -> void:
	match response_mode:
		ResponseMode.MANUAL_PREVIEW:
			_apply_manual_preview()
		ResponseMode.DISABLED:
			_update_disabled(delta)
		ResponseMode.AUTOMATIC:
			if Engine.is_editor_hint():
				_reset_automatic_state()
				return
			_update_automatic(delta)


func _resolve_targets() -> void:
	_impact_pose = get_node_or_null(
		rider_impact_pose_path
	) as RiderImpactPoseModifier3D
	_visual_controller = get_node_or_null(
		jet_ski_visual_controller_path
	) as JetSkiVisualController
	_rider_mount = get_node_or_null(rider_mount_path) as Node3D


func _connect_vehicle_signals() -> void:
	if not _vehicle.reset_completed.is_connected(
		_on_vehicle_reset_completed
	):
		_vehicle.reset_completed.connect(_on_vehicle_reset_completed)
	if not _vehicle.world_rebased.is_connected(_on_vehicle_world_rebased):
		_vehicle.world_rebased.connect(_on_vehicle_world_rebased)
	if not _vehicle.water_entered.is_connected(_on_water_entered):
		_vehicle.water_entered.connect(_on_water_entered)
	if not _vehicle.hard_landing.is_connected(_on_hard_landing):
		_vehicle.hard_landing.connect(_on_hard_landing)


func _on_response_mode_changed() -> void:
	_clear_automatic_transients()
	match response_mode:
		ResponseMode.AUTOMATIC:
			_current_compression = 0.0
			_apply_compression(0.0)
		ResponseMode.MANUAL_PREVIEW:
			_apply_manual_preview()
		ResponseMode.DISABLED:
			_target_compression = 0.0


func _apply_manual_preview() -> void:
	_clear_automatic_transients()
	_target_compression = debug_preview_compression
	_current_compression = debug_preview_compression
	_apply_compression(_current_compression)


func _update_disabled(delta: float) -> void:
	_clear_automatic_transients()
	_target_compression = 0.0
	if delta > 0.0 and is_finite(delta):
		var smoothing_speed := compression_release_speed
		if _current_compression < 0.0:
			smoothing_speed = extension_response_speed
		var smoothing_weight := 1.0 - exp(-smoothing_speed * delta)
		_current_compression = lerpf(
			_current_compression,
			0.0,
			smoothing_weight
		)
	if absf(_current_compression) < 0.0001:
		_current_compression = 0.0
	_apply_compression(_current_compression)


func _update_automatic(delta: float) -> void:
	if delta <= 0.0 or not is_finite(delta):
		_prime_velocity_history()
		_reset_response_for_history_tick()
		return

	var current_seat_velocity := _calculate_seat_point_velocity()
	if not current_seat_velocity.is_finite():
		_velocity_history_valid = false
		_reset_response_for_history_tick()
		return

	_seat_point_velocity = current_seat_velocity
	if not _velocity_history_valid:
		_previous_seat_point_velocity = current_seat_velocity
		_velocity_history_valid = true
		_reset_response_for_history_tick()
		return

	_raw_seat_acceleration = (
		(current_seat_velocity - _previous_seat_point_velocity) / delta
	)
	_previous_seat_point_velocity = current_seat_velocity
	if not _raw_seat_acceleration.is_finite():
		_velocity_history_valid = false
		_reset_response_for_history_tick()
		return

	_support_normal = _calculate_support_normal()
	_raw_support_acceleration = _raw_seat_acceleration.dot(
		_support_normal
	)
	var filter_weight := 1.0 - exp(-acceleration_filter_speed * delta)
	_filtered_support_acceleration = lerpf(
		_filtered_support_acceleration,
		_raw_support_acceleration,
		filter_weight
	)
	_acceleration_compression = _acceleration_to_compression(
		_filtered_support_acceleration
	)
	_contact_authority = _calculate_contact_authority()
	_landing_impulse *= exp(-landing_impulse_decay_speed * delta)
	_update_target_compression()
	_smooth_current_compression(delta)
	_apply_compression(_current_compression)


func _calculate_seat_point_velocity() -> Vector3:
	var offset_world := (
		_rider_mount.global_position - _vehicle.global_position
	)
	return (
		_vehicle.linear_velocity
		+ _vehicle.angular_velocity.cross(offset_world)
	)


func _calculate_support_normal() -> Vector3:
	var candidate := _vehicle.turn_lean_support_normal
	if not candidate.is_finite() or candidate.length_squared() <= 0.000001:
		candidate = _vehicle.global_basis.y
	if not candidate.is_finite() or candidate.length_squared() <= 0.000001:
		candidate = Vector3.UP
	candidate = candidate.normalized()
	if candidate.dot(Vector3.UP) < 0.0:
		candidate = -candidate
	return candidate


func _acceleration_to_compression(acceleration: float) -> float:
	var effective_acceleration := (
		signf(acceleration)
		* maxf(absf(acceleration) - acceleration_dead_zone, 0.0)
	)
	if is_zero_approx(effective_acceleration):
		return 0.0
	if effective_acceleration > 0.0:
		return clampf(
			effective_acceleration
			/ maxf(compression_acceleration_for_full, 0.001),
			0.0,
			1.0
		)
	return (
		-clampf(
			absf(effective_acceleration)
			/ maxf(extension_acceleration_for_full, 0.001),
			0.0,
			1.0
		)
		* extension_strength
	)


func _calculate_contact_authority() -> float:
	if _vehicle.has_solid_support:
		return 1.0
	if _vehicle.has_water_support:
		var water_blend := smoothstep(
			0.0,
			0.75,
			clampf(_vehicle.submerged_ratio, 0.0, 1.0)
		)
		return lerpf(0.35, 1.0, water_blend)
	return 0.0


func _update_target_compression() -> void:
	var deep_submerged := (
		_vehicle.navigation_state == JetSkiController.NavigationState.DEEP_SUBMERGED
		or _vehicle.submarine_dive_active
	)
	_airborne_extension_active = (
		_vehicle.navigation_state == JetSkiController.NavigationState.AIRBORNE
		or not _vehicle.has_any_support
	)
	if deep_submerged:
		_airborne_extension_active = false
		_target_compression = 0.0
	elif _airborne_extension_active:
		_target_compression = airborne_extension_target
	else:
		_target_compression = clampf(
			_acceleration_compression * _contact_authority
			+ _landing_impulse,
			-1.0,
			1.0
		)


func _smooth_current_compression(delta: float) -> void:
	var smoothing_speed := extension_response_speed
	if _target_compression > _current_compression:
		if _target_compression >= 0.0:
			smoothing_speed = compression_rise_speed
	else:
		if _current_compression > 0.0:
			smoothing_speed = compression_release_speed
	var smoothing_weight := 1.0 - exp(-smoothing_speed * delta)
	_current_compression = lerpf(
		_current_compression,
		_target_compression,
		smoothing_weight
	)
	_current_compression = clampf(_current_compression, -1.0, 1.0)


func _prime_velocity_history() -> void:
	var current_seat_velocity := _calculate_seat_point_velocity()
	if current_seat_velocity.is_finite():
		_seat_point_velocity = current_seat_velocity
		_previous_seat_point_velocity = current_seat_velocity
		_velocity_history_valid = true
	else:
		_velocity_history_valid = false


func _reset_response_for_history_tick() -> void:
	_raw_seat_acceleration = Vector3.ZERO
	_raw_support_acceleration = 0.0
	_filtered_support_acceleration = 0.0
	_contact_authority = 0.0
	_acceleration_compression = 0.0
	_landing_impulse = 0.0
	_target_compression = 0.0
	_current_compression = 0.0
	_airborne_extension_active = false
	_apply_compression(0.0)


func _clear_automatic_transients() -> void:
	_velocity_history_valid = false
	_seat_point_velocity = Vector3.ZERO
	_previous_seat_point_velocity = Vector3.ZERO
	_raw_seat_acceleration = Vector3.ZERO
	_support_normal = Vector3.UP
	_raw_support_acceleration = 0.0
	_filtered_support_acceleration = 0.0
	_contact_authority = 0.0
	_acceleration_compression = 0.0
	_landing_impulse = 0.0
	_target_compression = 0.0
	_airborne_extension_active = false


func _reset_automatic_state() -> void:
	_clear_automatic_transients()
	_current_compression = 0.0
	_apply_compression(0.0)


func _on_vehicle_reset_completed(_reason: StringName) -> void:
	if response_mode == ResponseMode.AUTOMATIC:
		_reset_automatic_state()


func _on_vehicle_world_rebased(_shift: Vector3) -> void:
	if response_mode == ResponseMode.AUTOMATIC:
		_reset_automatic_state()


func _on_water_entered(intensity: float, _position: Vector3) -> void:
	if (
		response_mode == ResponseMode.AUTOMATIC
		and not Engine.is_editor_hint()
	):
		var candidate := (
			clampf(intensity, 0.0, 1.0)
			* normal_landing_impulse
		)
		_landing_impulse = maxf(
			_landing_impulse,
			candidate
		)


func _on_hard_landing(intensity: float, _position: Vector3) -> void:
	if (
		response_mode == ResponseMode.AUTOMATIC
		and not Engine.is_editor_hint()
	):
		var candidate := (
			clampf(intensity, 0.0, 1.0)
			* hard_landing_impulse
		)
		_landing_impulse = maxf(
			_landing_impulse,
			candidate
		)


func _apply_compression(value: float) -> void:
	if not is_node_ready():
		return
	if (
		not is_instance_valid(_impact_pose)
		or not is_instance_valid(_visual_controller)
	):
		_resolve_targets()
	var clamped_value := clampf(value, -1.0, 1.0)
	if is_instance_valid(_impact_pose):
		_impact_pose.impact_compression = clamped_value
	if is_instance_valid(_visual_controller):
		_visual_controller.set_handle_impact_offset_degrees(
			_compression_to_handle_offset(clamped_value)
		)


func _compression_to_handle_offset(compression: float) -> float:
	if compression >= 0.0:
		return compression * compression_handle_offset_degrees
	return -compression * extension_handle_offset_degrees
