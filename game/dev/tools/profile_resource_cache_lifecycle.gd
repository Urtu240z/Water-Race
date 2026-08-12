extends SceneTree

const PARADISE_PATH := "res://levels/paradise_island/paradise_island.tscn"
const GOLD_PATH := "res://levels/gold_city/gold_city.tscn"
const CANDIDATES := [
	"res://gameplay/vehicles/jet_ski_01/jet_ski_with_rider.tscn",
	"res://gameplay/vehicles/jet_ski_01/jet_ski_01.tscn",
	"res://gameplay/vehicles/jet_ski_01/materials/jet_ski_01_hull.tres",
	"res://gameplay/riders/common/rider_rig.tscn",
	"res://gameplay/riders/common/fallen_rider_reduced_seed.tscn",
	"res://world/water/ocean/ocean_3d.tscn",
	"res://systems/camera/chase_camera.tscn",
	"res://systems/camera/underwater/shaders/underwater_split_view_post_process.gdshader",
	"res://ui/pause_menu/pause_menu.tscn",
	"res://levels/paradise_island/wildlife/ambient_wildlife.tscn",
	"res://world/props/boats/boat_02.glb",
	"res://audio/ambience/ocean/Ocean_Waves.ogg",
	"res://audio/ambience/ocean/Ocean_Wind.ogg",
	"res://world/vegetation/palms/textures/palm_billboard_albedo.png",
]


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_audit("BOOTSTRAP_ONLY")
	await _change_scene(PARADISE_PATH)
	_audit("PARADISE_ENTERED")
	await _change_scene(GOLD_PATH)
	_audit("GOLD_ENTERED_AFTER_PARADISE")
	await _change_scene(PARADISE_PATH)
	_audit("PARADISE_REENTERED_AFTER_GOLD")
	quit()


func _change_scene(scene_path: String) -> void:
	var packed_scene := ResourceLoader.load(scene_path, "PackedScene") as PackedScene
	if packed_scene == null:
		printerr("CACHE_AUDIT_LOAD_FAILED=", scene_path)
		quit(2)
		return
	var error := change_scene_to_packed(packed_scene)
	packed_scene = null
	if error != OK:
		printerr("CACHE_AUDIT_CHANGE_FAILED=", scene_path, ":", error_string(error))
		quit(3)
		return
	await process_frame
	await process_frame


func _audit(stage: String) -> void:
	var states := {}
	for resource_path in CANDIDATES:
		states[resource_path] = ResourceLoader.has_cached(resource_path)
	print("CACHE_AUDIT_JSON=", JSON.stringify({"stage": stage, "cached": states}))
