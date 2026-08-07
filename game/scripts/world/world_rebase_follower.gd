class_name WorldRebaseFollower
extends Node3D

## Keeps static level content in the same local coordinate frame as the vehicle.
## Attach this to a level-content root that must follow WorldOriginController rebases.

@export_node_path("Node") var world_origin_controller_path: NodePath

var _world_origin: WorldOriginController


func _ready() -> void:
	_world_origin = get_node_or_null(world_origin_controller_path) as WorldOriginController
	if _world_origin == null:
		push_warning("WorldRebaseFollower requires a valid WorldOriginController.")
		return
	if not _world_origin.world_rebased.is_connected(_on_world_rebased):
		_world_origin.world_rebased.connect(_on_world_rebased)


func _on_world_rebased(shift: Vector3) -> void:
	if not shift.is_finite():
		return
	global_position -= Vector3(shift.x, 0.0, shift.z)
	reset_physics_interpolation()
