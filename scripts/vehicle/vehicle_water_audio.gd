class_name VehicleWaterAudio
extends Node3D

## Spatial audio for confirmed water landings and surface movement.
## Reads the JetSkiController's existing navigation/contact API only.

@export_group("Audio Variants")
@export var normal_splash_streams: Array[AudioStream] = []
@export var heavy_splash_streams: Array[AudioStream] = []
@export var running_water_streams: Array[AudioStream] = []

@export_group("Landing Splash")
@export_range(0.0, 50.0, 0.1, "or_greater", "suffix:m/s") \
var minimum_landing_splash_speed: float = 1.5
@export_range(0.0, 50.0, 0.1, "or_greater", "suffix:m/s") \
var heavy_landing_speed: float = 6.0
@export_range(0.0, 5.0, 0.01, "or_greater", "suffix:s") \
var splash_cooldown_seconds: float = 0.25
@export_range(0.5, 2.0, 0.01) var splash_pitch_min: float = 0.96
@export_range(0.5, 2.0, 0.01) var splash_pitch_max: float = 1.04
@export_range(-60.0, 12.0, 0.5) var normal_splash_volume_db: float = -3.0
@export_range(-60.0, 12.0, 0.5) var heavy_splash_volume_db: float = 0.0

@export_group("Running Water")
@export_range(0.0, 100.0, 0.1, "or_greater", "suffix:m/s") \
var running_water_start_speed: float = 3.0
@export_range(0.0, 100.0, 0.1, "or_greater", "suffix:m/s") \
var running_water_stop_speed: float = 2.0
@export_range(0.1, 200.0, 0.1, "or_greater", "suffix:m/s") \
var running_water_full_speed: float = 20.0
@export_range(0.0, 2.0, 0.01, "or_greater", "suffix:s") \
var water_contact_grace_seconds: float = 0.15
@export_range(-60.0, 6.0, 0.5) var running_water_min_volume_db: float = -30.0
@export_range(-60.0, 6.0, 0.5) var running_water_max_volume_db: float = -3.0
@export_range(0.25, 2.0, 0.01) var running_water_min_pitch: float = 0.85
@export_range(0.25, 2.0, 0.01) var running_water_max_pitch: float = 1.12
@export_range(0.1, 120.0, 0.5, "suffix:dB/s") \
var running_water_fade_in_db_per_second: float = 30.0
@export_range(0.1, 120.0, 0.5, "suffix:dB/s") \
var running_water_fade_out_db_per_second: float = 45.0
@export_range(0.1, 160.0, 0.5, "suffix:dB/s") \
var running_water_air_fade_out_db_per_second: float = 70.0

@export_group("3D Audio")
@export_range(1.0, 500.0, 1.0, "suffix:m") var maximum_distance: float = 85.0
@export_range(0.1, 50.0, 0.1, "suffix:m") var attenuation_unit_size: float = 8.0
@export var audio_bus: StringName = &"Master"

@onready var _impact_player_a: AudioStreamPlayer3D = $ImpactPlayerA
@onready var _impact_player_b: AudioStreamPlayer3D = $ImpactPlayerB
@onready var _running_player: AudioStreamPlayer3D = $RunningWaterPlayer

var landing_down_speed: float:
	get:
		return _landing_down_speed

var horizontal_speed: float:
	get:
		return _horizontal_speed

var running_water_active: bool:
	get:
		return _running_requested

var running_water_target_db: float:
	get:
		return _running_target_db

var contact_grace_remaining: float:
	get:
		return _contact_grace_remaining

var last_splash_category: StringName:
	get:
		return _last_splash_category

var last_splash_down_speed: float:
	get:
		return _last_splash_down_speed

var _vehicle: JetSkiController
var _random := RandomNumberGenerator.new()
var _landing_down_speed: float = 0.0
var _horizontal_speed: float = 0.0
var _splash_cooldown_remaining: float = 0.0
var _contact_grace_remaining: float = 0.0
var _running_requested: bool = false
var _running_target_db: float = -60.0
var _last_splash_category: StringName = &"NONE"
var _last_splash_down_speed: float = 0.0
var _impact_pool_cursor: int = 0
var _last_normal_stream: AudioStream
var _last_heavy_stream: AudioStream
var _last_running_stream: AudioStream


func _ready() -> void:
	_vehicle = get_parent() as JetSkiController
	if _vehicle == null:
		push_warning("VehicleWaterAudio must be a child of a JetSkiController.")
		set_physics_process(false)
		return
	if (
		_impact_player_a == null
		or _impact_player_b == null
		or _running_player == null
	):
		push_warning("VehicleWaterAudio requires its three audio players.")
		set_physics_process(false)
		return

	_random.randomize()
	_configure_audio_players()
	_validate_streams()
	_connect_vehicle_signals()
	_reset_audio_state()


func _physics_process(delta: float) -> void:
	if not is_instance_valid(_vehicle):
		return
	var safe_delta := maxf(delta, 0.0)
	_splash_cooldown_remaining = maxf(
		_splash_cooldown_remaining - safe_delta,
		0.0
	)
	_horizontal_speed = Vector2(
		_vehicle.linear_velocity.x,
		_vehicle.linear_velocity.z
	).length()
	if (
		_vehicle.navigation_state
		== JetSkiController.NavigationState.AIRBORNE
	):
		_landing_down_speed = maxf(
			_landing_down_speed,
			maxf(-_vehicle.linear_velocity.y, 0.0)
		)
	_update_running_water(safe_delta)


func _configure_audio_players() -> void:
	var resolved_bus := audio_bus
	if AudioServer.get_bus_index(resolved_bus) < 0:
		resolved_bus = &"Master"
		push_warning(
			"VehicleWaterAudio bus '%s' does not exist; using Master."
			% audio_bus
		)
	for player: AudioStreamPlayer3D in [
		_impact_player_a,
		_impact_player_b,
		_running_player,
	]:
		player.bus = resolved_bus
		player.max_distance = maximum_distance
		player.unit_size = attenuation_unit_size
		player.doppler_tracking = AudioStreamPlayer3D.DOPPLER_TRACKING_PHYSICS_STEP
	_impact_player_a.top_level = true
	_impact_player_b.top_level = true


func _validate_streams() -> void:
	if _valid_stream_count(normal_splash_streams) == 0:
		push_warning("VehicleWaterAudio has no normal splash variants.")
	if _valid_stream_count(heavy_splash_streams) == 0:
		push_warning("VehicleWaterAudio has no heavy splash variants.")
	if _valid_stream_count(running_water_streams) == 0:
		push_warning("VehicleWaterAudio has no running-water variants.")
	for candidate: AudioStream in running_water_streams:
		if candidate is AudioStreamOggVorbis:
			(candidate as AudioStreamOggVorbis).loop = true


func _connect_vehicle_signals() -> void:
	if not _vehicle.water_entered.is_connected(_on_water_entered):
		_vehicle.water_entered.connect(_on_water_entered)
	if not _vehicle.reset_completed.is_connected(_on_vehicle_reset):
		_vehicle.reset_completed.connect(_on_vehicle_reset)
	if not _vehicle.world_rebased.is_connected(_on_world_rebased):
		_vehicle.world_rebased.connect(_on_world_rebased)


func _on_water_entered(
	_signal_intensity: float,
	impact_position: Vector3
) -> void:
	# This signal is emitted by the controller only after confirmed AIRBORNE
	# becomes a genuine water landing. Capture pre-contact descent before reset.
	var signal_frame_down_speed := maxf(-_vehicle.linear_velocity.y, 0.0)
	var impact_down_speed := maxf(
		_landing_down_speed,
		signal_frame_down_speed
	)
	_landing_down_speed = 0.0
	_last_splash_down_speed = impact_down_speed
	if _splash_cooldown_remaining > 0.0:
		return
	if impact_down_speed < minimum_landing_splash_speed:
		_last_splash_category = &"NONE"
		return

	var heavy := impact_down_speed >= heavy_landing_speed
	var variants := heavy_splash_streams if heavy else normal_splash_streams
	var previous := _last_heavy_stream if heavy else _last_normal_stream
	var selected := _choose_stream(variants, previous)
	if selected == null:
		return
	if heavy:
		_last_heavy_stream = selected
		_last_splash_category = &"HEAVY"
	else:
		_last_normal_stream = selected
		_last_splash_category = &"NORMAL"
	_play_impact(
		selected,
		impact_position,
		heavy_splash_volume_db if heavy else normal_splash_volume_db
	)
	_splash_cooldown_remaining = maxf(splash_cooldown_seconds, 0.0)


func _play_impact(
	selected_stream: AudioStream,
	impact_position: Vector3,
	impact_volume_db: float
) -> void:
	var player := _select_impact_player()
	player.global_position = impact_position
	player.stream = selected_stream
	player.volume_db = impact_volume_db
	player.pitch_scale = _random.randf_range(
		minf(splash_pitch_min, splash_pitch_max),
		maxf(splash_pitch_min, splash_pitch_max)
	)
	player.play()


func _select_impact_player() -> AudioStreamPlayer3D:
	var preferred := (
		_impact_player_a
		if (_impact_pool_cursor % 2) == 0
		else _impact_player_b
	)
	var alternate := (
		_impact_player_b
		if preferred == _impact_player_a
		else _impact_player_a
	)
	_impact_pool_cursor = (_impact_pool_cursor + 1) % 2
	if not preferred.playing:
		return preferred
	if not alternate.playing:
		return alternate
	return preferred


func _update_running_water(delta: float) -> void:
	var state := _vehicle.navigation_state
	var airborne := state == JetSkiController.NavigationState.AIRBORNE
	var deep_submerged := (
		state == JetSkiController.NavigationState.DEEP_SUBMERGED
	)
	var raw_contact := (
		_vehicle.current_contact_mask != 0
		and _vehicle.submerged_ratio > 0.0
	)
	if airborne or deep_submerged:
		_contact_grace_remaining = 0.0
	elif raw_contact:
		_contact_grace_remaining = maxf(water_contact_grace_seconds, 0.0)
	else:
		_contact_grace_remaining = maxf(
			_contact_grace_remaining - delta,
			0.0
		)
	var valid_surface_contact := (
		not airborne
		and not deep_submerged
		and (raw_contact or _contact_grace_remaining > 0.0)
	)

	if airborne or deep_submerged or not valid_surface_contact:
		_running_requested = false
	elif _running_requested:
		if _horizontal_speed <= running_water_stop_speed:
			_running_requested = false
	elif _horizontal_speed >= running_water_start_speed:
		_running_requested = true

	var speed_factor := _inverse_lerp_clamped(
		running_water_start_speed,
		maxf(running_water_full_speed, running_water_start_speed + 0.001),
		_horizontal_speed
	)
	_running_target_db = (
		lerpf(
			running_water_min_volume_db,
			running_water_max_volume_db,
			speed_factor
		)
		if _running_requested
		else -60.0
	)
	var target_pitch := lerpf(
		running_water_min_pitch,
		running_water_max_pitch,
		speed_factor
	)
	if _running_requested and not _running_player.playing:
		_start_running_water()
	if _running_player.playing:
		var fade_rate := running_water_fade_in_db_per_second
		if not _running_requested:
			fade_rate = (
				running_water_air_fade_out_db_per_second
				if airborne
				else running_water_fade_out_db_per_second
			)
		_running_player.volume_db = move_toward(
			_running_player.volume_db,
			_running_target_db,
			maxf(fade_rate, 0.0) * delta
		)
		var pitch_blend := 1.0 - exp(-6.0 * delta)
		_running_player.pitch_scale = lerpf(
			_running_player.pitch_scale,
			target_pitch,
			pitch_blend
		)
		if (
			not _running_requested
			and _running_player.volume_db <= -55.0
		):
			_running_player.stop()
			_running_player.stream = null
			_running_player.volume_db = -60.0


func _start_running_water() -> void:
	var selected := _choose_stream(
		running_water_streams,
		_last_running_stream
	)
	if selected == null:
		_running_requested = false
		return
	_last_running_stream = selected
	if selected is AudioStreamOggVorbis:
		(selected as AudioStreamOggVorbis).loop = true
	_running_player.stream = selected
	_running_player.volume_db = -60.0
	_running_player.pitch_scale = running_water_min_pitch
	_running_player.play()


func _choose_stream(
	variants: Array[AudioStream],
	previous: AudioStream
) -> AudioStream:
	var valid: Array[AudioStream] = []
	for candidate: AudioStream in variants:
		if candidate != null:
			valid.append(candidate)
	if valid.is_empty():
		return null
	if valid.size() == 1:
		return valid[0]
	var selected := valid[_random.randi_range(0, valid.size() - 1)]
	if selected == previous:
		var previous_index := valid.find(previous)
		var offset := _random.randi_range(1, valid.size() - 1)
		selected = valid[(previous_index + offset) % valid.size()]
	return selected


func _valid_stream_count(variants: Array[AudioStream]) -> int:
	var count := 0
	for candidate: AudioStream in variants:
		if candidate != null:
			count += 1
	return count


func _inverse_lerp_clamped(
	minimum: float,
	maximum: float,
	value: float
) -> float:
	if is_equal_approx(minimum, maximum):
		return 1.0 if value >= maximum else 0.0
	return clampf(inverse_lerp(minimum, maximum, value), 0.0, 1.0)


func _on_vehicle_reset(_reason: StringName) -> void:
	_reset_audio_state()


func _on_world_rebased(shift: Vector3) -> void:
	if not shift.is_finite():
		return
	var horizontal_shift := Vector3(shift.x, 0.0, shift.z)
	for player: AudioStreamPlayer3D in [
		_impact_player_a,
		_impact_player_b,
	]:
		if player.playing:
			player.global_position -= horizontal_shift


func _reset_audio_state() -> void:
	_landing_down_speed = 0.0
	_horizontal_speed = 0.0
	_splash_cooldown_remaining = 0.0
	_contact_grace_remaining = 0.0
	_running_requested = false
	_running_target_db = -60.0
	_last_splash_category = &"NONE"
	_last_splash_down_speed = 0.0
	for player: AudioStreamPlayer3D in [
		_impact_player_a,
		_impact_player_b,
		_running_player,
	]:
		player.stop()
		player.volume_db = -60.0
	_running_player.stream = null
