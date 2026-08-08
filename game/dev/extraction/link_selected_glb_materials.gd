@tool
extends EditorScript


# ============================================================
# LINK SELECTED GLB MATERIALS
# ============================================================
#
# OBJETIVO:
#
# - Seleccionas UN .glb en el FileSystem.
# - El script lee los nombres de materiales internos.
# - Busca los .tres/.res de la carpeta hermana "materials".
# - Los compara usando resource_name.
# - Si hay duplicados, prefiere el archivo renombrado que
#   empiece por el nombre del GLB:
#
#       boat_01_hull.tres
#       boat_02_glass_gray.tres
#
# - Configura Use External.
# - Desactiva la extracción automática de materiales.
# - Reimporta el GLB.
#
# NO:
# - renombra archivos
# - borra archivos
# - extrae texturas
# - adivina asociaciones dudosas
#
# Si no puede resolver TODOS los materiales, ABORTA
# sin modificar el .import.
# ============================================================


func _run() -> void:
	var selected := EditorInterface.get_selected_paths()

	var glb_paths: Array[String] = []

	for selected_path in selected:
		var path := String(selected_path)

		if path.to_lower().ends_with(".glb"):
			glb_paths.append(path)


	if glb_paths.size() != 1:
		push_error(
			"Selecciona exactamente UN archivo .glb "
			+ "en el FileSystem."
		)
		return


	var glb_path := glb_paths[0]

	_link_glb(glb_path)


# ============================================================
# PROCESAR GLB
# ============================================================

func _link_glb(glb_path: String) -> void:
	print("")
	print("================================================")
	print(" LINK GLB EXTERNAL MATERIALS")
	print("================================================")
	print("")
	print("GLB: ", glb_path)


	var asset_name := glb_path.get_file().get_basename()

	var base_dir := glb_path.get_base_dir()

	var materials_dir := base_dir.path_join(
		"materials"
	)

	var import_path := glb_path + ".import"


	print("Materials: ", materials_dir)
	print("Import: ", import_path)


	# ========================================================
	# VALIDACIONES BÁSICAS
	# ========================================================

	if not FileAccess.file_exists(glb_path):
		push_error(
			"No existe el GLB:\n" + glb_path
		)
		return


	if not FileAccess.file_exists(import_path):
		push_error(
			"No existe el .import:\n" + import_path
		)
		return


	var global_materials_dir := (
		ProjectSettings.globalize_path(
			materials_dir
		)
	)


	if not DirAccess.dir_exists_absolute(
		global_materials_dir
	):
		push_error(
			"No existe la carpeta:\n"
			+ materials_dir
		)
		return


	# ========================================================
	# LEER GLB
	# ========================================================

	print("")
	print("Leyendo materiales internos del GLB...")


	var state := GLTFState.new()


	# ========================================================
	# MUY IMPORTANTE
	#
	# Solo queremos inspeccionar los nombres de materiales.
	#
	# NO queremos que GLTFDocument extraiga las texturas
	# embebidas mientras lee el archivo.
	# ========================================================

	state.handle_binary_image_mode = (
		GLTFState.HANDLE_BINARY_IMAGE_MODE_DISCARD_TEXTURES
	)


	var document := GLTFDocument.new()


	var gltf_error := document.append_from_file(
		glb_path,
		state
	)


	if gltf_error != OK:
		push_error(
			"No se pudo leer el GLB. Error: %s"
			% gltf_error
		)
		return


	var gltf_materials := state.get_materials()


	if gltf_materials.is_empty():
		push_error(
			"El GLB no contiene materiales."
		)
		return


	# ========================================================
	# OBTENER NOMBRES INTERNOS
	# ========================================================

	var internal_names: Array[String] = []


	for material in gltf_materials:
		if material == null:
			continue


		var material_name := String(
			material.resource_name
		)


		if material_name.is_empty():
			push_error(
				"Hay un material del GLB sin nombre."
			)
			return


		if internal_names.has(material_name):
			push_error(
				"Hay dos materiales internos con "
				+ "el mismo nombre:\n"
				+ material_name
			)
			return


		internal_names.append(material_name)


	print(
		"Materiales internos encontrados: ",
		internal_names.size()
	)


	# ========================================================
	# INDEXAR MATERIALES EXTERNOS
	# ========================================================

	print("")
	print("Leyendo materiales externos...")


	var external_index := (
		_index_external_materials(
			materials_dir
		)
	)


	if external_index.is_empty():
		push_error(
			"No encontré materiales .tres/.res válidos en:\n"
			+ materials_dir
		)
		return


	# ========================================================
	# LEER .IMPORT
	# ========================================================

	var config := ConfigFile.new()


	var config_error := config.load(
		import_path
	)


	if config_error != OK:
		push_error(
			"No se pudo leer:\n"
			+ import_path
			+ "\nError: "
			+ str(config_error)
		)
		return


	var subresources: Dictionary = config.get_value(
		"params",
		"_subresources",
		{}
	)


	var configured_materials: Dictionary = (
		subresources.get(
			"materials",
			{}
		)
	)


	# ========================================================
	# RESOLVER ASOCIACIONES
	# ========================================================
	#
	# NO modificamos todavía el .import.
	#
	# Primero tenemos que encontrar una asociación segura
	# para TODOS los materiales.
	# ========================================================

	var resolved: Dictionary = {}

	var unresolved: Array[String] = []


	print("")
	print("Buscando asociaciones...")
	print("")


	var expected_prefix := (
		asset_name.to_lower()
		+ "_"
	)


	for internal_name in internal_names:

		var candidates: Array = external_index.get(
			internal_name,
			[]
		)


		# ====================================================
		# BUSCAR MATERIAL RENOMBRADO
		#
		# Ejemplo:
		#
		# interno:
		# [Translucent_Glass_Gray]
		#
		# candidatos:
		# [Translucent_Glass_Gray].tres
		# boat_02_glass_gray.tres
		#
		# Preferimos boat_02_...
		# ====================================================

		var preferred: Array[String] = []


		for candidate_variant in candidates:
			var candidate := String(
				candidate_variant
			)

			var candidate_file := (
				candidate
				.get_file()
				.to_lower()
			)


			if candidate_file.begins_with(
				expected_prefix
			):
				preferred.append(candidate)


		# ====================================================
		# 1. UN RENOMBRADO CLARO
		# ====================================================

		if preferred.size() == 1:
			var selected_path := preferred[0]

			resolved[internal_name] = selected_path


			print(
				"OK RENOMBRADO   ",
				internal_name,
				"  ->  ",
				selected_path.get_file()
			)

			continue


		# ====================================================
		# 2. MÁS DE UN RENOMBRADO = AMBIGUO
		# ====================================================

		if preferred.size() > 1:
			unresolved.append(
				internal_name
			)


			print(
				"AMBIGUO         ",
				internal_name
			)


			for path in preferred:
				print(
					"   -> ",
					path
				)


			continue


		# ====================================================
		# 3. COMPROBAR USE EXTERNAL EXISTENTE
		# ====================================================

		var existing_path := (
			_get_existing_external_path(
				configured_materials,
				internal_name
			)
		)


		if not existing_path.is_empty():

			# Si la asociación existente apunta al material
			# antiguo, pero solo tenemos ese material,
			# podemos conservarla.

			resolved[internal_name] = (
				existing_path
			)


			print(
				"OK EXISTENTE    ",
				internal_name,
				"  ->  ",
				existing_path.get_file()
			)

			continue


		# ====================================================
		# 4. SOLO EXISTE UN CANDIDATO
		# ====================================================

		if candidates.size() == 1:
			var selected_path := String(
				candidates[0]
			)


			resolved[internal_name] = (
				selected_path
			)


			print(
				"OK ÚNICO        ",
				internal_name,
				"  ->  ",
				selected_path.get_file()
			)

			continue


		# ====================================================
		# 5. NO HAY CANDIDATO
		# ====================================================

		if candidates.is_empty():
			unresolved.append(
				internal_name
			)


			print(
				"NO ENCONTRADO   ",
				internal_name
			)

			continue


		# ====================================================
		# 6. VARIOS CANDIDATOS Y NINGUNO ES CLARO
		# ====================================================

		unresolved.append(
			internal_name
		)


		print(
			"AMBIGUO         ",
			internal_name
		)


		for candidate_variant in candidates:
			print(
				"   -> ",
				String(candidate_variant)
			)


	# ========================================================
	# ABORTAR SI FALTA UNO SOLO
	# ========================================================

	if not unresolved.is_empty():

		print("")
		print("================================================")
		print(" NO SE HA MODIFICADO NADA")
		print("================================================")
		print("")


		print(
			"Materiales sin resolver: ",
			unresolved.size()
		)


		for material_name in unresolved:
			print(
				" - ",
				material_name
			)


		push_error(
			"No se han podido asociar todos "
			+ "los materiales."
		)

		return


	# ========================================================
	# TODOS RESUELTOS
	# ========================================================

	print("")
	print("================================================")
	print(" TODOS LOS MATERIALES RESUELTOS")
	print("================================================")
	print("")


	# ========================================================
	# CREAR USE EXTERNAL
	# ========================================================

	for internal_name in resolved:

		var external_path := String(
			resolved[internal_name]
		)


		var uid_path := ResourceUID.path_to_uid(
			external_path
		)


		configured_materials[internal_name] = {
			"use_external/enabled": true,
			"use_external/fallback_path": external_path,
			"use_external/path": uid_path,
		}


	subresources["materials"] = (
		configured_materials
	)


	config.set_value(
		"params",
		"_subresources",
		subresources
	)


	# ========================================================
	# DESACTIVAR EXTRACCIÓN AUTOMÁTICA
	# ========================================================
	#
	# IMPORTANTE:
	#
	# Esto NO hace que los materiales efectivos sean
	# internos.
	#
	# Los Use External anteriores siguen activos.
	#
	# Solo impedimos que Godot vuelva a crear:
	#
	# [Blue].tres
	# [WarmGray1].tres
	# Material.001.tres
	# etc.
	# ========================================================

	config.set_value(
		"params",
		"materials/extract",
		0
	)


	# ========================================================
	# GUARDAR .IMPORT
	# ========================================================

	print("Guardando configuración...")


	var save_error := config.save(
		import_path
	)


	if save_error != OK:
		push_error(
			"No se pudo guardar el .import. Error: %s"
			% save_error
		)
		return


	# ========================================================
	# VERIFICACIÓN ANTES DE REIMPORTAR
	# ========================================================

	var verify := ConfigFile.new()


	var verify_error := verify.load(
		import_path
	)


	if verify_error != OK:
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


	print(
		"materials/extract antes del reimport = ",
		extract_mode
	)


	if extract_mode != 0:
		push_error(
			"ABORTADO: materials/extract "
			+ "NO está en 0."
		)

		return


	# ========================================================
	# REIMPORTAR
	# ========================================================

	print("")
	print(
		"Configuración correcta."
	)

	print(
		"Reimportando ",
		glb_path,
		"..."
	)


	var filesystem := (
		EditorInterface.get_resource_filesystem()
	)


	# reimport_files bloquea hasta finalizar.
	filesystem.reimport_files(
		PackedStringArray(
			[glb_path]
		)
	)


	# ========================================================
	# COMPROBACIÓN DESPUÉS DEL REIMPORT
	# ========================================================

	var final_check := ConfigFile.new()


	var final_error := final_check.load(
		import_path
	)


	if final_error != OK:
		push_error(
			"No puedo comprobar el .import "
			+ "después del reimport."
		)
		return


	var final_extract := int(
		final_check.get_value(
			"params",
			"materials/extract",
			-1
		)
	)


	print("")
	print(
		"materials/extract después del reimport = ",
		final_extract
	)


	if final_extract != 0:
		push_error(
			"ATENCIÓN: Godot ha vuelto a cambiar "
			+ "materials/extract."
		)

		return


	# ========================================================
	# FIN
	# ========================================================

	print("")
	print("================================================")
	print(" TERMINADO CORRECTAMENTE")
	print("================================================")
	print("")

	print(
		"Materiales enlazados: ",
		resolved.size()
	)

	print(
		"Extracción automática: DESACTIVADA"
	)

	print(
		"Texturas durante inspección: IGNORADAS"
	)

	print("")
	print(
		"Ahora puedes hacer otro Reimport manual "
		+ "como prueba."
	)


# ============================================================
# INDEXAR MATERIALES EXTERNOS
# ============================================================

func _index_external_materials(
	materials_dir: String
) -> Dictionary:

	var result: Dictionary = {}


	var dir := DirAccess.open(
		materials_dir
	)


	if dir == null:
		return result


	dir.list_dir_begin()


	var file_name := dir.get_next()


	while not file_name.is_empty():

		if not dir.current_is_dir():

			var extension := (
				file_name
					.get_extension()
					.to_lower()
			)


			if (
				extension == "tres"
				or extension == "res"
			):

				var path := (
					materials_dir.path_join(
						file_name
					)
				)


				var resource := (
					ResourceLoader.load(
						path
					)
				)


				if resource is Material:

					var resource_name := String(
						resource.resource_name
					)


					if not resource_name.is_empty():

						if not result.has(
							resource_name
						):
							result[
								resource_name
							] = []


						result[
							resource_name
						].append(
							path
						)


		file_name = dir.get_next()


	dir.list_dir_end()


	return result


# ============================================================
# COMPROBAR ASOCIACIÓN EXISTENTE
# ============================================================

func _get_existing_external_path(
	configured_materials: Dictionary,
	internal_name: String
) -> String:

	if not configured_materials.has(
		internal_name
	):
		return ""


	var data = configured_materials[
		internal_name
	]


	if not data is Dictionary:
		return ""


	if not data.get(
		"use_external/enabled",
		false
	):
		return ""


	# ========================================================
	# PRIMERO FALLBACK PATH
	# ========================================================

	var fallback_path := String(
		data.get(
			"use_external/fallback_path",
			""
		)
	)


	if (
		not fallback_path.is_empty()
		and FileAccess.file_exists(
			fallback_path
		)
	):
		return fallback_path


	# ========================================================
	# DESPUÉS UID
	# ========================================================

	var uid_path := String(
		data.get(
			"use_external/path",
			""
		)
	)


	if uid_path.begins_with(
		"uid://"
	):

		var resolved_path := (
			ResourceUID.uid_to_path(
				uid_path
			)
		)


		if (
			not resolved_path.is_empty()
			and FileAccess.file_exists(
				resolved_path
			)
		):
			return resolved_path


	return ""
