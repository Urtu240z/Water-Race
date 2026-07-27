class_name WakeTrail3D
extends Node3D

class WakeSample:
	var position: Vector3
	var age: float
	var forward_direction: Vector3
	var speed_factor: float
	var initial_width: float

	func _init(
		initial_position: Vector3,
		initial_forward: Vector3,
		initial_speed_factor: float,
		width: float
	) -> void:
		position = initial_position
		age = 0.0
		forward_direction = initial_forward
		speed_factor = initial_speed_factor
		initial_width = width


var wake_enabled: bool = true
var wake_minimum_speed: float = 3.0
var wake_full_speed: float = 20.0
var wake_minimum_contact: float = 0.15
var wake_lifetime: float = 1.8
var wake_maximum_points: int = 72
var wake_sample_minimum_distance: float = 0.4
var wake_sample_maximum_interval: float = 0.1
var wake_surface_offset: float = 0.025
var wake_fade_start_ratio: float = 0.14
var wake_initial_width_multiplier: float = 1.05
var wake_maximum_width_multiplier: float = 2.60
var wake_opening_distance: float = 6.0
var mesh_update_interval: float = 0.05

var sample_count: int:
	get:
		return _samples.size()

var trail_length: float:
	get:
		return _trail_length

var oldest_age: float:
	get:
		return _samples[0].age if not _samples.is_empty() else 0.0

var current_width: float:
	get:
		return _current_width

var rebase_count: int:
	get:
		return _rebase_count

var surface_count: int:
	get:
		return _array_mesh.get_surface_count() if _array_mesh != null else 0

var vertex_count: int:
	get:
		return _vertices.size() if surface_count > 0 else 0

var foam_intensity: float = 0.0

var _vehicle: JetSkiController
var _water: WaterBody3D
var _propulsion_point: Marker3D
var _rear_left: Marker3D
var _rear_right: Marker3D
var _samples: Array[WakeSample] = []
var _sample_elapsed: float = 0.0
var _has_last_sample: bool = false
var _last_sample_position: Vector3 = Vector3.ZERO
var _suppress_sampling_ticks: int = 0
var _trail_length: float = 0.0
var _current_width: float = 0.0
var _rebase_count: int = 0
var _mesh_update_elapsed: float = 0.0
var _mesh_dirty: bool = true
var _array_mesh := ArrayMesh.new()
var _vertices := PackedVector3Array()
var _normals := PackedVector3Array()
var _colors := PackedColorArray()
var _uvs := PackedVector2Array()
var _indices := PackedInt32Array()
var _mesh_arrays: Array = []
var _foam_settings: WaterFoamSettings
var _foam_noise_texture: Texture2D
var _foam_settings_signature: int = -1
var _normal_material: ShaderMaterial

@onready var _wake_mesh: MeshInstance3D = $WakeMesh


func _ready() -> void:
	process_physics_priority = 10
	_mesh_arrays.resize(Mesh.ARRAY_MAX)
	_wake_mesh.mesh = _array_mesh
	_normal_material = _wake_mesh.material_override as ShaderMaterial


func configure(
	vehicle: JetSkiController,
	water: WaterBody3D,
	propulsion_point: Marker3D,
	rear_left: Marker3D = null,
	rear_right: Marker3D = null
) -> void:
	_vehicle = vehicle
	_water = water
	_propulsion_point = propulsion_point
	_rear_left = rear_left
	_rear_right = rear_right


func configure_quality(
	maximum_points: int,
	update_interval: float,
	sample_distance: float
) -> void:
	wake_maximum_points = maxi(maximum_points, 8)
	mesh_update_interval = clampf(update_interval, 0.01, 0.25)
	wake_sample_minimum_distance = clampf(sample_distance, 0.1, 2.0)
	while _samples.size() > wake_maximum_points:
		_samples.pop_front()
	_mesh_dirty = true


func configure_foam(settings: WaterFoamSettings, noise_texture: Texture2D) -> void:
	_foam_settings = settings
	_foam_noise_texture = noise_texture
	_foam_settings_signature = -1
	_update_foam_material(true)


func _physics_process(delta: float) -> void:
	if delta <= 0.0:
		return
	_update_foam_intensity(delta)
	_update_foam_material(false)
	_age_samples(delta)
	_sample_elapsed += delta
	_mesh_update_elapsed += delta
	if _suppress_sampling_ticks > 0:
		_suppress_sampling_ticks -= 1
	else:
		_try_add_sample()
	if _samples.is_empty():
		if _array_mesh.get_surface_count() > 0:
			_array_mesh.clear_surfaces()
	elif _mesh_dirty or _mesh_update_elapsed >= mesh_update_interval:
		_rebuild_mesh()
		_mesh_dirty = false
		_mesh_update_elapsed = 0.0


func clear_trail(suppress_next_tick: bool = true) -> void:
	_samples.clear()
	_sample_elapsed = 0.0
	_has_last_sample = false
	_last_sample_position = Vector3.ZERO
	_trail_length = 0.0
	_current_width = 0.0
	_suppress_sampling_ticks = 1 if suppress_next_tick else 0
	_mesh_dirty = true
	_mesh_update_elapsed = 0.0
	_array_mesh.clear_surfaces()
	foam_intensity = 0.0


func apply_world_rebase(shift: Vector3) -> void:
	var horizontal_shift := Vector3(shift.x, 0.0, shift.z)
	if horizontal_shift.is_zero_approx() or not horizontal_shift.is_finite():
		return
	for sample in _samples:
		sample.position -= horizontal_shift
	if _has_last_sample:
		_last_sample_position -= horizontal_shift
	_rebase_count += 1
	_rebuild_mesh()
	_mesh_dirty = false
	_mesh_update_elapsed = 0.0


func get_sample_positions() -> PackedVector3Array:
	var positions := PackedVector3Array()
	positions.resize(_samples.size())
	for index in _samples.size():
		positions[index] = _samples[index].position
	return positions


func _age_samples(delta: float) -> void:
	for sample in _samples:
		sample.age += delta
	while not _samples.is_empty() and _samples[0].age >= wake_lifetime:
		_samples.pop_front()
		_mesh_dirty = true


func _try_add_sample() -> void:
	if not _can_add_sample():
		return
	var sample_position := _propulsion_point.global_position
	var distance_from_last: float = (
		sample_position.distance_to(_last_sample_position) if _has_last_sample else INF
	)
	if (
		_has_last_sample
		and distance_from_last < wake_sample_minimum_distance
		and _sample_elapsed < wake_sample_maximum_interval
	):
		return
	var forward := -_vehicle.global_basis.z
	forward.y = 0.0
	if forward.length_squared() <= 0.000001:
		forward = Vector3.FORWARD
	else:
		forward = forward.normalized()
	var speed_factor := clampf(
		inverse_lerp(
			wake_minimum_speed,
			wake_full_speed,
			_vehicle.water_relative_forward_speed
		),
		0.0,
		1.0
	)
	var measured_half_width := _measured_hull_half_width()
	var initial_width := measured_half_width * wake_initial_width_multiplier
	initial_width *= lerpf(0.94, 1.08, speed_factor)
	_samples.append(WakeSample.new(sample_position, forward, speed_factor, initial_width))
	_mesh_dirty = true
	while _samples.size() > maxi(wake_maximum_points, 2):
		_samples.pop_front()
	_last_sample_position = sample_position
	_has_last_sample = true
	_sample_elapsed = 0.0


func _can_add_sample() -> bool:
	return (
		wake_enabled
		and is_instance_valid(_vehicle)
		and is_instance_valid(_water)
		and is_instance_valid(_propulsion_point)
		and _vehicle.navigation_state != JetSkiController.NavigationState.AIRBORNE
		and _vehicle.rear_submerged_ratio > 0.0
		and _vehicle.propulsion_contact_factor > wake_minimum_contact
		and _vehicle.water_relative_forward_speed > wake_minimum_speed
	)


func _rebuild_mesh() -> void:
	_array_mesh.clear_surfaces()
	_trail_length = 0.0
	_current_width = 0.0
	if _samples.size() < 2 or not is_instance_valid(_water):
		return
	_vertices.clear()
	_normals.clear()
	_colors.clear()
	_uvs.clear()
	_indices.clear()
	var cumulative_length: float = 0.0
	var newest_position := _samples[_samples.size() - 1].position
	for index in _samples.size():
		var sample := _samples[index]
		if index > 0:
			cumulative_length += Vector2(
				sample.position.x - _samples[index - 1].position.x,
				sample.position.z - _samples[index - 1].position.z
			).length()
		var surface_position := Vector3(
			sample.position.x,
			_water.sample_height(sample.position) + wake_surface_offset,
			sample.position.z
		)
		var water_normal := _water.sample_normal(sample.position)
		var tangent := _sample_tangent(index)
		var right := tangent.cross(water_normal)
		if right.length_squared() <= 0.000001:
			right = Vector3.RIGHT
		else:
			right = right.normalized()
		var lifetime_ratio := clampf(
			sample.age / maxf(wake_lifetime, 0.001),
			0.0,
			1.0
		)
		var history_ratio := (
			1.0 - float(index) / float(_samples.size() - 1)
			if _samples.size() > 1
			else 0.0
		)
		var age_ratio := maxf(lifetime_ratio, history_ratio)
		var distance_behind_hull := Vector2(
			sample.position.x - newest_position.x,
			sample.position.z - newest_position.z
		).length()
		var width_growth := smoothstep(
			0.0,
			maxf(wake_opening_distance, 0.01),
			distance_behind_hull
		) * lerpf(0.72, 1.0, sample.speed_factor)
		var outer_width := sample.initial_width * lerpf(
			1.0,
			wake_maximum_width_multiplier,
			width_growth
		)
		_current_width = maxf(_current_width, outer_width * 2.0)
		var fade := 1.0 - smoothstep(
			wake_fade_start_ratio,
			1.0,
			age_ratio
		)
		var alpha := fade * lerpf(0.08, 0.28, sample.speed_factor)
		var lateral_ratio := clampf(
			_vehicle.water_relative_lateral_speed
			/ maxf(absf(_vehicle.water_relative_forward_speed), 2.0),
			-1.0,
			1.0
		)
		var steering_bias := clampf(
			lateral_ratio * 0.45 + _vehicle.steering_input * 0.18,
			-0.35,
			0.35
		)
		var left_color := Color(
			age_ratio,
			sample.speed_factor,
			0.5 + steering_bias * 0.5,
			alpha * (1.0 + steering_bias * 0.22)
		)
		var right_color := Color(
			age_ratio,
			sample.speed_factor,
			0.5 + steering_bias * 0.5,
			alpha * (1.0 - steering_bias * 0.22)
		)
		_append_wake_vertex(
			surface_position - right * outer_width,
			water_normal,
			left_color,
			Vector2(0.0, cumulative_length)
		)
		_append_wake_vertex(
			surface_position + right * outer_width,
			water_normal,
			right_color,
			Vector2(1.0, cumulative_length)
		)
		if index > 0:
			var previous_base := (index - 1) * 2
			var current_base := index * 2
			_append_strip_indices(
				previous_base,
				previous_base + 1,
				current_base,
				current_base + 1
			)
	_trail_length = cumulative_length
	if _indices.is_empty():
		return
	_mesh_arrays.fill(null)
	_mesh_arrays[Mesh.ARRAY_VERTEX] = _vertices
	_mesh_arrays[Mesh.ARRAY_NORMAL] = _normals
	_mesh_arrays[Mesh.ARRAY_COLOR] = _colors
	_mesh_arrays[Mesh.ARRAY_TEX_UV] = _uvs
	_mesh_arrays[Mesh.ARRAY_INDEX] = _indices
	_array_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, _mesh_arrays)


func _sample_tangent(index: int) -> Vector3:
	var tangent := Vector3.ZERO
	if index > 0 and index + 1 < _samples.size():
		tangent = _samples[index + 1].position - _samples[index - 1].position
	elif index + 1 < _samples.size():
		tangent = _samples[index + 1].position - _samples[index].position
	elif index > 0:
		tangent = _samples[index].position - _samples[index - 1].position
	tangent.y = 0.0
	if tangent.length_squared() <= 0.000001:
		tangent = _samples[index].forward_direction
	return tangent.normalized()


func _append_wake_vertex(
	vertex_position: Vector3,
	normal: Vector3,
	color: Color,
	uv: Vector2
) -> void:
	_vertices.append(vertex_position)
	_normals.append(normal)
	_colors.append(color)
	_uvs.append(uv)


func _append_strip_indices(
	previous_left: int,
	previous_right: int,
	current_left: int,
	current_right: int
) -> void:
	_indices.append(previous_left)
	_indices.append(current_left)
	_indices.append(previous_right)
	_indices.append(previous_right)
	_indices.append(current_left)
	_indices.append(current_right)


func _measured_hull_half_width() -> float:
	if is_instance_valid(_rear_left) and is_instance_valid(_rear_right):
		var separation := Vector2(
			_rear_left.global_position.x - _rear_right.global_position.x,
			_rear_left.global_position.z - _rear_right.global_position.z
		).length()
		if separation > 0.1:
			return separation * 0.5
	return 0.5


func _update_foam_intensity(delta: float) -> void:
	var target_intensity: float = 0.0
	if not (
		_foam_settings == null
		or not _foam_settings.foam_enabled
		or not is_instance_valid(_vehicle)
		or _vehicle.navigation_state == JetSkiController.NavigationState.AIRBORNE
	):
		var speed_factor := clampf(
			inverse_lerp(
				wake_minimum_speed,
				maxf(wake_full_speed, wake_minimum_speed + 0.001),
				_vehicle.water_relative_forward_speed
			),
			0.0,
			1.0
		)
		target_intensity = clampf(
			speed_factor
			* _vehicle.rear_submerged_ratio
			* _vehicle.propulsion_contact_factor
			* _foam_settings.wake_foam_strength,
			0.0,
			1.0
		)
	var response := 9.0 if target_intensity > foam_intensity else 1.35
	var blend := 1.0 - exp(-response * maxf(delta, 0.0))
	foam_intensity = lerpf(foam_intensity, target_intensity, blend)


func _update_foam_material(force_update: bool) -> void:
	var signature := _foam_settings.configuration_signature() if _foam_settings != null else 0
	if not force_update and signature == _foam_settings_signature:
		var current_material := _wake_mesh.material_override as ShaderMaterial
		if current_material != null and is_instance_valid(_water):
			current_material.set_shader_parameter(
				&"simulation_time",
				_water.get_simulation_time()
			)
			current_material.set_shader_parameter(&"foam_intensity", foam_intensity)
		return
	var material := _wake_mesh.material_override as ShaderMaterial
	if material != null and _foam_settings != null:
		material.set_shader_parameter(&"foam_noise_texture", _foam_noise_texture)
		material.set_shader_parameter(&"foam_color", _foam_settings.foam_color)
		material.set_shader_parameter(&"macro_noise_scale", _foam_settings.macro_noise_scale)
		material.set_shader_parameter(&"detail_noise_scale", _foam_settings.detail_noise_scale)
		material.set_shader_parameter(&"noise_scroll_speed", _foam_settings.noise_scroll_speed)
		material.set_shader_parameter(&"breakup_strength", _foam_settings.breakup_strength)
		material.set_shader_parameter(
			&"opacity_boost",
			_foam_settings.wake_foam_opacity_boost
		)
		material.set_shader_parameter(
			&"core_opacity",
			_foam_settings.wake_foam_core_opacity
		)
		material.set_shader_parameter(
			&"emission_strength",
			_foam_settings.wake_foam_emission
		)
	_foam_settings_signature = signature
