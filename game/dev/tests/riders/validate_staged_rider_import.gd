extends SceneTree

const EXPECTED := {
	"rider_01": {"lods": 14, "vertices": 27992, "indices": 146151},
	"rider_02": {"lods": 14, "vertices": 38660, "indices": 208179},
	"rider_03": {"lods": 16, "vertices": 36689, "indices": 200628},
	"rider_04": {"lods": 16, "vertices": 27488, "indices": 149601},
}


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var rider := _argument("--rider")
	if not EXPECTED.has(rider):
		push_error("Expected --rider rider_0x.")
		quit(2)
		return
	var scene_path := "res://gameplay/riders/%s/%s_compatible.glb" % [rider, rider]
	var packed := load(scene_path) as PackedScene
	if packed == null:
		_fail("Could not load staged import %s." % scene_path)
		return
	var root_node := packed.instantiate()
	var vertices := 0
	var indices := 0
	var lods := 0
	for node: Node in _nodes_of_type(root_node, &"MeshInstance3D"):
		var mesh := (node as MeshInstance3D).mesh
		if mesh == null:
			continue
		for surface_index: int in mesh.get_surface_count():
			var arrays := mesh.surface_get_arrays(surface_index)
			vertices += (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
			indices += (arrays[Mesh.ARRAY_INDEX] as PackedInt32Array).size()
		var surfaces: Variant = mesh.get("_surfaces")
		if surfaces is Array:
			for surface in surfaces:
				if surface is Dictionary:
					lods += ((surface as Dictionary).get("lods", []) as Array).size()
	root_node.free()
	var expected: Dictionary = EXPECTED[rider]
	if vertices != int(expected.vertices) or indices != int(expected.indices) or lods != int(expected.lods):
		_fail("Unexpected staged geometry: vertices=%d indices=%d lods=%d." % [vertices, indices, lods])
		return
	print("STAGED_IMPORT_STATUS=PASS rider=%s vertices=%d indices=%d lods=%d" % [rider, vertices, indices, lods])
	quit(0)


func _argument(name: String) -> String:
	var args := OS.get_cmdline_user_args()
	for index: int in args.size():
		if args[index].begins_with(name + "="):
			return args[index].trim_prefix(name + "=")
		if args[index] == name and index + 1 < args.size():
			return args[index + 1]
	return ""


func _nodes_of_type(node: Node, type_name: StringName) -> Array[Node]:
	var result: Array[Node] = []
	if node.is_class(type_name):
		result.append(node)
	for child: Node in node.get_children():
		result.append_array(_nodes_of_type(child, type_name))
	return result


func _fail(message: String) -> void:
	push_error(message)
	print("STAGED_IMPORT_STATUS=FAIL %s" % message)
	quit(1)
