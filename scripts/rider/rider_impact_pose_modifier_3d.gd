@tool
class_name RiderImpactPoseModifier3D
extends SkeletonModifier3D

const HIPS_BONE := &"mixamorig_Hips"
const SPINE_BONE := &"mixamorig_Spine"
const SPINE1_BONE := &"mixamorig_Spine1"
const SPINE2_BONE := &"mixamorig_Spine2"
const NECK_BONE := &"mixamorig_Neck"
const HEAD_BONE := &"mixamorig_Head"

@export_range(-1.0, 1.0, 0.01) var impact_compression: float = 0.0:
	set(value):
		impact_compression = clampf(value, -1.0, 1.0)

@export_group("Compression")
@export var compression_pelvis_offset_local := Vector3(0.0, -0.085, -0.022)
@export var compression_pelvis_rotation_degrees := Vector3(4.0, 0.0, 0.0)
@export var compression_spine_rotation_degrees := Vector3(9.0, 0.0, 0.0)
@export var compression_spine1_rotation_degrees := Vector3(7.0, 0.0, 0.0)
@export var compression_spine2_rotation_degrees := Vector3(-6.0, 0.0, 0.0)
@export var compression_neck_rotation_degrees := Vector3(-5.0, 0.0, 0.0)
@export var compression_head_rotation_degrees := Vector3(-3.0, 0.0, 0.0)

@export_group("Extension")
@export var extension_pelvis_offset_local := Vector3(0.0, 0.022, 0.004)
@export var extension_pelvis_rotation_degrees := Vector3(-1.5, 0.0, 0.0)
@export var extension_spine_rotation_degrees := Vector3(-3.0, 0.0, 0.0)
@export var extension_spine1_rotation_degrees := Vector3(-2.0, 0.0, 0.0)
@export var extension_spine2_rotation_degrees := Vector3(2.0, 0.0, 0.0)
@export var extension_neck_rotation_degrees := Vector3(1.0, 0.0, 0.0)
@export var extension_head_rotation_degrees := Vector3(1.0, 0.0, 0.0)


func _process_modification() -> void:
	var skeleton := get_skeleton()
	if skeleton == null or is_zero_approx(impact_compression):
		return

	var amount := absf(impact_compression)
	var compressing := impact_compression > 0.0
	var pelvis_offset := (
		compression_pelvis_offset_local
		if compressing
		else extension_pelvis_offset_local
	)

	_apply_position_offset(skeleton, HIPS_BONE, pelvis_offset * amount)
	_apply_local_rotation(
		skeleton,
		HIPS_BONE,
		(
			compression_pelvis_rotation_degrees
			if compressing
			else extension_pelvis_rotation_degrees
		) * amount
	)
	_apply_local_rotation(
		skeleton,
		SPINE_BONE,
		(
			compression_spine_rotation_degrees
			if compressing
			else extension_spine_rotation_degrees
		) * amount
	)
	_apply_local_rotation(
		skeleton,
		SPINE1_BONE,
		(
			compression_spine1_rotation_degrees
			if compressing
			else extension_spine1_rotation_degrees
		) * amount
	)
	_apply_local_rotation(
		skeleton,
		SPINE2_BONE,
		(
			compression_spine2_rotation_degrees
			if compressing
			else extension_spine2_rotation_degrees
		) * amount
	)
	_apply_local_rotation(
		skeleton,
		NECK_BONE,
		(
			compression_neck_rotation_degrees
			if compressing
			else extension_neck_rotation_degrees
		) * amount
	)
	_apply_local_rotation(
		skeleton,
		HEAD_BONE,
		(
			compression_head_rotation_degrees
			if compressing
			else extension_head_rotation_degrees
		) * amount
	)


func _apply_position_offset(
	skeleton: Skeleton3D,
	bone_name: StringName,
	offset: Vector3
) -> void:
	var bone_index := skeleton.find_bone(bone_name)
	if bone_index < 0:
		return
	var pose := skeleton.get_bone_pose(bone_index)
	pose.origin += offset
	skeleton.set_bone_pose(bone_index, pose)


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
