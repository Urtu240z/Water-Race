@tool
class_name BoatTrafficActor
extends AnimatableBody3D

const WATER_SAMPLE_INTERVAL: float = 0.05
const CAMERA_OPTIMIZATION_UPDATE_INTERVAL: float = 0.1
const MIN_PATH_LENGTH: float = 0.001
const MIN_SAMPLE_SEPARATION: float = 0.1

@export_group("Movement")
@export var enabled: bool = true
@export_range(0.0, 50.0, 0.1, "or_greater", "suffix:m/s") var speed_mps: float = 8.0
@export_range(0.0, 100000.0, 0.1, "or_greater", "suffix:m") var start_progress: float = 0.0
@export var loop: bool = true
@export var reverse: bool = false
@export_range(0.01, 10.0, 0.05, "or_greater") var heading_response: float = 0.85
@export_range(1.0, 90.0, 0.5, "or_greater", "suffix:deg/s") var maximum_yaw_rate_degrees: float = 14.0

@export_group("Model")
@export var model_scene: PackedScene = preload("res://world/props/boats/boat_01.glb"):
	set(value):
		model_scene = value
		_queue_model_rebuild()
@export var model_position_offset: Vector3 = Vector3(0.0, -1.421934, 0.0):
	set(value):
		model_position_offset = value
		_apply_model_transform()
@export var model_rotation_offset_degrees: Vector3 = Vector3(0.0, 117.5667, 0.0):
	set(value):
		model_rotation_offset_degrees = value
		_apply_model_transform()
@export var model_scale: Vector3 = Vector3(0.395, 0.395, 0.395):
	set(value):
		model_scale = value
		_apply_model_transform()

@export_group("Water Following")
@export_node_path("Node3D") var water_provider_path: NodePath
@export_range(-10.0, 10.0, 0.01, "suffix:m") var waterline_offset: float = 0.0
@export_range(0.5, 100.0, 0.1, "or_greater", "suffix:m") var sample_length: float = 20.0
@export_range(0.5, 50.0, 0.1, "or_greater", "suffix:m") var sample_width: float = 6.0
@export_range(0.01, 20.0, 0.05, "or_greater") var vertical_response: float = 1.8
@export_range(0.01, 20.0, 0.05, "or_greater") var pitch_response: float = 1.35
@export_range(0.01, 20.0, 0.05, "or_greater") var roll_response: float = 1.15
@export_range(0.0, 30.0, 0.1, "suffix:deg") var maximum_pitch_degrees: float = 4.0
@export_range(0.0, 30.0, 0.1, "suffix:deg") var maximum_roll_degrees: float = 5.0

@export_group("Wake")
@export var wake_enabled: bool = true
@export_range(0.0, 4.0, 0.05, "or_greater") var wake_visual_strength: float = 2.5
@export_range(0.5, 30.0, 0.1, "or_greater", "suffix:m") var wake_width: float = 5.0
@export_range(2.0, 100.0, 0.5, "or_greater", "suffix:m") var wake_length: float = 28.0
@export_range(0.1, 12.0, 0.1, "or_greater", "suffix:s") var wake_fade: float = 4.0
@export_range(0.0, 30.0, 0.1, "or_greater", "suffix:m/s") var wake_minimum_speed: float = 2.0
@export_range(0.0, 2.0, 0.05, "or_greater") var directional_wake_strength: float = 1.5
@export var navigable_wake_enabled: bool = true
@export var physical_wake_enabled: bool = true
@export_range(0.0, 6.0, 0.05, "or_greater") var physical_wake_strength: float = 1.0
@export_range(0.5, 30.0, 0.25, "or_greater", "suffix:m") var physical_wake_interval_distance: float = 5.0
@export_range(0.0, 30.0, 0.1, "or_greater", "suffix:m/s") var physical_wake_minimum_speed: float = 2.0

@export_group("Optimization")
@export var camera_visibility_optimization_enabled: bool = true
@export_range(0.05, 1.0, 0.05, "suffix:s") var offscreen_water_sample_interval: float = 0.25
@export_range(10.0, 1000.0, 5.0, "or_greater", "suffix:m") var wake_near_distance: float = 120.0
@export_range(10.0, 2000.0, 5.0, "or_greater", "suffix:m") var wake_medium_distance: float = 280.0

@export_group("Collision")
@export var collision_enabled: bool = true
@export var collision_rotation_offset_degrees: Vector3 = Vector3(0.0, -152.4333, 0.0)
@export var collision_main_size: Vector3 = Vector3(6.8, 3.2, 20.0)
@export var collision_main_offset: Vector3 = Vector3(0.0, 0.2, 0.5)
@export var collision_bow_size: Vector3 = Vector3(5.0, 2.6, 7.0)
@export var collision_bow_offset: Vector3 = Vector3(0.0, 0.0, -10.5)

@export_group("Debug")
@export var debug_draw: bool = false

var _path_follow: PathFollow3D
var _path: Path3D
var _water_provider: WaterSurfaceProvider3D
var _ocean: Ocean3D
var _model_pivot: Node3D
var _model_container: Node3D
var _main_collision: CollisionShape3D
var _bow_collision: CollisionShape3D
var _front_marker: Marker3D
var _rear_marker: Marker3D
var _left_marker: Marker3D
var _right_marker: Marker3D
var _stern_center: Marker3D
var _stern_left: Marker3D
var _stern_right: Marker3D
var _wake_trail: WakeTrail3D
var _visibility_notifier: VisibleOnScreenNotifier3D
var _debug_mesh_instance: MeshInstance3D
var _debug_mesh: ImmediateMesh
var _model_rebuild_queued: bool = false

var _front_sample_scratch := WaterSample3D.new()
var _rear_sample_scratch := WaterSample3D.new()
var _left_sample_scratch := WaterSample3D.new()
var _right_sample_scratch := WaterSample3D.new()
var _front_surface_position: Vector3 = Vector3.ZERO
var _rear_surface_position: Vector3 = Vector3.ZERO
var _left_surface_position: Vector3 = Vector3.ZERO
var _right_surface_position: Vector3 = Vector3.ZERO
var _target_water_height: float = 0.0
var _target_pitch: float = 0.0
var _target_roll: float = 0.0
var _smoothed_water_height: float = 0.0
var _smoothed_pitch: float = 0.0
var _smoothed_roll: float = 0.0
var _smoothed_heading_forward: Vector3 = Vector3.BACK
var _has_smoothed_heading: bool = false
var _has_valid_water_target: bool = false
var _water_sample_elapsed: float = WATER_SAMPLE_INTERVAL
var _path_stopped: bool = false
var _has_last_wake_position: bool = false
var _last_wake_position: Vector3 = Vector3.ZERO
var _wake_distance_accumulator: float = 0.0
var _last_wake_emission_position: Vector3 = Vector3.ZERO
var _emit_left_physical_wake: bool = true
var _camera_effects_active: bool = true
var _camera_optimization_elapsed: float = CAMERA_OPTIMIZATION_UPDATE_INTERVAL


func _ready() -> void:
	_cache_nodes()
	_apply_model_transform()
	_rebuild_model()
	_apply_marker_configuration()
	_apply_collision_configuration()
	if Engine.is_editor_hint():
		set_physics_process(false)
		return
	process_physics_priority = 0
	_resolve_runtime_references()
	_initialize_path_progress()
	_sample_water_target()
	_update_water_follow(0.0, true)
	_configure_wake_trail()
	_connect_visibility_notifier()
	_update_camera_optimization(0.0, true)
	set_physics_process(true)


func _physics_process(delta: float) -> void:
	if delta <= 0.0 or not is_instance_valid(_path_follow):
		return
	_advance_path(delta)
	_update_camera_optimization(delta, false)
	_update_water_follow(delta, false)
	_update_wakes()
	_update_debug_draw()


func _get_configuration_warnings() -> PackedStringArray:
	var warnings := PackedStringArray()
	if get_parent() is not PathFollow3D:
		warnings.append("BoatTrafficActor must be a direct child of a PathFollow3D.")
	if model_scene == null:
		warnings.append("No boat model scene is configured.")
	if water_provider_path.is_empty():
		warnings.append("Assign an Ocean3D/WaterSurfaceProvider3D path for authoritative flotation.")
	return warnings


func _cache_nodes() -> void:
	_path_follow = get_parent() as PathFollow3D
	_path = _path_follow.get_parent() as Path3D if is_instance_valid(_path_follow) else null
	_model_pivot = get_node_or_null("ModelPivot") as Node3D
	_model_container = get_node_or_null("ModelPivot/ModelContainer") as Node3D
	_main_collision = get_node_or_null("MainHullCollision") as CollisionShape3D
	_bow_collision = get_node_or_null("BowCollision") as CollisionShape3D
	_front_marker = get_node_or_null("WaterSamples/Front") as Marker3D
	_rear_marker = get_node_or_null("WaterSamples/Rear") as Marker3D
	_left_marker = get_node_or_null("WaterSamples/Left") as Marker3D
	_right_marker = get_node_or_null("WaterSamples/Right") as Marker3D
	_stern_center = get_node_or_null("WakePoints/SternCenter") as Marker3D
	_stern_left = get_node_or_null("WakePoints/SternLeft") as Marker3D
	_stern_right = get_node_or_null("WakePoints/SternRight") as Marker3D
	_wake_trail = get_node_or_null("WakeRoot/BoatWake") as WakeTrail3D
	_visibility_notifier = get_node_or_null("VisibilityNotifier") as VisibleOnScreenNotifier3D
	_debug_mesh_instance = get_node_or_null("DebugDraw") as MeshInstance3D
	if is_instance_valid(_debug_mesh_instance):
		_debug_mesh = _debug_mesh_instance.mesh as ImmediateMesh


func _resolve_runtime_references() -> void:
	_water_provider = get_node_or_null(water_provider_path) as WaterSurfaceProvider3D
	if not is_instance_valid(_water_provider):
		_water_provider = get_tree().get_first_node_in_group(&"ocean_3d") as WaterSurfaceProvider3D
	_ocean = _water_provider as Ocean3D
	if not is_instance_valid(_water_provider):
		push_warning("BoatTrafficActor could not resolve its water provider; water following is disabled.")


func _initialize_path_progress() -> void:
	if not is_instance_valid(_path_follow) or not is_instance_valid(_path) or _path.curve == null:
		return
	var path_length := _path.curve.get_baked_length()
	_path_follow.loop = loop
	if path_length <= MIN_PATH_LENGTH:
		_path_follow.progress = 0.0
		_path_stopped = true
		return
	_path_follow.progress = (
		fposmod(start_progress, path_length)
		if loop
		else clampf(start_progress, 0.0, path_length)
	)
	_path_stopped = false


func _advance_path(delta: float) -> void:
	if not enabled or speed_mps <= 0.0 or _path_stopped:
		return
	if not is_instance_valid(_path) or _path.curve == null:
		return
	var path_length := _path.curve.get_baked_length()
	if path_length <= MIN_PATH_LENGTH:
		_path_stopped = true
		return
	var signed_step := speed_mps * delta * (-1.0 if reverse else 1.0)
	var next_progress := _path_follow.progress + signed_step
	_path_follow.loop = loop
	if loop:
		_path_follow.progress = fposmod(next_progress, path_length)
		return
	_path_follow.progress = clampf(next_progress, 0.0, path_length)
	_path_stopped = (
		_path_follow.progress <= 0.0
		if reverse
		else _path_follow.progress >= path_length
	)


func _update_water_follow(delta: float, snap: bool) -> void:
	if not is_instance_valid(_path_follow):
		return
	_water_sample_elapsed += maxf(delta, 0.0)
	var water_sample_interval := (
		WATER_SAMPLE_INTERVAL
		if _camera_effects_active
		else maxf(offscreen_water_sample_interval, WATER_SAMPLE_INTERVAL)
	)
	if _water_sample_elapsed >= water_sample_interval:
		_water_sample_elapsed = fmod(_water_sample_elapsed, water_sample_interval)
		_sample_water_target()
	var path_transform := _path_follow.global_transform
	var path_position := path_transform.origin
	var path_forward := path_transform.basis.z
	if reverse:
		path_forward = -path_forward
	path_forward.y = 0.0
	if path_forward.length_squared() <= 0.000001 or not path_forward.is_finite():
		path_forward = Vector3.BACK
	else:
		path_forward = path_forward.normalized()
	_update_smoothed_heading(path_forward, delta, snap)
	var hull_forward := _smoothed_heading_forward
	var hull_right := Vector3(hull_forward.z, 0.0, -hull_forward.x)
	if _has_valid_water_target:
		if snap:
			_smoothed_water_height = _target_water_height
			_smoothed_pitch = _target_pitch
			_smoothed_roll = _target_roll
		else:
			_smoothed_water_height = lerpf(
				_smoothed_water_height,
				_target_water_height,
				_exponential_response(vertical_response, delta)
			)
			_smoothed_pitch = lerpf(
				_smoothed_pitch,
				_target_pitch,
				_exponential_response(pitch_response, delta)
			)
			_smoothed_roll = lerpf(
				_smoothed_roll,
				_target_roll,
				_exponential_response(roll_response, delta)
			)
	else:
		_smoothed_water_height = path_position.y
	var forward_on_water := (
		hull_forward + Vector3.UP * tan(_smoothed_pitch)
	).normalized()
	var right_on_water := (
		hull_right + Vector3.UP * tan(_smoothed_roll)
	).normalized()
	var water_up := forward_on_water.cross(right_on_water)
	if water_up.length_squared() <= 0.000001 or not water_up.is_finite():
		water_up = Vector3.UP
	else:
		water_up = water_up.normalized()
	right_on_water = water_up.cross(forward_on_water).normalized()
	forward_on_water = right_on_water.cross(water_up).normalized()
	var water_basis := Basis(right_on_water, water_up, forward_on_water).orthonormalized()
	global_transform = Transform3D(
		water_basis,
		Vector3(path_position.x, _smoothed_water_height, path_position.z)
	)


func _sample_water_target() -> void:
	if not is_instance_valid(_water_provider) or not is_instance_valid(_path_follow):
		return
	var path_transform := _path_follow.global_transform
	var center := path_transform.origin
	var forward := (
		_smoothed_heading_forward
		if _has_smoothed_heading
		else path_transform.basis.z * (-1.0 if reverse else 1.0)
	)
	forward.y = 0.0
	if forward.length_squared() <= 0.000001:
		return
	forward = forward.normalized()
	var right := Vector3(forward.z, 0.0, -forward.x)
	var half_length := maxf(sample_length, MIN_SAMPLE_SEPARATION) * 0.5
	var half_width := maxf(sample_width, MIN_SAMPLE_SEPARATION) * 0.5
	var front_query := center + forward * half_length
	var rear_query := center - forward * half_length
	var left_query := center - right * half_width
	var right_query := center + right * half_width
	var front_sample := _water_provider.sample_water(front_query, _front_sample_scratch)
	var rear_sample := _water_provider.sample_water(rear_query, _rear_sample_scratch)
	var left_sample := _water_provider.sample_water(left_query, _left_sample_scratch)
	var right_sample := _water_provider.sample_water(right_query, _right_sample_scratch)
	if not (
		front_sample.valid
		and rear_sample.valid
		and left_sample.valid
		and right_sample.valid
	):
		return
	_front_surface_position = front_sample.surface_position
	_rear_surface_position = rear_sample.surface_position
	_left_surface_position = left_sample.surface_position
	_right_surface_position = right_sample.surface_position
	var front_height := _front_surface_position.y
	var rear_height := _rear_surface_position.y
	var left_height := _left_surface_position.y
	var right_height := _right_surface_position.y
	if not (
		is_finite(front_height)
		and is_finite(rear_height)
		and is_finite(left_height)
		and is_finite(right_height)
	):
		return
	_target_water_height = (
		(front_height + rear_height + left_height + right_height) * 0.25
		+ waterline_offset
	)
	_target_pitch = clampf(
		atan2(front_height - rear_height, maxf(sample_length, MIN_SAMPLE_SEPARATION)),
		-deg_to_rad(maximum_pitch_degrees),
		deg_to_rad(maximum_pitch_degrees)
	)
	_target_roll = clampf(
		atan2(right_height - left_height, maxf(sample_width, MIN_SAMPLE_SEPARATION)),
		-deg_to_rad(maximum_roll_degrees),
		deg_to_rad(maximum_roll_degrees)
	)
	_has_valid_water_target = true


func _configure_wake_trail() -> void:
	if not is_instance_valid(_wake_trail):
		return
	_wake_trail.wake_enabled = wake_enabled
	_wake_trail.wake_minimum_speed = wake_minimum_speed
	_wake_trail.wake_full_speed = maxf(wake_minimum_speed + 6.0, speed_mps)
	_wake_trail.wake_strength_multiplier = wake_visual_strength
	_wake_trail.directional_strength_multiplier = directional_wake_strength
	_wake_trail.directional_physics_enabled = navigable_wake_enabled
	_wake_trail.wake_surface_offset = 0.18
	_wake_trail.wake_initial_width_multiplier = 1.0
	_wake_trail.wake_maximum_width_multiplier = 2.2
	_wake_trail.wake_opening_distance = maxf(wake_length * 0.25, 1.0)
	var effective_speed := maxf(speed_mps, wake_minimum_speed + 0.1)
	var effective_lifetime := minf(wake_fade, wake_length / effective_speed)
	var sample_distance := clampf(wake_length / 32.0, 0.5, 1.5)
	var maximum_points := clampi(ceili(wake_length / sample_distance) + 2, 12, 40)
	_wake_trail.configure_quality(
		maximum_points,
		1.0 / 60.0,
		sample_distance,
		maxf(effective_lifetime, 0.25)
	)
	if is_instance_valid(_ocean):
		_wake_trail.configure_external_source(
			_ocean,
			_stern_center,
			_stern_left,
			_stern_right
		)


func _connect_visibility_notifier() -> void:
	if not is_instance_valid(_visibility_notifier):
		return
	if not _visibility_notifier.screen_entered.is_connected(_on_screen_entered):
		_visibility_notifier.screen_entered.connect(_on_screen_entered)
	if not _visibility_notifier.screen_exited.is_connected(_on_screen_exited):
		_visibility_notifier.screen_exited.connect(_on_screen_exited)


func _update_camera_optimization(delta: float, force: bool) -> void:
	_camera_optimization_elapsed += maxf(delta, 0.0)
	if not force and _camera_optimization_elapsed < CAMERA_OPTIMIZATION_UPDATE_INTERVAL:
		return
	_camera_optimization_elapsed = 0.0
	var current_camera := get_viewport().get_camera_3d()
	if (
		not camera_visibility_optimization_enabled
		or not is_instance_valid(_visibility_notifier)
		or not is_instance_valid(current_camera)
	):
		_set_camera_effects_active(true)
		_apply_wake_lod_interval(1.0 / 60.0)
		return
	_set_camera_effects_active(_visibility_notifier.is_on_screen())
	if not _camera_effects_active:
		return
	var camera_distance := global_position.distance_to(current_camera.global_position)
	var lod_interval := 1.0 / 15.0
	if camera_distance <= wake_near_distance:
		lod_interval = 1.0 / 60.0
	elif camera_distance <= maxf(wake_medium_distance, wake_near_distance):
		lod_interval = 1.0 / 30.0
	_apply_wake_lod_interval(lod_interval)


func _set_camera_effects_active(active: bool) -> void:
	if _camera_effects_active == active:
		return
	_camera_effects_active = active
	if is_instance_valid(_wake_trail):
		_wake_trail.set_external_visibility_active(active)
	if active:
		_water_sample_elapsed = maxf(offscreen_water_sample_interval, WATER_SAMPLE_INTERVAL)
	else:
		_has_last_wake_position = false
		_wake_distance_accumulator = 0.0


func _apply_wake_lod_interval(update_interval: float) -> void:
	if not is_instance_valid(_wake_trail):
		return
	var safe_interval := clampf(update_interval, 0.01, 0.25)
	_wake_trail.mesh_update_interval = safe_interval
	_wake_trail.requested_directional_update_interval = safe_interval


func _on_screen_entered() -> void:
	if camera_visibility_optimization_enabled:
		_set_camera_effects_active(true)
		_camera_optimization_elapsed = CAMERA_OPTIMIZATION_UPDATE_INTERVAL


func _on_screen_exited() -> void:
	if camera_visibility_optimization_enabled:
		_set_camera_effects_active(false)


func _update_wakes() -> void:
	var current_speed := (
		speed_mps
		if enabled and not _path_stopped
		else 0.0
	)
	var forward := global_basis.z
	forward.y = 0.0
	if forward.length_squared() <= 0.000001:
		forward = Vector3.BACK
	else:
		forward = forward.normalized()
	var visual_generating := (
		wake_enabled
		and _camera_effects_active
		and current_speed > wake_minimum_speed
		and is_instance_valid(_ocean)
	)
	if is_instance_valid(_wake_trail):
		_wake_trail.wake_enabled = wake_enabled
		_wake_trail.wake_strength_multiplier = wake_visual_strength
		_wake_trail.update_external_source(current_speed, forward, visual_generating)
	_update_physical_wake(current_speed if _camera_effects_active else 0.0)


func _update_physical_wake(current_speed: float) -> void:
	if not (
		physical_wake_enabled
		and current_speed > physical_wake_minimum_speed
		and is_instance_valid(_ocean)
		and is_instance_valid(_stern_center)
	):
		_has_last_wake_position = false
		_wake_distance_accumulator = 0.0
		return
	var current_position := _stern_center.global_position
	if not _has_last_wake_position:
		_last_wake_position = current_position
		_has_last_wake_position = true
		return
	var travelled := Vector2(
		current_position.x - _last_wake_position.x,
		current_position.z - _last_wake_position.z
	).length()
	_last_wake_position = current_position
	if travelled > maxf(sample_length * 3.0, 30.0):
		_wake_distance_accumulator = 0.0
		return
	_wake_distance_accumulator += travelled
	var safe_interval := maxf(physical_wake_interval_distance, 0.5)
	if _wake_distance_accumulator < safe_interval:
		return
	_wake_distance_accumulator = fmod(_wake_distance_accumulator, safe_interval)
	var speed_factor := clampf(
		inverse_lerp(
			physical_wake_minimum_speed,
			physical_wake_minimum_speed + 8.0,
			current_speed
		),
		0.0,
		1.0
	)
	# Dense alternating ripples overlap into a continuous wake. Each crest still
	# stands clearly above the large ambient Gold City swell without pulsing as
	# a simultaneous left/right pair.
	var amplitude := 0.12 * physical_wake_strength * speed_factor
	if amplitude <= 0.0:
		return
	var ripple_wavelength := clampf(wake_width * 0.38, 2.4, 6.0)
	var emitter := _stern_left if _emit_left_physical_wake else _stern_right
	_emit_physical_ripple(emitter, current_position, amplitude, ripple_wavelength)
	_emit_left_physical_wake = not _emit_left_physical_wake
	_last_wake_emission_position = current_position
	_last_wake_emission_position.y = _ocean.sample_height(current_position)


func _emit_physical_ripple(
	emitter: Marker3D,
	fallback_position: Vector3,
	amplitude: float,
	wavelength: float
) -> void:
	var emission_position := (
		emitter.global_position
		if is_instance_valid(emitter)
		else fallback_position
	)
	_ocean.add_ripple(
		emission_position,
		amplitude,
		3.6,
		wavelength,
		0.38,
		3.8
	)


func _apply_marker_configuration() -> void:
	if is_instance_valid(_front_marker):
		_front_marker.position = Vector3(0.0, 0.0, sample_length * 0.5)
	if is_instance_valid(_rear_marker):
		_rear_marker.position = Vector3(0.0, 0.0, -sample_length * 0.5)
	if is_instance_valid(_left_marker):
		_left_marker.position = Vector3(-sample_width * 0.5, 0.0, 0.0)
	if is_instance_valid(_right_marker):
		_right_marker.position = Vector3(sample_width * 0.5, 0.0, 0.0)
	var stern_z := -sample_length * 0.5
	if is_instance_valid(_stern_center):
		_stern_center.position = Vector3(0.0, 0.0, stern_z)
	if is_instance_valid(_stern_left):
		_stern_left.position = Vector3(-wake_width * 0.5, 0.0, stern_z)
	if is_instance_valid(_stern_right):
		_stern_right.position = Vector3(wake_width * 0.5, 0.0, stern_z)


func _apply_collision_configuration() -> void:
	var collision_basis := Basis.from_euler(
		collision_rotation_offset_degrees * PI / 180.0
	).orthonormalized()
	if is_instance_valid(_main_collision):
		_main_collision.disabled = not collision_enabled
		_main_collision.transform = Transform3D(
			collision_basis,
			collision_basis * collision_main_offset
		)
		var main_shape := _main_collision.shape as BoxShape3D
		if main_shape != null:
			main_shape.size = collision_main_size.max(Vector3.ONE * 0.1)
	if is_instance_valid(_bow_collision):
		_bow_collision.disabled = not collision_enabled
		_bow_collision.transform = Transform3D(
			collision_basis,
			collision_basis * collision_bow_offset
		)
		var bow_shape := _bow_collision.shape as BoxShape3D
		if bow_shape != null:
			bow_shape.size = collision_bow_size.max(Vector3.ONE * 0.1)


func _queue_model_rebuild() -> void:
	if not is_inside_tree() or _model_rebuild_queued:
		return
	_model_rebuild_queued = true
	call_deferred(&"_rebuild_model")


func _rebuild_model() -> void:
	_model_rebuild_queued = false
	if not is_instance_valid(_model_container):
		return
	for child in _model_container.get_children():
		_model_container.remove_child(child)
		child.queue_free()
	if model_scene == null:
		return
	var model_instance := model_scene.instantiate()
	model_instance.name = "BoatModel"
	_model_container.add_child(model_instance)
	_prepare_model_tree(model_instance)


func _prepare_model_tree(node: Node) -> void:
	if node is CollisionObject3D:
		var parent := node.get_parent()
		if parent != null:
			parent.remove_child(node)
		node.queue_free()
		return
	if node is MeshInstance3D:
		(node as MeshInstance3D).gi_mode = GeometryInstance3D.GI_MODE_DYNAMIC
	for child in node.get_children():
		_prepare_model_tree(child)


func _apply_model_transform() -> void:
	if not is_instance_valid(_model_pivot):
		return
	_model_pivot.position = model_position_offset
	_model_pivot.rotation_degrees = model_rotation_offset_degrees
	_model_pivot.scale = model_scale.max(Vector3.ONE * 0.001)


func _update_debug_draw() -> void:
	if not is_instance_valid(_debug_mesh_instance) or _debug_mesh == null:
		return
	_debug_mesh_instance.visible = debug_draw
	if not debug_draw:
		if _debug_mesh.get_surface_count() > 0:
			_debug_mesh.clear_surfaces()
		return
	_debug_mesh.clear_surfaces()
	_debug_mesh.surface_begin(Mesh.PRIMITIVE_LINES)
	if _has_valid_water_target:
		_debug_cross(_front_surface_position, Color(0.2, 1.0, 0.3), 0.45)
		_debug_cross(_rear_surface_position, Color(1.0, 0.55, 0.15), 0.45)
		_debug_cross(_left_surface_position, Color(0.25, 0.65, 1.0), 0.45)
		_debug_cross(_right_surface_position, Color(1.0, 0.25, 0.75), 0.45)
		_debug_line(
			global_position,
			Vector3(global_position.x, _target_water_height, global_position.z),
			Color.WHITE
		)
	var flat_forward := global_basis.z
	flat_forward.y = 0.0
	if flat_forward.length_squared() > 0.000001:
		_debug_line(global_position, global_position + flat_forward.normalized() * 6.0, Color.CYAN)
	if is_instance_valid(_stern_left):
		_debug_cross(_stern_left.global_position, Color.MAGENTA, 0.35)
	if is_instance_valid(_stern_right):
		_debug_cross(_stern_right.global_position, Color.MAGENTA, 0.35)
	if not _last_wake_emission_position.is_zero_approx():
		_debug_cross(_last_wake_emission_position, Color.YELLOW, 0.6)
	_debug_mesh.surface_end()


func _debug_cross(world_position: Vector3, color: Color, radius: float) -> void:
	_debug_line(
		world_position - Vector3.RIGHT * radius,
		world_position + Vector3.RIGHT * radius,
		color
	)
	_debug_line(
		world_position - Vector3.UP * radius,
		world_position + Vector3.UP * radius,
		color
	)
	_debug_line(
		world_position - Vector3.BACK * radius,
		world_position + Vector3.BACK * radius,
		color
	)


func _debug_line(start: Vector3, end: Vector3, color: Color) -> void:
	_debug_mesh.surface_set_color(color)
	_debug_mesh.surface_add_vertex(start)
	_debug_mesh.surface_set_color(color)
	_debug_mesh.surface_add_vertex(end)


func _exponential_response(response: float, delta: float) -> float:
	return 1.0 - exp(-maxf(response, 0.0) * maxf(delta, 0.0))


func _update_smoothed_heading(
	target_forward: Vector3,
	delta: float,
	snap: bool
) -> void:
	if snap or not _has_smoothed_heading:
		_smoothed_heading_forward = target_forward
		_has_smoothed_heading = true
		return
	var current_angle := atan2(
		_smoothed_heading_forward.x,
		_smoothed_heading_forward.z
	)
	var target_angle := atan2(target_forward.x, target_forward.z)
	var angle_error := wrapf(target_angle - current_angle, -PI, PI)
	var damped_step := angle_error * _exponential_response(heading_response, delta)
	var maximum_step := deg_to_rad(maximum_yaw_rate_degrees) * maxf(delta, 0.0)
	var next_angle := current_angle + clampf(damped_step, -maximum_step, maximum_step)
	_smoothed_heading_forward = Vector3(
		sin(next_angle),
		0.0,
		cos(next_angle)
	).normalized()
