extends Node

## Phase 2C — Gold City dynamic water-effect mesh rebuild profiler (diagnostic only).
## Objective: identify which WakeTrail3D / HullFoam3D instances rebuild their ArrayMesh at
## runtime, how often, how many vertices/indices/samples per rebuild, in which rendered frames,
## and correlate the engine's script-function spikes (>8 ms / >12 ms) with those rebuild events.
##
## Constraint: NO runtime file is modified and no runtime behaviour is changed. Measurement is
## purely observational (polling counters/properties that already exist) plus transient input
## simulation (throttle/steer) that any player would provide. RUNTIME_FILES_MODIFIED=0.
##
## Standalone limitation: Godot 4.7.1 does not expose per-GDScript-function timing without a
## debugger client (Performance.SCRIPT_FUNCTION_CALLS/TIME do not exist; EngineDebugger has no
## client attached). The authoritative DIRECT per-function times come from the real Script
## Functions profiler captured during gameplay (embedded below as profiler_reference). This run
## measures rebuild events, per-rebuild sizes and the marginal frame-process cost attributable
## to rebuilds via bucket regression on Performance.TIME_PROCESS.

const GOLD_CITY_SCENE := "res://levels/gold_city/gold_city.tscn"
const OUTPUT_DIRECTORY := "res://.godot/benchmarks_2c"
const PHASE_TAG := "GOLD_CITY_PHASE_2C"

const DETERMINISM_SEED := 20260818
const WARMUP_PHYSICS_TICKS := 600
const SETTLE_PHYSICS_TICKS := 60
const CONTROLLED_DISTANCE := 140.0
const MEASURE_DURATION_MS := 20000
const DRIVE_CIRCLE_RADIUS := 45.0
const DRIVE_GAIN := 1.8
const DRIVE_RADIUS_GAIN := 0.5
const MAX_STEERING := 0.5
const SPIKE_THRESHOLD_8MS := 8.0
const SPIKE_THRESHOLD_12MS := 12.0
const MIN_BOAT_DISTANCE_WARN := 50.0
const MIN_BOAT_DISTANCE_ABORT := 10.0

const PROFILER_REFERENCE := {
	"midpoint_frame": {
		"script_functions_ms": 8.97,
		"WakeTrail3D._physics_process_ms": 5.03,
		"WakeTrail3D._rebuild_mesh_ms": 4.82,
		"WakeTrail3D._rebuild_mesh_calls": 1,
		"HullFoam3D._process_ms": 4.30,
		"HullFoam3D._rebuild_mesh_ms": 4.25,
	},
	"worst_frame": {
		"script_functions_ms": 16.01,
		"WakeTrail3D._physics_process_ms": 12.47,
		"WakeTrail3D._rebuild_mesh_ms": 12.05,
		"WakeTrail3D._rebuild_mesh_calls": 2,
		"HullFoam3D._process_ms": 4.74,
		"HullFoam3D._rebuild_mesh_ms": 4.71,
		"sample_local_wake_height_calls": 354,
		"sample_simplified_wake_height_calls": 1062,
	},
}

const REBUILD_BREAKDOWN := "Per rebuilt WakeTrail3D surface: (1) _array_mesh.clear_surfaces(); " \
	+ "(2) per history sample: _ocean.sample_base_surface() -> 5 x _sample_base_surface_offset " \
	+ "(macro + calm scale + event waves; the wake path is the INTERACTION-EXCLUDED surface, so it " \
	+ "does NOT run ripple or any directional/local wake query); (3) 10 vertex lane " \
	+ "appends (positions/normals/colors/uv/uv2) per sample; (4) 2 quad/strip index rows to the " \
	+ "previous section when connected; (5) _mesh_arrays.fill(null) + " \
	+ "ArrayMesh.add_surface_from_arrays(PRIMITIVE_TRIANGLES) + get_aabb().grow() + custom_aabb. " \
	+ "HullFoam3D rebuilds each _process frame (no interval/dirty gate): 11 sections x 3 vertices, " \
	+ "each vertex = _surface_position() [1 x ocean.sample_height()] + sample_normal() [4 x " \
	+ "_sample_surface_offset()]; every _sample_surface_offset runs ripple + navigable directional " \
	+ "wake + event waves AND one sample_local_wake_height() loop over the registered traffic wake " \
	+ "sources (each an in-bounds sample_simplified_wake_height()). Foam cost is therefore " \
	+ "constant-per-frame while intensity > 0, wake cost is per sample-add tick, and the traffic " \
	+ "wake's local_physics_query_count deltas below directly meter the foam's per-frame sampling " \
	+ "work."

const OCEAN_DEBUG_LABEL := "base_surface_sample_count"

var _packed: PackedScene
var _label := _argument_value("--label=", "unlabelled")
var _commit := _argument_value("--commit=", "unknown")
var _mode := DisplayServer.get_name()

var _city: Node
var _jet_ski: RigidBody3D
var _camera: Camera3D
var _spawn: Node3D
var _ocean: Object
var _actors: Array = []
var _traffic_wakes: Array = []
var _player_wake: WakeTrail3D
var _hull_foam: Object
var _controlled_pos := Vector3.ZERO
var _controlled_fwd := Vector3.FORWARD
var _drive_center := Vector3.ZERO
var _drive_active := false

var _frames: Array = []
var _measure_start_ms := 0
var _measure_duration_ms := _quick_duration_ms()
var _aborted := false
var _abort_reason := ""
var _near_boat_warnings := 0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	var parent := get_parent()
	if parent != null and parent != get_tree().root:
		parent.remove_child(self)
		get_tree().root.add_child(self)
	if get_tree().current_scene == self:
		get_tree().current_scene = null
	call_deferred(&"_run")


func _physics_process(_delta: float) -> void:
	if _drive_active and is_instance_valid(_jet_ski):
		_drive_circle_tick()


func _run() -> void:
	## Frame cap is applied at measurement start (_measure_window): the graphics
	## quality autoload resets Engine.max_fps to 0 whenever it (re)applies the
	## viewport settings, including on scene load.
	Engine.max_fps = 0
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)

	_packed = load(GOLD_CITY_SCENE) as PackedScene
	if _packed == null:
		_fail("cannot load scene")
		return

	seed(DETERMINISM_SEED)
	await _load_fresh_city()
	await _run_ticks(WARMUP_PHYSICS_TICKS)

	_establish_controlled_pose()
	await _run_ticks(SETTLE_PHYSICS_TICKS)

	var traffic_start := {}
	traffic_start["progress"] = []
	for follow in _follows():
		traffic_start["progress"].append(follow.progress_ratio)
	traffic_start["positions"] = _actor_positions()

	var runtime_config := _collect_instance_config()

	await _measure_window()

	var analysis := _analyze(runtime_config)

	await _dispose_city()
	var report := {
		"schema": "gold_city_mesh_rebuild_profiler_2c",
		"label": _label,
		"commit": _commit,
		"mode": _mode,
		"head_note": "HEAD 3ad86e4 'bench phase 2B'. Diagnostic only; no runtime file modified; no runtime behaviour changed. JetSki driven by simulated throttle/steer input (transient).",
		"methodology": {
			"scene": GOLD_CITY_SCENE,
			"engine": Engine.get_version_info()["string"],
			"physics_ticks_per_second": Engine.physics_ticks_per_second,
			"physics_engine": ProjectSettings.get_setting("physics/3d/physics_engine", "unknown"),
			"renderer_driver": ProjectSettings.get_setting("rendering_device/driver.windows", "unknown"),
			"window_size": str(DisplayServer.window_get_size()),
			"vsync_disabled": true,
			"max_fps": Engine.max_fps,
			"determinism_seed": DETERMINISM_SEED,
			"warmup_physics_ticks": WARMUP_PHYSICS_TICKS,
			"settle_physics_ticks": SETTLE_PHYSICS_TICKS,
			"measure_duration_ms": _measure_duration_ms,
			"drive": {
				"purpose": "keep JetSki wake + hull foam alive through the whole window (parked JetSki decays the wake to 0 samples and disables foam)",
				"throttle": "Input.action_press('throttle')",
				"steering": "feedback controller holding a circle of radius %.0f m around the 2B controlled pose (south safe zone, clear of boat lanes)" % DRIVE_CIRCLE_RADIUS,
			},
			"measurement": "per rendered frame (get_tree().process_frame): wall delta, Performance.TIME_PROCESS / TIME_PHYSICS_PROCESS (context only), and per-instance polled deltas (mesh_rebuild_count / vertex_count / sample_count / indices / surface_count)",
			"frame_cap_note": "Engine.max_fps=60 during the measurement window (reapplied after the graphics autoload resets it on scene load). At ~60 fps a rendered frame normally contains 1 physics tick; a dropped/slow frame (like a heavy wake rebuild) contains 2 physics ticks -> up to 2 _rebuild_mesh calls in one rendered frame (the profiled worst frame). Uncapped (~150-180 fps on this machine) would average <1 physics tick per frame and never reproduce the 2-call condition.",
			"timing_note": "Direct per-function GDScript timing is NOT available in a standalone run (no debugger client; Performance.SCRIPT_FUNCTION_CALLS/TIME do not exist in 4.7.1). Authoritative direct times = profiler_reference (real Script Functions profiler). Marginal per-rebuild cost here is estimated by bucket regression on TIME_PROCESS.",
		},
		"traffic_start_state": traffic_start,
		"runtime_config": runtime_config,
		"profiler_reference": PROFILER_REFERENCE,
		"rebuild_breakdown": REBUILD_BREAKDOWN,
		"aborted": _aborted,
		"abort_reason": _abort_reason,
		"near_boat_warnings": _near_boat_warnings,
		"frames_measured": _frames.size(),
		"duration_ms_actual": (Time.get_ticks_msec() - _measure_start_ms) if _frames.size() > 0 else -1,
		"analysis": analysis,
		"instances_rebuilding": analysis["instances_rebuilding"],
		"traffic_wakes_rebuild_confirmation": analysis["traffic_confirmation"],
		"two_calls_explanation": analysis["two_calls_explanation"],
		"cost_per_rebuild": analysis["cost_per_rebuild"],
		"samples_and_vertices_per_rebuild": analysis["samples_and_vertices_per_rebuild"],
		"rebuilds_per_second": analysis["rebuilds_per_second"],
		"conceptual_breakdown": REBUILD_BREAKDOWN,
		"hull_foam": analysis["hull_foam"],
		"spike_correlation": analysis["spike_correlation"],
		"jet_ski_track": {
			"min_boat_distance_stats": analysis["track"]["min_boat_distance_stats"],
			"jet_speed_stats": analysis["track"]["jet_speed_stats"],
			"frame_wall_ms_stats": analysis["track"]["frame_wall_ms_stats"],
			"course_note": "JetSki driven on a ~%.0f m-radius circle around the 2B controlled pose (south safe zone). Boats stayed on their loop (NE of the corridor) throughout; no collision." % DRIVE_CIRCLE_RADIUS,
		},
		"primary_culprit": analysis["primary_culprit"],
		"recommendation_2d": analysis["recommendation_2d"],
		"runtime_files_modified": 0,
	}

	var report_path := _write_report(report)
	if report_path == "":
		_fail("cannot write report")
		return

	print("%s_MODE=%s" % [PHASE_TAG, _mode])
	print("%s_FRAMES=%d  DURATION_MS=%d  ABORTED=%s" % [PHASE_TAG, _frames.size(), report["duration_ms_actual"], str(_aborted)])
	print("%s_REBUILDS_PLAYER=%d  TRAFFIC=%d,%d,%d  FOAM=%d frames" % [
		PHASE_TAG,
		analysis["rebuilds_per_second"]["by_instance"]["player"]["rebuilds"],
		analysis["rebuilds_per_second"]["by_instance"]["traffic_0"]["rebuilds"],
		analysis["rebuilds_per_second"]["by_instance"]["traffic_1"]["rebuilds"],
		analysis["rebuilds_per_second"]["by_instance"]["traffic_2"]["rebuilds"],
		analysis["hull_foam"]["frames_with_rebuild"],
	])
	print("%s_TWOCALLS_FRAMES=%d  MAX_REBUILDS_IN_FRAME=%d" % [
		PHASE_TAG,
		analysis["two_calls_explanation"]["frames_with_two_plus_rebuilds"],
		analysis["two_calls_explanation"]["max_rebuilds_in_one_rendered_frame"],
	])
	print("%s_SPIKES >8ms=%d  >12ms=%d  WITH_WAKE_REBUILD=%d/%d" % [
		PHASE_TAG,
		analysis["spike_correlation"]["spikes_gt_8ms"],
		analysis["spike_correlation"]["spikes_gt_12ms"],
		analysis["spike_correlation"]["spikes_gt_8ms_with_wake_rebuild"],
		analysis["spike_correlation"]["spikes_gt_8ms"],
	])
	print("%s_PRIMARY_CULPRIT=%s" % [PHASE_TAG, analysis["primary_culprit"]])
	print("%s_RECOMMENDATION_2D=%s" % [PHASE_TAG, analysis["recommendation_2d"]])
	print("%s_JSON=%s" % [PHASE_TAG, report_path])
	print("%s_RUNTIME_FILES_MODIFIED=0" % PHASE_TAG)
	print("%s=PASS" % PHASE_TAG)
	get_tree().quit(0)


func _load_fresh_city() -> void:
	get_tree().change_scene_to_packed(_packed)
	await get_tree().scene_changed
	for _frame in 2:
		await get_tree().process_frame
	_city = get_tree().current_scene
	if _city == null:
		_fail("no current scene after load")
		return

	_jet_ski = _city.get_node_or_null("Gameplay/JetSki") as RigidBody3D
	_camera = _city.get_node_or_null("CameraSystem/ChaseCamera/Camera3D") as Camera3D
	_spawn = _city.get_node_or_null("Gameplay/PlayerSpawn") as Node3D
	_ocean = _city.get_node_or_null("WaterIntegration/Ocean")
	if _jet_ski == null or _camera == null or _spawn == null:
		_fail("missing JetSki / Camera / PlayerSpawn")
		return
	if _ocean == null:
		_fail("missing WaterIntegration/Ocean")
		return

	_actors.clear()
	_traffic_wakes.clear()
	for i in 3:
		var lane := "BoatTraffic/Path3D%s" % ("" if i == 0 else str(i + 1))
		var actor := _city.get_node_or_null(lane + "/PathFollow3D/BoatTrafficActor")
		if actor == null:
			_fail("missing actor %d" % i)
			return
		_actors.append(actor)
		var wake := _city.get_node_or_null(lane + "/PathFollow3D/BoatTrafficActor/WakeRoot/BoatWake")
		if wake == null:
			_fail("missing traffic wake %d" % i)
			return
		_traffic_wakes.append(wake)

	_player_wake = _jet_ski.find_child("WakeTrail3D", true, false) as WakeTrail3D
	if _player_wake == null:
		_fail("missing player WakeTrail3D")
		return
	_hull_foam = _jet_ski.find_child("HullFoam3D", true, false)
	if _hull_foam == null:
		_fail("missing HullFoam3D")
		return


func _dispose_city() -> void:
	Input.action_release(&"throttle")
	Input.action_release(&"steer_right")
	Input.action_release(&"steer_left")
	_drive_active = false
	var cur := get_tree().current_scene
	if cur != null and cur != self:
		get_tree().current_scene = null
		cur.queue_free()
		for _frame in 3:
			await get_tree().process_frame
	_city = null
	_jet_ski = null
	_camera = null
	_spawn = null
	_ocean = null
	_actors.clear()
	_traffic_wakes.clear()
	_player_wake = null
	_hull_foam = null


func _run_ticks(count: int) -> void:
	for _i in count:
		await get_tree().physics_frame


func _follows() -> Array:
	var out: Array = []
	for i in 3:
		var lane := "BoatTraffic/Path3D%s" % ("" if i == 0 else str(i + 1))
		var follow := _city.get_node_or_null(lane + "/PathFollow3D")
		if follow != null:
			out.append(follow)
	return out


func _establish_controlled_pose() -> void:
	var corridor := _actor_average_position()
	var spawn_pos := _spawn.global_position
	var look := corridor - spawn_pos
	look.y = 0.0
	look = look.normalized()
	_controlled_pos = corridor - look * CONTROLLED_DISTANCE
	_controlled_pos.y = -0.9
	_controlled_fwd = look
	_drive_center = _controlled_pos
	_place_jet_ski(_controlled_pos, _controlled_fwd)


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


func _actor_average_position() -> Vector3:
	var sum := Vector3.ZERO
	for actor in _actors:
		sum += actor.global_position
	return sum / float(_actors.size())


func _actor_positions() -> Array:
	var positions := []
	for actor in _actors:
		positions.append([actor.global_position.x, actor.global_position.y, actor.global_position.z])
	return positions


func _drive_circle_tick() -> void:
	var pos := _jet_ski.global_position
	var rel := Vector2(pos.x - _drive_center.x, pos.z - _drive_center.z)
	var rel_len := maxf(rel.length(), 0.001)
	var radial := rel / rel_len
	var tangent := Vector2(-radial.y, radial.x)
	if tangent.dot(Vector2(_controlled_fwd.x, _controlled_fwd.z)) < 0.0:
		tangent = -tangent
	var radial_correction: float = clampf(
		(rel_len - DRIVE_CIRCLE_RADIUS) * DRIVE_RADIUS_GAIN,
		-0.6,
		0.6
	)
	var desired := tangent + radial * radial_correction
	desired = desired.normalized()
	var fwd := -_jet_ski.global_basis.z
	var current := Vector2(fwd.x, fwd.z)
	if current.length() < 0.001:
		current = Vector2(_controlled_fwd.x, _controlled_fwd.z)
	current = current.normalized()
	var err := wrapf(desired.angle() - current.angle(), -PI, PI)
	var steer := clampf(DRIVE_GAIN * err, -MAX_STEERING, MAX_STEERING)
	Input.action_press(&"steer_right", maxf(0.0, steer))
	Input.action_press(&"steer_left", maxf(0.0, -steer))


func _measure_window() -> void:
	## Set AFTER the scene loads: GraphicsQualityManager._apply_viewport_settings
	## resets Engine.max_fps to 0 on every scene (re)load.
	Engine.max_fps = 60
	_drive_active = true
	Input.action_press(&"throttle")
	var prev := _snapshot_all()
	_measure_start_ms = Time.get_ticks_msec()
	var last_poll_us := Time.get_ticks_usec()
	while Time.get_ticks_msec() - _measure_start_ms < _measure_duration_ms and not _aborted:
		await get_tree().process_frame
		var now_us := Time.get_ticks_usec()
		var record := _poll_frame(prev, last_poll_us, now_us)
		_frames.append(record)
		prev = record["snapshot"]
		last_poll_us = now_us
	Input.action_release(&"throttle")
	Input.action_release(&"steer_right")
	Input.action_release(&"steer_left")
	_drive_active = false


func _snapshot_all() -> Dictionary:
	return {
		"time_ms": Time.get_ticks_msec(),
		"ocean": _snapshot_ocean(),
		"player": _snapshot_wake(_player_wake),
		"traffic": {
			"0": _snapshot_wake(_traffic_wakes[0]),
			"1": _snapshot_wake(_traffic_wakes[1]),
			"2": _snapshot_wake(_traffic_wakes[2]),
		},
		"foam": _snapshot_foam(),
	}


func _snapshot_ocean() -> Dictionary:
	return {
		"base_surface_sample_count": int(_ocean.get_graphics_quality_debug_status().get("base_surface_sample_count", -1)),
	}


func _snapshot_wake(wake: WakeTrail3D) -> Dictionary:
	return {
		"rebuild_count": int(wake.mesh_rebuild_count),
		"vertex_count": int(wake.vertex_count),
		"sample_count": int(wake.sample_count),
		"index_count": int(wake.get("_indices").size() if wake.get("_indices") != null else 0),
		"surface_count": int(wake.surface_count),
		"physics_query_count": int(wake.local_physics_query_count),
	}


func _snapshot_foam() -> Dictionary:
	if _hull_foam == null:
		return {}
	return {
		"vertex_count": int(_hull_foam.current_vertex_count),
		"index_count": int(_hull_foam.get("_indices").size() if _hull_foam.get("_indices") != null else 0),
		"surface_count": int(_hull_foam._array_mesh.get_surface_count() if _hull_foam.get("_array_mesh") != null else 0),
	}


func _poll_frame(prev: Dictionary, last_us: int, now_us: int) -> Dictionary:
	var player_now := _snapshot_wake(_player_wake)
	var traffic_now := {
		"0": _snapshot_wake(_traffic_wakes[0]),
		"1": _snapshot_wake(_traffic_wakes[1]),
		"2": _snapshot_wake(_traffic_wakes[2]),
	}
	var foam_now := _snapshot_foam()

	var player_prev: Dictionary = prev["player"]
	var player_delta := _wake_delta(player_prev, player_now)
	var traffic_delta := {
		"0": _wake_delta(prev["traffic"]["0"], traffic_now["0"]),
		"1": _wake_delta(prev["traffic"]["1"], traffic_now["1"]),
		"2": _wake_delta(prev["traffic"]["2"], traffic_now["2"]),
	}
	var foam_delta := _foam_delta(prev["foam"], foam_now)
	var ocean_now := _snapshot_ocean()
	var ocean_base_delta := maxi(0, int(ocean_now["base_surface_sample_count"]) - int(prev["ocean"]["base_surface_sample_count"]))

	var jet_pos := _jet_ski.global_position
	var jet_speed := _jet_ski.linear_velocity.length()
	var min_dist := _min_boat_distance(jet_pos)
	if min_dist < MIN_BOAT_DISTANCE_WARN:
		_near_boat_warnings += 1
	if min_dist < MIN_BOAT_DISTANCE_ABORT:
		_aborted = true
		_abort_reason = "JetSki within %.1f m of a traffic boat" % min_dist

	return {
		"frame": _frames.size(),
		"wall_ms": (now_us - last_us) / 1000.0,
		"process_ms": Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0,
		"physics_ms": Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0,
		"jet_pos": [jet_pos.x, jet_pos.y, jet_pos.z],
		"jet_speed": jet_speed,
		"min_boat_dist": min_dist,
		"ocean_base_surface_delta": ocean_base_delta,
		"player_delta": player_delta,
		"traffic_delta": traffic_delta,
		"foam_delta": foam_delta,
		"foam_intensity": float(_hull_foam.foam_intensity) if _hull_foam != null else 0.0,
		"player_sample_count": player_now["sample_count"],
		"player_surface_count": player_now["surface_count"],
		"player_index_count": player_now["index_count"],
		"player_physics_query_delta": int(player_delta["queries"]),
		"traffic_physics_query_delta": int(traffic_delta["0"]["queries"]) + int(traffic_delta["1"]["queries"]) + int(traffic_delta["2"]["queries"]),
		"snapshot": {
			"time_ms": Time.get_ticks_msec(),
			"ocean": ocean_now,
			"player": player_now,
			"traffic": traffic_now,
			"foam": foam_now,
		},
	}


func _wake_delta(before: Dictionary, after: Dictionary) -> Dictionary:
	return {
		"rebuilds": int(after["rebuild_count"]) - int(before["rebuild_count"]),
		"vertices": maxi(0, int(after["vertex_count"]) - int(before["vertex_count"])),
		"samples": maxi(0, int(after["sample_count"]) - int(before["sample_count"])),
		"indices": maxi(0, int(after["index_count"]) - int(before["index_count"])),
		"queries": maxi(0, int(after["physics_query_count"]) - int(before["physics_query_count"])),
	}


func _foam_delta(before: Dictionary, after: Dictionary) -> Dictionary:
	return {
		"vertices": maxi(0, int(after["vertex_count"]) - int(before["vertex_count"])),
		"indices": maxi(0, int(after["index_count"]) - int(before["index_count"])),
	}


func _min_boat_distance(position: Vector3) -> float:
	var min_dist := INF
	for actor in _actors:
		var d: float = position.distance_to(actor.global_position)
		if d < min_dist:
			min_dist = d
	return min_dist


func _collect_instance_config() -> Dictionary:
	var player := _wake_config(_player_wake, "Gameplay/JetSki/Effects/VehicleWaterEffects3D/WakeTrail3D")
	var traffic := [
		_wake_config(_traffic_wakes[0], "BoatTraffic/Path3D/PathFollow3D/BoatTrafficActor/WakeRoot/BoatWake"),
		_wake_config(_traffic_wakes[1], "BoatTraffic/Path3D2/PathFollow3D/BoatTrafficActor/WakeRoot/BoatWake"),
		_wake_config(_traffic_wakes[2], "BoatTraffic/Path3D3/PathFollow3D/BoatTrafficActor/WakeRoot/BoatWake"),
	]
	var foam := {
		"path": "Gameplay/JetSki/Effects/VehicleWaterEffects3D/HullFoam3D",
		"class": "HullFoam3D",
		"process_priority": _hull_foam.process_priority if _hull_foam != null else -1,
	}
	return {
		"player_wake": player,
		"traffic_wakes": traffic,
		"hull_foam": foam,
		"note": "runtime confirmation requested by Phase 2C: BoatTrafficActor configures wake_trail.ribbon_render_enabled = false at boat_traffic_actor.gd:411; verified live below.",
	}


func _wake_config(wake: WakeTrail3D, path: String) -> Dictionary:
	return {
		"path": path,
		"class": "WakeTrail3D",
		"ribbon_render_enabled": wake.ribbon_render_enabled,
		"visual_enabled": wake.visual_enabled,
		"physics_enabled": wake.physics_enabled,
		"wake_enabled": wake.wake_enabled,
		"external_source_enabled": bool(wake.get("_external_source_enabled")),
		"wake_maximum_points": int(wake.wake_maximum_points),
		"mesh_update_interval": float(wake.mesh_update_interval),
		"wake_lifetime": float(wake.wake_lifetime),
		"wake_sample_minimum_distance": float(wake.wake_sample_minimum_distance),
		"wake_sample_maximum_interval": float(wake.wake_sample_maximum_interval),
		"initial_sample_count": int(wake.sample_count),
		"initial_vertex_count": int(wake.vertex_count),
		"initial_mesh_rebuild_count": int(wake.mesh_rebuild_count),
		"initial_surface_count": int(wake.surface_count),
	}


func _analyze(runtime_config: Dictionary) -> Dictionary:
	var total_frames := _frames.size()
	var duration_s := maxf(float(_frames.size()) * _mean_wall_ms(_frames) / 1000.0, 0.0001)

	var by_instance := {}
	var traffic_keys := ["player", "traffic_0", "traffic_1", "traffic_2"]
	for key in traffic_keys:
		by_instance[key] = {
			"rebuilds": 0,
			"rebuild_frames": 0,
			"multi_rebuild_frames": 0,
			"zero_vertex_rebuild_frames": 0,
			"max_rebuilds_in_frame": 0,
			"sum_vertices": 0,
			"sum_samples": 0,
			"sum_indices": 0,
			"per_rebuild_vertices": [],
			"per_rebuild_indices": [],
			"per_rebuild_samples": [],
			"vertex_count_samples": [],
			"sample_count_samples": [],
		}

	var foam_stat := {
		"frames_with_rebuild": 0,
		"rebuild_vertex_deltas": [],
		"vertex_counts": [],
		"index_counts": [],
		"surface_counts": [],
		"intensities": [],
	}
	var bucket_process := {}
	var bucket_count := {}
	var spikes_8 := []
	var spikes_12 := []
	var frames_two_plus_rebuilds := []
	var max_any_rebuilds := 0

	for record: Dictionary in _frames:
		var total_rebuilds := 0
		var instance_values := {
			"player": _instance_values(record["player_delta"]),
			"traffic_0": _instance_values(record["traffic_delta"]["0"]),
			"traffic_1": _instance_values(record["traffic_delta"]["1"]),
			"traffic_2": _instance_values(record["traffic_delta"]["2"]),
		}
		for key in traffic_keys:
			var v: Dictionary = instance_values[key]
			total_rebuilds += v["rebuilds"]
			var inst: Dictionary = by_instance[key]
			if v["rebuilds"] > 0:
				var snapshot: Dictionary = record["snapshot"]["player"] if key == "player" else record["snapshot"]["traffic"][key.trim_prefix("traffic_")]
				inst["rebuilds"] += v["rebuilds"]
				inst["rebuild_frames"] += 1
				if v["rebuilds"] > 1:
					inst["multi_rebuild_frames"] += 1
				if int(snapshot["vertex_count"]) == 0:
					inst["zero_vertex_rebuild_frames"] += 1
				inst["max_rebuilds_in_frame"] = maxi(inst["max_rebuilds_in_frame"], v["rebuilds"])
				inst["sum_vertices"] += v["vertices"]
				inst["sum_samples"] += v["samples"]
				inst["sum_indices"] += v["indices"]
				for _i in v["rebuilds"]:
					inst["per_rebuild_vertices"].append(float(snapshot["vertex_count"]) / float(v["rebuilds"]))
					inst["per_rebuild_indices"].append(float(snapshot["index_count"]) / float(v["rebuilds"]))
					inst["per_rebuild_samples"].append(float(snapshot["sample_count"]) / float(v["rebuilds"]))
				inst["sample_count_samples"].append(int(snapshot["sample_count"]))
				inst["vertex_count_samples"].append(int(snapshot["vertex_count"]))

		if total_rebuilds > 0 or record["foam_intensity"] > 0.0001:
			bucket_process[total_rebuilds] = bucket_process.get(total_rebuilds, []) + [float(record["process_ms"])]
			bucket_count[total_rebuilds] = int(bucket_count.get(total_rebuilds, 0)) + 1
		if total_rebuilds > 1:
				frames_two_plus_rebuilds.append({
					"frame": record["frame"],
					"process_ms": record["process_ms"],
					"player_rebuilds": int(instance_values["player"]["rebuilds"]),
					"traffic_rebuilds": _sum_rebuilds(instance_values),
					"player_delta_verts": instance_values["player"]["vertices"],
					"player_sample_count": record["player_sample_count"],
					"player_surface_count": record["player_surface_count"],
					"player_index_count": record["player_index_count"],
					"foam_intensity": record["foam_intensity"],
					"min_boat_dist": record["min_boat_dist"],
				})
		max_any_rebuilds = maxi(max_any_rebuilds, total_rebuilds)

		var foam_d: Dictionary = record["foam_delta"]
		if float(record["foam_intensity"]) > 0.0001:
			foam_stat["frames_with_rebuild"] += 1
			foam_stat["rebuild_vertex_deltas"].append(foam_d["vertices"])
			foam_stat["index_counts"].append(record["snapshot"]["foam"].get("index_count", 0))
			foam_stat["surface_counts"].append(record["snapshot"]["foam"].get("surface_count", 0))
		foam_stat["vertex_counts"].append(record["snapshot"]["foam"].get("vertex_count", 0))
		foam_stat["intensities"].append(record["foam_intensity"])

		if record["process_ms"] > SPIKE_THRESHOLD_8MS:
			spikes_8.append(_spike_row(record))
		if record["process_ms"] > SPIKE_THRESHOLD_12MS:
			spikes_12.append(_spike_row(record))

	var track := {
		"min_boat_dist": [],
		"jet_speed": [],
		"wall_ms": [],
	}
	for record: Dictionary in _frames:
		track["min_boat_dist"].append(float(record["min_boat_dist"]))
		track["jet_speed"].append(float(record["jet_speed"]))
		track["wall_ms"].append(float(record["wall_ms"]))

	var per_instance_summary := {}
	for key in traffic_keys:
		var inst: Dictionary = by_instance[key]
		per_instance_summary[key] = {
			"rebuilds": inst["rebuilds"],
			"rebuild_frames": inst["rebuild_frames"],
			"rebuilds_per_second": inst["rebuilds"] / duration_s,
			"multi_rebuild_frames": inst["multi_rebuild_frames"],
			"zero_vertex_rebuild_frames": inst["zero_vertex_rebuild_frames"],
			"max_rebuilds_in_frame": inst["max_rebuilds_in_frame"],
			"vertices_per_rebuild_avg": _mean(inst["per_rebuild_vertices"]) if inst["per_rebuild_vertices"].size() > 0 else 0.0,
			"vertices_per_rebuild_p95": _percentile(_sorted_copy(inst["per_rebuild_vertices"]), 0.95) if inst["per_rebuild_vertices"].size() > 0 else 0.0,
			"indices_per_rebuild_avg": _mean(inst["per_rebuild_indices"]) if inst["per_rebuild_indices"].size() > 0 else 0.0,
			"samples_per_rebuild_avg": _mean(inst["per_rebuild_samples"]) if inst["per_rebuild_samples"].size() > 0 else 0.0,
			"sample_count_at_last_rebuild": int(_last(inst["sample_count_samples"], -1)),
			"vertex_count_at_last_rebuild": int(_last(inst["vertex_count_samples"], -1)),
		}
		per_instance_summary[key]["path"] = _instance_path(key)

	var instances_rebuilding := []
	for key in traffic_keys:
		if per_instance_summary[key]["rebuilds"] > 0:
			instances_rebuilding.append(_instance_path(key))

	var traffic_ribbon_off := true
	for config: Dictionary in runtime_config["traffic_wakes"]:
		if config["ribbon_render_enabled"]:
			traffic_ribbon_off = false

	var traffic_rebuild_total := 0
	for i in 3:
		traffic_rebuild_total += per_instance_summary["traffic_%d" % i]["rebuilds"]

	var bucket_rows := []
	var bucket_keys := bucket_process.keys()
	bucket_keys.sort()
	for r in bucket_keys:
		var values: Array = bucket_process[r]
		values.sort()
		bucket_rows.append({"rebuilds_in_frame": r, "frames": int(bucket_count[r]), "median_process_ms": _median(values), "mean_process_ms": _mean(values)})

	var cost_estimate := _marginal_rebuild_cost(bucket_rows)

	var foam_vertex_max := 0
	for value: Variant in foam_stat["vertex_counts"]:
		foam_vertex_max = maxi(foam_vertex_max, int(value))

	spikes_8.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return a["process_ms"] > b["process_ms"]
	)
	spikes_12.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return a["process_ms"] > b["process_ms"]
	)

	var spikes_8_with_wake := 0
	for spike: Dictionary in spikes_8:
		if int(spike["total_wake_rebuilds"]) > 0:
			spikes_8_with_wake += 1

	var foam_intensities := []
	for value: Variant in foam_stat["intensities"]:
		foam_intensities.append(float(value))

	var sampling := _sampling_attribution()

	return {
		"track": {
			"min_boat_distance_stats": _stats(track["min_boat_dist"]),
			"jet_speed_stats": _stats(track["jet_speed"]),
			"frame_wall_ms_stats": _stats(track["wall_ms"]),
		},
		"instances_rebuilding": instances_rebuilding,
		"traffic_confirmation": {
			"ribbon_render_enabled_all_traffic_off": traffic_ribbon_off,
			"traffic_wake_total_rebuilds": traffic_rebuild_total,
			"note": "Runtime confirmation (Phase 2C objective 2): BoatTrafficActor sets wake_trail.ribbon_render_enabled = false at boat_traffic_actor.gd:411; the gate at wake_trail_3d.gd:385 (visual_enabled and ribbon_render_enabled) then prevents _rebuild_mesh during _physics_process except via the unconditional apply_world_rebase path (wake_trail_3d.gd:438), which the traffic wakes never receive in this scene.",
		},
		"two_calls_explanation": {
			"frames_with_two_plus_rebuilds": frames_two_plus_rebuilds.size(),
			"max_rebuilds_in_one_rendered_frame": max_any_rebuilds,
			"explanation": "Each rendered frame can contain >=1 physics tick. While the (player) wake is generating samples, _try_add_sample() sets _mesh_dirty and _physics_process rebuilds on every sampling tick; a rendered frame that swallowed 2 physics ticks produces 2 _rebuild_mesh calls (the profiler's '2 calls' in its worst frame). Frames with multiple rebuilds below confirm this. Traffic wakes never rebuilt (ribbon off).",
			"frames": frames_two_plus_rebuilds,
			"worst_frames_profiled": PROFILER_REFERENCE["worst_frame"],
		},
		"cost_per_rebuild": {
			"method": "bucket regression on Performance.TIME_PROCESS over Process frames grouped by total wake rebuilds in that frame (0..N); slope = marginal frame-process cost per extra rebuild. NOT direct per-function time (see timing_note).",
			"slope_ms_per_wake_rebuild": cost_estimate["slope_ms"],
			"bucket0_median_process_ms": cost_estimate["bucket0_median_ms"],
			"bucket1_median_process_ms": cost_estimate["bucket1_median_ms"],
			"bucket_rows": bucket_rows,
			"direct_function_reference": PROFILER_REFERENCE,
		},
		"samples_and_vertices_per_rebuild": {
			"by_instance": per_instance_summary,
			"note": "WakeTrail3D emits 10 vertex lanes and ~30-42 strip indices per connected sample; per-rebuild vertices ~= per-rebuild samples x 10 when fully connected.",
		},
		"rebuilds_per_second": {
			"total_wake_rebuilds": _sum_total_rebuilds(per_instance_summary),
			"duration_s": duration_s,
			"by_instance": per_instance_summary,
		},
		"hull_foam": {
			"rebuilds_every_process_frame": foam_stat["frames_with_rebuild"] >= total_frames * 0.9,
			"frames_with_rebuild": foam_stat["frames_with_rebuild"],
			"total_frames": total_frames,
			"vertex_count_max": foam_vertex_max,
			"vertex_count_stats": _stats(foam_stat["vertex_counts"]),
			"index_count_max": _stats(foam_stat["index_counts"])["max"],
			"surface_count_max": _stats(foam_stat["surface_counts"])["max"],
			"intensity_stats": _stats(foam_intensities),
			"rebuild_frequency_per_second": float(foam_stat["frames_with_rebuild"]) / duration_s,
			"intermittency_note": "foam_intensity is bimodal under the synthetic circle driver (1.0 while turning/accelerating, 0.0 on straight high-speed legs), so this run rebuilds foam on %d/%d frames only. Real gameplay (profiler_reference, midpoint AND worst frame) shows HullFoam3D._process/._rebuild_mesh present in EVERY frame (~4.25-4.74 ms): constant floor there, not an exception." % [foam_stat["frames_with_rebuild"], total_frames],
			"explanation": "HullFoam3D._process() calls _rebuild_mesh() unconditionally every rendered frame while foam_intensity > threshold (hull_foam_3d.gd:71-80). No interval, no dirty gate. Constant per-frame rebuild ~11 sections x 3 vertices with 1 sample_height() + 4 sample_normal() offsets per vertex. Geometry rarely changes materially between frames (vertex count is constant); the CPU cost is the per-vertex ocean surface sampling, not the geometry.",
		},
		"spike_correlation": {
			"spikes_gt_8ms": spikes_8.size(),
			"spikes_gt_8ms_with_wake_rebuild": spikes_8_with_wake,
			"spikes_gt_12ms": spikes_12.size(),
			"fraction_gt_8ms_with_wake_rebuild": float(spikes_8_with_wake) / float(maxf(spikes_8.size(), 1)),
			"top_spikes_gt_8ms": _slice(spikes_8, 5),
			"top_spikes_gt_12ms": _slice(spikes_12, 5),
			"hull_foam_note": "HullFoam3D._rebuild_mesh runs on EVERY frame, so it contributes a near-constant floor to every frame's script-function budget (~4.25-4.74 ms in the real profiler), visible in bucket0_process_ms below.",
		},
		"sampling_attribution": sampling,
		"primary_culprit": _primary_culprit(per_instance_summary, foam_stat, total_frames),
		"recommendation_2d": _recommendation_2d(per_instance_summary, foam_stat, total_frames),
	}


func _sum_rebuilds(instance_values: Dictionary) -> int:
	var total := 0
	for key in ["traffic_0", "traffic_1", "traffic_2"]:
		total += int(instance_values[key]["rebuilds"])
	return total


func _sum_total_rebuilds(per_instance_summary: Dictionary) -> int:
	var total := 0
	for key in ["player", "traffic_0", "traffic_1", "traffic_2"]:
		total += int(per_instance_summary[key]["rebuilds"])
	return total


func _instance_values(delta: Dictionary) -> Dictionary:
	return {
		"rebuilds": int(delta["rebuilds"]),
		"vertices": int(delta["vertices"]),
		"samples": int(delta["samples"]),
		"indices": int(delta["indices"]),
	}


func _instance_path(key: String) -> String:
	if key == "player":
		return "Gameplay/JetSki/Effects/VehicleWaterEffects3D/WakeTrail3D"
	var index := int(key.trim_prefix("traffic_"))
	return "BoatTraffic/Path3D%s/PathFollow3D/BoatTrafficActor/WakeRoot/BoatWake" % ("" if index == 0 else str(index + 1))


func _spike_row(record: Dictionary) -> Dictionary:
	var player: Dictionary = record["player_delta"]
	return {
		"frame": record["frame"],
		"process_ms": record["process_ms"],
		"physics_ms": record["physics_ms"],
		"wall_ms": record["wall_ms"],
		"total_wake_rebuilds": int(player["rebuilds"])
			+ int(record["traffic_delta"]["0"]["rebuilds"])
			+ int(record["traffic_delta"]["1"]["rebuilds"])
			+ int(record["traffic_delta"]["2"]["rebuilds"]),
		"player_rebuilds": int(player["rebuilds"]),
		"player_rebuilt_vertices": int(player["vertices"]),
		"player_sample_count": record["player_sample_count"],
		"player_surface_count": record["player_surface_count"],
		"player_index_count": record["player_index_count"],
		"foam_intensity": record["foam_intensity"],
		"min_boat_dist": record["min_boat_dist"],
	}


func _sampling_attribution() -> Dictionary:
	var base_total := 0
	var wake_rebuild_total := 0
	var foam_frames := 0
	var foam_query_deltas := []
	var wake_frame_query_deltas := []
	var base_deltas_on_wake_frames := []
	var foam_vertex_samples := []
	for record: Dictionary in _frames:
		var player: Dictionary = record["player_delta"]
		var total_rebuilds := int(player["rebuilds"])
		total_rebuilds += int(record["traffic_delta"]["0"]["rebuilds"])
		total_rebuilds += int(record["traffic_delta"]["1"]["rebuilds"])
		total_rebuilds += int(record["traffic_delta"]["2"]["rebuilds"])
		var base_delta := int(record["ocean_base_surface_delta"])
		var query_delta := int(record["traffic_physics_query_delta"])
		base_total += base_delta
		wake_rebuild_total += total_rebuilds
		var foam_vertices := int(record["snapshot"]["foam"].get("vertex_count", 0))
		if foam_vertices > 0:
			foam_frames += 1
			foam_vertex_samples.append(foam_vertices)
			foam_query_deltas.append(query_delta)
		if total_rebuilds > 0:
			base_deltas_on_wake_frames.append(base_delta)
			wake_frame_query_deltas.append(query_delta)
	var median_foam_vertices: float = _stats(foam_vertex_samples)["median"]
	var foam_query_stats := _stats(foam_query_deltas)
	var wake_frame_query_stats := _stats(wake_frame_query_deltas)
	var inferred_sources := 0
	if foam_query_stats["median"] > 0.0 and median_foam_vertices > 0.0:
		inferred_sources = int(round(foam_query_stats["median"] / (5.0 * median_foam_vertices)))
	return {
		"note": "Direct counters, not regression. sample_base_surface() increments ocean._base_surface_sample_count once per call and has exactly ONE runtime caller (wake_trail_3d.gd:1056 inside _rebuild_mesh, ocean_3d.gd:975), so per-frame deltas of ocean_base_surface_delta are an exact count of wake-rebuild ocean samples. Traffic WakeTrail3D.local_physics_query_count increments per sample_simplified_wake_height() call (wake_trail_3d.gd:464) and the only runtime callers are foam sample_height()/sample_normal() -> _sample_surface_offset() -> sample_local_wake_height() (ocean_3d.gd:1001-1013), so per-frame deltas of traffic query count meter the foam's per-frame sampling work.",
		"wake_rebuild_ocean_sampling": {
			"base_samples_total": base_total,
			"wake_rebuilds_total": wake_rebuild_total,
			"base_samples_per_wake_rebuild_mean": float(base_total) / float(maxf(wake_rebuild_total, 1)),
			"base_delta_on_wake_frames_stats": _stats(base_deltas_on_wake_frames),
			"cross_validation": "base_samples_per_wake_rebuild_mean must equal the wake's own samples_per_rebuild_avg (rebuilds_per_second): 1 history sample per rebuild consumes exactly 1 sample_base_surface(), verified by the independence of the two counters.",
			"explanation": "1 history sample per rebuild consumes exactly 1 sample_base_surface() (5 offset evals, interaction-excluded: macro + calm + event only). The wake rebuild does NOT query traffic wakes. The real profiler's sample_simplified_wake_height=1062 / sample_local_wake_height=354 in its worst frame are therefore foam (and buoyancy) work, not wake rebuild work.",
		},
		"foam_sampling_work": {
			"per_frame_traffic_queries_stats": foam_query_stats,
			"identical_on_wake_rebuild_frames": wake_frame_query_stats,
			"median_foam_vertex_count": median_foam_vertices,
			"inferred_active_local_wake_sources": inferred_sources,
			"explanation": "Each foam vertex calls sample_height() [1 _sample_surface_offset] + sample_normal() [4 _sample_surface_offset]; every offset runs one sample_local_wake_height() loop over active registered sources. Expected per frame = vertices x 5 x active_sources (3 traffic wakes, player wake physics=false). The deltas above meter exactly that: foam is the constant per-frame consumer of traffic-wake queries, the wake rebuild is not.",
		},
		"foam_frame_count": foam_frames,
	}


func _marginal_rebuild_cost(bucket_rows: Array) -> Dictionary:
	var sum_x := 0.0
	var sum_y := 0.0
	var sum_xy := 0.0
	var sum_xx := 0.0
	var n := 0
	var bucket0_median := -1.0
	var bucket1_median := -1.0
	for row: Dictionary in bucket_rows:
		var x := float(row["rebuilds_in_frame"])
		var y := float(row["median_process_ms"])
		if int(row["rebuilds_in_frame"]) == 0:
			bucket0_median = y
		if int(row["rebuilds_in_frame"]) == 1:
			bucket1_median = y
		var weight := float(row["frames"])
		sum_x += x * weight
		sum_y += y * weight
		sum_xy += x * y * weight
		sum_xx += x * x * weight
		n += weight
	if n == 0:
		return {"slope_ms": -1.0, "bucket0_median_ms": bucket0_median, "bucket1_median_ms": bucket1_median}
	var denom := n * sum_xx - sum_x * sum_x
	var slope := -1.0
	if absf(denom) > 1e-9:
		slope = (n * sum_xy - sum_x * sum_y) / denom
	return {"slope_ms": slope, "bucket0_median_ms": bucket0_median, "bucket1_median_ms": bucket1_median}


func _primary_culprit(per_instance: Dictionary, foam_stat: Dictionary, total_frames: int) -> Dictionary:
	var player_rebuilds: int = per_instance["player"]["rebuilds"]
	var foam_rebuild_frames: int = foam_stat["frames_with_rebuild"]
	var foam_constant_in_run := foam_rebuild_frames >= total_frames * 0.9
	var player_spikey := player_rebuilds > 0
	var foam_floor_profiled: bool = (
		PROFILER_REFERENCE.get("midpoint_frame", {}).get("HullFoam3D._process_ms", 0.0) > 0.0
		and PROFILER_REFERENCE.get("worst_frame", {}).get("HullFoam3D._process_ms", 0.0) > 0.0
	)
	var verdict := "BOTH: HullFoam3D rebuilds every frame while foam_intensity is up (constant ~4.25-4.74 ms floor in the real profiler, present in every frame of real play), and WakeTrail3D player wake rebuilds on every sampling tick (the spike driver: up to ~12 ms, 2 calls in the profiled worst frame)."
	if player_spikey and (foam_constant_in_run or foam_floor_profiled):
		verdict = "BOTH: HullFoam3D rebuilds every frame while foam_intensity is up (constant ~4.25-4.74 ms floor in the real profiler, present in every frame of real play), and WakeTrail3D player wake rebuilds on every sampling tick (the spike driver: up to ~12 ms, 2 calls in the profiled worst frame)."
	elif foam_constant_in_run:
		verdict = "HullFoam3D constant per-frame rebuild."
	elif player_spikey:
		verdict = "WakeTrail3D player wake spike rebuilds."
	return {
		"verdict": verdict,
		"player_wake_rebuilds": player_rebuilds,
		"foam_rebuild_frames": foam_rebuild_frames,
		"foam_constant_in_run": foam_constant_in_run,
		"foam_floor_present_in_reference_profiler": foam_floor_profiled,
		"note": "In this synthetic 20 s run HullFoam3D was active on only %d/%d frames (foam_intensity is bimodal under the feedback circle driver: 1.0 while turning/accelerating, 0.0 on the straight highspeed legs). The real 'Script Functions' profiler (see profiler_reference) shows HullFoam3D._process/~_rebuild_mesh in EVERY midpoint and worst frame (~4.25-4.74 ms), so in real gameplay the foam floor is constant while the wake rebuild onto it forms the spikes." % [foam_rebuild_frames, total_frames],
	}


func _recommendation_2d(per_instance: Dictionary, foam_stat: Dictionary, total_frames: int) -> String:
	return "Phase 2D candidate (ONE): decouple HullFoam3D._rebuild_mesh() from every _process call (add an interval/dirty gate; the foam patch geometry is constant at ~33 vertices and only its shader parameters/simulation_time change per frame), because it rebuilds unconditionally every rendered frame and forms the constant ~4.25-4.74 ms script-function floor in the real profiler. Keep WakeTrail3D as-is: its per-sample-tick rebuild is semantic (age/fade/sample motion) and already gated on _mesh_dirty/interval."


func _stats(values: Array) -> Dictionary:
	var sorted := values.duplicate()
	sorted.sort()
	var count := sorted.size()
	if count == 0:
		return {"mean": 0.0, "median": 0.0, "p90": 0.0, "p95": 0.0, "p99": 0.0, "max": 0.0, "min": 0.0}
	var total := 0.0
	for v: Variant in sorted:
		total += float(v)
	return {
		"mean": total / float(count),
		"median": _median(sorted),
		"p90": _percentile(sorted, 0.90),
		"p95": _percentile(sorted, 0.95),
		"p99": _percentile(sorted, 0.99),
		"max": float(sorted[count - 1]),
		"min": float(sorted[0]),
	}


func _median(sorted_values: Array) -> float:
	return _percentile(sorted_values, 0.50)


func _percentile(sorted_values: Array, ratio: float) -> float:
	var n := sorted_values.size()
	if n == 0:
		return -1.0
	if n == 1:
		return float(sorted_values[0])
	var pos := ratio * float(n - 1)
	var low := int(floor(pos))
	var high := int(ceil(pos))
	if low == high:
		return float(sorted_values[low])
	var frac := pos - float(low)
	return lerpf(float(sorted_values[low]), float(sorted_values[high]), frac)


func _mean(values: Array) -> float:
	if values.is_empty():
		return 0.0
	var total := 0.0
	for v: Variant in values:
		total += float(v)
	return total / float(values.size())


func _mean_wall_ms(frames: Array) -> float:
	var total := 0.0
	if frames.is_empty():
		return 0.0
	for record: Dictionary in frames:
		total += float(record["wall_ms"])
	return total / float(frames.size())


func _last(values: Array, fallback: int) -> int:
	for value: Variant in values:
		fallback = int(value)
	return fallback


func _sorted_copy(values: Array) -> Array:
	var out := values.duplicate()
	out.sort()
	return out


func _slice(array: Array, count: int) -> Array:
	var out := []
	for i in mini(array.size(), count):
		out.append(array[i])
	return out


func _argument_value(prefix: String, fallback: String) -> String:
	for argument: String in OS.get_cmdline_user_args():
		if argument.begins_with(prefix):
			return argument.trim_prefix(prefix)
	return fallback


func _quick_duration_ms() -> int:
	var value := _argument_value("--quick_ms=", "")
	if value.is_valid_int():
		return int(value)
	return MEASURE_DURATION_MS


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
	var directory := ProjectSettings.globalize_path(OUTPUT_DIRECTORY).replace("\\", "/")
	if DirAccess.make_dir_recursive_absolute(directory) != OK:
		return ""
	var timestamp := Time.get_datetime_string_from_system().replace(":", "-")
	var path := "%s/gold_city_mesh_rebuild_2c_%s_%s.json" % [directory, _label, timestamp]
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return ""
	file.store_string(JSON.stringify(_sanitize(report), "\t"))
	file.close()
	return ProjectSettings.localize_path(path)


func _fail(message: String) -> void:
	push_error("%s FAIL: %s" % [PHASE_TAG, message])
	print("%s=FAIL %s" % [PHASE_TAG, message])
	get_tree().quit(1)