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
	# Fixed serialized values. Do not reorder or renumber existing skins.
	BOT = 0,
	RACER = 1,
	RIDER01 = 2,
	RIDER04 = 3,
	RIDER05 = 4,
	RIDER06 = 5,
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
var _skin_meshes_by_value: Dictionary = {}
var _last_missing_skin_warning: int = -1


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


static func get_rider_skin_options() -> Array[Dictionary]:
	var options: Array[Dictionary] = []
	for skin_name_variant: Variant in RiderSkin.keys():
		var skin_name := StringName(skin_name_variant)
		options.append(
			{
				"id": skin_name,
				"display_name": _format_rider_skin_name(skin_name),
				"value": int(RiderSkin[skin_name]),
			}
		)
	return options


static func get_rider_skin_id(value: int) -> StringName:
	for skin_name_variant: Variant in RiderSkin.keys():
		var skin_name := StringName(skin_name_variant)
		if int(RiderSkin[skin_name]) == value:
			return skin_name
	return &""


static func find_rider_skin_by_id(
	skin_id: StringName,
	fallback: int = RiderSkin.BOT
) -> int:
	if RiderSkin.has(skin_id):
		return int(RiderSkin[skin_id])
	return fallback


func get_available_rider_skin_options() -> Array[Dictionary]:
	var options: Array[Dictionary] = []
	for option: Dictionary in get_rider_skin_options():
		if is_rider_skin_available(int(option["value"])):
			options.append(option)
	return options


func is_rider_skin_available(value: int) -> bool:
	var meshes := _skin_meshes_by_value.get(value, []) as Array
	return _skin_meshes_valid(meshes)


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
	_skin_meshes_by_value.clear()
	for skin_value_variant: Variant in RiderSkin.values():
		_skin_meshes_by_value[int(skin_value_variant)] = []
	var rider_bot := get_node_or_null("RiderModelRoot/Rider_Bot")
	if rider_bot == null:
		push_warning("RiderRig cannot resolve RiderModelRoot/Rider_Bot.")
		return
	var pending: Array[Node] = [rider_bot]
	while not pending.is_empty():
		var current: Node = pending.pop_back() as Node
		if current is MeshInstance3D:
			var mesh_instance := current as MeshInstance3D
			var skin_value := _get_mesh_rider_skin(mesh_instance)
			if skin_value >= 0:
				var skin_meshes := (
					_skin_meshes_by_value[skin_value] as Array
				)
				skin_meshes.append(mesh_instance)
		for child: Node in current.get_children():
			pending.append(child)


func _apply_rider_skin() -> void:
	if not is_node_ready():
		return
	var selected_value := int(rider_skin)
	var displayed_value := selected_value
	if not is_rider_skin_available(selected_value):
		displayed_value = RiderSkin.BOT
	if displayed_value == selected_value:
		_last_missing_skin_warning = -1
	elif _last_missing_skin_warning != selected_value:
		_last_missing_skin_warning = selected_value
		push_warning(
			"%s skin resources are missing; RiderRig is showing BOT."
			% _format_rider_skin_name(get_rider_skin_id(selected_value))
		)
	for skin_value_variant: Variant in _skin_meshes_by_value:
		var skin_value := int(skin_value_variant)
		var skin_meshes := _skin_meshes_by_value[skin_value] as Array
		for mesh_variant: Variant in skin_meshes:
			var mesh_instance := mesh_variant as MeshInstance3D
			if mesh_instance != null:
				mesh_instance.visible = skin_value == displayed_value


func _skin_meshes_valid(
	meshes: Array
) -> bool:
	if meshes.is_empty():
		return false
	for mesh_variant: Variant in meshes:
		var mesh_instance := mesh_variant as MeshInstance3D
		if mesh_instance == null:
			return false
		if mesh_instance.mesh == null or mesh_instance.skin == null:
			return false
	return true


func _get_mesh_rider_skin(mesh_instance: MeshInstance3D) -> int:
	for skin_name_variant: Variant in RiderSkin.keys():
		var skin_name := StringName(skin_name_variant)
		if skin_name == &"BOT":
			continue
		var skin_group := StringName(
			"rider_skin_%s" % String(skin_name).to_lower()
		)
		if mesh_instance.is_in_group(skin_group):
			return int(RiderSkin[skin_name])
	if mesh_instance.mesh != null:
		return RiderSkin.BOT
	return -1


static func _format_rider_skin_name(skin_id: StringName) -> String:
	var raw_name := String(skin_id).to_lower().replace("_", " ")
	var formatted_name := ""
	for character_index: int in raw_name.length():
		var character := raw_name.substr(character_index, 1)
		if (
			character_index > 0
			and character.is_valid_int()
			and not raw_name.substr(character_index - 1, 1).is_valid_int()
			and not formatted_name.ends_with(" ")
		):
			formatted_name += " "
		formatted_name += character
	return formatted_name.capitalize()


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
