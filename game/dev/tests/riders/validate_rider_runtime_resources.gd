extends SceneTree

const RIDERS := [&"rider_01", &"rider_02", &"rider_03", &"rider_04"]
var _failures: PackedStringArray = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	for rider: StringName in RIDERS:
		_validate_rider(rider)
	print("RIDER_RUNTIME_RESOURCE_STATUS=%s" % ("PASS" if _failures.is_empty() else "FAIL"))
	quit(0 if _failures.is_empty() else 1)


func _validate_rider(rider: StringName) -> void:
	var runtime_root := "res://gameplay/riders/%s/runtime" % rider
	var texture_root := runtime_root + "/textures"
	var mesh_path := "%s/%s_body_mesh.res" % [runtime_root, rider]
	var dependencies := ResourceLoader.get_dependencies(mesh_path)
	for dependency: String in dependencies:
		_expect(
			not dependency.contains(".godot/imported") and not dependency.contains("source/riders") and not dependency.contains("_compatible.glb"),
			"%s mesh has no import-cache, source, or staged-GLB dependency." % rider,
		)
	var mesh := load(mesh_path) as ArrayMesh
	_expect(mesh != null, "%s runtime mesh loads for dependency audit." % rider)
	if mesh == null:
		return
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
