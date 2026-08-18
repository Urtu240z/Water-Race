extends Node

## Project-native Phase 0 CPU baseline for the current Ocean3D implementation.
##
## This benchmark intentionally uses only the existing public query API. It
## does not introduce batching, raw height buffers, analytic waves, or a new
## query service. Interaction fixtures are development-only snapshots that
## make the current bounded CPU loops reproducible.

const DEFAULT_THROUGHPUT_CALLS := 1200
const DEFAULT_WORKLOAD_OBSERVATIONS := 120
const DEFAULT_MAINTENANCE_ITERATIONS := 400
const DEFAULT_WARMUP_CALLS := 120
const QUICK_THROUGHPUT_CALLS := 240
const QUICK_WORKLOAD_OBSERVATIONS := 40
const QUICK_MAINTENANCE_ITERATIONS := 80
const QUICK_WARMUP_CALLS := 40
const THROUGHPUT_CHUNK_SIZE := 40
const POSITION_SEQUENCE_SIZE := 512
const CPU_PRECONDITION_USEC := 2_000_000
const STABILITY_CONTROL_QUERY_COUNT := 256
const DEFAULT_STABILITY_CONTROL_OBSERVATIONS := 7
const QUICK_STABILITY_CONTROL_OBSERVATIONS := 3
const STABILITY_CONTROL_WARMUP_QUERIES := 32
const MAXIMUM_CONTROL_MEDIAN_SPREAD := 0.25
const MINIMUM_WORKLOAD_LINEARITY := 0.75
const MAXIMUM_WORKLOAD_LINEARITY := 1.35
const OUTPUT_DIRECTORY := "res://.godot/ocean_benchmarks"
const FIXTURE_CENTER := Vector2.ZERO
const FAR_CENTER := Vector2(360.0, 360.0)

@export var auto_run := true
@export var quit_when_finished := true

@onready var _ocean: Ocean3D = $Ocean3D

var _throughput_calls := DEFAULT_THROUGHPUT_CALLS
var _workload_observations := DEFAULT_WORKLOAD_OBSERVATIONS
var _maintenance_iterations := DEFAULT_MAINTENANCE_ITERATIONS
var _warmup_calls := DEFAULT_WARMUP_CALLS
var _stability_control_observations := DEFAULT_STABILITY_CONTROL_OBSERVATIONS
var _rows: Array[Dictionary] = []
var _stability_controls: Array[Dictionary] = []
var _event_wave_owners: Array[Node] = []
var _near_positions := PackedVector3Array()
var _far_positions := PackedVector3Array()
var _sink_float := 0.0
var _sink_vector := Vector3.ZERO
var _failure_count := 0
var _started_usec := 0
var _precondition_calls := 0
var _stability: Dictionary = {}


func _ready() -> void:
	if not auto_run:
		return
	call_deferred(&"_run")


func _run() -> void:
	_started_usec = Time.get_ticks_usec()
	_apply_command_line_options()
	if not await _wait_until_ocean_ready():
		_finish_with_error("Ocean3D height images were not ready after 180 frames.")
		return
	_prepare_runner_state()
	_build_position_sequences()
	if _has_user_argument("--precondition"):
		_precondition_cpu()
		await _cool_down()
	print(
		"OCEAN_PHASE_0_BEGIN mode=%s throughput_calls=%d workload_observations=%d"
		% [
			"quick" if _is_quick_run() else "full",
			_throughput_calls,
			_workload_observations,
		]
	)
	var existing_before := _measure_stability_control("existing_api_empty", "before")
	_run_existing_api_baseline()
	var existing_after := _measure_stability_control("existing_api_empty", "after")
	_attach_local_control("existing_api", "empty", existing_before, existing_after)
	await _cool_down()
	await _run_interaction_scaling()
	await _cool_down()
	var maintenance_before := _measure_stability_control(
		"runtime_maintenance_combined_maximum",
		"before"
	)
	_run_runtime_maintenance()
	_clear_all_fixtures()
	var maintenance_after := _measure_stability_control(
		"runtime_maintenance_combined_maximum",
		"after"
	)
	_attach_local_control(
		"runtime_maintenance",
		"*",
		maintenance_before,
		maintenance_after
	)
	var report := _build_report()
	var paths := _write_report(report)
	_print_summary(paths)
	if _failure_count > 0:
		_finish_with_error(
			"Phase 0 completed with %d fixture validation failure(s)."
			% _failure_count
		)
		return
	print("OCEAN_PHASE_0_BENCHMARK=PASS")
	if quit_when_finished:
		get_tree().quit(0)


func _apply_command_line_options() -> void:
	if not _is_quick_run():
		return
	_throughput_calls = QUICK_THROUGHPUT_CALLS
	_workload_observations = QUICK_WORKLOAD_OBSERVATIONS
	_maintenance_iterations = QUICK_MAINTENANCE_ITERATIONS
	_warmup_calls = QUICK_WARMUP_CALLS
	_stability_control_observations = QUICK_STABILITY_CONTROL_OBSERVATIONS


func _is_quick_run() -> bool:
	return _has_user_argument("--quick")


func _has_user_argument(expected: String) -> bool:
	for argument: String in OS.get_cmdline_user_args():
		if argument == expected:
			return true
	return false


func _wait_until_ocean_ready() -> bool:
	for _frame in 180:
		if (
			_ocean != null
			and _ocean.get("_wave_image_a") is Image
			and _ocean.get("_wave_image_b") is Image
		):
			return true
		await get_tree().process_frame
	return false


func _prepare_runner_state() -> void:
	_ocean.process_mode = Node.PROCESS_MODE_DISABLED
	var surface := _ocean.get_surface()
	if surface != null:
		surface.visible = false
	_ocean.set_vehicle_interaction_quality(2)
	_ocean.set("_effective_ripple_count", Ocean3D.MAX_RIPPLES)
	_ocean.set(
		"_effective_directional_wake_sample_count",
		Ocean3D.MAX_DIRECTIONAL_WAKE_SEGMENTS
	)
	_ocean.set(
		"_effective_landing_impact_count",
		Ocean3D.MAX_LANDING_IMPACTS
	)
	_clear_all_fixtures()


func _build_position_sequences() -> void:
	_near_positions.resize(POSITION_SEQUENCE_SIZE)
	_far_positions.resize(POSITION_SEQUENCE_SIZE)
	for index in POSITION_SEQUENCE_SIZE:
		var progress := float(index) / float(POSITION_SEQUENCE_SIZE - 1)
		var x := lerpf(-32.0, 32.0, progress)
		var z := sin(progress * TAU * 5.0) * 4.0 + cos(progress * TAU * 2.0)
		_near_positions[index] = Vector3(x, 0.0, z)
		_far_positions[index] = Vector3(
			FAR_CENTER.x + x,
			0.0,
			FAR_CENTER.y + z
		)


func _precondition_cpu() -> void:
	# Modern laptop CPUs can begin at a short-lived turbo frequency and settle
	# at a much lower sustained clock. Preconditioning prevents scenario order
	# from masquerading as Ocean3D interaction scaling.
	_clear_all_fixtures()
	var sample := WaterSample3D.new()
	var started := Time.get_ticks_usec()
	var position_index := 0
	while Time.get_ticks_usec() - started < CPU_PRECONDITION_USEC:
		_ocean.sample_water(
			_near_positions[position_index % _near_positions.size()],
			sample
		)
		_sink_float += sample.signed_depth
		position_index += 1
	_precondition_calls = position_index


# ---------------------------------------------------------------------------
# Phase 0A: existing API only
# ---------------------------------------------------------------------------

func _run_existing_api_baseline() -> void:
	_clear_all_fixtures()
	var fixed_positions := PackedVector3Array([Vector3.ZERO])
	_append_throughput_rows("existing_api", "empty", "fixed", fixed_positions)
	_append_throughput_rows("existing_api", "empty", "sequence", _near_positions)
	_append_physics_workload_rows(
		"existing_api",
		"empty",
		"sequence",
		_near_positions
	)


func _append_throughput_rows(
	section: String,
	scenario: String,
	path_name: String,
	positions: PackedVector3Array
) -> void:
	_add_row(
		section,
		scenario,
		path_name,
		"sample_height",
		"us_per_call",
		_measure_height_throughput(positions)
	)
	_add_row(
		section,
		scenario,
		path_name,
		"sample_normal",
		"us_per_call",
		_measure_normal_throughput(positions)
	)
	_add_row(
		section,
		scenario,
		path_name,
		"sample_water",
		"us_per_call",
		_measure_water_throughput(positions)
	)


func _append_physics_workload_rows(
	section: String,
	scenario: String,
	path_name: String,
	positions: PackedVector3Array
) -> void:
	_add_row(
		section,
		scenario,
		path_name,
		"physics_workload_4_queries",
		"us_per_workload",
		_measure_water_workload(positions, 4)
	)
	_add_row(
		section,
		scenario,
		path_name,
		"physics_workload_16_queries",
		"us_per_workload",
		_measure_water_workload(positions, 16)
	)


func _measure_height_throughput(positions: PackedVector3Array) -> Dictionary:
	var position_count := positions.size()
	for index in _warmup_calls:
		_sink_float += _ocean.sample_height(positions[index % position_count])
	var timings := PackedFloat64Array()
	var completed := 0
	while completed < _throughput_calls:
		var calls_this_chunk := mini(
			THROUGHPUT_CHUNK_SIZE,
			_throughput_calls - completed
		)
		var started := Time.get_ticks_usec()
		for local_index in calls_this_chunk:
			var position := positions[(completed + local_index) % position_count]
			_sink_float += _ocean.sample_height(position)
		var elapsed := Time.get_ticks_usec() - started
		timings.append(float(elapsed) / float(calls_this_chunk))
		completed += calls_this_chunk
	return _stats(timings, _throughput_calls)


func _measure_normal_throughput(positions: PackedVector3Array) -> Dictionary:
	var position_count := positions.size()
	for index in _warmup_calls:
		_sink_vector += _ocean.sample_normal(positions[index % position_count])
	var timings := PackedFloat64Array()
	var completed := 0
	while completed < _throughput_calls:
		var calls_this_chunk := mini(
			THROUGHPUT_CHUNK_SIZE,
			_throughput_calls - completed
		)
		var started := Time.get_ticks_usec()
		for local_index in calls_this_chunk:
			var position := positions[(completed + local_index) % position_count]
			_sink_vector += _ocean.sample_normal(position)
		var elapsed := Time.get_ticks_usec() - started
		timings.append(float(elapsed) / float(calls_this_chunk))
		completed += calls_this_chunk
	return _stats(timings, _throughput_calls)


func _measure_water_throughput(positions: PackedVector3Array) -> Dictionary:
	var position_count := positions.size()
	var sample := WaterSample3D.new()
	for index in _warmup_calls:
		_ocean.sample_water(positions[index % position_count], sample)
		_sink_float += sample.signed_depth
	var timings := PackedFloat64Array()
	var completed := 0
	while completed < _throughput_calls:
		var calls_this_chunk := mini(
			THROUGHPUT_CHUNK_SIZE,
			_throughput_calls - completed
		)
		var started := Time.get_ticks_usec()
		for local_index in calls_this_chunk:
			var position := positions[(completed + local_index) % position_count]
			_ocean.sample_water(position, sample)
			_sink_float += sample.signed_depth
		var elapsed := Time.get_ticks_usec() - started
		timings.append(float(elapsed) / float(calls_this_chunk))
		completed += calls_this_chunk
	return _stats(timings, _throughput_calls)


func _measure_water_workload(
	positions: PackedVector3Array,
	queries_per_workload: int
) -> Dictionary:
	var position_count := positions.size()
	var sample := WaterSample3D.new()
	for warmup_index in _warmup_calls:
		_ocean.sample_water(positions[warmup_index % position_count], sample)
		_sink_float += sample.signed_depth
	var timings := PackedFloat64Array()
	var sequence_index := 0
	for _observation in _workload_observations:
		var started := Time.get_ticks_usec()
		for _query in queries_per_workload:
			_ocean.sample_water(positions[sequence_index % position_count], sample)
			_sink_float += sample.signed_depth
			sequence_index += 1
		timings.append(float(Time.get_ticks_usec() - started))
	return _stats(
		timings,
		_workload_observations * queries_per_workload
	)


# ---------------------------------------------------------------------------
# Phase 0B: bounded interaction scaling
# ---------------------------------------------------------------------------

func _run_interaction_scaling() -> void:
	for count in [0, 6, 12]:
		await _run_bracketed_interaction_case(
			"ripples",
			count,
			"ripples_%d" % count
		)
	for count in [0, 4, 8, 16]:
		await _run_bracketed_interaction_case(
			"directional_wakes",
			count,
			"directional_wakes_%d" % count
		)
	for count in [0, 2, 4]:
		await _run_bracketed_interaction_case(
			"event_waves",
			count,
			"event_waves_%d" % count
		)
	for count in [0, 2, 4]:
		await _run_bracketed_interaction_case(
			"calm_zones",
			count,
			"calm_zones_%d" % count
		)
	await _run_bracketed_combined_case(false, "combined_typical")
	await _run_bracketed_combined_case(true, "combined_maximum")
	_clear_all_fixtures()


func _run_bracketed_interaction_case(
	kind: String,
	count: int,
	scenario: String
) -> void:
	var before := _measure_stability_control(scenario, "before")
	_configure_single_interaction(kind, count)
	await _measure_interaction_case(scenario)
	_clear_all_fixtures()
	var after := _measure_stability_control(scenario, "after")
	_attach_local_control("interaction_scaling", scenario, before, after)
	await _cool_down()


func _run_bracketed_combined_case(maximum: bool, scenario: String) -> void:
	var before := _measure_stability_control(scenario, "before")
	_configure_combined_interactions(maximum)
	await _measure_interaction_case(scenario)
	_clear_all_fixtures()
	var after := _measure_stability_control(scenario, "after")
	_attach_local_control("interaction_scaling", scenario, before, after)
	await _cool_down()


func _cool_down() -> void:
	# Short cooperative pause prevents a long synchronous microbenchmark from
	# turning scenario order and sustained CPU throttling into fake scaling.
	await get_tree().create_timer(0.05).timeout


func _configure_single_interaction(kind: String, count: int) -> void:
	_clear_all_fixtures()
	match kind:
		"ripples":
			_seed_ripples(count)
		"directional_wakes":
			_seed_directional_wakes(count)
		"event_waves":
			_seed_event_waves(count)
		"calm_zones":
			_seed_calm_zones(count)
	_validate_fixture_count(kind, count)


func _configure_combined_interactions(maximum: bool) -> void:
	_clear_all_fixtures()
	_seed_ripples(12 if maximum else 6)
	_seed_directional_wakes(16 if maximum else 8)
	_seed_event_waves(4 if maximum else 2)
	_seed_calm_zones(4 if maximum else 2)
	_validate_fixture_count("ripples", 12 if maximum else 6)
	_validate_fixture_count("directional_wakes", 16 if maximum else 8)
	_validate_fixture_count("event_waves", 4 if maximum else 2)
	_validate_fixture_count("calm_zones", 4 if maximum else 2)


func _measure_interaction_case(scenario: String) -> void:
	for path_data: Dictionary in [
		{"name": "near_interaction", "positions": _near_positions},
		{"name": "far_from_interaction", "positions": _far_positions},
	]:
		var path_name := String(path_data["name"])
		var positions := path_data["positions"] as PackedVector3Array
		_add_row(
			"interaction_scaling",
			scenario,
			path_name,
			"sample_height",
			"us_per_call",
			_measure_height_throughput(positions)
		)
		await _cool_down()
		_add_row(
			"interaction_scaling",
			scenario,
			path_name,
			"physics_workload_4_queries",
			"us_per_workload",
			_measure_water_workload(positions, 4)
		)
		await _cool_down()
		_add_row(
			"interaction_scaling",
			scenario,
			path_name,
			"physics_workload_16_queries",
			"us_per_workload",
			_measure_water_workload(positions, 16)
		)
		if path_name != "far_from_interaction":
			await _cool_down()


func _seed_ripples(count: int) -> void:
	_ocean.clear_ripples()
	var safe_count := clampi(count, 0, Ocean3D.MAX_RIPPLES)
	for index in safe_count:
		var angle := float(index) * TAU / float(maxi(safe_count, 1))
		var center := Vector3(cos(angle) * 8.0, 0.0, sin(angle) * 4.0)
		_ocean.add_ripple(center, 0.15, 3.4, 2.6, 0.72, 60.0)
	var start_times := _ocean.get("_ripple_start_times") as PackedFloat32Array
	for index in safe_count:
		start_times[index] = _ocean.get_simulation_time() - 0.35
	_ocean.set("_ripple_start_times", start_times)


func _seed_directional_wakes(count: int) -> void:
	_ocean._clear_directional_wake_output()
	var safe_count := clampi(count, 0, Ocean3D.MAX_DIRECTIONAL_WAKE_SEGMENTS)
	var starts := _ocean.get("_directional_wake_start_positions") as PackedVector2Array
	var ends := _ocean.get("_directional_wake_end_positions") as PackedVector2Array
	var start_times := _ocean.get("_directional_wake_start_times") as PackedFloat32Array
	var end_times := _ocean.get("_directional_wake_end_times") as PackedFloat32Array
	var intensities := _ocean.get("_directional_wake_intensities") as PackedFloat32Array
	var widths := _ocean.get("_directional_wake_widths") as PackedFloat32Array
	var biases := _ocean.get("_directional_wake_biases") as PackedFloat32Array
	var speeds := _ocean.get("_directional_wake_speeds") as PackedFloat32Array
	var deformation := _ocean.get("_directional_wake_deformation_weights") as PackedFloat32Array
	var foam := _ocean.get("_directional_wake_persistent_foam_weights") as PackedFloat32Array
	var foam_durations := _ocean.get("_directional_wake_foam_history_durations") as PackedFloat32Array
	var navigable := _ocean.get("_directional_wake_navigable") as PackedInt32Array
	var sample_time := _ocean.get_simulation_time() - 0.32
	for index in safe_count:
		var start := Vector2(-32.0 + float(index) * 4.0, -1.5)
		starts[index] = start
		ends[index] = start + Vector2(3.5, 0.0)
		start_times[index] = sample_time
		end_times[index] = sample_time + 0.04
		intensities[index] = 0.9
		widths[index] = 1.1
		biases[index] = -0.25 if index % 2 == 0 else 0.25
		speeds[index] = 22.0
		deformation[index] = 1.0
		foam[index] = 0.0
		foam_durations[index] = 8.0
		navigable[index] = 1
	_ocean.set("_directional_wake_start_positions", starts)
	_ocean.set("_directional_wake_end_positions", ends)
	_ocean.set("_directional_wake_start_times", start_times)
	_ocean.set("_directional_wake_end_times", end_times)
	_ocean.set("_directional_wake_intensities", intensities)
	_ocean.set("_directional_wake_widths", widths)
	_ocean.set("_directional_wake_biases", biases)
	_ocean.set("_directional_wake_speeds", speeds)
	_ocean.set("_directional_wake_deformation_weights", deformation)
	_ocean.set("_directional_wake_persistent_foam_weights", foam)
	_ocean.set("_directional_wake_foam_history_durations", foam_durations)
	_ocean.set("_directional_wake_navigable", navigable)
	_ocean.set("_directional_wake_active_count", safe_count)
	_ocean._update_directional_wake_bounds()


func _seed_event_waves(count: int) -> void:
	_clear_event_waves()
	var safe_count := clampi(count, 0, Ocean3D.MAX_EVENT_WAVES)
	for index in safe_count:
		var owner := Node.new()
		owner.name = "BenchmarkEventWave%d" % index
		add_child(owner)
		_event_wave_owners.append(owner)
		var direction := Vector2.RIGHT.rotated(float(index) * 0.35)
		var accepted := _ocean.activate_event_wave(
			owner,
			{
				"origin": FIXTURE_CENTER + Vector2(float(index) * 3.0, 0.0),
				"direction": direction,
				"start": _ocean.get_simulation_time() - 1.0,
				"amplitude": 1.0,
				"width": 18.0,
				"speed": 0.0,
				"trough_amplitude": 0.25,
				"trough_width": 14.0,
				"trough_offset": 8.0,
				"flow": 1.5,
				"fade_in": 0.0,
				"lifetime": 0.0,
				"fade_out": 0.0,
			}
		)
		if not accepted:
			_record_failure("Event wave %d was rejected by Ocean3D." % index)


func _seed_calm_zones(count: int) -> void:
	var zones: Array[Dictionary] = []
	var safe_count := clampi(count, 0, Ocean3D.MAX_CALM_WATER_AREAS)
	for index in safe_count:
		zones.append(
			{
				"center": FIXTURE_CENTER + Vector2(float(index) * 5.0, 0.0),
				"axis_x": Vector2.RIGHT,
				"axis_z": Vector2.DOWN,
				"half_extents": Vector2(10.0, 6.0),
				"shape_type": CalmWaterArea3D.SHAPE_BOX,
				"transition_distance": 12.0,
				"wave_strength": 0.2,
				"surface_detail_strength": 0.35,
				"crest_foam_strength": 0.25,
			}
		)
	_ocean.set("_calm_water_zones", zones)


func _validate_fixture_count(kind: String, expected: int) -> void:
	var actual := 0
	match kind:
		"ripples":
			for active: int in _ocean.get("_ripple_active") as PackedInt32Array:
				actual += active
		"directional_wakes":
			actual = _ocean.directional_wake_active_segments
		"event_waves":
			actual = _ocean.get_active_event_wave_count()
		"calm_zones":
			actual = _ocean.get_active_calm_water_area_count()
	if actual != expected:
		_record_failure(
			"Fixture %s expected %d active entries but found %d."
			% [kind, expected, actual]
		)


# ---------------------------------------------------------------------------
# Phase 0C: runtime maintenance and CPU-side uniform submission
# ---------------------------------------------------------------------------

func _run_runtime_maintenance() -> void:
	_configure_combined_interactions(true)
	_seed_landing_visual_state(Ocean3D.MAX_LANDING_IMPACTS)
	_add_row(
		"runtime_maintenance",
		"combined_maximum",
		"not_spatial",
		"expire_ripples",
		"us_per_call",
		_measure_expire_ripples()
	)
	_add_row(
		"runtime_maintenance",
		"combined_maximum",
		"not_spatial",
		"expire_event_waves",
		"us_per_call",
		_measure_expire_event_waves()
	)
	_add_row(
		"runtime_maintenance",
		"combined_maximum",
		"not_spatial",
		"expire_landing_impacts",
		"us_per_call",
		_measure_expire_landing_impacts()
	)
	_add_row(
		"runtime_maintenance",
		"directional_wakes_16_snapshot",
		"not_spatial",
		"rebuild_directional_bounds",
		"us_per_call",
		_measure_directional_bounds()
	)
	_add_row(
		"runtime_maintenance",
		"combined_maximum",
		"not_spatial",
		"push_ripple_uniforms",
		"us_per_call",
		_measure_push_ripple_uniforms()
	)
	_add_row(
		"runtime_maintenance",
		"combined_maximum",
		"not_spatial",
		"push_event_wave_uniforms",
		"us_per_call",
		_measure_push_event_uniforms()
	)
	_add_row(
		"runtime_maintenance",
		"combined_maximum",
		"not_spatial",
		"push_landing_impact_uniforms",
		"us_per_call",
		_measure_push_landing_uniforms()
	)
	_add_row(
		"runtime_maintenance",
		"combined_maximum",
		"not_spatial",
		"push_directional_wake_uniforms",
		"us_per_call",
		_measure_push_directional_uniforms()
	)
	_add_row(
		"runtime_maintenance",
		"combined_maximum",
		"not_spatial",
		"push_calm_zone_uniforms",
		"us_per_call",
		_measure_push_calm_uniforms()
	)


func _seed_landing_visual_state(count: int) -> void:
	var safe_count := clampi(count, 0, Ocean3D.MAX_LANDING_IMPACTS)
	var active := _ocean.get("_landing_impact_active") as PackedInt32Array
	var starts := _ocean.get("_landing_impact_start_times") as PackedFloat32Array
	var durations := _ocean.get("_landing_impact_durations") as PackedFloat32Array
	for index in Ocean3D.MAX_LANDING_IMPACTS:
		active[index] = 1 if index < safe_count else 0
		starts[index] = _ocean.get_simulation_time() - 0.25
		durations[index] = 60.0
	_ocean.set("_landing_impact_active", active)
	_ocean.set("_landing_impact_start_times", starts)
	_ocean.set("_landing_impact_durations", durations)


func _measure_expire_ripples() -> Dictionary:
	var values := PackedFloat64Array()
	for _chunk in _maintenance_chunk_count():
		var started := Time.get_ticks_usec()
		for _index in THROUGHPUT_CHUNK_SIZE:
			if _ocean._expire_ripples():
				_sink_float += 1.0
		values.append(float(Time.get_ticks_usec() - started) / THROUGHPUT_CHUNK_SIZE)
	return _stats(values, _maintenance_iterations)


func _measure_expire_event_waves() -> Dictionary:
	var values := PackedFloat64Array()
	for _chunk in _maintenance_chunk_count():
		var started := Time.get_ticks_usec()
		for _index in THROUGHPUT_CHUNK_SIZE:
			_ocean._expire_event_waves()
		values.append(float(Time.get_ticks_usec() - started) / THROUGHPUT_CHUNK_SIZE)
	return _stats(values, _maintenance_iterations)


func _measure_expire_landing_impacts() -> Dictionary:
	var values := PackedFloat64Array()
	for _chunk in _maintenance_chunk_count():
		var started := Time.get_ticks_usec()
		for _index in THROUGHPUT_CHUNK_SIZE:
			if _ocean._expire_landing_impacts():
				_sink_float += 1.0
		values.append(float(Time.get_ticks_usec() - started) / THROUGHPUT_CHUNK_SIZE)
	return _stats(values, _maintenance_iterations)


func _measure_directional_bounds() -> Dictionary:
	var values := PackedFloat64Array()
	for _chunk in _maintenance_chunk_count():
		var started := Time.get_ticks_usec()
		for _index in THROUGHPUT_CHUNK_SIZE:
			_ocean._update_directional_wake_bounds()
		values.append(float(Time.get_ticks_usec() - started) / THROUGHPUT_CHUNK_SIZE)
	return _stats(values, _maintenance_iterations)


func _measure_push_ripple_uniforms() -> Dictionary:
	var values := PackedFloat64Array()
	for _chunk in _maintenance_chunk_count():
		var started := Time.get_ticks_usec()
		for _index in THROUGHPUT_CHUNK_SIZE:
			_ocean._push_ripple_parameters_to_all_materials()
		values.append(float(Time.get_ticks_usec() - started) / THROUGHPUT_CHUNK_SIZE)
	return _stats(values, _maintenance_iterations)


func _measure_push_event_uniforms() -> Dictionary:
	var values := PackedFloat64Array()
	for _chunk in _maintenance_chunk_count():
		var started := Time.get_ticks_usec()
		for _index in THROUGHPUT_CHUNK_SIZE:
			_ocean._push_event_wave_parameters_to_all_materials()
		values.append(float(Time.get_ticks_usec() - started) / THROUGHPUT_CHUNK_SIZE)
	return _stats(values, _maintenance_iterations)


func _measure_push_landing_uniforms() -> Dictionary:
	var values := PackedFloat64Array()
	for _chunk in _maintenance_chunk_count():
		var started := Time.get_ticks_usec()
		for _index in THROUGHPUT_CHUNK_SIZE:
			_ocean._push_landing_impact_parameters_to_all_materials()
		values.append(float(Time.get_ticks_usec() - started) / THROUGHPUT_CHUNK_SIZE)
	return _stats(values, _maintenance_iterations)


func _measure_push_directional_uniforms() -> Dictionary:
	var values := PackedFloat64Array()
	for _chunk in _maintenance_chunk_count():
		var started := Time.get_ticks_usec()
		for _index in THROUGHPUT_CHUNK_SIZE:
			_ocean._push_directional_wake_parameters_to_all_materials()
		values.append(float(Time.get_ticks_usec() - started) / THROUGHPUT_CHUNK_SIZE)
	return _stats(values, _maintenance_iterations)


func _measure_push_calm_uniforms() -> Dictionary:
	var values := PackedFloat64Array()
	for _chunk in _maintenance_chunk_count():
		var started := Time.get_ticks_usec()
		for _index in THROUGHPUT_CHUNK_SIZE:
			_ocean._push_calm_water_parameters_to_all_materials()
		values.append(float(Time.get_ticks_usec() - started) / THROUGHPUT_CHUNK_SIZE)
	return _stats(values, _maintenance_iterations)


func _maintenance_chunk_count() -> int:
	return ceili(float(_maintenance_iterations) / float(THROUGHPUT_CHUNK_SIZE))


# ---------------------------------------------------------------------------
# Fixture cleanup
# ---------------------------------------------------------------------------

func _clear_all_fixtures() -> void:
	if _ocean == null:
		return
	_ocean.clear_ripples()
	_ocean._clear_directional_wake_output()
	_clear_event_waves()
	var empty_zones: Array[Dictionary] = []
	_ocean.set("_calm_water_zones", empty_zones)
	_ocean._initialize_landing_impacts()


func _clear_event_waves() -> void:
	if _ocean != null:
		for owner: Node in _event_wave_owners:
			if is_instance_valid(owner):
				_ocean.deactivate_event_wave(owner)
	for owner: Node in _event_wave_owners:
		if is_instance_valid(owner):
			owner.free()
	_event_wave_owners.clear()


# ---------------------------------------------------------------------------
# Phase 0.1: long empty controls and local normalization
# ---------------------------------------------------------------------------

func _measure_stability_control(scenario: String, side: String) -> Dictionary:
	_clear_all_fixtures()
	var sample := WaterSample3D.new()
	var position_count := _near_positions.size()
	for warmup_index in STABILITY_CONTROL_WARMUP_QUERIES:
		_ocean.sample_water(
			_near_positions[warmup_index % position_count],
			sample
		)
		_sink_float += sample.signed_depth
	var per_query_timings := PackedFloat64Array()
	var sequence_index := 0
	for _observation in _stability_control_observations:
		var started := Time.get_ticks_usec()
		for _query in STABILITY_CONTROL_QUERY_COUNT:
			_ocean.sample_water(
				_near_positions[sequence_index % position_count],
				sample
			)
			_sink_float += sample.signed_depth
			sequence_index += 1
		var elapsed := Time.get_ticks_usec() - started
		per_query_timings.append(
			float(elapsed) / float(STABILITY_CONTROL_QUERY_COUNT)
		)
	var stats := _stats(
		per_query_timings,
		_stability_control_observations * STABILITY_CONTROL_QUERY_COUNT
	)
	var control := {
		"scenario": scenario,
		"side": side,
		"query_count_per_block": STABILITY_CONTROL_QUERY_COUNT,
		"warmup_queries": STABILITY_CONTROL_WARMUP_QUERIES,
		"stats": stats,
	}
	_stability_controls.append(control)
	print(
		(
			"OCEAN_PHASE_0_CONTROL scenario=%s side=%s blocks=%d "
			+ "queries_per_block=%d median=%.3f p95=%.3f us_per_query"
		)
		% [
			scenario,
			side,
			_stability_control_observations,
			STABILITY_CONTROL_QUERY_COUNT,
			float(stats.get("median", 0.0)),
			float(stats.get("p95", 0.0)),
		]
	)
	return control


func _attach_local_control(
	section: String,
	scenario: String,
	before: Dictionary,
	after: Dictionary
) -> void:
	var before_stats := before.get("stats", {}) as Dictionary
	var after_stats := after.get("stats", {}) as Dictionary
	var before_median := float(before_stats.get("median", 0.0))
	var after_median := float(after_stats.get("median", 0.0))
	var reference := (before_median + after_median) * 0.5
	var local_drift := 0.0
	if reference > 0.0:
		local_drift = absf(after_median - before_median) / reference
	for row: Dictionary in _rows:
		if String(row.get("section", "")) != section:
			continue
		if scenario != "*" and String(row.get("scenario", "")) != scenario:
			continue
		var local_control := {
			"before_us_per_query": before_median,
			"after_us_per_query": after_median,
			"reference_us_per_query": reference,
			"relative_drift": local_drift,
		}
		var query_count := _metric_query_count(String(row.get("metric", "")))
		if query_count > 0 and reference > 0.0:
			var row_stats := row.get("stats", {}) as Dictionary
			var row_median_per_query := (
				float(row_stats.get("median", 0.0)) / float(query_count)
			)
			local_control["row_median_us_per_query"] = row_median_per_query
			local_control["normalized_median_per_query_ratio"] = (
				row_median_per_query / reference
			)
		row["local_control"] = local_control


func _metric_query_count(metric: String) -> int:
	match metric:
		"sample_water":
			return 1
		"physics_workload_4_queries":
			return 4
		"physics_workload_16_queries":
			return 16
	return 0


# ---------------------------------------------------------------------------
# Results and metadata
# ---------------------------------------------------------------------------

func _add_row(
	section: String,
	scenario: String,
	path_name: String,
	metric: String,
	unit: String,
	stats: Dictionary
) -> void:
	_rows.append(
		{
			"section": section,
			"scenario": scenario,
			"path": path_name,
			"metric": metric,
			"unit": unit,
			"stats": stats,
		}
	)
	print(
		(
			"OCEAN_PHASE_0_ROW section=%s scenario=%s path=%s metric=%s "
			+ "mean=%.3f p95=%.3f p99=%.3f max=%.3f %s"
		)
		% [
			section,
			scenario,
			path_name,
			metric,
			float(stats.get("mean", 0.0)),
			float(stats.get("p95", 0.0)),
			float(stats.get("p99", 0.0)),
			float(stats.get("max", 0.0)),
			unit,
		]
	)


func _stats(values: PackedFloat64Array, total_calls: int) -> Dictionary:
	if values.is_empty():
		return {}
	var sorted := values.duplicate()
	sorted.sort()
	var total := 0.0
	for value: float in sorted:
		total += value
	return {
		"observations": sorted.size(),
		"total_calls": total_calls,
		"mean": total / float(sorted.size()),
		"min": sorted[0],
		"median": _percentile(sorted, 0.50),
		"p95": _percentile(sorted, 0.95),
		"p99": _percentile(sorted, 0.99),
		"max": sorted[sorted.size() - 1],
	}


func _percentile(sorted: PackedFloat64Array, ratio: float) -> float:
	var index := clampi(
		ceili(ratio * float(sorted.size())) - 1,
		0,
		sorted.size() - 1
	)
	return sorted[index]


func _build_report() -> Dictionary:
	_stability = _evaluate_stability()
	return {
		"schema": "ocean_phase_0_cpu_v2",
		"metadata": _collect_metadata(),
		"notes": [
			"CPU benchmark only; no authoritative GPU timings are claimed.",
			"Throughput percentiles describe per-chunk averages.",
			"Physics workload percentiles describe complete 4- or 16-query units.",
			"Only long empty sample_water controls determine session stability.",
			"Each measured scenario stores its immediately adjacent empty controls and local normalization.",
			"Four- and sixteen-query workload linearity is diagnostic and does not gate stability.",
			"Landing-impact arrays are GPU visual state; their physical CPU effect is represented by ripples.",
			"Directional query fixtures snapshot the exact bounded arrays consumed by Ocean3D.",
			"Boat-traffic source collection and local-wake maintenance remain covered by the dedicated Gold City benchmark.",
		],
		"rows": _rows,
		"stability_controls": _stability_controls,
		"stability": _stability,
		"failures": _failure_count,
		"elapsed_ms": float(Time.get_ticks_usec() - _started_usec) / 1000.0,
	}


func _collect_metadata() -> Dictionary:
	var quality_status := GraphicsQualityManager.get_graphics_quality_debug_status()
	var image_a := _ocean.get("_wave_image_a") as Image
	var image_b := _ocean.get("_wave_image_b") as Image
	return {
		"timestamp": Time.get_datetime_string_from_system(),
		"git_commit": _read_git_value(["rev-parse", "--short", "HEAD"]),
		"git_dirty": not _read_git_value(["status", "--porcelain"]).is_empty(),
		"godot": Engine.get_version_info(),
		"debug_build": OS.is_debug_build(),
		"processor": OS.get_processor_name(),
		"processor_count": OS.get_processor_count(),
		"video_adapter": RenderingServer.get_video_adapter_name(),
		"rendering_method": ProjectSettings.get_setting(
			"rendering/renderer/rendering_method",
			"default"
		),
		"physics_ticks_per_second": Engine.physics_ticks_per_second,
		"graphics_quality": quality_status,
		"benchmark_scene": scene_file_path,
		"mode": "quick" if _is_quick_run() else "full",
		"throughput_calls": _throughput_calls,
		"throughput_chunk_size": THROUGHPUT_CHUNK_SIZE,
		"workload_observations": _workload_observations,
		"maintenance_iterations": _maintenance_iterations,
		"warmup_calls": _warmup_calls,
		"stability_control_query_count": STABILITY_CONTROL_QUERY_COUNT,
		"stability_control_observations": _stability_control_observations,
		"stability_control_warmup_queries": STABILITY_CONTROL_WARMUP_QUERIES,
		"cpu_precondition_usec": CPU_PRECONDITION_USEC,
		"cpu_precondition_calls": _precondition_calls,
		"cpu_precondition_enabled": _has_user_argument("--precondition"),
		"wave_image_a": _image_metadata(image_a),
		"wave_image_b": _image_metadata(image_b),
		"command_line": OS.get_cmdline_args(),
		"user_command_line": OS.get_cmdline_user_args(),
		"sink": _sink_float + _sink_vector.length(),
	}


func _image_metadata(image: Image) -> Dictionary:
	if image == null:
		return {}
	return {
		"width": image.get_width(),
		"height": image.get_height(),
		"format": image.get_format(),
		"compressed": image.is_compressed(),
		"mipmaps": image.get_mipmap_count(),
		"bytes": image.get_data_size(),
	}


func _evaluate_stability() -> Dictionary:
	var control_medians := PackedFloat64Array()
	for control: Dictionary in _stability_controls:
		var stats := control.get("stats", {}) as Dictionary
		control_medians.append(float(stats.get("median", 0.0)))
	var sorted_controls := control_medians.duplicate()
	sorted_controls.sort()
	var control_reference := (
		_percentile(sorted_controls, 0.50)
		if not sorted_controls.is_empty()
		else 0.0
	)
	var control_spread := 0.0
	if control_reference > 0.0 and not sorted_controls.is_empty():
		control_spread = (
			(sorted_controls[sorted_controls.size() - 1] - sorted_controls[0])
			/ control_reference
		)
	var linearity := {
		"existing_empty": _workload_linearity("existing_api", "empty", "sequence"),
		"combined_typical": _workload_linearity(
			"interaction_scaling",
			"combined_typical",
			"near_interaction"
		),
		"combined_maximum": _workload_linearity(
			"interaction_scaling",
			"combined_maximum",
			"near_interaction"
		),
	}
	var stable := (
		control_medians.size() >= 8
		and control_spread <= MAXIMUM_CONTROL_MEDIAN_SPREAD
	)
	return {
		"stable": stable,
		"gate_method": "long_empty_sample_water_blocks",
		"control_count": control_medians.size(),
		"queries_per_control_block": STABILITY_CONTROL_QUERY_COUNT,
		"observations_per_control": _stability_control_observations,
		"control_medians_us_per_query": control_medians,
		"control_reference_median_us_per_query": control_reference,
		"control_relative_spread": control_spread,
		"maximum_control_relative_spread": MAXIMUM_CONTROL_MEDIAN_SPREAD,
		"workload_linearity": linearity,
		"workload_linearity_range": Vector2(
			MINIMUM_WORKLOAD_LINEARITY,
			MAXIMUM_WORKLOAD_LINEARITY
		),
		"workload_linearity_is_gate": false,
	}


func _workload_linearity(
	section: String,
	scenario: String,
	path_name: String
) -> float:
	var workload_4 := 0.0
	var workload_16 := 0.0
	for row: Dictionary in _rows:
		if (
			String(row.get("section", "")) != section
			or String(row.get("scenario", "")) != scenario
			or String(row.get("path", "")) != path_name
		):
			continue
		var metric := String(row.get("metric", ""))
		var stats := row.get("stats", {}) as Dictionary
		if metric == "physics_workload_4_queries":
			workload_4 = float(stats.get("median", 0.0))
		elif metric == "physics_workload_16_queries":
			workload_16 = float(stats.get("median", 0.0))
	if workload_4 <= 0.0:
		return 0.0
	return workload_16 / (workload_4 * 4.0)


func _read_git_value(arguments: Array[String]) -> String:
	var output: Array = []
	var full_arguments := PackedStringArray(["-C", ProjectSettings.globalize_path("res://")])
	for argument: String in arguments:
		full_arguments.append(argument)
	var exit_code := OS.execute("git", full_arguments, output, false)
	if exit_code != 0 or output.is_empty():
		return "unknown"
	return String(output[0]).strip_edges()


func _write_report(report: Dictionary) -> Dictionary:
	var absolute_directory := ProjectSettings.globalize_path(OUTPUT_DIRECTORY)
	var directory_error := DirAccess.make_dir_recursive_absolute(absolute_directory)
	if directory_error != OK:
		_record_failure(
			"Could not create benchmark output directory: %s"
			% error_string(directory_error)
		)
		return {}
	var timestamp := Time.get_datetime_string_from_system().replace(":", "-")
	var stem := "%s/ocean_phase_0_%s_%s" % [
		OUTPUT_DIRECTORY,
		"quick" if _is_quick_run() else "full",
		timestamp,
	]
	var json_path := stem + ".json"
	var csv_path := stem + ".csv"
	var json_file := FileAccess.open(json_path, FileAccess.WRITE)
	if json_file == null:
		_record_failure("Could not open %s." % json_path)
	else:
		json_file.store_string(JSON.stringify(report, "\t"))
		json_file.close()
	var csv_file := FileAccess.open(csv_path, FileAccess.WRITE)
	if csv_file == null:
		_record_failure("Could not open %s." % csv_path)
	else:
		csv_file.store_line(
			"section,scenario,path,metric,unit,observations,total_calls,"
			+ "mean,min,median,p95,p99,max,"
			+ "local_empty_before_us_per_query,"
			+ "local_empty_after_us_per_query,"
			+ "local_empty_reference_us_per_query,"
			+ "local_control_relative_drift,"
			+ "normalized_median_per_query_ratio"
		)
		for row: Dictionary in _rows:
			csv_file.store_csv_line(_csv_row_fields(row))
		for control: Dictionary in _stability_controls:
			var control_row := {
				"section": "stability_control",
				"scenario": control.get("scenario", ""),
				"path": control.get("side", ""),
				"metric": "empty_sample_water_%d_queries"
					% STABILITY_CONTROL_QUERY_COUNT,
				"unit": "us_per_query",
				"stats": control.get("stats", {}),
			}
			csv_file.store_csv_line(_csv_row_fields(control_row))
		csv_file.close()
	return {
		"json": ProjectSettings.globalize_path(json_path),
		"csv": ProjectSettings.globalize_path(csv_path),
	}


func _csv_row_fields(row: Dictionary) -> PackedStringArray:
	var stats := row.get("stats", {}) as Dictionary
	var local_control := row.get("local_control", {}) as Dictionary
	var normalized := ""
	if local_control.has("normalized_median_per_query_ratio"):
		normalized = "%.6f" % float(
			local_control["normalized_median_per_query_ratio"]
		)
	return PackedStringArray(
		[
			String(row.get("section", "")),
			String(row.get("scenario", "")),
			String(row.get("path", "")),
			String(row.get("metric", "")),
			String(row.get("unit", "")),
			str(stats.get("observations", 0)),
			str(stats.get("total_calls", 0)),
			"%.6f" % float(stats.get("mean", 0.0)),
			"%.6f" % float(stats.get("min", 0.0)),
			"%.6f" % float(stats.get("median", 0.0)),
			"%.6f" % float(stats.get("p95", 0.0)),
			"%.6f" % float(stats.get("p99", 0.0)),
			"%.6f" % float(stats.get("max", 0.0)),
			_csv_optional_float(local_control, "before_us_per_query"),
			_csv_optional_float(local_control, "after_us_per_query"),
			_csv_optional_float(local_control, "reference_us_per_query"),
			_csv_optional_float(local_control, "relative_drift"),
			normalized,
		]
	)


func _csv_optional_float(values: Dictionary, key: String) -> String:
	if not values.has(key):
		return ""
	return "%.6f" % float(values[key])


func _print_summary(paths: Dictionary) -> void:
	print("OCEAN_PHASE_0_ROWS=%d" % _rows.size())
	print("OCEAN_PHASE_0_CONTROLS=%d" % _stability_controls.size())
	print("OCEAN_PHASE_0_FAILURES=%d" % _failure_count)
	print(
		"OCEAN_PHASE_0_STABLE=%s CONTROL_SPREAD=%.3f"
		% [
			str(bool(_stability.get("stable", false))).to_lower(),
			float(_stability.get("control_relative_spread", INF)),
		]
	)
	print("OCEAN_PHASE_0_JSON=%s" % String(paths.get("json", "")))
	print("OCEAN_PHASE_0_CSV=%s" % String(paths.get("csv", "")))
	print(
		"OCEAN_PHASE_0_ELAPSED_MSEC=%.3f"
		% (float(Time.get_ticks_usec() - _started_usec) / 1000.0)
	)


func _record_failure(message: String) -> void:
	_failure_count += 1
	push_error("Ocean Phase 0: %s" % message)


func _finish_with_error(message: String) -> void:
	push_error(message)
	if quit_when_finished:
		get_tree().quit(1)
