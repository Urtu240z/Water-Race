extends SceneTree

const TERRAIN_GLB := "res://levels/paradise_island/terrain/paradise_island.glb"

var PLACEMENT := Transform3D(
	Basis.IDENTITY.scaled(Vector3(0.86, 0.86, 0.86)),
	Vector3(149.0, 1.8, 120.1001)
)

const GAMEPLAY_POINTS := {
	"buoy_1": Vector2(598.2306, 309.39752),
	"buoy_2": Vector2(707.1697, 119.86493),
	"buoy_3": Vector2(595.2577, -44.89177),
	"buoy_4": Vector2(455.20135, -334.34525),
	"buoy_5": Vector2(149.255, -334.34525),
	"buoy_6": Vector2(262.90787, 3.9871635),
	"buoy_7": Vector2(183.40842, 208.09734),
	"buoy_8": Vector2(-2.5322533, 541.0113),
	"buoy_9": Vector2(-319.31842, 127.12428),
	"buoy_10": Vector2(-286.12158, -272.01477),
	"buoy_11": Vector2(-176.74887, -411.07477),
	"ramp_1": Vector2(-319.45636, 63.17799),
	"ramp_2": Vector2(-154.48683, -420.8884),
	"ramp_3": Vector2(0.8299866, 541.0693),
	"ramp_4": Vector2(668.0774, 192.87813),
	"ramp_5": Vector2(603.64154, -416.57425),
	"jump_1": Vector2(189.9109, 2.8569958),
	"jump_2": Vector2(214.77977, 101.30986),
	"jump_3": Vector2(177.71559, 266.83514),
	"jump_4": Vector2(223.61113, -94.87814),
	"jump_5": Vector2(184.03395, -209.91396),
	"player_spawn": Vector2(596.97815, 464.24957),
	"beach_hotel": Vector2(-123.22586, -150.12727),
}


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var packed := load(TERRAIN_GLB) as PackedScene
	if packed == null:
		print("TERRAIN_LOAD=FAIL")
		quit(1)
		return
	var terrain := packed.instantiate() as Node3D
	root.add_child(terrain)
	await process_frame
	var local_aabb := AABB()
	var first := true
	for child in _collect_meshes(terrain):
		var mesh_aabb: AABB = child.get_aabb()
		if mesh_aabb.size == Vector3.ZERO:
			continue
		var world_aabb := child.transform * mesh_aabb
		if first:
			local_aabb = world_aabb
			first = false
		else:
			local_aabb = local_aabb.merge(world_aabb)
	var world_aabb := PLACEMENT * local_aabb
	print("TERRAIN_WORLD_AABB_POS=%s" % str(world_aabb.position))
	print("TERRAIN_WORLD_AABB_SIZE=%s" % str(world_aabb.size))
	print(
		"TERRAIN_XZ=(%.1f..%.1f, %.1f..%.1f)" % [
			world_aabb.position.x,
			world_aabb.position.x + world_aabb.size.x,
			world_aabb.position.z,
			world_aabb.position.z + world_aabb.size.z,
		]
	)
	var candidates := [Vector2(200.0, 0.0), Vector2(194.0, 65.0)]
	for candidate in candidates:
		var farthest_name := ""
		var farthest := 0.0
		for point_name in GAMEPLAY_POINTS:
			var distance: float = candidate.distance_to(GAMEPLAY_POINTS[point_name])
			if distance > farthest:
				farthest = distance
				farthest_name = String(point_name)
		var spawn_distance: float = candidate.distance_to(GAMEPLAY_POINTS["player_spawn"])
		print(
			"CENTER(%s): farthest=%s at %.1f m | spawn at %.1f m | worst_case_from_spawn=%.1f m" % [
				str(candidate), farthest_name, farthest, spawn_distance,
				farthest + spawn_distance,
			]
		)
	terrain.queue_free()
	quit(0)


func _collect_meshes(node: Node) -> Array[MeshInstance3D]:
	var result: Array[MeshInstance3D] = []
	if node is MeshInstance3D:
		result.append(node)
	for child in node.get_children():
		result.append_array(_collect_meshes(child))
	return result
