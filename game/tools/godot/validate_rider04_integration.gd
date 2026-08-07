extends SceneTree

const RIDER_RIG_SCENE := "res://scenes/rider/rider_rig.tscn"
const JET_SKI_RIDER_SCENE := \
	"res://scenes/vehicle/jet_ski_with_rider.tscn"
const ISLAND_SCENE := \
	"res://scenes/levels/island_test/island_test_BLENDER.tscn"
const RIDER04_MESH := \
	"res://assets/3D/Rider/skins/Rider04/runtime/Rider04_Body_Mesh.res"
const RIDER04_SKIN := \
	"res://assets/3D/Rider/skins/Rider04/runtime/Rider04_Skin.res"
const REPORT_PATH := \
	"res://assets/3D/Rider/skins/Rider04/runtime/Rider04_Integration_Report.txt"
const RACER_GROUP := &"rider_skin_racer"
const RIDER01_GROUP := &"rider_skin_rider01"
const RIDER04_GROUP := &"rider_skin_rider04"
const EXPECTED_MODIFIERS: Array[StringName] = [
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
const RIDER04_TEXTURES: Array[String] = [
	"res://assets/3D/Rider/skins/Rider04/"
		+ "Rider04_RiderCompatible_diving+suit+character+3d+model_basecolor.jpg",
	"res://assets/3D/Rider/skins/Rider04/"
		+ "Rider04_RiderCompatible_diving+suit+character+3d+model_normal.jpg",
	"res://assets/3D/Rider/skins/Rider04/"
		+ "Rider04_RiderCompatible_diving+suit+character+3d+model_rm.png",
]

var _report: PackedStringArray = []
var _failed := false


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	await _validate()
	_report.append(
		"INTEGRATION_STATUS=%s" % ("FAIL" if _failed else "PASS")
	)
	_write_report()
	print("\n".join(_report))
	call_deferred("_finish")


func _finish() -> void:
	quit(1 if _failed else 0)


func _validate() -> void:
	_report.append("=== RIDER04 INTEGRATION VALIDATION ===")
	_report.append("Godot: %s" % Engine.get_version_info().string)
	_validate_persistent_resources()

	var rig_packed := load(RIDER_RIG_SCENE) as PackedScene
	var jet_packed := load(JET_SKI_RIDER_SCENE) as PackedScene
	if rig_packed == null or jet_packed == null:
		_fail("Could not load RiderRig or JetSkiWithRider.")
		return
	await _validate_skin_switching(rig_packed)
	_validate_island_selection()
	await _validate_runtime(jet_packed)


func _validate_persistent_resources() -> void:
	var mesh := load(RIDER04_MESH) as ArrayMesh
	var skin := load(RIDER04_SKIN) as Skin
	_expect(mesh != null, "Rider04 persistent ArrayMesh loads.")
	_expect(skin != null, "Rider04 persistent Skin loads.")
	for path: String in [RIDER04_MESH, RIDER04_SKIN]:
		for dependency: String in ResourceLoader.get_dependencies(path):
			_expect(
				not dependency.contains("res://.godot/imported"),
				"%s has no .godot/imported dependency." % path
			)
	if mesh == null or skin == null:
		return
	_expect(skin.get_bind_count() == 52, "Rider04 Skin has 52 binds.")
	var material_count := 0
	var texture_paths: Dictionary = {}
	for surface_index: int in mesh.get_surface_count():
		var material := mesh.surface_get_material(surface_index)
		_expect(
			material != null,
			"Rider04 surface %d has a material." % surface_index
		)
		if material == null:
			continue
		material_count += 1
		if material is BaseMaterial3D:
			var base := material as BaseMaterial3D
			_collect_texture(base.albedo_texture, texture_paths)
			_collect_texture(base.normal_texture, texture_paths)
			_collect_texture(base.roughness_texture, texture_paths)
			_collect_texture(base.metallic_texture, texture_paths)
			_expect(base.albedo_texture != null, "Rider04 albedo texture resolves.")
			_expect(base.normal_texture != null, "Rider04 normal texture resolves.")
			_expect(base.roughness_texture != null, "Rider04 roughness texture resolves.")
			_expect(base.metallic_texture != null, "Rider04 metallic texture resolves.")
			_expect(base.normal_enabled, "Rider04 normal mapping is enabled.")
			_report.append(
				"Material PBR: metallic_channel=%d roughness_channel=%d "
				% [
					base.metallic_texture_channel,
					base.roughness_texture_channel,
				]
				+ "normal_scale=%.3f transparency=%d cull_mode=%d"
				% [
					base.normal_scale,
					base.transparency,
					base.cull_mode,
				]
			)
	_report.append(
		"Persistent material/texture paths: %s" % [texture_paths.keys()]
	)
	_expect(material_count == 1, "Rider04 resolves one PBR material.")
	_expect(texture_paths.size() == 3, "Rider04 resolves three unique textures.")

	var texture_bytes := 0.0
	for texture_path: String in RIDER04_TEXTURES:
		var texture := load(texture_path) as Texture2D
		_expect(texture != null, "%s loads." % texture_path)
		if texture == null:
			continue
		var width := texture.get_width()
		var height := texture.get_height()
		_expect(
			width == 4096 and height == 4096,
			"%s remains 4096x4096." % texture_path.get_file()
		)
		texture_bytes += float(width) * float(height) * 4.0 * 1.333333333
		_report.append(
			"Texture: %s, %dx%d, mipmapped import."
			% [texture_path, width, height]
		)
	_validate_texture_import_settings()
	_report.append(
		"Rider04 texture upper-bound VRAM (RGBA8+mips): %.2f MiB"
		% (texture_bytes / (1024.0 * 1024.0))
	)


func _validate_texture_import_settings() -> void:
	for texture_path: String in RIDER04_TEXTURES:
		var import_path := texture_path + ".import"
		var file := FileAccess.open(import_path, FileAccess.READ)
		_expect(file != null, "%s import settings exist." % texture_path)
		if file == null:
			continue
		var settings := file.get_as_text()
		_expect(
			settings.contains("compress/mode=2"),
			"%s uses VRAM compression." % texture_path.get_file()
		)
		_expect(
			settings.contains("mipmaps/generate=true"),
			"%s generates mipmaps." % texture_path.get_file()
		)
		if texture_path.contains("_normal"):
			_expect(
				settings.contains("compress/normal_map=1"),
				"Rider04 normal texture is imported as a normal map."
			)


func _validate_skin_switching(rig_packed: PackedScene) -> void:
	var rig := rig_packed.instantiate()
	root.add_child(rig)
	await process_frame
	var meshes := _collect_type(rig, &"MeshInstance3D")
	var bot := _bot_meshes(meshes)
	var racer := _group_meshes(meshes, RACER_GROUP)
	var rider01 := _group_meshes(meshes, RIDER01_GROUP)
	var rider04 := _group_meshes(meshes, RIDER04_GROUP)
	_expect(bot.size() == 1, "RiderRig contains one BOT mesh.")
	_expect(not racer.is_empty(), "RiderRig retains RACER.")
	_expect(not rider01.is_empty(), "RiderRig retains RIDER01.")
	_expect(rider04.size() == 1, "RiderRig contains one RIDER04 mesh.")
	var skeletons := _collect_type(rig, &"Skeleton3D")
	var trees := _collect_type(rig, &"AnimationTree")
	if skeletons.is_empty() or trees.is_empty():
		_fail("RiderRig lacks its canonical Skeleton3D or AnimationTree.")
		rig.queue_free()
		return
	var skeleton_id := skeletons[0].get_instance_id()
	var tree_id := trees[0].get_instance_id()
	var node_count := _collect_type(rig, &"Node").size()
	for skin_value: int in [0, 1, 2, 3, 0]:
		rig.call("set_rider_skin", skin_value)
		await process_frame
		_expect(
			_visible_count(bot) == (1 if skin_value == 0 else 0)
			and _visible_count(racer) == (
				racer.size() if skin_value == 1 else 0
			)
			and _visible_count(rider01) == (
				rider01.size() if skin_value == 2 else 0
			)
			and _visible_count(rider04) == (
				rider04.size() if skin_value == 3 else 0
			),
			"Serialized skin %d has exclusive visibility." % skin_value
		)
	_expect(
		skeletons[0].get_instance_id() == skeleton_id,
		"Skin switching preserves the canonical Skeleton3D."
	)
	_expect(
		trees[0].get_instance_id() == tree_id,
		"Skin switching preserves the shared AnimationTree."
	)
	_expect(
		_collect_type(rig, &"Node").size() == node_count,
		"Skin switching creates no runtime nodes."
	)
	rig.queue_free()
	await process_frame


func _validate_island_selection() -> void:
	var island_packed := load(ISLAND_SCENE) as PackedScene
	_expect(island_packed != null, "island_test_BLENDER loads.")
	if island_packed == null:
		return
	var island := island_packed.instantiate()
	var island_rig := _find_named(island, &"RiderRig")
	_expect(
		island_rig != null and int(island_rig.get("rider_skin")) == 3,
		"island_test_BLENDER selects serialized RIDER04 = 3."
	)
	island.free()


func _validate_runtime(jet_packed: PackedScene) -> void:
	var jet := jet_packed.instantiate()
	var rider_rig := _find_named(jet, &"RiderRig")
	if rider_rig == null:
		_fail("JetSkiWithRider has no RiderRig.")
		jet.free()
		return
	for candidate: Node in _collect_type(jet, &"Node"):
		if (
			candidate != rider_rig
			and not rider_rig.is_ancestor_of(candidate)
			and candidate.get_script() != null
		):
			candidate.set_script(null)
	rider_rig.set("rider_skin", 3)
	jet.process_mode = Node.PROCESS_MODE_ALWAYS
	root.add_child(jet)
	await process_frame

	var skeletons := _collect_type(rider_rig, &"Skeleton3D")
	var players := _collect_type(rider_rig, &"AnimationPlayer")
	var trees := _collect_type(rider_rig, &"AnimationTree")
	var meshes := _collect_type(rider_rig, &"MeshInstance3D")
	var bot := _bot_meshes(meshes)
	var racer := _group_meshes(meshes, RACER_GROUP)
	var rider01 := _group_meshes(meshes, RIDER01_GROUP)
	var rider04 := _group_meshes(meshes, RIDER04_GROUP)
	_expect(skeletons.size() == 1, "Runtime has exactly one Skeleton3D.")
	_expect(players.size() == 1, "Runtime has exactly one AnimationPlayer.")
	_expect(trees.size() == 1, "Runtime has exactly one AnimationTree.")
	_expect(rider04.size() == 1, "Runtime has one Rider04 MeshInstance3D.")
	_expect(
		_visible_count(bot) == 0
		and _visible_count(racer) == 0
		and _visible_count(rider01) == 0
		and _visible_count(rider04) == 1,
		"Runtime RIDER04 visibility is exclusive."
	)
	if skeletons.size() != 1 or players.size() != 1 or trees.size() != 1:
		jet.queue_free()
		return
	var skeleton := skeletons[0] as Skeleton3D
	var player := players[0] as AnimationPlayer
	var tree := trees[0] as AnimationTree
	_expect(skeleton.get_bone_count() == 52, "Canonical runtime skeleton has 52 bones.")
	_validate_rider04_mesh(rider04[0] as MeshInstance3D, skeleton)
	_validate_animation_resources(player, tree)
	await _validate_animation_samples(player, tree, skeleton)
	await _validate_modifiers_and_ik(jet, rider_rig, skeleton)
	_report_performance(bot, racer, rider01, rider04)
	jet.queue_free()
	await process_frame


func _validate_rider04_mesh(
	mesh_instance: MeshInstance3D,
	skeleton: Skeleton3D
) -> void:
	_expect(mesh_instance.mesh != null, "Rider04 runtime Mesh resolves.")
	_expect(mesh_instance.skin != null, "Rider04 runtime Skin resolves.")
	_expect(
		mesh_instance.get_node_or_null(mesh_instance.skeleton) == skeleton,
		"Rider04 targets the canonical Skeleton3D."
	)
	if mesh_instance.skin != null:
		_expect(
			mesh_instance.skin.get_bind_count() == skeleton.get_bone_count(),
			"Rider04 bind count matches the canonical skeleton."
		)
		for bind_index: int in mesh_instance.skin.get_bind_count():
			var bone_index := mesh_instance.skin.get_bind_bone(bind_index)
			var bind_name := mesh_instance.skin.get_bind_name(bind_index)
			_expect(
				bone_index == -1
				or (
					bone_index >= 0
					and bone_index < skeleton.get_bone_count()
				),
				"Bind %d uses a valid named or indexed bone."
				% bind_index
			)
			_expect(
				skeleton.find_bone(bind_name) >= 0,
				"Bind %s resolves on the canonical skeleton." % bind_name
			)
	var weight_stats := _weight_stats(mesh_instance.mesh)
	_report.append("Rider04 weight/array stats: %s" % weight_stats)
	_expect(weight_stats.non_finite_vertices == 0, "Rider04 has no non-finite vertices.")
	_expect(weight_stats.origin_vertices == 0, "Rider04 has no vertices exploded at origin.")
	_expect(weight_stats.invalid_bone_indices == 0, "Rider04 weights reference valid bones.")
	_expect(weight_stats.bad_weight_sums == 0, "Rider04 weights are normalized.")
	_expect(weight_stats.missing_normals == 0, "Rider04 normals are present.")
	_expect(weight_stats.missing_tangents == 0, "Rider04 tangents are present.")


func _validate_animation_resources(
	player: AnimationPlayer,
	tree: AnimationTree
) -> void:
	for animation_name: StringName in EXPECTED_ANIMATIONS:
		_expect(
			player.has_animation(animation_name),
			"Shared animation %s remains available." % animation_name
		)
	var blend_tree := tree.tree_root as AnimationNodeBlendTree
	_expect(blend_tree != null, "AnimationTree still uses the shared BlendTree.")
	if blend_tree == null:
		return
	var node_names := blend_tree.get_node_list()
	for node_name: StringName in EXPECTED_BLEND_NODES:
		_expect(
			node_names.has(node_name),
			"Shared BlendTree node %s remains available." % node_name
		)


func _validate_animation_samples(
	player: AnimationPlayer,
	tree: AnimationTree,
	skeleton: Skeleton3D
) -> void:
	tree.active = false
	for animation_name: StringName in EXPECTED_ANIMATIONS:
		if not player.has_animation(animation_name):
			continue
		skeleton.reset_bone_poses()
		player.play(animation_name)
		var animation := player.get_animation(animation_name)
		player.seek(maxf(0.01, animation.length * 0.5), true)
		player.advance(0.0)
		await process_frame
		_expect(
			_skeleton_finite(skeleton),
			"%s produces finite canonical bone transforms." % animation_name
		)
		_expect(
			_skeleton_determinants_valid(skeleton),
			"%s produces valid bone determinants." % animation_name
		)
	player.stop()
	skeleton.reset_bone_poses()
	tree.active = true
	await process_frame
	var rig := tree.get_parent()
	var combinations := [
		[-0.8, -0.5, 0.35],
		[0.8, 0.5, -0.35],
		[-0.45, 0.4, -0.25],
		[0.45, -0.4, 0.25],
	]
	for values: Array in combinations:
		rig.call("set_automatic_turn_blend", values[0])
		rig.call("set_manual_roll_blend", values[1])
		rig.call("set_manual_pitch_blend", values[2])
		tree.advance(0.05)
		_expect(
			_skeleton_finite(skeleton),
			"Combined turn/roll/pitch %s remains finite." % [values]
		)
	rig.call("reset_mounted_lean_blends")


func _validate_modifiers_and_ik(
	jet: Node,
	rider_rig: Node,
	skeleton: Skeleton3D
) -> void:
	var modifiers: Array[Node] = []
	for child: Node in skeleton.get_children():
		if child is SkeletonModifier3D:
			modifiers.append(child)
	var names: Array[StringName] = []
	var active_count := 0
	var resolved_ik := 0
	for node: Node in modifiers:
		names.append(node.name)
		var modifier := node as SkeletonModifier3D
		if modifier.active:
			active_count += 1
		if modifier is TwoBoneIK3D:
			var target_path := modifier.get("settings/0/target_node") as NodePath
			var pole_path := modifier.get("settings/0/pole_node") as NodePath
			if (
				not target_path.is_empty()
				and modifier.get_node_or_null(target_path) != null
				and not pole_path.is_empty()
				and modifier.get_node_or_null(pole_path) != null
			):
				resolved_ik += 1
	_expect(names == EXPECTED_MODIFIERS, "Modifier/IK order remains unchanged.")
	_expect(active_count == 8, "All eight existing modifiers remain active.")
	_expect(resolved_ik == 4, "All four TwoBoneIK target/pole pairs resolve.")
	var tree := _collect_type(rider_rig, &"AnimationTree")[0] as AnimationTree
	tree.active = true
	for _frame: int in 3:
		await process_frame
	_expect(
		_skeleton_finite(skeleton),
		"Mounted animation plus all modifiers remains finite."
	)
	var checks := [
		["Left hand", &"mixamorig_LeftHand", &"LeftGripTarget"],
		["Right hand", &"mixamorig_RightHand", &"RightGripTarget"],
		["Left foot", &"mixamorig_LeftFoot", &"LeftFootTarget"],
		["Right foot", &"mixamorig_RightFoot", &"RightFootTarget"],
	]
	for check: Array in checks:
		var target := _find_named(jet, check[2] as StringName) as Node3D
		if target == null:
			_fail("%s IK target is missing." % check[0])
			continue
		var bone_position := _bone_world_position(
			skeleton,
			check[1] as StringName,
		)
		var distance := bone_position.distance_to(target.global_position)
		_report.append("%s / target distance: %.6f m" % [check[0], distance])
		_expect(distance < 0.75, "%s remains within IK reach." % check[0])


func _report_performance(
	bot: Array[Node],
	racer: Array[Node],
	rider01: Array[Node],
	rider04: Array[Node]
) -> void:
	var bot_stats := _aggregate_stats(bot)
	var racer_stats := _aggregate_stats(racer)
	var rider01_stats := _aggregate_stats(rider01)
	var rider04_stats := _aggregate_stats(rider04)
	_report.append("BOT stats: %s" % bot_stats)
	_report.append("RACER stats: %s" % racer_stats)
	_report.append("RIDER01 stats: %s" % rider01_stats)
	_report.append("RIDER04 stats: %s" % rider04_stats)
	_report.append(
		"Draw calls BOT/RACER/RIDER01/RIDER04: %d/%d/%d/%d"
		% [
			bot_stats.draw_calls,
			racer_stats.draw_calls,
			rider01_stats.draw_calls,
			rider04_stats.draw_calls,
		]
	)
	_report.append(
		"AABB BOT/RACER/RIDER01/RIDER04: %s / %s / %s / %s"
		% [
			bot_stats.aabb_size,
			racer_stats.aabb_size,
			rider01_stats.aabb_size,
			rider04_stats.aabb_size,
		]
	)
	_report.append(
		"Headless validation checks geometry, materials, deformation and contacts; "
		+ "Forward+ frame rate and final camera composition remain a visual-editor check."
	)


func _weight_stats(mesh: Mesh) -> Dictionary:
	var result := {
		"vertices": 0,
		"triangles": 0,
		"surfaces": mesh.get_surface_count(),
		"materials": 0,
		"non_finite_vertices": 0,
		"origin_vertices": 0,
		"invalid_bone_indices": 0,
		"bad_weight_sums": 0,
		"missing_normals": 0,
		"missing_tangents": 0,
	}
	for surface_index: int in mesh.get_surface_count():
		var arrays := mesh.surface_get_arrays(surface_index)
		var positions := arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array
		var normals := arrays[Mesh.ARRAY_NORMAL] as PackedVector3Array
		var tangents := arrays[Mesh.ARRAY_TANGENT] as PackedFloat32Array
		var bones := arrays[Mesh.ARRAY_BONES] as PackedInt32Array
		var weights := arrays[Mesh.ARRAY_WEIGHTS] as PackedFloat32Array
		var indices := arrays[Mesh.ARRAY_INDEX] as PackedInt32Array
		result.vertices += positions.size()
		result.triangles += (
			indices.size() / 3
			if not indices.is_empty()
			else positions.size() / 3
		)
		if mesh.surface_get_material(surface_index) != null:
			result.materials += 1
		if normals.size() != positions.size():
			result.missing_normals += positions.size()
		if tangents.size() != positions.size() * 4:
			result.missing_tangents += positions.size()
		for position: Vector3 in positions:
			if not position.is_finite():
				result.non_finite_vertices += 1
			if position.length_squared() < 1.0e-12:
				result.origin_vertices += 1
		var influences_per_vertex := (
			weights.size() / positions.size() if not positions.is_empty() else 0
		)
		for vertex_index: int in positions.size():
			var weight_sum := 0.0
			for influence: int in influences_per_vertex:
				var flat_index := vertex_index * influences_per_vertex + influence
				var weight := weights[flat_index]
				weight_sum += weight
				if weight > 0.000001 and (
					bones[flat_index] < 0 or bones[flat_index] >= 52
				):
					result.invalid_bone_indices += 1
			if absf(weight_sum - 1.0) > 0.015:
				result.bad_weight_sums += 1
	return result


func _mesh_stats(mesh_instance: MeshInstance3D) -> Dictionary:
	var result := _weight_stats(mesh_instance.mesh)
	result["draw_calls"] = result.surfaces
	result["aabb_size"] = mesh_instance.get_aabb().size
	return result


func _aggregate_stats(meshes: Array[Node]) -> Dictionary:
	var result := {
		"draw_calls": 0,
		"surfaces": 0,
		"triangles": 0,
		"vertices": 0,
		"materials": 0,
		"non_finite_vertices": 0,
		"aabb_size": Vector3.ZERO,
	}
	var combined_aabb := AABB()
	var first := true
	for node: Node in meshes:
		var mesh_instance := node as MeshInstance3D
		var stats := _mesh_stats(mesh_instance)
		for key: String in [
			"draw_calls",
			"surfaces",
			"triangles",
			"vertices",
			"materials",
			"non_finite_vertices",
		]:
			result[key] += int(stats[key])
		if first:
			combined_aabb = mesh_instance.get_aabb()
			first = false
		else:
			combined_aabb = combined_aabb.merge(mesh_instance.get_aabb())
	result.aabb_size = combined_aabb.size
	return result


func _collect_texture(texture: Texture2D, paths: Dictionary) -> void:
	if texture == null:
		return
	paths[texture.resource_path] = true


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
		var mesh_instance := node as MeshInstance3D
		if (
			not node.is_in_group(RACER_GROUP)
			and not node.is_in_group(RIDER01_GROUP)
			and not node.is_in_group(RIDER04_GROUP)
			and mesh_instance.mesh != null
			and mesh_instance.skin != null
		):
			result.append(node)
	return result


func _visible_count(meshes: Array[Node]) -> int:
	var count := 0
	for node: Node in meshes:
		if (node as MeshInstance3D).visible:
			count += 1
	return count


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
