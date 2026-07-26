@tool
class_name WaterFoamSettings
extends Resource

@export_group("General")
@export var foam_enabled: bool = true
@export var foam_color: Color = Color(0.82, 0.94, 0.98, 1.0)
@export_range(0.0, 1.0, 0.01) var foam_amount: float = 0.72
@export_range(0.0, 1.0, 0.01) var foam_roughness: float = 0.86
@export_range(0.0, 1.0, 0.01) var foam_specular: float = 0.18

@export_group("Crest Foam")
@export_range(0.0, 2.0, 0.01) var breaking_threshold: float = 0.62
@export_range(0.01, 1.0, 0.01) var breaking_softness: float = 0.14
@export_range(0.001, 1.0, 0.001) var macro_noise_scale: float = 0.055
@export_range(0.001, 2.0, 0.001) var detail_noise_scale: float = 0.19
@export_range(0.0, 2.0, 0.01) var noise_scroll_speed: float = 0.16
@export_range(0.0, 1.0, 0.01) var breakup_strength: float = 0.78
@export_range(0.0, 1.0, 0.01) var base_ocean_foam_amount: float = 0.04
@export_range(0.0, 1.0, 0.01) var wave_set_foam_amount: float = 0.90

@export_group("Vehicle Foam")
@export var hull_foam_enabled: bool = true
@export_range(0.0, 2.0, 0.01) var hull_foam_strength: float = 0.85
@export_range(0.0, 2.0, 0.01) var wake_foam_strength: float = 0.90
@export_range(0.0, 30.0, 0.25) var hull_foam_full_speed: float = 15.0
@export_range(0.0, 4.0, 0.01) var hull_foam_opacity_boost: float = 1.25
@export_range(0.0, 4.0, 0.01) var wake_foam_opacity_boost: float = 1.0
@export_range(0.0, 1.0, 0.01) var hull_foam_core_opacity: float = 0.58
@export_range(0.0, 1.0, 0.01) var wake_foam_core_opacity: float = 0.22
@export_range(0.0, 2.0, 0.01) var hull_foam_emission: float = 0.08
@export_range(0.0, 2.0, 0.01) var wake_foam_emission: float = 0.05


func configuration_signature() -> int:
	return hash([
		foam_enabled,
		foam_color,
		foam_amount,
		foam_roughness,
		foam_specular,
		breaking_threshold,
		breaking_softness,
		macro_noise_scale,
		detail_noise_scale,
		noise_scroll_speed,
		breakup_strength,
		base_ocean_foam_amount,
		wave_set_foam_amount,
		hull_foam_enabled,
		hull_foam_strength,
		wake_foam_strength,
		hull_foam_full_speed,
		hull_foam_opacity_boost,
		wake_foam_opacity_boost,
		hull_foam_core_opacity,
		wake_foam_core_opacity,
		hull_foam_emission,
		wake_foam_emission,
	])
