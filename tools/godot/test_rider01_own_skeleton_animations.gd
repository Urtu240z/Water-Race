extends Node3D

const ANIMATIONS: Array[StringName] = [
	&"Mounted_Base",
	&"mounted_breathing",
	&"Mounted_Turn_Left",
	&"Mounted_Turn_Right",
	&"Mounted_Lean_Left",
	&"Mounted_Lean_Right",
	&"Mounted_Lean_Forward",
	&"Mounted_Lean_Back",
]

@export_file("*.txt") var report_path := (
	"res://assets/3D/Rider/skins/Rider01/runtime/"
	+ "Rider01_OwnSkeleton_Integration_Report.txt"
)
@export_dir var capture_directory := (
	"res://assets/3D/Rider/skins/Rider01/runtime/"
	+ "own_skeleton_animation_captures"
)
@export_file("*.glb") var source_glb := (
	"res://assets/3D/Rider/skins/Rider01/Rider01.glb"
)
@export_file("*.tscn") var rig_scene_path := (
	"res://scenes/rider/rider01_rig.tscn"
)
@export_range(1, 32, 1) var expected_skinned_mesh_count := 10
@export_node_path("Node3D") var rig_node_path := NodePath("Rider01Rig")

@onready var _rig = get_node(rig_node_path)
@onready var _camera: Camera3D = $Camera3D

var _player: AnimationPlayer
var _animation_tree: AnimationTree
var _skeleton: Skeleton3D
var _body_aabb := AABB()
var _report := PackedStringArray()


func _ready() -> void:
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
	DisplayServer.window_set_size(Vector2i(900, 900))
	await get_tree().process_frame
	_player = _rig.get_animation_player()
	_skeleton = _rig.get_skeleton()
	_animation_tree = _rig.get_node("AnimationTree") as AnimationTree
	_rig.set_mounted_pose_enabled(false)
	if not _prepare():
		_write_report("SETUP_FAILED")
		get_tree().quit(1)
		return
	await _run_animation_test()
	_write_report("ANIMATION_TEST_COMPLETED_VISUAL_REVIEW_REQUIRED")
	get_tree().quit(0)


func _prepare() -> bool:
	_report.append("=== RIDER01 OWN SKELETON ANIMATION TEST ===")
	_report.append("Rider scene: %s" % rig_scene_path)
	_report.append("Source GLB: %s" % source_glb)
	_report.append("Skeleton: %s" % _skeleton.get_path())
	_report.append("Skeleton bones: %d" % _skeleton.get_bone_count())
	var meshes := _collect_skinned_meshes(_rig)
	_report.append("Original skinned meshes: %d" % meshes.size())
	if meshes.size() != expected_skinned_mesh_count:
		_report.append(
			"FAIL: Expected %d skinned meshes, found %d."
			% [expected_skinned_mesh_count, meshes.size()]
		)
		return false
	var aabb_ready := false
	for mesh: MeshInstance3D in meshes:
		var world_aabb := mesh.global_transform * mesh.get_aabb()
		_body_aabb = world_aabb if not aabb_ready else _body_aabb.merge(world_aabb)
		aabb_ready = true
	for animation_name: StringName in ANIMATIONS:
		if not _player.has_animation(animation_name):
			_report.append("MISSING_ANIMATION=%s" % animation_name)
			return false
	_audit_animation_tracks()
	DirAccess.make_dir_recursive_absolute(
		ProjectSettings.globalize_path(capture_directory)
	)
	return true


func _audit_animation_tracks() -> void:
	_report.append("=== ANIMATION TRACK AUDIT ===")
	for animation_name: StringName in ANIMATIONS:
		var animation := _player.get_animation(animation_name)
		_report.append(
			"%s | length=%.6f | tracks=%d"
			% [
				animation_name,
				animation.length,
				animation.get_track_count(),
			]
		)
		var paths := PackedStringArray()
		for track_index: int in animation.get_track_count():
			paths.append(String(animation.track_get_path(track_index)))
		_report.append("  paths=%s" % ",".join(paths))


func _run_animation_test() -> void:
	for animation_name: StringName in ANIMATIONS:
		_rig.set_mounted_pose_enabled(false)
		_rig.set_breathing_enabled(false)
		_rig.reset_mounted_lean_blends()
		_skeleton.reset_bone_poses()
		_configure_animation_state(animation_name)
		_rig.set_mounted_pose_enabled(true)
		var sample_time := (
			3.0 if animation_name == &"mounted_breathing" else 0.5
		)
		_animation_tree.advance(sample_time)
		await get_tree().process_frame
		await RenderingServer.frame_post_draw
		_report.append(
			"ANIMATION_CAPTURED=%s | sample=%.6f"
			% [animation_name, sample_time]
		)
		await _capture_animation(animation_name)


func _configure_animation_state(animation_name: StringName) -> void:
	match animation_name:
		&"mounted_breathing":
			_rig.set_breathing_enabled(true)
		&"Mounted_Turn_Left":
			_rig.set_automatic_turn_blend(-1.0)
		&"Mounted_Turn_Right":
			_rig.set_automatic_turn_blend(1.0)
		&"Mounted_Lean_Left":
			_rig.set_manual_roll_blend(-1.0)
		&"Mounted_Lean_Right":
			_rig.set_manual_roll_blend(1.0)
		&"Mounted_Lean_Forward":
			_rig.set_manual_pitch_blend(-1.0)
		&"Mounted_Lean_Back":
			_rig.set_manual_pitch_blend(1.0)


func _capture_animation(animation_name: StringName) -> void:
	var center := _body_aabb.get_center()
	var body_size := maxf(
		_body_aabb.size.x,
		maxf(_body_aabb.size.y, _body_aabb.size.z)
	)
	var full_distance := maxf(body_size * 2.15, 3.2)
	var shoulder_center := _bone_pair_center(
		&"mixamorig_LeftShoulder",
		&"mixamorig_RightShoulder"
	)
	var hand_center := _bone_pair_center(
		&"mixamorig_LeftHand",
		&"mixamorig_RightHand"
	)
	var foot_center := _bone_pair_center(
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
			"name": "shoulders",
			"position": shoulder_center + Vector3(0.0, 0.0, 2.35),
			"target": shoulder_center,
			"fov": 31.0,
		},
		{
			"name": "hands",
			"position": hand_center + Vector3(0.0, 0.0, 2.75),
			"target": hand_center,
			"fov": 34.0,
		},
		{
			"name": "feet",
			"position": foot_center + Vector3(0.0, 0.0, 1.55),
			"target": foot_center,
			"fov": 28.0,
		},
	]
	for view: Dictionary in views:
		await _capture_view(animation_name, view)


func _capture_view(animation_name: StringName, view: Dictionary) -> void:
	_camera.global_position = view.position as Vector3
	_camera.fov = float(view.fov)
	_camera.look_at(view.target as Vector3, Vector3.UP)
	await get_tree().process_frame
	await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var image := get_viewport().get_texture().get_image()
	var animation_label := String(animation_name).to_snake_case()
	var output_path := (
		capture_directory
		+ "/"
		+ animation_label
		+ "_"
		+ String(view.name)
		+ ".png"
	)
	image.save_png(ProjectSettings.globalize_path(output_path))
	_report.append("CAPTURE=%s" % output_path)


func _bone_pair_center(left_name: StringName, right_name: StringName) -> Vector3:
	var left := _skeleton.find_bone(left_name)
	var right := _skeleton.find_bone(right_name)
	if left < 0 or right < 0:
		return _body_aabb.get_center()
	var left_position := (
		_skeleton.global_transform
		* _skeleton.get_bone_global_pose(left).origin
	)
	var right_position := (
		_skeleton.global_transform
		* _skeleton.get_bone_global_pose(right).origin
	)
	return (left_position + right_position) * 0.5


func _collect_skinned_meshes(root: Node) -> Array[MeshInstance3D]:
	var result: Array[MeshInstance3D] = []
	var pending: Array[Node] = [root]
	while not pending.is_empty():
		var current := pending.pop_back() as Node
		if current is MeshInstance3D:
			var mesh := current as MeshInstance3D
			if mesh.mesh != null and mesh.skin != null:
				result.append(mesh)
		for child: Node in current.get_children():
			pending.append(child)
	return result


func _write_report(stage: String) -> void:
	_report.append("TEST_STAGE=%s" % stage)
	var file := FileAccess.open(report_path, FileAccess.WRITE)
	if file != null:
		file.store_string("\n".join(_report) + "\n")
