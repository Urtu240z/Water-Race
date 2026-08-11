@tool
extends MultiMeshInstance3D

@export_range(1, 50, 1) var columns: int = 10
@export_range(1, 50, 1) var rows: int = 10
@export_range(1.0, 30.0, 0.5) var spacing: float = 5.0

@export_tool_button("Regenerate") var regenerate: Callable = _generate


func _ready() -> void:
	if not Engine.is_editor_hint():
		_generate()


func _generate() -> void:
	if multimesh == null:
		return

	var count := columns * rows

	# Custom Data debe activarse antes de crear las instancias.
	multimesh.instance_count = 0
	multimesh.use_custom_data = true
	multimesh.instance_count = count

	var rng := RandomNumberGenerator.new()
	rng.seed = 12345

	var index := 0

	for z in rows:
		for x in columns:
			var scale_variation := rng.randf_range(0.85, 1.15)

			var instance_position := Vector3(
				(float(x) - float(columns - 1) * 0.5) * spacing,
				1.0 * scale_variation,
				(float(z) - float(rows - 1) * 0.5) * spacing
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
