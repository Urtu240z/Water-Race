extends SceneTree


func _initialize() -> void:
	var arguments := OS.get_cmdline_user_args()
	if arguments.is_empty():
		printerr("Usage: -- <res://scene_path> [output_json_path]")
		quit(2)
		return
	var root_path := arguments[0]
	var pending: Array[String] = [root_path]
	var visited: Dictionary = {}
	var resource_types: Dictionary = {root_path: "PackedScene"}
	var entries: Array[Dictionary] = []
	while not pending.is_empty():
		var resource_path: String = pending.pop_back()
		if visited.has(resource_path):
			continue
		visited[resource_path] = true
		var direct_dependencies := PackedStringArray()
		for raw_dependency in ResourceLoader.get_dependencies(resource_path):
			var dependency_path := _dependency_path(raw_dependency)
			if dependency_path.is_empty():
				continue
			direct_dependencies.append(dependency_path)
			resource_types[dependency_path] = _dependency_type(raw_dependency)
			if not visited.has(dependency_path):
				pending.append(dependency_path)
		entries.append(
			{
				"path": resource_path,
				"type": String(resource_types.get(resource_path, "")),
				"dependencies": Array(direct_dependencies),
			}
		)
	var serialized := JSON.stringify(entries, "\t")
	if arguments.size() > 1:
		var output := FileAccess.open(arguments[1], FileAccess.WRITE)
		if output == null:
			printerr("Could not write %s" % arguments[1])
			quit(3)
			return
		output.store_string(serialized)
		print("DEPENDENCY_INVENTORY_WRITTEN=", arguments[1])
	else:
		print("DEPENDENCY_INVENTORY_JSON=", serialized)
	print("DEPENDENCY_COUNT=", entries.size())
	quit()


func _dependency_path(raw_dependency: String) -> String:
	var parts := raw_dependency.split("::")
	for index in range(parts.size() - 1, -1, -1):
		if parts[index].begins_with("res://"):
			return parts[index]
	return raw_dependency if raw_dependency.begins_with("res://") else ""


func _dependency_type(raw_dependency: String) -> String:
	var parts := raw_dependency.split("::")
	for part in parts:
		if not part.is_empty() and not part.begins_with("uid://") and not part.begins_with("res://"):
			return part
	return ""
