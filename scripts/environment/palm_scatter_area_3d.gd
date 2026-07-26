@tool
class_name PalmScatterArea3D
extends Node3D

## Deterministic palm placement for the editor and runtime. Generated content is
## always a child of this node, so it inherits the island's world-rebase transform.

enum PlacementMode {
	DECORATIVE_MULTIMESH,
	COLLIDABLE_SCENES,
}

const GENERATED_MULTIMESH_NAME := &"GeneratedMultiMesh"
const GENERATED_PALMS_NAME := &"GeneratedPalms"

@export_category("Placement")
@export var placement_mode: PlacementMode = PlacementMode.DECORATIVE_MULTIMESH
@export var palm_scene: PackedScene
@export var palm_mesh: Mesh
@export_range(0, 1000, 1) var amount: int = 8
@export var random_seed: int = 1
@export var area_size: Vector2 = Vector2(60.0, 50.0)
@export_range(0.1, 1000.0, 0.1, "suffix:m") var minimum_spacing: float = 8.0

@export_category("Terrain Query")
@export_range(0.1, 1000.0, 0.1, "suffix:m") var ray_start_height: float = 100.0
@export_range(0.1, 2000.0, 0.1, "suffix:m") var ray_depth: float = 250.0
@export_flags_3d_physics var terrain_collision_mask: int = 1
@export var terrain_group: StringName = &"island_terrain"
@export_range(0.0, 90.0, 0.1, "degrees") var maximum_slope_degrees: float = 35.0
@export var minimum_allowed_height: float = 2.05
@export var maximum_allowed_height: float = 100.0

@export_category("Variation")
@export_range(0.01, 10.0, 0.01) var minimum_scale: float = 0.75
@export_range(0.01, 10.0, 0.01) var maximum_scale: float = 1.25
@export var random_y_rotation: bool = true

@export_category("Rendering")
@export_range(0.0, 5000.0, 1.0, "suffix:m") var visibility_range_end: float = 250.0
@export var cast_shadows: bool = false

@export_category("Actions")
@export var generate_on_ready: bool = true

@export var regenerate_request: bool = false:
	set(value):
		regenerate_request = false
		if value:
			call_deferred("regenerate")

@export var clear_generated_request: bool = false:
	set(value):
		clear_generated_request = false
		if value:
			call_deferred("clear_generated")

var _last_generation_found_terrain := true
var _automatic_generation_pending := false


func _ready() -> void:
	if not generate_on_ready or _has_generated_content():
		return
	_automatic_generation_pending = true
	call_deferred("_generate_after_physics_sync")


func _generate_after_physics_sync() -> void:
	if not _automatic_generation_pending or not is_inside_tree():
		return
	await get_tree().physics_frame
	await get_tree().physics_frame
	if not is_inside_tree() or _has_generated_content():
		_automatic_generation_pending = false
		return
	_automatic_generation_pending = false
	regenerate()


func regenerate() -> void:
	if not is_inside_tree():
		return
	clear_generated()
	_last_generation_found_terrain = false
	if amount <= 0 or area_size.x <= 0.0 or area_size.y <= 0.0:
		update_configuration_warnings()
		return
	if minimum_scale > maximum_scale or minimum_spacing <= 0.0:
		update_configuration_warnings()
		return
	var mesh := _resolve_palm_mesh()
	if mesh == null:
		push_warning("PalmScatterArea3D needs palm_mesh or a MeshInstance3D in palm_scene.")
		update_configuration_warnings()
		return
	if placement_mode == PlacementMode.COLLIDABLE_SCENES and palm_scene == null:
		push_warning("Collidable palm placement requires palm_scene.")
		update_configuration_warnings()
		return

	var transforms := _sample_transforms()
	if transforms.is_empty():
		push_warning(
			"%s found no valid palm positions. Check its area, terrain mask, group and height."
			% name
		)
		update_configuration_warnings()
		return
	if placement_mode == PlacementMode.DECORATIVE_MULTIMESH:
		_create_multimesh(mesh, transforms)
	else:
		_create_collidable_palms(transforms)
	update_configuration_warnings()


func clear_generated() -> void:
	for child_name in [GENERATED_MULTIMESH_NAME, GENERATED_PALMS_NAME]:
		var child := get_node_or_null(NodePath(child_name))
		if child != null:
			remove_child(child)
			child.free()
	_last_generation_found_terrain = true
	update_configuration_warnings()


func _has_generated_content() -> bool:
	return (
		has_node(NodePath(GENERATED_MULTIMESH_NAME))
		or has_node(NodePath(GENERATED_PALMS_NAME))
	)


func _sample_transforms() -> Array[Transform3D]:
	var transforms: Array[Transform3D] = []
	var random := RandomNumberGenerator.new()
	random.seed = random_seed
	var space_state := get_world_3d().direct_space_state
	var maximum_slope_cosine := cos(deg_to_rad(maximum_slope_degrees))
	var attempts := maxi(amount * 100, 100)
	for _attempt in attempts:
		if transforms.size() >= amount:
			break
		var local_x := random.randf_range(-area_size.x * 0.5, area_size.x * 0.5)
		var local_z := random.randf_range(-area_size.y * 0.5, area_size.y * 0.5)
		var start := to_global(Vector3(local_x, ray_start_height, local_z))
		var end := to_global(Vector3(local_x, ray_start_height - ray_depth, local_z))
		var query := PhysicsRayQueryParameters3D.create(start, end, terrain_collision_mask)
		query.collide_with_areas = false
		query.collide_with_bodies = true
		var hit := space_state.intersect_ray(query)
		if hit.is_empty():
			continue
		var collider := hit.get("collider") as Node
		if collider == null or not _is_island_terrain(collider):
			continue
		_last_generation_found_terrain = true
		var hit_position := hit.get("position") as Vector3
		var normal := hit.get("normal") as Vector3
		if hit_position.y < minimum_allowed_height or hit_position.y > maximum_allowed_height:
			continue
		if normal.dot(Vector3.UP) < maximum_slope_cosine:
			continue
		if not _has_minimum_spacing(hit_position, transforms):
			continue
		var yaw_radians := random.randf_range(0.0, TAU) if random_y_rotation else 0.0
		var uniform_scale := random.randf_range(minimum_scale, maximum_scale)
		var palm_basis := Basis(Vector3.UP, yaw_radians).scaled(Vector3.ONE * uniform_scale)
		transforms.append(Transform3D(palm_basis, hit_position))
	return transforms


func _is_island_terrain(node: Node) -> bool:
	var current: Node = node
	while current != null:
		if current.is_in_group(terrain_group):
			return true
		current = current.get_parent()
	return false


func _has_minimum_spacing(candidate: Vector3, transforms: Array[Transform3D]) -> bool:
	var squared_spacing := minimum_spacing * minimum_spacing
	for palm_transform in transforms:
		var offset := palm_transform.origin - candidate
		offset.y = 0.0
		if offset.length_squared() < squared_spacing:
			return false
	return true


func _create_multimesh(mesh: Mesh, transforms: Array[Transform3D]) -> void:
	var multi_mesh := MultiMesh.new()
	multi_mesh.transform_format = MultiMesh.TRANSFORM_3D
	multi_mesh.mesh = mesh
	multi_mesh.instance_count = transforms.size()
	for index in transforms.size():
		multi_mesh.set_instance_transform(
			index,
			global_transform.affine_inverse() * transforms[index]
		)
	var instance := MultiMeshInstance3D.new()
	instance.name = GENERATED_MULTIMESH_NAME
	instance.multimesh = multi_mesh
	instance.cast_shadow = (
		GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		if cast_shadows
		else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	)
	instance.visibility_range_end = visibility_range_end
	_add_generated_child(instance)


func _create_collidable_palms(transforms: Array[Transform3D]) -> void:
	var container := Node3D.new()
	container.name = GENERATED_PALMS_NAME
	_add_generated_child(container)
	for index in transforms.size():
		var palm := palm_scene.instantiate() as Node3D
		palm.name = "Palm_%02d" % (index + 1)
		palm.transform = global_transform.affine_inverse() * transforms[index]
		container.add_child(palm)
		_set_scene_owner(palm)


func _resolve_palm_mesh() -> Mesh:
	if palm_mesh != null:
		return palm_mesh
	if palm_scene == null:
		return null
	var preview := palm_scene.instantiate()
	var mesh := _find_first_mesh(preview)
	preview.free()
	return mesh


func _find_first_mesh(node: Node) -> Mesh:
	if node is MeshInstance3D:
		var mesh_instance := node as MeshInstance3D
		if mesh_instance.mesh != null:
			return mesh_instance.mesh
	for child in node.get_children():
		var mesh := _find_first_mesh(child)
		if mesh != null:
			return mesh
	return null


func _add_generated_child(node: Node) -> void:
	add_child(node)
	_set_scene_owner(node)


func _set_scene_owner(node: Node) -> void:
	var edited_root := get_tree().edited_scene_root
	if edited_root != null:
		node.owner = edited_root


func _get_configuration_warnings() -> PackedStringArray:
	var warnings := PackedStringArray()
	if amount <= 0:
		warnings.append("Amount is zero; this area will not generate palms.")
	if area_size.x <= 0.0 or area_size.y <= 0.0:
		warnings.append("Area size must be greater than zero on both axes.")
	if minimum_scale > maximum_scale:
		warnings.append("Minimum scale must not exceed maximum scale.")
	if palm_scene == null:
		warnings.append("Assign PalmTree.tscn to palm_scene.")
	if palm_scene == null and palm_mesh == null:
		warnings.append("No palm mesh can be resolved for MultiMesh placement.")
	if placement_mode == PlacementMode.COLLIDABLE_SCENES and amount > 30:
		warnings.append("Collidable scenes above 30 can be expensive; use MultiMesh for distant palms.")
	if terrain_collision_mask == 0:
		warnings.append("Terrain collision mask is empty, so no terrain raycast can succeed.")
	if not _last_generation_found_terrain:
		warnings.append("The last generation found no valid terrain in this area. Check mask, group and height.")
	return warnings
