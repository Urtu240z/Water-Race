class_name PersistentFoamTrail3D
extends Node3D

## World-space persistent foam for the player JetSki ("Persistent Foam V2").
##
## Every deposited sample pins a fixed XZ position in the world. Turning,
## steering, aging and new deposits NEVER rewrite an old sample's position;
## only an explicit world rebase shifts them. The visual ribbon is rebuilt
## from those stored positions (authority), with only Y following the ocean
## surface so the foam rides the waves without sliding horizontally.

class PersistentFoamSample:
	var position_xz: Vector2
	var age: float = 0.0
	var half_width: float = 1.0
	var intensity: float = 1.0
	var forward: Vector2 = Vector2(0.0, 1.0)
	var break_before: bool = false
	var serial: int = 0

const REBUILD_INTERVAL: float = 1.0 / 30.0
const LIFETIME_FADE_START_RATIO: float = 0.70
const WIDTH_GROWTH_MAXIMUM: float = 1.35
const WIDTH_GROWTH_TIME: float = 4.0
const MINIMUM_SPEED: float = 4.0
const MINIMUM_CONTACT: float = 0.1
const MAXIMUM_SEGMENT_LENGTH: float = 4.0
const FALLBACK_FOAM_COLOR := Color(0.80, 0.94, 1.0, 0.85)

var enabled: bool = false:
	set(value):
		enabled = value
		if is_node_ready() and is_instance_valid(_mesh_instance):
			if value:
				_mesh_instance.visible = true
				_mesh_update_elapsed = REBUILD_INTERVAL
				_force_mesh_rebuild = true
			else:
				_mesh_instance.visible = false
				clear_trail()
var lifetime: float = 20.0
var sample_distance: float = 0.8
var maximum_points: int = 256
var width_multiplier: float = 1.0
var strength: float = 1.0

var sample_count: int:
	get:
		return _samples.size()

var mesh_rebuild_count: int = 0
var rebase_count: int = 0
var validation_max_horizontal_delta: float = 0.0
var validation_living_samples: int = 0

var _vehicle: JetSkiController
var _ocean: Ocean3D
var _propulsion_point: Marker3D
var _rear_left: Marker3D
var _rear_right: Marker3D
var _foam_settings: WaterFoamSettings
var _foam_noise_texture: Texture2D
var _foam_settings_signature: int = -1
var _material: ShaderMaterial
var _samples: Array[PersistentFoamSample] = []
var _array_mesh := ArrayMesh.new()
var _vertices := PackedVector3Array()
var _normals := PackedVector3Array()
var _colors := PackedColorArray()
var _uvs := PackedVector2Array()
var _indices := PackedInt32Array()
var _surface_scratch: WaterSample3D = WaterSample3D.new()
var _sample_serial: int = 0
var _last_sample_position: Vector2 = Vector2.ZERO
var _has_last_sample: bool = false
var _current_segment_id: int = 0
var _segment_break_pending: bool = true
var _was_generating: bool = false
var _mesh_update_elapsed: float = 0.0
var _force_mesh_rebuild: bool = false
var _validation_origin_positions: Array[Vector2] = []
var _validation_serials: Array[int] = []

@onready var _mesh_instance: MeshInstance3D = $FoamMesh


func _ready() -> void:
	process_physics_priority = 22
	if is_instance_valid(_mesh_instance):
		_mesh_instance.mesh = _array_mesh
		_mesh_instance.visible = enabled and not _samples.is_empty()
		_material = _mesh_instance.material_override as ShaderMaterial


func configure(
	vehicle: JetSkiController,
	ocean: Ocean3D,
	propulsion_point: Marker3D,
	rear_left: Marker3D = null,
	rear_right: Marker3D = null
) -> void:
	_vehicle = vehicle
	_ocean = ocean
	_propulsion_point = propulsion_point
	_rear_left = rear_left
	_rear_right = rear_right


func configure_foam(settings: WaterFoamSettings, noise_texture: Texture2D) -> void:
	_foam_settings = settings
	_foam_noise_texture = noise_texture
	_foam_settings_signature = -1
	_update_foam_material(true)


func _physics_process(delta: float) -> void:
	if not enabled:
		return
	var safe_delta := maxf(delta, 0.0)
	if safe_delta <= 0.0:
		return
	_age_samples(safe_delta)
	_update_deposition()
	_update_mesh_tick(safe_delta)
	_update_material_frame()


func clear_trail() -> void:
	_samples.clear()
	_has_last_sample = false
	_last_sample_position = Vector2.ZERO
	_current_segment_id = 0
	_segment_break_pending = true
	_was_generating = false
	_mesh_update_elapsed = 0.0
	_force_mesh_rebuild = true
	_array_mesh.clear_surfaces()
	if is_instance_valid(_mesh_instance):
		_mesh_instance.visible = enabled
	clear_position_validation()


func apply_world_rebase(shift: Vector3) -> void:
	var horizontal_shift := Vector2(shift.x, shift.z)
	if horizontal_shift.is_zero_approx() or not shift.is_finite():
		return
	for sample in _samples:
		sample.position_xz -= horizontal_shift
	if _has_last_sample:
		_last_sample_position -= horizontal_shift
	rebase_count += 1
	_mesh_update_elapsed = REBUILD_INTERVAL
	_force_mesh_rebuild = true


func mark_segment_break() -> void:
	if _segment_break_pending:
		return
	_current_segment_id += 1
	_segment_break_pending = true
	_has_last_sample = false


## Debug / test helper: records a sample at an arbitrary world position without
## requiring vehicle state. Used by the headless position-immutability test.
func debug_deposit_sample(
	world_position: Vector3,
	foam_forward: Vector2 = Vector2(0.0, 1.0),
	half_width: float = 1.2,
	foam_intensity: float = 1.0
) -> void:
	_append_sample(
		Vector2(world_position.x, world_position.z),
		foam_forward,
		half_width,
		foam_intensity
	)


func begin_position_validation(maximum_samples: int = 20) -> int:
	_validation_origin_positions.clear()
	_validation_serials.clear()
	validation_max_horizontal_delta = 0.0
	validation_living_samples = 0
	var count := mini(maximum_samples, _samples.size())
	for index in count:
		_validation_origin_positions.append(_samples[index].position_xz)
		_validation_serials.append(_samples[index].serial)
	return count


func get_position_validation_status() -> Dictionary:
	validation_max_horizontal_delta = 0.0
	validation_living_samples = 0
	for serial_index in _validation_serials.size():
		var serial := _validation_serials[serial_index]
		for sample in _samples:
			if sample.serial == serial:
				validation_living_samples += 1
				validation_max_horizontal_delta = maxf(
					validation_max_horizontal_delta,
					Vector2(
						sample.position_xz - _validation_origin_positions[serial_index]
					).length()
				)
				break
	return {
		&"snapshot_count": _validation_origin_positions.size(),
		&"living_samples": validation_living_samples,
		&"max_horizontal_position_delta": validation_max_horizontal_delta,
	}


func clear_position_validation() -> void:
	_validation_origin_positions.clear()
	_validation_serials.clear()
	validation_max_horizontal_delta = 0.0
	validation_living_samples = 0


func _can_deposit() -> bool:
	if (
		not is_instance_valid(_vehicle)
		or not is_instance_valid(_ocean)
		or not is_instance_valid(_propulsion_point)
	):
		return false
	if _vehicle.navigation_state == JetSkiController.NavigationState.AIRBORNE:
		return false
	if _vehicle.rear_submerged_ratio <= 0.0:
		return false
	if _vehicle.propulsion_contact_factor < MINIMUM_CONTACT:
		return false
	if absf(_vehicle.water_relative_forward_speed) < MINIMUM_SPEED:
		return false
	return true


func _update_deposition() -> void:
	var generating := _can_deposit()
	if _was_generating and not generating:
		mark_segment_break()
	_was_generating = generating
	if not generating:
		return
	var position := _propulsion_point.global_position
	var position_xz := Vector2(position.x, position.z)
	if _has_last_sample and position_xz.distance_to(_last_sample_position) < sample_distance:
		return
	_append_sample(
		position_xz,
		_movement_direction(position_xz),
		_measured_hull_half_width() * width_multiplier,
		_measure_intensity()
	)


func _append_sample(
	position_xz: Vector2,
	foam_forward: Vector2,
	half_width: float,
	foam_intensity: float
) -> PersistentFoamSample:
	if not position_xz.is_finite():
		return null
	var safe_forward := foam_forward if foam_forward.is_finite() else Vector2(0.0, 1.0)
	var sample := PersistentFoamSample.new()
	sample.position_xz = position_xz
	sample.forward = safe_forward
	sample.half_width = half_width
	sample.intensity = foam_intensity
	sample.break_before = _segment_break_pending
	sample.serial = _sample_serial
	_sample_serial += 1
	_samples.append(sample)
	_segment_break_pending = false
	while _samples.size() > maxi(maximum_points, 8):
		_samples.pop_front()
	_last_sample_position = position_xz
	_has_last_sample = true
	_mesh_update_elapsed = REBUILD_INTERVAL
	_force_mesh_rebuild = true
	return sample


func _age_samples(delta: float) -> void:
	for sample in _samples:
		sample.age += delta
	var retention_lifetime := maxf(lifetime, 0.1)
	while not _samples.is_empty() and _samples[0].age >= retention_lifetime:
		_samples.pop_front()
	if _samples.is_empty() and _array_mesh.get_surface_count() > 0:
		_array_mesh.clear_surfaces()


func _measure_intensity() -> float:
	if not is_instance_valid(_vehicle):
		return strength
	var speed := absf(_vehicle.water_relative_forward_speed)
	return clampf(
		inverse_lerp(MINIMUM_SPEED, 15.0, speed) * strength,
		0.0,
		1.0
	)


func _movement_direction(position_xz: Vector2) -> Vector2:
	if _has_last_sample:
		var move := position_xz - _last_sample_position
		if move.length_squared() > 0.000001:
			return move.normalized()
	if is_instance_valid(_vehicle):
		return _flatten_direction(-_vehicle.global_basis.z)
	return Vector2(0.0, 1.0)


func _flatten_direction(direction: Vector3) -> Vector2:
	var flat := Vector2(direction.x, direction.z)
	if flat.length_squared() <= 0.000001 or not flat.is_finite():
		return Vector2(0.0, 1.0)
	return flat.normalized()


func _measured_hull_half_width() -> float:
	if is_instance_valid(_rear_left) and is_instance_valid(_rear_right):
		var separation := Vector2(
			_rear_left.global_position.x - _rear_right.global_position.x,
			_rear_left.global_position.z - _rear_right.global_position.z
		).length()
		if separation > 0.1:
			return separation * 0.5
	return 0.6


func _update_mesh_tick(_delta: float) -> void:
	if _samples.size() < 2:
		if _array_mesh.get_surface_count() > 0:
			_array_mesh.clear_surfaces()
		return
	if not _force_mesh_rebuild and _mesh_update_elapsed < REBUILD_INTERVAL:
		return
	_mesh_update_elapsed = 0.0
	_force_mesh_rebuild = false
	_rebuild_mesh()


func _rebuild_mesh() -> void:
	mesh_rebuild_count += 1
	_array_mesh.clear_surfaces()
	_vertices.clear()
	_normals.clear()
	_colors.clear()
	_uvs.clear()
	_indices.clear()
	if _samples.size() < 2 or not is_instance_valid(_ocean):
		return
	var cumulative_length := 0.0
	for index in _samples.size():
		var sample := _samples[index]
		if index > 0 and not sample.break_before:
			cumulative_length += (
				sample.position_xz - _samples[index - 1].position_xz
			).length()
		var surface_normal := Vector3.UP
		var surface_y := 0.0
		if is_instance_valid(_ocean):
			var surface := _ocean.sample_base_surface(
				Vector3(sample.position_xz.x, 0.0, sample.position_xz.y),
				_surface_scratch
			)
			surface_y = surface.surface_position.y
			if surface.normal.is_finite() and surface.normal.length_squared() > 0.000001:
				surface_normal = surface.normal.normalized()
		elif is_instance_valid(_propulsion_point):
			surface_y = _propulsion_point.global_position.y
		var right := Vector2(sample.forward.y, -sample.forward.x)
		var growth_ratio := clampf(sample.age / WIDTH_GROWTH_TIME, 0.0, 1.0)
		var current_half_width := sample.half_width * lerpf(
			1.0,
			WIDTH_GROWTH_MAXIMUM,
			growth_ratio
		)
		var left_xz := sample.position_xz - right * current_half_width
		var right_xz := sample.position_xz + right * current_half_width
		var age_ratio := clampf(sample.age / maxf(lifetime, 0.001), 0.0, 1.0)
		var sample_color := Color(age_ratio, sample.intensity, 0.0, 1.0)
		_append_surface_vertex(
			Vector3(left_xz.x, surface_y, left_xz.y),
			surface_normal,
			sample_color,
			Vector2(0.0, cumulative_length)
		)
		_append_surface_vertex(
			Vector3(right_xz.x, surface_y, right_xz.y),
			surface_normal,
			sample_color,
			Vector2(1.0, cumulative_length)
		)
		if index > 0 and not sample.break_before:
			var previous := _samples[index - 1]
			if (
				previous.position_xz.distance_to(sample.position_xz)
				<= MAXIMUM_SEGMENT_LENGTH
			):
				var base := index * 2
				var previous_base := base - 2
				_indices.append_array(PackedInt32Array([
					previous_base, base, previous_base + 1,
					previous_base + 1, base, base + 1,
				]))
	if _indices.is_empty():
		return
	var surface_arrays: Array = []
	surface_arrays.resize(Mesh.ARRAY_MAX)
	surface_arrays.fill(null)
	surface_arrays[Mesh.ARRAY_VERTEX] = _vertices
	surface_arrays[Mesh.ARRAY_NORMAL] = _normals
	surface_arrays[Mesh.ARRAY_COLOR] = _colors
	surface_arrays[Mesh.ARRAY_TEX_UV] = _uvs
	surface_arrays[Mesh.ARRAY_INDEX] = _indices
	_array_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, surface_arrays)
	if is_instance_valid(_mesh_instance):
		_mesh_instance.custom_aabb = _array_mesh.get_aabb().grow(2.0)


func _append_surface_vertex(
	vertex_position: Vector3,
	vertex_normal: Vector3,
	vertex_color: Color,
	uv: Vector2
) -> void:
	_vertices.append(vertex_position)
	_normals.append(vertex_normal)
	_colors.append(vertex_color)
	_uvs.append(uv)


func _update_foam_material(force_update: bool) -> void:
	if _material == null:
		return
	var signature := (
		_foam_settings.configuration_signature() if _foam_settings != null else 0
	)
	if not force_update and signature == _foam_settings_signature:
		return
	var foam_color := (
		_foam_settings.foam_color
		if _foam_settings != null
		else FALLBACK_FOAM_COLOR
	)
	var macro_noise_scale := (
		_foam_settings.macro_noise_scale if _foam_settings != null else 0.055
	)
	var detail_noise_scale := (
		_foam_settings.detail_noise_scale if _foam_settings != null else 0.19
	)
	var breakup_strength := (
		_foam_settings.breakup_strength if _foam_settings != null else 0.78
	)
	var opacity_boost := (
		_foam_settings.wake_foam_opacity_boost if _foam_settings != null else 1.0
	)
	var core_opacity := (
		_foam_settings.wake_foam_core_opacity if _foam_settings != null else 0.22
	)
	var emission_strength := (
		_foam_settings.wake_foam_emission if _foam_settings != null else 0.05
	)
	var foam_roughness := (
		_foam_settings.foam_roughness if _foam_settings != null else 0.88
	)
	_material.set_shader_parameter(&"foam_color", foam_color)
	_material.set_shader_parameter(&"foam_noise_texture", _foam_noise_texture)
	_material.set_shader_parameter(&"macro_noise_scale", macro_noise_scale)
	_material.set_shader_parameter(&"detail_noise_scale", detail_noise_scale)
	_material.set_shader_parameter(&"breakup_strength", breakup_strength)
	_material.set_shader_parameter(&"opacity_boost", opacity_boost)
	_material.set_shader_parameter(&"core_opacity", core_opacity)
	_material.set_shader_parameter(&"emission_strength", emission_strength)
	_material.set_shader_parameter(&"foam_roughness", foam_roughness)
	_foam_settings_signature = signature


func _update_material_frame() -> void:
	if _material == null:
		return
	_material.set_shader_parameter(
		&"simulation_time",
		_ocean.get_simulation_time() if is_instance_valid(_ocean) else 0.0
	)