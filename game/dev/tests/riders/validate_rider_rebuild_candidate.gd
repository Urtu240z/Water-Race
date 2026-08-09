extends SceneTree

const EXPECTED := {
	"rider_01": {"vertices": 27992, "indices": 146151, "lods": 14},
	"rider_02": {"vertices": 38660, "indices": 208179, "lods": 14},
	"rider_03": {"vertices": 36689, "indices": 200628, "lods": 16},
	"rider_04": {"vertices": 27488, "indices": 149601, "lods": 16},
}

var _failures: PackedStringArray = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var rider := _argument("--rider")
	var runtime_root := _argument("--runtime-root")
	var texture_root := _argument("--texture-root")
	if not EXPECTED.has(rider) or runtime_root.is_empty() or texture_root.is_empty():
		push_error("Expected --rider rider_0x --runtime-root res://... --texture-root res://...")
		quit(2)
		return
	_validate(rider, runtime_root, texture_root)
	print("RIDER_REBUILD_CANDIDATE_STATUS=%s rider=%s" % ["PASS" if _failures.is_empty() else "FAIL", rider])
	quit(0 if _failures.is_empty() else 1)


func _validate(rider: String, runtime_root: String, texture_root: String) -> void:
	var expected: Dictionary = EXPECTED[rider]
	var mesh_path := "%s/%s_body_mesh.res" % [runtime_root, rider]
	var skin_path := "%s/%s_skin.res" % [runtime_root, rider]
	texture_root += "/"
	_expect(FileAccess.file_exists(mesh_path), "Candidate mesh file exists.")
	_expect(FileAccess.file_exists(skin_path), "Candidate skin file exists.")
	var mesh := load(mesh_path) as ArrayMesh
	var skin := load(skin_path) as Skin
	_expect(mesh != null, "Candidate mesh loads as ArrayMesh.")
	_expect(skin != null, "Candidate skin loads as Skin.")
	if mesh == null or skin == null:
		return
	_expect(mesh.get_surface_count() == 1, "Candidate has exactly one surface.")
	_expect(skin.get_bind_count() == 52, "Candidate skin has exactly 52 binds.")
	var vertices := 0
	var indices := 0
	var lods := 0
	for surface_index: int in mesh.get_surface_count():
		var arrays := mesh.surface_get_arrays(surface_index)
		vertices += (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
		indices += (arrays[Mesh.ARRAY_INDEX] as PackedInt32Array).size()
	var surfaces: Variant = mesh.get("_surfaces")
	if surfaces is Array:
		for surface: Variant in surfaces:
			if surface is Dictionary:
				var surface_data := surface as Dictionary
				var surface_lods: Variant = surface_data.get("lods", [])
				if surface_lods is Array:
					lods += (surface_lods as Array).size()
	_expect(vertices == int(expected.vertices), "Candidate vertex count matches baseline.")
	_expect(indices == int(expected.indices), "Candidate index count matches baseline.")
	_expect(lods == int(expected.lods), "Candidate LOD count matches baseline.")
	for dependency: String in ResourceLoader.get_dependencies(mesh_path):
		_expect(
			not dependency.contains(".godot/imported") and not dependency.contains("source/") and not dependency.contains("compatible.glb") and not dependency.contains("/staging/"),
			"Candidate has no importer, source, compatible-GLB, or staging dependency.",
		)
	for surface_index: int in mesh.get_surface_count():
		var material := mesh.surface_get_material(surface_index)
		_expect(material != null, "Candidate surface has a material.")
		if material == null:
			continue
		for property: Dictionary in material.get_property_list():
			var property_name := String(property.name)
			if not property_name.ends_with("_texture"):
				continue
			var texture_value: Variant = material.get(property.name)
			if texture_value is Texture2D:
				var texture := texture_value as Texture2D
				_expect(texture.resource_path.begins_with(texture_root), "%s points to candidate runtime/textures." % property_name)


func _argument(name: String) -> String:
	var arguments := OS.get_cmdline_user_args()
	for index: int in arguments.size():
		if arguments[index].begins_with(name + "="):
			return arguments[index].trim_prefix(name + "=")
		if arguments[index] == name and index + 1 < arguments.size():
			return arguments[index + 1]
	return ""


func _expect(condition: bool, message: String) -> void:
	print("%s: %s" % ["PASS" if condition else "FAIL", message])
	if not condition:
		_failures.append(message)
