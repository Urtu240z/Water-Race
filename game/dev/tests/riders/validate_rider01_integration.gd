extends SceneTree

const RIDER_RIG_SCENE := "res://gameplay/riders/common/rider_rig.tscn"
const JET_SKI_RIDER_SCENE := \
	"res://gameplay/vehicles/jet_ski_01/jet_ski_with_rider.tscn"
const ISLAND_SCENE := \
	"res://levels/paradise_island/island_test_BLENDER.tscn"
const REPORT_PATH := \
	"res://assets/3D/Rider/skins/Rider01/runtime/Rider01_Integration_Report.txt"
const RACER_GROUP := &"rider_skin_racer"
const RIDER01_GROUP := &"rider_skin_rider01"
const EXPECTED_MODIFIER_ORDER: Array[StringName] = [
	&"RiderImpactPose",
	&"LeftLegIK",
	&"RightLegIK",
	&"FootOrientation",
	&"LeftArmIK",
	&"RightArmIK",
	&"GripOrientation",
	&"GripFingers",
]
const EXPECTED_ANIMATIONS: Array[StringName] = [
	&"Mounted_Base",
	&"mounted_breathing",
	&"Mounted_Turn_Left",
	&"Mounted_Turn_Right",
	&"Mounted_Lean_Left",
	&"Mounted_Lean_Right",
	&"Mounted_Lean_Forward",
	&"Mounted_Lean_Back",
]
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
const RIDER01_TEXTURES: Array[String] = [
	"Rider01_RiderCompatible_Jartur_old_Slavic_Male_with_Genitals_and_beard_lsdif.png",
	"Rider01_RiderCompatible_brown_eye.png",
	"Rider01_RiderCompatible_eyebrow004.png",
	"Rider01_RiderCompatible_eyelashes01.png",
	"Rider01_RiderCompatible_short02_diffuse.png",
	"Rider01_RiderCompatible_sport_sunglasses.png",
	"Rider01_RiderCompatible_teeth.png",
	"Rider01_RiderCompatible_tongue01_diffuse.png",
	"Rider01_RiderCompatible_trunktest7.png",
	"Rider01_RiderCompatible_trunktest7normal.png",
	"Rider01_RiderCompatible_wb_normals.png",
	"Rider01_RiderCompatible_wb_tex3.png",
]

var _report: PackedStringArray = []
var _failed := false


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	await _validate()
	_write_report()
	print("\n".join(_report))
	call_deferred("_finish_validation")


func _finish_validation() -> void:
	quit(1 if _failed else 0)


func _validate() -> void:
	_report.append("=== RIDER01 INTEGRATION VALIDATION ===")
	_report.append("Godot: %s" % Engine.get_version_info().string)
	var rig_packed := load(RIDER_RIG_SCENE) as PackedScene
	var jet_packed := load(JET_SKI_RIDER_SCENE) as PackedScene
	if rig_packed == null or jet_packed == null:
		_fail("Could not load RiderRig or JetSkiWithRider.")
		return

	await _validate_isolated_switching(rig_packed)
	_validate_island_inheritance()

	var jet := jet_packed.instantiate()
	var rider_rig := _find_named(jet, &"RiderRig")
	if rider_rig == null:
		_fail("JetSkiWithRider has no RiderRig instance.")
		jet.free()
		return
	for candidate: Node in _collect_type(jet, &"Node"):
		if (
			candidate != rider_rig
			and not rider_rig.is_ancestor_of(candidate)
			and candidate.get_script() != null
		):
			candidate.set_script(null)
	# External gameplay scripts have been detached above. Keep the scene processing
	# so AnimationTree and SkeletonModifier3D evaluate before contact measurements.
	jet.process_mode = Node.PROCESS_MODE_ALWAYS
	root.add_child(jet)
	await process_frame

	var skeletons := _collect_type(rider_rig, &"Skeleton3D")
	var animation_players := _collect_type(rider_rig, &"AnimationPlayer")
	var animation_trees := _collect_type(rider_rig, &"AnimationTree")
	var meshes := _collect_type(rider_rig, &"MeshInstance3D")
	var bot_meshes := _bot_meshes(meshes)
	var racer_meshes := _group_meshes(meshes, RACER_GROUP)
	var rider01_meshes := _group_meshes(meshes, RIDER01_GROUP)
	_expect(skeletons.size() == 1, "Exactly one Skeleton3D remains.")
	_expect(
		animation_players.size() == 1,
		"Exactly one AnimationPlayer remains."
	)
	_expect(
		animation_trees.size() == 1,
		"Exactly one AnimationTree remains."
	)
	_expect(bot_meshes.size() == 1, "Exactly one BOT mesh remains.")
	_expect(racer_meshes.size() == 1, "Exactly one RACER mesh remains.")
	_expect(rider01_meshes.size() == 10, "Exactly ten RIDER01 meshes exist.")
	if (
		skeletons.size() != 1
		or animation_players.size() != 1
		or animation_trees.size() != 1
	):
		jet.queue_free()
		return

	var skeleton := skeletons[0] as Skeleton3D
	var animation_player := animation_players[0] as AnimationPlayer
	var animation_tree := animation_trees[0] as AnimationTree
	_expect(skeleton.get_bone_count() == 52, "Runtime skeleton has 52 bones.")
	_expect(
		int(rider_rig.get("rider_skin")) == 2,
		"JetSkiWithRider selects RIDER01."
	)
	_expect(
		_visible_count(bot_meshes) == 0
		and _visible_count(racer_meshes) == 0
		and _visible_count(rider01_meshes) == 10,
		"JetSkiWithRider shows only RIDER01."
	)
	_validate_mesh_resources(rider01_meshes, skeleton)
	_validate_animation_tree(animation_tree)
	var animation_results := await _validate_animations(
		animation_player,
		animation_tree,
		skeleton
	)
	_report.append("Animation results:")
	for result: Dictionary in animation_results:
		_report.append("  %s" % result)
	await _validate_modifiers_and_ik(jet, rider_rig, skeleton)

	var bot_stats := _aggregate_stats(bot_meshes)
	var racer_stats := _aggregate_stats(racer_meshes)
	var rider01_stats := _aggregate_stats(rider01_meshes)
	_report.append("BOT stats: %s" % bot_stats)
	_report.append("RACER stats: %s" % racer_stats)
	_report.append("RIDER01 stats: %s" % rider01_stats)
	_report.append(
		"RIDER01 texture VRAM estimate (RGBA8+mips): %.2f MiB"
		% _rider01_texture_vram_mib()
	)
	_report.append(
		"Approximate draw calls BOT/RACER/RIDER01: %d/%d/%d"
		% [
			bot_stats.draw_calls,
			racer_stats.draw_calls,
			rider01_stats.draw_calls,
		]
	)
	_report.append(
		"RIDER01 static geometry: %d vertices, %d triangles, %d materials."
		% [
			rider01_stats.vertices,
			rider01_stats.triangles,
			rider01_stats.materials,
		]
	)
	_report.append(
		"FPS note: headless validation cannot measure Forward+ GPU FPS; "
		+ "a focused graphical sample is recorded separately."
	)

	jet.queue_free()
	await process_frame
	_report.append(
		"INTEGRATION_STATUS=%s" % ("FAIL" if _failed else "PASS")
	)


func _validate_isolated_switching(rig_packed: PackedScene) -> void:
	var rig := rig_packed.instantiate()
	root.add_child(rig)
	await process_frame
	var meshes := _collect_type(rig, &"MeshInstance3D")
	var bot := _bot_meshes(meshes)
	var racer := _group_meshes(meshes, RACER_GROUP)
	var rider01 := _group_meshes(meshes, RIDER01_GROUP)
	_expect(bot.size() == 1, "Isolated RiderRig has one BOT mesh.")
	_expect(racer.size() == 1, "Isolated RiderRig has one RACER mesh.")
	_expect(rider01.size() == 10, "Isolated RiderRig has ten RIDER01 meshes.")
	var skeleton := _collect_type(rig, &"Skeleton3D")[0] as Skeleton3D
	var tree := _collect_type(rig, &"AnimationTree")[0] as AnimationTree
	var skeleton_id := skeleton.get_instance_id()
	var tree_id := tree.get_instance_id()
	var node_count := _collect_type(rig, &"Node").size()
	var sequence: Array[int] = [0, 2, 0, 1, 2, 0]
	for skin_value: int in sequence:
		rig.call("set_rider_skin", skin_value)
		await process_frame
		var expected_bot := 1 if skin_value == 0 else 0
		var expected_racer := 1 if skin_value == 1 else 0
		var expected_rider01 := 10 if skin_value == 2 else 0
		_expect(
			_visible_count(bot) == expected_bot
			and _visible_count(racer) == expected_racer
			and _visible_count(rider01) == expected_rider01,
			"Skin %d visibility is exclusive." % skin_value
		)
	_expect(
		skeleton.get_instance_id() == skeleton_id,
		"Skin switching preserves the Skeleton3D instance."
	)
	_expect(
		tree.get_instance_id() == tree_id,
		"Skin switching preserves the AnimationTree instance."
	)
	_expect(
		_collect_type(rig, &"Node").size() == node_count,
		"Skin switching creates no nodes."
	)
	_expect(
		_visible_count(bot) == 1
		and _visible_count(racer) == 0
		and _visible_count(rider01) == 0,
		"RiderRig returns reversibly to BOT."
	)
	rig.queue_free()
	await process_frame


func _validate_island_inheritance() -> void:
	var island_packed := load(ISLAND_SCENE) as PackedScene
	_expect(island_packed != null, "island_test_BLENDER loads.")
	if island_packed == null:
		return
	var island := island_packed.instantiate()
	var island_rig := _find_named(island, &"RiderRig")
	_expect(
		island_rig != null and int(island_rig.get("rider_skin")) == 2,
		"island_test_BLENDER inherits RIDER01 from JetSkiWithRider."
	)
	island.free()


func _validate_mesh_resources(
	meshes: Array[Node],
	skeleton: Skeleton3D
) -> void:
	var shared_skin: Skin = null
	var valid_materials := 0
	for node: Node in meshes:
		var mesh_instance := node as MeshInstance3D
		_expect(mesh_instance.mesh != null, "%s has a Mesh." % node.name)
		_expect(mesh_instance.skin != null, "%s has a Skin." % node.name)
		_expect(
			mesh_instance.get_node_or_null(mesh_instance.skeleton) == skeleton,
			"%s targets the shared Skeleton3D." % node.name
		)
		if shared_skin == null:
			shared_skin = mesh_instance.skin
		else:
			_expect(
				mesh_instance.skin == shared_skin,
				"%s reuses the shared Rider01 Skin." % node.name
			)
		if mesh_instance.skin != null:
			_expect(
				mesh_instance.skin.get_bind_count() == 52,
				"%s has 52 binds." % node.name
			)
		if mesh_instance.mesh != null:
			for surface_index: int in mesh_instance.mesh.get_surface_count():
				if mesh_instance.get_active_material(surface_index) != null:
					valid_materials += 1
	_expect(valid_materials == 10, "All ten Rider01 materials resolve.")


func _validate_animation_tree(animation_tree: AnimationTree) -> void:
	_expect(animation_tree.active, "AnimationTree is active after _ready().")
	var blend_tree := animation_tree.tree_root as AnimationNodeBlendTree
	_expect(blend_tree != null, "AnimationTree still uses its BlendTree.")
	if blend_tree == null:
		return
	var node_names := blend_tree.get_node_list()
	for node_name: StringName in EXPECTED_BLEND_NODES:
		_expect(
			node_names.has(node_name),
			"BlendTree node %s remains available." % node_name
		)


func _validate_animations(
	player: AnimationPlayer,
	tree: AnimationTree,
	skeleton: Skeleton3D
) -> Array[Dictionary]:
	var results: Array[Dictionary] = []
	for animation_name: StringName in EXPECTED_ANIMATIONS:
		_expect(
			player.has_animation(animation_name),
			"Animation %s remains available." % animation_name
		)
	if _failed:
		return results
	tree.active = false
	for animation_name: StringName in EXPECTED_ANIMATIONS:
		skeleton.reset_bone_poses()
		player.play(animation_name)
		var animation := player.get_animation(animation_name)
		var sample_time := maxf(0.01, animation.length * 0.5)
		player.seek(sample_time, true)
		player.advance(0.0)
		await process_frame
		var finite := _skeleton_finite(skeleton)
		var determinant_valid := _skeleton_determinants_valid(skeleton)
		_expect(finite, "%s produces finite bones." % animation_name)
		_expect(
			determinant_valid,
			"%s produces no inverted/degenerate bones." % animation_name
		)
		results.append({
			"name": animation_name,
			"sample_seconds": sample_time,
			"finite": finite,
			"determinants_valid": determinant_valid,
			"hips": _bone_origin(skeleton, &"mixamorig_Hips"),
			"head": _bone_origin(skeleton, &"mixamorig_Head"),
			"left_hand": _bone_origin(
				skeleton, &"mixamorig_LeftHand"
			),
			"left_foot": _bone_origin(
				skeleton, &"mixamorig_LeftFoot"
			),
		})
		player.stop()
		skeleton.reset_bone_poses()
	tree.active = true
	await process_frame
	return results


func _validate_modifiers_and_ik(
	jet: Node,
	rider_rig: Node,
	skeleton: Skeleton3D
) -> void:
	var modifier_nodes: Array[Node] = []
	for child: Node in skeleton.get_children():
		if child is SkeletonModifier3D:
			modifier_nodes.append(child)
	var modifier_names: Array[StringName] = []
	var active_count := 0
	var resolved_ik := 0
	for node: Node in modifier_nodes:
		modifier_names.append(node.name)
		var modifier := node as SkeletonModifier3D
		if modifier.active:
			active_count += 1
		if modifier is TwoBoneIK3D:
			var target_path := modifier.get(
				"settings/0/target_node"
			) as NodePath
			var pole_path := modifier.get(
				"settings/0/pole_node"
			) as NodePath
			if (
				not target_path.is_empty()
				and modifier.get_node_or_null(target_path) != null
				and not pole_path.is_empty()
				and modifier.get_node_or_null(pole_path) != null
			):
				resolved_ik += 1
	_expect(
		modifier_names == EXPECTED_MODIFIER_ORDER,
		"Modifier order remains %s." % [EXPECTED_MODIFIER_ORDER]
	)
	_expect(active_count == 8, "All eight modifiers are active.")
	_expect(resolved_ik == 4, "All four IK target/pole pairs resolve.")

	var animation_tree := _collect_type(
		rider_rig, &"AnimationTree"
	)[0] as AnimationTree
	animation_tree.active = true
	rider_rig.call("reset_mounted_lean_blends")
	for _frame: int in 3:
		await process_frame
	_expect(
		_skeleton_finite(skeleton),
		"Combined mounted animation and eight modifiers remain finite."
	)
	var checks := [
		[
			"Left hand/grip",
			&"mixamorig_LeftHand",
			_find_named(jet, &"LeftGripTarget"),
		],
		[
			"Right hand/grip",
			&"mixamorig_RightHand",
			_find_named(jet, &"RightGripTarget"),
		],
		[
			"Left foot/target",
			&"mixamorig_LeftFoot",
			_find_named(jet, &"LeftFootTarget"),
		],
		[
			"Right foot/target",
			&"mixamorig_RightFoot",
			_find_named(jet, &"RightFootTarget"),
		],
	]
	for check: Array in checks:
		var target := check[2] as Node3D
		if target == null:
			_fail("%s target is missing." % check[0])
			continue
		var bone_position := _bone_world_position(
			skeleton, check[1] as StringName
		)
		var distance := bone_position.distance_to(target.global_position)
		_report.append("%s distance: %.6f m" % [check[0], distance])
		_expect(distance < 0.75, "%s remains within IK reach." % check[0])


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
	for candidate: Node in _collect_type(node, &"Node"):
		if candidate.name == target_name:
			return candidate
	return null


func _group_meshes(
	meshes: Array[Node],
	group_name: StringName
) -> Array[Node]:
	var result: Array[Node] = []
	for node: Node in meshes:
		if node.is_in_group(group_name):
			result.append(node)
	return result


func _bot_meshes(meshes: Array[Node]) -> Array[Node]:
	var result: Array[Node] = []
	for node: Node in meshes:
		var mesh_node := node as MeshInstance3D
		if (
			not node.is_in_group(RACER_GROUP)
			and not node.is_in_group(RIDER01_GROUP)
			and mesh_node.mesh != null
			and mesh_node.skin != null
		):
			result.append(node)
	return result


func _visible_count(meshes: Array[Node]) -> int:
	var count := 0
	for node: Node in meshes:
		if (node as MeshInstance3D).visible:
			count += 1
	return count


func _mesh_stats(mesh_instance: MeshInstance3D) -> Dictionary:
	var surfaces := mesh_instance.mesh.get_surface_count()
	var triangles := 0
	var vertices := 0
	var materials := 0
	var non_finite_vertices := 0
	for surface_index: int in surfaces:
		var arrays := mesh_instance.mesh.surface_get_arrays(surface_index)
		var positions := arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array
		var indices := arrays[Mesh.ARRAY_INDEX] as PackedInt32Array
		vertices += positions.size()
		triangles += (
			indices.size() / 3
			if not indices.is_empty()
			else positions.size() / 3
		)
		for position: Vector3 in positions:
			if not position.is_finite():
				non_finite_vertices += 1
		if mesh_instance.get_active_material(surface_index) != null:
			materials += 1
	return {
		"draw_calls": surfaces,
		"triangles": triangles,
		"vertices": vertices,
		"materials": materials,
		"non_finite_vertices": non_finite_vertices,
		"aabb_size": mesh_instance.get_aabb().size,
	}


func _aggregate_stats(meshes: Array[Node]) -> Dictionary:
	var result := {
		"draw_calls": 0,
		"triangles": 0,
		"vertices": 0,
		"materials": 0,
		"non_finite_vertices": 0,
	}
	for node: Node in meshes:
		var stats := _mesh_stats(node as MeshInstance3D)
		for key: String in result:
			result[key] += int(stats[key])
	return result


func _skeleton_finite(skeleton: Skeleton3D) -> bool:
	for bone_index: int in skeleton.get_bone_count():
		var pose := skeleton.get_bone_pose(bone_index)
		var global_pose := skeleton.get_bone_global_pose(bone_index)
		if not _transform_finite(pose) or not _transform_finite(global_pose):
			return false
	return true


func _skeleton_determinants_valid(skeleton: Skeleton3D) -> bool:
	for bone_index: int in skeleton.get_bone_count():
		var determinant := skeleton.get_bone_global_pose(
			bone_index
		).basis.determinant()
		if not is_finite(determinant) or determinant < 0.01:
			return false
	return true


func _transform_finite(transform: Transform3D) -> bool:
	return (
		transform.origin.is_finite()
		and transform.basis.x.is_finite()
		and transform.basis.y.is_finite()
		and transform.basis.z.is_finite()
	)


func _bone_origin(
	skeleton: Skeleton3D,
	bone_name: StringName
) -> Vector3:
	var bone_index := skeleton.find_bone(bone_name)
	return (
		skeleton.get_bone_global_pose(bone_index).origin
		if bone_index >= 0
		else Vector3.INF
	)


func _bone_world_position(
	skeleton: Skeleton3D,
	bone_name: StringName
) -> Vector3:
	var bone_index := skeleton.find_bone(bone_name)
	if bone_index < 0:
		return Vector3.INF
	return skeleton.to_global(
		skeleton.get_bone_global_pose(bone_index).origin
	)


func _rider01_texture_vram_mib() -> float:
	var bytes := 0.0
	for filename: String in RIDER01_TEXTURES:
		var texture := load(
			"res://assets/3D/Rider/skins/Rider01/" + filename
		) as Texture2D
		if texture != null:
			bytes += (
				float(texture.get_width())
				* float(texture.get_height())
				* 4.0
				* 1.333333333
			)
	return bytes / (1024.0 * 1024.0)


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
