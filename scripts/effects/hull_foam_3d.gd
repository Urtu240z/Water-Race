class_name HullFoam3D
extends Node3D

const SURFACE_OFFSET: float = 0.07

var foam_intensity: float = 0.0

var current_vertex_count: int:
	get:
		return (
			_vertices.size()
			if is_instance_valid(_mesh_instance) and _mesh_instance.visible
			else 0
		)

var _vehicle: JetSkiController
var _water: WaterBody3D
var _front_left: Marker3D
var _front_right: Marker3D
var _rear_left: Marker3D
var _rear_right: Marker3D
var _propulsion_point: Marker3D
var _settings: WaterFoamSettings
var _noise_texture: Texture2D
var _settings_signature: int = -1
var _array_mesh := ArrayMesh.new()
var _vertices := PackedVector3Array()
var _normals := PackedVector3Array()
var _colors := PackedColorArray()
var _uvs := PackedVector2Array()
var _uv2s := PackedVector2Array()
var _indices := PackedInt32Array()
var _mesh_arrays: Array = []
var _normal_material: ShaderMaterial

@onready var _mesh_instance: MeshInstance3D = $HullFoamMesh


func _ready() -> void:
	process_priority = 21
	_mesh_arrays.resize(Mesh.ARRAY_MAX)
	_mesh_instance.mesh = _array_mesh
	_mesh_instance.visible = false
	_normal_material = _mesh_instance.material_override as ShaderMaterial


func configure(
	vehicle: JetSkiController,
	water: WaterBody3D,
	front_left: Marker3D,
	front_right: Marker3D,
	rear_left: Marker3D,
	rear_right: Marker3D,
	propulsion_point: Marker3D,
	settings: WaterFoamSettings,
	noise_texture: Texture2D
) -> void:
	_vehicle = vehicle
	_water = water
	_front_left = front_left
	_front_right = front_right
	_rear_left = rear_left
	_rear_right = rear_right
	_propulsion_point = propulsion_point
	_settings = settings
	_noise_texture = noise_texture
	_settings_signature = -1
	_update_material_settings(true)


func _process(_delta: float) -> void:
	_update_material_settings(false)
	foam_intensity = _calculate_intensity()
	if foam_intensity <= 0.0001 or not _references_valid():
		_mesh_instance.visible = false
		if _array_mesh.get_surface_count() > 0:
			_array_mesh.clear_surfaces()
		return
	_rebuild_mesh()
	_mesh_instance.visible = _array_mesh.get_surface_count() > 0
	var material := _mesh_instance.material_override as ShaderMaterial
	if material != null:
		material.set_shader_parameter(&"simulation_time", _water.get_simulation_time())
		material.set_shader_parameter(&"foam_intensity", foam_intensity)
		var backward := _horizontal_direction(_vehicle.global_basis.z, Vector3.BACK)
		material.set_shader_parameter(
			&"foam_flow_direction",
			Vector2(backward.x, backward.z)
		)
		material.set_shader_parameter(
			&"foam_flow_speed",
			clampf(absf(_vehicle.water_relative_forward_speed) / 15.0, 0.25, 1.15)
		)


func clear_foam() -> void:
	foam_intensity = 0.0
	_mesh_instance.visible = false
	_array_mesh.clear_surfaces()


func _calculate_intensity() -> float:
	if not _references_valid() or _settings == null:
		return 0.0
	if not _settings.foam_enabled or not _settings.hull_foam_enabled:
		return 0.0
	if _vehicle.navigation_state == JetSkiController.NavigationState.AIRBORNE:
		return 0.0
	var forward_speed := absf(_vehicle.water_relative_forward_speed)
	var speed_factor := clampf(
		inverse_lerp(2.5, maxf(_settings.hull_foam_full_speed, 2.501), forward_speed),
		0.0,
		1.0
	)
	var navigation_factor: float = 1.0
	match _vehicle.navigation_state:
		JetSkiController.NavigationState.PARTIALLY_SUBMERGED:
			navigation_factor = 0.82
		JetSkiController.NavigationState.LANDING:
			navigation_factor = 0.72
		JetSkiController.NavigationState.DEEP_SUBMERGED:
			navigation_factor = 0.62
	var turn_factor := lerpf(0.88, 1.18, absf(_vehicle.steering_input))
	var reverse_factor := 0.35 if _vehicle.water_relative_forward_speed < 0.0 else 1.0
	var contact_factor := clampf(
		lerpf(_vehicle.submerged_ratio, _vehicle.rear_submerged_ratio, 0.42),
		0.0,
		1.0
	)
	var rear_contact_factor := lerpf(0.48, 1.0, _vehicle.rear_submerged_ratio)
	var propulsion_factor := lerpf(0.55, 1.0, _vehicle.propulsion_contact_factor)
	return clampf(
		speed_factor
		* contact_factor
		* rear_contact_factor
		* propulsion_factor
		* navigation_factor
		* turn_factor
		* reverse_factor
		* _settings.hull_foam_strength,
		0.0,
		1.0
	)


func _rebuild_mesh() -> void:
	_array_mesh.clear_surfaces()
	_vertices.clear()
	_normals.clear()
	_colors.clear()
	_uvs.clear()
	_uv2s.clear()
	_indices.clear()
	var right := _horizontal_direction(_vehicle.global_basis.x, Vector3.RIGHT)
	var forward := _horizontal_direction(-_vehicle.global_basis.z, Vector3.FORWARD)
	var backward := -forward
	var steering := clampf(_vehicle.steering_input, -1.0, 1.0)
	var left_intensity := clampf(1.0 + steering * 0.18, 0.78, 1.18)
	var right_intensity := clampf(1.0 - steering * 0.18, 0.78, 1.18)
	var front_center := (
		_front_left.global_position + _front_right.global_position
	) * 0.5
	var rear_center := (
		_rear_left.global_position + _rear_right.global_position
	) * 0.5
	var hull_half_width := maxf(
		maxf(
			_horizontal_distance(_front_left.global_position, _front_right.global_position),
			_horizontal_distance(_rear_left.global_position, _rear_right.global_position)
		) * 0.5,
		0.42
	)
	var stern_shift := right * steering * lerpf(0.04, 0.18, foam_intensity)
	var rear_contact := clampf(_vehicle.rear_submerged_ratio, 0.0, 1.0)
	var tail_length := lerpf(0.38, 0.78, foam_intensity) * lerpf(0.72, 1.0, rear_contact)
	var propulsion_center := _propulsion_point.global_position + stern_shift
	var centers: Array[Vector3] = [
		front_center + forward * 0.25,
		front_center.lerp(rear_center, 0.18),
		front_center.lerp(rear_center, 0.55) + stern_shift * 0.45,
		rear_center + stern_shift * 0.78,
		propulsion_center,
		propulsion_center + backward * tail_length,
	]
	var widths: Array[float] = [
		hull_half_width * 0.16,
		hull_half_width * 0.60,
		hull_half_width * 0.76,
		hull_half_width * 0.68,
		lerpf(hull_half_width * 0.42, hull_half_width * 0.52, rear_contact),
		hull_half_width * lerpf(0.44, 0.52, rear_contact),
	]
	var section_alphas: Array[float] = [
		0.20,
		0.72,
		1.0,
		lerpf(0.62, 1.0, rear_contact),
		lerpf(0.48, 0.92, rear_contact),
		lerpf(0.16, 0.34, rear_contact),
	]
	_append_continuous_patch(
		centers,
		widths,
		section_alphas,
		right,
		left_intensity,
		right_intensity
	)
	if _vertices.is_empty():
		return
	_mesh_arrays.fill(null)
	_mesh_arrays[Mesh.ARRAY_VERTEX] = _vertices
	_mesh_arrays[Mesh.ARRAY_NORMAL] = _normals
	_mesh_arrays[Mesh.ARRAY_COLOR] = _colors
	_mesh_arrays[Mesh.ARRAY_TEX_UV] = _uvs
	_mesh_arrays[Mesh.ARRAY_TEX_UV2] = _uv2s
	_mesh_arrays[Mesh.ARRAY_INDEX] = _indices
	_array_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, _mesh_arrays)


func _append_continuous_patch(
	centers: Array[Vector3],
	widths: Array[float],
	section_alphas: Array[float],
	right: Vector3,
	left_intensity: float,
	right_intensity: float
) -> void:
	if centers.size() < 2 or centers.size() != widths.size():
		return
	if centers.size() != section_alphas.size():
		return
	const SUBDIVISIONS: int = 2
	var dense_section_count := (centers.size() - 1) * SUBDIVISIONS + 1
	for section in dense_section_count:
		var source_position := float(section) / float(SUBDIVISIONS)
		var source_index := mini(floori(source_position), centers.size() - 2)
		var local_ratio := source_position - float(source_index)
		var longitudinal := float(section) / float(dense_section_count - 1)
		var center := centers[source_index].lerp(
			centers[source_index + 1],
			local_ratio
		)
		var half_width := maxf(
			lerpf(widths[source_index], widths[source_index + 1], local_ratio),
			0.02
		)
		var section_alpha := lerpf(
			section_alphas[source_index],
			section_alphas[source_index + 1],
			local_ratio
		)
		var left_position := _surface_position(center - right * half_width)
		var center_position := _surface_position(center)
		var right_position := _surface_position(center + right * half_width)
		_append_patch_vertex(
			left_position,
			Vector2(0.0, longitudinal),
			section_alpha * left_intensity
		)
		_append_patch_vertex(
			center_position,
			Vector2(0.5, longitudinal),
			section_alpha * (left_intensity + right_intensity) * 0.5
		)
		_append_patch_vertex(
			right_position,
			Vector2(1.0, longitudinal),
			section_alpha * right_intensity
		)
		if section == 0:
			continue
		var current_left := section * 3
		var previous_left := current_left - 3
		_indices.append_array(PackedInt32Array([
			previous_left,
			current_left,
			previous_left + 1,
			previous_left + 1,
			current_left,
			current_left + 1,
			previous_left + 1,
			current_left + 1,
			previous_left + 2,
			previous_left + 2,
			current_left + 1,
			current_left + 2,
		]))


func _append_patch_vertex(vertex_position: Vector3, patch_uv: Vector2, alpha: float) -> void:
	_vertices.append(vertex_position)
	_normals.append(_water.sample_normal(vertex_position))
	_colors.append(Color(1.0, 1.0, 1.0, clampf(alpha, 0.0, 1.0)))
	_uvs.append(Vector2(vertex_position.x, vertex_position.z))
	_uv2s.append(patch_uv)


func _horizontal_direction(source: Vector3, fallback: Vector3) -> Vector3:
	var direction := source
	direction.y = 0.0
	if direction.length_squared() <= 0.000001 or not direction.is_finite():
		return fallback
	return direction.normalized()


func _horizontal_distance(first: Vector3, second: Vector3) -> float:
	return Vector2(first.x - second.x, first.z - second.z).length()


func _surface_position(source: Vector3) -> Vector3:
	return Vector3(
		source.x,
		_water.sample_height(source) + SURFACE_OFFSET,
		source.z
	)


func _references_valid() -> bool:
	return (
		is_instance_valid(_vehicle)
		and is_instance_valid(_water)
		and is_instance_valid(_front_left)
		and is_instance_valid(_front_right)
		and is_instance_valid(_rear_left)
		and is_instance_valid(_rear_right)
		and is_instance_valid(_propulsion_point)
	)


func _update_material_settings(force_update: bool) -> void:
	var signature := _settings.configuration_signature() if _settings != null else 0
	if not force_update and signature == _settings_signature:
		return
	var material := _mesh_instance.material_override as ShaderMaterial
	if material != null and _settings != null:
		material.set_shader_parameter(&"foam_noise_texture", _noise_texture)
		material.set_shader_parameter(&"foam_color", _settings.foam_color)
		material.set_shader_parameter(&"macro_noise_scale", _settings.macro_noise_scale)
		material.set_shader_parameter(&"detail_noise_scale", _settings.detail_noise_scale)
		material.set_shader_parameter(&"noise_scroll_speed", _settings.noise_scroll_speed)
		material.set_shader_parameter(&"breakup_strength", _settings.breakup_strength)
		material.set_shader_parameter(
			&"opacity_boost",
			_settings.hull_foam_opacity_boost
		)
		material.set_shader_parameter(
			&"core_opacity",
			_settings.hull_foam_core_opacity
		)
		material.set_shader_parameter(
			&"emission_strength",
			_settings.hull_foam_emission
		)
	_settings_signature = signature
