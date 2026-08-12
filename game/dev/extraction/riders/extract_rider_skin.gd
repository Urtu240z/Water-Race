extends SceneTree

# Shared extractor used exclusively by tools/riders/rebuild_riders.py.
# It deliberately reads the staged GLB, but writes only a candidate directory.
const RIDER_BOT_SCENE_PATH := "res://gameplay/riders/rider_bot/rider_bot.glb"
const RIDER_IDS := [
	&"rider_01",
	&"rider_02",
	&"rider_03",
	&"rider_04",
	&"rider_05",
]
const TRANSFORM_TOLERANCE := 0.0002

var _rider_id := ""
var _output_dir := ""
var _texture_root := ""


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_rider_id = _argument("--rider")
	if _rider_id.is_empty():
		_rider_id = _argument("--skin-id")
	_output_dir = _argument("--output-dir")
	_texture_root = _argument("--texture-root")
	if RIDER_IDS.has(StringName(_rider_id)):
		if _output_dir.is_empty():
			_output_dir = "res://gameplay/riders/%s/runtime" % _rider_id
		if _texture_root.is_empty():
			_texture_root = _output_dir + "/textures"
	else:
		push_error("Expected --rider rider_0x --output-dir res://... --texture-root res://...")
		quit(2)
		return
	quit(_extract())


func _argument(name: String) -> String:
	var arguments := OS.get_cmdline_user_args()
	for index: int in arguments.size():
		var argument := arguments[index]
		if argument.begins_with(name + "="):
			return argument.trim_prefix(name + "=")
		if argument == name and index + 1 < arguments.size():
			return arguments[index + 1]
	return ""


func _extract() -> int:
	var scene_path := "res://gameplay/riders/%s/%s_compatible.glb" % [_rider_id, _rider_id]
	var compatible := load(scene_path) as PackedScene
	var bot := load(RIDER_BOT_SCENE_PATH) as PackedScene
	if compatible == null or bot == null:
		return _fail("Could not load staged compatible GLB or rider_bot.")
	var compatible_root := compatible.instantiate()
	var bot_root := bot.instantiate()
	var source_meshes := _skinned_meshes(compatible_root)
	var bot_meshes := _skinned_meshes(bot_root)
	var source_skeletons := _nodes_of_type(compatible_root, &"Skeleton3D")
	var bot_skeletons := _nodes_of_type(bot_root, &"Skeleton3D")
	if source_meshes.size() != 1 or bot_meshes.size() != 1 or source_skeletons.size() != 1 or bot_skeletons.size() != 1:
		return _fail("Expected one skinned mesh and one Skeleton3D in compatible GLB and rider_bot.")
	var source_mesh := source_meshes[0] as MeshInstance3D
	var bot_mesh := bot_meshes[0] as MeshInstance3D
	var skeleton_error := _compare_skeletons(source_skeletons[0] as Skeleton3D, bot_skeletons[0] as Skeleton3D)
	if not skeleton_error.is_empty():
		return _fail(skeleton_error)
	if not _skins_match(source_mesh.skin, bot_mesh.skin):
		return _fail("Compatible skin no longer matches rider_bot binds.")
	var mesh_copy := source_mesh.mesh.duplicate(true) as ArrayMesh
	var skin_copy := source_mesh.skin.duplicate(true) as Skin
	if mesh_copy == null or skin_copy == null:
		return _fail("Could not duplicate compatible mesh or skin.")
	for surface_index: int in mesh_copy.get_surface_count():
		var source_material := source_mesh.get_active_material(surface_index)
		if source_material == null:
			return _fail("Surface %d has no material." % surface_index)
		var material := source_material.duplicate(true) as Material
		var remap_error := _remap_material_textures(material)
		if not remap_error.is_empty():
			return _fail(remap_error)
		mesh_copy.surface_set_material(surface_index, material)
	var output_error := DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(_output_dir))
	if output_error != OK and output_error != ERR_ALREADY_EXISTS:
		return _fail("Could not create candidate output directory.")
	var mesh_path := "%s/%s_body_mesh.res" % [_output_dir, _rider_id]
	var skin_path := "%s/%s_skin.res" % [_output_dir, _rider_id]
	if ResourceSaver.save(mesh_copy, mesh_path) != OK or ResourceSaver.save(skin_copy, skin_path) != OK:
		return _fail("ResourceSaver failed for candidate resources.")
	if load(mesh_path) == null or load(skin_path) == null:
		return _fail("Candidate resources could not be reloaded.")
	print("EXTRACTION_STATUS=PASS rider=%s mesh=%s skin=%s" % [_rider_id, mesh_path, skin_path])
	compatible_root.free()
	bot_root.free()
	return 0


func _remap_material_textures(material: Material) -> String:
	for property: Dictionary in material.get_property_list():
		var property_name := String(property.name)
		if not property_name.ends_with("_texture"):
			continue
		var texture_value: Variant = material.get(property.name)
		if not texture_value is Texture2D:
			continue
		var texture := texture_value as Texture2D
		var destination := "%s/%s" % [_texture_root, texture.resource_path.get_file()]
		var runtime_texture := load(destination) as Texture2D
		if runtime_texture == null:
			return "Missing imported runtime texture %s for %s." % [destination, property_name]
		material.set(property.name, runtime_texture)
	return ""


func _nodes_of_type(root_node: Node, type_name: StringName) -> Array[Node]:
	var result: Array[Node] = []
	var pending: Array[Node] = [root_node]
	while not pending.is_empty():
		var current: Node = pending.pop_back()
		if current.is_class(type_name):
			result.append(current)
		for child: Node in current.get_children():
			pending.append(child)
	return result


func _skinned_meshes(root_node: Node) -> Array[Node]:
	var result: Array[Node] = []
	for node: Node in _nodes_of_type(root_node, &"MeshInstance3D"):
		var mesh := node as MeshInstance3D
		if mesh.mesh != null and mesh.skin != null and not _has_skin_group(mesh):
			result.append(mesh)
	return result


func _has_skin_group(mesh: MeshInstance3D) -> bool:
	for group: StringName in mesh.get_groups():
		if String(group).begins_with("rider_skin_"):
			return true
	return false


func _skins_match(left: Skin, right: Skin) -> bool:
	if left == null or right == null or left.get_bind_count() != right.get_bind_count():
		return false
	for index: int in left.get_bind_count():
		if left.get_bind_name(index) != right.get_bind_name(index) or left.get_bind_bone(index) != right.get_bind_bone(index):
			return false
		if _transform_error(left.get_bind_pose(index), right.get_bind_pose(index)) > TRANSFORM_TOLERANCE:
			return false
	return true


func _compare_skeletons(left: Skeleton3D, right: Skeleton3D) -> String:
	if left.get_bone_count() != right.get_bone_count():
		return "Skeleton bone count differs from rider_bot."
	for index: int in left.get_bone_count():
		if left.get_bone_name(index) != right.get_bone_name(index) or left.get_bone_parent(index) != right.get_bone_parent(index):
			return "Skeleton hierarchy differs at index %d." % index
		if _transform_error(left.get_bone_rest(index), right.get_bone_rest(index)) > TRANSFORM_TOLERANCE:
			return "Skeleton rest differs at index %d." % index
	return ""


func _transform_error(left: Transform3D, right: Transform3D) -> float:
	var origin_delta := (left.origin - right.origin).abs()
	var maximum := maxf(origin_delta.x, maxf(origin_delta.y, origin_delta.z))
	for axis: int in 3:
		var basis_delta := (left.basis[axis] - right.basis[axis]).abs()
		maximum = maxf(
			maximum,
			maxf(basis_delta.x, maxf(basis_delta.y, basis_delta.z)),
		)
	return maximum


func _fail(message: String) -> int:
	push_error(message)
	print("EXTRACTION_STATUS=FAIL rider=%s error=%s" % [_rider_id, message])
	return 1
