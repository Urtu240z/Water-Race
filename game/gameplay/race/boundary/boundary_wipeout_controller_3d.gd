class_name BoundaryWipeoutController3D
extends Node3D

enum State {
	ARMED,
	WAVE_ACTIVE,
	WAITING_FOR_RECOVERY,
	WAITING_FOR_REARM,
}

const MIN_EFFECTIVE_SPEED := 0.0001
const MIN_INITIAL_CREST_DISTANCE := 0.0001
const DIRECTION_EPSILON := 0.000001
const ORIENTATION_ALIGNMENT_THRESHOLD := 0.999

@export_group("References")
@export_node_path("JetSkiController") var vehicle_path: NodePath
@export_node_path("Ocean3D") var ocean_path: NodePath
@export_node_path("EventWave3D") var event_wave_path: NodePath
@export_node_path("Node3D") var boundary_center_path: NodePath

@export_group("Boundary")
@export var boundary_enabled := true
@export var radial_detection_enabled := true
@export_range(10.0, 100000.0, 1.0, "suffix:m") var boundary_radius := 1000.0
@export_range(0.0, 1000.0, 1.0, "suffix:m") var rearm_margin := 50.0

@export_group("Tsunami Placement")
@export_range(5.0, 500.0, 1.0, "suffix:m") var wave_spawn_distance := 60.0
@export_range(0.0, 10.0, 0.05, "suffix:s") var activation_retry_cooldown := 1.0

@export_group("Tsunami Wipeout")
@export_range(0.0, 500.0, 1.0) var wipeout_forward_impulse := 8.0
@export_range(0.0, 500.0, 1.0) var wipeout_up_impulse := 5.0

var _state := State.WAITING_FOR_REARM
var _vehicle: JetSkiController
var _ocean: Ocean3D
var _event_wave: EventWave3D
var _boundary_center: Node3D
var _previous_signed_distance := 0.0
var _retry_remaining := 0.0


func _ready() -> void:
	_vehicle = get_node_or_null(vehicle_path) as JetSkiController
	_ocean = get_node_or_null(ocean_path) as Ocean3D
	_event_wave = get_node_or_null(event_wave_path) as EventWave3D
	_boundary_center = get_node_or_null(boundary_center_path) as Node3D
	_validate_references()
	if is_instance_valid(_vehicle):
		if not _vehicle.reset_completed.is_connected(_on_vehicle_reset_completed):
			_vehicle.reset_completed.connect(_on_vehicle_reset_completed)
	if _has_required_references():
		_state = State.ARMED


func _physics_process(delta: float) -> void:
	if _retry_remaining > 0.0:
		_retry_remaining = maxf(_retry_remaining - delta, 0.0)
	match _state:
		State.ARMED:
			_process_radial_detection()
		State.WAVE_ACTIVE:
			_process_wave_active()
		State.WAITING_FOR_REARM:
			_process_radial_rearm()
		State.WAITING_FOR_RECOVERY:
			pass


func request_boundary_violation(
	outward_direction: Vector3 = Vector3.ZERO
) -> bool:
	if not boundary_enabled or _state != State.ARMED:
		return false
	if not _has_required_references():
		return false
	if _vehicle.is_wipeout_active() or _retry_remaining > 0.0:
		return false
	var outward := _resolve_outward_direction(outward_direction)
	if outward == Vector2.ZERO:
		return false
	if _event_wave.active:
		_retry_remaining = activation_retry_cooldown
		return false
	if not _place_and_orient_wave(outward):
		_retry_remaining = activation_retry_cooldown
		return false
	if not _event_wave.activate():
		_retry_remaining = activation_retry_cooldown
		return false
	if _event_wave.activation_effective_speed <= MIN_EFFECTIVE_SPEED:
		_event_wave.deactivate()
		_retry_remaining = activation_retry_cooldown
		return false
	var vehicle_logical := _ocean.world_to_logical_xz(_vehicle.global_position)
	var initial_distance := _event_wave.get_signed_distance_to_crest(
		vehicle_logical
	)
	if (
		not is_finite(initial_distance)
		or initial_distance <= MIN_INITIAL_CREST_DISTANCE
	):
		_event_wave.deactivate()
		_retry_remaining = activation_retry_cooldown
		return false
	_previous_signed_distance = initial_distance
	_state = State.WAVE_ACTIVE
	return true


func request_rearm() -> bool:
	if _state != State.WAITING_FOR_REARM:
		return false
	if not boundary_enabled or not _has_required_references():
		return false
	if _vehicle.is_wipeout_active():
		return false
	_previous_signed_distance = 0.0
	_state = State.ARMED
	return true


func get_state() -> State:
	return _state


func _has_required_references() -> bool:
	return (
		is_instance_valid(_vehicle)
		and is_instance_valid(_ocean)
		and is_instance_valid(_event_wave)
	)


func _validate_references() -> void:
	if not is_instance_valid(_vehicle):
		push_error("BoundaryWipeoutController3D: JetSkiController is missing.")
	if not is_instance_valid(_ocean):
		push_error("BoundaryWipeoutController3D: Ocean3D is missing.")
	if not is_instance_valid(_event_wave):
		push_error("BoundaryWipeoutController3D: EventWave3D is missing.")
	if radial_detection_enabled and not is_instance_valid(_boundary_center):
		push_error(
			"BoundaryWipeoutController3D: radial detection requires a boundary center."
		)


func _resolve_outward_direction(outward_direction: Vector3) -> Vector2:
	var outward := Vector2(outward_direction.x, outward_direction.z)
	if outward.is_finite() and outward.length_squared() > DIRECTION_EPSILON:
		return outward.normalized()
	if (
		not is_instance_valid(_boundary_center)
		or not is_instance_valid(_vehicle)
	):
		return Vector2.ZERO
	var to_vehicle := Vector2(
		_vehicle.global_position.x - _boundary_center.global_position.x,
		_vehicle.global_position.z - _boundary_center.global_position.z
	)
	if (
		not to_vehicle.is_finite()
		or to_vehicle.length_squared() <= DIRECTION_EPSILON
	):
		return Vector2.ZERO
	return to_vehicle.normalized()


func _place_and_orient_wave(outward: Vector2) -> bool:
	if not _event_wave.is_inside_tree():
		return false
	var spawn_xz := Vector2(
		_vehicle.global_position.x,
		_vehicle.global_position.z
	) + outward * wave_spawn_distance
	var wave_position := _event_wave.global_position
	wave_position.x = spawn_xz.x
	wave_position.z = spawn_xz.y
	_event_wave.global_position = wave_position
	var travel := Vector3(-outward.x, 0.0, -outward.y)
	_event_wave.look_at(_event_wave.global_position + travel, Vector3.UP)
	var forward := -_event_wave.global_basis.z
	var forward_xz := Vector2(forward.x, forward.z)
	if (
		not forward_xz.is_finite()
		or forward_xz.length_squared() <= DIRECTION_EPSILON
	):
		return false
	var travel_xz := Vector2(travel.x, travel.z).normalized()
	return (
		forward_xz.normalized().dot(travel_xz)
		> ORIENTATION_ALIGNMENT_THRESHOLD
	)


func _process_radial_detection() -> void:
	if (
		not boundary_enabled
		or not radial_detection_enabled
		or not _has_required_references()
		or not is_instance_valid(_boundary_center)
		or _vehicle.is_wipeout_active()
		or _retry_remaining > 0.0
	):
		return
	var offset := Vector2(
		_vehicle.global_position.x - _boundary_center.global_position.x,
		_vehicle.global_position.z - _boundary_center.global_position.z
	)
	if offset.length() <= boundary_radius:
		return
	request_boundary_violation(
		Vector3(offset.x, 0.0, offset.y).normalized()
	)


func _process_wave_active() -> void:
	if not _has_required_references():
		_abort_active_incident()
		return
	if _vehicle.is_wipeout_active():
		_state = State.WAITING_FOR_RECOVERY
		return
	if not _event_wave.active:
		_abort_active_incident()
		return
	var vehicle_logical := _ocean.world_to_logical_xz(_vehicle.global_position)
	var current_distance := _event_wave.get_signed_distance_to_crest(
		vehicle_logical
	)
	if not is_finite(current_distance):
		_abort_active_incident()
		return
	if _previous_signed_distance > 0.0 and current_distance <= 0.0:
		_trigger_boundary_wipeout()
		return
	_previous_signed_distance = current_distance


func _process_radial_rearm() -> void:
	if (
		not boundary_enabled
		or not radial_detection_enabled
		or not _has_required_references()
		or not is_instance_valid(_boundary_center)
		or _vehicle.is_wipeout_active()
	):
		return
	var offset := Vector2(
		_vehicle.global_position.x - _boundary_center.global_position.x,
		_vehicle.global_position.z - _boundary_center.global_position.z
	)
	var rearm_radius := maxf(boundary_radius - rearm_margin, 0.0)
	if offset.length() <= rearm_radius:
		request_rearm()


func _trigger_boundary_wipeout() -> void:
	var wave_direction := Vector3(
		_event_wave.activation_direction.x,
		0.0,
		_event_wave.activation_direction.y
	).normalized()
	var incident_impulse := (
		wave_direction * wipeout_forward_impulse
		+ Vector3.UP * wipeout_up_impulse
	)
	var accepted := _vehicle.request_wipeout(
		WipeoutContext.new(&"boundary_tsunami", incident_impulse)
	)
	if accepted or _vehicle.is_wipeout_active():
		_state = State.WAITING_FOR_RECOVERY
	else:
		_abort_active_incident()


func _abort_active_incident() -> void:
	if is_instance_valid(_event_wave) and _event_wave.active:
		_event_wave.deactivate()
	_previous_signed_distance = 0.0
	_state = State.WAITING_FOR_REARM


func _on_vehicle_reset_completed(_reason: StringName) -> void:
	if _state == State.ARMED:
		return
	if is_instance_valid(_event_wave) and _event_wave.active:
		_event_wave.deactivate()
	_previous_signed_distance = 0.0
	_retry_remaining = 0.0
	_state = State.WAITING_FOR_REARM
