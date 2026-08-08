extends SceneTree

const SCENE_PATH := "res://gameplay/vehicles/jet_ski_01/jet_ski_with_rider.tscn"
const RIDER_PATH := "VisualRoot/RiderMount/RiderAssetRoot/RiderRig"
const SKELETON_PATH := (
	"RiderModelRoot/Rider_Bot/SKEL_Rider/Skeleton3D"
)


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var packed := load(SCENE_PATH) as PackedScene
	if packed == null:
		push_error("Could not load %s." % SCENE_PATH)
		quit(1)
		return
	var scene := packed.instantiate()
	root.add_child(scene)
	await process_frame
	var rig := scene.get_node_or_null(RIDER_PATH)
	if rig == null:
		push_error("RiderRig is missing.")
		quit(1)
		return
	var skeleton := rig.get_node_or_null(SKELETON_PATH) as Skeleton3D
	if skeleton == null or skeleton.get_bone_count() != 52:
		push_error("Expected a 52-bone shared skeleton.")
		quit(1)
		return
	var rider01_meshes: Array[MeshInstance3D] = []
	var bot_visible := 0
	var racer_visible := 0
	var pending: Array[Node] = [rig]
	while not pending.is_empty():
		var current := pending.pop_back() as Node
		if current is MeshInstance3D:
			var mesh := current as MeshInstance3D
			if mesh.is_in_group(&"rider_skin_rider01"):
				rider01_meshes.append(mesh)
			elif mesh.is_in_group(&"rider_skin_racer") and mesh.visible:
				racer_visible += 1
			elif mesh.mesh != null and mesh.visible:
				bot_visible += 1
		for child: Node in current.get_children():
			pending.append(child)
	if rider01_meshes.size() != 6:
		push_error(
			"Expected 6 Rider01 meshes, found %d." % rider01_meshes.size()
		)
		quit(1)
		return
	for mesh: MeshInstance3D in rider01_meshes:
		if not mesh.visible or mesh.mesh == null or mesh.skin == null:
			push_error("%s is not a valid visible Rider01 mesh." % mesh.name)
			quit(1)
			return
	if bot_visible != 0 or racer_visible != 0:
		push_error(
			"Other skins remain visible: BOT=%d RACER=%d."
			% [bot_visible, racer_visible]
		)
		quit(1)
		return
	print(
		"CH42_RIDER01_SLOT=PASS meshes=6 bones=52 "
		+ "bot_visible=0 racer_visible=0"
	)
	scene.queue_free()
	quit(0)
