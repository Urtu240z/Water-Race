@tool
extends EditorScript

const MATERIALS_DIR := \
	"res://levels/paradise_island/terrain/materials"

# Primero TRUE.
# Compruebas el listado.
# Luego FALSE y lo vuelves a ejecutar.
const PREVIEW_ONLY := false


func _run() -> void:
	var dir := DirAccess.open(MATERIALS_DIR)

	if dir == null:
		push_error("No puedo abrir: " + MATERIALS_DIR)
		return

	var files: Array[String] = []

	for file_name in dir.get_files():
		if file_name.get_extension().to_lower() == "tres":
			files.append(file_name)

	files.sort()

	if files.is_empty():
		push_error(
			"No hay materiales .tres en: "
			+ MATERIALS_DIR
		)
		return

	# ========================================================
	# 1. AGRUPAR POR NOMBRE LIMPIO
	# ========================================================

	var groups: Dictionary = {}

	for file_name in files:
		var clean_base := _clean_base_name(
			file_name.get_basename()
		)

		if not groups.has(clean_base):
			groups[clean_base] = []

		groups[clean_base].append(file_name)

	# ========================================================
	# 2. CONSTRUIR MAPA FINAL
	# ========================================================

	var rename_map: Dictionary = {}
	var used_names: Dictionary = {}

	var bases: Array = groups.keys()
	bases.sort()

	for base_variant in bases:
		var base := String(base_variant)
		var group: Array = groups[base]

		group.sort_custom(
			func(a, b):
				return (
					_sort_key(String(a))
					<
					_sort_key(String(b))
				)
		)

		# ----------------------------------------------------
		# Solo uno con ese nombre limpio:
		# paradise_island_x.tres
		# ----------------------------------------------------

		if group.size() == 1:
			var old_file := String(group[0])

			var new_file := (
				"paradise_island_"
				+ base
				+ ".tres"
			)

			if used_names.has(new_file):
				push_error(
					"COLISIÓN INTERNA: "
					+ new_file
				)
				return

			rename_map[old_file] = new_file
			used_names[new_file] = true

		# ----------------------------------------------------
		# Varios con el mismo nombre limpio:
		# _01, _02, _03...
		# ----------------------------------------------------

		else:
			for i in range(group.size()):
				var old_file := String(group[i])

				var new_file := (
					"paradise_island_"
						+ base
						+ "_"
						+ str(i + 1).pad_zeros(2)
						+ ".tres"
				)

				if used_names.has(new_file):
					push_error(
						"COLISIÓN INTERNA: "
							+ new_file
					)
					return

				rename_map[old_file] = new_file
				used_names[new_file] = true

	# ========================================================
	# 3. MOSTRAR PLAN
	# ========================================================

	print("")
	print(
		"=============================================="
	)
	print(
		"=== PARADISE ISLAND MATERIAL RENAME MAP ====="
	)
	print(
		"=============================================="
	)
	print("")

	var originals: Array = rename_map.keys()
	originals.sort()

	for old_variant in originals:
		var old_file := String(old_variant)

		print(
			old_file,
			"  ->  ",
			rename_map[old_file]
		)

	print("")
	print("TOTAL: ", rename_map.size())

	if PREVIEW_ONLY:
		print("")
		print(
			"PREVIEW ONLY: no se ha modificado nada."
		)
		return

	# ========================================================
	# 4. VALIDAR DESTINOS
	# ========================================================

	for old_variant in originals:
		var old_file := String(old_variant)
		var new_file := String(
			rename_map[old_file]
		)

		if old_file == new_file:
			continue

		var destination := MATERIALS_DIR.path_join(
			new_file
		)

		if FileAccess.file_exists(destination):
			push_error(
				"Ya existe el destino:\n"
					+ destination
			)
			return

	print("")
	print(
		"Validación correcta. Renombrando..."
	)
	print("")

	# ========================================================
	# 5. RENOMBRAR
	# ========================================================

	var renamed := 0

	for old_variant in originals:
		var old_file := String(old_variant)
		var new_file := String(
			rename_map[old_file]
		)

		if old_file == new_file:
			continue

		var old_path := MATERIALS_DIR.path_join(
			old_file
		)

		var new_path := MATERIALS_DIR.path_join(
			new_file
		)

		var old_absolute := (
			ProjectSettings.globalize_path(
				old_path
			)
		)

		var new_absolute := (
			ProjectSettings.globalize_path(
				new_path
			)
		)

		var err := DirAccess.rename_absolute(
			old_absolute,
			new_absolute
		)

		if err != OK:
			push_error(
				"ERROR RENOMBRANDO:\n"
					+ old_path
					+ "\n->\n"
					+ new_path
					+ "\nError: "
					+ str(err)
			)
			return

		print(
			"OK  ",
			old_file,
			"  ->  ",
			new_file
		)

		renamed += 1

	# Godot actualiza el FileSystem.
	EditorInterface.get_resource_filesystem().scan()

	print("")
	print(
		"=============================================="
	)
	print(
		"=== RENOMBRADO TERMINADO ====================="
	)
	print(
		"=============================================="
	)
	print("")
	print("RENOMBRADOS: ", renamed)
	print("")
	print(
		"resource_name NO se ha modificado."
	)
	print(
		"NO reimportes paradise_island.glb todavía."
	)


# ============================================================
# LIMPIEZA DEL NOMBRE
# ============================================================

func _clean_base_name(
	original: String
) -> String:
	var s := original

	# --------------------------------------------------------
	# Eliminar sufijos Blender:
	#
	# material.001
	# material.002
	# --------------------------------------------------------

	var blender_suffix := RegEx.new()
	blender_suffix.compile("\\.\\d{3}$")

	s = blender_suffix.sub(
		s,
		"",
		true
	)

	# --------------------------------------------------------
	# Símbolos que no queremos conservar.
	# --------------------------------------------------------

	s = s.replace("[", "")
	s = s.replace("]", "")
	s = s.replace("~", "_")

	var lower := s.to_lower()

	# --------------------------------------------------------
	# CASOS ESPECÍFICOS DEL PARADISE ISLAND GLB
	# --------------------------------------------------------

	if lower == "mat_palm_billboard_continuous":
		return "palm_billboard_continuous"

	if lower == "mat_terrain_master":
		return "terrain_master"

	if lower.begins_with("photo-"):
		return "photo"

	if lower.contains("saddlebrown"):
		return "saddle_brown"

	if lower.contains("darkgray"):
		return "dark_gray"

	if lower.contains("dimgray"):
		return "dim_gray"

	# aerial_rocks_02...
	if lower.begins_with("aerial_rocks"):
		return "aerial_rocks"

	# Carpet_01_1K...
	if lower.begins_with("carpet_"):
		return "carpet"

	# Metal_06_1K...
	if lower.begins_with("metal_06"):
		return "metal"

	# rufo / rufo.001...
	if lower == "rufo":
		return "rufo"

	# white / white1
	if (
		lower == "white"
		or lower == "white1"
	):
		return "white"

	# Wood 1 / Wood 2
	if (
		lower == "wood 1"
		or lower == "wood 2"
	):
		return "wood"

	# Wicker Rattan...
	if lower == "wicker rattan":
		return "wicker_rattan"

	# --------------------------------------------------------
	# Colores genéricos.
	#
	# [Color B05]
	# [Color C04]
	# [Color M04]
	# [Color_009]
	# --------------------------------------------------------

	if lower.begins_with("color "):
		return "color"

	if lower.begins_with("color_"):
		return "color"

	# --------------------------------------------------------
	# CorrogateShiny variantes.
	# --------------------------------------------------------

	if lower.contains("corrogateshiny"):
		return "corrogate_shiny"

	# --------------------------------------------------------
	# Linen variantes.
	# --------------------------------------------------------

	if lower.contains("linen"):
		return "linen"

	# --------------------------------------------------------
	# Metal-floor variantes.
	# --------------------------------------------------------

	if lower.contains("metal-floor"):
		return "metal_floor"

	# --------------------------------------------------------
	# Yellow / _Yellow_ / _Yellow_.001
	# --------------------------------------------------------

	if (
		lower
			.trim_prefix("_")
			.trim_suffix("_")
			== "yellow"
	):
		return "yellow"

	# --------------------------------------------------------
	# _2 / _2.001 / _2.002
	# --------------------------------------------------------

	if (
		lower
			.trim_prefix("_")
			.is_valid_int()
	):
		return "material"

	# ========================================================
	# LIMPIEZA GENERAL
	# ========================================================

	s = s.to_lower()

	s = s.replace(" ", "_")
	s = s.replace("-", "_")
	s = s.replace(".", "_")

	# --------------------------------------------------------
	# Quitar códigos numéricos al principio.
	#
	# 0135_DarkGray
	# 0043_SaddleBrown
	# 672118_EP05
	# --------------------------------------------------------

	var leading_code := RegEx.new()
	leading_code.compile("^\\d+[_-]*")

	s = leading_code.sub(
		s,
		"",
		true
	)

	# --------------------------------------------------------
	# Quitar códigos de resolución:
	#
	# 1K
	# 2K
	# 4K
	# --------------------------------------------------------

	var resolution_code := RegEx.new()
	resolution_code.compile(
		"(^|_)\\d+k($|_)"
	)

	s = resolution_code.sub(
		s,
		"_",
		true
	)

	# --------------------------------------------------------
	# Quitar número final usado como índice.
	#
	# Rock1
	# Porta_3
	# Metal Panel1
	# EP05 -> EP
	# --------------------------------------------------------

	var trailing_number := RegEx.new()
	trailing_number.compile(
		"[_ ]?\\d+$"
	)

	s = trailing_number.sub(
		s,
		"",
		true
	)

	# --------------------------------------------------------
	# Eliminar caracteres extraños.
	# --------------------------------------------------------

	var invalid := RegEx.new()
	invalid.compile("[^a-z0-9_]")

	s = invalid.sub(
		s,
		"_",
		true
	)

	# --------------------------------------------------------
	# Colapsar underscores.
	# --------------------------------------------------------

	var underscores := RegEx.new()
	underscores.compile("_+")

	s = underscores.sub(
		s,
		"_",
		true
	)

	s = s.trim_prefix("_")
	s = s.trim_suffix("_")

	if s.is_empty():
		s = "material"

	return s


# ============================================================
# ORDEN DE LAS VARIANTES
#
# original
# .001
# .002
# .003
# ...
#
# También deja nombres diferentes pero equivalentes en un
# orden determinista.
# ============================================================

func _sort_key(
	file_name: String
) -> String:
	var base := file_name.get_basename()

	var regex := RegEx.new()
	regex.compile("\\.(\\d{3})$")

	var result := regex.search(base)

	if result == null:
		return (
			"000000_"
			+ file_name
		)

	var number := int(
		result.get_string(1)
	)

	return (
		str(number + 1).pad_zeros(6)
			+ "_"
			+ file_name
	)
