class_name RagdollVisualInterpolationModifier3D
extends SkeletonModifier3D

## PhysicalBoneSimulator3D updates the visible skeleton at the physics tick
## rate. At higher render rates that aliases against interpolated objects such
## as the JetSki and ChaseCamera. This modifier interpolates only the rendered
## skeleton pose between the two latest real physics poses.

@export_node_path("PhysicalBoneSimulator3D")
var simulator_path := NodePath("../PhysicalBoneSimulator3D")

var _simulator: PhysicalBoneSimulator3D
var _previous_physics_pose: Array[Transform3D] = []
var _current_physics_pose: Array[Transform3D] = []
var _history_initialized := false
var _capture_enabled := false
var _order_valid := false


func _ready() -> void:
	active = false
	_simulator = get_node_or_null(simulator_path) as PhysicalBoneSimulator3D
	if not is_instance_valid(_simulator):
		push_error(
			"RagdollVisualInterpolationModifier3D requires a "
			+ "PhysicalBoneSimulator3D sibling."
		)
		return
	_order_valid = _simulator.get_parent() == get_parent() and (
		_simulator.get_index() < get_index()
	)
	if not _order_valid:
		push_error(
			"RagdollVisualInterpolationModifier3D must be ordered after "
			+ "PhysicalBoneSimulator3D under the same Skeleton3D."
		)
		return
	_simulator.modification_processed.connect(_on_physical_pose_processed)


func begin_interpolation() -> void:
	if not _order_valid:
		return
	_capture_enabled = false
	_initialize_history_from_skeleton()
	_capture_enabled = _history_initialized
	active = _history_initialized


func end_interpolation() -> void:
	_capture_enabled = false
	active = false
	_clear_history()


func has_valid_modifier_order() -> bool:
	return _order_valid


func _on_physical_pose_processed() -> void:
	if not _capture_enabled:
		return
	var skeleton := get_skeleton()
	if skeleton == null:
		return
	var physical_pose := _capture_skeleton_pose(skeleton)
	if not _history_initialized:
		_set_initial_history(physical_pose)
		return
	if not _poses_differ(physical_pose, _current_physics_pose):
		return
	_previous_physics_pose = _current_physics_pose.duplicate()
	_current_physics_pose = physical_pose


func _process_modification() -> void:
	if not _capture_enabled or not _history_initialized:
		return
	var skeleton := get_skeleton()
	if skeleton == null:
		return
	var bone_count := mini(
		skeleton.get_bone_count(),
		mini(_previous_physics_pose.size(), _current_physics_pose.size())
	)
	var alpha := clampf(Engine.get_physics_interpolation_fraction(), 0.0, 1.0)
	for bone_index: int in bone_count:
		var visual_pose := _previous_physics_pose[bone_index].interpolate_with(
			_current_physics_pose[bone_index],
			alpha
		)
		skeleton.set_bone_global_pose(bone_index, visual_pose)


func _initialize_history_from_skeleton() -> void:
	_clear_history()
	var skeleton := get_skeleton()
	if skeleton == null:
		return
	_set_initial_history(_capture_skeleton_pose(skeleton))


func _set_initial_history(pose: Array[Transform3D]) -> void:
	if pose.is_empty():
		return
	_previous_physics_pose = pose.duplicate()
	_current_physics_pose = pose.duplicate()
	_history_initialized = true


func _capture_skeleton_pose(skeleton: Skeleton3D) -> Array[Transform3D]:
	var pose: Array[Transform3D] = []
	pose.resize(skeleton.get_bone_count())
	for bone_index: int in skeleton.get_bone_count():
		pose[bone_index] = skeleton.get_bone_global_pose(bone_index)
	return pose


func _poses_differ(
	first: Array[Transform3D],
	second: Array[Transform3D]
) -> bool:
	if first.size() != second.size():
		return true
	for bone_index: int in first.size():
		if not first[bone_index].is_equal_approx(second[bone_index]):
			return true
	return false


func _clear_history() -> void:
	_previous_physics_pose.clear()
	_current_physics_pose.clear()
	_history_initialized = false
