class_name RiderMountedLeanController
extends Node

@export_group("Visual Scale")
@export_range(0.0, 2.0, 0.01) var automatic_turn_visual_scale: float = 1.0
@export_range(0.0, 2.0, 0.01) var manual_roll_visual_scale: float = 1.0
@export_range(0.0, 2.0, 0.01) var manual_pitch_visual_scale: float = 1.0

@export_group("Response")
@export_range(0.1, 30.0, 0.1) var automatic_turn_response_speed: float = 10.0
@export_range(0.1, 30.0, 0.1) var manual_lean_response_speed: float = 12.0

@export_group("Grip Reach Guard")
@export var grip_reach_guard_enabled: bool = true
@export_range(1.0, 2.0, 0.01) var maximum_same_direction_combined_blend: float = 1.35
@export_range(0.50, 1.00, 0.01) var grip_soft_extension_ratio: float = 0.90
@export_range(0.50, 1.10, 0.01) var grip_hard_extension_ratio: float = 0.98
@export_range(0.1, 30.0, 0.1) var grip_guard_attack_speed: float = 18.0
@export_range(0.1, 30.0, 0.1) var grip_guard_release_speed: float = 5.0
@export var bypass_grip_reach_guard_in_preview: bool = false

@export_group("Manual Preview")
@export var manual_preview_enabled: bool = false
@export_range(-1.0, 1.0, 0.01) var preview_automatic_turn: float = 0.0
@export_range(-1.0, 1.0, 0.01) var preview_manual_roll: float = 0.0
@export_range(-1.0, 1.0, 0.01) var preview_manual_pitch: float = 0.0

@export_group("Node Paths")
@export_node_path("Node3D") var rider_rig_path := NodePath(
	"../VisualRoot/RiderMount/RiderAssetRoot/RiderRig"
)
@export_node_path("Skeleton3D") var skeleton_path := NodePath(
	"../VisualRoot/RiderMount/RiderAssetRoot/RiderRig/"
	+ "RiderModelRoot/Rider_Bot/SKEL_Rider/Skeleton3D"
)
@export_node_path("Marker3D") var left_grip_target_path := NodePath(
	"../VisualRoot/JetSkiVisual/HandlePivot/GripTargets/LeftGripTarget"
)
@export_node_path("Marker3D") var right_grip_target_path := NodePath(
	"../VisualRoot/JetSkiVisual/HandlePivot/GripTargets/RightGripTarget"
)

const LEFT_ARM_BONE_NAME := &"mixamorig_LeftArm"
const LEFT_FOREARM_BONE_NAME := &"mixamorig_LeftForeArm"
const LEFT_HAND_BONE_NAME := &"mixamorig_LeftHand"
const RIGHT_ARM_BONE_NAME := &"mixamorig_RightArm"
const RIGHT_FOREARM_BONE_NAME := &"mixamorig_RightForeArm"
const RIGHT_HAND_BONE_NAME := &"mixamorig_RightHand"
const APPROXIMATELY_ZERO_BLEND := 0.001
const LAST_RESORT_EXHAUSTED_BLEND := 0.01

var _vehicle: JetSkiController
var _rider_rig: RiderRig
var _skeleton: Skeleton3D
var _left_grip_target: Marker3D
var _right_grip_target: Marker3D
var _left_arm_bone: int = -1
var _left_forearm_bone: int = -1
var _left_hand_bone: int = -1
var _right_arm_bone: int = -1
var _right_forearm_bone: int = -1
var _right_hand_bone: int = -1
var _left_arm_length: float = 0.0
var _right_arm_length: float = 0.0
var _grip_reach_guard_available: bool = false
var _current_automatic_turn: float = 0.0
var _current_manual_roll: float = 0.0
var _current_manual_pitch: float = 0.0
var _current_grip_reach_guard: float = 1.0
var _left_arm_extension_ratio: float = 0.0
var _right_arm_extension_ratio: float = 0.0
var _worst_arm_extension_ratio: float = 0.0
var _automatic_turn_before_guard: float = 0.0
var _automatic_turn_after_guard: float = 0.0
var _manual_roll_after_guard: float = 0.0
var _manual_pitch_after_guard: float = 0.0
var _current_manual_roll_reach_guard: float = 1.0
var _current_manual_pitch_reach_guard: float = 1.0
var _manual_roll_reach_guard_active: bool = false
var _manual_pitch_reach_guard_active: bool = false
var _left_hand_to_grip_distance: float = 0.0
var _right_hand_to_grip_distance: float = 0.0
var _post_ik_metrics_warning_emitted: bool = false
var _reset_hold_physics_frames: int = 0

var left_arm_length: float:
	get:
		return _left_arm_length

var right_arm_length: float:
	get:
		return _right_arm_length

var left_arm_extension_ratio: float:
	get:
		return _left_arm_extension_ratio

var right_arm_extension_ratio: float:
	get:
		return _right_arm_extension_ratio

var worst_arm_extension_ratio: float:
	get:
		return _worst_arm_extension_ratio

var grip_reach_guard: float:
	get:
		return _current_grip_reach_guard

var automatic_turn_before_guard: float:
	get:
		return _automatic_turn_before_guard

var automatic_turn_after_guard: float:
	get:
		return _automatic_turn_after_guard

var manual_roll_after_guard: float:
	get:
		return _manual_roll_after_guard

var manual_pitch_after_guard: float:
	get:
		return _manual_pitch_after_guard

var manual_roll_reach_guard: float:
	get:
		return _current_manual_roll_reach_guard

var manual_pitch_reach_guard: float:
	get:
		return _current_manual_pitch_reach_guard

var left_hand_to_grip_distance: float:
	get:
		return _left_hand_to_grip_distance

var right_hand_to_grip_distance: float:
	get:
		return _right_hand_to_grip_distance


func _ready() -> void:
	_vehicle = get_parent() as JetSkiController
	_rider_rig = get_node_or_null(rider_rig_path) as RiderRig
	if not is_instance_valid(_vehicle):
		push_error(
			"RiderMountedLeanController requires "
			+ "a JetSkiController parent."
		)
		set_physics_process(false)
		return
	if not is_instance_valid(_rider_rig):
		push_error(
			"RiderMountedLeanController could not resolve RiderRig."
		)
		set_physics_process(false)
		return
	_initialize_grip_reach_guard()
	_vehicle.reset_completed.connect(_on_vehicle_reset_completed)
	_vehicle.world_rebased.connect(_on_vehicle_world_rebased)
	_reset_blends(false)


func _exit_tree() -> void:
	_grip_reach_guard_available = false
	set_physics_process(false)
	if (
		is_instance_valid(_skeleton)
		and _skeleton.skeleton_updated.is_connected(
			_measure_post_ik_hand_distances
		)
	):
		_skeleton.skeleton_updated.disconnect(
			_measure_post_ik_hand_distances
		)


func _physics_process(delta: float) -> void:
	if _reset_hold_physics_frames > 0:
		_reset_hold_physics_frames -= 1
		_reset_blends(false)
		return
	if manual_preview_enabled:
		_apply_manual_preview(delta)
		return
	var automatic_turn_target := _automatic_turn_target()
	var manual_roll_target := clampf(
		_vehicle.rider_weight_shift_roll
		* manual_roll_visual_scale,
		-1.0,
		1.0
	)
	var manual_pitch_target := clampf(
		_vehicle.rider_weight_shift_pitch
		* manual_pitch_visual_scale,
		-1.0,
		1.0
	)
	if (
		_vehicle.navigation_state
		== JetSkiController.NavigationState.DEEP_SUBMERGED
	):
		manual_roll_target = 0.0
		manual_pitch_target = 0.0
	var automatic_weight := 1.0 - exp(
		-automatic_turn_response_speed * maxf(delta, 0.0)
	)
	var manual_weight := 1.0 - exp(
		-manual_lean_response_speed * maxf(delta, 0.0)
	)
	_current_automatic_turn = lerpf(
		_current_automatic_turn,
		automatic_turn_target,
		clampf(automatic_weight, 0.0, 1.0)
	)
	_current_manual_roll = lerpf(
		_current_manual_roll,
		manual_roll_target,
		clampf(manual_weight, 0.0, 1.0)
	)
	_current_manual_pitch = lerpf(
		_current_manual_pitch,
		manual_pitch_target,
		clampf(manual_weight, 0.0, 1.0)
	)
	_update_grip_reach_guard(delta)
	_apply_current_blends()


func _automatic_turn_target() -> float:
	if (
		_vehicle.navigation_state
		== JetSkiController.NavigationState.DEEP_SUBMERGED
		or _vehicle.submarine_dive_active
	):
		return 0.0
	return clampf(
		_vehicle.steering_input * automatic_turn_visual_scale,
		-1.0,
		1.0
	)


func _apply_manual_preview(delta: float) -> void:
	_current_automatic_turn = clampf(
		preview_automatic_turn * automatic_turn_visual_scale,
		-1.0,
		1.0
	)
	_current_manual_roll = clampf(
		preview_manual_roll * manual_roll_visual_scale,
		-1.0,
		1.0
	)
	_current_manual_pitch = clampf(
		preview_manual_pitch * manual_pitch_visual_scale,
		-1.0,
		1.0
	)
	_update_grip_reach_guard(delta)
	_apply_current_blends()


func _apply_current_blends() -> void:
	_automatic_turn_before_guard = _current_automatic_turn
	_automatic_turn_after_guard = _current_automatic_turn
	_manual_roll_after_guard = _current_manual_roll
	_manual_pitch_after_guard = _current_manual_pitch
	if _is_grip_reach_guard_active():
		_automatic_turn_after_guard = _limit_same_direction_automatic_turn(
			_automatic_turn_after_guard,
			_current_manual_roll
		)
		_automatic_turn_after_guard *= _current_grip_reach_guard
		_manual_roll_after_guard *= (
			_current_manual_roll_reach_guard
		)
		_manual_pitch_after_guard *= (
			_current_manual_pitch_reach_guard
		)
	_rider_rig.set_automatic_turn_blend(
		_automatic_turn_after_guard
	)
	_rider_rig.set_manual_roll_blend(
		_manual_roll_after_guard
	)
	_rider_rig.set_manual_pitch_blend(
		_manual_pitch_after_guard
	)


func _reset_blends(hold_next_physics_frame: bool) -> void:
	_current_automatic_turn = 0.0
	_current_manual_roll = 0.0
	_current_manual_pitch = 0.0
	_current_grip_reach_guard = 1.0
	_automatic_turn_before_guard = 0.0
	_automatic_turn_after_guard = 0.0
	_manual_roll_after_guard = 0.0
	_manual_pitch_after_guard = 0.0
	_reset_manual_reach_guards()
	if hold_next_physics_frame:
		_reset_hold_physics_frames = 1
	if is_instance_valid(_rider_rig):
		_rider_rig.reset_mounted_lean_blends()


func _initialize_grip_reach_guard() -> void:
	_skeleton = get_node_or_null(skeleton_path) as Skeleton3D
	_left_grip_target = get_node_or_null(left_grip_target_path) as Marker3D
	_right_grip_target = get_node_or_null(right_grip_target_path) as Marker3D
	if not is_instance_valid(_skeleton):
		_disable_grip_reach_guard(
			"could not resolve Skeleton3D."
		)
		return
	if not is_instance_valid(_left_grip_target):
		_disable_grip_reach_guard(
			"could not resolve LeftGripTarget."
		)
		return
	if not is_instance_valid(_right_grip_target):
		_disable_grip_reach_guard(
			"could not resolve RightGripTarget."
		)
		return
	if grip_hard_extension_ratio <= grip_soft_extension_ratio:
		_disable_grip_reach_guard(
			"requires grip_hard_extension_ratio to be greater than "
			+ "grip_soft_extension_ratio."
		)
		return
	_left_arm_bone = _skeleton.find_bone(LEFT_ARM_BONE_NAME)
	_left_forearm_bone = _skeleton.find_bone(LEFT_FOREARM_BONE_NAME)
	_left_hand_bone = _skeleton.find_bone(LEFT_HAND_BONE_NAME)
	_right_arm_bone = _skeleton.find_bone(RIGHT_ARM_BONE_NAME)
	_right_forearm_bone = _skeleton.find_bone(RIGHT_FOREARM_BONE_NAME)
	_right_hand_bone = _skeleton.find_bone(RIGHT_HAND_BONE_NAME)
	var resolved_bones := [
		_left_arm_bone,
		_left_forearm_bone,
		_left_hand_bone,
		_right_arm_bone,
		_right_forearm_bone,
		_right_hand_bone,
	]
	if resolved_bones.has(-1):
		_disable_grip_reach_guard(
			"could not resolve every Arm, ForeArm, and Hand bone."
		)
		return
	_left_arm_length = _calculate_rest_arm_length(
		_left_arm_bone,
		_left_forearm_bone,
		_left_hand_bone
	)
	_right_arm_length = _calculate_rest_arm_length(
		_right_arm_bone,
		_right_forearm_bone,
		_right_hand_bone
	)
	if (
		not is_finite(_left_arm_length)
		or not is_finite(_right_arm_length)
		or _left_arm_length <= 0.0
		or _right_arm_length <= 0.0
	):
		_disable_grip_reach_guard(
			"calculated invalid Rest arm lengths."
		)
		return
	_grip_reach_guard_available = true
	if not _skeleton.skeleton_updated.is_connected(
		_measure_post_ik_hand_distances
	):
		_skeleton.skeleton_updated.connect(
			_measure_post_ik_hand_distances
		)
	_measure_arm_reach()


func _calculate_rest_arm_length(
	arm_bone: int,
	forearm_bone: int,
	hand_bone: int
) -> float:
	var arm_rest_position := _get_bone_global_rest(arm_bone).origin
	var forearm_rest_position := _get_bone_global_rest(
		forearm_bone
	).origin
	var hand_rest_position := _get_bone_global_rest(hand_bone).origin
	if (
		not arm_rest_position.is_finite()
		or not forearm_rest_position.is_finite()
		or not hand_rest_position.is_finite()
	):
		return NAN
	return (
		arm_rest_position.distance_to(forearm_rest_position)
		+ forearm_rest_position.distance_to(hand_rest_position)
	)


func _get_bone_global_rest(bone_index: int) -> Transform3D:
	var global_rest := _skeleton.get_bone_rest(bone_index)
	var parent_index := _skeleton.get_bone_parent(bone_index)
	while parent_index >= 0:
		global_rest = (
			_skeleton.get_bone_rest(parent_index) * global_rest
		)
		parent_index = _skeleton.get_bone_parent(parent_index)
	return global_rest


func _update_grip_reach_guard(delta: float) -> void:
	if not _grip_reach_guard_available:
		_current_grip_reach_guard = 1.0
		_reset_manual_reach_guards()
		return
	_measure_arm_reach()
	if not _is_grip_reach_guard_active():
		_current_grip_reach_guard = 1.0
		_reset_manual_reach_guards()
		return
	var guard_target := 1.0 - smoothstep(
		grip_soft_extension_ratio,
		grip_hard_extension_ratio,
		_worst_arm_extension_ratio
	)
	_current_grip_reach_guard = _smooth_reach_guard_factor(
		_current_grip_reach_guard,
		guard_target,
		delta
	)
	var limited_automatic_turn := (
		_limit_same_direction_automatic_turn(
			_current_automatic_turn,
			_current_manual_roll
		)
	)
	var guarded_automatic_turn := (
		limited_automatic_turn * _current_grip_reach_guard
	)
	var automatic_turn_exhausted := (
		absf(guarded_automatic_turn)
		<= APPROXIMATELY_ZERO_BLEND
	)
	if absf(_current_manual_roll) <= APPROXIMATELY_ZERO_BLEND:
		_manual_roll_reach_guard_active = false
	elif (
		not _manual_roll_reach_guard_active
		and automatic_turn_exhausted
		and _worst_arm_extension_ratio
		> grip_hard_extension_ratio
	):
		_manual_roll_reach_guard_active = true
	var guarded_manual_roll := (
		_current_manual_roll
		* _current_manual_roll_reach_guard
	)
	var manual_roll_exhausted := (
		absf(_current_manual_roll) <= APPROXIMATELY_ZERO_BLEND
		or absf(guarded_manual_roll)
		<= LAST_RESORT_EXHAUSTED_BLEND
	)
	if absf(_current_manual_pitch) <= APPROXIMATELY_ZERO_BLEND:
		_manual_pitch_reach_guard_active = false
	elif (
		not _manual_pitch_reach_guard_active
		and automatic_turn_exhausted
		and manual_roll_exhausted
		and _worst_arm_extension_ratio
		> grip_hard_extension_ratio
	):
		_manual_pitch_reach_guard_active = true
	var manual_roll_guard_target := 1.0
	if (
		_manual_roll_reach_guard_active
		and not _manual_pitch_reach_guard_active
	):
		manual_roll_guard_target = _last_resort_guard_target(
			_current_manual_roll_reach_guard
		)
	_current_manual_roll_reach_guard = _smooth_reach_guard_factor(
		_current_manual_roll_reach_guard,
		manual_roll_guard_target,
		delta
	)
	var manual_pitch_guard_target := (
		_last_resort_guard_target(
			_current_manual_pitch_reach_guard
		)
		if _manual_pitch_reach_guard_active
		else 1.0
	)
	_current_manual_pitch_reach_guard = _smooth_reach_guard_factor(
		_current_manual_pitch_reach_guard,
		manual_pitch_guard_target,
		delta
	)


func _last_resort_guard_target(
	current_factor: float
) -> float:
	if _worst_arm_extension_ratio > grip_hard_extension_ratio:
		return 0.0
	if _worst_arm_extension_ratio < grip_soft_extension_ratio:
		return 1.0
	return current_factor


func _smooth_reach_guard_factor(
	current_factor: float,
	target_factor: float,
	delta: float
) -> float:
	var response_speed := (
		grip_guard_attack_speed
		if target_factor < current_factor
		else grip_guard_release_speed
	)
	var response_weight := 1.0 - exp(
		-response_speed * maxf(delta, 0.0)
	)
	return lerpf(
		current_factor,
		target_factor,
		clampf(response_weight, 0.0, 1.0)
	)


func _reset_manual_reach_guards() -> void:
	_current_manual_roll_reach_guard = 1.0
	_current_manual_pitch_reach_guard = 1.0
	_manual_roll_reach_guard_active = false
	_manual_pitch_reach_guard_active = false


func _measure_arm_reach() -> void:
	if not _are_grip_reach_nodes_inside_tree():
		return
	var left_arm_position := _skeleton.get_bone_global_pose(
		_left_arm_bone
	).origin
	var right_arm_position := _skeleton.get_bone_global_pose(
		_right_arm_bone
	).origin
	var left_target_position := _skeleton.to_local(
		_left_grip_target.global_position
	)
	var right_target_position := _skeleton.to_local(
		_right_grip_target.global_position
	)
	if (
		not left_arm_position.is_finite()
		or not right_arm_position.is_finite()
		or not left_target_position.is_finite()
		or not right_target_position.is_finite()
	):
		_disable_grip_reach_guard(
			"encountered non-finite arm or grip positions."
		)
		return
	_left_arm_extension_ratio = (
		left_arm_position.distance_to(left_target_position)
		/ _left_arm_length
	)
	_right_arm_extension_ratio = (
		right_arm_position.distance_to(right_target_position)
		/ _right_arm_length
	)
	_worst_arm_extension_ratio = maxf(
		_left_arm_extension_ratio,
		_right_arm_extension_ratio
	)
	if (
		not is_finite(_left_arm_extension_ratio)
		or not is_finite(_right_arm_extension_ratio)
		or not is_finite(_worst_arm_extension_ratio)
	):
		_disable_grip_reach_guard(
			"calculated non-finite reach metrics."
		)


func _measure_post_ik_hand_distances() -> void:
	if (
		not _grip_reach_guard_available
		or not _are_grip_reach_nodes_inside_tree()
	):
		return
	var left_hand_position := _skeleton.get_bone_global_pose(
		_left_hand_bone
	).origin
	var right_hand_position := _skeleton.get_bone_global_pose(
		_right_hand_bone
	).origin
	var left_target_position := _skeleton.to_local(
		_left_grip_target.global_position
	)
	var right_target_position := _skeleton.to_local(
		_right_grip_target.global_position
	)
	if (
		not left_hand_position.is_finite()
		or not right_hand_position.is_finite()
		or not left_target_position.is_finite()
		or not right_target_position.is_finite()
	):
		_warn_about_invalid_post_ik_metrics()
		return
	var left_distance := left_hand_position.distance_to(
		left_target_position
	)
	var right_distance := right_hand_position.distance_to(
		right_target_position
	)
	if not is_finite(left_distance) or not is_finite(right_distance):
		_warn_about_invalid_post_ik_metrics()
		return
	_left_hand_to_grip_distance = left_distance
	_right_hand_to_grip_distance = right_distance


func _are_grip_reach_nodes_inside_tree() -> bool:
	return (
		is_inside_tree()
		and is_instance_valid(_skeleton)
		and _skeleton.is_inside_tree()
		and is_instance_valid(_left_grip_target)
		and _left_grip_target.is_inside_tree()
		and is_instance_valid(_right_grip_target)
		and _right_grip_target.is_inside_tree()
	)


func _warn_about_invalid_post_ik_metrics() -> void:
	if _post_ik_metrics_warning_emitted:
		return
	_post_ik_metrics_warning_emitted = true
	push_warning(
		"RiderMountedLeanController could not calculate finite "
		+ "post-IK Hand-to-Grip telemetry."
	)


func _limit_same_direction_automatic_turn(
	automatic_turn: float,
	manual_roll: float
) -> float:
	if automatic_turn * manual_roll <= 0.0:
		return automatic_turn
	var allowed_automatic_magnitude := maxf(
		maximum_same_direction_combined_blend - absf(manual_roll),
		0.0
	)
	return (
		signf(automatic_turn)
		* minf(absf(automatic_turn), allowed_automatic_magnitude)
	)


func _is_grip_reach_guard_active() -> bool:
	return (
		grip_reach_guard_enabled
		and _grip_reach_guard_available
		and not (
			manual_preview_enabled
			and bypass_grip_reach_guard_in_preview
		)
	)


func _disable_grip_reach_guard(reason: String) -> void:
	push_warning(
		"RiderMountedLeanController disabled Grip Reach Guard: "
		+ reason
	)
	_grip_reach_guard_available = false
	_current_grip_reach_guard = 1.0
	_reset_manual_reach_guards()


func _on_vehicle_reset_completed(_reason: StringName) -> void:
	_reset_blends(true)


func _on_vehicle_world_rebased(_shift: Vector3) -> void:
	_reset_blends(true)
