extends Node

const GOLD_CITY_SCENE := "res://levels/gold_city/gold_city.tscn"
const OUTPUT_DIRECTORY := "res://.godot/ocean_benchmarks"
const TRAFFIC_WARMUP_PHYSICS_FRAMES := 300
const OBSERVATIONS := 9
const TARGET_BLOCK_US := 25000.0
const MAXIMUM_LOCAL_DRIFT := 0.25
const MAX_ATTEMPTS := 4
const REQUIRED_VALID_ATTEMPTS := 2
const CONTROL_OFFSET := Vector3(100000.0, 0.0, 100000.0)
const COMPONENTS := [
	"sample_water",
	"sample_height",
	"sample_normal",
	"sample_water_velocity",
	"sample_local_wake_height",
	"ambient_surface_offset",
	"event_wave_horizontal_flow",
]
const HISTORIC_1D := {
	"live_player_6": {
		"sample_water": 144.5,
		"sample_height": 21.6,
		"sample_normal": 97.6,
		"sample_water_velocity": 22.8,
		"sample_local_wake_height": 11.5,
	},
	"traffic_corridor_6": {
		"sample_water": 582.2,
		"sample_height": 86.6,
		"sample_normal": 523.8,
		"sample_water_velocity": 28.1,
		"sample_local_wake_height": 67.7,
	},
}

var _sink: float = 0.0
var _bench_ocean: Ocean3D
var _bench_positions := PackedVector3Array()
var _bench_logical := PackedVector2Array()
var _bench_sim_time: float = 0.0
var _bench_sample := WaterSample3D.new()


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
		_fail("Phase 1E1 could not resolve Ocean, JetSki, or BoatTraffic.")
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
	for _frame in TRAFFIC_WARMUP_PHYSICS_FRAMES:
		await get_tree().physics_frame

	ocean.call(&"_update_directional_wake_segments")
	var active_count := int(ocean.get("_directional_wake_active_count"))
	if active_count <= 0:
		_fail("Gold City produced no active directional-wake segments.")
		return
	var live_query_rows := _build_live_query_rows(jet_ski)
	var live_full := _live_positions(live_query_rows)
	if live_full.size() != 6:
		_fail("JetSki did not expose its six live query positions.")
		return
	var corridor_build := _build_traffic_corridor_queries(ocean, jet_ski)
	var corridor_24 := corridor_build.get("full", PackedVector3Array()) as PackedVector3Array
	if corridor_24.size() != 24:
		_fail("Could not build the 4-JetSki (24-query) corridor workload.")
		return
	var corridor_6 := corridor_24.slice(0, 6)

	city.process_mode = Node.PROCESS_MODE_DISABLED

	var sources := _read_sources(ocean)
	_warm_cache_paths(sources)
	var sources_rows := _local_wake_source_rows(sources)
	var overlap_points := _overlap_points(sources, ocean.water_level)
	var triple_points := _triple_points(sources, ocean.water_level)

	var workloads := Array()
	workloads.append(_make_workload("live_player_6", live_full, "One real Gold City JetSki physics tick (4 buoyancy + body center + propulsion)"))
	workloads.append(_make_workload("jet_ski_24", corridor_24, "24 queries = four replicated JetSki ticks (4 poses x 6 points) placed on real traffic segments"))
	workloads.append(_make_workload("traffic_corridor_6", corridor_6, "One complete JetSki tick positioned on a real traffic-wake segment"))
	if not (overlap_points as PackedVector3Array).is_empty():
		workloads.append(_make_workload("traffic_overlap_6", overlap_points, "Six points inside the real overlap region of two traffic wakes"))
	else:
		workloads.append(_make_workload("traffic_overlap_6", PackedVector3Array(), "NO_OVERLAP (no pair of traffic wake bounds intersect)"))
	if not (triple_points as PackedVector3Array).is_empty():
		workloads.append(_make_workload("traffic_triple_6", triple_points, "Six points inside the triple-overlap region of all three traffic wakes"))
	else:
		workloads.append(_make_workload("traffic_triple_6", PackedVector3Array(), "NO_TRIPLE_OVERLAP"))
	var far_6 := PackedVector3Array()
	for position: Vector3 in live_full:
		far_6.append(position + CONTROL_OFFSET)
	workloads.append(_make_workload("far_6", far_6, "Six points far outside every traffic wake (player layout + CONTROL_OFFSET)"))

	var workload_rows := Array()
	for workload: Dictionary in workloads:
		var row := _measure_workload(ocean, workload)
		workload_rows.append(row)
		await get_tree().process_frame

	for row: Dictionary in workload_rows:
		var name := String(row["name"])
		var reconstruction: Dictionary = row["reconstruction"]
		print(
			"GOLD_CITY_PHASE_1E1_RECON name=%s queries=%d sample_water_us=%.3f analytic=%.3f ratio=%.4f local_pct=%.1f ambient_pct=%.1f flow_pct=%.1f"
			% [
				name,
				int(row["queries"]),
				float(reconstruction["sample_water_us_per_query"]),
				float(reconstruction["analytic_reconstruction_us_per_query"]),
				float(reconstruction["analytic_over_full_ratio"]),
				float(reconstruction["local_wake_share_percent"]),
				float(reconstruction["ambient_share_percent"]),
				float(reconstruction["horizontal_flow_share_percent"]),
			]
		)
		for component: String in COMPONENTS:
			var comp: Dictionary = row["components"][component]
			print(
				"GOLD_CITY_PHASE_1E1_COMP name=%s component=%s us_per_query=%.3f drift=%.4f status=%s valid_attempts=%d"
				% [
					name,
					component,
					float(comp["us_per_query"]),
					float(comp["drift"]),
					String(comp["status"]),
					int(comp["valid_attempts"]),
				]
			)

	var corridor_row: Dictionary = workload_rows[1]
	var corridor_water := float(corridor_row["reconstruction"]["sample_water_us_per_query"])
	var bottleneck := _bottleneck_analysis(workload_rows)
	var reduction := _run_1e_reduction(ocean, corridor_6)
	var cold := _run_cold_diagnostic(sources)

	print("GOLD_CITY_PHASE_1E1_BOTTLENECK=%s" % JSON.stringify(bottleneck))
	print("GOLD_CITY_PHASE_1E1_1E_REDUCTION=%s" % JSON.stringify(reduction))
	print("GOLD_CITY_PHASE_1E1_COLD=%s" % JSON.stringify(cold))
	print("GOLD_CITY_PHASE_1E1_SOURCES=%s" % JSON.stringify(sources_rows))
	print("GOLD_CITY_PHASE_1E1_OVERLAP_STATUS=%s" % ("OVERLAP" if not (overlap_points as PackedVector3Array).is_empty() else "NO_OVERLAP"))
	print("GOLD_CITY_PHASE_1E1_TRIPLE_STATUS=%s" % ("TRIPLE" if not (triple_points as PackedVector3Array).is_empty() else "NO_TRIPLE"))

	var report := {
		"schema": "ocean_phase_1e1_post_v1",
		"label": _argument_value("--label=", "unlabelled"),
		"commit": _argument_value("--commit=", "unknown"),
		"diagnostic_only": true,
		"runtime_files_modified": 0,
		"methodology": {
			"note": "Phase 1E.1 post-optimization diagnostic (Phase 1C + Phase 1E). No runtime file modified. ABBA = control BEFORE (9 obs) + workload x2 (9 obs each) + control AFTER (9 obs). One VALID ABBA attempt requires |a2-a1|/mean <= 0.25.",
			"scene": GOLD_CITY_SCENE,
			"physics_hz": Engine.physics_ticks_per_second,
			"traffic_warmup_physics_frames": TRAFFIC_WARMUP_PHYSICS_FRAMES,
			"traffic_actor_count": traffic_actors.size(),
			"observations_per_block": OBSERVATIONS,
			"target_block_us": TARGET_BLOCK_US,
			"maximum_local_drift": MAXIMUM_LOCAL_DRIFT,
			"max_attempts": MAX_ATTEMPTS,
			"required_valid_attempts": REQUIRED_VALID_ATTEMPTS,
			"control_offset": CONTROL_OFFSET,
			"sampled_components": COMPONENTS,
			"internal_diagnostic_paths": [
				"_sample_surface_offset_without_local_wake",
				"_sample_event_wave_horizontal_flow",
			],
			"component_counts_per_sample_water": {
				"sample_height": "1 x (ambient + local_wake)",
				"sample_normal": "4 x (ambient + local_wake)",
				"sample_water_velocity": "2 x ambient + 1 x horizontal_flow",
				"analytic_total": "7 x ambient + 5 x local_wake + 1 x horizontal_flow",
			},
			"historic_1d_context": HISTORIC_1D,
			"historic_drift_disclaimer": "Phase 1D values had drift > 25% in places; they are context only, not authoritative.",
			"hot_path": "Main timings do not trigger cache invalidations; workload repeats reuse the Phase 1E candidate cache (warm path).",
			"cooldown_diagnostic_only": "COLD measurements invalidate cache deliberately and are reported separately.",
		},
		"snapshot": _snapshot_metadata(ocean, workloads),
		"live_player_query_rows": live_query_rows,
		"live_player_positions": live_full,
		"local_wake_sources": sources_rows,
		"workloads": workload_rows,
		"bottleneck": bottleneck,
		"phase_1e_reduction_diagnostic": reduction,
		"cold_diagnostic": cold,
	}
	var report_path := _write_report(report)
	print("GOLD_CITY_PHASE_1E1_SNAPSHOT=%s" % String(report["snapshot"]["fingerprint"]))
	print("GOLD_CITY_PHASE_1E1_JSON=%s" % report_path)
	print("GOLD_CITY_PHASE_1E1=PASS")
	get_tree().quit(0)


func _make_workload(name: String, positions: PackedVector3Array, description: String) -> Dictionary:
	return {
		"name": name,
		"positions": positions,
		"description": description,
	}


func _collect_traffic_actors(node: Node, result: Array[BoatTrafficActor]) -> void:
	if node is BoatTrafficActor:
		result.append(node as BoatTrafficActor)
	for child: Node in node.get_children():
		_collect_traffic_actors(child, result)


func _build_live_query_rows(jet_ski: JetSkiController) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for position: Vector3 in jet_ski.water_physics_system.point_world_positions:
		result.append({"label": "buoyancy", "position": position})
	result.append({"label": "body_center", "position": jet_ski.global_position})
	result.append({"label": "propulsion", "position": jet_ski.drive_system.state.propulsion_world_position})
	return result


func _live_positions(rows: Array[Dictionary]) -> PackedVector3Array:
	var result := PackedVector3Array()
	for row: Dictionary in rows:
		result.append(row["position"] as Vector3)
	return result


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
	var inverse_live_transform := jet_ski.global_transform.affine_inverse()
	var local_buoyancy := PackedVector3Array()
	for live_position: Vector3 in jet_ski.water_physics_system.point_world_positions:
		local_buoyancy.append(inverse_live_transform * live_position)
	var propulsion_local := (
		inverse_live_transform * jet_ski.drive_system.state.propulsion_world_position
	)
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
			full.append(pose * local_point)
		full.append(pose.origin)
		full.append(pose * propulsion_local)
	return {"full": full}


func _read_sources(ocean: Ocean3D) -> Array[WakeTrail3D]:
	var raw := ocean.get("_local_wake_physics_sources") as Array
	var result: Array[WakeTrail3D] = []
	for value: Variant in raw:
		var wake := value as WakeTrail3D
		if is_instance_valid(wake):
			result.append(wake)
	return result


func _local_wake_source_rows(sources: Array) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for index in sources.size():
		var wake := sources[index] as WakeTrail3D
		var bounds := wake.get("_physics_bounds") as Rect2
		var cache_candidates := 0
		var cache_valid := false
		var cache_built := false
		var cache_dirty := false
		if wake.is_local_wake_physics_active():
			cache_candidates = int((wake.get("_local_wake_candidate_start") as PackedVector2Array).size())
			cache_built = bool(wake.get("_local_wake_cache_built"))
			cache_dirty = bool(wake.get("_local_wake_cache_dirty"))
			cache_valid = bool(wake.call(&"_local_wake_candidate_cache_valid"))
		var stride := wake.local_physics_segment_stride
		var scanned_segments := 0.0
		if stride >= 1 and wake.sample_count >= 2:
			var first_recent := int(wake.get("_physics_first_recent_sample_index"))
			scanned_segments = (
				floorf(float(maxi(wake.sample_count - 1 - first_recent, 0)) / float(stride)) + 1.0
			)
		result.append({
			"index": index,
			"node_path": str(wake.get_path()),
			"local_wake_physics_active": wake.is_local_wake_physics_active(),
			"sample_count": wake.sample_count,
			"local_physics_segment_stride": stride,
			"local_physics_lifetime": wake.local_physics_lifetime,
			"wake_lifetime": wake.wake_lifetime,
			"physics_bounds_min_x": bounds.position.x,
			"physics_bounds_min_y": bounds.position.y,
			"physics_bounds_width": bounds.size.x,
			"physics_bounds_height": bounds.size.y,
			"physics_bounds_valid": bounds.size.x > 0.001 and bounds.size.y > 0.001,
			"estimated_scanned_segments_per_query": scanned_segments,
			"phase_1e_candidate_cache_count": cache_candidates,
			"phase_1e_cache_built": cache_built,
			"phase_1e_cache_dirty": cache_dirty,
			"phase_1e_cache_valid": cache_valid,
		})
	return result


func _warm_cache_paths(sources: Array) -> void:
	for source: Variant in sources:
		var wake := source as WakeTrail3D
		if not is_instance_valid(wake) or not wake.is_local_wake_physics_active():
			continue
		var bounds := wake.get("_physics_bounds") as Rect2
		if bounds.size.x <= 0.001 or bounds.size.y <= 0.001:
			continue
		var probe := Vector3(
			bounds.position.x + bounds.size.x * 0.5,
			wake.global_position.y,
			bounds.position.y + bounds.size.y * 0.5
		)
		wake.sample_simplified_wake_height(probe)
		_sink += wake.sample_simplified_wake_height(probe)


func _overlap_points(sources: Array, water_level: float) -> PackedVector3Array:
	var result := PackedVector3Array()
	for first in sources.size():
		for second in range(first + 1, sources.size()):
			var rect_a := (sources[first] as WakeTrail3D).get("_physics_bounds") as Rect2
			var rect_b := (sources[second] as WakeTrail3D).get("_physics_bounds") as Rect2
			var intersection := rect_a.intersection(rect_b)
			if intersection.size.x <= 0.001 or intersection.size.y <= 0.001:
				continue
			for gy in 3:
				for gx in 2:
					result.append(Vector3(
						intersection.position.x + intersection.size.x * (float(gx) + 0.5) * 0.5,
						water_level,
						intersection.position.y + intersection.size.y * (float(gy) + 0.5) / 3.0
					))
	return result


func _triple_points(sources: Array, water_level: float) -> PackedVector3Array:
	var result := PackedVector3Array()
	var minimum := Vector2(INF, INF)
	var maximum := Vector2(-INF, -INF)
	for source: Variant in sources:
		var bounds := (source as WakeTrail3D).get("_physics_bounds") as Rect2
		minimum = minimum.min(bounds.position)
		maximum = maximum.max(bounds.end)
	var quanta := 24
	var step_x := maxf((maximum.x - minimum.x) / float(quanta), 0.001)
	var step_z := maxf((maximum.y - minimum.y) / float(quanta), 0.001)
	for gy in quanta:
		for gx in quanta:
			var position := Vector3(
				minimum.x + (float(gx) + 0.5) * step_x,
				water_level,
				minimum.y + (float(gy) + 0.5) * step_z
			)
			var contained := 0
			for source: Variant in sources:
				if ((source as WakeTrail3D).get("_physics_bounds") as Rect2).has_point(
					Vector2(position.x, position.z)
				):
					contained += 1
			if contained == 3 and result.size() < 6:
				result.append(position)
	return result


func _measure_workload(ocean: Ocean3D, workload: Dictionary) -> Dictionary:
	var positions := workload["positions"] as PackedVector3Array
	var query_count := positions.size()
	if query_count == 0:
		return {
			"name": workload["name"],
			"description": workload["description"],
			"queries": 0,
			"skipped": true,
			"components": {},
			"reconstruction": _reconstruct({}, 0),
		}
	var control_positions := _build_control_positions(positions)
	var components := {}
	for component: String in COMPONENTS:
		components[component] = _run_abba_component(
			ocean,
			component,
			positions,
			control_positions
		)
	return {
		"name": workload["name"],
		"description": workload["description"],
		"queries": query_count,
		"skipped": false,
		"components": components,
		"reconstruction": _reconstruct(components, query_count),
	}


func _run_abba_component(
	ocean: Ocean3D,
	component: String,
	positions: PackedVector3Array,
	control_positions: PackedVector3Array
) -> Dictionary:
	var query_count := maxi(positions.size(), 1)
	_prepare_bench(ocean, positions)
	var workload_repeats := _calibrate(component, query_count)
	_prepare_bench(ocean, control_positions)
	var control_repeats := _calibrate(component, maxi(control_positions.size(), 1))
	var valid_medians := PackedFloat64Array()
	var attempt_rows := Array()
	var last_a1 := -1.0
	var last_a2 := -1.0
	var last_b1 := -1.0
	var last_b2 := -1.0
	var last_drift := INF
	for attempt in MAX_ATTEMPTS:
		_prepare_bench(ocean, control_positions)
		var a1 := _measure_block(component, control_repeats)
		_prepare_bench(ocean, positions)
		var b1 := _measure_block(component, workload_repeats)
		var b2 := _measure_block(component, workload_repeats)
		_prepare_bench(ocean, control_positions)
		var a2 := _measure_block(component, control_repeats)
		var reference := (a1 + a2) * 0.5
		var drift := absf(a2 - a1) / reference if reference > 0.0 else INF
		attempt_rows.append({
			"attempt": attempt,
			"a1_us_per_series": a1,
			"b1_us_per_series": b1,
			"b2_us_per_series": b2,
			"a2_us_per_series": a2,
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
		if valid_medians.size() >= REQUIRED_VALID_ATTEMPTS * 2:
			break
	var status := "VALID" if valid_medians.size() >= REQUIRED_VALID_ATTEMPTS * 2 else "INVALID"
	var authoritative := _median(valid_medians) if status == "VALID" else -1.0
	return {
		"us_per_query": authoritative / float(query_count) if status == "VALID" else -1.0,
		"us_per_series": authoritative,
		"control_before_us_per_series": last_a1,
		"control_after_us_per_series": last_a2,
		"drift": last_drift,
		"status": status,
		"valid_attempts": int(valid_medians.size() / 2),
		"attempts_used": attempt_rows.size(),
		"attempt_rows": attempt_rows,
	}


func _prepare_bench(ocean: Ocean3D, positions: PackedVector3Array) -> void:
	var logical := PackedVector2Array()
	logical.resize(positions.size())
	for index in positions.size():
		logical[index] = ocean.world_to_logical_xz(positions[index])
	_bench_ocean = ocean
	_bench_positions = positions
	_bench_logical = logical
	_bench_sim_time = ocean.get_simulation_time()
	_bench_sample = WaterSample3D.new()


func _measure_block(component: String, repeats: int) -> float:
	var timings := PackedFloat64Array()
	for _observation in OBSERVATIONS:
		var started := Time.get_ticks_usec()
		for _repeat in repeats:
			for index in _bench_positions.size():
				_execute_component(
					_bench_ocean,
					component,
					_bench_positions[index],
					_bench_logical[index],
					_bench_sim_time,
					_bench_sample
				)
		timings.append(float(Time.get_ticks_usec() - started) / float(repeats))
	return _median(timings)


func _calibrate(component: String, query_count: int) -> int:
	var probe := 512
	var elapsed := _time_passes(_bench_ocean, component, query_count, probe)
	var per_series := elapsed / float(probe)
	var repeats := int(round(TARGET_BLOCK_US / maxf(per_series, 0.05)))
	return clampi(repeats, 16, 4194304)


func _time_passes(ocean: Ocean3D, component: String, query_count: int, passes: int) -> float:
	var started := Time.get_ticks_usec()
	for _pass in passes:
		for index in query_count:
			_execute_component(
				ocean,
				component,
				_bench_positions[index],
				_bench_logical[index],
				_bench_sim_time,
				_bench_sample
			)
	return float(Time.get_ticks_usec() - started)


func _execute_component(
	ocean: Ocean3D,
	component: String,
	position: Vector3,
	logical: Vector2,
	simulation_time: float,
	sample: WaterSample3D
) -> void:
	match component:
		"sample_water":
			ocean.sample_water(position, sample)
			_sink += sample.signed_depth
		"sample_height":
			_sink += ocean.sample_height(position)
		"sample_normal":
			_sink += ocean.sample_normal(position).length()
		"sample_water_velocity":
			_sink += ocean.sample_water_velocity(position).length()
		"sample_local_wake_height":
			_sink += ocean.sample_local_wake_height(position)
		"ambient_surface_offset":
			_sink += float(ocean.call(
				"_sample_surface_offset_without_local_wake",
				logical,
				simulation_time
			))
		"event_wave_horizontal_flow":
			_sink += float(ocean.call(
				"_sample_event_wave_horizontal_flow",
				logical,
				simulation_time
			).length())


func _reconstruct(components: Dictionary, query_count: int) -> Dictionary:
	if query_count == 0 or components.is_empty():
		return {
			"query_count": 0,
			"sample_water_us_per_query": -1.0,
			"sum_of_sub_components_us_per_query": -1.0,
			"analytic_reconstruction_us_per_query": -1.0,
			"sum_over_full_ratio": -1.0,
			"analytic_over_full_ratio": -1.0,
			"local_wake_share_percent": 0.0,
			"ambient_share_percent": 0.0,
			"horizontal_flow_share_percent": 0.0,
			"sum_matches": false,
			"analytic_matches": false,
		}
	var full := float(components["sample_water"]["us_per_query"])
	var height := float(components["sample_height"]["us_per_query"])
	var normal := float(components["sample_normal"]["us_per_query"])
	var velocity := float(components["sample_water_velocity"]["us_per_query"])
	var local_wake := float(components["sample_local_wake_height"]["us_per_query"])
	var ambient := float(components["ambient_surface_offset"]["us_per_query"])
	var flow := float(components["event_wave_horizontal_flow"]["us_per_query"])
	var sum_of_sub_components := height + normal + velocity
	var analytic := 5.0 * (ambient + local_wake) + 2.0 * ambient + flow
	var ratio_sub := sum_of_sub_components / full if full > 0.0 else INF
	var ratio_analytic := analytic / full if full > 0.0 else INF
	return {
		"query_count": query_count,
		"sample_water_us_per_query": full,
		"sum_of_sub_components_us_per_query": sum_of_sub_components,
		"analytic_reconstruction_us_per_query": analytic,
		"sum_over_full_ratio": ratio_sub,
		"analytic_over_full_ratio": ratio_analytic,
		"local_wake_share_percent": 100.0 * 5.0 * local_wake / analytic if analytic > 0.0 else 0.0,
		"ambient_share_percent": 100.0 * 7.0 * ambient / analytic if analytic > 0.0 else 0.0,
		"horizontal_flow_share_percent": 100.0 * flow / analytic if analytic > 0.0 else 0.0,
		"sum_matches": absf(ratio_sub - 1.0) <= 0.25,
		"analytic_matches": absf(ratio_analytic - 1.0) <= 0.25,
	}


func _build_control_positions(positions: PackedVector3Array) -> PackedVector3Array:
	var result := PackedVector3Array()
	for position: Vector3 in positions:
		result.append(position + CONTROL_OFFSET)
	return result


func _bottleneck_analysis(workload_rows: Array) -> Dictionary:
	var corridor := Dictionary()
	for row: Dictionary in workload_rows:
		if String(row["name"]) == "traffic_corridor_6":
			corridor = row
			break
	if corridor.is_empty():
		return {"statement": "corridor workload missing"}
	var components: Dictionary = corridor["components"]
	var candidate_components := ["sample_height", "sample_normal", "sample_water_velocity", "sample_local_wake_height"]
	var biggest_name := "sample_normal"
	var biggest_value := -1.0
	for component: String in candidate_components:
		var value := float(components[component]["us_per_query"])
		if value > biggest_value:
			biggest_value = value
			biggest_name = component
	var ambient := float(components["ambient_surface_offset"]["us_per_query"])
	var local := float(components["sample_local_wake_height"]["us_per_query"])
	var normal := float(components["sample_normal"]["us_per_query"])
	var water := float(components["sample_water"]["us_per_query"])
	var local_share_of_water := 100.0 * 5.0 * local / water if water > 0.0 else 0.0
	var local_share_of_normal := 100.0 * 4.0 * local / normal if normal > 0.0 else 0.0
	return {
		"biggest_component_us_per_query": biggest_name,
		"biggest_component_share_of_sample_water_percent": 100.0 * biggest_value / water if water > 0.0 else 0.0,
		"local_wake_share_of_sample_water_percent": local_share_of_water,
		"local_wake_share_of_sample_normal_percent": local_share_of_normal,
		"ambient_us_per_query": ambient,
		"local_wake_us_per_query": local,
		"corridor_sample_water_us_per_query": water,
		"statement": "Biggest remaining component is %s at %.1f us/query; local traffic wake is now %.1f%% of sample_water." % [
			biggest_name, biggest_value, local_share_of_water
		],
	}


func _run_1e_reduction(ocean: Ocean3D, corridor_6: PackedVector3Array) -> Dictionary:
	var rows := Array()
	for label: String in ["cached", "reference_pre_1e"]:
		var timings := PackedFloat64Array()
		for _observation in OBSERVATIONS:
			var started := Time.get_ticks_usec()
			for _repeat in 4096:
				for position: Vector3 in corridor_6:
					if label == "cached":
						_sink += ocean.sample_local_wake_height(position)
					else:
						_sink += _reference_local_wake_aggregate(ocean, position)
			timings.append(float(Time.get_ticks_usec() - started) / 4096.0)
		rows.append({
			"label": label,
			"us_per_query": float(_median(timings)) / float(corridor_6.size()),
		})
	var cached := float(rows[0]["us_per_query"])
	var reference := float(rows[1]["us_per_query"])
	return {
		"cached_us_per_query": cached,
		"reference_pre_1e_us_per_query": reference,
		"reduction_us_per_query": maxf(reference - cached, 0.0),
		"reduction_percent": 100.0 * (reference - cached) / reference if reference > 0.0 else 0.0,
		"ratio_pre_1e_over_cached": reference / cached if cached > 0.0 else -1.0,
		"note": "In-process equivalence reference: same aggregate loop but a textual pre-1E sampler (reads _samples directly) instead of the cached Phase 1E hot path.",
	}


func _run_cold_diagnostic(sources: Array) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for index in sources.size():
		var wake := sources[index] as WakeTrail3D
		if not wake.is_local_wake_physics_active():
			continue
		var bounds := wake.get("_physics_bounds") as Rect2
		if bounds.size.x <= 0.001 or bounds.size.y <= 0.001:
			continue
		var probe := Vector3(
			bounds.position.x + bounds.size.x * 0.5,
			wake.global_position.y,
			bounds.position.y + bounds.size.y * 0.5
		)
		var hot := PackedFloat64Array()
		var cold := PackedFloat64Array()
		for _observation in OBSERVATIONS:
			var started := Time.get_ticks_usec()
			for _repeat in 4096:
				_sink += wake.sample_simplified_wake_height(probe)
			hot.append(float(Time.get_ticks_usec() - started) / 4096.0)
			started = Time.get_ticks_usec()
			for _repeat in 256:
				wake.set(&"_physics_bounds_dirty", true)
				wake.set(&"_local_wake_cache_dirty", true)
				_sink += wake.sample_simplified_wake_height(probe)
			cold.append(float(Time.get_ticks_usec() - started) / 256.0)
		wake.set(&"_physics_bounds_dirty", true)
		wake.set(&"_local_wake_cache_dirty", true)
		wake.sample_simplified_wake_height(probe)
		result.append({
			"source": index,
			"hot_us_per_query": _median(hot),
			"cold_full_tick_rebuild_us_per_query": _median(cold),
		})
	return result


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


func _reference_local_wake_aggregate(ocean: Ocean3D, world_position: Vector3) -> float:
	var height := 0.0
	var sources := ocean.get("_local_wake_physics_sources") as Array
	for index in range(sources.size() - 1, -1, -1):
		var source := sources[index] as WakeTrail3D
		if not is_instance_valid(source):
			continue
		if source.is_local_wake_physics_active():
			height += _reference_sample(source, world_position)
	return clampf(
		height,
		-ocean.vehicle_interaction_maximum_displacement,
		ocean.vehicle_interaction_maximum_displacement
	)


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


func _median(values: PackedFloat64Array) -> float:
	if values.is_empty():
		return -1.0
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


func _argument_value(prefix: String, fallback: String) -> String:
	for argument: String in OS.get_cmdline_user_args():
		if argument.begins_with(prefix):
			return argument.trim_prefix(prefix)
	return fallback


func _sanitize(value: Variant) -> Variant:
	if value is float:
		return value if is_finite(value) else -1.0
	if value is Array:
		var out := []
		for item: Variant in value:
			out.append(_sanitize(item))
		return out
	if value is Dictionary:
		var out := {}
		for key: Variant in value:
			out[key] = _sanitize(value[key])
		return out
	return value


func _write_report(report: Dictionary) -> String:
	var absolute_directory := ProjectSettings.globalize_path(OUTPUT_DIRECTORY)
	if DirAccess.make_dir_recursive_absolute(absolute_directory) != OK:
		return "ERROR_CREATING_OUTPUT_DIRECTORY"
	var timestamp := Time.get_datetime_string_from_system().replace(":", "-")
	var path := "%s/ocean_phase_1e1_post_%s_%s.json" % [
		OUTPUT_DIRECTORY,
		String(report["label"]),
		timestamp,
	]
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return "ERROR_OPENING_REPORT"
	file.store_string(JSON.stringify(_sanitize(report), "\t"))
	file.close()
	return ProjectSettings.globalize_path(path)


func _fail(message: String) -> void:
	get_tree().paused = false
	push_error("Ocean Phase 1E.1 Post Validation: %s" % message)
	get_tree().quit(1)