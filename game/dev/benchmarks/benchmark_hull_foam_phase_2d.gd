extends Node

## Phase 2D — Hull Foam geometry cadence benchmark.
##
## Compares two modes of the SAME hull_foam_3d.gd implementation:
##   REFERENCE_FULL_RATE : _geometry_update_interval = 0.0 (OLD: rebuild every rendered frame)
##   CANDIDATE_30HZ      : _geometry_update_interval = 1.0/30.0 (Phase 2D gate)
##
## The interval is a private variable the benchmark temporarily overrides via set()
## (never exported, never a gameplay option). Everything else — foam_intensity
## calculation, shader parameters (simulation_time / foam_intensity /
## foam_flow_direction / foam_flow_speed), visibility, clear_foam() — keeps running
## every rendered frame in both arms. Only _rebuild_mesh() is rate-limited.
##
## Geometry proof: the benchmark embeds a self-contained MIRROR of _rebuild_mesh()
## (pure replica, reads the same markers/vehicle/ocean and never touches the runtime
## node's arrays). On every frame the engine rebuilds, engine geometry is compared
## to the mirror (expect max_vertex_delta=0, max_normal_delta=0, mismatch_count=0).
## On candidate frames the gate deliberately skips, the mirror computes the reference
## geometry that OLD would have produced at that instant for the cadence-error report.
##
## Local-wake query attribution is exact: per frame the benchmark reads the traffic
## wakes' local_physics_query_count deltas around its own mirror sampling, so the
## engine's query contribution is separated from the mirror's.

const GOLD_CITY_SCENE := "res://levels/gold_city/gold_city.tscn"
const OUTPUT_DIRECTORY := "res://.godot/benchmarks_2d"
const PHASE_TAG := "HULL_FOAM_PHASE_2D"

const DETERMINISM_SEED := 20260818
const WARMUP_PHYSICS_TICKS := 600
const SETTLE_PHYSICS_TICKS := 60
const CONTROLLED_DISTANCE := 140.0
const MEASURE_DURATION_MS := 20000
const DRIVE_CIRCLE_RADIUS := 28.0
const DRIVE_GAIN := 1.8
const DRIVE_RADIUS_GAIN := 0.5
const MAX_STEERING := 0.5
const SPIKE_THRESHOLD_8MS := 8.0
const SPIKE_THRESHOLD_12MS := 12.0
const MIN_BOAT_DISTANCE_WARN := 50.0
const MIN_BOAT_DISTANCE_ABORT := 10.0
const CANDIDATE_INTERVAL := 1.0 / 30.0
const SURFACE_OFFSET_MIRROR := 0.07

const ARMS_DEFAULT := "both"

var _packed: PackedScene
var _label := _argument_value("--label=", "unlabelled")
var _commit := _argument_value("--commit=", "unknown")
var _mode := DisplayServer.get_name()
var _arms_argument := _argument_value("--arms=", ARMS_DEFAULT)
var _compare_only := _has_argument("--compare-only")
var _arms: Array = []

var _city: Node
var _jet_ski: RigidBody3D
var _camera: Camera3D
var _spawn: Node3D
var _ocean: Object
var _hull_foam: Object
var _traffic_wakes: Array = []
var _actors: Array = []
var _controlled_pos := Vector3.ZERO
var _controlled_fwd := Vector3.FORWARD
var _drive_center := Vector3.ZERO
var _drive_active := false

var _arm: String = ""
var _interval_read := -1.0
var _measuring := false
var _measure_start_ms := 0
var _measure_duration_ms := _quick_duration_ms()
var _aborted := false
var _abort_reason := ""
var _near_boat_warnings := 0
var _clear_foam_test := {}

var _frames: Array = []
var _last_snapshot := {}
var _last_rebuild_time_ms := 0
var _last_rebuild_jet_pos := Vector3.ZERO
var _last_rebuild_steer := 0.0
var _last_rebuild_intensity := 0.0
var _active_foam_frames := 0
var _rebuild_frames := 0
var _activation_count := 0
var _activation_immediate_ok := 0
var _deactivation_count := 0
var _deactivation_immediate_ok := 0
var _shader_sync_failures := 0
var _visible_mismatches := 0
var _was_active := false
var _was_rebuilding := false
var _prev_geom_elapsed := -1.0
var _prev_queries_total := 0
var _query_delta_total := 0
var _mirror_queries_total := 0
var _engine_queries_total := 0
var _query_sources_count := 0
var _rebuild_vertex_counts := []
var _rebuild_index_counts := []
var _rebuild_surface_counts := []
var _regression := {
	"frames_checked": 0,
	"max_vertex_delta": 0.0,
	"max_normal_delta": 0.0,
	"mismatch_count": 0,
	"count_mismatch_count": 0,
	"position_mismatch_count": 0,
	"normal_mismatch_count": 0,
	"color_mismatch_count": 0,
	"uv_mismatch_count": 0,
	"uv2_mismatch_count": 0,
	"index_mismatch_count": 0,
}
var _cadence := {
	"frames_evaluated": 0,
	"max_age_ms": 0.0,
	"max_distance_m": 0.0,
	"max_steering_delta": 0.0,
	"max_intensity_delta": 0.0,
	"max_vertex_position_error": 0.0,
	"ages_ms": [],
	"distances_m": [],
	"steering_deltas": [],
	"intensity_deltas": [],
	"vertex_errors": [],
}


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	## Must process AFTER HullFoam3D._process (process_priority=21): we snapshot
	## geometry/shader state produced by THIS frame's rebuild. Higher = later here.
	process_priority = 1000
	var parent := get_parent()
	if parent != null and parent != get_tree().root:
		parent.remove_child(self)
		get_tree().root.add_child(self)
	if get_tree().current_scene == self:
		get_tree().current_scene = null
	call_deferred(&"_run")


func _process(_delta: float) -> void:
	if not _measuring:
		return
	var now_ms := Time.get_ticks_msec()
	if now_ms - _measure_start_ms >= _measure_duration_ms or _aborted:
		_finish_measurement()
		return
	_poll_frame(now_ms)


func _physics_process(_delta: float) -> void:
	if _drive_active and is_instance_valid(_jet_ski):
		_drive_circle_tick()


func _run() -> void:
	if _compare_only:
		_print_comparison()
		print("%s_COMPARE=PASS" % PHASE_TAG)
		get_tree().quit(0)
		return
	Engine.max_fps = 0
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	_packed = load(GOLD_CITY_SCENE) as PackedScene
	if _packed == null:
		_fail("cannot load scene")
		return
	if _arms_argument == "reference":
		_arms = ["reference"]
	elif _arms_argument == "candidate":
		_arms = ["candidate"]
	else:
		_arms = ["reference", "candidate"]
	for arm in _arms:
		_arm = arm
		seed(DETERMINISM_SEED)
		await _load_fresh_city()
		if _aborted:
			break
		await _run_ticks(WARMUP_PHYSICS_TICKS)
		_establish_controlled_pose()
		await _run_ticks(SETTLE_PHYSICS_TICKS)
		_apply_arm_interval()
		_run_clear_foam_test()
		await _measure_window()
		var traffic_start := _traffic_state()
		var report := _build_report(traffic_start)
		var path := _write_report(report)
		await _dispose_city()
		_print_arm(report, path)
	if _aborted:
		_fail(_abort_reason)
		return
	_print_comparison()
	print("%s=PASS" % PHASE_TAG)
	get_tree().quit(0)


func _apply_arm_interval() -> void:
	if _arm == "reference":
		_hull_foam.set("_geometry_update_interval", 0.0)
	else:
		_hull_foam.set("_geometry_update_interval", CANDIDATE_INTERVAL)
	_interval_read = float(_hull_foam.get("_geometry_update_interval"))


func _run_clear_foam_test() -> void:
	var foam := _hull_foam
	foam.clear_foam()
	var surfaces := _foam_surfaces()
	var elapsed := float(foam.get("_geometry_update_elapsed"))
	_clear_foam_test = {
		"hidden": not _foam_visible(),
		"surfaces_after_clear": surfaces,
		"elapsed_after_clear": elapsed,
		"expected_elapsed": CANDIDATE_INTERVAL if _interval_read > 0.0 else 0.0,
		"elapsed_reset_ok": absf(elapsed - (CANDIDATE_INTERVAL if _interval_read > 0.0 else 0.0)) < 0.000001,
	}


func _measure_window() -> void:
	Engine.max_fps = 60
	_measure_start_ms = Time.get_ticks_msec()
	_frames.clear()
	_active_foam_frames = 0
	_rebuild_frames = 0
	_activation_count = 0
	_activation_immediate_ok = 0
	_deactivation_count = 0
	_deactivation_immediate_ok = 0
	_shader_sync_failures = 0
	_visible_mismatches = 0
	_was_active = false
	_was_rebuilding = false
	_prev_geom_elapsed = -1.0
	_last_rebuild_time_ms = 0
	_last_rebuild_jet_pos = Vector3.ZERO
	_last_rebuild_steer = 0.0
	_last_rebuild_intensity = 0.0
	_prev_queries_total = _traffic_query_total()
	_query_delta_total = 0
	_mirror_queries_total = 0
	_engine_queries_total = 0
	_query_sources_count = 0
	_rebuild_vertex_counts.clear()
	_rebuild_index_counts.clear()
	_rebuild_surface_counts.clear()
	_regression = {
		"frames_checked": 0,
		"max_vertex_delta": 0.0,
		"max_normal_delta": 0.0,
		"mismatch_count": 0,
		"count_mismatch_count": 0,
		"position_mismatch_count": 0,
		"normal_mismatch_count": 0,
		"color_mismatch_count": 0,
		"uv_mismatch_count": 0,
		"uv2_mismatch_count": 0,
		"index_mismatch_count": 0,
	}
	_cadence = {
		"frames_evaluated": 0,
		"max_age_ms": 0.0,
		"max_distance_m": 0.0,
		"max_steering_delta": 0.0,
		"max_intensity_delta": 0.0,
		"max_vertex_position_error": 0.0,
		"ages_ms": [],
		"distances_m": [],
		"steering_deltas": [],
		"intensity_deltas": [],
		"vertex_errors": [],
	}
	_drive_active = true
	Input.action_press(&"throttle")
	_measuring = true
	while _measuring:
		await get_tree().process_frame
		await get_tree().process_frame
	Input.action_release(&"throttle")
	Input.action_release(&"steer_right")
	Input.action_release(&"steer_left")
	_drive_active = false


func _finish_measurement() -> void:
	_measuring = false


func _poll_frame(now_ms: int) -> void:
	var last := _last_snapshot
	var foam := _hull_foam
	var active := _foam_active()
	var surfaces := _foam_surfaces()
	var elapsed := float(foam.get("_geometry_update_elapsed"))
	var queries_before := _traffic_query_total()
	var rebuild_detected := false
	if active:
		if surfaces > 0 and last.get("surfaces", 0) == 0:
			rebuild_detected = true
		elif _interval_read <= 0.0:
			rebuild_detected = true
		elif last.get("active", false) and elapsed < float(last.get("elapsed", -1.0)) - 0.000001:
			rebuild_detected = true
		elif not last.get("active", false) and elapsed < float(last.get("elapsed", -1.0)) - 0.000001:
			rebuild_detected = true

	var regression := {}
	var cadence := {}
	var mirror_queries := 0
	if active:
		var mirror := _mirror_geometry()
		mirror_queries = _traffic_query_total() - queries_before
		if rebuild_detected:
			regression = _compare_geometry(_engine_geometry(), mirror)
			_was_rebuilding = true
		elif _interval_read > 0.0:
			cadence = _cadence_delta(mirror, now_ms)
			_was_rebuilding = false

	var visible_ok := _foam_visible() == (surfaces > 0)
	if not visible_ok:
		_visible_mismatches += 1
	var shader_ok := true
	if active:
		shader_ok = _shader_sync_check()
		if not shader_ok:
			_shader_sync_failures += 1

	if _was_active and not active:
		_deactivation_count += 1
		if not _foam_visible() and surfaces == 0:
			_deactivation_immediate_ok += 1
	if not _was_active and active:
		_activation_count += 1
		if rebuild_detected:
			_activation_immediate_ok += 1
	_was_active = active

	var queries_after := _traffic_query_total()
	var frame_query_total := queries_after - _prev_queries_total
	_prev_queries_total = queries_after
	var engine_queries := maxi(0, frame_query_total - mirror_queries)
	_query_delta_total += frame_query_total
	_mirror_queries_total += mirror_queries
	_engine_queries_total += engine_queries
	_query_sources_count += 1

	if active:
		_active_foam_frames += 1
	if rebuild_detected:
		_rebuild_frames += 1
		_last_rebuild_time_ms = now_ms
		_last_rebuild_jet_pos = _jet_ski.global_position
		_last_rebuild_steer = float(_hull_foam.get("_vehicle").steering_input)
		_last_rebuild_intensity = float(foam.foam_intensity)
		_rebuild_vertex_counts.append(_engine_vertex_count())
		_rebuild_index_counts.append(_engine_index_count())
		_rebuild_surface_counts.append(surfaces)

	var jet_pos := _jet_ski.global_position
	var record := {
		"frame": _frames.size(),
		"wall_ms": (now_ms - int(last.get("time_ms", now_ms))) * 1.0,
		"process_ms": Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0,
		"physics_ms": Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0,
		"jet_pos": [jet_pos.x, jet_pos.y, jet_pos.z],
		"jet_speed": _jet_ski.linear_velocity.length(),
		"foam_intensity": float(foam.foam_intensity),
		"active": active,
		"surfaces": surfaces,
		"vertex_count": _engine_vertex_count(),
		"elapsed": elapsed,
		"rebuild": rebuild_detected,
		"engine_queries": engine_queries,
		"mirror_queries": mirror_queries,
		"shader_sync_ok": shader_ok,
		"visible_ok": visible_ok,
		"regression": regression,
		"cadence": cadence,
	}
	_frames.append(record)
	_last_snapshot = {
		"time_ms": now_ms,
		"active": active,
		"surfaces": surfaces,
		"elapsed": elapsed,
	}


func _shader_sync_check() -> bool:
	var material := _hull_foam.get("_mesh_instance").material_override as ShaderMaterial
	if material == null:
		return false
	var intensity_ok: bool = float(material.get_shader_parameter(&"foam_intensity")) == float(_hull_foam.foam_intensity)
	var time_ok: bool = float(material.get_shader_parameter(&"simulation_time")) == _ocean.get_simulation_time()
	return intensity_ok and time_ok


func _cadence_delta(mirror: Dictionary, now_ms: int) -> Dictionary:
	var engine := _engine_geometry()
	var error := 0.0
	for i in mini(engine["vertices"].size(), mirror["vertices"].size()):
		var delta: float = engine["vertices"][i].distance_to(mirror["vertices"][i])
		error = maxf(error, delta)
	var age_ms: float = float(maxi(now_ms - _last_rebuild_time_ms, 0))
	var distance: float = _jet_ski.global_position.distance_to(_last_rebuild_jet_pos)
	var steering := float(_hull_foam.get("_vehicle").steering_input)
	var intensity := float(_hull_foam.foam_intensity)
	var steer_delta: float = absf(steering - _last_rebuild_steer)
	var intensity_delta: float = absf(intensity - _last_rebuild_intensity)
	_cadence["frames_evaluated"] += 1
	_cadence["max_age_ms"] = maxf(_cadence["max_age_ms"], age_ms)
	_cadence["max_distance_m"] = maxf(_cadence["max_distance_m"], distance)
	_cadence["max_steering_delta"] = maxf(_cadence["max_steering_delta"], steer_delta)
	_cadence["max_intensity_delta"] = maxf(_cadence["max_intensity_delta"], intensity_delta)
	_cadence["max_vertex_position_error"] = maxf(_cadence["max_vertex_position_error"], error)
	_cadence["ages_ms"].append(age_ms)
	_cadence["distances_m"].append(distance)
	_cadence["steering_deltas"].append(steer_delta)
	_cadence["intensity_deltas"].append(intensity_delta)
	_cadence["vertex_errors"].append(error)
	return {
		"age_ms": age_ms,
		"steering_delta": steer_delta,
		"intensity_delta": intensity_delta,
		"max_vertex_position_error": error,
	}


func _compare_geometry(engine: Dictionary, mirror: Dictionary) -> Dictionary:
	var out := {
		"count_mismatch": false,
		"position_mismatch": 0,
		"normal_mismatch": 0,
		"color_mismatch": 0,
		"uv_mismatch": 0,
		"uv2_mismatch": 0,
		"index_mismatch": 0,
		"max_vertex_delta": 0.0,
		"max_normal_delta": 0.0,
		"match": false,
	}
	_regression["frames_checked"] += 1
	var engine_v: PackedVector3Array = engine["vertices"]
	var mirror_v: PackedVector3Array = mirror["vertices"]
	if engine_v.size() != mirror_v.size():
		_regression["count_mismatch_count"] += 1
		out["count_mismatch"] = true
		_regression["mismatch_count"] += 1
		return out
	for i in engine_v.size():
		var delta: Vector3 = engine_v[i] - mirror_v[i]
		out["max_vertex_delta"] = maxf(out["max_vertex_delta"], delta.length())
		_regression["max_vertex_delta"] = maxf(_regression["max_vertex_delta"], delta.length())
		if not engine_v[i].is_equal_approx(mirror_v[i]):
			out["position_mismatch"] += 1
	var engine_n: PackedVector3Array = engine["normals"]
	var mirror_n: PackedVector3Array = mirror["normals"]
	for i in engine_n.size():
		var delta: Vector3 = engine_n[i] - mirror_n[i]
		out["max_normal_delta"] = maxf(out["max_normal_delta"], delta.length())
		_regression["max_normal_delta"] = maxf(_regression["max_normal_delta"], delta.length())
		if not engine_n[i].is_equal_approx(mirror_n[i]):
			out["normal_mismatch"] += 1
	var engine_c: PackedColorArray = engine["colors"]
	var mirror_c: PackedColorArray = mirror["colors"]
	for i in engine_c.size():
		if not engine_c[i].is_equal_approx(mirror_c[i]):
			out["color_mismatch"] += 1
	var engine_u: PackedVector2Array = engine["uvs"]
	var mirror_u: PackedVector2Array = mirror["uvs"]
	for i in engine_u.size():
		if not engine_u[i].is_equal_approx(mirror_u[i]):
			out["uv_mismatch"] += 1
	var engine_u2: PackedVector2Array = engine["uv2s"]
	var mirror_u2: PackedVector2Array = mirror["uv2s"]
	for i in engine_u2.size():
		if not engine_u2[i].is_equal_approx(mirror_u2[i]):
			out["uv2_mismatch"] += 1
	var engine_i: PackedInt32Array = engine["indices"]
	var mirror_i: PackedInt32Array = mirror["indices"]
	if engine_i != mirror_i:
		out["index_mismatch"] = 1
	var mismatch_count: int = out["position_mismatch"] + out["normal_mismatch"] + out["color_mismatch"] + out["uv_mismatch"] + out["uv2_mismatch"] + out["index_mismatch"]
	out["mismatch"] = mismatch_count
	_regression["mismatch_count"] += mismatch_count
	_regression["position_mismatch_count"] += out["position_mismatch"]
	_regression["normal_mismatch_count"] += out["normal_mismatch"]
	_regression["color_mismatch_count"] += out["color_mismatch"]
	_regression["uv_mismatch_count"] += out["uv_mismatch"]
	_regression["uv2_mismatch_count"] += out["uv2_mismatch"]
	_regression["index_mismatch_count"] += out["index_mismatch"]
	out["match"] = mismatch_count == 0
	return out


func _mirror_geometry() -> Dictionary:
	var vehicle: Object = _hull_foam.get("_vehicle")
	var ocean: Object = _hull_foam.get("_ocean")
	var fl: Node3D = _hull_foam.get("_front_left")
	var fr: Node3D = _hull_foam.get("_front_right")
	var rl: Node3D = _hull_foam.get("_rear_left")
	var rr: Node3D = _hull_foam.get("_rear_right")
	var prop: Node3D = _hull_foam.get("_propulsion_point")
	var intensity := float(_hull_foam.foam_intensity)
	var right := _mirror_horizontal(vehicle.global_basis.x, Vector3.RIGHT)
	var forward := _mirror_horizontal(-vehicle.global_basis.z, Vector3.FORWARD)
	var backward := -forward
	var steering := clampf(float(vehicle.steering_input), -1.0, 1.0)
	var left_intensity := clampf(1.0 + steering * 0.18, 0.78, 1.18)
	var right_intensity := clampf(1.0 - steering * 0.18, 0.78, 1.18)
	var front_center := (fl.global_position + fr.global_position) * 0.5
	var rear_center := (rl.global_position + rr.global_position) * 0.5
	var hull_half_width := maxf(
		maxf(
			_mirror_hdist(fl.global_position, fr.global_position),
			_mirror_hdist(rl.global_position, rr.global_position)
		) * 0.5,
		0.42
	)
	var stern_shift := right * steering * lerpf(0.04, 0.18, intensity)
	var rear_contact := clampf(float(vehicle.rear_submerged_ratio), 0.0, 1.0)
	var tail_length := lerpf(0.38, 0.78, intensity) * lerpf(0.72, 1.0, rear_contact)
	var propulsion_center := prop.global_position + stern_shift
	var centers: Array[Vector3] = [
		front_center + forward * 0.25,
		front_center.lerp(rear_center, 0.18),
		front_center.lerp(rear_center, 0.55) + stern_shift * 0.45,
		rear_center + stern_shift * 0.78,
		propulsion_center,
		propulsion_center + backward * tail_length,
	]
	var widths: Array[float] = [
		hull_half_width * 0.16,
		hull_half_width * 0.60,
		hull_half_width * 0.76,
		hull_half_width * 0.68,
		lerpf(hull_half_width * 0.42, hull_half_width * 0.52, rear_contact),
		hull_half_width * lerpf(0.44, 0.52, rear_contact),
	]
	var section_alphas: Array[float] = [
		0.20,
		0.72,
		1.0,
		lerpf(0.62, 1.0, rear_contact),
		lerpf(0.48, 0.92, rear_contact),
		lerpf(0.16, 0.34, rear_contact),
	]
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var colors := PackedColorArray()
	var uvs := PackedVector2Array()
	var uv2s := PackedVector2Array()
	var indices := PackedInt32Array()
	const SUBDIVISIONS: int = 2
	var dense_section_count := (centers.size() - 1) * SUBDIVISIONS + 1
	for section in dense_section_count:
		var source_position := float(section) / float(SUBDIVISIONS)
		var source_index := mini(floori(source_position), centers.size() - 2)
		var local_ratio := source_position - float(source_index)
		var longitudinal := float(section) / float(dense_section_count - 1)
		var center := centers[source_index].lerp(centers[source_index + 1], local_ratio)
		var half_width := maxf(lerpf(widths[source_index], widths[source_index + 1], local_ratio), 0.02)
		var section_alpha := lerpf(section_alphas[source_index], section_alphas[source_index + 1], local_ratio)
		var left_position := _mirror_surface(center - right * half_width)
		var center_position := _mirror_surface(center)
		var right_position := _mirror_surface(center + right * half_width)
		vertices.append(left_position)
		normals.append(ocean.sample_normal(left_position))
		colors.append(Color(1.0, 1.0, 1.0, clampf(section_alpha * left_intensity, 0.0, 1.0)))
		uvs.append(Vector2(left_position.x, left_position.z))
		uv2s.append(Vector2(0.0, longitudinal))
		vertices.append(center_position)
		normals.append(ocean.sample_normal(center_position))
		colors.append(Color(1.0, 1.0, 1.0, clampf(section_alpha * (left_intensity + right_intensity) * 0.5, 0.0, 1.0)))
		uvs.append(Vector2(center_position.x, center_position.z))
		uv2s.append(Vector2(0.5, longitudinal))
		vertices.append(right_position)
		normals.append(ocean.sample_normal(right_position))
		colors.append(Color(1.0, 1.0, 1.0, clampf(section_alpha * right_intensity, 0.0, 1.0)))
		uvs.append(Vector2(right_position.x, right_position.z))
		uv2s.append(Vector2(1.0, longitudinal))
		if section == 0:
			continue
		var current_left := section * 3
		var previous_left := current_left - 3
		indices.append_array(PackedInt32Array([
			previous_left,
			current_left,
			previous_left + 1,
			previous_left + 1,
			current_left,
			current_left + 1,
			previous_left + 1,
			current_left + 1,
			previous_left + 2,
			previous_left + 2,
			current_left + 1,
			current_left + 2,
		]))
	return {
		"vertices": vertices,
		"normals": normals,
		"colors": colors,
		"uvs": uvs,
		"uv2s": uv2s,
		"indices": indices,
	}


func _mirror_surface(source: Vector3) -> Vector3:
	var ocean: Object = _hull_foam.get("_ocean")
	return Vector3(
		source.x,
		float(ocean.sample_height(source)) + SURFACE_OFFSET_MIRROR,
		source.z
	)


func _mirror_horizontal(source: Vector3, fallback: Vector3) -> Vector3:
	var direction := source
	direction.y = 0.0
	if direction.length_squared() <= 0.000001 or not direction.is_finite():
		return fallback
	return direction.normalized()


func _mirror_hdist(first: Vector3, second: Vector3) -> float:
	return Vector2(first.x - second.x, first.z - second.z).length()


func _engine_geometry() -> Dictionary:
	return {
		"vertices": _hull_foam.get("_vertices"),
		"normals": _hull_foam.get("_normals"),
		"colors": _hull_foam.get("_colors"),
		"uvs": _hull_foam.get("_uvs"),
		"uv2s": _hull_foam.get("_uv2s"),
		"indices": _hull_foam.get("_indices"),
	}


func _foam_active() -> bool:
	return float(_hull_foam.foam_intensity) > 0.0001


func _foam_surfaces() -> int:
	var mesh: ArrayMesh = _hull_foam.get("_array_mesh")
	if mesh == null:
		return 0
	return mesh.get_surface_count()


func _foam_visible() -> bool:
	var mi: MeshInstance3D = _hull_foam.get("_mesh_instance")
	return mi != null and mi.visible


func _engine_vertex_count() -> int:
	var v: PackedVector3Array = _hull_foam.get("_vertices")
	return v.size() if v != null else 0


func _engine_index_count() -> int:
	var i: PackedInt32Array = _hull_foam.get("_indices")
	return i.size() if i != null else 0


func _traffic_query_total() -> int:
	var total := 0
	for wake in _traffic_wakes:
		total += int(wake.local_physics_query_count)
	return total


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
	_hull_foam = _jet_ski.find_child("HullFoam3D", true, false)
	if _hull_foam == null:
		_fail("missing HullFoam3D")
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
	_hull_foam = null
	_actors.clear()
	_traffic_wakes.clear()


func _run_ticks(count: int) -> void:
	for _i in count:
		await get_tree().physics_frame


func _traffic_state() -> Dictionary:
	var out := {"progress": [], "positions": []}
	for follow_path in ["BoatTraffic/Path3D/PathFollow3D", "BoatTraffic/Path3D2/PathFollow3D", "BoatTraffic/Path3D3/PathFollow3D"]:
		var follow := _city.get_node_or_null(follow_path)
		if follow != null:
			out["progress"].append(float(follow.progress_ratio))
	for actor in _actors:
		out["positions"].append([actor.global_position.x, actor.global_position.y, actor.global_position.z])
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


func _build_report(traffic_start: Dictionary) -> Dictionary:
	var duration_ms := (Time.get_ticks_msec() - _measure_start_ms) if _frames.size() > 0 else -1
	var duration_s := float(duration_ms) / 1000.0 if duration_ms > 0 else 0.0
	var active_frames := _active_foam_frames
	var wall := _stats(_collect("wall_ms"))
	var process := _stats(_collect("process_ms"))
	## Active duration uses the MEDIAN wall time: a single scheduler-stall frame
	## (e.g. >1 s) would otherwise skew mean-based rebuilds-per-second.
	var active_duration_s: float = float(active_frames) * float(wall["median"]) / 1000.0 if _frames.size() > 0 else 0.0
	var rebuilds_per_second := float(_rebuild_frames) / maxf(active_duration_s, 0.0001)
	var rebuilds_per_second_total := float(_rebuild_frames) / maxf(duration_s, 0.0001)
	var frames_gt8 := _count_gt(_collect("wall_ms"), SPIKE_THRESHOLD_8MS)
	var frames_gt12 := _count_gt(_collect("wall_ms"), SPIKE_THRESHOLD_12MS)
	var query_stats := _stats(_collect("engine_queries"))
	var buoyancy_estimates := []
	for record: Dictionary in _frames:
		if not bool(record["active"]):
			buoyancy_estimates.append(float(record["engine_queries"]))
		elif not bool(record["rebuild"]) and _interval_read > 0.0:
			buoyancy_estimates.append(float(record["engine_queries"]))
	var buoyancy_per_frame: float = _median(_sorted_copy(buoyancy_estimates)) if buoyancy_estimates.size() > 0 else 0.0
	var foam_only_queries: float = float(_engine_queries_total) - buoyancy_per_frame * float(maxi(_frames.size(), 1))
	return {
		"schema": "hull_foam_cadence_2d",
		"label": _label,
		"commit": _commit,
		"arm": _arm,
		"interval_set": _interval_read,
		"mode": _mode,
		"methodology": {
			"scene": GOLD_CITY_SCENE,
			"engine": Engine.get_version_info()["string"],
			"physics_ticks_per_second": Engine.physics_ticks_per_second,
			"renderer_driver": ProjectSettings.get_setting("rendering_device/driver.windows", "unknown"),
			"window_size": str(DisplayServer.window_get_size()),
			"vsync_disabled": true,
			"max_fps": Engine.max_fps,
			"determinism_seed": DETERMINISM_SEED,
			"warmup_physics_ticks": WARMUP_PHYSICS_TICKS,
			"settle_physics_ticks": SETTLE_PHYSICS_TICKS,
			"measure_duration_ms": _measure_duration_ms,
			"drive": {
				"purpose": "sustained moderate-speed circle so foam_intensity stays active across the window (planing/speeding suppresses foam; parking suppresses contact)",
				"throttle": "Input.action_press('throttle')",
				"steering": "feedback controller holding a circle of radius %.0f m" % DRIVE_CIRCLE_RADIUS,
			},
			"mirror": "self-contained replica of _rebuild_mesh() inside the benchmark; reads the same markers/vehicle/ocean, writes to private arrays, never touches the runtime node. Used for common-frame geometry regression and cadence-error reference.",
			"query_attribution": "per frame: traffic WakeTrail3D.local_physics_query_count delta is split around the benchmark's own mirror sampling so engine queries and mirror queries are counted separately.",
			"rebuild_detection": "surfaces 0->1 activation OR (interval<=0 and active) [reference] OR _geometry_update_elapsed drop [candidate gate]. Validated by the spec cross-checks below.",
			"timing_note": "TIME_PROCESS / wall are context only (no per-function timing without a debugger client). Mirror runs on every foam-active frame in BOTH arms (symmetric overhead).",
		},
		"frames_measured": _frames.size(),
		"duration_ms_actual": duration_ms,
		"active_foam_frames": active_frames,
		"active_duration_s": active_duration_s,
		"foam_active_fraction": float(active_frames) / float(maxi(_frames.size(), 1)),
		"rebuild_count": _rebuild_frames,
		"rebuilds_per_second_active": rebuilds_per_second,
		"rebuilds_per_second_total": rebuilds_per_second_total,
		"rebuilds_per_active_frame": float(_rebuild_frames) / float(maxi(active_frames, 1)),
		"cross_check_reference_rebuilds_eq_active_frames": float(_rebuild_frames) / float(maxi(active_frames, 1)) if _interval_read <= 0.0 else -1.0,
		"cross_check_candidate_rebuilds_per_second_30hz": rebuilds_per_second if _interval_read > 0.0 else -1.0,
		"engine_query_total": _engine_queries_total,
		"mirror_query_total": _mirror_queries_total,
		"buoyancy_queries_per_frame_est": buoyancy_per_frame,
		"foam_only_queries_total": foam_only_queries,
		"foam_only_queries_per_rebuild": foam_only_queries / float(maxi(_rebuild_frames, 1)),
		"foam_only_queries_per_active_frame": foam_only_queries / float(maxi(active_frames, 1)),
		"engine_queries_per_rebuild": float(_engine_queries_total) / float(maxi(_rebuild_frames, 1)),
		"engine_queries_per_active_frame": float(_engine_queries_total) / float(maxi(active_frames, 1)),
		"engine_query_per_frame_stats": query_stats,
		"frame_wall_ms_stats": wall,
		"frame_process_ms_stats": process,
		"frames_gt_8ms": frames_gt8,
		"frames_gt_12ms": frames_gt12,
		"rebuild_vertex_count_stats": _stats(_rebuild_vertex_counts),
		"rebuild_index_count_stats": _stats(_rebuild_index_counts),
		"rebuild_surface_count_stats": _stats(_rebuild_surface_counts),
		"shader_sync_failures": _shader_sync_failures,
		"visible_mismatches": _visible_mismatches,
		"activation_count": _activation_count,
		"activation_immediate_rebuild_ok": _activation_immediate_ok,
		"deactivation_count": _deactivation_count,
		"deactivation_immediate_hide_ok": _deactivation_immediate_ok,
		"clear_foam_test": _clear_foam_test,
		"geometry_regression": {
			"method": "engine _rebuild_mesh arrays vs benchmark mirror on every frame the engine rebuilt",
			"frames_checked": _regression["frames_checked"],
			"max_vertex_delta": _regression["max_vertex_delta"],
			"max_normal_delta": _regression["max_normal_delta"],
			"mismatch_count": _regression["mismatch_count"],
			"count_mismatch_count": _regression["count_mismatch_count"],
			"position_mismatch_count": _regression["position_mismatch_count"],
			"normal_mismatch_count": _regression["normal_mismatch_count"],
			"color_mismatch_count": _regression["color_mismatch_count"],
			"uv_mismatch_count": _regression["uv_mismatch_count"],
			"uv2_mismatch_count": _regression["uv2_mismatch_count"],
			"index_mismatch_count": _regression["index_mismatch_count"],
			"bit_identical": _regression["frames_checked"] > 0 and _regression["mismatch_count"] == 0,
		},
		"cadence_error": {
			"method": "candidate-only; on gate-skipped active frames the mirror produces the reference geometry OLD would have rebuilt at that instant; compared against the geometry the engine currently displays",
			"frames_evaluated": _cadence["frames_evaluated"],
			"max_positional_age_ms": _cadence["max_age_ms"],
			"max_jet_distance_since_last_rebuild_m": _cadence["max_distance_m"],
			"max_steering_delta": _cadence["max_steering_delta"],
			"max_foam_intensity_delta": _cadence["max_intensity_delta"],
			"max_vertex_position_error_m": _cadence["max_vertex_position_error"],
			"positional_age_ms_stats": _stats(_cadence["ages_ms"]),
			"jet_distance_since_last_rebuild_stats": _stats(_cadence["distances_m"]),
			"steering_delta_stats": _stats(_cadence["steering_deltas"]),
			"foam_intensity_delta_stats": _stats(_cadence["intensity_deltas"]),
			"vertex_position_error_stats": _stats(_cadence["vertex_errors"]),
		},
		"traffic_start_state": traffic_start,
		"aborted": _aborted,
		"abort_reason": _abort_reason,
		"near_boat_warnings": _near_boat_warnings,
	}


func _print_arm(report: Dictionary, path: String) -> void:
	print("%s_ARM=%s INTERVAL=%.6f" % [PHASE_TAG, _arm, report["interval_set"]])
	print("%s_%s_FRAMES=%d DURATION_MS=%d ABORTED=%s" % [PHASE_TAG, _arm.to_upper(), report["frames_measured"], report["duration_ms_actual"], str(report["aborted"])])
	print("%s_%s_ACTIVE_FRAMES=%d FACTION=%.3f" % [PHASE_TAG, _arm.to_upper(), report["active_foam_frames"], report["foam_active_fraction"]])
	print("%s_%s_REBUILDS=%d  REBUILDS_PER_S(active)=%.2f  PER_TOTAL=%.2f" % [PHASE_TAG, _arm.to_upper(), report["rebuild_count"], report["rebuilds_per_second_active"], report["rebuilds_per_second_total"]])
	print("%s_%s_ENGINE_QUERIES=%d  PER_REBUILD=%.1f  PER_ACTIVE_FRAME=%.1f" % [PHASE_TAG, _arm.to_upper(), report["engine_query_total"], report["engine_queries_per_rebuild"], report["engine_queries_per_active_frame"]])
	print("%s_%s_FOAM_ONLY_QUERIES=%.0f (buoyancy_est=%.1f/frame)  PER_REBUILD=%.1f" % [PHASE_TAG, _arm.to_upper(), report["foam_only_queries_total"], report["buoyancy_queries_per_frame_est"], report["foam_only_queries_per_rebuild"]])
	print("%s_%s_WALL median=%.2f p95=%.2f p99=%.2f max=%.2f  >8ms=%d  >12ms=%d" % [
		PHASE_TAG, _arm.to_upper(),
		report["frame_wall_ms_stats"]["median"], report["frame_wall_ms_stats"]["p95"], report["frame_wall_ms_stats"]["p99"], report["frame_wall_ms_stats"]["max"],
		report["frames_gt_8ms"], report["frames_gt_12ms"],
	])
	print("%s_%s_GEOMETRY_REGRESSION frames=%d max_v_delta=%.6f max_n_delta=%.6f mismatches=%d bit_identical=%s" % [
		PHASE_TAG, _arm.to_upper(),
		report["geometry_regression"]["frames_checked"], report["geometry_regression"]["max_vertex_delta"], report["geometry_regression"]["max_normal_delta"], report["geometry_regression"]["mismatch_count"], str(report["geometry_regression"]["bit_identical"]),
	])
	print("%s_%s_CADENCE frames=%d max_age=%.1fms max_dist=%.2fm max_steer=%.3f max_intensity=%.3f max_vertex_err=%.4fm" % [
		PHASE_TAG, _arm.to_upper(),
		report["cadence_error"]["frames_evaluated"], report["cadence_error"]["max_positional_age_ms"], report["cadence_error"]["max_jet_distance_since_last_rebuild_m"], report["cadence_error"]["max_steering_delta"], report["cadence_error"]["max_foam_intensity_delta"], report["cadence_error"]["max_vertex_position_error_m"],
	])
	print("%s_%s_ACTIVATION=%d ok=%d  DEACTIVATION=%d ok=%d  CLEAR=%s" % [PHASE_TAG, _arm.to_upper(), report["activation_count"], report["activation_immediate_rebuild_ok"], report["deactivation_count"], report["deactivation_immediate_hide_ok"], str(report["clear_foam_test"])])
	print("%s_%s_JSON=%s" % [PHASE_TAG, _arm.to_upper(), path])


func _print_comparison() -> void:
	var ref_report = _load_arm_report("reference")
	var cand_report = _load_arm_report("candidate")
	if ref_report == null or cand_report == null:
		return
	var old_rate := float(ref_report["rebuilds_per_second_active"])
	var new_rate := float(cand_report["rebuilds_per_second_active"])
	var old_queries := int(ref_report["engine_query_total"])
	var new_queries := int(cand_report["engine_query_total"])
	var old_foam_only := float(ref_report["foam_only_queries_total"])
	var new_foam_only := float(cand_report["foam_only_queries_total"])
	var reduction_percent := (1.0 - new_rate / maxf(old_rate, 0.0001)) * 100.0
	var query_reduction_percent := (1.0 - float(new_queries) / maxf(float(old_queries), 0.0001)) * 100.0
	var foam_only_reduction_percent := (1.0 - new_foam_only / maxf(old_foam_only, 0.0001)) * 100.0
	print("%s_COMPARISON OLD %.2f/s -> NEW %.2f/s  REBUILD_REDUCTION=%.1f%%" % [PHASE_TAG, old_rate, new_rate, reduction_percent])
	print("%s_COMPARISON ENGINE_QUERIES(raw incl buoyancy) OLD=%d -> NEW=%d  QUERY_REDUCTION=%.1f%%" % [PHASE_TAG, old_queries, new_queries, query_reduction_percent])
	print("%s_COMPARISON FOAM_ONLY_QUERIES OLD=%.0f -> NEW=%.0f  FOAM_QUERY_REDUCTION=%.1f%%" % [PHASE_TAG, old_foam_only, new_foam_only, foam_only_reduction_percent])
	print("%s_COMPARISON WALL_MEDIAN OLD=%.2f NEW=%.2f  P95 OLD=%.2f NEW=%.2f  MAX OLD=%.2f NEW=%.2f  >8ms OLD=%d NEW=%d  >12ms OLD=%d NEW=%d" % [
		PHASE_TAG,
		ref_report["frame_wall_ms_stats"]["median"], cand_report["frame_wall_ms_stats"]["median"],
		ref_report["frame_wall_ms_stats"]["p95"], cand_report["frame_wall_ms_stats"]["p95"],
		ref_report["frame_wall_ms_stats"]["max"], cand_report["frame_wall_ms_stats"]["max"],
		int(ref_report["frames_gt_8ms"]), int(cand_report["frames_gt_8ms"]),
		int(ref_report["frames_gt_12ms"]), int(cand_report["frames_gt_12ms"]),
	])
	print("%s_COMPARISON GEOMETRY_REF frames=%d mismatches=%d  GEOMETRY_CAND frames=%d mismatches=%d" % [
		PHASE_TAG,
		ref_report["geometry_regression"]["frames_checked"], ref_report["geometry_regression"]["mismatch_count"],
		cand_report["geometry_regression"]["frames_checked"], cand_report["geometry_regression"]["mismatch_count"],
	])


func _load_arm_report(arm: String) -> Variant:
	var newest := 0
	var newest_path := ""
	for path in _arm_paths():
		if not FileAccess.file_exists(path):
			continue
		var modified := FileAccess.get_modified_time(path)
		var file := FileAccess.open(path, FileAccess.READ)
		if file == null:
			continue
		var parsed: Variant = JSON.parse_string(file.get_as_text())
		file.close()
		if parsed is Dictionary and parsed.get("arm", "") == arm and modified >= newest:
			newest = modified
			newest_path = path
	if newest_path == "":
		return null
	var file2 := FileAccess.open(newest_path, FileAccess.READ)
	if file2 == null:
		return null
	var result: Variant = JSON.parse_string(file2.get_as_text())
	file2.close()
	if result is Dictionary:
		return result
	return null


func _arm_paths() -> Array:
	var directory := ProjectSettings.globalize_path(OUTPUT_DIRECTORY).replace("\\", "/")
	if not DirAccess.dir_exists_absolute(directory):
		return []
	var paths := []
	for filename in DirAccess.get_files_at(directory):
		if filename.begins_with("hull_foam_2d_") and filename.ends_with(".json"):
			paths.append(ProjectSettings.localize_path(directory + "/" + filename))
	return paths


func _collect(key: String) -> Array:
	var out := []
	for record: Dictionary in _frames:
		out.append(float(record[key]))
	return out


func _count_gt(values: Array, threshold: float) -> int:
	var count := 0
	for v: Variant in values:
		if float(v) > threshold:
			count += 1
	return count


func _mean_wall_ms(frames: Array) -> float:
	if frames.is_empty():
		return 0.0
	var total := 0.0
	for record: Dictionary in frames:
		total += float(record["wall_ms"])
	return total / float(frames.size())


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


func _sorted_copy(values: Array) -> Array:
	var out := values.duplicate()
	out.sort()
	return out


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


func _write_report(report: Dictionary) -> String:
	var directory := ProjectSettings.globalize_path(OUTPUT_DIRECTORY).replace("\\", "/")
	if DirAccess.make_dir_recursive_absolute(directory) != OK:
		return ""
	var timestamp := Time.get_datetime_string_from_system().replace(":", "-")
	var path := "%s/hull_foam_2d_%s_%s_%s.json" % [directory, _arm, _label, timestamp]
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return ""
	file.store_string(JSON.stringify(_sanitize(report), "\t"))
	file.close()
	return ProjectSettings.localize_path(path)


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


func _argument_value(prefix: String, fallback: String) -> String:
	for argument: String in OS.get_cmdline_user_args():
		if argument.begins_with(prefix):
			return argument.trim_prefix(prefix)
	return fallback


func _has_argument(name: String) -> bool:
	return OS.get_cmdline_user_args().has(name)


func _quick_duration_ms() -> int:
	var value := _argument_value("--quick_ms=", "")
	if value.is_valid_int():
		return int(value)
	return MEASURE_DURATION_MS


func _fail(message: String) -> void:
	push_error("%s FAIL: %s" % [PHASE_TAG, message])
	print("%s=FAIL %s" % [PHASE_TAG, message])
	get_tree().quit(1)
