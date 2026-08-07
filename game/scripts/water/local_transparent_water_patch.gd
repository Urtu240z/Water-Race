@tool
class_name LocalTransparentWaterPatch
extends Node3D

@export var transparent_material: ShaderMaterial

@onready var _transparent_mesh: MeshInstance3D = (
	get_node_or_null("TransparentMesh") as MeshInstance3D
)

var patch_size: float = 16.0
var patch_subdivisions: int = 63

var grid_spacing: float:
	get:
		return patch_size / float(patch_subdivisions + 1)

var material_valid: bool:
	get:
		var material := get_transparent_material()
		return material != null and material.shader != null


func _ready() -> void:
	set_process(false)
	configure_geometry(patch_size, patch_subdivisions)


func configure_geometry(size_value: float, subdivisions_value: int) -> void:
	patch_size = clampf(size_value, 16.0, 128.0)
	patch_subdivisions = clampi(subdivisions_value, 15, 255)
	if patch_subdivisions % 2 == 0:
		patch_subdivisions = mini(patch_subdivisions + 1, 255)
	if _transparent_mesh == null:
		_transparent_mesh = get_node_or_null("TransparentMesh") as MeshInstance3D
	if _transparent_mesh == null:
		return
	var plane_mesh := _transparent_mesh.mesh as PlaneMesh
	if plane_mesh == null:
		return
	var expected_size := Vector2(patch_size, patch_size)
	if (
		not plane_mesh.size.is_equal_approx(expected_size)
		or plane_mesh.subdivide_width != patch_subdivisions
		or plane_mesh.subdivide_depth != patch_subdivisions
	):
		plane_mesh.size = expected_size
		plane_mesh.subdivide_width = patch_subdivisions
		plane_mesh.subdivide_depth = patch_subdivisions
	_transparent_mesh.custom_aabb = AABB(
		Vector3(-patch_size * 0.5, -4.0, -patch_size * 0.5),
		Vector3(patch_size, 8.0, patch_size)
	)


func set_patch_enabled(enabled: bool) -> void:
	visible = enabled


func set_center_xz(center_xz: Vector2, force_snap: bool = false) -> void:
	if not center_xz.is_finite():
		return
	var next_position := Vector3(center_xz.x, 0.0, center_xz.y)
	var previous_xz := Vector2(global_position.x, global_position.z)
	global_position = next_position
	if force_snap or previous_xz.distance_to(center_xz) > patch_size * 0.5:
		reset_physics_interpolation()
		if _transparent_mesh != null:
			_transparent_mesh.reset_physics_interpolation()


func get_transparent_material() -> ShaderMaterial:
	if transparent_material != null:
		return transparent_material
	if _transparent_mesh == null:
		_transparent_mesh = get_node_or_null("TransparentMesh") as MeshInstance3D
	return (
		_transparent_mesh.material_override as ShaderMaterial
		if _transparent_mesh != null
		else null
	)


func set_transparent_material(value: ShaderMaterial) -> void:
	transparent_material = value
	if _transparent_mesh == null:
		_transparent_mesh = get_node_or_null("TransparentMesh") as MeshInstance3D
	if _transparent_mesh != null:
		_transparent_mesh.material_override = value
