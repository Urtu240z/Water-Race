class_name AmbientWildlifeController
extends Node3D

const SEAGULL_SCENE: PackedScene = preload("res://world/wildlife/seagull/seagull.glb")
const DOLPHIN_SCENE: PackedScene = preload("res://world/wildlife/dolphin/dolphin.glb")
const FISH_SCENE: PackedScene = preload("res://world/wildlife/fish/fish.glb")
const DOLPHIN_BREACH_ANIMATION_SECONDS: float = 31.0 / 24.0

const BIRD_GROUPS := [
	{
		"center": Vector3(520.0, 54.0, 420.0),
		"count": 24,
		"radius_x": 72.0,
		"radius_z": 48.0,
	},
	{
		"center": Vector3(145.0, 68.0, 115.0),
		"count": 24,
		"radius_x": 125.0,
		"radius_z": 82.0,
	},
	{
		"center": Vector3(-210.0, 48.0, 155.0),
		"count": 24,
		"radius_x": 82.0,
		"radius_z": 58.0,
	},
]

const FISH_GROUPS := [
	{
		"center": Vector3(565.0, 0.0, 445.0),
		"count": 8,
		"radius_x": 34.0,
		"radius_z": 21.0,
		"depth": 4.2,
	},
	{
		"center": Vector3(565.0, 0.0, -235.0),
		"count": 8,
		"radius_x": 52.0,
		"radius_z": 30.0,
		"depth": 6.0,
	},
	{
		"center": Vector3(-315.0, 0.0, 245.0),
		"count": 8,
		"radius_x": 46.0,
		"radius_z": 28.0,
		"depth": 5.0,
	},
]

const DOLPHIN_GROUPS := [
	{
		"center": Vector3(525.0, 0.0, 420.0),
		"count": 4,
		"radius_x": 88.0,
		"radius_z": 56.0,
	},
	{
		"center": Vector3(470.0, 0.0, -300.0),
		"count": 4,
		"radius_x": 105.0,
		"radius_z": 64.0,
	},
]

@export_group("References")
@export_node_path("Ocean3D") var ocean_path: NodePath
@export_node_path("Node3D") var player_path: NodePath

@export_group("Population")
@export var wildlife_enabled: bool = true
@export_range(0.1, 3.0, 0.05) var animation_speed_multiplier: float = 1.0
@export_range(-20.0, 20.0, 0.01, "suffix:m") var fallback_water_level: float = -1.02
@export_range(0.1, 10.0, 0.1, "or_greater", "suffix:×") var bird_size_multiplier: float = 1.8
@export_range(0.1, 10.0, 0.1, "or_greater", "suffix:×") var fish_size_multiplier: float = 2.5
@export_range(0.1, 10.0, 0.1, "or_greater", "suffix:×") var dolphin_size_multiplier: float = 1.5

@export_group("Model Orientation")
@export_range(-180.0, 180.0, 1.0, "suffix:°") var bird_forward_yaw: float = 180.0
@export_range(-180.0, 180.0, 1.0, "suffix:°") var fish_forward_yaw: float = 180.0
@export_range(-180.0, 180.0, 1.0, "suffix:°") var dolphin_forward_yaw: float = 180.0

@export_group("Movement Randomness")
@export var randomize_each_run: bool = true
@export var movement_seed: int = 73194
@export_range(0.25, 3.0, 0.05) var wandering_response: float = 1.0

@export_group("Visibility")
@export_range(50.0, 2000.0, 10.0, "suffix:m") var bird_visibility_distance: float = 850.0
@export_range(50.0, 1000.0, 10.0, "suffix:m") var fish_visibility_distance: float = 260.0
@export_range(50.0, 2000.0, 10.0, "suffix:m") var dolphin_visibility_distance: float = 750.0

@export_group("Dolphin Breach")
@export_range(0.5, 3.0, 0.05, "suffix:s") var dolphin_breach_duration_min: float = 0.95
@export_range(0.5, 3.0, 0.05, "suffix:s") var dolphin_breach_duration_max: float = 1.35
@export_range(0.5, 12.0, 0.1, "suffix:m") var dolphin_breach_height_min: float = 3.2
@export_range(0.5, 12.0, 0.1, "suffix:m") var dolphin_breach_height_max: float = 5.8
@export_range(0.2, 0.7, 0.01) var dolphin_breach_rise_ratio: float = 0.40

@onready var bird_flocks: Node3D = $BirdFlocks
@onready var fish_schools: Node3D = $FishSchools
@onready var dolphin_pods: Node3D = $DolphinPods

var wildlife_actor_count: int:
	get:
		return _actors.size()

var visible_wildlife_actor_count: int:
	get:
		return _visible_actor_count

var quality_active_actor_count: int:
	get:
		return _quality_active_actor_count

var animated_wildlife_actor_count: int:
	get:
		return _animated_actor_count

var wildlife_update_rate_hz: float:
	get:
		return 1.0 / _quality_update_interval

var _ocean: Ocean3D
var _player: Node3D
var _actors: Array[Dictionary] = []
var _elapsed_time: float = 0.0
var _quality_elapsed: float = 0.0
var _quality_update_interval: float = 1.0 / 60.0
var _population_ratio: float = 1.0
var _visible_actor_count: int = 0
var _quality_active_actor_count: int = 0
var _animated_actor_count: int = 0
var _random := RandomNumberGenerator.new()


func _ready() -> void:
	LoadTrace.mark("WILDLIFE_SPAWN_BEGIN")
	_ocean = get_node_or_null(ocean_path) as Ocean3D
	_player = get_node_or_null(player_path) as Node3D
	if not wildlife_enabled:
		set_process(false)
		LoadTrace.mark("WILDLIFE_READY")
		return
	if randomize_each_run:
		_random.randomize()
	else:
		_random.seed = movement_seed
	_spawn_bird_flocks()
	LoadTrace.mark("WILDLIFE_BIRDS_READY")
	_spawn_fish_schools()
	LoadTrace.mark("WILDLIFE_FISH_READY")
	_spawn_dolphin_pods()
	LoadTrace.mark("WILDLIFE_DOLPHINS_READY")
	_update_wildlife(0.0)
	LoadTrace.mark("WILDLIFE_READY")


func _process(delta: float) -> void:
	_quality_elapsed += maxf(delta, 0.0)
	if _quality_elapsed < _quality_update_interval:
		return
	var update_delta := _quality_elapsed
	_quality_elapsed = 0.0
	_elapsed_time += update_delta
	_update_wildlife(update_delta)


func set_graphics_quality(
	_level: int,
	profile: GraphicsQualityProfile
) -> void:
	if profile == null:
		return
	_population_ratio = clampf(profile.wildlife_population_ratio, 0.0, 1.0)
	_quality_update_interval = 1.0 / maxf(
		profile.wildlife_update_rate_hz,
		1.0
	)
	bird_visibility_distance = profile.wildlife_bird_visibility_distance
	fish_visibility_distance = profile.wildlife_fish_visibility_distance
	dolphin_visibility_distance = (
		profile.wildlife_dolphin_visibility_distance
	)
	for state: Dictionary in _actors:
		var distance := _visibility_distance_for_type(String(state.type))
		state.visibility_distance = distance
		var actor := state.node as Node3D
		if actor == null:
			continue
		for child: Node in actor.find_children(
			"*",
			"GeometryInstance3D",
			true,
			false
		):
			var geometry := child as GeometryInstance3D
			if geometry != null:
				geometry.visibility_range_end = distance
	_quality_elapsed = _quality_update_interval
	if is_node_ready() and not _actors.is_empty():
		_update_wildlife(0.0)


func get_graphics_quality_debug_status() -> Dictionary:
	return {
		"actor_count": _actors.size(),
		"quality_active_actor_count": _quality_active_actor_count,
		"visible_actor_count": _visible_actor_count,
		"animated_actor_count": _animated_actor_count,
		"population_ratio": _population_ratio,
		"update_rate_hz": 1.0 / _quality_update_interval,
		"bird_visibility_distance": bird_visibility_distance,
		"fish_visibility_distance": fish_visibility_distance,
		"dolphin_visibility_distance": dolphin_visibility_distance,
	}


func _spawn_bird_flocks() -> void:
	var actor_index := 0
	for group_index in BIRD_GROUPS.size():
		var specification: Dictionary = BIRD_GROUPS[group_index]
		var group := Node3D.new()
		group.name = "BirdFlock_%02d" % (group_index + 1)
		bird_flocks.add_child(group)
		for member_index in int(specification.count):
			var actor := _instantiate_actor(
				SEAGULL_SCENE,
				group,
				"Seagull_%02d" % (actor_index + 1),
				"bird"
			)
			var animation_name := "Glide" if _random.randf() < 0.18 else "Fly"
			var animation_player := _find_animation_player(actor)
			var state := {
				"type": "bird",
				"node": actor,
				"player": animation_player,
				"animation": animation_name,
				"center": specification.center,
				"radius_x": float(specification.radius_x) * _random.randf_range(0.82, 1.08),
				"radius_z": float(specification.radius_z) * _random.randf_range(0.82, 1.08),
				"vertical_amplitude": _random.randf_range(5.0, 15.0),
				"speed": _random.randf_range(9.0, 17.0),
				"turn_response": _random.randf_range(0.42, 0.82),
				"retarget_time": _random.randf_range(2.0, 7.0),
				"visibility_distance": bird_visibility_distance,
				"group_index": group_index,
				"member_index": member_index,
				"group_count": int(specification.count),
			}
			state.actor_position = _random_bird_target(state)
			state.target_position = _random_bird_target(state)
			state.velocity = _initial_velocity(
				state.actor_position,
				state.target_position,
				float(state.speed)
			)
			actor.scale = (
				Vector3.ONE
				* bird_size_multiplier
				* _random.randf_range(0.82, 1.18)
			)
			_play_animation(state, animation_name, _random.randf_range(0.88, 1.18))
			_actors.append(state)
			actor_index += 1


func _spawn_fish_schools() -> void:
	var actor_index := 0
	for group_index in FISH_GROUPS.size():
		var specification: Dictionary = FISH_GROUPS[group_index]
		var group := Node3D.new()
		group.name = "FishSchool_%02d" % (group_index + 1)
		fish_schools.add_child(group)
		for member_index in int(specification.count):
			var actor := _instantiate_actor(
				FISH_SCENE,
				group,
				"Fish_%02d" % (actor_index + 1),
				"fish"
			)
			var animation_player := _find_animation_player(actor)
			var state := {
				"type": "fish",
				"node": actor,
				"player": animation_player,
				"animation": "Swim",
				"center": specification.center,
				"radius_x": float(specification.radius_x) * _random.randf_range(0.72, 1.0),
				"radius_z": float(specification.radius_z) * _random.randf_range(0.72, 1.0),
				"depth": float(specification.depth) + _random.randf_range(-0.4, 1.8),
				"vertical_amplitude": _random.randf_range(0.35, 1.2),
				"speed": _random.randf_range(2.2, 4.8),
				"turn_response": _random.randf_range(0.65, 1.25),
				"retarget_time": _random.randf_range(3.0, 8.0),
				"visibility_distance": fish_visibility_distance,
				"group_index": group_index,
				"member_index": member_index,
				"group_count": int(specification.count),
			}
			state.actor_position = _random_fish_target(state)
			state.target_position = _random_fish_target(state)
			state.velocity = _initial_velocity(
				state.actor_position,
				state.target_position,
				float(state.speed)
			)
			actor.scale = (
				Vector3.ONE
				* fish_size_multiplier
				* _random.randf_range(0.84, 1.24)
			)
			_play_animation(state, "Swim", _random.randf_range(0.82, 1.22))
			_actors.append(state)
			actor_index += 1


func _spawn_dolphin_pods() -> void:
	var actor_index := 0
	for group_index in DOLPHIN_GROUPS.size():
		var specification: Dictionary = DOLPHIN_GROUPS[group_index]
		var group := Node3D.new()
		group.name = "DolphinPod_%02d" % (group_index + 1)
		dolphin_pods.add_child(group)
		for member_index in int(specification.count):
			var actor := _instantiate_actor(
				DOLPHIN_SCENE,
				group,
				"Dolphin_%02d" % (actor_index + 1),
				"dolphin"
			)
			var animation_player := _find_animation_player(actor)
			var state := {
				"type": "dolphin",
				"node": actor,
				"player": animation_player,
				"animation": "Swim",
				"center": specification.center,
				"radius_x": float(specification.radius_x) * _random.randf_range(0.82, 1.06),
				"radius_z": float(specification.radius_z) * _random.randf_range(0.82, 1.06),
				"surface_offset": _random.randf_range(-2.4, -0.8),
				"speed": _random.randf_range(6.0, 10.5),
				"turn_response": _random.randf_range(0.38, 0.72),
				"retarget_time": _random.randf_range(4.0, 10.0),
				"is_breaching": false,
				"breach_start_time": 0.0,
				"breach_duration": _random.randf_range(
					dolphin_breach_duration_min,
					maxf(dolphin_breach_duration_max, dolphin_breach_duration_min)
				),
				"breach_height": _random.randf_range(
					dolphin_breach_height_min,
					maxf(dolphin_breach_height_max, dolphin_breach_height_min)
				),
				"next_breach_time": _random.randf_range(8.0, 32.0)
					+ group_index * 2.0
					+ member_index * 1.4,
				"visibility_distance": dolphin_visibility_distance,
				"group_index": group_index,
				"member_index": member_index,
				"group_count": int(specification.count),
			}
			state.actor_position = _random_dolphin_target(state)
			state.target_position = _random_dolphin_target(state)
			state.velocity = _initial_velocity(
				state.actor_position,
				state.target_position,
				float(state.speed)
			)
			actor.scale = (
				Vector3.ONE
				* dolphin_size_multiplier
				* _random.randf_range(0.54, 0.75)
			)
			_play_animation(state, "Swim", _random.randf_range(0.86, 1.12))
			_actors.append(state)
			actor_index += 1


func _instantiate_actor(
	packed_scene: PackedScene,
	parent: Node3D,
	actor_name: String,
	actor_type: String
) -> Node3D:
	var actor := packed_scene.instantiate() as Node3D
	actor.name = actor_name
	actor.set_meta("wildlife_type", actor_type)
	var forward_yaw := 0.0
	match actor_type:
		"bird":
			forward_yaw = bird_forward_yaw
		"fish":
			forward_yaw = fish_forward_yaw
		"dolphin":
			forward_yaw = dolphin_forward_yaw
	actor.set_meta("forward_yaw_radians", deg_to_rad(forward_yaw))
	parent.add_child(actor)
	for child in actor.find_children("*", "GeometryInstance3D", true, false):
		var geometry := child as GeometryInstance3D
		match actor_type:
			"bird":
				geometry.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
				geometry.visibility_range_end = bird_visibility_distance
			"fish":
				geometry.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
				geometry.visibility_range_end = fish_visibility_distance
			"dolphin":
				geometry.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
				geometry.visibility_range_end = dolphin_visibility_distance
		geometry.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
	return actor


func _find_animation_player(actor: Node) -> AnimationPlayer:
	if actor is AnimationPlayer:
		return actor as AnimationPlayer
	var matches := actor.find_children("*", "AnimationPlayer", true, false)
	return matches[0] as AnimationPlayer if not matches.is_empty() else null


func _update_wildlife(delta: float) -> void:
	_visible_actor_count = 0
	_quality_active_actor_count = 0
	_animated_actor_count = 0
	for state: Dictionary in _actors:
		var actor := state.node as Node3D
		var animation_player := state.player as AnimationPlayer
		var active_count := maxi(
			ceili(float(state.group_count) * _population_ratio),
			1
		)
		var quality_active := int(state.member_index) < active_count
		if not quality_active:
			_set_actor_runtime_active(actor, animation_player, false)
			continue
		_quality_active_actor_count += 1
		if not _actor_is_in_visibility_range(state):
			_set_actor_runtime_active(actor, animation_player, false)
			continue
		match String(state.type):
			"bird":
				_update_bird(state, delta)
			"fish":
				_update_fish(state, delta)
			"dolphin":
				_update_dolphin(state, delta)
		_set_actor_runtime_active(actor, animation_player, true)
		_visible_actor_count += 1
		_animated_actor_count += 1


func _actor_is_in_visibility_range(state: Dictionary) -> bool:
	var actor := state.node as Node3D
	if is_instance_valid(_player):
		var maximum_distance := float(state.visibility_distance)
		return (
			actor.global_position.distance_squared_to(_player.global_position)
			<= maximum_distance * maximum_distance
		)
	return true


func _set_actor_runtime_active(
	actor: Node3D,
	animation_player: AnimationPlayer,
	active: bool
) -> void:
	if is_instance_valid(actor):
		actor.visible = active
	if is_instance_valid(animation_player):
		animation_player.active = active


func _visibility_distance_for_type(actor_type: String) -> float:
	match actor_type:
		"bird":
			return bird_visibility_distance
		"fish":
			return fish_visibility_distance
		_:
			return dolphin_visibility_distance


func _update_bird(state: Dictionary, delta: float) -> void:
	var actor := state.node as Node3D
	state.retarget_time = float(state.retarget_time) - delta
	if _wanderer_needs_target(state, 8.0):
		state.target_position = _random_bird_target(state)
		state.retarget_time = _random.randf_range(3.5, 9.0)
	_advance_wanderer(state, delta)
	var actor_position := state.actor_position as Vector3
	var velocity := state.velocity as Vector3
	var next_position := actor_position + velocity
	_set_actor_transform(actor, actor_position, next_position)


func _update_fish(state: Dictionary, delta: float) -> void:
	var actor := state.node as Node3D
	state.retarget_time = float(state.retarget_time) - delta
	if _wanderer_needs_target(state, 2.2):
		state.target_position = _random_fish_target(state)
		state.retarget_time = _random.randf_range(4.0, 10.0)
	_advance_wanderer(state, delta)
	var actor_position := state.actor_position as Vector3
	var velocity := state.velocity as Vector3
	var next_position := actor_position + velocity
	_set_actor_transform(actor, actor_position, next_position)


func _update_dolphin(state: Dictionary, delta: float) -> void:
	var actor := state.node as Node3D
	state.retarget_time = float(state.retarget_time) - delta
	if _wanderer_needs_target(state, 10.0):
		state.target_position = _random_dolphin_target(state)
		state.retarget_time = _random.randf_range(6.0, 14.0)
	_advance_wanderer(state, delta)

	var is_breaching := bool(state.is_breaching)
	if not is_breaching and _elapsed_time >= float(state.next_breach_time):
		is_breaching = true
		state.is_breaching = true
		state.breach_start_time = _elapsed_time
		state.breach_duration = _random.randf_range(
			dolphin_breach_duration_min,
			maxf(dolphin_breach_duration_max, dolphin_breach_duration_min)
		)
		state.breach_height = _random.randf_range(
			dolphin_breach_height_min,
			maxf(dolphin_breach_height_max, dolphin_breach_height_min)
		)

	var actor_position := state.actor_position as Vector3
	var velocity := state.velocity as Vector3
	var surface_height := _sample_surface_height(actor_position)
	var vertical_speed := 0.0
	if is_breaching:
		var normalized_time := clampf(
			(_elapsed_time - float(state.breach_start_time))
				/ float(state.breach_duration),
			0.0,
			1.0
		)
		var rise_ratio := clampf(dolphin_breach_rise_ratio, 0.2, 0.7)
		var arc := 0.0
		var normalized_vertical_speed := 0.0
		if normalized_time < rise_ratio:
			var rise_time := normalized_time / rise_ratio
			arc = 1.0 - (1.0 - rise_time) * (1.0 - rise_time)
			normalized_vertical_speed = (
				2.0 * (1.0 - rise_time)
				/ rise_ratio
			)
		else:
			var fall_time := (
				(normalized_time - rise_ratio)
				/ maxf(1.0 - rise_ratio, 0.001)
			)
			arc = 1.0 - fall_time * fall_time
			normalized_vertical_speed = (
				-2.0 * fall_time
				/ maxf(1.0 - rise_ratio, 0.001)
			)
		actor_position.y = (
			surface_height
			+ float(state.surface_offset)
			+ arc * float(state.breach_height)
		)
		vertical_speed = (
			normalized_vertical_speed
			* float(state.breach_height)
			/ float(state.breach_duration)
		)
		if normalized_time >= 1.0:
			is_breaching = false
			state.is_breaching = false
			state.next_breach_time = _elapsed_time + _random.randf_range(14.0, 42.0)
	else:
		var swim_wave := sin(_elapsed_time * 1.35 + float(state.speed))
		actor_position.y = surface_height + float(state.surface_offset) + swim_wave * 0.22
		vertical_speed = cos(_elapsed_time * 1.35 + float(state.speed)) * 0.30

	state.actor_position = actor_position
	var facing_velocity := velocity
	facing_velocity.y = vertical_speed
	var next_position := actor_position + facing_velocity
	_set_actor_transform(actor, actor_position, next_position)
	if is_breaching:
		var synchronized_speed := (
			DOLPHIN_BREACH_ANIMATION_SECONDS
			/ maxf(float(state.breach_duration), 0.001)
			/ maxf(animation_speed_multiplier, 0.001)
		)
		_play_animation(state, "Breach", synchronized_speed)
	else:
		_play_animation(state, "Swim", 0.92)


func _advance_wanderer(state: Dictionary, delta: float) -> void:
	var actor_position := state.actor_position as Vector3
	var target_position := state.target_position as Vector3
	var velocity := state.velocity as Vector3
	var target_direction := target_position - actor_position
	var center := state.center as Vector3
	var normalized_x := (actor_position.x - center.x) / float(state.radius_x)
	var normalized_z := (actor_position.z - center.z) / float(state.radius_z)
	var zone_radius := Vector2(normalized_x, normalized_z).length()
	if zone_radius > 0.92:
		target_direction.x = center.x - actor_position.x
		target_direction.z = center.z - actor_position.z
	if target_direction.length_squared() > 0.0001:
		var desired_heading := Vector3(
			target_direction.x,
			0.0,
			target_direction.z
		).normalized()
		var current_heading := Vector3(
			velocity.x,
			0.0,
			velocity.z
		).normalized()
		if current_heading.length_squared() <= 0.0001:
			current_heading = desired_heading
		if desired_heading.length_squared() <= 0.0001:
			desired_heading = current_heading
		if current_heading.dot(desired_heading) < -0.97:
			var turn_sign := (
				-1.0
				if (state.node as Node).get_instance_id() % 2 == 0
				else 1.0
			)
			var perpendicular := Vector3(
				-current_heading.z,
				0.0,
				current_heading.x
			)
			desired_heading = (
				desired_heading
				+ perpendicular.normalized() * turn_sign * 0.18
			).normalized()
		var maximum_turn := (
			float(state.turn_response)
			* wandering_response
			* delta
		)
		if zone_radius > 0.92:
			maximum_turn *= 1.0 + clampf(
				(zone_radius - 0.92) * 4.0,
				0.0,
				2.5
			)
		var turn_angle := current_heading.angle_to(desired_heading)
		var turn_fraction := (
			1.0
			if turn_angle <= 0.0001
			else minf(1.0, maximum_turn / turn_angle)
		)
		var new_heading := current_heading.slerp(
			desired_heading,
			turn_fraction
		).normalized()
		var maximum_vertical_speed := float(state.speed) * 0.35
		var desired_vertical_speed := clampf(
			target_direction.y,
			-maximum_vertical_speed,
			maximum_vertical_speed
		)
		var vertical_blend := 1.0 - exp(
			-float(state.turn_response) * wandering_response * delta
		)
		velocity = new_heading * float(state.speed)
		velocity.y = lerpf(
			float((state.velocity as Vector3).y),
			desired_vertical_speed,
			clampf(vertical_blend, 0.0, 1.0)
		)
	actor_position += velocity * delta
	state.actor_position = actor_position
	state.velocity = velocity


func _wanderer_needs_target(state: Dictionary, arrival_distance: float) -> bool:
	if float(state.retarget_time) <= 0.0:
		return true
	var actor_position := state.actor_position as Vector3
	var target_position := state.target_position as Vector3
	return (
		actor_position.distance_squared_to(target_position)
		<= arrival_distance * arrival_distance
	)


func _random_bird_target(state: Dictionary) -> Vector3:
	var horizontal := _random_point_in_ellipse(
		state.center,
		float(state.radius_x),
		float(state.radius_z)
	)
	var center := state.center as Vector3
	horizontal.y = center.y + _random.randf_range(
		-float(state.vertical_amplitude),
		float(state.vertical_amplitude)
	)
	return horizontal


func _random_fish_target(state: Dictionary) -> Vector3:
	var target_position := _random_point_in_ellipse(
		state.center,
		float(state.radius_x),
		float(state.radius_z)
	)
	var surface_level := (
		_ocean.water_level
		if is_instance_valid(_ocean)
		else fallback_water_level
	)
	target_position.y = (
		surface_level
		- float(state.depth)
		+ _random.randf_range(
			-float(state.vertical_amplitude),
			float(state.vertical_amplitude)
		)
	)
	return target_position


func _random_dolphin_target(state: Dictionary) -> Vector3:
	var target_position := _random_point_in_ellipse(
		state.center,
		float(state.radius_x),
		float(state.radius_z)
	)
	target_position.y = _sample_surface_height(target_position) + float(state.surface_offset)
	return target_position


func _random_point_in_ellipse(
	center: Vector3,
	radius_x: float,
	radius_z: float
) -> Vector3:
	var angle := _random.randf_range(0.0, TAU)
	var radial_distance := sqrt(_random.randf_range(0.06, 1.0))
	return Vector3(
		center.x + cos(angle) * radius_x * radial_distance,
		center.y,
		center.z + sin(angle) * radius_z * radial_distance
	)


func _initial_velocity(
	actor_position: Vector3,
	target_position: Vector3,
	speed: float
) -> Vector3:
	var direction := target_position - actor_position
	if direction.length_squared() <= 0.0001:
		var random_angle := _random.randf_range(0.0, TAU)
		direction = Vector3(cos(random_angle), 0.0, sin(random_angle))
	return direction.normalized() * speed


func _sample_surface_height(world_position: Vector3) -> float:
	if is_instance_valid(_ocean):
		return _ocean.sample_height(world_position)
	return fallback_water_level


func _set_actor_transform(
	actor: Node3D,
	actor_position: Vector3,
	next_position: Vector3
) -> void:
	actor.global_position = actor_position
	var direction := next_position - actor_position
	if direction.length_squared() > 0.000001:
		actor.look_at(next_position, Vector3.UP)
		actor.rotate_object_local(
			Vector3.UP,
			float(actor.get_meta("forward_yaw_radians", 0.0))
		)


func _play_animation(state: Dictionary, animation_name: String, speed: float) -> void:
	var animation_player := state.player as AnimationPlayer
	if not is_instance_valid(animation_player):
		return
	if String(state.animation) != animation_name or not animation_player.is_playing():
		state.animation = animation_name
		animation_player.play(animation_name, 0.20)
	animation_player.speed_scale = speed * animation_speed_multiplier
