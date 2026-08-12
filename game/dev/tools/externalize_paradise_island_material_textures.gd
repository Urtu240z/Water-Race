extends SceneTree

const MATERIALS_DIR := "res://levels/paradise_island/terrain/materials"
const TEXTURES_DIR := MATERIALS_DIR + "/textures"
const GLB_IMPORT_PATH := "res://levels/paradise_island/terrain/paradise_island.glb.import"
const MANIFEST_PATH := TEXTURES_DIR + "/externalized_textures_manifest.json"
const PILOT_TEXTURE_PATH := TEXTURES_DIR + "/paradise_island_material_01_albedo.res"
const PILOT_COMPRESSED_MD5 := "930cf68db6adec48d0d5b2a4e3b80b27"

var _failures: Array[String] = []
var _compressed_to_path: Dictionary = {
	PILOT_COMPRESSED_MD5: PILOT_TEXTURE_PATH,
}
var _path_to_compressed: Dictionary = {
	PILOT_TEXTURE_PATH: PILOT_COMPRESSED_MD5,
}
var _manifest_materials: Array[Dictionary] = []
var _materials_modified := 0
var _textures_created := 0
var _embedded_textures_found := 0
var _duplicates_reused := 0
var _bytes_before := 0


func _initialize() -> void:
	var dry_run := OS.get_cmdline_user_args().has("dry-run")
	var material_paths := _used_material_paths()
	if material_paths.is_empty():
		_fail("No Paradise Island terrain materials were found in the GLB import mappings.")
		_finish(dry_run)
		return
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(TEXTURES_DIR))
	_load_existing_manifest_hashes()
	for material_path in material_paths:
		_bytes_before += FileAccess.get_file_as_bytes(material_path).size()
		_process_material(material_path, dry_run)
	if not dry_run and _failures.is_empty():
		_write_manifest(material_paths)
	_finish(dry_run)


func _used_material_paths() -> Array[String]:
	var text := FileAccess.get_file_as_string(GLB_IMPORT_PATH)
	var regex := RegEx.new()
	regex.compile('"use_external/fallback_path": "([^"]+\\.tres)"')
	var unique: Dictionary = {}
	for match_result in regex.search_all(text):
		var path := match_result.get_string(1)
		if path.get_base_dir() == MATERIALS_DIR:
			unique[path] = true
	var paths: Array[String] = []
	for path in unique.keys():
		paths.append(path)
	paths.sort()
	return paths


func _process_material(material_path: String, dry_run: bool) -> void:
	var original_text := FileAccess.get_file_as_string(material_path)
	var blocks := _embedded_texture_blocks(original_text)
	_embedded_textures_found += blocks.size()
	if blocks.is_empty():
		return
	var material := ResourceLoader.load(material_path, "", ResourceLoader.CACHE_MODE_IGNORE) as Material
	if material == null:
		_fail("Could not load material before migration: %s" % material_path)
		return
	var uid := _resource_uid(original_text)
	if uid.is_empty():
		_fail("Material has no UID: %s" % material_path)
		return
	var before_snapshot := _material_snapshot(material)
	var replacements: Dictionary = {}
	var ext_headers: Dictionary = {}
	var created_for_material: Array[String] = []
	for block in blocks:
		var subresource_id: String = block.id
		var source_texture := _find_texture_by_subresource_id(material, subresource_id)
		if source_texture == null:
			_fail("Could not find texture subresource %s in %s" % [subresource_id, material_path])
			continue
		var payload := Marshalls.base64_to_raw(block.base64)
		if payload.is_empty():
			_fail("Embedded texture payload is empty in %s::%s" % [material_path, subresource_id])
			continue
		var compressed_md5 := _md5(payload)
		var external_path := String(_compressed_to_path.get(compressed_md5, ""))
		if external_path.is_empty():
			external_path = "%s/paradise_texture_%s.res" % [TEXTURES_DIR, compressed_md5]
			_compressed_to_path[compressed_md5] = external_path
			_path_to_compressed[external_path] = compressed_md5
			if not dry_run:
				if not _create_external_texture(source_texture, payload, external_path):
					continue
				created_for_material.append(external_path)
			_textures_created += 1
		else:
			_duplicates_reused += 1
		var ext_id := "texture_%s" % compressed_md5.substr(0, 12)
		replacements[subresource_id] = ext_id
		ext_headers[ext_id] = '[ext_resource type="Texture2D" path="%s" id="%s"]' % [external_path, ext_id]
	if not _failures.is_empty() or dry_run:
		return
	var migrated_text := original_text
	blocks.reverse()
	for block in blocks:
		migrated_text = migrated_text.erase(block.start, block.length)
	for subresource_id in replacements:
		migrated_text = migrated_text.replace(
			'SubResource("%s")' % subresource_id,
			'ExtResource("%s")' % replacements[subresource_id]
		)
	var header_end := migrated_text.find("\n") + 1
	var headers: Array[String] = []
	for ext_id in ext_headers:
		headers.append(ext_headers[ext_id])
	headers.sort()
	migrated_text = migrated_text.insert(header_end, "\n" + "\n".join(headers) + "\n")
	if not _write_text(material_path, migrated_text):
		_fail("Could not write migrated material: %s" % material_path)
		return
	var migrated := ResourceLoader.load(material_path, "", ResourceLoader.CACHE_MODE_REPLACE) as Material
	if migrated == null:
		_write_text(material_path, original_text)
		_fail("Migrated material failed to reload; original restored: %s" % material_path)
		return
	if _resource_uid(migrated_text) != uid:
		_write_text(material_path, original_text)
		_fail("Material UID changed; original restored: %s" % material_path)
		return
	var after_snapshot := _material_snapshot(migrated)
	if before_snapshot != after_snapshot:
		_write_text(material_path, original_text)
		_fail("Material properties changed; original restored: %s" % material_path)
		return
	_materials_modified += 1


func _embedded_texture_blocks(text: String) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var header_marker := '[sub_resource type="PortableCompressedTexture2D" id="'
	var search_from := 0
	while true:
		var block_start := text.find(header_marker, search_from)
		if block_start < 0:
			break
		var id_start := block_start + header_marker.length()
		var id_end := text.find('"', id_start)
		var header_end := text.find("\n", id_end)
		if id_end < 0 or header_end < 0:
			break
		var next_section := text.find("\n[", header_end + 1)
		var block_end := text.length() if next_section < 0 else next_section + 1
		var body := text.substr(header_end + 1, block_end - header_end - 1)
		var marker := 'PackedByteArray("'
		var data_start := body.find(marker)
		if data_start < 0:
			search_from = block_end
			continue
		data_start += marker.length()
		var data_end := body.find('")', data_start)
		if data_end < 0:
			search_from = block_end
			continue
		result.append({
			"id": text.substr(id_start, id_end - id_start),
			"base64": body.substr(data_start, data_end - data_start),
			"start": block_start,
			"length": block_end - block_start,
		})
		search_from = block_end
	return result


func _find_texture_by_subresource_id(material: Material, subresource_id: String) -> PortableCompressedTexture2D:
	var suffix := "::%s" % subresource_id
	for property in material.get_property_list():
		var value: Variant = material.get(property.name)
		if value is PortableCompressedTexture2D and value.resource_path.ends_with(suffix):
			return value
	return null


func _create_external_texture(source: PortableCompressedTexture2D, payload: PackedByteArray, path: String) -> bool:
	var standalone := PortableCompressedTexture2D.new()
	standalone.keep_compressed_buffer = source.keep_compressed_buffer
	standalone.size_override = source.size_override
	standalone.set("_data", payload)
	var error := ResourceSaver.save(standalone, path)
	if error != OK:
		_fail("Could not save texture %s: %s" % [path, error_string(error)])
		return false
	var reloaded := ResourceLoader.load(path, "PortableCompressedTexture2D", ResourceLoader.CACHE_MODE_REPLACE) as PortableCompressedTexture2D
	if reloaded == null or not _textures_equal(source, reloaded):
		_fail("External texture validation failed: %s" % path)
		return false
	return true


func _textures_equal(left: PortableCompressedTexture2D, right: PortableCompressedTexture2D) -> bool:
	var left_image := left.get_image()
	var right_image := right.get_image()
	return (
		left_image != null
		and right_image != null
		and left.get_width() == right.get_width()
		and left.get_height() == right.get_height()
		and left.keep_compressed_buffer == right.keep_compressed_buffer
		and left.size_override == right.size_override
		and left_image.get_format() == right_image.get_format()
		and left_image.has_mipmaps() == right_image.has_mipmaps()
		and _md5(left_image.get_data()) == _md5(right_image.get_data())
	)


func _material_snapshot(material: Material) -> Dictionary:
	var snapshot: Dictionary = {
		"class": material.get_class(),
		"properties": {},
	}
	for property in material.get_property_list():
		if int(property.usage) & PROPERTY_USAGE_STORAGE == 0:
			continue
		var value: Variant = material.get(property.name)
		if value is Texture2D:
			snapshot.properties[String(property.name)] = _texture_snapshot(value)
		elif value is Resource:
			snapshot.properties[String(property.name)] = {
				"class": value.get_class(),
				"name": value.resource_name,
			}
		else:
			snapshot.properties[String(property.name)] = var_to_str(value)
	return snapshot


func _texture_snapshot(texture: Texture2D) -> Dictionary:
	var image := texture.get_image()
	var snapshot := {
		"class": texture.get_class(),
		"name": texture.resource_name,
		"width": texture.get_width(),
		"height": texture.get_height(),
	}
	if texture is PortableCompressedTexture2D:
		snapshot["keep_compressed_buffer"] = texture.keep_compressed_buffer
		snapshot["size_override"] = var_to_str(texture.size_override)
	if image != null:
		snapshot["format"] = image.get_format()
		snapshot["mipmaps"] = image.has_mipmaps()
		snapshot["data_bytes"] = image.get_data().size()
		snapshot["decoded_md5"] = _md5(image.get_data())
	return snapshot


func _write_manifest(material_paths: Array[String]) -> void:
	_manifest_materials.clear()
	for material_path in material_paths:
		var material := ResourceLoader.load(material_path, "", ResourceLoader.CACHE_MODE_REPLACE) as Material
		if material == null:
			_fail("Could not load material while writing manifest: %s" % material_path)
			continue
		var texture_entries: Array[Dictionary] = []
		for property in material.get_property_list():
			var value: Variant = material.get(property.name)
			if not value is PortableCompressedTexture2D:
				continue
			var texture := value as PortableCompressedTexture2D
			if not texture.resource_path.begins_with(TEXTURES_DIR + "/"):
				continue
			var texture_data := _texture_snapshot(texture)
			texture_data["slot"] = String(property.name)
			texture_data["path"] = texture.resource_path
			texture_data["compressed_md5"] = String(_path_to_compressed.get(texture.resource_path, ""))
			texture_entries.append(texture_data)
		texture_entries.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a.slot < b.slot)
		_manifest_materials.append({
			"path": material_path,
			"uid": _resource_uid(FileAccess.get_file_as_string(material_path)),
			"snapshot_md5": _md5(JSON.stringify(_material_snapshot(material)).to_utf8_buffer()),
			"textures": texture_entries,
		})
	var manifest := {
		"format": 1,
		"glb": "res://levels/paradise_island/terrain/paradise_island.glb",
		"materials": _manifest_materials,
	}
	_write_text(MANIFEST_PATH, JSON.stringify(manifest, "  ") + "\n")


func _load_existing_manifest_hashes() -> void:
	var textures_dir := DirAccess.open(TEXTURES_DIR)
	if textures_dir != null:
		for file_name in textures_dir.get_files():
			if file_name.begins_with("paradise_texture_") and file_name.ends_with(".res"):
				var compressed_md5 := file_name.trim_prefix("paradise_texture_").trim_suffix(".res")
				var path := TEXTURES_DIR + "/" + file_name
				_compressed_to_path[compressed_md5] = path
				_path_to_compressed[path] = compressed_md5
	if not FileAccess.file_exists(MANIFEST_PATH):
		return
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(MANIFEST_PATH))
	if not parsed is Dictionary:
		return
	for material_entry in parsed.get("materials", []):
		for texture_entry in material_entry.get("textures", []):
			var path := String(texture_entry.get("path", ""))
			var compressed_md5 := String(texture_entry.get("compressed_md5", ""))
			if not path.is_empty() and not compressed_md5.is_empty():
				_compressed_to_path[compressed_md5] = path
				_path_to_compressed[path] = compressed_md5


func _resource_uid(text: String) -> String:
	var regex := RegEx.new()
	regex.compile('uid="([^"]+)"')
	var result := regex.search(text)
	return result.get_string(1) if result != null else ""


func _write_text(path: String, text: String) -> bool:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return false
	file.store_string(text)
	return true


func _md5(data: PackedByteArray) -> String:
	var context := HashingContext.new()
	context.start(HashingContext.HASH_MD5)
	context.update(data)
	return context.finish().hex_encode()


func _fail(message: String) -> void:
	_failures.append(message)
	printerr(message)


func _finish(dry_run: bool) -> void:
	print("PARADISE_TEXTURE_MIGRATION_JSON=", JSON.stringify({
		"dry_run": dry_run,
		"materials_modified": _materials_modified,
		"embedded_textures_found": _embedded_textures_found,
		"textures_created": _textures_created,
		"duplicates_reused": _duplicates_reused,
		"material_bytes_before": _bytes_before,
		"failures": _failures,
	}))
	quit(0 if _failures.is_empty() else 1)
