@tool
extends RefCounted

## Keeps editor-only API identifiers out of scripts that are loaded by
## exported builds. Runtime scripts must load this bridge dynamically and only
## while Engine.is_editor_hint() is true.


func get_editor_viewport_camera() -> Camera3D:
	var editor_viewport := EditorInterface.get_editor_viewport_3d(0)
	if editor_viewport == null:
		return null
	return editor_viewport.get_camera_3d()


func get_edited_scene_root() -> Node:
	return EditorInterface.get_edited_scene_root()


func mark_scene_as_unsaved() -> void:
	EditorInterface.mark_scene_as_unsaved()


func get_resource_filesystem() -> EditorFileSystem:
	return EditorInterface.get_resource_filesystem()
