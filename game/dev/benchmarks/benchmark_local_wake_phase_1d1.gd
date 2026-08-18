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

var _sink: float = 0.0
var _water_level: float = 0.0
var _bench_source: WakeTrail3D
var _bench_position: Vector3 = Vector3.ZERO
var _bench_ocean: Ocean3D
var _bench_positions: PackedVector3Array = PackedVector3Array()
var _bench_cands := {}
var _bench_mirror_n: int = 0
var _bench_qx: float = 0.0
var _bench_qz: float = 0.0
var _bench_mirror_best_index: int = -1
var _bench_mirror_best_ratio: float = 0.0
var _bench_mirror_best_dist: float = INF
var _bench_arith := PackedFloat64Array()


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
		_fail("Phase 1D1 could not resolve Ocean, JetSki, or BoatTraffic.")
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
	var dir_sources := _collect_dir_sources(jet_ski, traffic_actors)

	var profiles := Array()
	for source: WakeTrail3D in sources:
		profiles.append(_build_source_profile(source))
	var source_rows := Array()
	for index in sources.size():
		var profile: Dictionary = profiles[index]
		source_rows.append({
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
			"candidates_skipped_by_age": profile["age_skips"],
			"candidates_skipped_by_break_or_segment_id": profile["break_skips"],
			"candidates_skipped_degenerate": profile["degenerate_skips"],
			"geometric_projection_candidates": profile["projection_candidates"],
		})
		print(
			"GOLD_CITY_PHASE_1D1_SOURCE_REAL src=%d samples=%d first_recent=%d iters=%d proj=%d bounds=%.1fx%.1f"
			% [
				index,
				sources[index].sample_count,
				int(profile["first_recent"]),
				int(profile["loop_iterations"]),
				int(profile["projection_candidates"]),
				float(profile["bounds_width"]),
				float(profile["bounds_height"]),
			]
		)

	var test_positions := Array()
	for index in sources.size():
		var prof: Dictionary = profiles[index]
		var outside := Vector3(
			prof.bounds.position.x - OUTSIDE_MARGIN,
			_water_level,
			prof.bounds.position.y - OUTSIDE_MARGIN
		)
		var far_control := Vector3(
			prof.bounds.position.x - BOUND_FAR_MARGIN,
			_water_level,
			prof.bounds.position.y - BOUND_FAR_MARGIN
		)
		var inside_zero := _find_inside_zero(sources[index], prof)
		var near_segment := _find_near_segment(sources[index], prof)
		var zero_height := sources[index].sample_simplified_wake_height(inside_zero)
		var near_height := sources[index].sample_simplified_wake_height(near_segment)
		_sink += zero_height + near_height
		var outside_height := sources[index].sample_simplified_wake_height(outside)
		_sink += outside_height
		test_positions.append({
			"source": index,
			"outside_world": outside,
			"outside_height": outside_height,
			"far_control_world": far_control,
			"inside_zero_world": inside_zero,
			"inside_zero_height": zero_height,
			"inside_zero_projection_candidates": prof["projection_candidates"],
			"inside_zero_scan_entered": prof["loop_iterations"] > 0,
			"near_segment_world": near_segment,
			"near_segment_height": near_height,
		})
		print(
			"GOLD_CITY_PHASE_1D1_POS src=%d outside_h=%.4f zero_h=%.4f near_h=%.4f"
			% [index, outside_height, zero_height, near_height]
		)

	var near_best_index := 0
	var near_best_abs := -1.0
	for index in test_positions.size():
		var candidate_abs := absf(float(test_positions[index]["near_segment_height"]))
		if candidate_abs > near_best_abs:
			near_best_abs = candidate_abs
			near_best_index = index

	var overlap := _compute_overlap(profiles)
	var near_position := test_positions[near_best_index]["near_segment_world"] as Vector3

	var real_player := Array()
	var aggregate_heights := PackedFloat64Array()
	for position: Vector3 in player_positions:
		var row := {
			"position": position,
			"aggregate_height": 0.0,
		}
		var source_data := Array()
		for index in sources.size():
			var inside := bool(
				(profiles[index]["bounds"] as Rect2).has_point(Vector2(position.x, position.z))
			)
			var height := sources[index].sample_simplified_wake_height(position)
			_sink += height
			source_data.append({
				"source": index,
				"inside_bounds": inside,
				"geometric_projection_candidates": int(profiles[index]["projection_candidates"]),
				"height": height,
			})
		row["sources"] = source_data
		var aggregate := ocean.sample_local_wake_height(position)
		_sink += aggregate
		row["aggregate_height"] = aggregate
		aggregate_heights.append(aggregate)
		real_player.append(row)

	_bench_arith.resize(512)
	for i in _bench_arith.size():
		_bench_arith[i] = 0.000001

	var scenarios := Array()
	scenarios.append(_run_scenario_signal("source", "src_0_out", {
		"source": sources[0], "position": test_positions[0]["outside_world"],
	}, {
		"source": sources[0], "position": test_positions[0]["far_control_world"],
	}))
	scenarios.append(_run_scenario_signal("source", "src_0_zero", {
		"source": sources[0], "position": test_positions[0]["inside_zero_world"],
	}, {
		"source": sources[0], "position": test_positions[0]["far_control_world"],
	}))
	scenarios.append(_run_scenario_signal("source", "src_0_near", {
		"source": sources[0], "position": test_positions[0]["near_segment_world"],
	}, {
		"source": sources[0], "position": test_positions[0]["far_control_world"],
	}))
	scenarios.append(_run_scenario_signal("source", "src_1_out", {
		"source": sources[1], "position": test_positions[1]["outside_world"],
	}, {
		"source": sources[1], "position": test_positions[1]["far_control_world"],
	}))
	scenarios.append(_run_scenario_signal("source", "src_1_zero", {
		"source": sources[1], "position": test_positions[1]["inside_zero_world"],
	}, {
		"source": sources[1], "position": test_positions[1]["far_control_world"],
	}))
	scenarios.append(_run_scenario_signal("source", "src_1_near", {
		"source": sources[1], "position": test_positions[1]["near_segment_world"],
	}, {
		"source": sources[1], "position": test_positions[1]["far_control_world"],
	}))
	scenarios.append(_run_scenario_signal("source", "src_2_out", {
		"source": sources[2], "position": test_positions[2]["outside_world"],
	}, {
		"source": sources[2], "position": test_positions[2]["far_control_world"],
	}))
	scenarios.append(_run_scenario_signal("source", "src_2_zero", {
		"source": sources[2], "position": test_positions[2]["inside_zero_world"],
	}, {
		"source": sources[2], "position": test_positions[2]["far_control_world"],
	}))
	scenarios.append(_run_scenario_signal("source", "src_2_near", {
		"source": sources[2], "position": test_positions[2]["near_segment_world"],
	}, {
		"source": sources[2], "position": test_positions[2]["far_control_world"],
	}))

	scenarios.append(_run_scenario_signal("aggregate", "aggregate_out", {
		"ocean": ocean, "position": test_positions[0]["far_control_world"],
	}, {
		"ocean": ocean, "position": test_positions[0]["far_control_world"],
	}))
	var overlap_position: Vector3 = Vector3.ZERO
	if not overlap["rects"].is_empty():
		overlap_position = (overlap["rects"][0] as Dictionary)["world_position"] as Vector3
		scenarios.append(_run_scenario_signal("aggregate", "aggregate_near_overlap", {
			"ocean": ocean, "position": overlap_position,
		}, {
			"ocean": ocean, "position": test_positions[0]["far_control_world"],
		}))
	else:
		scenarios.append(_run_scenario_signal("aggregate", "aggregate_near", {
			"ocean": ocean, "position": near_position,
		}, {
			"ocean": ocean, "position": test_positions[0]["far_control_world"],
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
			"GOLD_CITY_PHASE_1D1_TIMING name=%s per_query_us=%.3f drift=%.4f status=%s pairs=%d"
			% [
				name,
				float(scenario["authoritative_us_per_query"]),
				float(scenario["drift"]),
				String(scenario["status"]),
				int(scenario["valid_pairs"]),
			]
		)

	var scaling := _run_scaling(profiles, test_positions)
	var aggregate_rows := _scenario_map(scenarios)
	var aggregate_out_us := float(aggregate_rows["aggregate_out"]["authoritative_us_per_query"])
	var aggregate_near_us := 0.0
	if aggregate_rows.has("aggregate_near_overlap"):
		aggregate_near_us = float(aggregate_rows["aggregate_near_overlap"]["authoritative_us_per_query"])
	else:
		aggregate_near_us = float(aggregate_rows["aggregate_near"]["authoritative_us_per_query"])
	var aggregate_player_us := float(aggregate_rows["aggregate_player_6"]["authoritative_us_per_query"])
	print(
		"GOLD_CITY_PHASE_1D1_AGGEGATE out=%.3f near=%.3f ratio=%.3f player=%.3f"
		% [
			aggregate_out_us,
			aggregate_near_us,
			aggregate_near_us / aggregate_out_us if aggregate_out_us > 0.0 else -1.0,
			aggregate_player_us,
		]
	)
	print("GOLD_CITY_PHASE_1D1_OVERLAP STATUS=%s" % String(overlap["status"]))

	var dominant := _compute_dominant(scenarios)
	print(
		"GOLD_CITY_PHASE_1D1_DOMINANT src1=%s src2=%s src3=%s"
		% [dominant["0"], dominant["1"], dominant["2"]]
	)

	var report := {
		"schema": "ocean_phase_1d1_local_wake_v1",
		"label": _argument_value("--label=", "unlabelled"),
		"commit": _argument_value("--commit=", "unknown"),
		"diagnostic_only": true,
		"methodology": {
			"note": "Phase 1D1 local traffic wake nearest-segment profiler. No runtime, no Ocean3D, no WakeTrail3D, no shaders, no scenes modified. Mirror replicates only the while-loop iteration logic of sample_simplified_wake_height.",
			"scene": GOLD_CITY_SCENE,
			"physics_hz": Engine.physics_ticks_per_second,
			"traffic_warmup_physics_frames": TRAFFIC_WARMUP_PHYSICS_FRAMES,
			"observations_per_series": OBSERVATIONS,
			"target_observation_us": TARGET_OBSERVATION_US,
			"maximum_local_drift": MAXIMUM_LOCAL_DRIFT,
			"max_attempts": MAX_ATTEMPTS,
			"required_valid_pairs": REQUIRED_VALID_PAIRS,
			"control_rule": "ABBA: control BEFORE (9 obs), workload x2 (9 obs each), control AFTER (9 obs); drift measured between the two controls.",
			"measured_function": "WakeTrail3D.sample_simplified_wake_height(world_position) and Ocean3D.sample_local_wake_height(world_position)",
			"not_measured": ["sample_normal", "sample_water", "sample_height"],
			"block_duration_ms": "Each observation is calibrated to ~25 ms before timing; calibration is not part of the final timing.",
		},
		"snapshot": _snapshot_metadata(ocean),
		"sources": source_rows,
		"directional_sources": dir_sources,
		"test_positions": test_positions,
		"real_player": real_player,
		"real_player_aggregate_heights": aggregate_heights,
		"overlap": overlap,
		"scenarios": scenarios,
		"scaling": scaling,
		"dominant": dominant,
		"aggregate_summary": {
			"out_us_per_query": aggregate_out_us,
			"near_us_per_query": aggregate_near_us,
			"near_over_out_ratio": aggregate_near_us / aggregate_out_us if aggregate_out_us > 0.0 else -1.0,
			"player_6_us_per_query": aggregate_player_us,
		},
	}
	var report_path := _write_report(report)
	print("GOLD_CITY_PHASE_1D1_SNAPSHOT=%s" % String(report["snapshot"]["fingerprint"]))
	print("GOLD_CITY_PHASE_1D1_JSON=%s" % report_path)
	print("GOLD_CITY_PHASE_1D1=PASS")
	get_tree().quit(0)


func _collect_traffic_actors(node: Node, result: Array[BoatTrafficActor]) -> void:
	if node is BoatTrafficActor:
		result.append(node as BoatTrafficActor)
	for child: Node in node.get_children():
		_collect_traffic_actors(child, result)


func _collect_dir_sources(
	jet_ski: JetSkiController,
	traffic_actors: Array[BoatTrafficActor]
) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var player_wake := jet_ski.find_child("WakeTrail3D", true, false) as WakeTrail3D
	if player_wake != null:
		result.append({
			"label": "player_jetski",
			"node_path": str(player_wake.get_path()),
			"sample_count": player_wake.sample_count,
			"local_wake_physics_active": player_wake.is_local_wake_physics_active(),
		})
	for index in traffic_actors.size():
		var wake := traffic_actors[index].get_node_or_null("WakeRoot/BoatWake") as WakeTrail3D
		if wake != null:
			result.append({
				"label": "traffic_boat_%d" % (index + 1),
				"node_path": str(wake.get_path()),
				"sample_count": wake.sample_count,
				"local_wake_physics_active": wake.is_local_wake_physics_active(),
			})
	return result


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
	var age_skips := 0
	var break_skips := 0
	var degenerate_skips := 0
	var projection_candidates := 0
	var sx := PackedFloat32Array()
	var sz := PackedFloat32Array()
	var dx := PackedFloat32Array()
	var dz := PackedFloat32Array()
	var len_sq := PackedFloat32Array()
	var index := first_recent
	while index < size - 1:
		loop_iterations += 1
		var newer_index := mini(index + stride, size - 1)
		var older: Variant = samples[index]
		var newer: Variant = samples[newer_index]
		if older.age > lifetime and newer.age > lifetime:
			age_skips += 1
		elif newer.break_before or newer.segment_id != older.segment_id:
			break_skips += 1
		else:
			var seg_x := float(newer.position.x) - float(older.position.x)
			var seg_z := float(newer.position.z) - float(older.position.z)
			var segment_length_squared := seg_x * seg_x + seg_z * seg_z
			if segment_length_squared <= 0.0001:
				degenerate_skips += 1
			else:
				sx.append(float(older.position.x))
				sz.append(float(older.position.z))
				dx.append(seg_x)
				dz.append(seg_z)
				len_sq.append(segment_length_squared)
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
		"age_skips": age_skips,
		"break_skips": break_skips,
		"degenerate_skips": degenerate_skips,
		"projection_candidates": projection_candidates,
		"candidates_sx": sx,
		"candidates_sz": sz,
		"candidates_dx": dx,
		"candidates_dz": dz,
		"candidates_len_sq": len_sq,
	}


func _mirror_best(candidate_count: int) -> void:
	var sx := _bench_cands["candidates_sx"] as PackedFloat32Array
	var sz := _bench_cands["candidates_sz"] as PackedFloat32Array
	var dx := _bench_cands["candidates_dx"] as PackedFloat32Array
	var dz := _bench_cands["candidates_dz"] as PackedFloat32Array
	var len_sq := _bench_cands["candidates_len_sq"] as PackedFloat32Array
	var limit := mini(candidate_count, sx.size())
	var best_dist := INF
	var best_ratio := 0.0
	var best_index := -1
	var qx := _bench_qx
	var qz := _bench_qz
	for i in limit:
		var ratio := clampf(
			((qx - sx[i]) * dx[i] + (qz - sz[i]) * dz[i]) / len_sq[i],
			0.0,
			1.0
		)
		var proj_x := sx[i] + ratio * dx[i]
		var proj_z := sz[i] + ratio * dz[i]
		var distance_squared := (qx - proj_x) * (qx - proj_x) + (qz - proj_z) * (qz - proj_z)
		if distance_squared < best_dist:
			best_dist = distance_squared
			best_ratio = ratio
			best_index = i
	_bench_mirror_best_index = best_index
	_bench_mirror_best_ratio = best_ratio
	_bench_mirror_best_dist = best_dist


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
	var fineness := 48
	var fine_step_x := maxf(bounds.size.x / float(fineness), 0.001)
	var fine_step_z := maxf(bounds.size.y / float(fineness), 0.001)
	for gy in fineness:
		for gx in fineness:
			var position := Vector3(
				bounds.position.x + (float(gx) + 0.5) * fine_step_x,
				_water_level,
				bounds.position.y + (float(gy) + 0.5) * fine_step_z
			)
			var height := source.sample_simplified_wake_height(position)
			if height == 0.0 and int(profile["loop_iterations"]) > 0:
				return position
	return Vector3(bounds.position.x + bounds.size.x * 0.5, _water_level, bounds.position.y + bounds.size.y * 0.5)


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
					"min_x": intersection.position.x,
					"min_y": intersection.position.y,
					"max_x": intersection.position.x + intersection.size.x,
					"max_y": intersection.position.y + intersection.size.y,
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
		"source":
			for _iteration in count:
				_sink += _bench_source.sample_simplified_wake_height(_bench_position)
		"aggregate":
			for _iteration in count:
				_sink += _bench_ocean.sample_local_wake_height(_bench_position)
		"aggregate_pass":
			for _iteration in count:
				for position: Vector3 in _bench_positions:
					_sink += _bench_ocean.sample_local_wake_height(position)
		"mirror":
			for _iteration in count:
				_mirror_best(_bench_mirror_n)
				_sink += _bench_mirror_best_dist
		"arith":
			for _iteration in count:
				var acc := 0.0
				for value: float in _bench_arith:
					acc += value
				_sink += acc
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


func _compute_dominant(scenarios: Array) -> Dictionary:
	var by_source := {"0": {}, "1": {}, "2": {}}
	for scenario: Dictionary in scenarios:
		var name := String(scenario["name"])
		if not name.begins_with("src_"):
			continue
		var parts := name.split("_")
		var source_key := parts[1]
		var part := parts[2]
		var container := by_source[source_key] as Dictionary
		container[part] = {
			"us_per_query": scenario["authoritative_us_per_query"],
			"valid": String(scenario["status"]) == "VALID",
		}
	var result := {}
	for source_key: String in ["0", "1", "2"]:
		var container := by_source[source_key] as Dictionary
		var out_row: Dictionary = container.get("out", {})
		var zero_row: Dictionary = container.get("zero", {})
		var near_row: Dictionary = container.get("near", {})
		var valid := bool(out_row.get("valid", false)) and bool(zero_row.get("valid", false)) and bool(near_row.get("valid", false))
		if not valid:
			result[source_key] = "INVALID"
			continue
		var bound_us := float(out_row["us_per_query"])
		var scan_us := maxf(float(zero_row["us_per_query"]) - bound_us, 0.0)
		var profile_us := maxf(float(near_row["us_per_query"]) - float(zero_row["us_per_query"]), 0.0)
		var labels := ["BOUND", "NEAREST_SCAN", "PROFILE"]
		var values := [bound_us, scan_us, profile_us]
		var best_value := 0.0
		var best_label := "BOUND"
		for i in 3:
			if float(values[i]) > best_value:
				best_value = float(values[i])
				best_label = labels[i]
		result[source_key] = {
			"dominant": best_label,
			"bound_us_per_query": bound_us,
			"scan_us_per_query": scan_us,
			"profile_us_per_query": profile_us,
		}
	return result


func _run_scaling(profiles: Array, test_positions: Array) -> Dictionary:
	var profile: Dictionary = profiles[0]
	var total_candidates := int(profile["projection_candidates"])
	_bench_cands = profile
	var query_entry := test_positions[0]["near_segment_world"] as Vector3
	_bench_qx = query_entry.x
	_bench_qz = query_entry.z
	var sets := [4, 8, 16, total_candidates]
	var repeats_for_set := {}
	for value: int in sets:
		_bench_mirror_n = value
		repeats_for_set[value] = _calibrate("mirror", TARGET_OBSERVATION_US)
	_bench_arith.resize(1024)
	for i in _bench_arith.size():
		_bench_arith[i] = 0.000001
	var control_repeats := _calibrate("arith", TARGET_OBSERVATION_US)
	var a1 := float(_measure_series("arith", control_repeats)["median"])
	var buckets: Array[PackedFloat64Array] = []
	for _index in sets.size():
		buckets.append(PackedFloat64Array())
	for _observation in OBSERVATIONS:
		for set_index in sets.size():
			var value: int = sets[set_index]
			_bench_mirror_n = value
			var elapsed := _time_branch("mirror", int(repeats_for_set[value]))
			var per_call := elapsed / float(repeats_for_set[value])
			buckets[set_index].append(per_call)
	var a2 := float(_measure_series("arith", control_repeats)["median"])
	var reference := (a1 + a2) * 0.5
	var drift := absf(a2 - a1) / reference if reference > 0.0 else INF
	var rows := Array()
	for set_index in sets.size():
		var median := _median(buckets[set_index])
		rows.append({
			"set": sets[set_index],
			"candidates": sets[set_index],
			"us_per_call": median,
			"us_per_candidate": median / float(maxi(sets[set_index], 1)),
		})
	var us4 := float(rows[0]["us_per_call"])
	var us_full := float(rows[3]["us_per_call"])
	var full_candidates := total_candidates
	var linear_ratio := (
		(us_full / float(full_candidates)) / (us4 / 4.0)
		if us4 > 0.0 else -1.0
	)
	_mirror_best(total_candidates)
	_bench_qx = query_entry.x
	_bench_qz = query_entry.z
	var full_index := _bench_mirror_best_index
	var full_ratio := _bench_mirror_best_ratio
	var full_dist := _bench_mirror_best_dist
	var reconstructed := _reconstruct_nearest(profile, query_entry.x, query_entry.z)
	var full_matches := (
		full_index == int(reconstructed["best_index"])
		and absf(full_ratio - float(reconstructed["best_ratio"])) < 0.00001
		and absf(full_dist - float(reconstructed["best_dist_sq"])) < 0.00001
	)
	print(
		"GOLD_CITY_PHASE_1D1_SCALING n4=%.3f n8=%.3f n16=%.3f nfull=%.3f linear=%.3f match=%s"
		% [
			float(rows[0]["us_per_call"]),
			float(rows[1]["us_per_call"]),
			float(rows[2]["us_per_call"]),
			float(rows[3]["us_per_call"]),
			linear_ratio,
			str(full_matches),
		]
	)
	return {
		"source_used": 0,
		"total_candidates": total_candidates,
		"query": query_entry,
		"observations": OBSERVATIONS,
		"rows": rows,
		"linear_ratio_us_per_candidate_16_vs_4": linear_ratio,
		"full_matches_reconstructed": full_matches,
		"full_nearest": {"index": full_index, "ratio": full_ratio, "distance_squared": full_dist},
		"reconstructed_nearest": reconstructed,
		"control": {
			"a1_us_per_iter": a1,
			"a2_us_per_iter": a2,
			"drift": drift,
			"valid": drift <= MAXIMUM_LOCAL_DRIFT,
		},
	}


func _reconstruct_nearest(profile: Dictionary, qx: float, qz: float) -> Dictionary:
	var sx := profile["candidates_sx"] as PackedFloat32Array
	var sz := profile["candidates_sz"] as PackedFloat32Array
	var dx := profile["candidates_dx"] as PackedFloat32Array
	var dz := profile["candidates_dz"] as PackedFloat32Array
	var len_sq := profile["candidates_len_sq"] as PackedFloat32Array
	var best_dist := INF
	var best_ratio := 0.0
	var best_index := -1
	for i in sx.size():
		var ratio := clampf(
			((qx - sx[i]) * dx[i] + (qz - sz[i]) * dz[i]) / len_sq[i],
			0.0,
			1.0
		)
		var proj_x := sx[i] + ratio * dx[i]
		var proj_z := sz[i] + ratio * dz[i]
		var distance_squared := (qx - proj_x) * (qx - proj_x) + (qz - proj_z) * (qz - proj_z)
		if distance_squared < best_dist:
			best_dist = distance_squared
			best_ratio = ratio
			best_index = i
	return {"best_index": best_index, "best_ratio": best_ratio, "best_dist_sq": best_dist}


func _snapshot_metadata(ocean: Ocean3D) -> Dictionary:
	return {
		"fingerprint": str(hash("%.6f" % ocean.get_simulation_time())),
		"simulation_time": ocean.get_simulation_time(),
		"water_level": ocean.water_level,
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
	var path := "%s/ocean_phase_1d1_profile_%s_%s.json" % [
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
	push_error("Ocean Phase 1D1 Local Wake Profile: %s" % message)
	get_tree().quit(1)