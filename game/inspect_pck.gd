extends SceneTree


const PACK_PATH: String = "C:/Users/ehort/Documents/GODOT PROJECTS/Water Race/prueba.pck"

const TREE_BAKE_DIRECTORY: String = (
	"res://world/vegetation/trees/baked"
)


func _initialize() -> void:
	var loaded: bool = ProjectSettings.load_resource_pack(
		PACK_PATH,
		true
	)

	print("PCK loaded: ", loaded)

	if not loaded:
		quit(1)
		return

	print("")
	print("TREE BAKES:")
	print("-----------")

	var files: PackedStringArray = ResourceLoader.list_directory(
		TREE_BAKE_DIRECTORY
	)

	for file_name: String in files:
		print(file_name)

	print("")
	print("Total: ", files.size())

	quit()
