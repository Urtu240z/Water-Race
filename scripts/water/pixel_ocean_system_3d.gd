@tool
class_name PixelOceanSystem3D
extends Node3D

@export_group("Targets")
@export_node_path("Node3D") var follow_target_path: NodePath
@export_node_path("Camera3D") var follow_camera_path: NodePath
@export_node_path("Node3D") var ripple_emitter_target_path: NodePath

@onready var physics: PixelOceanWater3D = $Physics as PixelOceanWater3D
@onready var surface: OceanClipmap3D = $Surface as OceanClipmap3D


func _ready() -> void:
	_resolve_targets()
	if Engine.is_editor_hint():
		update_configuration_warnings()


func _get_configuration_warnings() -> PackedStringArray:
	var warnings := PackedStringArray()
	if get_node_or_null("Physics") is not PixelOceanWater3D:
		warnings.append("PixelOceanSystem3D requires its PixelOceanWater3D Physics child.")
	if get_node_or_null("Surface") is not OceanClipmap3D:
		warnings.append("PixelOceanSystem3D requires its OceanClipmap3D Surface child.")
	if not Engine.is_editor_hint():
		return warnings
	if not follow_target_path.is_empty() and get_node_or_null(follow_target_path) == null:
		warnings.append("The configured follow target cannot be resolved.")
	if not follow_camera_path.is_empty() and get_node_or_null(follow_camera_path) == null:
		warnings.append("The configured follow camera cannot be resolved.")
	return warnings


func _resolve_targets() -> void:
	if physics == null or surface == null:
		return
	var target := get_node_or_null(follow_target_path) as Node3D
	var camera := get_node_or_null(follow_camera_path) as Camera3D
	var ripple_target := get_node_or_null(ripple_emitter_target_path) as Node3D
	surface.physical_water = physics
	surface.follow_target = target
	surface.follow_camera = camera
	physics.follow_target = camera
	physics.follow_target_path = NodePath()
	physics.configure_ripple_emitter(ripple_target if ripple_target != null else target)
