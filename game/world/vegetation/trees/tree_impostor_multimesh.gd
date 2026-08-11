@tool
extends MultiMeshInstance3D


# ============================================================
# DISTRIBUTION
# ============================================================

@export_group("Distribution")

@export_range(1, 100, 1) var columns: int = 16
@export_range(1, 100, 1) var rows: int = 20

@export_range(0.25, 30.0, 0.05) var min_spacing: float = 4.0
@export_range(0.25, 30.0, 0.05) var max_spacing: float = 10.0

@export_range(0.10, 15.0, 0.05) var min_scale: float = 2.0
@export_range(0.10, 15.0, 0.05) var max_scale: float = 7.5

@export_range(0.0, 100.0, 1.0) var center_scale_bias_percent: float = 0.0

@export var random_seed: int = 12345


# ============================================================
# GROUND PLACEMENT
# ============================================================

@export_group("Ground Placement")

@export var snap_to_ground: bool = true

@export_range(1.0, 500.0, 1.0) var ray_above_height: float = 100.0
@export_range(1.0, 1000.0, 1.0) var ray_below_depth: float = 300.0

@export_flags_3d_physics var ground_collision_mask: int = 0xFFFFFFFF

# Si está vacío, cualquier collider puede servir como suelo.
# En Paradise Island usaremos Terrain_Master_COL.
@export var valid_ground_name_contains: PackedStringArray = PackedStringArray([
	"Terrain_Master_COL"
])


# ============================================================
# VISUAL GEOMETRY EXCLUSION
# ============================================================

@export_group("Visual Geometry Exclusion")

@export var avoid_visual_geometry: bool = true

# Aquí añades, desde Paradise Island:
#
# ../../Buildings
# ../../Rocks
# ../../Ramps
#
# etc.
#
# No necesitan collider.
@export var visual_exclusion_roots: Array[NodePath] = []

# 1.0 = utilizamos aproximadamente todo el ancho del árbol.
# Menos de 1.0 permite que copas puedan acercarse más.
@export_range(0.1, 1.5, 0.05) var visual_radius_factor: float = 0.8

# Margen adicional alrededor del árbol.
@export_range(0.0, 10.0, 0.1) var visual_extra_clearance: float = 1.0


# ============================================================
# WATER EXCLUSION
# ============================================================

@export_group("Water Exclusion")

@export var avoid_water: bool = true

# Puede quedar vacío.
# Intentaremos encontrar automáticamente Ocean3D.
@export var water_provider_path: NodePath

# Altura mínima del terreno respecto a la superficie del agua.
#
# 0 = solo impide árboles sumergidos.
# 1 = deja aproximadamente 1 m vertical libre respecto al agua.
@export_range(0.0, 20.0, 0.1) var minimum_height_above_water: float = 1.0


# ============================================================
# EDITOR
# ============================================================

@export_tool_button("Regenerate") var regenerate = _generate


func _ready() -> void:
	if not Engine.is_editor_hint():
		_generate()


# ============================================================
# GENERATE
# ============================================================

func _generate() -> void:
	if multimesh == null:
		return

	if snap_to_ground and not is_inside_tree():
		push_warning(
			"Tree MultiMesh must be inside the scene tree to query the ground."
		)
		return


	var space_state: PhysicsDirectSpaceState3D = null

	if snap_to_ground:
		space_state = get_world_3d().direct_space_state


	# --------------------------------------------------------
	# WATER
	# --------------------------------------------------------

	var water_provider: WaterSurfaceProvider3D = null

	if avoid_water:
		water_provider = _resolve_water_provider()

		if water_provider == null:
			push_warning(
				"Water exclusion is enabled, but no "
				+ "WaterSurfaceProvider3D was found."
			)


	# --------------------------------------------------------
	# VISUAL BLOCKERS
	# --------------------------------------------------------

	var visual_blocker_aabbs: Array[AABB] = []

	if avoid_visual_geometry:
		visual_blocker_aabbs = _build_visual_blocker_aabbs()


	# --------------------------------------------------------
	# SAFE VALUES
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


	var count: int = columns * rows


	# --------------------------------------------------------
	# MULTIMESH
	# --------------------------------------------------------

	multimesh.instance_count = 0
	multimesh.use_custom_data = true
	multimesh.instance_count = count
	multimesh.visible_instance_count = 0


	# --------------------------------------------------------
	# RANDOM
	# --------------------------------------------------------

	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.seed = random_seed


	# --------------------------------------------------------
	# POSITIONS
	# --------------------------------------------------------

	var x_positions: PackedFloat32Array = _generate_axis_positions(
		columns,
		safe_min_spacing,
		safe_max_spacing,
		rng
	)

	var z_positions: PackedFloat32Array = _generate_axis_positions(
		rows,
		safe_min_spacing,
		safe_max_spacing,
		rng
	)


	# --------------------------------------------------------
	# CENTER BIAS MAX RADIUS
	# --------------------------------------------------------

	var max_radius: float = 0.001

	for z in range(rows):
		for x in range(columns):

			var radius: float = Vector2(
				x_positions[x],
				z_positions[z]
			).length()

			if radius > max_radius:
				max_radius = radius


	# --------------------------------------------------------
	# COUNTERS
	# --------------------------------------------------------

	var index: int = 0

	var rejected_no_ground: int = 0
	var rejected_invalid_ground: int = 0
	var rejected_visual_geometry: int = 0
	var rejected_water: int = 0


	# ========================================================
	# GENERATE INSTANCES
	# ========================================================

	for z in rows:
		for x in columns:

			# ------------------------------------------------
			# SCALE
			# ------------------------------------------------

			var radial_ratio: float = Vector2(
				x_positions[x],
				z_positions[z]
			).length() / max_radius

			radial_ratio = clampf(
				radial_ratio,
				0.0,
				1.0
			)

			var bias: float = clampf(
				center_scale_bias_percent / 100.0,
				0.0,
				1.0
			)

			var random_t: float = rng.randf()

			var center_weighted_t: float = radial_ratio

			var final_t: float = lerpf(
				random_t,
				center_weighted_t,
				bias
			)

			var scale_variation: float = lerpf(
				safe_max_scale,
				safe_min_scale,
				final_t
			)


			# ------------------------------------------------
			# LOCAL X/Z
			# ------------------------------------------------

			var local_x: float = x_positions[x]
			var local_z: float = z_positions[z]

			var ground_y: float = 0.0

			var ground_position_global: Vector3 = to_global(
				Vector3(
					local_x,
					0.0,
					local_z
				)
			)


			# ====================================================
			# GROUND
			# ====================================================

			if snap_to_ground:

				var ray_from: Vector3 = (
					ground_position_global
					+ Vector3.UP * ray_above_height
				)

				var ray_to: Vector3 = (
					ground_position_global
					- Vector3.UP * ray_below_depth
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


				var hit: Dictionary = space_state.intersect_ray(
					query
				)


				if hit.is_empty():
					rejected_no_ground += 1
					continue


				var ground_collider: Object = hit["collider"]


				if not _is_valid_ground_collider(
					ground_collider
				):
					rejected_invalid_ground += 1
					continue


				ground_position_global = hit["position"]


				var ground_position_local: Vector3 = to_local(
					ground_position_global
				)

				ground_y = ground_position_local.y


			# ====================================================
			# OCEAN
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
						- water_sample.surface_position.y
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
			# FINAL POSITION
			# ====================================================

			var instance_position: Vector3 = Vector3(
				local_x,
				ground_y + scale_variation,
				local_z
			)


			# ------------------------------------------------
			# BASIS / SCALE
			# ------------------------------------------------

			var instance_basis: Basis = Basis.IDENTITY.scaled(
				Vector3(
					scale_variation,
					scale_variation,
					scale_variation
				)
			)


			var instance_transform: Transform3D = Transform3D(
				instance_basis,
				instance_position
			)


			# ------------------------------------------------
			# MULTIMESH
			# ------------------------------------------------

			multimesh.set_instance_transform(
				index,
				instance_transform
			)


			# ------------------------------------------------
			# LEAF COLOR RANDOM
			# ------------------------------------------------

			var leaf_variation: float = rng.randf()


			multimesh.set_instance_custom_data(
				index,
				Color(
					leaf_variation,
					0.0,
					0.0,
					1.0
				)
			)


			index += 1


	# ========================================================
	# SHOW ONLY VALID INSTANCES
	# ========================================================

	multimesh.visible_instance_count = index


	print(
		"Tree scatter | placed: ",
		index,
		" / ",
		count,
		" | no ground: ",
		rejected_no_ground,
		" | invalid ground: ",
		rejected_invalid_ground,
		" | visual geometry: ",
		rejected_visual_geometry,
		" | water: ",
		rejected_water,
		" | visual blockers: ",
		visual_blocker_aabbs.size()
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


	var collider_node: Node = collider as Node
	var collider_name: String = String(
		collider_node.name
	)


	for filter_text: String in valid_ground_name_contains:

		if filter_text.is_empty():
			continue

		if collider_name.contains(filter_text):
			return true


	return false


# ============================================================
# VISUAL EXCLUSION
# ============================================================

func _build_visual_blocker_aabbs() -> Array[AABB]:

	var blocker_aabbs: Array[AABB] = []


	for root_path: NodePath in visual_exclusion_roots:

		if root_path == NodePath(""):
			continue


		var root_node: Node = get_node_or_null(
			root_path
		)


		if root_node == null:
			push_warning(
				"Visual exclusion root not found: "
				+ String(root_path)
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
			node as MeshInstance3D
		)


		if (
			mesh_instance.mesh != null
				and mesh_instance.visible
		):

			var world_aabb: AABB = _get_world_aabb(
				mesh_instance
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
# MESH LOCAL AABB -> WORLD AABB
# ============================================================

func _get_world_aabb(
	mesh_instance: MeshInstance3D
) -> AABB:

	var local_aabb: AABB = mesh_instance.get_aabb()

	var local_min: Vector3 = local_aabb.position
	var local_max: Vector3 = (
		local_aabb.position
		+ local_aabb.size
	)


	var corners: PackedVector3Array = PackedVector3Array([
		Vector3(local_min.x, local_min.y, local_min.z),
		Vector3(local_max.x, local_min.y, local_min.z),
		Vector3(local_min.x, local_max.y, local_min.z),
		Vector3(local_max.x, local_max.y, local_min.z),

		Vector3(local_min.x, local_min.y, local_max.z),
		Vector3(local_max.x, local_min.y, local_max.z),
		Vector3(local_min.x, local_max.y, local_max.z),
		Vector3(local_max.x, local_max.y, local_max.z)
	])


	var first_world_corner: Vector3 = (
		mesh_instance.global_transform
		* corners[0]
	)


	var world_min: Vector3 = first_world_corner
	var world_max: Vector3 = first_world_corner


	for i in range(1, corners.size()):

		var world_corner: Vector3 = (
			mesh_instance.global_transform
			* corners[i]
		)


		world_min = Vector3(
			minf(world_min.x, world_corner.x),
			minf(world_min.y, world_corner.y),
			minf(world_min.z, world_corner.z)
		)


		world_max = Vector3(
			maxf(world_max.x, world_corner.x),
			maxf(world_max.y, world_corner.y),
			maxf(world_max.z, world_corner.z)
		)


	return AABB(
		world_min,
		world_max - world_min
	)


# ============================================================
# TREE BOX vs VISUAL GEOMETRY
# ============================================================

func _intersects_visual_geometry(
	ground_position_global: Vector3,
	scale_variation: float,
	blocker_aabbs: Array[AABB]
) -> bool:

	if blocker_aabbs.is_empty():
		return false


	# Quad base = 2x2.
	#
	# Escala 5:
	# ancho  = 10 m
	# alto   = 10 m

	var tree_height: float = maxf(
		2.0 * scale_variation,
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
			tree_half_width * 2.0,
			tree_height,
			tree_half_width * 2.0
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
	# EXPLICIT PATH
	# --------------------------------------------------------

	if water_provider_path != NodePath(""):

		var explicit_node: Node = get_node_or_null(
			water_provider_path
		)


		if explicit_node is WaterSurfaceProvider3D:
			return (
				explicit_node
				as WaterSurfaceProvider3D
			)


	# --------------------------------------------------------
	# AUTOMATIC OCEAN3D
	# --------------------------------------------------------

	if is_inside_tree():

		var grouped_node: Node = (
			get_tree().get_first_node_in_group(
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
# AXIS DISTRIBUTION
# ============================================================

func _generate_axis_positions(
	axis_count: int,
	spacing_min: float,
	spacing_max: float,
	rng: RandomNumberGenerator
) -> PackedFloat32Array:

	var positions: PackedFloat32Array = PackedFloat32Array()


	if axis_count <= 0:
		return positions


	positions.resize(axis_count)
	positions[0] = 0.0


	for i in range(1, axis_count):

		positions[i] = (
			positions[i - 1]
			+ rng.randf_range(
				spacing_min,
				spacing_max
			)
		)


	# --------------------------------------------------------
	# CENTER AROUND ORIGIN
	# --------------------------------------------------------

	var center: float = (
		positions[0]
		+ positions[axis_count - 1]
	) * 0.5


	for i in axis_count:
		positions[i] -= center


	return positions
