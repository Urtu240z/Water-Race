extends SceneTree


func _initialize() -> void:
	var arguments := OS.get_cmdline_user_args()
	if arguments.size() < 2:
		printerr("Usage: -- <source_scene> <target_scene>")
		quit(2)
		return
	var source_path := arguments[0]
	var target_path := arguments[1]
	var source := ResourceLoader.load(source_path, "PackedScene") as PackedScene
	if source == null:
		printerr("Could not load source scene %s" % source_path)
		quit(3)
		return
	var target_started_usec := Time.get_ticks_usec()
	var target := ResourceLoader.load(target_path, "PackedScene") as PackedScene
	var target_usec := Time.get_ticks_usec() - target_started_usec
	if target == null:
		printerr("Could not load target scene %s" % target_path)
		quit(4)
		return
	print(
		"TRANSITION_PROFILE_JSON=",
		JSON.stringify(
			{
				"source": source_path,
				"target": target_path,
				"target_load_usec": target_usec,
			}
		)
	)
	quit()
