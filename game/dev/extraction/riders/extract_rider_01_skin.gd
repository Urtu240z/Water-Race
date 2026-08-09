extends SceneTree

const RIDER_01_SCENE_PATH := \
	"res://gameplay/riders/rider_01/rider_01_compatible.glb"
const RIDER_BOT_SCENE_PATH := \
	"res://gameplay/riders/rider_bot/rider_bot.glb"
const OUTPUT_DIR := \
	"res://gameplay/riders/rider_01/runtime"
const MESH_OUTPUT := OUTPUT_DIR + "/rider_01_body_mesh.res"
const SKIN_OUTPUT := OUTPUT_DIR + "/rider_01_skin.res"
const REPORT_OUTPUT := "user://rider_01_extraction_report.txt"
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
	_report.append("=== RIDER_01 GODOT EXTRACTION ===")
	_report.append("Godot: %s" % Engine.get_version_info().string)
	var rider_01_packed := load(RIDER_01_SCENE_PATH) as PackedScene
	var bot_packed := load(RIDER_BOT_SCENE_PATH) as PackedScene
	if rider_01_packed == null or bot_packed == null:
		return _fail("Could not load rider_01 GLB or canonical rider_bot.")
	var rider_01_root := rider_01_packed.instantiate()
	var bot_root := bot_packed.instantiate()
	if rider_01_root == null or bot_root == null:
		return _fail("Could not instantiate rider_01 GLB or rider_bot.")

	var rider_01_skeletons := _collect_type(rider_01_root, &"Skeleton3D")
	var rider_01_meshes := _collect_skinned_meshes(rider_01_root)
	if rider_01_skeletons.size() != 1:
		return _fail(
			"rider_01 GLB has %d Skeleton3D nodes; expected 1."
			% rider_01_skeletons.size()
		)
	if rider_01_meshes.size() != 1:
		return _fail(
			"rider_01 GLB has %d skinned meshes; expected 1."
			% rider_01_meshes.size()
		)
	var rider_01_skeleton := rider_01_skeletons[0] as Skeleton3D
	var rider_01_mesh := rider_01_meshes[0]
	var bot_skeletons := _collect_type(bot_root, &"Skeleton3D")
	if bot_skeletons.size() != 1:
		return _fail(
			"rider_bot has %d Skeleton3D nodes; expected 1."
			% bot_skeletons.size()
		)
	var rig_skeleton := bot_skeletons[0] as Skeleton3D
	var bot_meshes := _collect_bot_meshes(bot_root)
	if bot_meshes.size() != 1:
		return _fail(
			"RiderRig has %d canonical BOT meshes; expected 1."
			% bot_meshes.size()
		)
	var bot_mesh := bot_meshes[0]

	var skeleton_error := _compare_skeletons(
		rider_01_skeleton,
		rig_skeleton,
	)
	if not skeleton_error.is_empty():
		return _fail(skeleton_error)
	var skin_error := _compare_skins(rider_01_mesh.skin, bot_mesh.skin)
	if not skin_error.is_empty():
		return _fail(skin_error)
	if not rider_01_mesh.mesh is ArrayMesh:
		return _fail("rider_01 skinned mesh is not an ArrayMesh.")

	var absolute_output := ProjectSettings.globalize_path(OUTPUT_DIR)
	var directory_error := DirAccess.make_dir_recursive_absolute(
		absolute_output
	)
	if directory_error != OK and directory_error != ERR_ALREADY_EXISTS:
		return _fail("Could not create rider_01 runtime directory.")

	var mesh_copy := rider_01_mesh.mesh.duplicate(true) as ArrayMesh
	var skin_copy := rider_01_mesh.skin.duplicate(true) as Skin
	if mesh_copy == null or skin_copy == null:
		return _fail("Could not duplicate rider_01 Mesh or Skin.")
	for surface_index: int in mesh_copy.get_surface_count():
		var material := rider_01_mesh.get_active_material(surface_index)
		if material == null:
			return _fail(
				"rider_01 surface %d has no material." % surface_index
			)
		mesh_copy.surface_set_material(
			surface_index,
			material.duplicate(true),
		)

	var mesh_error := ResourceSaver.save(mesh_copy, MESH_OUTPUT)
	var skin_save_error := ResourceSaver.save(skin_copy, SKIN_OUTPUT)
	if mesh_error != OK or skin_save_error != OK:
		return _fail(
			"ResourceSaver failed: mesh=%s skin=%s."
			% [error_string(mesh_error), error_string(skin_save_error)]
		)

	var mesh_stats := _mesh_stats(rider_01_mesh)
	_report.append(
		"rider_01 Skeleton3D: %s"
		% _relative_path(rider_01_skeleton, rider_01_root)
	)
	_report.append(
		"rider_01 MeshInstance3D: %s"
		% _relative_path(rider_01_mesh, rider_01_root)
	)
	_report.append(
		"Canonical Skeleton3D: %s"
		% _relative_path(rig_skeleton, bot_root)
	)
	_report.append("Skeleton comparison: PASS")
	_report.append("Skin bind comparison: PASS")
	_report.append("Bone count: %d" % rider_01_skeleton.get_bone_count())
	_report.append("Bind count: %d" % skin_copy.get_bind_count())
	_report.append("Mesh stats: %s" % mesh_stats)
	_report.append("Mesh resource: %s" % MESH_OUTPUT)
	_report.append("Skin resource: %s" % SKIN_OUTPUT)
	for surface_index: int in mesh_copy.get_surface_count():
		var material := mesh_copy.surface_get_material(surface_index)
		_report.append(
			"Surface %d material: %s (%s)"
			% [
				surface_index,
				material.resource_name,
				material.get_class(),
			]
		)
	var persistence_error := _validate_persistent_resource(MESH_OUTPUT)
	if not persistence_error.is_empty():
		return _fail(persistence_error)
	persistence_error = _validate_persistent_resource(SKIN_OUTPUT)
	if not persistence_error.is_empty():
		return _fail(persistence_error)
	_report.append("Persistent resource dependency check: PASS")
	_report.append("EXTRACTION_STATUS=PASS")
	_write_report()
	rider_01_root.free()
	bot_root.free()
	return 0


func _collect_type(root: Node, type_name: StringName) -> Array[Node]:
	var result: Array[Node] = []
	var pending: Array[Node] = [root]
	while not pending.is_empty():
		var current: Node = pending.pop_back() as Node
		if current.is_class(type_name):
			result.append(current)
		for child: Node in current.get_children():
			pending.append(child)
	return result


func _collect_skinned_meshes(root: Node) -> Array[MeshInstance3D]:
	var result: Array[MeshInstance3D] = []
	for node: Node in _collect_type(root, &"MeshInstance3D"):
		var mesh_instance := node as MeshInstance3D
		if mesh_instance.mesh != null and mesh_instance.skin != null:
			result.append(mesh_instance)
	return result


func _collect_bot_meshes(root: Node) -> Array[MeshInstance3D]:
	var result: Array[MeshInstance3D] = []
	for mesh_instance: MeshInstance3D in _collect_skinned_meshes(root):
		if not _has_rider_skin_group(mesh_instance):
			result.append(mesh_instance)
	return result


func _has_rider_skin_group(mesh_instance: MeshInstance3D) -> bool:
	for group: StringName in mesh_instance.get_groups():
		if String(group).begins_with("rider_skin_"):
			return true
	return false


func _compare_skeletons(left: Skeleton3D, right: Skeleton3D) -> String:
	if left.get_bone_count() != right.get_bone_count():
		return (
			"Skeleton bone count mismatch: rider_01=%d RiderRig=%d."
			% [left.get_bone_count(), right.get_bone_count()]
		)
	var left_globals := _global_rests(left)
	var right_globals := _global_rests(right)
	for bone_index: int in left.get_bone_count():
		var left_name := left.get_bone_name(bone_index)
		var right_name := right.get_bone_name(bone_index)
		if left_name != right_name:
			return (
				"Bone name/order mismatch at %d: rider_01=%s RiderRig=%s."
				% [bone_index, left_name, right_name]
			)
		if left.get_bone_parent(bone_index) != right.get_bone_parent(
			bone_index
		):
			return "Bone parent mismatch at %s." % left_name
		var local_error := _transform_error(
			left.get_bone_rest(bone_index),
			right.get_bone_rest(bone_index),
		)
		var global_error := _transform_error(
			left_globals[bone_index],
			right_globals[bone_index],
		)
		if (
			local_error > TRANSFORM_TOLERANCE
			or global_error > TRANSFORM_TOLERANCE
		):
			return (
				"Rest mismatch at %s: local=%.9f global=%.9f."
				% [left_name, local_error, global_error]
			)
	return ""


func _compare_skins(left: Skin, right: Skin) -> String:
	if left == null or right == null:
		return "rider_01 or BOT Skin is null."
	if left.get_bind_count() != right.get_bind_count():
		return (
			"Skin bind count mismatch: rider_01=%d BOT=%d."
			% [left.get_bind_count(), right.get_bind_count()]
		)
	for bind_index: int in left.get_bind_count():
		if left.get_bind_name(bind_index) != right.get_bind_name(bind_index):
			return (
				"Skin bind name mismatch at %d: rider_01=%s BOT=%s."
				% [
					bind_index,
					left.get_bind_name(bind_index),
					right.get_bind_name(bind_index),
				]
			)
		if left.get_bind_bone(bind_index) != right.get_bind_bone(bind_index):
			return "Skin bind index mismatch at %d." % bind_index
		if _transform_error(
			left.get_bind_pose(bind_index),
			right.get_bind_pose(bind_index),
		) > TRANSFORM_TOLERANCE:
			return "Skin bind pose mismatch at %d." % bind_index
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


func _transform_error(left: Transform3D, right: Transform3D) -> float:
	var origin_delta := (left.origin - right.origin).abs()
	var maximum := maxf(
		origin_delta.x,
		maxf(origin_delta.y, origin_delta.z),
	)
	for axis: int in 3:
		var delta := (left.basis[axis] - right.basis[axis]).abs()
		maximum = maxf(
			maximum,
			maxf(delta.x, maxf(delta.y, delta.z)),
		)
	return maximum


func _mesh_stats(mesh_instance: MeshInstance3D) -> Dictionary:
	var vertices := 0
	var triangles := 0
	var materials := 0
	for surface_index: int in mesh_instance.mesh.get_surface_count():
		var arrays := mesh_instance.mesh.surface_get_arrays(surface_index)
		var positions := arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array
		var indices := arrays[Mesh.ARRAY_INDEX] as PackedInt32Array
		vertices += positions.size()
		triangles += (
			indices.size() / 3
			if not indices.is_empty()
			else positions.size() / 3
		)
		if mesh_instance.get_active_material(surface_index) != null:
			materials += 1
	return {
		"surfaces": mesh_instance.mesh.get_surface_count(),
		"vertices": vertices,
		"triangles": triangles,
		"materials": materials,
		"aabb_size": mesh_instance.get_aabb().size,
	}


func _validate_persistent_resource(path: String) -> String:
	var resource := load(path)
	if resource == null:
		return "Could not reload persistent resource %s." % path
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return "Could not inspect persistent resource %s." % path
	var serialized := file.get_as_text()
	if serialized.contains("res://.godot/imported"):
		return "%s depends on res://.godot/imported." % path
	return ""


func _relative_path(node: Node, root: Node) -> String:
	var names: PackedStringArray = []
	var current: Node = node
	while current != null:
		names.insert(0, String(current.name))
		if current == root:
			break
		current = current.get_parent()
	return "/".join(names)


func _fail(message: String) -> int:
	_report.append("ERROR: %s" % message)
	_report.append("EXTRACTION_STATUS=FAIL")
	push_error(message)
	_write_report()
	return 1


func _write_report() -> void:
	DirAccess.make_dir_recursive_absolute(
		ProjectSettings.globalize_path(OUTPUT_DIR)
	)
	var file := FileAccess.open(REPORT_OUTPUT, FileAccess.WRITE)
	if file != null:
		file.store_string("\n".join(_report) + "\n")
