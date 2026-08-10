class_name RiderRagdollVisualInterpolationModifier3D
extends SkeletonModifier3D

func _process_modification() -> void:
	var skeleton := get_skeleton()
	if skeleton == null:
		return
	var simulator := skeleton.get_node_or_null("PhysicalBoneSimulator3D") as PhysicalBoneSimulator3D
	if simulator == null or not simulator.active:
		return
	for child in simulator.get_children():
		if child is not PhysicalBone3D:
			continue
		var physical_body := child as PhysicalBone3D
		var bone_index := skeleton.find_bone(physical_body.bone_name)
		if bone_index < 0:
			continue
		var bone_world := physical_body.get_global_transform_interpolated() * physical_body.body_offset.affine_inverse()
		var bone_skeleton_pose := skeleton.global_transform.affine_inverse() * bone_world
		if bone_skeleton_pose.is_finite():
			skeleton.set_bone_global_pose(bone_index, bone_skeleton_pose)
