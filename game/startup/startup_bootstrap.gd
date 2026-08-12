extends Node

const INITIAL_LEVEL_PATH := "res://levels/paradise_island/paradise_island.tscn"


func _enter_tree() -> void:
	LoadTrace.mark("BOOTSTRAP_ENTER_TREE")


func _ready() -> void:
	var initial_level_path := _requested_initial_level_path()
	LoadTrace.mark("BOOTSTRAP_READY")
	LoadTrace.section(
		"INITIAL PARADISE LOAD"
		if initial_level_path == INITIAL_LEVEL_PATH
		else "INITIAL LEVEL LOAD: %s" % initial_level_path
	)
	LoadTrace.mark("INITIAL_LEVEL_RESOURCE_LOAD_BEGIN")
	var initial_level := ResourceLoader.load(
		initial_level_path,
		"PackedScene"
	) as PackedScene
	LoadTrace.mark("INITIAL_LEVEL_RESOURCE_LOADED")
	if initial_level == null:
		printerr("StartupBootstrap could not load %s" % initial_level_path)
		LoadTrace.mark("INITIAL_LEVEL_RESOURCE_LOAD_FAILED")
		LoadTrace.flush()
		return
	LoadTrace.mark("INITIAL_CHANGE_SCENE_BEGIN")
	get_tree().change_scene_to_packed.call_deferred(initial_level)
	LoadTrace.mark("INITIAL_CHANGE_SCENE_QUEUED")


func _requested_initial_level_path() -> String:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("initial_level="):
			return argument.trim_prefix("initial_level=")
	return INITIAL_LEVEL_PATH
