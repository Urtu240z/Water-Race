class_name VehicleWaterEffects3D
extends Node3D

const SPRAY_SPRITE_SHADER := preload("res://shaders/water_spray_sprite.gdshader")
const QUALITY_LOW := preload("res://resources/water/vehicle_effects_quality_low.tres")
const QUALITY_MEDIUM := preload("res://resources/water/vehicle_effects_quality_medium.tres")
const QUALITY_HIGH := preload("res://resources/water/vehicle_effects_quality_high.tres")
const IMPACT_POOL_CAPACITY: int = 4

enum QualityLevel {
	LOW,
	MEDIUM,
	HIGH,
}

@export_group("References")
@export_node_path("RigidBody3D") var vehicle_path: NodePath
@export_node_path("Ocean3D") var ocean_path: NodePath
@export_node_path("Node") var world_origin_controller_path: NodePath
@export_node_path("Marker3D") var front_left_marker_path: NodePath
@export_node_path("Marker3D") var front_right_marker_path: NodePath
@export_node_path("Marker3D") var rear_left_marker_path: NodePath
@export_node_path("Marker3D") var rear_right_marker_path: NodePath
@export_node_path("Marker3D") var propulsion_point_path: NodePath
@export_node_path("Node") var turbine_controller_path: NodePath

@export_group("Quality")
@export var quality_level: QualityLevel = QualityLevel.HIGH:
	set(value):
		quality_level = value
		if is_inside_tree():
			_apply_quality_profile()

@export_group("Continuous Spray")
@export var spray_enabled: bool = true
@export var spray_sheet_enabled: bool = false
@export_range(0.0, 50.0, 0.1, "or_greater", "suffix:m/s") var spray_minimum_speed: float = 8.9
@export_range(0.1, 50.0, 0.1, "or_greater", "suffix:m/s") var spray_full_speed: float = 13.6
@export_range(0.05, 5.0, 0.01, "or_greater", "suffix:s") var spray_lifetime: float = 0.30
@export_range(0.001, 2.0, 0.001, "or_greater", "suffix:m") var spray_minimum_scale: float = 0.252
@export_range(0.001, 2.0, 0.001, "or_greater", "suffix:m") var spray_maximum_scale: float = 0.405
@export_range(0.0, 50.0, 0.1, "or_greater", "suffix:m/s") var spray_minimum_velocity: float = 1.4
@export_range(0.0, 50.0, 0.1, "or_greater", "suffix:m/s") var spray_maximum_velocity: float = 3.8
@export_range(0.1, 6.0, 0.05) var spray_particle_amount_multiplier: float = 6.0
@export_range(1.0, 3.0, 0.05) var spray_growth_multiplier: float = 1.5
@export_range(0.0, 720.0, 5.0, "suffix:deg/s") var spray_rotation_speed: float = 240.0
@export var spray_quad_size: Vector2 = Vector2(0.54, 1.275)
@export var spray_emission_box_size: Vector3 = Vector3(1.005, 0.285, 1.645)
@export_range(0.0, 0.5, 0.01, "suffix:m") var spray_hull_inset: float = 0.5
@export_range(0.0, 0.25, 0.005, "suffix:m") var spray_surface_offset: float = 0.0
@export_range(0.1, 1.0, 0.01) var spray_birth_scale: float = 0.37

@export_group("Spray Sprite Appearance")
@export var spray_color: Color = Color(0.78039217, 0.9490196, 1.0, 0.27058825)
@export var spray_edge_color: Color = Color(1.0, 1.0, 1.0, 0.30588236)
@export_range(0.01, 0.4, 0.01) var spray_edge_softness: float = 0.39
@export_range(0.0, 1.0, 0.01) var spray_irregularity: float = 1.0
@export_range(0.0, 1.0, 0.01) var spray_core_opacity: float = 0.17
@export_range(0.0, 3.0, 0.01) var spray_sprite_emission: float = 0.62

@export_group("Impact Splash")
@export var impact_splash_enabled: bool = true
@export_range(1, 4, 1) var impact_pool_size: int = 4
@export_range(0.0, 1.0, 0.001, "or_greater", "suffix:m") var splash_surface_offset: float = 0.16
@export_range(1, 500, 1, "or_greater") var impact_minimum_amount: int = 8
@export_range(1, 500, 1, "or_greater") var impact_maximum_amount: int = 110
@export_range(0.1, 6.0, 0.05) var impact_particle_amount_multiplier: float = 1.5
@export_range(0.0, 50.0, 0.1, "or_greater", "suffix:m/s") var impact_minimum_velocity: float = 3.0
@export_range(0.0, 50.0, 0.1, "or_greater", "suffix:m/s") var impact_maximum_velocity: float = 11.0
@export_range(0.001, 3.0, 0.001, "or_greater", "suffix:m") var impact_minimum_scale: float = 0.40
@export_range(0.001, 3.0, 0.001, "or_greater", "suffix:m") var impact_maximum_scale: float = 0.78
@export_range(0.05, 5.0, 0.01, "or_greater", "suffix:s") var impact_minimum_lifetime: float = 0.30
@export_range(0.05, 5.0, 0.01, "or_greater", "suffix:s") var impact_maximum_lifetime: float = 0.72
@export var impact_quad_size: Vector2 = Vector2(0.88, 1.22)
@export var impact_emission_box_size: Vector3 = Vector3(1.6, 0.10, 2.2)
@export_range(1.0, 4.0, 0.05) var impact_growth_multiplier: float = 1.65
@export_range(0.0, 1080.0, 5.0, "suffix:deg/s") var impact_rotation_speed: float = 360.0
@export_range(0.1, 1.0, 0.01) var impact_birth_scale: float = 0.48

@export_group("Impact Sprite Appearance")
@export var impact_color: Color = Color(0.88, 0.98, 1.0, 0.62)
@export var impact_edge_color: Color = Color(1.0, 1.0, 1.0, 0.78)
@export_range(0.01, 0.4, 0.01) var impact_edge_softness: float = 0.14
@export_range(0.0, 1.0, 0.01) var impact_irregularity: float = 0.86
@export_range(0.0, 1.0, 0.01) var impact_core_opacity: float = 0.50
@export_range(0.0, 3.0, 0.01) var impact_sprite_emission: float = 0.70
@export_range(0, 127, 1) var splash_render_priority: int = 6

@export_group("Wake")
@export var wake_enabled: bool = true
@export_range(0.0, 50.0, 0.1, "or_greater", "suffix:m/s") var wake_minimum_speed: float = 3.0
@export_range(0.1, 50.0, 0.1, "or_greater", "suffix:m/s") var wake_full_speed: float = 20.0
@export_range(0.0, 1.0, 0.01) var wake_minimum_contact: float = 0.15
@export_range(0.1, 20.0, 0.1, "or_greater", "suffix:s") var wake_lifetime: float = 1.8
@export_range(0.01, 1.0, 0.01, "or_greater", "suffix:s") var wake_sample_maximum_interval: float = 0.1
@export_range(0.0, 0.5, 0.001, "or_greater", "suffix:m") var wake_surface_offset: float = 0.10
@export_range(0.0, 0.99, 0.01) var wake_fade_start_ratio: float = 0.14
@export_range(0.5, 2.0, 0.05) var wake_hull_width_multiplier: float = 1.05
@export_range(1.0, 6.0, 0.05) var wake_maximum_width_multiplier: float = 2.60
@export_range(0.5, 30.0, 0.25, "suffix:m") var wake_opening_distance: float = 6.0

var current_spray_intensity: float:
	get:
		return _current_spray_intensity

var left_spray_emitting: bool:
	get:
		return _bow_left.emitting if is_instance_valid(_bow_left) else false

var right_spray_emitting: bool:
	get:
		return _bow_right.emitting if is_instance_valid(_bow_right) else false

var bow_spray_intensity: float:
	get:
		return _current_spray_intensity

var front_spray_intensity: float:
	get:
		return _current_spray_intensity

var left_bow_spray_intensity: float:
	get:
		return _left_spray_intensity

var right_bow_spray_intensity: float:
	get:
		return _right_spray_intensity

var spray_sheet_vertex_count: int:
	get:
		return _spray_sheet.current_vertex_count if is_instance_valid(_spray_sheet) else 0

var impact_burst_count: int:
	get:
		return _impact_burst_count

var active_impact_burst_count: int:
	get:
		return _active_impact_burst_count

var last_impact_visual_intensity: float:
	get:
		return _last_impact_visual_intensity

var last_impact_particle_amount: int:
	get:
		return _last_impact_particle_amount

var last_impact_initial_velocity: float:
	get:
		return _last_impact_initial_velocity

var last_impact_scale: float:
	get:
		return _last_impact_scale

var last_impact_lifetime: float:
	get:
		return _last_impact_lifetime

var last_impact_spread: float:
	get:
		return _last_impact_spread

var last_impact_direction: Vector3:
	get:
		return _last_impact_direction

var hard_landing_merge_count: int:
	get:
		return _hard_landing_merge_count

var wake_sample_count: int:
	get:
		return _wake_trail.sample_count if is_instance_valid(_wake_trail) else 0

var wake_length: float:
	get:
		return _wake_trail.trail_length if is_instance_valid(_wake_trail) else 0.0

var wake_oldest_age: float:
	get:
		return _wake_trail.oldest_age if is_instance_valid(_wake_trail) else 0.0

var wake_current_width: float:
	get:
		return _wake_trail.current_width if is_instance_valid(_wake_trail) else 0.0

var wake_surface_count: int:
	get:
		return _wake_trail.surface_count if is_instance_valid(_wake_trail) else 0

var particle_clear_count_on_rebase: int:
	get:
		return _particle_clear_count_on_rebase

var wake_rebase_count: int:
	get:
		return _wake_trail.rebase_count if is_instance_valid(_wake_trail) else 0

var effects_reset_count: int:
	get:
		return _effects_reset_count

var estimated_active_particle_count: int:
	get:
		return _estimated_active_particle_count

var active_particle_count: int:
	get:
		var turbine_particles := (
			_turbine_controller.estimated_active_particle_count
			if is_instance_valid(_turbine_controller)
			else 0
		)
		return _estimated_active_particle_count + turbine_particles

var active_vertex_count: int:
	get:
		var wake_vertices := (
			_wake_trail.vertex_count if is_instance_valid(_wake_trail) else 0
		)
		var hull_vertices := (
			_hull_foam.current_vertex_count if is_instance_valid(_hull_foam) else 0
		)
		var turbine_vertices := (
			_turbine_controller.stream_vertex_count
			if is_instance_valid(_turbine_controller)
			else 0
		)
		return spray_sheet_vertex_count + wake_vertices + hull_vertices + turbine_vertices

var jet_stream_length: float:
	get:
		return (
			_turbine_controller.current_core_length
			if is_instance_valid(_turbine_controller)
			else 0.0
		)

var hull_foam_intensity: float:
	get:
		return _hull_foam.foam_intensity if is_instance_valid(_hull_foam) else 0.0

var wake_foam_intensity: float:
	get:
		return _wake_trail.foam_intensity if is_instance_valid(_wake_trail) else 0.0

var _vehicle: JetSkiController
var _ocean: Ocean3D
var _world_origin: WorldOriginController
var _front_left_marker: Marker3D
var _front_right_marker: Marker3D
var _rear_left_marker: Marker3D
var _rear_right_marker: Marker3D
var _propulsion_point: Marker3D
var _turbine_controller: TurbineExhaustController
var _reference_warnings: Dictionary[StringName, bool] = {}
var _spray_valid: bool = false
var _impact_valid: bool = false
var _wake_valid: bool = false
var _spray_materials: Array[ParticleProcessMaterial] = []
var _impact_emitters: Array[GPUParticles3D] = []
var _impact_materials: Array[ParticleProcessMaterial] = []
var _impact_start_times := PackedFloat32Array()
var _impact_end_times := PackedFloat32Array()
var _visual_physics_time: float = 0.0
var _continuous_emission_block_ticks: int = 0
var _current_spray_intensity: float = 0.0
var _impact_burst_count: int = 0
var _active_impact_burst_count: int = 0
var _last_impact_visual_intensity: float = 0.0
var _last_impact_particle_amount: int = 0
var _last_impact_initial_velocity: float = 0.0
var _last_impact_scale: float = 0.0
var _last_impact_lifetime: float = 0.0
var _last_impact_spread: float = 0.0
var _last_impact_direction: Vector3 = Vector3.UP
var _last_impact_index: int = -1
var _last_impact_physics_frame: int = -1
var _hard_landing_merge_count: int = 0
var _particle_clear_count_on_rebase: int = 0
var _effects_reset_count: int = 0
var _estimated_active_particle_count: int = 0
var _spray_particle_quad: QuadMesh
var _impact_particle_quad: QuadMesh
var _spray_particle_material: ShaderMaterial
var _impact_particle_material: ShaderMaterial
var _quality_profile: VehicleWaterEffectsQuality
var _left_spray_intensity: float = 0.0
var _right_spray_intensity: float = 0.0
var _left_contact_position: Vector3 = Vector3.ZERO
var _right_contact_position: Vector3 = Vector3.ZERO
var _left_contact_normal: Vector3 = Vector3.UP
var _right_contact_normal: Vector3 = Vector3.UP
var _left_spray_direction: Vector3 = Vector3.UP
var _right_spray_direction: Vector3 = Vector3.UP
var _left_contact_factor: float = 0.0
var _right_contact_factor: float = 0.0

@onready var _bow_left: GPUParticles3D = $BowDropletsLeft
@onready var _bow_right: GPUParticles3D = $BowDropletsRight
@onready var _rail_left: GPUParticles3D = $RailDropletsLeft
@onready var _rail_right: GPUParticles3D = $RailDropletsRight
@onready var _spray_sheet: HullSpraySheet3D = $HullSpraySheet3D
@onready var _impact_pool: Node3D = $ImpactSplashPool
@onready var _wake_trail: WakeTrail3D = $WakeTrail3D
@onready var _hull_foam: HullFoam3D = $HullFoam3D


func _ready() -> void:
	process_priority = 20
	process_physics_priority = 20
	set_physics_process(false)
	call_deferred("_initialize_effects")


func _initialize_effects() -> void:
	_resolve_references()
	_configure_particle_resources()
	_configure_wake()
	_configure_hull_foam()
	_configure_spray_sheet()
	_apply_quality_profile()
	_connect_signals()
	_update_validity()
	_update_emitter_transforms()
	set_physics_process(true)


func _process(delta: float) -> void:
	_update_active_impact_metrics()
	if not _spray_valid:
		_stop_continuous_spray()
		_update_estimated_particle_count()
		return
	_update_emitter_transforms()
	if _continuous_emission_block_ticks > 0:
		_stop_continuous_spray()
	else:
		_update_continuous_spray(delta)
	_update_estimated_particle_count()


func _physics_process(delta: float) -> void:
	_visual_physics_time += maxf(delta, 0.0)
	if _continuous_emission_block_ticks > 0:
		_continuous_emission_block_ticks -= 1
	_update_active_impact_metrics()


func get_wake_sample_positions() -> PackedVector3Array:
	return _wake_trail.get_sample_positions() if is_instance_valid(_wake_trail) else PackedVector3Array()


func clear_all_visual_effects() -> void:
	_stop_continuous_spray()
	_clear_particle_emitters()
	if is_instance_valid(_wake_trail):
		_wake_trail.clear_trail()
	if is_instance_valid(_hull_foam):
		_hull_foam.clear_foam()
	if is_instance_valid(_spray_sheet):
		_spray_sheet.clear_sheets()
	_continuous_emission_block_ticks = 1
	_current_spray_intensity = 0.0


func set_visual_effects_enabled(
	continuous_spray_enabled: bool,
	impact_enabled: bool,
	wake_generation_enabled: bool
) -> void:
	spray_enabled = continuous_spray_enabled
	impact_splash_enabled = impact_enabled
	wake_enabled = wake_generation_enabled
	if is_instance_valid(_wake_trail):
		_wake_trail.wake_enabled = wake_generation_enabled
	if not continuous_spray_enabled:
		_stop_continuous_spray()
	if not impact_enabled:
		_clear_particle_emitters()
	if not wake_generation_enabled and is_instance_valid(_wake_trail):
		_wake_trail.clear_trail()


func set_quality_level(level: int) -> void:
	quality_level = clampi(
		level,
		QualityLevel.LOW,
		QualityLevel.HIGH
	) as QualityLevel


func _resolve_references() -> void:
	_vehicle = get_node_or_null(vehicle_path) as JetSkiController
	_ocean = get_node_or_null(ocean_path) as Ocean3D
	_world_origin = get_node_or_null(world_origin_controller_path) as WorldOriginController
	_rear_left_marker = get_node_or_null(rear_left_marker_path) as Marker3D
	_rear_right_marker = get_node_or_null(rear_right_marker_path) as Marker3D
	_propulsion_point = get_node_or_null(propulsion_point_path) as Marker3D
	_turbine_controller = get_node_or_null(turbine_controller_path) as TurbineExhaustController
	_front_left_marker = get_node_or_null(front_left_marker_path) as Marker3D
	_front_right_marker = get_node_or_null(front_right_marker_path) as Marker3D
	if is_instance_valid(_vehicle):
		if not is_instance_valid(_ocean):
			_ocean = _vehicle.get_ocean()
		if not is_instance_valid(_front_left_marker):
			_front_left_marker = _vehicle.get_node_or_null(
				"BuoyancyPoints/FrontLeft"
			) as Marker3D
		if not is_instance_valid(_front_right_marker):
			_front_right_marker = _vehicle.get_node_or_null(
				"BuoyancyPoints/FrontRight"
			) as Marker3D
		if not is_instance_valid(_rear_left_marker):
			_rear_left_marker = _vehicle.get_node_or_null(
				"BuoyancyPoints/RearLeft"
			) as Marker3D
		if not is_instance_valid(_rear_right_marker):
			_rear_right_marker = _vehicle.get_node_or_null(
				"BuoyancyPoints/RearRight"
			) as Marker3D
		if not is_instance_valid(_propulsion_point):
			_propulsion_point = _vehicle.get_node_or_null(
				"PropulsionPoint"
			) as Marker3D
		if not is_instance_valid(_turbine_controller):
			_turbine_controller = _vehicle.get_node_or_null(
				"Effects/TurbineExhaust"
			) as TurbineExhaustController


func _update_validity() -> void:
	_spray_valid = false
	_spray_valid = (
		is_instance_valid(_vehicle)
		and is_instance_valid(_ocean)
		and is_instance_valid(_front_left_marker)
		and is_instance_valid(_front_right_marker)
		and is_instance_valid(_rear_left_marker)
		and is_instance_valid(_rear_right_marker)
	)
	_impact_valid = is_instance_valid(_vehicle) and is_instance_valid(_ocean) and not _impact_emitters.is_empty()
	_wake_valid = (
		is_instance_valid(_vehicle)
		and is_instance_valid(_ocean)
		and is_instance_valid(_propulsion_point)
		and is_instance_valid(_wake_trail)
	)
	if not _spray_valid:
		_warn_once(&"spray", "Hull spray is disabled because vehicle, water, or hull marker references are invalid.")
	if not _impact_valid:
		_warn_once(&"impact", "Impact splashes are disabled because vehicle, water, or pool references are invalid.")
	if not _wake_valid:
		_warn_once(&"wake", "Wake generation is disabled because vehicle, water, propulsion point, or WakeTrail3D is invalid.")
	if (
		not world_origin_controller_path.is_empty()
		and not is_instance_valid(_world_origin)
	):
		_warn_once(&"world", "Visual rebase handling is disabled because WorldOriginController is invalid.")


func _configure_particle_resources() -> void:
	_spray_particle_material = _create_spray_sprite_material()
	_impact_particle_material = _create_impact_sprite_material()
	_spray_particle_quad = QuadMesh.new()
	_spray_particle_quad.size = spray_quad_size
	_spray_particle_quad.material = _spray_particle_material
	_impact_particle_quad = QuadMesh.new()
	_impact_particle_quad.size = impact_quad_size
	_impact_particle_quad.material = _impact_particle_material
	_spray_materials.clear()
	for emitter in _continuous_emitters():
		emitter.amount = 24
		emitter.amount_ratio = 0.0
		emitter.lifetime = spray_lifetime
		emitter.one_shot = false
		emitter.local_coords = false
		emitter.emitting = false
		emitter.fixed_fps = 60
		emitter.interpolate = true
		emitter.fract_delta = true
		emitter.visibility_aabb = AABB(Vector3(-16.0, -8.0, -16.0), Vector3(32.0, 24.0, 32.0))
		emitter.draw_pass_1 = _spray_particle_quad
		var process_material := _create_particle_process_material(false)
		emitter.process_material = process_material
		_spray_materials.append(process_material)
	_impact_emitters.clear()
	_impact_materials.clear()
	for child in _impact_pool.get_children():
		var emitter := child as GPUParticles3D
		if emitter == null:
			continue
		emitter.amount = impact_minimum_amount
		emitter.amount_ratio = 1.0
		emitter.lifetime = impact_minimum_lifetime
		emitter.one_shot = true
		emitter.explosiveness = 1.0
		emitter.randomness = 0.35
		emitter.local_coords = false
		emitter.emitting = false
		emitter.fixed_fps = 60
		emitter.interpolate = true
		emitter.fract_delta = true
		emitter.visibility_aabb = AABB(Vector3(-20.0, -8.0, -20.0), Vector3(40.0, 32.0, 40.0))
		emitter.draw_pass_1 = _impact_particle_quad
		var process_material := _create_particle_process_material(true)
		emitter.process_material = process_material
		_impact_emitters.append(emitter)
		_impact_materials.append(process_material)
	_impact_start_times.resize(_impact_emitters.size())
	_impact_end_times.resize(_impact_emitters.size())
	for index in _impact_emitters.size():
		_impact_start_times[index] = -INF
		_impact_end_times[index] = -INF


func _create_spray_sprite_material() -> ShaderMaterial:
	var material := ShaderMaterial.new()
	material.shader = SPRAY_SPRITE_SHADER
	material.render_priority = splash_render_priority
	material.set_shader_parameter(&"spray_color", spray_color)
	material.set_shader_parameter(&"edge_color", spray_edge_color)
	material.set_shader_parameter(&"edge_softness", spray_edge_softness)
	material.set_shader_parameter(&"irregularity", spray_irregularity)
	material.set_shader_parameter(&"core_opacity", spray_core_opacity)
	material.set_shader_parameter(&"emission_strength", spray_sprite_emission)
	return material


func _create_impact_sprite_material() -> ShaderMaterial:
	var material := ShaderMaterial.new()
	material.shader = SPRAY_SPRITE_SHADER
	material.render_priority = splash_render_priority
	material.set_shader_parameter(&"spray_color", impact_color)
	material.set_shader_parameter(&"edge_color", impact_edge_color)
	material.set_shader_parameter(&"edge_softness", impact_edge_softness)
	material.set_shader_parameter(&"irregularity", impact_irregularity)
	material.set_shader_parameter(&"core_opacity", impact_core_opacity)
	material.set_shader_parameter(&"emission_strength", impact_sprite_emission)
	return material


func _create_particle_process_material(is_impact: bool) -> ParticleProcessMaterial:
	var material := ParticleProcessMaterial.new()
	material.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	var emission_box_size := (
		impact_emission_box_size if is_impact else spray_emission_box_size
	)
	material.emission_box_extents = Vector3(
		maxf(emission_box_size.x * 0.5, 0.001),
		maxf(emission_box_size.y * 0.5, 0.001),
		maxf(emission_box_size.z * 0.5, 0.001)
	)
	material.direction = Vector3.UP
	material.spread = 48.0 if is_impact else 13.0
	material.gravity = Vector3(0.0, -12.5 if is_impact else -11.0, 0.0)
	material.initial_velocity_min = impact_minimum_velocity if is_impact else spray_minimum_velocity
	material.initial_velocity_max = impact_minimum_velocity * 1.18 if is_impact else spray_minimum_velocity * 1.2
	material.scale_min = impact_minimum_scale if is_impact else spray_minimum_scale
	material.scale_max = material.scale_min * 1.35
	var rotation_speed := (
		impact_rotation_speed if is_impact else spray_rotation_speed
	)
	var growth_multiplier := (
		impact_growth_multiplier if is_impact else spray_growth_multiplier
	)
	var birth_scale := impact_birth_scale if is_impact else spray_birth_scale
	material.angle_min = -180.0
	material.angle_max = 180.0
	material.angular_velocity_min = -rotation_speed
	material.angular_velocity_max = rotation_speed
	var scale_curve := Curve.new()
	scale_curve.min_value = 0.0
	scale_curve.max_value = maxf(growth_multiplier * 1.15, 2.0)
	scale_curve.add_point(Vector2(0.0, birth_scale))
	scale_curve.add_point(Vector2(0.10, 1.0))
	scale_curve.add_point(Vector2(0.72, growth_multiplier))
	scale_curve.add_point(Vector2(1.0, growth_multiplier * 1.08))
	var scale_texture := CurveTexture.new()
	scale_texture.curve = scale_curve
	material.scale_curve = scale_texture
	material.damping_min = 0.05
	material.damping_max = 0.28
	material.inherit_velocity_ratio = 0.42 if is_impact else 0.28
	material.particle_flag_align_y = true
	var gradient := Gradient.new()
	gradient.offsets = PackedFloat32Array([0.0, 0.55, 1.0])
	gradient.colors = (
		PackedColorArray([
			Color(0.92, 0.99, 1.0, 1.0),
			Color(0.78, 0.94, 1.0, 0.68),
			Color(0.70, 0.90, 1.0, 0.0),
		])
		if is_impact
		else PackedColorArray([
			Color(0.82, 0.95, 1.0, 0.92),
			Color(0.72, 0.9, 1.0, 0.56),
			Color(0.65, 0.86, 1.0, 0.0),
		])
	)
	var gradient_texture := GradientTexture1D.new()
	gradient_texture.gradient = gradient
	material.color_ramp = gradient_texture
	return material


func _configure_wake() -> void:
	if not is_instance_valid(_wake_trail):
		return
	_wake_trail.configure(
		_vehicle,
		_ocean,
		_propulsion_point,
		_rear_left_marker,
		_rear_right_marker
	)
	_wake_trail.wake_enabled = wake_enabled
	_wake_trail.wake_minimum_speed = wake_minimum_speed
	_wake_trail.wake_full_speed = wake_full_speed
	_wake_trail.wake_minimum_contact = wake_minimum_contact
	_wake_trail.wake_lifetime = wake_lifetime
	_wake_trail.wake_sample_maximum_interval = wake_sample_maximum_interval
	_wake_trail.wake_surface_offset = wake_surface_offset
	_wake_trail.wake_fade_start_ratio = wake_fade_start_ratio
	_wake_trail.wake_initial_width_multiplier = wake_hull_width_multiplier
	_wake_trail.wake_maximum_width_multiplier = wake_maximum_width_multiplier
	_wake_trail.wake_opening_distance = wake_opening_distance
	_wake_trail.configure_foam(
		_ocean.foam_settings if is_instance_valid(_ocean) else null,
		_ocean.foam_noise_texture if is_instance_valid(_ocean) else null
	)


func _configure_spray_sheet() -> void:
	if not is_instance_valid(_spray_sheet):
		return
	_spray_sheet.configure(
		_ocean,
		_quality_profile.refraction_enabled if _quality_profile != null else true
	)


func _configure_hull_foam() -> void:
	if not is_instance_valid(_hull_foam):
		return
	_hull_foam.configure(
		_vehicle,
		_ocean,
		_front_left_marker,
		_front_right_marker,
		_rear_left_marker,
		_rear_right_marker,
		_propulsion_point,
		_ocean.foam_settings if is_instance_valid(_ocean) else null,
		_ocean.foam_noise_texture if is_instance_valid(_ocean) else null
	)


func _connect_signals() -> void:
	if is_instance_valid(_vehicle):
		if not _vehicle.water_entered.is_connected(_on_ocean_entered):
			_vehicle.water_entered.connect(_on_ocean_entered)
		if not _vehicle.hard_landing.is_connected(_on_hard_landing):
			_vehicle.hard_landing.connect(_on_hard_landing)
		if not _vehicle.reset_completed.is_connected(_on_reset_completed):
			_vehicle.reset_completed.connect(_on_reset_completed)
	if is_instance_valid(_world_origin) and not _world_origin.world_rebased.is_connected(_on_world_rebased):
		_world_origin.world_rebased.connect(_on_world_rebased)


func _update_emitter_transforms() -> void:
	if not _spray_valid:
		return
	var left_contact := _calculate_rail_contact(
		_front_left_marker,
		_rear_left_marker
	)
	var right_contact := _calculate_rail_contact(
		_front_right_marker,
		_rear_right_marker
	)
	_left_contact_position = left_contact.position
	_left_contact_normal = left_contact.normal
	_left_contact_factor = left_contact.factor
	_right_contact_position = right_contact.position
	_right_contact_normal = right_contact.normal
	_right_contact_factor = right_contact.factor
	var vehicle_basis := _vehicle.get_global_transform_interpolated().basis.orthonormalized()
	var backward := _horizontal_direction(vehicle_basis.z, Vector3.BACK)
	var rightward := _horizontal_direction(vehicle_basis.x, Vector3.RIGHT)
	var left_emission_position := (
		_left_contact_position
		+ rightward * spray_hull_inset
		+ _left_contact_normal * spray_surface_offset
	)
	var right_emission_position := (
		_right_contact_position
		- rightward * spray_hull_inset
		+ _right_contact_normal * spray_surface_offset
	)
	_left_spray_direction = (
		_left_contact_normal * 0.68
		- rightward * 0.82
		+ backward * 0.32
	).normalized()
	_right_spray_direction = (
		_right_contact_normal * 0.68
		+ rightward * 0.82
		+ backward * 0.32
	).normalized()
	var left_transform := Transform3D(
		_basis_with_y(_left_spray_direction, backward),
		left_emission_position
	)
	var right_transform := Transform3D(
		_basis_with_y(_right_spray_direction, backward),
		right_emission_position
	)
	_bow_left.global_transform = left_transform
	_bow_right.global_transform = right_transform
	_rail_left.global_transform = Transform3D(
		_basis_with_y(
			(_left_spray_direction + backward * 0.38).normalized(),
			backward
		),
		left_emission_position + backward * 0.18
	)
	_rail_right.global_transform = Transform3D(
		_basis_with_y(
			(_right_spray_direction + backward * 0.38).normalized(),
			backward
		),
		right_emission_position + backward * 0.18
	)


func _update_continuous_spray(delta: float) -> void:
	var forward_speed := _vehicle.water_relative_forward_speed
	var speed_factor := clampf(
		inverse_lerp(spray_minimum_speed, spray_full_speed, forward_speed),
		0.0,
		1.0
	)
	var in_contact := (
		_vehicle.navigation_state != JetSkiController.NavigationState.AIRBORNE
		and maxf(_left_contact_factor, _right_contact_factor) > 0.0
		and forward_speed >= spray_minimum_speed
	)
	var base_intensity := (
		speed_factor
		if spray_enabled and in_contact
		else 0.0
	)
	var lateral_ratio := clampf(
		_vehicle.water_relative_lateral_speed / maxf(forward_speed, 2.0),
		-1.0,
		1.0
	)
	var asymmetry := clampf(
		lateral_ratio * 0.35 + _vehicle.steering_input * 0.18,
		-0.42,
		0.42
	)
	var target_left := clampf(
		base_intensity * _left_contact_factor * (1.0 + asymmetry),
		0.0,
		1.0
	)
	var target_right := clampf(
		base_intensity * _right_contact_factor * (1.0 - asymmetry),
		0.0,
		1.0
	)
	var response := 1.0 - exp(-10.0 * maxf(delta, 0.0))
	_left_spray_intensity = lerpf(_left_spray_intensity, target_left, response)
	_right_spray_intensity = lerpf(_right_spray_intensity, target_right, response)
	_current_spray_intensity = maxf(_left_spray_intensity, _right_spray_intensity)
	_update_emitter_state(_bow_left, _spray_materials[0], _left_spray_intensity, false)
	_update_emitter_state(_bow_right, _spray_materials[1], _right_spray_intensity, false)
	_update_emitter_state(_rail_left, _spray_materials[2], _left_spray_intensity * 0.48, true)
	_update_emitter_state(_rail_right, _spray_materials[3], _right_spray_intensity * 0.48, true)
	if is_instance_valid(_spray_sheet) and spray_sheet_enabled:
		var backward := _horizontal_direction(
			_vehicle.global_basis.z,
			Vector3.BACK
		)
		_spray_sheet.update_sheets(
			_left_contact_position,
			_right_contact_position,
			_left_spray_direction,
			_right_spray_direction,
			backward,
			_left_contact_normal,
			_right_contact_normal,
			_left_spray_intensity,
			_right_spray_intensity
		)
	elif is_instance_valid(_spray_sheet):
		_spray_sheet.clear_sheets()


func _update_emitter_state(
	emitter: GPUParticles3D,
	material: ParticleProcessMaterial,
	intensity: float,
	is_rail: bool
) -> void:
	if (
		is_rail
		and _quality_profile != null
		and _quality_profile.rail_particles_per_side <= 0
	):
		emitter.emitting = false
		emitter.amount_ratio = 0.0
		return
	var should_emit := intensity > 0.015
	emitter.lifetime = spray_lifetime * (0.82 if is_rail else 1.0)
	emitter.amount_ratio = lerpf(0.08, 1.0, intensity) if should_emit else 0.0
	emitter.emitting = should_emit
	var particle_scale := lerpf(
		spray_minimum_scale,
		spray_maximum_scale,
		intensity
	) * (0.72 if is_rail else 1.0)
	var particle_velocity := lerpf(
		spray_minimum_velocity,
		spray_maximum_velocity,
		intensity
	)
	material.initial_velocity_min = particle_velocity * (0.78 if is_rail else 0.86)
	material.initial_velocity_max = particle_velocity * (1.02 if is_rail else 1.16)
	material.scale_min = particle_scale * 0.76
	material.scale_max = particle_scale * 1.20
	material.spread = 18.0 if is_rail else 12.0


func _calculate_rail_contact(
	front_marker: Marker3D,
	rear_marker: Marker3D
) -> Dictionary:
	var front_position := front_marker.get_global_transform_interpolated().origin
	var rear_position := rear_marker.get_global_transform_interpolated().origin
	var front_depth := _ocean.sample_height(front_position) - front_position.y
	var rear_depth := _ocean.sample_height(rear_position) - rear_position.y
	var ratio := 0.0
	if front_depth < 0.0 and rear_depth > 0.0:
		ratio = clampf(
			front_depth / (front_depth - rear_depth),
			0.0,
			1.0
		)
	elif front_depth <= 0.0 and rear_depth <= 0.0:
		ratio = 1.0
	var contact_position := front_position.lerp(rear_position, ratio)
	var water_height := _ocean.sample_height(contact_position)
	contact_position.y = water_height + splash_surface_offset
	var normal := _ocean.sample_normal(contact_position)
	if not normal.is_finite() or normal.length_squared() <= 0.000001:
		normal = Vector3.UP
	else:
		normal = normal.normalized()
	var maximum_depth := maxf(front_depth, rear_depth)
	var factor := (
		clampf(inverse_lerp(-0.08, 0.34, maximum_depth), 0.0, 1.0)
		if maximum_depth > -0.08
		else 0.0
	)
	return {
		&"position": contact_position,
		&"normal": normal,
		&"factor": factor,
	}


func _stop_continuous_spray() -> void:
	_current_spray_intensity = 0.0
	_left_spray_intensity = 0.0
	_right_spray_intensity = 0.0
	for emitter in _continuous_emitters():
		if not is_instance_valid(emitter):
			continue
		emitter.emitting = false
		emitter.amount_ratio = 0.0
	if is_instance_valid(_spray_sheet):
		_spray_sheet.clear_sheets()


func _on_ocean_entered(_signal_intensity: float, impact_position: Vector3) -> void:
	if not impact_splash_enabled or not _impact_valid:
		return
	var visual_intensity := clampf(_vehicle.last_landing_intensity, 0.0, 1.0)
	var emitter_index := _select_impact_emitter()
	if emitter_index < 0:
		return
	var emitter := _impact_emitters[emitter_index]
	var material := _impact_materials[emitter_index]
	var quality_impact_base := (
		_quality_profile.impact_maximum_particles
		if _quality_profile != null
		else impact_maximum_amount
	)
	var quality_impact_maximum := mini(
		impact_maximum_amount,
		maxi(
			roundi(
				float(quality_impact_base)
				* maxf(impact_particle_amount_multiplier, 0.1)
			),
			1
		)
	)
	var scaled_impact_minimum := mini(
		quality_impact_maximum,
		maxi(
			roundi(
				float(impact_minimum_amount)
				* maxf(impact_particle_amount_multiplier, 0.1)
			),
			1
		)
	)
	var particle_amount := roundi(lerpf(
		float(scaled_impact_minimum),
		float(quality_impact_maximum),
		visual_intensity
	))
	var initial_velocity := lerpf(impact_minimum_velocity, impact_maximum_velocity, visual_intensity)
	var particle_scale := lerpf(impact_minimum_scale, impact_maximum_scale, visual_intensity)
	var particle_lifetime := lerpf(impact_minimum_lifetime, impact_maximum_lifetime, visual_intensity)
	var particle_spread := lerpf(35.0, 75.0, visual_intensity)
	var water_position := Vector3(
		impact_position.x,
		_ocean.sample_height(impact_position) + splash_surface_offset,
		impact_position.z
	)
	var water_normal := _ocean.sample_normal(impact_position)
	var biased_normal := _impact_direction(water_normal)
	emitter.global_transform = Transform3D(
		_basis_with_y(biased_normal, -_vehicle.global_basis.z),
		water_position
	)
	emitter.amount = particle_amount
	emitter.amount_ratio = 1.0
	emitter.lifetime = particle_lifetime
	material.initial_velocity_min = initial_velocity * 0.78
	material.initial_velocity_max = initial_velocity * 1.22
	material.scale_min = particle_scale * 0.78
	material.scale_max = particle_scale * 1.22
	material.spread = particle_spread
	emitter.emitting = true
	emitter.restart()
	_impact_start_times[emitter_index] = _visual_physics_time
	_impact_end_times[emitter_index] = _visual_physics_time + particle_lifetime
	_last_impact_index = emitter_index
	_last_impact_physics_frame = Engine.get_physics_frames()
	_last_impact_visual_intensity = visual_intensity
	_last_impact_particle_amount = particle_amount
	_last_impact_initial_velocity = initial_velocity
	_last_impact_scale = particle_scale
	_last_impact_lifetime = particle_lifetime
	_last_impact_spread = particle_spread
	_last_impact_direction = biased_normal
	_impact_burst_count += 1
	_update_active_impact_metrics()


func _on_hard_landing(_intensity: float, _position: Vector3) -> void:
	# water_entered is emitted immediately before hard_landing by the physical
	# controller. The same configured burst already uses last_landing_intensity;
	# record the merge but never create a second burst.
	if _last_impact_index >= 0 and _last_impact_physics_frame == Engine.get_physics_frames():
		_hard_landing_merge_count += 1


func _impact_direction(water_normal: Vector3) -> Vector3:
	var bias := Vector3.ZERO
	var forward := -_vehicle.global_basis.z.normalized()
	var right := _vehicle.global_basis.x.normalized()
	match _vehicle.last_landing_entry_type:
		JetSkiController.LandingEntryType.FRONT:
			bias = forward * 0.25
		JetSkiController.LandingEntryType.REAR:
			bias = -forward * 0.25
		JetSkiController.LandingEntryType.LEFT:
			bias = -right * 0.25
		JetSkiController.LandingEntryType.RIGHT:
			bias = right * 0.25
		JetSkiController.LandingEntryType.DIAGONAL:
			bias = (forward + right) * 0.16
		JetSkiController.LandingEntryType.SINGLE_POINT:
			bias = right * (-0.18 if (_vehicle.last_landing_contact_mask & JetSkiController.LEFT_CONTACT_MASK) != 0 else 0.18)
	return (water_normal + bias).normalized()


func _select_impact_emitter() -> int:
	var available_count := mini(impact_pool_size, _impact_emitters.size())
	if available_count <= 0:
		return -1
	for index in available_count:
		if _impact_end_times[index] <= _visual_physics_time:
			return index
	var oldest_index: int = 0
	var oldest_start: float = _impact_start_times[0]
	for index in range(1, available_count):
		if _impact_start_times[index] < oldest_start:
			oldest_start = _impact_start_times[index]
			oldest_index = index
	return oldest_index


func _update_active_impact_metrics() -> void:
	_active_impact_burst_count = 0
	for index in mini(impact_pool_size, _impact_emitters.size()):
		if _impact_end_times[index] > _visual_physics_time:
			_active_impact_burst_count += 1


func _on_world_rebased(shift: Vector3) -> void:
	if is_instance_valid(_wake_trail):
		_wake_trail.apply_world_rebase(shift)
	_stop_continuous_spray()
	_clear_particle_emitters()
	_continuous_emission_block_ticks = 1
	_particle_clear_count_on_rebase += 1
	_update_emitter_transforms()


func _on_reset_completed(_reason: StringName) -> void:
	clear_all_visual_effects()
	_effects_reset_count += 1
	_update_emitter_transforms()


func _clear_particle_emitters() -> void:
	for emitter in _continuous_emitters():
		if not is_instance_valid(emitter):
			continue
		emitter.emitting = false
		emitter.restart()
		emitter.emitting = false
	for index in _impact_emitters.size():
		var emitter := _impact_emitters[index]
		emitter.emitting = false
		emitter.restart()
		emitter.emitting = false
		_impact_start_times[index] = -INF
		_impact_end_times[index] = -INF
	_active_impact_burst_count = 0


func _update_estimated_particle_count() -> void:
	var spray_particles: int = 0
	for emitter in _continuous_emitters():
		if emitter.emitting:
			spray_particles += roundi(float(emitter.amount) * emitter.amount_ratio)
	var impact_particles: int = 0
	for index in mini(impact_pool_size, _impact_emitters.size()):
		if _impact_end_times[index] > _visual_physics_time:
			impact_particles += _impact_emitters[index].amount
	_estimated_active_particle_count = spray_particles + impact_particles


func _continuous_emitters() -> Array[GPUParticles3D]:
	return [_bow_left, _bow_right, _rail_left, _rail_right]


func _apply_quality_profile() -> void:
	match quality_level:
		QualityLevel.LOW:
			_quality_profile = QUALITY_LOW
		QualityLevel.MEDIUM:
			_quality_profile = QUALITY_MEDIUM
		_:
			_quality_profile = QUALITY_HIGH
	if not is_inside_tree() or _quality_profile == null:
		return
	var amount_multiplier := maxf(spray_particle_amount_multiplier, 0.1)
	_bow_left.amount = maxi(
		roundi(float(_quality_profile.bow_particles_per_side) * amount_multiplier),
		1
	)
	_bow_right.amount = _bow_left.amount
	_rail_left.amount = maxi(
		roundi(float(_quality_profile.rail_particles_per_side) * amount_multiplier),
		1
	)
	_rail_right.amount = _rail_left.amount
	if _quality_profile.rail_particles_per_side <= 0:
		_rail_left.emitting = false
		_rail_right.emitting = false
	if is_instance_valid(_wake_trail):
		_wake_trail.configure_quality(
			_quality_profile.wake_maximum_points,
			_quality_profile.wake_mesh_update_interval,
			_quality_profile.wake_sample_distance
		)
	if is_instance_valid(_spray_sheet):
		_spray_sheet.set_refraction_enabled(_quality_profile.refraction_enabled)
	if is_instance_valid(_turbine_controller):
		_turbine_controller.set_quality_level(quality_level)


func _horizontal_direction(source: Vector3, fallback: Vector3) -> Vector3:
	var direction := source
	direction.y = 0.0
	if direction.length_squared() <= 0.000001 or not direction.is_finite():
		return fallback
	return direction.normalized()


func _basis_with_y(direction: Vector3, reference_forward: Vector3) -> Basis:
	var y_axis := direction.normalized()
	var reference := reference_forward.normalized()
	if reference.is_zero_approx() or absf(reference.dot(y_axis)) > 0.96:
		reference = Vector3.FORWARD
	var x_axis := y_axis.cross(reference)
	if x_axis.length_squared() <= 0.000001:
		x_axis = y_axis.cross(Vector3.RIGHT)
	x_axis = x_axis.normalized()
	var z_axis := x_axis.cross(y_axis).normalized()
	return Basis(x_axis, y_axis, z_axis).orthonormalized()


func _warn_once(key: StringName, message: String) -> void:
	if _reference_warnings.get(key, false):
		return
	_reference_warnings[key] = true
	push_warning(message)
