@tool
extends MultiMeshInstance3D


@export_group("Distribution")

@export_range(1, 100, 1) var columns: int = 16
@export_range(1, 100, 1) var rows: int = 20

@export_range(0.25, 30.0, 0.05) var min_spacing: float = 2.0
@export_range(0.25, 30.0, 0.05) var max_spacing: float = 4.0

@export_range(0.10, 3.0, 0.05) var min_scale: float = 0.65
@export_range(0.10, 3.0, 0.05) var max_scale: float = 1.45

@export var random_seed: int = 12345

@export_tool_button("Regenerate") var regenerate = _generate


func _ready() -> void:
	if not Engine.is_editor_hint():
		_generate()


func _generate() -> void:
	if multimesh == null:
		return

	var safe_min_spacing: float = minf(min_spacing, max_spacing)
	var safe_max_spacing: float = maxf(min_spacing, max_spacing)

	var safe_min_scale: float = minf(min_scale, max_scale)
	var safe_max_scale: float = maxf(min_scale, max_scale)

	var count := columns * rows

	# Custom Data debe activarse antes de crear las instancias.
	multimesh.instance_count = 0
	multimesh.use_custom_data = true
	multimesh.instance_count = count

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

	var index := 0

	for z in rows:
		for x in columns:
			var scale_variation := rng.randf_range(
				safe_min_scale,
				safe_max_scale
			)

			var instance_position := Vector3(
				x_positions[x],
				1.0 * scale_variation,
				z_positions[z]
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
