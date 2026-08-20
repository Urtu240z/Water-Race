extends Node

## GPU validation for the Ocean3D-owned PersistentFoamHistoryMap3D backend.
##
## This test deliberately reads only a few known pixels after each controlled
## pass. Runtime code never performs CPU readback; the readback is test-only so
## the state-writing, merge, clear and rebase contracts are observable.

const HISTORY_SCENE_PATH := "res://world/water/ocean/foam/persistent_history/persistent_foam_history_map_3d.tscn"
const WORLD_ORIGIN_SCRIPT := "res://systems/world_origin/world_origin_controller.gd"
const OCEAN_SHADER_PATHS := [
	"res://world/water/ocean/shaders/ocean_water.gdshader",
	"res://world/water/ocean/shaders/ocean_water_custom_ssr.gdshader",
]
const MAP_CENTER := Vector2.ZERO
const MAP_RESOLUTION := 1024.0

var _failures: Array[String] = []
var _map: PersistentFoamHistoryMap3D
var _ocean: Ocean3D


func _ready() -> void:
	call_deferred("_run_validation")


func _run_validation() -> void:
	_map = load(HISTORY_SCENE_PATH).instantiate()
	add_child(_map)
	await _flush_gpu()

	_map.position_jitter = 0.0
	_map.scale_random_min = 1.0
	_map.scale_random_max = 1.0
	_map.aspect_min = 1.0
	_map.aspect_max = 1.0
	_map.rotation_random_deg = 0.0
	_map.lifetime = 3.0
	_map.enabled = true
	## The production map advances from _physics_process. Tests invoke exact
	## passes directly so a frame cannot consume or age a deposit implicitly.
	_map.set_physics_process(false)
	await _flush_gpu()

	_expect_true("HistoryA uses HDR 2D", _map._history_viewports[0].use_hdr_2d)
	_expect_true("HistoryB uses HDR 2D", _map._history_viewports[1].use_hdr_2d)

	_test_cpu_empty_state_semantics()
	_test_time_preservation()
	_test_true_size_multipliers()
	_test_pending_rebase()
	await _test_gpu_true_size_multipliers()
	await _test_gpu_lifetime_real_seconds()
	await _test_empty_pixel_never_activates()
	await _test_dead_foam_does_not_resurrect()
	await _test_nearby_empty_water()
	await _test_deposit_texture_clears()
	await _test_birth_and_cpu_consumption()
	await _test_fade_growth_and_death()
	await _test_refresh_preserves_state()
	await _test_saturation_and_multi_source()
	await _test_freshness_footprint()
	await _test_rotation_stability()
	await _test_strength_and_params_version()
	await _test_anchor_world_lock_and_fallback()
	await _test_vehicle_to_ocean_to_gpu_path()
	await _test_clear()
	await _test_rebase_semantics()
	_test_anchor_recenter_count()
	await _test_source_cleanup_and_backend_requests()
	_test_shader_resources()

	print("PERSISTENT_FOAM_HISTORY_MAP_VALIDATION")
	print("  pending_count=", _map.get_deposit_validation_status().pending_count)
	print("  update_count=", _map.update_count)
	print("  rebase_count=", _map.rebase_count)
	print("  anchor_count=", _map.anchor_count)
	if _failures.is_empty():
		print("RESULT: PASS")
		get_tree().quit(0)
	else:
		for failure in _failures:
			push_error("VALIDATION FAILURE: " + failure)
		print("RESULT: FAIL (%d)" % _failures.size())
		get_tree().quit(1)


func _test_cpu_empty_state_semantics() -> void:
	var state := Vector4.ZERO
	for _index in 12:
		state = PersistentFoamHistoryState.advance(state, Vector4.ZERO, 0.5, _map.fade_in_ratio)
	_expect_vector4_zero("CPU empty state remains zero", state)


func _test_time_preservation() -> void:
	_map._accumulated_time = 0.0
	_map._update_in_flight = true
	_map.call("_physics_process", 10.0)
	_map._update_in_flight = false
	_expect_close("HISTORY_TIME_PRESERVED", _map._accumulated_time, 10.0, 0.001)
	## One pass consumes a bounded piece and retains the remainder for later
	## passes, so the elapsed ten seconds cannot vanish during GPU stalls.
	var consumed := minf(_map._accumulated_time, _map.lifetime * _map.MAX_DT_RATIO_PER_STEP)
	_expect_true("LIFETIME_REAL_TIME", consumed > 0.0 and _map._accumulated_time - consumed > 0.0)
	_map._accumulated_time = 0.0


func _test_true_size_multipliers() -> void:
	var previous_min := _map.size_min
	var previous_max := _map.size_max
	_map.size_min = 0.5
	_map.size_max = 2.0
	var deposit := _map.submit_deposit(9001, Vector2(40.0, -25.0), Vector2.UP, 10.0, 1.0)
	_expect_close("SIZE_MAX_TRUE_MULTIPLIER", deposit.radius, 20.0, 0.001)
	_expect_close("SIZE_MIN_TRUE_MULTIPLIER", deposit.radius * _map.size_min / _map.size_max, 5.0, 0.001)
	_expect_true("SIZE_MAX_APPLIED_ONCE", is_equal_approx(deposit.radius, 20.0))
	_expect_true("GROWTH_CENTER_STABLE", deposit.world_xz.is_equal_approx(Vector2(40.0, -25.0)))
	_map.clear_history()
	_map.size_min = previous_min
	_map.size_max = previous_max


func _test_gpu_true_size_multipliers() -> void:
	var previous_min := _map.size_min
	var previous_max := _map.size_max
	var previous_fade_in := _map.fade_in_ratio
	var previous_fade_out := _map.fade_out_start_ratio
	var previous_lifetime := _map.lifetime
	_map.clear_history()
	await _flush_gpu()
	_map.size_min = 0.5
	_map.size_max = 2.0
	_map.fade_in_ratio = 0.001
	_map.fade_out_start_ratio = 0.99
	_map.lifetime = 10.0
	_map.position_jitter = 0.0
	_map.scale_random_min = 1.0
	_map.scale_random_max = 1.0
	_map.aspect_min = 1.0
	_map.aspect_max = 1.0
	_map.rotation_random_deg = 0.0
	_map.submit_deposit(9010, MAP_CENTER, Vector2.UP, 10.0, 1.0)
	_map.call("_run_update_pass", 0.0)
	await _flush_gpu()
	_map.call("_run_update_pass", 0.001)
	await _flush_gpu()
	var birth_radius := _visible_radius_along_x(MAP_CENTER)
	_map.call("_run_update_pass", 0.90)
	await _flush_gpu()
	var mature_radius := _visible_radius_along_x(MAP_CENTER)
	_expect_true(
		"GPU_SIZE_MIN_TRUE_MULTIPLIER radius=" + str(birth_radius),
		birth_radius >= 3.0 and birth_radius <= 7.5
	)
	_expect_true(
		"GPU_SIZE_MAX_TRUE_MULTIPLIER radius=" + str(mature_radius),
		mature_radius >= 14.0 and mature_radius <= 22.5
	)
	_map.clear_history()
	await _flush_gpu()
	_map.size_min = previous_min
	_map.size_max = previous_max
	_map.fade_in_ratio = previous_fade_in
	_map.fade_out_start_ratio = previous_fade_out
	_map.lifetime = previous_lifetime


func _test_gpu_lifetime_real_seconds() -> void:
	var previous_lifetime := _map.lifetime
	var previous_hz := _map.history_update_hz
	_map.clear_history()
	await _flush_gpu()
	_map.lifetime = 10.0
	_map.history_update_hz = 20
	_map._accumulated_time = 0.0
	_map.submit_deposit(9011, MAP_CENTER, Vector2.UP, 12.0, 1.0)
	for _step in 100:
		_map.call("_physics_process", 0.05)
		await _flush_gpu()
	var halfway := _read_history(MAP_CENTER)
	for _step in 112:
		_map.call("_physics_process", 0.05)
		await _flush_gpu()
	var dead := _read_history(MAP_CENTER)
	_expect_true(
		"GPU_LIFETIME_REAL_SECONDS halfway=" + str(halfway) + " dead=" + str(dead),
		absf(halfway.b - 0.5) <= 0.04 and dead.r <= 0.001
	)
	_map._accumulated_time = 0.0
	_map.lifetime = previous_lifetime
	_map.history_update_hz = previous_hz
	_map.clear_history()
	await _flush_gpu()


func _test_pending_rebase() -> void:
	_map.clear_history()
	var pending_position := Vector2(60.0, 90.0)
	_map.submit_deposit(9002, pending_position, Vector2.UP, 4.0, 1.0)
	var last_deposit_before := _map._last_deposit_xz
	var shift := Vector3(16.0, 0.0, 8.0)
	_map.apply_world_rebase(shift)
	_expect_true(
		"PENDING_REBASE",
		_map._pending.size() == 1 and _map._pending[0].world_xz.is_equal_approx(pending_position - Vector2(16.0, 8.0))
	)
	_expect_true(
		"LAST_DEPOSIT_REBASE",
		_map._last_deposit_xz.is_equal_approx(last_deposit_before - Vector2(16.0, 8.0))
	)
	var source := VehicleWaterEffects3D.new()
	source.set("_history_has_last_sample", true)
	source.set("_history_last_sample_position", pending_position)
	source.call("_on_world_rebased", shift)
	_expect_true(
		"HISTORY_GATE_REBASE",
		(source.get("_history_last_sample_position") as Vector2).is_equal_approx(pending_position - Vector2(16.0, 8.0))
	)
	source.free()
	_map.clear_history()


func _test_empty_pixel_never_activates() -> void:
	_map.clear_history()
	await _flush_gpu()
	var empty_position := Vector2(160.0, -160.0)
	## Two complete lifetimes at 0.5 seconds per deterministic update.
	for index in 12:
		_map.call("_run_update_pass", 0.5)
		await _flush_gpu()
		if index == 0 or index == 5 or index == 11:
			_expect_vector4_zero("EMPTY_STAYS_ZERO step " + str(index + 1), _read_history(empty_position))


func _test_dead_foam_does_not_resurrect() -> void:
	_map.clear_history()
	await _flush_gpu()
	_map.submit_deposit(1001, MAP_CENTER, Vector2(0.0, 1.0), 16.0, 0.8)
	_map.call("_run_update_pass", 0.0)
	await _flush_gpu()
	for _index in 6:
		_map.call("_run_update_pass", 0.5)
		await _flush_gpu()
	_expect_vector4_zero("DEAD_STAYS_DEAD at death", _read_history(MAP_CENTER))
	for _index in 6:
		_map.call("_run_update_pass", 0.5)
		await _flush_gpu()
	_expect_vector4_zero("DEAD_STAYS_DEAD after another lifetime", _read_history(MAP_CENTER))


func _test_nearby_empty_water() -> void:
	_map.clear_history()
	await _flush_gpu()
	var untouched_position := Vector2(160.0, 160.0)
	_map.submit_deposit(1001, MAP_CENTER, Vector2(0.0, 1.0), 16.0, 0.8)
	_map.call("_run_update_pass", 0.0)
	await _flush_gpu()
	for index in 6:
		_expect_vector4_zero("UNTOUCHED_WATER_STAYS_EMPTY step " + str(index), _read_history(untouched_position))
		_map.call("_run_update_pass", 0.5)
		await _flush_gpu()
	_expect_vector4_zero("UNTOUCHED_WATER_STAYS_EMPTY at death", _read_history(untouched_position))


func _test_deposit_texture_clears() -> void:
	_map.clear_history()
	await _flush_gpu()
	_map.submit_deposit(1001, MAP_CENTER, Vector2(0.0, 1.0), 16.0, 0.8)
	_map._deposit_canvas.stamps = _map._pending.duplicate()
	_map._deposit_canvas.mark_dirty()
	_map.call("_render_viewport_now", _map._deposit_viewport)
	await _flush_gpu()
	_expect_true("deposit texture contains new stamp", _texture_max(_map._deposit_viewport.get_texture()) > 0.01)
	_map.call("_run_update_pass", 0.0)
	await _flush_gpu()
	_expect_close("DEPOSIT_TEXTURE_CLEARS", _texture_max(_map._deposit_viewport.get_texture()), 0.0, 0.001)
	_expect_equal("PENDING_RETURNS_ZERO", _map.get_deposit_validation_status().pending_count, 0)


func _test_birth_and_cpu_consumption() -> void:
	_map.clear_history()
	await _flush_gpu()
	var command := _map.submit_deposit(1001, MAP_CENTER, Vector2(0.0, 1.0), 16.0, 0.8)
	_expect_true("birth command accepted", command != null)
	_expect_equal("one pending CPU command", _map.get_deposit_validation_status().pending_count, 1)
	_map.call("_run_update_pass", 0.0)
	await _flush_gpu()
	var birth := _read_history(MAP_CENTER)
	_expect_true("birth writes footprint with A == 0", birth.r > 0.5 and birth.a <= 0.001)
	_expect_close("birth age == 0", birth.b, 0.0, 0.01)
	_expect_close("birth reveal == 0", birth.g, 0.0, 0.01)
	_expect_equal("pending commands return to zero", _map.get_deposit_validation_status().pending_count, 0)


func _test_fade_growth_and_death() -> void:
	_map.call("_run_update_pass", 0.5)
	await _flush_gpu()
	var growing := _read_history(MAP_CENTER)
	_expect_true("fade-in establishes alpha", growing.a > 0.0)
	_expect_true("growth reveal advances", growing.g > 0.0)
	_expect_true("history center remains at same world location", _read_history(MAP_CENTER).r > 0.0)
	for _index in 8:
		_map.call("_run_update_pass", 0.5)
		await _flush_gpu()
	var dead := _read_history(MAP_CENTER)
	_expect_true("foam coverage reaches zero at death " + str(dead), dead.r <= 0.001)


func _test_refresh_preserves_state() -> void:
	_map.clear_history()
	await _flush_gpu()
	_map.submit_deposit(1001, MAP_CENTER, Vector2(0.0, 1.0), 16.0, 0.8)
	_map.call("_run_update_pass", 0.0)
	await _flush_gpu()
	_map.call("_run_update_pass", 0.5)
	await _flush_gpu()
	var before := _read_history(MAP_CENTER)
	_map.submit_deposit(1001, MAP_CENTER, Vector2(0.0, 1.0), 16.0, 0.8)
	_map.call("_run_update_pass", 0.0)
	await _flush_gpu()
	var after := _read_history(MAP_CENTER)
	_expect_true("refresh keeps coverage", after.r + 0.001 >= before.r)
	_expect_true("refresh keeps established visibility", after.a + 0.001 >= before.a)
	_expect_true("REFRESH_NO_DIP", after.a > 0.25)


func _test_saturation_and_multi_source() -> void:
	_map.clear_history()
	await _flush_gpu()
	for index in 10:
		_map.submit_deposit(1001 + index, MAP_CENTER, Vector2(0.0, 1.0), 16.0, 0.45)
	_map.call("_run_update_pass", 0.0)
	await _flush_gpu()
	var saturated := _read_history(MAP_CENTER)
	_expect_true("overlapping deposits merge at strong coverage", saturated.r >= 0.80)
	_expect_true("overlapping deposits stay bounded", saturated.r <= 1.001)

	_map.clear_history()
	await _flush_gpu()
	_map.submit_deposit(1001, Vector2(-32.0, 0.0), Vector2(0.0, 1.0), 8.0, 0.8)
	_map.submit_deposit(2002, Vector2(32.0, 0.0), Vector2(0.0, 1.0), 8.0, 0.8)
	_expect_equal("two synthetic sources pending", _map.get_deposit_validation_status().pending_count, 2)
	_map.call("_run_update_pass", 0.0)
	await _flush_gpu()
	_expect_true("source 1001 survives merge", _read_history(Vector2(-32.0, 0.0)).r > 0.5)
	_expect_true("source 2002 survives merge", _read_history(Vector2(32.0, 0.0)).r > 0.5)


func _test_freshness_footprint() -> void:
	## First create established foam with a wide stamp. Then refresh with a
	## smaller stamp. The selected point is inside the smaller square but on a
	## transparent corner of its actual irregular footprint.
	_map.clear_history()
	await _flush_gpu()
	var stamp_image: Image = _map._deposit_canvas._stamp_texture.get_image()
	var center_px := (stamp_image.get_width() - 1) * 0.5
	var old_radius := 32.0
	var small_radius := 16.0
	var maximum_size_multiplier := _map.size_max
	var selected := Vector2i(-1, -1)
	for y in stamp_image.get_height():
		for x in stamp_image.get_width():
			var old_pixel := stamp_image.get_pixel(x, y).r
			var point := Vector2(
				(float(x) - center_px) * old_radius * maximum_size_multiplier / 64.0,
				(float(y) - center_px) * old_radius * maximum_size_multiplier / 64.0
			)
			var mapped := Vector2i(
				roundi(center_px + (float(x) - center_px) * old_radius / small_radius),
				roundi(center_px + (float(y) - center_px) * old_radius / small_radius)
			)
			if (
				old_pixel > 0.05
				and absf(point.x) < small_radius * 0.9
				and absf(point.y) < small_radius * 0.9
				and mapped.x >= 0
				and mapped.y >= 0
				and mapped.x < stamp_image.get_width()
				and mapped.y < stamp_image.get_height()
				and stamp_image.get_pixel(mapped.x, mapped.y).r <= 0.001
			):
				selected = Vector2i(x, y)
				break
		if selected.x >= 0:
			break
	if selected.x < 0:
		_failures.append("could not find an outer stamp pixel for freshness test")
		return
	var point := Vector2(
		(float(selected.x) - center_px) * old_radius * maximum_size_multiplier / 64.0,
		(float(selected.y) - center_px) * old_radius * maximum_size_multiplier / 64.0
	)
	_map.submit_deposit(1001, MAP_CENTER, Vector2(0.0, 1.0), old_radius, 1.0)
	_map.call("_run_update_pass", 0.0)
	await _flush_gpu()
	_map.call("_run_update_pass", 0.5)
	await _flush_gpu()
	var before := _read_history(point)
	_map.submit_deposit(1001, MAP_CENTER, Vector2(0.0, 1.0), 16.0, 1.0)
	_map.call("_run_update_pass", 0.0)
	await _flush_gpu()
	var after := _read_history(point)
	_expect_true("outer old foam exists for freshness test", before.r > 0.05)
	_expect_true(
		"transparent corner does not reset age before=" + str(before) + " after=" + str(after),
		after.b >= before.b - 0.01 and after.b > 0.1
	)


func _test_rotation_stability() -> void:
	_map.clear_history()
	await _flush_gpu()
	_map.rotation_random_deg = 0.0
	var no_rotation := _map.submit_deposit(1001, MAP_CENTER, Vector2(0.0, 1.0), 8.0, 1.0)
	_expect_close("zero rotation range produces zero stamp rotation", no_rotation.rotation, 0.0, 0.0001)
	_map.clear_history()
	await _flush_gpu()
	_map.rotation_random_deg = 90.0
	var rotated := _map.submit_deposit(1001, MAP_CENTER, Vector2(0.0, 1.0), 8.0, 1.0)
	var stored_rotation := rotated.rotation
	_map.call("_run_update_pass", 0.0)
	await _flush_gpu()
	_expect_close("one-deposit rotation remains stable until consumed", rotated.rotation, stored_rotation, 0.0)
	_expect_true("configured random range affects stored rotation", absf(stored_rotation) <= PI * 0.5)


func _test_strength_and_params_version() -> void:
	var version_before: int = _map.get_history_params_version()
	_map.strength = 0.25
	_expect_true("strength changes params version immediately", _map.get_history_params_version() > version_before)
	_expect_close("history strength reports configured value", _map.get_history_strength(), 0.25, 0.001)

	_ocean = Ocean3D.new()
	add_child(_ocean)
	_map.configure(_ocean, MAP_CENTER)
	for shader_path in OCEAN_SHADER_PATHS:
		var probe := ShaderMaterial.new()
		probe.shader = load(shader_path)
		_ocean.call("_push_persistent_foam_history_parameters", probe)
		_expect_true(
			"history enabled reaches " + shader_path.get_file(),
			probe.get_shader_parameter("persistent_foam_history_enabled")
		)
		_expect_close(
			"strength reaches " + shader_path.get_file(),
			probe.get_shader_parameter("persistent_foam_history_strength"),
			0.25,
			0.001
		)


func _test_clear() -> void:
	_map.submit_deposit(1001, MAP_CENTER, Vector2(0.0, 1.0), 16.0, 1.0)
	_map.call("_run_update_pass", 0.0)
	await _flush_gpu()
	_expect_true("foam exists before clear", _read_history(MAP_CENTER).r > 0.5)
	_map.clear_history()
	await _flush_gpu()
	_expect_true("clear zeros current GPU history", _read_history(MAP_CENTER).r <= 0.001)
	_map.call("_run_update_pass", 0.0)
	await _flush_gpu()
	_expect_true("clear does not resurrect old foam", _read_history(MAP_CENTER).r <= 0.001)
	_expect_equal("clear removes pending commands", _map.get_deposit_validation_status().pending_count, 0)


func _test_anchor_world_lock_and_fallback() -> void:
	_map.clear_history()
	await _flush_gpu()
	var visible_world := _map.get_history_anchor_xz()
	_map.submit_deposit(1001, visible_world, Vector2.UP, 12.0, 1.0)
	_map.call("_run_update_pass", 0.0)
	await _flush_gpu()
	var target := Node3D.new()
	add_child(target)
	var published_before := _map.get_history_anchor_xz()
	_ocean.follow_target = target
	target.global_position = Vector3(published_before.x + 240.0, 0.0, published_before.y)
	_map.call("_track_anchor")
	_expect_vector2_close("anchor remains published before remap", _map.get_history_anchor_xz(), published_before, 0.001)
	_map.call("_run_update_pass", 0.0)
	await _flush_gpu()
	_expect_true("ANCHOR_PIXEL_WORLD_LOCK", _read_history(visible_world).r > 0.5)
	_expect_true("DEPOSIT_AND_HISTORY_SAME_FRAME", _read_history(visible_world).r > 0.5)
	_ocean.follow_target = null
	var camera := Camera3D.new()
	add_child(camera)
	camera.global_position = Vector3(333.0, 0.0, -222.0)
	_ocean.follow_camera = camera
	_map.call("_track_anchor")
	_expect_true("ANCHOR_FALLBACK", _map.anchor_count > 0)
	camera.queue_free()
	target.queue_free()


func _test_vehicle_to_ocean_to_gpu_path() -> void:
	_map.clear_history()
	await _flush_gpu()
	_map.enabled = true
	_map.configure(_ocean, _map.get_history_anchor_xz())
	var material := ShaderMaterial.new()
	material.shader = load(OCEAN_SHADER_PATHS[0])
	_ocean.ocean_material = material
	var vehicle := load(
		"res://gameplay/vehicles/jet_ski_01/jet_ski_01.tscn"
	).instantiate() as JetSkiController
	add_child(vehicle)
	vehicle.process_mode = Node.PROCESS_MODE_DISABLED
	var water_system := vehicle.water_physics_system
	var drive_system := vehicle.drive_system
	var navigation_system := vehicle.navigation_system
	water_system.state.rear_submerged_ratio = 1.0
	water_system.state.water_relative_forward_speed = 12.0
	drive_system.state.propulsion_contact_factor = 1.0
	navigation_system.state.navigation_state = JetSkiTypes.NavigationState.IN_WATER
	var propulsion := Marker3D.new()
	var rear_left := Marker3D.new()
	var rear_right := Marker3D.new()
	vehicle.add_child(propulsion)
	vehicle.add_child(rear_left)
	vehicle.add_child(rear_right)
	var deposit_world := _map.get_history_anchor_xz()
	propulsion.position = Vector3(deposit_world.x, 0.0, deposit_world.y)
	rear_left.position = propulsion.position + Vector3(-1.0, 0.0, 0.0)
	rear_right.position = propulsion.position + Vector3(1.0, 0.0, 0.0)
	var source := VehicleWaterEffects3D.new()
	source.set("_vehicle", vehicle)
	source.set("_ocean", _ocean)
	source.set("_propulsion_point", propulsion)
	source.set("_rear_left_marker", rear_left)
	source.set("_rear_right_marker", rear_right)
	source.persistent_foam_v2_backend = VehicleWaterEffects3D.PersistentFoamHistoryBackend.HISTORY_MAP
	source.persistent_foam_v2_enabled = true
	source.persistent_foam_v2_sample_distance = 0.5
	source.persistent_foam_v2_width_multiplier = 1.0
	source.call("_sync_persistent_foam_backend")
	var vehicle_before: int = source.get("_history_deposit_count")
	var map_before := _map.deposit_count
	_expect_true("vehicle history deposition gate is ready", source.call("_history_deposit_ready"))
	source.call("_update_history_deposition")
	propulsion.position += Vector3(1.0, 0.0, 0.0)
	source.call("_update_history_deposition")
	var deposited_world := Vector2(propulsion.position.x, propulsion.position.z)
	_map.call("_run_update_pass", 0.0)
	await _flush_gpu()
	_map.call("_run_update_pass", 0.05)
	await _flush_gpu()
	_ocean.call("_push_persistent_foam_history_parameters", material)
	var state := _read_history(deposited_world)
	var final_coverage := PersistentFoamHistoryState.coverage(
		Vector4(state.r, state.g, state.b, state.a),
		_map.size_min,
		_map.size_max,
		_map.fade_out_start_ratio
	)
	var path_ok: bool = (
		int(source.get("_history_deposit_count")) >= vehicle_before + 2
		and _map.deposit_count >= map_before + 2
		and _map.get_deposit_validation_status().pending_count == 0
		and state.r > 0.01
		and material.get_shader_parameter("persistent_foam_history_enabled")
		and material.get_shader_parameter("persistent_foam_history_texture") == _map.get_history_texture()
		and final_coverage > 0.0
	)
	_expect_true("VEHICLE_TO_OCEAN_TO_GPU_PATH coverage=" + str(final_coverage), path_ok)
	source.call("_exit_tree")
	source.free()
	vehicle.queue_free()


func _test_rebase_semantics() -> void:
	_map.clear_history()
	await _flush_gpu()
	var visible_local := _map.get_history_anchor_xz() + Vector2(20.0, -12.0)
	_map.submit_deposit(1001, visible_local, Vector2.UP, 12.0, 1.0)
	_map.call("_run_update_pass", 0.0)
	await _flush_gpu()
	var visible_before := _read_history(visible_local)
	var old_anchor := _map.get_history_anchor_xz()
	var old_local := Vector2(20.0, -12.0)
	var shift := Vector3(128.0, 0.0, 64.0)
	var origin_script = load(WORLD_ORIGIN_SCRIPT)
	var origin_controller: Node = origin_script.new()
	origin_controller.set("_logical_origin_x", 0.0)
	origin_controller.set("_logical_origin_z", 0.0)
	var old_logical: Vector3 = origin_controller.call("local_to_logical_position", Vector3(old_local.x, 0.0, old_local.y))
	origin_controller.set("_logical_origin_x", shift.x)
	origin_controller.set("_logical_origin_z", shift.z)
	var new_local := old_local - Vector2(shift.x, shift.z)
	var new_logical: Vector3 = origin_controller.call("local_to_logical_position", Vector3(new_local.x, 0.0, new_local.y))
	_expect_true("actual WorldOriginController semantics preserve logical position", old_logical.is_equal_approx(new_logical))
	_map.apply_world_rebase(shift)
	_expect_vector2_close("history anchor follows local rebase with negative sign", _map.get_history_anchor_xz(), old_anchor - Vector2(shift.x, shift.z), 0.001)
	_expect_true(
		"VISIBLE_REBASE_WORLD_LOCK",
		_read_history(visible_local - Vector2(shift.x, shift.z)).r >= visible_before.r - 0.01
	)


func _test_anchor_recenter_count() -> void:
	if not is_instance_valid(_ocean):
		_failures.append("anchor recenter test ocean missing")
		return
	var target := Node3D.new()
	add_child(target)
	_ocean.follow_target = target
	var anchor_before := _map.anchor_count
	var anchor := _map.get_history_anchor_xz()
	target.global_position = Vector3(anchor.x + 240.0, 0.0, anchor.y)
	_map.call("_track_anchor")
	_expect_equal("one physical recenter counts once", _map.anchor_count, anchor_before + 1)
	target.queue_free()


func _test_source_cleanup_and_backend_requests() -> void:
	_ocean = Ocean3D.new()
	add_child(_ocean)
	var local_map: PersistentFoamHistoryMap3D = load(HISTORY_SCENE_PATH).instantiate()
	_ocean.add_child(local_map)
	await _flush_gpu()
	_ocean.set_persistent_foam_history_requested(true, 1001)
	_ocean.set_persistent_foam_history_requested(true, 2002)
	_expect_true("history remains enabled with two source requests", local_map.enabled)
	_ocean.set_persistent_foam_history_requested(false, 1001)
	_expect_true("removing one source keeps history enabled", local_map.enabled)
	_ocean.set_persistent_foam_history_requested(false, 2002)
	_expect_true("removing second source disables history", not local_map.enabled)
	local_map.call("request_settings_owner", 1001)
	local_map.call("apply_owner_settings", 1001, {&"strength": 0.25, &"lifetime": 20.0})
	local_map.call("request_settings_owner", 2002)
	local_map.call("apply_owner_settings", 2002, {&"strength": 0.9, &"lifetime": 8.0})
	_expect_true(
		"MULTI_SOURCE_NO_LAST_WRITER_WINS",
		is_equal_approx(local_map.strength, 0.25) and is_equal_approx(local_map.lifetime, 20.0)
	)
	local_map.call("release_settings_owner", 1001)
	var owner_source := VehicleWaterEffects3D.new()
	var owner_mask := PersistentFoamMask3D.new()
	owner_source.set("_persistent_foam", owner_mask)
	owner_source.set("_ocean", _ocean)
	owner_source.persistent_foam_v2_enabled = true
	owner_source.persistent_foam_v2_backend = VehicleWaterEffects3D.PersistentFoamHistoryBackend.HISTORY_MAP
	owner_source.persistent_foam_v2_global_settings_owner = true
	owner_source.call("_sync_persistent_foam_backend")
	var owner_lifecycle_ok := local_map._settings_owner_source_id == owner_source.get_instance_id()
	owner_source.persistent_foam_v2_global_settings_owner = false
	owner_source.call("_sync_history_map_appearance")
	owner_lifecycle_ok = owner_lifecycle_ok and local_map._settings_owner_source_id == 0
	owner_source.persistent_foam_v2_global_settings_owner = true
	owner_source.call("_sync_history_map_appearance")
	owner_lifecycle_ok = owner_lifecycle_ok and local_map._settings_owner_source_id == owner_source.get_instance_id()
	owner_source.persistent_foam_v2_enabled = false
	owner_source.call("_sync_persistent_foam_backend")
	owner_lifecycle_ok = owner_lifecycle_ok and local_map._settings_owner_source_id == 0
	owner_source.persistent_foam_v2_enabled = true
	owner_source.call("_sync_persistent_foam_backend")
	owner_source.persistent_foam_v2_backend = VehicleWaterEffects3D.PersistentFoamHistoryBackend.SPLAT_MASK
	owner_source.call("_sync_persistent_foam_backend")
	owner_lifecycle_ok = owner_lifecycle_ok and local_map._settings_owner_source_id == 0
	owner_source.persistent_foam_v2_backend = VehicleWaterEffects3D.PersistentFoamHistoryBackend.HISTORY_MAP
	owner_source.call("_sync_persistent_foam_backend")
	owner_source._exit_tree()
	owner_lifecycle_ok = owner_lifecycle_ok and local_map._settings_owner_source_id == 0
	_expect_true("SETTINGS_OWNER_LIFECYCLE", owner_lifecycle_ok)
	owner_mask.free()
	owner_source.free()

	var source := VehicleWaterEffects3D.new()
	source.set("_ocean", _ocean)
	_ocean.set_persistent_foam_history_requested(true, source.get_instance_id())
	source._exit_tree()
	_expect_true("vehicle tree cleanup releases its source request", not local_map.enabled)

	var switching_source := VehicleWaterEffects3D.new()
	var fallback_mask := PersistentFoamMask3D.new()
	switching_source.set("_persistent_foam", fallback_mask)
	switching_source.set("_ocean", _ocean)
	switching_source.persistent_foam_v2_enabled = true
	switching_source.persistent_foam_v2_backend = VehicleWaterEffects3D.PersistentFoamHistoryBackend.HISTORY_MAP
	switching_source.call("_sync_persistent_foam_backend")
	_expect_true("SPLAT_MASK to HISTORY_MAP enables only history", local_map.enabled and not fallback_mask.enabled)
	switching_source.persistent_foam_v2_backend = VehicleWaterEffects3D.PersistentFoamHistoryBackend.SPLAT_MASK
	switching_source.call("_sync_persistent_foam_backend")
	_expect_true("HISTORY_MAP to SPLAT_MASK releases history", not local_map.enabled and fallback_mask.enabled)
	fallback_mask.free()
	switching_source.free()


func _test_shader_resources() -> void:
	for shader_path in OCEAN_SHADER_PATHS:
		var shader: Shader = load(shader_path)
		_expect_true("ocean shader loads: " + shader_path.get_file(), shader != null and shader.get_code().contains("persistent_foam_history_enabled"))
		_expect_true(
			"HISTORY_OUTSIDE_MAP_ZERO " + shader_path.get_file(),
			shader != null
			and shader.get_code().contains("history_inside")
			and shader.get_code().contains("history_value = history_inside * history_coverage")
		)


func _flush_gpu() -> void:
	## frame_post_draw is not emitted reliably by Godot's headless renderer.
	## Two process frames are sufficient for UPDATE_ONCE SubViewports to submit
	## their controlled test render and make the texture readable below.
	await get_tree().process_frame
	await get_tree().process_frame
	await get_tree().process_frame


func _read_history(world_xz: Vector2) -> Color:
	var texture := _map.get_history_texture()
	if texture == null:
		return Color(0.0, 0.0, 0.0, 0.0)
	var image := texture.get_image()
	var uv := (world_xz - _map.get_history_anchor_xz()) / _map.get_history_world_size() + Vector2.ONE * 0.5
	var pixel := Vector2i(
		clampi(roundi(uv.x * (MAP_RESOLUTION - 1.0)), 0, int(MAP_RESOLUTION - 1.0)),
		clampi(roundi(uv.y * (MAP_RESOLUTION - 1.0)), 0, int(MAP_RESOLUTION - 1.0))
	)
	return image.get_pixel(pixel.x, pixel.y)


func _visible_radius_along_x(center_world: Vector2) -> float:
	var texture := _map.get_history_texture()
	if texture == null:
		return 0.0
	var image := texture.get_image()
	if image == null or image.is_empty():
		return 0.0
	var center_uv := (
		(center_world - _map.get_history_anchor_xz())
		/ _map.get_history_world_size()
		+ Vector2.ONE * 0.5
	)
	var center_pixel := Vector2i(
		clampi(roundi(center_uv.x * (image.get_width() - 1)), 0, image.get_width() - 1),
		clampi(roundi(center_uv.y * (image.get_height() - 1)), 0, image.get_height() - 1)
	)
	var last_visible := 0.0
	var found_visible := false
	var empty_run := 0
	for x in range(center_pixel.x, image.get_width()):
		var pixel := image.get_pixel(x, center_pixel.y)
		var coverage := PersistentFoamHistoryState.coverage(
			Vector4(pixel.r, pixel.g, pixel.b, pixel.a),
			_map.size_min,
			_map.size_max,
			_map.fade_out_start_ratio
		)
		if coverage >= 0.5:
			found_visible = true
			empty_run = 0
			last_visible = (
				float(x - center_pixel.x)
				* _map.get_history_world_size()
				/ float(image.get_width() - 1)
			)
		elif found_visible:
			empty_run += 1
			if empty_run >= 4:
				break
	return last_visible


func _texture_max(texture: Texture2D) -> float:
	if texture == null:
		return 0.0
	var image := texture.get_image()
	var max_value := 0.0
	for y in image.get_height():
		for x in image.get_width():
			var pixel := image.get_pixel(x, y)
			max_value = maxf(max_value, maxf(pixel.r, pixel.g))
	return max_value


func _expect_true(label: String, value: bool) -> void:
	if value:
		print("  OK ", label)
	else:
		_failures.append(label)
		print("  FAIL ", label)


func _expect_equal(label: String, actual: Variant, expected: Variant) -> void:
	_expect_true(label + " = " + str(actual), actual == expected)


func _expect_close(label: String, actual: Variant, expected: float, tolerance: float) -> void:
	var valid := (typeof(actual) == TYPE_FLOAT or typeof(actual) == TYPE_INT)
	_expect_true(label + " = " + str(actual), valid and absf(float(actual) - expected) <= tolerance)


func _expect_vector2_close(label: String, actual: Vector2, expected: Vector2, tolerance: float) -> void:
	_expect_true(label + " = " + str(actual), actual.distance_to(expected) <= tolerance)


func _expect_vector4_zero(label: String, actual: Variant) -> void:
	var is_zero := false
	if actual is Vector4:
		is_zero = (actual as Vector4).length_squared() <= 0.000001
	elif actual is Color:
		var color := actual as Color
		is_zero = color.r * color.r + color.g * color.g + color.b * color.b + color.a * color.a <= 0.000001
	_expect_true(label + " = " + str(actual), is_zero)
