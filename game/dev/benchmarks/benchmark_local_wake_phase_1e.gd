extends Node

const GOLD_CITY_SCENE := "res://levels/gold_city/gold_city.tscn"
const OUTPUT_DIRECTORY := "res://.godot/ocean_benchmarks"
const TRAFFIC_WARMUP_PHYSICS_FRAMES := 300
const OBSERVATIONS := 9
const TARGET_OBSERVATION_US := 25000.0
const MAXIMUM_LOCAL_DRIFT := 0.25
const MAX_ATTEMPTS := 3
const REQUIRED_VALID_PAIRS := 2
const CONTROL_OFFSET := Vector3(100000.0, 0.0, 100000.0)
const BOUND_FAR_MARGIN := 5000.0
const OUTSIDE_MARGIN := 50.0
const MIN_SAMPLE_AGE := 0.15
const HEIGHT_EPS := 1e-9
const GRID_QUANTA := 15
const SIDE_OFFSETS: Array[float] = [0.4, 1.0, 2.5, 5.0, 8.0, 12.0]
const RANDOM_QUERIES := 180
const RANDOM_SEED := 20260818
const COLD_QUERY_COUNT := 30

var _sink: float = 0.0
var _water_level: float = 0.0
var _bench_source: WakeTrail3D
var _bench_position: Vector3 = Vector3.ZERO
var _bench_ocean: Ocean3D
var _bench_positions: PackedVector3Array = PackedVector3Array()


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
	var jet_ski := city.get_node_or_null("Gameplay/JetSki") as JetSkiController
	var traffic_root := city.get_node_or_null("BoatTraffic")
	if ocean == null or jet_ski == null or traffic_root == null:
		_fail("Phase 1E could not resolve Ocean, JetSki, or BoatTraffic.")
		return
	var traffic_actors: Array[BoatTrafficActor] = []
	_collect_traffic_actors(traffic_root, traffic_actors)
	if traffic_actors.size() != 3:
		_fail("Expected 3 Gold City traffic actors; found %d." % traffic_actors.size())
		return
	for actor: BoatTrafficActor in traffic_actors:
		actor.camera_visibility_optimization_enabled = false
		actor.call(&"_set_camera_effects_active", true)
	_water_level = ocean.water_level

	get_tree().paused = false
	for _frame in TRAFFIC_WARMUP_PHYSICS_FRAMES:
		await get_tree().physics_frame

	var player_positions := _build_live_queries(jet_ski)
	if player_positions.size() != 6:
		_fail("JetSki did not expose its six live query positions.")
		return

	city.process_mode = Node.PROCESS_MODE_DISABLED

	var sources := _read_sources(ocean)
	if sources.size() != 3:
		_fail("Expected 3 local wake physics sources; found %d." % sources.size())
		return

	var profiles := Array()
	for source: WakeTrail3D in sources:
		profiles.append(_build_source_profile(source))

	var source_rows := _source_rows(sources, profiles)
	var overlap := _compute_overlap(profiles)
	var multi_points := _multi_overlap_points(profiles)

	var regression := _run_static_regression(sources, profiles, overlap, multi_points, player_positions)
	var identity := _candidate_identity(sources)
	var timings := _run_timings(sources, profiles, overlap, ocean, player_positions)
	var guard := _run_mutation_regression(sources)
	var sums := _regression_sums(regression["tally"])

	print("GOLD_CITY_PHASE_1E_REGRESSION=%s" % JSON.stringify(sums))
	print("GOLD_CITY_PHASE_1E_IDENTITY=%s" % JSON.stringify(identity))
	print("GOLD_CITY_PHASE_1E_TIMINGS=%s" % JSON.stringify({
		"per_source": timings["per_source"],
		"aggregate": timings["aggregate"],
	}))
	print("GOLD_CITY_PHASE_1E_GUARD=%s" % JSON.stringify(guard))

	var report := {
		"schema": "ocean_phase_1e_local_wake_cache_v1",
		"label": _argument_value("--label=", "unlabelled"),
		"commit": _argument_value("--commit=", "unknown"),
		"diagnostic_only": false,
		"runtime_modified": true,
		"runtime_files": ["game/gameplay/vehicles/common/water_effects/wake/wake_trail_3d.gd"],
		"methodology": {
			"note": "Phase 1E local traffic wake candidate cache. Only WakeTrail3D.sample_simplified_wake_height and its private helpers were modified. REFERENCE is a textual copy of the pre-1E sampler reading _samples directly. Regression compares RUNTIME against REFERENCE for the same frozen traffic state.",
			"scene": GOLD_CITY_SCENE,
			"physics_hz": Engine.physics_ticks_per_second,
			"traffic_warmup_physics_frames": TRAFFIC_WARMUP_PHYSICS_FRAMES,
			"observations_per_series": OBSERVATIONS,
			"target_observation_us": TARGET_OBSERVATION_US,
			"maximum_local_drift": MAXIMUM_LOCAL_DRIFT,
			"max_attempts": MAX_ATTEMPTS,
			"required_valid_pairs": REQUIRED_VALID_PAIRS,
			"control_rule": "ABBA: control BEFORE (9 obs), workload x2 (9 obs each), control AFTER (9 obs); drift measured between the two controls.",
			"hot": "cache warm, repeated in-bounds queries reuse the packed candidate arrays.",
			"cold_1": "each timed iteration marks _physics_bounds_dirty and _local_wake_cache_dirty, then one in-bounds query: full per-tick rebuild + query.",
			"cold_30": "each timed iteration marks both dirty flags, then 30 in-bounds queries: one rebuild + 29 cache hits, amortized per query.",
			"reference": "pre-1E sampler copy reading _samples/_physics_bounds/_physics_first_recent_sample_index via reflection.",
			"regression_cases": ["grid", "zero", "near", "segment_endpoints", "both_sides", "random", "outside", "two_wake_overlap", "triple_overlap", "player_6", "after_append", "after_expiry", "after_break", "after_world_rebase"],
			"not_measured": ["sample_normal", "sample_water", "sample_height"],
			"block_duration_ms": "Each observation is calibrated to ~25 ms before timing; calibration is not part of the final timing.",
		},
		"snapshot": _snapshot_metadata(ocean),
		"sources": source_rows,
		"regression_static": regression["cases"],
		"regression_sums": sums,
		"candidate_identity": identity,
		"timings": timings,
		"mutation_guard": guard,
	}
	var report_path := _write_report(report)
	print("GOLD_CITY_PHASE_1E_SNAPSHOT=%s" % String(report["snapshot"]["fingerprint"]))
	print("GOLD_CITY_PHASE_1E_JSON=%s" % report_path)
	print("GOLD_CITY_PHASE_1E=PASS" if int(sums["mismatches"]) == 0 else "GOLD_CITY_PHASE_1E=FAIL")
	get_tree().quit(0)


func _collect_traffic_actors(node: Node, result: Array[BoatTrafficActor]) -> void:
	if node is BoatTrafficActor:
		result.append(node as BoatTrafficActor)
	for child: Node in node.get_children():
		_collect_traffic_actors(child, result)


func _build_live_queries(jet_ski: JetSkiController) -> PackedVector3Array:
	var result := jet_ski.water_physics_system.point_world_positions.duplicate()
	if result.size() != JetSkiWaterPhysicsSystem.BUOYANCY_POINT_COUNT:
		return PackedVector3Array()
	result.append(jet_ski.global_position)
	result.append(jet_ski.drive_system.state.propulsion_world_position)
	return result


func _read_sources(ocean: Ocean3D) -> Array[WakeTrail3D]:
	var raw := ocean.get("_local_wake_physics_sources") as Array
	var result: Array[WakeTrail3D] = []
	for value: Variant in raw:
		var wake := value as WakeTrail3D
		if is_instance_valid(wake):
			result.append(wake)
	return result


func _source_rows(sources: Array, profiles: Array) -> Array[Dictionary]:
	var rows: Array[Dictionary] = []
	for index in sources.size():
		var profile: Dictionary = profiles[index]
		rows.append({
			"index": index,
			"label": "traffic_wake_%d" % (index + 1),
			"node_path": str(sources[index].get_path()),
			"sample_count": sources[index].sample_count,
			"samples_array_size": profile["samples_size"],
			"local_physics_segment_stride": profile["stride"],
			"local_physics_lifetime": profile["local_physics_lifetime"],
			"wake_lifetime": profile["wake_lifetime"],
			"physics_first_recent_sample_index": profile["first_recent"],
			"physics_bounds": profile["bounds"],
			"physics_bounds_width": profile["bounds_width"],
			"physics_bounds_height": profile["bounds_height"],
			"physics_bounds_valid": profile["bounds_valid"],
			"local_wake_physics_active": sources[index].is_local_wake_physics_active(),
			"loop_iterations": profile["loop_iterations"],
			"geometric_projection_candidates": profile["projection_candidates"],
		})
		print(
			"GOLD_CITY_PHASE_1E_SOURCE_REAL src=%d samples=%d first_recent=%d proj=%d bounds=%.1fx%.1f"
			% [
				index,
				sources[index].sample_count,
				int(profile["first_recent"]),
				int(profile["projection_candidates"]),
				float(profile["bounds_width"]),
				float(profile["bounds_height"]),
			]
		)
	return rows


func _build_source_profile(source: WakeTrail3D) -> Dictionary:
	var samples := source.get("_samples") as Array
	var size := samples.size()
	var bounds := source.get("_physics_bounds") as Rect2
	var first_recent := clampi(
		int(source.get("_physics_first_recent_sample_index")),
		0,
		maxi(size - 1, 0)
	)
	var lifetime := maxf(minf(source.wake_lifetime, source.local_physics_lifetime), 0.1)
	var stride := maxi(source.local_physics_segment_stride, 1)
	var loop_iterations := 0
	var projection_candidates := 0
	var index := first_recent
	while index < size - 1:
		loop_iterations += 1
		var newer_index := mini(index + stride, size - 1)
		var older: Variant = samples[index]
		var newer: Variant = samples[newer_index]
		if older.age > lifetime and newer.age > lifetime:
			index = newer_index
			continue
		if newer.break_before or newer.segment_id != older.segment_id:
			index = newer_index
			continue
		var segment_length_squared := Vector2(
			float(newer.position.x) - float(older.position.x),
			float(newer.position.z) - float(older.position.z)
		).length_squared()
		if segment_length_squared <= 0.0001:
			index = newer_index
			continue
		projection_candidates += 1
		index = newer_index
	var bounds_width := maxf(bounds.size.x, 0.0)
	var bounds_height := maxf(bounds.size.y, 0.0)
	return {
		"samples_size": size,
		"bounds": bounds,
		"bounds_width": bounds_width,
		"bounds_height": bounds_height,
		"bounds_valid": bounds_width > 0.001 and bounds_height > 0.001,
		"first_recent": first_recent,
		"lifetime": lifetime,
		"stride": stride,
		"local_physics_lifetime": source.local_physics_lifetime,
		"wake_lifetime": source.wake_lifetime,
		"loop_iterations": loop_iterations,
		"projection_candidates": projection_candidates,
	}


func _mirror_candidates(source: WakeTrail3D) -> Dictionary:
	var samples := source.get("_samples") as Array
	var size := samples.size()
	var lifetime := maxf(minf(source.wake_lifetime, source.local_physics_lifetime), 0.1)
	var stride := maxi(source.local_physics_segment_stride, 1)
	var first_recent := clampi(
		int(source.get("_physics_first_recent_sample_index")),
		0,
		maxi(size - 1, 0)
	)
	var starts := PackedVector2Array()
	var segments := PackedVector2Array()
	var length_squared := PackedFloat64Array()
	var older_index := PackedInt32Array()
	var newer_index := PackedInt32Array()
	var index := first_recent
	while index < size - 1:
		var newer_index_value := mini(index + stride, size - 1)
		var older: Variant = samples[index]
		var newer: Variant = samples[newer_index_value]
		if older.age > lifetime and newer.age > lifetime:
			index = newer_index_value
			continue
		if newer.break_before or newer.segment_id != older.segment_id:
			index = newer_index_value
			continue
		var start := Vector2(older.position.x, older.position.z)
		var finish := Vector2(newer.position.x, newer.position.z)
		var segment := finish - start
		var segment_length_squared := segment.length_squared()
		if segment_length_squared <= 0.0001:
			index = newer_index_value
			continue
		starts.append(start)
		segments.append(segment)
		length_squared.append(segment_length_squared)
		older_index.append(index)
		newer_index.append(newer_index_value)
		index = newer_index_value
	return {
		"starts": starts,
		"segments": segments,
		"length_squared": length_squared,
		"older_index": older_index,
		"newer_index": newer_index,
	}


func _regression_sum(queries: int, mismatches: int, max_abs_delta: float) -> Dictionary:
	return {
		"queries": queries,
		"mismatches": mismatches,
		"max_abs_height_delta": max_abs_delta,
	}


func _run_static_regression(
	sources: Array,
	profiles: Array,
	overlap: Dictionary,
	multi_points: Dictionary,
	player_positions: PackedVector3Array
) -> Dictionary:
	var cases := Array()
	var tally := _regression_sum(0, 0, 0.0)
	for index in sources.size():
		var zero_position := _find_inside_zero(sources[index], profiles[index])
		var near_position := _find_near_segment(sources[index], profiles[index])
		var zeros := Vector3(zero_position)
		sources[index].sample_simplified_wake_height(zeros)
		sources[index].sample_simplified_wake_height(near_position)
		cases.append(_measure_case(sources[index], "grid_%d" % index, _grid_queries(sources[index], profiles[index]), tally))
		cases.append(_measure_case(sources[index], "endpoints_%d" % index, _endpoint_queries(sources[index], profiles[index]), tally))
		cases.append(_measure_case(sources[index], "sides_%d" % index, _side_queries(sources[index], profiles[index]), tally))
		cases.append(_measure_case(sources[index], "random_%d" % index, _random_queries(sources[index], profiles[index]), tally))
		cases.append(_measure_case(sources[index], "outside_%d" % index, _outside_queries(profiles[index]), tally))
		cases.append(_measure_case(sources[index], "zero_%d" % index, [zeros], tally))
		cases.append(_measure_case(sources[index], "near_%d" % index, [near_position], tally))
	if not overlap["rects"].is_empty():
		for rect: Dictionary in overlap["rects"]:
			var point := rect["world_position"] as Vector3
			for index in sources.size():
				cases.append(_measure_case(sources[index], "overlap_pair_%s_src%d" % [rect["pair"], index], [point], tally))
	if not multi_points["count_3"].is_empty():
		for point: Vector3 in multi_points["count_3"]:
			for index in sources.size():
				cases.append(_measure_case(sources[index], "triple_src%d" % index, [point], tally))
	for position: Vector3 in player_positions:
		for index in sources.size():
			cases.append(_measure_case(sources[index], "player6_src%d" % index, [position], tally))
	return {"cases": cases, "tally": tally}


func _measure_case(source: WakeTrail3D, name: String, queries: Array, tally: Dictionary) -> Dictionary:
	var mismatches := 0
	var max_abs_delta := 0.0
	for query: Vector3 in queries:
		var runtime := source.sample_simplified_wake_height(query)
		var reference := _reference_sample(source, query)
		var delta := absf(runtime - reference)
		if delta > HEIGHT_EPS:
			mismatches += 1
			max_abs_delta = maxf(max_abs_delta, delta)
	sink_tally(tally, queries.size(), mismatches, max_abs_delta)
	return {
		"name": name,
		"queries": queries.size(),
		"mismatches": mismatches,
		"max_abs_height_delta": max_abs_delta,
	}


func sink_tally(tally: Dictionary, queries: int, mismatches: int, max_abs_delta: float) -> void:
	tally["queries"] = int(tally["queries"]) + queries
	tally["mismatches"] = int(tally["mismatches"]) + mismatches
	tally["max_abs_height_delta"] = maxf(float(tally["max_abs_height_delta"]), max_abs_delta)


func _grid_queries(source: WakeTrail3D, profile: Dictionary) -> Array:
	var bounds := profile["bounds"] as Rect2
	var result := Array()
	var quanta := GRID_QUANTA
	var step_x := maxf(bounds.size.x / float(quanta), 0.001)
	var step_z := maxf(bounds.size.y / float(quanta), 0.001)
	for gy in quanta:
		for gx in quanta:
			result.append(Vector3(
				bounds.position.x + (float(gx) + 0.5) * step_x,
				_water_level,
				bounds.position.y + (float(gy) + 0.5) * step_z
			))
	return result


func _endpoint_queries(source: WakeTrail3D, profile: Dictionary) -> Array:
	var samples := source.get("_samples") as Array
	var bounds := profile["bounds"] as Rect2
	var result := Array()
	var headroom := 120
	var every := maxi(int(ceil(float(samples.size()) / float(headroom))), 1)
	for index in range(0, samples.size(), every):
		var sample: Variant = samples[index]
		var position := Vector3(sample.position.x, _water_level, sample.position.z)
		if bounds.has_point(Vector2(position.x, position.z)):
			result.append(position)
	return result


func _side_queries(source: WakeTrail3D, profile: Dictionary) -> Array:
	var samples := source.get("_samples") as Array
	var stride := maxi(int(profile["stride"]), 1)
	var first_recent := int(profile["first_recent"])
	var result := Array()
	var step := maxi(int(ceil(float(samples.size()) / 140.0)), 1)
	var index := first_recent
	while index < samples.size() - 1:
		var newer_index_value := mini(index + stride, samples.size() - 1)
		var older: Variant = samples[index]
		var newer: Variant = samples[newer_index_value]
		if not newer.break_before and newer.segment_id == older.segment_id:
			var a := Vector2(older.position.x, older.position.z)
			var b := Vector2(newer.position.x, newer.position.z)
			var delta := b - a
			var length_squared := delta.length_squared()
			if length_squared > 0.0001:
				var normal := Vector2(-delta.y, delta.x)
				var normal_length := normal.length()
				if normal_length > 0.0001:
					normal /= normal_length
					var midpoint := (a + b) * 0.5
					for offset: float in SIDE_OFFSETS:
						result.append(Vector3(
							midpoint.x + normal.x * offset,
							_water_level,
							midpoint.y + normal.y * offset
						))
						result.append(Vector3(
							midpoint.x - normal.x * offset,
							_water_level,
							midpoint.y - normal.y * offset
						))
		index += step
	return result


func _outside_queries(profile: Dictionary) -> Array:
	var bounds := profile["bounds"] as Rect2
	var result := Array()
	var margin := OUTSIDE_MARGIN
	result.append(Vector3(bounds.position.x - margin, _water_level, bounds.position.y - margin))
	result.append(Vector3(bounds.end.x + margin, _water_level, bounds.position.y - margin))
	result.append(Vector3(bounds.position.x - margin, _water_level, bounds.end.y + margin))
	result.append(Vector3(bounds.end.x + margin, _water_level, bounds.end.y + margin))
	result.append(Vector3(bounds.position.x - margin, _water_level, bounds.position.y + bounds.size.y * 0.5))
	result.append(Vector3(bounds.end.x + margin, _water_level, bounds.position.y + bounds.size.y * 0.5))
	result.append(Vector3(bounds.position.x + bounds.size.x * 0.5, _water_level, bounds.position.y - margin))
	result.append(Vector3(bounds.position.x + bounds.size.x * 0.5, _water_level, bounds.end.y + margin))
	return result


func _random_queries(source: WakeTrail3D, profile: Dictionary) -> Array:
	var bounds := profile["bounds"] as Rect2
	var result := Array()
	var rng := RandomNumberGenerator.new()
	rng.seed = RANDOM_SEED
	for _iteration in RANDOM_QUERIES:
		result.append(Vector3(
			bounds.position.x + rng.randf() * bounds.size.x,
			_water_level,
			bounds.position.y + rng.randf() * bounds.size.y
		))
	return result


func _find_inside_zero(source: WakeTrail3D, profile: Dictionary) -> Vector3:
	var bounds := profile["bounds"] as Rect2
	var quanta := 24
	var step_x := maxf(bounds.size.x / float(quanta), 0.001)
	var step_z := maxf(bounds.size.y / float(quanta), 0.001)
	for gy in quanta:
		for gx in quanta:
			var position := Vector3(
				bounds.position.x + (float(gx) + 0.5) * step_x,
				_water_level,
				bounds.position.y + (float(gy) + 0.5) * step_z
			)
			var height := source.sample_simplified_wake_height(position)
			if height == 0.0 and int(profile["loop_iterations"]) > 0:
				return position
	return Vector3(
		bounds.position.x + bounds.size.x * 0.5,
		_water_level,
		bounds.position.y + bounds.size.y * 0.5
	)


func _find_near_segment(source: WakeTrail3D, profile: Dictionary) -> Vector3:
	var samples := source.get("_samples") as Array
	var lifetime := float(profile["lifetime"])
	var best_height := 0.0
	var best_position := Vector3.ZERO
	var first_recent := int(profile["first_recent"])
	for index in range(first_recent, samples.size() - 1):
		var sample: Variant = samples[index]
		var age := float(sample.age)
		if age < MIN_SAMPLE_AGE or age >= lifetime:
			continue
		var position := Vector3(
			float(sample.position.x),
			_water_level,
			float(sample.position.z)
		)
		var height := source.sample_simplified_wake_height(position)
		_sink += height
		if absf(height) > absf(best_height):
			best_height = height
			best_position = position
	return best_position


func _compute_overlap(profiles: Array) -> Dictionary:
	var rect_list := Array()
	var world_list := PackedVector3Array()
	for first in profiles.size():
		for second in range(first + 1, profiles.size()):
			var rect_a := profiles[first]["bounds"] as Rect2
			var rect_b := profiles[second]["bounds"] as Rect2
			var intersection := rect_a.intersection(rect_b)
			if intersection.size.x > 0.001 and intersection.size.y > 0.001:
				rect_list.append({
					"pair": "%d-%d" % [first, second],
					"world_position": Vector3(
						intersection.position.x + intersection.size.x * 0.5,
						_water_level,
						intersection.position.y + intersection.size.y * 0.5
					),
				})
				world_list.append(Vector3(
					intersection.position.x + intersection.size.x * 0.5,
					_water_level,
					intersection.position.y + intersection.size.y * 0.5
				))
	return {
		"status": "OVERLAP" if not rect_list.is_empty() else "NO_OVERLAP",
		"rects": rect_list,
		"world_positions": world_list,
	}


func _multi_overlap_points(profiles: Array) -> Dictionary:
	var count_2 := PackedVector3Array()
	var count_3 := PackedVector3Array()
	var minimum := Vector2(INF, INF)
	var maximum := Vector2(-INF, -INF)
	for profile: Dictionary in profiles:
		var bounds := profile["bounds"] as Rect2
		minimum = minimum.min(bounds.position)
		maximum = maximum.max(bounds.end)
	var quanta := 24
	var step_x := maxf((maximum.x - minimum.x) / float(quanta), 0.001)
	var step_z := maxf((maximum.y - minimum.y) / float(quanta), 0.001)
	for gy in quanta:
		for gx in quanta:
			var position := Vector3(
				minimum.x + (float(gx) + 0.5) * step_x,
				_water_level,
				minimum.y + (float(gy) + 0.5) * step_z
			)
			var contained := 0
			for profile: Dictionary in profiles:
				if (profile["bounds"] as Rect2).has_point(Vector2(position.x, position.z)):
					contained += 1
			if contained == 2:
				count_2.append(position)
			elif contained == 3:
				count_3.append(position)
	return {"count_2": count_2, "count_3": count_3}


func _candidate_identity(sources: Array) -> Array[Dictionary]:
	var rows: Array[Dictionary] = []
	for index in sources.size():
		var source := sources[index] as WakeTrail3D
		if not source.is_local_wake_physics_active():
			rows.append({"index": index, "active": false, "equal": false})
			continue
		var bounds := source.get("_physics_bounds") as Rect2
		var probe := Vector3(
			bounds.position.x + bounds.size.x * 0.5,
			_water_level,
			bounds.position.y + bounds.size.y * 0.5
		)
		source.sample_simplified_wake_height(probe)
		var cache_starts := source.get("_local_wake_candidate_start") as PackedVector2Array
		var cache_segments := source.get("_local_wake_candidate_segment") as PackedVector2Array
		var cache_length_squared := source.get("_local_wake_candidate_length_squared") as PackedFloat64Array
		var cache_older := source.get("_local_wake_candidate_older_index") as PackedInt32Array
		var cache_newer := source.get("_local_wake_candidate_newer_index") as PackedInt32Array
		var mirror := _mirror_candidates(source)
		var equal := (
			cache_starts.size() == (mirror["starts"] as PackedVector2Array).size()
		)
		if equal:
			for i in cache_starts.size():
				if (
					cache_starts[i] != (mirror["starts"] as PackedVector2Array)[i]
					or cache_segments[i] != (mirror["segments"] as PackedVector2Array)[i]
					or absf(cache_length_squared[i] - (mirror["length_squared"] as PackedFloat64Array)[i]) > 1e-9
					or cache_older[i] != (mirror["older_index"] as PackedInt32Array)[i]
					or cache_newer[i] != (mirror["newer_index"] as PackedInt32Array)[i]
				):
					equal = false
					break
		rows.append({
			"index": index,
			"active": true,
			"cached_candidates": cache_starts.size(),
			"mirrored_candidates": (mirror["starts"] as PackedVector2Array).size(),
			"equal": equal,
		})
	return rows


func _run_timings(sources: Array, profiles: Array, overlap: Dictionary, ocean: Ocean3D, player_positions: PackedVector3Array) -> Dictionary:
	var scenarios := Array()
	for index in sources.size():
		var zero_position := _find_inside_zero(sources[index], profiles[index])
		var near_position := _find_near_segment(sources[index], profiles[index])
		var far_control := Vector3(
			(profiles[index]["bounds"] as Rect2).position.x - BOUND_FAR_MARGIN,
			_water_level,
			(profiles[index]["bounds"] as Rect2).position.y - BOUND_FAR_MARGIN
		)
		scenarios.append(_run_scenario_signal("hot", "src_%d_zero_hot" % index, {
			"source": sources[index], "position": zero_position,
		}, {
			"source": sources[index], "position": far_control,
		}))
		scenarios.append(_run_scenario_signal("hot", "src_%d_near_hot" % index, {
			"source": sources[index], "position": near_position,
		}, {
			"source": sources[index], "position": far_control,
		}))
		scenarios.append(_run_scenario_signal("ref", "src_%d_zero_ref" % index, {
			"source": sources[index], "position": zero_position,
		}, {
			"source": sources[index], "position": far_control,
		}))
		scenarios.append(_run_scenario_signal("ref", "src_%d_near_ref" % index, {
			"source": sources[index], "position": near_position,
		}, {
			"source": sources[index], "position": far_control,
		}))
		scenarios.append(_run_scenario_signal("cold_1", "src_%d_near_cold1" % index, {
			"source": sources[index], "position": near_position,
		}, {
			"source": sources[index], "position": far_control,
		}))
		scenarios.append(_run_scenario_signal("cold_30", "src_%d_near_cold30" % index, {
			"source": sources[index], "position": near_position,
		}, {
			"source": sources[index], "position": far_control,
		}, COLD_QUERY_COUNT))
	scenarios.append(_run_scenario_signal("aggregate", "aggregate_out", {
		"ocean": ocean, "position": Vector3(
			-5000.0, _water_level, -5000.0
		),
	}, {
		"ocean": ocean, "position": Vector3(
			-134000.0, _water_level, -134000.0
		),
	}))
	var overlap_position: Vector3 = Vector3.ZERO
	if not overlap["rects"].is_empty():
		overlap_position = (overlap["rects"][0] as Dictionary)["world_position"] as Vector3
		scenarios.append(_run_scenario_signal("aggregate", "aggregate_near_overlap", {
			"ocean": ocean, "position": overlap_position,
		}, {
			"ocean": ocean, "position": Vector3(-134000.0, _water_level, -134000.0),
		}))
	var player_control := PackedVector3Array()
	for position: Vector3 in player_positions:
		player_control.append(position + CONTROL_OFFSET)
	scenarios.append(_run_scenario_signal("aggregate_pass", "aggregate_player_6", {
		"ocean": ocean, "positions": player_positions,
	}, {
		"ocean": ocean, "positions": player_control,
	}, 6))

	for scenario: Dictionary in scenarios:
		var name := String(scenario["name"])
		print(
			"GOLD_CITY_PHASE_1E_TIMING name=%s per_query_us=%.3f drift=%.4f status=%s pairs=%d"
			% [
				name,
				float(scenario["authoritative_us_per_query"]),
				float(scenario["drift"]),
				String(scenario["status"]),
				int(scenario["valid_pairs"]),
			]
		)

	var rows := _scenario_map(scenarios)
	var per_source := Dictionary()
	for index in sources.size():
		per_source[index] = {
			"zero_hot_us": _row_us(rows, "src_%d_zero_hot" % index),
			"near_hot_us": _row_us(rows, "src_%d_near_hot" % index),
			"zero_ref_us": _row_us(rows, "src_%d_zero_ref" % index),
			"near_ref_us": _row_us(rows, "src_%d_near_ref" % index),
			"near_cold1_us": _row_us(rows, "src_%d_near_cold1" % index),
			"near_cold30_us": _row_us(rows, "src_%d_near_cold30" % index),
			"hot_vs_ref_speedup": _row_us(rows, "src_%d_near_ref" % index) / _row_us(rows, "src_%d_near_hot" % index) if _row_us(rows, "src_%d_near_hot" % index) > 0.0 else -1.0,
		}
	var aggregate := {
		"out_us": _row_us(rows, "aggregate_out"),
		"near_overlap_us": _row_us(rows, "aggregate_near_overlap") if rows.has("aggregate_near_overlap") else -1.0,
		"player_6_us": _row_us(rows, "aggregate_player_6"),
	}
	print(
		"GOLD_CITY_PHASE_1E_AGGREGATE out=%.3f near=%.3f player=%.3f"
		% [float(aggregate["out_us"]), float(aggregate["near_overlap_us"]), float(aggregate["player_6_us"])]
	)
	print("GOLD_CITY_PHASE_1E_OVERLAP_STATUS=%s" % String(overlap["status"]))
	return {"scenarios": scenarios, "per_source": per_source, "aggregate": aggregate}


func _row_us(rows: Dictionary, name: String) -> float:
	var row: Dictionary = rows.get(name, {})
	return float(row.get("authoritative_us_per_query", -1.0))


func _run_mutation_regression(sources: Array) -> Array:
	var rows := Array()
	for index in sources.size():
		var source := sources[index] as WakeTrail3D
		var before := _profile_candidates(source)
		rows.append(_mutation_chain(source, index, before))
	return rows


func _profile_candidates(source: WakeTrail3D) -> int:
	var mirror := _mirror_candidates(source)
	return (mirror["starts"] as PackedVector2Array).size()


func _mutation_chain(source: WakeTrail3D, index: int, candidates_before: int) -> Dictionary:
	var chain := Array()
	var mutation := _compare_mutation(source, _fn_append, "after_append")
	chain.append(mutation)
	mutation = _compare_mutation(source, _fn_expiry, "after_expiry")
	chain.append(mutation)
	mutation = _compare_mutation(source, _fn_break, "after_break")
	chain.append(mutation)
	mutation = _compare_mutation(source, _fn_rebase, "after_world_rebase")
	chain.append(mutation)
	return {
		"index": index,
		"candidates_before": candidates_before,
		"candidates_after": _profile_candidates(source),
		"chain": chain,
	}


func _fn_append(source: WakeTrail3D) -> void:
	var samples := source.get("_samples") as Array
	if samples.size() >= 2:
		var newest: Variant = samples[samples.size() - 1]
		var previous: Variant = samples[samples.size() - 2]
		var newest_pos: Vector3 = newest.position
		var previous_pos: Vector3 = previous.position
		var delta := newest_pos - previous_pos
		samples.append(WakeTrail3D.WakeSample.new(
			newest_pos + delta,
			newest.forward_direction as Vector3,
			newest.speed_factor as float,
			newest.horizontal_speed as float,
			newest.initial_width as float,
			newest.steering_bias as float,
			newest.segment_id as int,
			false
		))
	source.set("_physics_bounds_dirty", true)
	source.set("_local_wake_cache_dirty", true)


func _fn_expiry(source: WakeTrail3D) -> void:
	var samples := source.get("_samples") as Array
	var bump := maxf(minf(source.wake_lifetime, source.local_physics_lifetime), 0.1) * 0.24
	for sample: Variant in samples:
		sample.age += bump
	var retention_lifetime := source.wake_lifetime
	if source.legacy_global_deformation_enabled:
		retention_lifetime = maxf(source.wake_lifetime, source.directional_history_lifetime)
	while not samples.is_empty() and float(samples[0].age) >= retention_lifetime:
		samples.pop_front()
	source.set("_physics_bounds_dirty", true)
	source.set("_local_wake_cache_dirty", true)


func _fn_break(source: WakeTrail3D) -> void:
	var samples := source.get("_samples") as Array
	var target := int(float(samples.size()) * 0.42)
	target = clampi(target, 0, maxi(samples.size() - 1, 0))
	if target >= 0 and target < samples.size() and samples.size() >= 2:
		var changed_id := int(samples[target].segment_id) + 1
		for i in range(target, samples.size()):
			samples[i].segment_id = changed_id
		samples[target].break_before = true
	source.set("_physics_bounds_dirty", true)
	source.set("_local_wake_cache_dirty", true)


func _fn_rebase(source: WakeTrail3D) -> void:
	source.apply_world_rebase(Vector3(12.5, 0.0, -7.25))


func _compare_mutation(source: WakeTrail3D, mutator: Callable, name: String) -> Dictionary:
	mutator.call(source)
	source.call(&"_ensure_physics_bounds")
	var profile := _build_source_profile(source)
	var queries := Array()
	if bool(profile["bounds_valid"]):
		queries = _grid_queries(source, profile)
	var mismatches := 0
	var max_abs_delta := 0.0
	for query: Vector3 in queries:
		var runtime := source.sample_simplified_wake_height(query)
		var reference := _reference_sample(source, query)
		var delta := absf(runtime - reference)
		if delta > HEIGHT_EPS:
			mismatches += 1
			max_abs_delta = maxf(max_abs_delta, delta)
	var this_one := _profile_candidates(source)
	var no_flag_delta := 0.0
	var no_flag_mismatches := 0
	if name == "after_expiry":
		var guarded := _no_flag_expiry_probe(source, queries)
		no_flag_mismatches = int(guarded["mismatches"])
		no_flag_delta = float(guarded["max_abs_delta"])
	return {
		"name": name,
		"queries": queries.size(),
		"mismatches": mismatches,
		"max_abs_height_delta": max_abs_delta,
		"candidates_after": this_one,
		"cache_rebuilt_from_scratch": _cache_from_scratch(source),
		"guard_probe_no_flag_mismatches": no_flag_mismatches,
		"guard_probe_no_flag_max_abs_delta": no_flag_delta,
	}


func _no_flag_expiry_probe(source: WakeTrail3D, queries: Array) -> Dictionary:
	var samples := source.get("_samples") as Array
	var probe_snapshot := Array()
	for sample: Variant in samples:
		probe_snapshot.append(float(sample.age))
	var legacy := source.legacy_global_deformation_enabled
	source.set("legacy_global_deformation_enabled", false)
	var mismatches := 0
	var max_abs_delta := 0.0
	for query: Vector3 in queries:
		var runtime := source.sample_simplified_wake_height(query)
		var reference := _reference_sample(source, query)
		var delta := absf(runtime - reference)
		if delta > HEIGHT_EPS:
			mismatches += 1
			max_abs_delta = maxf(max_abs_delta, delta)
	source.set("legacy_global_deformation_enabled", legacy)
	for i in samples.size():
		samples[i].age = probe_snapshot[i]
	source.set("_physics_bounds_dirty", true)
	source.set("_local_wake_cache_dirty", true)
	return {"mismatches": mismatches, "max_abs_delta": max_abs_delta}


func _cache_from_scratch(source: WakeTrail3D) -> bool:
	source.set("_local_wake_cache_built", false)
	source.set("_local_wake_cache_dirty", true)
	source.sample_simplified_wake_height(_probe_point(source))
	return bool(source.get("_local_wake_cache_built"))


func _probe_point(source: WakeTrail3D) -> Vector3:
	var bounds := source.get("_physics_bounds") as Rect2
	if bounds.size.x <= 0.0 or bounds.size.y <= 0.0:
		return Vector3(_water_level, _water_level, _water_level)
	return Vector3(
		bounds.position.x + bounds.size.x * 0.5,
		_water_level,
		bounds.position.y + bounds.size.y * 0.5
	)


func _reference_sample(source: WakeTrail3D, world_position: Vector3) -> float:
	if not source.is_local_wake_physics_active() or not is_instance_valid(source.get("_ocean")):
		return 0.0
	source.call(&"_ensure_physics_bounds")
	var query := Vector2(world_position.x, world_position.z)
	if not (source.get("_physics_bounds") as Rect2).has_point(query):
		return 0.0
	var samples := source.get("_samples") as Array
	var ocean := source.get("_ocean") as Ocean3D
	var size := samples.size()
	var lifetime := maxf(minf(source.wake_lifetime, source.local_physics_lifetime), 0.1)
	var stride := maxi(source.local_physics_segment_stride, 1)
	var best_index_value: int = -1
	var best_ratio: float = 0.0
	var best_distance_squared: float = INF
	var index := clampi(
		int(source.get("_physics_first_recent_sample_index")),
		0,
		maxi(size - 1, 0)
	)
	while index < size - 1:
		var candidate_older: Variant = samples[index]
		var newer_index_value := mini(index + stride, size - 1)
		var candidate_newer: Variant = samples[newer_index_value]
		if candidate_older.age > lifetime and candidate_newer.age > lifetime:
			index = newer_index_value
			continue
		if (
			candidate_newer.break_before
			or candidate_newer.segment_id != candidate_older.segment_id
		):
			index = newer_index_value
			continue
		var start := Vector2(candidate_older.position.x, candidate_older.position.z)
		var finish := Vector2(candidate_newer.position.x, candidate_newer.position.z)
		var segment := finish - start
		var segment_length_squared := segment.length_squared()
		if segment_length_squared <= 0.0001:
			index = newer_index_value
			continue
		var ratio := clampf(
			(query - start).dot(segment) / segment_length_squared,
			0.0,
			1.0
		)
		var distance_squared := query.distance_squared_to(start + segment * ratio)
		if distance_squared < best_distance_squared:
			best_distance_squared = distance_squared
			best_index_value = index
			best_ratio = ratio
		index = newer_index_value
	if best_index_value < 0:
		return 0.0
	var selected_older: Variant = samples[best_index_value]
	var selected_newer: Variant = samples[mini(
		best_index_value + stride,
		size - 1
	)]
	var age := lerpf(selected_older.age, selected_newer.age, best_ratio)
	if age < 0.12 or age >= lifetime:
		return 0.0
	var initial_width := lerpf(
		selected_older.initial_width,
		selected_newer.initial_width,
		best_ratio
	)
	var source_speed := lerpf(
		selected_older.horizontal_speed,
		selected_newer.horizontal_speed,
		best_ratio
	)
	var intensity := clampf(
		lerpf(selected_older.speed_factor, selected_newer.speed_factor, best_ratio)
			* source.directional_strength_multiplier,
		0.0,
		2.0
	)
	var front_distance := initial_width + age * (
		ocean.directional_wake_propagation_speed
			+ source_speed * ocean.directional_wake_opening_slope
	)
	var lateral_distance := sqrt(best_distance_squared)
	var crest_width := maxf(ocean.directional_wake_arm_width * 1.8, 0.65)
	if lateral_distance > front_distance + crest_width:
		return 0.0
	var crest := 1.0 - smoothstep(
		0.0,
		crest_width,
		absf(lateral_distance - front_distance)
	)
	var center_width := maxf(initial_width * 0.78, 0.45)
	var center_depression := 1.0 - smoothstep(
		center_width * 0.30,
		center_width,
		lateral_distance
	)
	var age_fade := 1.0 - smoothstep(lifetime * 0.58, lifetime, age)
	var height := (
		(
			ocean.directional_wake_amplitude * crest
				- ocean.directional_wake_center_depression * center_depression
		)
		* intensity
		* age_fade
		* ocean.directional_wake_physics_response
		* source.local_physics_height_multiplier
	)
	return clampf(
		height,
		-ocean.vehicle_interaction_maximum_displacement,
		ocean.vehicle_interaction_maximum_displacement
	)


func _set_state(state: Dictionary) -> void:
	_bench_source = state.get("source", null) as WakeTrail3D
	_bench_position = state.get("position", Vector3.ZERO) as Vector3
	_bench_ocean = state.get("ocean", null) as Ocean3D
	_bench_positions = state.get("positions", PackedVector3Array()) as PackedVector3Array


func _calibrate(mode: String, target_us: float) -> int:
	var probe := 2048
	var elapsed := _time_branch(mode, probe)
	var per_iter := maxf(elapsed / float(probe), 0.05)
	var repeats := int(round(target_us / per_iter))
	repeats = clampi(repeats, 16, 4194304)
	var adjusted := false
	for _round in 3:
		var observation_us := _time_branch(mode, repeats)
		if observation_us < 16000.0:
			repeats = int(float(repeats) * (target_us / maxf(observation_us, 1.0)))
			repeats = clampi(repeats, 16, 4194304)
			_time_branch(mode, 256)
			adjusted = true
		else:
			break
	return repeats


func _measure_series(mode: String, repeats: int) -> Dictionary:
	var timings := PackedFloat64Array()
	for _observation in OBSERVATIONS:
		var elapsed := _time_branch(mode, repeats)
		timings.append(elapsed / float(repeats))
	return _stats(timings)


func _time_branch(mode: String, count: int) -> float:
	var started := Time.get_ticks_usec()
	match mode:
		"hot", "out":
			for _iteration in count:
				_sink += _bench_source.sample_simplified_wake_height(_bench_position)
		"ref":
			for _iteration in count:
				_sink += _reference_sample(_bench_source, _bench_position)
		"cold_1":
			for _iteration in count:
				_bench_source.set("_physics_bounds_dirty", true)
				_bench_source.set("_local_wake_cache_dirty", true)
				_sink += _bench_source.sample_simplified_wake_height(_bench_position)
		"cold_30":
			for _iteration in count:
				_bench_source.set("_physics_bounds_dirty", true)
				_bench_source.set("_local_wake_cache_dirty", true)
				for _query in COLD_QUERY_COUNT:
					_sink += _bench_source.sample_simplified_wake_height(_bench_position)
		"aggregate":
			for _iteration in count:
				_sink += _bench_ocean.sample_local_wake_height(_bench_position)
		"aggregate_pass":
			for _iteration in count:
				for position: Vector3 in _bench_positions:
					_sink += _bench_ocean.sample_local_wake_height(position)
	return float(Time.get_ticks_usec() - started)


func _run_scenario_signal(
	mode: String,
	name: String,
	workload_state: Dictionary,
	control_state: Dictionary,
	query_divisor: int = 1
) -> Dictionary:
	_set_state(control_state)
	var control_repeats := _calibrate(mode, TARGET_OBSERVATION_US)
	_set_state(workload_state)
	var workload_repeats := _calibrate(mode, TARGET_OBSERVATION_US)
	var valid_medians := PackedFloat64Array()
	var attempt_rows := Array()
	var last_a1 := 0.0
	var last_a2 := 0.0
	var last_b1 := 0.0
	var last_b2 := 0.0
	var last_drift := INF
	for attempt in MAX_ATTEMPTS:
		_set_state(control_state)
		var a1 := float(_measure_series(mode, control_repeats)["median"])
		_set_state(workload_state)
		var b1 := float(_measure_series(mode, workload_repeats)["median"])
		var b2 := float(_measure_series(mode, workload_repeats)["median"])
		_set_state(control_state)
		var a2 := float(_measure_series(mode, control_repeats)["median"])
		var reference := (a1 + a2) * 0.5
		var drift := absf(a2 - a1) / reference if reference > 0.0 else INF
		attempt_rows.append({
			"attempt": attempt,
			"a1_us_per_iter": a1,
			"b1_us_per_iter": b1,
			"b2_us_per_iter": b2,
			"a2_us_per_iter": a2,
			"drift": drift,
			"valid": drift <= MAXIMUM_LOCAL_DRIFT,
		})
		last_a1 = a1
		last_a2 = a2
		last_b1 = b1
		last_b2 = b2
		last_drift = drift
		if drift <= MAXIMUM_LOCAL_DRIFT:
			valid_medians.append(b1)
			valid_medians.append(b2)
		if valid_medians.size() >= REQUIRED_VALID_PAIRS:
			break
	var status := "VALID" if valid_medians.size() >= REQUIRED_VALID_PAIRS else "INESTABLE"
	var authoritative := _median(valid_medians) if status == "VALID" else -1.0
	return {
		"name": name,
		"mode": mode,
		"status": status,
		"valid_pairs": valid_medians.size(),
		"attempts": attempt_rows.size(),
		"drift": last_drift,
		"a1_us_per_iter": last_a1,
		"a2_us_per_iter": last_a2,
		"b1_us_per_iter": last_b1,
		"b2_us_per_iter": last_b2,
		"authoritative_us_per_iter": authoritative,
		"authoritative_us_per_query": authoritative / float(query_divisor),
		"query_divisor": query_divisor,
		"attempts_rows": attempt_rows,
	}


func _scenario_map(scenarios: Array) -> Dictionary:
	var result := {}
	for scenario: Dictionary in scenarios:
		result[String(scenario["name"])] = scenario
	return result


func _snapshot_metadata(ocean: Ocean3D) -> Dictionary:
	return {
		"fingerprint": str(hash("%.6f" % ocean.get_simulation_time())),
		"simulation_time": ocean.get_simulation_time(),
		"water_level": ocean.water_level,
	}


func _regression_sums(tally: Dictionary) -> Dictionary:
	return {
		"queries": int(tally["queries"]),
		"mismatches": int(tally["mismatches"]),
		"max_abs_height_delta": float(tally["max_abs_height_delta"]),
		"pass": int(tally["mismatches"]) == 0,
	}


func _median(values: PackedFloat64Array) -> float:
	if values.is_empty():
		return -1.0
	var sorted := values.duplicate()
	sorted.sort()
	return _percentile(sorted, 0.50)


func _stats(values: PackedFloat64Array) -> Dictionary:
	if values.is_empty():
		return {"count": 0, "mean": 0.0, "median": 0.0, "p50": 0.0, "p95": 0.0, "p99": 0.0, "min": 0.0, "max": 0.0}
	var sorted := values.duplicate()
	sorted.sort()
	var sum := 0.0
	for value: float in sorted:
		sum += value
	return {
		"count": sorted.size(),
		"mean": sum / float(sorted.size()),
		"median": _percentile(sorted, 0.50),
		"p50": _percentile(sorted, 0.50),
		"p95": _percentile(sorted, 0.95),
		"p99": _percentile(sorted, 0.99),
		"min": sorted[0],
		"max": sorted[-1],
	}


func _percentile(sorted: PackedFloat64Array, ratio: float) -> float:
	if sorted.is_empty():
		return 0.0
	var position := clampf(ratio, 0.0, 1.0) * float(sorted.size() - 1)
	var lower := int(floor(position))
	var upper := mini(lower + 1, sorted.size() - 1)
	return lerpf(sorted[lower], sorted[upper], position - float(lower))


func _argument_value(prefix: String, fallback: String) -> String:
	for argument: String in OS.get_cmdline_user_args():
		if argument.begins_with(prefix):
			return argument.trim_prefix(prefix)
	return fallback


func _write_report(report: Dictionary) -> String:
	var absolute_directory := ProjectSettings.globalize_path(OUTPUT_DIRECTORY)
	if DirAccess.make_dir_recursive_absolute(absolute_directory) != OK:
		return "ERROR_CREATING_OUTPUT_DIRECTORY"
	var timestamp := Time.get_datetime_string_from_system().replace(":", "-")
	var path := "%s/ocean_phase_1e_cache_%s_%s.json" % [
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


func _fail(message: String) -> void:
	get_tree().paused = false
	push_error("Ocean Phase 1E Local Wake Cache: %s" % message)
	get_tree().quit(1)