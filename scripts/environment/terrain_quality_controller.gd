class_name TerrainQualityController
extends Node3D

const TERRAIN_SHADER_PATH := "res://shaders/terrain/terrain_master.gdshader"

var _materials: Array[ShaderMaterial] = []
var _quality_level: int = 2
var _hex_tiling_mode: int = 2


func _ready() -> void:
	_scan_terrain_materials()


func set_graphics_quality(
	level: int,
	profile: GraphicsQualityProfile
) -> void:
	if profile == null:
		return
	_quality_level = clampi(level, 0, 2)
	_hex_tiling_mode = clampi(profile.terrain_hex_tiling_mode, 0, 2)
	if _materials.is_empty():
		_scan_terrain_materials()
	for material: ShaderMaterial in _materials:
		if is_instance_valid(material):
			material.set_shader_parameter(&"hex_tiling_mode", _hex_tiling_mode)


func get_graphics_quality_debug_status() -> Dictionary:
	return {
		"quality_level": _quality_level,
		"hex_tiling_mode": _hex_tiling_mode,
		"terrain_material_count": _materials.size(),
	}


func _scan_terrain_materials() -> void:
	_materials.clear()
	var localized: Dictionary = {}
	for candidate: Node in find_children("*", "MeshInstance3D", true, false):
		var mesh_instance := candidate as MeshInstance3D
		if mesh_instance == null:
			continue
		var override := mesh_instance.material_override as ShaderMaterial
		if _is_terrain_material(override):
			mesh_instance.material_override = _localize_material(override, localized)
			_append_unique(mesh_instance.material_override as ShaderMaterial)
		if mesh_instance.mesh == null:
			continue
		for surface_index in mesh_instance.mesh.get_surface_count():
			var surface_material := (
				mesh_instance.get_surface_override_material(surface_index)
				as ShaderMaterial
			)
			if surface_material == null:
				surface_material = (
					mesh_instance.mesh.surface_get_material(surface_index)
					as ShaderMaterial
				)
			if not _is_terrain_material(surface_material):
				continue
			var local_material := _localize_material(
				surface_material,
				localized
			)
			mesh_instance.set_surface_override_material(
				surface_index,
				local_material
			)
			_append_unique(local_material)


func _localize_material(
	material: ShaderMaterial,
	cache: Dictionary
) -> ShaderMaterial:
	if material.resource_local_to_scene:
		return material
	var instance_id := material.get_instance_id()
	if cache.has(instance_id):
		return cache[instance_id] as ShaderMaterial
	var local_material := material.duplicate(true) as ShaderMaterial
	local_material.resource_local_to_scene = true
	cache[instance_id] = local_material
	return local_material


func _is_terrain_material(material: ShaderMaterial) -> bool:
	return (
		material != null
		and material.shader != null
		and material.shader.resource_path == TERRAIN_SHADER_PATH
	)


func _append_unique(material: ShaderMaterial) -> void:
	if material != null and material not in _materials:
		_materials.append(material)
