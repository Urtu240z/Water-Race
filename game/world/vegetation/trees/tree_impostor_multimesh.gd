@tool
extends MultiMeshInstance3D


# ============================================================
# BAKED MULTIMESH
# ============================================================

const BAKED_DIRECTORY: String = (
	"res://world/vegetation/trees/baked"
)

const BAKE_VERSION: int = 1


# ============================================================
# DISTRIBUTION
# ============================================================

@export_group("Distribution")

@export_range(1, 5000, 1)
var target_count: int = 625

# X = Z -> círculo
# X != Z -> elipse
@export_range(5.0, 1000.0, 1.0)
var area_radius_x: float = 100.0

@export_range(5.0, 1000.0, 1.0)
var area_radius_z: float = 80.0

@export_range(0.5, 50.0, 0.1)
var min_spacing: float = 4.0

@export_range(0.5, 50.0, 0.1)
var max_spacing: float = 8.0

@export_range(4, 64, 1)
var poisson_attempts_per_point: int = 24

@export_range(1.0, 5.0, 0.1)
var candidate_pool_multiplier: float = 2.0

@export var random_seed: int = 12345


# ============================================================
# TREE SCALE
# ============================================================

@export_group("Tree Scale")

@export_range(0.10, 15.0, 0.05)
var min_scale: float = 2.0

@export_range(0.10, 15.0, 0.05)
var max_scale: float = 7.5

@export_range(0.0, 100.0, 1.0)
var center_scale_bias_percent: float = 65.0


# ============================================================
# GROUND PLACEMENT
# ============================================================

@export_group("Ground Placement")

@export var snap_to_ground: bool = true

@export_range(1.0, 500.0, 1.0)
var ray_above_height: float = 100.0

@export_range(1.0, 1000.0, 1.0)
var ray_below_depth: float = 300.0

@export_flags_3d_physics
var ground_collision_mask: int = 0xFFFFFFFF

@export var valid_ground_name_contains: PackedStringArray = (
	PackedStringArray([
		"Terrain_Master_COL"
	])
)


# ============================================================
# SLOPE FILTER
# ============================================================

@export_group("Slope Filter")

@export var reject_steep_slopes: bool = true

@export_range(0.0, 89.0, 1.0)
var max_ground_slope_degrees: float = 40.0


# ============================================================
# VISUAL GEOMETRY EXCLUSION
# ============================================================

@export_group("Visual Geometry Exclusion")

@export var avoid_visual_geometry: bool = true

@export var visual_exclusion_roots: Array[NodePath] = []

@export_range(0.10, 1.50, 0.05)
var visual_radius_factor: float = 0.80

@export_range(0.0, 10.0, 0.1)
var visual_extra_clearance: float = 1.0


# ============================================================
# WATER EXCLUSION
# ============================================================

@export_group("Water Exclusion")

@export var avoid_water: bool = true

@export var water_provider_path: NodePath

@export_range(0.0, 20.0, 0.1)
var minimum_height_above_water: float = 1.0


# ============================================================
# BAKED RUNTIME
# ============================================================

@export_group("Baked Runtime")

# Si no existe un bake o está desactualizado,
# el editor lo genera automáticamente.
#
# RUNTIME NUNCA genera árboles.
@export var auto_bake_if_missing_or_stale_in_editor: bool = true


# ============================================================
# EDITOR
# ============================================================

@export_group("Editor")

@export_tool_button("Regenerate + Bake")
var regenerate = _generate


# ============================================================
# READY
# ============================================================

func _ready() -> void:

	# --------------------------------------------------------
	# EDITOR
	# --------------------------------------------------------

	if Engine.is_editor_hint():

		var bake_loaded: bool = (
			_load_baked_multimesh(
				true
			)
		)


		if bake_loaded:
			return


		if auto_bake_if_missing_or_stale_in_editor:

			call_deferred(
				"_generate"
			)


		return


	# --------------------------------------------------------
	# RUNTIME
	# --------------------------------------------------------

	var runtime_bake_loaded: bool = (
		_load_baked_multimesh(
			false
		)
	)


	if runtime_bake_loaded:
		return


	visible = false


	push_error(
		"Missing baked tree MultiMesh: "
		+ _get_baked_multimesh_path()
		+ "\nOpen Paradise Island in the editor "
		+ "and use Regenerate Forest."
	)


# ============================================================
# GENERATE + BAKE
# ============================================================

func _generate() -> void:

	# --------------------------------------------------------
	# GENERATION IS EDITOR-ONLY
	# --------------------------------------------------------

	if not Engine.is_editor_hint():

		push_error(
			"Tree generation is editor-only. "
			+ "Runtime must use the baked MultiMesh."
		)

		return


	if multimesh == null:
		return


	if (
		snap_to_ground
		and not is_inside_tree()
	):

		push_warning(
			"Tree MultiMesh must be inside the scene tree "
			+ "to query the ground."
		)

		return


	# --------------------------------------------------------
	# PHYSICS
	# --------------------------------------------------------

	var space_state: PhysicsDirectSpaceState3D = null


	if snap_to_ground:

		space_state = (
			get_world_3d()
				.direct_space_state
		)


	# --------------------------------------------------------
	# WATER PROVIDER
	# --------------------------------------------------------

	var water_provider: WaterSurfaceProvider3D = null


	if avoid_water:

		water_provider = (
			_resolve_water_provider()
		)


		if water_provider == null:

			push_warning(
				"Water exclusion enabled but no "
				+ "WaterSurfaceProvider3D was found."
			)


	# --------------------------------------------------------
	# VISUAL BLOCKERS
	# --------------------------------------------------------

	var visual_blocker_aabbs: Array[AABB] = []


	if avoid_visual_geometry:

		visual_blocker_aabbs = (
			_build_visual_blocker_aabbs()
		)


	# --------------------------------------------------------
	# SAFE SETTINGS
	# --------------------------------------------------------

	var safe_min_spacing: float = minf(
		min_spacing,
		max_spacing
	)

	var safe_max_spacing: float = maxf(
		min_spacing,
		max_spacing
	)

	var safe_min_scale: float = minf(
		min_scale,
		max_scale
	)

	var safe_max_scale: float = maxf(
		min_scale,
		max_scale
	)

	var safe_radius_x: float = maxf(
		area_radius_x,
		0.1
	)

	var safe_radius_z: float = maxf(
		area_radius_z,
		0.1
	)


	# --------------------------------------------------------
	# RNG
	# --------------------------------------------------------

	var rng: RandomNumberGenerator = (
		RandomNumberGenerator.new()
	)

	rng.seed = random_seed


	# --------------------------------------------------------
	# CANDIDATE POOL
	# --------------------------------------------------------

	var candidate_pool_target: int = maxi(
		target_count,
		int(
			ceil(
				float(target_count)
				* candidate_pool_multiplier
			)
		)
	)


	var poisson_positions: Array[Vector2] = (
		_generate_poisson_positions(
			candidate_pool_target,
			safe_radius_x,
			safe_radius_z,
			safe_min_spacing,
			safe_max_spacing,
			poisson_attempts_per_point,
			rng
		)
	)


	# --------------------------------------------------------
	# MULTIMESH
	# --------------------------------------------------------

	multimesh.instance_count = 0

	multimesh.use_custom_data = true

	multimesh.instance_count = (
		target_count
	)

	multimesh.visible_instance_count = 0


	# --------------------------------------------------------
	# COUNTERS
	# --------------------------------------------------------

	var instance_index: int = 0

	var rejected_no_ground: int = 0
	var rejected_invalid_ground: int = 0
	var rejected_steep_slope: int = 0
	var rejected_visual_geometry: int = 0
	var rejected_water: int = 0


	# ========================================================
	# CANDIDATES
	# ========================================================

	for point: Vector2 in poisson_positions:

		if instance_index >= target_count:
			break


		# ====================================================
		# SCALE
		# ====================================================

		var radial_ratio: float = (
			_get_ellipse_radius_ratio(
				point,
				safe_radius_x,
				safe_radius_z
			)
		)


		var center_bias: float = clampf(
			center_scale_bias_percent
				/ 100.0,
			0.0,
			1.0
		)


		var random_t: float = (
			rng.randf()
		)


		var final_t: float = lerpf(
			random_t,
			radial_ratio,
			center_bias
		)


		var scale_variation: float = lerpf(
			safe_max_scale,
			safe_min_scale,
			final_t
		)


		# ====================================================
		# BASE POSITION
		# ====================================================

		var local_x: float = point.x
		var local_z: float = point.y

		var ground_y: float = 0.0


		var ground_position_global: Vector3 = (
			to_global(
				Vector3(
					local_x,
					0.0,
					local_z
				)
			)
		)


		# ====================================================
		# GROUND RAYCAST
		# ====================================================

		if snap_to_ground:

			var ray_from: Vector3 = (
				ground_position_global
				+ Vector3.UP
				* ray_above_height
			)


			var ray_to: Vector3 = (
				ground_position_global
				- Vector3.UP
				* ray_below_depth
			)


			var query: PhysicsRayQueryParameters3D = (
				PhysicsRayQueryParameters3D.create(
					ray_from,
					ray_to,
					ground_collision_mask
				)
			)


			query.collide_with_bodies = true
			query.collide_with_areas = false


			var hit: Dictionary = (
				space_state.intersect_ray(
					query
				)
			)


			# ------------------------------------------------
			# NO GROUND
			# ------------------------------------------------

			if hit.is_empty():

				rejected_no_ground += 1

				continue


			# ------------------------------------------------
			# VALID GROUND
			# ------------------------------------------------

			var ground_collider: Object = (
				hit["collider"]
			)


			if not _is_valid_ground_collider(
				ground_collider
			):

				rejected_invalid_ground += 1

				continue


			# ------------------------------------------------
			# SLOPE
			# ------------------------------------------------

			if reject_steep_slopes:

				var ground_normal: Vector3 = (
					hit["normal"]
				)


				if (
					ground_normal.length_squared()
					<= 0.000001
				):

					rejected_steep_slope += 1

					continue


				ground_normal = (
					ground_normal.normalized()
				)


				var up_dot: float = clampf(
					ground_normal.dot(
						Vector3.UP
					),
					-1.0,
					1.0
				)


				var slope_radians: float = (
					acos(
						up_dot
					)
				)


				var slope_degrees: float = (
					rad_to_deg(
						slope_radians
					)
				)


				if (
					slope_degrees
					> max_ground_slope_degrees
				):

					rejected_steep_slope += 1

					continue


			# ------------------------------------------------
			# FINAL GROUND POSITION
			# ------------------------------------------------

			ground_position_global = (
				hit["position"]
			)


			var ground_position_local: Vector3 = (
				to_local(
					ground_position_global
				)
			)


			ground_y = (
				ground_position_local.y
			)


		# ====================================================
		# WATER
		# ====================================================

		if (
			avoid_water
			and water_provider != null
		):

			var water_sample: WaterSample3D = (
				water_provider.sample_water(
					ground_position_global
				)
			)


			if water_sample.valid:

				var height_above_water: float = (
					ground_position_global.y
					- water_sample
						.surface_position.y
				)


				if (
					height_above_water
					<= minimum_height_above_water
				):

					rejected_water += 1

					continue


		# ====================================================
		# VISUAL GEOMETRY
		# ====================================================

		if (
			avoid_visual_geometry
			and _intersects_visual_geometry(
				ground_position_global,
				scale_variation,
				visual_blocker_aabbs
			)
		):

			rejected_visual_geometry += 1

			continue


		# ====================================================
		# INSTANCE
		# ====================================================

		var instance_position: Vector3 = Vector3(
			local_x,
			ground_y
				+ scale_variation,
			local_z
		)


		var instance_basis: Basis = (
			Basis.IDENTITY.scaled(
				Vector3(
					scale_variation,
					scale_variation,
					scale_variation
				)
			)
		)


		var instance_transform: Transform3D = (
			Transform3D(
				instance_basis,
				instance_position
			)
		)


		multimesh.set_instance_transform(
			instance_index,
			instance_transform
		)


		# ====================================================
		# LEAF COLOR VARIATION
		# ====================================================

		var leaf_variation: float = (
			rng.randf()
		)


		multimesh.set_instance_custom_data(
			instance_index,
			Color(
				leaf_variation,
				0.0,
				0.0,
				1.0
			)
		)


		instance_index += 1


	# ========================================================
	# FINALIZE
	# ========================================================

	multimesh.visible_instance_count = (
		instance_index
	)


	multimesh.emit_changed()


	_sync_shadow_multimesh()


	var bake_saved: bool = (
		_save_baked_multimesh()
	)


	if not bake_saved:

		push_error(
			"Tree scatter generated but the "
			+ "baked MultiMesh could not be saved."
		)


	print(
		"Tree scatter | placed: ",
		instance_index,
		" / ",
		target_count,
		" | poisson candidates: ",
		poisson_positions.size(),
		" | no ground: ",
		rejected_no_ground,
		" | invalid ground: ",
		rejected_invalid_ground,
		" | steep slope: ",
		rejected_steep_slope,
		" | visual geometry: ",
		rejected_visual_geometry,
		" | water: ",
		rejected_water,
		" | visual blockers: ",
		visual_blocker_aabbs.size()
	)


# ============================================================
# BAKED MULTIMESH - SAVE
# ============================================================

func _save_baked_multimesh() -> bool:

	if not Engine.is_editor_hint():
		return false


	if multimesh == null:
		return false


	var absolute_directory: String = (
		ProjectSettings.globalize_path(
			BAKED_DIRECTORY
		)
	)


	var directory_error: Error = (
		DirAccess.make_dir_recursive_absolute(
			absolute_directory
		)
	)


	if directory_error != OK:

		push_error(
			"Could not create tree bake directory: "
			+ absolute_directory
			+ " | Error: "
			+ str(
				directory_error
			)
		)

		return false


	var duplicated_resource: Resource = (
		multimesh.duplicate(
			true
		)
	)


	if not duplicated_resource is MultiMesh:

		push_error(
			"Could not duplicate generated MultiMesh."
		)

		return false


	var baked_multimesh: MultiMesh = (
		duplicated_resource
			as MultiMesh
	)


	# La geometría viene siempre de la escena base.
	#
	# El .res solo guarda:
	# - transforms
	# - custom data
	# - counts
	# - buffer
	#
	# Así evitamos duplicar QuadMesh/materiales
	# en cada bosque.

	baked_multimesh.resource_local_to_scene = false


	baked_multimesh.set_meta(
		"tree_bake_version",
		BAKE_VERSION
	)


	baked_multimesh.set_meta(
		"tree_bake_signature",
		_build_bake_signature()
	)


	baked_multimesh.set_meta(
		"tree_bake_source",
		_get_scene_relative_path_string()
	)


	var baked_path: String = (
		_get_baked_multimesh_path()
	)


	var save_error: Error = (
		ResourceSaver.save(
			baked_multimesh,
			baked_path
		)
	)


	if save_error != OK:

		push_error(
			"Could not save baked tree MultiMesh: "
			+ baked_path
			+ " | Error: "
			+ str(
				save_error
			)
		)

		return false


	print(
		"Tree bake saved: ",
		baked_path,
		" | visible instances: ",
		multimesh.visible_instance_count
	)


	return true


# ============================================================
# BAKED MULTIMESH - LOAD
# ============================================================

func _load_baked_multimesh(
	require_matching_signature: bool
) -> bool:

	if multimesh == null:
		return false


	var baked_path: String = (
		_get_baked_multimesh_path()
	)


	if not ResourceLoader.exists(
		baked_path
	):
		return false


	var loaded_resource: Resource = (
		ResourceLoader.load(
			baked_path
		)
	)


	if not loaded_resource is MultiMesh:

		push_warning(
			"Invalid tree bake resource: "
			+ baked_path
		)

		return false


	var loaded_multimesh: MultiMesh = (
		loaded_resource
			as MultiMesh
	)


	# --------------------------------------------------------
	# EDITOR STALE CHECK
	# --------------------------------------------------------

	if require_matching_signature:

		var saved_signature: String = String(
			loaded_multimesh.get_meta(
				"tree_bake_signature",
				""
			)
		)


		var current_signature: String = (
			_build_bake_signature()
		)


		if (
			saved_signature
			!= current_signature
		):

			print(
				"Tree bake stale, regenerating: ",
				baked_path
			)

			return false


	# --------------------------------------------------------
	# KEEP CURRENT TEMPLATE MESH
	# --------------------------------------------------------

	var template_mesh: Mesh = (
		multimesh.mesh
	)


	if template_mesh == null:

		push_warning(
			"Tree MultiMesh template has no mesh: "
			+ String(
				get_path()
			)
		)

		return false


	# Never modify the cached .res directly.
	var live_resource: Resource = (
		loaded_multimesh.duplicate(
			true
		)
	)


	if not live_resource is MultiMesh:
		return false


	var live_multimesh: MultiMesh = (
		live_resource
			as MultiMesh
	)


	live_multimesh.mesh = (
		template_mesh
	)


	live_multimesh.resource_local_to_scene = (
		true
	)


	multimesh = (
		live_multimesh
	)


	_sync_shadow_multimesh()


	return true


# ============================================================
# BAKE PATH
# ============================================================

func _get_baked_multimesh_path() -> String:

	var scene_root: Node = (
		_get_cache_scene_root()
	)


	var scene_name: String = (
		"scene"
	)


	if (
		scene_root != null
		and not scene_root.scene_file_path.is_empty()
	):

		scene_name = (
			scene_root.scene_file_path
				.get_file()
				.get_basename()
		)


	elif scene_root != null:

		scene_name = String(
			scene_root.name
		)


	var relative_path: String = (
		_get_scene_relative_path_string()
	)


	var safe_scene_name: String = (
		_sanitize_cache_key(
			scene_name
		)
	)


	var safe_relative_path: String = (
		_sanitize_cache_key(
			relative_path
		)
	)


	var file_name: String = (
		safe_scene_name
		+ "__"
		+ safe_relative_path
		+ ".res"
	)


	return (
		BAKED_DIRECTORY.path_join(
			file_name
		)
	)


func _get_cache_scene_root() -> Node:

	if Engine.is_editor_hint():

		var edited_scene_root: Node = (
			EditorInterface
				.get_edited_scene_root()
		)


		if edited_scene_root != null:
			return edited_scene_root


	if get_tree() != null:

		var current_scene: Node = (
			get_tree().current_scene
		)


		if current_scene != null:
			return current_scene


	var top_node: Node = self


	while (
		top_node.get_parent() != null
		and get_tree() != null
		and top_node.get_parent()
			!= get_tree().root
	):

		top_node = (
			top_node.get_parent()
		)


	return top_node


func _get_scene_relative_path_string() -> String:

	var scene_root: Node = (
		_get_cache_scene_root()
	)


	if scene_root == null:

		return String(
			name
		)


	if scene_root == self:

		return String(
			name
		)


	return String(
		scene_root.get_path_to(
			self
		)
	)


func _sanitize_cache_key(
	source_text: String
) -> String:

	var safe_text: String = (
		source_text
	)


	safe_text = safe_text.replace(
		"\\",
		"__"
	)

	safe_text = safe_text.replace(
		"/",
		"__"
	)

	safe_text = safe_text.replace(
		":",
		"_"
	)

	safe_text = safe_text.replace(
		"@",
		"_"
	)

	safe_text = safe_text.replace(
		" ",
		"_"
	)


	return (
		safe_text.to_lower()
	)


# ============================================================
# BAKE SIGNATURE
# ============================================================

func _build_bake_signature() -> String:

	var signature: String = (
		"version="
		+ str(
			BAKE_VERSION
		)
	)


	signature += (
		"|node="
		+ _get_scene_relative_path_string()
	)


	signature += (
		"|global_transform="
		+ str(
			global_transform
		)
	)


	signature += (
		"|target_count="
		+ str(
			target_count
		)
	)


	signature += (
		"|radius_x="
		+ str(
			area_radius_x
		)
	)


	signature += (
		"|radius_z="
		+ str(
			area_radius_z
		)
	)


	signature += (
		"|min_spacing="
		+ str(
			min_spacing
		)
	)


	signature += (
		"|max_spacing="
		+ str(
			max_spacing
		)
	)


	signature += (
		"|poisson_attempts="
		+ str(
			poisson_attempts_per_point
		)
	)


	signature += (
		"|candidate_multiplier="
		+ str(
			candidate_pool_multiplier
		)
	)


	signature += (
		"|seed="
		+ str(
			random_seed
		)
	)


	signature += (
		"|min_scale="
		+ str(
			min_scale
		)
	)


	signature += (
		"|max_scale="
		+ str(
			max_scale
		)
	)


	signature += (
		"|center_bias="
		+ str(
			center_scale_bias_percent
		)
	)


	signature += (
		"|snap="
		+ str(
			snap_to_ground
		)
	)


	signature += (
		"|ray_above="
		+ str(
			ray_above_height
		)
	)


	signature += (
		"|ray_below="
		+ str(
			ray_below_depth
		)
	)


	signature += (
		"|collision_mask="
		+ str(
			ground_collision_mask
		)
	)


	signature += (
		"|valid_ground="
		+ str(
			valid_ground_name_contains
		)
	)


	signature += (
		"|reject_slope="
		+ str(
			reject_steep_slopes
		)
	)


	signature += (
		"|max_slope="
		+ str(
			max_ground_slope_degrees
		)
	)


	signature += (
		"|avoid_visual="
		+ str(
			avoid_visual_geometry
		)
	)


	signature += (
		"|visual_roots="
		+ str(
			visual_exclusion_roots
		)
	)


	signature += (
		"|visual_radius="
		+ str(
			visual_radius_factor
		)
	)


	signature += (
		"|visual_clearance="
		+ str(
			visual_extra_clearance
		)
	)


	signature += (
		"|avoid_water="
		+ str(
			avoid_water
		)
	)


	signature += (
		"|water_path="
		+ str(
			water_provider_path
		)
	)


	signature += (
		"|water_height="
		+ str(
			minimum_height_above_water
		)
	)


	if (
		multimesh != null
		and multimesh.mesh != null
	):

		signature += (
			"|mesh_aabb="
			+ str(
				multimesh.mesh.get_aabb()
			)
		)


	return signature


# ============================================================
# TREE SHADOW MULTIMESH
# ============================================================

func _sync_shadow_multimesh() -> void:

	var parent_node: Node = (
		get_parent()
	)


	if parent_node == null:
		return


	var shadow_node: Node = (
		parent_node.get_node_or_null(
			"TreeShadows"
		)
	)


	if not shadow_node is MultiMeshInstance3D:
		return


	var tree_shadows: MultiMeshInstance3D = (
		shadow_node
			as MultiMeshInstance3D
	)


	tree_shadows.multimesh = (
		multimesh
	)


# ============================================================
# VALID GROUND
# ============================================================

func _is_valid_ground_collider(
	collider: Object
) -> bool:

	if valid_ground_name_contains.is_empty():
		return true


	if not collider is Node:
		return false


	var collider_node: Node = (
		collider
			as Node
	)


	var collider_name: String = String(
		collider_node.name
	)


	for filter_text: String in valid_ground_name_contains:

		if filter_text.is_empty():
			continue


		if collider_name.contains(
			filter_text
		):
			return true


	return false


# ============================================================
# VISUAL BLOCKERS
# ============================================================

func _build_visual_blocker_aabbs() -> Array[AABB]:

	var blocker_aabbs: Array[AABB] = []


	for root_path: NodePath in visual_exclusion_roots:

		if root_path == NodePath(""):
			continue


		var root_node: Node = (
			get_node_or_null(
				root_path
			)
		)


		if root_node == null:

			push_warning(
				"Visual exclusion root not found: "
				+ String(
					root_path
				)
			)

			continue


		_collect_visual_blockers(
			root_node,
			blocker_aabbs
		)


	return blocker_aabbs


func _collect_visual_blockers(
	node: Node,
	blocker_aabbs: Array[AABB]
) -> void:

	if node is MeshInstance3D:

		var mesh_instance: MeshInstance3D = (
			node
				as MeshInstance3D
		)


		if mesh_instance.mesh != null:

			var world_aabb: AABB = (
				_get_world_aabb(
					mesh_instance
				)
			)


			if (
				world_aabb.size.x > 0.0001
				or world_aabb.size.y > 0.0001
				or world_aabb.size.z > 0.0001
			):

				blocker_aabbs.append(
					world_aabb
				)


	for child: Node in node.get_children():

		_collect_visual_blockers(
			child,
			blocker_aabbs
		)


# ============================================================
# LOCAL AABB -> WORLD AABB
# ============================================================

func _get_world_aabb(
	mesh_instance: MeshInstance3D
) -> AABB:

	var local_aabb: AABB = (
		mesh_instance.get_aabb()
	)


	var local_min: Vector3 = (
		local_aabb.position
	)


	var local_max: Vector3 = (
		local_aabb.position
		+ local_aabb.size
	)


	var corners: PackedVector3Array = PackedVector3Array([
		Vector3(
			local_min.x,
			local_min.y,
			local_min.z
		),
		Vector3(
			local_max.x,
			local_min.y,
			local_min.z
		),
		Vector3(
			local_min.x,
			local_max.y,
			local_min.z
		),
		Vector3(
			local_max.x,
			local_max.y,
			local_min.z
		),

		Vector3(
			local_min.x,
			local_min.y,
			local_max.z
		),
		Vector3(
			local_max.x,
			local_min.y,
			local_max.z
		),
		Vector3(
			local_min.x,
			local_max.y,
			local_max.z
		),
		Vector3(
			local_max.x,
			local_max.y,
			local_max.z
		)
	])


	var first_world_corner: Vector3 = (
		mesh_instance.global_transform
		* corners[0]
	)


	var world_min: Vector3 = (
		first_world_corner
	)

	var world_max: Vector3 = (
		first_world_corner
	)


	for corner_index: int in range(
		1,
		corners.size()
	):

		var world_corner: Vector3 = (
			mesh_instance.global_transform
			* corners[
				corner_index
			]
		)


		world_min = Vector3(
			minf(
				world_min.x,
				world_corner.x
			),
			minf(
				world_min.y,
				world_corner.y
			),
			minf(
				world_min.z,
				world_corner.z
			)
		)


		world_max = Vector3(
			maxf(
				world_max.x,
				world_corner.x
			),
			maxf(
				world_max.y,
				world_corner.y
			),
			maxf(
				world_max.z,
				world_corner.z
			)
		)


	return AABB(
		world_min,
		world_max
			- world_min
	)


# ============================================================
# TREE vs VISUAL GEOMETRY
# ============================================================

func _intersects_visual_geometry(
	ground_position_global: Vector3,
	scale_variation: float,
	blocker_aabbs: Array[AABB]
) -> bool:

	if blocker_aabbs.is_empty():
		return false


	var tree_height: float = maxf(
		2.0
			* scale_variation,
		0.1
	)


	var tree_half_width: float = maxf(
		scale_variation
			* visual_radius_factor
			+ visual_extra_clearance,
		0.05
	)


	var tree_aabb: AABB = AABB(
		Vector3(
			ground_position_global.x
				- tree_half_width,

			ground_position_global.y,

			ground_position_global.z
				- tree_half_width
		),

		Vector3(
			tree_half_width
				* 2.0,

			tree_height,

			tree_half_width
				* 2.0
		)
	)


	for blocker_aabb: AABB in blocker_aabbs:

		if tree_aabb.intersects(
			blocker_aabb
		):
			return true


	return false


# ============================================================
# WATER PROVIDER
# ============================================================

func _resolve_water_provider() -> WaterSurfaceProvider3D:

	# --------------------------------------------------------
	# EXPLICIT
	# --------------------------------------------------------

	if water_provider_path != NodePath(""):

		var explicit_node: Node = (
			get_node_or_null(
				water_provider_path
			)
		)


		if explicit_node is WaterSurfaceProvider3D:

			return (
				explicit_node
					as WaterSurfaceProvider3D
			)


	# --------------------------------------------------------
	# AUTO
	# --------------------------------------------------------

	if is_inside_tree():

		var grouped_node: Node = (
			get_tree()
				.get_first_node_in_group(
					"graphics_quality_ocean"
				)
		)


		if grouped_node is WaterSurfaceProvider3D:

			return (
				grouped_node
					as WaterSurfaceProvider3D
			)


	return null


# ============================================================
# POISSON
# ============================================================

func _generate_poisson_positions(
	wanted_count: int,
	radius_x: float,
	radius_z: float,
	spacing_min: float,
	spacing_max: float,
	attempts_per_point: int,
	rng: RandomNumberGenerator
) -> Array[Vector2]:

	var points: Array[Vector2] = []
	var active_points: Array[Vector2] = []


	if wanted_count <= 0:
		return points


	var safe_radius_x: float = maxf(
		radius_x,
		0.1
	)

	var safe_radius_z: float = maxf(
		radius_z,
		0.1
	)

	var safe_min_distance: float = maxf(
		spacing_min,
		0.01
	)

	var safe_max_distance: float = maxf(
		spacing_max,
		safe_min_distance
	)


	var minimum_distance_squared: float = (
		safe_min_distance
		* safe_min_distance
	)


	# --------------------------------------------------------
	# FIRST POINT
	# --------------------------------------------------------

	var first_point: Vector2 = (
		_random_point_in_ellipse(
			safe_radius_x,
			safe_radius_z,
			rng
		)
	)


	points.append(
		first_point
	)

	active_points.append(
		first_point
	)


	# --------------------------------------------------------
	# BRIDSON STYLE POISSON
	# --------------------------------------------------------

	while (
		not active_points.is_empty()
		and points.size()
			< wanted_count
	):

		var active_index: int = (
			rng.randi_range(
				0,
				active_points.size()
					- 1
			)
		)


		var origin: Vector2 = (
			active_points[
				active_index
			]
		)


		var found_candidate: bool = false


		for _attempt: int in range(
			attempts_per_point
		):

			var angle: float = (
				rng.randf_range(
					0.0,
					TAU
				)
			)


			var candidate_distance: float = (
				rng.randf_range(
					safe_min_distance,
					safe_max_distance
				)
			)


			var candidate: Vector2 = (
				origin
				+ Vector2(
					cos(
						angle
					),
					sin(
						angle
					)
				)
				* candidate_distance
			)


			if not _point_inside_ellipse(
				candidate,
				safe_radius_x,
				safe_radius_z
			):
				continue


			if not _is_poisson_candidate_valid(
				candidate,
				points,
				minimum_distance_squared
			):
				continue


			points.append(
				candidate
			)


			active_points.append(
				candidate
			)


			found_candidate = true

			break


		if not found_candidate:

			active_points.remove_at(
				active_index
			)


	return points


# ============================================================
# RANDOM POINT IN ELLIPSE
# ============================================================

func _random_point_in_ellipse(
	radius_x: float,
	radius_z: float,
	rng: RandomNumberGenerator
) -> Vector2:

	var angle: float = (
		rng.randf_range(
			0.0,
			TAU
		)
	)


	var radial: float = (
		sqrt(
			rng.randf()
		)
	)


	return Vector2(
		cos(
			angle
		)
			* radial
			* radius_x,

		sin(
			angle
		)
			* radial
			* radius_z
	)


# ============================================================
# ELLIPSE TEST
# ============================================================

func _point_inside_ellipse(
	point: Vector2,
	radius_x: float,
	radius_z: float
) -> bool:

	var normalized_x: float = (
		point.x
		/ maxf(
			radius_x,
			0.001
		)
	)


	var normalized_z: float = (
		point.y
		/ maxf(
			radius_z,
			0.001
		)
	)


	return (
		normalized_x
			* normalized_x

		+ normalized_z
			* normalized_z

		<= 1.0
	)


# ============================================================
# POISSON DISTANCE
# ============================================================

func _is_poisson_candidate_valid(
	candidate: Vector2,
	points: Array[Vector2],
	minimum_distance_squared: float
) -> bool:

	for existing_point: Vector2 in points:

		if (
			candidate.distance_squared_to(
				existing_point
			)
			< minimum_distance_squared
		):
			return false


	return true


# ============================================================
# CENTER -> EDGE RATIO
# ============================================================

func _get_ellipse_radius_ratio(
	point: Vector2,
	radius_x: float,
	radius_z: float
) -> float:

	var normalized_x: float = (
		point.x
		/ maxf(
			radius_x,
			0.001
		)
	)


	var normalized_z: float = (
		point.y
		/ maxf(
			radius_z,
			0.001
		)
	)


	return clampf(
		sqrt(
			normalized_x
				* normalized_x
			+ normalized_z
				* normalized_z
		),
		0.0,
		1.0
	)


# ============================================================
# EDITOR SAVE
# ============================================================

func _notification(
	what: int
) -> void:

	if not Engine.is_editor_hint():
		return


	# Seguimos guardando la escena SIN miles de transforms.
	#
	# La diferencia respecto al sistema anterior:
	#
	# ANTES:
	#   PRE SAVE  -> borrar
	#   POST SAVE -> regenerar TODO
	#
	# AHORA:
	#   PRE SAVE  -> borrar
	#   POST SAVE -> cargar .res ya bakeado
	if what == NOTIFICATION_EDITOR_PRE_SAVE:

		_clear_generated_multimesh()


	elif what == NOTIFICATION_EDITOR_POST_SAVE:

		call_deferred(
			"_restore_baked_after_editor_save"
		)


func _restore_baked_after_editor_save() -> void:

	var restored: bool = (
		_load_baked_multimesh(
			false
		)
	)


	if (
		not restored
		and auto_bake_if_missing_or_stale_in_editor
	):

		call_deferred(
			"_generate"
		)


func _clear_generated_multimesh() -> void:

	if multimesh == null:
		return


	multimesh.instance_count = 0

	multimesh.visible_instance_count = -1
