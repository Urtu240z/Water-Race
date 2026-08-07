class_name WorldOriginController
extends Node

signal world_rebased(shift: Vector3)

@export_group("Rebase")
@export var rebase_enabled: bool = true
@export_range(1.0, 100000.0, 1.0, "or_greater", "suffix:m") var rebase_trigger_distance: float = 512.0
@export_range(1.0, 100000.0, 1.0, "or_greater", "suffix:m") var rebase_grid_size: float = 256.0

@export_group("References")
@export_node_path("RigidBody3D") var vehicle_path: NodePath
@export_node_path("Ocean3D") var ocean_path: NodePath
@export_node_path("Node3D") var chase_camera_path: NodePath

@export_group("Debug")
@export var print_rebase_events: bool = false

var rebase_count: int:
	get:
		return _rebase_count

var last_rebase_shift: Vector3:
	get:
		return _last_rebase_shift

var logical_origin_x: float:
	get:
		return _logical_origin_x

var logical_origin_z: float:
	get:
		return _logical_origin_z

var logical_origin_offset: Vector3:
	get:
		return Vector3(_logical_origin_x, 0.0, _logical_origin_z)

var vehicle_local_position: Vector3:
	get:
		return _vehicle.global_position if is_instance_valid(_vehicle) else Vector3.ZERO

var vehicle_logical_position: Vector3:
	get:
		return get_vehicle_logical_position()

var total_rebased_distance: float:
	get:
		return _total_rebased_distance

var maximum_local_distance_observed: float:
	get:
		return _maximum_local_distance_observed

var _vehicle: JetSkiController
var _ocean: Ocean3D
var _chase_camera: ChaseCamera
var _reference_warning_emitted: bool = false
var _rebase_count: int = 0
var _last_rebase_shift: Vector3 = Vector3.ZERO
var _logical_origin_x: float = 0.0
var _logical_origin_z: float = 0.0
var _total_rebased_distance: float = 0.0
var _maximum_local_distance_observed: float = 0.0
var _last_rebase_physics_frame: int = -1


func _ready() -> void:
	process_physics_priority = -200
	_resolve_references()
	if not _has_valid_references():
		_warn_about_invalid_references_once()
		set_physics_process(false)


func _physics_process(_delta: float) -> void:
	if not _has_valid_references():
		return
	var local_xz := Vector2(_vehicle.global_position.x, _vehicle.global_position.z)
	_maximum_local_distance_observed = maxf(
		_maximum_local_distance_observed,
		local_xz.length()
	)
	if not rebase_enabled or local_xz.length() <= rebase_trigger_distance:
		return
	var grid_size := maxf(rebase_grid_size, 1.0)
	var shift := Vector3(
		roundf(_vehicle.global_position.x / grid_size) * grid_size,
		0.0,
		roundf(_vehicle.global_position.z / grid_size) * grid_size
	)
	_apply_world_rebase(shift)


func local_to_logical_position(local_position: Vector3) -> Vector3:
	return Vector3(
		local_position.x + _logical_origin_x,
		local_position.y,
		local_position.z + _logical_origin_z
	)


func get_vehicle_logical_position() -> Vector3:
	if not is_instance_valid(_vehicle):
		return Vector3.ZERO
	return local_to_logical_position(_vehicle.global_position)


func force_world_rebase(shift: Vector3) -> bool:
	if not _has_valid_references() or not shift.is_finite():
		return false
	var grid_size := maxf(rebase_grid_size, 1.0)
	var grid_shift := Vector3(
		roundf(shift.x / grid_size) * grid_size,
		0.0,
		roundf(shift.z / grid_size) * grid_size
	)
	return _apply_world_rebase(grid_shift)


func get_vehicle() -> JetSkiController:
	return _vehicle


func get_ocean() -> Ocean3D:
	return _ocean


func get_chase_camera() -> ChaseCamera:
	return _chase_camera


func _apply_world_rebase(shift: Vector3) -> bool:
	var horizontal_shift := Vector3(shift.x, 0.0, shift.z)
	if horizontal_shift.is_zero_approx() or not horizontal_shift.is_finite():
		return false
	var physics_frame := Engine.get_physics_frames()
	if physics_frame == _last_rebase_physics_frame:
		return false
	_last_rebase_physics_frame = physics_frame
	var next_logical_origin_x := _logical_origin_x + horizontal_shift.x
	var next_logical_origin_z := _logical_origin_z + horizontal_shift.z
	_ocean.apply_world_rebase(
		horizontal_shift,
		next_logical_origin_x,
		next_logical_origin_z
	)
	_vehicle.apply_world_rebase(horizontal_shift)
	_chase_camera.apply_world_rebase(horizontal_shift)
	_logical_origin_x = next_logical_origin_x
	_logical_origin_z = next_logical_origin_z
	_last_rebase_shift = horizontal_shift
	_rebase_count += 1
	_total_rebased_distance += Vector2(horizontal_shift.x, horizontal_shift.z).length()
	if print_rebase_events:
		print(
			"WORLD_REBASE count=%d shift=%s logical_origin=%s vehicle_local=%s"
			% [_rebase_count, horizontal_shift, logical_origin_offset, _vehicle.global_position]
		)
	world_rebased.emit(horizontal_shift)
	return true


func _resolve_references() -> void:
	_vehicle = get_node_or_null(vehicle_path) as JetSkiController
	_ocean = get_node_or_null(ocean_path) as Ocean3D
	_chase_camera = get_node_or_null(chase_camera_path) as ChaseCamera


func _has_valid_references() -> bool:
	return (
		is_instance_valid(_vehicle)
		and is_instance_valid(_ocean)
		and is_instance_valid(_chase_camera)
	)


func _warn_about_invalid_references_once() -> void:
	if _reference_warning_emitted:
		return
	_reference_warning_emitted = true
	push_warning(
		"WorldOriginController is disabled because vehicle, ocean, or chase_camera is invalid."
	)
