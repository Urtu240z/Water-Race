class_name RiderRig
extends Node3D

const MOUNTED_BASE := &"Mounted_Base"

@export_range(0.0, 1.0, 0.01) var breathing_influence: float = 0.22:
	set(value):
		breathing_influence = clampf(value, 0.0, 1.0)
		_apply_animation_parameters()

@export var breathing_enabled: bool = true:
	set(value):
		breathing_enabled = value
		_apply_animation_parameters()

@export var mounted_pose_enabled: bool = true:
	set(value):
		mounted_pose_enabled = value
		_apply_animation_state()

@onready var _animation_tree: AnimationTree = $AnimationTree
@onready var _skeleton: Skeleton3D = (
	$RiderModelRoot/Rider_Bot/SKEL_Rider/Skeleton3D as Skeleton3D
)


func _ready() -> void:
	_apply_mounted_base_animation()
	_apply_animation_parameters()
	_apply_animation_state()


func set_breathing_enabled(enabled: bool) -> void:
	breathing_enabled = enabled


func set_mounted_pose_enabled(enabled: bool) -> void:
	mounted_pose_enabled = enabled


func get_skeleton() -> Skeleton3D:
	return _skeleton


func _apply_animation_parameters() -> void:
	if not is_node_ready():
		return

	var influence := breathing_influence if breathing_enabled else 0.0
	_animation_tree.set("parameters/mounted_add/add_amount", influence)


func _apply_animation_state() -> void:
	if not is_node_ready():
		return

	_animation_tree.active = mounted_pose_enabled

	if not mounted_pose_enabled:
		_skeleton.reset_bone_poses()


func _apply_mounted_base_animation() -> void:
	if not is_node_ready():
		return

	var blend_tree := _animation_tree.tree_root as AnimationNodeBlendTree

	if blend_tree == null:
		push_error("RiderRig requires an AnimationNodeBlendTree.")
		return

	var mounted_node := blend_tree.get_node(&"mounted_base") as AnimationNodeAnimation

	if mounted_node == null:
		push_error("RiderRig is missing the mounted_base animation node.")
		return

	mounted_node.animation = MOUNTED_BASE
