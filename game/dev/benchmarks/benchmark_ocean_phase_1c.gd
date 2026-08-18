extends Node

const GOLD_CITY_SCENE := "res://levels/gold_city/gold_city.tscn"
const OUTPUT_DIRECTORY := "res://.godot/ocean_benchmarks"
const TRAFFIC_WARMUP_PHYSICS_FRAMES := 300
const PERFORMANCE_SAMPLE_FRAMES := 120
const CONTROL_QUERY_COUNT := 256
const CONTROL_OBSERVATIONS := 7
const CONTROL_WARMUP_QUERIES := 32
const WORKLOAD_OBSERVATIONS := 13
const WORKLOAD_WARMUP_QUERIES := 64
const MAXIMUM_LOCAL_DRIFT := 0.25
const MIN_SAMPLE_SEPARATION_METRIC := 0.1
const SWEEP_GRID_STEP := 10.0
const SWEEP_GRID_HALF_EXTENT := 200.0
const WAKE_SWEEP_MAX_POINTS := 256

var _sink: float = 0.0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	call_deferred(&"_run")


func _run() -> void:
	Engine.max_fps = 0
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	get_tree().paused = true
	var packed := load(GOLD_CITY_SCENE) as PackedScene
	if packed == null:
		_fail("Could not load Gold City.")
		return
	get_tree().current_scene = null
	if get_tree().change_scene_to_packed(packed) != OK:
		_fail("Could not switch to Gold City.")
		return
	await get_tree().scene_changed
	var city := get_tree().current_scene
	for _frame in 3:
		await get_tree().process_frame
	var ocean := city.get_node_or_null("WaterIntegration/Ocean") as Ocean3D
	var traffic_root := city.get_node_or_null("BoatTraffic")
	if ocean == null or traffic_root == null:
		_fail("Ocean Phase 1C could not resolve Ocean or BoatTraffic.")
		return
	var traffic_actors: Array[BoatTrafficActor] = []
	_collect_traffic_actors(traffic_root, traffic_actors)
	if traffic_actors.size() != 3:
		_fail("Expected 3 Gold City traffic actors; found %d." % traffic_actors.size())
		return
	var fast_path_ocean_ok := true
	for actor: BoatTrafficActor in traffic_actors:
		if not is_instance_valid(actor.get(&"_ocean")):
			fast_path_ocean_ok = false
			break
	if not fast_path_ocean_ok:
		_fail("Gold City traffic actors did not resolve an Ocean3D fast path.")
		return
	print("OCEAN_PHASE_1C_FASTPATH=ocean3d actors=%d" % traffic_actors.size())
	for actor: BoatTrafficActor in traffic_actors:
		actor.camera_visibility_optimization_enabled = false
		actor.call(&"_set_camera_effects_active", true)

	get_tree().paused = false
	var physics_process_msec := PackedFloat64Array()
	var frame_process_msec := PackedFloat64Array()
	var physics_frame_wall_msec := PackedFloat64Array()
	var previous_frame_usec := Time.get_ticks_usec()
	var trigger_counts := {}
	var previous_elapsed := {}
	for frame_index in TRAFFIC_WARMUP_PHYSICS_FRAMES:
		await get_tree().physics_frame
		if frame_index >= TRAFFIC_WARMUP_PHYSICS_FRAMES - PERFORMANCE_SAMPLE_FRAMES:
			var now_usec := Time.get_ticks_usec()
			physics_frame_wall_msec.append(float(now_usec - previous_frame_usec) / 1000.0)
			physics_process_msec.append(
				float(Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS)) * 1000.0
			)
			frame_process_msec.append(
				float(Performance.get_monitor(Performance.TIME_PROCESS)) * 1000.0
			)
			for actor: BoatTrafficActor in traffic_actors:
				var elapsed := float(actor.get(&"_water_sample_elapsed"))
				if previous_elapsed.has(actor) and elapsed < float(previous_elapsed[actor]):
					var key := actor
					var count := int(trigger_counts.get(key, 0))
					trigger_counts[key] = count + 1
				previous_elapsed[actor] = elapsed
		previous_frame_usec = Time.get_ticks_usec()
	ocean.call(&"_update_directional_wake_segments")

	# Freeze the exact Gold City state so repeated sampling stays deterministic.
	city.process_mode = Node.PROCESS_MODE_DISABLED

	# Force one deterministic water-target sample per boat through the live NEW
	# path. The stored surface positions are exactly Vector3(query.x, height,
	# query.z), so their x/z recover the boat's real Front/Rear/Left/Right
	# queries without duplicating the actor's query arithmetic.
	var boat_queries := PackedVector3Array()
	var boat_stored_positions: Array[Vector3] = []
	var swept_queries := PackedVector3Array()
	var boat_centers := PackedVector3Array()
	for actor: BoatTrafficActor in traffic_actors:
		actor.call(&"_sample_water_target")
		if not bool(actor.get(&"_has_valid_water_target")):
			_fail("Traffic actor did not produce a valid water target after freeze.")
			return
		var stored_names := [
			&"_front_surface_position",
			&"_rear_surface_position",
			&"_left_surface_position",
			&"_right_surface_position",
		]
		for stored_name: StringName in stored_names:
			var stored := actor.get(stored_name) as Vector3
			if not stored.is_finite():
				_fail("Traffic actor stored a non-finite water target surface position.")
				return
			boat_queries.append(stored)
			boat_stored_positions.append(stored)
		swept_queries.append_array(_wake_sweep_queries(actor))
		boat_centers.append(actor.global_position)

	var grid_center := Vector3.ZERO
	for center: Vector3 in boat_centers:
		grid_center += center
	grid_center /= float(boat_centers.size())
	var grid_queries := _region_sweep_queries(grid_center)

	var regression_rows: Array[Dictionary] = []
	regression_rows.append(_run_live_regression(ocean, boat_stored_positions))
	regression_rows.append(_run_regression(ocean, swept_queries, "wake_sweep"))
	regression_rows.append(_run_regression(ocean, grid_queries, "region_grid"))

	var target_rows: Array[Dictionary] = []
	for actor_index in traffic_actors.size():
		var actor: BoatTrafficActor = traffic_actors[actor_index]
		var queries := PackedVector3Array()
		for slot in 4:
			queries.append(boat_stored_positions[actor_index * 4 + slot])
		target_rows.append(_run_target_regression(ocean, queries, actor, actor_index))

	var control_positions := _build_control_positions(boat_queries)
	var rounds: Array[Dictionary] = []
	for variant in ["old", "new", "new", "old"]:
		var before := _measure_control(ocean, control_positions)
		var timing := _measure_workload(ocean, boat_queries, variant)
		var after := _measure_control(ocean, control_positions)
		rounds.append(_build_round(variant, timing, before, after, boat_queries.size()))
		await get_tree().process_frame

	var pairs := _build_pairs(rounds)
	for pair: Dictionary in pairs:
		await get_tree().process_frame

	var valid_pair_count := 0
	for pair: Dictionary in pairs:
		if bool(pair["both_valid"]):
			valid_pair_count += 1
	var pooled := _pool(_valid_pair_rounds(pairs))
	var pooled_unfiltered := _pool(rounds)

	var frequency := _frequency_summary(trigger_counts, traffic_actors)
	var estimated_saved_us_per_second := (
		(float(pooled["old_median_us_per_query"]) - float(pooled["new_median_us_per_query"]))
		* float(frequency["total_updates_per_second"])
		* 4.0
	)
	var report := {
		"schema": "ocean_phase_1c_v1",
		"label": _argument_value("--label=", "unlabelled"),
		"commit": _argument_value("--commit=", "unknown"),
		"methodology": {
			"scene": GOLD_CITY_SCENE,
			"physics_hz": Engine.physics_ticks_per_second,
			"traffic_warmup_physics_frames": TRAFFIC_WARMUP_PHYSICS_FRAMES,
			"traffic_actor_count": traffic_actors.size(),
			"control_query_count": CONTROL_QUERY_COUNT,
			"control_observations": CONTROL_OBSERVATIONS,
			"workload_observations": WORKLOAD_OBSERVATIONS,
			"maximum_local_drift": MAXIMUM_LOCAL_DRIFT,
			"old_workload": "4x sample_water() per boat water-target update",
			"new_workload": "4x sample_height() per boat water-target update",
			"gold_city_resolved_fast_path": "ocean3d",
		},
		"snapshot": _snapshot_metadata(ocean, boat_queries),
		"regression": regression_rows,
		"target_regression": target_rows,
		"timing_rounds": rounds,
		"timing_pairs": pairs,
		"pooled": pooled.duplicate(true),
		"pooled_unfiltered": pooled_unfiltered.duplicate(true),
		"pooled_valid_pair_count": valid_pair_count,
		"frequency": frequency,
		"estimated_saved_us_per_second": estimated_saved_us_per_second,
		"frame_diagnostic": {
			"note": "Headless Gold City diagnostic; not an FPS claim",
			"physics_process_msec": _stats(physics_process_msec),
			"frame_process_msec": _stats(frame_process_msec),
			"physics_frame_wall_msec": _stats(physics_frame_wall_msec),
		},
	}
	var report_path := _write_report(report)
	print("OCEAN_PHASE_1C_SNAPSHOT=%s" % String(report["snapshot"]["fingerprint"]))
	print(
		"OCEAN_PHASE_1C_POOLED old_us_q=%.4f new_us_q=%.4f old_norm=%.4f new_norm=%.4f reduction=%.2f%% valid_pairs=%d"
		% [
			float(pooled["old_median_us_per_query"]),
			float(pooled["new_median_us_per_query"]),
			float(pooled["old_normalized_median_ratio"]),
			float(pooled["new_normalized_median_ratio"]),
			float(pooled["pooled_reduction_percent"]),
			valid_pair_count,
		]
	)
	print(
		"OCEAN_PHASE_1C_POOLED_UNFILTERED old_us_q=%.4f new_us_q=%.4f old_norm=%.4f new_norm=%.4f reduction=%.2f%% (all rounds, raw)"
		% [
			float(pooled_unfiltered["old_median_us_per_query"]),
			float(pooled_unfiltered["new_median_us_per_query"]),
			float(pooled_unfiltered["old_normalized_median_ratio"]),
			float(pooled_unfiltered["new_normalized_median_ratio"]),
			float(pooled_unfiltered["pooled_reduction_percent"]),
		]
	)
	print(
		"OCEAN_PHASE_1C_FREQUENCY total_updates_per_second=%.2f saved_us_per_second=%.2f"
		% [float(frequency["total_updates_per_second"]), estimated_saved_us_per_second]
	)
	print("OCEAN_PHASE_1C_JSON=%s" % report_path)
	print("OCEAN_PHASE_1C_BENCHMARK=PASS")
	get_tree().quit(0)


func _build_round(
	variant: String,
	timing: Dictionary,
	before: Dictionary,
	after: Dictionary,
	query_count: int
) -> Dictionary:
	var before_median := float(before.get("median", 0.0))
	var after_median := float(after.get("median", 0.0))
	var reference := (before_median + after_median) * 0.5
	var drift := (
		absf(after_median - before_median) / reference if reference > 0.0 else INF
	)
	var median_per_query := float(timing.get("median", 0.0)) / float(query_count)
	var row := {
		"variant": variant,
		"median_us_per_workload": float(timing.get("median", 0.0)),
		"median_us_per_query": median_per_query,
		"normalized_median_per_query_ratio": (
			median_per_query / reference if reference > 0.0 else INF
		),
		"control_before_us_per_query": before,
		"control_after_us_per_query": after,
		"control_reference_us_per_query": reference,
		"local_relative_drift": drift,
		"valid": drift <= MAXIMUM_LOCAL_DRIFT,
	}
	print(
		"OCEAN_PHASE_1C_ROUND variant=%s median_us_per_query=%.4f normalized=%.4f drift=%.4f valid=%s"
		% [
			variant,
			median_per_query,
			float(row["normalized_median_per_query_ratio"]),
			drift,
			str(drift <= MAXIMUM_LOCAL_DRIFT),
		]
	)
	return row


func _build_pairs(rounds: Array[Dictionary]) -> Array[Dictionary]:
	var pairs: Array[Dictionary] = []
	# ABBA ordering: pair 1 = rounds[0]/rounds[1], pair 2 = rounds[3]/rounds[2].
	var indices := [[0, 1], [3, 2]]
	for assignment: Array in indices:
		var old_round: Dictionary = rounds[assignment[0]]
		var new_round: Dictionary = rounds[assignment[1]]
		var old_ratio := float(old_round["normalized_median_per_query_ratio"])
		var new_ratio := float(new_round["normalized_median_per_query_ratio"])
		var old_median := float(old_round["median_us_per_query"])
		var new_median := float(new_round["median_us_per_query"])
		var both_valid := bool(old_round["valid"]) and bool(new_round["valid"])
		var row := {
			"pair_name": "pair_%d" % (indices.find(assignment) + 1),
			"old_round": old_round,
			"new_round": new_round,
			"old_median_us_per_query": old_median,
			"new_median_us_per_query": new_median,
			"raw_change_percent": (
				(new_median - old_median) / old_median * 100.0 if old_median > 0.0 else INF
			),
			"normalized_change_percent": (
				(new_ratio - old_ratio) / old_ratio * 100.0 if old_ratio > 0.0 else INF
			),
			"reduction_percent": (
				(1.0 - new_ratio / old_ratio) * 100.0 if old_ratio > 0.0 else INF
			),
			"both_valid": both_valid,
		}
		pairs.append(row)
		print(
			"OCEAN_PHASE_1C_PAIR %s old_us_q=%.4f new_us_q=%.4f raw=%.2f%% norm=%.2f%% reduction=%.2f%% valid=%s"
			% [
				String(row["pair_name"]),
				old_median,
				new_median,
				float(row["raw_change_percent"]),
				float(row["normalized_change_percent"]),
				float(row["reduction_percent"]),
				str(both_valid),
			]
		)
	return pairs


func _valid_pair_rounds(pairs: Array[Dictionary]) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for pair: Dictionary in pairs:
		if not bool(pair["both_valid"]):
			continue
		result.append(pair["old_round"] as Dictionary)
		result.append(pair["new_round"] as Dictionary)
	return result


func _pool(rounds: Array[Dictionary]) -> Dictionary:
	var old_values := PackedFloat64Array()
	var new_values := PackedFloat64Array()
	var old_ratios := PackedFloat64Array()
	var new_ratios := PackedFloat64Array()
	for round: Dictionary in rounds:
		if String(round["variant"]) == "old":
			old_values.append(float(round["median_us_per_query"]))
			old_ratios.append(float(round["normalized_median_per_query_ratio"]))
		else:
			new_values.append(float(round["median_us_per_query"]))
			new_ratios.append(float(round["normalized_median_per_query_ratio"]))
	var old_stats := _stats(old_values)
	var new_stats := _stats(new_values)
	var old_ratio := _median(old_ratios)
	var new_ratio := _median(new_ratios)
	var old_us := float(old_stats["median"])
	var new_us := float(new_stats["median"])
	var has_data := old_values.size() > 0 and new_values.size() > 0
	return {
		"old_median_us_per_query": old_us,
		"new_median_us_per_query": new_us,
		"old_stats_us_per_query": old_stats,
		"new_stats_us_per_query": new_stats,
		"old_normalized_median_ratio": old_ratio,
		"new_normalized_median_ratio": new_ratio,
		"had_valid_rounds": has_data,
		"pooled_raw_change_percent": (
			(new_us - old_us) / old_us * 100.0 if has_data and old_us > 0.0 else INF
		),
		"pooled_reduction_percent": (
			(1.0 - new_ratio / old_ratio) * 100.0 if has_data and old_ratio > 0.0 else INF
		),
	}


func _collect_traffic_actors(node: Node, result: Array[BoatTrafficActor]) -> void:
	if node is BoatTrafficActor:
		result.append(node as BoatTrafficActor)
	for child: Node in node.get_children():
		_collect_traffic_actors(child, result)


func _wake_sweep_queries(actor: BoatTrafficActor) -> PackedVector3Array:
	var result := PackedVector3Array()
	var wake := actor.get_node_or_null("WakeRoot/BoatWake") as WakeTrail3D
	if wake == null:
		return result
	var forward := actor.get(&"_smoothed_heading_forward") as Vector3
	forward.y = 0.0
	if forward.length_squared() <= 0.000001:
		return result
	forward = forward.normalized()
	var right := Vector3(forward.z, 0.0, -forward.x)
	var half_length := maxf(actor.sample_length, MIN_SAMPLE_SEPARATION_METRIC) * 0.5
	var half_width := maxf(actor.sample_width, MIN_SAMPLE_SEPARATION_METRIC) * 0.5
	var offsets := PackedVector3Array([
		forward * half_length,
		-forward * half_length,
		-right * half_width,
		right * half_width,
	])
	var positions := wake.get_sample_positions()
	var step := maxi(1, int(ceili(float(positions.size()) / float(WAKE_SWEEP_MAX_POINTS))))
	for index in range(0, positions.size(), step):
		var center: Vector3 = positions[index]
		for offset: Vector3 in offsets:
			result.append(center + offset)
	return result


func _region_sweep_queries(center: Vector3) -> PackedVector3Array:
	var result := PackedVector3Array()
	var x := center.x - SWEEP_GRID_HALF_EXTENT
	while x <= center.x + SWEEP_GRID_HALF_EXTENT:
		var z := center.z - SWEEP_GRID_HALF_EXTENT
		while z <= center.z + SWEEP_GRID_HALF_EXTENT:
			result.append(Vector3(x, center.y, z))
			z += SWEEP_GRID_STEP
		x += SWEEP_GRID_STEP
	return result


func _run_live_regression(ocean: Ocean3D, stored: Array[Vector3]) -> Dictionary:
	var sample := WaterSample3D.new()
	var total := 0
	var differing := 0
	var non_finite := 0
	var max_abs_delta := 0.0
	var sum_abs_delta := 0.0
	for position: Vector3 in stored:
		var old_y: float = ocean.sample_water(position, sample).surface_position.y
		var new_y := position.y
		if not (is_finite(old_y) and is_finite(new_y)):
			non_finite += 1
			continue
		total += 1
		var delta := absf(new_y - old_y)
		if delta > 0.0:
			differing += 1
		max_abs_delta = maxf(max_abs_delta, delta)
		sum_abs_delta += delta
	return {
		"label": "live_boat_12_actor_new_path",
		"samples": total,
		"non_finite": non_finite,
		"differing": differing,
		"max_abs_delta": max_abs_delta,
		"mean_abs_delta": sum_abs_delta / float(maxi(total, 1)),
	}


func _run_regression(ocean: Ocean3D, queries: PackedVector3Array, label: String) -> Dictionary:
	var sample := WaterSample3D.new()
	var total := 0
	var differing := 0
	var non_finite := 0
	var max_abs_delta := 0.0
	var sum_abs_delta := 0.0
	var self_consistent_total := 0
	var self_inconsistent := 0
	var repeat_non_finite := 0
	var recovered_max_abs_delta := 0.0
	var recovered_sum_abs_delta := 0.0
	var recovered_count := 0
	for position: Vector3 in queries:
		var old_y: float = ocean.sample_water(position, sample).surface_position.y
		var new_y: float = ocean.sample_height(position)
		var new_y_again: float = ocean.sample_height(position)
		if not (is_finite(old_y) and is_finite(new_y) and is_finite(new_y_again)):
			non_finite += 1
			if not (is_finite(new_y) and is_finite(new_y_again)):
				repeat_non_finite += 1
			continue
		self_consistent_total += 1
		if absf(new_y - new_y_again) > 0.0:
			self_inconsistent += 1
		total += 1
		var delta := absf(new_y - old_y)
		if delta > 0.0:
			differing += 1
		max_abs_delta = maxf(max_abs_delta, delta)
		sum_abs_delta += delta
		var recovered := sample.signed_depth + position.y
		if is_finite(recovered):
			recovered_count += 1
			recovered_max_abs_delta = maxf(
				recovered_max_abs_delta,
				absf(recovered - new_y)
			)
			recovered_sum_abs_delta += absf(recovered - new_y)
	return {
		"label": label,
		"samples": total,
		"non_finite": non_finite,
		"differing": differing,
		"max_abs_delta": max_abs_delta,
		"mean_abs_delta": sum_abs_delta / float(maxi(total, 1)),
		"sample_height_self_consistent_samples": self_consistent_total,
		"sample_height_self_inconsistent": self_inconsistent,
		"recovered_float64_surface_delta_samples": recovered_count,
		"recovered_float64_surface_max_abs_delta": recovered_max_abs_delta,
		"recovered_float64_surface_mean_abs_delta": (
			recovered_sum_abs_delta / float(maxi(recovered_count, 1))
		),
	}


func _run_target_regression(
	ocean: Ocean3D,
	queries: PackedVector3Array,
	actor: BoatTrafficActor,
	actor_index: int
) -> Dictionary:
	var sample := WaterSample3D.new()
	var old_heights := PackedFloat64Array()
	var new_heights := PackedFloat64Array()
	for position: Vector3 in queries:
		old_heights.append(ocean.sample_water(position, sample).surface_position.y)
		new_heights.append(ocean.sample_height(position))
	if old_heights.size() != 4:
		return {"actor": actor_index, "error": "invalid query set"}
	var old_targets := _compute_targets(old_heights, actor)
	var new_targets := _compute_targets(new_heights, actor)
	var actor_stored_targets := {
		"target_water_height": float(actor.get(&"_target_water_height")),
		"target_pitch": float(actor.get(&"_target_pitch")),
		"target_roll": float(actor.get(&"_target_roll")),
	}
	var stored_deltas := {
		"target_water_height_delta": absf(
			float(actor_stored_targets["target_water_height"]) - float(old_targets["target_water_height"])
		),
		"target_pitch_delta": absf(
			float(actor_stored_targets["target_pitch"]) - float(old_targets["target_pitch"])
		),
		"target_roll_delta": absf(
			float(actor_stored_targets["target_roll"]) - float(old_targets["target_roll"])
		),
	}
	return {
		"actor": actor_index,
		"height_max_abs_delta": _max_abs_delta(old_heights, new_heights),
		"height_mean_abs_delta": _mean_abs_delta(old_heights, new_heights),
		"height_differing": _count_differing(old_heights, new_heights),
		"target_water_height_delta": absf(
			float(new_targets["target_water_height"]) - float(old_targets["target_water_height"])
		),
		"target_pitch_delta": absf(
			float(new_targets["target_pitch"]) - float(old_targets["target_pitch"])
		),
		"target_roll_delta": absf(
			float(new_targets["target_roll"]) - float(old_targets["target_roll"])
		),
		"actor_stored_target_deltas_vs_old": stored_deltas,
		"old": old_targets,
		"new": new_targets,
		"actor_stored": actor_stored_targets,
	}


func _compute_targets(heights: PackedFloat64Array, actor: BoatTrafficActor) -> Dictionary:
	var front := float(heights[0])
	var rear := float(heights[1])
	var left := float(heights[2])
	var right := float(heights[3])
	var target_water_height := (front + rear + left + right) * 0.25 + actor.waterline_offset
	var target_pitch := clampf(
		atan2(front - rear, maxf(actor.sample_length, MIN_SAMPLE_SEPARATION_METRIC)),
		-deg_to_rad(actor.maximum_pitch_degrees),
		deg_to_rad(actor.maximum_pitch_degrees)
	)
	var target_roll := clampf(
		atan2(right - left, maxf(actor.sample_width, MIN_SAMPLE_SEPARATION_METRIC)),
		-deg_to_rad(actor.maximum_roll_degrees),
		deg_to_rad(actor.maximum_roll_degrees)
	)
	return {
		"target_water_height": target_water_height,
		"target_pitch": target_pitch,
		"target_roll": target_roll,
	}


func _measure_control(ocean: Ocean3D, positions: PackedVector3Array) -> Dictionary:
	var sample := WaterSample3D.new()
	for index in CONTROL_WARMUP_QUERIES:
		ocean.sample_water(positions[index % positions.size()], sample)
		_sink += sample.signed_depth
	var timings := PackedFloat64Array()
	var sequence_index := 0
	for _observation in CONTROL_OBSERVATIONS:
		var started := Time.get_ticks_usec()
		for _query in CONTROL_QUERY_COUNT:
			ocean.sample_water(positions[sequence_index % positions.size()], sample)
			_sink += sample.signed_depth
			sequence_index += 1
		timings.append(float(Time.get_ticks_usec() - started) / float(CONTROL_QUERY_COUNT))
	return _stats(timings)


func _measure_workload(
	ocean: Ocean3D,
	positions: PackedVector3Array,
	variant: String
) -> Dictionary:
	var sample := WaterSample3D.new()
	for index in WORKLOAD_WARMUP_QUERIES:
		_run_workload_pass(ocean, positions, variant, sample)
	var repeats := 32
	var timings := PackedFloat64Array()
	for _observation in WORKLOAD_OBSERVATIONS:
		var started := Time.get_ticks_usec()
		for _repeat in repeats:
			_run_workload_pass(ocean, positions, variant, sample)
		timings.append(float(Time.get_ticks_usec() - started) / float(repeats))
	return _stats(timings)


func _run_workload_pass(
	ocean: Ocean3D,
	positions: PackedVector3Array,
	variant: String,
	sample: WaterSample3D
) -> void:
	for position: Vector3 in positions:
		if variant == "old":
			_sink += ocean.sample_water(position, sample).surface_position.y
		else:
			_sink += ocean.sample_height(position)


func _build_control_positions(positions: PackedVector3Array) -> PackedVector3Array:
	var result := PackedVector3Array()
	for position: Vector3 in positions:
		result.append(position + Vector3(100000.0, 0.0, 100000.0))
	return result


func _frequency_summary(
	trigger_counts: Dictionary,
	traffic_actors: Array[BoatTrafficActor]
) -> Dictionary:
	var per_actor: Array[Dictionary] = []
	var total_triggers := 0
	for actor: BoatTrafficActor in traffic_actors:
		var count := int(trigger_counts.get(actor, 0))
		total_triggers += count
		per_actor.append({
			"actor": traffic_actors.find(actor),
			"observed_water_target_updates_in_120_frames": count,
		})
	var total_updates_per_second := (
		float(total_triggers) / float(PERFORMANCE_SAMPLE_FRAMES)
		* float(Engine.physics_ticks_per_second)
	)
	var sample_water_calls_per_second_old := total_updates_per_second * 4.0
	return {
		"per_actor": per_actor,
		"observed_frames": PERFORMANCE_SAMPLE_FRAMES,
		"total_observed_updates": total_triggers,
		"total_updates_per_second": total_updates_per_second,
		"updates_per_second_per_boat": total_updates_per_second / float(maxi(traffic_actors.size(), 1)),
		"saved_by_optimization": false,
		"sample_water_calls_per_second_old": sample_water_calls_per_second_old,
	}


func _snapshot_metadata(ocean: Ocean3D, boat_queries: PackedVector3Array) -> Dictionary:
	var fingerprint_parts := PackedStringArray()
	var active_count := int(ocean.get(&"_directional_wake_active_count"))
	var starts := ocean.get(&"_directional_wake_start_positions") as PackedVector2Array
	var ends := ocean.get(&"_directional_wake_end_positions") as PackedVector2Array
	for index in active_count:
		fingerprint_parts.append("S%.5f,%.5f" % [starts[index].x, starts[index].y])
		fingerprint_parts.append("E%.5f,%.5f" % [ends[index].x, ends[index].y])
	for position: Vector3 in boat_queries:
		fingerprint_parts.append("Q%.5f,%.5f,%.5f" % [position.x, position.y, position.z])
	return {
		"fingerprint": str(hash("|".join(fingerprint_parts))),
		"active_directional_segments": active_count,
		"simulation_time": ocean.get_simulation_time(),
		"query_count": boat_queries.size(),
	}


func _stats(values: PackedFloat64Array) -> Dictionary:
	if values.is_empty():
		return {"count": 0, "mean": 0.0, "median": 0.0, "min": 0.0, "max": 0.0}
	var sorted := values.duplicate()
	sorted.sort()
	var sum := 0.0
	for value: float in sorted:
		sum += value
	return {
		"count": sorted.size(),
		"mean": sum / float(sorted.size()),
		"median": _percentile(sorted, 0.50),
		"min": sorted[0],
		"max": sorted[-1],
	}


func _median(values: PackedFloat64Array) -> float:
	if values.is_empty():
		return 0.0
	var sorted := values.duplicate()
	sorted.sort()
	return _percentile(sorted, 0.50)


func _percentile(sorted: PackedFloat64Array, ratio: float) -> float:
	if sorted.is_empty():
		return 0.0
	var position := clampf(ratio, 0.0, 1.0) * float(sorted.size() - 1)
	var lower := int(floor(position))
	var upper := mini(lower + 1, sorted.size() - 1)
	return lerpf(sorted[lower], sorted[upper], position - float(lower))


func _max_abs_delta(a: PackedFloat64Array, b: PackedFloat64Array) -> float:
	var maximum := 0.0
	for index in mini(a.size(), b.size()):
		maximum = maxf(maximum, absf(float(a[index]) - float(b[index])))
	return maximum


func _mean_abs_delta(a: PackedFloat64Array, b: PackedFloat64Array) -> float:
	var sum := 0.0
	var count := mini(a.size(), b.size())
	for index in count:
		sum += absf(float(a[index]) - float(b[index]))
	return sum / float(maxi(count, 1))


func _count_differing(a: PackedFloat64Array, b: PackedFloat64Array) -> int:
	var count := 0
	for index in mini(a.size(), b.size()):
		if absf(float(a[index]) - float(b[index])) > 0.0:
			count += 1
	return count


func _write_report(report: Dictionary) -> String:
	var absolute_directory := ProjectSettings.globalize_path(OUTPUT_DIRECTORY)
	if DirAccess.make_dir_recursive_absolute(absolute_directory) != OK:
		return "ERROR_CREATING_OUTPUT_DIRECTORY"
	var timestamp := Time.get_datetime_string_from_system().replace(":", "-")
	var path := "%s/ocean_phase_1c_%s_%s.json" % [
		OUTPUT_DIRECTORY,
		String(report["label"]),
		timestamp,
	]
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return "ERROR_OPENING_REPORT"
	file.store_string(JSON.stringify(report, "\t"))
	file.close()
	return ProjectSettings.globalize_path(path)


func _argument_value(prefix: String, fallback: String) -> String:
	for argument: String in OS.get_cmdline_user_args():
		if argument.begins_with(prefix):
			return argument.trim_prefix(prefix)
	return fallback


func _fail(message: String) -> void:
	get_tree().paused = false
	push_error("Ocean Phase 1C: %s" % message)
	get_tree().quit(1)