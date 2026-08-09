extends SceneTree

const RIDER_RIG_SCENE := "res://gameplay/riders/common/rider_rig.tscn"
const MESH_PATH := "res://gameplay/riders/rider_04/runtime/rider_04_body_mesh.res"
const SKIN_PATH := "res://gameplay/riders/rider_04/runtime/rider_04_skin.res"
const GROUP := &"rider_skin_rider_04"
const SKIN_VALUE := 1
const REPORT_PATH := "user://rider_04_integration_report.txt"

var _failures: PackedStringArray = []
var _report: PackedStringArray = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_report.append("=== RIDER_04 INTEGRATION VALIDATION ===")
	_validate_resources()
	await _validate_rig()
	_report.append("INTEGRATION_STATUS=%s" % ("PASS" if _failures.is_empty() else "FAIL"))
	var file := FileAccess.open(REPORT_PATH, FileAccess.WRITE)
	if file != null:
		file.store_string("\n".join(_report) + "\n")
	print("\n".join(_report))
	quit(0 if _failures.is_empty() else 1)


func _validate_resources() -> void:
	var mesh := load(MESH_PATH) as ArrayMesh
	var skin := load(SKIN_PATH) as Skin
	_expect(mesh != null, "rider_04 persistent ArrayMesh loads.")
	_expect(skin != null, "rider_04 persistent Skin loads.")
	if mesh != null:
		_expect(mesh.get_surface_count() == 1, "rider_04 keeps one mesh surface.")
		_expect(_vertex_count(mesh) == 27488, "rider_04 keeps 27,488 vertices.")
	if skin != null:
		_expect(skin.get_bind_count() == 52, "rider_04 keeps 52 skin binds.")
	for path: String in [MESH_PATH, SKIN_PATH]:
		for dependency: String in ResourceLoader.get_dependencies(path):
			_expect(
				not dependency.contains("res://.godot/imported"),
				"%s has no imported-cache dependency." % path
			)


func _validate_rig() -> void:
	var packed := load(RIDER_RIG_SCENE) as PackedScene
	_expect(packed != null, "RiderRig scene loads.")
	if packed == null:
		return
	var rig := packed.instantiate()
	root.add_child(rig)
	await process_frame
	var skeletons := _collect_type(rig, &"Skeleton3D")
	var rider_meshes := _group_meshes(rig, GROUP)
	_expect(skeletons.size() == 1, "RiderRig has one canonical Skeleton3D.")
	_expect(rider_meshes.size() == 1, "RiderRig has one rider_04 body mesh.")
	if skeletons.size() == 1 and rider_meshes.size() == 1:
		var skeleton := skeletons[0] as Skeleton3D
		var mesh := rider_meshes[0] as MeshInstance3D
		_expect(skeleton.get_bone_count() == 52, "Canonical skeleton keeps 52 bones.")
		_expect(mesh.skin != null and mesh.skin.get_bind_count() == 52, "rider_04 resolves 52 binds.")
		_expect(mesh.get_node_or_null(mesh.skeleton) == skeleton, "rider_04 targets the canonical skeleton.")
	rig.call("set_rider_skin", SKIN_VALUE)
	await process_frame
	_expect(_visible_count(rider_meshes) == 1, "Serialized value 1 selects physical rider_04.")
	rig.call("set_rider_skin", 0)
	await process_frame
	_expect(_visible_count(rider_meshes) == 0, "rider_bot selection hides rider_04.")
	rig.queue_free()
	await process_frame


func _vertex_count(mesh: ArrayMesh) -> int:
	var total := 0
	for surface_index: int in mesh.get_surface_count():
		var arrays := mesh.surface_get_arrays(surface_index)
		total += (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
	return total


func _collect_type(node: Node, type_name: StringName) -> Array[Node]:
	var result: Array[Node] = []
	if node.is_class(type_name):
		result.append(node)
	for child: Node in node.get_children():
		result.append_array(_collect_type(child, type_name))
	return result


func _group_meshes(node: Node, group: StringName) -> Array[Node]:
	var result: Array[Node] = []
	for candidate: Node in _collect_type(node, &"MeshInstance3D"):
		if candidate.is_in_group(group):
			result.append(candidate)
	return result


func _visible_count(nodes: Array[Node]) -> int:
	var count := 0
	for node: Node in nodes:
		if (node as MeshInstance3D).visible:
			count += 1
	return count


func _expect(condition: bool, message: String) -> void:
	_report.append("%s: %s" % ["PASS" if condition else "FAIL", message])
	if not condition:
		_failures.append(message)

