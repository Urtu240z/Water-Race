extends Node

## Phase 2B — Gold City physics tick attribution (deterministic fresh-scene arms).
## Diagnostic only. Runtime ablations are transient (apply -> measure -> restore -> verify).
## Every arm (BASELINE BEFORE / VARIANT / BASELINE AFTER) runs from a brand-new, freshly
## loaded Gold City instance so boats/wakes/history start from the same logical state.
## No runtime file is modified. No permanent behaviour change.

const GOLD_CITY_SCENE := "res://levels/gold_city/gold_city.tscn"
const OUTPUT_DIRECTORY := "res://.godot/benchmarks_2b"
const PHASE_TAG := "GOLD_CITY_PHASE_2B"

const WARMUP_PHYSICS_TICKS := 600
const SETTLE_PHYSICS_TICKS := 60
const BLOCK_PHYSICS_TICKS := 400
const MAX_BASELINE_DIVERGENCE := 0.25
const CONTROLLED_DISTANCE := 140.0
const NEAR_VOLUME_DISTANCE := 250.0
const DETERMINISM_SEED := 20260818

## Fingerprint comparison tolerances. Positions/progress are allowed to drift by up to
## ~1 engine physics tick of traffic-boat travel (phase-anchor jitter between fresh loads);
## integer wake-history state (sample_count / first_recent / directional_export_count) must
## match exactly.
const FINGERPRINT_POSITION_EPSILON := 0.6
const FINGERPRINT_PROGRESS_EPSILON := 0.001
const FINGERPRINT_JETSKI_BASIS_EPSILON := 0.06

## Baseline references from Phase 2A rendered run (same machine/config) for context only.
const PHASE_2A_TRAFFIC_VISIBLE_PHYSICS_MS := 9.119
const PHASE_2A_SPAWN_STATIONARY_PHYSICS_MS := 2.509

var _packed: PackedScene
var _label := _argument_value("--label=", "unlabelled")
var _commit := _argument_value("--commit=", "unknown")
var _mode := DisplayServer.get_name()

var _city: Node
var _jet_ski: RigidBody3D
var _camera: Camera3D
var _spawn: Node3D
var _actors: Array = []
var _follows: Array = []
var _wakes: Array = []
var _exclusions: Array = []

var _controlled_pos := Vector3.ZERO
var _controlled_fwd := Vector3.FORWARD


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	var parent := get_parent()
	if parent != null and parent != get_tree().root:
		parent.remove_child(self)
		get_tree().root.add_child(self)
	if get_tree().current_scene == self:
		get_tree().current_scene = null
	call_deferred(&"_run")


func _run() -> void:
	Engine.max_fps = 0
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)

	_packed = load(GOLD_CITY_SCENE) as PackedScene
	if _packed == null:
		_fail("cannot load scene")
		return

	var variant_specs := [
		{"name": "BASELINE", "kind": "none"},
		{"name": "TRAFFIC_ACTOR_SCRIPT_OFF", "kind": "physics_process", "nodes": _actors},
		{"name": "WAKE_MAINTENANCE_OFF", "kind": "physics_process", "nodes": _wakes},
		{"name": "LOCAL_WAKE_PHYSICS_OFF", "kind": "wake_physics", "nodes": _wakes},
		{"name": "TRAFFIC_COLLISION_OFF", "kind": "body_collision", "bodies": _actors},
		{"name": "EXCLUSION_OFF", "kind": "exclusion", "nodes": _exclusions},
		{"name": "JETSKI_SCRIPT_OFF", "kind": "subtree_phys"},
		{"name": "JETSKI_BODY_OFF", "kind": "jetski_body_collision"},
		{"name": "CAMERA_AWAY", "kind": "camera_away"},
	]

	var bracket_results: Array = []
	for spec: Dictionary in variant_specs:
		var result := await _run_bracket(spec)
		bracket_results.append(result)
		_print_variant(result)

	var inventory := _collect_inventory()
	var final_pose := _pose_dict()
	var final_actor_positions := _actor_positions()
	await _dispose_city()

	var visibility := _visibility_summary(bracket_results)
	var context_note := "Phase 2A rendered sessions on this machine: spawn stationary physics median=%.3f ms; TRAFFIC_VISIBLE (boats ~200 m, in frustum) physics median=%.3f ms. This run re-loads a fresh Gold City per arm." % [PHASE_2A_SPAWN_STATIONARY_PHYSICS_MS, PHASE_2A_TRAFFIC_VISIBLE_PHYSICS_MS]

	var baseline := _find_result(bracket_results, "BASELINE")
	var baseline_median: float = baseline["baseline_local_median"]
	var attributed := _attribution(bracket_results)
	var residual := maxf(0.0, baseline_median - attributed["sum_deltas_ms"])

	var arms: Array = []
	for result: Dictionary in bracket_results:
		arms.append_array(result["arms"])

	var report := {
		"schema": "gold_city_physics_attribution_2b_v2",
		"label": _label,
		"commit": _commit,
		"mode": _mode,
		"snapshot": _snapshot_fingerprint(),
		"methodology": {
			"scene": GOLD_CITY_SCENE,
			"engine": Engine.get_version_info()["string"],
			"physics_ticks_per_second": Engine.physics_ticks_per_second,
			"physics_engine": ProjectSettings.get_setting("physics/3d/physics_engine", "unknown"),
			"renderer_driver": ProjectSettings.get_setting("rendering_device/driver.windows", "unknown"),
			"window_size": str(DisplayServer.window_get_size()),
			"vsync_disabled": true,
			"max_fps": 0,
			"principle": "fresh deterministic Gold City per arm; BEFORE / VARIANT / AFTER each start from the same logical traffic state",
			"determinism_seed": DETERMINISM_SEED,
			"warmup_physics_ticks": WARMUP_PHYSICS_TICKS,
			"settle_physics_ticks": SETTLE_PHYSICS_TICKS,
			"measure_physics_ticks_per_block": BLOCK_PHYSICS_TICKS,
			"max_baseline_divergence": MAX_BASELINE_DIVERGENCE,
			"fingerprint": {
				"captured_pre_apply": true,
				"fields": [
					"path3d_progress_ratio x3",
					"boat_traffic_actor_global_positions x3",
					"wake_sample_count x3",
					"wake_first_recent_sample_index x3 (if available)",
					"wake_directional_export_count x3",
					"jet_ski_pose",
					"camera_pose",
				],
				"match_requirement": "BEFORE/VARIANT/AFTER fingerprints must match (integer wake state exact; float fields within the phase-anchor envelope)",
				"position_epsilon_m": FINGERPRINT_POSITION_EPSILON,
				"progress_epsilon": FINGERPRINT_PROGRESS_EPSILON,
				"jet_ski_basis_epsilon": FINGERPRINT_JETSKI_BASIS_EPSILON,
			},
			"attribution_metric": "Performance.TIME_PHYSICS_PROCESS per physics tick (engine seconds * 1000 = ms)",
			"controlled_pose": final_pose,
			"actor_world_positions": final_actor_positions,
			"context_note": context_note,
		},
		"inventory": inventory,
		"arms": arms,
		"variants": bracket_results,
		"visibility_control": visibility,
		"attribution": attributed,
		"residual_unattributed_ms": residual,
		"recommendation_2c": _recommendation(attributed, baseline_median, residual),
		"runtime_files_modified": 0,
	}

	var report_path := _write_report(report)
	if report_path == "":
		_fail("cannot write report")
		return

	print("%s_MODE=%s" % [PHASE_TAG, _mode])
	print("%s_SNAPSHOT=%s" % [PHASE_TAG, report["snapshot"]])
	print("%s_CONTROLLED_POSE %s" % [PHASE_TAG, JSON.stringify(final_pose).replace("\n", " ")])
	print("%s_BASELINE median=%.4f ms  phase2a_traffic_visible=%.3f ms  phase2a_spawn_stationary=%.3f ms" % [PHASE_TAG, baseline_median, PHASE_2A_TRAFFIC_VISIBLE_PHYSICS_MS, PHASE_2A_SPAWN_STATIONARY_PHYSICS_MS])
	print("%s_ATTRIBUTION sum_deltas_ms=%.3f  sum_abs_deltas_ms=%.3f  residual_ms=%.3f" % [PHASE_TAG, attributed["sum_deltas_ms"], attributed["sum_abs_deltas_ms"], residual])
	print("%s_JSON=%s" % [PHASE_TAG, report_path])
	print("%s=PASS" % PHASE_TAG)
	get_tree().quit(0)


func _run_bracket(spec: Dictionary) -> Dictionary:
	var name: String = spec["name"]
	var before := await _run_arm(spec, false)
	var variant := await _run_arm(spec, true)
	var after := await _run_arm(spec, false)

	var match_bv: bool = _fingerprints_match(before["fingerprint_pre"], variant["fingerprint_pre"])
	var match_va: bool = _fingerprints_match(variant["fingerprint_pre"], after["fingerprint_pre"])
	var fingerprints_match: bool = match_bv and match_va

	var before_median: float = before["median"]
	var variant_median: float = variant["median"]
	var after_median: float = after["median"]

	var all_values: Array = before["values"] + after["values"]
	all_values.sort()
	var local_stats := _stats(all_values)
	var local_baseline_median: float = local_stats["median"]
	var divergence: float = absf(after_median - before_median) / ((after_median + before_median) * 0.5) if (after_median + before_median) > 0.0 else 0.0
	var delta_ms: float = variant_median - local_baseline_median
	var delta_percent: float = delta_ms / local_baseline_median * 100.0 if local_baseline_median > 0.0 else 0.0
	var apply_expected: bool = spec.get("kind", "none") != "none"
	var restore_ok: bool = not apply_expected or variant["restore_ok"]
	var valid: bool = divergence <= MAX_BASELINE_DIVERGENCE and fingerprints_match and restore_ok

	var result := {
		"name": name,
		"arms": [
			before["arm"],
			variant["arm"],
			after["arm"],
		],
		"baseline_before_median": before_median,
		"baseline_after_median": after_median,
		"baseline_local_median": local_baseline_median,
		"baseline_divergence": divergence,
		"variant_median": variant_median,
		"delta_ms": delta_ms,
		"delta_percent": delta_percent,
		"valid": valid,
		"fingerprints_match": fingerprints_match,
		"fingerprints_match_before_variant": match_bv,
		"fingerprints_match_variant_after": match_va,
		"restore_verified": restore_ok,
		"distribution_before": before["stats"],
		"distribution_variant": variant["stats"],
		"distribution_after": after["stats"],
	}
	return result


func _run_arm(spec: Dictionary, apply: bool) -> Dictionary:
	seed(DETERMINISM_SEED)
	await _load_fresh_city()
	await _run_ticks(WARMUP_PHYSICS_TICKS)

	_establish_controlled_pose()
	await _run_ticks(SETTLE_PHYSICS_TICKS)

	var fingerprint_pre := _capture_fingerprint()

	var saves: Array = []
	var restore_ok := true
	if apply:
		saves = _variant_apply(spec)

	var values: Array = await _measure_ticks(BLOCK_PHYSICS_TICKS)

	if apply:
		var ok_restore := _variant_restore(saves)
		var ok_verify := _variant_verify(saves)
		restore_ok = ok_restore and ok_verify

	var stats := _stats(values)
	var arm := {
		"variant": spec["name"],
		"applied": apply,
		"fingerprint_pre": fingerprint_pre,
		"restore_ok": restore_ok,
		"distribution": stats,
	}

	await _dispose_city()
	return {
		"median": stats["median"],
		"stats": stats,
		"values": values,
		"fingerprint_pre": fingerprint_pre,
		"restore_ok": restore_ok,
		"arm": arm,
	}


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
	if _jet_ski == null or _camera == null or _spawn == null:
		_fail("missing JetSki / Camera / PlayerSpawn")
		return

	_actors.clear()
	_follows.clear()
	_wakes.clear()
	_exclusions.clear()
	for i in 3:
		var lane := "BoatTraffic/Path3D%s" % ("" if i == 0 else str(i + 1))
		var follow := _city.get_node_or_null(lane + "/PathFollow3D")
		if follow == null:
			_fail("missing path follow %d" % i)
			return
		_follows.append(follow)
		var actor := _city.get_node_or_null(lane + "/PathFollow3D/BoatTrafficActor")
		if actor == null:
			_fail("missing actor %d" % i)
			return
		_actors.append(actor)
		var wake := _city.get_node_or_null(lane + "/PathFollow3D/BoatTrafficActor/WakeRoot/BoatWake")
		if wake == null:
			_fail("missing wake %d" % i)
			return
		_wakes.append(wake)
		var exclusion := _city.get_node_or_null(lane + "/PathFollow3D/BoatTrafficActor/WaterExclusionVolume3D")
		if exclusion == null:
			_fail("missing exclusion %d" % i)
			return
		_exclusions.append(exclusion)


func _dispose_city() -> void:
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
	_actors.clear()
	_follows.clear()
	_wakes.clear()
	_exclusions.clear()


func _run_ticks(count: int) -> void:
	for _i in count:
		await get_tree().physics_frame


func _measure_ticks(count: int) -> Array:
	var values: Array = []
	for _i in count:
		await get_tree().physics_frame
		values.append(Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0)
	return values


func _capture_fingerprint() -> Dictionary:
	var follows_progress := []
	for follow in _follows:
		follows_progress.append(follow.progress_ratio)
	var actor_positions := []
	for actor in _actors:
		actor_positions.append(_sanitize([actor.global_position.x, actor.global_position.y, actor.global_position.z]))
	var wakes := []
	for wake in _wakes:
		var sample_count: Variant = wake.get("sample_count")
		var first_recent: Variant = wake.get("_physics_first_recent_sample_index")
		var export_count: Variant = wake.get("directional_export_count")
		wakes.append({
			"sample_count": int(sample_count if sample_count != null else -1),
			"first_recent": int(first_recent if first_recent != null else -1),
			"directional_export_count": int(export_count if export_count != null else -1),
		})
	var jet_pose := _jet_ski.global_transform
	var cam_pose := _camera.global_transform
	return {
		"path_follow_progress_ratio": follows_progress,
		"boat_actor_positions": actor_positions,
		"wakes": wakes,
		"jet_ski": {
			"origin": [jet_pose.origin.x, jet_pose.origin.y, jet_pose.origin.z],
			"basis_z": [jet_pose.basis.z.x, jet_pose.basis.z.y, jet_pose.basis.z.z],
		},
		"camera": {
			"origin": [cam_pose.origin.x, cam_pose.origin.y, cam_pose.origin.z],
			"basis_z": [cam_pose.basis.z.x, cam_pose.basis.z.y, cam_pose.basis.z.z],
		},
	}


func _fingerprints_match(a: Dictionary, b: Dictionary) -> bool:
	if a.is_empty() or b.is_empty():
		return false
	for i in _follows.size():
		if absf(float(a["path_follow_progress_ratio"][i]) - float(b["path_follow_progress_ratio"][i])) > FINGERPRINT_PROGRESS_EPSILON:
			return false
	for i in _actors.size():
		var pa: Array = a["boat_actor_positions"][i]
		var pb: Array = b["boat_actor_positions"][i]
		for axis in 3:
			if absf(float(pa[axis]) - float(pb[axis])) > FINGERPRINT_POSITION_EPSILON:
				return false
	for i in _wakes.size():
		var wa: Dictionary = a["wakes"][i]
		var wb: Dictionary = b["wakes"][i]
		if int(wa["sample_count"]) != int(wb["sample_count"]):
			return false
		if int(wa["directional_export_count"]) != int(wb["directional_export_count"]):
			return false
		if int(wa["first_recent"]) != -1 and int(wb["first_recent"]) != -1 and int(wa["first_recent"]) != int(wb["first_recent"]):
			return false
	var ja: Dictionary = a["jet_ski"]
	var jb: Dictionary = b["jet_ski"]
	for axis in 3:
		if absf(float(ja["origin"][axis]) - float(jb["origin"][axis])) > FINGERPRINT_POSITION_EPSILON:
			return false
		if absf(float(ja["basis_z"][axis]) - float(jb["basis_z"][axis])) > FINGERPRINT_JETSKI_BASIS_EPSILON:
			return false
	var ca: Dictionary = a["camera"]
	var cb: Dictionary = b["camera"]
	for axis in 3:
		if absf(float(ca["origin"][axis]) - float(cb["origin"][axis])) > 1.0:
			return false
		if absf(float(ca["basis_z"][axis]) - float(cb["basis_z"][axis])) > 0.1:
			return false
	return true


func _variant_apply(spec: Dictionary) -> Array:
	var saves: Array = []
	match spec.get("kind", "none"):
		"none":
			pass
		"physics_process":
			for node in spec["nodes"]:
				saves.append({"kind": "physics_process", "node": node, "saved": node.is_physics_processing()})
				node.set_physics_process(false)
		"wake_physics":
			for node in spec["nodes"]:
				saves.append({"kind": "wake_physics", "node": node, "saved": node.physics_enabled})
				node.physics_enabled = false
		"exclusion":
			for node in spec["nodes"]:
				saves.append({"kind": "exclusion", "node": node, "saved": node.enabled})
				node.enabled = false
		"body_collision":
			for body: CollisionObject3D in spec["bodies"]:
				saves.append({"kind": "layer", "node": body, "saved": body.collision_layer})
				saves.append({"kind": "mask", "node": body, "saved": body.collision_mask})
				body.collision_layer = 0
				body.collision_mask = 0
				for shape: CollisionShape3D in _collision_shapes(body):
					saves.append({"kind": "shape", "node": shape, "saved": shape.disabled})
					shape.disabled = true
		"subtree_phys":
			var root: Node = _jet_ski
			if root != null:
				for node in _physics_subtree(root):
					saves.append({"kind": "physics_process", "node": node, "saved": node.is_physics_processing()})
					node.set_physics_process(false)
		"jetski_body_collision":
			if _jet_ski != null:
				for body: CollisionObject3D in [_jet_ski]:
					saves.append({"kind": "layer", "node": body, "saved": body.collision_layer})
					saves.append({"kind": "mask", "node": body, "saved": body.collision_mask})
					body.collision_layer = 0
					body.collision_mask = 0
					for shape: CollisionShape3D in _collision_shapes(body):
						saves.append({"kind": "shape", "node": shape, "saved": shape.disabled})
						shape.disabled = true
		"camera_away":
			saves.append({"kind": "transform", "node": _jet_ski, "saved": Transform3D(Basis.looking_at(_controlled_fwd, Vector3.UP), _controlled_pos)})
			_place_jet_ski(_controlled_pos, -_controlled_fwd)
		_:
			push_warning("unknown variant kind: %s" % str(spec.get("kind", "none")))
	return saves


func _variant_restore(saves: Array) -> bool:
	var ok := true
	for s: Dictionary in saves:
		var node = s["node"]
		match s["kind"]:
			"physics_process":
				node.set_physics_process(bool(s["saved"]))
			"wake_physics":
				node.physics_enabled = s["saved"]
			"exclusion":
				node.enabled = s["saved"]
			"layer":
				node.collision_layer = s["saved"]
			"mask":
				node.collision_mask = s["saved"]
			"shape":
				node.disabled = s["saved"]
			"transform":
				var saved_transform: Transform3D = s["saved"]
				if node is RigidBody3D:
					_place_jet_ski(saved_transform.origin, -saved_transform.basis.z)
				else:
					ok = false
	return ok


func _variant_verify(saves: Array) -> bool:
	for s: Dictionary in saves:
		var node: Object = s["node"]
		match s["kind"]:
			"physics_process":
				if node.is_physics_processing() != bool(s["saved"]):
					return false
			"wake_physics":
				if node.physics_enabled != s["saved"]:
					return false
			"exclusion":
				if node.enabled != s["saved"]:
					return false
			"layer":
				if node.collision_layer != s["saved"]:
					return false
			"mask":
				if node.collision_mask != s["saved"]:
					return false
			"shape":
				if node.disabled != s["saved"]:
					return false
			"transform":
				var rb := node as RigidBody3D
				if rb != null and rb.global_transform.origin.distance_to(_controlled_pos) > 0.5:
					return false
	return true


func _collision_shapes(node: Node) -> Array:
	var shapes: Array = []
	if node == null:
		return shapes
	for child: Node in node.get_children():
		if child is CollisionShape3D:
			shapes.append(child)
	return shapes


func _physics_subtree(root: Node) -> Array:
	var out: Array = []
	if root.is_physics_processing():
		out.append(root)
	for child: Node in root.get_children():
		out.append_array(_physics_subtree(child))
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


func _pose_dict() -> Dictionary:
	var t := _jet_ski.global_transform if _jet_ski != null else Transform3D()
	return {
		"origin": [t.origin.x, t.origin.y, t.origin.z],
		"basis_z": [t.basis.z.x, t.basis.z.y, t.basis.z.z],
		"forward_vector": [_controlled_fwd.x, _controlled_fwd.y, _controlled_fwd.z],
		"player_camera_path": "CameraSystem/ChaseCamera/Camera3D",
		"camera_transform": _camera_transform_dict(),
		"controlled_distance_m": CONTROLLED_DISTANCE,
	}


func _camera_transform_dict() -> Dictionary:
	if _camera == null:
		return {}
	var t := _camera.global_transform
	return {"origin": [t.origin.x, t.origin.y, t.origin.z], "basis_z": [t.basis.z.x, t.basis.z.y, t.basis.z.z]}


func _collect_inventory() -> Dictionary:
	var exclusions_total: Array = []
	var exclusions_near: Array = []
	if _city != null:
		_collect_water_exclusion_volumes(_city, exclusions_total)
	var control := Vector3.ZERO
	if _jet_ski != null:
		control = _jet_ski.global_transform.origin
	for volume in exclusions_total:
		var dist: float = volume.global_transform.origin.distance_to(control)
		if dist <= NEAR_VOLUME_DISTANCE:
			exclusions_near.append({
				"path": volume.get_path(),
				"type": "Node3D + WaterExclusionVolume3D script",
				"enabled": volume.enabled,
				"distance_to_controlled_position": dist,
				"collision_processing": false,
			})

	var boat_shapes: Array = []
	var jet_ski_shapes: Array = []
	for actor in _actors:
		var shapes := []
		for shape: CollisionShape3D in _collision_shapes(actor):
			shapes.append({"path": shape.get_path(), "disabled": shape.disabled})
		boat_shapes.append({"actor": actor.get_path(), "shapes": shapes})
	if _jet_ski != null:
		for shape: CollisionShape3D in _collision_shapes(_jet_ski):
			jet_ski_shapes.append({"path": shape.get_path(), "disabled": shape.disabled})

	return {
		"water_exclusion_volumes_total": exclusions_total.size(),
		"water_exclusion_zone": exclusions_near,
		"traffic_collision_shapes": boat_shapes,
		"jet_ski_collision_shapes": jet_ski_shapes,
		"physics_3d_monitor_note": "Jolt does not populate PHYSICS_3D_ACTIVE_OBJECTS / COLLISION_PAIRS in 4.7.1 (observed 0 in Phase 2A); not used for attribution.",
	}


func _collect_water_exclusion_volumes(node: Node, out: Array) -> void:
	if node is WaterExclusionVolume3D:
		out.append(node)
	for child: Node in node.get_children():
		_collect_water_exclusion_volumes(child, out)


func _visibility_summary(bracket_results: Array) -> Dictionary:
	var base := _find_result(bracket_results, "BASELINE")
	var away := _find_result(bracket_results, "CAMERA_AWAY")
	if base.is_empty() or away.is_empty():
		return {"available": false}
	return {
		"available": true,
		"controlled_position_same": true,
		"corridor_facing_baseline_median_ms": base["baseline_local_median"],
		"camera_away_variant_median_ms": away["variant_median"],
		"delta_camera_off_corridor_ms": away["variant_median"] - base["baseline_local_median"],
		"note": "Same position; only the JetSki/camera heading changes 180deg between corridor-facing and corridor-away.",
	}


func _attribution(bracket_results: Array) -> Dictionary:
	var baseline := _find_result(bracket_results, "BASELINE")
	var base_median: float = baseline["baseline_local_median"]
	var rows := {}
	var sum_deltas := 0.0
	var sum_abs := 0.0
	for v: Dictionary in bracket_results:
		if v["name"] == "BASELINE":
			continue
		var delta: float = v["delta_ms"]
		var keeper: String = v["name"]
		if v["valid"]:
			rows[keeper] = delta
			sum_deltas += maxf(delta, 0.0)
			sum_abs += absf(delta)
	var sorted_rows := []
	for key: String in rows:
		sorted_rows.append({"name": key, "delta_ms": rows[key]})
	sorted_rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return a["delta_ms"] < b["delta_ms"]
	)
	return {
		"baseline_median_ms": base_median,
		"per_variant_delta_ms": sorted_rows,
		"sum_deltas_ms": sum_deltas,
		"sum_abs_deltas_ms": sum_abs,
	}


func _recommendation(attribution: Dictionary, baseline_median: float, residual: float) -> String:
	var smallest := ""
	var smallest_value := -1.0
	for row: Dictionary in attribution["per_variant_delta_ms"]:
		if smallest == "" or row["delta_ms"] < smallest_value:
			smallest = row["name"]
			smallest_value = row["delta_ms"]
	return ("Phase 2C candidate: %s; corridor baseline %.3f ms tick; residuo sin atribuir %.3f ms." % [smallest, baseline_median, residual])


func _find_result(bracket_results: Array, name: String) -> Dictionary:
	for v: Dictionary in bracket_results:
		if v["name"] == name:
			return v
	return {}


func _print_variant(result: Dictionary) -> void:
	print(
		"%s_VARIANT name=%s before_med=%.4f after_med=%.4f local_base=%.4f variant_med=%.4f delta_ms=%.3f delta_pct=%.2f divergence=%.3f fp_match=%s valid=%s"
		% [
			PHASE_TAG, result["name"],
			result["baseline_before_median"], result["baseline_after_median"],
			result["baseline_local_median"], result["variant_median"],
			result["delta_ms"], result["delta_percent"],
			result["baseline_divergence"], str(result["fingerprints_match"]), str(result["valid"]),
		]
	)


func _stats(values: Array) -> Dictionary:
	var sorted := values.duplicate()
	sorted.sort()
	var count := sorted.size()
	var total := 0.0
	for v: Variant in sorted:
		total += float(v)
	return {
		"mean": total / float(count),
		"median": _percentile(sorted, 0.50),
		"p90": _percentile(sorted, 0.90),
		"p95": _percentile(sorted, 0.95),
		"p99": _percentile(sorted, 0.99),
		"max": float(sorted[count - 1]),
	}


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


func _snapshot_fingerprint() -> int:
	var parts := [
		GOLD_CITY_SCENE,
		str(ProjectSettings.get_setting("renderer/rendering_method", "unknown")),
		str(ProjectSettings.get_setting("rendering_device/driver.windows", "unknown")),
		_mode,
		str(DETERMINISM_SEED),
	]
	return hash("|".join(parts))


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
	var directory := ProjectSettings.globalize_path(OUTPUT_DIRECTORY).replace("\\", "/")
	if DirAccess.make_dir_recursive_absolute(directory) != OK:
		return ""
	var timestamp := Time.get_datetime_string_from_system().replace(":", "-")
	var path := "%s/gold_city_physics_2b_%s_%s.json" % [directory, _label, timestamp]
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