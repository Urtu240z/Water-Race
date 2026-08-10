class_name RiderRagdollHandoff
extends Node

@export_node_path("RiderRig") var mounted_rider_path: NodePath
@export_node_path("FallenRider3D") var fallen_rider_path: NodePath

var _vehicle: RigidBody3D
var _mounted_rider: RiderRig
var _mounted_skeleton: Skeleton3D
var _fallen_rider: FallenRider3D
var _handoff_pending := false
var _handoff_active := false
var _incident_impulse := Vector3.ZERO

func _ready() -> void:
	_vehicle = get_parent() as RigidBody3D
	_mounted_rider = get_node_or_null(mounted_rider_path) as RiderRig
	_fallen_rider = get_node_or_null(fallen_rider_path) as FallenRider3D
	if _mounted_rider != null:
		_mounted_skeleton = _mounted_rider.get_skeleton()
	if _mounted_skeleton != null:
		_mounted_skeleton.skeleton_updated.connect(_on_mounted_skeleton_updated)

func request_handoff(incident_impulse: Vector3 = Vector3.ZERO) -> void:
	if _handoff_pending or _handoff_active or _mounted_skeleton == null or _fallen_rider == null:
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
	_fallen_rider.top_level = true
	_fallen_rider.global_transform = _mounted_skeleton.global_transform * fallen_skeleton.transform.affine_inverse()
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
	_fallen_rider.start_simulation()
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
