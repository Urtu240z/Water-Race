extends Node3D

const REPORT_PATH := \
	"res://assets/3D/Rider/skins/Rider01/runtime/" \
	+ "Rider01_OriginalSkin_SharedSkeleton_Test.txt"
const CAPTURE_DIRECTORY := \
	"res://assets/3D/Rider/skins/Rider01/runtime/original_skin_test_captures"
const TARGET_SKELETON_PATH := \
	"RiderModelRoot/Rider_Bot/SKEL_Rider/Skeleton3D"
const TEST_MESH_PREFIX := "OriginalSkinTest_"
const KEY_BONES: Array[StringName] = [
	&"mixamorig_Hips",
	&"mixamorig_Spine2",
	&"mixamorig_LeftArm",
	&"mixamorig_LeftForeArm",
	&"mixamorig_LeftHand",
	&"mixamorig_RightArm",
	&"mixamorig_RightForeArm",
	&"mixamorig_RightHand",
	&"mixamorig_LeftUpLeg",
	&"mixamorig_LeftLeg",
	&"mixamorig_LeftFoot",
	&"mixamorig_RightUpLeg",
	&"mixamorig_RightLeg",
	&"mixamorig_RightFoot",
]

@onready var _original_root: Node3D = $OriginalRider
@onready var _shared_rig: Node3D = $SharedRiderRig
@onready var _camera: Camera3D = $Camera3D

var _source_skeleton: Skeleton3D
var _target_skeleton: Skeleton3D
var _source_meshes: Array[MeshInstance3D] = []
var _test_meshes: Array[MeshInstance3D] = []
var _hidden_target_meshes: Array[MeshInstance3D] = []
var _report: PackedStringArray = []
var _body_aabb := AABB()
var _aabb_initialized := false


func _ready() -> void:
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
	DisplayServer.window_set_size(Vector2i(900, 900))
	await get_tree().process_frame
	if not _prepare_test():
		_write_report(&"SETUP_FAILED")
		get_tree().quit(1)
		return
	await get_tree().process_frame
	await RenderingServer.frame_post_draw
	_collect_metrics()
	await _capture_all_views()
	_write_report(&"REST_CAPTURED")
	get_tree().quit(0)


func _prepare_test() -> bool:
	_source_skeleton = _find_first_skeleton(_original_root)
	_target_skeleton = _shared_rig.get_node_or_null(
		TARGET_SKELETON_PATH
	) as Skeleton3D
	if _source_skeleton == null or _target_skeleton == null:
		_report.append("FAIL: Source or target Skeleton3D is missing.")
		return false
	_source_meshes = _collect_skinned_meshes(_original_root)
	if _source_meshes.size() != 10:
		_report.append(
			"FAIL: Expected 10 original skinned meshes, found %d."
			% _source_meshes.size()
		)
		return false

	_disable_animation_and_modifiers(_original_root)
	_disable_animation_and_modifiers(_shared_rig)
	_source_skeleton.reset_bone_poses()
	_target_skeleton.reset_bone_poses()

	# Align only the isolated test roots so both Skeleton3D origins coincide.
	var target_in_rig := (
		_shared_rig.global_transform.affine_inverse()
		* _target_skeleton.global_transform
	)
	_shared_rig.global_transform = (
		_source_skeleton.global_transform
		* target_in_rig.affine_inverse()
	)

	for existing: MeshInstance3D in _collect_meshes(_shared_rig):
		existing.visible = false
		_hidden_target_meshes.append(existing)
	for source_mesh: MeshInstance3D in _source_meshes:
		var relative_transform := (
			_source_skeleton.global_transform.affine_inverse()
			* source_mesh.global_transform
		)
		var test_mesh := MeshInstance3D.new()
		test_mesh.name = TEST_MESH_PREFIX + source_mesh.name
		test_mesh.mesh = source_mesh.mesh
		test_mesh.skin = source_mesh.skin
		test_mesh.skeleton = NodePath("..")
		test_mesh.transform = relative_transform
		test_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		_target_skeleton.add_child(test_mesh)
		_test_meshes.append(test_mesh)
	for mesh: MeshInstance3D in _collect_meshes(_original_root):
		if mesh not in _source_meshes:
			mesh.visible = false
	_original_root.visible = true
	_shared_rig.visible = false
	return true


func _disable_animation_and_modifiers(root: Node) -> void:
	var pending: Array[Node] = [root]
	while not pending.is_empty():
		var current := pending.pop_back() as Node
		if current is AnimationTree:
			(current as AnimationTree).active = false
		elif current is AnimationPlayer:
			(current as AnimationPlayer).stop()
		elif current is SkeletonModifier3D:
			(current as SkeletonModifier3D).active = false
		for child: Node in current.get_children():
			pending.append(child)


func _collect_metrics() -> void:
	_report.append("=== RIDER01 ORIGINAL SKIN / SHARED SKELETON REST TEST ===")
	_report.append(
		"Source Skeleton3D: %s" % _source_skeleton.get_path()
	)
	_report.append(
		"Target Skeleton3D: %s" % _target_skeleton.get_path()
	)
	_report.append(
		"Source/target bones: %d/%d"
		% [
			_source_skeleton.get_bone_count(),
			_target_skeleton.get_bone_count(),
		]
	)
	_report.append("Original skinned meshes: %d" % _source_meshes.size())
	_report.append("Temporary shared meshes: %d" % _test_meshes.size())
	_report.append(
		"Source visual with own Skeleton3D: %s"
		% ("PASS" if _source_meshes.size() == 10 else "FAIL")
	)

	var source_names := _bone_name_set(_source_skeleton)
	var target_names := _bone_name_set(_target_skeleton)
	_report.append(
		"Bone names match: %s" % ("YES" if source_names == target_names else "NO")
	)
	var max_source_residual := 0.0
	var max_target_residual := 0.0
	var max_target_translation := 0.0
	var max_target_angle := 0.0
	var bind_names_match := true
	var shared_bind_count := -1
	for source_mesh: MeshInstance3D in _source_meshes:
		var test_mesh := _find_test_mesh(source_mesh.name)
		var relative := (
			_source_skeleton.global_transform.affine_inverse()
			* source_mesh.global_transform
		)
		var source_aabb := _world_aabb(source_mesh)
		var target_aabb := _world_aabb(test_mesh)
		_merge_body_aabb(source_aabb)
		var skin := source_mesh.skin
		var bind_count := skin.get_bind_count() if skin != null else 0
		if shared_bind_count < 0:
			shared_bind_count = bind_count
		elif shared_bind_count != bind_count:
			bind_names_match = false
		_report.append(
			"MESH %s | relative=%s | binds=%d"
			% [source_mesh.name, relative, bind_count]
		)
		_report.append(
			"  bind_names=%s" % _skin_bind_names(skin)
		)
		_report.append(
			"  source_aabb center=%s size=%s"
			% [source_aabb.get_center(), source_aabb.size]
		)
		_report.append(
			"  shared_aabb center=%s size=%s"
			% [target_aabb.get_center(), target_aabb.size]
		)
		if skin == null:
			bind_names_match = false
			continue
		for bind_index: int in skin.get_bind_count():
			var bind_name := skin.get_bind_name(bind_index)
			var source_bone := _source_skeleton.find_bone(bind_name)
			var target_bone := _target_skeleton.find_bone(bind_name)
			if source_bone < 0 or target_bone < 0:
				bind_names_match = false
				continue
			var bind_pose := skin.get_bind_pose(bind_index)
			var source_residual := (
				_source_skeleton.get_bone_global_rest(source_bone)
				* bind_pose
			)
			var target_residual := (
				_target_skeleton.get_bone_global_rest(target_bone)
				* bind_pose
			)
			max_source_residual = maxf(
				max_source_residual,
				_transform_identity_error(source_residual)
			)
			max_target_residual = maxf(
				max_target_residual,
				_transform_identity_error(target_residual)
			)
			max_target_translation = maxf(
				max_target_translation,
				target_residual.origin.length()
			)
			max_target_angle = maxf(
				max_target_angle,
				rad_to_deg(
					target_residual.basis.get_rotation_quaternion().get_angle()
				)
			)
	_report.append("Shared bind count: %d" % shared_bind_count)
	_report.append(
		"Bind names resolve on both skeletons: %s"
		% ("YES" if bind_names_match else "NO")
	)
	_report.append(
		"Own-skeleton bind residual max: %.9f" % max_source_residual
	)
	_report.append(
		"Shared-skeleton bind residual max: %.9f" % max_target_residual
	)
	_report.append(
		"Shared residual translation max: %.6f m"
		% max_target_translation
	)
	_report.append(
		"Shared residual rotation max: %.6f deg" % max_target_angle
	)
	_report.append("=== KEY BONE RESIDUALS ON SHARED REST ===")
	var reference_skin := _source_meshes[0].skin
	for bone_name: StringName in KEY_BONES:
		var bind_index := _find_bind(reference_skin, bone_name)
		var target_bone := _target_skeleton.find_bone(bone_name)
		if bind_index < 0 or target_bone < 0:
			_report.append("%s | MISSING" % bone_name)
			continue
		var residual := (
			_target_skeleton.get_bone_global_rest(target_bone)
			* reference_skin.get_bind_pose(bind_index)
		)
		_report.append(
			"%s | translation=%.6f m | rotation=%.6f deg | scale=%s"
			% [
				bone_name,
				residual.origin.length(),
				rad_to_deg(
					residual.basis.get_rotation_quaternion().get_angle()
				),
				residual.basis.get_scale(),
			]
		)
	var rest_numeric_pass := (
		max_target_translation <= 0.02
		and max_target_angle <= 5.0
	)
	_report.append(
		"REST_NUMERIC_RESULT=%s"
		% ("PASS" if rest_numeric_pass else "FAIL")
	)
	if not rest_numeric_pass:
		_report.append("ANIMATION_RESULT=NOT_RUN_REST_FAILED")
		_report.append("MODIFIER_RESULT=NOT_RUN_REST_FAILED")
		_report.append("CONCLUSION=NOT_COMPATIBLE")


func _capture_all_views() -> void:
	DirAccess.make_dir_recursive_absolute(
		ProjectSettings.globalize_path(CAPTURE_DIRECTORY)
	)
	var center := _body_aabb.get_center()
	var body_size := maxf(
		_body_aabb.size.x,
		maxf(_body_aabb.size.y, _body_aabb.size.z)
	)
	var full_distance := maxf(body_size * 2.0, 2.4)
	var hand_center := _bone_pair_center(
		_source_skeleton,
		&"mixamorig_LeftHand",
		&"mixamorig_RightHand"
	)
	var foot_center := _bone_pair_center(
		_source_skeleton,
		&"mixamorig_LeftFoot",
		&"mixamorig_RightFoot"
	)
	var views := [
		{
			"name": "front",
			"position": center + Vector3(0.0, 0.0, full_distance),
			"target": center,
			"fov": 34.0,
		},
		{
			"name": "lateral",
			"position": center + Vector3(full_distance, 0.0, 0.0),
			"target": center,
			"fov": 34.0,
		},
		{
			"name": "rear",
			"position": center + Vector3(0.0, 0.0, -full_distance),
			"target": center,
			"fov": 34.0,
		},
		{
			"name": "hands",
			"position": hand_center + Vector3(0.0, 0.0, full_distance * 0.8),
			"target": hand_center,
			"fov": 32.0,
		},
		{
			"name": "feet",
			"position": foot_center + Vector3(0.0, 0.0, body_size * 0.75),
			"target": foot_center,
			"fov": 26.0,
		},
	]
	for view: Dictionary in views:
		await _capture_view(view, true)
		await _capture_view(view, false)


func _capture_view(view: Dictionary, original_visible: bool) -> void:
	_original_root.visible = original_visible
	_shared_rig.visible = not original_visible
	_camera.global_position = view.position as Vector3
	_camera.fov = float(view.fov)
	_camera.look_at(view.target as Vector3, Vector3.UP)
	await get_tree().process_frame
	await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var image := get_viewport().get_texture().get_image()
	var model_label := "original" if original_visible else "shared"
	var output_path := (
		CAPTURE_DIRECTORY
		+ "/rest_"
		+ model_label
		+ "_"
		+ String(view.name)
		+ ".png"
	)
	image.save_png(ProjectSettings.globalize_path(output_path))
	_report.append("CAPTURE: %s" % output_path)


func _world_aabb(mesh_instance: MeshInstance3D) -> AABB:
	if mesh_instance == null:
		return AABB()
	return mesh_instance.global_transform * mesh_instance.get_aabb()


func _merge_body_aabb(value: AABB) -> void:
	if not _aabb_initialized:
		_body_aabb = value
		_aabb_initialized = true
	else:
		_body_aabb = _body_aabb.merge(value)


func _bone_pair_center(
	skeleton: Skeleton3D,
	left_name: StringName,
	right_name: StringName
) -> Vector3:
	var left := skeleton.find_bone(left_name)
	var right := skeleton.find_bone(right_name)
	if left < 0 or right < 0:
		return _body_aabb.get_center()
	var left_position := (
		skeleton.global_transform
		* skeleton.get_bone_global_pose(left).origin
	)
	var right_position := (
		skeleton.global_transform
		* skeleton.get_bone_global_pose(right).origin
	)
	return (left_position + right_position) * 0.5


func _find_first_skeleton(root: Node) -> Skeleton3D:
	var pending: Array[Node] = [root]
	while not pending.is_empty():
		var current := pending.pop_back() as Node
		if current is Skeleton3D:
			return current as Skeleton3D
		for child: Node in current.get_children():
			pending.append(child)
	return null


func _collect_meshes(root: Node) -> Array[MeshInstance3D]:
	var result: Array[MeshInstance3D] = []
	var pending: Array[Node] = [root]
	while not pending.is_empty():
		var current := pending.pop_back() as Node
		if current is MeshInstance3D:
			result.append(current as MeshInstance3D)
		for child: Node in current.get_children():
			pending.append(child)
	return result


func _collect_skinned_meshes(root: Node) -> Array[MeshInstance3D]:
	var result: Array[MeshInstance3D] = []
	for mesh: MeshInstance3D in _collect_meshes(root):
		if mesh.mesh != null and mesh.skin != null:
			result.append(mesh)
	return result


func _find_test_mesh(source_name: StringName) -> MeshInstance3D:
	for mesh: MeshInstance3D in _test_meshes:
		if mesh.name == TEST_MESH_PREFIX + source_name:
			return mesh
	return null


func _bone_name_set(skeleton: Skeleton3D) -> Dictionary:
	var result := {}
	for bone_index: int in skeleton.get_bone_count():
		result[skeleton.get_bone_name(bone_index)] = true
	return result


func _find_bind(skin: Skin, bone_name: StringName) -> int:
	if skin == null:
		return -1
	for bind_index: int in skin.get_bind_count():
		if skin.get_bind_name(bind_index) == bone_name:
			return bind_index
	return -1


func _skin_bind_names(skin: Skin) -> String:
	if skin == null:
		return "<none>"
	var names := PackedStringArray()
	for bind_index: int in skin.get_bind_count():
		names.append(String(skin.get_bind_name(bind_index)))
	return ",".join(names)


func _transform_identity_error(value: Transform3D) -> float:
	var maximum := value.origin.length()
	maximum = maxf(maximum, value.basis.x.distance_to(Vector3.RIGHT))
	maximum = maxf(maximum, value.basis.y.distance_to(Vector3.UP))
	maximum = maxf(maximum, value.basis.z.distance_to(Vector3.BACK))
	return maximum


func _write_report(stage: StringName) -> void:
	_report.append("TEST_STAGE=%s" % stage)
	var file := FileAccess.open(REPORT_PATH, FileAccess.WRITE)
	if file != null:
		file.store_string("\n".join(_report) + "\n")
