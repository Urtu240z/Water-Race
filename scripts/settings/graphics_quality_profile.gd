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
@export_range(0, 1000, 1) var max_fps: int = 60

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
