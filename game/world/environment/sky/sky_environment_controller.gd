@tool
class_name SkyEnvironmentController
extends Node


enum SkyEnvironmentPreset {
	ORIGINAL,
	ARISTEA_WRECK,
	KLOOFENDAL_48D,
	OVERCAST_SOIL,
	CUSTOM,
}


const BUILT_IN_SKY_PRESET_COUNT: int = 5

const DEFAULT_ORIGINAL_SKY_PATH: String = "res://world/environment/sky/sky_original.tres"
const DEFAULT_ARISTEA_WRECK_PATH: String = "res://world/environment/sky/hdris/aristea_wreck_puresky_4k.hdr"
const DEFAULT_KLOOFENDAL_48D_PATH: String = "res://world/environment/sky/hdris/kloofendal_48d_partly_cloudy_puresky_4k.hdr"
const DEFAULT_OVERCAST_SOIL_PATH: String = "res://world/environment/sky/hdris/qwantani_dusk_1_puresky_4k.hdr"
const DEFAULT_CUSTOM_SKY_PATH: String = "res://world/environment/sky/hdris/kloofendal_43d_clear_puresky_4k.hdr"


# ============================================================
# REFERENCES
# ============================================================

@export_group("References")

@export_node_path("WorldEnvironment")
var world_environment_path: NodePath = NodePath("../WorldEnvironment")


# ============================================================
# SKY PATHS
#
# Strings only. They do not preload the HDRIs.
# ============================================================

@export_group("Sky Paths")

@export_file var original_sky_path: String = DEFAULT_ORIGINAL_SKY_PATH:
	set(value):
		if original_sky_path == value:
			return
		original_sky_path = value
		_request_sky_update()


@export_file var aristea_wreck_path: String = DEFAULT_ARISTEA_WRECK_PATH:
	set(value):
		if aristea_wreck_path == value:
			return
		aristea_wreck_path = value
		_request_sky_update()


@export_file var kloofendal_48d_path: String = DEFAULT_KLOOFENDAL_48D_PATH:
	set(value):
		if kloofendal_48d_path == value:
			return
		kloofendal_48d_path = value
		_request_sky_update()


@export_file var overcast_soil_path: String = DEFAULT_OVERCAST_SOIL_PATH:
	set(value):
		if overcast_soil_path == value:
			return
		overcast_soil_path = value
		_request_sky_update()


@export_file var custom_sky_path: String = DEFAULT_CUSTOM_SKY_PATH:
	set(value):
		if custom_sky_path == value:
			return
		custom_sky_path = value
		_request_sky_update()


@export_file var additional_sky_paths: PackedStringArray = PackedStringArray():
	set(value):
		additional_sky_paths = value

		if sky_preset > _get_maximum_sky_preset_index():
			sky_preset = SkyEnvironmentPreset.CUSTOM

		notify_property_list_changed()
		_request_sky_update()


# ============================================================
# ENVIRONMENT SETTINGS
# ============================================================

@export_group("Sky Environment")

@export var sky_preset: int = SkyEnvironmentPreset.KLOOFENDAL_48D:
	set(value):
		var validated_value: int = clampi(
			value,
			0,
			_get_maximum_sky_preset_index()
		)

		if sky_preset == validated_value:
			return

		sky_preset = validated_value
		_request_sky_update()


@export var panorama_rotation_degrees: Vector3 = Vector3.ZERO:
	set(value):
		var validated_value: Vector3 = Vector3(
			clampf(value.x, -180.0, 180.0),
			clampf(value.y, -180.0, 180.0),
			clampf(value.z, -180.0, 180.0)
		)

		if panorama_rotation_degrees.is_equal_approx(validated_value):
			return

		panorama_rotation_degrees = validated_value

		if _syncing_panorama_rotation:
			return

		_syncing_panorama_rotation = true
		sky_rotation_degrees = validated_value.y
		_syncing_panorama_rotation = false

		_request_sky_update()


@export_storage var sky_rotation_degrees: float = 0.0:
	set(value):
		var validated_value: float = clampf(value, -180.0, 180.0)

		if is_equal_approx(sky_rotation_degrees, validated_value):
			return

		sky_rotation_degrees = validated_value

		if _syncing_panorama_rotation:
			return

		_syncing_panorama_rotation = true

		var rotation_value: Vector3 = panorama_rotation_degrees
		rotation_value.y = validated_value
		panorama_rotation_degrees = rotation_value

		_syncing_panorama_rotation = false

		_request_sky_update()


@export_range(0.05, 4.0, 0.05)
var sky_energy_multiplier: float = 1.0:
	set(value):
		var validated_value: float = clampf(value, 0.05, 4.0)

		if is_equal_approx(sky_energy_multiplier, validated_value):
			return

		sky_energy_multiplier = validated_value
		_request_sky_update()


@export_range(0.0, 1.0, 0.01)
var ambient_sky_contribution: float = 0.85:
	set(value):
		var validated_value: float = clampf(value, 0.0, 1.0)

		if is_equal_approx(ambient_sky_contribution, validated_value):
			return

		ambient_sky_contribution = validated_value
		_request_sky_update()


# ============================================================
# INTERNAL
# ============================================================

var _world_environment: WorldEnvironment = null
var _environment: Environment = null
var _fallback_sky: Sky = null

var _original_sky_energy: float = 1.0
var _original_ambient_sky_contribution: float = 0.8

var _syncing_panorama_rotation: bool = false

# Solo contiene skies que realmente se hayan utilizado.
var _sky_cache: Dictionary = {}


# ============================================================
# OBSERVATIONAL STATE
# ============================================================

var _effective_sky_energy_value: float = 1.0
var _effective_ambient_sky_contribution_value: float = 0.85
var _sky_texture_path_value: String = ""
var _sky_process_mode_name_value: StringName = &"N/A"
var _sky_radiance_size_value: int = 0
var _sky_change_count_value: int = 0
var _sky_reference_valid_value: bool = false


var sky_preset_name: StringName:
	get:
		return StringName(_get_sky_preset_display_name(sky_preset))


var sky_texture_path: String:
	get:
		return _sky_texture_path_value


var effective_sky_energy: float:
	get:
		return _effective_sky_energy_value


var effective_ambient_sky_contribution: float:
	get:
		return _effective_ambient_sky_contribution_value


var sky_process_mode_name: StringName:
	get:
		return _sky_process_mode_name_value


var sky_radiance_size: int:
	get:
		return _sky_radiance_size_value


var sky_change_count: int:
	get:
		return _sky_change_count_value


var sky_reference_valid: bool:
	get:
		return _sky_reference_valid_value


# ============================================================
# READY
# ============================================================

func _ready() -> void:
	_world_environment = get_node_or_null(
		world_environment_path
	) as WorldEnvironment

	if (
		_world_environment == null
		or _world_environment.environment == null
	):
		_sky_reference_valid_value = false

		push_error(
			"SkyEnvironmentController requires a "
			+ "WorldEnvironment with an Environment resource."
		)
		return

	_environment = _world_environment.environment
	_fallback_sky = _environment.sky

	_original_sky_energy = _environment.background_energy_multiplier
	_original_ambient_sky_contribution = (
		_environment.ambient_light_sky_contribution
	)

	_apply_active_preset()


func _request_sky_update() -> void:
	if (
		not is_inside_tree()
		or not is_node_ready()
		or _environment == null
	):
		return

	_apply_active_preset()


# ============================================================
# INSPECTOR
# ============================================================

func _validate_property(property: Dictionary) -> void:
	if property.name == &"sky_preset":
		property.hint = PROPERTY_HINT_ENUM
		property.hint_string = _get_sky_preset_hint_string()


# ============================================================
# APPLY PRESET
# ============================================================

func _apply_active_preset() -> void:
	if _environment == null:
		return

	var selected_energy: float = sky_energy_multiplier
	var selected_ambient: float = ambient_sky_contribution

	if sky_preset == SkyEnvironmentPreset.ORIGINAL:
		selected_energy = _original_sky_energy
		selected_ambient = _original_ambient_sky_contribution

	var selected_path: String = _get_sky_path(sky_preset)
	var selected_sky: Sky = _load_sky(selected_path, sky_preset)

	_sky_reference_valid_value = selected_sky != null

	if selected_sky == null:
		selected_sky = _fallback_sky

	if selected_sky == null:
		push_warning(
			"Could not resolve sky preset: "
			+ _get_sky_preset_display_name(sky_preset)
		)
		return

	_environment.background_mode = Environment.BG_SKY
	_environment.sky = selected_sky

	_environment.sky_rotation = Vector3(
		deg_to_rad(panorama_rotation_degrees.x),
		deg_to_rad(panorama_rotation_degrees.y),
		deg_to_rad(panorama_rotation_degrees.z)
	)

	_environment.background_energy_multiplier = selected_energy
	_environment.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	_environment.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	_environment.ambient_light_sky_contribution = selected_ambient

	_effective_sky_energy_value = selected_energy
	_effective_ambient_sky_contribution_value = selected_ambient

	_update_observational_state(selected_sky)

	_sky_change_count_value += 1


# ============================================================
# LAZY LOAD
# ============================================================

func _load_sky(
	resource_path: String,
	preset_index: int
) -> Sky:
	if resource_path.is_empty():
		return null

	var sky_mode: Sky.ProcessMode = _get_sky_process_mode(
		preset_index
	)

	var sky_radiance: Sky.RadianceSize = _get_sky_radiance_size(
		preset_index
	)

	var cache_key: String = (
		resource_path
		+ "|"
		+ str(int(sky_mode))
		+ "|"
		+ str(int(sky_radiance))
	)

	if _sky_cache.has(cache_key):
		var cached_value: Variant = _sky_cache[cache_key]

		if cached_value is Sky:
			return cached_value as Sky

	if not ResourceLoader.exists(resource_path):
		push_warning(
			"Sky resource does not exist: "
			+ resource_path
		)
		return null

	var loaded_resource: Resource = ResourceLoader.load(
		resource_path
	)

	if loaded_resource == null:
		return null

	if loaded_resource is Sky:
		var direct_sky: Sky = loaded_resource as Sky
		_sky_cache[cache_key] = direct_sky
		return direct_sky

	if loaded_resource is Texture2D:
		var panorama_material: PanoramaSkyMaterial = (
			PanoramaSkyMaterial.new()
		)

		panorama_material.panorama = loaded_resource as Texture2D

		var generated_sky: Sky = Sky.new()
		generated_sky.sky_material = panorama_material
		generated_sky.process_mode = sky_mode
		generated_sky.radiance_size = sky_radiance

		_sky_cache[cache_key] = generated_sky

		return generated_sky

	push_warning(
		"Sky path must reference a Sky or Texture2D: "
		+ resource_path
	)

	return null


# ============================================================
# PRESET SETTINGS
# ============================================================

func _get_sky_process_mode(
	preset_index: int
) -> Sky.ProcessMode:
	if (
		preset_index == SkyEnvironmentPreset.KLOOFENDAL_48D
		or preset_index == SkyEnvironmentPreset.CUSTOM
	):
		return Sky.PROCESS_MODE_QUALITY

	return Sky.PROCESS_MODE_AUTOMATIC


func _get_sky_radiance_size(
	preset_index: int
) -> Sky.RadianceSize:
	if (
		preset_index == SkyEnvironmentPreset.KLOOFENDAL_48D
		or preset_index == SkyEnvironmentPreset.CUSTOM
	):
		return Sky.RADIANCE_SIZE_1024

	return Sky.RADIANCE_SIZE_256


# ============================================================
# PATHS
# ============================================================

func _get_sky_path(preset_index: int) -> String:
	match preset_index:
		SkyEnvironmentPreset.ORIGINAL:
			return original_sky_path

		SkyEnvironmentPreset.ARISTEA_WRECK:
			return aristea_wreck_path

		SkyEnvironmentPreset.KLOOFENDAL_48D:
			return kloofendal_48d_path

		SkyEnvironmentPreset.OVERCAST_SOIL:
			return overcast_soil_path

		SkyEnvironmentPreset.CUSTOM:
			return custom_sky_path

	return _get_additional_sky_path(preset_index)


func _get_additional_sky_path(
	preset_index: int
) -> String:
	var additional_index: int = (
		preset_index
		- BUILT_IN_SKY_PRESET_COUNT
	)

	if (
		additional_index < 0
		or additional_index >= additional_sky_paths.size()
	):
		return ""

	return additional_sky_paths[additional_index]


func _get_maximum_sky_preset_index() -> int:
	return (
		BUILT_IN_SKY_PRESET_COUNT
		+ additional_sky_paths.size()
		- 1
	)


# ============================================================
# PRESET NAMES
# ============================================================

func _get_sky_preset_hint_string() -> String:
	var entries: PackedStringArray = PackedStringArray()

	for preset_index: int in range(
		BUILT_IN_SKY_PRESET_COUNT
	):
		entries.append(
			"%s:%d" % [
				_get_sky_preset_display_name(preset_index),
				preset_index,
			]
		)

	for additional_index: int in range(
		additional_sky_paths.size()
	):
		var preset_index: int = (
			BUILT_IN_SKY_PRESET_COUNT
			+ additional_index
		)

		entries.append(
			"%s:%d" % [
				_get_sky_preset_display_name(preset_index),
				preset_index,
			]
		)

	return ",".join(entries)


func _get_sky_preset_display_name(
	preset_index: int
) -> String:
	if (
		preset_index >= 0
		and preset_index < BUILT_IN_SKY_PRESET_COUNT
	):
		return String(
			SkyEnvironmentPreset.keys()[preset_index]
		).replace("_", " ")

	var additional_index: int = (
		preset_index
		- BUILT_IN_SKY_PRESET_COUNT
	)

	if (
		additional_index < 0
		or additional_index >= additional_sky_paths.size()
	):
		return "UNKNOWN"

	var resource_path: String = additional_sky_paths[
		additional_index
	]

	if resource_path.is_empty():
		return "ADDED %d - EMPTY" % (additional_index + 1)

	return "ADDED %d - %s" % [
		additional_index + 1,
		resource_path.get_file().get_basename(),
	]


# ============================================================
# OBSERVATION
# ============================================================

func _update_observational_state(
	active_sky: Sky
) -> void:
	_sky_texture_path_value = ""
	_sky_process_mode_name_value = &"N/A"
	_sky_radiance_size_value = 0

	if active_sky == null:
		return

	_sky_process_mode_name_value = _get_process_mode_name(
		active_sky.process_mode
	)

	_sky_radiance_size_value = _get_radiance_size_value(
		active_sky.radiance_size
	)

	var panorama_material: PanoramaSkyMaterial = (
		active_sky.sky_material as PanoramaSkyMaterial
	)

	if (
		panorama_material != null
		and panorama_material.panorama != null
	):
		_sky_texture_path_value = (
			panorama_material.panorama.resource_path
		)


func _get_process_mode_name(
	sky_mode: Sky.ProcessMode
) -> StringName:
	match sky_mode:
		Sky.PROCESS_MODE_AUTOMATIC:
			return &"AUTOMATIC"

		Sky.PROCESS_MODE_QUALITY:
			return &"QUALITY"

		Sky.PROCESS_MODE_INCREMENTAL:
			return &"INCREMENTAL"

		Sky.PROCESS_MODE_REALTIME:
			return &"REALTIME"

	return &"UNKNOWN"


func _get_radiance_size_value(
	sky_radiance: Sky.RadianceSize
) -> int:
	match sky_radiance:
		Sky.RADIANCE_SIZE_32:
			return 32

		Sky.RADIANCE_SIZE_64:
			return 64

		Sky.RADIANCE_SIZE_128:
			return 128

		Sky.RADIANCE_SIZE_256:
			return 256

		Sky.RADIANCE_SIZE_512:
			return 512

		Sky.RADIANCE_SIZE_1024:
			return 1024

		Sky.RADIANCE_SIZE_2048:
			return 2048

	return 0
