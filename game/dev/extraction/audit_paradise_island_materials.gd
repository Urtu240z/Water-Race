@tool
extends EditorScript

const LOCAL_DIR := "res://levels/paradise_island/terrain/materials"

# Sitios donde YA tenemos materiales que podrían reutilizarse.
# NO modifica ninguno.
const REUSE_ROOTS := [
	"res://shared/materials",
	"res://world/props/rocks/materials",
	"res://world/props/terrain/materials",
	"res://world/vegetation/palms/materials",
]


func _run() -> void:
	print("")
	print("==============================================")
	print("=== PARADISE ISLAND MATERIAL AUDIT ==========")
	print("==============================================")
	print("")

	var local_paths := _collect_materials_recursive(LOCAL_DIR)

	if local_paths.is_empty():
		push_error("No encuentro materiales en: " + LOCAL_DIR)
		return

	var external_paths: Array[String] = []

	for root in REUSE_ROOTS:
		external_paths.append_array(
			_collect_materials_recursive(root)
		)

	print("Materiales Paradise: ", local_paths.size())
	print("Materiales externos analizados: ", external_paths.size())
	print("")

	var local_info := _build_info(local_paths)
	var external_info := _build_info(external_paths)

	_print_local_name_groups(local_info)
	_print_exact_local_duplicates(local_info)
	_print_external_candidates(local_info, external_info)

	print("")
	print("==============================================")
	print("=== FIN AUDITORIA ============================")
	print("==============================================")
	print("")
	print("NO se ha modificado ningún archivo.")


# ============================================================
# RECOGIDA DE ARCHIVOS
# ============================================================

func _collect_materials_recursive(root: String) -> Array[String]:
	var result: Array[String] = []

	if not DirAccess.dir_exists_absolute(root):
		return result

	_collect_recursive(root, result)

	result.sort()

	return result


func _collect_recursive(
	current_dir: String,
	result: Array[String]
) -> void:
	var dir := DirAccess.open(current_dir)

	if dir == null:
		return

	for file_name in dir.get_files():
		var extension := file_name.get_extension().to_lower()

		if extension != "tres" and extension != "res":
			continue

		var path := current_dir.path_join(file_name)

		var resource := ResourceLoader.load(
			path,
			"",
			ResourceLoader.CACHE_MODE_IGNORE
		)

		if resource is Material:
			result.append(path)

	for directory_name in dir.get_directories():
		_collect_recursive(
			current_dir.path_join(directory_name),
			result
		)


# ============================================================
# INFORMACIÓN DE CADA MATERIAL
# ============================================================

func _build_info(paths: Array[String]) -> Array[Dictionary]:
	var info: Array[Dictionary] = []

	for path in paths:
		var resource := ResourceLoader.load(
			path,
			"",
			ResourceLoader.CACHE_MODE_IGNORE
		)

		if not resource is Material:
			continue

		var material := resource as Material

		var resource_name := String(material.resource_name)

		# Si por alguna razón resource_name está vacío,
		# usamos el nombre de archivo únicamente como ayuda.
		if resource_name.is_empty():
			resource_name = path.get_file().get_basename()

		info.append({
			"path": path,
			"file": path.get_file(),
			"resource_name": resource_name,
			"signature": _material_signature(material),
		})

	return info


# ============================================================
# 1. MISMO resource_name DENTRO DE PARADISE
# ============================================================

func _print_local_name_groups(
	info: Array[Dictionary]
) -> void:
	print("")
	print("=== 1. RESOURCE_NAME REPETIDOS EN PARADISE ===")
	print("")

	var groups: Dictionary = {}

	for item in info:
		var name := String(item["resource_name"])

		if not groups.has(name):
			groups[name] = []

		groups[name].append(item)

	var found := false

	var names := groups.keys()
	names.sort()

	for name_variant in names:
		var name := String(name_variant)
		var entries: Array = groups[name]

		if entries.size() <= 1:
			continue

		found = true

		print(
			"RESOURCE_NAME: ",
			name,
			"  x",
			entries.size()
		)

		var signatures: Dictionary = {}

		for entry_variant in entries:
			var entry: Dictionary = entry_variant

			print(
				"    ",
				entry["file"]
			)

			var signature := String(entry["signature"])

			if not signatures.has(signature):
				signatures[signature] = 0

			signatures[signature] += 1

		if signatures.size() == 1:
			print(
				"    >>> EXACTAMENTE IGUALES SEGUN PROPIEDADES"
			)
		else:
			print(
				"    >>> MISMO NOMBRE PERO PROPIEDADES DIFERENTES"
			)

		print("")

	if not found:
		print("No hay resource_name repetidos.")


# ============================================================
# 2. DUPLICADOS EXACTOS AUNQUE TENGAN NOMBRES DISTINTOS
# ============================================================

func _print_exact_local_duplicates(
	info: Array[Dictionary]
) -> void:
	print("")
	print("=== 2. DUPLICADOS EXACTOS EN PARADISE ===")
	print("")

	var groups: Dictionary = {}

	for item in info:
		var signature := String(item["signature"])

		if not groups.has(signature):
			groups[signature] = []

		groups[signature].append(item)

	var found := false

	for signature_variant in groups:
		var entries: Array = groups[signature_variant]

		if entries.size() <= 1:
			continue

		found = true

		print(
			"GRUPO EXACTO x",
			entries.size()
		)

		for entry_variant in entries:
			var entry: Dictionary = entry_variant

			print(
				"    ",
				entry["file"],
				"    [resource_name=",
				entry["resource_name"],
				"]"
			)

		print("")

	if not found:
		print(
			"No hay duplicados exactos detectables por propiedades."
		)


# ============================================================
# 3. POSIBLES MATERIALES YA EXISTENTES FUERA DE PARADISE
# ============================================================

func _print_external_candidates(
	local_info: Array[Dictionary],
	external_info: Array[Dictionary]
) -> void:
	print("")
	print("=== 3. CANDIDATOS A REUTILIZAR ===")
	print("")

	var external_by_name: Dictionary = {}

	for item in external_info:
		var name := String(item["resource_name"])

		if not external_by_name.has(name):
			external_by_name[name] = []

		external_by_name[name].append(item)

	var found := false

	for local_item in local_info:
		var local_name := String(
			local_item["resource_name"]
		)

		if not external_by_name.has(local_name):
			continue

		found = true

		print("")
		print(
			"PARADISE: ",
			local_item["file"],
			"    resource_name=",
			local_name
		)

		var candidates: Array = external_by_name[
			local_name
		]

		for candidate_variant in candidates:
			var candidate: Dictionary = candidate_variant

			var exact := (
				String(local_item["signature"])
				==
				String(candidate["signature"])
			)

			if exact:
				print(
					"    >>> MATCH EXACTO: ",
					candidate["path"]
				)
			else:
				print(
					"    ? MISMO RESOURCE_NAME: ",
					candidate["path"]
				)

	if not found:
		print(
			"No se encontraron resource_name coincidentes fuera."
		)


# ============================================================
# FIRMA DE MATERIAL
#
# Compara propiedades guardadas del Material.
# resource_name/resource_path se ignoran deliberadamente.
#
# Las texturas externas se identifican por su resource_path.
# Esto evita declarar iguales dos materiales solo porque
# tengan el mismo nombre.
# ============================================================

func _material_signature(
	material: Material
) -> String:
	var parts: Array[String] = []

	parts.append(
		"CLASS=" + material.get_class()
	)

	var properties := material.get_property_list()

	for property_variant in properties:
		var property: Dictionary = property_variant

		var usage := int(property["usage"])

		if (usage & PROPERTY_USAGE_STORAGE) == 0:
			continue

		var property_name := String(property["name"])

		if property_name in [
			"resource_name",
			"resource_path",
			"resource_local_to_scene",
			"resource_scene_unique_id",
		]:
			continue

		var value = material.get(property_name)

		parts.append(
			property_name
			+ "="
			+ _variant_signature(value, {})
		)

	parts.sort()

	return "\n".join(parts)


func _variant_signature(
	value,
	seen: Dictionary
) -> String:
	if value == null:
		return "null"

	if value is Resource:
		var resource := value as Resource

		# Si es recurso externo, su path es su identidad.
		if not resource.resource_path.is_empty():
			return (
				resource.get_class()
				+ "@"
				+ resource.resource_path
			)

		return _embedded_resource_signature(
			resource,
			seen
		)

	if value is Array:
		var result: Array[String] = []

		for item in value:
			result.append(
				_variant_signature(item, seen)
			)

		return "[" + ",".join(result) + "]"

	if value is Dictionary:
		var result: Array[String] = []

		var keys: Array = value.keys()
		keys.sort()

		for key in keys:
			result.append(
				str(key)
				+ ":"
				+ _variant_signature(
					value[key],
					seen
				)
			)

		return "{" + ",".join(result) + "}"

	return var_to_str(value)


func _embedded_resource_signature(
	resource: Resource,
	seen: Dictionary
) -> String:
	var object_id := resource.get_instance_id()

	if seen.has(object_id):
		return "<cycle>"

	seen[object_id] = true

	var parts: Array[String] = []

	parts.append(
		"CLASS=" + resource.get_class()
	)

	for property_variant in resource.get_property_list():
		var property: Dictionary = property_variant

		var usage := int(property["usage"])

		if (usage & PROPERTY_USAGE_STORAGE) == 0:
			continue

		var property_name := String(property["name"])

		if property_name in [
			"resource_name",
			"resource_path",
			"resource_local_to_scene",
			"resource_scene_unique_id",
		]:
			continue

		var value = resource.get(property_name)

		parts.append(
			property_name
			+ "="
			+ _variant_signature(
				value,
				seen
			)
		)

	parts.sort()

	seen.erase(object_id)

	return (
		"{"
		+ "\n".join(parts)
		+ "}"
	)
