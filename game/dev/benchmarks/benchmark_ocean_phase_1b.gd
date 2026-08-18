extends Node

const OUTPUT_DIRECTORY := "res://.godot/ocean_benchmarks"
const PROBE_SEQUENCE_SIZE := 512
const SEGMENT_COUNT := 16

@onready var _runner: Variant = $BenchmarkOceanPhase0
@onready var _ocean: Ocean3D = $BenchmarkOceanPhase0/Ocean3D

var _culling_diagnostics: Array[Dictionary] = []
var _regression_samples: Array[Dictionary] = []


func _ready() -> void:
	_runner._started_usec = Time.get_ticks_usec()
	if not await _runner._wait_until_ocean_ready():
		push_error("Ocean Phase 1B: Ocean3D did not become ready.")
		get_tree().quit(1)
		return
	_runner._prepare_runner_state()
	_runner._build_position_sequences()
	await _run_standard_case()
	await _runner._cool_down()
	await _run_diagnostic_case("phase_1b_sparse", true)
	await _runner._cool_down()
	await _run_diagnostic_case("phase_1b_dense", false)
	_capture_regression_samples()
	var report := {
		"schema": "ocean_phase_1b_cpu_v1",
		"label": _run_label(),
		"methodology": {
			"phase_0_runner": "res://dev/benchmarks/benchmark_ocean_phase_0.gd",
			"workload_observations": _runner._workload_observations,
			"control_query_count": _runner.STABILITY_CONTROL_QUERY_COUNT,
			"control_observations": _runner._stability_control_observations,
		},
		"rows": _runner._rows,
		"controls": _runner._stability_controls,
		"culling_diagnostics": _culling_diagnostics,
		"regression_samples": _regression_samples,
	}
	var report_path := _write_report(report)
	print("OCEAN_PHASE_1B_ROWS=%d" % _runner._rows.size())
	print("OCEAN_PHASE_1B_CONTROLS=%d" % _runner._stability_controls.size())
	print("OCEAN_PHASE_1B_REGRESSION_SAMPLES=%d" % _regression_samples.size())
	print("OCEAN_PHASE_1B_JSON=%s" % report_path)
	get_tree().quit(0)


func _run_label() -> String:
	for argument: String in OS.get_cmdline_user_args():
		if argument.begins_with("--label="):
			return argument.trim_prefix("--label=")
	return "unlabelled"


func _run_standard_case() -> void:
	var scenario := "directional_wakes_16"
	var before: Dictionary = _runner._measure_stability_control(scenario, "before")
	_runner._configure_single_interaction("directional_wakes", SEGMENT_COUNT)
	_culling_diagnostics.append(
		_calculate_culling_diagnostic(
			scenario,
			"near_interaction",
			_runner._near_positions
		)
	)
	_culling_diagnostics.append(
		_calculate_culling_diagnostic(
			scenario,
			"far_from_interaction",
			_runner._far_positions
		)
	)
	await _runner._measure_interaction_case(scenario)
	_runner._clear_all_fixtures()
	var after: Dictionary = _runner._measure_stability_control(scenario, "after")
	_runner._attach_local_control(
		"interaction_scaling",
		scenario,
		before,
		after
	)


func _run_diagnostic_case(scenario: String, sparse: bool) -> void:
	var before: Dictionary = _runner._measure_stability_control(scenario, "before")
	_seed_diagnostic_segments(sparse)
	var positions := _build_diagnostic_positions()
	_culling_diagnostics.append(
		_calculate_culling_diagnostic(scenario, "probe", positions)
	)
	await _measure_custom_case(scenario, positions)
	_runner._clear_all_fixtures()
	var after: Dictionary = _runner._measure_stability_control(scenario, "after")
	_runner._attach_local_control(
		"phase_1b_diagnostic",
		scenario,
		before,
		after
	)


func _measure_custom_case(
	scenario: String,
	positions: PackedVector3Array
) -> void:
	_runner._add_row(
		"phase_1b_diagnostic",
		scenario,
		"probe",
		"physics_workload_4_queries",
		"us_per_workload",
		_runner._measure_water_workload(positions, 4)
	)
	await _runner._cool_down()
	_runner._add_row(
		"phase_1b_diagnostic",
		scenario,
		"probe",
		"physics_workload_16_queries",
		"us_per_workload",
		_runner._measure_water_workload(positions, 16)
	)


func _seed_diagnostic_segments(sparse: bool) -> void:
	_runner._seed_directional_wakes(SEGMENT_COUNT)
	var starts := _ocean.get(
		"_directional_wake_start_positions"
	) as PackedVector2Array
	var ends := _ocean.get(
		"_directional_wake_end_positions"
	) as PackedVector2Array
	for index in SEGMENT_COUNT:
		var center := Vector2.ZERO
		if sparse:
			if index > 0 and index <= 7:
				center.x = -100.0 * float(index)
			elif index >= 8:
				center.x = 100.0 * float(index - 7)
		else:
			center = Vector2(
				lerpf(-3.0, 3.0, float(index) / float(SEGMENT_COUNT - 1)),
				lerpf(-2.0, 2.0, float(index) / float(SEGMENT_COUNT - 1))
			)
		starts[index] = center - Vector2(1.75, 0.0)
		ends[index] = center + Vector2(1.75, 0.0)
	_ocean.set("_directional_wake_start_positions", starts)
	_ocean.set("_directional_wake_end_positions", ends)
	_ocean._update_directional_wake_bounds()


func _build_diagnostic_positions() -> PackedVector3Array:
	var positions := PackedVector3Array()
	positions.resize(PROBE_SEQUENCE_SIZE)
	for index in PROBE_SEQUENCE_SIZE:
		var progress := float(index) / float(PROBE_SEQUENCE_SIZE - 1)
		positions[index] = Vector3(
			lerpf(-2.0, 2.0, progress),
			0.0,
			sin(progress * TAU * 5.0) * 1.5
		)
	return positions


func _calculate_culling_diagnostic(
	scenario: String,
	path_name: String,
	positions: PackedVector3Array
) -> Dictionary:
	var starts := _ocean.get(
		"_directional_wake_start_positions"
	) as PackedVector2Array
	var ends := _ocean.get(
		"_directional_wake_end_positions"
	) as PackedVector2Array
	var navigable := _ocean.get(
		"_directional_wake_navigable"
	) as PackedInt32Array
	var safe_wavelength := maxf(_ocean.directional_wake_wavelength, 0.05)
	var safe_arm_width := maxf(_ocean.directional_wake_arm_width, 0.08)
	var considered := 0
	var discarded := 0
	var evaluated := 0
	var global_rejected := 0
	var global_min := _ocean.get(
		"_directional_wake_physics_bounds_min"
	) as Vector2
	var global_max := _ocean.get(
		"_directional_wake_physics_bounds_max"
	) as Vector2
	for world_position: Vector3 in positions:
		var logical_xz := _ocean.world_to_logical_xz(world_position)
		if _outside_bounds(logical_xz, global_min, global_max):
			global_rejected += 1
			continue
		for index in _ocean.directional_wake_active_segments:
			if navigable[index] == 0:
				continue
			considered += 1
			var reach := _ocean._directional_wake_physical_reach(
				index,
				safe_wavelength,
				safe_arm_width
			)
			var expansion := Vector2(reach, reach)
			var segment_min := starts[index].min(ends[index]) - expansion
			var segment_max := starts[index].max(ends[index]) + expansion
			if _outside_bounds(logical_xz, segment_min, segment_max):
				discarded += 1
			else:
				evaluated += 1
	var sample_count := maxi(positions.size() - global_rejected, 1)
	return {
		"scenario": scenario,
		"path": path_name,
		"positions": positions.size(),
		"global_rejected_positions": global_rejected,
		"average_segments_considered": float(considered) / float(sample_count),
		"average_segments_discarded": float(discarded) / float(sample_count),
		"average_segments_evaluated": float(evaluated) / float(sample_count),
	}


func _outside_bounds(point: Vector2, minimum: Vector2, maximum: Vector2) -> bool:
	return (
		point.x < minimum.x
		or point.y < minimum.y
		or point.x > maximum.x
		or point.y > maximum.y
	)


func _capture_regression_samples() -> void:
	var fixtures := ["standard", "sparse", "dense"]
	for fixture: String in fixtures:
		for age: float in [0.10, 1.0, 3.0, 6.40]:
			_configure_regression_fixture(fixture, age)
			_append_regression_fixture_samples(fixture, age)


func _configure_regression_fixture(fixture: String, age: float) -> void:
	if fixture == "standard":
		_runner._seed_directional_wakes(SEGMENT_COUNT)
	else:
		_seed_diagnostic_segments(fixture == "sparse")
	var start_times := _ocean.get(
		"_directional_wake_start_times"
	) as PackedFloat32Array
	var end_times := _ocean.get(
		"_directional_wake_end_times"
	) as PackedFloat32Array
	var sample_time := _ocean.get_simulation_time()
	for index in _ocean.directional_wake_active_segments:
		start_times[index] = sample_time - age
		end_times[index] = sample_time - age + 0.04
	_ocean.set("_directional_wake_start_times", start_times)
	_ocean.set("_directional_wake_end_times", end_times)
	_ocean._update_directional_wake_bounds()


func _append_regression_fixture_samples(fixture: String, age: float) -> void:
	var starts := _ocean.get(
		"_directional_wake_start_positions"
	) as PackedVector2Array
	var ends := _ocean.get(
		"_directional_wake_end_positions"
	) as PackedVector2Array
	var safe_wavelength := maxf(_ocean.directional_wake_wavelength, 0.05)
	var safe_arm_width := maxf(_ocean.directional_wake_arm_width, 0.08)
	var positions := PackedVector2Array()
	for index in _ocean.directional_wake_active_segments:
		var reach := _ocean._directional_wake_physical_reach(
			index,
			safe_wavelength,
			safe_arm_width
		)
		var minimum := starts[index].min(ends[index]) - Vector2(reach, reach)
		var maximum := starts[index].max(ends[index]) + Vector2(reach, reach)
		var center := (starts[index] + ends[index]) * 0.5
		positions.append(center)
		for delta: float in [-0.01, 0.0, 0.01]:
			positions.append(Vector2(minimum.x + delta, center.y))
			positions.append(Vector2(maximum.x + delta, center.y))
			positions.append(Vector2(center.x, minimum.y + delta))
			positions.append(Vector2(center.x, maximum.y + delta))
		if index + 1 < _ocean.directional_wake_active_segments:
			var next_center := (starts[index + 1] + ends[index + 1]) * 0.5
			positions.append((center + next_center) * 0.5)
	for x_index in 17:
		for z_index in 9:
			positions.append(Vector2(
				lerpf(-40.0, 40.0, float(x_index) / 16.0),
				lerpf(-20.0, 20.0, float(z_index) / 8.0)
			))
	for logical_xz: Vector2 in positions:
		_regression_samples.append({
			"fixture": fixture,
			"age": age,
			"x": logical_xz.x,
			"z": logical_xz.y,
			"height": _ocean._sample_navigable_directional_wake_height(
				logical_xz,
				_ocean.get_simulation_time()
			),
		})


func _write_report(report: Dictionary) -> String:
	var absolute_directory := ProjectSettings.globalize_path(OUTPUT_DIRECTORY)
	var directory_error := DirAccess.make_dir_recursive_absolute(absolute_directory)
	if directory_error != OK:
		push_error("Ocean Phase 1B: output directory creation failed.")
		return ""
	var timestamp := Time.get_datetime_string_from_system().replace(":", "-")
	var path := "%s/ocean_phase_1b_%s_%s.json" % [
		OUTPUT_DIRECTORY,
		_run_label(),
		timestamp,
	]
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_error("Ocean Phase 1B: report open failed.")
		return ""
	file.store_string(JSON.stringify(report, "\t"))
	file.close()
	return ProjectSettings.globalize_path(path)
