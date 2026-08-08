extends SceneTree

const RIDER01_SCENE_PATH := \
	"res://assets/3D/Rider/skins/Rider01/Rider01_RiderCompatible.glb"
const RIDER_RIG_PATH := "res://gameplay/riders/common/rider_rig.tscn"
const RIDER_SKELETON_PATH := \
	"RiderModelRoot/Rider_Bot/SKEL_Rider/Skeleton3D"
const OUTPUT_DIR := \
	"res://assets/3D/Rider/skins/Rider01/runtime"
const SKIN_OUTPUT := OUTPUT_DIR + "/Rider01_Skin.res"
const REPORT_OUTPUT := OUTPUT_DIR + "/Rider01_Extraction_Report.txt"
const TRANSFORM_TOLERANCE := 0.0002
const EXPECTED_MESHES := 6

var _report: PackedStringArray = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var exit_code := _extract_and_validate()
	if not _report.is_empty():
		print("\n".join(_report))
	quit(exit_code)


func _extract_and_validate() -> int:
	_report.append("=== RIDER01 GODOT EXTRACTION ===")
	_report.append("Godot: %s" % Engine.get_version_info().string)
	var rider01_packed := load(RIDER01_SCENE_PATH) as PackedScene
	var rig_packed := load(RIDER_RIG_PATH) as PackedScene
	if rider01_packed == null or rig_packed == null:
		return _fail("Could not load Rider01 compatible GLB or RiderRig.")
	var rider01_root := rider01_packed.instantiate()
	var rig_root := rig_packed.instantiate()
	if rider01_root == null or rig_root == null:
		return _fail("Could not instantiate Rider01 compatible GLB or RiderRig.")

	var rider01_skeletons := _collect_nodes_of_type(
		rider01_root, &"Skeleton3D"
	)
	var rider01_mesh_nodes := _collect_nodes_of_type(
		rider01_root, &"MeshInstance3D"
	)
	if rider01_skeletons.size() != 1:
		return _fail(
			"Rider01 GLB has %d Skeleton3D nodes; expected 1."
			% rider01_skeletons.size()
		)
	var rider01_skeleton := rider01_skeletons[0] as Skeleton3D
	var rider01_meshes: Array[MeshInstance3D] = []
	for node: Node in rider01_mesh_nodes:
		var mesh_instance := node as MeshInstance3D
		if mesh_instance.mesh != null and mesh_instance.skin != null:
			rider01_meshes.append(mesh_instance)
	if rider01_meshes.size() != EXPECTED_MESHES:
		return _fail(
			"Rider01 GLB has %d skinned meshes; expected %d."
			% [rider01_meshes.size(), EXPECTED_MESHES]
		)
	rider01_meshes.sort_custom(
		func(left: MeshInstance3D, right: MeshInstance3D) -> bool:
			return String(left.name) < String(right.name)
	)

	var rig_skeleton := rig_root.get_node_or_null(
		RIDER_SKELETON_PATH
	) as Skeleton3D
	if rig_skeleton == null:
		return _fail(
			"RiderRig skeleton not found at %s." % RIDER_SKELETON_PATH
		)
	var bot_meshes := _collect_bot_meshes(
		rig_root.get_node("RiderModelRoot/Rider_Bot")
	)
	if bot_meshes.size() != 1:
		return _fail(
			"Rider_Bot has %d original skinned meshes; expected 1."
			% bot_meshes.size()
		)
	var bot_mesh := bot_meshes[0]

	var skeleton_error := _compare_skeletons(
		rider01_skeleton, rig_skeleton
	)
	if not skeleton_error.is_empty():
		return _fail(skeleton_error)
	for mesh_instance: MeshInstance3D in rider01_meshes:
		var skin_error := _compare_skins(mesh_instance.skin, bot_mesh.skin)
		if not skin_error.is_empty():
			return _fail(
				"%s: %s" % [mesh_instance.name, skin_error]
			)

	var absolute_output := ProjectSettings.globalize_path(OUTPUT_DIR)
	var directory_error := DirAccess.make_dir_recursive_absolute(
		absolute_output
	)
	if directory_error != OK and directory_error != ERR_ALREADY_EXISTS:
		return _fail("Could not create Rider01 runtime directory.")

	var shared_skin := rider01_meshes[0].skin.duplicate(true) as Skin
	if shared_skin == null:
		return _fail("Could not duplicate Rider01 shared Skin.")
	var skin_save_error := ResourceSaver.save(shared_skin, SKIN_OUTPUT)
	if skin_save_error != OK:
		return _fail(
			"Could not save Rider01 Skin: %s."
			% error_string(skin_save_error)
		)

	var mesh_outputs: PackedStringArray = []
	for mesh_instance: MeshInstance3D in rider01_meshes:
		if not mesh_instance.mesh is ArrayMesh:
			return _fail(
				"%s is not an ArrayMesh." % mesh_instance.name
			)
		var mesh_copy := mesh_instance.mesh.duplicate(true) as ArrayMesh
		if mesh_copy == null:
			return _fail(
				"Could not duplicate %s." % mesh_instance.name
			)
		for surface_index: int in mesh_copy.get_surface_count():
			var material := mesh_instance.get_active_material(surface_index)
			if material != null:
				mesh_copy.surface_set_material(
					surface_index,
					material.duplicate(true)
				)
		var stable_name := String(mesh_instance.name).trim_suffix(
			"_RiderBotRest"
		)
		var mesh_output := (
			OUTPUT_DIR + "/%s_Mesh.res" % stable_name
		)
		var mesh_error := ResourceSaver.save(mesh_copy, mesh_output)
		if mesh_error != OK:
			return _fail(
				"Could not save %s: %s."
				% [mesh_output, error_string(mesh_error)]
			)
		mesh_outputs.append(mesh_output)

	_report.append(
		"Rider01 Skeleton3D: %s"
		% _relative_path(rider01_skeleton, rider01_root)
	)
	_report.append("Rider Skeleton3D: %s" % RIDER_SKELETON_PATH)
	_report.append("Skeleton comparison: PASS")
	_report.append("All six Skin bind comparisons: PASS")
	_report.append(
		"Bone count: %d" % rider01_skeleton.get_bone_count()
	)
	_report.append(
		"Shared bind count: %d" % shared_skin.get_bind_count()
	)
	_report.append("Shared Skin resource: %s" % SKIN_OUTPUT)
	for mesh_output: String in mesh_outputs:
		_report.append("Mesh resource: %s" % mesh_output)
	_report.append("EXTRACTION_STATUS=PASS")
	_write_report()
	rider01_root.free()
	rig_root.free()
	return 0


func _collect_nodes_of_type(
	root: Node,
	type_name: StringName
) -> Array[Node]:
	var result: Array[Node] = []
	var pending: Array[Node] = [root]
	while not pending.is_empty():
		var current: Node = pending.pop_back() as Node
		if current.is_class(type_name):
			result.append(current)
		for child: Node in current.get_children():
			pending.append(child)
	return result


func _collect_bot_meshes(root: Node) -> Array[MeshInstance3D]:
	var result: Array[MeshInstance3D] = []
	for node: Node in _collect_nodes_of_type(root, &"MeshInstance3D"):
		var mesh_instance := node as MeshInstance3D
		if (
			mesh_instance.mesh != null
			and mesh_instance.skin != null
			and not mesh_instance.is_in_group(&"rider_skin_racer")
			and not mesh_instance.is_in_group(&"rider_skin_rider01")
		):
			result.append(mesh_instance)
	return result


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
			"Skeleton bone count mismatch: Rider01=%d RiderRig=%d."
			% [left.get_bone_count(), right.get_bone_count()]
		)
	var left_globals := _global_rests(left)
	var right_globals := _global_rests(right)
	for bone_index: int in left.get_bone_count():
		var left_name := left.get_bone_name(bone_index)
		var right_name := right.get_bone_name(bone_index)
		if left_name != right_name:
			return (
				"Bone name mismatch at %d: Rider01=%s RiderRig=%s."
				% [bone_index, left_name, right_name]
			)
		var left_parent := left.get_bone_parent(bone_index)
		var right_parent := right.get_bone_parent(bone_index)
		if left_parent != right_parent:
			return (
				"Bone parent mismatch at %s: Rider01=%d RiderRig=%d."
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
	for bone_index: int in skeleton.get_bone_count():
		var local := skeleton.get_bone_rest(bone_index)
		var parent := skeleton.get_bone_parent(bone_index)
		result[bone_index] = (
			result[parent] * local if parent >= 0 else local
		)
	return result


func _compare_skins(left: Skin, right: Skin) -> String:
	if left == null or right == null:
		return "Rider01 or Rider_Bot Skin is null."
	if left.get_bind_count() != right.get_bind_count():
		return (
			"Skin bind count mismatch: Rider01=%d Rider_Bot=%d."
			% [left.get_bind_count(), right.get_bind_count()]
		)
	for bind_index: int in left.get_bind_count():
		if left.get_bind_name(bind_index) != right.get_bind_name(bind_index):
			return (
				"Skin bind name mismatch at %d: Rider01=%s Rider_Bot=%s."
				% [
					bind_index,
					left.get_bind_name(bind_index),
					right.get_bind_name(bind_index),
				]
			)
		if left.get_bind_bone(bind_index) != right.get_bind_bone(bind_index):
			return (
				"Skin bind bone mismatch at %s: Rider01=%d Rider_Bot=%d."
				% [
					left.get_bind_name(bind_index),
					left.get_bind_bone(bind_index),
					right.get_bind_bone(bind_index),
				]
			)
		var pose_error := _transform_error(
			left.get_bind_pose(bind_index),
			right.get_bind_pose(bind_index)
		)
		if pose_error > TRANSFORM_TOLERANCE:
			return (
				"Skin bind pose mismatch at %s: %.9f > %.9f."
				% [
					left.get_bind_name(bind_index),
					pose_error,
					TRANSFORM_TOLERANCE,
				]
			)
	return ""


func _transform_error(left: Transform3D, right: Transform3D) -> float:
	var origin_delta := (left.origin - right.origin).abs()
	var maximum := maxf(
		origin_delta.x,
		maxf(origin_delta.y, origin_delta.z)
	)
	for axis: int in 3:
		var delta := (left.basis[axis] - right.basis[axis]).abs()
		maximum = maxf(
			maximum,
			maxf(delta.x, maxf(delta.y, delta.z))
		)
	return maximum


func _fail(message: String) -> int:
	_report.append("ERROR: %s" % message)
	_report.append("EXTRACTION_STATUS=FAIL")
	push_error(message)
	_write_report()
	return 1


func _write_report() -> void:
	var absolute_dir := ProjectSettings.globalize_path(OUTPUT_DIR)
	DirAccess.make_dir_recursive_absolute(absolute_dir)
	var file := FileAccess.open(REPORT_OUTPUT, FileAccess.WRITE)
	if file != null:
		file.store_string("\n".join(_report) + "\n")
