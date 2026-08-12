extends SceneTree

const MATERIALS_DIR := "res://levels/paradise_island/terrain/materials"
const TEXTURES_DIR := MATERIALS_DIR + "/textures"
const MANIFEST_PATH := TEXTURES_DIR + "/externalized_textures_manifest.json"
const GLB_PATH := "res://levels/paradise_island/terrain/paradise_island.glb"
const LEVEL_PATH := "res://levels/paradise_island/paradise_island.tscn"

var _failures: Array[String] = []
var _materials_checked := 0
var _texture_slots_checked := 0
var _unique_texture_paths: Dictionary = {}


func _initialize() -> void:
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(MANIFEST_PATH))
	if not parsed is Dictionary:
		_fail("External texture manifest is missing or invalid.")
		_finish()
		return
	for material_entry in parsed.get("materials", []):
		_validate_material(material_entry)
	_validate_scene(GLB_PATH, "GLB")
	_validate_scene(LEVEL_PATH, "level")
	_finish()


func _validate_material(entry: Dictionary) -> void:
	var path := String(entry.get("path", ""))
	var text := FileAccess.get_file_as_string(path)
	if text.contains('[sub_resource type="PortableCompressedTexture2D"'):
		_fail("Embedded PortableCompressedTexture2D remains in %s" % path)
	var expected_uid := String(entry.get("uid", ""))
	if _resource_uid(text) != expected_uid:
		_fail("UID mismatch in %s" % path)
	var material := ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_REPLACE) as Material
	if material == null:
		_fail("Material failed to load: %s" % path)
		return
	_materials_checked += 1
	var snapshot_md5 := _md5(JSON.stringify(_material_snapshot(material)).to_utf8_buffer())
	if snapshot_md5 != String(entry.get("snapshot_md5", "")):
		_fail("Material property snapshot mismatch: %s" % path)
	for texture_entry in entry.get("textures", []):
		_validate_texture_slot(material, texture_entry, path)


func _validate_texture_slot(material: Material, entry: Dictionary, material_path: String) -> void:
	var slot := String(entry.get("slot", ""))
	var value: Variant = material.get(slot)
	if not value is PortableCompressedTexture2D:
		_fail("Slot %s is not PortableCompressedTexture2D in %s" % [slot, material_path])
		return
	var texture := value as PortableCompressedTexture2D
	var expected_path := String(entry.get("path", ""))
	if texture.resource_path != expected_path:
		_fail("External path mismatch for %s:%s" % [material_path, slot])
	if not FileAccess.file_exists(expected_path):
		_fail("External texture is missing: %s" % expected_path)
		return
	var actual := _texture_snapshot(texture)
	for key in ["class", "width", "height", "format", "mipmaps", "data_bytes", "decoded_md5", "keep_compressed_buffer", "size_override"]:
		if actual.get(key) != entry.get(key):
			_fail("Texture %s differs in %s" % [expected_path, key])
	if String(entry.get("compressed_md5", "")).length() != 32:
		_fail("Compressed payload hash is missing for %s" % expected_path)
	_texture_slots_checked += 1
	_unique_texture_paths[expected_path] = true


func _validate_scene(path: String, label: String) -> void:
	var packed := ResourceLoader.load(path, "PackedScene", ResourceLoader.CACHE_MODE_REPLACE) as PackedScene
	if packed == null:
		_fail("Paradise Island %s failed to load: %s" % [label, path])
		return
	var instance := packed.instantiate()
	if instance == null:
		_fail("Paradise Island %s failed to instantiate: %s" % [label, path])
		return
	instance.free()


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


func _resource_uid(text: String) -> String:
	var regex := RegEx.new()
	regex.compile('uid="([^"]+)"')
	var result := regex.search(text)
	return result.get_string(1) if result != null else ""


func _md5(data: PackedByteArray) -> String:
	var context := HashingContext.new()
	context.start(HashingContext.HASH_MD5)
	context.update(data)
	return context.finish().hex_encode()


func _fail(message: String) -> void:
	_failures.append(message)
	printerr(message)


func _finish() -> void:
	print("PARADISE_TEXTURE_VALIDATION_JSON=", JSON.stringify({
		"ok": _failures.is_empty(),
		"materials_checked": _materials_checked,
		"texture_slots_checked": _texture_slots_checked,
		"unique_textures_checked": _unique_texture_paths.size(),
		"failures": _failures,
	}))
	quit(0 if _failures.is_empty() else 1)
