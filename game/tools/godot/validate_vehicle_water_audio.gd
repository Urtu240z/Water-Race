extends SceneTree

const MAIN_SCENE := \
	"res://scenes/levels/island_test/island_test_BLENDER.tscn"
const REPORT_PATH := \
	"res://tools/godot/vehicle_water_audio_validation_report.txt"
const STEP := 1.0 / 60.0

var _vehicle: JetSkiController
var _audio: VehicleWaterAudio
var _island: Node
var _report: PackedStringArray = []
var _failed := false


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var packed := load(MAIN_SCENE) as PackedScene
	if packed == null:
		_fail("island_test_BLENDER.tscn loads.")
		_finish()
		return
	_island = packed.instantiate()
	_vehicle = _island.get_node_or_null("Gameplay/JetSki") as JetSkiController
	if _vehicle == null:
		_fail("The main scene contains its JetSkiController.")
		_finish()
		return
	_vehicle.freeze = true
	_vehicle.process_mode = Node.PROCESS_MODE_DISABLED
	_island.process_mode = Node.PROCESS_MODE_DISABLED
	root.add_child(_island)
	await process_frame
	_audio = _vehicle.get_node_or_null("WaterAudio") as VehicleWaterAudio
	_expect(_audio != null, "WaterAudio component exists.")
	if _audio == null:
		_finish()
		return
	# The main level deliberately overrides this to 0.0 for immediate ambience,
	# while the focused stopped-water case validates the base JetSki threshold.
	_audio.running_water_start_speed = 0.5
	var audio_random := _audio.get("_random") as RandomNumberGenerator
	if audio_random != null:
		audio_random.seed = 42

	_report.append("=== VEHICLE WATER AUDIO FOCUSED VALIDATION ===")
	_validate_resources_and_structure()
	_validate_stopped()
	_validate_acceleration_and_high_speed()
	_validate_coasting()
	_validate_stop_fade()
	_validate_contact_grace_and_airborne_cut()
	_validate_normal_landing()
	_validate_heavy_landing()
	_validate_cooldown()
	_validate_deep_submerged()
	_validate_restart_and_node_stability()
	_report.append(
		"VALIDATION_STATUS=%s" % ("FAIL" if _failed else "PASS")
	)
	_finish()


func _validate_resources_and_structure() -> void:
	var players := _collect_audio_players(_audio)
	_expect(players.size() == 3, "Exactly three WaterAudio players exist.")
	_expect(
		_valid_stream_count(_audio.normal_splash_streams) >= 1,
		"At least one configured normal splash variant resolves."
	)
	_expect(
		_valid_stream_count(_audio.heavy_splash_streams) >= 1,
		"At least one configured heavy splash variant resolves."
	)
	_expect(
		_valid_stream_count(_audio.running_water_streams) >= 1,
		"At least one configured running-water variant resolves."
	)
	var running_loops := true
	for stream: AudioStream in _audio.running_water_streams:
		running_loops = (
			running_loops
			and stream is AudioStreamOggVorbis
			and (stream as AudioStreamOggVorbis).loop
		)
	_expect(running_loops, "All running-water OGG streams loop.")
	var splashes_loop := false
	for stream: AudioStream in (
		_audio.normal_splash_streams + _audio.heavy_splash_streams
	):
		if (
			stream is AudioStreamOggVorbis
			and (stream as AudioStreamOggVorbis).loop
		):
			splashes_loop = true
	_expect(not splashes_loop, "Splash OGG streams do not loop.")


func _validate_stopped() -> void:
	_reset_audio()
	_snapshot(JetSkiController.NavigationState.IN_WATER, Vector3.ZERO, 4)
	_expect(
		not _audio.running_water_active
		and not _running_player().playing,
		"1. Stopped on water: running water stays off."
	)


func _validate_acceleration_and_high_speed() -> void:
	_snapshot(
		JetSkiController.NavigationState.IN_WATER,
		Vector3(0.0, 0.0, 4.0),
		4
	)
	var first_volume := _running_player().volume_db
	_expect(
		_audio.running_water_active
		and _running_player().playing
		and first_volume > -60.0
		and first_volume < _audio.running_water_target_db,
		"2. Acceleration: running water starts with a progressive fade."
	)
	for _frame: int in 60:
		_snapshot(
			JetSkiController.NavigationState.IN_WATER,
			Vector3(0.0, 0.0, 20.0),
			4
		)
	_expect(
		is_equal_approx(
			_audio.running_water_target_db,
			_audio.running_water_max_volume_db
		)
		and _running_player().pitch_scale > 1.0,
		"3. High speed: target volume and pitch increase smoothly."
	)


func _validate_coasting() -> void:
	_vehicle.input_system.state.throttle = 0.0
	_snapshot(
		JetSkiController.NavigationState.PARTIALLY_SUBMERGED,
		Vector3(0.0, 0.0, 10.0),
		2
	)
	_expect(
		_audio.running_water_active and _running_player().playing,
		"4. Coasting: audio follows speed, not throttle."
	)


func _validate_stop_fade() -> void:
	var was_playing := _running_player().playing
	for _frame: int in 120:
		_snapshot(
			JetSkiController.NavigationState.IN_WATER,
			Vector3.ZERO,
			4
		)
	_expect(
		was_playing
		and not _audio.running_water_active
		and not _running_player().playing,
		"5. Braking to rest: fade-out reaches stop."
	)


func _validate_contact_grace_and_airborne_cut() -> void:
	_snapshot(
		JetSkiController.NavigationState.IN_WATER,
		Vector3(0.0, 0.0, 8.0),
		4
	)
	for _frame: int in 5:
		_snapshot(
			JetSkiController.NavigationState.PARTIALLY_SUBMERGED,
			Vector3(0.0, 0.0, 8.0),
			0
		)
	var survived_short_gap := _audio.running_water_active
	_snapshot(
		JetSkiController.NavigationState.AIRBORNE,
		Vector3(0.0, 1.0, 8.0),
		0
	)
	_expect(
		survived_short_gap
		and not _audio.running_water_active
		and is_zero_approx(_audio.contact_grace_remaining),
		"Contact grace bridges short wave gaps but not confirmed AIRBORNE."
	)


func _validate_normal_landing() -> void:
	_reset_audio()
	_set_landing_descriptor(false)
	_snapshot(
		JetSkiController.NavigationState.AIRBORNE,
		Vector3(0.0, -3.0, 6.0),
		0
	)
	var pool_before := int(_audio.get("_impact_pool_cursor"))
	_vehicle.navigation_system.state.navigation_state = (
		JetSkiController.NavigationState.LANDING
	)
	_vehicle.navigation_system.state.current_contact_mask = 3
	_set_submerged_point_count(2)
	_vehicle.linear_velocity = Vector3(0.0, -0.3, 6.0)
	_vehicle.water_entered.emit(0.2, Vector3(1.0, 0.0, 2.0))
	_expect(
		_audio.last_splash_category == &"NORMAL"
		and _audio.last_splash_down_speed >= 3.0
		and int(_audio.get("_impact_pool_cursor")) == (pool_before + 1) % 2,
		"6. Short jump: exactly one normal splash is selected."
	)


func _validate_heavy_landing() -> void:
	_reset_audio()
	_set_landing_descriptor(true)
	_snapshot(
		JetSkiController.NavigationState.AIRBORNE,
		Vector3(0.0, -8.0, 8.0),
		0
	)
	var pool_before := int(_audio.get("_impact_pool_cursor"))
	_vehicle.navigation_system.state.navigation_state = (
		JetSkiController.NavigationState.LANDING
	)
	_vehicle.navigation_system.state.current_contact_mask = 15
	_set_submerged_point_count(4)
	_vehicle.linear_velocity = Vector3(0.0, -0.4, 8.0)
	_vehicle.water_entered.emit(0.8, Vector3(2.0, 0.0, 3.0))
	_expect(
		_audio.last_splash_category == &"HEAVY"
		and _audio.last_splash_down_speed >= 8.0
		and int(_audio.get("_impact_pool_cursor")) == (pool_before + 1) % 2,
		"7. High jump: exactly one heavy splash is selected."
	)


func _validate_cooldown() -> void:
	var pool_before := int(_audio.get("_impact_pool_cursor"))
	_audio.set("_landing_down_speed", 8.0)
	_vehicle.water_entered.emit(0.8, Vector3(2.0, 0.0, 3.0))
	_expect(
		int(_audio.get("_impact_pool_cursor")) == pool_before,
		"8. Small post-impact bounce is suppressed by cooldown."
	)


func _validate_deep_submerged() -> void:
	_reset_audio()
	_snapshot(
		JetSkiController.NavigationState.IN_WATER,
		Vector3(0.0, 0.0, 12.0),
		4
	)
	_snapshot(
		JetSkiController.NavigationState.DEEP_SUBMERGED,
		Vector3(0.0, 0.0, 12.0),
		4
	)
	_expect(
		not _audio.running_water_active
		and is_zero_approx(_audio.contact_grace_remaining),
		"9. Deep submerged: surface running water is disabled."
	)


func _validate_restart_and_node_stability() -> void:
	_reset_audio()
	var player_count_before := _collect_audio_players(_audio).size()
	var chosen_streams: Array[AudioStream] = []
	for _cycle: int in 4:
		_snapshot(
			JetSkiController.NavigationState.IN_WATER,
			Vector3(0.0, 0.0, 8.0),
			4
		)
		chosen_streams.append(_running_player().stream)
		for _frame: int in 120:
			_snapshot(
				JetSkiController.NavigationState.IN_WATER,
				Vector3.ZERO,
				4
			)
	var no_adjacent_repeat := true
	for index: int in range(1, chosen_streams.size()):
		if chosen_streams[index] == chosen_streams[index - 1]:
			no_adjacent_repeat = false
	var enough_variants_for_rotation := (
		_valid_stream_count(_audio.running_water_streams) >= 2
	)
	_expect(
		_collect_audio_players(_audio).size() == player_count_before
		and player_count_before == 3
		and not chosen_streams.has(null)
		and (no_adjacent_repeat or not enough_variants_for_rotation),
		"10. Repeated starts use valid variants without node accumulation."
	)


func _snapshot(
	state: JetSkiController.NavigationState,
	velocity: Vector3,
	submerged_points: int
) -> void:
	_vehicle.navigation_system.state.navigation_state = state
	_vehicle.navigation_system.state.current_contact_mask = (
		(1 << submerged_points) - 1 if submerged_points > 0 else 0
	)
	_set_submerged_point_count(submerged_points)
	_vehicle.linear_velocity = velocity
	_audio.call("_physics_process", STEP)


func _set_submerged_point_count(value: int) -> void:
	var water_state := _vehicle.water_physics_system.state
	water_state.submerged_point_count = value
	water_state.submerged_ratio = (
		float(value) / float(JetSkiController.BUOYANCY_POINT_COUNT)
	)


func _set_landing_descriptor(special_impact_eligible: bool) -> void:
	var descriptor := LandingImpactDescriptor.new()
	descriptor.confirmed_airborne = special_impact_eligible
	descriptor.special_impact_eligible = special_impact_eligible
	descriptor.rejection_reason = (
		LandingImpactDescriptor.REJECTION_ACCEPTED
		if special_impact_eligible
		else LandingImpactDescriptor.REJECTION_AIRTIME_TOO_SHORT
	)
	_vehicle.last_landing_impact_descriptor = descriptor


func _reset_audio() -> void:
	_audio.call("_reset_audio_state")


func _running_player() -> AudioStreamPlayer3D:
	return _audio.get_node("RunningWaterPlayer") as AudioStreamPlayer3D


func _collect_audio_players(node: Node) -> Array[AudioStreamPlayer3D]:
	var result: Array[AudioStreamPlayer3D] = []
	var pending: Array[Node] = [node]
	while not pending.is_empty():
		var current := pending.pop_back() as Node
		if current is AudioStreamPlayer3D:
			result.append(current as AudioStreamPlayer3D)
		for child: Node in current.get_children():
			pending.append(child)
	return result


func _valid_stream_count(streams: Array[AudioStream]) -> int:
	var count := 0
	for stream: AudioStream in streams:
		if stream != null:
			count += 1
	return count


func _expect(condition: bool, message: String) -> void:
	if condition:
		_report.append("PASS: %s" % message)
	else:
		_fail(message)


func _fail(message: String) -> void:
	_failed = true
	_report.append("FAIL: %s" % message)
	push_error(message)


func _finish() -> void:
	var file := FileAccess.open(REPORT_PATH, FileAccess.WRITE)
	if file != null:
		file.store_string("\n".join(_report) + "\n")
	file = null
	print("\n".join(_report))
	if is_instance_valid(_island):
		_stop_all_audio(_island)
		_island.free()
	_vehicle = null
	_audio = null
	_island = null
	await physics_frame
	await process_frame
	await process_frame
	quit(1 if _failed else 0)


func _stop_all_audio(node: Node) -> void:
	var pending: Array[Node] = [node]
	while not pending.is_empty():
		var current := pending.pop_back() as Node
		if current is AudioStreamPlayer:
			var player := current as AudioStreamPlayer
			player.stop()
			player.stream = null
		elif current is AudioStreamPlayer3D:
			var player_3d := current as AudioStreamPlayer3D
			player_3d.stop()
			player_3d.stream = null
		for child: Node in current.get_children():
			pending.append(child)
