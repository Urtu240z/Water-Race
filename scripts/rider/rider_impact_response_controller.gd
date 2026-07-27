@tool
class_name RiderImpactResponseController
extends Node

@export_range(-1.0, 1.0, 0.01) var debug_preview_compression: float = 0.0:
	set(value):
		debug_preview_compression = clampf(value, -1.0, 1.0)
		_apply_preview()

@export var compression_handle_offset_degrees: float = -2.5:
	set(value):
		compression_handle_offset_degrees = value
		_apply_preview()

@export var extension_handle_offset_degrees: float = 2.0:
	set(value):
		extension_handle_offset_degrees = value
		_apply_preview()

@export_node_path("SkeletonModifier3D") var rider_impact_pose_path := NodePath(
	"../VisualRoot/RiderMount/RiderAssetRoot/RiderRig/"
	+ "RiderModelRoot/Rider_Bot/SKEL_Rider/Skeleton3D/RiderImpactPose"
)
@export_node_path("Node3D") var jet_ski_visual_controller_path := NodePath(
	"../VisualRoot/JetSkiVisual"
)

var _impact_pose: RiderImpactPoseModifier3D
var _visual_controller: JetSkiVisualController


func _ready() -> void:
	_resolve_targets()
	_apply_preview()


func _resolve_targets() -> void:
	_impact_pose = get_node_or_null(
		rider_impact_pose_path
	) as RiderImpactPoseModifier3D
	_visual_controller = get_node_or_null(
		jet_ski_visual_controller_path
	) as JetSkiVisualController


func _apply_preview() -> void:
	if not is_node_ready():
		return
	if (
		not is_instance_valid(_impact_pose)
		or not is_instance_valid(_visual_controller)
	):
		_resolve_targets()
	if is_instance_valid(_impact_pose):
		_impact_pose.impact_compression = debug_preview_compression
	if is_instance_valid(_visual_controller):
		_visual_controller.set_handle_impact_offset_degrees(
			_compression_to_handle_offset(debug_preview_compression)
		)


func _compression_to_handle_offset(compression: float) -> float:
	if compression >= 0.0:
		return compression * compression_handle_offset_degrees
	return -compression * extension_handle_offset_degrees
