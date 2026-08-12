class_name RaceLevelBootstrap
extends Node3D

const COURSE_SIGN_LIGHT_POOL_SCRIPT := preload(
	"res://gameplay/race/course/signs/course_sign_light_pool.gd"
)

@export_group("Integration")
@export_range(-100.0, 100.0, 0.01, "suffix:m") var water_level: float = -1.02
@export var place_vehicle_at_spawn: bool = true

@export_group("References")
@export_node_path("Ocean3D") var ocean_path: NodePath
@export_node_path("Marker3D") var player_spawn_path: NodePath
@export_node_path("RigidBody3D") var vehicle_path: NodePath
@export_node_path("Node3D") var chase_camera_path: NodePath

@export_group("Course Sign Lighting")
@export var course_sign_lighting_enabled: bool = true
@export_range(1, 8, 1) var sign_light_pool_size: int = 4
@export_range(0, 8, 1) var sign_light_medium_pool_size: int = 2
@export var sign_lights_on_low_quality: bool = false
@export_range(1.0, 120.0, 0.5, "suffix:m") var sign_light_activation_distance: float = 30.0
@export_range(0.1, 50.0, 0.1, "suffix:m") var sign_light_range: float = 13.0
@export_range(0.0, 4.0, 0.05, "suffix:m") var sign_light_surface_offset: float = 0.75
@export_range(0.0, 1.0, 0.01) var sign_light_pulse_influence: float = 0.15
@export_range(0.0, 60.0, 0.5) var sign_light_position_smoothing: float = 20.0
@export_range(0.0, 60.0, 0.5) var sign_light_energy_smoothing: float = 16.0
@export_range(0.1, 20.0, 0.1) var sign_light_activation_fade_speed: float = 6.0
@export var arrow_sign_light_color: Color = Color(1.0, 0.62, 0.08)
@export_range(0.0, 4.0, 0.01) var arrow_sign_light_energy_multiplier: float = 0.45
@export var wrong_sign_light_color: Color = Color(1.0, 0.055, 0.02)
@export_range(0.0, 4.0, 0.01) var wrong_sign_light_energy_multiplier: float = 0.5

var _ocean: Ocean3D
var _player_spawn: Marker3D
var _vehicle: JetSkiController
var _chase_camera: ChaseCamera


func _enter_tree() -> void:
	LoadTrace.mark("LEVEL_ENTER_TREE: %s" % name)
	_resolve_references()
	LoadTrace.mark("LEVEL_REFERENCES_RESOLVED: %s" % name)
	_align_ocean()
	if place_vehicle_at_spawn:
		_place_vehicle_at_spawn()
	LoadTrace.mark("LEVEL_ROOT_ENTER_TREE_DONE: %s" % name)


func _ready() -> void:
	LoadTrace.mark("LEVEL_ROOT_READY_BEGIN: %s" % name)
	_resolve_references()
	_align_ocean()
	_validate_references()
	_install_course_sign_light_pool()
	LoadTrace.mark("LEVEL_ROOT_READY: %s" % name)
	LoadTrace.mark("FIRST_FRAME_TRACE_QUEUED: %s" % name)
	call_deferred("_trace_first_playable_frame")


func _trace_first_playable_frame() -> void:
	LoadTrace.mark("FIRST_FRAME_TRACE_CALLBACK: %s" % name)
	await get_tree().process_frame
	LoadTrace.mark("FIRST_PROCESS_FRAME: %s" % name)
	await RenderingServer.frame_post_draw
	LoadTrace.mark("FIRST_FRAME_DRAWN: %s" % name)
	LoadTrace.flush()


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
		push_error("RaceLevelBootstrap: Ocean3D is missing.")
	elif not is_instance_valid(_ocean.get_surface()):
		push_error("RaceLevelBootstrap: Ocean3D has no valid OceanSurface3D child.")
	elif not _ocean.get_surface().visible:
		push_error("RaceLevelBootstrap: OceanSurface3D must remain visible.")
	if not is_instance_valid(_player_spawn):
		push_error("RaceLevelBootstrap: PlayerSpawn is missing.")
	if not is_instance_valid(_vehicle):
		push_error("RaceLevelBootstrap: JetSki is missing.")
	if not is_instance_valid(_chase_camera):
		push_error("RaceLevelBootstrap: ChaseCamera is missing.")


func _install_course_sign_light_pool() -> void:
	if not course_sign_lighting_enabled:
		return
	if get_node_or_null("CourseSignLightPool") != null:
		return
	var tree := get_tree()
	if tree == null:
		return
	var has_arrow_signs := not tree.get_nodes_in_group(
		&"course_emissive_arrow_sign"
	).is_empty()
	var has_wrong_signs := not tree.get_nodes_in_group(
		&"course_emissive_wrong_sign"
	).is_empty()
	if not has_arrow_signs and not has_wrong_signs:
		return
	var light_pool := COURSE_SIGN_LIGHT_POOL_SCRIPT.new() as Node3D
	light_pool.name = "CourseSignLightPool"
	light_pool.set("vehicle_path", NodePath("../Gameplay/JetSki"))
	light_pool.set("maximum_pool_size", sign_light_pool_size)
	light_pool.set("medium_quality_pool_size", sign_light_medium_pool_size)
	light_pool.set("enable_on_low_quality", sign_lights_on_low_quality)
	light_pool.set("activation_distance", sign_light_activation_distance)
	light_pool.set("light_range", sign_light_range)
	light_pool.set("surface_offset", sign_light_surface_offset)
	light_pool.set("light_pulse_influence", sign_light_pulse_influence)
	light_pool.set("position_smoothing_speed", sign_light_position_smoothing)
	light_pool.set("energy_smoothing_speed", sign_light_energy_smoothing)
	light_pool.set("activation_fade_speed", sign_light_activation_fade_speed)
	light_pool.set("arrow_light_color", arrow_sign_light_color)
	light_pool.set(
		"arrow_light_energy_multiplier",
		arrow_sign_light_energy_multiplier
	)
	light_pool.set("wrong_light_color", wrong_sign_light_color)
	light_pool.set(
		"wrong_light_energy_multiplier",
		wrong_sign_light_energy_multiplier
	)
	add_child(light_pool)
