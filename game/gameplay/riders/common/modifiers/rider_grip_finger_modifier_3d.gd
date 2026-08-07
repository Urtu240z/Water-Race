@tool
class_name RiderGripFingerModifier3D
extends SkeletonModifier3D

const LEFT_THUMB_BONES: Array[StringName] = [
	&"mixamorig_LeftHandThumb1",
	&"mixamorig_LeftHandThumb2",
	&"mixamorig_LeftHandThumb3",
]
const LEFT_INDEX_BONES: Array[StringName] = [
	&"mixamorig_LeftHandIndex1",
	&"mixamorig_LeftHandIndex2",
	&"mixamorig_LeftHandIndex3",
]
const LEFT_MIDDLE_BONES: Array[StringName] = [
	&"mixamorig_LeftHandMiddle1",
	&"mixamorig_LeftHandMiddle2",
	&"mixamorig_LeftHandMiddle3",
]
const LEFT_RING_BONES: Array[StringName] = [
	&"mixamorig_LeftHandRing1",
	&"mixamorig_LeftHandRing2",
	&"mixamorig_LeftHandRing3",
]
const LEFT_PINKY_BONES: Array[StringName] = [
	&"mixamorig_LeftHandPinky1",
	&"mixamorig_LeftHandPinky2",
	&"mixamorig_LeftHandPinky3",
]
const RIGHT_THUMB_BONES: Array[StringName] = [
	&"mixamorig_RightHandThumb1",
	&"mixamorig_RightHandThumb2",
	&"mixamorig_RightHandThumb3",
]
const RIGHT_INDEX_BONES: Array[StringName] = [
	&"mixamorig_RightHandIndex1",
	&"mixamorig_RightHandIndex2",
	&"mixamorig_RightHandIndex3",
]
const RIGHT_MIDDLE_BONES: Array[StringName] = [
	&"mixamorig_RightHandMiddle1",
	&"mixamorig_RightHandMiddle2",
	&"mixamorig_RightHandMiddle3",
]
const RIGHT_RING_BONES: Array[StringName] = [
	&"mixamorig_RightHandRing1",
	&"mixamorig_RightHandRing2",
	&"mixamorig_RightHandRing3",
]
const RIGHT_PINKY_BONES: Array[StringName] = [
	&"mixamorig_RightHandPinky1",
	&"mixamorig_RightHandPinky2",
	&"mixamorig_RightHandPinky3",
]

@export_group("Grip Strength")
@export_range(0.0, 1.0, 0.01) var left_grip_strength: float = 1.0
@export_range(0.0, 1.0, 0.01) var right_grip_strength: float = 1.0
@export_range(0.0, 1.0, 0.01) var thumb_opposition_strength: float = 1.0

@export_group("Left Hand - Thumb")
@export var left_thumb_corrections: Array[Vector3] = [
	Vector3(12.0, 24.0, -20.0),
	Vector3(32.0, 8.0, -10.0),
	Vector3(28.0, 4.0, -6.0),
]
@export_group("Left Hand - Index")
@export var left_index_corrections: Array[Vector3] = [
	Vector3(50.0, 0.0, 0.0),
	Vector3(58.0, 0.0, 0.0),
	Vector3(42.0, 0.0, 0.0),
]
@export_group("Left Hand - Middle")
@export var left_middle_corrections: Array[Vector3] = [
	Vector3(54.0, 0.0, 0.0),
	Vector3(62.0, 0.0, 0.0),
	Vector3(44.0, 0.0, 0.0),
]
@export_group("Left Hand - Ring")
@export var left_ring_corrections: Array[Vector3] = [
	Vector3(56.0, 0.0, 0.0),
	Vector3(64.0, 0.0, 0.0),
	Vector3(46.0, 0.0, 0.0),
]
@export_group("Left Hand - Pinky")
@export var left_pinky_corrections: Array[Vector3] = [
	Vector3(58.0, 0.0, 0.0),
	Vector3(66.0, 0.0, 0.0),
	Vector3(48.0, 0.0, 0.0),
]

@export_group("Right Hand - Thumb")
@export var right_thumb_corrections: Array[Vector3] = [
	Vector3(12.0, -24.0, 20.0),
	Vector3(32.0, -8.0, 10.0),
	Vector3(28.0, -4.0, 6.0),
]
@export_group("Right Hand - Index")
@export var right_index_corrections: Array[Vector3] = [
	Vector3(50.0, 0.0, 0.0),
	Vector3(58.0, 0.0, 0.0),
	Vector3(42.0, 0.0, 0.0),
]
@export_group("Right Hand - Middle")
@export var right_middle_corrections: Array[Vector3] = [
	Vector3(54.0, 0.0, 0.0),
	Vector3(62.0, 0.0, 0.0),
	Vector3(44.0, 0.0, 0.0),
]
@export_group("Right Hand - Ring")
@export var right_ring_corrections: Array[Vector3] = [
	Vector3(56.0, 0.0, 0.0),
	Vector3(64.0, 0.0, 0.0),
	Vector3(46.0, 0.0, 0.0),
]
@export_group("Right Hand - Pinky")
@export var right_pinky_corrections: Array[Vector3] = [
	Vector3(58.0, 0.0, 0.0),
	Vector3(66.0, 0.0, 0.0),
	Vector3(48.0, 0.0, 0.0),
]


func _process_modification() -> void:
	var skeleton := get_skeleton()
	if skeleton == null:
		return
	_apply_hand(
		skeleton,
		left_grip_strength,
		LEFT_THUMB_BONES,
		left_thumb_corrections,
		LEFT_INDEX_BONES,
		left_index_corrections,
		LEFT_MIDDLE_BONES,
		left_middle_corrections,
		LEFT_RING_BONES,
		left_ring_corrections,
		LEFT_PINKY_BONES,
		left_pinky_corrections
	)
	_apply_hand(
		skeleton,
		right_grip_strength,
		RIGHT_THUMB_BONES,
		right_thumb_corrections,
		RIGHT_INDEX_BONES,
		right_index_corrections,
		RIGHT_MIDDLE_BONES,
		right_middle_corrections,
		RIGHT_RING_BONES,
		right_ring_corrections,
		RIGHT_PINKY_BONES,
		right_pinky_corrections
	)


func set_left_grip_strength(value: float) -> void:
	left_grip_strength = clampf(value, 0.0, 1.0)


func set_right_grip_strength(value: float) -> void:
	right_grip_strength = clampf(value, 0.0, 1.0)


func set_grip_strength(value: float) -> void:
	var clamped_value := clampf(value, 0.0, 1.0)
	left_grip_strength = clamped_value
	right_grip_strength = clamped_value


func release_grip() -> void:
	set_grip_strength(0.0)


func close_grip() -> void:
	set_grip_strength(1.0)


func _apply_hand(
	skeleton: Skeleton3D,
	grip_strength: float,
	thumb_bones: Array[StringName],
	thumb_corrections: Array[Vector3],
	index_bones: Array[StringName],
	index_corrections: Array[Vector3],
	middle_bones: Array[StringName],
	middle_corrections: Array[Vector3],
	ring_bones: Array[StringName],
	ring_corrections: Array[Vector3],
	pinky_bones: Array[StringName],
	pinky_corrections: Array[Vector3]
) -> void:
	var clamped_strength := clampf(grip_strength, 0.0, 1.0)
	_apply_finger_chain(
		skeleton,
		thumb_bones,
		thumb_corrections,
		clamped_strength * clampf(thumb_opposition_strength, 0.0, 1.0)
	)
	_apply_finger_chain(
		skeleton,
		index_bones,
		index_corrections,
		clamped_strength
	)
	_apply_finger_chain(
		skeleton,
		middle_bones,
		middle_corrections,
		clamped_strength
	)
	_apply_finger_chain(
		skeleton,
		ring_bones,
		ring_corrections,
		clamped_strength
	)
	_apply_finger_chain(
		skeleton,
		pinky_bones,
		pinky_corrections,
		clamped_strength
	)


func _apply_finger_chain(
	skeleton: Skeleton3D,
	bone_names: Array[StringName],
	corrections: Array[Vector3],
	strength: float
) -> void:
	var correction_count := mini(bone_names.size(), corrections.size())
	for correction_index in range(correction_count):
		var bone_index := skeleton.find_bone(
			bone_names[correction_index]
		)
		if bone_index < 0:
			continue
		var correction_degrees := (
			corrections[correction_index] * strength
		)
		var correction_radians := Vector3(
			deg_to_rad(correction_degrees.x),
			deg_to_rad(correction_degrees.y),
			deg_to_rad(correction_degrees.z)
		)
		var pose := skeleton.get_bone_pose(bone_index)
		pose.basis *= Basis.from_euler(correction_radians)
		skeleton.set_bone_pose(bone_index, pose)
