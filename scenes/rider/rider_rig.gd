class_name RiderRig
extends Node3D

const MOUNTED_BASE := &"Mounted_Base"
const MOUNTED_LEAN_ADD_NODES: Array[StringName] = [
	&"automatic_turn_add",
	&"manual_roll_add",
	&"manual_pitch_add",
]

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

var _mounted_lean_blends_valid: bool = false
var _automatic_turn_blend: float = 0.0
var _manual_roll_blend: float = 0.0
var _manual_pitch_blend: float = 0.0


func _ready() -> void:
	_apply_mounted_base_animation()
	_mounted_lean_blends_valid = _validate_mounted_lean_nodes()
	_apply_animation_parameters()
	_apply_mounted_lean_blends()
	_apply_animation_state()


func set_breathing_enabled(enabled: bool) -> void:
	breathing_enabled = enabled


func set_mounted_pose_enabled(enabled: bool) -> void:
	mounted_pose_enabled = enabled


func set_automatic_turn_blend(value: float) -> void:
	_automatic_turn_blend = clampf(value, -1.0, 1.0)
	_set_mounted_lean_parameter(
		&"automatic_turn_add",
		_automatic_turn_blend
	)


func set_manual_roll_blend(value: float) -> void:
	_manual_roll_blend = clampf(value, -1.0, 1.0)
	_set_mounted_lean_parameter(
		&"manual_roll_add",
		_manual_roll_blend
	)


func set_manual_pitch_blend(value: float) -> void:
	_manual_pitch_blend = clampf(value, -1.0, 1.0)
	_set_mounted_lean_parameter(
		&"manual_pitch_add",
		_manual_pitch_blend
	)


func reset_mounted_lean_blends() -> void:
	_automatic_turn_blend = 0.0
	_manual_roll_blend = 0.0
	_manual_pitch_blend = 0.0
	_apply_mounted_lean_blends()


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


func _apply_mounted_lean_blends() -> void:
	if not is_node_ready() or not _mounted_lean_blends_valid:
		return
	_animation_tree.set(
		"parameters/automatic_turn_add/add_amount",
		_automatic_turn_blend
	)
	_animation_tree.set(
		"parameters/manual_roll_add/add_amount",
		_manual_roll_blend
	)
	_animation_tree.set(
		"parameters/manual_pitch_add/add_amount",
		_manual_pitch_blend
	)


func _set_mounted_lean_parameter(
	node_name: StringName,
	value: float
) -> void:
	if not is_node_ready() or not _mounted_lean_blends_valid:
		return
	_animation_tree.set(
		"parameters/%s/add_amount" % node_name,
		value
	)


func _validate_mounted_lean_nodes() -> bool:
	var blend_tree := _animation_tree.tree_root as AnimationNodeBlendTree
	if blend_tree == null:
		push_error(
			"RiderRig requires an AnimationNodeBlendTree "
			+ "for mounted lean layers."
		)
		return false
	var nodes_valid := true
	var node_names := blend_tree.get_node_list()
	for node_name in MOUNTED_LEAN_ADD_NODES:
		if not node_names.has(node_name):
			push_error(
				"RiderRig BlendTree is missing %s."
				% node_name
			)
			nodes_valid = false
			continue
		if not blend_tree.get_node(node_name) is AnimationNodeAdd3:
			push_error(
				"RiderRig BlendTree node %s must be "
				% node_name
				+ "an AnimationNodeAdd3."
			)
			nodes_valid = false
	return nodes_valid


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
