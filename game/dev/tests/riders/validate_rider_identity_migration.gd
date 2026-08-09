extends SceneTree

const RIDER_RIG_SCENE := "res://gameplay/riders/common/rider_rig.tscn"
const JET_SKI_RIDER_SCENE := \
	"res://gameplay/vehicles/jet_ski_01/jet_ski_with_rider.tscn"
const EXPECTED := {
	&"rider_bot": {
		"value": 0,
		"glb": "res://gameplay/riders/rider_bot/rider_bot.glb",
	},
	&"rider_01": {
		"value": 3,
		"glb": "res://gameplay/riders/rider_01/rider_01_compatible.glb",
		"mesh": "res://gameplay/riders/rider_01/runtime/rider_01_body_mesh.res",
		"skin": "res://gameplay/riders/rider_01/runtime/rider_01_skin.res",
		"lods": 14,
		"vertices": 27992,
		"indices": 146151,
	},
	&"rider_02": {
		"value": 4,
		"glb": "res://gameplay/riders/rider_02/rider_02_compatible.glb",
		"mesh": "res://gameplay/riders/rider_02/runtime/rider_02_body_mesh.res",
		"skin": "res://gameplay/riders/rider_02/runtime/rider_02_skin.res",
		"lods": 14,
		"vertices": 38660,
		"indices": 208179,
	},
	&"rider_03": {
		"value": 5,
		"glb": "res://gameplay/riders/rider_03/rider_03_compatible.glb",
		"mesh": "res://gameplay/riders/rider_03/runtime/rider_03_body_mesh.res",
		"skin": "res://gameplay/riders/rider_03/runtime/rider_03_skin.res",
		"lods": 16,
		"vertices": 36689,
		"indices": 200628,
	},
	&"rider_04": {
		"value": 1,
		"glb": "res://gameplay/riders/rider_04/rider_04_compatible.glb",
		"mesh": "res://gameplay/riders/rider_04/runtime/rider_04_body_mesh.res",
		"skin": "res://gameplay/riders/rider_04/runtime/rider_04_skin.res",
		"lods": 16,
		"vertices": 27488,
		"indices": 149601,
	},
}
const REPORT_PATH := "user://rider_identity_migration_report.txt"

var _failures: PackedStringArray = []
var _report: PackedStringArray = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_report.append("=== RIDER IDENTITY MIGRATION VALIDATION ===")
	await _validate()
	_report.append("IDENTITY_MIGRATION_STATUS=%s" % ("PASS" if _failures.is_empty() else "FAIL"))
	var file := FileAccess.open(REPORT_PATH, FileAccess.WRITE)
	if file != null:
		file.store_string("\n".join(_report) + "\n")
	print("\n".join(_report))
	quit(0 if _failures.is_empty() else 1)


func _validate() -> void:
	var packed := load(RIDER_RIG_SCENE) as PackedScene
	_expect(packed != null, "RiderRig scene loads.")
	if packed == null:
		return
	var rig := packed.instantiate()
	root.add_child(rig)
	await process_frame
	_expect(
		int(rig.get("rider_skin")) == 5,
		"RiderRig default remains physical Athletic Female as rider_03."
	)
	_validate_jet_ski_default()
	var options: Array[Dictionary] = rig.get_available_rider_skin_options()
	_expect(options.size() == 5, "Exactly five selectable Rider identities are exposed.")
	var actual_ids: Array[StringName] = []
	for option: Dictionary in options:
		actual_ids.append(StringName(String(option["id"]).to_lower()))
	for rider_id: StringName in EXPECTED:
		_expect(actual_ids.has(rider_id), "%s is present in the selector catalog." % rider_id)
	var skeletons := _collect_type(rig, &"Skeleton3D")
	_expect(skeletons.size() == 1, "The rig keeps one canonical Skeleton3D.")
	if skeletons.size() == 1:
		_expect((skeletons[0] as Skeleton3D).get_bone_count() == 52, "The canonical skeleton keeps 52 bones.")

	for rider_id: StringName in EXPECTED:
		var data: Dictionary = EXPECTED[rider_id]
		_expect(ResourceLoader.exists(data.glb), "%s GLB exists." % rider_id)
		if rider_id == &"rider_bot":
			continue
		_validate_imported_glb(rider_id, data)
		var mesh := load(data.mesh) as ArrayMesh
		var skin := load(data.skin) as Skin
		_expect(mesh != null, "%s runtime mesh loads." % rider_id)
		_expect(skin != null, "%s runtime skin loads." % rider_id)
		if mesh != null:
			_expect(mesh.get_surface_count() == 1, "%s has one runtime surface." % rider_id)
		if skin != null:
			_expect(skin.get_bind_count() == 52, "%s has 52 runtime binds." % rider_id)
		var group := StringName("rider_skin_%s" % rider_id)
		var group_meshes := _group_meshes(rig, group)
		_expect(group_meshes.size() == 1, "%s has exactly one rig mesh." % rider_id)
		rig.call("set_rider_skin", int(data.value))
		await process_frame
		_expect(_visible_count(group_meshes) == 1, "%s is selectable using preserved value %d." % [rider_id, int(data.value)])
		for other_id: StringName in EXPECTED:
			if other_id == &"rider_bot" or other_id == rider_id:
				continue
			_expect(
				_visible_count(_group_meshes(rig, StringName("rider_skin_%s" % other_id))) == 0,
				"%s selection hides %s." % [rider_id, other_id]
			)
	rig.queue_free()
	await process_frame


func _validate_jet_ski_default() -> void:
	var packed := load(JET_SKI_RIDER_SCENE) as PackedScene
	_expect(packed != null, "JetSkiWithRider scene loads.")
	if packed == null:
		return
	var jet := packed.instantiate()
	var rig := _find_named(jet, &"RiderRig")
	_expect(
		rig != null and int(rig.get("rider_skin")) == 4,
		"JetSkiWithRider keeps physical Athletic Male as rider_02."
	)
	jet.free()


func _validate_imported_glb(rider_id: StringName, data: Dictionary) -> void:
	var packed := load(data.glb) as PackedScene
	_expect(packed != null, "%s compatible GLB imports." % rider_id)
	if packed == null:
		return
	var instance := packed.instantiate()
	var meshes := _collect_type(instance, &"MeshInstance3D")
	var vertices := 0
	var indices := 0
	var lods := 0
	for node: Node in meshes:
		var mesh := (node as MeshInstance3D).mesh
		if mesh == null:
			continue
		for surface_index: int in mesh.get_surface_count():
			var arrays := mesh.surface_get_arrays(surface_index)
			vertices += (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
			indices += (arrays[Mesh.ARRAY_INDEX] as PackedInt32Array).size()
		var surfaces = mesh.get("_surfaces")
		if surfaces is Array:
			for surface in surfaces:
				if surface is Dictionary and (surface as Dictionary).get("lods", []) is Array:
					lods += ((surface as Dictionary).get("lods", []) as Array).size()
	_expect(vertices == int(data.vertices), "%s keeps %d imported vertices." % [rider_id, int(data.vertices)])
	_expect(indices == int(data.indices), "%s keeps %d imported indices." % [rider_id, int(data.indices)])
	_expect(lods == int(data.lods), "%s keeps %d imported LOD entries." % [rider_id, int(data.lods)])
	instance.free()


func _collect_type(node: Node, type_name: StringName) -> Array[Node]:
	var result: Array[Node] = []
	if node.is_class(type_name):
		result.append(node)
	for child: Node in node.get_children():
		result.append_array(_collect_type(child, type_name))
	return result


func _group_meshes(node: Node, group: StringName) -> Array[Node]:
	var result: Array[Node] = []
	for candidate: Node in _collect_type(node, &"MeshInstance3D"):
		if candidate.is_in_group(group):
			result.append(candidate)
	return result


func _find_named(node: Node, target_name: StringName) -> Node:
	if node.name == target_name:
		return node
	for child: Node in node.get_children():
		var found := _find_named(child, target_name)
		if found != null:
			return found
	return null


func _visible_count(nodes: Array[Node]) -> int:
	var count := 0
	for node: Node in nodes:
		if (node as MeshInstance3D).visible:
			count += 1
	return count


func _expect(condition: bool, message: String) -> void:
	_report.append("%s: %s" % ["PASS" if condition else "FAIL", message])
	if not condition:
		_failures.append(message)
