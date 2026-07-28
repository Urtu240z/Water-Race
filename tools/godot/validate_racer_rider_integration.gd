extends SceneTree

const RIDER_RIG_SCENE := "res://scenes/rider/rider_rig.tscn"
const JET_SKI_RIDER_SCENE := \
	"res://scenes/vehicle/jet_ski_with_rider.tscn"
const ISLAND_SCENE := \
	"res://scenes/levels/island_test/island_test_BLENDER.tscn"
const REPORT_PATH := \
	"res://assets/3D/Rider/skins/Racer/runtime/Racer_Integration_Report.txt"
const RACER_GROUP := &"rider_skin_racer"
const EXPECTED_BLEND_NODES: Array[StringName] = [
	&"mounted_base",
	&"mounted_add",
	&"turn_left_delta",
	&"turn_right_delta",
	&"automatic_turn_add",
	&"lean_left_delta",
	&"lean_right_delta",
	&"manual_roll_add",
	&"lean_forward_delta",
	&"lean_back_delta",
	&"manual_pitch_add",
]

var _report: PackedStringArray = []
var _failed := false


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	await _validate()
	_write_report()
	print("\n".join(_report))
	quit(1 if _failed else 0)


func _validate() -> void:
	_report.append("=== RACER RIDER INTEGRATION VALIDATION ===")
	_report.append("Godot: %s" % Engine.get_version_info().string)
	var rig_packed := load(RIDER_RIG_SCENE) as PackedScene
	var jet_packed := load(JET_SKI_RIDER_SCENE) as PackedScene
	if rig_packed == null or jet_packed == null:
		_fail("Could not load RiderRig or JetSkiWithRider.")
		return

	var isolated_rig := rig_packed.instantiate()
	root.add_child(isolated_rig)
	await process_frame
	var isolated_meshes := _collect_type(isolated_rig, &"MeshInstance3D")
	var isolated_bot := _bot_meshes(isolated_meshes)
	var isolated_racer := _racer_meshes(isolated_meshes)
	_expect(isolated_bot.size() == 1, "Isolated RiderRig has one Bot mesh.")
	_expect(isolated_racer.size() == 1, "Isolated RiderRig has one Racer mesh.")
	_expect(
		_visible_count(isolated_bot) == 1
		and _visible_count(isolated_racer) == 0,
		"RiderRig default BOT visibility is exclusive."
	)
	isolated_rig.call("set_rider_skin", 1)
	await process_frame
	_expect(
		_visible_count(isolated_bot) == 0
		and _visible_count(isolated_racer) == 1,
		"RiderRig RACER visibility is exclusive."
	)
	isolated_rig.call("set_rider_skin", 0)
	await process_frame
	_expect(
		_visible_count(isolated_bot) == 1
		and _visible_count(isolated_racer) == 0,
		"RiderRig switches back to BOT immediately."
	)
	isolated_rig.queue_free()
	await process_frame

	var island_packed := load(ISLAND_SCENE) as PackedScene
	_expect(island_packed != null, "island_test_BLENDER loads.")
	if island_packed != null:
		var island := island_packed.instantiate()
		var island_rig := _find_named(island, &"RiderRig")
		_expect(
			island_rig != null and int(island_rig.get("rider_skin")) == 1,
			"island_test_BLENDER inherits the RACER override."
		)
		if island_rig != null:
			_expect(
				_racer_meshes(
					_collect_type(island_rig, &"MeshInstance3D")
				).size() == 1,
				"island_test_BLENDER contains one inherited RacerSkinMesh."
			)
		island.free()

	var jet := jet_packed.instantiate()
	var rider_rig := _find_named(jet, &"RiderRig")
	if rider_rig == null:
		_fail("JetSkiWithRider has no RiderRig instance.")
		jet.free()
		return
	for candidate in _collect_type(jet, &"Node"):
		if (
			candidate != rider_rig
			and not rider_rig.is_ancestor_of(candidate)
			and candidate.get_script() != null
		):
			candidate.set_script(null)
	jet.process_mode = Node.PROCESS_MODE_DISABLED
	root.add_child(jet)
	await process_frame
	var skeletons := _collect_type(rider_rig, &"Skeleton3D")
	var animation_players := _collect_type(rider_rig, &"AnimationPlayer")
	var animation_trees := _collect_type(rider_rig, &"AnimationTree")
	var modifiers := _collect_type(rider_rig, &"SkeletonModifier3D")
	var meshes := _collect_type(rider_rig, &"MeshInstance3D")
	var bot_meshes := _bot_meshes(meshes)
	var racer_meshes := _racer_meshes(meshes)
	_expect(skeletons.size() == 1, "Exactly one Skeleton3D in runtime RiderRig.")
	_expect(
		animation_players.size() == 1,
		"Exactly one AnimationPlayer in runtime RiderRig."
	)
	_expect(
		animation_trees.size() == 1,
		"Exactly one AnimationTree in runtime RiderRig."
	)
	_expect(
		modifiers.size() == 8,
		"Exactly eight IK/modifier nodes remain in runtime RiderRig."
	)
	_expect(bot_meshes.size() == 1, "Detected one original Bot MeshInstance3D.")
	_expect(racer_meshes.size() == 1, "Detected one RacerSkinMesh.")
	_expect(
		int(rider_rig.get("rider_skin")) == 1,
		"JetSkiWithRider override selects RACER."
	)
	_expect(
		_visible_count(bot_meshes) == 0
		and _visible_count(racer_meshes) == 1,
		"JetSkiWithRider shows Racer only."
	)

	var skeleton := skeletons[0] as Skeleton3D
	var animation_player := animation_players[0] as AnimationPlayer
	var animation_tree := animation_trees[0] as AnimationTree
	_expect(skeleton.get_bone_count() == 52, "Runtime skeleton has 52 bones.")
	_expect(animation_tree.active, "AnimationTree is active after RiderRig ready.")
	_expect(
		animation_player.has_animation(&"Mounted_Base"),
		"Mounted_Base remains available."
	)
	var blend_tree := animation_tree.tree_root as AnimationNodeBlendTree
	_expect(blend_tree != null, "AnimationTree still uses a BlendTree.")
	if blend_tree != null:
		var node_names := blend_tree.get_node_list()
		for expected_name in EXPECTED_BLEND_NODES:
			_expect(
				node_names.has(expected_name),
				"BlendTree node %s remains available." % expected_name
			)
		_report.append(
			"BlendTree resource: %s" % blend_tree.resource_path
		)

	var active_modifiers := 0
	var resolved_ik_targets := 0
	for modifier_node in modifiers:
		var modifier := modifier_node as SkeletonModifier3D
		if modifier.active:
			active_modifiers += 1
		if modifier is TwoBoneIK3D:
			var target_path := modifier.get("settings/0/target_node") as NodePath
			var pole_path := modifier.get("settings/0/pole_node") as NodePath
			if (
				not target_path.is_empty()
				and modifier.get_node_or_null(target_path) != null
				and not pole_path.is_empty()
				and modifier.get_node_or_null(pole_path) != null
			):
				resolved_ik_targets += 1
	_expect(active_modifiers == 8, "All eight IK/modifiers are active.")
	_expect(
		resolved_ik_targets == 4,
		"All four TwoBoneIK target/pole pairs resolve."
	)

	rider_rig.call("set_automatic_turn_blend", -0.65)
	rider_rig.call("set_manual_roll_blend", -0.45)
	rider_rig.call("set_manual_pitch_blend", 0.35)
	animation_tree.advance(0.05)
	_expect(
		is_equal_approx(
			float(animation_tree.get(
				"parameters/automatic_turn_add/add_amount"
			)),
			-0.65
		),
		"Turn Left parameter reaches the shared BlendTree."
	)
	_expect(
		is_equal_approx(
			float(animation_tree.get(
				"parameters/manual_roll_add/add_amount"
			)),
			-0.45
		),
		"Lean Left parameter reaches the shared BlendTree."
	)
	_expect(
		is_equal_approx(
			float(animation_tree.get(
				"parameters/manual_pitch_add/add_amount"
			)),
			0.35
		),
		"Forward/back lean parameter reaches the shared BlendTree."
	)
	_expect(_skeleton_finite(skeleton), "Combined skeleton pose is finite.")
	rider_rig.call("reset_mounted_lean_blends")
	animation_tree.advance(0.05)

	var bot_stats := _mesh_stats(bot_meshes[0] as MeshInstance3D)
	var racer_stats := _mesh_stats(racer_meshes[0] as MeshInstance3D)
	_report.append("Bot MeshInstance3D: %s" % _relative_path(
		bot_meshes[0], rider_rig
	))
	_report.append("Racer MeshInstance3D: %s" % _relative_path(
		racer_meshes[0], rider_rig
	))
	_report.append("Bot stats: %s" % bot_stats)
	_report.append("Racer stats: %s" % racer_stats)
	_expect(
		int(racer_stats.origin_vertices) == 0,
		"Racer has zero rest vertices at local origin."
	)
	_expect(
		int(racer_stats.non_finite_vertices) == 0,
		"Racer has zero non-finite vertices."
	)
	_report.append(
		"Racer texture VRAM estimate (RGBA8+mips): %.2f MiB"
		% _racer_texture_vram_mib()
	)
	_report.append(
		"Visible skinned meshes with RACER selected: %d"
		% (_visible_count(bot_meshes) + _visible_count(racer_meshes))
	)
	_report.append(
		"Visual proportion AABB Bot/Racer: %s / %s"
		% [bot_stats.aabb_size, racer_stats.aabb_size]
	)
	jet.queue_free()
	await process_frame
	_report.append(
		"INTEGRATION_STATUS=%s" % ("FAIL" if _failed else "PASS")
	)


func _collect_type(node: Node, type_name: StringName) -> Array[Node]:
	var result: Array[Node] = []
	var pending: Array[Node] = [node]
	while not pending.is_empty():
		var current: Node = pending.pop_back() as Node
		if current.is_class(type_name):
			result.append(current)
		for child: Node in current.get_children():
			pending.append(child)
	return result


func _find_named(node: Node, target_name: StringName) -> Node:
	for candidate in _collect_type(node, &"Node"):
		if candidate.name == target_name:
			return candidate
	return null


func _racer_meshes(meshes: Array[Node]) -> Array[Node]:
	var result: Array[Node] = []
	for node in meshes:
		if node.is_in_group(RACER_GROUP):
			result.append(node)
	return result


func _bot_meshes(meshes: Array[Node]) -> Array[Node]:
	var result: Array[Node] = []
	for node in meshes:
		var mesh_node := node as MeshInstance3D
		if (
			not node.is_in_group(RACER_GROUP)
			and mesh_node.mesh != null
			and mesh_node.skin != null
		):
			result.append(node)
	return result


func _visible_count(meshes: Array[Node]) -> int:
	var count := 0
	for node in meshes:
		if (node as MeshInstance3D).visible:
			count += 1
	return count


func _mesh_stats(mesh_instance: MeshInstance3D) -> Dictionary:
	var surfaces := mesh_instance.mesh.get_surface_count()
	var triangles := 0
	var vertices := 0
	var origin_vertices := 0
	var non_finite_vertices := 0
	var materials := 0
	for surface_index in surfaces:
		var arrays := mesh_instance.mesh.surface_get_arrays(surface_index)
		var positions := arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array
		var indices := arrays[Mesh.ARRAY_INDEX] as PackedInt32Array
		vertices += positions.size()
		triangles += (
			indices.size() / 3
			if not indices.is_empty()
			else positions.size() / 3
		)
		for position in positions:
			if position.length_squared() < 1.0e-12:
				origin_vertices += 1
			if not position.is_finite():
				non_finite_vertices += 1
		if mesh_instance.get_active_material(surface_index) != null:
			materials += 1
	return {
		"draw_calls": surfaces,
		"surfaces": surfaces,
		"triangles": triangles,
		"vertices": vertices,
		"materials": materials,
		"origin_vertices": origin_vertices,
		"non_finite_vertices": non_finite_vertices,
		"aabb_size": mesh_instance.get_aabb().size,
	}


func _skeleton_finite(skeleton: Skeleton3D) -> bool:
	for bone_index in skeleton.get_bone_count():
		var pose := skeleton.get_bone_pose(bone_index)
		if (
			not pose.origin.is_finite()
			or not pose.basis.x.is_finite()
			or not pose.basis.y.is_finite()
			or not pose.basis.z.is_finite()
		):
			return false
	return true


func _racer_texture_vram_mib() -> float:
	var paths := [
		"res://assets/3D/Rider/skins/Racer/"
			+ "Racer_RiderCompatible_Ch20_1001_Diffuse.png",
		"res://assets/3D/Rider/skins/Racer/"
			+ "Racer_RiderCompatible_Ch20_1001_Glossiness.png",
		"res://assets/3D/Rider/skins/Racer/"
			+ "Racer_RiderCompatible_Ch20_1001_Normal.png",
		"res://assets/3D/Rider/skins/Racer/"
			+ "Racer_RiderCompatible_Ch20_1001_Specular.png",
	]
	var bytes := 0.0
	for path in paths:
		var texture := load(path) as Texture2D
		if texture != null:
			bytes += (
				float(texture.get_width())
				* float(texture.get_height())
				* 4.0
				* 1.333333333
			)
	return bytes / (1024.0 * 1024.0)


func _relative_path(node: Node, root_node: Node) -> String:
	var names: PackedStringArray = []
	var current: Node = node
	while current != null:
		names.insert(0, String(current.name))
		if current == root_node:
			break
		current = current.get_parent()
	return "/".join(names)


func _expect(condition: bool, message: String) -> void:
	if condition:
		_report.append("PASS: %s" % message)
	else:
		_fail(message)


func _fail(message: String) -> void:
	_failed = true
	_report.append("FAIL: %s" % message)
	push_error(message)


func _write_report() -> void:
	var file := FileAccess.open(REPORT_PATH, FileAccess.WRITE)
	if file != null:
		file.store_string("\n".join(_report) + "\n")
