@tool
extends EditorScript

const TEXTURE_DIRECTORY: String = "res://world/vegetation/trees/textures"

const GRID_SIZE: int = 3
const CELL_SIZE: int = 1024
const PADDING: int = 32
const INNER_SIZE: int = CELL_SIZE - (PADDING * 2)

const TREE_PREFIXES: Array[String] = [
	"tree_beech_a",
	"tree_beech_b",
	"tree_fir_a",
	"tree_fir_b",
	"tree_linden_a",
	"tree_linden_b",
	"tree_linden_c",
	"tree_oak_a",
	"tree_oak_b",
]

const OUTPUT_TEX: String = (
	"res://world/vegetation/trees/textures/tree_atlas_tex.png"
)
const OUTPUT_MASK: String = (
	"res://world/vegetation/trees/textures/tree_atlas_mask.png"
)
const OUTPUT_NORMAL: String = (
	"res://world/vegetation/trees/textures/tree_atlas_nor.png"
)


func _run() -> void:
	if INNER_SIZE <= 0:
		push_error(
			"Tree atlas builder: CELL_SIZE must be larger "
			+ "than PADDING * 2."
		)
		return

	var tex_ok: bool = _build_atlas("_tex", OUTPUT_TEX)
	var mask_ok: bool = _build_atlas("_mask", OUTPUT_MASK)
	var normal_ok: bool = _build_atlas("_nor", OUTPUT_NORMAL)

	if not tex_ok or not mask_ok or not normal_ok:
		push_error(
			"Tree atlas builder failed. Check the errors above."
		)
		return

	EditorInterface.get_resource_filesystem().scan()

	print("")
	print("============================================================")
	print("TREE ATLASES CREATED")
	print("============================================================")
	print(OUTPUT_TEX)
	print(OUTPUT_MASK)
	print(OUTPUT_NORMAL)
	print("")
	print("0 Beech A | 1 Beech B | 2 Fir A")
	print("3 Fir B   | 4 Linden A | 5 Linden B")
	print("6 Linden C| 7 Oak A    | 8 Oak B")
	print("============================================================")


func _build_atlas(
	suffix: String,
	output_path: String
) -> bool:
	var atlas_size: int = GRID_SIZE * CELL_SIZE

	var atlas: Image = Image.create(
		atlas_size,
		atlas_size,
		false,
		Image.FORMAT_RGBA8
	)

	if atlas == null:
		push_error(
			"Tree atlas builder: could not create atlas image."
		)
		return false

	atlas.fill(Color(0.0, 0.0, 0.0, 0.0))

	for tree_index: int in range(TREE_PREFIXES.size()):
		var prefix: String = TREE_PREFIXES[tree_index]
		var source_path: String = TEXTURE_DIRECTORY.path_join(
			prefix + suffix + ".png"
		)

		var source_image: Image = _load_source_image(source_path)

		if source_image == null:
			return false

		source_image.resize(
			INNER_SIZE,
			INNER_SIZE,
			Image.INTERPOLATE_LANCZOS
		)

		var padded_cell: Image = _create_padded_cell(source_image)

		if padded_cell == null:
			return false

		var column: int = tree_index % GRID_SIZE
		var row: int = int(
			floor(
				float(tree_index) / float(GRID_SIZE)
			)
		)

		atlas.blit_rect(
			padded_cell,
			Rect2i(
				Vector2i.ZERO,
				Vector2i(CELL_SIZE, CELL_SIZE)
			),
			Vector2i(
				column * CELL_SIZE,
				row * CELL_SIZE
			)
		)

	var absolute_output_path: String = (
		ProjectSettings.globalize_path(output_path)
	)

	var save_error: Error = atlas.save_png(
		absolute_output_path
	)

	if save_error != OK:
		push_error(
			"Tree atlas builder: could not save "
			+ output_path
			+ " | Error: "
			+ str(save_error)
		)
		return false

	print(
		"Tree atlas saved: ",
		output_path,
		" | ",
		atlas_size,
		"x",
		atlas_size,
		" | cell ",
		CELL_SIZE,
		" | padding ",
		PADDING
	)

	return true


func _load_source_image(
	source_path: String
) -> Image:
	var absolute_source_path: String = (
		ProjectSettings.globalize_path(
			source_path
		)
	)

	var source_image: Image = Image.new()

	var load_error: Error = source_image.load(
		absolute_source_path
	)

	if load_error != OK:
		push_error(
			"Tree atlas source could not be loaded: "
			+ source_path
			+ " | Error: "
			+ str(load_error)
		)
		return null

	if source_image.is_empty():
		push_error(
			"Tree atlas source is empty: "
			+ source_path
		)
		return null

	source_image.convert(
		Image.FORMAT_RGBA8
	)

	return source_image


func _create_padded_cell(
	source_image: Image
) -> Image:
	if source_image == null:
		return null

	if (
		source_image.get_width() != INNER_SIZE
		or source_image.get_height() != INNER_SIZE
	):
		push_error(
			"Tree atlas builder: unexpected source image size."
		)
		return null

	var cell: Image = Image.create(
		CELL_SIZE,
		CELL_SIZE,
		false,
		Image.FORMAT_RGBA8
	)

	if cell == null:
		return null

	cell.fill(Color(0.0, 0.0, 0.0, 0.0))

	var inner_rect: Rect2i = Rect2i(
		Vector2i.ZERO,
		Vector2i(INNER_SIZE, INNER_SIZE)
	)

	cell.blit_rect(
		source_image,
		inner_rect,
		Vector2i(PADDING, PADDING)
	)

	var top_row: Rect2i = Rect2i(
		0,
		0,
		INNER_SIZE,
		1
	)
	var bottom_row: Rect2i = Rect2i(
		0,
		INNER_SIZE - 1,
		INNER_SIZE,
		1
	)
	var left_column: Rect2i = Rect2i(
		0,
		0,
		1,
		INNER_SIZE
	)
	var right_column: Rect2i = Rect2i(
		INNER_SIZE - 1,
		0,
		1,
		INNER_SIZE
	)

	for padding_index: int in range(PADDING):
		cell.blit_rect(
			source_image,
			top_row,
			Vector2i(
				PADDING,
				padding_index
			)
		)

		cell.blit_rect(
			source_image,
			bottom_row,
			Vector2i(
				PADDING,
				PADDING + INNER_SIZE + padding_index
			)
		)

		cell.blit_rect(
			source_image,
			left_column,
			Vector2i(
				padding_index,
				PADDING
			)
		)

		cell.blit_rect(
			source_image,
			right_column,
			Vector2i(
				PADDING + INNER_SIZE + padding_index,
				PADDING
			)
		)

	var top_left: Color = source_image.get_pixel(0, 0)
	var top_right: Color = source_image.get_pixel(
		INNER_SIZE - 1,
		0
	)
	var bottom_left: Color = source_image.get_pixel(
		0,
		INNER_SIZE - 1
	)
	var bottom_right: Color = source_image.get_pixel(
		INNER_SIZE - 1,
		INNER_SIZE - 1
	)

	for y_index: int in range(PADDING):
		for x_index: int in range(PADDING):
			cell.set_pixel(
				x_index,
				y_index,
				top_left
			)
			cell.set_pixel(
				PADDING + INNER_SIZE + x_index,
				y_index,
				top_right
			)
			cell.set_pixel(
				x_index,
				PADDING + INNER_SIZE + y_index,
				bottom_left
			)
			cell.set_pixel(
				PADDING + INNER_SIZE + x_index,
				PADDING + INNER_SIZE + y_index,
				bottom_right
			)

	return cell
