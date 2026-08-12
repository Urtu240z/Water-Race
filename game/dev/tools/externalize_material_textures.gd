extends SceneTree

const TARGETS := {
	"paradise_island": {
		"material_roots": ["res://levels/paradise_island/terrain/materials"],
		"textures_dir": "res://levels/paradise_island/terrain/materials/textures",
		"resources": [
			"res://levels/paradise_island/terrain/paradise_island.glb",
			"res://levels/paradise_island/paradise_island.tscn",
		],
	},
	"gold_city": {
		"material_roots": [
			"res://levels/gold_city/terrain/materials",
			"res://levels/gold_city/props/roller_coaster/materials",
			"res://levels/gold_city/props/ferris_wheel/materials",
			"res://levels/gold_city/city/buildings/casino/materials",
		],
		"textures_dir": "res://levels/gold_city/material_textures",
		"resources": [
			"res://levels/gold_city/props/roller_coaster/animated_roller_coaster.glb",
			"res://levels/gold_city/props/ferris_wheel/ferrys_wheel.glb",
			"res://levels/gold_city/city/buildings/casino/casino.glb",
			"res://levels/gold_city/terrain/gold_city.glb",
			"res://levels/gold_city/gold_city.tscn",
		],
	},
	"shared_common": {
		"dependency_intersection": [
			"res://levels/paradise_island/paradise_island.tscn",
			"res://levels/gold_city/gold_city.tscn",
		],
		"textures_dir": "res://shared/material_textures",
		"resources": [
			"res://gameplay/vehicles/jet_ski_01/jet_ski_with_rider.tscn",
			"res://gameplay/race/course/ramps/ramp_01.tscn",
			"res://gameplay/race/course/ramps/ramp_02.tscn",
			"res://world/props/boats/boat_01.glb",
			"res://world/props/boats/boat_02.glb",
			"res://levels/paradise_island/paradise_island.tscn",
			"res://levels/gold_city/gold_city.tscn",
		],
	},
}
const EXISTING_MANIFESTS := [
	"res://levels/paradise_island/terrain/materials/textures/externalized_textures_manifest.json",
	"res://levels/gold_city/material_textures/externalized_textures_manifest.json",
]
const PILOT_TEXTURE_PATH := "res://levels/paradise_island/terrain/materials/textures/paradise_island_material_01_albedo.res"
const PILOT_COMPRESSED_MD5 := "930cf68db6adec48d0d5b2a4e3b80b27"

var _target_name := ""
var _config: Dictionary = {}
var _textures_dir := ""
var _manifest_path := ""
var _failures: Array[String] = []
var _compressed_to_path: Dictionary = {}
var _path_to_compressed: Dictionary = {}
var _manifest_materials: Array[Dictionary] = []
var _materials_modified := 0
var _textures_created := 0
var _embedded_textures_found := 0
var _duplicates_reused := 0
var _global_duplicates_reused := 0
var _bytes_before := 0


func _initialize() -> void:
	var arguments := OS.get_cmdline_user_args()
	if arguments.is_empty() or not TARGETS.has(arguments[0]):
		printerr("Usage: -- <paradise_island|gold_city|shared_common> [dry-run]")
		quit(2)
		return
	_target_name = arguments[0]
	_config = TARGETS[_target_name]
	_textures_dir = _config.textures_dir
	_manifest_path = _textures_dir + "/externalized_textures_manifest.json"
	if _target_name == "paradise_island":
		_compressed_to_path[PILOT_COMPRESSED_MD5] = PILOT_TEXTURE_PATH
		_path_to_compressed[PILOT_TEXTURE_PATH] = PILOT_COMPRESSED_MD5
	var dry_run := arguments.has("dry-run")
	var material_paths := _material_paths()
	if material_paths.is_empty():
		_fail("No materials were found for target %s." % _target_name)
		_finish(dry_run)
		return
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(_textures_dir))
	_load_existing_manifest_hashes()
	for material_path in material_paths:
		_bytes_before += FileAccess.get_file_as_bytes(material_path).size()
		_process_material(material_path, dry_run)
	if not dry_run and _failures.is_empty():
		_write_manifest(material_paths)
	_finish(dry_run)


func _material_paths() -> Array[String]:
	if _config.has("dependency_intersection"):
		return _intersection_material_paths(_config.dependency_intersection)
	var paths: Array[String] = []
	for material_root in _config.material_roots:
		var directory := DirAccess.open(material_root)
		if directory == null:
			_fail("Could not open material directory: %s" % material_root)
			continue
		for file_name in directory.get_files():
			if file_name.ends_with(".tres"):
				paths.append(material_root + "/" + file_name)
	paths.sort()
	return paths


func _intersection_material_paths(root_paths: Array) -> Array[String]:
	if root_paths.size() != 2:
		_fail("A dependency intersection requires exactly two root resources.")
		return []
	var first := _transitive_dependencies(String(root_paths[0]))
	var second := _transitive_dependencies(String(root_paths[1]))
	var paths: Array[String] = []
	for resource_path in first:
		if not resource_path.ends_with(".tres") or not second.has(resource_path):
			continue
		var candidate := ResourceLoader.load(
			resource_path,
			"",
			ResourceLoader.CACHE_MODE_IGNORE
		)
		if candidate is Material:
			paths.append(resource_path)
	paths.sort()
	return paths


func _transitive_dependencies(root_path: String) -> Dictionary:
	var pending: Array[String] = [root_path]
	var visited: Dictionary = {}
	while not pending.is_empty():
		var resource_path: String = pending.pop_back()
		if visited.has(resource_path):
			continue
		visited[resource_path] = true
		for raw_dependency in ResourceLoader.get_dependencies(resource_path):
			var dependency_path := _dependency_path(raw_dependency)
			if not dependency_path.is_empty() and not visited.has(dependency_path):
				pending.append(dependency_path)
	visited.erase(root_path)
	return visited


func _dependency_path(raw_dependency: String) -> String:
	var parts := raw_dependency.split("::")
	for index in range(parts.size() - 1, -1, -1):
		if parts[index].begins_with("res://"):
			return parts[index]
	return raw_dependency if raw_dependency.begins_with("res://") else ""


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
			external_path = "%s/%s_texture_%s.res" % [_textures_dir, _target_name, compressed_md5]
			_compressed_to_path[compressed_md5] = external_path
			_path_to_compressed[external_path] = compressed_md5
			if not dry_run:
				if not _create_external_texture(source_texture, payload, external_path):
					continue
			_textures_created += 1
		else:
			_duplicates_reused += 1
			if not external_path.begins_with(_textures_dir + "/"):
				_global_duplicates_reused += 1
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
			if not _path_to_compressed.has(texture.resource_path):
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
		"target": _target_name,
		"resources": _config.resources,
		"materials": _manifest_materials,
	}
	_write_text(_manifest_path, JSON.stringify(manifest, "  ") + "\n")


func _load_existing_manifest_hashes() -> void:
	var textures_dir := DirAccess.open(_textures_dir)
	if textures_dir != null:
		for file_name in textures_dir.get_files():
			var prefix := _target_name + "_texture_"
			if file_name.begins_with(prefix) and file_name.ends_with(".res"):
				var compressed_md5 := file_name.trim_prefix(prefix).trim_suffix(".res")
				var path := _textures_dir + "/" + file_name
				_compressed_to_path[compressed_md5] = path
				_path_to_compressed[path] = compressed_md5
	_load_manifest_hashes(_manifest_path)
	for manifest_path in EXISTING_MANIFESTS:
		if manifest_path != _manifest_path:
			_load_manifest_hashes(manifest_path)


func _load_manifest_hashes(manifest_path: String) -> void:
	if not FileAccess.file_exists(manifest_path):
		return
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(manifest_path))
	if not parsed is Dictionary:
		return
	for material_entry in parsed.get("materials", []):
		for texture_entry in material_entry.get("textures", []):
			var path := String(texture_entry.get("path", ""))
			var compressed_md5 := String(texture_entry.get("compressed_md5", ""))
			if (
				not path.is_empty()
				and not compressed_md5.is_empty()
				and not _compressed_to_path.has(compressed_md5)
			):
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
	print("MATERIAL_TEXTURE_MIGRATION_JSON=", JSON.stringify({
		"target": _target_name,
		"dry_run": dry_run,
		"materials_modified": _materials_modified,
		"embedded_textures_found": _embedded_textures_found,
		"textures_created": _textures_created,
		"duplicates_reused": _duplicates_reused,
		"global_duplicates_reused": _global_duplicates_reused,
		"material_bytes_before": _bytes_before,
		"failures": _failures,
	}))
	quit(0 if _failures.is_empty() else 1)
