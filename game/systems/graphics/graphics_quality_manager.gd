extends Node

signal quality_changed(quality: int)
signal graphics_quality_applying(level: int, profile: GraphicsQualityProfile)
signal graphics_quality_applied(level: int, profile: GraphicsQualityProfile)

enum Quality {
	LOW = 0,
	MEDIUM = 1,
	HIGH = 2,
}

const ENVIRONMENT_GROUP: StringName = &"graphics_quality_environment"
const DIRECTIONAL_LIGHT_GROUP: StringName = &"graphics_quality_directional_light"
const POSITIONAL_LIGHT_GROUP: StringName = &"graphics_quality_positional_light"
const REFLECTION_PROBE_GROUP: StringName = &"graphics_quality_reflection_probe"
const GEOMETRY_GROUP: StringName = &"graphics_quality_geometry"
const OCEAN_GROUP: StringName = &"graphics_quality_ocean"
const VEHICLE_EFFECTS_GROUP: StringName = &"graphics_quality_vehicle_effects"
const TERRAIN_GROUP: StringName = &"graphics_quality_terrain"
const VEGETATION_GROUP: StringName = &"graphics_quality_vegetation"
const WILDLIFE_GROUP: StringName = &"graphics_quality_wildlife"
const UNDERWATER_GROUP: StringName = &"graphics_quality_underwater"

const SETTINGS_PATH := "user://graphics_settings.cfg"
const SETTINGS_SECTION := "graphics"
const SETTINGS_KEY := "quality"
const STEAM_DECK_HIGH_SCALE := 0.77

const PROFILE_PATHS := {
	Quality.LOW: "res://resources/settings/graphics_low.tres",
	Quality.MEDIUM: "res://resources/settings/graphics_medium.tres",
	Quality.HIGH: "res://resources/settings/graphics_high.tres",
}

var is_steam_deck: bool = false
var current_quality: int = Quality.HIGH
var current_profile: GraphicsQualityProfile
var is_applying: bool = false
var restart_required: bool = false

var _profiles: Dictionary = {}
var _settings_path: String = SETTINGS_PATH
var _environment_refs: Array[WeakRef] = []
var _directional_light_refs: Array[WeakRef] = []
var _positional_light_refs: Array[WeakRef] = []
var _reflection_probe_refs: Array[WeakRef] = []
var _geometry_refs: Array[WeakRef] = []
var _ocean_refs: Array[WeakRef] = []
var _vehicle_effects_refs: Array[WeakRef] = []
var _terrain_refs: Array[WeakRef] = []
var _vegetation_refs: Array[WeakRef] = []
var _wildlife_refs: Array[WeakRef] = []
var _underwater_refs: Array[WeakRef] = []
var _scene_refresh_queued: bool = false
var _application_revision: int = 0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	Engine.max_fps = 0
	is_steam_deck = _detect_steam_deck()
	_load_profiles()
	current_quality = _get_startup_quality()
	current_profile = _profiles.get(current_quality) as GraphicsQualityProfile
	get_tree().node_added.connect(_on_tree_node_added)
	call_deferred("_refresh_and_apply")


func set_quality(quality: int, persist: bool = true) -> void:
	if not _is_valid_quality(quality):
		push_warning("GraphicsQualityManager: invalid quality %s; using MEDIUM." % quality)
		quality = Quality.MEDIUM
	var profile := _profiles.get(quality) as GraphicsQualityProfile
	if profile == null:
		push_error("GraphicsQualityManager: profile %s could not be loaded." % quality)
		return
	current_quality = quality
	current_profile = profile
	is_applying = true
	_application_revision += 1
	var revision := _application_revision
	graphics_quality_applying.emit(current_quality, current_profile)
	_refresh_targets()
	_apply_current_profile()
	if persist:
		_save_quality()
	quality_changed.emit(current_quality)
	_finish_quality_application(revision)


func reapply_current_quality() -> void:
	if current_profile == null:
		return
	is_applying = true
	_application_revision += 1
	var revision := _application_revision
	graphics_quality_applying.emit(current_quality, current_profile)
	_refresh_targets()
	_apply_current_profile()
	_finish_quality_application(revision)


func get_graphics_quality_debug_status() -> Dictionary:
	return {
		"level": current_quality,
		"name": get_quality_name(),
		"is_applying": is_applying,
		"restart_required": restart_required,
		"ocean": _collect_debug_status(_ocean_refs),
		"vehicle_effects": _collect_debug_status(_vehicle_effects_refs),
		"terrain": _collect_debug_status(_terrain_refs),
		"vegetation": _collect_debug_status(_vegetation_refs),
		"wildlife": _collect_debug_status(_wildlife_refs),
		"underwater": _collect_debug_status(_underwater_refs),
	}


func get_quality_name(quality: int = current_quality) -> String:
	match quality:
		Quality.LOW:
			return "BAJO"
		Quality.MEDIUM:
			return "MEDIO"
		Quality.HIGH:
			return "ALTO"
		_:
			return "DESCONOCIDO"


func get_applied_3d_scale() -> float:
	if current_profile == null:
		return 1.0
	if current_quality == Quality.HIGH and is_steam_deck:
		return STEAM_DECK_HIGH_SCALE
	return current_profile.scaling_3d_scale


func _load_profiles() -> void:
	for quality: int in PROFILE_PATHS:
		var profile := load(PROFILE_PATHS[quality]) as GraphicsQualityProfile
		if profile == null:
			push_error(
				"GraphicsQualityManager: failed to load %s." % PROFILE_PATHS[quality]
			)
			continue
		_profiles[quality] = profile


func _get_startup_quality() -> int:
	var command_line_quality := _get_command_line_quality()
	if command_line_quality >= 0:
		return command_line_quality
	return Quality.HIGH


func _save_quality() -> void:
	var config := ConfigFile.new()
	config.set_value(SETTINGS_SECTION, SETTINGS_KEY, current_quality)
	var error := config.save(_settings_path)
	if error != OK:
		push_warning(
			"GraphicsQualityManager: could not save %s (error %s)."
			% [_settings_path, error]
		)


func _get_command_line_quality() -> int:
	for argument: String in _get_all_command_line_arguments():
		if not argument.begins_with("--graphics-preset="):
			continue
		match argument.trim_prefix("--graphics-preset=").to_lower():
			"low":
				return Quality.LOW
			"medium":
				return Quality.MEDIUM
			"high":
				return Quality.HIGH
			_:
				push_warning(
					"GraphicsQualityManager: unknown command-line preset '%s'."
					% argument
				)
	return -1


func _detect_steam_deck() -> bool:
	if "--force-steam-deck" in _get_all_command_line_arguments():
		return true
	if OS.get_name() != "Linux":
		return false
	for environment_name: String in [
		"SteamDeck",
		"STEAM_DECK",
		"SteamOS",
		"STEAMOS",
	]:
		if _environment_flag_is_true(OS.get_environment(environment_name)):
			return true
	var desktop := OS.get_environment("XDG_CURRENT_DESKTOP").to_lower()
	var session := OS.get_environment("DESKTOP_SESSION").to_lower()
	if "gamescope" in desktop or "gamescope" in session:
		return true
	var screen_size := DisplayServer.screen_get_size()
	var short_side := mini(screen_size.x, screen_size.y)
	var long_side := maxi(screen_size.x, screen_size.y)
	return abs(short_side - 800) <= 40 and abs(long_side - 1280) <= 80


func _environment_flag_is_true(value: String) -> bool:
	return value.strip_edges().to_lower() in ["1", "true", "yes", "on"]


func _get_all_command_line_arguments() -> PackedStringArray:
	var arguments := OS.get_cmdline_args()
	for argument: String in OS.get_cmdline_user_args():
		if argument not in arguments:
			arguments.append(argument)
	return arguments


func _on_tree_node_added(node: Node) -> void:
	if (
		node.is_in_group(ENVIRONMENT_GROUP)
		or node.is_in_group(DIRECTIONAL_LIGHT_GROUP)
		or node.is_in_group(POSITIONAL_LIGHT_GROUP)
		or node.is_in_group(REFLECTION_PROBE_GROUP)
		or node.is_in_group(GEOMETRY_GROUP)
		or node.is_in_group(OCEAN_GROUP)
		or node.is_in_group(VEHICLE_EFFECTS_GROUP)
		or node.is_in_group(TERRAIN_GROUP)
		or node.is_in_group(VEGETATION_GROUP)
		or node.is_in_group(WILDLIFE_GROUP)
		or node.is_in_group(UNDERWATER_GROUP)
	):
		_queue_scene_refresh()


func _queue_scene_refresh() -> void:
	if _scene_refresh_queued:
		return
	_scene_refresh_queued = true
	call_deferred("_refresh_and_apply")


func _refresh_and_apply() -> void:
	_scene_refresh_queued = false
	_refresh_targets()
	_apply_current_profile()


func _refresh_targets() -> void:
	_environment_refs.clear()
	_directional_light_refs.clear()
	_positional_light_refs.clear()
	_reflection_probe_refs.clear()
	_geometry_refs.clear()
	_ocean_refs.clear()
	_vehicle_effects_refs.clear()
	_terrain_refs.clear()
	_vegetation_refs.clear()
	_wildlife_refs.clear()
	_underwater_refs.clear()
	var current_scene := get_tree().current_scene
	if current_scene != null:
		_collect_targets(current_scene)


func _collect_targets(node: Node) -> void:
	if node.is_in_group(ENVIRONMENT_GROUP) and node is WorldEnvironment:
		_environment_refs.append(weakref(node))
	if node.is_in_group(DIRECTIONAL_LIGHT_GROUP) and node is DirectionalLight3D:
		_directional_light_refs.append(weakref(node))
	if (
		node.is_in_group(POSITIONAL_LIGHT_GROUP)
		and (node is OmniLight3D or node is SpotLight3D)
	):
		_positional_light_refs.append(weakref(node))
	if node.is_in_group(REFLECTION_PROBE_GROUP) and node is ReflectionProbe:
		_reflection_probe_refs.append(weakref(node))
	if node.is_in_group(GEOMETRY_GROUP) and node is GeometryInstance3D:
		_geometry_refs.append(weakref(node))
	_collect_quality_target(node, OCEAN_GROUP, _ocean_refs)
	_collect_quality_target(node, VEHICLE_EFFECTS_GROUP, _vehicle_effects_refs)
	_collect_quality_target(node, TERRAIN_GROUP, _terrain_refs)
	_collect_quality_target(node, VEGETATION_GROUP, _vegetation_refs)
	_collect_quality_target(node, WILDLIFE_GROUP, _wildlife_refs)
	_collect_quality_target(node, UNDERWATER_GROUP, _underwater_refs)
	for child: Node in node.get_children():
		_collect_targets(child)


func _apply_current_profile() -> void:
	if current_profile == null:
		return
	_apply_viewport_settings(current_profile)
	_apply_environment_settings(current_profile)
	_apply_directional_light_settings(current_profile)
	_apply_positional_light_settings(current_profile)
	_apply_reflection_probe_settings(current_profile)
	_apply_quality_targets(_ocean_refs, current_profile)
	_apply_quality_targets(_vehicle_effects_refs, current_profile)
	_apply_quality_targets(_terrain_refs, current_profile)
	_apply_quality_targets(_vegetation_refs, current_profile)
	_apply_quality_targets(_wildlife_refs, current_profile)
	_apply_quality_targets(_underwater_refs, current_profile)


func _collect_quality_target(
	node: Node,
	group: StringName,
	target_refs: Array[WeakRef]
) -> void:
	if node.is_in_group(group) and node.has_method(&"set_graphics_quality"):
		target_refs.append(weakref(node))


func _apply_quality_targets(
	target_refs: Array[WeakRef],
	profile: GraphicsQualityProfile
) -> void:
	for reference: WeakRef in target_refs:
		var target := reference.get_ref() as Node
		if target != null:
			target.call(&"set_graphics_quality", current_quality, profile)


func _finish_quality_application(revision: int) -> void:
	await get_tree().process_frame
	if revision != _application_revision:
		return
	is_applying = false
	graphics_quality_applied.emit(current_quality, current_profile)


func _collect_debug_status(target_refs: Array[WeakRef]) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for reference: WeakRef in target_refs:
		var target := reference.get_ref() as Node
		if target == null:
			continue
		var status := {"node": str(target.get_path())}
		if target.has_method(&"get_graphics_quality_debug_status"):
			var reported: Variant = target.call(
				&"get_graphics_quality_debug_status"
			)
			if reported is Dictionary:
				status.merge(reported as Dictionary, true)
		result.append(status)
	return result


func _apply_viewport_settings(profile: GraphicsQualityProfile) -> void:
	var viewport := get_viewport()
	if viewport == null:
		return
	viewport.scaling_3d_mode = profile.scaling_3d_mode
	viewport.scaling_3d_scale = get_applied_3d_scale()
	viewport.msaa_3d = profile.msaa_3d
	viewport.screen_space_aa = profile.screen_space_aa
	viewport.use_taa = profile.use_taa
	viewport.anisotropic_filtering_level = profile.anisotropic_filtering
	viewport.texture_mipmap_bias = profile.texture_mipmap_bias
	viewport.mesh_lod_threshold = profile.mesh_lod_bias
	viewport.positional_shadow_atlas_size = profile.positional_shadow_atlas_size
	RenderingServer.directional_shadow_atlas_set_size(
		profile.directional_shadow_atlas_size,
		true
	)
	Engine.max_fps = 0


func _apply_environment_settings(profile: GraphicsQualityProfile) -> void:
	for reference: WeakRef in _environment_refs:
		var world_environment := reference.get_ref() as WorldEnvironment
		if world_environment == null or world_environment.environment == null:
			continue
		var environment := world_environment.environment
		environment.ssr_enabled = profile.built_in_ssr
		environment.ssao_enabled = profile.ssao
		if profile.ssao:
			environment.ssao_radius = profile.ssao_radius
			environment.ssao_detail = profile.ssao_detail
			environment.ssao_power = profile.ssao_power
		environment.ssil_enabled = profile.ssil
		if profile.ssil:
			environment.ssil_radius = profile.ssil_radius
			environment.ssil_intensity = profile.ssil_intensity
		environment.glow_enabled = profile.glow
		if profile.glow:
			environment.glow_intensity = profile.glow_intensity
		environment.fog_enabled = profile.fog
		environment.volumetric_fog_enabled = profile.volumetric_fog
		environment.sdfgi_enabled = profile.sdfgi
		if environment.sky != null:
			environment.sky.radiance_size = profile.sky_radiance


func _apply_directional_light_settings(profile: GraphicsQualityProfile) -> void:
	for reference: WeakRef in _directional_light_refs:
		var light := reference.get_ref() as DirectionalLight3D
		if light == null:
			continue
		light.directional_shadow_max_distance = profile.directional_shadow_max_distance
		light.directional_shadow_mode = profile.directional_shadow_mode
		light.shadow_blur = profile.directional_shadow_blur


func _apply_positional_light_settings(profile: GraphicsQualityProfile) -> void:
	for reference: WeakRef in _positional_light_refs:
		var light := reference.get_ref() as Light3D
		if light != null:
			light.shadow_enabled = profile.omni_shadows


func _apply_reflection_probe_settings(profile: GraphicsQualityProfile) -> void:
	for reference: WeakRef in _reflection_probe_refs:
		var probe := reference.get_ref() as ReflectionProbe
		if probe == null:
			continue
		probe.visible = profile.reflection_probe
		probe.enable_shadows = (
			profile.reflection_probe and profile.reflection_probe_shadows
		)


func _is_valid_quality(quality: int) -> bool:
	return quality >= Quality.LOW and quality <= Quality.HIGH
