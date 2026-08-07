@tool
class_name Rider01Rig
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

@export_node_path("Node3D") var model_root_path := NodePath("Rider01")

@onready var _animation_player: AnimationPlayer = $AnimationPlayer
@onready var _animation_tree: AnimationTree = $AnimationTree

var _skeleton: Skeleton3D
var _mounted_lean_blends_valid := false
var _automatic_turn_blend := 0.0
var _manual_roll_blend := 0.0
var _manual_pitch_blend := 0.0


func _ready() -> void:
	var model_root := get_node_or_null(model_root_path)
	_skeleton = _find_first_skeleton(model_root)
	if _skeleton == null:
		push_error("Rider01Rig could not resolve its original Skeleton3D.")
		return
	var skeleton_container := _skeleton.get_parent()
	if skeleton_container != null:
		skeleton_container.name = &"SKEL_Rider"
	if Engine.is_editor_hint():
		return
	_apply_mounted_base_animation()
	_mounted_lean_blends_valid = _validate_mounted_lean_nodes()
	_apply_animation_parameters()
	_apply_mounted_lean_blends()
	_apply_animation_state()


func set_breathing_enabled(enabled: bool) -> void:
	breathing_enabled = enabled


func set_mounted_pose_enabled(enabled: bool) -> void:
	mounted_pose_enabled = enabled


func set_rider_skin(_value: int) -> void:
	pass


func set_automatic_turn_blend(value: float) -> void:
	_automatic_turn_blend = clampf(value, -1.0, 1.0)
	_set_mounted_lean_parameter(&"automatic_turn_add", _automatic_turn_blend)


func set_manual_roll_blend(value: float) -> void:
	_manual_roll_blend = clampf(value, -1.0, 1.0)
	_set_mounted_lean_parameter(&"manual_roll_add", _manual_roll_blend)


func set_manual_pitch_blend(value: float) -> void:
	_manual_pitch_blend = clampf(value, -1.0, 1.0)
	_set_mounted_lean_parameter(&"manual_pitch_add", _manual_pitch_blend)


func reset_mounted_lean_blends() -> void:
	_automatic_turn_blend = 0.0
	_manual_roll_blend = 0.0
	_manual_pitch_blend = 0.0
	_apply_mounted_lean_blends()


func get_skeleton() -> Skeleton3D:
	return _skeleton


func get_animation_player() -> AnimationPlayer:
	return _animation_player


func _find_first_skeleton(root: Node) -> Skeleton3D:
	if root == null:
		return null
	var pending: Array[Node] = [root]
	while not pending.is_empty():
		var current := pending.pop_back() as Node
		if current is Skeleton3D:
			return current as Skeleton3D
		for child: Node in current.get_children():
			pending.append(child)
	return null


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


func _set_mounted_lean_parameter(node_name: StringName, value: float) -> void:
	if not is_node_ready() or not _mounted_lean_blends_valid:
		return
	_animation_tree.set("parameters/%s/add_amount" % node_name, value)


func _validate_mounted_lean_nodes() -> bool:
	var blend_tree := _animation_tree.tree_root as AnimationNodeBlendTree
	if blend_tree == null:
		return false
	var node_names := blend_tree.get_node_list()
	for node_name: StringName in MOUNTED_LEAN_ADD_NODES:
		if not node_names.has(node_name):
			return false
		if not blend_tree.get_node(node_name) is AnimationNodeAdd3:
			return false
	return true


func _apply_mounted_base_animation() -> void:
	if not is_node_ready():
		return
	var blend_tree := _animation_tree.tree_root as AnimationNodeBlendTree
	if blend_tree == null:
		return
	var mounted_node := (
		blend_tree.get_node(&"mounted_base") as AnimationNodeAnimation
	)
	if mounted_node != null:
		mounted_node.animation = MOUNTED_BASE
