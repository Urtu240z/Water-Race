class_name RiderRagdollHandoff
extends Node

@export_node_path("RiderRig") var mounted_rider_path: NodePath
@export_node_path("FallenRider3D") var fallen_rider_path: NodePath
@export_node_path("RigidBody3D") var vehicle_path: NodePath

var _vehicle: RigidBody3D
var _mounted_rider: RiderRig
var _mounted_skeleton: Skeleton3D
var _fallen_rider: FallenRider3D
var _handoff_pending := false
var _handoff_active := false
var _incident_impulse := Vector3.ZERO
var _vehicle_collision_exception_bodies: Array[PhysicalBone3D] = []

func _ready() -> void:
	_vehicle = get_node_or_null(vehicle_path) as RigidBody3D
	_mounted_rider = get_node_or_null(mounted_rider_path) as RiderRig
	_fallen_rider = get_node_or_null(fallen_rider_path) as FallenRider3D
	if _mounted_rider != null:
		_mounted_skeleton = _mounted_rider.get_skeleton()
	if _mounted_skeleton != null:
		_mounted_skeleton.skeleton_updated.connect(_on_mounted_skeleton_updated)
	if _vehicle == null or _mounted_rider == null or _fallen_rider == null or _mounted_skeleton == null:
		push_error("RiderRagdollHandoff requires valid vehicle, mounted rider, fallen rider, and skeleton paths.")

func request_handoff(incident_impulse: Vector3 = Vector3.ZERO) -> void:
	if _handoff_pending or _handoff_active or _vehicle == null or _mounted_skeleton == null or _fallen_rider == null:
		return
	_incident_impulse = incident_impulse if incident_impulse.is_finite() else Vector3.ZERO
	_handoff_pending = true

func _on_mounted_skeleton_updated() -> void:
	if not _handoff_pending:
		return
	_handoff_pending = false
	_perform_handoff()

func _perform_handoff() -> void:
	var fallen_skeleton := _fallen_rider.get_skeleton()
	if fallen_skeleton == null or not _mounted_skeleton.global_transform.is_finite():
		return
	_fallen_rider.set_rider_skin(_mounted_rider.rider_skin)
	var fallen_root_to_skeleton := _fallen_rider.global_transform.affine_inverse() * fallen_skeleton.global_transform
	_fallen_rider.top_level = true
	_fallen_rider.global_transform = _mounted_skeleton.global_transform * fallen_root_to_skeleton.affine_inverse()
	if not fallen_skeleton.global_transform.is_equal_approx(_mounted_skeleton.global_transform):
		push_error("RiderRagdollHandoff could not align fallen and mounted skeleton transforms.")
		return
	for source_index in _mounted_skeleton.get_bone_count():
		var bone_name := _mounted_skeleton.get_bone_name(source_index)
		var target_index := fallen_skeleton.find_bone(bone_name)
		if target_index < 0:
			continue
		fallen_skeleton.set_bone_pose_position(target_index, _mounted_skeleton.get_bone_pose_position(source_index))
		fallen_skeleton.set_bone_pose_rotation(target_index, _mounted_skeleton.get_bone_pose_rotation(source_index))
		fallen_skeleton.set_bone_pose_scale(target_index, _mounted_skeleton.get_bone_pose_scale(source_index))
	for child in _fallen_rider.get_physical_bone_simulator().get_children():
		if child is PhysicalBone3D:
			var body := child as PhysicalBone3D
			body.add_collision_exception_with(_vehicle)
			_vehicle_collision_exception_bodies.append(body)
	_fallen_rider.start_simulation()
	_reset_fallen_rider_physics_interpolation()
	for child in _fallen_rider.get_physical_bone_simulator().get_children():
		if child is PhysicalBone3D:
			var body := child as PhysicalBone3D
			var offset := body.global_position - _vehicle.global_position
			body.linear_velocity = _vehicle.linear_velocity + _vehicle.angular_velocity.cross(offset)
			body.angular_velocity = _vehicle.angular_velocity
	var hips := _fallen_rider.get_physical_bone_simulator().get_node_or_null("Physical Bone mixamorig_Hips") as PhysicalBone3D
	if hips != null and not _incident_impulse.is_zero_approx():
		hips.apply_central_impulse(_incident_impulse)
	_mounted_rider.visible = false
	_handoff_active = true

func _physics_process(_delta: float) -> void:
	if _vehicle_collision_exception_bodies.is_empty():
		return
	for index in range(_vehicle_collision_exception_bodies.size() - 1, -1, -1):
		var body := _vehicle_collision_exception_bodies[index]
		if not is_instance_valid(body) or not _is_body_overlapping_vehicle(body):
			if is_instance_valid(body):
				body.remove_collision_exception_with(_vehicle)
			_vehicle_collision_exception_bodies.remove_at(index)

func _reset_fallen_rider_physics_interpolation() -> void:
	_fallen_rider.reset_physics_interpolation()
	for child in _fallen_rider.get_physical_bone_simulator().get_children():
		if child is PhysicalBone3D:
			(child as PhysicalBone3D).reset_physics_interpolation()

func _is_body_overlapping_vehicle(body: PhysicalBone3D) -> bool:
	var collision_shape := body.get_node_or_null("CollisionShape3D") as CollisionShape3D
	if collision_shape == null or collision_shape.shape == null:
		return false
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = collision_shape.shape
	query.transform = collision_shape.global_transform
	query.collision_mask = _vehicle.collision_layer
	query.collide_with_bodies = true
	query.collide_with_areas = false
	query.exclude = [body.get_rid()]
	var space_state := _vehicle.get_world_3d().direct_space_state
	var overlaps: Array[Dictionary] = space_state.intersect_shape(query)
	for overlap: Dictionary in overlaps:
		if overlap.get("collider") == _vehicle:
			return true
	return false
