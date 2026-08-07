@tool
class_name RiderGripOrientationModifier3D
extends SkeletonModifier3D

@export_node_path("Node3D") var left_hand_target: NodePath
@export_node_path("Node3D") var right_hand_target: NodePath

@export var left_hand_bone_name: StringName = &"mixamorig_LeftHand"
@export var right_hand_bone_name: StringName = &"mixamorig_RightHand"

@export var left_hand_rotation_correction_degrees := Vector3.ZERO
@export var right_hand_rotation_correction_degrees := Vector3.ZERO


func _process_modification() -> void:
	var skeleton := get_skeleton()
	if skeleton == null:
		return
	_orient_hand(
		skeleton,
		left_hand_bone_name,
		left_hand_target,
		left_hand_rotation_correction_degrees
	)
	_orient_hand(
		skeleton,
		right_hand_bone_name,
		right_hand_target,
		right_hand_rotation_correction_degrees
	)


func _orient_hand(
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
	var hand_pose := skeleton.get_bone_global_pose(bone_index)
	hand_pose.basis = desired_skeleton_basis
	skeleton.set_bone_global_pose(bone_index, hand_pose)
