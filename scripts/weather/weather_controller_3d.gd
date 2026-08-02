class_name WeatherController3D
extends Node3D

signal storm_sequence_started
signal weather_intensity_changed(storm_intensity: float, rain_intensity: float)
signal full_storm_reached

@export_node_path("WorldEnvironment") var world_environment_path: NodePath
@export_node_path("DirectionalLight3D") var primary_light_path: NodePath
@export_node_path("DirectionalLight3D") var lightning_light_path: NodePath
@export_node_path("Camera3D") var camera_path: NodePath
@export_node_path("Ocean3D") var ocean_path: NodePath
@export_node_path("AudioStreamPlayer") var ocean_wind_player_path: NodePath

@export_group("Weather Timing")
@export_range(1.0, 60.0, 0.5) var cloud_build_duration: float = 16.0
@export_range(1.0, 60.0, 0.5) var light_rain_duration: float = 9.0
@export_range(1.0, 60.0, 0.5) var heavy_rain_duration: float = 11.0
@export_group("Water")
@export var water_level: float = -1.02

@export_group("Water Rain Impacts")
@export_range(0.0, 1.0, 0.01) var rain_impact_density: float = 0.70
@export_range(0.1, 10.0, 0.1, "suffix:cycles/s") var rain_impact_rate: float = 4.2
@export_range(0.30, 2.0, 0.01, "suffix:m") var rain_impact_cell_size: float = 0.72
@export_range(0.03, 0.60, 0.01, "suffix:m") var rain_impact_radius: float = 0.18
@export_range(0.005, 0.15, 0.005, "suffix:m") var rain_impact_ring_width: float = 0.035
@export_range(0.0, 1.0, 0.01) var rain_impact_normal_strength: float = 0.22
@export_range(0.0, 1.0, 0.01) var rain_impact_foam_strength: float = 0.24
@export_range(0.05, 0.60, 0.005, "suffix:s") var rain_impact_lifetime: float = 0.22
@export_range(0.0, 1.0, 0.01) var rain_impact_lifetime_randomness: float = 0.35
@export_range(0.0, 1.0, 0.01) var rain_impact_size_randomness: float = 0.30
@export_range(0.0, 1.0, 0.01) var rain_impact_center_flash_strength: float = 0.42
@export_range(0.0, 1.0, 0.01) var rain_impact_crown_strength: float = 0.28

@export_group("Sea Mist Volume")
@export var sea_mist_enabled: bool = true
@export_range(0.0, 0.5, 0.005) var sea_mist_density: float = 0.10
@export_range(0.0, 0.95, 0.01) var sea_mist_start_rain_intensity: float = 0.30
@export var sea_mist_color: Color = Color(0.56, 0.64, 0.70, 1.0)
@export_range(0.0, 2.0, 0.01, "suffix:m") var sea_mist_height: float = 0.75
@export_range(0.0, 1.5, 0.01, "suffix:m") var sea_mist_height_noise_strength: float = 0.25
@export_range(0.1, 4.0, 0.01) var sea_mist_height_falloff: float = 1.60
@export_range(0.1, 20.0, 0.1) var sea_mist_noise_scale: float = 6.0
@export_range(0.1, 40.0, 0.1) var sea_mist_detail_scale: float = 16.0
@export_range(0.0, 4.0, 0.05, "suffix:m/s") var sea_mist_wind_speed: float = 0.25
@export_range(0.0, 3.0, 0.01, "suffix:m") var sea_mist_height_offset: float = 0.0
@export_range(0.0, 1.0, 0.01) var sea_mist_far_density_multiplier: float = 0.18
@export_range(0.0, 1.0, 0.01) var sea_mist_underwater_fade: float = 0.0
@export_range(32.0, 512.0, 1.0, "suffix:m") var sea_mist_volumetric_fog_length: float = 180.0
@export_group("Storm Environment")
@export_range(0.0, 1.0, 0.01) var storm_sun_energy_multiplier: float = 0.45
@export_range(0.0, 1.0, 0.01) var storm_ambient_energy_multiplier: float = 0.60
@export_range(0.0, 1.0, 0.01) var storm_sky_energy_multiplier: float = 0.55
@export_range(0.0, 2.0, 0.01) var storm_fog_density_multiplier: float = 1.35
@export_range(0.1, 1.0, 0.01) var storm_fog_end_multiplier: float = 0.55
@export_range(0.0, 1.0, 0.01) var storm_saturation: float = 0.68
@export var storm_light_color: Color = Color(0.38, 0.48, 0.66, 1.0)
@export var storm_fog_color: Color = Color(0.18, 0.25, 0.34, 1.0)
@export_group("Wind")
@export var wind_direction: Vector2 = Vector2(0.92, 0.38)
@export_range(0.0, 20.0, 0.1) var maximum_rain_wind_speed: float = 7.0
@export_range(-60.0, 6.0, 0.5) var storm_wind_volume_db: float = -3.0
@export_group("Lightning")
@export_range(1.0, 60.0, 0.5) var lightning_interval_min: float = 7.0
@export_range(1.0, 60.0, 0.5) var lightning_interval_max: float = 15.0
@export_range(0.0, 16.0, 0.1) var lightning_energy: float = 5.0
@export_group("Debug")
@export var debug_start_storm_on_ready: bool = false

var storm_intensity: float = 0.0
var rain_intensity: float = 0.0
var sequence_running: bool = false
var full_storm_active: bool = false
var _sequence_elapsed: float = 0.0
var _world_environment: WorldEnvironment
var _primary_light: DirectionalLight3D
var _lightning_light: DirectionalLight3D
var _camera: Camera3D
var _ocean: Ocean3D
var _ocean_wind_player: AudioStreamPlayer
var _rain_follow_rig: Node3D
var _rain_near: GPUParticles3D
var _rain_far: GPUParticles3D
var _cloud_dome: MeshInstance3D

var _sea_mist_volume_rig: Node3D
var _sea_mist_volume_near: FogVolume
var _sea_mist_volume_far: FogVolume

var _sea_mist_volume_near_material: ShaderMaterial
var _sea_mist_volume_far_material: ShaderMaterial

var _sea_mist_world: FogVolume
var _sea_mist_world_material: ShaderMaterial
var _lightning_flash: ColorRect
var _original_primary_energy: float = 0.0
var _original_primary_color: Color
var _original_ambient_energy: float = 1.0
var _original_sky_energy: float = 1.0
var _original_fog_density: float = 0.0
var _original_fog_color: Color
var _original_fog_end: float = 1000.0
var _original_volumetric_fog_enabled: bool = false
var _original_volumetric_fog_density: float = 0.0
var _original_volumetric_fog_length: float = 64.0
var _original_saturation: float = 1.0
var _adjustment_enabled: bool = false
var _original_wind_volume_db: float = 0.0
var _original_lightning_visible: bool = false
var _original_lightning_energy: float = 0.0
var _far_rain_quality_enabled: bool = true
var _sea_mist_quality_enabled: bool = true
var _sea_mist_far_quality_enabled: bool = true
var _sea_mist_ratio: float = 0.0
var _rain_impact_quality: int = 2
var _rain_impact_distance: float = 55.0
var _lightning_quality_enabled: bool = true
var _camera_underwater: bool = false
var _lightning_elapsed: float = -1.0
var _lightning_wait: float = 0.0
var _rng := RandomNumberGenerator.new()


func _ready() -> void:
	_world_environment = get_node_or_null(world_environment_path) as WorldEnvironment
	_primary_light = get_node_or_null(primary_light_path) as DirectionalLight3D
	_lightning_light = get_node_or_null(lightning_light_path) as DirectionalLight3D
	_camera = get_node_or_null(camera_path) as Camera3D
	_ocean = get_node_or_null(ocean_path) as Ocean3D
	_ocean_wind_player = get_node_or_null(ocean_wind_player_path) as AudioStreamPlayer
	_rain_follow_rig = get_node_or_null("RainFollowRig") as Node3D
	_rain_near = get_node_or_null("RainFollowRig/RainNear") as GPUParticles3D
	_rain_far = get_node_or_null("RainFollowRig/RainFar") as GPUParticles3D
	_cloud_dome = get_node_or_null(
		"CloudDome"
	) as MeshInstance3D

	_sea_mist_volume_rig = get_node_or_null(
		"SeaMistVolumeRig"
	) as Node3D

	_sea_mist_volume_near = get_node_or_null(
		"SeaMistVolumeRig/SeaMistVolumeNear"
	) as FogVolume

	_sea_mist_volume_far = get_node_or_null(
		"SeaMistVolumeRig/SeaMistVolumeFar"
	) as FogVolume

	if _sea_mist_volume_near != null:
		_sea_mist_volume_near_material = (
			_sea_mist_volume_near.material
			as ShaderMaterial
		)

	if _sea_mist_volume_far != null:
		_sea_mist_volume_far_material = (
			_sea_mist_volume_far.material
			as ShaderMaterial
		)

	_sea_mist_world = get_node_or_null("SeaMistWorld") as FogVolume
	if _sea_mist_world != null:
		_sea_mist_world_material = _sea_mist_world.material as ShaderMaterial
	_lightning_flash = get_node_or_null("ScreenEffects/LightningFlash") as ColorRect
	_validate_reference(_world_environment, "WorldEnvironment")
	_validate_reference(_primary_light, "primary DirectionalLight3D")
	_validate_reference(_lightning_light, "lightning DirectionalLight3D")
	_validate_reference(_camera, "Camera3D")
	_validate_reference(_ocean, "Ocean3D")
	_validate_reference(_ocean_wind_player, "OceanWind AudioStreamPlayer")
	_capture_original_state()
	reset_weather_immediate()
	if GraphicsQualityManager.current_profile != null:
		set_graphics_quality(GraphicsQualityManager.current_quality, GraphicsQualityManager.current_profile)
	if debug_start_storm_on_ready:
		call_deferred("start_storm_sequence")


func _process(delta: float) -> void:
	_update_follow_rigs()
	if sequence_running:
		_sequence_elapsed += delta
		var cloud_end := cloud_build_duration
		var light_end := cloud_end + light_rain_duration
		var storm_end := light_end + heavy_rain_duration
		if _sequence_elapsed < cloud_end:
			set_weather_immediate(_smooth_progress(_sequence_elapsed / cloud_build_duration) * 0.68, 0.0)
		elif _sequence_elapsed < light_end:
			var phase := _smooth_progress((_sequence_elapsed - cloud_end) / light_rain_duration)
			set_weather_immediate(lerpf(0.68, 0.88, phase), lerpf(0.0, 0.35, phase))
		elif _sequence_elapsed < storm_end:
			var phase := _smooth_progress((_sequence_elapsed - light_end) / heavy_rain_duration)
			set_weather_immediate(lerpf(0.88, 1.0, phase), lerpf(0.35, 1.0, phase))
		else:
			set_weather_immediate(1.0, 1.0)
			sequence_running = false
			full_storm_active = true
			full_storm_reached.emit()
	_update_lightning(delta)


func start_storm_sequence() -> void:
	if sequence_running or full_storm_active:
		return
	sequence_running = true
	_sequence_elapsed = 0.0
	storm_sequence_started.emit()


func reset_weather_immediate() -> void:
	sequence_running = false
	full_storm_active = false
	_sequence_elapsed = 0.0
	set_weather_immediate(0.0, 0.0)
	_finish_lightning()


func set_weather_immediate(new_storm_intensity: float, new_rain_intensity: float) -> void:
	storm_intensity = clampf(new_storm_intensity, 0.0, 1.0)
	rain_intensity = clampf(new_rain_intensity, 0.0, 1.0)
	_apply_environment()
	_apply_particles()
	_apply_ocean()
	weather_intensity_changed.emit(storm_intensity, rain_intensity)


func set_graphics_quality(_quality_level: int, profile: GraphicsQualityProfile) -> void:
	if profile == null:
		return
	if _rain_near != null:
		_rain_near.amount = profile.weather_rain_near_amount
	if _rain_far != null:
		_rain_far.amount = profile.weather_rain_far_amount
	_far_rain_quality_enabled = profile.weather_far_rain_enabled
	_sea_mist_quality_enabled = profile.weather_sea_mist_volume_enabled
	_sea_mist_far_quality_enabled = profile.weather_sea_mist_far_volume_enabled
	_rain_impact_quality = profile.weather_rain_impact_quality
	_rain_impact_distance = profile.weather_rain_impact_distance
	_lightning_quality_enabled = profile.weather_lightning_enabled
	if _cloud_dome != null and _cloud_dome.material_override is ShaderMaterial:
		(_cloud_dome.material_override as ShaderMaterial).set_shader_parameter("quality_octaves", profile.weather_cloud_octaves)
	if not _lightning_quality_enabled:
		_finish_lightning()
	set_weather_immediate(storm_intensity, rain_intensity)


func get_graphics_quality_debug_status() -> Dictionary:
	return {
		"storm_intensity": storm_intensity,
		"rain_intensity": rain_intensity,
		"sequence_running": sequence_running,
		"full_storm_active": full_storm_active,
		"rain_near_amount": _rain_near.amount if _rain_near != null else 0,
		"rain_far_amount": _rain_far.amount if _rain_far != null else 0,
		"far_rain_enabled": _far_rain_quality_enabled,
		"sea_mist_ratio": _sea_mist_ratio,
		"sea_mist_near_enabled": _sea_mist_volume_near.visible if _sea_mist_volume_near != null else false,
		"sea_mist_far_enabled": _sea_mist_far_quality_enabled,
		"rain_impact_quality": _rain_impact_quality,
		"rain_impact_distance": _rain_impact_distance,
		"rain_impact_density": rain_impact_density,
		"lightning_enabled": _lightning_quality_enabled,
		"camera_underwater": _camera_underwater,
	}


func _capture_original_state() -> void:
	if _primary_light != null:
		_original_primary_energy = _primary_light.light_energy
		_original_primary_color = _primary_light.light_color
	if _world_environment != null and _world_environment.environment != null:
		var environment := _world_environment.environment
		_original_ambient_energy = environment.ambient_light_energy
		_original_sky_energy = environment.background_energy_multiplier
		_original_fog_density = environment.fog_density
		_original_fog_color = environment.fog_light_color
		_original_fog_end = environment.fog_depth_end
		_original_volumetric_fog_enabled = environment.volumetric_fog_enabled
		_original_volumetric_fog_density = environment.volumetric_fog_density
		_original_volumetric_fog_length = environment.volumetric_fog_length
		_adjustment_enabled = environment.adjustment_enabled
		_original_saturation = environment.adjustment_saturation
	if _ocean_wind_player != null:
		_original_wind_volume_db = _ocean_wind_player.volume_db
	if _lightning_light != null:
		_original_lightning_visible = _lightning_light.visible
		_original_lightning_energy = _lightning_light.light_energy
		_lightning_light.shadow_enabled = false
		_lightning_light.visible = false


func _apply_environment() -> void:
	if _primary_light != null:
		_primary_light.light_energy = lerpf(_original_primary_energy, _original_primary_energy * storm_sun_energy_multiplier, storm_intensity)
		_primary_light.light_color = _original_primary_color.lerp(storm_light_color, storm_intensity)
	if _world_environment != null and _world_environment.environment != null:
		var environment := _world_environment.environment
		environment.ambient_light_energy = lerpf(_original_ambient_energy, _original_ambient_energy * storm_ambient_energy_multiplier, storm_intensity)
		environment.background_energy_multiplier = lerpf(_original_sky_energy, _original_sky_energy * storm_sky_energy_multiplier, storm_intensity)
		environment.fog_density = lerpf(_original_fog_density, _original_fog_density * storm_fog_density_multiplier, storm_intensity)
		environment.fog_light_color = _original_fog_color.lerp(storm_fog_color, storm_intensity)
		environment.fog_depth_end = lerpf(_original_fog_end, maxf(280.0, _original_fog_end * storm_fog_end_multiplier), storm_intensity)
		if _adjustment_enabled:
			environment.adjustment_saturation = lerpf(_original_saturation, storm_saturation, storm_intensity)
	if _ocean_wind_player != null:
		_ocean_wind_player.volume_db = lerpf(_original_wind_volume_db, storm_wind_volume_db, storm_intensity)
	if _cloud_dome != null and _cloud_dome.material_override is ShaderMaterial:
		var material := _cloud_dome.material_override as ShaderMaterial
		material.set_shader_parameter("storm_intensity", storm_intensity)
		material.set_shader_parameter("wind_direction", wind_direction.normalized())
		material.set_shader_parameter("wind_speed", maximum_rain_wind_speed * 0.0017)


func _apply_particles() -> void:
	var visible_particles: bool = not _camera_underwater

	_apply_particle_state(
		_rain_near,
		rain_intensity,
		visible_particles
	)

	var far_ratio: float = smoothstep(
		0.05,
		0.55,
		rain_intensity
	)

	_apply_particle_state(
		_rain_far,
		far_ratio,
		visible_particles
			and _far_rain_quality_enabled
	)

	var mist_ratio: float = 0.0

	if (
		sea_mist_enabled
		and _sea_mist_quality_enabled
		and rain_intensity
			> sea_mist_start_rain_intensity
	):
		mist_ratio = smoothstep(
			sea_mist_start_rain_intensity,
			1.0,
			rain_intensity
		)

	_sea_mist_ratio = clampf(
		mist_ratio,
		0.0,
		1.0
	)

	_apply_sea_mist_materials(
		visible_particles
	)

func _apply_particle_state(particles: GPUParticles3D, amount_ratio: float, visible_particles: bool) -> void:
	if particles == null:
		return
	particles.amount_ratio = amount_ratio
	particles.visible = visible_particles
	particles.emitting = amount_ratio > 0.001 and visible_particles


func _apply_ocean() -> void:
	if _ocean == null or _ocean.ocean_material == null:
		return
	var ocean_material: ShaderMaterial = _ocean.ocean_material
	ocean_material.set_shader_parameter("weather_rain_intensity", rain_intensity)
	ocean_material.set_shader_parameter("weather_rain_impact_density", rain_impact_density)
	ocean_material.set_shader_parameter("weather_rain_impact_rate", rain_impact_rate)
	ocean_material.set_shader_parameter("weather_rain_impact_cell_size", rain_impact_cell_size)
	ocean_material.set_shader_parameter("weather_rain_impact_radius", rain_impact_radius)
	ocean_material.set_shader_parameter("weather_rain_impact_ring_width", rain_impact_ring_width)
	ocean_material.set_shader_parameter("weather_rain_impact_normal_strength", rain_impact_normal_strength)
	ocean_material.set_shader_parameter("weather_rain_impact_foam_strength", rain_impact_foam_strength)
	ocean_material.set_shader_parameter("weather_rain_impact_quality", _rain_impact_quality)
	ocean_material.set_shader_parameter("weather_rain_impact_distance", _rain_impact_distance)
	ocean_material.set_shader_parameter("weather_rain_impact_lifetime", rain_impact_lifetime)
	ocean_material.set_shader_parameter("weather_rain_impact_lifetime_randomness", rain_impact_lifetime_randomness)
	ocean_material.set_shader_parameter("weather_rain_impact_size_randomness", rain_impact_size_randomness)
	ocean_material.set_shader_parameter("weather_rain_impact_center_flash_strength", rain_impact_center_flash_strength)
	ocean_material.set_shader_parameter("weather_rain_impact_crown_strength", rain_impact_crown_strength)


func _update_follow_rigs() -> void:
	if _camera == null:
		return
	var camera_position: Vector3 = _camera.global_position
	_camera_underwater = camera_position.y < water_level + 0.05
	if _cloud_dome != null:
		_cloud_dome.global_position = Vector3(camera_position.x, water_level - 100.0, camera_position.z)
	if _rain_follow_rig != null:
		_rain_follow_rig.global_position = camera_position
	_apply_particles()


func _apply_sea_mist_materials(
	visible_particles: bool
) -> void:
	var mist_active: bool = (
		sea_mist_enabled
		and _sea_mist_quality_enabled
		and visible_particles
		and rain_intensity
			> sea_mist_start_rain_intensity
		and _sea_mist_ratio > 0.0001
	)

	var world_opacity: float = (
		_sea_mist_ratio
		if mist_active
		else 0.0
	)

	if (
		_world_environment != null
		and _world_environment.environment != null
	):
		var environment: Environment = (
			_world_environment.environment
		)

		if mist_active:
			environment.volumetric_fog_enabled = true

			# SeaMistWorld es la única contribución volumétrica.
			# No sumar densidad global.
			environment.volumetric_fog_density = 0.0

			environment.volumetric_fog_length = (
				sea_mist_volumetric_fog_length
			)
		else:
			environment.volumetric_fog_enabled = (
				_original_volumetric_fog_enabled
			)

			environment.volumetric_fog_density = (
				_original_volumetric_fog_density
			)

			environment.volumetric_fog_length = (
				_original_volumetric_fog_length
			)

	_apply_sea_mist_shader(
		_sea_mist_world_material,
		world_opacity
	)

	# Neutralizar completamente el sistema antiguo.
	if _sea_mist_volume_near_material != null:
		_sea_mist_volume_near_material.set_shader_parameter(
			"mist_opacity",
			0.0
		)

	if _sea_mist_volume_far_material != null:
		_sea_mist_volume_far_material.set_shader_parameter(
			"mist_opacity",
			0.0
		)

	if _sea_mist_volume_near != null:
		_sea_mist_volume_near.visible = false

	if _sea_mist_volume_far != null:
		_sea_mist_volume_far.visible = false

	if _sea_mist_world != null:
		_sea_mist_world.visible = mist_active


func _apply_sea_mist_shader(
	material: ShaderMaterial,
	opacity: float
) -> void:
	if material == null:
		return

	material.set_shader_parameter(
		"water_level",
		water_level
	)

	material.set_shader_parameter(
		"mist_density",
		sea_mist_density
	)

	material.set_shader_parameter(
		"mist_opacity",
		opacity
	)

	material.set_shader_parameter(
		"mist_color",
		sea_mist_color
	)

	material.set_shader_parameter(
		"mist_height",
		sea_mist_height
	)

	material.set_shader_parameter(
		"mist_height_noise_strength",
		sea_mist_height_noise_strength
	)

	material.set_shader_parameter(
		"mist_height_falloff",
		sea_mist_height_falloff
	)

	material.set_shader_parameter(
		"mist_noise_scale",
		sea_mist_noise_scale
	)

	material.set_shader_parameter(
		"mist_detail_scale",
		sea_mist_detail_scale
	)

	material.set_shader_parameter(
		"mist_wind_speed",
		sea_mist_wind_speed
	)

	var normalized_wind: Vector2 = (
		wind_direction.normalized()
	)

	if normalized_wind.length_squared() <= 0.0001:
		normalized_wind = Vector2(1.0, 0.0)

	material.set_shader_parameter(
		"mist_wind_direction",
		normalized_wind
	)


func _update_lightning(delta: float) -> void:
	if _lightning_elapsed >= 0.0:
		_lightning_elapsed += delta
		_apply_lightning_flash()
		return
	if storm_intensity < 0.65 or not _lightning_quality_enabled:
		return
	if _lightning_wait <= 0.0:
		_lightning_wait = _rng.randf_range(lightning_interval_min, lightning_interval_max)
		return
	_lightning_wait -= delta
	if _lightning_wait <= 0.0:
		_lightning_elapsed = 0.0
		_lightning_wait = _rng.randf_range(lightning_interval_min, lightning_interval_max)


func _apply_lightning_flash() -> void:
	if _lightning_elapsed >= 0.32:
		_finish_lightning()
		return
	var alpha: float
	var energy: float
	if _lightning_elapsed < 0.05:
		var t := _lightning_elapsed / 0.05
		alpha = lerpf(0.0, 0.72, t)
		energy = lerpf(0.0, lightning_energy, t)
	elif _lightning_elapsed < 0.12:
		var t := (_lightning_elapsed - 0.05) / 0.07
		alpha = lerpf(0.72, 0.08, t)
		energy = lerpf(lightning_energy, lightning_energy * 0.12, t)
	elif _lightning_elapsed < 0.17:
		var t := (_lightning_elapsed - 0.12) / 0.05
		alpha = lerpf(0.08, 0.43, t)
		energy = lerpf(lightning_energy * 0.12, lightning_energy * 0.58, t)
	else:
		var t := (_lightning_elapsed - 0.17) / 0.15
		alpha = lerpf(0.43, 0.0, t)
		energy = lerpf(lightning_energy * 0.58, 0.0, t)
	if _lightning_flash != null:
		_lightning_flash.visible = true
		_lightning_flash.color.a = alpha
	if _lightning_light != null:
		_lightning_light.visible = true
		_lightning_light.light_energy = energy


func _finish_lightning() -> void:
	_lightning_elapsed = -1.0
	if _lightning_flash != null:
		_lightning_flash.visible = false
		_lightning_flash.color.a = 0.0
	if _lightning_light != null:
		_lightning_light.visible = false
		_lightning_light.light_energy = _original_lightning_energy


func _smooth_progress(value: float) -> float:
	var t := clampf(value, 0.0, 1.0)
	return t * t * (3.0 - 2.0 * t)


func _validate_reference(reference: Node, label: String) -> void:
	if reference == null:
		push_error("WeatherController3D: missing %s reference." % label)
