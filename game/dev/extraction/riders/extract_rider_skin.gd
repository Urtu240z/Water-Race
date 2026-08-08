extends SceneTree

const RIDER_RIG_PATH := "res://gameplay/riders/common/rider_rig.tscn"
const RIDER_SKELETON_PATH := \
	"RiderModelRoot/Rider_Bot/SKEL_Rider/Skeleton3D"
const TRANSFORM_TOLERANCE := 0.0002

var _skin_id := ""
var _report: PackedStringArray = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_skin_id = _read_skin_id()
	if _skin_id.is_empty():
		push_error("Expected --skin-id Rider05 (or --skin-id=Rider05).")
		quit(2)
		return
	var exit_code := _extract_and_validate()
	if not _report.is_empty():
		print("\n".join(_report))
	quit(exit_code)


func _read_skin_id() -> String:
	var arguments := OS.get_cmdline_user_args()
	for index: int in arguments.size():
		var argument := arguments[index]
		if argument.begins_with("--skin-id="):
			return argument.trim_prefix("--skin-id=")
		if argument == "--skin-id" and index + 1 < arguments.size():
			return arguments[index + 1]
	return ""


func _extract_and_validate() -> int:
	var compatible_scene_path := (
		"res://assets/3D/Rider/skins/%s/%s_RiderCompatible.glb"
		% [_skin_id, _skin_id]
	)
	var output_dir := (
		"res://assets/3D/Rider/skins/%s/runtime" % _skin_id
	)
	var mesh_output := (
		"%s/%s_Body_Mesh.res" % [output_dir, _skin_id]
	)
	var skin_output := "%s/%s_Skin.res" % [output_dir, _skin_id]
	var report_output := (
		"%s/%s_Extraction_Report.txt" % [output_dir, _skin_id]
	)
	_report.append("=== %s GODOT EXTRACTION ===" % _skin_id.to_upper())
	_report.append("Godot: %s" % Engine.get_version_info().string)

	var compatible_packed := load(compatible_scene_path) as PackedScene
	var rig_packed := load(RIDER_RIG_PATH) as PackedScene
	if compatible_packed == null or rig_packed == null:
		return _fail(
			"Could not load compatible GLB or RiderRig.",
			report_output,
		)
	var compatible_root := compatible_packed.instantiate()
	var rig_root := rig_packed.instantiate()
	if compatible_root == null or rig_root == null:
		return _fail(
			"Could not instantiate compatible GLB or RiderRig.",
			report_output,
		)

	var compatible_skeletons := _collect_type(
		compatible_root,
		&"Skeleton3D",
	)
	var compatible_meshes := _collect_skinned_meshes(compatible_root)
	if compatible_skeletons.size() != 1:
		return _fail(
			"Compatible GLB has %d Skeleton3D nodes; expected 1."
			% compatible_skeletons.size(),
			report_output,
		)
	if compatible_meshes.size() != 1:
		return _fail(
			"Compatible GLB has %d skinned meshes; expected 1."
			% compatible_meshes.size(),
			report_output,
		)
	var compatible_skeleton := compatible_skeletons[0] as Skeleton3D
	var compatible_mesh := compatible_meshes[0]
	var rig_skeleton := rig_root.get_node_or_null(
		RIDER_SKELETON_PATH
	) as Skeleton3D
	if rig_skeleton == null:
		return _fail(
			"Canonical RiderRig Skeleton3D is missing.",
			report_output,
		)
	var bot_meshes := _collect_bot_meshes(
		rig_root.get_node("RiderModelRoot/Rider_Bot")
	)
	if bot_meshes.size() != 1:
		return _fail(
			"RiderRig has %d canonical BOT meshes; expected 1."
			% bot_meshes.size(),
			report_output,
		)
	var bot_mesh := bot_meshes[0]

	var skeleton_error := _compare_skeletons(
		compatible_skeleton,
		rig_skeleton,
	)
	if not skeleton_error.is_empty():
		return _fail(skeleton_error, report_output)
	var skin_error := _compare_skins(compatible_mesh.skin, bot_mesh.skin)
	if not skin_error.is_empty():
		return _fail(skin_error, report_output)
	if not compatible_mesh.mesh is ArrayMesh:
		return _fail(
			"Compatible skinned mesh is not an ArrayMesh.",
			report_output,
		)

	var absolute_output := ProjectSettings.globalize_path(output_dir)
	var directory_error := DirAccess.make_dir_recursive_absolute(
		absolute_output
	)
	if directory_error != OK and directory_error != ERR_ALREADY_EXISTS:
		return _fail(
			"Could not create runtime directory.",
			report_output,
		)

	var mesh_copy := compatible_mesh.mesh.duplicate(true) as ArrayMesh
	var skin_copy := compatible_mesh.skin.duplicate(true) as Skin
	if mesh_copy == null or skin_copy == null:
		return _fail(
			"Could not duplicate Mesh or Skin.",
			report_output,
		)
	for surface_index: int in mesh_copy.get_surface_count():
		var material := compatible_mesh.get_active_material(surface_index)
		if material == null:
			return _fail(
				"Surface %d has no material." % surface_index,
				report_output,
			)
		mesh_copy.surface_set_material(
			surface_index,
			material.duplicate(true),
		)

	var mesh_error := ResourceSaver.save(mesh_copy, mesh_output)
	var skin_save_error := ResourceSaver.save(skin_copy, skin_output)
	if mesh_error != OK or skin_save_error != OK:
		return _fail(
			"ResourceSaver failed: mesh=%s skin=%s."
			% [error_string(mesh_error), error_string(skin_save_error)],
			report_output,
		)

	_report.append("Compatible scene: %s" % compatible_scene_path)
	_report.append("Canonical Skeleton3D: %s" % RIDER_SKELETON_PATH)
	_report.append("Skeleton comparison: PASS")
	_report.append("Skin bind comparison: PASS")
	_report.append(
		"Bone count: %d" % compatible_skeleton.get_bone_count()
	)
	_report.append("Bind count: %d" % skin_copy.get_bind_count())
	_report.append("Mesh stats: %s" % _mesh_stats(compatible_mesh))
	_report.append("Mesh resource: %s" % mesh_output)
	_report.append("Skin resource: %s" % skin_output)
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
	var persistence_error := _validate_persistent_resource(mesh_output)
	if not persistence_error.is_empty():
		return _fail(persistence_error, report_output)
	persistence_error = _validate_persistent_resource(skin_output)
	if not persistence_error.is_empty():
		return _fail(persistence_error, report_output)
	_report.append("Persistent resource dependency check: PASS")
	_report.append("EXTRACTION_STATUS=PASS")
	_write_report(report_output)
	compatible_root.free()
	rig_root.free()
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
		var is_optional_skin := false
		for group: StringName in mesh_instance.get_groups():
			if String(group).begins_with("rider_skin_"):
				is_optional_skin = true
				break
		if not is_optional_skin:
			result.append(mesh_instance)
	return result


func _compare_skeletons(left: Skeleton3D, right: Skeleton3D) -> String:
	if left.get_bone_count() != right.get_bone_count():
		return (
			"Skeleton bone count mismatch: compatible=%d RiderRig=%d."
			% [left.get_bone_count(), right.get_bone_count()]
		)
	var left_globals := _global_rests(left)
	var right_globals := _global_rests(right)
	for bone_index: int in left.get_bone_count():
		var left_name := left.get_bone_name(bone_index)
		var right_name := right.get_bone_name(bone_index)
		if left_name != right_name:
			return (
				"Bone name/order mismatch at %d: compatible=%s RiderRig=%s."
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
		return "Compatible or BOT Skin is null."
	if left.get_bind_count() != right.get_bind_count():
		return (
			"Skin bind count mismatch: compatible=%d BOT=%d."
			% [left.get_bind_count(), right.get_bind_count()]
		)
	for bind_index: int in left.get_bind_count():
		if left.get_bind_name(bind_index) != right.get_bind_name(bind_index):
			return (
				"Skin bind name mismatch at %d: compatible=%s BOT=%s."
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


func _fail(message: String, report_output: String) -> int:
	_report.append("ERROR: %s" % message)
	_report.append("EXTRACTION_STATUS=FAIL")
	push_error(message)
	_write_report(report_output)
	return 1


func _write_report(report_output: String) -> void:
	DirAccess.make_dir_recursive_absolute(
		ProjectSettings.globalize_path(report_output.get_base_dir())
	)
	var file := FileAccess.open(report_output, FileAccess.WRITE)
	if file != null:
		file.store_string("\n".join(_report) + "\n")
