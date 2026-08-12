extends SceneTree


func _initialize() -> void:
	var arguments := OS.get_cmdline_user_args()
	if arguments.is_empty():
		printerr("Usage: -- <res://resource_path>")
		quit(2)
		return
	var resource_path := arguments[0]
	var prewarmed_resources: Array[Resource] = []
	var prewarm_usec := -1
	if arguments.size() > 1 and arguments[1] == "prewarm_direct":
		var prewarm_started_usec := Time.get_ticks_usec()
		for raw_dependency in ResourceLoader.get_dependencies(resource_path):
			var dependency_path := _dependency_path(raw_dependency)
			var dependency := ResourceLoader.load(dependency_path)
			if dependency != null:
				prewarmed_resources.append(dependency)
		prewarm_usec = Time.get_ticks_usec() - prewarm_started_usec
	var load_started_usec := Time.get_ticks_usec()
	var resource := ResourceLoader.load(
		resource_path,
		"",
		ResourceLoader.CACHE_MODE_REUSE
	)
	var load_finished_usec := Time.get_ticks_usec()
	if resource == null:
		printerr("Could not load %s" % resource_path)
		quit(3)
		return

	var cached_started_usec := Time.get_ticks_usec()
	var cached_resource := ResourceLoader.load(
		resource_path,
		"",
		ResourceLoader.CACHE_MODE_REUSE
	)
	var cached_finished_usec := Time.get_ticks_usec()

	var instantiate_usec := -1
	var instantiated_node: Node
	if resource is PackedScene:
		var instantiate_started_usec := Time.get_ticks_usec()
		instantiated_node = resource.instantiate()
		instantiate_usec = Time.get_ticks_usec() - instantiate_started_usec

	print(
		"RESOURCE_PROFILE_JSON=",
		JSON.stringify(
			{
				"path": resource_path,
				"type": resource.get_class(),
				"direct_dependency_count": prewarmed_resources.size(),
				"prewarm_direct_dependencies_usec": prewarm_usec,
				"process_cold_load_usec": load_finished_usec - load_started_usec,
				"resource_cache_load_usec": cached_finished_usec - cached_started_usec,
				"cache_same_reference": cached_resource == resource,
				"instantiate_usec": instantiate_usec,
			}
		)
	)
	if instantiated_node != null:
		instantiated_node.free()
	quit()


func _dependency_path(raw_dependency: String) -> String:
	var parts := raw_dependency.split("::")
	for index in range(parts.size() - 1, -1, -1):
		if parts[index].begins_with("res://"):
			return parts[index]
	return raw_dependency if raw_dependency.begins_with("res://") else ""
