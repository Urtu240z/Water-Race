@tool
class_name SkyEnvironmentController
extends Node

const ORIGINAL_SKY_ENERGY: float = 1.0
const ORIGINAL_AMBIENT_SKY_CONTRIBUTION: float = 0.8

var _syncing_panorama_rotation: bool = false

enum SkyEnvironmentPreset {
	ORIGINAL,
	ARISTEA_WRECK,
	KLOOFENDAL_48D,
	OVERCAST_SOIL,
	CUSTOM,
}

const BUILT_IN_SKY_PRESET_COUNT: int = 5

@export_group("References")
@export_node_path("WorldEnvironment") var world_environment_path: NodePath = NodePath("../WorldEnvironment")

@export_group("Sky Resources")
@export var original_sky: Sky:
	set(value):
		if original_sky == value:
			return
		original_sky = value
		_request_sky_update()
@export var aristea_wreck_sky: Sky:
	set(value):
		if aristea_wreck_sky == value:
			return
		aristea_wreck_sky = value
		_request_sky_update()
@export var kloofendal_48d_sky: Sky:
	set(value):
		if kloofendal_48d_sky == value:
			return
		kloofendal_48d_sky = value
		_request_sky_update()
@export var overcast_soil_sky: Sky:
	set(value):
		if overcast_soil_sky == value:
			return
		overcast_soil_sky = value
		_request_sky_update()
## Extra Sky resources appended to the Sky Preset dropdown.
## Use the Array '+' button in the Inspector, then assign a Sky resource.
@export var additional_skies: Array[Sky] = []:
	set(value):
		additional_skies = value
		if int(sky_preset) > _get_maximum_sky_preset_index():
			sky_preset = SkyEnvironmentPreset.CUSTOM
		notify_property_list_changed()
		_request_sky_update()

@export_group("Sky Environment")
@export var sky_preset: int = SkyEnvironmentPreset.ARISTEA_WRECK:
	set(value):
		var validated_value := clampi(
			int(value),
			0,
			_get_maximum_sky_preset_index()
		)
		if int(sky_preset) == validated_value:
			return
		sky_preset = validated_value
		_request_sky_update()
@export var custom_sky: Sky:
	set(value):
		if custom_sky == value:
			return
		custom_sky = value
		_request_sky_update()
## Euler rotation applied to the active panorama, in degrees.
@export var panorama_rotation_degrees: Vector3 = Vector3.ZERO:
	set(value):
		var validated_value := Vector3(
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
## Legacy Y-only property retained for existing scenes.
@export_storage var sky_rotation_degrees: float = 0.0:
	set(value):
		var validated_value := clampf(value, -180.0, 180.0)
		if is_equal_approx(sky_rotation_degrees, validated_value):
			return
		sky_rotation_degrees = validated_value
		if _syncing_panorama_rotation:
			return
		_syncing_panorama_rotation = true
		var migrated_rotation := panorama_rotation_degrees
		migrated_rotation.y = validated_value
		panorama_rotation_degrees = migrated_rotation
		_syncing_panorama_rotation = false
		_request_sky_update()
@export_range(0.05, 4.0, 0.05) var sky_energy_multiplier: float = 1.0:
	set(value):
		var validated_value := clampf(value, 0.05, 4.0)
		if is_equal_approx(sky_energy_multiplier, validated_value):
			return
		sky_energy_multiplier = validated_value
		_request_sky_update()
@export_range(0.0, 1.0, 0.01) var ambient_sky_contribution: float = 0.85:
	set(value):
		var validated_value := clampf(value, 0.0, 1.0)
		if is_equal_approx(ambient_sky_contribution, validated_value):
			return
		ambient_sky_contribution = validated_value
		_request_sky_update()

var _world_environment: WorldEnvironment
var _environment: Environment
var _original_sky_reference: Sky
var _original_sky_energy: float = ORIGINAL_SKY_ENERGY
var _original_ambient_sky_contribution: float = ORIGINAL_AMBIENT_SKY_CONTRIBUTION
var _effective_sky_energy_value: float = 1.0
var _effective_ambient_sky_contribution_value: float = 0.85
var _sky_texture_path_value: String = ""
var _sky_process_mode_name_value: StringName = &"N/A"
var _sky_radiance_size_value: int = 0
var _sky_change_count_value: int = 0
var _sky_reference_valid_value: bool = false

var sky_preset_name: StringName:
	get:
		return StringName(_get_sky_preset_display_name(int(sky_preset)))

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

	_original_sky_reference = (
		original_sky
		if original_sky != null
		else _environment.sky
	)

	_original_sky_energy = (
		_environment.background_energy_multiplier
	)
	_original_ambient_sky_contribution = (
		_environment.ambient_light_sky_contribution
	)

	_apply_active_preset()


func _request_sky_update() -> void:
	if not is_inside_tree() or not is_node_ready() or _environment == null:
		return
	_apply_active_preset()


func _validate_property(property: Dictionary) -> void:
	if property.name == &"sky_preset":
		property.hint = PROPERTY_HINT_ENUM
		property.hint_string = _get_sky_preset_hint_string()


func _apply_active_preset() -> void:
	if _environment == null:
		return

	var selected_sky: Sky
	var selected_energy := sky_energy_multiplier
	var selected_ambient_contribution := ambient_sky_contribution
	var active_reference_is_valid := true

	match sky_preset:
		SkyEnvironmentPreset.ORIGINAL:
			selected_sky = _original_sky_reference
			selected_energy = _original_sky_energy
			selected_ambient_contribution = (
				_original_ambient_sky_contribution
			)

		SkyEnvironmentPreset.ARISTEA_WRECK:
			selected_sky = aristea_wreck_sky

		SkyEnvironmentPreset.KLOOFENDAL_48D:
			selected_sky = kloofendal_48d_sky

		SkyEnvironmentPreset.OVERCAST_SOIL:
			selected_sky = overcast_soil_sky

		SkyEnvironmentPreset.CUSTOM:
			selected_sky = custom_sky
			active_reference_is_valid = custom_sky != null

		_:
			selected_sky = _get_additional_sky(int(sky_preset))
			active_reference_is_valid = selected_sky != null

	if selected_sky == null:
		active_reference_is_valid = false
		selected_sky = _original_sky_reference

	_environment.background_mode = Environment.BG_SKY
	_environment.sky = selected_sky
	_environment.sky_rotation = Vector3(
		deg_to_rad(panorama_rotation_degrees.x),
		deg_to_rad(panorama_rotation_degrees.y),
		deg_to_rad(panorama_rotation_degrees.z)
	)
	_environment.background_energy_multiplier = selected_energy
	_environment.ambient_light_source = (
		Environment.AMBIENT_SOURCE_SKY
	)
	_environment.reflected_light_source = (
		Environment.REFLECTION_SOURCE_SKY
	)
	_environment.ambient_light_sky_contribution = (
		selected_ambient_contribution
	)

	_effective_sky_energy_value = selected_energy
	_effective_ambient_sky_contribution_value = (
		selected_ambient_contribution
	)
	_sky_reference_valid_value = (
		active_reference_is_valid
		and _world_environment != null
		and _environment != null
		and selected_sky != null
	)

	_update_observational_sky_state(selected_sky)
	_sky_change_count_value += 1


func _get_maximum_sky_preset_index() -> int:
	return BUILT_IN_SKY_PRESET_COUNT + additional_skies.size() - 1


func _get_additional_sky(preset_index: int) -> Sky:
	var additional_index := preset_index - BUILT_IN_SKY_PRESET_COUNT
	if additional_index < 0 or additional_index >= additional_skies.size():
		return null
	return additional_skies[additional_index]


func _get_sky_preset_hint_string() -> String:
	var entries := PackedStringArray()
	for preset_index in BUILT_IN_SKY_PRESET_COUNT:
		entries.append(
			"%s:%d" % [
				_get_sky_preset_display_name(preset_index),
				preset_index,
			]
		)
	for additional_index in additional_skies.size():
		var preset_index := BUILT_IN_SKY_PRESET_COUNT + additional_index
		entries.append(
			"%s:%d" % [
				_get_sky_preset_display_name(preset_index),
				preset_index,
			]
		)
	return ",".join(entries)


func _get_sky_preset_display_name(preset_index: int) -> String:
	if preset_index >= 0 and preset_index < BUILT_IN_SKY_PRESET_COUNT:
		return String(SkyEnvironmentPreset.keys()[preset_index]).replace("_", " ")

	var additional_index := preset_index - BUILT_IN_SKY_PRESET_COUNT
	if additional_index < 0 or additional_index >= additional_skies.size():
		return "UNKNOWN"

	var selected_sky := additional_skies[additional_index]
	var resource_label := _get_sky_resource_label(selected_sky)
	return "ADDED %d - %s" % [additional_index + 1, resource_label]


func _get_sky_resource_label(sky: Sky) -> String:
	if sky == null:
		return "EMPTY"
	if not sky.resource_name.strip_edges().is_empty():
		return _sanitize_preset_label(sky.resource_name)
	if not sky.resource_path.is_empty():
		return _sanitize_preset_label(
			sky.resource_path.get_file().get_basename()
		)
	var panorama_material := sky.sky_material as PanoramaSkyMaterial
	if panorama_material != null and panorama_material.panorama != null:
		var panorama := panorama_material.panorama
		if not panorama.resource_name.strip_edges().is_empty():
			return _sanitize_preset_label(panorama.resource_name)
		if not panorama.resource_path.is_empty():
			return _sanitize_preset_label(
				panorama.resource_path.get_file().get_basename()
			)
	return "SKY RESOURCE"


func _sanitize_preset_label(label: String) -> String:
	return label.replace(",", " ").replace(":", " ")


func _update_observational_sky_state(active_sky: Sky) -> void:
	_sky_texture_path_value = ""
	_sky_process_mode_name_value = &"N/A"
	_sky_radiance_size_value = 0
	if active_sky == null:
		return
	_sky_process_mode_name_value = _get_process_mode_name(active_sky.process_mode)
	_sky_radiance_size_value = _get_radiance_size(active_sky.radiance_size)
	var panorama_material := active_sky.sky_material as PanoramaSkyMaterial
	if panorama_material != null and panorama_material.panorama != null:
		_sky_texture_path_value = panorama_material.panorama.resource_path


func _get_process_mode_name(sky_process_mode: Sky.ProcessMode) -> StringName:
	match sky_process_mode:
		Sky.PROCESS_MODE_AUTOMATIC:
			return &"AUTOMATIC"
		Sky.PROCESS_MODE_QUALITY:
			return &"QUALITY"
		Sky.PROCESS_MODE_INCREMENTAL:
			return &"INCREMENTAL"
		Sky.PROCESS_MODE_REALTIME:
			return &"REALTIME"
		_:
			return &"UNKNOWN"


func _get_radiance_size(radiance_size_value: Sky.RadianceSize) -> int:
	match radiance_size_value:
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
		_:
			return 0
