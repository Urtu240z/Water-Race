class_name FallenRider3D
extends Node3D

const WaterPhysicsScript = preload(
	"res://gameplay/riders/common/fallen_rider_water_physics_3d.gd"
)

@onready var rider_rig: RiderRig = $RiderRig
@onready var simulator: PhysicalBoneSimulator3D = (
	$RiderRig/RiderModelRoot/rider_bot/SKEL_Rider/Skeleton3D/PhysicalBoneSimulator3D
)
@onready var water_physics = $WaterPhysics as WaterPhysicsScript


func _ready() -> void:
	_prepare_animation_ownership()
	prepare_dormant()


func set_rider_skin(value: RiderRig.RiderSkin) -> void:
	rider_rig.set_rider_skin(value)


func get_skeleton() -> Skeleton3D:
	return rider_rig.get_skeleton()


func get_physical_bone_simulator() -> PhysicalBoneSimulator3D:
	return simulator


func set_water_provider(provider: WaterSurfaceProvider3D) -> void:
	water_physics.set_water_provider(provider)


func start_simulation() -> void:
	if not is_instance_valid(simulator):
		return

	# IMPORTANT:
	# Do NOT reset Skeleton poses here.
	# Phase 2B will copy the final mounted pose BEFORE this call.
	visible = true

	simulator.active = true
	simulator.physical_bones_start_simulation()
	water_physics.set_active(true)


func stop_simulation() -> void:
	if not is_instance_valid(simulator):
		return

	simulator.physical_bones_stop_simulation()
	simulator.active = false
	water_physics.clear_water_provider()

	_clear_physical_velocities()
	_prime_physics_interpolation()

	visible = false


func prepare_dormant() -> void:
	if not is_instance_valid(simulator):
		visible = false
		return

	# Setting the simulator inactive ensures stopped PhysicalBone3D bodies
	# become inert/static with collision layer and mask disabled by Godot.
	simulator.active = false
	simulator.physical_bones_stop_simulation()
	water_physics.clear_water_provider()

	_clear_physical_velocities()
	_prime_physics_interpolation()

	visible = false


func _prepare_animation_ownership() -> void:
	# The fallen representation must never have mounted animation
	# continuously writing bone poses.
	#
	# Do this once during initialization, long before the future
	# mounted-to-ragdoll pose handoff.
	rider_rig.set_mounted_pose_enabled(false)


func _clear_physical_velocities() -> void:
	if not is_instance_valid(simulator):
		return

	for child: Node in simulator.get_children():
		if child is not PhysicalBone3D:
			continue

		var physical_bone := child as PhysicalBone3D

		physical_bone.linear_velocity = Vector3.ZERO
		physical_bone.angular_velocity = Vector3.ZERO


func _prime_physics_interpolation() -> void:
	if not is_instance_valid(simulator):
		return

	for child: Node in simulator.get_children():
		if child is PhysicalBone3D:
			(child as PhysicalBone3D).get_global_transform_interpolated()
