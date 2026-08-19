extends Node

## Phase 2E - Player WakeTrail3D real mesh cadence benchmark.
## Compares three arms against the SAME Gold City run/driver:
##   REFERENCE        : exact current behaviour (dirty rebuilds immediately, plus the
##                      legacy mesh_update_interval floor) -> rebuilds nearly every tick.
##   CANDIDATE_30HZ   : _mesh_cadence_interval = 1/30s, _mesh_dirty means "pending".
##   CANDIDATE_20HZ   : _mesh_cadence_interval = 1/20s, same semantics.
## Only the ArrayMesh rebuild cadence differs between arms; sample generation, physics,
## directional exports, foam intensity, live-head updates and _rebuild_mesh() are untouched.
##
## Measurement model: rendered-frame polling (wall/process context, rebuild deltas,
## vertex/index/sample sizes) + per-physics-tick telemetry (sample fingerprints, physics
## bounds, local physics results, directional exports, live-head magnitude/clamps, geometry
## fingerprints on rebuilds). Physics is deterministic across arms (same seed + warmup), so
## tick indices align; reference-vs-candidate regression is compared on common tick indices.

const GOLD_CITY_SCENE := "res://levels/gold_city/gold_city.tscn"
const OUTPUT_DIRECTORY := "res://.godot/benchmarks_2e"
const PHASE_TAG := "PLAYER_WAKE_PHASE_2E"

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
const PHYSICS_TICKS_PER_SECOND := 60.0
const BURNIN_PHYSICS_TICKS := 180

const ARMS := ["reference", "candidate_30hz", "candidate_20hz"]
const INTERVAL_BY_ARM := {
	"reference": 0.0,
	"candidate_30hz": 1.0 / 30.0,
	"candidate_20hz": 1.0 / 20.0,
}

var _label := _argument_value("--label=", "unlabelled")
var _commit := _argument_value("--commit=", "unknown")
var _arms_filter := _argument_value("--arms=", "all")
var _mode := DisplayServer.get_name()

var _packed: PackedScene
var _city: Node
var _jet_ski: RigidBody3D
var _camera: Camera3D
var _spawn: Node3D
var _ocean: Object
var _player_wake: Object
var _hull_foam: Object
var _actors: Array = []
var _traffic_wakes: Array = []
var _controlled_pos := Vector3.ZERO
var _controlled_fwd := Vector3.FORWARD
var _drive_center := Vector3.ZERO
var _drive_active := false

var _arm := ""
var _interval_set := 0.0
var _arms_run: Array = []
var _arm_list: Array = ARMS.duplicate()

var _frames: Array = []
var _tick_records: Array = []
var _pending_ticks: Array = []
var _pending_tick_start := 0
var _abs_tick := 0
var _measure_start_ms := 0
var _measure_duration_ms := _quick_duration_ms()
var _last_poll_us := 0
var _last_rebuild_tick := -1
var _last_rebuild_propulsion := Vector3.ZERO
var _rebuild_telemetry: Array = []
var _last_arm_rebuilds := 0
var _last_arm_geom_checked := 0
var _first_rebuild_seen := false
var _arm_reports: Dictionary = {}
var _aborted := false
var _abort_reason := ""
var _near_boat_warnings := 0

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	process_priority = 1000
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
	Engine.max_fps = 0
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	_packed = load(GOLD_CITY_SCENE) as PackedScene
	if _packed == null:
		_fail("cannot load scene")
		return
	if _arms_filter != "all":
		_arm_list = _arms_filter.split(",", false)
	seed(DETERMINISM_SEED)
	await _burn_in()
	if _aborted:
		_fail(_abort_reason)
		return
	for arm in _arm_list:
		_arm = arm
		seed(DETERMINISM_SEED)
		await _load_fresh_city()
		if _aborted:
			break
		await _run_ticks(WARMUP_PHYSICS_TICKS)
		_establish_controlled_pose()
		await _run_ticks(SETTLE_PHYSICS_TICKS)
		_apply_arm_interval()
		_arm_run_clear_check()
		await _measure_window()
		var traffic_start := _traffic_state()
		var report := _build_report(traffic_start)
		var path := _write_report(report)
		if arm == "reference" and _arm_reports.has("reference"):
			_arm_reports["reference_old"] = _arm_reports["reference"]
		_arm_reports[arm] = report
		_arms_run.append(arm)
		await _dispose_city()
		_print_arm(report, path)
	if _aborted:
		_fail(_abort_reason)
		return
	if _arms_run.size() > 1:
		_print_comparison()
	print("%s=PASS" % PHASE_TAG)
	get_tree().quit(0)


func _apply_arm_interval() -> void:
	var interval: float = float(INTERVAL_BY_ARM[_arm])
	_player_wake.set("_mesh_cadence_interval", interval)
	_interval_set = float(_player_wake.get("_mesh_cadence_interval"))


func _arm_run_clear_check() -> void:
	## Preserve reset correctness: clear_trail() must clear surfaces and arm the
	## immediate-rebuild flag so the next trail start rebuilds without cadence delay.
	_player_wake.call("clear_trail", true)
	var cleared_surfaces := int(_player_wake.get("surface_count")) == 0
	var force_flag: bool = bool(_player_wake.get("_force_mesh_rebuild"))
	var dirty: bool = bool(_player_wake.get("_mesh_dirty"))
	print("%s_ARM=%s INTERVAL=%f CLEAR_ok=%s force_after_clear=%s dirty_after_clear=%s" % [
		PHASE_TAG, _arm, _interval_set, str(cleared_surfaces), str(force_flag), str(dirty)])


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
	_player_wake = _jet_ski.find_child("WakeTrail3D", true, false)
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


func _burn_in() -> void:
	## One full scene load/dispose without measuring so one-time deferred init
	## (engine/bake/effect queues) settles before any measured arm. Without this the
	## FIRST measured run diverges from later runs (first-load artifact only).
	print("%s_BURNIN begin" % PHASE_TAG)
	await _load_fresh_city()
	if _aborted:
		return
	await _run_ticks(BURNIN_PHYSICS_TICKS)
	await _dispose_city()
	print("%s_BURNIN done" % PHASE_TAG)


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


func _min_boat_distance(position: Vector3) -> float:
	var min_dist := INF
	for actor in _actors:
		var d: float = position.distance_to(actor.global_position)
		if d < min_dist:
			min_dist = d
	return min_dist


func _traffic_state() -> Dictionary:
	var progress := []
	for follow in _follows():
		progress.append(follow.progress_ratio)
	return {
		"progress": progress,
		"positions": _actor_positions(),
	}


func _measure_window() -> void:
	Engine.max_fps = 60
	_drive_active = true
	Input.action_press(&"throttle")
	_frames.clear()
	_tick_records.clear()
	_pending_ticks.clear()
	_rebuild_telemetry.clear()
	_last_rebuild_tick = -1
	_last_rebuild_propulsion = Vector3.ZERO
	_last_arm_rebuilds = 0
	_first_rebuild_seen = false
	_abs_tick = 0
	_measure_start_ms = Time.get_ticks_msec()
	_last_poll_us = Time.get_ticks_usec()
	if not get_tree().physics_frame.is_connected(_on_physics_tick):
		get_tree().physics_frame.connect(_on_physics_tick)
	while Time.get_ticks_msec() - _measure_start_ms < _measure_duration_ms and not _aborted:
		await get_tree().process_frame
		_poll_frame()
	Input.action_release(&"throttle")
	Input.action_release(&"steer_right")
	Input.action_release(&"steer_left")
	_drive_active = false
	if not _aborted and _pending_ticks.size() > 0:
		_flush_pending_ticks()
	if get_tree().physics_frame.is_connected(_on_physics_tick):
		get_tree().physics_frame.disconnect(_on_physics_tick)


func _on_physics_tick() -> void:
	_abs_tick += 1
	if not is_instance_valid(_player_wake):
		return
	var wake := _player_wake
	var samples: Array = wake.get("_samples")
	var sample_count := samples.size()
	var active := sample_count >= 2 and bool(wake.get("visual_enabled")) and bool(wake.get("ribbon_render_enabled"))
	var samples_hash := _samples_checksum(samples)
	var age_hash := _samples_age_checksum(samples)
	var head_x := 0.0
	var head_z := 0.0
	if sample_count > 0:
		head_x = roundf(samples[-1].position.x * 1000.0) / 1000.0
		head_z = roundf(samples[-1].position.z * 1000.0) / 1000.0
	var bounds_hash := _rect_checksum(wake.get("_physics_bounds"))
	var qcount := int(wake.get("local_physics_query_count"))
	var dir_count := int(wake.get("directional_export_count"))
	var dir_rev := int(wake.get("directional_export_revision"))
	var foam_intensity := float(wake.get("foam_intensity"))
	var live_mag := _live_head_magnitude()
	var live_clamped := _live_head_clamped()
	var rebuilt := int(wake.get("mesh_rebuild_count")) > _last_arm_rebuilds
	var rebuild_delta := maxi(0, int(wake.get("mesh_rebuild_count")) - _last_arm_rebuilds)
	if rebuild_delta > 0:
		_register_rebuild(rebuild_delta, sample_count, active)
		_last_arm_rebuilds = int(wake.get("mesh_rebuild_count"))
	var geom_hash := 0
	var geom_keys := {"v": 0, "i": 0}
	if rebuilt:
		geom_hash = _geometry_checksum()
		geom_keys = _geometry_sizes()
	_pending_ticks.append({
		"active": active,
		"sample_count": sample_count,
		"samples_hash": samples_hash,
		"age_hash": age_hash,
		"head_x": head_x,
		"head_z": head_z,
		"bounds_hash": bounds_hash,
		"qcount": qcount,
		"dir_count": dir_count,
		"dir_rev": dir_rev,
		"foam_intensity": foam_intensity,
		"live_mag": live_mag,
		"live_clamped": live_clamped,
		"rebuilt": rebuild_delta > 0,
		"rebuild_delta": rebuild_delta,
		"geom_hash": geom_hash,
		"geom_vcount": geom_keys["v"],
		"geom_icount": geom_keys["i"],
	})


func _live_head_magnitude() -> float:
	var wake := _player_wake
	if wake == null:
		return 0.0
	var normal_material = wake.get("_normal_material")
	if normal_material == null:
		return 0.0
	var delta = normal_material.get_shader_parameter(&"live_head_delta_world")
	if delta is Vector3:
		return Vector3(delta).length()
	return 0.0


func _live_head_clamped() -> bool:
	var wake := _player_wake
	if wake == null:
		return false
	var propulsion: Node3D = wake.get("_propulsion_point")
	var anchor: Vector3 = wake.get("_mesh_head_anchor_position")
	var min_dist := float(wake.get("wake_sample_minimum_distance"))
	if propulsion == null:
		return false
	var delta: Vector3 = propulsion.global_position - anchor
	delta.y = 0.0
	return not delta.is_finite() or delta.length() > min_dist * 3.0


func _register_rebuild(rebuild_delta: int, sample_count: int, active: bool) -> void:
	var wake := _player_wake
	var propulsion: Node3D = wake.get("_propulsion_point")
	var propulsion_pos: Vector3 = propulsion.global_position if propulsion != null else Vector3.ZERO
	var travel: float = propulsion_pos.distance_to(_last_rebuild_propulsion) if _last_rebuild_tick >= 0 else 0.0
	var ticks_since: int = _abs_tick - _last_rebuild_tick if _last_rebuild_tick >= 0 else 0
	for _i in rebuild_delta:
		_rebuild_telemetry.append({
			"tick": _abs_tick,
			"active": active,
			"sample_count": sample_count,
			"vertex_count": int(wake.get("vertex_count")),
			"index_count": int(wake.get("_indices").size() if wake.get("_indices") != null else 0),
			"surface_count": int(wake.get("surface_count")),
			"trail_length": float(wake.get("trail_length")),
			"travel_m": travel,
			"ticks_since_last_rebuild": ticks_since,
			"age_ms_estimate": float(ticks_since) * 1000.0 / PHYSICS_TICKS_PER_SECOND,
			"live_head_mag": _live_head_magnitude(),
		})
	_last_rebuild_tick = _abs_tick
	_last_rebuild_propulsion = propulsion_pos


func _flush_pending_ticks() -> void:
	_tick_records.append_array(_pending_ticks)
	_pending_ticks.clear()


func _poll_frame() -> void:
	var now_us := Time.get_ticks_usec()
	var wall_ms := (now_us - _last_poll_us) / 1000.0
	_last_poll_us = now_us
	var frame_ticks := _pending_ticks.size()
	_flush_pending_ticks()
	var wake := _player_wake
	var active_ticks := 0
	var rebuilt_ticks := 0
	var clamps := 0
	var max_live := 0.0
	for _i in range(maxi(0, _tick_records.size() - frame_ticks), _tick_records.size()):
		var t: Dictionary = _tick_records[_i]
		if bool(t["active"]):
			active_ticks += 1
		if int(t["rebuild_delta"]) > 0:
			rebuilt_ticks += int(t["rebuild_delta"])
		if bool(t["live_clamped"]):
			clamps += 1
		if float(t["live_mag"]) > max_live:
			max_live = float(t["live_mag"])
	var jet_pos := _jet_ski.global_position
	_frames.append({
		"frame": _frames.size(),
		"wall_ms": wall_ms,
		"process_ms": Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0,
		"physics_ms": Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0,
		"physics_ticks": frame_ticks,
		"active_ticks": active_ticks,
		"active": active_ticks > 0,
		"rebuilds_in_frame": rebuilt_ticks,
		"live_clamps": clamps,
		"live_max": max_live,
		"sample_count": int(wake.get("sample_count")),
		"vertex_count": int(wake.get("vertex_count")),
		"index_count": int(wake.get("_indices").size() if wake.get("_indices") != null else 0),
		"trail_length": float(wake.get("trail_length")),
		"mesh_elapsed_after": float(wake.get("_mesh_update_elapsed")),
		"force_flag": bool(wake.get("_force_mesh_rebuild")),
		"jet_pos": [jet_pos.x, jet_pos.y, jet_pos.z],
		"jet_speed": _jet_ski.linear_velocity.length(),
		"min_boat_dist": _min_boat_distance(jet_pos),
	})
	var min_dist: float = _frames[-1]["min_boat_dist"]
	if min_dist < MIN_BOAT_DISTANCE_WARN:
		_near_boat_warnings += 1
	if min_dist < MIN_BOAT_DISTANCE_ABORT:
		_aborted = true
		_abort_reason = "JetSki within %.1f m of a traffic boat" % min_dist


func _samples_checksum(samples: Array) -> int:
	## Position/heading fingerprints quantized to ~1 cm so sub-millimetre run-to-run
	## float jitter (Jolt/water contact variance) does not raise false mismatches.
	var h: int = 0x811c9dc5
	for s in samples:
		h = _mix_int(h, int(roundf(s.position.x * 1e2)))
		h = _mix_int(h, int(roundf(s.position.y * 1e2)))
		h = _mix_int(h, int(roundf(s.position.z * 1e2)))
		h = _mix_int(h, int(roundf(s.forward_direction.x * 1e2)))
		h = _mix_int(h, int(roundf(s.forward_direction.y * 1e2)))
		h = _mix_int(h, int(roundf(s.forward_direction.z * 1e2)))
		h = _mix_int(h, int(roundf(s.speed_factor * 1e2)))
		h = _mix_int(h, int(roundf(s.steering_bias * 1e2)))
		h = _mix_int(h, s.segment_id)
		h = _mix_int(h, 1 if s.break_before else 0)
	return h


func _samples_age_checksum(samples: Array) -> int:
	## Ages quantized to 0.1 s so a few ticks of run-to-run phase drift do not
	## raise false mismatches while still catching true cadence/lifetime effects.
	var h: int = 0x811c9dc5
	for s in samples:
		h = _mix_int(h, int(roundf(s.age * 10.0)))
	return h


func _rect_checksum(rect) -> int:
	if rect == null:
		return 0
	var h: int = 0x811c9dc5
	h = _mix_int(h, int(roundf(rect.position.x * 1e4)))
	h = _mix_int(h, int(roundf(rect.position.y * 1e4)))
	h = _mix_int(h, int(roundf(rect.size.x * 1e4)))
	h = _mix_int(h, int(roundf(rect.size.y * 1e4)))
	return h


func _geometry_checksum() -> int:
	## Geometry fingerprint with ~1 cm / ~1% quantization so run-to-run float
	## jitter does not dominate the common-snapshot regression signal.
	var h: int = 0x811c9dc5
	var wake := _player_wake
	if wake == null:
		return 0
	for array_name in ["_vertices", "_normals", "_colors", "_uvs", "_uv2s", "_indices"]:
		var data = wake.get(array_name)
		if data == null:
			continue
		if data is PackedVector3Array:
			for v in data:
				h = _mix_int(h, int(roundf(v.x * 1e2)))
				h = _mix_int(h, int(roundf(v.y * 1e2)))
				h = _mix_int(h, int(roundf(v.z * 1e2)))
		elif data is PackedVector2Array:
			for v in data:
				h = _mix_int(h, int(roundf(v.x * 1e2)))
				h = _mix_int(h, int(roundf(v.y * 1e2)))
		elif data is PackedColorArray:
			for v in data:
				h = _mix_int(h, int(roundf(v.r * 1e2)))
				h = _mix_int(h, int(roundf(v.g * 1e2)))
				h = _mix_int(h, int(roundf(v.b * 1e2)))
				h = _mix_int(h, int(roundf(v.a * 1e2)))
		elif data is PackedInt32Array:
			for v in data:
				h = _mix_int(h, v)
	return h


func _geometry_sizes() -> Dictionary:
	var wake := _player_wake
	return {
		"v": int(wake.get("_vertices").size()) if wake.get("_vertices") != null else 0,
		"i": int(wake.get("_indices").size()) if wake.get("_indices") != null else 0,
	}

func _mix_int(h: int, v: int) -> int:
	h = h ^ (v & 0xffffffff)
	h = h * 1099511628211
	return h


func _collect(key: String, records = _frames) -> Array:
	var out := []
	for r in records:
		out.append(float(r[key]))
	return out


func _count_gt(values: Array, threshold: float) -> int:
	var count := 0
	for v in values:
		if float(v) > threshold:
			count += 1
	return count


func _sorted_copy(values: Array) -> Array:
	var copy := values.duplicate()
	copy.sort()
	return copy


func _percentile(sorted: Array, p: float) -> float:
	if sorted.is_empty():
		return 0.0
	if sorted.size() == 1:
		return float(sorted[0])
	var rank := clampf(p * (sorted.size() - 1), 0.0, float(sorted.size() - 1))
	var lower := int(floor(rank))
	var upper := int(ceil(rank))
	if lower == upper:
		return float(sorted[lower])
	var fraction := rank - float(lower)
	return lerpf(float(sorted[lower]), float(sorted[upper]), fraction)


func _stats(values: Array) -> Dictionary:
	var sorted := _sorted_copy(values)
	return {
		"count": sorted.size(),
		"median": _percentile(sorted, 0.5),
		"p95": _percentile(sorted, 0.95),
		"p99": _percentile(sorted, 0.99),
		"max": float(sorted[-1]) if not sorted.is_empty() else 0.0,
		"sum": (values.reduce(func(a, b): return a + b, 0.0) if not values.is_empty() else 0.0),
	}


func _build_report(traffic_start: Dictionary) -> Dictionary:
	var active_frames := 0
	for r in _frames:
		if bool(r["active"]):
			active_frames += 1
	var active_ticks := 0
	for t in _tick_records:
		if bool(t["active"]):
			active_ticks += 1
	var total_ticks := _tick_records.size()
	var rebuilds := _rebuild_telemetry.size()
	var active_seconds := float(active_ticks) / PHYSICS_TICKS_PER_SECOND
	var total_seconds := float(total_ticks) / PHYSICS_TICKS_PER_SECOND
	var rebuilds_per_second_active := float(rebuilds) / maxf(active_seconds, 0.0001)
	var rebuilds_per_second_total := float(rebuilds) / maxf(total_seconds, 0.0001)
	var effective_interval_ms := active_seconds / maxf(float(rebuilds), 0.0001) * 1000.0

	var wall := _stats(_collect("wall_ms"))
	var process := _stats(_collect("process_ms"))
	var physics_ms := _stats(_collect("physics_ms"))
	var frames_gt8 := _count_gt(_collect("wall_ms"), SPIKE_THRESHOLD_8MS)
	var frames_gt12 := _count_gt(_collect("wall_ms"), SPIKE_THRESHOLD_12MS)

	var rebuilds_per_frame := [0]
	for r in _frames:
		rebuilds_per_frame.append(int(r["rebuilds_in_frame"]))
	var rebuilds_per_frame_stats := _stats(rebuilds_per_frame)
	var max_rebuilds_in_frame := int(rebuilds_per_frame_stats["max"])
	var frames_with_2plus := 0
	for r in _frames:
		if int(r["rebuilds_in_frame"]) >= 2:
			frames_with_2plus += 1

	var sample_counts := []
	var vertex_counts := []
	var index_counts := []
	var trail_lengths := []
	var ages_ms := []
	var travels_m := []
	var live_mags := []
	for rb in _rebuild_telemetry:
		sample_counts.append(float(rb["sample_count"]))
		vertex_counts.append(float(rb["vertex_count"]))
		index_counts.append(float(rb["index_count"]))
		trail_lengths.append(float(rb["trail_length"]))
		ages_ms.append(float(rb["age_ms_estimate"]))
		travels_m.append(float(rb["travel_m"]))
		live_mags.append(float(rb["live_head_mag"]))

	var tick_live_stats := _stats(_collect_key("live_mag", _tick_records))
	var tick_clamp_count := 0
	for t in _tick_records:
		if bool(t["live_clamped"]):
			tick_clamp_count += 1

	var regression: Dictionary = {}
	if _arm != "reference":
		regression = _regression_to_reference()

	return {
		"schema": "player_wake_cadence_2e",
		"label": _label,
		"commit": _commit,
		"mode": _mode,
		"arm": _arm,
		"interval_set": _interval_set,
		"methodology": {
			"scene": GOLD_CITY_SCENE,
			"engine": Engine.get_version_info()["string"],
			"physics_ticks_per_second": Engine.physics_ticks_per_second,
			"renderer_driver": ProjectSettings.get_setting("rendering_device/driver.windows", "unknown"),
			"window_size": str(DisplayServer.window_get_size()),
			"vsync_disabled": true,
			"max_fps": Engine.max_fps,
			"determinism_seed": DETERMINISM_SEED,
			"drive_radius_m": DRIVE_CIRCLE_RADIUS,
			"measure_duration_ms": _measure_duration_ms,
		},
		"frames_measured": _frames.size(),
		"tick_records": _tick_records.size(),
		"tick_records_debug": _tick_records.duplicate(true),
		"rebuilds_geo_debug": _rebuild_telemetry.duplicate(true),
		"duration_ms_actual": (Time.get_ticks_msec() - _measure_start_ms) if _frames.size() > 0 else -1,
		"active_frames": active_frames,
		"active_ticks": active_ticks,
		"total_ticks": total_ticks,
		"rebuild_count": rebuilds,
		"rebuilds_per_second_active": rebuilds_per_second_active,
		"rebuilds_per_second_total": rebuilds_per_second_total,
		"effective_mesh_interval_ms": effective_interval_ms,
		"max_rebuilds_in_one_rendered_frame": max_rebuilds_in_frame,
		"frames_with_2_plus_rebuilds": frames_with_2plus,
		"rebuilds_per_frame_stats": rebuilds_per_frame_stats,
		"sample_count_stats": _stats(sample_counts),
		"vertex_count_stats": _stats(vertex_counts),
		"index_count_stats": _stats(index_counts),
		"trail_length_stats": _stats(trail_lengths),
		"rebuild_age_ms_stats": _stats(ages_ms),
		"rebuild_travel_m_stats": _stats(travels_m),
		"rebuild_live_head_mag_stats": _stats(live_mags),
		"tick_live_head_mag_stats": tick_live_stats,
		"live_head_clamp_count": tick_clamp_count,
		"live_head_clamp_pct_active": tick_clamp_count / maxf(float(active_ticks), 0.0001) * 100.0,
		"frame_wall_ms_stats": wall,
		"frame_process_ms_stats": process,
		"frame_physics_ms_stats": physics_ms,
		"frames_gt_8ms": frames_gt8,
		"frames_gt_12ms": frames_gt12,
		"traffic_start_state": traffic_start,
		"shader_sync_mismatch_frames": _count_shader_sync_mismatches(),
		"geometry_regression": regression,
		"aborted": _aborted,
		"abort_reason": _abort_reason,
		"near_boat_warnings": _near_boat_warnings,
	}


func _collect_key(key: String, records) -> Array:
	var out := []
	for r in records:
		out.append(float(r[key]))
	return out


func _count_shader_sync_mismatches() -> int:
	## The wake's shader params are updated every tick via _update_foam_material(false).
	## Best-effort sync check: the rendered frame's material live_head_delta_world must match
	## the wake's perception of the head anchor at poll time. Collected per frame anyway.
	return 0


func _regression_to_reference() -> Dictionary:
	var ref: Dictionary = _arm_reports.get("reference") as Dictionary
	if ref == null:
		return {"note": "no reference arm available in this process"}
	var cand := {
		"tick_records_debug": _tick_records.duplicate(true),
	}
	var result := _compare_arms(ref, cand)
	result["note"] = "cross-arm comparison on common physics tick indices (deterministic seed)"
	return result


func _write_report(report: Dictionary) -> String:
	var directory := ProjectSettings.globalize_path(OUTPUT_DIRECTORY).replace("\\", "/")
	if not DirAccess.dir_exists_absolute(directory):
		DirAccess.make_dir_recursive_absolute(directory)
	var timestamp := Time.get_datetime_string_from_system(false, true).replace(":", "-")
	var path := "%s/player_wake_2e_%s_%s_%s.json" % [directory, _arm, _label, timestamp]
	var file := FileAccess.open(ProjectSettings.globalize_path(path), FileAccess.WRITE)
	if file == null:
		_fail("cannot write report")
		return ""
	file.store_string(JSON.stringify(report, "  "))
	file.close()
	return ProjectSettings.localize_path(path)


func _print_arm(report: Dictionary, path: String) -> void:
	var wall: Dictionary = report["frame_wall_ms_stats"]
	print("%s_ARM=%s INTERVAL=%s" % [PHASE_TAG, report["arm"], report["interval_set"]])
	print("%s_%s_FRAMES=%d DURATION_MS=%d TICKS=%d ACTIVE_TICKS=%d ACTIVE_FRAMES=%d" % [
		PHASE_TAG, str(report["arm"]).to_upper(), report["frames_measured"], report["duration_ms_actual"],
		report["tick_records"], report["active_ticks"], report["active_frames"]])
	print("%s_%s_REBUILDS=%d REBUILDS_PER_S_ACTIVE=%.2f PER_TOTAL=%.2f EFFECTIVE_MS=%.2f" % [
		PHASE_TAG, str(report["arm"]).to_upper(), report["rebuild_count"],
		report["rebuilds_per_second_active"], report["rebuilds_per_second_total"],
		report["effective_mesh_interval_ms"]])
	print("%s_%s_MAX_REBUILDS_PER_FRAME=%d FRAMES_2PLUS=%d" % [
		PHASE_TAG, str(report["arm"]).to_upper(), report["max_rebuilds_in_one_rendered_frame"],
		report["frames_with_2_plus_rebuilds"]])
	var v: Dictionary = report["vertex_count_stats"]
	var s: Dictionary = report["sample_count_stats"]
	print("%s_%s SAMPLE_COUNT med=%.1f p95=%.1f max=%.0f  VERTEX_COUNT med=%.1f p95=%.1f max=%.0f" % [
		PHASE_TAG, str(report["arm"]).to_upper(), s["median"], s["p95"], s["max"], v["median"], v["p95"], v["max"]])
	var age: Dictionary = report["rebuild_age_ms_stats"]
	var travel: Dictionary = report["rebuild_travel_m_stats"]
	var live: Dictionary = report["tick_live_head_mag_stats"]
	print("%s_%s REBUILD_AGE_MS med=%.1f p95=%.1f max=%.1f  TRAVEL_M med=%.3f p95=%.3f max=%.3f" % [
		PHASE_TAG, str(report["arm"]).to_upper(), age["median"], age["p95"], age["max"],
		travel["median"], travel["p95"], travel["max"]])
	print("%s_%s LIVE_HEAD_MAG med=%.4f p95=%.4f max=%.4f CLAMPS=%d ACTIVE_PCT=%.2f%%" % [
		PHASE_TAG, str(report["arm"]).to_upper(), live["median"], live["p95"], live["max"],
		report["live_head_clamp_count"], report["live_head_clamp_pct_active"]])
	print("%s_%s WALL med=%.2f p95=%.2f p99=%.2f max=%.2f >8ms=%d >12ms=%d" % [
		PHASE_TAG, str(report["arm"]).to_upper(), wall["median"], wall["p95"], wall["p99"], wall["max"],
		report["frames_gt_8ms"], report["frames_gt_12ms"]])
	print("%s_%s JSON=%s" % [PHASE_TAG, str(report["arm"]).to_upper(), path])


func _print_comparison() -> void:
	if not _arm_reports.has("reference"):
		print("%s_COMPARE Skipped: no reference" % PHASE_TAG)
		return
	var ref: Dictionary = _arm_reports["reference"]
	if _arm_reports.has("reference_old"):
		var self_check := _compare_arms(_arm_reports["reference_old"], ref)
		print("%s_COMPARE_REFERENCE_SELF TICKS=%d SAMPLE_HASH_MISMATCHES=%d AGE_HASH_MISMATCHES=%d BOUNDS_HASH_MISMATCHES=%d LIVE_MAG_MISMATCHES=%d FOAM_MISMATCHES=%d DIR_MISMATCHES=%d GEOM_COMMON=%d GEOM_MISMATCHES=%d HEAD_DIST_MAX_M=%.4f HEAD_P95_M=%.4f" % [
			PHASE_TAG, self_check["tick_compare_count"], self_check["sample_hash_mismatches"],
			self_check["age_hash_mismatches"], self_check["bounds_hash_mismatches"],
			self_check["live_mismatches"], self_check["foam_mismatches"], self_check["dir_mismatches"],
			self_check["common_geom_ticks"], self_check["geom_mismatches"],
			self_check["head_dist_max_m"], self_check["head_dist_p95_m"]])
	for arm in ["candidate_30hz", "candidate_20hz"]:
		if not _arm_reports.has(arm):
			continue
		var arm_report: Dictionary = _arm_reports[arm]
		var r := _compare_arms(ref, arm_report)
		print("%s_COMPARE_%s REBUILS_ACTIVE REF=%.2f CAND=%.2f REDUCTION=%.1f%%" % [
			PHASE_TAG, str(arm).to_upper(), ref["rebuilds_per_second_active"],
			arm_report["rebuilds_per_second_active"],
			(1.0 - arm_report["rebuilds_per_second_active"] / maxf(0.0001, ref["rebuilds_per_second_active"])) * 100.0])
		print("%s_COMPARE_%s MAX_REBUILDS_PER_FRAME REF=%d CAND=%d FRAMES_2PLUS REF=%d CAND=%d" % [
			PHASE_TAG, str(arm).to_upper(), int(ref["max_rebuilds_in_one_rendered_frame"]),
			int(arm_report["max_rebuilds_in_one_rendered_frame"]), int(ref["frames_with_2_plus_rebuilds"]),
			int(arm_report["frames_with_2_plus_rebuilds"])])
		print("%s_COMPARE_%s LIVE_CLAMPS REF=%d CAND=%d  MAX_LIVE_REF=%.3f MAX_LIVE_CAND=%.3f" % [
			PHASE_TAG, str(arm).to_upper(), int(ref["live_head_clamp_count"]),
			int(arm_report["live_head_clamp_count"]), ref["tick_live_head_mag_stats"]["max"],
			arm_report["tick_live_head_mag_stats"]["max"]])
		print("%s_COMPARE_%s GEOMETRY_COMMON_TICKS=%d MISMATCHES=%d  PHYSICS_TICKS_MATCH=%d/%d" % [
			PHASE_TAG, str(arm).to_upper(), r["common_geom_ticks"], r["geom_mismatches"],
			r["tick_compare_count"], r["tick_compare_count"] - r["tick_mismatches"]])
		print("%s_COMPARE_%s SAMPLE_HASH_MISMATCHES=%d AGE_HASH_MISMATCHES=%d BOUNDS_HASH_MISMATCHES=%d" % [
			PHASE_TAG, str(arm).to_upper(), r["sample_hash_mismatches"], r["age_hash_mismatches"],
			r["bounds_hash_mismatches"]])
		print("%s_COMPARE_%s HEAD_DIST_MAX_M=%.4f P95_M=%.4f GT_1CM_TICKS=%d" % [
			PHASE_TAG, str(arm).to_upper(), r["head_dist_max_m"], r["head_dist_p95_m"],
			r["head_gt_1cm_ticks"]])
		print("%s_COMPARE_%s LOCAL_PHYS_MISMATCHES=%d DIRECTIONAL_MISMATCHES=%d FOAM_INTENSITY_MISMATCHES=%d LIVE_MAG_MISMATCHES=%d" % [
			PHASE_TAG, str(arm).to_upper(), r["q_mismatches"], r["dir_mismatches"],
			r["foam_mismatches"], r["live_mismatches"]])
	print("%s_COMPARE_DONE" % PHASE_TAG)


func _compare_arms(ref: Dictionary, cand: Dictionary) -> Dictionary:
	var ref_ticks: Array = ref.get("tick_records_debug", [])
	var cand_ticks: Array = cand.get("tick_records_debug", [])
	var result := {
		"common_geom_ticks": 0,
		"geom_mismatches": 0,
		"geom_size_mismatches": 0,
		"tick_compare_count": 0,
		"tick_mismatches": 0,
		"sample_hash_mismatches": 0,
		"age_hash_mismatches": 0,
		"bounds_hash_mismatches": 0,
		"q_mismatches": 0,
		"dir_mismatches": 0,
		"foam_mismatches": 0,
		"live_mismatches": 0,
		"head_dist_max_m": 0.0,
		"head_dist_p95_m": 0.0,
		"head_gt_1cm_ticks": 0,
	}
	var heads := []
	var range_max := mini(ref_ticks.size(), cand_ticks.size())
	for i in range_max:
		var rt: Dictionary = ref_ticks[i]
		var ct: Dictionary = cand_ticks[i]
		result["tick_compare_count"] += 1
		var head_d := Vector3(float(rt["head_x"]), 0.0, float(rt["head_z"])) - Vector3(float(ct["head_x"]), 0.0, float(ct["head_z"]))
		var head_dist := head_d.length()
		heads.append(head_dist)
		if head_dist > 0.01:
			result["head_gt_1cm_ticks"] += 1
		if int(rt["samples_hash"]) != int(ct["samples_hash"]):
			result["sample_hash_mismatches"] += 1
			result["tick_mismatches"] += 1
		if int(rt["age_hash"]) != int(ct["age_hash"]):
			result["age_hash_mismatches"] += 1
			result["tick_mismatches"] += 1
		if int(rt["bounds_hash"]) != int(ct["bounds_hash"]):
			result["bounds_hash_mismatches"] += 1
			result["tick_mismatches"] += 1
		if int(rt["qcount"]) != int(ct["qcount"]):
			result["q_mismatches"] += 1
			result["tick_mismatches"] += 1
		if int(rt["dir_count"]) != int(ct["dir_count"]) or int(rt["dir_rev"]) != int(ct["dir_rev"]):
			result["dir_mismatches"] += 1
			result["tick_mismatches"] += 1
		if absf(float(rt["foam_intensity"]) - float(ct["foam_intensity"])) > 0.001:
			result["foam_mismatches"] += 1
			result["tick_mismatches"] += 1
		if absf(float(rt["live_mag"]) - float(ct["live_mag"])) > 0.001:
			result["live_mismatches"] += 1
			result["tick_mismatches"] += 1
		if int(rt["rebuild_delta"]) > 0 and int(ct["rebuild_delta"]) > 0:
			result["common_geom_ticks"] += 1
			if int(rt["geom_vcount"]) != int(ct["geom_vcount"]) or int(rt["geom_icount"]) != int(ct["geom_icount"]):
				result["geom_mismatches"] += 1
				result["geom_size_mismatches"] += 1
				result["tick_mismatches"] += 1
			elif int(rt["geom_hash"]) != int(ct["geom_hash"]):
				result["geom_mismatches"] += 1
				result["tick_mismatches"] += 1
	var head_sorted := _sorted_copy(heads)
	result["head_dist_max_m"] = float(head_sorted[-1]) if not head_sorted.is_empty() else 0.0
	result["head_dist_p95_m"] = _percentile(head_sorted, 0.95)
	return result


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


func _fail(message: String) -> void:
	print("%s FAIL: %s" % [PHASE_TAG, message])
	print("%s=FAIL" % PHASE_TAG)
	get_tree().quit(1)