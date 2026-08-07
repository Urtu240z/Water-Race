class_name WaveSpectrumBuilder
extends RefCounted

const MAX_WAVE_COMPONENTS: int = 12
const BASE_WAVE_COMPONENTS: int = 4
const MODULATION_COUNT: int = 2
const MINIMUM_LOG_WAVELENGTH_SEPARATION: float = 0.085
const ENERGY_EPSILON: float = 0.000000001
const GRAVITY: float = 9.81
const GROUP_RMS_COEFFICIENT: float = 0.2564
const MAXIMUM_COMPONENT_ENERGY_RATIO: float = 0.24
# RACE_10 deliberately places 62% of its energy in two primary waves. Its
# per-component limit therefore has to exceed 31%, while remaining tight
# enough to prevent a single primary from owning the silhouette.
const RACE_MAXIMUM_COMPONENT_ENERGY_RATIO: float = 0.34

const MODE_CLASSIC_4: int = 0
const MODE_ARCADE_8: int = 1
const MODE_RACE_10: int = 2
const MODE_CROSS_CHOP_10: int = 3
const MODE_STORM_12: int = 4
const MODE_CUSTOM: int = 5

enum WaveFamily {
	PRIMARY,
	SECONDARY,
	CROSS_SWELL,
	LONG_BREAKER,
}


static func build(
	base_waves: Array[WaveComponent],
	mode: int,
	settings: WaveSpectrumSettings,
	intensity_multiplier: float,
	crest_shape_multiplier: float,
	speed_multiplier: float,
	temporal_phase_offsets: PackedFloat32Array,
	modulation_temporal_phase_offsets: PackedFloat32Array,
	logical_origin_x: float,
	logical_origin_z: float
) -> Dictionary:
	var directions := PackedVector2Array()
	var amplitudes := PackedFloat32Array()
	var wavelengths := PackedFloat32Array()
	var base_speeds := PackedFloat32Array()
	var effective_speeds := PackedFloat32Array()
	var wave_numbers := PackedFloat32Array()
	var angular_frequencies := PackedFloat32Array()
	var base_phases := PackedFloat32Array()
	var temporal_offsets := PackedFloat32Array()
	var effective_phases := PackedFloat32Array()
	var crest_shapes := PackedFloat32Array()
	var crest_normalizations := PackedFloat32Array()
	var families := PackedInt32Array()
	var phase_warp_weights := PackedFloat32Array()
	var group_weights := PackedFloat32Array()
	var group_phase_offsets := PackedFloat32Array()
	directions.resize(MAX_WAVE_COMPONENTS)
	amplitudes.resize(MAX_WAVE_COMPONENTS)
	wavelengths.resize(MAX_WAVE_COMPONENTS)
	base_speeds.resize(MAX_WAVE_COMPONENTS)
	effective_speeds.resize(MAX_WAVE_COMPONENTS)
	wave_numbers.resize(MAX_WAVE_COMPONENTS)
	angular_frequencies.resize(MAX_WAVE_COMPONENTS)
	base_phases.resize(MAX_WAVE_COMPONENTS)
	temporal_offsets.resize(MAX_WAVE_COMPONENTS)
	effective_phases.resize(MAX_WAVE_COMPONENTS)
	crest_shapes.resize(MAX_WAVE_COMPONENTS)
	crest_normalizations.resize(MAX_WAVE_COMPONENTS)
	families.resize(MAX_WAVE_COMPONENTS)
	phase_warp_weights.resize(MAX_WAVE_COMPONENTS)
	group_weights.resize(MAX_WAVE_COMPONENTS)
	group_phase_offsets.resize(MAX_WAVE_COMPONENTS)
	_fill_wave_defaults(
		directions,
		amplitudes,
		wavelengths,
		base_speeds,
		effective_speeds,
		wave_numbers,
		angular_frequencies,
		base_phases,
		temporal_offsets,
		effective_phases,
		crest_shapes,
		crest_normalizations,
		families,
		phase_warp_weights,
		group_weights,
		group_phase_offsets
	)

	var active_count := _active_count_for_mode(mode, settings.custom_wave_count)
	var reference_energy := _manual_profile_energy(base_waves)
	if mode == MODE_CLASSIC_4:
		_build_classic_waves(
			base_waves,
			directions,
			amplitudes,
			wavelengths,
			base_speeds,
			base_phases,
			families
		)
	else:
		reference_energy = settings.target_spectrum_energy
		_build_modern_waves(
			mode,
			settings,
			active_count,
			reference_energy,
			directions,
			amplitudes,
			wavelengths,
			base_speeds,
			base_phases,
			families,
			phase_warp_weights,
			group_weights,
			group_phase_offsets
		)

	var generated_energy: float = 0.0
	var maximum_component_energy: float = 0.0
	var maximum_crest_shape: float = 0.0
	var crest_shape_sum: float = 0.0
	var harmonic_energy_error: float = 0.0
	for index in active_count:
		var component_energy := amplitudes[index] * amplitudes[index]
		generated_energy += component_energy
		maximum_component_energy = maxf(maximum_component_energy, component_energy)
		var direction := directions[index].normalized()
		if direction.is_zero_approx():
			direction = Vector2.RIGHT
		directions[index] = direction
		var wavelength := maxf(wavelengths[index], WaveComponent.MIN_WAVELENGTH)
		var wave_number := TAU / wavelength
		var base_speed := maxf(base_speeds[index], 0.0)
		var effective_speed := base_speed * speed_multiplier
		var temporal_offset := 0.0
		if index < temporal_phase_offsets.size():
			temporal_offset = temporal_phase_offsets[index]
		if not is_finite(temporal_offset):
			temporal_offset = 0.0
		var crest_shape := 0.0
		if settings.crest_shape_enabled and mode != MODE_CLASSIC_4:
			var resolution := _smoothstep(
				settings.crest_shape_start_wavelength,
				settings.crest_shape_full_wavelength,
				wavelength
			)
			crest_shape = clampf(
				_crest_shape_for_family(mode, families[index], settings)
				* settings.global_crest_shape_strength
				* maxf(crest_shape_multiplier, 0.0),
				0.0,
				0.25
			) * resolution
		var crest_normalization := 1.0 / sqrt(1.0 + crest_shape * crest_shape)
		crest_shapes[index] = crest_shape
		crest_normalizations[index] = crest_normalization
		maximum_crest_shape = maxf(maximum_crest_shape, crest_shape)
		crest_shape_sum += crest_shape
		var normalized_fundamental := crest_normalization * crest_normalization
		var normalized_harmonic := crest_shape * crest_normalization
		harmonic_energy_error = maxf(
			harmonic_energy_error,
			absf(
				normalized_fundamental
				+ normalized_harmonic * normalized_harmonic
				- 1.0
			)
		)
		wavelengths[index] = wavelength
		base_speeds[index] = base_speed
		effective_speeds[index] = effective_speed
		wave_numbers[index] = wave_number
		angular_frequencies[index] = wave_number * effective_speed
		temporal_offsets[index] = _wrap_phase(temporal_offset)
		effective_phases[index] = _wrap_phase(
			base_phases[index]
			+ temporal_offsets[index]
			+ wave_number * direction.dot(
				Vector2(logical_origin_x, logical_origin_z)
			)
		)
		amplitudes[index] *= intensity_multiplier

	var modulation_block := _build_modulators(
		mode,
		settings,
		speed_multiplier,
		modulation_temporal_phase_offsets,
		logical_origin_x,
		logical_origin_z
	)
	return {
		"active_wave_count": active_count,
		"wave_directions": directions,
		"wave_amplitudes": amplitudes,
		"wave_wavelengths": wavelengths,
		"wave_base_speeds": base_speeds,
		"wave_effective_speeds": effective_speeds,
		"wave_numbers": wave_numbers,
		"wave_angular_frequencies": angular_frequencies,
		"wave_base_phases": base_phases,
		"wave_temporal_phase_offsets": temporal_offsets,
		"wave_effective_phases": effective_phases,
		"wave_crest_shapes": crest_shapes,
		"wave_crest_normalizations": crest_normalizations,
		"wave_families": families,
		"wave_phase_warp_weights": phase_warp_weights,
		"wave_group_weights": group_weights,
		"wave_group_phase_offsets": group_phase_offsets,
		"reference_spectrum_energy": reference_energy,
		"generated_spectrum_energy": generated_energy,
		"spectrum_energy_error": generated_energy - reference_energy,
		"maximum_component_energy_ratio": (
			maximum_component_energy / maxf(generated_energy, ENERGY_EPSILON)
		),
		"maximum_effective_crest_shape": maximum_crest_shape,
		"average_effective_crest_shape": (
			crest_shape_sum / float(active_count) if active_count > 0 else 0.0
		),
		"harmonic_energy_error": harmonic_energy_error,
		"natural_variation_active": modulation_block["natural_variation_active"],
		"effective_phase_warp_strength": modulation_block["effective_phase_warp_strength"],
		"effective_wave_group_strength": modulation_block["effective_wave_group_strength"],
		"modulation_directions": modulation_block["modulation_directions"],
		"modulation_wavelengths": modulation_block["modulation_wavelengths"],
		"modulation_base_speeds": modulation_block["modulation_base_speeds"],
		"modulation_speeds": modulation_block["modulation_speeds"],
		"modulation_wave_numbers": modulation_block["modulation_wave_numbers"],
		"modulation_angular_frequencies": modulation_block["modulation_angular_frequencies"],
		"modulation_base_phases": modulation_block["modulation_base_phases"],
		"modulation_temporal_phase_offsets": modulation_block["modulation_temporal_phase_offsets"],
		"modulation_effective_phases": modulation_block["modulation_effective_phases"],
	}


static func _fill_wave_defaults(
	directions: PackedVector2Array,
	amplitudes: PackedFloat32Array,
	wavelengths: PackedFloat32Array,
	base_speeds: PackedFloat32Array,
	effective_speeds: PackedFloat32Array,
	wave_numbers: PackedFloat32Array,
	angular_frequencies: PackedFloat32Array,
	base_phases: PackedFloat32Array,
	temporal_offsets: PackedFloat32Array,
	effective_phases: PackedFloat32Array,
	crest_shapes: PackedFloat32Array,
	crest_normalizations: PackedFloat32Array,
	families: PackedInt32Array,
	phase_warp_weights: PackedFloat32Array,
	group_weights: PackedFloat32Array,
	group_phase_offsets: PackedFloat32Array
) -> void:
	for index in MAX_WAVE_COMPONENTS:
		directions[index] = Vector2.RIGHT
		amplitudes[index] = 0.0
		wavelengths[index] = 1.0
		base_speeds[index] = 0.0
		effective_speeds[index] = 0.0
		wave_numbers[index] = 0.0
		angular_frequencies[index] = 0.0
		base_phases[index] = 0.0
		temporal_offsets[index] = 0.0
		effective_phases[index] = 0.0
		crest_shapes[index] = 0.0
		crest_normalizations[index] = 1.0
		families[index] = WaveFamily.PRIMARY
		phase_warp_weights[index] = 0.0
		group_weights[index] = 0.0
		group_phase_offsets[index] = 0.0


static func _manual_profile_energy(base_waves: Array[WaveComponent]) -> float:
	var energy: float = 0.0
	for index in mini(BASE_WAVE_COMPONENTS, base_waves.size()):
		var wave := base_waves[index]
		if wave != null:
			energy += wave.amplitude * wave.amplitude
	return energy


static func _build_classic_waves(
	base_waves: Array[WaveComponent],
	directions: PackedVector2Array,
	amplitudes: PackedFloat32Array,
	wavelengths: PackedFloat32Array,
	base_speeds: PackedFloat32Array,
	base_phases: PackedFloat32Array,
	families: PackedInt32Array
) -> void:
	for index in BASE_WAVE_COMPONENTS:
		if index >= base_waves.size() or base_waves[index] == null:
			continue
		var wave := base_waves[index]
		var direction := wave.direction.normalized()
		directions[index] = direction if not direction.is_zero_approx() else Vector2.RIGHT
		amplitudes[index] = wave.amplitude
		wavelengths[index] = maxf(wave.wavelength, WaveComponent.MIN_WAVELENGTH)
		base_speeds[index] = maxf(wave.speed, 0.0)
		base_phases[index] = wave.phase_offset
		families[index] = WaveFamily.PRIMARY


static func _build_modern_waves(
	mode: int,
	settings: WaveSpectrumSettings,
	active_count: int,
	target_energy: float,
	directions: PackedVector2Array,
	amplitudes: PackedFloat32Array,
	wavelengths: PackedFloat32Array,
	base_speeds: PackedFloat32Array,
	base_phases: PackedFloat32Array,
	families: PackedInt32Array,
	phase_warp_weights: PackedFloat32Array,
	group_weights: PackedFloat32Array,
	group_phase_offsets: PackedFloat32Array
) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = settings.spectrum_seed
	var family_counts := _family_counts_for_mode(mode, active_count, settings)
	var family_energy_ratios := _family_energy_ratios_for_mode(mode, settings)
	var used_wavelengths: Array[float] = []
	var raw_amplitude_weights := PackedFloat32Array()
	raw_amplitude_weights.resize(active_count)
	var component_index := 0
	for family in 4:
		var family_count := family_counts[family]
		for family_index in family_count:
			families[component_index] = family
			wavelengths[component_index] = _generate_family_wavelength(
				mode,
				family,
				family_index,
				family_count,
				settings,
				rng,
				used_wavelengths
			)
			directions[component_index] = _generate_modern_direction(
				mode,
				family,
				family_index,
				settings,
				rng
			)
			var wave_number := TAU / wavelengths[component_index]
			var physical_phase_speed := sqrt(GRAVITY / wave_number)
			var jitter := rng.randf_range(
				1.0 - settings.speed_jitter,
				1.0 + settings.speed_jitter
			)
			base_speeds[component_index] = (
				physical_phase_speed * settings.base_phase_speed_scale * jitter
			)
			base_phases[component_index] = rng.randf_range(0.0, TAU)
			if mode == MODE_RACE_10 and family == WaveFamily.PRIMARY:
				# Keep the two dominant swells close enough to share their 62%
				# family budget without either exceeding the RACE safety cap.
				raw_amplitude_weights[component_index] = rng.randf_range(0.98, 1.02)
			else:
				raw_amplitude_weights[component_index] = rng.randf_range(
					1.0 - settings.amplitude_jitter,
					1.0 + settings.amplitude_jitter
				)
			phase_warp_weights[component_index] = rng.randf_range(0.55, 1.0)
			group_weights[component_index] = rng.randf_range(0.45, 1.0)
			group_phase_offsets[component_index] = rng.randf_range(0.0, TAU)
			component_index += 1
	var component_energies := PackedFloat32Array()
	component_energies.resize(active_count)
	for family in 4:
		var family_weight_energy: float = 0.0
		for index in active_count:
			if families[index] == family:
				family_weight_energy += (
					raw_amplitude_weights[index] * raw_amplitude_weights[index]
				)
		var family_target_energy := target_energy * family_energy_ratios[family]
		for index in active_count:
			if families[index] == family:
				component_energies[index] = family_target_energy * (
					raw_amplitude_weights[index] * raw_amplitude_weights[index]
					/ maxf(family_weight_energy, ENERGY_EPSILON)
				)
	_enforce_component_energy_limit(
		component_energies,
		target_energy,
		(
			RACE_MAXIMUM_COMPONENT_ENERGY_RATIO
			if mode == MODE_RACE_10
			else MAXIMUM_COMPONENT_ENERGY_RATIO
		)
	)
	for index in active_count:
		amplitudes[index] = sqrt(maxf(component_energies[index], 0.0))


static func _family_counts_for_mode(
	mode: int,
	active_count: int,
	settings: WaveSpectrumSettings
) -> PackedInt32Array:
	match mode:
		MODE_ARCADE_8:
			return PackedInt32Array([2, 3, 1, 2])
		MODE_RACE_10:
			return PackedInt32Array([2, 4, 2, 2])
		MODE_CROSS_CHOP_10:
			return PackedInt32Array([2, 3, 3, 2])
		MODE_STORM_12:
			return PackedInt32Array([3, 4, 3, 2])
		MODE_CUSTOM:
			var cross_count := clampi(
				roundi(float(active_count) * settings.cross_swell_ratio),
				1,
				maxi(active_count - 4, 1)
			)
			var primary_count := mini(2, active_count)
			var short_count := mini(2, maxi(active_count - primary_count - cross_count, 0))
			var mid_count := maxi(
				active_count - primary_count - cross_count - short_count,
				0
			)
			return PackedInt32Array([
				primary_count,
				mid_count,
				cross_count,
				short_count,
			])
	return PackedInt32Array([active_count, 0, 0, 0])


static func _family_energy_ratios_for_mode(
	mode: int,
	settings: WaveSpectrumSettings
) -> PackedFloat32Array:
	match mode:
		MODE_ARCADE_8:
			return PackedFloat32Array([0.42, 0.36, 0.12, 0.10])
		MODE_RACE_10:
			return PackedFloat32Array([0.62, 0.27, 0.08, 0.03])
		MODE_CROSS_CHOP_10:
			return PackedFloat32Array([0.30, 0.32, 0.28, 0.10])
		MODE_STORM_12:
			return PackedFloat32Array([0.36, 0.32, 0.24, 0.08])
		MODE_CUSTOM:
			var cross_ratio := clampf(settings.cross_swell_ratio, 0.08, 0.35)
			var short_ratio := 0.10
			var remaining := 1.0 - cross_ratio - short_ratio
			return PackedFloat32Array([
				remaining * 0.52,
				remaining * 0.48,
				cross_ratio,
				short_ratio,
			])
	return PackedFloat32Array([1.0, 0.0, 0.0, 0.0])


static func _family_wavelength_range(
	mode: int,
	family: int,
	settings: WaveSpectrumSettings
) -> Vector2:
	if mode == MODE_RACE_10:
		match family:
			WaveFamily.PRIMARY:
				return Vector2(38.0, 58.0)
			WaveFamily.SECONDARY:
				return Vector2(20.0, 36.0)
			WaveFamily.CROSS_SWELL:
				return Vector2(16.0, 28.0)
			WaveFamily.LONG_BREAKER:
				return Vector2(10.0, 15.0)
	if mode == MODE_STORM_12:
		match family:
			WaveFamily.PRIMARY:
				return Vector2(38.0, 68.0)
			WaveFamily.SECONDARY:
				return Vector2(18.0, 40.0)
			WaveFamily.CROSS_SWELL:
				return Vector2(12.0, 32.0)
			WaveFamily.LONG_BREAKER:
				return Vector2(8.0, 16.0)
	if mode == MODE_CROSS_CHOP_10:
		match family:
			WaveFamily.PRIMARY:
				return Vector2(30.0, 52.0)
			WaveFamily.SECONDARY:
				return Vector2(16.0, 34.0)
			WaveFamily.CROSS_SWELL:
				return Vector2(12.0, 30.0)
			WaveFamily.LONG_BREAKER:
				return Vector2(8.0, 15.0)
	if mode == MODE_ARCADE_8:
		match family:
			WaveFamily.PRIMARY:
				return Vector2(32.0, 50.0)
			WaveFamily.SECONDARY:
				return Vector2(16.0, 32.0)
			WaveFamily.CROSS_SWELL:
				return Vector2(12.0, 26.0)
			WaveFamily.LONG_BREAKER:
				return Vector2(8.0, 14.0)
	var minimum := minf(
		settings.minimum_physical_wavelength,
		settings.maximum_physical_wavelength
	)
	var maximum := maxf(
		settings.minimum_physical_wavelength,
		settings.maximum_physical_wavelength
	)
	var log_minimum := log(minimum)
	var log_maximum := log(maximum)
	match family:
		WaveFamily.PRIMARY:
			return Vector2(exp(lerpf(log_minimum, log_maximum, 0.68)), maximum)
		WaveFamily.SECONDARY:
			return Vector2(exp(lerpf(log_minimum, log_maximum, 0.30)), exp(lerpf(log_minimum, log_maximum, 0.75)))
		WaveFamily.CROSS_SWELL:
			return Vector2(exp(lerpf(log_minimum, log_maximum, 0.18)), exp(lerpf(log_minimum, log_maximum, 0.68)))
		_:
			return Vector2(minimum, exp(lerpf(log_minimum, log_maximum, 0.38)))


static func _generate_family_wavelength(
	mode: int,
	family: int,
	family_index: int,
	family_count: int,
	settings: WaveSpectrumSettings,
	rng: RandomNumberGenerator,
	used_wavelengths: Array[float]
) -> float:
	var wavelength_range := _family_wavelength_range(mode, family, settings)
	var minimum := minf(wavelength_range.x, wavelength_range.y)
	var maximum := maxf(wavelength_range.x, wavelength_range.y)
	var log_minimum := log(maxf(minimum, 0.001))
	var log_maximum := log(maxf(maximum, minimum + 0.001))
	var stratum_width := 1.0 / float(maxi(family_count, 1))
	var stratum_center := (float(family_index) + 0.5) * stratum_width
	for _attempt in 96:
		var jitter := rng.randf_range(-0.38, 0.38) * stratum_width
		var t := clampf(stratum_center + jitter, 0.0, 1.0)
		var candidate := exp(lerpf(log_minimum, log_maximum, t))
		if _has_wavelength_separation(candidate, used_wavelengths):
			used_wavelengths.append(candidate)
			return candidate
	for scan_index in 257:
		var rotated_index := (scan_index + family_index * 37 + family * 53) % 257
		var scan_t := float(rotated_index) / 256.0
		var candidate := exp(lerpf(log_minimum, log_maximum, scan_t))
		if _has_wavelength_separation(candidate, used_wavelengths):
			used_wavelengths.append(candidate)
			return candidate
	var fallback := exp(lerpf(log_minimum, log_maximum, stratum_center))
	used_wavelengths.append(fallback)
	return fallback


static func _has_wavelength_separation(
	wavelength: float,
	used_wavelengths: Array[float]
) -> bool:
	for used_wavelength in used_wavelengths:
		if absf(log(wavelength / maxf(used_wavelength, 0.001))) < MINIMUM_LOG_WAVELENGTH_SEPARATION:
			return false
	return true


static func _generate_modern_direction(
	mode: int,
	family: int,
	family_index: int,
	settings: WaveSpectrumSettings,
	rng: RandomNumberGenerator
) -> Vector2:
	var dominant_angle := deg_to_rad(settings.primary_direction_degrees)
	var alternating_sign := -1.0 if family_index % 2 == 0 else 1.0
	var offset_degrees: float
	if mode == MODE_RACE_10:
		match family:
			WaveFamily.PRIMARY:
				offset_degrees = alternating_sign * rng.randf_range(2.0, 10.0)
			WaveFamily.SECONDARY:
				offset_degrees = alternating_sign * rng.randf_range(8.0, 24.0)
			WaveFamily.CROSS_SWELL:
				offset_degrees = alternating_sign * rng.randf_range(55.0, 72.0)
			_:
				offset_degrees = alternating_sign * rng.randf_range(16.0, 35.0)
	else:
		match family:
			WaveFamily.PRIMARY:
				offset_degrees = alternating_sign * rng.randf_range(4.0, 12.0)
			WaveFamily.SECONDARY:
				offset_degrees = alternating_sign * rng.randf_range(13.0, 35.0)
			WaveFamily.CROSS_SWELL:
				offset_degrees = alternating_sign * rng.randf_range(55.0, 85.0)
			_:
				offset_degrees = alternating_sign * rng.randf_range(24.0, 55.0)
	var direction := Vector2.from_angle(dominant_angle + deg_to_rad(offset_degrees))
	return direction.normalized() if not direction.is_zero_approx() else Vector2.RIGHT


static func _enforce_component_energy_limit(
	energies: PackedFloat32Array,
	target_energy: float,
	maximum_ratio: float
) -> void:
	var maximum_energy := target_energy * maximum_ratio
	for _iteration in 16:
		var excess: float = 0.0
		var distributable: float = 0.0
		for index in energies.size():
			if energies[index] > maximum_energy:
				excess += energies[index] - maximum_energy
				energies[index] = maximum_energy
			else:
				distributable += energies[index]
		if excess <= ENERGY_EPSILON or distributable <= ENERGY_EPSILON:
			break
		for index in energies.size():
			if energies[index] < maximum_energy:
				energies[index] += excess * energies[index] / distributable
	var final_energy: float = 0.0
	for energy in energies:
		final_energy += energy
	if final_energy <= ENERGY_EPSILON:
		return
	var correction := target_energy / final_energy
	for index in energies.size():
		energies[index] *= correction


static func _build_modulators(
	mode: int,
	settings: WaveSpectrumSettings,
	speed_multiplier: float,
	temporal_phase_offsets: PackedFloat32Array,
	logical_origin_x: float,
	logical_origin_z: float
) -> Dictionary:
	var directions := PackedVector2Array()
	var wavelengths := PackedFloat32Array()
	var base_speeds := PackedFloat32Array()
	var speeds := PackedFloat32Array()
	var wave_numbers := PackedFloat32Array()
	var angular_frequencies := PackedFloat32Array()
	var base_phases := PackedFloat32Array()
	var temporal_offsets := PackedFloat32Array()
	var effective_phases := PackedFloat32Array()
	directions.resize(MODULATION_COUNT)
	wavelengths.resize(MODULATION_COUNT)
	base_speeds.resize(MODULATION_COUNT)
	speeds.resize(MODULATION_COUNT)
	wave_numbers.resize(MODULATION_COUNT)
	angular_frequencies.resize(MODULATION_COUNT)
	base_phases.resize(MODULATION_COUNT)
	temporal_offsets.resize(MODULATION_COUNT)
	effective_phases.resize(MODULATION_COUNT)
	var rng := RandomNumberGenerator.new()
	rng.seed = settings.spectrum_seed + 104729
	var dominant_angle := deg_to_rad(settings.primary_direction_degrees)
	var minimum_wavelength := minf(
		settings.modulation_min_wavelength,
		settings.modulation_max_wavelength
	)
	var maximum_wavelength := maxf(
		settings.modulation_min_wavelength,
		settings.modulation_max_wavelength
	)
	var midpoint := sqrt(minimum_wavelength * maximum_wavelength)
	for index in MODULATION_COUNT:
		var angle_offset := (
			rng.randf_range(48.0, 72.0)
			if index == 0
			else -rng.randf_range(72.0, 108.0)
		)
		directions[index] = Vector2.from_angle(
			dominant_angle + deg_to_rad(angle_offset)
		).normalized()
		wavelengths[index] = (
			rng.randf_range(minimum_wavelength, midpoint)
			if index == 0
			else rng.randf_range(midpoint, maximum_wavelength)
		)
		var wave_number := TAU / wavelengths[index]
		var physical_speed := sqrt(GRAVITY / wave_number)
		base_speeds[index] = (
			physical_speed
			* settings.base_phase_speed_scale
			* settings.modulation_speed_scale
		)
		speeds[index] = base_speeds[index] * speed_multiplier
		wave_numbers[index] = wave_number
		angular_frequencies[index] = wave_number * speeds[index]
		base_phases[index] = rng.randf_range(0.0, TAU)
		var temporal_offset := 0.0
		if index < temporal_phase_offsets.size():
			temporal_offset = temporal_phase_offsets[index]
		if not is_finite(temporal_offset):
			temporal_offset = 0.0
		temporal_offsets[index] = _wrap_phase(temporal_offset)
		effective_phases[index] = _wrap_phase(
			base_phases[index]
			+ temporal_offsets[index]
			+ wave_number * directions[index].dot(
				Vector2(logical_origin_x, logical_origin_z)
			)
		)
	var strengths := _effective_variation_strengths(mode, settings)
	return {
		"natural_variation_active": (
			settings.natural_variation_enabled and mode != MODE_CLASSIC_4
		),
		"effective_phase_warp_strength": strengths.x,
		"effective_wave_group_strength": strengths.y,
		"modulation_directions": directions,
		"modulation_wavelengths": wavelengths,
		"modulation_base_speeds": base_speeds,
		"modulation_speeds": speeds,
		"modulation_wave_numbers": wave_numbers,
		"modulation_angular_frequencies": angular_frequencies,
		"modulation_base_phases": base_phases,
		"modulation_temporal_phase_offsets": temporal_offsets,
		"modulation_effective_phases": effective_phases,
	}


static func _effective_variation_strengths(
	mode: int,
	settings: WaveSpectrumSettings
) -> Vector2:
	if not settings.natural_variation_enabled or mode == MODE_CLASSIC_4:
		return Vector2.ZERO
	match mode:
		MODE_ARCADE_8:
			return Vector2(0.18, 0.12)
		MODE_RACE_10:
			return Vector2(
				minf(settings.phase_warp_strength, 0.14),
				minf(settings.wave_group_strength, 0.09)
			)
		MODE_CROSS_CHOP_10:
			return Vector2(0.22, 0.15)
		MODE_STORM_12:
			return Vector2(0.20, 0.14)
		MODE_CUSTOM:
			return Vector2(
				settings.phase_warp_strength,
				settings.wave_group_strength
			)
	return Vector2.ZERO


static func _active_count_for_mode(mode: int, custom_count: int) -> int:
	match mode:
		MODE_CLASSIC_4:
			return 4
		MODE_ARCADE_8:
			return 8
		MODE_RACE_10, MODE_CROSS_CHOP_10:
			return 10
		MODE_STORM_12:
			return 12
		MODE_CUSTOM:
			return clampi(custom_count, 4, MAX_WAVE_COMPONENTS)
	return 4


static func _crest_shape_for_family(
	mode: int,
	family: int,
	settings: WaveSpectrumSettings
) -> float:
	if mode == MODE_CUSTOM:
		match family:
			WaveFamily.PRIMARY:
				return settings.primary_crest_shape
			WaveFamily.SECONDARY:
				return settings.secondary_crest_shape
			WaveFamily.CROSS_SWELL:
				return settings.cross_swell_crest_shape
			WaveFamily.LONG_BREAKER:
				return settings.long_breaker_crest_shape
	match mode:
		MODE_ARCADE_8:
			return [0.09, 0.05, 0.03, 0.07][family]
		MODE_RACE_10:
			return [0.07, 0.045, 0.025, 0.06][family]
		MODE_CROSS_CHOP_10:
			return [0.10, 0.07, 0.06, 0.09][family]
		MODE_STORM_12:
			return [0.18, 0.12, 0.08, 0.15][family]
	return 0.0


static func _smoothstep(edge_0: float, edge_1: float, value: float) -> float:
	var width := maxf(edge_1 - edge_0, 0.000001)
	var t := clampf((value - edge_0) / width, 0.0, 1.0)
	return t * t * (3.0 - 2.0 * t)


static func _wrap_phase(value: float) -> float:
	return fposmod(value + PI, TAU) - PI
