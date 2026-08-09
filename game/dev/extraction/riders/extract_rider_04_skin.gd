extends SceneTree

const RIDER_04_SCENE_PATH := \
	"res://gameplay/riders/rider_04/rider_04_compatible.glb"
const RIDER_BOT_SCENE_PATH := \
	"res://gameplay/riders/rider_bot/rider_bot.glb"
const OUTPUT_DIR := \
	"res://gameplay/riders/rider_04/runtime"
const MESH_OUTPUT := OUTPUT_DIR + "/rider_04_body_mesh.res"
const SKIN_OUTPUT := OUTPUT_DIR + "/rider_04_skin.res"
const REPORT_OUTPUT := "user://rider_04_extraction_report.txt"
const TRANSFORM_TOLERANCE := 0.0002

var _report: PackedStringArray = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var exit_code := _extract_and_validate()
	if not _report.is_empty():
		print("\n".join(_report))
	quit(exit_code)


func _extract_and_validate() -> int:
	_report.append("=== RIDER_04 GODOT EXTRACTION ===")
	_report.append("Godot: %s" % Engine.get_version_info().string)
	var rider_04_packed := load(RIDER_04_SCENE_PATH) as PackedScene
	var bot_packed := load(RIDER_BOT_SCENE_PATH) as PackedScene
	if rider_04_packed == null or bot_packed == null:
		return _fail("Could not load rider_04 GLB or canonical rider_bot.")
	var rider_04_root := rider_04_packed.instantiate()
	var bot_root := bot_packed.instantiate()
	if rider_04_root == null or bot_root == null:
		return _fail("Could not instantiate rider_04 GLB or rider_bot.")

	var rider_04_skeletons := _collect_nodes_of_type(rider_04_root, "Skeleton3D")
	var rider_04_meshes := _collect_nodes_of_type(rider_04_root, "MeshInstance3D")
	if rider_04_skeletons.size() != 1:
		return _fail(
			"rider_04 GLB has %d Skeleton3D nodes; expected 1."
			% rider_04_skeletons.size()
		)
	var rider_04_skeleton := rider_04_skeletons[0] as Skeleton3D
	var rider_04_mesh: MeshInstance3D = null
	for candidate_node in rider_04_meshes:
		var candidate := candidate_node as MeshInstance3D
		if candidate.skin != null and candidate.mesh != null:
			if rider_04_mesh != null:
				return _fail("rider_04 GLB has more than one skinned mesh.")
			rider_04_mesh = candidate
	if rider_04_mesh == null:
		return _fail("rider_04 GLB has no persistent skinned MeshInstance3D.")

	var bot_skeletons := _collect_nodes_of_type(bot_root, "Skeleton3D")
	if bot_skeletons.size() != 1:
		return _fail(
			"rider_bot has %d Skeleton3D nodes; expected 1."
			% bot_skeletons.size()
		)
	var rig_skeleton := bot_skeletons[0] as Skeleton3D
	var bot_meshes := _collect_skinned_meshes(bot_root)
	if bot_meshes.size() != 1:
		return _fail(
			"rider_bot has %d skinned visual meshes; expected 1."
			% bot_meshes.size()
		)
	var bot_mesh := bot_meshes[0] as MeshInstance3D

	_report.append(
		"rider_04 Skeleton3D: %s"
		% _relative_path(rider_04_skeleton, rider_04_root)
	)
	_report.append(
		"rider_04 MeshInstance3D: %s"
		% _relative_path(rider_04_mesh, rider_04_root)
	)
	_report.append(
		"Rider Skeleton3D: %s"
		% _relative_path(rig_skeleton, bot_root)
	)
	_report.append(
		"Bot MeshInstance3D: %s"
		% _relative_path(bot_mesh, bot_root)
	)
	var skeleton_error := _compare_skeletons(rider_04_skeleton, rig_skeleton)
	if not skeleton_error.is_empty():
		return _fail(skeleton_error)
	var skin_error := _compare_skins(rider_04_mesh.skin, bot_mesh.skin)
	if not skin_error.is_empty():
		return _fail(skin_error)

	if not rider_04_mesh.mesh is ArrayMesh:
		return _fail("rider_04 mesh is not an ArrayMesh.")
	var mesh_copy := rider_04_mesh.mesh.duplicate(true) as ArrayMesh
	if mesh_copy == null:
		return _fail("Could not duplicate rider_04 ArrayMesh.")
	for surface_index in mesh_copy.get_surface_count():
		var material := rider_04_mesh.get_active_material(surface_index)
		if material != null:
			mesh_copy.surface_set_material(
				surface_index,
				material.duplicate(true)
			)
	var skin_copy := rider_04_mesh.skin.duplicate(true) as Skin
	if skin_copy == null:
		return _fail("Could not duplicate rider_04 Skin.")

	var absolute_output := ProjectSettings.globalize_path(OUTPUT_DIR)
	var directory_error := DirAccess.make_dir_recursive_absolute(
		absolute_output
	)
	if directory_error != OK and directory_error != ERR_ALREADY_EXISTS:
		return _fail("Could not create runtime output directory.")
	var mesh_error := ResourceSaver.save(mesh_copy, MESH_OUTPUT)
	var skin_save_error := ResourceSaver.save(skin_copy, SKIN_OUTPUT)
	if mesh_error != OK or skin_save_error != OK:
		return _fail(
			"ResourceSaver failed: mesh=%s skin=%s."
			% [error_string(mesh_error), error_string(skin_save_error)]
		)
	_report.append("Skeleton comparison: PASS")
	_report.append("Skin bind comparison: PASS")
	_report.append("Bone count: %d" % rider_04_skeleton.get_bone_count())
	_report.append("Bind count: %d" % rider_04_mesh.skin.get_bind_count())
	_report.append("Mesh resource: %s" % MESH_OUTPUT)
	_report.append("Skin resource: %s" % SKIN_OUTPUT)
	_report.append("EXTRACTION_STATUS=PASS")
	_write_report()
	rider_04_root.free()
	bot_root.free()
	return 0


func _collect_nodes_of_type(root: Node, type_name: StringName) -> Array[Node]:
	var result: Array[Node] = []
	var pending: Array[Node] = [root]
	while not pending.is_empty():
		var current: Node = pending.pop_back() as Node
		if current.is_class(type_name):
			result.append(current)
		for child: Node in current.get_children():
			pending.append(child)
	return result


func _collect_skinned_meshes(root: Node) -> Array[Node]:
	var result: Array[Node] = []
	for node in _collect_nodes_of_type(root, &"MeshInstance3D"):
		var mesh_node := node as MeshInstance3D
		if (
			mesh_node.mesh != null
			and mesh_node.skin != null
			and not _has_rider_skin_group(mesh_node)
		):
			result.append(mesh_node)
	return result


func _has_rider_skin_group(mesh_instance: MeshInstance3D) -> bool:
	for group: StringName in mesh_instance.get_groups():
		if String(group).begins_with("rider_skin_"):
			return true
	return false


func _relative_path(node: Node, root: Node) -> String:
	var names: PackedStringArray = []
	var current: Node = node
	while current != null:
		names.insert(0, String(current.name))
		if current == root:
			break
		current = current.get_parent()
	return "/".join(names)


func _compare_skeletons(left: Skeleton3D, right: Skeleton3D) -> String:
	if left.get_bone_count() != right.get_bone_count():
		return (
			"Skeleton bone count mismatch: rider_04=%d RiderRig=%d."
			% [left.get_bone_count(), right.get_bone_count()]
		)
	var left_globals := _global_rests(left)
	var right_globals := _global_rests(right)
	for bone_index in left.get_bone_count():
		var left_name := left.get_bone_name(bone_index)
		var right_name := right.get_bone_name(bone_index)
		if left_name != right_name:
			return (
				"Bone name mismatch at %d: rider_04=%s RiderRig=%s."
				% [bone_index, left_name, right_name]
			)
		var left_parent := left.get_bone_parent(bone_index)
		var right_parent := right.get_bone_parent(bone_index)
		if left_parent != right_parent:
			return (
				"Bone parent mismatch at %s: rider_04=%d RiderRig=%d."
				% [left_name, left_parent, right_parent]
			)
		var local_error := _transform_error(
			left.get_bone_rest(bone_index),
			right.get_bone_rest(bone_index)
		)
		if local_error > TRANSFORM_TOLERANCE:
			return (
				"Local rest mismatch at %s: %.9f > %.9f."
				% [left_name, local_error, TRANSFORM_TOLERANCE]
			)
		var global_error := _transform_error(
			left_globals[bone_index],
			right_globals[bone_index]
		)
		if global_error > TRANSFORM_TOLERANCE:
			return (
				"Global rest mismatch at %s: %.9f > %.9f."
				% [left_name, global_error, TRANSFORM_TOLERANCE]
			)
	return ""


func _global_rests(skeleton: Skeleton3D) -> Array[Transform3D]:
	var result: Array[Transform3D] = []
	result.resize(skeleton.get_bone_count())
	for bone_index in skeleton.get_bone_count():
		var local := skeleton.get_bone_rest(bone_index)
		var parent := skeleton.get_bone_parent(bone_index)
		result[bone_index] = (
			result[parent] * local if parent >= 0 else local
		)
	return result


func _compare_skins(left: Skin, right: Skin) -> String:
	if left == null or right == null:
		return "rider_04 or rider_bot Skin is null."
	if left.get_bind_count() != right.get_bind_count():
		return (
			"Skin bind count mismatch: rider_04=%d rider_bot=%d."
			% [left.get_bind_count(), right.get_bind_count()]
		)
	for bind_index in left.get_bind_count():
		var left_name := left.get_bind_name(bind_index)
		var right_name := right.get_bind_name(bind_index)
		if left_name != right_name:
			return (
				"Skin bind name mismatch at %d: rider_04=%s rider_bot=%s."
				% [bind_index, left_name, right_name]
			)
		var left_bone := left.get_bind_bone(bind_index)
		var right_bone := right.get_bind_bone(bind_index)
		if left_bone != right_bone:
			return (
				"Skin bind bone mismatch at %s: rider_04=%d rider_bot=%d."
				% [left_name, left_bone, right_bone]
			)
		var pose_error := _transform_error(
			left.get_bind_pose(bind_index),
			right.get_bind_pose(bind_index)
		)
		if pose_error > TRANSFORM_TOLERANCE:
			return (
				"Skin bind pose mismatch at %s: %.9f > %.9f."
				% [left_name, pose_error, TRANSFORM_TOLERANCE]
			)
	return ""


func _transform_error(left: Transform3D, right: Transform3D) -> float:
	var values := PackedFloat32Array([
		absf(left.origin.x - right.origin.x),
		absf(left.origin.y - right.origin.y),
		absf(left.origin.z - right.origin.z),
	])
	for axis in 3:
		var left_column := left.basis[axis]
		var right_column := right.basis[axis]
		values.append(absf(left_column.x - right_column.x))
		values.append(absf(left_column.y - right_column.y))
		values.append(absf(left_column.z - right_column.z))
	var maximum := 0.0
	for value in values:
		maximum = maxf(maximum, value)
	return maximum


func _fail(message: String) -> int:
	_report.append("ERROR: %s" % message)
	_report.append("EXTRACTION_STATUS=FAIL")
	push_error(message)
	_write_report()
	return 1


func _write_report() -> void:
	var absolute_dir := ProjectSettings.globalize_path(
		REPORT_OUTPUT.get_base_dir()
	)
	DirAccess.make_dir_recursive_absolute(absolute_dir)
	var file := FileAccess.open(REPORT_OUTPUT, FileAccess.WRITE)
	if file != null:
		file.store_string("\n".join(_report) + "\n")
