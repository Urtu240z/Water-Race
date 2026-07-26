@tool
class_name WaveSpectrumSettings
extends Resource

@export_group("Spectrum")
@export var spectrum_seed: int = 1847:
	set(value):
		if spectrum_seed == value:
			return
		spectrum_seed = value
		emit_changed()
@export_range(4, 12, 1) var custom_wave_count: int = 10:
	set(value):
		var validated_value := clampi(value, 4, 12)
		if custom_wave_count == validated_value:
			return
		custom_wave_count = validated_value
		emit_changed()
@export_range(6.0, 20.0, 0.5) var minimum_physical_wavelength: float = 8.0:
	set(value):
		var validated_value := clampf(value, 6.0, 20.0)
		if is_equal_approx(minimum_physical_wavelength, validated_value):
			return
		minimum_physical_wavelength = validated_value
		emit_changed()
@export_range(20.0, 80.0, 0.5) var maximum_physical_wavelength: float = 48.0:
	set(value):
		var validated_value := clampf(value, 20.0, 80.0)
		if is_equal_approx(maximum_physical_wavelength, validated_value):
			return
		maximum_physical_wavelength = validated_value
		emit_changed()

@export_group("Direction")
@export_range(-180.0, 180.0, 1.0) var primary_direction_degrees: float = 28.055722:
	set(value):
		var validated_value := clampf(value, -180.0, 180.0)
		if is_equal_approx(primary_direction_degrees, validated_value):
			return
		primary_direction_degrees = validated_value
		emit_changed()
@export_range(0.0, 90.0, 1.0) var primary_direction_spread_degrees: float = 38.0:
	set(value):
		var validated_value := clampf(value, 0.0, 90.0)
		if is_equal_approx(primary_direction_spread_degrees, validated_value):
			return
		primary_direction_spread_degrees = validated_value
		emit_changed()
@export_range(0.0, 1.0, 0.01) var cross_swell_ratio: float = 0.25:
	set(value):
		var validated_value := clampf(value, 0.0, 1.0)
		if is_equal_approx(cross_swell_ratio, validated_value):
			return
		cross_swell_ratio = validated_value
		emit_changed()
@export_range(30.0, 140.0, 1.0) var cross_swell_angle_degrees: float = 82.0:
	set(value):
		var validated_value := clampf(value, 30.0, 140.0)
		if is_equal_approx(cross_swell_angle_degrees, validated_value):
			return
		cross_swell_angle_degrees = validated_value
		emit_changed()
@export_range(0.0, 45.0, 1.0) var cross_swell_spread_degrees: float = 18.0:
	set(value):
		var validated_value := clampf(value, 0.0, 45.0)
		if is_equal_approx(cross_swell_spread_degrees, validated_value):
			return
		cross_swell_spread_degrees = validated_value
		emit_changed()

@export_group("Energy")
@export_range(0.0, 0.75, 0.01) var secondary_energy_ratio: float = 0.30:
	set(value):
		var validated_value := clampf(value, 0.0, 0.75)
		if is_equal_approx(secondary_energy_ratio, validated_value):
			return
		secondary_energy_ratio = validated_value
		emit_changed()
@export_range(0.0, 0.30, 0.01) var wavelength_jitter: float = 0.12:
	set(value):
		var validated_value := clampf(value, 0.0, 0.30)
		if is_equal_approx(wavelength_jitter, validated_value):
			return
		wavelength_jitter = validated_value
		emit_changed()
@export_range(0.0, 0.50, 0.01) var amplitude_jitter: float = 0.18:
	set(value):
		var validated_value := clampf(value, 0.0, 0.50)
		if is_equal_approx(amplitude_jitter, validated_value):
			return
		amplitude_jitter = validated_value
		emit_changed()
@export_range(0.0, 0.20, 0.01) var secondary_speed_jitter: float = 0.08:
	set(value):
		var validated_value := clampf(value, 0.0, 0.20)
		if is_equal_approx(secondary_speed_jitter, validated_value):
			return
		secondary_speed_jitter = validated_value
		emit_changed()

@export_group("Physical Motion")
@export_range(0.10, 10.0, 0.01) var target_spectrum_energy: float = 2.2629:
	set(value):
		var validated_value := clampf(value, 0.10, 10.0)
		if is_equal_approx(target_spectrum_energy, validated_value):
			return
		target_spectrum_energy = validated_value
		emit_changed()
@export_range(0.50, 1.20, 0.01) var base_phase_speed_scale: float = 0.92:
	set(value):
		var validated_value := clampf(value, 0.50, 1.20)
		if is_equal_approx(base_phase_speed_scale, validated_value):
			return
		base_phase_speed_scale = validated_value
		emit_changed()
@export_range(0.0, 0.05, 0.01) var speed_jitter: float = 0.05:
	set(value):
		var validated_value := clampf(value, 0.0, 0.05)
		if is_equal_approx(speed_jitter, validated_value):
			return
		speed_jitter = validated_value
		emit_changed()

@export_group("Natural Variation")
@export var natural_variation_enabled: bool = true:
	set(value):
		if natural_variation_enabled == value:
			return
		natural_variation_enabled = value
		emit_changed()
@export_range(0.0, 0.6, 0.01) var phase_warp_strength: float = 0.10:
	set(value):
		var validated_value := clampf(value, 0.0, 0.6)
		if is_equal_approx(phase_warp_strength, validated_value):
			return
		phase_warp_strength = validated_value
		emit_changed()
@export_range(0.0, 0.4, 0.01) var wave_group_strength: float = 0.06:
	set(value):
		var validated_value := clampf(value, 0.0, 0.4)
		if is_equal_approx(wave_group_strength, validated_value):
			return
		wave_group_strength = validated_value
		emit_changed()
@export_range(60.0, 300.0, 1.0) var modulation_min_wavelength: float = 90.0:
	set(value):
		var validated_value := clampf(value, 60.0, 300.0)
		if is_equal_approx(modulation_min_wavelength, validated_value):
			return
		modulation_min_wavelength = validated_value
		if modulation_max_wavelength <= modulation_min_wavelength:
			modulation_max_wavelength = minf(
				modulation_min_wavelength + 1.0,
				400.0
			)
		emit_changed()
@export_range(80.0, 400.0, 1.0) var modulation_max_wavelength: float = 180.0:
	set(value):
		var validated_value := clampf(
			value,
			maxf(modulation_min_wavelength + 1.0, 80.0),
			400.0
		)
		if is_equal_approx(modulation_max_wavelength, validated_value):
			return
		modulation_max_wavelength = validated_value
		emit_changed()
@export_range(0.05, 1.0, 0.01) var modulation_speed_scale: float = 0.30:
	set(value):
		var validated_value := clampf(value, 0.05, 1.0)
		if is_equal_approx(modulation_speed_scale, validated_value):
			return
		modulation_speed_scale = validated_value
		emit_changed()

@export_group("Crest Shape")
@export var crest_shape_enabled: bool = true:
	set(value):
		if crest_shape_enabled == value:
			return
		crest_shape_enabled = value
		emit_changed()
@export_range(0.0, 0.30, 0.005) var primary_crest_shape: float = 0.07:
	set(value):
		var validated_value := clampf(value, 0.0, 0.30)
		if is_equal_approx(primary_crest_shape, validated_value):
			return
		primary_crest_shape = validated_value
		emit_changed()
@export_range(0.0, 0.30, 0.005) var secondary_crest_shape: float = 0.045:
	set(value):
		var validated_value := clampf(value, 0.0, 0.30)
		if is_equal_approx(secondary_crest_shape, validated_value):
			return
		secondary_crest_shape = validated_value
		emit_changed()
@export_range(0.0, 0.30, 0.005) var cross_swell_crest_shape: float = 0.025:
	set(value):
		var validated_value := clampf(value, 0.0, 0.30)
		if is_equal_approx(cross_swell_crest_shape, validated_value):
			return
		cross_swell_crest_shape = validated_value
		emit_changed()
@export_range(0.0, 0.30, 0.005) var long_breaker_crest_shape: float = 0.06:
	set(value):
		var validated_value := clampf(value, 0.0, 0.30)
		if is_equal_approx(long_breaker_crest_shape, validated_value):
			return
		long_breaker_crest_shape = validated_value
		emit_changed()
@export_range(0.0, 2.0, 0.05) var global_crest_shape_strength: float = 1.0:
	set(value):
		var validated_value := clampf(value, 0.0, 2.0)
		if is_equal_approx(global_crest_shape_strength, validated_value):
			return
		global_crest_shape_strength = validated_value
		emit_changed()

@export_group("Crest Resolution")
@export_range(6.0, 30.0, 0.5) var crest_shape_start_wavelength: float = 10.0:
	set(value):
		var validated_value := clampf(value, 6.0, 30.0)
		if is_equal_approx(crest_shape_start_wavelength, validated_value):
			return
		crest_shape_start_wavelength = validated_value
		if crest_shape_full_wavelength <= crest_shape_start_wavelength:
			crest_shape_full_wavelength = minf(
				crest_shape_start_wavelength + 0.5,
				40.0
			)
		emit_changed()
@export_range(8.0, 40.0, 0.5) var crest_shape_full_wavelength: float = 18.0:
	set(value):
		var validated_value := clampf(
			value,
			maxf(crest_shape_start_wavelength + 0.5, 8.0),
			40.0
		)
		if is_equal_approx(crest_shape_full_wavelength, validated_value):
			return
		crest_shape_full_wavelength = validated_value
		emit_changed()


func configuration_signature() -> int:
	return hash([
		spectrum_seed,
		custom_wave_count,
		minimum_physical_wavelength,
		maximum_physical_wavelength,
		primary_direction_degrees,
		primary_direction_spread_degrees,
		cross_swell_ratio,
		cross_swell_angle_degrees,
		cross_swell_spread_degrees,
		secondary_energy_ratio,
		wavelength_jitter,
		amplitude_jitter,
		secondary_speed_jitter,
		target_spectrum_energy,
		base_phase_speed_scale,
		speed_jitter,
		natural_variation_enabled,
		phase_warp_strength,
		wave_group_strength,
		modulation_min_wavelength,
		modulation_max_wavelength,
		modulation_speed_scale,
		crest_shape_enabled,
		primary_crest_shape,
		secondary_crest_shape,
		cross_swell_crest_shape,
		long_breaker_crest_shape,
		global_crest_shape_strength,
		crest_shape_start_wavelength,
		crest_shape_full_wavelength,
	])
