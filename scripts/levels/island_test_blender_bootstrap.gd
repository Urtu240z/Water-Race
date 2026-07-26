class_name IslandTestBlenderBootstrap
extends Node3D

@export_group("Integration")
@export_range(-100.0, 100.0, 0.01, "suffix:m") var water_level: float = -1.02
@export var place_vehicle_at_spawn: bool = true

@export_group("References")
@export_node_path("WaterBody3D") var physical_water_path: NodePath
@export_node_path("OceanClipmap3D") var ocean_clipmap_path: NodePath
@export_node_path("Marker3D") var player_spawn_path: NodePath
@export_node_path("RigidBody3D") var vehicle_path: NodePath
@export_node_path("Node3D") var chase_camera_path: NodePath

var _physical_water: WaterBody3D
var _ocean_clipmap: OceanClipmap3D
var _player_spawn: Marker3D
var _vehicle: JetSkiController
var _chase_camera: ChaseCamera


func _enter_tree() -> void:
	_resolve_references()
	_align_water()
	if place_vehicle_at_spawn:
		_place_vehicle_at_spawn()


func _ready() -> void:
	_resolve_references()
	_align_water()
	_validate_references()


func _resolve_references() -> void:
	_physical_water = get_node_or_null(physical_water_path) as WaterBody3D
	_ocean_clipmap = get_node_or_null(ocean_clipmap_path) as OceanClipmap3D
	_player_spawn = get_node_or_null(player_spawn_path) as Marker3D
	_vehicle = get_node_or_null(vehicle_path) as JetSkiController
	_chase_camera = get_node_or_null(chase_camera_path) as ChaseCamera


func _align_water() -> void:
	if is_instance_valid(_physical_water):
		_physical_water.base_height = water_level
	if is_instance_valid(_ocean_clipmap):
		_ocean_clipmap.water_level = water_level


func _place_vehicle_at_spawn() -> void:
	if not is_instance_valid(_vehicle) or not is_instance_valid(_player_spawn):
		return
	var configured_scale := _vehicle.scale
	var spawn_transform := _player_spawn.transform
	if _vehicle.get_parent() != _player_spawn.get_parent():
		if not _vehicle.is_inside_tree() or not _player_spawn.is_inside_tree():
			return
		spawn_transform = _player_spawn.global_transform
	spawn_transform.basis = spawn_transform.basis.scaled(configured_scale)
	if _vehicle.get_parent() == _player_spawn.get_parent():
		_vehicle.transform = spawn_transform
	else:
		_vehicle.global_transform = spawn_transform
	_vehicle.linear_velocity = Vector3.ZERO
	_vehicle.angular_velocity = Vector3.ZERO
	if _vehicle.is_inside_tree():
		_vehicle.reset_physics_interpolation()


func _validate_references() -> void:
	if not is_instance_valid(_physical_water):
		push_error("IslandTestBlender: the physical WaterBody3D provider is missing.")
	elif _physical_water.visible:
		push_error(
			"IslandTestBlender: physical WaterBody3D must remain hidden; "
			+ "OceanClipmap3D owns the visible water surface."
		)
	if not is_instance_valid(_ocean_clipmap):
		push_error("IslandTestBlender: OceanClipmap3D is missing.")
	elif not _ocean_clipmap.visible:
		push_error("IslandTestBlender: OceanClipmap3D must remain visible.")
	if not is_instance_valid(_player_spawn):
		push_error("IslandTestBlender: PlayerSpawn is missing.")
	if not is_instance_valid(_vehicle):
		push_error("IslandTestBlender: JetSki is missing.")
	if not is_instance_valid(_chase_camera):
		push_error("IslandTestBlender: ChaseCamera is missing.")
