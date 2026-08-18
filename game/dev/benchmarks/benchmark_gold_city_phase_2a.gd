extends Node

## Phase 2A — Gold City whole-frame profiler.
## Diagnostic only. No runtime modified. Scenario sampling of the real Gold City.
## Modes: headless (CPU diagnostic) or rendered (real window), auto-detected.

const GOLD_CITY_SCENE := "res://levels/gold_city/gold_city.tscn"
const OUTPUT_DIRECTORY := "res://.godot/benchmarks_2a"
const PHASE_TAG := "GOLD_CITY_PHASE_2A"

const WARMUP_PHYSICS_FRAMES := 600
const SETTLE_PHYSICS_FRAMES := 150
const SAMPLE_PROCESS_FRAMES := 240
const SWEEP_HEADINGS := 8
const SWEEP_FRAMES_PER_HEADING := 6

const FRAME_16_67_MS := 16.667
const FRAME_20_MS := 20.0
const FRAME_33_33_MS := 33.333

## Phase 1E1 authoritative per-query ocean costs (live player / traffic corridor).
const OCEAN_US_PER_QUERY_LIVE := 53.825
const OCEAN_US_PER_QUERY_CORRIDOR := 89.269
const OCEAN_QUERY_COUNT := 6
const OCEAN_1E1_COMMIT := "c531c45"

const SCENARIO_STATIONARY := "PLAYER_STATIONARY"
const SCENARIO_MOVING := "PLAYER_MOVING"
const SCENARIO_TRAFFIC_VISIBLE := "TRAFFIC_VISIBLE"
const SCENARIO_TRAFFIC_OFFSCREEN := "TRAFFIC_OFFSCREEN"
const SCENARIO_WORST_VIEW := "WORST_VIEW"

var _label := _argument_value("--label=", "unlabelled")
var _commit := _argument_value("--commit=", "unknown")
var _mode := "unknown"
var _renderer_active := false

var _city: Node
var _jet_ski: RigidBody3D
var _camera: Camera3D
var _ocean: Node3D
var _spawn: Node3D
var _traffic_roots: Array[Node3D] = []
var _building_roots: Array[Node3D] = []

var _sample_active := false
var _last_process_wall_us := 0
var _last_physics_wall_us := 0
var _scenario_name := ""
var _wall_ms: Array[float] = []
var _process_ms: Array[float] = []
var _physics_ms: Array[float] = []
var _physics_wall_ms: Array[float] = []
var _fps: Array[float] = []
var _monitors := {}

const MONITOR_NAMES: Array[String] = [
	"time_process",
	"time_physics_process",
	"time_navigation_process",
	"object_count",
	"object_resource_count",
	"object_node_count",
	"object_orphan_node_count",
	"render_total_objects_in_frame",
	"render_total_primitives_in_frame",
	"render_total_draw_calls_in_frame",
	"memory_static",
	"memory_static_max",
	"physics_3d_active_objects",
	"physics_3d_collision_pairs",
	"audio_output_latency",
]

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	call_deferred(&"_run")


func _run() -> void:
	var mode := DisplayServer.get_name()
	if mode == "headless":
		_mode = "headless"
		_renderer_active = false
	else:
		_mode = "rendered"
		_renderer_active = true

	Engine.max_fps = 0
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)

	for monitor_name: String in MONITOR_NAMES:
		_monitors[monitor_name] = []

	get_tree().paused = true
	var packed := load(GOLD_CITY_SCENE) as PackedScene
	if packed == null:
		_fail("cannot load %s" % GOLD_CITY_SCENE)
		return
	get_tree().current_scene = null
	get_tree().change_scene_to_packed(packed)
	await get_tree().scene_changed
	for _frame in 3:
		await get_tree().process_frame
	_city = get_tree().current_scene
	if _city == null:
		_fail("no scene")
		return

	_jet_ski = _city.get_node_or_null("Gameplay/JetSki") as RigidBody3D
	_camera = _city.get_node_or_null("CameraSystem/ChaseCamera/Camera3D") as Camera3D
	_ocean = _city.get_node_or_null("WaterIntegration/Ocean") as Node3D
	_spawn = _city.get_node_or_null("Gameplay/PlayerSpawn") as Node3D
	if _jet_ski == null or _camera == null or _spawn == null:
		_fail("missing JetSki / Camera3D / PlayerSpawn")
		return

	_traffic_roots.clear()
	for i in 3:
		var lane_path := "BoatTraffic/Path3D%s" % ("" if i == 0 else str(i + 1))
		var path_follow := _city.get_node_or_null(lane_path + "/PathFollow3D")
		if path_follow == null:
			_fail("missing traffic path %d (%s)" % [i, lane_path])
			return
		var actor := _city.get_node_or_null(lane_path + "/PathFollow3D/BoatTrafficActor") as Node3D
		_traffic_roots.append(actor if actor != null else path_follow as Node3D)

	for building_name: String in ["casino", "beach_hotel", "rollercoaster", "ferrys_wheel"]:
		var building := _city.get_node_or_null("Props/Buildings/%s" % building_name) as Node3D
		if building != null:
			_building_roots.append(building)

	get_tree().paused = false
	for _frame in WARMUP_PHYSICS_FRAMES:
		await get_tree().physics_frame

	var scenarios := []
	scenarios.append(await _sample_scenario(SCENARIO_STATIONARY, {}))
	scenarios.append(await _sample_scenario(SCENARIO_MOVING, {"throttle": true}))
	var traffic_center := _average_traffic_position()
	var spawn_pos := _spawn.global_position
	var look_dir := (traffic_center - spawn_pos)
	look_dir.y = 0.0
	look_dir = look_dir.normalized()
	var behind := traffic_center - look_dir * 140.0
	behind.y = -0.9
	scenarios.append(await _sample_scenario(SCENARIO_TRAFFIC_VISIBLE, {"place_pos": behind, "forward": look_dir}))
	scenarios.append(await _sample_scenario(SCENARIO_TRAFFIC_OFFSCREEN, {"place_pos": behind, "forward": -look_dir}))
	scenarios.append(await _sample_scenario(SCENARIO_WORST_VIEW, {"sweep": true, "sweep_center": traffic_center}))

	Input.action_release("throttle")

	var report := _build_report(scenarios, mode)
	var report_path := _write_report(report)
	if report_path == "":
		_fail("cannot write report")
		return

	print("%s_MODE=%s" % [PHASE_TAG, _mode])
	print("%s_SNAPSHOT=%s" % [PHASE_TAG, report["snapshot"]])
	print("%s_JSON=%s" % [PHASE_TAG, report_path])
	for scenario: Dictionary in scenarios:
		var wall: Dictionary = scenario["wall_ms"]
		var physics: Dictionary = scenario["physics_ms"]
		var process: Dictionary = scenario["process_ms"]
		var draw: Dictionary = scenario["monitor_stats"]["render_total_draw_calls_in_frame"]
		var objects: Dictionary = scenario["monitor_stats"]["render_total_objects_in_frame"]
		var prims: Dictionary = scenario["monitor_stats"]["render_total_primitives_in_frame"]
		print(
			"%s_SUMMARY mode=%s scenario=%s frames=%d fps_mean=%.2f wall_ms_median=%.3f wall_p99=%.3f process_ms_mean=%.3f physics_ms_mean=%.3f physics_wall_mean=%.3f draw_calls_mean=%.2f objects_mean=%.2f primitives_mean=%.2f traffic_visible=%d"
			% [
				PHASE_TAG, _mode, scenario["name"], wall["count"],
				scenario["fps_mean"], wall["median"], wall["p99"],
				process["mean"], physics["mean"], (scenario["physics_wall_ms"] as Dictionary)["mean"],
				draw["mean"], objects["mean"], prims["mean"],
				scenario["traffic_in_frustum"],
			]
		)
	print("%s_VERDICT %s" % [PHASE_TAG, report["cpu_vs_render"]["verdict"]])
	var ranking_line := " "
	for r: String in report["candidate_ranking"]:
		ranking_line += " | " + r
	print("%s_RANKING%s" % [PHASE_TAG, ranking_line])
	print("%s=%s" % [PHASE_TAG, "PASS"])
	get_tree().quit(0)


func _sample_scenario(scenario_name: String, options: Dictionary) -> Dictionary:
	_scenario_name = scenario_name
	_samples_clear()

	get_tree().paused = false
	Input.action_release("throttle")
	Input.action_release("brake")
	Input.action_release("steer_left")
	Input.action_release("steer_right")

	if options.has("place_pos"):
		var forward: Vector3 = options.get("forward", Vector3.FORWARD)
		_place_jet_ski(options["place_pos"] as Vector3, forward)

	if options.get("sweep", false):
		_run_view_sweep(options["sweep_center"] as Vector3)

	var throttle: bool = options.get("throttle", false)
	if throttle:
		Input.action_press("throttle")

	for _frame in SETTLE_PHYSICS_FRAMES:
		await get_tree().physics_frame

	if options.has("place_pos"):
		_place_jet_ski(options["place_pos"] as Vector3, options["forward"] as Vector3)
		for _frame in 12:
			await get_tree().physics_frame

	var traffic_visible := _traffic_visible_count()

	_sample_active = true
	_last_process_wall_us = Time.get_ticks_usec()
	_last_physics_wall_us = 0
	for _frame in SAMPLE_PROCESS_FRAMES:
		await get_tree().process_frame
	_sample_active = false

	if throttle:
		Input.action_release("throttle")

	var scenario := {
		"name": scenario_name,
		"frames": _wall_ms.size(),
		"jet_ski_transform": _jet_ski_transform_dict(),
		"traffic_in_frustum": traffic_visible,
		"traffic_world_positions": _traffic_positions(),
		"video_memory_mb_snapshot": _vram_snapshot_mb(),
		"wall_ms": _stats(_wall_ms),
		"process_ms": _stats(_process_ms),
		"physics_ms": _stats(_physics_ms),
		"physics_wall_ms": _stats(_physics_wall_ms),
		"fps_mean": _mean(_fps),
		"overs": _overs(_wall_ms),
		"top_spikes": _top_spikes(_wall_ms, 5),
		"monitor_stats": {},
	}
	for monitor_name: String in MONITOR_NAMES:
		var values: Array = _monitors[monitor_name]
		scenario["monitor_stats"][monitor_name] = _stats(values)
	return scenario


func _run_view_sweep(center: Vector3) -> void:
	var base := center - _spawn.global_position
	base.y = 0.0
	base = base.normalized()
	var best_score := -1.0
	var best_heading := {}
	for i in SWEEP_HEADINGS:
		var angle := float(i) * TAU / float(SWEEP_HEADINGS)
		var fwd := Vector3(
			base.x * cos(angle) - base.z * sin(angle),
			0.0,
			base.x * sin(angle) + base.z * cos(angle)
		).normalized()
		var pos := center - fwd * 160.0
		pos.y = -0.9
		_place_jet_ski(pos, fwd)
		for _frame in SWEEP_FRAMES_PER_HEADING:
			await get_tree().process_frame
		var objects: float = 0.0
		if _renderer_active:
			objects = Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME)
		else:
			objects = float(_traffic_visible_count())
		var score: float = float(_traffic_visible_count()) * 5000.0 + objects
		if score > best_score:
			best_score = score
			best_heading = {"pos": pos, "forward": fwd}
	if best_heading.is_empty():
		return
	_place_jet_ski(best_heading["pos"] as Vector3, best_heading["forward"] as Vector3)


func _place_jet_ski(pos: Vector3, forward: Vector3) -> void:
	var safe := Vector3(forward.x, 0.0, forward.z)
	if safe.length() < 0.001:
		safe = Vector3.FORWARD
	safe = safe.normalized()
	_jet_ski.global_transform = Transform3D(Basis.looking_at(safe, Vector3.UP), pos)
	_jet_ski.linear_velocity = Vector3.ZERO
	_jet_ski.angular_velocity = Vector3.ZERO
	if _jet_ski.has_method("reset_physics_interpolation"):
		_jet_ski.reset_physics_interpolation()


func _samples_clear() -> void:
	_wall_ms.clear()
	_process_ms.clear()
	_physics_ms.clear()
	_physics_wall_ms.clear()
	_fps.clear()
	for monitor_name: String in MONITOR_NAMES:
		_monitors[monitor_name].clear()


func _vram_snapshot_mb() -> float:
	if not _renderer_active:
		return -1.0
	var rendering_server := RenderingServer
	if rendering_server == null or not ClassDB.class_has_method("RenderingServer", "get_rendering_device"):
		return -1.0
	var rd := rendering_server.get_rendering_device()
	if rd == null:
		return -1.0
	var usage: Variant = rd.call("get_memory_usage", 0)
	if typeof(usage) != TYPE_DICTIONARY:
		return -1.0
	var total: Variant = usage.get("total", -1)
	if int(total) >= 0:
		return float(int(total)) / (1024.0 * 1024.0)
	var tex: Variant = usage.get("texture", -1)
	var buf: Variant = usage.get("buffer", -1)
	if int(tex) >= 0 and int(buf) >= 0:
		return (float(int(tex)) + float(int(buf))) / (1024.0 * 1024.0)
	return -1.0


func _process(_delta: float) -> void:
	if not (_sample_active and _last_process_wall_us > 0):
		return
	var now_us := Time.get_ticks_usec()
	_wall_ms.append(float(now_us - _last_process_wall_us) / 1000.0)
	_last_process_wall_us = now_us
	_process_ms.append(Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0)
	_fps.append(Engine.get_frames_per_second())
	_snapshot_monitors()


func _physics_process(_delta: float) -> void:
	if not _sample_active:
		return
	var now_us := Time.get_ticks_usec()
	if _last_physics_wall_us > 0:
		_physics_wall_ms.append(float(now_us - _last_physics_wall_us) / 1000.0)
	_last_physics_wall_us = now_us
	_physics_ms.append(Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0)


func _snapshot_monitors() -> void:
	for monitor_name: String in MONITOR_NAMES:
		var monitor_id := _monitor_id(monitor_name)
		var value: float = Performance.get_monitor(monitor_id)
		_monitors[monitor_name].append(value)


func _monitor_id(monitor_name: String) -> int:
	match monitor_name:
		"time_process":
			return Performance.TIME_PROCESS
		"time_physics_process":
			return Performance.TIME_PHYSICS_PROCESS
		"time_navigation_process":
			return Performance.TIME_NAVIGATION_PROCESS
		"object_count":
			return Performance.OBJECT_COUNT
		"object_resource_count":
			return Performance.OBJECT_RESOURCE_COUNT
		"object_node_count":
			return Performance.OBJECT_NODE_COUNT
		"object_orphan_node_count":
			return Performance.OBJECT_ORPHAN_NODE_COUNT
		"render_total_objects_in_frame":
			return Performance.RENDER_TOTAL_OBJECTS_IN_FRAME
		"render_total_primitives_in_frame":
			return Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME
		"render_total_draw_calls_in_frame":
			return Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME
		"memory_static":
			return Performance.MEMORY_STATIC
		"memory_static_max":
			return Performance.MEMORY_STATIC_MAX
		"physics_3d_active_objects":
			return Performance.PHYSICS_3D_ACTIVE_OBJECTS
		"physics_3d_collision_pairs":
			return Performance.PHYSICS_3D_COLLISION_PAIRS
		"audio_output_latency":
			return Performance.AUDIO_OUTPUT_LATENCY
	return Performance.OBJECT_COUNT


func _traffic_visible_count() -> int:
	if _camera == null:
		return 0
	var count := 0
	for root: Node3D in _traffic_roots:
		if _camera.is_position_in_frustum(root.global_position):
			count += 1
	return count


func _average_traffic_position() -> Vector3:
	var sum := Vector3.ZERO
	for root: Node3D in _traffic_roots:
		sum += root.global_position
	return sum / float(_traffic_roots.size())


func _traffic_positions() -> Array:
	var positions := []
	for root: Node3D in _traffic_roots:
		positions.append([root.global_position.x, root.global_position.y, root.global_position.z])
	return positions


func _jet_ski_transform_dict() -> Dictionary:
	var t := _jet_ski.global_transform
	return {
		"origin": [t.origin.x, t.origin.y, t.origin.z],
		"basis_x": [t.basis.x.x, t.basis.x.y, t.basis.x.z],
		"basis_y": [t.basis.y.x, t.basis.y.y, t.basis.y.z],
		"basis_z": [t.basis.z.x, t.basis.z.y, t.basis.z.z],
	}


func _build_report(scenarios: Array, mode: String) -> Dictionary:
	var physics_tick_mean_us: float = float(scenarios[0]["physics_ms"]["mean"]) * 1000.0
	var verdict := _classify(mode, scenarios)

	var report := {
		"schema": "gold_city_whole_frame_2a",
		"label": _label,
		"commit": _commit,
		"mode": mode,
		"snapshot": _snapshot_fingerprint(),
		"methodology": {
			"scene": GOLD_CITY_SCENE,
			"engine": Engine.get_version_info()["string"] if Engine.get_version_info().has("string") else str(Engine.get_version_info()),
			"physics_ticks_per_second": Engine.physics_ticks_per_second,
			"physics_interpolation": ProjectSettings.get_setting("physics/common/physics_interpolation", false),
			"physics_engine": ProjectSettings.get_setting("physics/3d/physics_engine", "unknown"),
			"renderer_method": ProjectSettings.get_setting("renderer/rendering_method", "unknown"),
			"renderer_driver": ProjectSettings.get_setting("rendering_device/driver.windows", "unknown"),
			"scaling_3d_scale": ProjectSettings.get_setting("rendering/scaling_3d/scale", 1.0),
			"gi_use_half_resolution": ProjectSettings.get_setting("rendering/global_illumination/gi/use_half_resolution", false),
			"warmup_physics_frames": WARMUP_PHYSICS_FRAMES,
			"settle_physics_frames": SETTLE_PHYSICS_FRAMES,
			"sample_process_frames": SAMPLE_PROCESS_FRAMES,
			"vsync_disabled": true,
			"max_fps": 0,
			"window_size": str(DisplayServer.window_get_size()),
			"video_adapter_name": RenderingServer.get_video_adapter_name(),
			"video_adapter_vendor": RenderingServer.get_video_adapter_vendor(),
			"graphics_quality_debug": _graphics_quality_debug(),
		},
		"scenarios": scenarios,
		"ocean_share_approx": {
			"phase_1e1_commit": OCEAN_1E1_COMMIT,
			"queries_per_tick": OCEAN_QUERY_COUNT,
			"us_per_query_live": OCEAN_US_PER_QUERY_LIVE,
			"us_per_tick_live": OCEAN_US_PER_QUERY_LIVE * float(OCEAN_QUERY_COUNT),
			"us_per_query_corridor": OCEAN_US_PER_QUERY_CORRIDOR,
			"us_per_tick_corridor": OCEAN_US_PER_QUERY_CORRIDOR * float(OCEAN_QUERY_COUNT),
			"physics_tick_mean_us": physics_tick_mean_us,
			"live_percent_of_tick": OCEAN_US_PER_QUERY_LIVE * float(OCEAN_QUERY_COUNT) / physics_tick_mean_us * 100.0 if physics_tick_mean_us > 0.0 else -1.0,
			"corridor_percent_of_tick": OCEAN_US_PER_QUERY_CORRIDOR * float(OCEAN_QUERY_COUNT) / physics_tick_mean_us * 100.0 if physics_tick_mean_us > 0.0 else -1.0,
			"note": "Approximate: 6 real JetSki ocean queries per physics tick at Phase 1E1 authoritative costs; do not re-read as a new microbenchmark.",
		},
		"cpu_vs_render": verdict,
		"candidate_ranking": _ranking(scenarios, mode),
		"runtime_files_modified": 0,
	}
	return report


func _classify(mode: String, scenarios: Array) -> Dictionary:
	var wall := scenarios[0]["wall_ms"] as Dictionary
	var process := scenarios[0]["process_ms"] as Dictionary
	var physics := scenarios[0]["physics_ms"] as Dictionary

	var weights := float(scenarios.size())
	var wall_sum := 0.0
	var cpu_sum := 0.0
	for s: Dictionary in scenarios:
		wall_sum += s["wall_ms"]["median"]
		cpu_sum += (s["process_ms"]["median"] + s["physics_ms"]["median"])
	var wall_avg := wall_sum / weights
	var cpu_avg := cpu_sum / weights
	var gap := wall_avg - cpu_avg
	var cpu_share := cpu_avg / wall_avg if wall_avg > 0.0 else 0.0

	var verdict := "INCONCLUSIVE"
	var evidence := {
		"wall_median_ms": wall["median"],
		"process_median_ms": process["median"],
		"physics_median_ms": physics["median"],
		"avg_wall_ms": wall_avg,
		"avg_cpu_ms": cpu_avg,
		"render_gap_ms": gap,
		"render_cpu_share": cpu_share,
		"render_active": _renderer_active,
		"note": "No per-frame GPU timer exists on the 4.7 D3D12 driver (RenderingServer.get_frame_time_gpu removed); render-bound classification uses wall-vs-CPU gap.",
	}
	if mode == "headless":
		verdict = "CPU_DIAGNOSTIC"
	else:
		if wall_avg <= 16.0:
			verdict = "WELL_WITHIN_BUDGET"
		elif cpu_share >= 0.6 and wall_avg > 16.0:
			verdict = "CPU_PHYSICS_BOUND" if physics["median"] >= process["median"] else "CPU_SCRIPT_BOUND"
		else:
			verdict = "LIKELY_RENDER_BOUND"
	return {"verdict": verdict, "evidence": evidence}


func _ranking(scenarios: Array, mode: String) -> Array:
	var process_sum := 0.0
	var physics_sum := 0.0
	var draw_sum := 0.0
	var objects_sum := 0.0
	var orphan_sum := 0.0
	for s: Dictionary in scenarios:
		process_sum += s["process_ms"]["mean"]
		physics_sum += s["physics_ms"]["mean"]
		draw_sum += s["monitor_stats"]["render_total_draw_calls_in_frame"]["mean"]
		objects_sum += s["monitor_stats"]["render_total_objects_in_frame"]["mean"]
		orphan_sum += s["monitor_stats"]["object_orphan_node_count"]["mean"]
	var n := float(scenarios.size())
	var process_avg := process_sum / n
	var physics_avg := physics_sum / n
	var draw_avg := draw_sum / n
	var objects_avg := objects_sum / n

	var ranked: Array[String] = []
	if _renderer_active:
		var wall_avg := 0.0
		for s: Dictionary in scenarios:
			wall_avg += s["wall_ms"]["median"]
		wall_avg /= n
		var ord := _classify(mode, scenarios)
		if ord["verdict"] == "LIKELY_RENDER_BOUND":
			ranked.append("rendering/lights/shadows (draw_calls=%.1f objects=%.1f)" % [draw_avg, objects_avg])
		if physics_avg >= process_avg:
			ranked.append("physics tick (Jolt + vehicle/ocean + traffic) (%.3f ms)" % physics_avg)
			ranked.append("process scripts (camera/effects/vegetation) (%.3f ms)" % process_avg)
		else:
			ranked.append("process scripts (camera/effects/vegetation) (%.3f ms)" % process_avg)
			ranked.append("physics tick (Jolt + vehicle/ocean + traffic) (%.3f ms)" % physics_avg)
		ranked.append("geometry/primitives budget (city + terrain + vegetation) objects=%.0f" % objects_avg)
		ranked.append("node/orphan overhead (orphan_nodes=%.1f nodes=%d)" % [orphan_sum / n, int(scenarios[0]["monitor_stats"]["object_node_count"]["mean"])])
	elif physics_avg >= process_avg:
		ranked.append("physics tick (Jolt + vehicle/ocean + traffic) (%.3f ms)" % physics_avg)
		ranked.append("process scripts (camera/effects/vegetation) (%.3f ms)" % process_avg)
		ranked.append("node/orphan overhead (orphan_nodes=%.1f)" % (orphan_sum / n))
	else:
		ranked.append("process scripts (camera/effects/vegetation) (%.3f ms)" % process_avg)
		ranked.append("physics tick (Jolt + vehicle/ocean + traffic) (%.3f ms)" % physics_avg)
		ranked.append("node/orphan overhead (orphan_nodes=%.1f)" % (orphan_sum / n))
	return ranked


func _stats(values: Array) -> Dictionary:
	if values.is_empty():
		return {
			"count": 0,
			"min": -1.0,
			"mean": -1.0,
			"median": -1.0,
			"p90": -1.0,
			"p95": -1.0,
			"p99": -1.0,
			"max": -1.0,
		}
	var sorted := values.duplicate()
	sorted.sort()
	var count := sorted.size()
	var total := 0.0
	for v: float in sorted:
		total += v
	return {
		"count": count,
		"min": sorted[0],
		"mean": total / float(count),
		"median": _percentile(sorted, 0.50),
		"p90": _percentile(sorted, 0.90),
		"p95": _percentile(sorted, 0.95),
		"p99": _percentile(sorted, 0.99),
		"max": sorted[count - 1],
	}


func _percentile(sorted_values: Array, ratio: float) -> float:
	var n := sorted_values.size()
	if n == 0:
		return -1.0
	if n == 1:
		return sorted_values[0]
	var pos := ratio * float(n - 1)
	var low := int(floor(pos))
	var high := int(ceil(pos))
	if low == high:
		return sorted_values[low]
	var frac := pos - float(low)
	return lerpf(sorted_values[low], sorted_values[high], frac)


func _mean(values: Array) -> float:
	if values.is_empty():
		return -1.0
	var total := 0.0
	for v: float in values:
		total += v
	return total / float(values.size())


func _overs(wall_ms_values: Array) -> Dictionary:
	var o16 := 0
	var o20 := 0
	var o33 := 0
	for v: float in wall_ms_values:
		if v > FRAME_16_67_MS:
			o16 += 1
		if v > FRAME_20_MS:
			o20 += 1
		if v > FRAME_33_33_MS:
			o33 += 1
	var total := float(wall_ms_values.size())
	return {
		"16.67_count": o16,
		"16.67_pct": o16 / total * 100.0 if total > 0.0 else 0.0,
		"20_count": o20,
		"20_pct": o20 / total * 100.0 if total > 0.0 else 0.0,
		"33.33_count": o33,
		"33.33_pct": o33 / total * 100.0 if total > 0.0 else 0.0,
	}


func _top_spikes(wall_ms_values: Array, max_spikes: int) -> Array:
	var indexed: Array[Array] = []
	for i: int in range(wall_ms_values.size()):
		indexed.append([wall_ms_values[i], i])
	indexed.sort_custom(func(a: Array, b: Array) -> bool:
		return a[0] > b[0]
	)
	var spikes: Array = []
	for i: int in range(mini(max_spikes, indexed.size())):
		if (indexed[i][0] as float) > FRAME_16_67_MS:
			spikes.append({"frame_ms": indexed[i][0], "at_frame": indexed[i][1]})
	return spikes


func _snapshot_fingerprint() -> int:
	var parts := [
		GOLD_CITY_SCENE,
		str(Engine.physics_ticks_per_second),
		str(ProjectSettings.get_setting("renderer/rendering_method", "unknown")),
		str(ProjectSettings.get_setting("rendering_device/driver.windows", "unknown")),
		_mode,
		_graphics_quality_debug(),
	]
	return hash("|".join(parts))


func _graphics_quality_debug() -> String:
	var manager := get_node_or_null("/root/GraphicsQualityManager")
	if manager != null and manager.has_method("get_graphics_quality_debug_status"):
		return str(manager.get_graphics_quality_debug_status())
	return "n/a"


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
	var directory := ProjectSettings.globalize_path(OUTPUT_DIRECTORY)
	var absolute_directory := directory.replace("\\", "/")
	if DirAccess.make_dir_recursive_absolute(absolute_directory) != OK:
		return ""
	var timestamp := Time.get_datetime_string_from_system().replace(":", "-")
	var path := "%s/gold_city_phase_2a_%s_%s.json" % [absolute_directory, _label, timestamp]
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return ""
	file.store_string(JSON.stringify(_sanitize(report), "\t"))
	file.close()
	return ProjectSettings.localize_path(path)


func _fail(message: String) -> void:
	get_tree().paused = false
	push_error("%s FAIL: %s" % [PHASE_TAG, message])
	print("%s=FAIL %s" % [PHASE_TAG, message])
	get_tree().quit(1)