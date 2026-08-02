class_name GraphicsQualityProfile
extends Resource

@export_group("3D Rendering")
@export var scaling_3d_scale: float = 1.0
@export var scaling_3d_mode: Viewport.Scaling3DMode = Viewport.SCALING_3D_MODE_FSR
@export var msaa_3d: Viewport.MSAA = Viewport.MSAA_DISABLED
@export var screen_space_aa: Viewport.ScreenSpaceAA = Viewport.SCREEN_SPACE_AA_SMAA
@export var use_taa: bool = false
@export var anisotropic_filtering: Viewport.AnisotropicFiltering = Viewport.ANISOTROPY_8X
@export_range(-2.0, 2.0, 0.01) var texture_mipmap_bias: float = 0.0
@export_range(0.0, 4.0, 0.01) var mesh_lod_bias: float = 1.0

@export_group("Environment")
@export var built_in_ssr: bool = false
@export var ssao: bool = true
@export_range(0.01, 16.0, 0.01) var ssao_radius: float = 2.5
@export_range(0.0, 5.0, 0.01) var ssao_detail: float = 0.7
@export_range(0.0, 16.0, 0.01) var ssao_power: float = 1.35
@export var ssil: bool = true
@export_range(0.01, 16.0, 0.01) var ssil_radius: float = 16.0
@export_range(0.0, 16.0, 0.01) var ssil_intensity: float = 2.94
@export var glow: bool = true
@export_range(0.0, 8.0, 0.01) var glow_intensity: float = 0.67
@export var fog: bool = true
@export var volumetric_fog: bool = false
@export var sdfgi: bool = false

@export_group("Lights and Shadows")
@export_range(0.0, 8192.0, 0.1) var directional_shadow_max_distance: float = 500.0
@export var directional_shadow_mode: DirectionalLight3D.ShadowMode = (
	DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS
)
@export_range(0.0, 10.0, 0.001) var directional_shadow_blur: float = 3.796
@export_range(256, 16384, 256) var directional_shadow_atlas_size: int = 4096
@export_range(256, 16384, 256) var positional_shadow_atlas_size: int = 4096
@export var omni_shadows: bool = true

@export_group("Reflections and Sky")
@export var reflection_probe: bool = true
@export var reflection_probe_shadows: bool = true
@export var sky_radiance: Sky.RadianceSize = Sky.RADIANCE_SIZE_256

@export_group("Ocean Geometry")
@export_range(1.0, 1000.0, 1.0) var ocean_near_radius: float = 220.0
@export_range(0.25, 128.0, 0.25) var ocean_near_cell_size: float = 0.5
@export_range(1.0, 2000.0, 1.0) var ocean_middle_radius: float = 700.0
@export_range(0.25, 128.0, 0.25) var ocean_middle_cell_size: float = 10.0
@export_range(1.0, 5000.0, 1.0) var ocean_far_radius: float = 3000.0
@export_range(0.25, 256.0, 0.25) var ocean_far_cell_size: float = 100.0
@export_range(0.25, 16.0, 0.25) var ocean_snap_step: float = 2.0
@export_range(0.0, 1000.0, 1.0) var ocean_detailed_wave_fade_start: float = 170.0
@export_range(1.0, 2000.0, 1.0) var ocean_detailed_wave_fade_end: float = 280.0
@export_range(0.0, 1.0, 0.01) var ocean_middle_wave_amplitude_ratio: float = 0.55
@export_range(0.0, 1.0, 0.01) var ocean_far_wave_amplitude_ratio: float = 0.08

@export_group("Ocean Visual Interaction")
@export_range(1, 12, 1) var ocean_effective_ripple_count: int = 12
@export_range(1, 16, 1) var ocean_effective_directional_segment_count: int = 16
@export_range(1, 4, 1) var ocean_effective_landing_impact_count: int = 4
@export_range(8.0, 200.0, 1.0) var ocean_vehicle_interaction_distance: float = 86.0
@export_range(0, 2, 1) var ocean_geometry_normal_quality: int = 2
@export_range(0, 2, 1) var ocean_surface_detail_quality: int = 2
@export_range(0.0, 1000.0, 1.0) var ocean_surface_detail_fade_start: float = 130.0
@export_range(1.0, 2000.0, 1.0) var ocean_surface_detail_fade_end: float = 520.0

@export_group("Ocean Reflections")
@export var ocean_custom_ssr_enabled: bool = true
@export_range(0, 32, 1) var ocean_custom_ssr_steps: int = 24
@export_range(0, 5, 1) var ocean_custom_ssr_refinement_steps: int = 2
@export_range(0.0, 500.0, 1.0) var ocean_custom_ssr_max_distance: float = 280.0
@export_range(0.0, 500.0, 1.0) var ocean_custom_ssr_distance_fade_start: float = 190.0
@export_range(1.0, 600.0, 1.0) var ocean_custom_ssr_distance_fade_end: float = 300.0
@export_range(0.0, 5.0, 0.05) var ocean_custom_ssr_blur_lod: float = 0.15
@export var ocean_mirrored_reflection_enabled: bool = true
@export_range(0.0, 1.5, 0.01) var ocean_mirrored_reflection_strength: float = 0.82
@export_range(0.0, 5.0, 0.05) var ocean_mirrored_reflection_blur_lod: float = 0.20

@export_group("Ocean Foam")
@export_range(0.0, 2.0, 0.01) var ocean_shore_foam_strength: float = 1.05
@export_range(0.0, 2.0, 0.01) var ocean_crest_foam_strength: float = 0.82
@export_range(0, 1, 1) var ocean_foam_detail_quality: int = 1
@export_range(1.0, 2000.0, 1.0) var ocean_foam_evaluation_distance: float = 520.0

@export_group("Vehicle Water Effects")
@export_range(0, 2, 1) var vehicle_effects_quality_level: int = 2

@export_group("Terrain")
@export_range(0, 2, 1) var terrain_hex_tiling_mode: int = 2

@export_group("Vegetation")
@export_range(1.0, 5000.0, 1.0) var vegetation_full_3d_range: float = 4000.0
@export_range(1.0, 5000.0, 1.0) var vegetation_impostor_range: float = 4000.0
@export_range(0.0, 5000.0, 1.0) var vegetation_ground_shadow_range: float = 4000.0
@export var vegetation_ground_shadows_enabled: bool = true
@export var vegetation_real_shadows_enabled: bool = true
@export_range(1.0, 30.0, 1.0) var vegetation_update_rate_hz: float = 12.0
@export_range(0.0, 1.0, 0.01) var vegetation_future_density_ratio: float = 1.0

@export_group("Wildlife")
@export_range(0.0, 1.0, 0.01) var wildlife_population_ratio: float = 1.0
@export_range(1.0, 60.0, 1.0) var wildlife_update_rate_hz: float = 60.0
@export_range(1.0, 3000.0, 1.0) var wildlife_bird_visibility_distance: float = 1500.0
@export_range(1.0, 1000.0, 1.0) var wildlife_fish_visibility_distance: float = 360.0
@export_range(1.0, 3000.0, 1.0) var wildlife_dolphin_visibility_distance: float = 1080.0

@export_group("Underwater Post-process")
@export_range(0.0, 24.0, 0.1) var underwater_blur_strength: float = 5.0
@export_range(1, 4, 1) var underwater_blur_passes: int = 2
@export_range(0, 2000, 1) var underwater_entry_bubbles_amount: int = 500
@export_range(0.0, 1.0, 0.01) var underwater_wet_lens_warp_multiplier: float = 1.0
@export_range(0.0, 1.0, 0.01) var underwater_wet_lens_zoom_multiplier: float = 1.0
