extends SceneTree


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var rider := _argument("--rider")
	var runtime_root := _argument("--runtime-root")
	var texture_root := _argument("--texture-root")
	if rider.is_empty() or runtime_root.is_empty() or texture_root.is_empty():
		push_error("Expected --rider rider_0x --runtime-root res://... --texture-root res://...")
		quit(2)
		return
	var mesh_path := "%s/%s_body_mesh.res" % [runtime_root, rider]
	var mesh := load(mesh_path) as ArrayMesh
	if mesh == null:
		_fail("Could not load candidate mesh.")
		return
	for surface_index: int in mesh.get_surface_count():
		var material := mesh.surface_get_material(surface_index)
		if material == null:
			_fail("Candidate surface has no material.")
			return
		for property: Dictionary in material.get_property_list():
			var property_name := String(property.name)
			if not property_name.ends_with("_texture"):
				continue
			var texture_value: Variant = material.get(property.name)
			if not texture_value is Texture2D:
				continue
			var texture := texture_value as Texture2D
			var final_texture := load("%s/%s" % [texture_root, texture.resource_path.get_file()]) as Texture2D
			if final_texture == null:
				_fail("Could not load final runtime texture for %s." % property_name)
				return
			material.set(property.name, final_texture)
	if ResourceSaver.save(mesh, mesh_path) != OK:
		_fail("Could not save retargeted candidate mesh.")
		return
	print("CANDIDATE_RETARGET_STATUS=PASS rider=%s" % rider)
	quit(0)


func _argument(name: String) -> String:
	var arguments := OS.get_cmdline_user_args()
	for index: int in arguments.size():
		if arguments[index].begins_with(name + "="):
			return arguments[index].trim_prefix(name + "=")
		if arguments[index] == name and index + 1 < arguments.size():
			return arguments[index + 1]
	return ""


func _fail(message: String) -> void:
	push_error(message)
	print("CANDIDATE_RETARGET_STATUS=FAIL %s" % message)
	quit(1)
