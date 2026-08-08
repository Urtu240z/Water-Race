@tool
extends EditorScript

const GLB := \
	"res://levels/paradise_island/terrain/paradise_island.glb"

const IMPORT_FILE := GLB + ".import"

const MATERIALS_DIR := \
	"res://levels/paradise_island/terrain/materials"


# ============================================================
# DEDUPLICACIÓN CONFIRMADA
#
# Auditoría:
#
# [Color_009].001 == [Color_009]
# _Linen_.001      == _Linen_
# _Yellow_.001     == _Yellow_
#
# Ambos materiales internos utilizarán el mismo .tres.
#
# NO se borra el archivo duplicado.
# ============================================================

const DUPLICATE_FILES := {
	"paradise_island_color_09.tres":
		"paradise_island_color_08.tres",

	"paradise_island_linen_02.tres":
		"paradise_island_linen_01.tres",

	"paradise_island_yellow_03.tres":
		"paradise_island_yellow_02.tres",
}


func _run() -> void:
	print("")
	print(
		"=============================================="
	)
	print(
		"=== PARADISE ISLAND MATERIAL LINKER ========="
	)
	print(
		"=============================================="
	)
	print("")

	# ========================================================
	# 1. LEER LOS MATERIALES INTERNOS DEL GLB
	#
	# DISCARD_TEXTURES evita que esta inspección genere
	# imágenes extraídas.
	# ========================================================

	var state := GLTFState.new()

	state.handle_binary_image_mode = (
		GLTFState
			.HANDLE_BINARY_IMAGE_MODE_DISCARD_TEXTURES
	)

	var document := GLTFDocument.new()

	var gltf_error := document.append_from_file(
		GLB,
		state
	)

	if gltf_error != OK:
		push_error(
			"No puedo leer el GLB.\n"
				+ GLB
				+ "\nError: "
				+ str(gltf_error)
		)
		return

	var gltf_materials := state.get_materials()

	if gltf_materials.is_empty():
		push_error(
			"El GLB no contiene materiales."
		)
		return

	# ========================================================
	# 2. OBTENER NOMBRES INTERNOS
	# ========================================================

	var internal_names: Array[String] = []
	var seen_internal: Dictionary = {}

	for material_variant in gltf_materials:
		if not material_variant is Material:
			continue

		var material := material_variant as Material

		var internal_name := String(
			material.resource_name
		)

		if internal_name.is_empty():
			push_error(
				"Hay un material interno del GLB "
				+ "sin resource_name.\n"
				+ "Abortado por seguridad."
			)
			return

		if seen_internal.has(internal_name):
			push_error(
				"Nombre interno duplicado en GLB:\n"
					+ internal_name
			)
			return

		seen_internal[internal_name] = true
		internal_names.append(internal_name)

	internal_names.sort()

	print(
		"Materiales internos GLB: ",
		internal_names.size()
	)

	# ========================================================
	# 3. CONSTRUIR LOS NOMBRES EXTERNOS ESPERADOS
	#
	# Exactamente la misma lógica que el renombrador.
	# ========================================================

	var groups: Dictionary = {}

	for internal_name in internal_names:
		var clean_base := _clean_base_name(
			internal_name
		)

		if not groups.has(clean_base):
			groups[clean_base] = []

		groups[clean_base].append(
			internal_name
		)

	var material_paths: Dictionary = {}

	var bases: Array = groups.keys()
	bases.sort()

	for base_variant in bases:
		var base := String(base_variant)
		var group: Array = groups[base]

		group.sort_custom(
			func(a, b):
				return (
					_sort_key_name(String(a))
					<
					_sort_key_name(String(b))
				)
		)

		if group.size() == 1:
			var internal_name := String(
				group[0]
			)

			material_paths[internal_name] = (
				MATERIALS_DIR.path_join(
					"paradise_island_"
						+ base
						+ ".tres"
				)
			)

		else:
			for i in range(group.size()):
				var internal_name := String(
					group[i]
				)

				var file_name := (
					"paradise_island_"
						+ base
						+ "_"
						+ str(i + 1).pad_zeros(2)
						+ ".tres"
				)

				material_paths[internal_name] = (
					MATERIALS_DIR.path_join(
						file_name
					)
				)

	# ========================================================
	# 4. VALIDAR LOS 115 MATERIALES
	#
	# TODAVÍA NO se modifica nada.
	# ========================================================

	print("")
	print("=== VALIDACIÓN ===")
	print("")

	var missing: Array[String] = []

	for internal_name in internal_names:
		if not material_paths.has(internal_name):
			missing.append(
				internal_name
			)
			continue

		var path := String(
			material_paths[internal_name]
		)

		if not FileAccess.file_exists(path):
			missing.append(
				internal_name
					+ "  ->  "
					+ path
			)

	if not missing.is_empty():
		print("")
		push_error(
			"FALTAN "
				+ str(missing.size())
				+ " asociaciones."
		)

		for item in missing:
			print(
				"FALTA: ",
				item
			)

		print("")
		print(
			"NO se ha modificado el .import."
		)
		return

	print(
		"Todos los materiales tienen "
			+ "archivo externo."
	)

	# ========================================================
	# 5. APLICAR DEDUPLICADOS CONFIRMADOS
	#
	# Lo hacemos por ARCHIVO EXTERNO ya resuelto,
	# no por nombre interno del GLB.
	#
	# Esto evita problemas con nombres internos raros como
	# _Linen_, _Yellow_, etc.
	# ========================================================

	print("")
	print(
		"=== DEDUPLICADOS CONFIRMADOS ==="
	)
	print("")

	for duplicate_file_variant in DUPLICATE_FILES:
		var duplicate_file := String(
			duplicate_file_variant
		)

		var canonical_file := String(
			DUPLICATE_FILES[duplicate_file]
		)

		var duplicate_internal_names: Array[String] = []

		# ----------------------------------------------------
		# Buscar qué material INTERNO del GLB estaba asociado
		# al .tres duplicado.
		# ----------------------------------------------------

		for internal_name_variant in material_paths:
			var internal_name := String(
				internal_name_variant
			)

			var external_path := String(
				material_paths[internal_name]
			)

			if external_path.get_file() == duplicate_file:
				duplicate_internal_names.append(
					internal_name
				)

		# Tiene que existir exactamente UNO.
		if duplicate_internal_names.size() != 1:
			push_error(
				"No puedo resolver de forma segura:\n"
					+ duplicate_file
					+ "\nCoincidencias internas: "
					+ str(
						duplicate_internal_names.size()
					)
			)
			return

		var duplicate_internal_name := (
			duplicate_internal_names[0]
		)

		# ----------------------------------------------------
		# Buscar el material canónico.
		# ----------------------------------------------------

		var canonical_path := (
			MATERIALS_DIR.path_join(
				canonical_file
			)
		)

		if not FileAccess.file_exists(
			canonical_path
		):
			push_error(
				"No existe material canónico:\n"
					+ canonical_path
			)
			return

		var old_path := String(
			material_paths[
				duplicate_internal_name
			]
		)

		# ----------------------------------------------------
		# El material interno del GLB pasa a utilizar
		# el mismo .tres que el material canónico.
		# ----------------------------------------------------

		material_paths[
			duplicate_internal_name
		] = canonical_path

		print(
			"INTERNO: ",
			duplicate_internal_name
		)

		print(
			"    ",
			old_path.get_file(),
			"  ->  ",
			canonical_file
		)

		print(
			"    candidato a quedar sin uso: ",
			duplicate_file
		)

		print("")

	# ========================================================
	# 6. ABRIR .IMPORT
	# ========================================================

	var config := ConfigFile.new()

	var err := config.load(
		IMPORT_FILE
	)

	if err != OK:
		push_error(
			"No puedo abrir:\n"
				+ IMPORT_FILE
				+ "\nError: "
				+ str(err)
		)
		return

	var subresources: Dictionary = (
		config.get_value(
			"params",
			"_subresources",
			{}
		)
	)

	var configured_materials: Dictionary = (
		subresources.get(
			"materials",
			{}
		)
	)

	# ========================================================
	# 7. CREAR USE EXTERNAL
	# ========================================================

	print("")
	print(
		"=== CREANDO ASOCIACIONES ==="
	)
	print("")

	var linked := 0

	for internal_name in internal_names:
		var external_path := String(
			material_paths[internal_name]
		)

		if not FileAccess.file_exists(
			external_path
		):
			push_error(
				"Ha desaparecido antes de enlazar:\n"
					+ external_path
			)
			return

		var uid_path := (
			ResourceUID.path_to_uid(
				external_path
			)
		)

		if uid_path.is_empty():
			push_error(
				"No puedo obtener UID para:\n"
					+ external_path
			)
			return

		configured_materials[
			internal_name
		] = {
			"use_external/enabled": true,
			"use_external/fallback_path":
				external_path,
			"use_external/path":
				uid_path,
		}

		print(
			internal_name,
			"  ->  ",
			external_path.get_file()
		)

		linked += 1

	# ========================================================
	# 8. GUARDAR CONFIGURACIÓN
	# ========================================================

	subresources["materials"] = (
		configured_materials
	)

	config.set_value(
		"params",
		"_subresources",
		subresources
	)

	# Ya NO queremos extracción automática de materiales.
	config.set_value(
		"params",
		"materials/extract",
		0
	)

	# Embedded Texture Handling:
	# Embed as Basis Universal.
	config.set_value(
		"params",
		"gltf/embedded_image_handling",
		2
	)

	err = config.save(
		IMPORT_FILE
	)

	if err != OK:
		push_error(
			"No puedo guardar:\n"
				+ IMPORT_FILE
				+ "\nError: "
				+ str(err)
		)
		return

	# ========================================================
	# 9. VERIFICAR ANTES DE REIMPORTAR
	# ========================================================

	var verify := ConfigFile.new()

	err = verify.load(
		IMPORT_FILE
	)

	if err != OK:
		push_error(
			"No puedo verificar el .import."
		)
		return

	var extract_mode := int(
		verify.get_value(
			"params",
			"materials/extract",
			-1
		)
	)

	var texture_mode := int(
		verify.get_value(
			"params",
			"gltf/embedded_image_handling",
			-1
		)
	)

	if extract_mode != 0:
		push_error(
			"materials/extract NO quedó en 0."
		)
		return

	if texture_mode != 2:
		push_error(
			"Embedded Texture Handling "
				+ "NO quedó en Basis Universal."
		)
		return

	print("")
	print(
		"Asociaciones creadas: ",
		linked
	)

	print(
		"materials/extract = 0"
	)

	print(
		"embedded_image_handling = 2"
	)

	# ========================================================
	# 10. REIMPORTAR
	# ========================================================

	print("")
	print(
		"Reimportando paradise_island.glb..."
	)
	print("")

	var fs := (
		EditorInterface
			.get_resource_filesystem()
	)

	fs.reimport_files(
		PackedStringArray([
			GLB
		])
	)

	# ========================================================
	# 11. VERIFICACIÓN DESPUÉS DEL REIMPORT
	# ========================================================

	var after := ConfigFile.new()

	err = after.load(
		IMPORT_FILE
	)

	if err != OK:
		push_error(
			"No puedo verificar después "
				+ "del reimport."
		)
		return

	var after_extract := int(
		after.get_value(
			"params",
			"materials/extract",
			-1
		)
	)

	var after_texture_mode := int(
		after.get_value(
			"params",
			"gltf/embedded_image_handling",
			-1
		)
	)

	if after_extract != 0:
		push_error(
			"Después del reimport, "
				+ "materials/extract cambió."
		)
		return

	if after_texture_mode != 2:
		push_error(
			"Después del reimport, "
				+ "Basis Universal cambió."
		)
		return

	print("")
	print(
		"=============================================="
	)
	print(
		"=== PARADISE ISLAND LINKED =================="
	)
	print(
		"=============================================="
	)
	print("")

	print(
		"Materiales internos enlazados: ",
		linked
	)

	print(
		"Extracción automática: DESACTIVADA"
	)

	print(
		"Texturas GLB: BASIS UNIVERSAL"
	)

	print("")
	print(
		"Comprueba Paradise Island visualmente."
	)

	print("")
	print(
		"Si todo está correcto, comprueba propietarios "
			+ "antes de borrar los 3 duplicados."
	)

	print("")
	print(
		"Candidatos:"
	)

	print(
		"paradise_island_color_09.tres"
	)

	print(
		"paradise_island_linen_02.tres"
	)

	print(
		"paradise_island_yellow_03.tres"
	)


# ============================================================
# MISMA FUNCIÓN DE NOMBRES QUE EL RENOMBRADOR
# ============================================================

func _clean_base_name(
	original: String
) -> String:
	var s := original

	var blender_suffix := RegEx.new()
	blender_suffix.compile("\\.\\d{3}$")

	s = blender_suffix.sub(
		s,
		"",
		true
	)

	s = s.replace("[", "")
	s = s.replace("]", "")
	s = s.replace("~", "_")

	var lower := s.to_lower()

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

	if lower.begins_with("aerial_rocks"):
		return "aerial_rocks"

	if lower.begins_with("carpet_"):
		return "carpet"

	if lower.begins_with("metal_06"):
		return "metal"

	if lower == "rufo":
		return "rufo"

	if (
		lower == "white"
		or lower == "white1"
	):
		return "white"

	if (
		lower == "wood 1"
		or lower == "wood 2"
	):
		return "wood"

	if lower == "wicker rattan":
		return "wicker_rattan"

	if lower.begins_with("color "):
		return "color"

	if lower.begins_with("color_"):
		return "color"

	if lower.contains("corrogateshiny"):
		return "corrogate_shiny"

	if lower.contains("linen"):
		return "linen"

	if lower.contains("metal-floor"):
		return "metal_floor"

	if (
		lower
			.trim_prefix("_")
			.trim_suffix("_")
			== "yellow"
	):
		return "yellow"

	if (
		lower
			.trim_prefix("_")
			.is_valid_int()
	):
		return "material"

	s = s.to_lower()

	s = s.replace(" ", "_")
	s = s.replace("-", "_")
	s = s.replace(".", "_")

	var leading_code := RegEx.new()
	leading_code.compile("^\\d+[_-]*")

	s = leading_code.sub(
		s,
		"",
		true
	)

	var resolution_code := RegEx.new()
	resolution_code.compile(
		"(^|_)\\d+k($|_)"
	)

	s = resolution_code.sub(
		s,
		"_",
		true
	)

	var trailing_number := RegEx.new()
	trailing_number.compile(
		"[_ ]?\\d+$"
	)

	s = trailing_number.sub(
		s,
		"",
		true
	)

	var invalid := RegEx.new()
	invalid.compile("[^a-z0-9_]")

	s = invalid.sub(
		s,
		"_",
		true
	)

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
# MISMO ORDEN QUE EL RENOMBRADOR,
# pero trabajando directamente con nombres internos del GLB.
# ============================================================

func _sort_key_name(
	internal_name: String
) -> String:
	var regex := RegEx.new()
	regex.compile("\\.(\\d{3})$")

	var result := regex.search(
		internal_name
	)

	if result == null:
		return (
			"000000_"
			+ internal_name
		)

	var number := int(
		result.get_string(1)
	)

	return (
		str(number + 1).pad_zeros(6)
			+ "_"
			+ internal_name
	)
