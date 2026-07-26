@tool
class_name WaterBody3D
extends Node3D

const BASE_WAVE_COMPONENTS: int = 4
const MAX_WAVE_COMPONENTS: int = 12
# Compatibility alias used by existing observational tooling. Canonical wave
# arrays now always contain the maximum fixed number of components.
const WAVE_COUNT: int = MAX_WAVE_COMPONENTS

enum WaveSpectrumMode {
	CLASSIC_4,
	ARCADE_8,
	RACE_10,
	CROSS_CHOP_10,
	STORM_12,
	CUSTOM,
}

enum WaveIntensity {
	VERY_CALM,
	CALM,
	DEFAULT,
	ROUGH,
	STORM,
}

enum WaveSetMode {
	OFF,
	NATURAL,
	NATURAL_ARCADE,
	CUSTOM,
}

enum WaterRenderMode {
	ARCADE_OPAQUE,
	TRANSPARENT_LEGACY,
}

enum WaterOpticsDebugMode {
	FINAL,
	THICKNESS,
	ABSORPTION,
	FRESNEL,
	DISTANCE_OPACITY,
	FINAL_ALPHA,
	REFRACTION,
}

enum SurfaceDetailMode {
	OFF,
	CROSSED,
	STOCHASTIC,
}

enum WaterAppearancePreset {
	CLEAR,
	OCEAN,
	DENSE,
	CUSTOM,
}

enum WaterOpticsPreset {
	ARCADE_CLEAR,
	RACE_BLUE,
	ROUGH_OCEAN,
	STORM_DENSE,
	CUSTOM,
}

# Kept as observational compatibility values for existing debug consumers.
# The active opaque and local shaders no longer use a clearcoat layer.
const ARCADE_CLEARCOAT: float = 0.0
const ARCADE_CLEARCOAT_GLOSS: float = 0.0

@export_group("Water Render")
@export var water_render_mode: WaterRenderMode = WaterRenderMode.ARCADE_OPAQUE:
	set(value):
		var validated_value := clampi(int(value), 0, WaterRenderMode.size() - 1)
		if int(water_render_mode) == validated_value:
			return
		water_render_mode = validated_value as WaterRenderMode
		_request_water_material_update()
@export var opaque_water_material: ShaderMaterial
@export var legacy_water_material: ShaderMaterial

@export_group("Local Transparency")
@export var local_transparency_enabled: bool = true:
	set(value):
		if local_transparency_enabled == value:
			return
		local_transparency_enabled = value
		_request_local_transparency_update()
@export_range(1.0, 20.0, 0.25) var local_transparency_core_radius: float = 3.0:
	set(value):
		var validated_value := clampf(value, 1.0, 20.0)
		if is_equal_approx(local_transparency_core_radius, validated_value):
			return
		local_transparency_core_radius = validated_value
		_request_local_transparency_update()
@export_range(2.0, 30.0, 0.25) var local_transparency_handoff_radius: float = 6.0:
	set(value):
		var validated_value := clampf(value, 2.0, 30.0)
		if is_equal_approx(local_transparency_handoff_radius, validated_value):
			return
		local_transparency_handoff_radius = validated_value
		_request_local_transparency_update()
@export_range(0.001, 0.10, 0.001) var local_transparency_handoff_epsilon: float = 0.02:
	set(value):
		var validated_value := clampf(value, 0.001, 0.10)
		if is_equal_approx(local_transparency_handoff_epsilon, validated_value):
			return
		local_transparency_handoff_epsilon = validated_value
		_request_local_transparency_update()
@export_range(16.0, 128.0, 1.0) var local_transparency_patch_size: float = 16.0:
	set(value):
		var validated_value := clampf(value, 16.0, 128.0)
		if is_equal_approx(local_transparency_patch_size, validated_value):
			return
		local_transparency_patch_size = validated_value
		_request_local_transparency_update()
@export_range(15, 255, 2) var local_transparency_subdivisions: int = 63:
	set(value):
		var validated_value := clampi(value, 15, 255)
		if validated_value % 2 == 0:
			validated_value = mini(validated_value + 1, 255)
		if local_transparency_subdivisions == validated_value:
			return
		local_transparency_subdivisions = validated_value
		_request_local_transparency_update()
@export_range(0.50, 1.0, 0.01) var local_transparency_near_alpha: float = 0.78:
	set(value):
		var validated_value := clampf(value, 0.50, 1.0)
		if is_equal_approx(local_transparency_near_alpha, validated_value):
			return
		local_transparency_near_alpha = validated_value
		_request_local_transparency_update()
@export_range(0.60, 1.0, 0.01) var local_transparency_deep_alpha: float = 0.95:
	set(value):
		var validated_value := clampf(value, 0.60, 1.0)
		if is_equal_approx(local_transparency_deep_alpha, validated_value):
			return
		local_transparency_deep_alpha = validated_value
		_request_local_transparency_update()
@export_range(0.01, 1.0, 0.01) var local_transparency_absorption_density: float = 0.28:
	set(value):
		var validated_value := clampf(value, 0.01, 1.0)
		if is_equal_approx(local_transparency_absorption_density, validated_value):
			return
		local_transparency_absorption_density = validated_value
		_request_local_transparency_update()
@export_range(0.0, 0.03, 0.0005) var local_transparency_refraction_strength: float = 0.005:
	set(value):
		var validated_value := clampf(value, 0.0, 0.03)
		if is_equal_approx(local_transparency_refraction_strength, validated_value):
			return
		local_transparency_refraction_strength = validated_value
		_request_local_transparency_update()
@export_range(0.0, 1.0, 0.01) var local_transparency_fresnel_opacity: float = 0.90:
	set(value):
		var validated_value := clampf(value, 0.0, 1.0)
		if is_equal_approx(local_transparency_fresnel_opacity, validated_value):
			return
		local_transparency_fresnel_opacity = validated_value
		_request_local_transparency_update()
@export_node_path("Node3D") var local_transparency_target_path: NodePath

@export_group("Wave Motion")
@export var wave_profile: WaveProfile
@export var wave_intensity: WaveIntensity = WaveIntensity.DEFAULT:
	set(value):
		var validated_value := clampi(int(value), 0, WaveIntensity.size() - 1)
		if int(wave_intensity) == validated_value:
			return
		wave_intensity = validated_value as WaveIntensity
		_request_wave_block_rebuild()
@export_range(0.25, 2.0, 0.05) var wave_speed_multiplier: float = 2.0:
	set(value):
		var validated_value := clampf(value, 0.25, 2.0)
		if is_equal_approx(wave_speed_multiplier, validated_value):
			return
		_preserve_wave_phase_continuity(wave_speed_multiplier, validated_value)
		wave_speed_multiplier = validated_value
		_request_wave_block_rebuild()
@export var base_height: float = 0.0

@export_group("Adaptive Crest Shape")
@export var adaptive_crest_shape_enabled: bool = true:
	set(value):
		if adaptive_crest_shape_enabled == value:
			return
		adaptive_crest_shape_enabled = value
		_request_wave_block_rebuild()
@export_range(0.0, 2.0, 0.05) var crest_shape_strength: float = 1.0:
	set(value):
		var validated_value := clampf(value, 0.0, 2.0)
		if is_equal_approx(crest_shape_strength, validated_value):
			return
		crest_shape_strength = validated_value
		_request_wave_block_rebuild()
@export var gerstner_choppiness_enabled: bool = true:
	set(value):
		if gerstner_choppiness_enabled == value:
			return
		gerstner_choppiness_enabled = value
		_request_wave_block_rebuild()
@export_range(0.0, 2.0, 0.05) var gerstner_choppiness_scale: float = 1.0:
	set(value):
		var validated_value := clampf(value, 0.0, 2.0)
		if is_equal_approx(gerstner_choppiness_scale, validated_value):
			return
		gerstner_choppiness_scale = validated_value
		_request_wave_block_rebuild()
@export_range(0.10, 0.90, 0.01) var gerstner_maximum_total_steepness: float = 0.72:
	set(value):
		var validated_value := clampf(value, 0.10, 0.90)
		if is_equal_approx(gerstner_maximum_total_steepness, validated_value):
			return
		gerstner_maximum_total_steepness = validated_value
		_request_wave_block_rebuild()
@export_range(2, 6, 1) var gerstner_inverse_iterations: int = 4:
	set(value):
		gerstner_inverse_iterations = clampi(value, 2, 6)

@export_group("Wave Spectrum")
@export var wave_spectrum_mode: WaveSpectrumMode = WaveSpectrumMode.RACE_10:
	set(value):
		var validated_value := clampi(int(value), 0, WaveSpectrumMode.size() - 1)
		if int(wave_spectrum_mode) == validated_value:
			return
		wave_spectrum_mode = validated_value as WaveSpectrumMode
		_clear_temporal_phase_offsets()
		_request_wave_block_rebuild()
@export var spectrum_settings: WaveSpectrumSettings:
	set(value):
		if spectrum_settings == value:
			return
		_disconnect_spectrum_settings()
		spectrum_settings = value
		_connect_spectrum_settings()
		_clear_temporal_phase_offsets()
		_request_wave_block_rebuild()

@export_group("Wave Sets")
@export var wave_set_mode: WaveSetMode = WaveSetMode.NATURAL_ARCADE:
	set(value):
		var validated_value := clampi(int(value), 0, WaveSetMode.size() - 1)
		if int(wave_set_mode) == validated_value:
			return
		wave_set_mode = validated_value as WaveSetMode
		_request_wave_set_update()
@export var wave_set_settings: WaveSetSettings:
	set(value):
		if wave_set_settings == value:
			return
		wave_set_settings = value
		_request_wave_set_update()
@export_tool_button("Force Gentle Set")
var force_gentle_set_button: Callable = _force_gentle_set_from_editor
@export_tool_button("Force Medium Set")
var force_medium_set_button: Callable = _force_medium_set_from_editor
@export_tool_button("Force Strong Set")
var force_strong_set_button: Callable = _force_strong_set_from_editor

@export_group("Foam")
@export var foam_settings: WaterFoamSettings:
	set(value):
		if foam_settings == value:
			return
		foam_settings = value
		_request_foam_update()
@export var foam_noise_texture: Texture2D:
	set(value):
		if foam_noise_texture == value:
			return
		foam_noise_texture = value
		_request_foam_update()

@export_group("Visual Surface")
@export_range(0.25, 4.0, 0.05) var visual_detail_speed_multiplier: float = 2.0:
	set(value):
		var validated_value := clampf(value, 0.25, 4.0)
		if is_equal_approx(visual_detail_speed_multiplier, validated_value):
			return
		visual_detail_speed_multiplier = validated_value
		_request_visual_shader_update()
@export_range(0.0, 0.3, 0.005) var micro_wave_strength: float = 0.08:
	set(value):
		var validated_value := clampf(value, 0.0, 0.3)
		if is_equal_approx(micro_wave_strength, validated_value):
			return
		micro_wave_strength = validated_value
		_request_visual_shader_update()

@export_subgroup("Organic Detail")
@export var surface_detail_mode: SurfaceDetailMode = SurfaceDetailMode.STOCHASTIC:
	set(value):
		var validated_value := clampi(int(value), 0, SurfaceDetailMode.size() - 1)
		if int(surface_detail_mode) == validated_value:
			return
		surface_detail_mode = validated_value as SurfaceDetailMode
		_request_visual_shader_update()
@export var surface_normal_texture_a: Texture2D:
	set(value):
		if surface_normal_texture_a == value:
			return
		surface_normal_texture_a = value
		_request_visual_shader_update()
@export var surface_normal_texture_b: Texture2D:
	set(value):
		if surface_normal_texture_b == value:
			return
		surface_normal_texture_b = value
		_request_visual_shader_update()
@export var surface_warp_texture: Texture2D:
	set(value):
		if surface_warp_texture == value:
			return
		surface_warp_texture = value
		_request_visual_shader_update()
@export_range(0.0, 2.0, 0.01) var surface_normal_strength: float = 0.72:
	set(value):
		var validated_value := clampf(value, 0.0, 2.0)
		if is_equal_approx(surface_normal_strength, validated_value):
			return
		surface_normal_strength = validated_value
		_request_visual_shader_update()
@export_range(0.25, 80.0, 0.05) var surface_normal_world_size_a: float = 7.5:
	set(value):
		var validated_value := clampf(value, 0.25, 80.0)
		if is_equal_approx(surface_normal_world_size_a, validated_value):
			return
		surface_normal_world_size_a = validated_value
		_request_visual_shader_update()
@export_range(0.25, 80.0, 0.05) var surface_normal_world_size_b: float = 3.25:
	set(value):
		var validated_value := clampf(value, 0.25, 80.0)
		if is_equal_approx(surface_normal_world_size_b, validated_value):
			return
		surface_normal_world_size_b = validated_value
		_request_visual_shader_update()
@export var surface_flow_direction_a: Vector2 = Vector2(0.82, 0.57):
	set(value):
		surface_flow_direction_a = value
		_request_visual_shader_update()
@export var surface_flow_direction_b: Vector2 = Vector2(-0.46, 0.89):
	set(value):
		surface_flow_direction_b = value
		_request_visual_shader_update()
@export_range(-3.0, 3.0, 0.01) var surface_flow_speed_a: float = 0.38:
	set(value):
		var validated_value := clampf(value, -3.0, 3.0)
		if is_equal_approx(surface_flow_speed_a, validated_value):
			return
		surface_flow_speed_a = validated_value
		_request_visual_shader_update()
@export_range(-3.0, 3.0, 0.01) var surface_flow_speed_b: float = -0.26:
	set(value):
		var validated_value := clampf(value, -3.0, 3.0)
		if is_equal_approx(surface_flow_speed_b, validated_value):
			return
		surface_flow_speed_b = validated_value
		_request_visual_shader_update()
@export_range(2.0, 300.0, 0.5) var surface_warp_world_size: float = 46.0:
	set(value):
		var validated_value := clampf(value, 2.0, 300.0)
		if is_equal_approx(surface_warp_world_size, validated_value):
			return
		surface_warp_world_size = validated_value
		_request_visual_shader_update()
@export_range(0.0, 12.0, 0.05) var surface_warp_strength: float = 2.4:
	set(value):
		var validated_value := clampf(value, 0.0, 12.0)
		if is_equal_approx(surface_warp_strength, validated_value):
			return
		surface_warp_strength = validated_value
		_request_visual_shader_update()
@export var surface_warp_direction: Vector2 = Vector2(0.31, -0.95):
	set(value):
		surface_warp_direction = value
		_request_visual_shader_update()
@export_range(-1.0, 1.0, 0.005) var surface_warp_speed: float = 0.055:
	set(value):
		var validated_value := clampf(value, -1.0, 1.0)
		if is_equal_approx(surface_warp_speed, validated_value):
			return
		surface_warp_speed = validated_value
		_request_visual_shader_update()
@export_range(2.0, 120.0, 0.5) var surface_stochastic_cell_size: float = 26.0:
	set(value):
		var validated_value := clampf(value, 2.0, 120.0)
		if is_equal_approx(surface_stochastic_cell_size, validated_value):
			return
		surface_stochastic_cell_size = validated_value
		_request_visual_shader_update()
@export_range(0.0, 1.0, 0.01) var surface_stochastic_rotation: float = 0.90:
	set(value):
		var validated_value := clampf(value, 0.0, 1.0)
		if is_equal_approx(surface_stochastic_rotation, validated_value):
			return
		surface_stochastic_rotation = validated_value
		_request_visual_shader_update()
@export_range(0.0, 1000.0, 1.0) var surface_detail_fade_start: float = 150.0:
	set(value):
		var validated_value := clampf(value, 0.0, 1000.0)
		if is_equal_approx(surface_detail_fade_start, validated_value):
			return
		surface_detail_fade_start = validated_value
		_request_visual_shader_update()
@export_range(1.0, 2000.0, 1.0) var surface_detail_fade_end: float = 620.0:
	set(value):
		var validated_value := clampf(value, 1.0, 2000.0)
		if is_equal_approx(surface_detail_fade_end, validated_value):
			return
		surface_detail_fade_end = validated_value
		_request_visual_shader_update()
@export_range(0.0, 0.35, 0.005) var surface_roughness_variation: float = 0.075:
	set(value):
		var validated_value := clampf(value, 0.0, 0.35)
		if is_equal_approx(surface_roughness_variation, validated_value):
			return
		surface_roughness_variation = validated_value
		_request_visual_shader_update()
@export_range(0.0, 2.0, 0.01) var surface_refraction_detail_strength: float = 1.0:
	set(value):
		var validated_value := clampf(value, 0.0, 2.0)
		if is_equal_approx(surface_refraction_detail_strength, validated_value):
			return
		surface_refraction_detail_strength = validated_value
		_request_visual_shader_update()

@export_subgroup("Height Color")
@export var wave_height_color_enabled: bool = true:
	set(value):
		if wave_height_color_enabled == value:
			return
		wave_height_color_enabled = value
		_request_visual_shader_update()
@export var wave_trough_color: Color = Color(0.006, 0.050, 0.105, 1.0):
	set(value):
		if wave_trough_color == value:
			return
		wave_trough_color = value
		_request_visual_shader_update()
@export var wave_crest_color: Color = Color(0.090, 0.500, 0.610, 1.0):
	set(value):
		if wave_crest_color == value:
			return
		wave_crest_color = value
		_request_visual_shader_update()
@export_range(0.0, 1.0, 0.01) var wave_height_color_strength: float = 0.24:
	set(value):
		var validated_value := clampf(value, 0.0, 1.0)
		if is_equal_approx(wave_height_color_strength, validated_value):
			return
		wave_height_color_strength = validated_value
		_request_visual_shader_update()
@export_range(0.05, 8.0, 0.05) var wave_height_color_range: float = 1.35:
	set(value):
		var validated_value := clampf(value, 0.05, 8.0)
		if is_equal_approx(wave_height_color_range, validated_value):
			return
		wave_height_color_range = validated_value
		_request_visual_shader_update()
@export_range(-2.0, 2.0, 0.01) var wave_height_color_bias: float = 0.0:
	set(value):
		var validated_value := clampf(value, -2.0, 2.0)
		if is_equal_approx(wave_height_color_bias, validated_value):
			return
		wave_height_color_bias = validated_value
		_request_visual_shader_update()
@export_range(0.0, 1.0, 0.01) var wave_compression_color_strength: float = 0.18:
	set(value):
		var validated_value := clampf(value, 0.0, 1.0)
		if is_equal_approx(wave_compression_color_strength, validated_value):
			return
		wave_compression_color_strength = validated_value
		_request_visual_shader_update()

@export_group("Arcade Water")
@export var arcade_deep_color: Color = Color(0.012, 0.07, 0.10, 1.0):
	set(value):
		if arcade_deep_color == value:
			return
		arcade_deep_color = value
		_request_arcade_shader_update()
@export var arcade_mid_color: Color = Color(0.013623337, 0.19032064, 0.2905303, 1.0):
	set(value):
		if arcade_mid_color == value:
			return
		arcade_mid_color = value
		_request_arcade_shader_update()
@export var arcade_crest_color: Color = Color(0.09803922, 0.47058824, 0.58431375, 1.0):
	set(value):
		if arcade_crest_color == value:
			return
		arcade_crest_color = value
		_request_arcade_shader_update()
@export_range(0.0, 0.12, 0.005) var arcade_color_strength: float = 0.12:
	set(value):
		var validated_value := clampf(value, 0.0, 0.12)
		if is_equal_approx(arcade_color_strength, validated_value):
			return
		arcade_color_strength = validated_value
		_request_arcade_shader_update()
@export_range(0.08, 0.5, 0.01) var calm_roughness: float = 0.10:
	set(value):
		var validated_value := clampf(value, 0.08, 0.5)
		if is_equal_approx(calm_roughness, validated_value):
			return
		calm_roughness = validated_value
		_request_arcade_shader_update()
@export_range(0.08, 0.5, 0.01) var slope_roughness: float = 0.18:
	set(value):
		var validated_value := clampf(value, 0.08, 0.5)
		if is_equal_approx(slope_roughness, validated_value):
			return
		slope_roughness = validated_value
		_request_arcade_shader_update()
# Foam keeps a deliberately broad roughness range for the existing effect.
@export_range(0.08, 1.0, 0.01) var foam_roughness: float = 0.75:
	set(value):
		var validated_value := clampf(value, 0.08, 1.0)
		if is_equal_approx(foam_roughness, validated_value):
			return
		foam_roughness = validated_value
		_request_arcade_shader_update()

@export_group("Legacy Transparent Water")
@export var water_optics_preset: WaterOpticsPreset = WaterOpticsPreset.RACE_BLUE:
	set(value):
		var validated_value := clampi(int(value), 0, WaterOpticsPreset.size() - 1)
		if int(water_optics_preset) == validated_value:
			return
		water_optics_preset = validated_value as WaterOpticsPreset
		_request_optics_shader_update()
@export var water_optics_debug_mode: WaterOpticsDebugMode = WaterOpticsDebugMode.FINAL:
	set(value):
		var validated_value := clampi(int(value), 0, WaterOpticsDebugMode.size() - 1)
		if int(water_optics_debug_mode) == validated_value:
			return
		water_optics_debug_mode = validated_value as WaterOpticsDebugMode
		_request_optics_shader_update()

@export_group("Legacy Transparent Water/Custom Color")
@export var custom_shallow_color: Color = Color(0.055, 0.42, 0.56, 1.0):
	set(value):
		if custom_shallow_color == value:
			return
		custom_shallow_color = value
		_request_optics_shader_update()
@export var custom_deep_color: Color = Color(0.012, 0.085, 0.15, 1.0):
	set(value):
		if custom_deep_color == value:
			return
		custom_deep_color = value
		_request_optics_shader_update()
@export var custom_horizon_color: Color = Color(0.12, 0.46, 0.62, 1.0):
	set(value):
		if custom_horizon_color == value:
			return
		custom_horizon_color = value
		_request_optics_shader_update()
@export var custom_reflection_tint: Color = Color(0.62, 0.82, 0.96, 1.0):
	set(value):
		if custom_reflection_tint == value:
			return
		custom_reflection_tint = value
		_request_optics_shader_update()

@export_group("Legacy Transparent Water/Custom Absorption")
@export_range(0.01, 1.0, 0.01) var custom_absorption_density: float = 0.18:
	set(value):
		var validated_value := clampf(value, 0.01, 1.0)
		if is_equal_approx(custom_absorption_density, validated_value):
			return
		custom_absorption_density = validated_value
		_request_optics_shader_update()
@export_range(1.0, 100.0, 0.5) var custom_maximum_optical_depth: float = 25.0:
	set(value):
		var validated_value := clampf(value, 1.0, 100.0)
		if is_equal_approx(custom_maximum_optical_depth, validated_value):
			return
		custom_maximum_optical_depth = validated_value
		_request_optics_shader_update()
@export_range(0.5, 20.0, 0.25) var custom_shallow_depth_range: float = 5.0:
	set(value):
		var validated_value := clampf(value, 0.5, 20.0)
		if is_equal_approx(custom_shallow_depth_range, validated_value):
			return
		custom_shallow_depth_range = validated_value
		_request_optics_shader_update()

@export_group("Legacy Transparent Water/Custom Alpha")
@export_range(0.55, 1.0, 0.01) var custom_near_alpha: float = 0.84:
	set(value):
		var validated_value := clampf(value, 0.55, 1.0)
		if is_equal_approx(custom_near_alpha, validated_value):
			return
		custom_near_alpha = validated_value
		_request_optics_shader_update()
@export_range(0.70, 1.0, 0.01) var custom_deep_alpha: float = 0.98:
	set(value):
		var validated_value := clampf(value, 0.70, 1.0)
		if is_equal_approx(custom_deep_alpha, validated_value):
			return
		custom_deep_alpha = validated_value
		_request_optics_shader_update()
@export_range(0.90, 1.0, 0.01) var custom_horizon_alpha: float = 1.0:
	set(value):
		var validated_value := clampf(value, 0.90, 1.0)
		if is_equal_approx(custom_horizon_alpha, validated_value):
			return
		custom_horizon_alpha = validated_value
		_request_optics_shader_update()
@export_range(0.0, 200.0, 1.0) var custom_opacity_distance_start: float = 10.0:
	set(value):
		var validated_value := clampf(value, 0.0, 200.0)
		if is_equal_approx(custom_opacity_distance_start, validated_value):
			return
		custom_opacity_distance_start = validated_value
		if custom_opacity_distance_end <= custom_opacity_distance_start:
			custom_opacity_distance_end = custom_opacity_distance_start + 1.0
		_request_optics_shader_update()
@export_range(1.0, 400.0, 1.0) var custom_opacity_distance_end: float = 45.0:
	set(value):
		var validated_value := clampf(value, 1.0, 400.0)
		validated_value = maxf(validated_value, custom_opacity_distance_start + 1.0)
		if is_equal_approx(custom_opacity_distance_end, validated_value):
			return
		custom_opacity_distance_end = validated_value
		_request_optics_shader_update()

@export_group("Legacy Transparent Water/Custom Reflection")
@export_range(0.5, 10.0, 0.1) var custom_fresnel_power: float = 3.5:
	set(value):
		var validated_value := clampf(value, 0.5, 10.0)
		if is_equal_approx(custom_fresnel_power, validated_value):
			return
		custom_fresnel_power = validated_value
		_request_optics_shader_update()
@export_range(0.0, 1.0, 0.01) var custom_fresnel_opacity_strength: float = 0.95:
	set(value):
		var validated_value := clampf(value, 0.0, 1.0)
		if is_equal_approx(custom_fresnel_opacity_strength, validated_value):
			return
		custom_fresnel_opacity_strength = validated_value
		_request_optics_shader_update()
@export_range(0.0, 1.0, 0.01) var custom_reflection_strength: float = 0.72:
	set(value):
		var validated_value := clampf(value, 0.0, 1.0)
		if is_equal_approx(custom_reflection_strength, validated_value):
			return
		custom_reflection_strength = validated_value
		_request_optics_shader_update()
@export_range(0.0, 1.0, 0.01) var custom_water_specular: float = 0.85:
	set(value):
		var validated_value := clampf(value, 0.0, 1.0)
		if is_equal_approx(custom_water_specular, validated_value):
			return
		custom_water_specular = validated_value
		_request_optics_shader_update()
@export_range(0.02, 0.8, 0.01) var custom_near_roughness: float = 0.12:
	set(value):
		var validated_value := clampf(value, 0.02, 0.8)
		if is_equal_approx(custom_near_roughness, validated_value):
			return
		custom_near_roughness = validated_value
		_request_optics_shader_update()
@export_range(0.02, 0.8, 0.01) var custom_horizon_roughness: float = 0.22:
	set(value):
		var validated_value := clampf(value, 0.02, 0.8)
		if is_equal_approx(custom_horizon_roughness, validated_value):
			return
		custom_horizon_roughness = validated_value
		_request_optics_shader_update()

@export_group("Legacy Transparent Water/Custom Refraction")
@export_range(0.0, 0.04, 0.0005) var custom_refraction_strength: float = 0.008:
	set(value):
		var validated_value := clampf(value, 0.0, 0.04)
		if is_equal_approx(custom_refraction_strength, validated_value):
			return
		custom_refraction_strength = validated_value
		_request_optics_shader_update()
@export_range(0.1, 20.0, 0.1) var custom_refraction_depth_range: float = 4.5:
	set(value):
		var validated_value := clampf(value, 0.1, 20.0)
		if is_equal_approx(custom_refraction_depth_range, validated_value):
			return
		custom_refraction_depth_range = validated_value
		_request_optics_shader_update()
@export_range(0.0, 1.0, 0.01) var custom_refraction_distance_fade: float = 0.90:
	set(value):
		var validated_value := clampf(value, 0.0, 1.0)
		if is_equal_approx(custom_refraction_distance_fade, validated_value):
			return
		custom_refraction_distance_fade = validated_value
		_request_optics_shader_update()
@export_range(0.0, 1.0, 0.01) var custom_refraction_fresnel_fade: float = 0.85:
	set(value):
		var validated_value := clampf(value, 0.0, 1.0)
		if is_equal_approx(custom_refraction_fresnel_fade, validated_value):
			return
		custom_refraction_fresnel_fade = validated_value
		_request_optics_shader_update()

@export_group("Legacy Transparent Water/Custom Crest Light")
@export_range(0.0, 1.0, 0.01) var custom_crest_scattering_strength: float = 0.18:
	set(value):
		var validated_value := clampf(value, 0.0, 1.0)
		if is_equal_approx(custom_crest_scattering_strength, validated_value):
			return
		custom_crest_scattering_strength = validated_value
		_request_optics_shader_update()
@export_range(0.5, 8.0, 0.1) var custom_crest_scattering_power: float = 2.2:
	set(value):
		var validated_value := clampf(value, 0.5, 8.0)
		if is_equal_approx(custom_crest_scattering_power, validated_value):
			return
		custom_crest_scattering_power = validated_value
		_request_optics_shader_update()
@export var custom_crest_scattering_color: Color = Color(0.38, 0.82, 0.88, 1.0):
	set(value):
		if custom_crest_scattering_color == value:
			return
		custom_crest_scattering_color = value
		_request_optics_shader_update()

@export_group("Ocean Mesh")
@export var follow_target: Node3D
@export_node_path("Node3D") var follow_target_path: NodePath
@export var mesh_size: Vector2 = Vector2(512.0, 512.0)
@export_range(1, 512, 1) var mesh_subdivisions: int = 511

var _simulation_time: float = 0.0
var _profile_signature: int = -1
var _logical_origin_x: float = 0.0
var _logical_origin_z: float = 0.0
var _water_rebase_count: int = 0
var _effective_shallow_color: Color = Color(0.055, 0.42, 0.56, 1.0)
var _effective_deep_color: Color = Color(0.012, 0.085, 0.15, 1.0)
var _effective_horizon_color: Color = Color(0.12, 0.46, 0.62, 1.0)
var _effective_reflection_tint: Color = Color(0.62, 0.82, 0.96, 1.0)
var _effective_absorption_density: float = 0.18
var _effective_maximum_optical_depth: float = 25.0
var _effective_shallow_depth_range: float = 5.0
var _effective_near_alpha_value: float = 0.84
var _effective_deep_alpha_value: float = 0.98
var _effective_horizon_alpha_value: float = 1.0
var _effective_opacity_distance_start_value: float = 10.0
var _effective_opacity_distance_end_value: float = 45.0
var _effective_fresnel_power_value: float = 3.5
var _effective_fresnel_opacity_strength: float = 0.95
var _effective_reflection_strength_value: float = 0.72
var _effective_water_specular: float = 0.85
var _effective_near_roughness_value: float = 0.12
var _effective_horizon_roughness_value: float = 0.22
var _effective_refraction_strength_value: float = 0.008
var _effective_refraction_depth_range: float = 4.5
var _effective_refraction_distance_fade: float = 0.90
var _effective_refraction_fresnel_fade: float = 0.85
var _effective_crest_scattering_strength_value: float = 0.18
var _effective_crest_scattering_power: float = 2.2
var _effective_crest_scattering_color: Color = Color(0.38, 0.82, 0.88, 1.0)
var _optics_uniform_update_count_value: int = 0
var _wave_rebuild_queued: bool = false
var _active_wave_count: int = BASE_WAVE_COMPONENTS
var _reference_spectrum_energy: float = 0.0
var _generated_spectrum_energy: float = 0.0
var _spectrum_energy_error: float = 0.0
var _maximum_component_energy_ratio: float = 0.0
var _spectrum_rebuild_count: int = 0
var _last_spectrum_rebuild_duration_ms: float = 0.0
var _maximum_effective_crest_shape: float = 0.0
var _average_effective_crest_shape: float = 0.0
var _harmonic_energy_error: float = 0.0
var _local_transparency_target: Node3D
var _local_transparency_center_xz: Vector2 = Vector2.ZERO
var _local_transparency_follow_error_value: float = INF
var _local_transparency_update_count_value: int = 0
var _applying_local_transparency_constraints: bool = false
var _wave_set_controller := WaveSetController.new()
var _wave_set_shader_revision: int = -1
var _foam_settings_signature: int = -1
var _dominant_wave_direction: Vector2 = Vector2.RIGHT
var _wave_set_target_warning_emitted: bool = false
var _constructive_interference_metric_max_value: float = 0.0
var _tracked_jump_set_slot: int = -1
var _tracked_jump_set_category: StringName = &"NONE"
var _tracked_jump_set_peak_height: float = 0.0
var _wave_set_target_was_airborne: bool = false
var _last_jump_set_category_value: StringName = &"NONE"
var _last_jump_set_peak_height_value: float = 0.0

# These packed arrays are the canonical wave state used by CPU sampling. In
# phase 2, the same arrays are passed directly to the water shader.
var _wave_directions: PackedVector2Array = PackedVector2Array()
var _wave_amplitudes: PackedFloat32Array = PackedFloat32Array()
var _wave_wavelengths: PackedFloat32Array = PackedFloat32Array()
var _wave_base_speeds: PackedFloat32Array = PackedFloat32Array()
var _wave_effective_speeds: PackedFloat32Array = PackedFloat32Array()
var _wave_numbers: PackedFloat32Array = PackedFloat32Array()
var _wave_angular_frequencies: PackedFloat32Array = PackedFloat32Array()
var _wave_base_phases: PackedFloat32Array = PackedFloat32Array()
var _wave_temporal_phase_offsets: PackedFloat32Array = PackedFloat32Array()
var _wave_effective_phases: PackedFloat32Array = PackedFloat32Array()
var _wave_crest_shapes: PackedFloat32Array = PackedFloat32Array()
var _wave_crest_normalizations: PackedFloat32Array = PackedFloat32Array()
var _wave_horizontal_amplitudes: PackedFloat32Array = PackedFloat32Array()
var _wave_families: PackedInt32Array = PackedInt32Array()
var _wave_phase_warp_weights: PackedFloat32Array = PackedFloat32Array()
var _wave_group_weights: PackedFloat32Array = PackedFloat32Array()
var _wave_group_phase_offsets: PackedFloat32Array = PackedFloat32Array()
var _natural_variation_active: bool = false
var _effective_phase_warp_strength: float = 0.0
var _effective_wave_group_strength: float = 0.0
var _modulation_directions: PackedVector2Array = PackedVector2Array()
var _modulation_wavelengths: PackedFloat32Array = PackedFloat32Array()
var _modulation_base_speeds: PackedFloat32Array = PackedFloat32Array()
var _modulation_speeds: PackedFloat32Array = PackedFloat32Array()
var _modulation_wave_numbers: PackedFloat32Array = PackedFloat32Array()
var _modulation_angular_frequencies: PackedFloat32Array = PackedFloat32Array()
var _modulation_base_phases: PackedFloat32Array = PackedFloat32Array()
var _modulation_temporal_phase_offsets: PackedFloat32Array = PackedFloat32Array()
var _modulation_effective_phases: PackedFloat32Array = PackedFloat32Array()

@onready var _ocean_mesh: MeshInstance3D = get_node_or_null("OceanMesh") as MeshInstance3D
@onready var _local_transparent_patch: LocalTransparentWaterPatch = (
	get_node_or_null("LocalTransparentPatch") as LocalTransparentWaterPatch
)
var _shader_material: ShaderMaterial
var _normal_local_transparency_material: ShaderMaterial
var _external_water_materials: Array[ShaderMaterial] = []

var effective_wave_phase_offsets: PackedFloat32Array:
	get:
		_sync_wave_cache_if_needed()
		return _wave_effective_phases.duplicate()

var wave_spectrum_mode_name: StringName:
	get:
		return StringName(WaveSpectrumMode.keys()[int(wave_spectrum_mode)])

var active_wave_count: int:
	get:
		_sync_wave_cache_if_needed()
		return _active_wave_count

var spectrum_seed: int:
	get:
		return spectrum_settings.spectrum_seed if spectrum_settings != null else 0

var reference_spectrum_energy: float:
	get:
		_sync_wave_cache_if_needed()
		return _reference_spectrum_energy

var generated_spectrum_energy: float:
	get:
		_sync_wave_cache_if_needed()
		return _generated_spectrum_energy

var spectrum_energy_error: float:
	get:
		_sync_wave_cache_if_needed()
		return _spectrum_energy_error

var maximum_component_energy_ratio: float:
	get:
		_sync_wave_cache_if_needed()
		return _maximum_component_energy_ratio

var spectrum_rebuild_count: int:
	get:
		return _spectrum_rebuild_count

var last_spectrum_rebuild_duration_ms: float:
	get:
		return _last_spectrum_rebuild_duration_ms

var wave_intensity_name: StringName:
	get:
		return _get_wave_intensity_name()

var wave_intensity_multiplier: float:
	get:
		return _get_wave_intensity_multiplier()

var effective_wave_amplitudes: PackedFloat32Array:
	get:
		_sync_wave_cache_if_needed()
		return _wave_amplitudes.duplicate()

var effective_wave_speeds: PackedFloat32Array:
	get:
		_sync_wave_cache_if_needed()
		return _wave_effective_speeds.duplicate()

var effective_wave_wavelengths: PackedFloat32Array:
	get:
		_sync_wave_cache_if_needed()
		return _wave_wavelengths.duplicate()

var effective_wave_directions_degrees: PackedFloat32Array:
	get:
		_sync_wave_cache_if_needed()
		var angles := PackedFloat32Array()
		angles.resize(MAX_WAVE_COMPONENTS)
		for index in MAX_WAVE_COMPONENTS:
			angles[index] = rad_to_deg(_wave_directions[index].angle())
		return angles

var effective_wave_angular_frequencies: PackedFloat32Array:
	get:
		_sync_wave_cache_if_needed()
		return _wave_angular_frequencies.duplicate()

var effective_wave_phases: PackedFloat32Array:
	get:
		_sync_wave_cache_if_needed()
		return _wave_effective_phases.duplicate()

var crest_shape_enabled: bool:
	get:
		return spectrum_settings.crest_shape_enabled if spectrum_settings != null else false

var maximum_effective_crest_shape: float:
	get:
		_sync_wave_cache_if_needed()
		return _maximum_effective_crest_shape

var average_effective_crest_shape: float:
	get:
		_sync_wave_cache_if_needed()
		return _average_effective_crest_shape

var harmonic_energy_error: float:
	get:
		_sync_wave_cache_if_needed()
		return _harmonic_energy_error

var effective_wave_crest_shapes: PackedFloat32Array:
	get:
		_sync_wave_cache_if_needed()
		return _wave_crest_shapes.duplicate()

var effective_wave_crest_normalizations: PackedFloat32Array:
	get:
		_sync_wave_cache_if_needed()
		return _wave_crest_normalizations.duplicate()

var effective_wave_horizontal_amplitudes: PackedFloat32Array:
	get:
		_sync_wave_cache_if_needed()
		return _wave_horizontal_amplitudes.duplicate()

var effective_wave_families: PackedInt32Array:
	get:
		_sync_wave_cache_if_needed()
		return _wave_families.duplicate()

var natural_variation_active: bool:
	get:
		_sync_wave_cache_if_needed()
		return _natural_variation_active

var effective_phase_warp_strength: float:
	get:
		_sync_wave_cache_if_needed()
		return _effective_phase_warp_strength

var effective_wave_group_strength: float:
	get:
		_sync_wave_cache_if_needed()
		return _effective_wave_group_strength

var modulation_directions: PackedVector2Array:
	get:
		_sync_wave_cache_if_needed()
		return _modulation_directions.duplicate()

var modulation_wavelengths: PackedFloat32Array:
	get:
		_sync_wave_cache_if_needed()
		return _modulation_wavelengths.duplicate()

var modulation_speeds: PackedFloat32Array:
	get:
		_sync_wave_cache_if_needed()
		return _modulation_speeds.duplicate()

var modulation_phases: PackedFloat32Array:
	get:
		_sync_wave_cache_if_needed()
		return _modulation_effective_phases.duplicate()

var effective_wave_phase_warp_weights: PackedFloat32Array:
	get:
		_sync_wave_cache_if_needed()
		return _wave_phase_warp_weights.duplicate()

var effective_wave_group_weights: PackedFloat32Array:
	get:
		_sync_wave_cache_if_needed()
		return _wave_group_weights.duplicate()

var effective_wave_group_phase_offsets: PackedFloat32Array:
	get:
		_sync_wave_cache_if_needed()
		return _wave_group_phase_offsets.duplicate()

var water_rebase_count: int:
	get:
		return _water_rebase_count

var wave_sets_enabled: bool:
	get:
		return (
			wave_set_mode != WaveSetMode.OFF
			and wave_set_settings != null
			and wave_set_settings.enabled
		)

var active_wave_set_count: int:
	get:
		return _wave_set_controller.active_set_count()

var next_wave_set_time: float:
	get:
		return _wave_set_controller.next_wave_set_time

var last_wave_set_strength_category: StringName:
	get:
		var category := clampi(
			_wave_set_controller.last_wave_set_strength_category,
			0,
			WaveSetController.StrengthCategory.size() - 1
		)
		return StringName(WaveSetController.StrengthCategory.keys()[category])

var wave_set_frequency_preset_name: StringName:
	get:
		return (
			wave_set_settings.frequency_preset_name()
			if wave_set_settings != null
			else &"NONE"
		)

var effective_wave_set_interval: Vector2:
	get:
		return (
			wave_set_settings.ordered_interval()
			if wave_set_settings != null
			else Vector2.ZERO
		)

var active_wave_set_category: StringName:
	get:
		var slot := _wave_set_controller.primary_active_slot(_simulation_time)
		if slot < 0:
			return &"NONE"
		return StringName(
			WaveSetController.StrengthCategory.keys()[
				_wave_set_controller.strength_categories[slot]
			]
		)

var active_wave_set_focus_distance: float:
	get:
		var slot := _wave_set_controller.primary_active_slot(_simulation_time)
		if slot < 0:
			return 0.0
		var target_state := _wave_set_target_state()
		return _wave_set_controller.focus_positions_logical[slot].distance_to(
			target_state[0] as Vector2
		)

var active_wave_set_time_to_focus: float:
	get:
		var slot := _wave_set_controller.primary_active_slot(_simulation_time)
		return (
			_wave_set_controller.focus_times[slot] - _simulation_time
			if slot >= 0
			else 0.0
		)

var active_wave_set_expected_peak_height: float:
	get:
		var slot := _wave_set_controller.primary_active_slot(_simulation_time)
		return (
			_wave_set_controller.predicted_maximum_heights[slot]
			if slot >= 0
			else 0.0
		)

var active_wave_set_predicted_maximum_slope: float:
	get:
		var slot := _wave_set_controller.primary_active_slot(_simulation_time)
		return (
			_wave_set_controller.predicted_maximum_slopes[slot]
			if slot >= 0
			else 0.0
		)

var active_wave_set_current_peak_contribution: float:
	get:
		var slot := _wave_set_controller.primary_active_slot(_simulation_time)
		return (
			_wave_set_controller.current_peak_contributions[slot]
			if slot >= 0
			else 0.0
		)

var approach_foam_factor: float:
	get:
		var slot := _wave_set_controller.primary_active_slot(_simulation_time)
		return (
			_wave_set_controller.approach_foam_factors[slot]
			if slot >= 0
			else 0.0
		)

var last_jump_set_category: StringName:
	get:
		return _last_jump_set_category_value

var last_jump_set_peak_height: float:
	get:
		return _last_jump_set_peak_height_value

var active_set_focus_positions: PackedVector2Array:
	get:
		return _wave_set_controller.focus_positions_logical.duplicate()

var active_set_focus_times: PackedFloat32Array:
	get:
		return _wave_set_controller.focus_times.duplicate()

var active_set_amplitudes: PackedFloat32Array:
	get:
		return _wave_set_controller.total_amplitudes.duplicate()

var active_set_wavelengths: PackedFloat32Array:
	get:
		return _wave_set_controller.base_wavelengths.duplicate()

var maximum_packet_height_contribution: float:
	get:
		return _wave_set_controller.maximum_packet_height_contribution

var maximum_breaking_metric: float:
	get:
		return _wave_set_controller.maximum_breaking_metric

var constructive_interference_metric_max: float:
	get:
		return _constructive_interference_metric_max_value

var crest_foam_maximum: float:
	get:
		if foam_settings == null or not foam_settings.foam_enabled:
			return 0.0
		var base_component := (
			_constructive_interference_metric_max_value
			* foam_settings.base_ocean_foam_amount * 0.55
		)
		var reinforced_component := maxf(
			_constructive_interference_metric_max_value,
			maximum_breaking_metric * 0.24
		) * foam_settings.wave_set_foam_amount
		return clampf(
			(base_component + reinforced_component) * foam_settings.foam_amount,
			0.0,
			1.0
		)

var crest_foam_average: float:
	get:
		return crest_foam_maximum * 0.35

var water_render_mode_name: StringName:
	get:
		return StringName(WaterRenderMode.keys()[int(water_render_mode)])

var opaque_water_material_valid: bool:
	get:
		return (
			_is_shader_material_valid(opaque_water_material)
			and opaque_water_material != legacy_water_material
		)

var legacy_water_material_valid: bool:
	get:
		return (
			_is_shader_material_valid(legacy_water_material)
			and legacy_water_material != opaque_water_material
		)

var water_mesh_subdivisions: int:
	get:
		return mesh_subdivisions

var ssr_enabled: bool:
	get:
		if not is_inside_tree():
			return false
		var world := get_world_3d()
		return (
			world != null
			and world.environment != null
			and world.environment.ssr_enabled
		)

var effective_arcade_roughness: float:
	get:
		return calm_roughness

var effective_clearcoat: float:
	get:
		return ARCADE_CLEARCOAT

var effective_clearcoat_gloss: float:
	get:
		return ARCADE_CLEARCOAT_GLOSS

var local_transparency_center: Vector2:
	get:
		return _local_transparency_center_xz

var local_transparency_grid_spacing: float:
	get:
		return local_transparency_patch_size / float(local_transparency_subdivisions + 1)

var local_transparency_material_valid: bool:
	get:
		return (
			_local_transparent_patch != null
			and _local_transparent_patch.material_valid
		)

var local_transparency_follow_error: float:
	get:
		return _local_transparency_follow_error_value

var local_transparency_update_count: int:
	get:
		return _local_transparency_update_count_value

# Observational optics state. Presets resolve into these internal values without
# overwriting the Inspector's CUSTOM controls.
var water_optics_preset_name: StringName:
	get:
		return StringName(WaterOpticsPreset.keys()[int(water_optics_preset)])

var effective_near_alpha: float:
	get:
		return _effective_near_alpha_value

var effective_deep_alpha: float:
	get:
		return _effective_deep_alpha_value

var effective_horizon_alpha: float:
	get:
		return _effective_horizon_alpha_value

var effective_absorption_density: float:
	get:
		return _effective_absorption_density

var effective_opacity_distance_start: float:
	get:
		return _effective_opacity_distance_start_value

var effective_opacity_distance_end: float:
	get:
		return _effective_opacity_distance_end_value

var effective_fresnel_power: float:
	get:
		return _effective_fresnel_power_value

var effective_reflection_strength: float:
	get:
		return _effective_reflection_strength_value

var effective_refraction_strength: float:
	get:
		return _effective_refraction_strength_value

var effective_near_roughness: float:
	get:
		return _effective_near_roughness_value

var effective_horizon_roughness: float:
	get:
		return _effective_horizon_roughness_value

var effective_crest_scattering_strength: float:
	get:
		return _effective_crest_scattering_strength_value

var optics_uniform_update_count: int:
	get:
		return _optics_uniform_update_count_value

# Compatibility aliases keep the accepted diagnostic scene parseable. They
# route old CUSTOM writes into the new manual controls; runtime shader state is
# still resolved exclusively by the new optics preset.
var water_appearance_preset: WaterAppearancePreset:
	get:
		match water_optics_preset:
			WaterOpticsPreset.ARCADE_CLEAR:
				return WaterAppearancePreset.CLEAR
			WaterOpticsPreset.RACE_BLUE:
				return WaterAppearancePreset.OCEAN
			WaterOpticsPreset.ROUGH_OCEAN, WaterOpticsPreset.STORM_DENSE:
				return WaterAppearancePreset.DENSE
			_:
				return WaterAppearancePreset.CUSTOM
	set(value):
		match value:
			WaterAppearancePreset.CLEAR:
				water_optics_preset = WaterOpticsPreset.ARCADE_CLEAR
			WaterAppearancePreset.OCEAN:
				water_optics_preset = WaterOpticsPreset.RACE_BLUE
			WaterAppearancePreset.DENSE:
				water_optics_preset = WaterOpticsPreset.ROUGH_OCEAN
			WaterAppearancePreset.CUSTOM:
				water_optics_preset = WaterOpticsPreset.CUSTOM

var shallow_water_color: Color:
	get:
		return _effective_shallow_color
	set(value):
		custom_shallow_color = value

var deep_water_color: Color:
	get:
		return _effective_deep_color
	set(value):
		custom_deep_color = value

var horizon_water_color: Color:
	get:
		return _effective_horizon_color
	set(value):
		custom_horizon_color = value

var absorption_density: float:
	get:
		return _effective_absorption_density
	set(value):
		custom_absorption_density = value

var maximum_optical_depth: float:
	get:
		return _effective_maximum_optical_depth
	set(value):
		custom_maximum_optical_depth = value

var shallow_depth_range: float:
	get:
		return _effective_shallow_depth_range
	set(value):
		custom_shallow_depth_range = value

var near_water_alpha: float:
	get:
		return _effective_near_alpha_value
	set(value):
		custom_near_alpha = value

var deep_water_alpha: float:
	get:
		return _effective_deep_alpha_value
	set(value):
		custom_deep_alpha = value

var horizon_water_alpha: float:
	get:
		return _effective_horizon_alpha_value
	set(value):
		custom_horizon_alpha = value

var opacity_distance_start: float:
	get:
		return _effective_opacity_distance_start_value
	set(value):
		custom_opacity_distance_start = value

var opacity_distance_end: float:
	get:
		return _effective_opacity_distance_end_value
	set(value):
		custom_opacity_distance_end = value

var fresnel_power: float:
	get:
		return _effective_fresnel_power_value
	set(value):
		custom_fresnel_power = value

var fresnel_opacity_strength: float:
	get:
		return _effective_fresnel_opacity_strength
	set(value):
		custom_fresnel_opacity_strength = value

var fresnel_color_strength: float:
	get:
		return _effective_reflection_strength_value
	set(value):
		custom_reflection_strength = value

var refraction_strength: float:
	get:
		return _effective_refraction_strength_value
	set(value):
		custom_refraction_strength = value

var refraction_depth_range: float:
	get:
		return _effective_refraction_depth_range
	set(value):
		custom_refraction_depth_range = value

var refraction_distance_fade: float:
	get:
		return _effective_refraction_distance_fade
	set(value):
		custom_refraction_distance_fade = value

var near_water_roughness: float:
	get:
		return _effective_near_roughness_value
	set(value):
		custom_near_roughness = value

var horizon_water_roughness: float:
	get:
		return _effective_horizon_roughness_value
	set(value):
		custom_horizon_roughness = value

var water_specular: float:
	get:
		return _effective_water_specular
	set(value):
		custom_water_specular = value

var water_roughness: float:
	get:
		return near_water_roughness
	set(value):
		near_water_roughness = value

var surface_alpha: float:
	get:
		return near_water_alpha
	set(value):
		near_water_alpha = value

var deep_alpha: float:
	get:
		return deep_water_alpha
	set(value):
		deep_water_alpha = value


func _ready() -> void:
	process_priority = -100
	process_physics_priority = -100
	_connect_spectrum_settings()
	if follow_target == null and not follow_target_path.is_empty():
		follow_target = get_node_or_null(follow_target_path) as Node3D
	_resolve_local_transparency_target()
	_initialize_wave_arrays()
	_configure_visual_mesh()
	_configure_local_transparency_patch()
	_update_effective_optics_parameters()
	_sync_wave_cache_if_needed()
	_update_wave_set_controller(false)
	_push_runtime_shader_parameters()
	_push_wave_set_shader_parameters(true)
	_push_visual_shader_parameters()
	_push_foam_shader_parameters(true)
	_push_optics_shader_parameters()
	_push_arcade_shader_parameters()
	_push_local_transparency_shader_parameters()
	_follow_target_on_grid(true)
	_update_local_transparency_tracking(true)


func _process(_delta: float) -> void:
	_update_local_transparency_tracking(false)


func _physics_process(delta: float) -> void:
	_sync_wave_cache_if_needed()
	_simulation_time += delta
	_update_wave_set_controller(true)
	_follow_target_on_grid(false)
	_push_runtime_shader_parameters()
	_push_wave_set_shader_parameters(false)
	_push_foam_shader_parameters(false)


func sample_height(world_position: Vector3) -> float:
	_sync_wave_cache_if_needed()
	var state := _sample_surface_state(
		Vector2(world_position.x, world_position.z),
		_simulation_time
	)
	return base_height + state.x


func sample_normal(world_position: Vector3) -> Vector3:
	_sync_wave_cache_if_needed()
	var physical_xz := Vector2(world_position.x, world_position.z)
	var source_xz := _solve_surface_source_xz(physical_xz, _simulation_time)
	var vertical_state := _sample_surface_state_at_source(
		source_xz,
		_simulation_time
	)
	var horizontal_state := _sample_horizontal_state_at_source(
		source_xz,
		_simulation_time
	)
	return _surface_normal_from_states(vertical_state, horizontal_state)


func sample_surface_derivatives(world_position: Vector3) -> Vector2:
	_sync_wave_cache_if_needed()
	var state := _sample_surface_state(
		Vector2(world_position.x, world_position.z),
		_simulation_time
	)
	return Vector2(state.y, state.z)


func sample_water_velocity(world_position: Vector3) -> Vector3:
	_sync_wave_cache_if_needed()
	var physical_xz := Vector2(world_position.x, world_position.z)
	var source_xz := _solve_surface_source_xz(physical_xz, _simulation_time)
	var vertical_state := _sample_surface_state_at_source(
		source_xz,
		_simulation_time
	)
	var horizontal_state := _sample_horizontal_state_at_source(
		source_xz,
		_simulation_time
	)
	return Vector3(
		horizontal_state.basis.y.x,
		vertical_state.w,
		horizontal_state.basis.y.z
	)


func sample_vertical_velocity(world_position: Vector3) -> float:
	return sample_water_velocity(world_position).y

func sample_depth(world_position: Vector3) -> float:
	return sample_height(world_position) - world_position.y


func sample_breaking_metric(world_position: Vector3) -> float:
	var logical_xz := _physical_to_logical_xz(
		Vector2(world_position.x, world_position.z)
	)
	return _wave_set_controller.sample_breaking_metric(logical_xz, _simulation_time)


func sample_constructive_interference_metric(world_position: Vector3) -> float:
	var logical_xz := _physical_to_logical_xz(
		Vector2(world_position.x, world_position.z)
	)
	return _sample_constructive_interference_metric(logical_xz)


func sample_crest_metric(world_position: Vector3) -> float:
	_sync_wave_cache_if_needed()
	var physical_xz := Vector2(world_position.x, world_position.z)
	var center_state := _sample_surface_state(physical_xz, _simulation_time)
	const CURVATURE_SAMPLE_STEP: float = 0.75
	var offset_x := Vector2(CURVATURE_SAMPLE_STEP, 0.0)
	var offset_z := Vector2(0.0, CURVATURE_SAMPLE_STEP)
	var neighbor_height_sum := (
		_sample_surface_state(physical_xz + offset_x, _simulation_time).x
		+ _sample_surface_state(physical_xz - offset_x, _simulation_time).x
		+ _sample_surface_state(physical_xz + offset_z, _simulation_time).x
		+ _sample_surface_state(physical_xz - offset_z, _simulation_time).x
	)
	var crest_curvature := maxf(
		(4.0 * center_state.x - neighbor_height_sum)
			/ (CURVATURE_SAMPLE_STEP * CURVATURE_SAMPLE_STEP),
		0.0
	)
	var slope := Vector2(center_state.y, center_state.z).length()
	var height_factor := smoothstep(0.04, 0.78, center_state.x)
	var slope_factor := smoothstep(0.045, 0.30, slope)
	var curvature_factor := smoothstep(0.004, 0.042, crest_curvature)
	var rise_factor := smoothstep(0.02, 0.58, maxf(center_state.w, 0.0))
	var logical_xz := _physical_to_logical_xz(physical_xz)
	var constructive_factor := _sample_constructive_interference_metric(logical_xz)
	var breaking_factor := _wave_set_controller.sample_breaking_metric(
		logical_xz,
		_simulation_time
	)
	var total_surface_crest := (
		height_factor
		* maxf(slope_factor, curvature_factor)
		* lerpf(0.70, 1.0, rise_factor)
	)
	var raw_crest_metric := maxf(
		breaking_factor,
		total_surface_crest * lerpf(0.72, 1.0, constructive_factor)
	)
	return smoothstep(0.10, 0.82, clampf(raw_crest_metric, 0.0, 1.0))


func sample_crest_direction(world_position: Vector3) -> Vector2:
	var logical_xz := _physical_to_logical_xz(
		Vector2(world_position.x, world_position.z)
	)
	var influence_slot := _wave_set_controller.strongest_influence_slot(
		logical_xz,
		_simulation_time
	)
	if influence_slot >= 0:
		var set_direction := _wave_set_controller.directions[influence_slot]
		if set_direction.length_squared() > 0.000001 and set_direction.is_finite():
			return set_direction.normalized()
	return _dominant_wave_direction


func world_to_logical_xz(world_position: Vector3) -> Vector2:
	return _physical_to_logical_xz(Vector2(world_position.x, world_position.z))


func logical_to_world_xz(logical_xz: Vector2) -> Vector2:
	return logical_xz - Vector2(_logical_origin_x, _logical_origin_z)


func force_test_wave_set(
	strength: int = WaveSetController.StrengthCategory.MEDIUM,
	focus_lead_time: float = 5.0,
	focus_distance: float = 50.0
) -> bool:
	_constructive_interference_metric_max_value = 0.0
	_reset_tracked_jump_set()
	var target_state := _wave_set_target_state()
	var created := _wave_set_controller.force_test_wave_set(
		_simulation_time,
		target_state[0] as Vector2,
		target_state[1] as Vector2,
		_dominant_wave_direction,
		strength,
		focus_lead_time,
		focus_distance
	)
	_push_wave_set_shader_parameters(true)
	return created


func force_debug_wave_set(
	strength: int,
	focus_lead_time: float = 5.0,
	focus_distance: float = 47.5
) -> bool:
	_sync_wave_cache_if_needed()
	_update_wave_set_controller(false)
	var target_state := _wave_set_target_state()
	var created := _wave_set_controller.force_debug_wave_set(
		_simulation_time,
		target_state[0] as Vector2,
		target_state[1] as Vector2,
		_dominant_wave_direction,
		strength,
		focus_lead_time,
		focus_distance
	)
	if created:
		_push_wave_set_shader_parameters(true)
	return created


func _force_gentle_set_from_editor() -> void:
	_force_wave_set_from_editor(WaveSetController.StrengthCategory.GENTLE)


func _force_medium_set_from_editor() -> void:
	_force_wave_set_from_editor(WaveSetController.StrengthCategory.MEDIUM)


func _force_strong_set_from_editor() -> void:
	_force_wave_set_from_editor(WaveSetController.StrengthCategory.STRONG)


func _force_wave_set_from_editor(strength: int) -> void:
	if not is_inside_tree() or not is_node_ready():
		return
	if not force_debug_wave_set(strength, 5.0, 47.5):
		push_warning(
			"WaterBody3D: could not force %s wave set because no descriptor slot is available."
			% WaveSetController.StrengthCategory.keys()[strength]
		)


func clear_wave_sets_for_test(suppress_scheduler: bool = true) -> void:
	_wave_set_controller.clear_active_sets(_simulation_time, suppress_scheduler)
	_constructive_interference_metric_max_value = 0.0
	_reset_tracked_jump_set()
	_push_wave_set_shader_parameters(true)


func get_simulation_time() -> float:
	return _simulation_time


func get_active_water_material() -> ShaderMaterial:
	if _shader_material != null:
		return _shader_material
	return legacy_water_material


func register_external_water_material(material: ShaderMaterial) -> void:
	if not _is_shader_material_valid(material):
		return
	if _external_water_materials.has(material):
		return
	_external_water_materials.append(material)
	_sync_wave_cache_if_needed()
	_update_shared_wave_uniforms(material)
	_push_runtime_shader_parameters()
	_push_wave_set_shader_parameters(true)
	_push_visual_shader_parameters()
	_push_foam_shader_parameters(true)
	_push_optics_shader_parameters()
	_push_arcade_shader_parameters()
	_push_local_transparency_shader_parameters()


func unregister_external_water_material(material: ShaderMaterial) -> void:
	_external_water_materials.erase(material)


func get_logical_origin_offset_xz() -> Vector2:
	return Vector2(_logical_origin_x, _logical_origin_z)


func apply_world_rebase(
	shift: Vector3,
	logical_origin_x: float,
	logical_origin_z: float
) -> void:
	var horizontal_shift := Vector3(shift.x, 0.0, shift.z)
	if (
		horizontal_shift.is_zero_approx()
		or not horizontal_shift.is_finite()
		or not is_finite(logical_origin_x)
		or not is_finite(logical_origin_z)
	):
		return
	_logical_origin_x = logical_origin_x
	_logical_origin_z = logical_origin_z
	_profile_signature = _calculate_profile_signature()
	_rebuild_wave_cache()
	_push_wave_shader_parameters()
	_push_wave_set_shader_parameters(true)
	_push_foam_shader_parameters(true)
	_push_runtime_shader_parameters()
	if _ocean_mesh != null:
		_ocean_mesh.global_position -= horizontal_shift
		_ocean_mesh.reset_physics_interpolation()
	_local_transparency_center_xz -= Vector2(horizontal_shift.x, horizontal_shift.z)
	if _local_transparent_patch != null:
		_local_transparent_patch.set_center_xz(_local_transparency_center_xz, true)
	_push_local_transparency_center_uniforms()
	_water_rebase_count += 1


func _initialize_wave_arrays() -> void:
	_wave_directions.resize(MAX_WAVE_COMPONENTS)
	_wave_amplitudes.resize(MAX_WAVE_COMPONENTS)
	_wave_wavelengths.resize(MAX_WAVE_COMPONENTS)
	_wave_base_speeds.resize(MAX_WAVE_COMPONENTS)
	_wave_effective_speeds.resize(MAX_WAVE_COMPONENTS)
	_wave_numbers.resize(MAX_WAVE_COMPONENTS)
	_wave_angular_frequencies.resize(MAX_WAVE_COMPONENTS)
	_wave_base_phases.resize(MAX_WAVE_COMPONENTS)
	_wave_temporal_phase_offsets.resize(MAX_WAVE_COMPONENTS)
	_wave_effective_phases.resize(MAX_WAVE_COMPONENTS)
	_wave_crest_shapes.resize(MAX_WAVE_COMPONENTS)
	_wave_crest_normalizations.resize(MAX_WAVE_COMPONENTS)
	_wave_horizontal_amplitudes.resize(MAX_WAVE_COMPONENTS)
	_wave_families.resize(MAX_WAVE_COMPONENTS)
	_wave_phase_warp_weights.resize(MAX_WAVE_COMPONENTS)
	_wave_group_weights.resize(MAX_WAVE_COMPONENTS)
	_wave_group_phase_offsets.resize(MAX_WAVE_COMPONENTS)
	_modulation_directions.resize(2)
	_modulation_wavelengths.resize(2)
	_modulation_base_speeds.resize(2)
	_modulation_speeds.resize(2)
	_modulation_wave_numbers.resize(2)
	_modulation_angular_frequencies.resize(2)
	_modulation_base_phases.resize(2)
	_modulation_temporal_phase_offsets.resize(2)
	_modulation_effective_phases.resize(2)
	for index in MAX_WAVE_COMPONENTS:
		_wave_directions[index] = Vector2.RIGHT
		_wave_amplitudes[index] = 0.0
		_wave_wavelengths[index] = 1.0
		_wave_base_speeds[index] = 0.0
		_wave_effective_speeds[index] = 0.0
		_wave_numbers[index] = 0.0
		_wave_angular_frequencies[index] = 0.0
		_wave_base_phases[index] = 0.0
		_wave_temporal_phase_offsets[index] = 0.0
		_wave_effective_phases[index] = 0.0
		_wave_crest_shapes[index] = 0.0
		_wave_crest_normalizations[index] = 1.0
		_wave_horizontal_amplitudes[index] = 0.0
		_wave_families[index] = WaveSpectrumBuilder.WaveFamily.PRIMARY
		_wave_phase_warp_weights[index] = 0.0
		_wave_group_weights[index] = 0.0
		_wave_group_phase_offsets[index] = 0.0
	for index in 2:
		_modulation_directions[index] = Vector2.RIGHT
		_modulation_wavelengths[index] = 1.0
		_modulation_base_speeds[index] = 0.0
		_modulation_speeds[index] = 0.0
		_modulation_wave_numbers[index] = 0.0
		_modulation_angular_frequencies[index] = 0.0
		_modulation_base_phases[index] = 0.0
		_modulation_temporal_phase_offsets[index] = 0.0
		_modulation_effective_phases[index] = 0.0


func _sync_wave_cache_if_needed() -> bool:
	if _wave_directions.size() != MAX_WAVE_COMPONENTS:
		_initialize_wave_arrays()
	var new_signature := _calculate_profile_signature()
	if new_signature == _profile_signature:
		return false
	_profile_signature = new_signature
	_rebuild_wave_cache()
	_push_wave_shader_parameters()
	return true


func _calculate_profile_signature() -> int:
	var settings_signature: int = (
		spectrum_settings.configuration_signature()
		if spectrum_settings != null
		else 0
	)
	var signature: int = hash([
		17,
		int(wave_intensity),
		wave_speed_multiplier,
		adaptive_crest_shape_enabled,
		crest_shape_strength,
		gerstner_choppiness_enabled,
		gerstner_choppiness_scale,
		gerstner_maximum_total_steepness,
		int(wave_spectrum_mode),
		settings_signature,
	])
	if wave_spectrum_mode != WaveSpectrumMode.CLASSIC_4:
		return signature
	if wave_profile == null or not wave_profile.has_method(&"get_waves"):
		return signature
	for wave in wave_profile.get_waves():
		if wave == null:
			signature = hash([signature, 0])
		else:
			signature = hash([
				signature,
				wave.direction,
				wave.amplitude,
				wave.wavelength,
				wave.speed,
				wave.phase_offset,
			])
	return signature


func _rebuild_wave_cache() -> void:
	var rebuild_started_usec := Time.get_ticks_usec()
	var waves: Array[WaveComponent] = []
	if wave_profile != null and wave_profile.has_method(&"get_waves"):
		waves = wave_profile.get_waves()
	var settings := spectrum_settings
	if settings == null:
		settings = WaveSpectrumSettings.new()
	var block := WaveSpectrumBuilder.build(
		waves,
		int(wave_spectrum_mode),
		settings,
		_get_wave_intensity_multiplier(),
		_get_crest_shape_multiplier(),
		wave_speed_multiplier,
		_wave_temporal_phase_offsets,
		_modulation_temporal_phase_offsets,
		_logical_origin_x,
		_logical_origin_z
	)
	_active_wave_count = int(block["active_wave_count"])
	_wave_directions = block["wave_directions"] as PackedVector2Array
	_wave_amplitudes = block["wave_amplitudes"] as PackedFloat32Array
	_wave_wavelengths = block["wave_wavelengths"] as PackedFloat32Array
	_wave_base_speeds = block["wave_base_speeds"] as PackedFloat32Array
	_wave_effective_speeds = block["wave_effective_speeds"] as PackedFloat32Array
	_wave_numbers = block["wave_numbers"] as PackedFloat32Array
	_wave_angular_frequencies = block["wave_angular_frequencies"] as PackedFloat32Array
	_wave_base_phases = block["wave_base_phases"] as PackedFloat32Array
	_wave_temporal_phase_offsets = (
		block["wave_temporal_phase_offsets"] as PackedFloat32Array
	)
	_wave_effective_phases = block["wave_effective_phases"] as PackedFloat32Array
	_wave_crest_shapes = block["wave_crest_shapes"] as PackedFloat32Array
	_wave_crest_normalizations = (
		block["wave_crest_normalizations"] as PackedFloat32Array
	)
	_wave_families = block["wave_families"] as PackedInt32Array
	_wave_phase_warp_weights = (
		block["wave_phase_warp_weights"] as PackedFloat32Array
	)
	_wave_group_weights = block["wave_group_weights"] as PackedFloat32Array
	_wave_group_phase_offsets = (
		block["wave_group_phase_offsets"] as PackedFloat32Array
	)
	_reference_spectrum_energy = float(block["reference_spectrum_energy"])
	_generated_spectrum_energy = float(block["generated_spectrum_energy"])
	_spectrum_energy_error = float(block["spectrum_energy_error"])
	_maximum_component_energy_ratio = float(
		block["maximum_component_energy_ratio"]
	)
	_natural_variation_active = bool(block["natural_variation_active"])
	_effective_phase_warp_strength = float(
		block["effective_phase_warp_strength"]
	)
	_effective_wave_group_strength = float(
		block["effective_wave_group_strength"]
	)
	_modulation_directions = (
		block["modulation_directions"] as PackedVector2Array
	)
	_modulation_wavelengths = (
		block["modulation_wavelengths"] as PackedFloat32Array
	)
	_modulation_base_speeds = (
		block["modulation_base_speeds"] as PackedFloat32Array
	)
	_modulation_speeds = block["modulation_speeds"] as PackedFloat32Array
	_modulation_wave_numbers = (
		block["modulation_wave_numbers"] as PackedFloat32Array
	)
	_modulation_angular_frequencies = (
		block["modulation_angular_frequencies"] as PackedFloat32Array
	)
	_modulation_base_phases = (
		block["modulation_base_phases"] as PackedFloat32Array
	)
	_modulation_temporal_phase_offsets = (
		block["modulation_temporal_phase_offsets"] as PackedFloat32Array
	)
	_modulation_effective_phases = (
		block["modulation_effective_phases"] as PackedFloat32Array
	)
	_maximum_effective_crest_shape = float(block["maximum_effective_crest_shape"])
	_average_effective_crest_shape = float(block["average_effective_crest_shape"])
	_harmonic_energy_error = float(block["harmonic_energy_error"])
	_rebuild_wave_horizontal_amplitudes()
	_update_dominant_wave_direction()
	_spectrum_rebuild_count += 1
	_last_spectrum_rebuild_duration_ms = (
		float(Time.get_ticks_usec() - rebuild_started_usec) / 1000.0
	)


func _request_wave_block_rebuild() -> void:
	_profile_signature = -1
	if not is_inside_tree() or not is_node_ready():
		return
	if _wave_rebuild_queued:
		return
	_wave_rebuild_queued = true
	call_deferred("_flush_queued_wave_block_rebuild")


func _flush_queued_wave_block_rebuild() -> void:
	_wave_rebuild_queued = false
	if not is_inside_tree() or not is_node_ready():
		return
	_sync_wave_cache_if_needed()
	_push_runtime_shader_parameters()


func _preserve_wave_phase_continuity(
	previous_multiplier: float,
	next_multiplier: float
) -> void:
	if (
		not is_inside_tree()
		or not is_node_ready()
		or wave_profile == null
		or not wave_profile.has_method(&"get_waves")
	):
		return
	_sync_wave_cache_if_needed()
	for index in _active_wave_count:
		if index >= _wave_base_speeds.size():
			continue
		var angular_frequency_delta := (
			_wave_numbers[index]
			* _wave_base_speeds[index]
			* (next_multiplier - previous_multiplier)
		)
		_wave_temporal_phase_offsets[index] = _wrap_phase(
			_wave_temporal_phase_offsets[index]
			+ angular_frequency_delta * _simulation_time
		)
	for index in 2:
		if index >= _modulation_base_speeds.size():
			continue
		var angular_frequency_delta := (
			_modulation_wave_numbers[index]
			* _modulation_base_speeds[index]
			* (next_multiplier - previous_multiplier)
		)
		_modulation_temporal_phase_offsets[index] = _wrap_phase(
			_modulation_temporal_phase_offsets[index]
			+ angular_frequency_delta * _simulation_time
		)


func _connect_spectrum_settings() -> void:
	if (
		spectrum_settings != null
		and not spectrum_settings.changed.is_connected(_on_spectrum_settings_changed)
	):
		spectrum_settings.changed.connect(_on_spectrum_settings_changed)


func _disconnect_spectrum_settings() -> void:
	if (
		spectrum_settings != null
		and spectrum_settings.changed.is_connected(_on_spectrum_settings_changed)
	):
		spectrum_settings.changed.disconnect(_on_spectrum_settings_changed)


func _on_spectrum_settings_changed() -> void:
	_request_wave_block_rebuild()


func _clear_temporal_phase_offsets() -> void:
	if _wave_temporal_phase_offsets.size() != MAX_WAVE_COMPONENTS:
		_wave_temporal_phase_offsets.resize(MAX_WAVE_COMPONENTS)
	for index in MAX_WAVE_COMPONENTS:
		_wave_temporal_phase_offsets[index] = 0.0
	if _modulation_temporal_phase_offsets.size() != 2:
		_modulation_temporal_phase_offsets.resize(2)
	for index in 2:
		_modulation_temporal_phase_offsets[index] = 0.0


func _request_visual_shader_update() -> void:
	if not is_inside_tree() or not is_node_ready():
		return
	_push_visual_shader_parameters()


func _request_water_material_update() -> void:
	if not is_inside_tree() or not is_node_ready():
		return
	_apply_water_render_material()
	_configure_local_transparency_patch()
	_push_wave_shader_parameters()
	_push_runtime_shader_parameters()
	_push_visual_shader_parameters()
	_push_optics_shader_parameters()
	_push_arcade_shader_parameters()
	_push_local_transparency_shader_parameters()


func _request_arcade_shader_update() -> void:
	if not is_inside_tree() or not is_node_ready():
		return
	_push_arcade_shader_parameters()


func _request_local_transparency_update() -> void:
	if _applying_local_transparency_constraints:
		return
	_enforce_local_transparency_constraints()
	if not is_inside_tree() or not is_node_ready():
		return
	_configure_local_transparency_patch()
	_push_local_transparency_shader_parameters()
	_update_local_transparency_tracking(true)


func _enforce_local_transparency_constraints() -> void:
	if _applying_local_transparency_constraints:
		return
	_applying_local_transparency_constraints = true
	local_transparency_core_radius = clampf(
		local_transparency_core_radius,
		1.0,
		20.0
	)
	local_transparency_handoff_radius = clampf(
		maxf(
			local_transparency_handoff_radius,
			local_transparency_core_radius + 0.25
		),
		2.0,
		30.0
	)
	local_transparency_handoff_epsilon = clampf(
		local_transparency_handoff_epsilon,
		0.001,
		0.10
	)
	local_transparency_patch_size = clampf(
		maxf(
			local_transparency_patch_size,
			local_transparency_handoff_radius * 2.0 + 2.0
		),
		16.0,
		128.0
	)
	local_transparency_subdivisions = clampi(
		local_transparency_subdivisions,
		15,
		255
	)
	if local_transparency_subdivisions % 2 == 0:
		local_transparency_subdivisions = mini(
			local_transparency_subdivisions + 1,
			255
		)
	_applying_local_transparency_constraints = false


func _request_optics_shader_update() -> void:
	if not is_inside_tree() or not is_node_ready():
		return
	_update_effective_optics_parameters()
	_push_optics_shader_parameters()


func _update_effective_optics_parameters() -> void:
	_effective_shallow_color = custom_shallow_color
	_effective_deep_color = custom_deep_color
	_effective_horizon_color = custom_horizon_color
	_effective_reflection_tint = custom_reflection_tint
	_effective_absorption_density = custom_absorption_density
	_effective_maximum_optical_depth = custom_maximum_optical_depth
	_effective_shallow_depth_range = custom_shallow_depth_range
	_effective_near_alpha_value = custom_near_alpha
	_effective_deep_alpha_value = custom_deep_alpha
	_effective_horizon_alpha_value = custom_horizon_alpha
	_effective_opacity_distance_start_value = custom_opacity_distance_start
	_effective_opacity_distance_end_value = maxf(
		custom_opacity_distance_end,
		custom_opacity_distance_start + 1.0
	)
	_effective_fresnel_power_value = custom_fresnel_power
	_effective_fresnel_opacity_strength = custom_fresnel_opacity_strength
	_effective_reflection_strength_value = custom_reflection_strength
	_effective_water_specular = custom_water_specular
	_effective_near_roughness_value = custom_near_roughness
	_effective_horizon_roughness_value = custom_horizon_roughness
	_effective_refraction_strength_value = custom_refraction_strength
	_effective_refraction_depth_range = custom_refraction_depth_range
	_effective_refraction_distance_fade = custom_refraction_distance_fade
	_effective_refraction_fresnel_fade = custom_refraction_fresnel_fade
	_effective_crest_scattering_strength_value = custom_crest_scattering_strength
	_effective_crest_scattering_power = custom_crest_scattering_power
	_effective_crest_scattering_color = custom_crest_scattering_color

	match water_optics_preset:
		WaterOpticsPreset.ARCADE_CLEAR:
			_effective_shallow_color = Color(0.08, 0.50, 0.62, 1.0)
			_effective_deep_color = Color(0.015, 0.13, 0.20, 1.0)
			_effective_horizon_color = Color(0.16, 0.52, 0.68, 1.0)
			_effective_absorption_density = 0.11
			_effective_near_alpha_value = 0.76
			_effective_deep_alpha_value = 0.94
			_effective_horizon_alpha_value = 1.0
			_effective_opacity_distance_start_value = 16.0
			_effective_opacity_distance_end_value = 65.0
			_effective_fresnel_power_value = 3.8
			_effective_fresnel_opacity_strength = 0.90
			_effective_reflection_strength_value = 0.68
			_effective_refraction_strength_value = 0.011
			_effective_near_roughness_value = 0.11
			_effective_horizon_roughness_value = 0.20
			_effective_crest_scattering_strength_value = 0.22
		WaterOpticsPreset.RACE_BLUE:
			_effective_shallow_color = Color(0.055, 0.42, 0.56, 1.0)
			_effective_deep_color = Color(0.012, 0.085, 0.15, 1.0)
			_effective_horizon_color = Color(0.12, 0.46, 0.62, 1.0)
			_effective_reflection_tint = Color(0.62, 0.82, 0.96, 1.0)
			_effective_absorption_density = 0.18
			_effective_maximum_optical_depth = 25.0
			_effective_shallow_depth_range = 5.0
			_effective_near_alpha_value = 0.84
			_effective_deep_alpha_value = 0.98
			_effective_horizon_alpha_value = 1.0
			_effective_opacity_distance_start_value = 10.0
			_effective_opacity_distance_end_value = 45.0
			_effective_fresnel_power_value = 3.5
			_effective_fresnel_opacity_strength = 0.95
			_effective_reflection_strength_value = 0.72
			_effective_water_specular = 0.85
			_effective_refraction_strength_value = 0.008
			_effective_refraction_depth_range = 4.5
			_effective_refraction_distance_fade = 0.90
			_effective_refraction_fresnel_fade = 0.85
			_effective_near_roughness_value = 0.12
			_effective_horizon_roughness_value = 0.22
			_effective_crest_scattering_strength_value = 0.18
			_effective_crest_scattering_power = 2.2
		WaterOpticsPreset.ROUGH_OCEAN:
			_effective_shallow_color = Color(0.04, 0.31, 0.43, 1.0)
			_effective_deep_color = Color(0.008, 0.055, 0.11, 1.0)
			_effective_horizon_color = Color(0.08, 0.34, 0.48, 1.0)
			_effective_absorption_density = 0.27
			_effective_near_alpha_value = 0.88
			_effective_deep_alpha_value = 0.99
			_effective_horizon_alpha_value = 1.0
			_effective_opacity_distance_start_value = 7.0
			_effective_opacity_distance_end_value = 34.0
			_effective_fresnel_power_value = 3.2
			_effective_fresnel_opacity_strength = 1.0
			_effective_reflection_strength_value = 0.78
			_effective_refraction_strength_value = 0.006
			_effective_near_roughness_value = 0.15
			_effective_horizon_roughness_value = 0.26
			_effective_crest_scattering_strength_value = 0.14
		WaterOpticsPreset.STORM_DENSE:
			_effective_shallow_color = Color(0.025, 0.20, 0.28, 1.0)
			_effective_deep_color = Color(0.004, 0.025, 0.055, 1.0)
			_effective_horizon_color = Color(0.045, 0.20, 0.29, 1.0)
			_effective_absorption_density = 0.40
			_effective_near_alpha_value = 0.92
			_effective_deep_alpha_value = 1.0
			_effective_horizon_alpha_value = 1.0
			_effective_opacity_distance_start_value = 4.0
			_effective_opacity_distance_end_value = 24.0
			_effective_fresnel_power_value = 2.8
			_effective_fresnel_opacity_strength = 1.0
			_effective_reflection_strength_value = 0.84
			_effective_refraction_strength_value = 0.0035
			_effective_near_roughness_value = 0.19
			_effective_horizon_roughness_value = 0.31
			_effective_crest_scattering_strength_value = 0.08
		WaterOpticsPreset.CUSTOM:
			pass


func _get_wave_intensity_multiplier() -> float:
	match wave_intensity:
		WaveIntensity.VERY_CALM:
			return 0.50
		WaveIntensity.CALM:
			return 0.70
		WaveIntensity.DEFAULT:
			return 1.00
		WaveIntensity.ROUGH:
			return 1.30
		WaveIntensity.STORM:
			return 1.60
		_:
			return 1.00


func _get_wave_intensity_name() -> StringName:
	match wave_intensity:
		WaveIntensity.VERY_CALM:
			return &"VERY_CALM"
		WaveIntensity.CALM:
			return &"CALM"
		WaveIntensity.DEFAULT:
			return &"DEFAULT"
		WaveIntensity.ROUGH:
			return &"ROUGH"
		WaveIntensity.STORM:
			return &"STORM"
		_:
			return &"DEFAULT"


func _get_crest_shape_multiplier() -> float:
	var intensity_factor: float = 1.0
	if adaptive_crest_shape_enabled:
		match wave_intensity:
			WaveIntensity.VERY_CALM:
				intensity_factor = 0.15
			WaveIntensity.CALM:
				intensity_factor = 0.35
			WaveIntensity.DEFAULT:
				intensity_factor = 0.65
			WaveIntensity.ROUGH:
				intensity_factor = 1.00
			WaveIntensity.STORM:
				intensity_factor = 1.20
	return intensity_factor * crest_shape_strength


func _get_gerstner_choppiness() -> float:
	if not gerstner_choppiness_enabled:
		return 0.0
	var intensity_factor: float = 0.0
	match wave_intensity:
		WaveIntensity.VERY_CALM:
			intensity_factor = 0.00
		WaveIntensity.CALM:
			intensity_factor = 0.12
		WaveIntensity.DEFAULT:
			intensity_factor = 0.32
		WaveIntensity.ROUGH:
			intensity_factor = 0.62
		WaveIntensity.STORM:
			intensity_factor = 0.90
	return intensity_factor * gerstner_choppiness_scale


func _rebuild_wave_horizontal_amplitudes() -> void:
	if _wave_horizontal_amplitudes.size() != MAX_WAVE_COMPONENTS:
		_wave_horizontal_amplitudes.resize(MAX_WAVE_COMPONENTS)
	var choppiness := _get_gerstner_choppiness()
	var accumulated_steepness: float = 0.0
	for index in MAX_WAVE_COMPONENTS:
		_wave_horizontal_amplitudes[index] = 0.0
		if index >= _active_wave_count or choppiness <= 0.000001:
			continue
		var group_scale := (
			_effective_wave_group_strength * _wave_group_weights[index]
		)
		var maximum_envelope := _group_normalization(group_scale) * (
			1.0 + absf(group_scale)
		)
		accumulated_steepness += (
			absf(_wave_numbers[index])
			* absf(_wave_amplitudes[index] * choppiness)
			* maximum_envelope
		)
	var safety_scale := 1.0
	if accumulated_steepness > gerstner_maximum_total_steepness:
		safety_scale = (
			gerstner_maximum_total_steepness
			/ maxf(accumulated_steepness, 0.000001)
		)
	for index in _active_wave_count:
		_wave_horizontal_amplitudes[index] = (
			_wave_amplitudes[index] * choppiness * safety_scale
		)


func _solve_surface_source_xz(physical_xz: Vector2, sample_time: float) -> Vector2:
	var source_xz := physical_xz
	for _iteration in gerstner_inverse_iterations:
		var horizontal_state := _sample_horizontal_state_at_source(
			source_xz,
			sample_time
		)
		var displacement := Vector2(
			horizontal_state.origin.x,
			horizontal_state.origin.z
		)
		var next_source_xz := physical_xz - displacement
		if next_source_xz.distance_squared_to(source_xz) <= 0.00000001:
			source_xz = next_source_xz
			break
		source_xz = next_source_xz
	return source_xz


func _surface_normal_from_states(
	vertical_state: Vector4,
	horizontal_state: Transform3D
) -> Vector3:
	var horizontal_derivative_x := Vector2(
		horizontal_state.basis.x.x,
		horizontal_state.basis.x.z
	)
	var horizontal_derivative_z := Vector2(
		horizontal_state.basis.z.x,
		horizontal_state.basis.z.z
	)
	var tangent_x := Vector3(
		1.0 + horizontal_derivative_x.x,
		vertical_state.y,
		horizontal_derivative_x.y
	)
	var tangent_z := Vector3(
		horizontal_derivative_z.x,
		vertical_state.z,
		1.0 + horizontal_derivative_z.y
	)
	var surface_normal := tangent_z.cross(tangent_x).normalized()
	return surface_normal if surface_normal.y >= 0.0 else -surface_normal


func _sample_surface_state(world_xz: Vector2, sample_time: float) -> Vector4:
	var source_xz := _solve_surface_source_xz(world_xz, sample_time)
	var vertical_state := _sample_surface_state_at_source(source_xz, sample_time)
	var horizontal_state := _sample_horizontal_state_at_source(
		source_xz,
		sample_time
	)
	var surface_normal := _surface_normal_from_states(
		vertical_state,
		horizontal_state
	)
	var safe_normal_y := maxf(surface_normal.y, 0.0001)
	return Vector4(
		vertical_state.x,
		-surface_normal.x / safe_normal_y,
		-surface_normal.z / safe_normal_y,
		vertical_state.w
	)


func _sample_horizontal_state_at_source(
	world_xz: Vector2,
	sample_time: float
) -> Transform3D:
	var psi_0: float = 0.0
	var psi_1: float = 0.0
	var sin_psi_0: float = 0.0
	var sin_psi_1: float = 0.0
	var cos_psi_0: float = 0.0
	var cos_psi_1: float = 0.0
	var dpsi_0_dx: float = 0.0
	var dpsi_0_dz: float = 0.0
	var dpsi_0_dt: float = 0.0
	var dpsi_1_dx: float = 0.0
	var dpsi_1_dz: float = 0.0
	var dpsi_1_dt: float = 0.0
	if _natural_variation_active:
		psi_0 = (
			_modulation_wave_numbers[0]
			* _modulation_directions[0].dot(world_xz)
			- _modulation_angular_frequencies[0] * sample_time
			+ _modulation_effective_phases[0]
		)
		psi_1 = (
			_modulation_wave_numbers[1]
			* _modulation_directions[1].dot(world_xz)
			- _modulation_angular_frequencies[1] * sample_time
			+ _modulation_effective_phases[1]
		)
		sin_psi_0 = sin(psi_0)
		sin_psi_1 = sin(psi_1)
		cos_psi_0 = cos(psi_0)
		cos_psi_1 = cos(psi_1)
		dpsi_0_dx = _modulation_wave_numbers[0] * _modulation_directions[0].x
		dpsi_0_dz = _modulation_wave_numbers[0] * _modulation_directions[0].y
		dpsi_0_dt = -_modulation_angular_frequencies[0]
		dpsi_1_dx = _modulation_wave_numbers[1] * _modulation_directions[1].x
		dpsi_1_dz = _modulation_wave_numbers[1] * _modulation_directions[1].y
		dpsi_1_dt = -_modulation_angular_frequencies[1]
	var displacement := Vector2.ZERO
	var derivative_x := Vector2.ZERO
	var derivative_z := Vector2.ZERO
	var horizontal_velocity := Vector2.ZERO
	for index in _active_wave_count:
		var horizontal_amplitude := _wave_horizontal_amplitudes[index]
		if absf(horizontal_amplitude) <= 0.0000001:
			continue
		var direction := _wave_directions[index]
		var theta := (
			_wave_numbers[index] * direction.dot(world_xz)
			- _wave_angular_frequencies[index] * sample_time
			+ _wave_effective_phases[index]
		)
		var phase_warp_scale := (
			_effective_phase_warp_strength * _wave_phase_warp_weights[index]
		)
		var phase_warp := phase_warp_scale * (
			0.62 * sin_psi_0 + 0.38 * sin_psi_1
		)
		var phase_warp_dx := phase_warp_scale * (
			0.62 * cos_psi_0 * dpsi_0_dx
			+ 0.38 * cos_psi_1 * dpsi_1_dx
		)
		var phase_warp_dz := phase_warp_scale * (
			0.62 * cos_psi_0 * dpsi_0_dz
			+ 0.38 * cos_psi_1 * dpsi_1_dz
		)
		var phase_warp_dt := phase_warp_scale * (
			0.62 * cos_psi_0 * dpsi_0_dt
			+ 0.38 * cos_psi_1 * dpsi_1_dt
		)
		var warped_theta := theta + phase_warp
		var warped_theta_dx := _wave_numbers[index] * direction.x + phase_warp_dx
		var warped_theta_dz := _wave_numbers[index] * direction.y + phase_warp_dz
		var warped_theta_dt := -_wave_angular_frequencies[index] + phase_warp_dt
		var group_scale := (
			_effective_wave_group_strength * _wave_group_weights[index]
		)
		var group_offset := _wave_group_phase_offsets[index]
		var group_phase_0 := psi_0 + group_offset
		var group_phase_1 := psi_1 - group_offset * 0.7
		var group_value := group_scale * (
			0.58 * sin(group_phase_0) + 0.42 * sin(group_phase_1)
		)
		var group_value_dx := group_scale * (
			0.58 * cos(group_phase_0) * dpsi_0_dx
			+ 0.42 * cos(group_phase_1) * dpsi_1_dx
		)
		var group_value_dz := group_scale * (
			0.58 * cos(group_phase_0) * dpsi_0_dz
			+ 0.42 * cos(group_phase_1) * dpsi_1_dz
		)
		var group_value_dt := group_scale * (
			0.58 * cos(group_phase_0) * dpsi_0_dt
			+ 0.42 * cos(group_phase_1) * dpsi_1_dt
		)
		var group_normalization := _group_normalization(group_scale)
		var envelope := group_normalization * (1.0 + group_value)
		var envelope_dx := group_normalization * group_value_dx
		var envelope_dz := group_normalization * group_value_dz
		var envelope_dt := group_normalization * group_value_dt
		var cosine_phase := cos(warped_theta)
		var sine_phase := sin(warped_theta)
		displacement += direction * (
			horizontal_amplitude * envelope * cosine_phase
		)
		derivative_x += direction * horizontal_amplitude * (
			envelope_dx * cosine_phase
			- envelope * sine_phase * warped_theta_dx
		)
		derivative_z += direction * horizontal_amplitude * (
			envelope_dz * cosine_phase
			- envelope * sine_phase * warped_theta_dz
		)
		horizontal_velocity += direction * horizontal_amplitude * (
			envelope_dt * cosine_phase
			- envelope * sine_phase * warped_theta_dt
		)
	var encoded_basis := Basis(
		Vector3(derivative_x.x, 0.0, derivative_x.y),
		Vector3(horizontal_velocity.x, 0.0, horizontal_velocity.y),
		Vector3(derivative_z.x, 0.0, derivative_z.y)
	)
	return Transform3D(
		encoded_basis,
		Vector3(displacement.x, 0.0, displacement.y)
	)


func _sample_surface_state_at_source(world_xz: Vector2, sample_time: float) -> Vector4:
	var psi_0: float = 0.0
	var psi_1: float = 0.0
	var sin_psi_0: float = 0.0
	var sin_psi_1: float = 0.0
	var cos_psi_0: float = 0.0
	var cos_psi_1: float = 0.0
	var dpsi_0_dx: float = 0.0
	var dpsi_0_dz: float = 0.0
	var dpsi_0_dt: float = 0.0
	var dpsi_1_dx: float = 0.0
	var dpsi_1_dz: float = 0.0
	var dpsi_1_dt: float = 0.0
	if _natural_variation_active:
		psi_0 = (
			_modulation_wave_numbers[0]
			* _modulation_directions[0].dot(world_xz)
			- _modulation_angular_frequencies[0] * sample_time
			+ _modulation_effective_phases[0]
		)
		psi_1 = (
			_modulation_wave_numbers[1]
			* _modulation_directions[1].dot(world_xz)
			- _modulation_angular_frequencies[1] * sample_time
			+ _modulation_effective_phases[1]
		)
		sin_psi_0 = sin(psi_0)
		sin_psi_1 = sin(psi_1)
		cos_psi_0 = cos(psi_0)
		cos_psi_1 = cos(psi_1)
		dpsi_0_dx = _modulation_wave_numbers[0] * _modulation_directions[0].x
		dpsi_0_dz = _modulation_wave_numbers[0] * _modulation_directions[0].y
		dpsi_0_dt = -_modulation_angular_frequencies[0]
		dpsi_1_dx = _modulation_wave_numbers[1] * _modulation_directions[1].x
		dpsi_1_dz = _modulation_wave_numbers[1] * _modulation_directions[1].y
		dpsi_1_dt = -_modulation_angular_frequencies[1]
	var total_height: float = 0.0
	var total_derivative_x: float = 0.0
	var total_derivative_z: float = 0.0
	var total_vertical_velocity: float = 0.0
	for index in _active_wave_count:
		var theta := (
			_wave_numbers[index] * _wave_directions[index].dot(world_xz)
			- _wave_angular_frequencies[index] * sample_time
			+ _wave_effective_phases[index]
		)
		var phase_weight := _wave_phase_warp_weights[index]
		var phase_warp_scale := _effective_phase_warp_strength * phase_weight
		var phase_warp := phase_warp_scale * (
			0.62 * sin_psi_0 + 0.38 * sin_psi_1
		)
		var phase_warp_dx := phase_warp_scale * (
			0.62 * cos_psi_0 * dpsi_0_dx
			+ 0.38 * cos_psi_1 * dpsi_1_dx
		)
		var phase_warp_dz := phase_warp_scale * (
			0.62 * cos_psi_0 * dpsi_0_dz
			+ 0.38 * cos_psi_1 * dpsi_1_dz
		)
		var phase_warp_dt := phase_warp_scale * (
			0.62 * cos_psi_0 * dpsi_0_dt
			+ 0.38 * cos_psi_1 * dpsi_1_dt
		)
		var warped_theta := theta + phase_warp
		var warped_theta_dx := (
			_wave_numbers[index] * _wave_directions[index].x
			+ phase_warp_dx
		)
		var warped_theta_dz := (
			_wave_numbers[index] * _wave_directions[index].y
			+ phase_warp_dz
		)
		var warped_theta_dt := -_wave_angular_frequencies[index] + phase_warp_dt
		var group_weight := _wave_group_weights[index]
		var group_scale := _effective_wave_group_strength * group_weight
		var group_offset := _wave_group_phase_offsets[index]
		var group_phase_0 := psi_0 + group_offset
		var group_phase_1 := psi_1 - group_offset * 0.7
		var group_value := group_scale * (
			0.58 * sin(group_phase_0) + 0.42 * sin(group_phase_1)
		)
		var group_value_dx := group_scale * (
			0.58 * cos(group_phase_0) * dpsi_0_dx
			+ 0.42 * cos(group_phase_1) * dpsi_1_dx
		)
		var group_value_dz := group_scale * (
			0.58 * cos(group_phase_0) * dpsi_0_dz
			+ 0.42 * cos(group_phase_1) * dpsi_1_dz
		)
		var group_value_dt := group_scale * (
			0.58 * cos(group_phase_0) * dpsi_0_dt
			+ 0.42 * cos(group_phase_1) * dpsi_1_dt
		)
		var group_normalization := _group_normalization(group_scale)
		var envelope := group_normalization * (1.0 + group_value)
		var envelope_dx := group_normalization * group_value_dx
		var envelope_dz := group_normalization * group_value_dz
		var envelope_dt := group_normalization * group_value_dt
		var shape := _sample_wave_shape(index, warped_theta)
		var shape_derivative := _sample_wave_shape_derivative(
			index,
			warped_theta
		)
		var amplitude := _wave_amplitudes[index]
		total_height += amplitude * envelope * shape
		total_derivative_x += amplitude * (
			envelope_dx * shape
			+ envelope * shape_derivative * warped_theta_dx
		)
		total_derivative_z += amplitude * (
			envelope_dz * shape
			+ envelope * shape_derivative * warped_theta_dz
		)
		total_vertical_velocity += amplitude * (
			envelope_dt * shape
			+ envelope * shape_derivative * warped_theta_dt
		)
	var logical_xz := _physical_to_logical_xz(world_xz)
	var wave_set_state := _wave_set_controller.sample_surface_state(
		logical_xz,
		sample_time
	)
	total_height += wave_set_state.x
	total_derivative_x += wave_set_state.y
	total_derivative_z += wave_set_state.z
	total_vertical_velocity += wave_set_state.w
	return Vector4(
		total_height,
		total_derivative_x,
		total_derivative_z,
		total_vertical_velocity
	)


func _physical_to_logical_xz(physical_xz: Vector2) -> Vector2:
	return physical_xz + Vector2(_logical_origin_x, _logical_origin_z)


func _update_dominant_wave_direction() -> void:
	var weighted_direction := Vector2.ZERO
	for index in _active_wave_count:
		var amplitude := _wave_amplitudes[index]
		weighted_direction += _wave_directions[index] * amplitude * amplitude
	if weighted_direction.length_squared() > 0.000001 and weighted_direction.is_finite():
		_dominant_wave_direction = weighted_direction.normalized()
	elif spectrum_settings != null:
		_dominant_wave_direction = Vector2.RIGHT.rotated(
			deg_to_rad(spectrum_settings.primary_direction_degrees)
		)
	else:
		_dominant_wave_direction = Vector2.RIGHT


func _update_wave_set_controller(advance_scheduler: bool) -> void:
	_wave_set_controller.configure(
		int(wave_set_mode),
		wave_set_settings,
		wave_speed_multiplier,
		_simulation_time
	)
	if foam_settings != null:
		_wave_set_controller.configure_breaking_metric(
			foam_settings.breaking_threshold,
			foam_settings.breaking_softness
		)
	if not advance_scheduler:
		return
	var target_state := _wave_set_target_state()
	_wave_set_controller.update(
		_simulation_time,
		target_state[0] as Vector2,
		target_state[1] as Vector2,
		_dominant_wave_direction,
		bool(target_state[2])
	)
	_update_constructive_interference_maximum(target_state[0] as Vector2)
	_update_jump_set_observation(target_state[0] as Vector2)


func _update_jump_set_observation(target_logical_xz: Vector2) -> void:
	# JetSkiController is runtime-only. In editor tool mode Godot exposes the
	# scene node as a bare RigidBody3D, so its script properties are unavailable.
	if Engine.is_editor_hint():
		_wave_set_target_was_airborne = false
		return

	var target := _wave_set_observation_target()
	var vehicle := target as JetSkiController
	if vehicle == null:
		_wave_set_target_was_airborne = false
		return
	var influence_slot := _wave_set_controller.strongest_influence_slot(
		target_logical_xz,
		_simulation_time
	)
	if influence_slot >= 0:
		_tracked_jump_set_slot = influence_slot
		_tracked_jump_set_category = StringName(
			WaveSetController.StrengthCategory.keys()[
				_wave_set_controller.strength_categories[influence_slot]
			]
		)
		_tracked_jump_set_peak_height = maxf(
			_tracked_jump_set_peak_height,
			maxf(
				_wave_set_controller.sample_slot_height(
					influence_slot,
					target_logical_xz,
					_simulation_time
				),
				0.0
			)
		)
	var is_airborne := (
		vehicle.navigation_state == JetSkiController.NavigationState.AIRBORNE
	)
	if is_airborne and not _wave_set_target_was_airborne:
		var jump_slot := _tracked_jump_set_slot
		if jump_slot < 0:
			jump_slot = _wave_set_controller.primary_active_slot(_simulation_time)
		if jump_slot >= 0:
			_last_jump_set_category_value = StringName(
				WaveSetController.StrengthCategory.keys()[
					_wave_set_controller.strength_categories[jump_slot]
				]
			)
			_last_jump_set_peak_height_value = maxf(
				_tracked_jump_set_peak_height,
				_wave_set_controller.current_peak_contributions[jump_slot]
			)
	if not is_airborne and influence_slot < 0:
		_tracked_jump_set_slot = -1
		_tracked_jump_set_category = &"NONE"
		_tracked_jump_set_peak_height = 0.0
	_wave_set_target_was_airborne = is_airborne


func _reset_tracked_jump_set() -> void:
	_tracked_jump_set_slot = -1
	_tracked_jump_set_category = &"NONE"
	_tracked_jump_set_peak_height = 0.0
	_wave_set_target_was_airborne = false


func _update_constructive_interference_maximum(target_logical_xz: Vector2) -> void:
	var sample_positions: Array[Vector2] = [
		target_logical_xz,
		target_logical_xz + _dominant_wave_direction * 4.0,
		target_logical_xz - _dominant_wave_direction * 4.0,
	]
	for slot in WaveSetController.MAX_ACTIVE_WAVE_SETS:
		if _wave_set_controller.active_flags[slot] != 0:
			sample_positions.append(_wave_set_controller.focus_positions_logical[slot])
	var current_maximum: float = 0.0
	for logical_xz in sample_positions:
		current_maximum = maxf(
			current_maximum,
			_sample_constructive_interference_metric(logical_xz)
		)
	if _wave_set_controller.active_set_count() > 0:
		_constructive_interference_metric_max_value = maxf(
			_constructive_interference_metric_max_value,
			current_maximum
		)
	else:
		_constructive_interference_metric_max_value = current_maximum


func _sample_constructive_interference_metric(logical_xz: Vector2) -> float:
	var physical_xz := logical_xz - Vector2(_logical_origin_x, _logical_origin_z)
	var center_state := _sample_surface_state(physical_xz, _simulation_time)
	var neighbor_offset: float = 2.25
	var local_mean := (
		_sample_surface_state(
			physical_xz + Vector2(neighbor_offset, 0.0),
			_simulation_time
		).x
		+ _sample_surface_state(
			physical_xz - Vector2(neighbor_offset, 0.0),
			_simulation_time
		).x
		+ _sample_surface_state(
			physical_xz + Vector2(0.0, neighbor_offset),
			_simulation_time
		).x
		+ _sample_surface_state(
			physical_xz - Vector2(0.0, neighbor_offset),
			_simulation_time
		).x
	) * 0.25
	var wave_set_state := _wave_set_controller.sample_surface_state(
		logical_xz,
		_simulation_time
	)
	var base_height_contribution := center_state.x - wave_set_state.x
	var cross_system_reinforcement := minf(
		maxf(base_height_contribution, 0.0),
		maxf(wave_set_state.x, 0.0)
	)
	var local_crest_excess := maxf(center_state.x - local_mean, 0.0)
	var reinforcement := local_crest_excess + cross_system_reinforcement * 0.70
	var height_factor := smoothstep(0.16, 0.92, center_state.x)
	var slope_factor := smoothstep(
		0.07,
		0.30,
		Vector2(center_state.y, center_state.z).length()
	)
	var reinforcement_factor := smoothstep(0.035, 0.32, reinforcement)
	return clampf(
		height_factor * lerpf(0.55, 1.0, slope_factor) * reinforcement_factor,
		0.0,
		1.0
	)


func _wave_set_target_state() -> Array[Variant]:
	var target := _wave_set_observation_target()
	if not is_instance_valid(target):
		if not _wave_set_target_warning_emitted and not Engine.is_editor_hint():
			push_warning(
				"WaterBody3D: wave sets use the logical origin because no Jet Ski or camera target was resolved."
			)
			_wave_set_target_warning_emitted = true
		return [Vector2(_logical_origin_x, _logical_origin_z), Vector2.ZERO, false]
	var target_position := target.global_position
	var logical_position := _physical_to_logical_xz(Vector2(target_position.x, target_position.z))
	var horizontal_velocity := Vector2.ZERO
	if target is RigidBody3D:
		var body := target as RigidBody3D
		horizontal_velocity = Vector2(body.linear_velocity.x, body.linear_velocity.z)
	return [logical_position, horizontal_velocity, true]


func _wave_set_observation_target() -> Node3D:
	var target := _local_transparency_target
	if not is_instance_valid(target):
		target = follow_target
	return target


func _request_wave_set_update() -> void:
	if not is_inside_tree() or not is_node_ready():
		return
	_update_wave_set_controller(false)
	_push_wave_set_shader_parameters(true)


func _request_foam_update() -> void:
	_foam_settings_signature = -1
	if not is_inside_tree() or not is_node_ready():
		return
	_update_wave_set_controller(false)
	_push_foam_shader_parameters(true)


func _group_normalization(group_scale: float) -> float:
	var energy_normalization := 1.0 / sqrt(
		1.0 + group_scale * group_scale * 0.2564
	)
	var positive_envelope_normalization := 0.651 / maxf(
		1.0 - group_scale,
		0.001
	)
	return maxf(energy_normalization, positive_envelope_normalization)


func _sample_phase(index: int, world_xz: Vector2) -> float:
	return (
		_wave_numbers[index] * _wave_directions[index].dot(world_xz)
		- _wave_angular_frequencies[index] * _simulation_time
		+ _wave_effective_phases[index]
	)


func _sample_wave_shape(index: int, phase: float) -> float:
	return _wave_crest_normalizations[index] * (
		sin(phase) - _wave_crest_shapes[index] * cos(2.0 * phase)
	)


func _sample_wave_shape_derivative(index: int, phase: float) -> float:
	return _wave_crest_normalizations[index] * (
		cos(phase) + 2.0 * _wave_crest_shapes[index] * sin(2.0 * phase)
	)


func _wrap_phase(value: float) -> float:
	return fposmod(value + PI, TAU) - PI


func _resolve_local_transparency_target() -> void:
	if local_transparency_target_path.is_empty():
		return
	_local_transparency_target = get_node_or_null(
		local_transparency_target_path
	) as Node3D
	if (
		is_instance_valid(_local_transparency_target)
		and _local_transparency_target.has_signal(&"reset_completed")
		and not _local_transparency_target.is_connected(
			&"reset_completed",
			_on_local_transparency_target_reset
		)
	):
		_local_transparency_target.connect(
			&"reset_completed",
			_on_local_transparency_target_reset
		)


func _on_local_transparency_target_reset(_reason: StringName) -> void:
	_wave_set_controller.reset(_simulation_time)
	_push_wave_set_shader_parameters(true)
	call_deferred("_update_local_transparency_tracking", true)


func _configure_local_transparency_patch() -> void:
	_enforce_local_transparency_constraints()
	if _local_transparent_patch == null:
		return
	_local_transparent_patch.configure_geometry(
		local_transparency_patch_size,
		local_transparency_subdivisions
	)
	_local_transparent_patch.set_patch_enabled(_is_local_transparency_active())


func _is_local_transparency_active() -> bool:
	return (
		local_transparency_enabled
		and water_render_mode == WaterRenderMode.ARCADE_OPAQUE
		and is_instance_valid(_local_transparency_target)
		and local_transparency_material_valid
	)


func _update_local_transparency_tracking(force_snap: bool) -> void:
	if (
		not is_instance_valid(_local_transparency_target)
		or _local_transparent_patch == null
	):
		_local_transparency_follow_error_value = INF
		if _local_transparent_patch != null:
			_local_transparent_patch.set_patch_enabled(false)
		_push_local_transparency_center_uniforms()
		return
	var target_transform := _local_transparency_target.global_transform
	if not Engine.is_editor_hint():
		target_transform = _local_transparency_target.get_global_transform_interpolated()
	var target_xz := Vector2(target_transform.origin.x, target_transform.origin.z)
	if not target_xz.is_finite():
		_local_transparency_follow_error_value = INF
		return
	_local_transparency_center_xz = target_xz
	_local_transparent_patch.set_center_xz(target_xz, force_snap)
	_local_transparent_patch.set_patch_enabled(_is_local_transparency_active())
	var patch_position := _local_transparent_patch.global_position
	_local_transparency_follow_error_value = target_xz.distance_to(
		Vector2(patch_position.x, patch_position.z)
	)
	_push_local_transparency_center_uniforms()
	_local_transparency_update_count_value += 1


func _configure_visual_mesh() -> void:
	if _ocean_mesh == null:
		return
	var plane_mesh := _ocean_mesh.mesh as PlaneMesh
	if plane_mesh != null:
		plane_mesh.size = mesh_size
		plane_mesh.subdivide_width = mesh_subdivisions
		plane_mesh.subdivide_depth = mesh_subdivisions
	if opaque_water_material == null:
		opaque_water_material = _ocean_mesh.material_override as ShaderMaterial
		if opaque_water_material == null and plane_mesh != null:
			opaque_water_material = plane_mesh.material as ShaderMaterial
	_apply_water_render_material()
	_ocean_mesh.custom_aabb = AABB(
		Vector3(-mesh_size.x * 0.5, -4.0, -mesh_size.y * 0.5),
		Vector3(mesh_size.x, 8.0, mesh_size.y)
	)


func _apply_water_render_material() -> void:
	_shader_material = legacy_water_material
	if _ocean_mesh != null:
		_ocean_mesh.material_override = _shader_material


func _water_shader_materials() -> Array[ShaderMaterial]:
	var materials: Array[ShaderMaterial] = []
	if legacy_water_material != null:
		materials.append(legacy_water_material)
	for material in [
		_normal_local_transparency_material,
		_local_transparency_material(),
	]:
		if material != null and not materials.has(material):
			materials.append(material)
	for material in _external_water_materials:
		if is_instance_valid(material) and not materials.has(material):
			materials.append(material)
	return materials

func _local_transparency_material() -> ShaderMaterial:
	return (
		_local_transparent_patch.get_transparent_material()
		if _local_transparent_patch != null
		else null
	)


func _is_shader_material_valid(material: ShaderMaterial) -> bool:
	return material != null and material.shader != null


func _push_wave_shader_parameters() -> void:
	for material in _water_shader_materials():
		_update_shared_wave_uniforms(material)
	_push_wave_set_shader_parameters(true)


func _update_shared_wave_uniforms(material: ShaderMaterial) -> void:
	if material == null:
		return
	material.set_shader_parameter(&"active_wave_count", _active_wave_count)
	material.set_shader_parameter(&"wave_directions", _wave_directions)
	material.set_shader_parameter(&"wave_amplitudes", _wave_amplitudes)
	material.set_shader_parameter(&"wave_numbers", _wave_numbers)
	material.set_shader_parameter(&"wave_angular_frequencies", _wave_angular_frequencies)
	material.set_shader_parameter(&"wave_effective_phases", _wave_effective_phases)
	material.set_shader_parameter(&"wave_crest_shapes", _wave_crest_shapes)
	material.set_shader_parameter(
		&"wave_crest_normalizations",
		_wave_crest_normalizations
	)
	material.set_shader_parameter(
		&"wave_horizontal_amplitudes",
		_wave_horizontal_amplitudes
	)
	material.set_shader_parameter(
		&"natural_variation_enabled",
		_natural_variation_active
	)
	material.set_shader_parameter(
		&"phase_warp_strength",
		_effective_phase_warp_strength
	)
	material.set_shader_parameter(
		&"wave_group_strength",
		_effective_wave_group_strength
	)
	material.set_shader_parameter(
		&"modulation_directions",
		_modulation_directions
	)
	material.set_shader_parameter(
		&"modulation_wave_numbers",
		_modulation_wave_numbers
	)
	material.set_shader_parameter(
		&"modulation_angular_frequencies",
		_modulation_angular_frequencies
	)
	material.set_shader_parameter(
		&"modulation_effective_phases",
		_modulation_effective_phases
	)
	material.set_shader_parameter(
		&"wave_phase_warp_weights",
		_wave_phase_warp_weights
	)
	material.set_shader_parameter(&"wave_group_weights", _wave_group_weights)
	material.set_shader_parameter(
		&"wave_group_phase_offsets",
		_wave_group_phase_offsets
	)


func _push_wave_set_shader_parameters(force_update: bool) -> void:
	if not force_update and _wave_set_shader_revision == _wave_set_controller.state_revision:
		return
	var logical_origin := Vector2(_logical_origin_x, _logical_origin_z)
	var focus_positions := _wave_set_controller.shader_focus_positions(logical_origin)
	var carrier_phases := _wave_set_controller.shader_carrier_phases(logical_origin)
	for material in _water_shader_materials():
		material.set_shader_parameter(&"wave_set_active", _wave_set_controller.active_flags)
		material.set_shader_parameter(&"wave_set_focus_positions", focus_positions)
		material.set_shader_parameter(&"wave_set_focus_times", _wave_set_controller.focus_times)
		material.set_shader_parameter(&"wave_set_directions", _wave_set_controller.directions)
		material.set_shader_parameter(
			&"wave_set_right_directions",
			_wave_set_controller.right_directions
		)
		material.set_shader_parameter(&"wave_set_group_speeds", _wave_set_controller.group_speeds)
		material.set_shader_parameter(&"wave_set_packet_lengths", _wave_set_controller.packet_lengths)
		material.set_shader_parameter(&"wave_set_packet_widths", _wave_set_controller.packet_widths)
		material.set_shader_parameter(
			&"wave_set_total_amplitudes",
			_wave_set_controller.total_amplitudes
		)
		material.set_shader_parameter(
			&"wave_set_strength_categories",
			_wave_set_controller.strength_categories
		)
		material.set_shader_parameter(
			&"wave_set_carrier_amplitudes",
			_wave_set_controller.carrier_amplitudes
		)
		material.set_shader_parameter(
			&"wave_set_carrier_wave_numbers",
			_wave_set_controller.carrier_wave_numbers
		)
		material.set_shader_parameter(
			&"wave_set_carrier_angular_frequencies",
			_wave_set_controller.carrier_angular_frequencies
		)
		material.set_shader_parameter(&"wave_set_carrier_phases", carrier_phases)
		material.set_shader_parameter(
			&"wave_set_crest_sharpnesses",
			_wave_set_controller.crest_sharpnesses
		)
		material.set_shader_parameter(
			&"wave_set_front_face_skews",
			_wave_set_controller.front_face_skews
		)
		material.set_shader_parameter(
			&"wave_set_third_harmonics",
			_wave_set_controller.third_harmonics
		)
		material.set_shader_parameter(
			&"wave_set_shape_normalizations",
			_wave_set_controller.shape_normalizations
		)
	_wave_set_shader_revision = _wave_set_controller.state_revision


func _push_foam_shader_parameters(force_update: bool) -> void:
	var signature := foam_settings.configuration_signature() if foam_settings != null else 0
	if not force_update and signature == _foam_settings_signature:
		return
	var enabled := foam_settings != null and foam_settings.foam_enabled
	for material in _water_shader_materials():
		material.set_shader_parameter(&"foam_enabled", enabled)
		material.set_shader_parameter(&"foam_noise_texture", foam_noise_texture)
		material.set_shader_parameter(&"foam_logical_origin_xz", Vector2(
			_logical_origin_x,
			_logical_origin_z
		))
		material.set_shader_parameter(&"foam_dominant_direction", _dominant_wave_direction)
		if foam_settings == null:
			continue
		material.set_shader_parameter(&"foam_color", foam_settings.foam_color)
		material.set_shader_parameter(&"foam_amount", foam_settings.foam_amount)
		material.set_shader_parameter(&"foam_roughness", foam_settings.foam_roughness)
		material.set_shader_parameter(&"foam_specular", foam_settings.foam_specular)
		material.set_shader_parameter(&"breaking_threshold", foam_settings.breaking_threshold)
		material.set_shader_parameter(&"breaking_softness", foam_settings.breaking_softness)
		material.set_shader_parameter(&"foam_macro_noise_scale", foam_settings.macro_noise_scale)
		material.set_shader_parameter(&"foam_detail_noise_scale", foam_settings.detail_noise_scale)
		material.set_shader_parameter(&"foam_noise_scroll_speed", foam_settings.noise_scroll_speed)
		material.set_shader_parameter(&"foam_breakup_strength", foam_settings.breakup_strength)
		material.set_shader_parameter(
			&"base_ocean_foam_amount",
			foam_settings.base_ocean_foam_amount
		)
		material.set_shader_parameter(
			&"wave_set_foam_amount",
			foam_settings.wave_set_foam_amount
		)
	_foam_settings_signature = signature


func _push_runtime_shader_parameters() -> void:
	for material in _water_shader_materials():
		material.set_shader_parameter(&"base_height", base_height)
		material.set_shader_parameter(&"simulation_time", _simulation_time)


func _push_visual_shader_parameters() -> void:
	for material in _water_shader_materials():
		material.set_shader_parameter(&"surface_detail_mode", int(surface_detail_mode))
		material.set_shader_parameter(&"surface_normal_texture_a", surface_normal_texture_a)
		material.set_shader_parameter(&"surface_normal_texture_b", surface_normal_texture_b)
		material.set_shader_parameter(&"surface_warp_texture", surface_warp_texture)
		material.set_shader_parameter(&"surface_normal_strength", surface_normal_strength)
		material.set_shader_parameter(
			&"surface_normal_world_size_a",
			surface_normal_world_size_a
		)
		material.set_shader_parameter(
			&"surface_normal_world_size_b",
			surface_normal_world_size_b
		)
		material.set_shader_parameter(&"surface_flow_direction_a", surface_flow_direction_a)
		material.set_shader_parameter(&"surface_flow_direction_b", surface_flow_direction_b)
		material.set_shader_parameter(
			&"surface_flow_speed_a",
			surface_flow_speed_a * visual_detail_speed_multiplier
		)
		material.set_shader_parameter(
			&"surface_flow_speed_b",
			surface_flow_speed_b * visual_detail_speed_multiplier
		)
		material.set_shader_parameter(&"surface_warp_world_size", surface_warp_world_size)
		material.set_shader_parameter(&"surface_warp_strength", surface_warp_strength)
		material.set_shader_parameter(&"surface_warp_direction", surface_warp_direction)
		material.set_shader_parameter(
			&"surface_warp_speed",
			surface_warp_speed * visual_detail_speed_multiplier
		)
		material.set_shader_parameter(
			&"surface_stochastic_cell_size",
			surface_stochastic_cell_size
		)
		material.set_shader_parameter(
			&"surface_stochastic_rotation",
			surface_stochastic_rotation
		)
		material.set_shader_parameter(&"surface_detail_fade_start", surface_detail_fade_start)
		material.set_shader_parameter(&"surface_detail_fade_end", surface_detail_fade_end)
		material.set_shader_parameter(
			&"surface_roughness_variation",
			surface_roughness_variation
		)
		material.set_shader_parameter(
			&"surface_refraction_detail_strength",
			surface_refraction_detail_strength
		)
		material.set_shader_parameter(&"wave_height_color_enabled", wave_height_color_enabled)
		material.set_shader_parameter(&"wave_trough_color", wave_trough_color)
		material.set_shader_parameter(&"wave_crest_color", wave_crest_color)
		material.set_shader_parameter(
			&"wave_height_color_strength",
			wave_height_color_strength
		)
		material.set_shader_parameter(&"wave_height_color_range", wave_height_color_range)
		material.set_shader_parameter(&"wave_height_color_bias", wave_height_color_bias)
		material.set_shader_parameter(
			&"wave_compression_color_strength",
			wave_compression_color_strength
		)


func _push_optics_shader_parameters() -> void:
	var materials: Array[ShaderMaterial] = []
	if legacy_water_material != null:
		materials.append(legacy_water_material)
	for external_material in _external_water_materials:
		if (
			is_instance_valid(external_material)
			and _materials_share_shader(external_material, legacy_water_material)
			and not materials.has(external_material)
		):
			materials.append(external_material)
	if materials.is_empty():
		return
	for material in materials:
		_apply_optics_shader_parameters(material)
	_optics_uniform_update_count_value += 1


func _apply_optics_shader_parameters(material: ShaderMaterial) -> void:
	material.set_shader_parameter(&"shallow_water_color", _effective_shallow_color)
	material.set_shader_parameter(&"deep_water_color", _effective_deep_color)
	material.set_shader_parameter(&"horizon_water_color", _effective_horizon_color)
	material.set_shader_parameter(&"reflection_tint", _effective_reflection_tint)
	material.set_shader_parameter(&"absorption_density", _effective_absorption_density)
	material.set_shader_parameter(
		&"maximum_optical_depth",
		_effective_maximum_optical_depth
	)
	material.set_shader_parameter(&"shallow_depth_range", _effective_shallow_depth_range)
	material.set_shader_parameter(&"near_water_alpha", _effective_near_alpha_value)
	material.set_shader_parameter(&"deep_water_alpha", _effective_deep_alpha_value)
	material.set_shader_parameter(&"horizon_water_alpha", _effective_horizon_alpha_value)
	material.set_shader_parameter(
		&"opacity_distance_start",
		_effective_opacity_distance_start_value
	)
	material.set_shader_parameter(
		&"opacity_distance_end",
		_effective_opacity_distance_end_value
	)
	material.set_shader_parameter(&"fresnel_power", _effective_fresnel_power_value)
	material.set_shader_parameter(
		&"fresnel_opacity_strength",
		_effective_fresnel_opacity_strength
	)
	material.set_shader_parameter(
		&"reflection_strength",
		_effective_reflection_strength_value
	)
	material.set_shader_parameter(&"water_specular", _effective_water_specular)
	material.set_shader_parameter(
		&"refraction_strength",
		_effective_refraction_strength_value
	)
	material.set_shader_parameter(
		&"refraction_depth_range",
		_effective_refraction_depth_range
	)
	material.set_shader_parameter(
		&"refraction_distance_fade",
		_effective_refraction_distance_fade
	)
	material.set_shader_parameter(
		&"refraction_fresnel_fade",
		_effective_refraction_fresnel_fade
	)
	material.set_shader_parameter(
		&"near_water_roughness",
		_effective_near_roughness_value
	)
	material.set_shader_parameter(
		&"horizon_water_roughness",
		_effective_horizon_roughness_value
	)
	material.set_shader_parameter(
		&"crest_scattering_strength",
		_effective_crest_scattering_strength_value
	)
	material.set_shader_parameter(
		&"crest_scattering_power",
		_effective_crest_scattering_power
	)
	material.set_shader_parameter(
		&"crest_scattering_color",
		_effective_crest_scattering_color
	)
	material.set_shader_parameter(
		&"water_optics_debug_mode",
		int(water_optics_debug_mode)
	)


func _push_arcade_shader_parameters() -> void:
	var materials: Array[ShaderMaterial] = []
	if opaque_water_material != null:
		materials.append(opaque_water_material)
	var local_material := _local_transparency_material()
	if local_material != null:
		materials.append(local_material)
	for material in _external_water_materials:
		if (
			is_instance_valid(material)
			and _materials_share_shader(material, opaque_water_material)
			and not materials.has(material)
		):
			materials.append(material)
	for material in materials:
		material.set_shader_parameter(&"arcade_deep_color", arcade_deep_color)
		material.set_shader_parameter(&"arcade_mid_color", arcade_mid_color)
		material.set_shader_parameter(&"arcade_crest_color", arcade_crest_color)
		material.set_shader_parameter(
			&"arcade_color_strength",
			arcade_color_strength
		)
		material.set_shader_parameter(&"calm_roughness", calm_roughness)
		material.set_shader_parameter(&"slope_roughness", slope_roughness)


func _push_local_transparency_shader_parameters() -> void:
	var local_material := _local_transparency_material()
	var local_active := _is_local_transparency_active()
	var opaque_materials: Array[ShaderMaterial] = []
	if opaque_water_material != null:
		opaque_materials.append(opaque_water_material)
	for external_material in _external_water_materials:
		if (
			is_instance_valid(external_material)
			and _materials_share_shader(external_material, opaque_water_material)
			and not opaque_materials.has(external_material)
		):
			opaque_materials.append(external_material)
	for opaque_material in opaque_materials:
		opaque_material.set_shader_parameter(
			&"local_transparency_enabled",
			local_active
		)
		opaque_material.set_shader_parameter(
			&"local_transparency_handoff_radius",
			local_transparency_handoff_radius
		)
		opaque_material.set_shader_parameter(
			&"local_transparency_handoff_epsilon",
			local_transparency_handoff_epsilon
		)
	if local_material == null:
		return
	local_material.set_shader_parameter(&"local_transparency_enabled", local_active)
	local_material.set_shader_parameter(
		&"local_transparency_core_radius",
		local_transparency_core_radius
	)
	local_material.set_shader_parameter(
		&"local_transparency_handoff_radius",
		local_transparency_handoff_radius
	)
	local_material.set_shader_parameter(
		&"local_transparency_handoff_epsilon",
		local_transparency_handoff_epsilon
	)
	local_material.set_shader_parameter(
		&"local_transparency_near_alpha",
		local_transparency_near_alpha
	)
	local_material.set_shader_parameter(
		&"local_transparency_deep_alpha",
		local_transparency_deep_alpha
	)
	local_material.set_shader_parameter(
		&"local_transparency_absorption_density",
		local_transparency_absorption_density
	)
	local_material.set_shader_parameter(
		&"local_transparency_refraction_strength",
		local_transparency_refraction_strength
	)
	local_material.set_shader_parameter(
		&"local_transparency_fresnel_opacity",
		local_transparency_fresnel_opacity
	)
	if opaque_water_material != null:
		var shared_parameter_names: Array[StringName] = [
			&"micro_wave_scale_1",
			&"micro_wave_scale_2",
			&"micro_wave_speed_1",
			&"micro_wave_speed_2",
		]
		for parameter_name in shared_parameter_names:
			var parameter_value: Variant = opaque_water_material.get_shader_parameter(
				parameter_name
			)
			local_material.set_shader_parameter(parameter_name, parameter_value)
	_push_local_transparency_center_uniforms()


func _push_local_transparency_center_uniforms() -> void:
	var opaque_materials: Array[ShaderMaterial] = []
	if opaque_water_material != null:
		opaque_materials.append(opaque_water_material)
	for external_material in _external_water_materials:
		if (
			is_instance_valid(external_material)
			and _materials_share_shader(external_material, opaque_water_material)
			and not opaque_materials.has(external_material)
		):
			opaque_materials.append(external_material)
	for opaque_material in opaque_materials:
		opaque_material.set_shader_parameter(
			&"local_transparency_center_xz",
			_local_transparency_center_xz
		)
	var local_material := _local_transparency_material()
	if local_material != null:
		local_material.set_shader_parameter(
			&"local_transparency_center_xz",
			_local_transparency_center_xz
		)


func _materials_share_shader(
	material: ShaderMaterial,
	reference_material: ShaderMaterial
) -> bool:
	return (
		material != null
		and reference_material != null
		and material.shader != null
		and material.shader == reference_material.shader
	)


func _follow_target_on_grid(force_reset: bool) -> void:
	if _ocean_mesh == null or follow_target == null:
		return
	var cells_per_axis := float(mesh_subdivisions + 1)
	var cell_size := Vector2(mesh_size.x / cells_per_axis, mesh_size.y / cells_per_axis)
	var target_position := follow_target.global_position
	var snapped_position := Vector3(
		roundf(target_position.x / cell_size.x) * cell_size.x,
		_ocean_mesh.global_position.y,
		roundf(target_position.z / cell_size.y) * cell_size.y
	)
	if not force_reset and snapped_position.is_equal_approx(_ocean_mesh.global_position):
		return
	_ocean_mesh.global_position = snapped_position
	_ocean_mesh.reset_physics_interpolation()
