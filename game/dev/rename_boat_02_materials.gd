@tool
extends EditorScript

const BOAT := "res://world/props/boats/boat_02.glb"
const IMPORT_FILE := BOAT + ".import"
const MATERIALS_DIR := "res://world/props/boats/materials"


# Nombre ORIGINAL dentro del GLB -> archivo .tres limpio
const MATERIAL_MAP := {
	"[0016_Tomato]": "boat_02_tomato.tres",
	"[0020_Red]": "boat_02_red.tres",
	"[0025_Coral]": "boat_02_coral.tres",
	"[0074_SeaGreen]": "boat_02_seagreen.tres",
	"[0099_LightSteelBlue]": "boat_02_lightsteelblue.tres",
	"[Blue]": "boat_02_blue.tres",
	"[Yellow]": "boat_02_yellow.tres",

	"[WarmGray1]": "boat_02_warmgray.tres",
	"[CoolGray6]": "boat_02_coolgray.tres",
	"_Gray6_": "boat_02_gray.tres",

	"Carpet_Pattern_Dots": "boat_02_carpet_dots.tres",
	"Carpet_Pattern_Leaves": "boat_02_carpet_leaves.tres",
	"[Carpet_Diamond_Olive]": "boat_02_carpet_olive.tres",

	"[Tile_Ceramic_Natural]": "boat_02_tile_natural.tres",
	"Tile_Squares_Neutral": "boat_02_tile_neutral.tres",
	"Tile_Ceiling_Drop": "boat_02_ceiling_drop.tres",

	"Metal_Brushed": "boat_02_metal_brushed.tres",
	"Metal_Corrogated_Rust": "boat_02_metal_rust.tres",

	"[Translucent_Glass_Blue]": "boat_02_glass_blue.tres",
	"[Translucent_Glass_Gray]": "boat_02_glass_gray.tres",

	"[Wood_Cherry_Original]": "boat_02_wood_cherry.tres",
	"[Wood_Floor_Parquet]": "boat_02_wood_parquet.tres",
	"Wood_Floor2": "boat_02_wood_floor.tres",

	"[Water_Pool]": "boat_02_pool.tres",

	"Blinds_Mini_Blue": "boat_02_blinds_mini_blue.tres",
	"Blinds_Vertical_Stripe_Blue": "boat_02_blinds_vertical_blue.tres",

	"Textile_Stripes_Pastels": "boat_02_textile_pastels.tres",
	"subby": "boat_02_subby.tres",
	"cuadro": "boat_02_cuadro.tres",

}


func _run() -> void:
	var config := ConfigFile.new()

	var err := config.load(IMPORT_FILE)
	if err != OK:
		push_error(
			"No puedo abrir %s. Error: %s"
			% [IMPORT_FILE, err]
		)
		return

	var subresources: Dictionary = config.get_value(
		"params",
		"_subresources",
		{}
	)

	var materials: Dictionary = subresources.get(
		"materials",
		{}
	)

	var added := 0
	var missing := 0

	print("")
	print("=== BOAT 02 EXTERNAL MATERIALS ===")

	for original_name: String in MATERIAL_MAP:
		var file_name: String = MATERIAL_MAP[original_name]
		var clean_path := MATERIALS_DIR.path_join(file_name)

		if not FileAccess.file_exists(clean_path):
			push_warning(
				"NO EXISTE: %s -> %s"
				% [original_name, clean_path]
			)
			missing += 1
			continue

		var uid_path := ResourceUID.path_to_uid(clean_path)

		materials[original_name] = {
			"use_external/enabled": true,
			"use_external/fallback_path": clean_path,
			"use_external/path": uid_path,
		}

		print(
			original_name,
			"  ->  ",
			file_name,
			"  [",
			uid_path,
			"]"
		)

		added += 1

	subresources["materials"] = materials

	# IMPORTANTE:
	# Ya no queremos extracción automática.
	config.set_value(
		"params",
		"materials/extract",
		0
	)

	config.set_value(
		"params",
		"_subresources",
		subresources
	)

	err = config.save(IMPORT_FILE)

	if err != OK:
		push_error(
			"No se pudo guardar %s. Error: %s"
			% [IMPORT_FILE, err]
		)
		return

	print("")
	print("Asociaciones creadas: ", added)
	print("Materiales limpios no encontrados: ", missing)

	if missing > 0:
		print("")
		push_warning(
			"Hay materiales sin asociar. NO reimportes todavía."
		)
		return

	print("")
	print("Reimportando boat_02...")

	var fs := EditorInterface.get_resource_filesystem()

	fs.reimport_files(
		PackedStringArray([BOAT])
	)

	print("")
	print("=== TERMINADO ===")
	print("Comprueba boat_02 visualmente.")
