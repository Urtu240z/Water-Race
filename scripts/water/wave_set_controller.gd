class_name WaveSetController
extends RefCounted

const MAX_ACTIVE_WAVE_SETS: int = 3
const CARRIERS_PER_SET: int = 3
const TOTAL_CARRIERS: int = MAX_ACTIVE_WAVE_SETS * CARRIERS_PER_SET
const GRAVITY: float = 9.81
const EVENT_HASH: int = 104729
const ENERGY_EPSILON: float = 0.000000001
const CARRIER_WAVELENGTH_RATIOS := [0.88, 1.0, 1.14]
const CARRIER_AMPLITUDE_WEIGHTS := [0.24, 0.52, 0.24]
const CATEGORY_PEAK_LIMITS := [0.50, 0.85, 1.20]

enum StrengthCategory {
	GENTLE,
	MEDIUM,
	STRONG,
}

var active_flags := PackedInt32Array()
var set_ids := PackedInt32Array()
var spawn_times := PackedFloat32Array()
var focus_times := PackedFloat32Array()
var end_times := PackedFloat32Array()
var focus_positions_logical := PackedVector2Array()
var directions := PackedVector2Array()
var right_directions := PackedVector2Array()
var group_speeds := PackedFloat32Array()
var packet_lengths := PackedFloat32Array()
var packet_widths := PackedFloat32Array()
var base_wavelengths := PackedFloat32Array()
var total_amplitudes := PackedFloat32Array()
var strength_categories := PackedInt32Array()
var carrier_wavelengths := PackedFloat32Array()
var carrier_amplitudes := PackedFloat32Array()
var carrier_wave_numbers := PackedFloat32Array()
var carrier_angular_frequencies := PackedFloat32Array()
var carrier_phases := PackedFloat32Array()
var crest_sharpnesses := PackedFloat32Array()
var front_face_skews := PackedFloat32Array()
var third_harmonics := PackedFloat32Array()
var shape_normalizations := PackedFloat32Array()
var requested_peak_heights := PackedFloat32Array()
var predicted_maximum_heights := PackedFloat32Array()
var predicted_maximum_slopes := PackedFloat32Array()
var current_peak_contributions := PackedFloat32Array()
var approach_foam_factors := PackedFloat32Array()

var next_wave_set_time: float = INF
var last_wave_set_strength_category: int = StrengthCategory.GENTLE
var maximum_packet_height_contribution: float = 0.0
var maximum_breaking_metric: float = 0.0
var state_revision: int = 0
var breaking_threshold: float = 0.62
var breaking_softness: float = 0.14

var _settings: WaveSetSettings
var _mode: int = 0
var _speed_multiplier: float = 1.0
var _settings_signature: int = 0
var _event_index: int = 0
var _configured: bool = false
var _scheduler_suppressed: bool = false


func _init() -> void:
	_resize_arrays()
	_clear_slots()


func configure(
	mode: int,
	settings: WaveSetSettings,
	speed_multiplier: float,
	simulation_time: float
) -> void:
	var signature := settings.configuration_signature() if settings != null else 0
	var requires_reset := (
		not _configured
		or _mode != mode
		or _settings != settings
		or _settings_signature != signature
		or not is_equal_approx(_speed_multiplier, speed_multiplier)
	)
	_settings = settings
	_mode = mode
	_speed_multiplier = maxf(speed_multiplier, 0.0)
	_settings_signature = signature
	_configured = true
	if requires_reset:
		reset(simulation_time)


func reset(simulation_time: float) -> void:
	_clear_slots()
	_event_index = 0
	_scheduler_suppressed = false
	maximum_packet_height_contribution = 0.0
	maximum_breaking_metric = 0.0
	next_wave_set_time = (
		simulation_time + _settings.ordered_interval().x
		if _is_scheduler_enabled()
		else INF
	)
	state_revision += 1


func configure_breaking_metric(threshold: float, softness: float) -> void:
	breaking_threshold = clampf(threshold, 0.0, 2.0)
	breaking_softness = clampf(softness, 0.01, 1.0)


func clear_active_sets(simulation_time: float, suppress_scheduler: bool = false) -> void:
	_clear_slots()
	_scheduler_suppressed = suppress_scheduler
	maximum_packet_height_contribution = 0.0
	maximum_breaking_metric = 0.0
	next_wave_set_time = (
		INF
		if suppress_scheduler or not _is_scheduler_enabled()
		else simulation_time + _settings.ordered_interval().x
	)
	state_revision += 1


func update(
	simulation_time: float,
	player_position_logical: Vector2,
	player_horizontal_velocity: Vector2,
	dominant_direction: Vector2,
	target_valid: bool
) -> void:
	var changed := false
	for slot in MAX_ACTIVE_WAVE_SETS:
		if active_flags[slot] != 0 and simulation_time > end_times[slot]:
			_clear_slot(slot)
			changed = true
	if changed:
		state_revision += 1
	_update_observational_maxima(simulation_time)
	if not _is_scheduler_enabled() or _scheduler_suppressed:
		next_wave_set_time = INF
		return
	if simulation_time < next_wave_set_time:
		return
	if active_set_count() >= mini(_settings.maximum_active_sets, MAX_ACTIVE_WAVE_SETS):
		next_wave_set_time = simulation_time + 0.5
		return
	_spawn_descriptor(
		simulation_time,
		player_position_logical,
		player_horizontal_velocity,
		dominant_direction,
		target_valid,
		-1,
		-1.0,
		-1.0,
		INF
	)


func force_test_wave_set(
	simulation_time: float,
	player_position_logical: Vector2,
	player_horizontal_velocity: Vector2,
	dominant_direction: Vector2,
	strength_category: int = StrengthCategory.MEDIUM,
	focus_lead_time: float = 5.0,
	focus_distance: float = 50.0
) -> bool:
	clear_active_sets(simulation_time, true)
	return _spawn_descriptor(
		simulation_time,
		player_position_logical,
		player_horizontal_velocity,
		dominant_direction,
		true,
		clampi(strength_category, StrengthCategory.GENTLE, StrengthCategory.STRONG),
		maxf(focus_lead_time, 0.25),
		clampf(focus_distance, 40.0, 55.0),
		0.0
	)


func force_debug_wave_set(
	simulation_time: float,
	player_position_logical: Vector2,
	player_horizontal_velocity: Vector2,
	dominant_direction: Vector2,
	strength_category: int,
	focus_lead_time: float = 5.0,
	focus_distance: float = 47.5
) -> bool:
	if _settings == null:
		return false
	if active_set_count() >= mini(_settings.maximum_active_sets, MAX_ACTIVE_WAVE_SETS):
		return false
	var preserved_next_wave_set_time := next_wave_set_time
	var created := _spawn_descriptor(
		simulation_time,
		player_position_logical,
		player_horizontal_velocity,
		dominant_direction,
		true,
		clampi(strength_category, StrengthCategory.GENTLE, StrengthCategory.STRONG),
		maxf(focus_lead_time, 0.25),
		clampf(focus_distance, 40.0, 55.0),
		INF
	)
	next_wave_set_time = preserved_next_wave_set_time
	return created


func active_set_count() -> int:
	var count: int = 0
	for slot in MAX_ACTIVE_WAVE_SETS:
		count += int(active_flags[slot] != 0)
	return count


func primary_active_slot(simulation_time: float) -> int:
	var selected_slot: int = -1
	var selected_time_distance: float = INF
	for slot in MAX_ACTIVE_WAVE_SETS:
		if active_flags[slot] == 0:
			continue
		var time_distance := absf(focus_times[slot] - simulation_time)
		if time_distance < selected_time_distance:
			selected_time_distance = time_distance
			selected_slot = slot
	return selected_slot


func strongest_influence_slot(logical_xz: Vector2, sample_time: float) -> int:
	var selected_slot: int = -1
	var selected_envelope: float = 0.0
	for slot in MAX_ACTIVE_WAVE_SETS:
		if active_flags[slot] == 0:
			continue
		var envelope := sample_packet_envelope(slot, logical_xz, sample_time)
		if envelope > selected_envelope:
			selected_envelope = envelope
			selected_slot = slot
	return selected_slot if selected_envelope >= 0.08 else -1


func sample_packet_envelope(slot: int, logical_xz: Vector2, sample_time: float) -> float:
	if slot < 0 or slot >= MAX_ACTIVE_WAVE_SETS or active_flags[slot] == 0:
		return 0.0
	var half_length := maxf(packet_lengths[slot] * 0.5, 0.001)
	var half_width := maxf(packet_widths[slot] * 0.5, 0.001)
	var relative := logical_xz - _packet_center(slot, sample_time)
	var normalized_along := relative.dot(directions[slot]) / half_length
	var normalized_across := relative.dot(right_directions[slot]) / half_width
	return exp(-pow(normalized_along, 4.0) - pow(normalized_across, 4.0))


func sample_slot_height(slot: int, logical_xz: Vector2, sample_time: float) -> float:
	var envelope := sample_packet_envelope(slot, logical_xz, sample_time)
	if envelope <= 0.0000001:
		return 0.0
	var height: float = 0.0
	for carrier in CARRIERS_PER_SET:
		var index := slot * CARRIERS_PER_SET + carrier
		var theta := (
			carrier_wave_numbers[index] * directions[slot].dot(logical_xz)
			- carrier_angular_frequencies[index] * sample_time
			+ carrier_phases[index]
		)
		height += carrier_amplitudes[index] * envelope * _breaker_shape(slot, theta)
	return height


func sample_slot_peak_observation(slot: int, sample_time: float) -> Vector4:
	if slot < 0 or slot >= MAX_ACTIVE_WAVE_SETS or active_flags[slot] == 0:
		return Vector4.ZERO
	return _sample_slot_peak_observation(slot, sample_time)


func sample_surface_state(logical_xz: Vector2, sample_time: float) -> Vector4:
	var total_height: float = 0.0
	var total_derivative_x: float = 0.0
	var total_derivative_z: float = 0.0
	var total_vertical_velocity: float = 0.0
	for slot in MAX_ACTIVE_WAVE_SETS:
		if active_flags[slot] == 0:
			continue
		var direction := directions[slot]
		var right := right_directions[slot]
		var half_length := maxf(packet_lengths[slot] * 0.5, 0.001)
		var half_width := maxf(packet_widths[slot] * 0.5, 0.001)
		var packet_center := (
			focus_positions_logical[slot]
			+ direction * group_speeds[slot] * (sample_time - focus_times[slot])
		)
		var relative := logical_xz - packet_center
		var normalized_along := relative.dot(direction) / half_length
		var normalized_across := relative.dot(right) / half_width
		var along_squared := normalized_along * normalized_along
		var across_squared := normalized_across * normalized_across
		var envelope := exp(
			-along_squared * along_squared
			- across_squared * across_squared
		)
		if envelope < 0.0000001:
			continue
		var envelope_exponent_dx := (
			-4.0 * normalized_along * along_squared * direction.x / half_length
			- 4.0 * normalized_across * across_squared * right.x / half_width
		)
		var envelope_exponent_dz := (
			-4.0 * normalized_along * along_squared * direction.y / half_length
			- 4.0 * normalized_across * across_squared * right.y / half_width
		)
		var normalized_along_dt := -group_speeds[slot] / half_length
		var envelope_exponent_dt := (
			-4.0 * normalized_along * along_squared * normalized_along_dt
		)
		var envelope_dx := envelope * envelope_exponent_dx
		var envelope_dz := envelope * envelope_exponent_dz
		var envelope_dt := envelope * envelope_exponent_dt
		for carrier in CARRIERS_PER_SET:
			var carrier_index := slot * CARRIERS_PER_SET + carrier
			var wave_number := carrier_wave_numbers[carrier_index]
			var angular_frequency := carrier_angular_frequencies[carrier_index]
			var theta := (
				wave_number * direction.dot(logical_xz)
				- angular_frequency * sample_time
				+ carrier_phases[carrier_index]
			)
			var shape := _breaker_shape(slot, theta)
			var shape_derivative := _breaker_shape_derivative(slot, theta)
			var amplitude := carrier_amplitudes[carrier_index]
			var phase_dx := wave_number * direction.x
			var phase_dz := wave_number * direction.y
			var phase_dt := -angular_frequency
			total_height += amplitude * envelope * shape
			total_derivative_x += amplitude * (
				envelope_dx * shape
				+ envelope * shape_derivative * phase_dx
			)
			total_derivative_z += amplitude * (
				envelope_dz * shape
				+ envelope * shape_derivative * phase_dz
			)
			total_vertical_velocity += amplitude * (
				envelope_dt * shape
				+ envelope * shape_derivative * phase_dt
			)
	return Vector4(
		total_height,
		total_derivative_x,
		total_derivative_z,
		total_vertical_velocity
	)


func sample_breaking_metric(logical_xz: Vector2, sample_time: float) -> float:
	var maximum_metric: float = 0.0
	for slot in MAX_ACTIVE_WAVE_SETS:
		if active_flags[slot] == 0:
			continue
		var direction := directions[slot]
		var right := right_directions[slot]
		var half_length := maxf(packet_lengths[slot] * 0.5, 0.001)
		var half_width := maxf(packet_widths[slot] * 0.5, 0.001)
		var packet_center := (
			focus_positions_logical[slot]
			+ direction * group_speeds[slot] * (sample_time - focus_times[slot])
		)
		var relative := logical_xz - packet_center
		var normalized_along := relative.dot(direction) / half_length
		var normalized_across := relative.dot(right) / half_width
		var envelope := exp(
			-pow(normalized_along, 4.0)
			- pow(normalized_across, 4.0)
		)
		if envelope < 0.000001:
			continue
		var envelope_dt := envelope * (
			-4.0 * pow(normalized_along, 3.0)
			* (-group_speeds[slot] / half_length)
		)
		var set_height: float = 0.0
		var set_vertical_velocity: float = 0.0
		var curvature_signal: float = 0.0
		var front_face_signal: float = 0.0
		var amplitude_scale := maxf(total_amplitudes[slot], 0.001)
		for carrier in CARRIERS_PER_SET:
			var carrier_index := slot * CARRIERS_PER_SET + carrier
			var wave_number := carrier_wave_numbers[carrier_index]
			var angular_frequency := carrier_angular_frequencies[carrier_index]
			var theta := (
				wave_number * direction.dot(logical_xz)
				- angular_frequency * sample_time
				+ carrier_phases[carrier_index]
			)
			var shape := _breaker_shape(slot, theta)
			var shape_derivative := _breaker_shape_derivative(slot, theta)
			var shape_second_derivative := _breaker_shape_second_derivative(slot, theta)
			var amplitude := carrier_amplitudes[carrier_index]
			set_height += amplitude * envelope * shape
			set_vertical_velocity += amplitude * (
				envelope_dt * shape
				- envelope * shape_derivative * angular_frequency
			)
			curvature_signal += (
				amplitude * maxf(-shape_second_derivative, 0.0) / amplitude_scale
			)
			front_face_signal += maxf(
				-amplitude * shape_derivative * wave_number,
				0.0
			) / amplitude_scale
		var softness := maxf(_foam_breaking_softness(), 0.01)
		var threshold := _foam_breaking_threshold()
		var crest_factor := smoothstep(
			threshold - softness,
			threshold + softness,
			maxf(set_height / amplitude_scale, 0.0)
		)
		var curvature_factor := smoothstep(0.18, 0.85, curvature_signal)
		var front_face_factor := smoothstep(0.02, 0.18, front_face_signal)
		var rise_factor := smoothstep(0.02, 0.55, maxf(set_vertical_velocity, 0.0))
		var strength_factor := lerpf(
			0.75,
			1.0,
			float(strength_categories[slot]) / float(StrengthCategory.STRONG)
		)
		var metric := (
			envelope
			* crest_factor
			* maxf(curvature_factor, front_face_factor)
			* lerpf(0.75, 1.0, rise_factor)
			* strength_factor
		)
		maximum_metric = maxf(maximum_metric, metric)
	return clampf(maximum_metric, 0.0, 1.0)


func shader_focus_positions(logical_origin: Vector2) -> PackedVector2Array:
	var values := PackedVector2Array()
	values.resize(MAX_ACTIVE_WAVE_SETS)
	for slot in MAX_ACTIVE_WAVE_SETS:
		values[slot] = focus_positions_logical[slot] - logical_origin
	return values


func shader_carrier_phases(logical_origin: Vector2) -> PackedFloat32Array:
	var values := PackedFloat32Array()
	values.resize(TOTAL_CARRIERS)
	for slot in MAX_ACTIVE_WAVE_SETS:
		for carrier in CARRIERS_PER_SET:
			var index := slot * CARRIERS_PER_SET + carrier
			values[index] = _wrap_phase(
				carrier_phases[index]
				+ carrier_wave_numbers[index] * directions[slot].dot(logical_origin)
			)
	return values


func _spawn_descriptor(
	simulation_time: float,
	player_position_logical: Vector2,
	player_horizontal_velocity: Vector2,
	dominant_direction: Vector2,
	target_valid: bool,
	forced_strength_category: int,
	forced_focus_lead_time: float,
	forced_focus_distance: float,
	forced_lateral_offset: float
) -> bool:
	if _settings == null:
		return false
	var slot := _find_inactive_slot()
	if slot < 0:
		return false
	var rng := RandomNumberGenerator.new()
	rng.seed = _settings.wave_set_seed + _event_index * EVENT_HASH
	var event_id := _event_index
	_event_index += 1
	var direction := dominant_direction.normalized()
	if direction.is_zero_approx() or not direction.is_finite():
		direction = Vector2.RIGHT
	var jitter_degrees := rng.randf_range(
		-_settings.direction_jitter_degrees,
		_settings.direction_jitter_degrees
	)
	direction = direction.rotated(deg_to_rad(jitter_degrees)).normalized()
	var right := Vector2(-direction.y, direction.x)
	var lead_range := _settings.ordered_focus_lead_time()
	var focus_lead_time := (
		forced_focus_lead_time
		if forced_focus_lead_time > 0.0
		else rng.randf_range(lead_range.x, lead_range.y)
	)
	var distance_range := _settings.ordered_focus_distance()
	var focus_distance := (
		forced_focus_distance
		if forced_focus_distance > 0.0
		else rng.randf_range(distance_range.x, distance_range.y)
	)
	var lateral_offset := (
		forced_lateral_offset
		if is_finite(forced_lateral_offset)
		else rng.randf_range(
			-_settings.lateral_focus_variation,
			_settings.lateral_focus_variation
		)
	)
	var natural_focus := (
		player_position_logical
		+ direction * focus_distance
		+ right * lateral_offset
	)
	var focus_position := natural_focus
	if forced_focus_distance > 0.0 and target_valid:
		var predicted_offset := player_horizontal_velocity * focus_lead_time
		var predicted_distance := minf(predicted_offset.length(), focus_distance)
		var trajectory_direction := (
			predicted_offset.normalized()
			if predicted_offset.length_squared() > 0.000001
			else direction
		)
		focus_position = (
			player_position_logical
			+ trajectory_direction * predicted_distance
			+ direction * (focus_distance - predicted_distance)
			+ right * lateral_offset
		)
	elif _mode == 2 and target_valid:
		var predicted_position := (
			player_position_logical
			+ player_horizontal_velocity * focus_lead_time
		)
		var assisted_focus := predicted_position + direction * focus_distance * 0.35
		focus_position = natural_focus.lerp(
			assisted_focus,
			clampf(_settings.player_path_bias, 0.0, 1.0)
		)
		var assisted_offset := focus_position - player_position_logical
		if assisted_offset.length_squared() <= 0.000001:
			assisted_offset = direction * focus_distance + right * lateral_offset
		var assisted_distance := clampf(
			assisted_offset.length(),
			distance_range.x,
			distance_range.y
		)
		focus_position = (
			player_position_logical
			+ assisted_offset.normalized() * assisted_distance
		)
	var packet_length_range := _settings.ordered_packet_length()
	var packet_width_range := _settings.ordered_packet_width()
	var wavelength_range := _settings.ordered_wavelength()
	var packet_length := rng.randf_range(packet_length_range.x, packet_length_range.y)
	var packet_width := rng.randf_range(packet_width_range.x, packet_width_range.y)
	var base_wavelength := rng.randf_range(wavelength_range.x, wavelength_range.y)
	var strength_category := (
		forced_strength_category
		if forced_strength_category >= 0
		else _choose_strength_category(rng)
	)
	var total_amplitude := _choose_total_amplitude(rng, strength_category)
	var crest_sharpness := clampf(
		_settings.strong_crest_sharpness
		if strength_category == StrengthCategory.STRONG
		else _settings.crest_sharpness,
		0.0,
		0.24
	)
	var front_face_skew := clampf(
		_settings.strong_front_face_skew
		if strength_category == StrengthCategory.STRONG
		else _settings.front_face_skew,
		-0.15,
		0.15
	)
	var third_harmonic := clampf(
		_settings.strong_third_harmonic
		if strength_category == StrengthCategory.STRONG
		else _settings.third_harmonic,
		0.0,
		0.07
	)
	var normalization := 1.0 / sqrt(
		1.0
		+ crest_sharpness * crest_sharpness
		+ front_face_skew * front_face_skew
		+ third_harmonic * third_harmonic
	)
	var focus_time := simulation_time + focus_lead_time
	var center_wave_number := TAU / maxf(base_wavelength, 0.001)
	var center_angular_frequency := sqrt(GRAVITY * center_wave_number) * _speed_multiplier
	var group_speed := (
		center_angular_frequency / center_wave_number
		* 0.5
		* _settings.group_speed_multiplier
	)
	active_flags[slot] = 1
	set_ids[slot] = event_id
	spawn_times[slot] = simulation_time
	focus_times[slot] = focus_time
	focus_positions_logical[slot] = focus_position
	directions[slot] = direction
	right_directions[slot] = right
	group_speeds[slot] = group_speed
	packet_lengths[slot] = packet_length
	packet_widths[slot] = packet_width
	base_wavelengths[slot] = base_wavelength
	requested_peak_heights[slot] = total_amplitude
	total_amplitudes[slot] = total_amplitude
	strength_categories[slot] = strength_category
	crest_sharpnesses[slot] = crest_sharpness
	front_face_skews[slot] = front_face_skew
	third_harmonics[slot] = third_harmonic
	shape_normalizations[slot] = normalization
	var weight_energy: float = 0.0
	for weight: float in CARRIER_AMPLITUDE_WEIGHTS:
		weight_energy += weight * weight
	var weight_normalization := sqrt(maxf(weight_energy, ENERGY_EPSILON))
	for carrier in CARRIERS_PER_SET:
		var carrier_index := slot * CARRIERS_PER_SET + carrier
		var wavelength: float = (
			base_wavelength * float(CARRIER_WAVELENGTH_RATIOS[carrier])
		)
		var wave_number := TAU / maxf(wavelength, 0.001)
		var angular_frequency := sqrt(GRAVITY * wave_number) * _speed_multiplier
		var amplitude: float = (
			total_amplitude
			* float(CARRIER_AMPLITUDE_WEIGHTS[carrier])
			/ weight_normalization
		)
		carrier_wavelengths[carrier_index] = wavelength
		carrier_amplitudes[carrier_index] = amplitude
		carrier_wave_numbers[carrier_index] = wave_number
		carrier_angular_frequencies[carrier_index] = angular_frequency
		carrier_phases[carrier_index] = _wrap_phase(
			PI * 0.5
			- wave_number * direction.dot(focus_position)
			+ angular_frequency * focus_time
		)
	_normalize_descriptor_peak(slot, strength_category)
	_limit_carrier_slope(slot)
	_update_descriptor_predictions(slot)
	var visible_travel_time := packet_length * 2.5 / maxf(group_speed, 0.1)
	end_times[slot] = focus_time + maxf(visible_travel_time, 12.0)
	last_wave_set_strength_category = strength_category
	maximum_packet_height_contribution = maxf(
		maximum_packet_height_contribution,
		_maximum_height_bound_for_slot(slot)
	)
	if not _scheduler_suppressed:
		var interval_range := _settings.ordered_interval()
		next_wave_set_time = simulation_time + rng.randf_range(
			interval_range.x,
			interval_range.y
		)
	else:
		next_wave_set_time = INF
	state_revision += 1
	return true


func _choose_strength_category(rng: RandomNumberGenerator) -> int:
	var probabilities := _settings.normalized_strength_probabilities()
	var roll := rng.randf()
	if roll < probabilities.x:
		return StrengthCategory.GENTLE
	if roll < probabilities.x + probabilities.y:
		return StrengthCategory.MEDIUM
	return StrengthCategory.STRONG


func _choose_total_amplitude(rng: RandomNumberGenerator, category: int) -> float:
	var amplitude_range: Vector2
	match category:
		StrengthCategory.MEDIUM:
			amplitude_range = Vector2(
				_settings.medium_amplitude_min,
				_settings.medium_amplitude_max
			)
		StrengthCategory.STRONG:
			amplitude_range = Vector2(
				_settings.strong_amplitude_min,
				_settings.strong_amplitude_max
			)
		_:
			amplitude_range = Vector2(
				_settings.gentle_amplitude_min,
				_settings.gentle_amplitude_max
			)
	var minimum := maxf(minf(amplitude_range.x, amplitude_range.y), 0.0)
	var maximum := maxf(amplitude_range.x, amplitude_range.y)
	var amplitude := rng.randf_range(minimum, maximum)
	return clampf(amplitude, 0.0, 1.5) if is_finite(amplitude) else minimum


func _limit_carrier_slope(slot: int) -> void:
	var estimated_slope := _predicted_slope_for_slot(slot)
	if estimated_slope <= 1.8 or estimated_slope <= 0.0:
		return
	var scale := 1.8 / estimated_slope
	_scale_slot_amplitudes(slot, scale)


func _normalize_descriptor_peak(slot: int, category: int) -> void:
	var current_bound := _maximum_height_bound_for_slot(slot)
	if current_bound <= ENERGY_EPSILON:
		return
	var category_limit := float(CATEGORY_PEAK_LIMITS[clampi(
		category,
		StrengthCategory.GENTLE,
		StrengthCategory.STRONG
	)])
	var target_peak := minf(requested_peak_heights[slot], category_limit)
	_scale_slot_amplitudes(slot, target_peak / current_bound)


func _scale_slot_amplitudes(slot: int, scale: float) -> void:
	var safe_scale := maxf(scale, 0.0) if is_finite(scale) else 0.0
	for carrier in CARRIERS_PER_SET:
		var index := slot * CARRIERS_PER_SET + carrier
		carrier_amplitudes[index] *= safe_scale


func _predicted_slope_for_slot(slot: int) -> float:
	var shape_slope_bound := (
		1.0
		+ 2.0 * crest_sharpnesses[slot]
		+ 2.0 * absf(front_face_skews[slot])
		+ 3.0 * third_harmonics[slot]
	) * shape_normalizations[slot]
	var estimated_slope: float = 0.0
	for carrier in CARRIERS_PER_SET:
		var index := slot * CARRIERS_PER_SET + carrier
		estimated_slope += (
			carrier_amplitudes[index]
			* carrier_wave_numbers[index]
			* shape_slope_bound
		)
	return estimated_slope


func _update_descriptor_predictions(slot: int) -> void:
	predicted_maximum_heights[slot] = _maximum_height_bound_for_slot(slot)
	predicted_maximum_slopes[slot] = _predicted_slope_for_slot(slot)
	total_amplitudes[slot] = predicted_maximum_heights[slot]


func _update_observational_maxima(simulation_time: float) -> void:
	maximum_packet_height_contribution = 0.0
	maximum_breaking_metric = 0.0
	for slot in MAX_ACTIVE_WAVE_SETS:
		if active_flags[slot] == 0:
			continue
		var observation := _sample_slot_peak_observation(slot, simulation_time)
		current_peak_contributions[slot] = observation.x
		approach_foam_factors[slot] = _calculate_approach_foam_factor(
			slot,
			simulation_time,
			observation
		)
		maximum_packet_height_contribution = maxf(
			maximum_packet_height_contribution,
			_maximum_height_bound_for_slot(slot)
		)
		maximum_breaking_metric = maxf(
			maximum_breaking_metric,
			sample_breaking_metric(focus_positions_logical[slot], simulation_time)
		)


func _sample_slot_peak_observation(slot: int, sample_time: float) -> Vector4:
	var packet_center := _packet_center(slot, sample_time)
	var maximum_height: float = 0.0
	var selected_slope: float = 0.0
	var selected_curvature: float = 0.0
	var selected_envelope: float = 0.0
	for offset_index in 5:
		var along_offset := (float(offset_index) - 2.0) * base_wavelengths[slot] * 0.48
		var sample_xz := packet_center + directions[slot] * along_offset
		var envelope := sample_packet_envelope(slot, sample_xz, sample_time)
		var height: float = 0.0
		var derivative := Vector2.ZERO
		var curvature: float = 0.0
		for carrier in CARRIERS_PER_SET:
			var index := slot * CARRIERS_PER_SET + carrier
			var theta := (
				carrier_wave_numbers[index] * directions[slot].dot(sample_xz)
				- carrier_angular_frequencies[index] * sample_time
				+ carrier_phases[index]
			)
			var amplitude := carrier_amplitudes[index]
			var shape := _breaker_shape(slot, theta)
			var shape_derivative := _breaker_shape_derivative(slot, theta)
			var shape_second := _breaker_shape_second_derivative(slot, theta)
			height += amplitude * envelope * shape
			derivative += (
				directions[slot] * amplitude * envelope
				* shape_derivative * carrier_wave_numbers[index]
			)
			curvature += maxf(
				-amplitude * envelope * shape_second
					* carrier_wave_numbers[index] * carrier_wave_numbers[index],
				0.0
			)
		if height > maximum_height:
			maximum_height = height
			selected_slope = derivative.length()
			selected_curvature = curvature
			selected_envelope = envelope
	return Vector4(
		maximum_height,
		selected_slope,
		selected_curvature,
		selected_envelope
	)


func _calculate_approach_foam_factor(
	slot: int,
	sample_time: float,
	observation: Vector4
) -> float:
	var time_to_focus := focus_times[slot] - sample_time
	var temporal_factor: float = 0.0
	if time_to_focus > 6.0:
		temporal_factor = 0.0
	elif time_to_focus > 4.0:
		temporal_factor = lerpf(0.0, 0.18, inverse_lerp(6.0, 4.0, time_to_focus))
	elif time_to_focus > 2.0:
		temporal_factor = lerpf(0.18, 0.58, inverse_lerp(4.0, 2.0, time_to_focus))
	elif time_to_focus >= 0.0:
		temporal_factor = lerpf(0.58, 1.0, inverse_lerp(2.0, 0.0, time_to_focus))
	else:
		temporal_factor = 1.0 - smoothstep(0.0, 4.0, -time_to_focus)
	var expected_peak := maxf(predicted_maximum_heights[slot], 0.001)
	var interference_factor := smoothstep(0.18, 0.78, observation.x / expected_peak)
	var slope_factor := smoothstep(0.04, 0.22, observation.y)
	var curvature_factor := smoothstep(0.002, 0.025, observation.z)
	return clampf(
		temporal_factor * observation.w
			* maxf(slope_factor, curvature_factor) * interference_factor,
		0.0,
		1.0
	)


func _packet_center(slot: int, sample_time: float) -> Vector2:
	return (
		focus_positions_logical[slot]
		+ directions[slot] * group_speeds[slot]
			* (sample_time - focus_times[slot])
	)


func _maximum_height_bound_for_slot(slot: int) -> float:
	var shape_bound := shape_normalizations[slot] * (
		1.0
		+ crest_sharpnesses[slot]
		+ absf(front_face_skews[slot])
		+ third_harmonics[slot]
	)
	var bound: float = 0.0
	for carrier in CARRIERS_PER_SET:
		bound += carrier_amplitudes[slot * CARRIERS_PER_SET + carrier] * shape_bound
	return bound


func _breaker_shape(slot: int, theta: float) -> float:
	return shape_normalizations[slot] * (
		sin(theta)
		- crest_sharpnesses[slot] * cos(2.0 * theta)
		+ front_face_skews[slot] * sin(2.0 * theta)
		+ third_harmonics[slot] * sin(3.0 * theta)
	)


func _breaker_shape_derivative(slot: int, theta: float) -> float:
	return shape_normalizations[slot] * (
		cos(theta)
		+ 2.0 * crest_sharpnesses[slot] * sin(2.0 * theta)
		+ 2.0 * front_face_skews[slot] * cos(2.0 * theta)
		+ 3.0 * third_harmonics[slot] * cos(3.0 * theta)
	)


func _breaker_shape_second_derivative(slot: int, theta: float) -> float:
	return shape_normalizations[slot] * (
		-sin(theta)
		+ 4.0 * crest_sharpnesses[slot] * cos(2.0 * theta)
		- 4.0 * front_face_skews[slot] * sin(2.0 * theta)
		- 9.0 * third_harmonics[slot] * sin(3.0 * theta)
	)


func _foam_breaking_threshold() -> float:
	return breaking_threshold


func _foam_breaking_softness() -> float:
	return breaking_softness


func _is_scheduler_enabled() -> bool:
	return _settings != null and _settings.enabled and _mode != 0


func _find_inactive_slot() -> int:
	for slot in MAX_ACTIVE_WAVE_SETS:
		if active_flags[slot] == 0:
			return slot
	return -1


func _resize_arrays() -> void:
	active_flags.resize(MAX_ACTIVE_WAVE_SETS)
	set_ids.resize(MAX_ACTIVE_WAVE_SETS)
	strength_categories.resize(MAX_ACTIVE_WAVE_SETS)
	spawn_times.resize(MAX_ACTIVE_WAVE_SETS)
	focus_times.resize(MAX_ACTIVE_WAVE_SETS)
	end_times.resize(MAX_ACTIVE_WAVE_SETS)
	group_speeds.resize(MAX_ACTIVE_WAVE_SETS)
	packet_lengths.resize(MAX_ACTIVE_WAVE_SETS)
	packet_widths.resize(MAX_ACTIVE_WAVE_SETS)
	base_wavelengths.resize(MAX_ACTIVE_WAVE_SETS)
	total_amplitudes.resize(MAX_ACTIVE_WAVE_SETS)
	crest_sharpnesses.resize(MAX_ACTIVE_WAVE_SETS)
	front_face_skews.resize(MAX_ACTIVE_WAVE_SETS)
	third_harmonics.resize(MAX_ACTIVE_WAVE_SETS)
	shape_normalizations.resize(MAX_ACTIVE_WAVE_SETS)
	requested_peak_heights.resize(MAX_ACTIVE_WAVE_SETS)
	predicted_maximum_heights.resize(MAX_ACTIVE_WAVE_SETS)
	predicted_maximum_slopes.resize(MAX_ACTIVE_WAVE_SETS)
	current_peak_contributions.resize(MAX_ACTIVE_WAVE_SETS)
	approach_foam_factors.resize(MAX_ACTIVE_WAVE_SETS)
	focus_positions_logical.resize(MAX_ACTIVE_WAVE_SETS)
	directions.resize(MAX_ACTIVE_WAVE_SETS)
	right_directions.resize(MAX_ACTIVE_WAVE_SETS)
	carrier_wavelengths.resize(TOTAL_CARRIERS)
	carrier_amplitudes.resize(TOTAL_CARRIERS)
	carrier_wave_numbers.resize(TOTAL_CARRIERS)
	carrier_angular_frequencies.resize(TOTAL_CARRIERS)
	carrier_phases.resize(TOTAL_CARRIERS)


func _clear_slots() -> void:
	for slot in MAX_ACTIVE_WAVE_SETS:
		_clear_slot(slot)


func _clear_slot(slot: int) -> void:
	active_flags[slot] = 0
	set_ids[slot] = -1
	spawn_times[slot] = 0.0
	focus_times[slot] = 0.0
	end_times[slot] = 0.0
	focus_positions_logical[slot] = Vector2.ZERO
	directions[slot] = Vector2.RIGHT
	right_directions[slot] = Vector2.DOWN
	group_speeds[slot] = 0.0
	packet_lengths[slot] = 1.0
	packet_widths[slot] = 1.0
	base_wavelengths[slot] = 1.0
	total_amplitudes[slot] = 0.0
	strength_categories[slot] = StrengthCategory.GENTLE
	crest_sharpnesses[slot] = 0.0
	front_face_skews[slot] = 0.0
	third_harmonics[slot] = 0.0
	shape_normalizations[slot] = 1.0
	requested_peak_heights[slot] = 0.0
	predicted_maximum_heights[slot] = 0.0
	predicted_maximum_slopes[slot] = 0.0
	current_peak_contributions[slot] = 0.0
	approach_foam_factors[slot] = 0.0
	for carrier in CARRIERS_PER_SET:
		var index := slot * CARRIERS_PER_SET + carrier
		carrier_wavelengths[index] = 1.0
		carrier_amplitudes[index] = 0.0
		carrier_wave_numbers[index] = 0.0
		carrier_angular_frequencies[index] = 0.0
		carrier_phases[index] = 0.0


func _wrap_phase(value: float) -> float:
	return fposmod(value + PI, TAU) - PI
