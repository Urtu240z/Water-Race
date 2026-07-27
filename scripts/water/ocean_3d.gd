@tool
class_name Ocean3D
extends Node3D

## Single authority for the visible and physical ocean.
##
## Ocean3D owns simulation time, CPU surface sampling, dynamic ripples,
## wake impulses, shader synchronization, logical-world rebasing and the
## OceanSurface3D child. It intentionally does not inherit from the former generic water system.

const MAX_RIPPLES: int = 12
const MIN_SAMPLE_STEP: float = 0.05

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
		_static_parameters_dirty = true
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

@export_subgroup("Dynamic Ripples")
@export_range(0.25, 10.0, 0.05, "suffix:m") var wake_ripple_spacing: float = 2.8
@export_range(0.0, 20.0, 0.1, "suffix:m/s") var wake_minimum_speed: float = 2.0
@export_range(0.0, 1.0, 0.005, "suffix:m") var wake_ripple_amplitude: float = 0.075
@export_range(0.1, 12.0, 0.05, "suffix:m/s") var ripple_speed: float = 3.4
@export_range(0.25, 12.0, 0.05, "suffix:m") var ripple_wavelength: float = 2.6
@export_range(0.0, 4.0, 0.01) var ripple_decay: float = 0.72
@export_range(0.25, 12.0, 0.05, "suffix:s") var ripple_lifetime: float = 4.6
@export_range(0.0, 5.0, 0.05, "suffix:m") var ripple_contact_height: float = 2.4
@export_range(0.0, 4.0, 0.05, "suffix:m") var wake_rear_offset: float = 1.15
@export_range(0.0, 2.0, 0.05, "suffix:m") var wake_lateral_offset: float = 0.0

@export_group("Foam")
@export var wave_crest_color: Color = Color(0.090, 0.500, 0.610, 1.0)## Preserved because the current scene assigns these resources. The ocean
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

var _ripple_active := PackedInt32Array()
var _ripple_positions := PackedVector2Array()
var _ripple_start_times := PackedFloat32Array()
var _ripple_amplitudes := PackedFloat32Array()
var _ripple_speeds := PackedFloat32Array()
var _ripple_wavelengths := PackedFloat32Array()
var _ripple_decays := PackedFloat32Array()
var _ripple_lifetimes := PackedFloat32Array()

var _last_emitter_logical_xz := Vector2.ZERO
var _has_last_emitter_position: bool = false
var _static_parameters_dirty: bool = true
var _ripple_parameters_dirty: bool = true
var _editor_refresh_elapsed: float = 0.0


func _enter_tree() -> void:
	if Engine.is_editor_hint():
		call_deferred(&"_refresh_editor_preview")


func _ready() -> void:
	process_priority = -100
	process_physics_priority = -100
	_surface = get_node_or_null("Surface") as OceanSurface3D
	_initialize_ripples()
	_resolve_targets()
	_configure_surface()
	configure_ripple_emitter(ripple_emitter_target)
	set_process(Engine.is_editor_hint())
	set_physics_process(not Engine.is_editor_hint())
	_build_runtime_height_maps_when_ready()
	_push_all_shader_parameters()
	if Engine.is_editor_hint():
		update_configuration_warnings()


func _process(delta: float) -> void:
	if not Engine.is_editor_hint():
		return
	_editor_refresh_elapsed += maxf(delta, 0.0)
	if _editor_refresh_elapsed < 0.25:
		return
	_editor_refresh_elapsed = 0.0
	_resolve_targets()
	_configure_surface()
	_push_time_parameter_to_all_materials()
	if _static_parameters_dirty:
		_push_static_parameters_to_all_materials()
	if _ripple_parameters_dirty:
		_push_ripple_parameters_to_all_materials()


func _physics_process(delta: float) -> void:
	var safe_delta := maxf(delta, 0.0)
	_simulation_time += safe_delta
	if _expire_ripples():
		_ripple_parameters_dirty = true
	_update_automatic_wake(safe_delta)
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
	_static_parameters_dirty = true
	_ripple_parameters_dirty = true
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


func configure_ripple_emitter(target: Node3D) -> void:
	if ripple_emitter_target == target:
		_connect_ripple_emitter_signals()
		return
	_disconnect_ripple_emitter_signals()
	ripple_emitter_target = target
	_has_last_emitter_position = false
	_connect_ripple_emitter_signals()


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
	_has_last_emitter_position = false
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
	_push_all_parameters_to_material(material)


func unregister_external_water_material(material: ShaderMaterial) -> void:
	_external_materials.erase(material)


func apply_world_rebase(
	_shift: Vector3,
	logical_origin_x: float,
	logical_origin_z: float
) -> void:
	if not is_finite(logical_origin_x) or not is_finite(logical_origin_z):
		return
	_logical_origin_xz = Vector2(logical_origin_x, logical_origin_z)
	_has_last_emitter_position = false
	_push_origin_parameter_to_all_materials()


func _refresh_editor_preview() -> void:
	if not Engine.is_editor_hint() or not is_node_ready():
		return
	_surface = get_node_or_null("Surface") as OceanSurface3D
	_resolve_targets()
	_configure_surface()
	rebuild_height_maps()
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


func _update_automatic_wake(delta: float) -> void:
	if not is_instance_valid(ripple_emitter_target) or delta <= 0.0:
		return
	var target_position := ripple_emitter_target.global_position
	var logical_xz := world_to_logical_xz(target_position)
	if not _has_last_emitter_position:
		_last_emitter_logical_xz = logical_xz
		_has_last_emitter_position = true
		return
	var travelled := logical_xz.distance_to(_last_emitter_logical_xz)
	var speed := travelled / delta
	var surface_height := sample_height(target_position)
	var close_to_surface := absf(target_position.y - surface_height) <= ripple_contact_height
	if not close_to_surface or speed < wake_minimum_speed or travelled < wake_ripple_spacing:
		if travelled > wake_ripple_spacing * 3.0:
			_last_emitter_logical_xz = logical_xz
		return
	var emitter_basis := ripple_emitter_target.global_transform.basis.orthonormalized()
	var backward := emitter_basis.z.normalized()
	var lateral := emitter_basis.x.normalized() * wake_lateral_offset
	var wake_position := target_position + backward * wake_rear_offset + lateral
	wake_position.y = surface_height
	var speed_factor := clampf(
		inverse_lerp(wake_minimum_speed, wake_minimum_speed + 18.0, speed),
		0.0,
		1.0
	)
	add_ripple(wake_position, wake_ripple_amplitude * lerpf(0.55, 1.25, speed_factor))
	_last_emitter_logical_xz = logical_xz


func _on_water_impact(intensity: float, impact_position: Vector3) -> void:
	var safe_intensity := clampf(intensity, 0.0, 2.0)
	add_ripple(
		impact_position,
		lerpf(0.12, 0.34, clampf(safe_intensity, 0.0, 1.0)),
		ripple_speed * lerpf(1.0, 1.45, clampf(safe_intensity, 0.0, 1.0)),
		ripple_wavelength * lerpf(1.25, 1.8, clampf(safe_intensity, 0.0, 1.0)),
		ripple_decay * 0.68,
		ripple_lifetime * 1.25
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
	var image_a := _generate_height_image(wave_height_texture_a)
	var image_b := _generate_height_image(wave_height_texture_b)
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
	_runtime_wave_texture_a = ImageTexture.create_from_image(_wave_image_a)
	_runtime_wave_texture_b = ImageTexture.create_from_image(_wave_image_b)
	return _runtime_wave_texture_a != null and _runtime_wave_texture_b != null


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


func _push_static_parameters(material: ShaderMaterial) -> void:
	if material == null or material.shader == null:
		return
	material.set_shader_parameter(&"ocean_enabled", true)
	material.set_shader_parameter(&"water_level", water_level)
	material.set_shader_parameter(
		&"wave_height_texture_a",
		_runtime_wave_texture_a if _runtime_wave_texture_a != null else wave_height_texture_a
	)
	material.set_shader_parameter(
		&"wave_height_texture_b",
		_runtime_wave_texture_b if _runtime_wave_texture_b != null else wave_height_texture_b
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


func _all_ocean_materials() -> Array[ShaderMaterial]:
	var materials: Array[ShaderMaterial] = []
	if ocean_material != null and ocean_material.shader != null:
		materials.append(ocean_material)
	for material in _external_materials:
		if material != null and material.shader != null and not materials.has(material):
			materials.append(material)
	return materials


func _safe_direction(direction: Vector2, fallback: Vector2) -> Vector2:
	if direction.length_squared() <= 0.000001 or not direction.is_finite():
		return fallback
	return direction.normalized()
