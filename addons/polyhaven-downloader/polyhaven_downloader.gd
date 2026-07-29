@tool
@icon("res://addons/polyhaven-downloader/polyhaven_icon.png")
extends Node


const PREFIX: String = "https://polyhaven.com/a/"

const DOWNLOAD_ROOT: String = \
	"https://dl.polyhaven.org/file/ph-assets/Textures"

const COMPRESS_MODE_VRAM: int = 2
const NORMAL_MAP_DETECT: int = 0
const NORMAL_MAP_ENABLE: int = 1

const MAX_WAIT_FRAMES: int = 1800


## Slug o URL completa de Poly Haven.
@export var requested_texture: String:
	set(value):
		var clean_value: String = (
			value.strip_edges().to_lower()
		)

		if clean_value.begins_with(PREFIX):
			requested_texture = clean_value.substr(
				PREFIX.length()
			)
		else:
			requested_texture = clean_value


## Resolución de las texturas.
@export_enum("1k", "2k", "4k", "8k")
var texture_size: String = "1k"


## Carpeta donde se guardará el material.
@export_dir
var materials_dir: String = "res://assets/materials"


## Material base.
@export
var blueprint: ORMMaterial3D = preload(
	"res://addons/polyhaven-downloader/blueprint.tres"
)


## Activa esta casilla para iniciar la descarga.
@export var download: bool = false:
	set(value):
		download = false

		if not value:
			return

		if _is_downloading:
			push_warning(
				"Ya hay una textura descargándose."
			)
			return

		_download_requested = true
		set_process(true)


var _download_requested: bool = false
var _is_downloading: bool = false


func _ready() -> void:
	set_process(false)


func _process(_delta: float) -> void:
	if not _download_requested:
		set_process(false)
		return

	_download_requested = false
	set_process(false)

	_is_downloading = true
	_run_download()


func _run_download() -> void:
	await download_texture()
	_is_downloading = false


func download_texture() -> void:
	if requested_texture.is_empty():
		push_error(
			"Requested Texture está vacío."
		)
		return

	if not materials_dir.begins_with("res://"):
		push_error(
			"Materials Dir debe estar dentro de res://"
		)
		return

	print("")
	print("========================================")
	print("DESCARGANDO MATERIAL DE POLY HAVEN")
	print("Textura: ", requested_texture)
	print("Resolución: ", texture_size)
	print("========================================")


	# ========================================================
	# CREAR CARPETAS
	# ========================================================

	var textures_directory: String = (
		materials_dir.path_join(
			requested_texture + "_textures"
		)
	)

	var absolute_directory: String = (
		ProjectSettings.globalize_path(
			textures_directory
		)
	)

	var directory_error: Error = (
		DirAccess.make_dir_recursive_absolute(
			absolute_directory
		)
	)

	if directory_error != OK:
		push_error(
			"No se pudo crear la carpeta: "
			+ textures_directory
			+ ". Código: "
			+ str(directory_error)
		)
		return


	# ========================================================
	# RUTAS DE LAS TEXTURAS
	# ========================================================

	var albedo_path: String = (
		textures_directory.path_join(
			requested_texture
			+ "_albedo_"
			+ texture_size
			+ ".jpg"
		)
	)

	var orm_path: String = (
		textures_directory.path_join(
			requested_texture
			+ "_orm_"
			+ texture_size
			+ ".jpg"
		)
	)

	var normal_path: String = (
		textures_directory.path_join(
			requested_texture
			+ "_normal_"
			+ texture_size
			+ ".jpg"
		)
	)


	# ========================================================
	# DESCARGAR ARCHIVOS
	# ========================================================

	var albedo_ok: bool = (
		await _download_first_available(
			PackedStringArray([
				"diff",
				"diffuse",
			]),
			albedo_path,
			"Albedo"
		)
	)

	var orm_ok: bool = (
		await _download_first_available(
			PackedStringArray([
				"arm",
			]),
			orm_path,
			"ORM"
		)
	)

	var normal_ok: bool = (
		await _download_first_available(
			PackedStringArray([
				"nor_gl",
			]),
			normal_path,
			"Normal"
		)
	)

	if not albedo_ok or not orm_ok or not normal_ok:
		push_error(
			"No se descargaron correctamente "
			+ "los tres mapas."
		)
		return

	var texture_paths: PackedStringArray = (
		PackedStringArray([
			albedo_path,
			orm_path,
			normal_path,
		])
	)


	# ========================================================
	# ESPERAR A SALIR DEL CALLBACK HTTP
	# ========================================================

	await get_tree().process_frame
	await get_tree().process_frame


	# ========================================================
	# ESCANEO E IMPORTACIÓN INICIAL
	# ========================================================

	var editor_filesystem: EditorFileSystem = (
		EditorInterface.get_resource_filesystem()
	)

	var idle_before_scan: bool = (
		await _wait_for_editor_idle(
			editor_filesystem
		)
	)

	if not idle_before_scan:
		return

	print("Escaneando los nuevos archivos...")

	editor_filesystem.scan()

	var initial_import_ok: bool = (
		await _wait_for_initial_import(
			editor_filesystem,
			texture_paths
		)
	)

	if not initial_import_ok:
		push_error(
			"Godot no terminó la importación inicial "
			+ "de las texturas."
		)
		return


	# ========================================================
	# CONFIGURAR LOS ARCHIVOS .IMPORT
	# ========================================================

	var albedo_configured: bool = (
		_configure_texture_import(
			albedo_path,
			false
		)
	)

	var orm_configured: bool = (
		_configure_texture_import(
			orm_path,
			false
		)
	)

	var normal_configured: bool = (
		_configure_texture_import(
			normal_path,
			true
		)
	)

	if (
		not albedo_configured
		or not orm_configured
		or not normal_configured
	):
		push_error(
			"No se pudieron configurar todos "
			+ "los archivos .import."
		)
		return


	# ========================================================
	# REIMPORTAR CON LA CONFIGURACIÓN DEFINITIVA
	# ========================================================

	await get_tree().process_frame
	await get_tree().process_frame

	var idle_before_reimport: bool = (
		await _wait_for_editor_idle(
			editor_filesystem
		)
	)

	if not idle_before_reimport:
		return

	print(
		"Reimportando con VRAM Compressed, "
		+ "alta calidad y mipmaps..."
	)

	editor_filesystem.reimport_files(
		texture_paths
	)

	await get_tree().process_frame


	# ========================================================
	# CARGAR TEXTURAS IMPORTADAS
	# ========================================================

	var albedo_texture: Texture2D = (
		_load_imported_texture(
			albedo_path
		)
	)

	var orm_texture: Texture2D = (
		_load_imported_texture(
			orm_path
		)
	)

	var normal_texture: Texture2D = (
		_load_imported_texture(
			normal_path
		)
	)

	if (
		albedo_texture == null
		or orm_texture == null
		or normal_texture == null
	):
		push_error(
			"No se pudieron cargar las texturas "
			+ "después de importarlas."
		)
		return


	# ========================================================
	# CREAR MATERIAL
	# ========================================================

	var material: ORMMaterial3D = (
		blueprint.duplicate(true) as ORMMaterial3D
	)

	if material == null:
		push_error(
			"No se pudo duplicar el blueprint."
		)
		return

	material.resource_name = requested_texture

	material.albedo_texture = albedo_texture

	material.normal_enabled = true
	material.normal_texture = normal_texture

	material.ao_enabled = true
	material.orm_texture = orm_texture

	material.uv1_world_triplanar = true


	# ========================================================
	# GUARDAR MATERIAL
	# ========================================================

	var material_path: String = (
		materials_dir.path_join(
			requested_texture + ".res"
		)
	)

	var save_error: Error = (
		ResourceSaver.save(
			material,
			material_path
		)
	)

	if save_error != OK:
		push_error(
			"No se pudo guardar el material: "
			+ material_path
			+ ". Código: "
			+ str(save_error)
		)
		return

	editor_filesystem.update_file(
		material_path
	)

	print("")
	print("========================================")
	print("MATERIAL CREADO CORRECTAMENTE")
	print("Material: ", material_path)
	print("Texturas: ", textures_directory)
	print("========================================")
	print("")


func _wait_for_editor_idle(
	editor_filesystem: EditorFileSystem
) -> bool:
	for frame_index: int in range(
		MAX_WAIT_FRAMES
	):
		if (
			not editor_filesystem.is_scanning()
			and not editor_filesystem.is_importing()
		):
			return true

		await get_tree().process_frame

	push_error(
		"Tiempo de espera agotado esperando "
		+ "al sistema de archivos de Godot."
	)

	return false


func _wait_for_initial_import(
	editor_filesystem: EditorFileSystem,
	texture_paths: PackedStringArray
) -> bool:
	for frame_index: int in range(
		MAX_WAIT_FRAMES
	):
		var import_files_exist: bool = true

		for texture_path: String in texture_paths:
			var import_path: String = (
				texture_path + ".import"
			)

			if not FileAccess.file_exists(
				import_path
			):
				import_files_exist = false
				break

		if (
			import_files_exist
			and not editor_filesystem.is_scanning()
			and not editor_filesystem.is_importing()
		):
			return true

		await get_tree().process_frame

	return false


func _download_first_available(
	map_types: PackedStringArray,
	output_path: String,
	map_label: String
) -> bool:
	for map_type: String in map_types:
		var downloaded_data: PackedByteArray = (
			await _download_bytes(
				map_type
			)
		)

		if downloaded_data.is_empty():
			continue

		var saved: bool = (
			_save_downloaded_file(
				downloaded_data,
				output_path
			)
		)

		if saved:
			print(
				map_label,
				" guardado: ",
				output_path
			)

			return true

	push_error(
		"No se encontró el mapa "
		+ map_label
		+ " para "
		+ requested_texture
	)

	return false


func _download_bytes(
	map_type: String
) -> PackedByteArray:
	var url: String = (
		DOWNLOAD_ROOT
		+ "/jpg/"
		+ texture_size
		+ "/"
		+ requested_texture
		+ "/"
		+ requested_texture
		+ "_"
		+ map_type
		+ "_"
		+ texture_size
		+ ".jpg"
	)

	print("Solicitando: ", url)

	var http: HTTPRequest = HTTPRequest.new()
	add_child(http)

	var request_error: Error = (
		http.request(url)
	)

	if request_error != OK:
		push_error(
			"Error iniciando la solicitud HTTP. "
			+ "Código: "
			+ str(request_error)
		)

		http.queue_free()

		return PackedByteArray()

	var response: Array = (
		await http.request_completed
	)

	http.queue_free()

	if response.size() < 4:
		push_error(
			"La respuesta HTTP está incompleta."
		)
		return PackedByteArray()

	var result: int = int(response[0])
	var response_code: int = int(response[1])
	var body: PackedByteArray = (
		response[3] as PackedByteArray
	)

	if response_code == 404:
		print(
			"No existe el mapa ",
			map_type,
			". Probando alternativa..."
		)

		return PackedByteArray()

	if result != HTTPRequest.RESULT_SUCCESS:
		push_error(
			"Falló la descarga de "
			+ map_type
			+ ". Resultado: "
			+ str(result)
		)

		return PackedByteArray()

	if response_code < 200 or response_code >= 300:
		push_error(
			"Poly Haven devolvió HTTP "
			+ str(response_code)
			+ " para "
			+ map_type
		)

		return PackedByteArray()

	if body.is_empty():
		push_error(
			"Poly Haven devolvió un archivo vacío: "
			+ map_type
		)

		return PackedByteArray()

	return body


func _save_downloaded_file(
	data: PackedByteArray,
	output_path: String
) -> bool:
	var absolute_path: String = (
		ProjectSettings.globalize_path(
			output_path
		)
	)

	var file: FileAccess = (
		FileAccess.open(
			absolute_path,
			FileAccess.WRITE
		)
	)

	if file == null:
		push_error(
			"No se pudo escribir: "
			+ output_path
			+ ". Código: "
			+ str(FileAccess.get_open_error())
		)

		return false

	file.store_buffer(data)
	file.close()

	return true


func _configure_texture_import(
	texture_path: String,
	is_normal_map: bool
) -> bool:
	var import_path: String = (
		texture_path + ".import"
	)

	if not FileAccess.file_exists(
		import_path
	):
		push_error(
			"No existe el archivo: "
			+ import_path
		)

		return false

	var import_config: ConfigFile = (
		ConfigFile.new()
	)

	var load_error: Error = (
		import_config.load(
			import_path
		)
	)

	if load_error != OK:
		push_error(
			"No se pudo leer "
			+ import_path
			+ ". Código: "
			+ str(load_error)
		)

		return false

	import_config.set_value(
		"params",
		"compress/mode",
		COMPRESS_MODE_VRAM
	)

	import_config.set_value(
		"params",
		"compress/high_quality",
		true
	)

	import_config.set_value(
		"params",
		"compress/normal_map",
		NORMAL_MAP_ENABLE
			if is_normal_map
			else NORMAL_MAP_DETECT
	)

	import_config.set_value(
		"params",
		"mipmaps/generate",
		true
	)

	import_config.set_value(
		"params",
		"mipmaps/limit",
		-1
	)

	import_config.set_value(
		"params",
		"process/normal_map_invert_y",
		false
	)

	var save_error: Error = (
		import_config.save(
			import_path
		)
	)

	if save_error != OK:
		push_error(
			"No se pudo guardar "
			+ import_path
			+ ". Código: "
			+ str(save_error)
		)

		return false

	return true


func _load_imported_texture(
	texture_path: String
) -> Texture2D:
	var loaded_resource: Resource = (
		ResourceLoader.load(
			texture_path,
			"Texture2D",
			ResourceLoader.CACHE_MODE_REPLACE
		)
	)

	var texture: Texture2D = (
		loaded_resource as Texture2D
	)

	if texture == null:
		push_error(
			"No se pudo cargar como Texture2D: "
			+ texture_path
		)

	return texture
