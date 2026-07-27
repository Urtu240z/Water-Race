class_name HullSpraySheet3D
extends Node3D

const SECTION_COUNT: int = 4

var current_vertex_count: int:
	get:
		return _vertices.size()

var _water: WaterBody3D
var _array_mesh := ArrayMesh.new()
var _vertices := PackedVector3Array()
var _normals := PackedVector3Array()
var _colors := PackedColorArray()
var _uvs := PackedVector2Array()
var _indices := PackedInt32Array()
var _mesh_arrays: Array = []
var _material: ShaderMaterial

@onready var _mesh_instance: MeshInstance3D = $SprayMesh


func _ready() -> void:
	_mesh_arrays.resize(Mesh.ARRAY_MAX)
	_mesh_instance.mesh = _array_mesh
	_material = _mesh_instance.material_override as ShaderMaterial
	_mesh_instance.visible = false


func configure(water: WaterBody3D, refraction_enabled: bool) -> void:
	_water = water
	set_refraction_enabled(refraction_enabled)
	if _material == null or not is_instance_valid(_water):
		return
	_material.set_shader_parameter(&"sheet_mode", true)
	_material.set_shader_parameter(&"water_tint", _water.wave_crest_color)
	if _water.foam_settings != null:
		_material.set_shader_parameter(&"foam_tint", _water.foam_settings.foam_color)


func set_refraction_enabled(enabled: bool) -> void:
	if _material != null:
		_material.set_shader_parameter(&"refraction_enabled", enabled)


func update_sheets(
	left_origin: Vector3,
	right_origin: Vector3,
	left_direction: Vector3,
	right_direction: Vector3,
	fan_axis: Vector3,
	left_normal: Vector3,
	right_normal: Vector3,
	left_intensity: float,
	right_intensity: float
) -> void:
	_array_mesh.clear_surfaces()
	_vertices.clear()
	_normals.clear()
	_colors.clear()
	_uvs.clear()
	_indices.clear()
	if not is_instance_valid(_water):
		_mesh_instance.visible = false
		return
	if left_intensity > 0.001:
		_append_sheet(
			left_origin,
			left_direction,
			fan_axis,
			left_normal,
			left_intensity
		)
	if right_intensity > 0.001:
		_append_sheet(
			right_origin,
			right_direction,
			fan_axis,
			right_normal,
			right_intensity
		)
	if _vertices.is_empty():
		_mesh_instance.visible = false
		return
	_mesh_arrays.fill(null)
	_mesh_arrays[Mesh.ARRAY_VERTEX] = _vertices
	_mesh_arrays[Mesh.ARRAY_NORMAL] = _normals
	_mesh_arrays[Mesh.ARRAY_COLOR] = _colors
	_mesh_arrays[Mesh.ARRAY_TEX_UV] = _uvs
	_mesh_arrays[Mesh.ARRAY_INDEX] = _indices
	_array_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, _mesh_arrays)
	_mesh_instance.visible = true
	if _material != null:
		_material.set_shader_parameter(&"simulation_time", _water.get_simulation_time())


func clear_sheets() -> void:
	_vertices.clear()
	_array_mesh.clear_surfaces()
	_mesh_instance.visible = false


func _append_sheet(
	origin: Vector3,
	direction: Vector3,
	fan_axis: Vector3,
	surface_normal: Vector3,
	intensity: float
) -> void:
	var base_index := _vertices.size()
	var safe_direction := direction.normalized()
	var safe_axis := fan_axis.normalized()
	var length := lerpf(0.42, 1.35, intensity)
	var widths := PackedFloat32Array([
		0.045,
		lerpf(0.08, 0.16, intensity),
		lerpf(0.12, 0.24, intensity),
		0.06,
	])
	var alphas := PackedFloat32Array([0.42, 0.86, 0.56, 0.04])
	for section in SECTION_COUNT:
		var ratio := float(section) / float(SECTION_COUNT - 1)
		var arc_height := sin(ratio * PI) * lerpf(0.06, 0.26, intensity)
		var gravity_drop := ratio * ratio * lerpf(0.035, 0.14, intensity)
		var center := (
			origin
			+ safe_direction * length * ratio
			+ surface_normal * arc_height
			- Vector3.UP * gravity_drop
		)
		var half_width := widths[section]
		_append_vertex(center - safe_axis * half_width, surface_normal, Color(1.0, 1.0, 1.0, alphas[section] * intensity), Vector2(0.0, ratio))
		_append_vertex(center + safe_axis * half_width, surface_normal, Color(1.0, 1.0, 1.0, alphas[section] * intensity), Vector2(1.0, ratio))
		if section == 0:
			continue
		var current := base_index + section * 2
		var previous := current - 2
		_indices.append_array(PackedInt32Array([
			previous,
			current,
			previous + 1,
			previous + 1,
			current,
			current + 1,
		]))


func _append_vertex(
	world_position: Vector3,
	world_normal: Vector3,
	color: Color,
	uv: Vector2
) -> void:
	_vertices.append(_mesh_instance.to_local(world_position))
	_normals.append((_mesh_instance.global_basis.inverse() * world_normal).normalized())
	_colors.append(color)
	_uvs.append(uv)
