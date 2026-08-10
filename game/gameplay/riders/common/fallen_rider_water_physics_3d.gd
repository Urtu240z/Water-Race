class_name FallenRiderWaterPhysics3D
extends Node

@export var max_submersion_depth := 0.55
@export var buoyancy_strength_per_point := 1250.0
@export var buoyancy_damping_per_point := 180.0
@export var maximum_buoyancy_force_per_point := 950.0
@export var tangential_drag_linear_per_point := 25.0
@export var tangential_drag_quadratic_per_point := 2.0
@export var maximum_tangential_drag_force_per_point := 350.0

var _provider: WaterSurfaceProvider3D
var _hips: PhysicalBone3D
var _spine2: PhysicalBone3D
var _hips_sample := WaterSample3D.new()
var _spine2_sample := WaterSample3D.new()

var submerged_sample_count := 0
var hips_signed_depth := 0.0
var spine2_signed_depth := 0.0
var hips_buoyancy_force_magnitude := 0.0
var spine2_buoyancy_force_magnitude := 0.0
var total_tangential_drag_magnitude := 0.0


func _ready() -> void:
	set_physics_process(false)


func configure(simulator: PhysicalBoneSimulator3D) -> void:
	_hips = null
	_spine2 = null
	set_physics_process(false)
	if simulator == null:
		return
	_hips = simulator.get_node_or_null("Physical Bone mixamorig_Hips") as PhysicalBone3D
	_spine2 = simulator.get_node_or_null("Physical Bone mixamorig_Spine2") as PhysicalBone3D


func set_water_provider(provider: WaterSurfaceProvider3D) -> void:
	_provider = provider


func set_active(value: bool) -> void:
	_reset_debug_state()
	set_physics_process(
		value
		and is_instance_valid(_provider)
		and is_instance_valid(_hips)
		and is_instance_valid(_spine2)
	)


func clear_water_provider() -> void:
	_provider = null
	set_active(false)


func get_debug_state() -> Dictionary:
	return {
		"active": is_physics_processing(),
		"provider_valid": is_instance_valid(_provider),
		"submerged_sample_count": submerged_sample_count,
		"hips_signed_depth": hips_signed_depth,
		"spine2_signed_depth": spine2_signed_depth,
		"hips_buoyancy_force_magnitude": hips_buoyancy_force_magnitude,
		"spine2_buoyancy_force_magnitude": spine2_buoyancy_force_magnitude,
		"total_tangential_drag_magnitude": total_tangential_drag_magnitude,
	}


func _physics_process(_delta: float) -> void:
	_reset_debug_state()
	if not is_instance_valid(_provider):
		set_physics_process(false)
		return
	_apply_water_forces(_hips, _hips_sample, true)
	_apply_water_forces(_spine2, _spine2_sample, false)


func _apply_water_forces(body: PhysicalBone3D, sample: WaterSample3D, is_hips: bool) -> void:
	if body == null:
		return
	_provider.sample_water(body.global_position, sample)
	var depth := sample.signed_depth if sample.valid else 0.0
	if is_hips:
		hips_signed_depth = depth
	else:
		spine2_signed_depth = depth
	if not sample.valid or depth <= 0.0 or not sample.normal.is_finite() or not sample.velocity.is_finite():
		return
	var normal := sample.normal.normalized()
	if normal.length_squared() <= 0.0001:
		return
	submerged_sample_count += 1
	var depth_ratio := clampf(depth / maxf(max_submersion_depth, 0.001), 0.0, 1.0)
	var relative_velocity := body.linear_velocity - sample.velocity
	var normal_speed := relative_velocity.dot(normal)
	var buoyancy := clampf(
		minf(depth, max_submersion_depth) * buoyancy_strength_per_point
		- normal_speed * buoyancy_damping_per_point * depth_ratio,
		0.0,
		maximum_buoyancy_force_per_point
	)
	_apply_central_force(body, normal * buoyancy)
	if is_hips:
		hips_buoyancy_force_magnitude = buoyancy
	else:
		spine2_buoyancy_force_magnitude = buoyancy
	var tangential_velocity := relative_velocity - normal * normal_speed
	var speed := tangential_velocity.length()
	if speed <= 0.0001:
		return
	var drag := minf(
		(tangential_drag_linear_per_point * speed + tangential_drag_quadratic_per_point * speed * speed) * depth_ratio,
		maximum_tangential_drag_force_per_point
	)
	_apply_central_force(body, -tangential_velocity / speed * drag)
	total_tangential_drag_magnitude += drag


func _apply_central_force(body: PhysicalBone3D, force: Vector3) -> void:
	if not is_instance_valid(body) or not body.is_simulating_physics() or not force.is_finite():
		return
	PhysicsServer3D.body_apply_central_force(body.get_rid(), force)


func _reset_debug_state() -> void:
	submerged_sample_count = 0
	hips_signed_depth = 0.0
	spine2_signed_depth = 0.0
	hips_buoyancy_force_magnitude = 0.0
	spine2_buoyancy_force_magnitude = 0.0
	total_tangential_drag_magnitude = 0.0
