extends SceneTree


func _initialize() -> void:
	var arguments := OS.get_cmdline_user_args()
	if arguments.size() < 3:
		printerr("Usage: -- <scene_a> <scene_b> <target_scene>")
		quit(2)
		return
	var scene_a := arguments[0]
	var scene_b := arguments[1]
	var target_scene := arguments[2]
	var dependencies_a := _transitive_dependencies(scene_a)
	var dependencies_b := _transitive_dependencies(scene_b)
	var shared := PackedStringArray()
	for resource_path in dependencies_a:
		if dependencies_b.has(resource_path):
			shared.append(resource_path)
	shared.sort()

	var retained: Array[Resource] = []
	var shared_started_usec := Time.get_ticks_usec()
	for resource_path in shared:
		var resource := ResourceLoader.load(resource_path)
		if resource != null:
			retained.append(resource)
	var shared_usec := Time.get_ticks_usec() - shared_started_usec

	var target_started_usec := Time.get_ticks_usec()
	var target := ResourceLoader.load(target_scene, "PackedScene") as PackedScene
	var target_remainder_usec := Time.get_ticks_usec() - target_started_usec
	if target == null:
		printerr("Could not load target scene %s" % target_scene)
		quit(3)
		return
	print(
		"SHARED_UNION_PROFILE_JSON=",
		JSON.stringify(
			{
				"shared_resource_count": shared.size(),
				"shared_loaded_count": retained.size(),
				"shared_union_cold_usec": shared_usec,
				"target": target_scene,
				"target_remainder_after_shared_usec": target_remainder_usec,
			}
		)
	)
	quit()


func _transitive_dependencies(root_path: String) -> Dictionary:
	var pending: Array[String] = [root_path]
	var visited := {}
	while not pending.is_empty():
		var resource_path: String = pending.pop_back()
		if visited.has(resource_path):
			continue
		visited[resource_path] = true
		for raw_dependency in ResourceLoader.get_dependencies(resource_path):
			var dependency_path := _dependency_path(raw_dependency)
			if not dependency_path.is_empty() and not visited.has(dependency_path):
				pending.append(dependency_path)
	visited.erase(root_path)
	return visited


func _dependency_path(raw_dependency: String) -> String:
	var parts := raw_dependency.split("::")
	for index in range(parts.size() - 1, -1, -1):
		if parts[index].begins_with("res://"):
			return parts[index]
	return raw_dependency if raw_dependency.begins_with("res://") else ""
