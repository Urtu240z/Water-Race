@tool
class_name RiderFootOrientationModifier3D
extends SkeletonModifier3D

@export_node_path("Node3D") var left_foot_target: NodePath
@export_node_path("Node3D") var right_foot_target: NodePath
@export_node_path("Node3D") var left_sole_target: NodePath
@export_node_path("Node3D") var right_sole_target: NodePath

@export var left_foot_bone_name: StringName = &"mixamorig_LeftFoot"
@export var right_foot_bone_name: StringName = &"mixamorig_RightFoot"
@export var left_toe_bone_name: StringName = &"mixamorig_LeftToeBase"
@export var right_toe_bone_name: StringName = &"mixamorig_RightToeBase"

@export var left_foot_rotation_correction_degrees := Vector3(
	90.0,
	0.0,
	0.0
)
@export var right_foot_rotation_correction_degrees := Vector3(
	90.0,
	0.0,
	0.0
)
@export var left_toe_rotation_correction_degrees := Vector3(
	-38.0,
	0.0,
	0.0
)
@export var right_toe_rotation_correction_degrees := Vector3(
	-38.0,
	0.0,
	0.0
)


func _process_modification() -> void:
	var skeleton := get_skeleton()
	if skeleton == null:
		return
	_orient_foot(
		skeleton,
		left_foot_bone_name,
		left_sole_target,
		left_foot_rotation_correction_degrees
	)
	_orient_foot(
		skeleton,
		right_foot_bone_name,
		right_sole_target,
		right_foot_rotation_correction_degrees
	)
	_apply_local_rotation(
		skeleton,
		left_toe_bone_name,
		left_toe_rotation_correction_degrees
	)
	_apply_local_rotation(
		skeleton,
		right_toe_bone_name,
		right_toe_rotation_correction_degrees
	)


func _orient_foot(
	skeleton: Skeleton3D,
	bone_name: StringName,
	target_path: NodePath,
	correction_degrees: Vector3
) -> void:
	var bone_index := skeleton.find_bone(bone_name)
	var target := get_node_or_null(target_path) as Node3D
	if bone_index < 0 or target == null:
		return

	var correction_radians := Vector3(
		deg_to_rad(correction_degrees.x),
		deg_to_rad(correction_degrees.y),
		deg_to_rad(correction_degrees.z)
	)
	var desired_world_basis := (
		target.global_basis.orthonormalized()
		* Basis.from_euler(correction_radians)
	)
	var desired_skeleton_basis := (
		skeleton.global_basis.inverse()
		* desired_world_basis
	).orthonormalized()
	var foot_pose := skeleton.get_bone_global_pose(bone_index)
	foot_pose.basis = desired_skeleton_basis
	skeleton.set_bone_global_pose(bone_index, foot_pose)


func _apply_local_rotation(
	skeleton: Skeleton3D,
	bone_name: StringName,
	local_rotation_degrees: Vector3
) -> void:
	var bone_index := skeleton.find_bone(bone_name)
	if bone_index < 0:
		return
	var local_rotation_radians := Vector3(
		deg_to_rad(local_rotation_degrees.x),
		deg_to_rad(local_rotation_degrees.y),
		deg_to_rad(local_rotation_degrees.z)
	)
	var pose := skeleton.get_bone_pose(bone_index)
	pose.basis *= Basis.from_euler(local_rotation_radians)
	skeleton.set_bone_pose(bone_index, pose)
