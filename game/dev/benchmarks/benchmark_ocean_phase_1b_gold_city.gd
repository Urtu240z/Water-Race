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
const INTERNAL_DIRECTIONAL_SAMPLES_PER_WATER_QUERY := 7

var _sink: float = 0.0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	call_deferred(&"_run")


func _run() -> void:
	Engine.max_fps = 0
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	# Prevent load-time performance from changing how many physics ticks Gold
	# City advances before the deterministic 300-tick capture window begins.
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
		_fail("Gold City benchmark could not resolve Ocean, JetSki, or BoatTraffic.")
		return
	var traffic_actors: Array[BoatTrafficActor] = []
	_collect_traffic_actors(traffic_root, traffic_actors)
	if traffic_actors.size() != 3:
		_fail("Expected 3 Gold City traffic actors; found %d." % traffic_actors.size())
		return
	for actor: BoatTrafficActor in traffic_actors:
		actor.camera_visibility_optimization_enabled = false
		actor.call(&"_set_camera_effects_active", true)

	get_tree().paused = false
	var physics_process_msec := PackedFloat64Array()
	var frame_process_msec := PackedFloat64Array()
	var physics_frame_wall_msec := PackedFloat64Array()
	var previous_frame_usec := Time.get_ticks_usec()
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
		previous_frame_usec = Time.get_ticks_usec()
	ocean.call(&"_update_directional_wake_segments")
	var active_count := int(ocean.get("_directional_wake_active_count"))
	if active_count <= 0:
		_fail("Gold City produced no active directional-wake segments.")
		return

	var live_core := jet_ski.water_physics_system.point_world_positions.duplicate()
	if live_core.size() != JetSkiWaterPhysicsSystem.BUOYANCY_POINT_COUNT:
		_fail("JetSki did not expose its four live buoyancy query positions.")
		return
	var live_full := live_core.duplicate()
	live_full.append(jet_ski.global_position)
	live_full.append(jet_ski.drive_system.state.propulsion_world_position)

	var route_queries := _build_traffic_corridor_queries(ocean, jet_ski)
	var corridor_core_16 := route_queries.get("core", PackedVector3Array()) as PackedVector3Array
	var corridor_full_24 := route_queries.get("full", PackedVector3Array()) as PackedVector3Array
	if corridor_core_16.size() != 16 or corridor_full_24.size() != 24:
		_fail(
			"Could not build the 4-JetSki-equivalent Gold City workload (core=%d full=%d)."
			% [corridor_core_16.size(), corridor_full_24.size()]
		)
		return
	var corridor_core_4 := corridor_core_16.slice(0, 4)
	var corridor_full_6 := corridor_full_24.slice(0, 6)

	# Freeze the exact Gold City state. Direct sample_water() calls remain valid,
	# while traffic, JetSki physics, and wake ages can no longer move between rows.
	city.process_mode = Node.PROCESS_MODE_DISABLED
	var workloads := [
		{
			"name": "live_player_full_6",
			"positions": live_full,
			"queries": 6,
			"description": "One live Gold City JetSki physics tick",
		},
		{
			"name": "traffic_corridor_core_4",
			"positions": corridor_core_4,
			"queries": 4,
			"description": "One JetSki buoyancy footprint on a real traffic-wake segment",
		},
		{
			"name": "traffic_corridor_full_6",
			"positions": corridor_full_6,
			"queries": 6,
			"description": "One complete JetSki tick on a real traffic-wake segment",
		},
		{
			"name": "traffic_corridor_core_16",
			"positions": corridor_core_16,
			"queries": 16,
			"description": "Four JetSki buoyancy footprints on real traffic-wake segments",
		},
		{
			"name": "traffic_corridor_full_24",
			"positions": corridor_full_24,
			"queries": 24,
			"description": "Four complete JetSki ticks on real traffic-wake segments",
		},
	]
	var culling_rows: Array[Dictionary] = []
	var timing_rows: Array[Dictionary] = []
	for workload: Dictionary in workloads:
		var positions := workload["positions"] as PackedVector3Array
		culling_rows.append(_calculate_culling(ocean, String(workload["name"]), positions))
		var control_positions := _build_control_positions(positions)
		var before := _measure_control(ocean, control_positions)
		var timing := _measure_workload(ocean, positions)
		var after := _measure_control(ocean, control_positions)
		var before_median := float(before.get("median", 0.0))
		var after_median := float(after.get("median", 0.0))
		var reference := (before_median + after_median) * 0.5
		var drift := (
			absf(after_median - before_median) / reference
			if reference > 0.0
			else INF
		)
		var query_count := int(workload["queries"])
		var median_per_query := float(timing.get("median", 0.0)) / float(query_count)
		timing_rows.append({
			"name": workload["name"],
			"description": workload["description"],
			"queries_per_workload": query_count,
			"timing_us_per_workload": timing,
			"control_before_us_per_query": before,
			"control_after_us_per_query": after,
			"control_reference_us_per_query": reference,
			"local_relative_drift": drift,
			"valid": drift <= MAXIMUM_LOCAL_DRIFT,
			"median_us_per_query": median_per_query,
			"normalized_median_per_query_ratio": (
				median_per_query / reference if reference > 0.0 else INF
			),
		})
		print(
			"GOLD_CITY_PHASE_1B_TIMING name=%s queries=%d median_us=%.3f normalized=%.4f drift=%.4f valid=%s"
			% [
				String(workload["name"]),
				query_count,
				float(timing.get("median", 0.0)),
				float(timing_rows[-1]["normalized_median_per_query_ratio"]),
				drift,
				str(drift <= MAXIMUM_LOCAL_DRIFT),
			]
		)
		await get_tree().process_frame

	var report := {
		"schema": "ocean_phase_1b_gold_city_v1",
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
			"internal_directional_samples_per_water_query": INTERNAL_DIRECTIONAL_SAMPLES_PER_WATER_QUERY,
			"workload_source": "Live JetSki query geometry replayed at current Gold City traffic-wake segment transforms",
		},
		"snapshot": _snapshot_metadata(ocean, workloads),
		"directional_sources": _directional_source_metadata(jet_ski, traffic_actors),
		"culling": culling_rows,
		"timings": timing_rows,
		"frame_diagnostic": {
			"note": "Headless Gold City diagnostic; not an FPS claim",
			"physics_process_msec": _stats(physics_process_msec),
			"frame_process_msec": _stats(frame_process_msec),
			"physics_frame_wall_msec": _stats(physics_frame_wall_msec),
		},
	}
	var report_path := _write_report(report)
	print("GOLD_CITY_PHASE_1B_ACTIVE_SEGMENTS=%d" % active_count)
	print("GOLD_CITY_PHASE_1B_SNAPSHOT=%s" % String(report["snapshot"]["fingerprint"]))
	print("GOLD_CITY_PHASE_1B_JSON=%s" % report_path)
	print("GOLD_CITY_PHASE_1B_BENCHMARK=PASS")
	get_tree().quit(0)


func _collect_traffic_actors(node: Node, result: Array[BoatTrafficActor]) -> void:
	if node is BoatTrafficActor:
		result.append(node as BoatTrafficActor)
	for child: Node in node.get_children():
		_collect_traffic_actors(child, result)


func _build_traffic_corridor_queries(
	ocean: Ocean3D,
	jet_ski: JetSkiController
) -> Dictionary:
	var starts := ocean.get("_directional_wake_start_positions") as PackedVector2Array
	var ends := ocean.get("_directional_wake_end_positions") as PackedVector2Array
	var active_count := int(ocean.get("_directional_wake_active_count"))
	var active_indices := PackedInt32Array()
	for index in active_count:
		if (ends[index] - starts[index]).length_squared() > 0.0001:
			active_indices.append(index)
	if active_indices.is_empty():
		return {}
	# Derive the footprint from the positions consumed by the immediately
	# preceding real physics tick, rather than duplicating marker configuration.
	var inverse_live_transform := jet_ski.global_transform.affine_inverse()
	var local_buoyancy := PackedVector3Array()
	for live_position: Vector3 in jet_ski.water_physics_system.point_world_positions:
		local_buoyancy.append(inverse_live_transform * live_position)
	var propulsion_local := (
		inverse_live_transform * jet_ski.drive_system.state.propulsion_world_position
	)
	var core := PackedVector3Array()
	var full := PackedVector3Array()
	for pose_index in 4:
		var selected_offset := int(round(
			float(pose_index) * float(active_indices.size() - 1) / 3.0
		))
		var segment_index := active_indices[selected_offset]
		var logical_center := (starts[segment_index] + ends[segment_index]) * 0.5
		var world_center := ocean.logical_to_world_xz(logical_center)
		var logical_direction := ends[segment_index] - starts[segment_index]
		if logical_direction.length_squared() <= 0.0001:
			logical_direction = Vector2(0.0, -1.0)
		else:
			logical_direction = logical_direction.normalized()
		var forward := Vector3(logical_direction.x, 0.0, logical_direction.y)
		var basis := Basis.looking_at(forward, Vector3.UP)
		var origin := Vector3(world_center.x, ocean.water_level, world_center.y)
		var pose := Transform3D(basis, origin)
		for local_point: Vector3 in local_buoyancy:
			var query := pose * local_point
			core.append(query)
			full.append(query)
		full.append(pose.origin)
		full.append(pose * propulsion_local)
	return {"core": core, "full": full}


func _calculate_culling(
	ocean: Ocean3D,
	workload_name: String,
	positions: PackedVector3Array
) -> Dictionary:
	var starts := ocean.get("_directional_wake_start_positions") as PackedVector2Array
	var ends := ocean.get("_directional_wake_end_positions") as PackedVector2Array
	var navigable := ocean.get("_directional_wake_navigable") as PackedInt32Array
	var active_count := int(ocean.get("_directional_wake_active_count"))
	var global_min := ocean.get("_directional_wake_physics_bounds_min") as Vector2
	var global_max := ocean.get("_directional_wake_physics_bounds_max") as Vector2
	var safe_wavelength := maxf(ocean.directional_wake_wavelength, 0.05)
	var safe_arm_width := maxf(ocean.directional_wake_arm_width, 0.08)
	var segment_mins := PackedVector2Array()
	var segment_maxs := PackedVector2Array()
	segment_mins.resize(active_count)
	segment_maxs.resize(active_count)
	var navigable_count := 0
	for index in active_count:
		if navigable[index] == 0:
			continue
		navigable_count += 1
		var reach := ocean._directional_wake_physical_reach(
			index,
			safe_wavelength,
			safe_arm_width
		)
		var expansion := Vector2(reach, reach)
		segment_mins[index] = starts[index].min(ends[index]) - expansion
		segment_maxs[index] = starts[index].max(ends[index]) + expansion
	var global_rejected_samples := 0
	var entered_samples := 0
	var considered := 0
	var discarded := 0
	var evaluated := 0
	var fully_rejected_queries := 0
	var evaluated_per_sample := PackedFloat64Array()
	var evaluated_per_query := PackedFloat64Array()
	for world_position: Vector3 in positions:
		var logical := ocean.world_to_logical_xz(world_position)
		var step := maxf(ocean.normal_sample_step, 0.001)
		var internal_samples := PackedVector2Array([
			logical,
			logical - Vector2(step, 0.0),
			logical + Vector2(step, 0.0),
			logical - Vector2(0.0, step),
			logical + Vector2(0.0, step),
			logical,
			logical,
		])
		var query_evaluated := 0
		var query_enters_phase_1b := false
		for sample_position: Vector2 in internal_samples:
			if _outside_bounds(sample_position, global_min, global_max):
				global_rejected_samples += 1
				evaluated_per_sample.append(0.0)
				continue
			query_enters_phase_1b = true
			entered_samples += 1
			var sample_evaluated := 0
			for index in active_count:
				if navigable[index] == 0:
					continue
				considered += 1
				if _outside_bounds(sample_position, segment_mins[index], segment_maxs[index]):
					discarded += 1
				else:
					evaluated += 1
					sample_evaluated += 1
			query_evaluated += sample_evaluated
			evaluated_per_sample.append(float(sample_evaluated))
		if not query_enters_phase_1b:
			fully_rejected_queries += 1
		evaluated_per_query.append(float(query_evaluated))
	var query_count := positions.size()
	var directional_sample_count := query_count * INTERNAL_DIRECTIONAL_SAMPLES_PER_WATER_QUERY
	var row := {
		"workload": workload_name,
		"water_queries": query_count,
		"active_segments": active_count,
		"navigable_segments": navigable_count,
		"directional_sampler_invocations": directional_sample_count,
		"phase_1a_fully_rejected_water_queries": fully_rejected_queries,
		"phase_1a_fully_rejected_water_query_percent": _percent(fully_rejected_queries, query_count),
		"phase_1a_rejected_directional_samples": global_rejected_samples,
		"phase_1a_rejected_directional_sample_percent": _percent(global_rejected_samples, directional_sample_count),
		"phase_1b_entered_directional_samples": entered_samples,
		"phase_1b_entered_directional_sample_percent": _percent(entered_samples, directional_sample_count),
		"phase_1b_conditional_applicable": considered > 0,
		"phase_1b_segments_considered": considered,
		"phase_1b_segments_discarded": discarded,
		"phase_1b_segments_evaluated": evaluated,
		"phase_1b_segment_discard_percent_after_phase_1a": _percent(discarded, considered),
		"average_segments_evaluated_per_directional_sample": (
			float(evaluated) / float(maxi(entered_samples, 1))
		),
		"average_segment_evaluations_per_water_query": (
			float(evaluated) / float(maxi(query_count, 1))
		),
		"evaluated_segments_per_directional_sample": _stats(evaluated_per_sample),
		"segment_evaluations_per_water_query": _stats(evaluated_per_query),
	}
	print(
		"GOLD_CITY_PHASE_1B_CULLING name=%s active=%d phase1a_query_reject=%.2f%% phase1b_discard=%.2f%% avg_eval=%.3f"
		% [
			workload_name,
			active_count,
			float(row["phase_1a_fully_rejected_water_query_percent"]),
			float(row["phase_1b_segment_discard_percent_after_phase_1a"]),
			float(row["average_segments_evaluated_per_directional_sample"]),
		]
	)
	return row


func _directional_source_metadata(
	jet_ski: JetSkiController,
	traffic_actors: Array[BoatTrafficActor]
) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var player_wake := jet_ski.find_child("WakeTrail3D", true, false) as WakeTrail3D
	if player_wake != null:
		result.append(_wake_source_row("player_jetski", player_wake))
	for index in traffic_actors.size():
		var wake := traffic_actors[index].get_node_or_null("WakeRoot/BoatWake") as WakeTrail3D
		if wake != null:
			result.append(_wake_source_row("traffic_boat_%d" % (index + 1), wake))
	return result


func _wake_source_row(label: String, wake: WakeTrail3D) -> Dictionary:
	return {
		"label": label,
		"node_path": str(wake.get_path()),
		"sample_count": wake.sample_count,
		"physics_enabled": wake.physics_enabled,
		"directional_global_physics_enabled": wake.directional_global_physics_enabled,
		"directional_source_active": wake.directional_source_active,
		"legacy_global_deformation_enabled": wake.legacy_global_deformation_enabled,
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


func _measure_workload(ocean: Ocean3D, positions: PackedVector3Array) -> Dictionary:
	var sample := WaterSample3D.new()
	for index in WORKLOAD_WARMUP_QUERIES:
		ocean.sample_water(positions[index % positions.size()], sample)
		_sink += sample.signed_depth
	var repeats := 64 if positions.size() <= 6 else 32
	var timings := PackedFloat64Array()
	for _observation in WORKLOAD_OBSERVATIONS:
		var started := Time.get_ticks_usec()
		for _repeat in repeats:
			for position: Vector3 in positions:
				ocean.sample_water(position, sample)
				_sink += sample.signed_depth
		timings.append(float(Time.get_ticks_usec() - started) / float(repeats))
	return _stats(timings)


func _build_control_positions(positions: PackedVector3Array) -> PackedVector3Array:
	var result := PackedVector3Array()
	for position: Vector3 in positions:
		result.append(position + Vector3(100000.0, 0.0, 100000.0))
	return result


func _snapshot_metadata(ocean: Ocean3D, workloads: Array) -> Dictionary:
	var fingerprint_parts := PackedStringArray()
	var active_count := int(ocean.get("_directional_wake_active_count"))
	var starts := ocean.get("_directional_wake_start_positions") as PackedVector2Array
	var ends := ocean.get("_directional_wake_end_positions") as PackedVector2Array
	for index in active_count:
		fingerprint_parts.append("S%.5f,%.5f" % [starts[index].x, starts[index].y])
		fingerprint_parts.append("E%.5f,%.5f" % [ends[index].x, ends[index].y])
	for workload: Dictionary in workloads:
		fingerprint_parts.append(String(workload["name"]))
		for position: Vector3 in workload["positions"]:
			fingerprint_parts.append("Q%.5f,%.5f,%.5f" % [position.x, position.y, position.z])
	return {
		"fingerprint": str(hash("|".join(fingerprint_parts))),
		"active_directional_segments": active_count,
		"simulation_time": ocean.get_simulation_time(),
		"global_physics_bounds_min": ocean.get("_directional_wake_physics_bounds_min"),
		"global_physics_bounds_max": ocean.get("_directional_wake_physics_bounds_max"),
	}


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


func _percent(numerator: int, denominator: int) -> float:
	return 100.0 * float(numerator) / float(maxi(denominator, 1))


func _outside_bounds(point: Vector2, minimum: Vector2, maximum: Vector2) -> bool:
	return point.x < minimum.x or point.y < minimum.y or point.x > maximum.x or point.y > maximum.y


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
	var path := "%s/ocean_phase_1b_gold_city_%s_%s.json" % [
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
	push_error("Ocean Phase 1B Gold City: %s" % message)
	get_tree().quit(1)
