@tool
class_name Ocean3D
extends Node3D

## Single authority for the visible and physical ocean.
##
## Ocean3D owns simulation time, CPU surface sampling, dynamic ripples,
## wake impulses, shader synchronization, logical-world rebasing and the
## OceanSurface3D child. It intentionally does not inherit from the former generic water system.

const MAX_RIPPLES: int = 12
const MAX_DIRECTIONAL_WAKE_SAMPLES: int = 16
const MIN_SAMPLE_STEP: float = 0.05
const MACRO_MATERIAL_SYNC_INTERVAL: float = 0.25

@export_group("Targets")
@export_node_path("Node3D") var follow_target_path: NodePath
@export_node_path("Camera3D") var follow_camera_path: NodePath
@export_node_path("Node3D") var ripple_emitter_target_path: NodePath

@export_group("Ocean")
@export var water_level: float = 0.0:
	set(value):
		water_level = value
		_static_parameters_dirty = true
		if is_inside_tree():
			_push_static_parameters_to_all_materials()
			_configure_surface()
@export var ocean_material: ShaderMaterial:
	set(value):
		ocean_material = value
		_macro_material_signature = -1
		_static_parameters_dirty = true
		_refresh_material_cache()

		if is_inside_tree():
			_configure_surface()
			_push_all_shader_parameters()
@export var wave_height_texture_a: Texture2D:
	set(value):
		wave_height_texture_a = value
		_runtime_wave_texture_a = null
		_wave_image_a = null
		_static_parameters_dirty = true
@export var wave_height_texture_b: Texture2D:
	set(value):
		wave_height_texture_b = value
		_runtime_wave_texture_b = null
		_wave_image_b = null
		_static_parameters_dirty = true

@export_subgroup("Macro Waves")
@export_range(8.0, 600.0, 0.5, "suffix:m") var wave_world_size_a: float = 180.0
@export_range(8.0, 600.0, 0.5, "suffix:m") var wave_world_size_b: float = 72.0
@export_range(0.0, 4.0, 0.01, "suffix:m") var wave_amplitude_a: float = 1.35
@export_range(0.0, 4.0, 0.01, "suffix:m") var wave_amplitude_b: float = 0.42
@export var wave_direction_a: Vector2 = Vector2(0.86, 0.51)
@export var wave_direction_b: Vector2 = Vector2(-0.38, 0.92)
@export_range(-20.0, 20.0, 0.05, "suffix:m/s") var wave_travel_speed_a: float = 4.6
@export_range(-20.0, 20.0, 0.05, "suffix:m/s") var wave_travel_speed_b: float = 2.3
@export_range(0.0, 1.0, 0.001) var wave_mean_a: float = 0.50
@export_range(0.0, 1.0, 0.001) var wave_mean_b: float = 0.47
@export_range(0.05, 2.0, 0.05, "suffix:m") var normal_sample_step: float = 0.40

@export_subgroup("Impact Ripples")
@export_range(0.0, 1.0, 0.005, "suffix:m") var wake_ripple_amplitude: float = 0.075
@export_range(0.1, 12.0, 0.05, "suffix:m/s") var ripple_speed: float = 3.4
@export_range(0.25, 12.0, 0.05, "suffix:m") var ripple_wavelength: float = 2.6
@export_range(0.0, 4.0, 0.01) var ripple_decay: float = 0.72
@export_range(0.25, 12.0, 0.05, "suffix:s") var ripple_lifetime: float = 4.6
@export_range(0.0, 0.5, 0.01, "suffix:s") var impact_merge_cooldown: float = 0.14
# Kept as a serialized compatibility property and used as the minimum lateral
# separation of the optional secondary landing ripples.
@export_range(0.0, 2.0, 0.05, "suffix:m") var wake_lateral_offset: float = 0.0

@export_group("Directional Wake")
@export var directional_wake_enabled: bool = true
@export_range(8, MAX_DIRECTIONAL_WAKE_SAMPLES, 1) var directional_wake_sample_count: int = 16
@export_range(0.0, 0.5, 0.005, "suffix:m") var directional_wake_amplitude: float = 0.11
@export_range(0.25, 12.0, 0.05, "suffix:m") var directional_wake_wavelength: float = 2.4
@export_range(0.0, 12.0, 0.05, "suffix:m/s") var directional_wake_propagation_speed: float = 2.1
@export_range(0.02, 1.0, 0.01) var directional_wake_opening_slope: float = 0.24
@export_range(0.1, 4.0, 0.05, "suffix:m") var directional_wake_arm_width: float = 0.72
@export_range(0.0, 0.5, 0.005, "suffix:m") var directional_wake_center_depression: float = 0.055
@export_range(4.0, 100.0, 1.0, "suffix:m") var directional_wake_maximum_distance: float = 46.0
@export_range(0.25, 12.0, 0.05, "suffix:s") var directional_wake_duration: float = 4.2
@export_range(0.0, 0.2, 0.001) var directional_wake_attenuation: float = 0.028
@export_range(0.0, 2.0, 0.01) var directional_wake_turn_strength: float = 0.65
@export_range(0.025, 0.25, 0.005, "suffix:s") var vehicle_interaction_update_interval: float = 0.05

@export_group("Hull Pressure")
@export var hull_pressure_enabled: bool = true
@export_range(0.0, 0.5, 0.005, "suffix:m") var hull_pressure_amplitude: float = 0.14
@export_range(0.0, 2.0, 0.01) var hull_pressure_depression_strength: float = 0.72
@export_range(2.0, 30.0, 0.25, "suffix:m") var hull_pressure_maximum_distance: float = 9.0

@export_group("Vehicle Interaction Limits")
@export_range(0.05, 2.0, 0.01, "suffix:m") var vehicle_interaction_maximum_displacement: float = 0.48
@export_range(8.0, 200.0, 1.0, "suffix:m") var vehicle_interaction_clipmap_distance: float = 86.0
@export_enum("Disabled:0", "Ripples:1", "Directional Wake:2", "Hull Pressure:3", "Total:4")
var ocean_interaction_debug_mode: int = 0

@export_group("Foam")
@export var wave_crest_color: Color = Color(0.090, 0.500, 0.610, 1.0)
# Preserved because the current scene assigns these resources. The ocean
## shader consumes foam_noise_texture directly; higher-level effects may query
## foam_settings through get_foam_settings().
@export var foam_settings: WaterFoamSettings
@export var foam_noise_texture: Texture2D

@export_group("Editor")
@export_tool_button("Apply Ocean Settings")
var apply_ocean_settings_button: Callable = apply_ocean_settings
@export_tool_button("Rebuild Height Maps")
var rebuild_height_maps_button: Callable = rebuild_height_maps

var follow_target: Node3D
var follow_camera: Camera3D
var ripple_emitter_target: Node3D

var _surface: OceanSurface3D
var _simulation_time: float = 0.0
var _logical_origin_xz := Vector2.ZERO
var _wave_image_a: Image
var _wave_image_b: Image
var _runtime_wave_texture_a: Texture2D
var _runtime_wave_texture_b: Texture2D
var _external_materials: Array[ShaderMaterial] = []
var _material_cache: Array[ShaderMaterial] = []

var _ripple_active := PackedInt32Array()
var _ripple_positions := PackedVector2Array()
var _ripple_start_times := PackedFloat32Array()
var _ripple_amplitudes := PackedFloat32Array()
var _ripple_speeds := PackedFloat32Array()
var _ripple_wavelengths := PackedFloat32Array()
var _ripple_decays := PackedFloat32Array()
var _ripple_lifetimes := PackedFloat32Array()

var _wake_source: WakeTrail3D
var _interaction_vehicle: JetSkiController
var _interaction_front_left: Marker3D
var _interaction_front_right: Marker3D
var _interaction_rear_left: Marker3D
var _interaction_rear_right: Marker3D
var _interaction_propulsion_point: Marker3D
var _directional_wake_positions := PackedVector2Array()
var _directional_wake_directions := PackedVector2Array()
var _directional_wake_start_times := PackedFloat32Array()
var _directional_wake_intensities := PackedFloat32Array()
var _directional_wake_widths := PackedFloat32Array()
var _directional_wake_biases := PackedFloat32Array()
var _directional_wake_active_count: int = 0
var _effective_directional_wake_sample_count: int = MAX_DIRECTIONAL_WAKE_SAMPLES
var _vehicle_interaction_quality_level: int = 2
var _interaction_update_elapsed: float = 0.0
var _hull_pressure_center := Vector2.ZERO
var _hull_pressure_forward := Vector2(0.0, -1.0)
var _hull_pressure_half_extents := Vector2(0.6, 1.45)
var _hull_pressure_contact: float = 0.0
var _hull_pressure_intensity: float = 0.0
var _hull_pressure_left_strength: float = 0.0
var _hull_pressure_right_strength: float = 0.0
var _hull_pressure_turn_bias: float = 0.0
var _hull_pressure_pitch: float = 0.0
var _last_interaction_horizontal_velocity := Vector2.ZERO
var _has_last_interaction_velocity: bool = false
var _last_impact_time: float = -INF
var _last_impact_logical_xz := Vector2.ZERO
var _merged_impact_count: int = 0
var _interaction_uniform_update_count: int = 0
var _interaction_uniform_write_count: int = 0
var _maximum_requested_interaction_amplitude: float = 0.0
var _directional_wake_updated_last_tick: bool = false
var _static_parameters_dirty: bool = true
var _ripple_parameters_dirty: bool = true
var _editor_refresh_elapsed: float = 0.0

var _macro_material_sync_elapsed: float = 0.0
var _macro_material_signature: int = -1


func _enter_tree() -> void:
	if Engine.is_editor_hint():
		call_deferred(&"_refresh_editor_preview")


func _ready() -> void:
	process_priority = -100
	process_physics_priority = -100
	_surface = get_node_or_null("Surface") as OceanSurface3D
	_sync_macro_waves_from_material(true)
	_initialize_ripples()
	_initialize_vehicle_interactions()
	_resolve_targets()
	_refresh_material_cache()
	_configure_surface()
	configure_ripple_emitter(ripple_emitter_target)
	set_process(Engine.is_editor_hint())
	set_physics_process(not Engine.is_editor_hint())
	_push_all_shader_parameters()

	if not Engine.is_editor_hint():
		_build_runtime_height_maps_when_ready()
	else:
		update_configuration_warnings()


func _process(delta: float) -> void:
	if not Engine.is_editor_hint():
		return
	_editor_refresh_elapsed += maxf(delta, 0.0)
	if _editor_refresh_elapsed < 0.25:
		return
	_editor_refresh_elapsed = 0.0
	_sync_macro_waves_from_material()
	_resolve_targets()
	_configure_surface()
	_push_time_parameter_to_all_materials()
	if _static_parameters_dirty:
		_push_static_parameters_to_all_materials()
	if _ripple_parameters_dirty:
		_push_ripple_parameters_to_all_materials()


func _physics_process(delta: float) -> void:
	var safe_delta := maxf(delta, 0.0)
	_macro_material_sync_elapsed += safe_delta
	if (
		_macro_material_sync_elapsed
		>= MACRO_MATERIAL_SYNC_INTERVAL
	):
		_macro_material_sync_elapsed = 0.0
		if _sync_macro_waves_from_material():
			if (
				_wave_image_a == null
				or _wave_image_b == null
			):
				_build_runtime_height_maps()
	_simulation_time += safe_delta
	if _expire_ripples():
		_ripple_parameters_dirty = true
	_interaction_update_elapsed += safe_delta
	var interaction_interval := maxf(vehicle_interaction_update_interval, 0.025)
	if _interaction_update_elapsed >= interaction_interval:
		var interaction_delta := _interaction_update_elapsed
		_interaction_update_elapsed = fmod(
			_interaction_update_elapsed,
			interaction_interval
		)
		_update_vehicle_interactions(interaction_delta)
		_push_vehicle_interaction_parameters_to_all_materials()
	_push_time_parameter_to_all_materials()
	if _static_parameters_dirty:
		_push_static_parameters_to_all_materials()
	if _ripple_parameters_dirty:
		_push_ripple_parameters_to_all_materials()


func _exit_tree() -> void:
	_disconnect_ripple_emitter_signals()


func _get_configuration_warnings() -> PackedStringArray:
	var warnings := PackedStringArray()
	if get_node_or_null("Surface") is not OceanSurface3D:
		warnings.append("Ocean3D requires an OceanSurface3D child named Surface.")
	if ocean_material == null or ocean_material.shader == null:
		warnings.append("Assign a persistent ShaderMaterial to ocean_material.")
	if wave_height_texture_a == null or wave_height_texture_b == null:
		warnings.append("Assign both macro wave height textures.")
	if not follow_target_path.is_empty() and get_node_or_null(follow_target_path) == null:
		warnings.append("The configured follow target cannot be resolved.")
	if not follow_camera_path.is_empty() and get_node_or_null(follow_camera_path) == null:
		warnings.append("The configured follow camera cannot be resolved.")
	if not ripple_emitter_target_path.is_empty() and get_node_or_null(ripple_emitter_target_path) == null:
		warnings.append("The configured ripple emitter cannot be resolved.")
	return warnings


func apply_ocean_settings() -> void:
	if _directional_wake_positions.size() != MAX_DIRECTIONAL_WAKE_SAMPLES:
		_initialize_vehicle_interactions()
	_static_parameters_dirty = true
	_ripple_parameters_dirty = true
	set_vehicle_interaction_quality(_vehicle_interaction_quality_level)
	_resolve_targets()
	_configure_surface()
	_push_all_shader_parameters()
	if Engine.is_editor_hint():
		update_configuration_warnings()


func rebuild_height_maps() -> void:
	_runtime_wave_texture_a = null
	_runtime_wave_texture_b = null
	_wave_image_a = null
	_wave_image_b = null
	if _build_runtime_height_maps():
		_static_parameters_dirty = true
		_push_all_shader_parameters()
	elif not Engine.is_editor_hint():
		push_warning("Ocean3D could not rebuild synchronized height maps.")


func get_surface() -> OceanSurface3D:
	return _surface


func get_foam_settings() -> WaterFoamSettings:
	return foam_settings


var directional_wake_active_samples: int:
	get:
		return _directional_wake_active_count


var maximum_requested_interaction_amplitude: float:
	get:
		return _maximum_requested_interaction_amplitude


var hull_pressure_field_intensity: float:
	get:
		return _hull_pressure_intensity * _hull_pressure_contact


var hull_pressure_left_force: float:
	get:
		return _hull_pressure_left_strength


var hull_pressure_right_force: float:
	get:
		return _hull_pressure_right_strength


var directional_wake_is_updating: bool:
	get:
		return _directional_wake_updated_last_tick


var interaction_uniform_update_count: int:
	get:
		return _interaction_uniform_update_count


var interaction_uniform_write_count: int:
	get:
		return _interaction_uniform_write_count


var merged_impact_count: int:
	get:
		return _merged_impact_count


func configure_ripple_emitter(target: Node3D) -> void:
	if ripple_emitter_target == target:
		_connect_ripple_emitter_signals()
		return
	_disconnect_ripple_emitter_signals()
	ripple_emitter_target = target
	_connect_ripple_emitter_signals()


func configure_vehicle_interaction_source(
	wake_source: WakeTrail3D,
	vehicle: JetSkiController,
	front_left: Marker3D,
	front_right: Marker3D,
	rear_left: Marker3D,
	rear_right: Marker3D,
	propulsion_point: Marker3D
) -> void:
	_wake_source = wake_source
	_interaction_vehicle = vehicle
	_interaction_front_left = front_left
	_interaction_front_right = front_right
	_interaction_rear_left = rear_left
	_interaction_rear_right = rear_right
	_interaction_propulsion_point = propulsion_point
	if is_instance_valid(_wake_source):
		_wake_source.directional_history_lifetime = maxf(
			_wake_source.wake_lifetime,
			directional_wake_duration
		)
	_interaction_update_elapsed = maxf(vehicle_interaction_update_interval, 0.025)


func set_vehicle_interaction_quality(quality_level: int) -> void:
	_vehicle_interaction_quality_level = clampi(quality_level, 0, 2)
	match _vehicle_interaction_quality_level:
		0:
			_effective_directional_wake_sample_count = 8
		1:
			_effective_directional_wake_sample_count = 12
		_:
			_effective_directional_wake_sample_count = 16
	_effective_directional_wake_sample_count = mini(
		_effective_directional_wake_sample_count,
		clampi(
			directional_wake_sample_count,
			8,
			MAX_DIRECTIONAL_WAKE_SAMPLES
		)
	)
	_interaction_update_elapsed = maxf(vehicle_interaction_update_interval, 0.025)


func add_ripple(
	world_position: Vector3,
	amplitude: float = -1.0,
	speed: float = -1.0,
	wavelength: float = -1.0,
	decay: float = -1.0,
	lifetime: float = -1.0
) -> void:
	if not world_position.is_finite():
		return
	var slot := _find_ripple_slot()
	_ripple_active[slot] = 1
	_ripple_positions[slot] = world_to_logical_xz(world_position)
	_ripple_start_times[slot] = _simulation_time
	_ripple_amplitudes[slot] = wake_ripple_amplitude if amplitude < 0.0 else maxf(amplitude, 0.0)
	_ripple_speeds[slot] = ripple_speed if speed < 0.0 else maxf(speed, 0.01)
	_ripple_wavelengths[slot] = ripple_wavelength if wavelength < 0.0 else maxf(wavelength, 0.05)
	_ripple_decays[slot] = ripple_decay if decay < 0.0 else maxf(decay, 0.0)
	_ripple_lifetimes[slot] = ripple_lifetime if lifetime < 0.0 else maxf(lifetime, 0.05)
	_ripple_parameters_dirty = true


func clear_ripples() -> void:
	_ripple_active.fill(0)
	_ripple_parameters_dirty = true
	_push_ripple_parameters_to_all_materials()


func sample_height(world_position: Vector3) -> float:
	return water_level + _sample_surface_offset(
		world_to_logical_xz(world_position),
		_simulation_time
	)


func sample_normal(world_position: Vector3) -> Vector3:
	var logical_xz := world_to_logical_xz(world_position)
	var step := maxf(normal_sample_step, MIN_SAMPLE_STEP)
	var left := _sample_surface_offset(logical_xz - Vector2(step, 0.0), _simulation_time)
	var right := _sample_surface_offset(logical_xz + Vector2(step, 0.0), _simulation_time)
	var back := _sample_surface_offset(logical_xz - Vector2(0.0, step), _simulation_time)
	var front := _sample_surface_offset(logical_xz + Vector2(0.0, step), _simulation_time)
	var derivatives := Vector2(
		(right - left) / (2.0 * step),
		(front - back) / (2.0 * step)
	)
	return Vector3(-derivatives.x, 1.0, -derivatives.y).normalized()


func sample_surface_derivatives(world_position: Vector3) -> Vector2:
	var normal := sample_normal(world_position)
	var safe_y := maxf(normal.y, 0.0001)
	return Vector2(-normal.x / safe_y, -normal.z / safe_y)


func sample_water_velocity(world_position: Vector3) -> Vector3:
	var logical_xz := world_to_logical_xz(world_position)
	const TIME_STEP: float = 0.02
	var previous_height := _sample_surface_offset(logical_xz, _simulation_time - TIME_STEP)
	var next_height := _sample_surface_offset(logical_xz, _simulation_time + TIME_STEP)
	return Vector3(0.0, (next_height - previous_height) / (2.0 * TIME_STEP), 0.0)


func sample_vertical_velocity(world_position: Vector3) -> float:
	return sample_water_velocity(world_position).y


func sample_depth(world_position: Vector3) -> float:
	return sample_height(world_position) - world_position.y


func sample_crest_metric(world_position: Vector3) -> float:
	var height_offset := sample_height(world_position) - water_level
	var slope := sample_surface_derivatives(world_position).length()
	var height_factor := smoothstep(0.18, 0.92, height_offset)
	var slope_factor := smoothstep(0.05, 0.34, slope)
	return clampf(height_factor * lerpf(0.58, 1.0, slope_factor), 0.0, 1.0)


func sample_breaking_metric(world_position: Vector3) -> float:
	return sample_crest_metric(world_position)


func sample_constructive_interference_metric(world_position: Vector3) -> float:
	var ripple_height := absf(_sample_ripple_height(
		world_to_logical_xz(world_position),
		_simulation_time
	))
	return clampf(ripple_height / maxf(wake_ripple_amplitude, 0.001), 0.0, 1.0)


func sample_crest_direction(_world_position: Vector3) -> Vector2:
	return _safe_direction(wave_direction_a, Vector2.RIGHT)


func world_to_logical_xz(world_position: Vector3) -> Vector2:
	return Vector2(world_position.x, world_position.z) + _logical_origin_xz


func logical_to_world_xz(logical_xz: Vector2) -> Vector2:
	return logical_xz - _logical_origin_xz


func get_simulation_time() -> float:
	return _simulation_time


func get_logical_origin_offset_xz() -> Vector2:
	return _logical_origin_xz


func get_active_water_material() -> ShaderMaterial:
	return ocean_material


func register_external_water_material(material: ShaderMaterial) -> void:
	if material == null or material.shader == null:
		return
	if _external_materials.has(material):
		return

	_external_materials.append(material)
	_refresh_material_cache()
	_push_all_parameters_to_material(material)


func unregister_external_water_material(material: ShaderMaterial) -> void:
	_external_materials.erase(material)
	_refresh_material_cache()


func apply_world_rebase(
	_shift: Vector3,
	logical_origin_x: float,
	logical_origin_z: float
) -> void:
	if not is_finite(logical_origin_x) or not is_finite(logical_origin_z):
		return
	_logical_origin_xz = Vector2(logical_origin_x, logical_origin_z)
	_push_origin_parameter_to_all_materials()


func _refresh_editor_preview() -> void:
	if not Engine.is_editor_hint() or not is_node_ready():
		return

	_surface = get_node_or_null("Surface") as OceanSurface3D
	_resolve_targets()
	_configure_surface()
	apply_ocean_settings()


func _resolve_targets() -> void:
	follow_target = get_node_or_null(follow_target_path) as Node3D
	follow_camera = get_node_or_null(follow_camera_path) as Camera3D
	var resolved_ripple_target := get_node_or_null(ripple_emitter_target_path) as Node3D
	if resolved_ripple_target == null:
		resolved_ripple_target = follow_target
	if resolved_ripple_target != ripple_emitter_target:
		configure_ripple_emitter(resolved_ripple_target)


func _configure_surface() -> void:
	if not is_instance_valid(_surface):
		_surface = get_node_or_null("Surface") as OceanSurface3D
	if not is_instance_valid(_surface):
		return
	_surface.ocean = self
	_surface.follow_target = follow_target
	_surface.follow_camera = follow_camera
	_surface.ocean_material = ocean_material
	_surface.water_level = water_level


func _sample_surface_offset(logical_xz: Vector2, sample_time: float) -> float:
	return _sample_macro_height(logical_xz, sample_time) + _sample_ripple_height(logical_xz, sample_time)


func _sample_macro_height(logical_xz: Vector2, sample_time: float) -> float:
	var direction_a := _safe_direction(wave_direction_a, Vector2.RIGHT)
	var direction_b := _safe_direction(wave_direction_b, Vector2.DOWN)
	var uv_a := (
		logical_xz / maxf(wave_world_size_a, 0.001)
		+ direction_a * sample_time * wave_travel_speed_a / maxf(wave_world_size_a, 0.001)
	)
	var uv_b := (
		logical_xz / maxf(wave_world_size_b, 0.001)
		+ direction_b * sample_time * wave_travel_speed_b / maxf(wave_world_size_b, 0.001)
		+ Vector2(0.307, 0.476)
	)
	var height_a := (_sample_image_repeat(_wave_image_a, uv_a) - wave_mean_a) * wave_amplitude_a
	var height_b := (_sample_image_repeat(_wave_image_b, uv_b) - wave_mean_b) * wave_amplitude_b
	return height_a + height_b


func _sample_ripple_height(logical_xz: Vector2, sample_time: float) -> float:
	var height: float = 0.0
	for index in MAX_RIPPLES:
		if _ripple_active[index] == 0:
			continue
		var age := sample_time - _ripple_start_times[index]
		if age < 0.0 or age > _ripple_lifetimes[index]:
			continue
		var radius := age * _ripple_speeds[index]
		var distance_to_center := logical_xz.distance_to(_ripple_positions[index])
		var wavelength := maxf(_ripple_wavelengths[index], 0.05)
		var shell_width := maxf(wavelength * 1.35, 0.1)
		var shell_offset := distance_to_center - radius
		var normalized_shell := shell_offset / shell_width
		var envelope := (
			exp(-normalized_shell * normalized_shell)
			* exp(-age * _ripple_decays[index])
			* smoothstep(0.0, 0.18, age)
		)
		height += sin(shell_offset * TAU / wavelength) * _ripple_amplitudes[index] * envelope
	return height


func _sample_image_repeat(image: Image, uv: Vector2) -> float:
	if image == null or image.is_empty():
		return 0.5
	var width := image.get_width()
	var height := image.get_height()
	if width <= 0 or height <= 0:
		return 0.5
	var wrapped_uv := Vector2(fposmod(uv.x, 1.0), fposmod(uv.y, 1.0))
	var pixel_x := wrapped_uv.x * float(width) - 0.5
	var pixel_y := wrapped_uv.y * float(height) - 0.5
	var x_0 := posmod(floori(pixel_x), width)
	var y_0 := posmod(floori(pixel_y), height)
	var x_1 := (x_0 + 1) % width
	var y_1 := (y_0 + 1) % height
	var weight_x := pixel_x - floorf(pixel_x)
	var weight_y := pixel_y - floorf(pixel_y)
	var top := lerpf(image.get_pixel(x_0, y_0).r, image.get_pixel(x_1, y_0).r, weight_x)
	var bottom := lerpf(image.get_pixel(x_0, y_1).r, image.get_pixel(x_1, y_1).r, weight_x)
	return lerpf(top, bottom, weight_y)


func _initialize_ripples() -> void:
	_ripple_active.resize(MAX_RIPPLES)
	_ripple_positions.resize(MAX_RIPPLES)
	_ripple_start_times.resize(MAX_RIPPLES)
	_ripple_amplitudes.resize(MAX_RIPPLES)
	_ripple_speeds.resize(MAX_RIPPLES)
	_ripple_wavelengths.resize(MAX_RIPPLES)
	_ripple_decays.resize(MAX_RIPPLES)
	_ripple_lifetimes.resize(MAX_RIPPLES)
	_ripple_active.fill(0)
	_ripple_positions.fill(Vector2.ZERO)
	_ripple_start_times.fill(-INF)
	_ripple_amplitudes.fill(0.0)
	_ripple_speeds.fill(ripple_speed)
	_ripple_wavelengths.fill(ripple_wavelength)
	_ripple_decays.fill(ripple_decay)
	_ripple_lifetimes.fill(ripple_lifetime)
	_ripple_parameters_dirty = true


func _initialize_vehicle_interactions() -> void:
	_directional_wake_positions.resize(MAX_DIRECTIONAL_WAKE_SAMPLES)
	_directional_wake_directions.resize(MAX_DIRECTIONAL_WAKE_SAMPLES)
	_directional_wake_start_times.resize(MAX_DIRECTIONAL_WAKE_SAMPLES)
	_directional_wake_intensities.resize(MAX_DIRECTIONAL_WAKE_SAMPLES)
	_directional_wake_widths.resize(MAX_DIRECTIONAL_WAKE_SAMPLES)
	_directional_wake_biases.resize(MAX_DIRECTIONAL_WAKE_SAMPLES)
	_directional_wake_positions.fill(Vector2.ZERO)
	_directional_wake_directions.fill(Vector2(0.0, -1.0))
	_directional_wake_start_times.fill(-INF)
	_directional_wake_intensities.fill(0.0)
	_directional_wake_widths.fill(0.0)
	_directional_wake_biases.fill(0.0)
	_effective_directional_wake_sample_count = clampi(
		directional_wake_sample_count,
		8,
		MAX_DIRECTIONAL_WAKE_SAMPLES
	)


func _find_ripple_slot() -> int:
	var oldest_slot := 0
	var oldest_time := INF
	for index in MAX_RIPPLES:
		if _ripple_active[index] == 0:
			return index
		if _ripple_start_times[index] < oldest_time:
			oldest_time = _ripple_start_times[index]
			oldest_slot = index
	return oldest_slot


func _expire_ripples() -> bool:
	var changed := false
	for index in MAX_RIPPLES:
		if (
			_ripple_active[index] != 0
			and _simulation_time - _ripple_start_times[index] > _ripple_lifetimes[index]
		):
			_ripple_active[index] = 0
			changed = true
	return changed


func _update_vehicle_interactions(delta: float) -> void:
	var safe_delta := maxf(delta, 0.0001)
	_directional_wake_updated_last_tick = false
	if is_instance_valid(_wake_source):
		_wake_source.directional_history_lifetime = maxf(
			_wake_source.wake_lifetime,
			directional_wake_duration
		)
		_directional_wake_active_count = (
			_wake_source.fill_directional_shader_samples(
				_directional_wake_positions,
				_directional_wake_directions,
				_directional_wake_start_times,
				_directional_wake_intensities,
				_directional_wake_widths,
				_directional_wake_biases,
				_effective_directional_wake_sample_count,
				directional_wake_maximum_distance,
				directional_wake_duration,
				_logical_origin_xz,
				_simulation_time
			)
			if directional_wake_enabled
			else 0
		)
		_directional_wake_updated_last_tick = (
			directional_wake_enabled
			and _directional_wake_active_count > 0
		)
	else:
		_directional_wake_active_count = 0
	_update_hull_pressure_state(safe_delta)
	_update_interaction_metrics()


func _update_hull_pressure_state(delta: float) -> void:
	var vehicle_valid := (
		hull_pressure_enabled
		and is_instance_valid(_interaction_vehicle)
	)
	var contact_target: float = 0.0
	var intensity_target: float = 0.0
	var left_target: float = 0.0
	var right_target: float = 0.0
	var turn_bias_target: float = 0.0
	if vehicle_valid:
		var vehicle_basis := (
			_interaction_vehicle.global_transform.basis.orthonormalized()
		)
		var forward_3d := -vehicle_basis.z
		var forward_xz := Vector2(forward_3d.x, forward_3d.z)
		if forward_xz.length_squared() > 0.000001 and forward_xz.is_finite():
			_hull_pressure_forward = forward_xz.normalized()
		var hull_center := _interaction_vehicle.global_position
		var all_hull_markers_valid := (
			is_instance_valid(_interaction_front_left)
			and is_instance_valid(_interaction_front_right)
			and is_instance_valid(_interaction_rear_left)
			and is_instance_valid(_interaction_rear_right)
		)
		if all_hull_markers_valid:
			var front_center := (
				_interaction_front_left.global_position
				+ _interaction_front_right.global_position
			) * 0.5
			var rear_center := (
				_interaction_rear_left.global_position
				+ _interaction_rear_right.global_position
			) * 0.5
			hull_center = (front_center + rear_center) * 0.5
			var front_width := _horizontal_distance(
				_interaction_front_left.global_position,
				_interaction_front_right.global_position
			)
			var rear_width := _horizontal_distance(
				_interaction_rear_left.global_position,
				_interaction_rear_right.global_position
			)
			_hull_pressure_half_extents.x = maxf(
				(front_width + rear_width) * 0.25,
				0.25
			)
			_hull_pressure_half_extents.y = maxf(
				_horizontal_distance(front_center, rear_center) * 0.5,
				0.5
			)
		_hull_pressure_center = world_to_logical_xz(hull_center)

		var water_state := _interaction_vehicle.water_physics_system.state
		var navigation_airborne := (
			_interaction_vehicle.navigation_state
			== JetSkiController.NavigationState.AIRBORNE
		)
		var deep_submersion_fade := 1.0 - smoothstep(
			0.45,
			1.45,
			maxf(_interaction_vehicle.average_depth, 0.0)
		)
		if _interaction_vehicle.submarine_dive_active:
			deep_submersion_fade *= 0.08
		contact_target = (
			clampf(_interaction_vehicle.submerged_ratio, 0.0, 1.0)
			* deep_submersion_fade
			if not navigation_airborne
			else 0.0
		)
		var relative_velocity := (
			_interaction_vehicle.linear_velocity
			- water_state.average_water_velocity
		)
		var horizontal_velocity := Vector2(
			relative_velocity.x,
			relative_velocity.z
		)
		var horizontal_speed := horizontal_velocity.length()
		var speed_factor := clampf(
			inverse_lerp(0.75, 22.0, horizontal_speed),
			0.0,
			1.0
		)
		var acceleration_factor: float = 0.0
		if _has_last_interaction_velocity:
			acceleration_factor = clampf(
				(horizontal_velocity - _last_interaction_horizontal_velocity).length()
					/ delta / 18.0,
				0.0,
				1.0
			)
		_last_interaction_horizontal_velocity = horizontal_velocity
		_has_last_interaction_velocity = true
		var vertical_factor := clampf(absf(relative_velocity.y) / 8.0, 0.0, 1.0)
		_hull_pressure_pitch = clampf(forward_3d.y * 1.4, -0.6, 0.6)
		intensity_target = clampf(
			0.07
				+ speed_factor * 0.78
				+ vertical_factor * 0.10
				+ acceleration_factor * 0.12
				+ clampf(
					absf(_interaction_vehicle.water_relative_lateral_speed) / 18.0,
					0.0,
					1.0
				) * 0.12,
			0.0,
			1.2
		)
		var movement_direction := (
			horizontal_velocity.normalized()
			if horizontal_velocity.length_squared() > 0.0001
			else _hull_pressure_forward
		)
		var right_xz := Vector2(
			-_hull_pressure_forward.y,
			_hull_pressure_forward.x
		)
		var trajectory_misalignment := clampf(
			movement_direction.dot(right_xz),
			-1.0,
			1.0
		)
		var lateral_ratio := clampf(
			_interaction_vehicle.water_relative_lateral_speed
				/ maxf(absf(_interaction_vehicle.water_relative_forward_speed), 2.0),
			-1.0,
			1.0
		)
		var contact_mask := _interaction_vehicle.current_contact_mask
		var left_contact := _contact_side_ratio(contact_mask, 1, 4)
		var right_contact := _contact_side_ratio(contact_mask, 2, 8)
		turn_bias_target = clampf(
			lateral_ratio * 0.42
				+ trajectory_misalignment * 0.28
				+ _interaction_vehicle.steering_input * 0.22
				+ (right_contact - left_contact) * 0.18,
			-0.55,
			0.55
		)
		left_target = clampf(
			maxf(left_contact, contact_target * 0.55)
				* (1.0 + turn_bias_target * directional_wake_turn_strength),
			0.0,
			1.45
		)
		right_target = clampf(
			maxf(right_contact, contact_target * 0.55)
				* (1.0 - turn_bias_target * directional_wake_turn_strength),
			0.0,
			1.45
		)
	else:
		_has_last_interaction_velocity = false
	var contact_response := 11.0 if contact_target > _hull_pressure_contact else 3.6
	var intensity_response := 8.0 if intensity_target > _hull_pressure_intensity else 3.2
	_hull_pressure_contact = _smooth_value(
		_hull_pressure_contact,
		contact_target,
		contact_response,
		delta
	)
	_hull_pressure_intensity = _smooth_value(
		_hull_pressure_intensity,
		intensity_target,
		intensity_response,
		delta
	)
	_hull_pressure_left_strength = _smooth_value(
		_hull_pressure_left_strength,
		left_target,
		6.0,
		delta
	)
	_hull_pressure_right_strength = _smooth_value(
		_hull_pressure_right_strength,
		right_target,
		6.0,
		delta
	)
	_hull_pressure_turn_bias = _smooth_value(
		_hull_pressure_turn_bias,
		turn_bias_target,
		5.0,
		delta
	)


func _update_interaction_metrics() -> void:
	var maximum_wake_intensity: float = 0.0
	var maximum_wake_bias: float = 0.0
	for index in _directional_wake_active_count:
		maximum_wake_intensity = maxf(
			maximum_wake_intensity,
			_directional_wake_intensities[index]
		)
		maximum_wake_bias = maxf(
			maximum_wake_bias,
			absf(_directional_wake_biases[index])
		)
	var requested_wake := directional_wake_amplitude * maximum_wake_intensity * (
		1.0 + maximum_wake_bias * directional_wake_turn_strength
	)
	var requested_hull := hull_pressure_amplitude * _hull_pressure_intensity * (
		1.0 + hull_pressure_depression_strength
	) * _hull_pressure_contact
	_maximum_requested_interaction_amplitude = maxf(
		requested_wake,
		requested_hull
	)


func _horizontal_distance(first: Vector3, second: Vector3) -> float:
	return Vector2(first.x - second.x, first.z - second.z).length()


func _contact_side_ratio(contact_mask: int, first_bit: int, second_bit: int) -> float:
	return float(
		int((contact_mask & first_bit) != 0)
		+ int((contact_mask & second_bit) != 0)
	) * 0.5


func _smooth_value(
	current: float,
	target: float,
	response: float,
	delta: float
) -> float:
	return lerpf(
		current,
		target,
		1.0 - exp(-maxf(response, 0.0) * maxf(delta, 0.0))
	)


func _on_water_impact(intensity: float, impact_position: Vector3) -> void:
	if not impact_position.is_finite():
		return
	var logical_xz := world_to_logical_xz(impact_position)
	if (
		_simulation_time - _last_impact_time <= impact_merge_cooldown
		and logical_xz.distance_to(_last_impact_logical_xz) <= 2.5
	):
		_merged_impact_count += 1
		return
	_last_impact_time = _simulation_time
	_last_impact_logical_xz = logical_xz
	var safe_intensity := clampf(intensity, 0.0, 2.0)
	var normalized_intensity := clampf(safe_intensity, 0.0, 1.0)
	var main_amplitude := lerpf(0.12, 0.34, normalized_intensity)
	add_ripple(
		impact_position,
		main_amplitude,
		ripple_speed * lerpf(1.0, 1.45, normalized_intensity),
		ripple_wavelength * lerpf(1.25, 1.8, normalized_intensity),
		ripple_decay * 0.68,
		ripple_lifetime * 1.25
	)
	if normalized_intensity >= 0.62:
		_add_secondary_impact_ripples(
			main_amplitude * lerpf(0.30, 0.46, normalized_intensity),
			normalized_intensity
		)


func _add_secondary_impact_ripples(amplitude: float, intensity: float) -> void:
	var left_position := Vector3.ZERO
	var right_position := Vector3.ZERO
	var has_markers := (
		is_instance_valid(_interaction_front_left)
		and is_instance_valid(_interaction_front_right)
		and is_instance_valid(_interaction_rear_left)
		and is_instance_valid(_interaction_rear_right)
	)
	if has_markers:
		left_position = (
			_interaction_front_left.global_position
			+ _interaction_rear_left.global_position
		) * 0.5
		right_position = (
			_interaction_front_right.global_position
			+ _interaction_rear_right.global_position
		) * 0.5
	elif is_instance_valid(ripple_emitter_target):
		var lateral_offset := maxf(wake_lateral_offset, 0.55)
		var right_axis := ripple_emitter_target.global_basis.x.normalized()
		left_position = ripple_emitter_target.global_position - right_axis * lateral_offset
		right_position = ripple_emitter_target.global_position + right_axis * lateral_offset
	else:
		return
	var secondary_speed := ripple_speed * lerpf(0.92, 1.18, intensity)
	var secondary_wavelength := ripple_wavelength * lerpf(1.05, 1.34, intensity)
	var secondary_lifetime := ripple_lifetime * lerpf(0.82, 1.08, intensity)
	add_ripple(
		left_position,
		amplitude,
		secondary_speed,
		secondary_wavelength,
		ripple_decay * 0.78,
		secondary_lifetime
	)
	add_ripple(
		right_position,
		amplitude,
		secondary_speed,
		secondary_wavelength,
		ripple_decay * 0.78,
		secondary_lifetime
	)


func _on_submarine_dive_started() -> void:
	if not is_instance_valid(ripple_emitter_target):
		return
	var body := ripple_emitter_target as RigidBody3D
	var speed_factor: float = 0.5
	if body != null:
		speed_factor = clampf(
			Vector2(body.linear_velocity.x, body.linear_velocity.z).length() / 22.0,
			0.0,
			1.0
		)
	_on_water_impact(
		lerpf(0.45, 0.9, speed_factor),
		ripple_emitter_target.global_position
	)


func _on_submarine_dive_ended(duration: float, maximum_depth: float) -> void:
	if not is_instance_valid(ripple_emitter_target):
		return
	var exit_position := ripple_emitter_target.global_position
	var surface_height := sample_height(exit_position)
	if absf(exit_position.y - surface_height) > 2.4:
		return
	_on_water_impact(
		clampf(maximum_depth / 1.6 + duration * 0.12, 0.35, 1.0),
		exit_position
	)


func _connect_ripple_emitter_signals() -> void:
	if not is_instance_valid(ripple_emitter_target):
		return
	var impact_callable := Callable(self, "_on_water_impact")
	for signal_name: StringName in [&"water_entered", &"hard_landing"]:
		if (
			ripple_emitter_target.has_signal(signal_name)
			and not ripple_emitter_target.is_connected(signal_name, impact_callable)
		):
			ripple_emitter_target.connect(signal_name, impact_callable)
	var dive_started_callable := Callable(self, "_on_submarine_dive_started")
	if (
		ripple_emitter_target.has_signal(&"submarine_dive_started")
		and not ripple_emitter_target.is_connected(
			&"submarine_dive_started",
			dive_started_callable
		)
	):
		ripple_emitter_target.connect(
			&"submarine_dive_started",
			dive_started_callable
		)
	var dive_ended_callable := Callable(self, "_on_submarine_dive_ended")
	if (
		ripple_emitter_target.has_signal(&"submarine_dive_ended")
		and not ripple_emitter_target.is_connected(
			&"submarine_dive_ended",
			dive_ended_callable
		)
	):
		ripple_emitter_target.connect(
			&"submarine_dive_ended",
			dive_ended_callable
		)


func _disconnect_ripple_emitter_signals() -> void:
	if not is_instance_valid(ripple_emitter_target):
		return
	var impact_callable := Callable(self, "_on_water_impact")
	for signal_name: StringName in [&"water_entered", &"hard_landing"]:
		if (
			ripple_emitter_target.has_signal(signal_name)
			and ripple_emitter_target.is_connected(signal_name, impact_callable)
		):
			ripple_emitter_target.disconnect(signal_name, impact_callable)
	var dive_started_callable := Callable(self, "_on_submarine_dive_started")
	if (
		ripple_emitter_target.has_signal(&"submarine_dive_started")
		and ripple_emitter_target.is_connected(
			&"submarine_dive_started",
			dive_started_callable
		)
	):
		ripple_emitter_target.disconnect(
			&"submarine_dive_started",
			dive_started_callable
		)
	var dive_ended_callable := Callable(self, "_on_submarine_dive_ended")
	if (
		ripple_emitter_target.has_signal(&"submarine_dive_ended")
		and ripple_emitter_target.is_connected(
			&"submarine_dive_ended",
			dive_ended_callable
		)
	):
		ripple_emitter_target.disconnect(
			&"submarine_dive_ended",
			dive_ended_callable
		)


func _build_runtime_height_maps_when_ready() -> void:
	if _build_runtime_height_maps():
		_static_parameters_dirty = true
		_push_all_shader_parameters()
		return
	for _attempt in 60:
		await get_tree().process_frame
		if _build_runtime_height_maps():
			_static_parameters_dirty = true
			_push_all_shader_parameters()
			return
	push_warning(
        "Ocean3D could not build synchronized height maps; physical sampling will remain flat."
	)


func _build_runtime_height_maps() -> bool:
	var image_a := _get_cpu_readable_image(wave_height_texture_a)
	var image_b := _get_cpu_readable_image(wave_height_texture_b)

	if image_a == null or image_b == null:
		return false

	if (
		image_a == null
		or image_a.is_empty()
		or not _image_has_variation(image_a)
		or image_b == null
		or image_b.is_empty()
		or not _image_has_variation(image_b)
	):
		return false
	_wave_image_a = image_a
	_wave_image_b = image_b

	_runtime_wave_texture_a = _resolve_runtime_wave_texture(
		wave_height_texture_a,
		_wave_image_a
	)
	_runtime_wave_texture_b = _resolve_runtime_wave_texture(
		wave_height_texture_b,
		_wave_image_b
	)

	return (
		_runtime_wave_texture_a != null
		and _runtime_wave_texture_b != null
	)


func _get_cpu_readable_image(texture: Texture2D) -> Image:
	if texture == null:
		return null

	var image := texture.get_image()
	if image == null or image.is_empty():
		return null

	if image.is_compressed():
		var decompress_error := image.decompress()

		if decompress_error != OK:
			push_warning(
				"Ocean3D could not decompress a wave height image "
				+ "for CPU sampling. Error: %s"
				% error_string(decompress_error)
			)
			return null

	return image


func _resolve_runtime_wave_texture(
	source_texture: Texture2D,
	generated_image: Image
) -> Texture2D:
	if source_texture == null:
		return null

	# Las texturas importadas, como PNG o JPG, ya son el recurso
	# que debe utilizar el shader. No hay que duplicarlas.
	if source_texture is not NoiseTexture2D:
		return source_texture

	# Una NoiseTexture2D sí necesita convertirse a una imagen concreta
	# para que la física CPU y el shader GPU usen exactamente los mismos datos.
	if generated_image == null or generated_image.is_empty():
		return source_texture

	return ImageTexture.create_from_image(generated_image)


func _generate_height_image(source: Texture2D) -> Image:
	if source == null:
		return null
	if source is not NoiseTexture2D:
		return source.get_image()
	var noise_texture := source as NoiseTexture2D
	if noise_texture.noise == null:
		return null
	var runtime_noise := noise_texture.noise.duplicate(true) as Noise
	if runtime_noise == null:
		return null
	var width := maxi(noise_texture.width, 2)
	var height := maxi(noise_texture.height, 2)
	var image: Image
	if noise_texture.seamless:
		image = runtime_noise.get_seamless_image(
			width,
			height,
			noise_texture.invert,
			noise_texture.in_3d_space,
			noise_texture.seamless_blend_skirt,
			true
		)
	else:
		image = runtime_noise.get_image(
			width,
			height,
			noise_texture.invert,
			noise_texture.in_3d_space,
			true
		)
	if image == null or image.is_empty():
		return null
	if noise_texture.color_ramp != null:
		image.convert(Image.FORMAT_RGBA8)
		for pixel_y in height:
			for pixel_x in width:
				var noise_value := image.get_pixel(pixel_x, pixel_y).r
				image.set_pixel(pixel_x, pixel_y, noise_texture.color_ramp.sample(noise_value))
	return image


func _image_has_variation(image: Image) -> bool:
	if image == null or image.is_empty():
		return false
	var width := image.get_width()
	var height := image.get_height()
	if width < 2 or height < 2:
		return false
	var minimum_value := INF
	var maximum_value := -INF
	var value_sum: float = 0.0
	var squared_value_sum: float = 0.0
	const CHECK_GRID_SIZE: int = 16
	const CHECK_SAMPLE_COUNT: float = 256.0
	for y_index in CHECK_GRID_SIZE:
		for x_index in CHECK_GRID_SIZE:
			var pixel_x := mini(
				floori((float(x_index) + 0.37) / float(CHECK_GRID_SIZE) * float(width)),
				width - 1
			)
			var pixel_y := mini(
				floori((float(y_index) + 0.61) / float(CHECK_GRID_SIZE) * float(height)),
				height - 1
			)
			var value := image.get_pixel(pixel_x, pixel_y).r
			minimum_value = minf(minimum_value, value)
			maximum_value = maxf(maximum_value, value)
			value_sum += value
			squared_value_sum += value * value
	var mean := value_sum / CHECK_SAMPLE_COUNT
	var variance := squared_value_sum / CHECK_SAMPLE_COUNT - mean * mean
	return maximum_value - minimum_value > 0.05 and variance > 0.0004


func _sync_macro_waves_from_material(
	force: bool = false
) -> bool:
	if ocean_material == null or ocean_material.shader == null:
		return false

	var texture_a := ocean_material.get_shader_parameter(
		&"wave_height_texture_a"
	) as Texture2D

	var texture_b := ocean_material.get_shader_parameter(
		&"wave_height_texture_b"
	) as Texture2D

	var world_size_a := float(
		ocean_material.get_shader_parameter(
			&"wave_world_size_a"
		)
	)

	var world_size_b := float(
		ocean_material.get_shader_parameter(
			&"wave_world_size_b"
		)
	)

	var amplitude_a := float(
		ocean_material.get_shader_parameter(
			&"wave_amplitude_a"
		)
	)

	var amplitude_b := float(
		ocean_material.get_shader_parameter(
			&"wave_amplitude_b"
		)
	)

	var direction_a: Vector2 = (
		ocean_material.get_shader_parameter(
			&"wave_direction_a"
		)
	)

	var direction_b: Vector2 = (
		ocean_material.get_shader_parameter(
			&"wave_direction_b"
		)
	)

	var travel_speed_a := float(
		ocean_material.get_shader_parameter(
			&"wave_travel_speed_a"
		)
	)

	var travel_speed_b := float(
		ocean_material.get_shader_parameter(
			&"wave_travel_speed_b"
		)
	)

	var mean_a := float(
		ocean_material.get_shader_parameter(
			&"wave_mean_a"
		)
	)

	var mean_b := float(
		ocean_material.get_shader_parameter(
			&"wave_mean_b"
		)
	)

	var geometry_step := float(
		ocean_material.get_shader_parameter(
			&"geometry_normal_step"
		)
	)

	direction_a = _safe_direction(
		direction_a,
		Vector2.RIGHT
	)
	direction_b = _safe_direction(
		direction_b,
		Vector2.DOWN
	)

	var signature := hash([
		texture_a,
		texture_b,
		world_size_a,
		world_size_b,
		amplitude_a,
		amplitude_b,
		direction_a,
		direction_b,
		travel_speed_a,
		travel_speed_b,
		mean_a,
		mean_b,
		geometry_step,
	])

	if (
		not force
		and signature == _macro_material_signature
	):
		return false

	_macro_material_signature = signature

	if texture_a != wave_height_texture_a:
		wave_height_texture_a = texture_a

	if texture_b != wave_height_texture_b:
		wave_height_texture_b = texture_b

	wave_world_size_a = maxf(world_size_a, 0.001)
	wave_world_size_b = maxf(world_size_b, 0.001)
	wave_amplitude_a = maxf(amplitude_a, 0.0)
	wave_amplitude_b = maxf(amplitude_b, 0.0)
	wave_direction_a = direction_a
	wave_direction_b = direction_b
	wave_travel_speed_a = travel_speed_a
	wave_travel_speed_b = travel_speed_b
	wave_mean_a = clampf(mean_a, 0.0, 1.0)
	wave_mean_b = clampf(mean_b, 0.0, 1.0)
	normal_sample_step = maxf(
		geometry_step,
		MIN_SAMPLE_STEP
	)

	_static_parameters_dirty = true
	return true


func _push_all_shader_parameters() -> void:
	for material in _all_ocean_materials():
		_push_all_parameters_to_material(material)
	_static_parameters_dirty = false
	_ripple_parameters_dirty = false


func _push_all_parameters_to_material(material: ShaderMaterial) -> void:
	_push_static_parameters(material)
	_push_time_parameter(material)
	_push_origin_parameter(material)
	_push_ripple_parameters(material)
	_push_vehicle_interaction_parameters(material)


func _push_static_parameters_to_all_materials() -> void:
	for material in _all_ocean_materials():
		_push_static_parameters(material)
	_static_parameters_dirty = false


func _push_time_parameter_to_all_materials() -> void:
	for material in _all_ocean_materials():
		_push_time_parameter(material)


func _push_origin_parameter_to_all_materials() -> void:
	for material in _all_ocean_materials():
		_push_origin_parameter(material)


func _push_ripple_parameters_to_all_materials() -> void:
	for material in _all_ocean_materials():
		_push_ripple_parameters(material)
	_ripple_parameters_dirty = false


func _push_vehicle_interaction_parameters_to_all_materials() -> void:
	for material in _all_ocean_materials():
		_push_vehicle_interaction_parameters(material)
	_interaction_uniform_update_count += 1


func _push_static_parameters(material: ShaderMaterial) -> void:
	if material == null or material.shader == null:
		return
	material.set_shader_parameter(&"ocean_enabled", true)
	material.set_shader_parameter(&"water_level", water_level)
	var shader_wave_texture_a: Texture2D = wave_height_texture_a
	var shader_wave_texture_b: Texture2D = wave_height_texture_b

	if not Engine.is_editor_hint():
		if _runtime_wave_texture_a != null:
			shader_wave_texture_a = _runtime_wave_texture_a
		if _runtime_wave_texture_b != null:
			shader_wave_texture_b = _runtime_wave_texture_b

	material.set_shader_parameter(
		&"wave_height_texture_a",
		shader_wave_texture_a
	)
	material.set_shader_parameter(
		&"wave_height_texture_b",
		shader_wave_texture_b
	)
	material.set_shader_parameter(&"wave_world_size_a", wave_world_size_a)
	material.set_shader_parameter(&"wave_world_size_b", wave_world_size_b)
	material.set_shader_parameter(&"wave_amplitude_a", wave_amplitude_a)
	material.set_shader_parameter(&"wave_amplitude_b", wave_amplitude_b)
	material.set_shader_parameter(&"wave_direction_a", _safe_direction(wave_direction_a, Vector2.RIGHT))
	material.set_shader_parameter(&"wave_direction_b", _safe_direction(wave_direction_b, Vector2.DOWN))
	material.set_shader_parameter(&"wave_travel_speed_a", wave_travel_speed_a)
	material.set_shader_parameter(&"wave_travel_speed_b", wave_travel_speed_b)
	material.set_shader_parameter(&"wave_mean_a", wave_mean_a)
	material.set_shader_parameter(&"wave_mean_b", wave_mean_b)
	material.set_shader_parameter(&"geometry_normal_step", normal_sample_step)
	material.set_shader_parameter(&"directional_wake_enabled", directional_wake_enabled)
	material.set_shader_parameter(&"directional_wake_amplitude", directional_wake_amplitude)
	material.set_shader_parameter(&"directional_wake_wavelength", directional_wake_wavelength)
	material.set_shader_parameter(
		&"directional_wake_propagation_speed",
		directional_wake_propagation_speed
	)
	material.set_shader_parameter(
		&"directional_wake_opening_slope",
		directional_wake_opening_slope
	)
	material.set_shader_parameter(&"directional_wake_arm_width", directional_wake_arm_width)
	material.set_shader_parameter(
		&"directional_wake_center_depression",
		directional_wake_center_depression
	)
	material.set_shader_parameter(
		&"directional_wake_maximum_distance",
		directional_wake_maximum_distance
	)
	material.set_shader_parameter(&"directional_wake_duration", directional_wake_duration)
	material.set_shader_parameter(
		&"directional_wake_attenuation",
		directional_wake_attenuation
	)
	material.set_shader_parameter(
		&"directional_wake_turn_strength",
		directional_wake_turn_strength
	)
	material.set_shader_parameter(&"hull_pressure_enabled", hull_pressure_enabled)
	material.set_shader_parameter(&"hull_pressure_amplitude", hull_pressure_amplitude)
	material.set_shader_parameter(
		&"hull_pressure_depression_strength",
		hull_pressure_depression_strength
	)
	material.set_shader_parameter(
		&"hull_pressure_maximum_distance",
		hull_pressure_maximum_distance
	)
	material.set_shader_parameter(
		&"vehicle_interaction_maximum_displacement",
		vehicle_interaction_maximum_displacement
	)
	material.set_shader_parameter(
		&"vehicle_interaction_clipmap_distance",
		vehicle_interaction_clipmap_distance
	)
	material.set_shader_parameter(
		&"ocean_interaction_debug_mode",
		ocean_interaction_debug_mode
	)
	if foam_noise_texture != null:
		material.set_shader_parameter(&"foam_noise_texture", foam_noise_texture)


func _push_time_parameter(material: ShaderMaterial) -> void:
	if material != null and material.shader != null:
		material.set_shader_parameter(&"simulation_time", _simulation_time)


func _push_origin_parameter(material: ShaderMaterial) -> void:
	if material != null and material.shader != null:
		material.set_shader_parameter(&"ocean_logical_origin_offset_xz", _logical_origin_xz)


func _push_ripple_parameters(material: ShaderMaterial) -> void:
	if material == null or material.shader == null:
		return
	material.set_shader_parameter(&"ripple_active", _ripple_active)
	material.set_shader_parameter(&"ripple_positions", _ripple_positions)
	material.set_shader_parameter(&"ripple_start_times", _ripple_start_times)
	material.set_shader_parameter(&"ripple_amplitudes", _ripple_amplitudes)
	material.set_shader_parameter(&"ripple_speeds", _ripple_speeds)
	material.set_shader_parameter(&"ripple_wavelengths", _ripple_wavelengths)
	material.set_shader_parameter(&"ripple_decays", _ripple_decays)
	material.set_shader_parameter(&"ripple_lifetimes", _ripple_lifetimes)


func _push_vehicle_interaction_parameters(material: ShaderMaterial) -> void:
	if material == null or material.shader == null:
		return
	material.set_shader_parameter(
		&"directional_wake_active_count",
		_directional_wake_active_count
	)
	material.set_shader_parameter(
		&"directional_wake_positions",
		_directional_wake_positions
	)
	material.set_shader_parameter(
		&"directional_wake_directions",
		_directional_wake_directions
	)
	material.set_shader_parameter(
		&"directional_wake_start_times",
		_directional_wake_start_times
	)
	material.set_shader_parameter(
		&"directional_wake_intensities",
		_directional_wake_intensities
	)
	material.set_shader_parameter(
		&"directional_wake_widths",
		_directional_wake_widths
	)
	material.set_shader_parameter(
		&"directional_wake_biases",
		_directional_wake_biases
	)
	material.set_shader_parameter(&"hull_pressure_center", _hull_pressure_center)
	material.set_shader_parameter(&"hull_pressure_forward", _hull_pressure_forward)
	material.set_shader_parameter(
		&"hull_pressure_half_extents",
		_hull_pressure_half_extents
	)
	material.set_shader_parameter(&"hull_pressure_contact", _hull_pressure_contact)
	material.set_shader_parameter(&"hull_pressure_intensity", _hull_pressure_intensity)
	material.set_shader_parameter(
		&"hull_pressure_left_strength",
		_hull_pressure_left_strength
	)
	material.set_shader_parameter(
		&"hull_pressure_right_strength",
		_hull_pressure_right_strength
	)
	material.set_shader_parameter(
		&"hull_pressure_turn_bias",
		_hull_pressure_turn_bias
	)
	material.set_shader_parameter(&"hull_pressure_pitch", _hull_pressure_pitch)
	_interaction_uniform_write_count += 15


func _all_ocean_materials() -> Array[ShaderMaterial]:
	return _material_cache


func _refresh_material_cache() -> void:
	_material_cache.clear()
	if ocean_material != null and ocean_material.shader != null:
		_material_cache.append(ocean_material)
	for material in _external_materials:
		if (
			material != null
			and material.shader != null
			and not _material_cache.has(material)
		):
			_material_cache.append(material)


func _safe_direction(direction: Vector2, fallback: Vector2) -> Vector2:
	if direction.length_squared() <= 0.000001 or not direction.is_finite():
		return fallback
	return direction.normalized()
