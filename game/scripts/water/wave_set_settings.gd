@tool
class_name WaveSetSettings
extends Resource

enum WaveSetFrequencyPreset {
	CALIBRATION,
	GAMEPLAY,
	CUSTOM,
}

const CALIBRATION_INTERVAL := Vector2(10.0, 18.0)
const GAMEPLAY_INTERVAL := Vector2(16.0, 28.0)

@export_group("Scheduling")
@export var enabled: bool = true
@export var wave_set_seed: int = 7351
# minimum_interval and maximum_interval are preserved as the CUSTOM values.
# Selecting either built-in preset never overwrites them.
@export var wave_set_frequency_preset: WaveSetFrequencyPreset = (
	WaveSetFrequencyPreset.CALIBRATION
)
@export_range(5.0, 120.0, 0.5) var minimum_interval: float = 18.0
@export_range(5.0, 180.0, 0.5) var maximum_interval: float = 35.0
@export_range(1, 3, 1) var maximum_active_sets: int = 2
@export_range(2.0, 15.0, 0.25) var minimum_focus_lead_time: float = 4.0
@export_range(2.0, 20.0, 0.25) var maximum_focus_lead_time: float = 6.5

@export_group("Placement")
@export_range(20.0, 150.0, 1.0) var minimum_focus_distance: float = 35.0
@export_range(20.0, 200.0, 1.0) var maximum_focus_distance: float = 65.0
@export_range(0.0, 50.0, 1.0) var lateral_focus_variation: float = 14.0
@export_range(0.0, 1.0, 0.01) var player_path_bias: float = 0.72
@export_range(0.0, 30.0, 1.0) var direction_jitter_degrees: float = 10.0

@export_group("Packet Shape")
@export_range(30.0, 180.0, 1.0) var minimum_packet_length: float = 65.0
@export_range(30.0, 220.0, 1.0) var maximum_packet_length: float = 110.0
@export_range(20.0, 140.0, 1.0) var minimum_packet_width: float = 42.0
@export_range(20.0, 180.0, 1.0) var maximum_packet_width: float = 68.0
@export_range(12.0, 50.0, 0.5) var minimum_wavelength: float = 20.0
@export_range(12.0, 60.0, 0.5) var maximum_wavelength: float = 32.0
@export_range(0.5, 2.0, 0.05) var group_speed_multiplier: float = 1.0

@export_group("Strength")
@export_range(0.0, 1.0, 0.01) var gentle_probability: float = 0.35
@export_range(0.0, 1.0, 0.01) var medium_probability: float = 0.45
@export_range(0.0, 1.0, 0.01) var strong_probability: float = 0.20
@export_range(0.05, 1.0, 0.01) var gentle_amplitude_min: float = 0.25
@export_range(0.05, 1.0, 0.01) var gentle_amplitude_max: float = 0.40
@export_range(0.05, 1.2, 0.01) var medium_amplitude_min: float = 0.50
@export_range(0.05, 1.2, 0.01) var medium_amplitude_max: float = 0.75
@export_range(0.05, 1.5, 0.01) var strong_amplitude_min: float = 0.80
@export_range(0.05, 1.5, 0.01) var strong_amplitude_max: float = 1.10

@export_group("Breaker Shape")
@export_range(0.0, 0.24, 0.005) var crest_sharpness: float = 0.16
@export_range(-0.15, 0.15, 0.005) var front_face_skew: float = 0.09
@export_range(0.0, 0.07, 0.005) var third_harmonic: float = 0.035
@export_range(0.0, 0.24, 0.005) var strong_crest_sharpness: float = 0.20
@export_range(-0.15, 0.15, 0.005) var strong_front_face_skew: float = 0.12
@export_range(0.0, 0.07, 0.005) var strong_third_harmonic: float = 0.05


func configuration_signature() -> int:
	return hash([
		enabled,
		wave_set_seed,
		int(wave_set_frequency_preset),
		minimum_interval,
		maximum_interval,
		maximum_active_sets,
		minimum_focus_lead_time,
		maximum_focus_lead_time,
		minimum_focus_distance,
		maximum_focus_distance,
		lateral_focus_variation,
		player_path_bias,
		direction_jitter_degrees,
		minimum_packet_length,
		maximum_packet_length,
		minimum_packet_width,
		maximum_packet_width,
		minimum_wavelength,
		maximum_wavelength,
		group_speed_multiplier,
		gentle_probability,
		medium_probability,
		strong_probability,
		gentle_amplitude_min,
		gentle_amplitude_max,
		medium_amplitude_min,
		medium_amplitude_max,
		strong_amplitude_min,
		strong_amplitude_max,
		crest_sharpness,
		front_face_skew,
		third_harmonic,
		strong_crest_sharpness,
		strong_front_face_skew,
		strong_third_harmonic,
	])


func normalized_strength_probabilities() -> Vector3:
	var weights := Vector3(
		maxf(gentle_probability, 0.0),
		maxf(medium_probability, 0.0),
		maxf(strong_probability, 0.0)
	)
	var total := weights.x + weights.y + weights.z
	return weights / total if total > 0.000001 else Vector3(1.0, 0.0, 0.0)


func ordered_interval() -> Vector2:
	match wave_set_frequency_preset:
		WaveSetFrequencyPreset.CALIBRATION:
			return CALIBRATION_INTERVAL
		WaveSetFrequencyPreset.GAMEPLAY:
			return GAMEPLAY_INTERVAL
		WaveSetFrequencyPreset.CUSTOM:
			pass
	var minimum := minf(minimum_interval, maximum_interval)
	return Vector2(minimum, maxf(maximum_interval, minimum + 0.5))


func frequency_preset_name() -> StringName:
	return StringName(WaveSetFrequencyPreset.keys()[int(wave_set_frequency_preset)])


func ordered_focus_lead_time() -> Vector2:
	var minimum := minf(minimum_focus_lead_time, maximum_focus_lead_time)
	return Vector2(minimum, maxf(maximum_focus_lead_time, minimum + 0.25))


func ordered_focus_distance() -> Vector2:
	var minimum := minf(minimum_focus_distance, maximum_focus_distance)
	return Vector2(minimum, maxf(maximum_focus_distance, minimum + 1.0))


func ordered_packet_length() -> Vector2:
	var minimum := minf(minimum_packet_length, maximum_packet_length)
	return Vector2(minimum, maxf(maximum_packet_length, minimum + 1.0))


func ordered_packet_width() -> Vector2:
	var minimum := minf(minimum_packet_width, maximum_packet_width)
	return Vector2(minimum, maxf(maximum_packet_width, minimum + 1.0))


func ordered_wavelength() -> Vector2:
	var minimum := minf(minimum_wavelength, maximum_wavelength)
	return Vector2(minimum, maxf(maximum_wavelength, minimum + 0.5))
