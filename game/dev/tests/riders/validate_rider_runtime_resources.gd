extends SceneTree

const EXPECTED := {
	&"rider_01": {"vertices": 27992, "indices": 146151, "lods": 14},
	&"rider_02": {"vertices": 38660, "indices": 208179, "lods": 14},
	&"rider_03": {"vertices": 36689, "indices": 200628, "lods": 16},
	&"rider_04": {"vertices": 27488, "indices": 149601, "lods": 16},
}
var _failures: PackedStringArray = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	for rider: StringName in EXPECTED:
		_validate_rider(rider)
	print("RIDER_RUNTIME_RESOURCE_STATUS=%s" % ("PASS" if _failures.is_empty() else "FAIL"))
	quit(0 if _failures.is_empty() else 1)


func _validate_rider(rider: StringName) -> void:
	var runtime_root := "res://gameplay/riders/%s/runtime" % rider
	var texture_root := runtime_root + "/textures"
	var mesh_path := "%s/%s_body_mesh.res" % [runtime_root, rider]
	var skin_path := "%s/%s_skin.res" % [runtime_root, rider]
	var dependencies := ResourceLoader.get_dependencies(mesh_path)
	for dependency: String in dependencies:
		_expect(
			not dependency.contains(".godot/imported") and not dependency.contains("source/riders") and not dependency.contains("_compatible.glb"),
			"%s mesh has no import-cache, source, or staged-GLB dependency." % rider,
		)
	var mesh := load(mesh_path) as ArrayMesh
	var skin := load(skin_path) as Skin
	_expect(mesh != null, "%s runtime mesh loads for dependency audit." % rider)
	_expect(skin != null and skin.get_bind_count() == 52, "%s runtime skin has exactly 52 binds." % rider)
	if mesh == null or skin == null:
		return
	_expect(mesh.get_surface_count() == 1, "%s runtime mesh has exactly one surface." % rider)
	var vertices := 0
	var indices := 0
	for surface_index: int in mesh.get_surface_count():
		var arrays := mesh.surface_get_arrays(surface_index)
		vertices += (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
		indices += (arrays[Mesh.ARRAY_INDEX] as PackedInt32Array).size()
	var lods := 0
	var surfaces: Variant = mesh.get("_surfaces")
	if surfaces is Array:
		for surface: Variant in surfaces:
			if surface is Dictionary:
				var surface_lods: Variant = (surface as Dictionary).get("lods", [])
				if surface_lods is Array:
					lods += (surface_lods as Array).size()
	var expected: Dictionary = EXPECTED[rider]
	_expect(vertices == int(expected.vertices), "%s runtime vertex count matches baseline." % rider)
	_expect(indices == int(expected.indices), "%s runtime index count matches baseline." % rider)
	_expect(lods == int(expected.lods), "%s runtime LOD count matches baseline." % rider)
	for surface_index: int in mesh.get_surface_count():
		var material := mesh.surface_get_material(surface_index)
		_expect(material != null, "%s surface %d has a material." % [rider, surface_index])
		if material == null:
			continue
		for property: Dictionary in material.get_property_list():
			var name := String(property.name)
			if not name.ends_with("_texture"):
				continue
			var value: Variant = material.get(property.name)
			if value is Texture2D:
				var texture := value as Texture2D
				_expect(texture.resource_path.begins_with(texture_root + "/"), "%s %s points to runtime/textures." % [rider, name])


func _expect(condition: bool, message: String) -> void:
	print("%s: %s" % ["PASS" if condition else "FAIL", message])
	if not condition:
		_failures.append(message)
