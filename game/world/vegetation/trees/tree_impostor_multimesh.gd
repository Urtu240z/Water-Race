@tool
extends MultiMeshInstance3D


@export_group("Distribution")

@export_range(1, 100, 1) var columns: int = 16
@export_range(1, 100, 1) var rows: int = 20

@export_range(0.25, 30.0, 0.05) var min_spacing: float = 2.0
@export_range(0.25, 30.0, 0.05) var max_spacing: float = 4.0

@export_range(0.10, 4.0, 0.05) var min_scale: float = 0.65
@export_range(0.10, 15.0, 0.05) var max_scale: float = 1.45

@export_range(0.0, 100.0, 1.0) var center_scale_bias_percent: float = 0.0

@export var random_seed: int = 12345

@export_group("Ground Placement")

@export var snap_to_ground: bool = true

@export_range(1.0, 500.0, 1.0) var ray_above_height: float = 100.0
@export_range(1.0, 1000.0, 1.0) var ray_below_depth: float = 300.0

@export_flags_3d_physics var ground_collision_mask: int = 0xFFFFFFFF

@export_tool_button("Regenerate") var regenerate = _generate


func _ready() -> void:
	if not Engine.is_editor_hint():
		_generate()


func _generate() -> void:
	if multimesh == null:
		return

	if snap_to_ground and not is_inside_tree():
		push_warning("Tree MultiMesh must be inside the scene tree to query the ground.")
		return

	var space_state: PhysicsDirectSpaceState3D = null

	if snap_to_ground:
		space_state = get_world_3d().direct_space_state

	var safe_min_spacing: float = minf(min_spacing, max_spacing)
	var safe_max_spacing: float = maxf(min_spacing, max_spacing)

	var safe_min_scale: float = minf(min_scale, max_scale)
	var safe_max_scale: float = maxf(min_scale, max_scale)

	var count := columns * rows

	# Custom Data debe activarse antes de crear las instancias.
	multimesh.instance_count = 0
	multimesh.use_custom_data = true
	multimesh.instance_count = count
	multimesh.visible_instance_count = 0

	var rng := RandomNumberGenerator.new()
	rng.seed = random_seed

	# Creamos posiciones irregulares para cada columna y fila.
	# Cada separación consecutiva estará entre min_spacing y max_spacing.
	var x_positions := _generate_axis_positions(
		columns,
		safe_min_spacing,
		safe_max_spacing,
		rng
	)

	var z_positions := _generate_axis_positions(
		rows,
		safe_min_spacing,
		safe_max_spacing,
		rng
	)

	var max_radius: float = 0.001

	for z in range(rows):
		for x in range(columns):
			var radius: float = Vector2(
				x_positions[x],
				z_positions[z]
			).length()

			if radius > max_radius:
				max_radius = radius

	var index := 0

	for z in rows:
		for x in columns:
			var radial_ratio: float = Vector2(
				x_positions[x],
				z_positions[z]
			).length() / max_radius

			radial_ratio = clampf(radial_ratio, 0.0, 1.0)

			var bias: float = clampf(
				center_scale_bias_percent / 100.0,
				0.0,
				1.0
			)

			var random_t: float = rng.randf()

			# 0.0 = centro, 1.0 = borde
			# Para escala:
			#   0.0 -> árbol grande
			#   1.0 -> árbol pequeño
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

			var local_x: float = x_positions[x]
			var local_z: float = z_positions[z]

			var ground_y: float = 0.0

			if snap_to_ground:
				var local_probe_position: Vector3 = Vector3(
					local_x,
					0.0,
					local_z
				)

				var global_probe_position: Vector3 = to_global(
					local_probe_position
				)

				var ray_from: Vector3 = (
					global_probe_position
					+ Vector3.UP * ray_above_height
				)

				var ray_to: Vector3 = (
					global_probe_position
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

				var hit: Dictionary = space_state.intersect_ray(query)

				if hit.is_empty():
					continue

				var hit_position_global: Vector3 = hit["position"]
				var hit_position_local: Vector3 = to_local(
					hit_position_global
				)

				ground_y = hit_position_local.y

			var instance_position: Vector3 = Vector3(
				local_x,
				ground_y + scale_variation,
				local_z
			)

			var instance_basis := Basis.IDENTITY.scaled(
				Vector3(
					scale_variation,
					scale_variation,
					scale_variation
				)
			)

			var instance_transform := Transform3D(
				instance_basis,
				instance_position
			)

			multimesh.set_instance_transform(
				index,
				instance_transform
			)

			var leaf_variation := rng.randf()

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
	multimesh.visible_instance_count = index

	print(
		"Trees placed on ground: ",
		index,
		" / ",
		count
	)

func _generate_axis_positions(
	axis_count: int,
	spacing_min: float,
	spacing_max: float,
	rng: RandomNumberGenerator
) -> PackedFloat32Array:

	var positions := PackedFloat32Array()

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

	# Centramos todo alrededor del origen.
	var center := (
		positions[0]
		+ positions[axis_count - 1]
	) * 0.5

	for i in axis_count:
		positions[i] -= center

	return positions
