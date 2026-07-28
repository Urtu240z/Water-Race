@tool
class_name RiderRig
extends Node3D

const MOUNTED_BASE := &"Mounted_Base"
const MOUNTED_LEAN_ADD_NODES: Array[StringName] = [
	&"automatic_turn_add",
	&"manual_roll_add",
	&"manual_pitch_add",
]

enum RiderSkin {
	# Serialized values: BOT = 0, RACER = 1, RIDER01 = 2.
	BOT,
	RACER,
	RIDER01,
}

@export var rider_skin: RiderSkin = RiderSkin.BOT:
	set(value):
		rider_skin = value
		_apply_rider_skin()

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
var _bot_skin_meshes: Array[MeshInstance3D] = []
var _racer_skin_meshes: Array[MeshInstance3D] = []
var _rider01_skin_meshes: Array[MeshInstance3D] = []


func _ready() -> void:
	_resolve_rider_skin_meshes()
	_apply_rider_skin()
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


func set_rider_skin(value: RiderSkin) -> void:
	rider_skin = value


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


func _resolve_rider_skin_meshes() -> void:
	_bot_skin_meshes.clear()
	_racer_skin_meshes.clear()
	_rider01_skin_meshes.clear()
	var rider_bot := get_node_or_null("RiderModelRoot/Rider_Bot")
	if rider_bot == null:
		push_warning("RiderRig cannot resolve RiderModelRoot/Rider_Bot.")
		return
	var pending: Array[Node] = [rider_bot]
	while not pending.is_empty():
		var current: Node = pending.pop_back() as Node
		if current is MeshInstance3D:
			var mesh_instance := current as MeshInstance3D
			if mesh_instance.is_in_group(&"rider_skin_racer"):
				_racer_skin_meshes.append(mesh_instance)
			elif mesh_instance.is_in_group(&"rider_skin_rider01"):
				_rider01_skin_meshes.append(mesh_instance)
			elif mesh_instance.mesh != null:
				_bot_skin_meshes.append(mesh_instance)
		for child: Node in current.get_children():
			pending.append(child)


func _apply_rider_skin() -> void:
	if not is_node_ready():
		return
	var racer_valid := _skin_meshes_valid(_racer_skin_meshes)
	var rider01_valid := _skin_meshes_valid(_rider01_skin_meshes)
	var show_racer := rider_skin == RiderSkin.RACER and racer_valid
	var show_rider01 := (
		rider_skin == RiderSkin.RIDER01 and rider01_valid
	)
	if rider_skin == RiderSkin.RACER and not racer_valid:
		push_warning(
			"Racer skin resources are missing; RiderRig is showing BOT."
		)
	if rider_skin == RiderSkin.RIDER01 and not rider01_valid:
		push_warning(
			"Rider01 skin resources are missing; RiderRig is showing BOT."
		)
	for mesh_instance in _bot_skin_meshes:
		mesh_instance.visible = not show_racer and not show_rider01
	for mesh_instance in _racer_skin_meshes:
		mesh_instance.visible = show_racer
	for mesh_instance in _rider01_skin_meshes:
		mesh_instance.visible = show_rider01


func _skin_meshes_valid(
	meshes: Array[MeshInstance3D]
) -> bool:
	if meshes.is_empty():
		return false
	for mesh_instance in meshes:
		if mesh_instance.mesh == null or mesh_instance.skin == null:
			return false
	return true


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
