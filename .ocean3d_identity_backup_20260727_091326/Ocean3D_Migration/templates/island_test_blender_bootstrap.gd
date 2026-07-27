class_name IslandTestBlenderBootstrap
extends Node3D

@export_group("Integration")
@export_range(-100.0, 100.0, 0.01, "suffix:m") var water_level: float = -1.02
@export var place_vehicle_at_spawn: bool = true

@export_group("References")
@export_node_path("Ocean3D") var ocean_path: NodePath
@export_node_path("Marker3D") var player_spawn_path: NodePath
@export_node_path("RigidBody3D") var vehicle_path: NodePath
@export_node_path("Node3D") var chase_camera_path: NodePath

var _ocean: Ocean3D
var _player_spawn: Marker3D
var _vehicle: JetSkiController
var _chase_camera: ChaseCamera


func _enter_tree() -> void:
    _resolve_references()
    _align_ocean()
    if place_vehicle_at_spawn:
        _place_vehicle_at_spawn()


func _ready() -> void:
    _resolve_references()
    _align_ocean()
    _validate_references()


func _resolve_references() -> void:
    _ocean = get_node_or_null(ocean_path) as Ocean3D
    _player_spawn = get_node_or_null(player_spawn_path) as Marker3D
    _vehicle = get_node_or_null(vehicle_path) as JetSkiController
    _chase_camera = get_node_or_null(chase_camera_path) as ChaseCamera


func _align_ocean() -> void:
    if is_instance_valid(_ocean):
        _ocean.water_level = water_level
        _ocean.apply_ocean_settings()


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
    if not is_instance_valid(_ocean):
        push_error("IslandTestBlender: Ocean3D is missing.")
    elif not is_instance_valid(_ocean.get_surface()):
        push_error("IslandTestBlender: Ocean3D has no valid OceanSurface3D child.")
    elif not _ocean.get_surface().visible:
        push_error("IslandTestBlender: OceanSurface3D must remain visible.")
    if not is_instance_valid(_player_spawn):
        push_error("IslandTestBlender: PlayerSpawn is missing.")
    if not is_instance_valid(_vehicle):
        push_error("IslandTestBlender: JetSki is missing.")
    if not is_instance_valid(_chase_camera):
        push_error("IslandTestBlender: ChaseCamera is missing.")
