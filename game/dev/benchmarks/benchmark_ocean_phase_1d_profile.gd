extends Node

const GOLD_CITY_SCENE := "res://levels/gold_city/gold_city.tscn"
const OUTPUT_DIRECTORY := "res://.godot/ocean_benchmarks"
const TRAFFIC_WARMUP_PHYSICS_FRAMES := 300
const WORKLOAD_OBSERVATIONS := 9
const WORKLOAD_WARMUP_QUERIES := 64
const MAXIMUM_LOCAL_DRIFT := 0.25
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
	var jet_ski := city.get_node_or_null("Gameplay/JetSki") as JetSkiController
	var traffic_root := city.get_node_or_null("BoatTraffic")
	if ocean == null or jet_ski == null or traffic_root == null:
		_fail("Phase 1D could not resolve Ocean, JetSki, or BoatTraffic.")
		return
	var traffic_actors: Array[BoatTrafficActor] = []
	_collect_traffic_actors(traffic_root, traffic_actors)
	if traffic_actors.size() != 3:
		_fail("Expected 3 Gold City traffic actors; found %d." % traffic_actors.size())
		return
	for actor: BoatTrafficActor in traffic_actors:
		actor.camera_visibility_optimization_enabled = false
		actor.call(&"_set_camera_effects_active", true)
	var player_wake := jet_ski.find_child("WakeTrail3D", true, false) as WakeTrail3D

	get_tree().paused = false
	for _frame in TRAFFIC_WARMUP_PHYSICS_FRAMES:
		await get_tree().physics_frame

	ocean.call(&"_update_directional_wake_segments")
	var active_count := int(ocean.get("_directional_wake_active_count"))
	if active_count <= 0:
		_fail("Gold City produced no active directional-wake segments.")
		return
	var live_full := _build_live_queries(jet_ski)
	if live_full.size() != 6:
		_fail("JetSki did not expose its six live query positions.")
		return
	var route_queries := _build_traffic_corridor_queries(ocean, jet_ski)
	var corridor_full := route_queries.get("full", PackedVector3Array()) as PackedVector3Array
	if corridor_full.size() < 6:
		_fail("Could not build the 6-query traffic-corridor workload.")
		return
	var corridor_full_6 := corridor_full.slice(0, 6)

	city.process_mode = Node.PROCESS_MODE_DISABLED

	var workloads := [
		{
			"name": "live_player_full_6",
			"positions": live_full,
			"description": "One live Gold City JetSki physics tick (4 buoyancy + body center + propulsion)",
		},
		{
			"name": "traffic_corridor_full_6",
			"positions": corridor_full_6,
			"description": "One complete JetSki tick positioned on a real traffic-wake segment",
		},
	]
	var workload_rows: Array[Dictionary] = []
	for workload: Dictionary in workloads:
		var positions := workload["positions"] as PackedVector3Array
		var components := _measure_components(ocean, positions)
		var reconstruction := _reconstruct(components, positions.size())
		workload_rows.append({
			"name": workload["name"],
			"description": workload["description"],
			"queries": positions.size(),
			"components": components,
			"reconstruction": reconstruction,
		})
		var name := String(workload["name"])
		print(
			"GOLD_CITY_PHASE_1D_PROFILE name=%s queries=%d sample_water_us=%.3f sum_sub=%.3f analytic=%.3f ratio=%.4f"
			% [
				name,
				positions.size(),
				float(reconstruction["sample_water_us_per_query"]),
				float(reconstruction["sum_of_sub_components_us_per_query"]),
				float(reconstruction["analytic_reconstruction_us_per_query"]),
				float(reconstruction["analytic_over_full_ratio"]),
			]
		)
		print(
			"GOLD_CITY_PHASE_1D_SPLIT name=%s local_wake_pct=%.1f ambient_pct=%.1f flow_pct=%.1f"
			% [
				name,
				float(reconstruction["local_wake_share_percent"]),
				float(reconstruction["ambient_share_percent"]),
				float(reconstruction["horizontal_flow_share_percent"]),
			]
		)
		await get_tree().process_frame

	var corridor_row := workload_rows[1]
	var near_local := float(
		corridor_row["components"]["sample_local_wake_height"]["us_per_query"]
	)
	var far_local := (
		(
			float(corridor_row["components"]["sample_local_wake_height"]["control_before_us_per_query"])
			+ float(corridor_row["components"]["sample_local_wake_height"]["control_after_us_per_query"])
		) * 0.5
	)
	var near_ambient := float(
		corridor_row["components"]["ambient_surface_offset"]["us_per_query"]
	)
	var far_ambient := (
		(
			float(corridor_row["components"]["ambient_surface_offset"]["control_before_us_per_query"])
			+ float(corridor_row["components"]["ambient_surface_offset"]["control_after_us_per_query"])
		) * 0.5
	)
	var live_local := float(
		workload_rows[0]["components"]["sample_local_wake_height"]["us_per_query"]
	)
	var near_vs_far := {
		"near_workload": "traffic_corridor_full_6",
		"far_control_offset": CONTROL_OFFSET,
		"sample_local_wake_height": {
			"near_us_per_query": near_local,
			"far_us_per_query": far_local,
			"ratio_near_over_far": near_local / far_local if far_local > 0.0 else INF,
			"live_player_us_per_query": live_local,
		},
		"ambient_surface_offset": {
			"near_us_per_query": near_ambient,
			"far_us_per_query": far_ambient,
			"ratio_near_over_far": near_ambient / far_ambient if far_ambient > 0.0 else INF,
			"note": "Far control excludes navigable directional-wake segment loops (phase 1a bounds reject).",
		},
	}
	print(
		"GOLD_CITY_PHASE_1D_LOCAL_WAKE near_us=%.3f far_us=%.3f ratio=%.3f live_us=%.3f sources=%d"
		% [
			near_local,
			far_local,
			near_local / far_local if far_local > 0.0 else INF,
			live_local,
			_local_wake_source_rows(ocean).size(),
		]
	)

	var report := {
		"schema": "ocean_phase_1d_profile_v1",
		"label": _argument_value("--label=", "unlabelled"),
		"commit": _argument_value("--commit=", "unknown"),
		"diagnostic_only": true,
		"methodology": {
			"note": "Phase 1D diagnostic decomposition. No runtime files, no Ocean3D, no shaders, no scenes were modified. Internal paths are benchmark-only.",
			"scene": GOLD_CITY_SCENE,
			"physics_hz": Engine.physics_ticks_per_second,
			"traffic_warmup_physics_frames": TRAFFIC_WARMUP_PHYSICS_FRAMES,
			"traffic_actor_count": traffic_actors.size(),
			"workload_observations": WORKLOAD_OBSERVATIONS,
			"workload_warmup_queries": WORKLOAD_WARMUP_QUERIES,
			"maximum_local_drift": MAXIMUM_LOCAL_DRIFT,
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
			"player_wake_registered_as_local_physics_source": _local_wake_sources_contain(ocean, player_wake),
		},
		"snapshot": _snapshot_metadata(ocean, workloads),
		"local_wake_sources": _local_wake_source_rows(ocean),
		"directional_sources": _directional_source_metadata(jet_ski, traffic_actors),
		"workloads": workload_rows,
		"near_vs_far": near_vs_far,
	}
	var report_path := _write_report(report)
	print("GOLD_CITY_PHASE_1D_SNAPSHOT=%s" % String(report["snapshot"]["fingerprint"]))
	print("GOLD_CITY_PHASE_1D_JSON=%s" % report_path)
	print("GOLD_CITY_PHASE_1D_PROFILE=PASS")
	get_tree().quit(0)


func _collect_traffic_actors(node: Node, result: Array[BoatTrafficActor]) -> void:
	if node is BoatTrafficActor:
		result.append(node as BoatTrafficActor)
	for child: Node in node.get_children():
		_collect_traffic_actors(child, result)


func _build_live_queries(jet_ski: JetSkiController) -> PackedVector3Array:
	var result := (
		jet_ski.water_physics_system.point_world_positions.duplicate()
	)
	if result.size() != JetSkiWaterPhysicsSystem.BUOYANCY_POINT_COUNT:
		return PackedVector3Array()
	result.append(jet_ski.global_position)
	result.append(jet_ski.drive_system.state.propulsion_world_position)
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


func _measure_components(
	ocean: Ocean3D,
	positions: PackedVector3Array
) -> Dictionary:
	var control_positions := _build_control_positions(positions)
	var result := {}
	for component: String in COMPONENTS:
		var before := _measure_component(ocean, component, control_positions)
		var workload := _measure_component(ocean, component, positions)
		var after := _measure_component(ocean, component, control_positions)
		var before_median := float(before.get("median", 0.0))
		var after_median := float(after.get("median", 0.0))
		var reference := (before_median + after_median) * 0.5
		var drift := (
			absf(after_median - before_median) / reference
			if reference > 0.0
			else INF
		)
		result[component] = {
			"timing": workload,
			"us_per_query": float(workload.get("median", 0.0)) / float(maxi(positions.size(), 1)),
			"control_before_us_per_query": before_median / float(maxi(positions.size(), 1)),
			"control_after_us_per_query": after_median / float(maxi(positions.size(), 1)),
			"local_relative_drift": drift,
			"valid": drift <= MAXIMUM_LOCAL_DRIFT,
		}
	return result


func _measure_component(
	ocean: Ocean3D,
	component: String,
	positions: PackedVector3Array
) -> Dictionary:
	var logical := PackedVector2Array()
	logical.resize(positions.size())
	for index in positions.size():
		logical[index] = ocean.world_to_logical_xz(positions[index])
	var simulation_time := ocean.get_simulation_time()
	var sample := WaterSample3D.new()
	var query_count := positions.size()
	var repeats := 64 if query_count <= 6 else 32
	for index in WORKLOAD_WARMUP_QUERIES:
		_execute_component(
			ocean,
			component,
			positions[index % query_count],
			logical[index % query_count],
			simulation_time,
			sample
		)
	var timings := PackedFloat64Array()
	for _observation in WORKLOAD_OBSERVATIONS:
		var started := Time.get_ticks_usec()
		for _repeat in repeats:
			for index in query_count:
				_execute_component(
					ocean,
					component,
					positions[index],
					logical[index],
					simulation_time,
					sample
				)
		timings.append(float(Time.get_ticks_usec() - started) / float(repeats))
	return _stats(timings)


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


func _local_wake_source_rows(ocean: Ocean3D) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var sources := ocean.get("_local_wake_physics_sources") as Array
	for source: Variant in sources:
		var wake := source as WakeTrail3D
		if wake == null:
			continue
		var bounds := wake.get("_physics_bounds") as Rect2
		var stride := wake.local_physics_segment_stride
		var scanned_segments := 0.0
		if stride >= 1 and wake.sample_count >= 2:
			var first_recent := int(wake.get("_physics_first_recent_sample_index"))
			scanned_segments = (
				floorf(float(maxi(wake.sample_count - 1 - first_recent, 0)) / float(stride)) + 1.0
			)
		result.append({
			"label": "traffic_wake",
			"node_path": str(wake.get_path()),
			"sample_count": wake.sample_count,
			"physics_enabled": wake.physics_enabled,
			"wake_enabled": wake.wake_enabled,
			"local_wake_physics_active": wake.is_local_wake_physics_active(),
			"local_physics_segment_stride": stride,
			"local_physics_lifetime": wake.local_physics_lifetime,
			"wake_lifetime": wake.wake_lifetime,
			"physics_bounds_min_x": bounds.position.x,
			"physics_bounds_min_y": bounds.position.y,
			"physics_bounds_width": bounds.size.x,
			"physics_bounds_height": bounds.size.y,
			"estimated_scanned_segments_per_query": scanned_segments,
		})
	return result


func _local_wake_sources_contain(ocean: Ocean3D, wake: WakeTrail3D) -> bool:
	if not is_instance_valid(wake):
		return false
	var sources := ocean.get("_local_wake_physics_sources") as Array
	return sources.has(wake)


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
	var path := "%s/ocean_phase_1d_profile_%s_%s.json" % [
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
	push_error("Ocean Phase 1D Profile: %s" % message)
	get_tree().quit(1)
