class_name WakeTrail3D
extends Node3D

class WakeSample:
	var position: Vector3
	var age: float
	var forward_direction: Vector3
	var speed_factor: float
	var horizontal_speed: float
	var initial_width: float
	var steering_bias: float
	var segment_id: int
	var break_before: bool

	func _init(
		initial_position: Vector3,
		initial_forward: Vector3,
		initial_speed_factor: float,
		initial_horizontal_speed: float,
		width: float,
		initial_steering_bias: float,
		initial_segment_id: int,
		initial_break_before: bool
	) -> void:
		position = initial_position
		age = 0.0
		forward_direction = initial_forward
		speed_factor = initial_speed_factor
		horizontal_speed = initial_horizontal_speed
		initial_width = width
		steering_bias = initial_steering_bias
		segment_id = initial_segment_id
		break_before = initial_break_before


var wake_enabled: bool = true
var wake_minimum_speed: float = 3.0
var wake_full_speed: float = 20.0
var wake_minimum_contact: float = 0.15
var wake_lifetime: float = 1.8
var wake_maximum_points: int = 72
var wake_sample_minimum_distance: float = 0.4
var wake_sample_maximum_interval: float = 0.1
## External traffic sources keep laying foam while culled, but store fewer
## history points. The live shader head still interpolates between them.
var offscreen_sample_distance_multiplier: float = 2.0
var offscreen_sample_interval_multiplier: float = 2.0
var wake_surface_offset: float = 0.025
var wake_fade_start_ratio: float = 0.14
var wake_initial_width_multiplier: float = 1.05
var wake_maximum_width_multiplier: float = 2.60
var wake_opening_distance: float = 6.0
var mesh_update_interval: float = 0.05
var directional_history_lifetime: float = 4.2
var wake_strength_multiplier: float = 1.0
var directional_strength_multiplier: float = 1.0
var physics_enabled: bool = false
## The traffic boat uses the cheaper local CPU sampler for navigation, while
## the directional shader remains visual-only to avoid evaluating it twice.
var directional_global_physics_enabled: bool = true
## Only traffic boats opt into the long world-space foam channel. The player
## JetSki keeps the original ripple/interaction foam path.
var directional_persistent_foam_enabled: bool = false
## Allows Ocean3D to keep rendering deposited foam while suppressing the
## displacement packet belonging to an off-screen traffic boat.
var directional_deformation_active: bool = true
## Spatial cap for the expensive ocean displacement. Foam may keep using the
## complete history after the physical wave has faded out.
var directional_deformation_maximum_distance: float = 1.0e20
var directional_deformation_distance_fade_start_ratio: float = 0.75
var visual_fade_duration: float = 0.2
var local_visual_crest_height: float = 0.10
var local_visual_center_depression: float = 0.025
var local_visual_center_turbulence_height: float = 0.0
var local_visual_arm_half_width_multiplier: float = 0.34
var local_physics_height_multiplier: float = 2.4
var local_physics_lifetime: float = 6.5
var local_physics_maximum_distance: float = 1.0e20
## Traffic wakes can use a coarser centerline for buoyancy than the visual
## history. This keeps the physical wave smooth while avoiding dozens of
## redundant closest-segment tests for every JetSki water probe.
var local_physics_segment_stride: int = 1
var history_capture_enabled: bool = true
var visual_enabled: bool = true
## Disables the detached foam ribbon while preserving wake history for ocean
## deformation and ocean-integrated foam.
var ribbon_render_enabled: bool = true:
	set(value):
		ribbon_render_enabled = value
		if is_node_ready() and is_instance_valid(_wake_mesh):
			_wake_mesh.visible = value and visual_enabled
			if not value and _array_mesh.get_surface_count() > 0:
				_array_mesh.clear_surfaces()
var legacy_global_deformation_enabled: bool = true
## Ocean3D ignores inactive sources entirely, including their physical wake.
var directional_source_active: bool = true
## Requested cadence for this source. Ocean3D chooses the fastest active source.
var requested_directional_update_interval: float = 0.05

var sample_count: int:
	get:
		return _samples.size()

var trail_length: float:
	get:
		return _trail_length

var oldest_age: float:
	get:
		return _samples[0].age if not _samples.is_empty() else 0.0

var current_width: float:
	get:
		return _current_width

var rebase_count: int:
	get:
		return _rebase_count

var surface_count: int:
	get:
		return _array_mesh.get_surface_count() if _array_mesh != null else 0

var vertex_count: int:
	get:
		return _vertices.size() if surface_count > 0 else 0

var foam_intensity: float = 0.0
var directional_export_count: int = 0
var directional_export_revision: int = 0
var jump_discontinuity_count: int = 0
var local_physics_query_count: int = 0
var live_head_update_count: int = 0
var mesh_rebuild_count: int = 0

var _vehicle: JetSkiController
var _ocean: Ocean3D
var _propulsion_point: Marker3D
var _front_left: Marker3D
var _front_right: Marker3D
var _rear_left: Marker3D
var _rear_right: Marker3D
var _samples: Array[WakeSample] = []
var _sample_elapsed: float = 0.0
var _has_last_sample: bool = false
var _last_sample_position: Vector3 = Vector3.ZERO
var _suppress_sampling_ticks: int = 0
var _current_segment_id: int = 0
var _segment_break_pending: bool = true
var _was_generating_wake: bool = false
var _trail_length: float = 0.0
var _current_width: float = 0.0
var _rebase_count: int = 0
var _mesh_update_elapsed: float = 0.0
var _mesh_dirty: bool = true
var _array_mesh := ArrayMesh.new()
var _vertices := PackedVector3Array()
var _normals := PackedVector3Array()
var _colors := PackedColorArray()
var _uvs := PackedVector2Array()
var _uv2s := PackedVector2Array()
var _indices := PackedInt32Array()
var _mesh_arrays: Array = []
var _foam_settings: WaterFoamSettings
var _foam_noise_texture: Texture2D
var _foam_settings_signature: int = -1
var _normal_material: ShaderMaterial
var _external_source_enabled: bool = false
var _external_source_generating: bool = false
var _external_visibility_active: bool = true
var _external_horizontal_speed: float = 0.0
var _external_forward_direction: Vector3 = Vector3.FORWARD
var _physics_bounds := Rect2()
var _physics_bounds_dirty: bool = true
var _physics_first_recent_sample_index: int = 0
var _local_wake_candidate_start := PackedVector2Array()
var _local_wake_candidate_segment := PackedVector2Array()
var _local_wake_candidate_length_squared := PackedFloat64Array()
var _local_wake_candidate_older_index := PackedInt32Array()
var _local_wake_candidate_newer_index := PackedInt32Array()
var _local_wake_cache_built: bool = false
var _local_wake_cache_dirty: bool = true
var _local_wake_cache_sample_count: int = 0
var _local_wake_cache_stride: int = 1
var _local_wake_cache_lifetime: float = 0.1
var _local_wake_cache_first_recent: int = 0
var _runtime_physics_active: bool = true
var _base_surface_sample_scratch := WaterSample3D.new()
var _mesh_head_anchor_position: Vector3 = Vector3.ZERO
var _visual_fade: float = 1.0

@onready var _wake_mesh: MeshInstance3D = $WakeMesh


func _ready() -> void:
	process_physics_priority = 10
	_mesh_arrays.resize(Mesh.ARRAY_MAX)
	_wake_mesh.mesh = _array_mesh
	_wake_mesh.visible = ribbon_render_enabled
	var source_material := _wake_mesh.material_override as ShaderMaterial
	if source_material != null:
		_normal_material = source_material.duplicate() as ShaderMaterial
		_wake_mesh.material_override = _normal_material


func _exit_tree() -> void:
	_unregister_ocean_material()
	_disconnect_vehicle_signals()


func configure(
	vehicle: JetSkiController,
	ocean: Ocean3D,
	propulsion_point: Marker3D,
	rear_left: Marker3D = null,
	rear_right: Marker3D = null,
	front_left: Marker3D = null,
	front_right: Marker3D = null
) -> void:
	_unregister_ocean_material()
	_disconnect_vehicle_signals()
	_external_source_enabled = false
	_external_source_generating = false
	_external_visibility_active = true
	visual_enabled = true
	_runtime_physics_active = true
	directional_global_physics_enabled = true
	directional_persistent_foam_enabled = false
	directional_deformation_active = true
	directional_source_active = true
	_vehicle = vehicle
	_ocean = ocean
	_propulsion_point = propulsion_point
	_rear_left = rear_left
	_rear_right = rear_right
	_front_left = front_left
	_front_right = front_right
	_connect_vehicle_signals()
	if is_instance_valid(_ocean):
		_ocean.configure_vehicle_interaction_source(
			self,
			_vehicle,
			_front_left,
			_front_right,
			_rear_left,
			_rear_right,
			_propulsion_point
		)


## Configures the existing trail for a deterministic external mover. Local
## history, visual ribbon, and simplified physics remain independent from the
## optional legacy directional export.
func configure_external_source(
	ocean: Ocean3D,
	propulsion_point: Marker3D,
	rear_left: Marker3D = null,
	rear_right: Marker3D = null
) -> void:
	_unregister_ocean_material()
	_disconnect_vehicle_signals()
	_vehicle = null
	_ocean = ocean
	_propulsion_point = propulsion_point
	_rear_left = rear_left
	_rear_right = rear_right
	_front_left = null
	_front_right = null
	_external_source_enabled = true
	_external_source_generating = false
	_external_visibility_active = true
	visual_enabled = true
	_runtime_physics_active = true
	directional_global_physics_enabled = false
	directional_deformation_active = true
	directional_source_active = legacy_global_deformation_enabled
	if is_instance_valid(_ocean):
		_ocean.register_additional_directional_wake_source(self)
		_ocean.register_local_wake_physics_source(self)


func update_external_source(
	horizontal_speed: float,
	forward_direction: Vector3,
	generating: bool
) -> void:
	if not _external_source_enabled:
		return
	_external_horizontal_speed = maxf(horizontal_speed, 0.0)
	var flat_forward := Vector3(
		forward_direction.x,
		0.0,
		forward_direction.z
	)
	if flat_forward.is_finite() and flat_forward.length_squared() > 0.000001:
		_external_forward_direction = flat_forward.normalized()
	_external_source_generating = generating


## Suspends rendering and physical influence without discarding deposited
## foam. Sparse world-space capture continues, while Ocean3D exports the
## source with zero deformation weight.
func set_external_visibility_active(active: bool) -> void:
	if not _external_source_enabled:
		return
	var was_active := _external_visibility_active
	_external_visibility_active = active
	visual_enabled = active
	_runtime_physics_active = active
	directional_deformation_active = active and legacy_global_deformation_enabled
	directional_source_active = legacy_global_deformation_enabled
	if is_instance_valid(_wake_mesh):
		_wake_mesh.visible = active and ribbon_render_enabled
	if active:
		requested_directional_update_interval = 1.0 / 60.0
		_mesh_dirty = true
		_mesh_update_elapsed = mesh_update_interval
		if not was_active:
			_visual_fade = 0.0
	else:
		requested_directional_update_interval = 0.1
	if is_instance_valid(_ocean):
		_ocean.request_directional_wake_refresh()


func configure_quality(
	maximum_points: int,
	update_interval: float,
	sample_distance: float,
	lifetime: float = wake_lifetime
) -> void:
	wake_maximum_points = maxi(maximum_points, 8)
	mesh_update_interval = clampf(update_interval, 0.01, 0.25)
	wake_sample_minimum_distance = clampf(sample_distance, 0.1, 2.0)
	wake_lifetime = maxf(lifetime, 0.1)
	while _samples.size() > wake_maximum_points:
		_samples.pop_front()
	_mesh_dirty = true
	_physics_bounds_dirty = true
	_local_wake_cache_dirty = true


func get_graphics_quality_debug_status() -> Dictionary:
	return {
		"maximum_points": wake_maximum_points,
		"sample_count": sample_count,
		"mesh_update_interval": mesh_update_interval,
		"sample_distance": wake_sample_minimum_distance,
		"lifetime": wake_lifetime,
		"vertex_count": vertex_count,
		"history_capture_enabled": history_capture_enabled,
		"visual_enabled": visual_enabled,
		"physics_enabled": physics_enabled,
		"legacy_global_deformation_enabled": legacy_global_deformation_enabled,
		"local_physics_active": is_local_wake_physics_active(),
		"local_physics_query_count": local_physics_query_count,
		"live_head_update_count": live_head_update_count,
		"mesh_rebuild_count": mesh_rebuild_count,
		"visual_fade": _visual_fade,
	}


func configure_foam(settings: WaterFoamSettings, noise_texture: Texture2D) -> void:
	_foam_settings = settings
	_foam_noise_texture = noise_texture
	_foam_settings_signature = -1
	_update_foam_material(true)


func _physics_process(delta: float) -> void:
	if delta <= 0.0:
		return
	_update_foam_intensity(delta)
	_age_samples(delta)
	_sample_elapsed += delta
	_mesh_update_elapsed += delta
	_update_segment_continuity()
	if _suppress_sampling_ticks > 0:
		_suppress_sampling_ticks -= 1
	else:
		_try_add_sample()
	if _samples.is_empty():
		if _array_mesh.get_surface_count() > 0:
			_array_mesh.clear_surfaces()
	elif visual_enabled and ribbon_render_enabled and (
		_mesh_dirty or _mesh_update_elapsed >= mesh_update_interval
	):
		_rebuild_mesh()
		_mesh_dirty = false
		_mesh_update_elapsed = 0.0
	elif not ribbon_render_enabled and _array_mesh.get_surface_count() > 0:
		_array_mesh.clear_surfaces()
	if visual_enabled and ribbon_render_enabled:
		# Rebuilds can change the head anchor. Update this afterwards so the
		# newest section never receives one frame of stale extrapolation.
		_update_live_visual_state(delta)
		_update_foam_material(false)


func clear_trail(suppress_next_tick: bool = true) -> void:
	_samples.clear()
	_sample_elapsed = 0.0
	_has_last_sample = false
	_last_sample_position = Vector3.ZERO
	_current_segment_id = 0
	_segment_break_pending = true
	_was_generating_wake = false
	jump_discontinuity_count = 0
	_trail_length = 0.0
	_current_width = 0.0
	_suppress_sampling_ticks = 1 if suppress_next_tick else 0
	_mesh_dirty = true
	_mesh_update_elapsed = 0.0
	_array_mesh.clear_surfaces()
	foam_intensity = 0.0
	_physics_bounds = Rect2()
	_physics_bounds_dirty = true
	_physics_first_recent_sample_index = 0
	_local_wake_candidate_start.clear()
	_local_wake_candidate_segment.clear()
	_local_wake_candidate_length_squared.clear()
	_local_wake_candidate_older_index.clear()
	_local_wake_candidate_newer_index.clear()
	_local_wake_cache_dirty = true


func apply_world_rebase(shift: Vector3) -> void:
	var horizontal_shift := Vector3(shift.x, 0.0, shift.z)
	if horizontal_shift.is_zero_approx() or not horizontal_shift.is_finite():
		return
	for sample in _samples:
		sample.position -= horizontal_shift
	if _has_last_sample:
		_last_sample_position -= horizontal_shift
	_rebase_count += 1
	_physics_bounds_dirty = true
	_local_wake_cache_dirty = true
	_rebuild_mesh()
	_mesh_dirty = false
	_mesh_update_elapsed = 0.0


func get_sample_positions() -> PackedVector3Array:
	var positions := PackedVector3Array()
	positions.resize(_samples.size())
	for index in _samples.size():
		positions[index] = _samples[index].position
	return positions


func is_local_wake_physics_active() -> bool:
	return (
		_external_source_enabled
		and physics_enabled
		and _runtime_physics_active
		and wake_enabled
		and _samples.size() >= 2
	)


## Navigable traffic wake with cheap candidate selection and one compact
## transverse profile. It intentionally does not reproduce the visual shader.
func sample_simplified_wake_height(world_position: Vector3) -> float:
	local_physics_query_count += 1
	if not is_local_wake_physics_active() or not is_instance_valid(_ocean):
		return 0.0
	_ensure_physics_bounds()
	var query := Vector2(world_position.x, world_position.z)
	if not _physics_bounds.has_point(query):
		return 0.0
	var best_index: int = -1
	var best_ratio: float = 0.0
	var best_distance_squared: float = INF
	if not _local_wake_candidate_cache_valid():
		_rebuild_local_wake_candidate_cache()
	for candidate_index in _local_wake_candidate_start.size():
		var start := _local_wake_candidate_start[candidate_index]
		var segment := _local_wake_candidate_segment[candidate_index]
		var segment_length_squared := _local_wake_candidate_length_squared[candidate_index]
		var ratio := clampf(
			(query - start).dot(segment) / segment_length_squared,
			0.0,
			1.0
		)
		var distance_squared := query.distance_squared_to(start + segment * ratio)
		if distance_squared < best_distance_squared:
			best_distance_squared = distance_squared
			best_index = candidate_index
			best_ratio = ratio
	if best_index < 0:
		return 0.0
	var lifetime := maxf(minf(wake_lifetime, local_physics_lifetime), 0.1)
	var selected_older := _samples[_local_wake_candidate_older_index[best_index]]
	var selected_newer := _samples[_local_wake_candidate_newer_index[best_index]]
	var age := lerpf(selected_older.age, selected_newer.age, best_ratio)
	if age < 0.12 or age >= lifetime:
		return 0.0
	var initial_width := lerpf(
		selected_older.initial_width,
		selected_newer.initial_width,
		best_ratio
	)
	var source_speed := lerpf(
		selected_older.horizontal_speed,
		selected_newer.horizontal_speed,
		best_ratio
	)
	var intensity := clampf(
		lerpf(selected_older.speed_factor, selected_newer.speed_factor, best_ratio)
			* directional_strength_multiplier,
		0.0,
		2.0
	)
	var front_distance := initial_width + age * (
		_ocean.directional_wake_propagation_speed
			+ source_speed * _ocean.directional_wake_opening_slope
	)
	var lateral_distance := sqrt(best_distance_squared)
	var crest_width := maxf(_ocean.directional_wake_arm_width * 1.8, 0.65)
	if lateral_distance > front_distance + crest_width:
		return 0.0
	var crest := 1.0 - smoothstep(
		0.0,
		crest_width,
		absf(lateral_distance - front_distance)
	)
	var center_width := maxf(initial_width * 0.78, 0.45)
	var center_depression := 1.0 - smoothstep(
		center_width * 0.30,
		center_width,
		lateral_distance
	)
	var age_fade := 1.0 - smoothstep(lifetime * 0.58, lifetime, age)
	var height := (
		(
			_ocean.directional_wake_amplitude * crest
				- _ocean.directional_wake_center_depression * center_depression
		)
		* intensity
		* age_fade
		* _ocean.directional_wake_physics_response
		* local_physics_height_multiplier
	)
	return clampf(
		height,
		-_ocean.vehicle_interaction_maximum_displacement,
		_ocean.vehicle_interaction_maximum_displacement
	)


func _ensure_physics_bounds() -> void:
	if not _physics_bounds_dirty:
		return
	_physics_bounds_dirty = false
	if _samples.is_empty():
		_physics_bounds = Rect2()
		return
	var minimum := Vector2(INF, INF)
	var maximum := Vector2(-INF, -INF)
	var maximum_reach := 1.0
	var physics_lifetime := maxf(
		minf(wake_lifetime, local_physics_lifetime),
		0.1
	)
	var newest_index := _samples.size() - 1
	if newest_index < 0 or _samples[newest_index].age > physics_lifetime:
		_physics_bounds = Rect2()
		_physics_first_recent_sample_index = _samples.size()
		return
	_physics_first_recent_sample_index = newest_index
	var covered_distance := 0.0
	var maximum_distance := maxf(local_physics_maximum_distance, 0.1)
	for index in range(newest_index - 1, -1, -1):
		var older := _samples[index]
		var newer := _samples[index + 1]
		if older.age > physics_lifetime:
			break
		if newer.break_before or newer.segment_id != older.segment_id:
			break
		var pair_distance := Vector2(
			newer.position.x - older.position.x,
			newer.position.z - older.position.z
		).length()
		if covered_distance + pair_distance > maximum_distance:
			break
		covered_distance += pair_distance
		_physics_first_recent_sample_index = index
	if _physics_first_recent_sample_index >= _samples.size():
		_physics_bounds = Rect2()
		return
	var has_recent_sample := false
	for index in range(_physics_first_recent_sample_index, _samples.size()):
		var sample := _samples[index]
		if sample.age > physics_lifetime:
			continue
		has_recent_sample = true
		var horizontal := Vector2(sample.position.x, sample.position.z)
		minimum = minimum.min(horizontal)
		maximum = maximum.max(horizontal)
		maximum_reach = maxf(
			maximum_reach,
			sample.initial_width + minf(sample.age, physics_lifetime) * (
				_ocean.directional_wake_propagation_speed
					+ sample.horizontal_speed * _ocean.directional_wake_opening_slope
			) + _ocean.directional_wake_arm_width * 2.0
		)
	if not has_recent_sample:
		_physics_bounds = Rect2()
		return
	var expansion := Vector2(maximum_reach, maximum_reach)
	_physics_bounds = Rect2(
		minimum - expansion,
		maximum - minimum + expansion * 2.0
	)


func _local_wake_candidate_cache_valid() -> bool:
	if not _local_wake_cache_built:
		return false
	if _local_wake_cache_dirty:
		return false
	if _local_wake_cache_sample_count != _samples.size():
		return false
	if _local_wake_cache_stride != maxi(local_physics_segment_stride, 1):
		return false
	if _local_wake_cache_lifetime != maxf(minf(wake_lifetime, local_physics_lifetime), 0.1):
		return false
	if _local_wake_cache_first_recent != _physics_first_recent_sample_index:
		return false
	return true


func _rebuild_local_wake_candidate_cache() -> void:
	var lifetime := maxf(minf(wake_lifetime, local_physics_lifetime), 0.1)
	var stride := maxi(local_physics_segment_stride, 1)
	var size := _samples.size()
	var first_recent := clampi(_physics_first_recent_sample_index, 0, maxi(size - 1, 0))
	_local_wake_candidate_start.clear()
	_local_wake_candidate_segment.clear()
	_local_wake_candidate_length_squared.clear()
	_local_wake_candidate_older_index.clear()
	_local_wake_candidate_newer_index.clear()
	var index := first_recent
	while index < size - 1:
		var newer_index := mini(index + stride, size - 1)
		var candidate_older := _samples[index]
		var candidate_newer := _samples[newer_index]
		if candidate_older.age > lifetime and candidate_newer.age > lifetime:
			index = newer_index
			continue
		if (
			candidate_newer.break_before
			or candidate_newer.segment_id != candidate_older.segment_id
		):
			index = newer_index
			continue
		var start := Vector2(candidate_older.position.x, candidate_older.position.z)
		var finish := Vector2(candidate_newer.position.x, candidate_newer.position.z)
		var segment := finish - start
		var segment_length_squared := segment.length_squared()
		if segment_length_squared <= 0.0001:
			index = newer_index
			continue
		_local_wake_candidate_start.append(start)
		_local_wake_candidate_segment.append(segment)
		_local_wake_candidate_length_squared.append(segment_length_squared)
		_local_wake_candidate_older_index.append(index)
		_local_wake_candidate_newer_index.append(newer_index)
		index = newer_index
	_local_wake_cache_built = true
	_local_wake_cache_dirty = false
	_local_wake_cache_sample_count = size
	_local_wake_cache_stride = stride
	_local_wake_cache_lifetime = lifetime
	_local_wake_cache_first_recent = first_recent


func fill_directional_shader_segments(
	start_positions: PackedVector2Array,
	end_positions: PackedVector2Array,
	start_times: PackedFloat32Array,
	end_times: PackedFloat32Array,
	intensities: PackedFloat32Array,
	widths: PackedFloat32Array,
	biases: PackedFloat32Array,
	speeds: PackedFloat32Array,
	maximum_segments: int,
	maximum_distance: float,
	maximum_age: float,
	logical_origin_xz: Vector2,
	simulation_time: float
) -> int:
	var buffer_size := mini(
		start_positions.size(),
		mini(
			end_positions.size(),
			mini(
				start_times.size(),
				mini(
					end_times.size(),
					mini(
						intensities.size(),
						mini(widths.size(), mini(biases.size(), speeds.size()))
					)
				)
			)
		)
	)
	var allowed_segments := clampi(maximum_segments, 0, buffer_size)
	var export_count: int = 0
	var newest_index := _samples.size() - 1
	var first_index := newest_index
	var covered_distance: float = 0.0
	# Keep the stored history distance-bounded while its leading segment follows
	# the propulsion point every frame. Without this live head, the wake endpoint
	# advances only whenever a persistent sample is added and visibly steps.
	if (
		allowed_segments > 0
		and newest_index >= 0
		and not _segment_break_pending
		and _can_add_sample()
	):
		var newest_sample := _samples[newest_index]
		var live_position := _propulsion_point.global_position
		var live_start := Vector2(
			newest_sample.position.x,
			newest_sample.position.z
		)
		var live_end := Vector2(live_position.x, live_position.z)
		var live_distance := live_start.distance_to(live_end)
		if live_distance > 0.0001 and live_distance <= maximum_distance:
			var live_speed := _water_relative_horizontal_speed()
			var live_speed_factor := clampf(
				inverse_lerp(wake_minimum_speed, wake_full_speed, live_speed)
					* wake_strength_multiplier,
				0.0,
				1.0
			)
			var live_forward := _real_movement_direction(live_position)
			start_positions[0] = live_start + logical_origin_xz
			end_positions[0] = live_end + logical_origin_xz
			start_times[0] = simulation_time - maxf(newest_sample.age, 0.0)
			end_times[0] = simulation_time
			intensities[0] = clampf(
				(newest_sample.speed_factor + live_speed_factor) * 0.5
					* directional_strength_multiplier,
				0.0,
				2.0
			)
			widths[0] = maxf(
				(newest_sample.initial_width + _measured_hull_half_width()) * 0.5,
				0.1
			)
			biases[0] = clampf(
				(newest_sample.steering_bias + _current_steering_bias(live_forward))
					* 0.5,
				-1.0,
				1.0
			)
			speeds[0] = maxf(
				(newest_sample.horizontal_speed + live_speed) * 0.5,
				0.0
			)
			export_count = 1
			covered_distance = live_distance
	if allowed_segments > export_count and newest_index > 0:
		for index in range(newest_index - 1, -1, -1):
			var newer := _samples[index + 1]
			var older := _samples[index]
			if older.age > maximum_age:
				break
			if newer.break_before or newer.segment_id != older.segment_id:
				first_index = index
				continue
			var pair_distance := Vector2(
				newer.position.x - older.position.x,
				newer.position.z - older.position.z
			).length()
			if covered_distance + pair_distance > maximum_distance:
				break
			covered_distance += pair_distance
			first_index = index
		var valid_pair_count: int = 0
		for pair_index in range(newest_index, first_index, -1):
			var newer := _samples[pair_index]
			var older := _samples[pair_index - 1]
			if not newer.break_before and newer.segment_id == older.segment_id:
				valid_pair_count += 1
		var historical_budget := maxi(allowed_segments - export_count, 1)
		var pair_stride := maxi(
			ceili(float(valid_pair_count) / float(historical_budget)),
			1
		)
		var newer_index := newest_index
		while newer_index > first_index and export_count < allowed_segments:
			var immediate_newer := _samples[newer_index]
			var immediate_older := _samples[newer_index - 1]
			if (
				immediate_newer.break_before
				or immediate_newer.segment_id != immediate_older.segment_id
			):
				newer_index -= 1
				continue
			var group_newer_index := newer_index
			var group_older_index := newer_index - 1
			var grouped_pair_count := 1
			while (
				grouped_pair_count < pair_stride
				and group_older_index > first_index
			):
				var candidate_newer := _samples[group_older_index]
				var candidate_older := _samples[group_older_index - 1]
				if (
					candidate_newer.break_before
					or candidate_newer.segment_id != candidate_older.segment_id
				):
					break
				group_older_index -= 1
				grouped_pair_count += 1
			var newer := _samples[group_newer_index]
			var older := _samples[group_older_index]
			if not newer.position.is_finite() or not older.position.is_finite():
				newer_index = group_older_index
				continue
			var horizontal_start := Vector2(older.position.x, older.position.z)
			var horizontal_end := Vector2(newer.position.x, newer.position.z)
			if horizontal_start.distance_squared_to(horizontal_end) <= 0.000001:
				newer_index = group_older_index
				continue
			start_positions[export_count] = horizontal_start + logical_origin_xz
			end_positions[export_count] = horizontal_end + logical_origin_xz
			start_times[export_count] = simulation_time - maxf(older.age, 0.0)
			end_times[export_count] = simulation_time - maxf(newer.age, 0.0)
			intensities[export_count] = clampf(
				(older.speed_factor + newer.speed_factor) * 0.5
					* directional_strength_multiplier,
				0.0,
				2.0
			)
			widths[export_count] = maxf(
				(older.initial_width + newer.initial_width) * 0.5,
				0.1
			)
			biases[export_count] = clampf(
				(older.steering_bias + newer.steering_bias) * 0.5,
				-1.0,
				1.0
			)
			speeds[export_count] = maxf(
				(older.horizontal_speed + newer.horizontal_speed) * 0.5,
				0.0
			)
			export_count += 1
			newer_index = group_older_index
	for output_index in range(export_count, buffer_size):
		start_positions[output_index] = Vector2.ZERO
		end_positions[output_index] = Vector2.ZERO
		start_times[output_index] = -INF
		end_times[output_index] = -INF
		intensities[output_index] = 0.0
		widths[output_index] = 0.0
		biases[output_index] = 0.0
		speeds[output_index] = 0.0
	directional_export_count = export_count
	directional_export_revision += 1
	return export_count


func _age_samples(delta: float) -> void:
	for sample in _samples:
		sample.age += delta
	# Recent physics samples are a shorter moving window than the retained
	# visual/foam history. Rebuild its bounds and first index once this tick,
	# then all water probes reuse the result.
	if physics_enabled and _external_source_enabled:
		_physics_bounds_dirty = true
		_local_wake_cache_dirty = true
	var retention_lifetime := wake_lifetime
	if legacy_global_deformation_enabled:
		retention_lifetime = maxf(wake_lifetime, directional_history_lifetime)
	while not _samples.is_empty() and _samples[0].age >= retention_lifetime:
		_samples.pop_front()
		_mesh_dirty = true
		_physics_bounds_dirty = true
		_local_wake_cache_dirty = true


func _try_add_sample() -> void:
	if not _can_add_sample():
		return
	var sample_position := _propulsion_point.global_position
	var distance_from_last: float = (
		sample_position.distance_to(_last_sample_position) if _has_last_sample else INF
	)
	var effective_sample_distance := wake_sample_minimum_distance
	var effective_sample_interval := wake_sample_maximum_interval
	if _external_source_enabled and not _external_visibility_active:
		effective_sample_distance *= maxf(offscreen_sample_distance_multiplier, 1.0)
		effective_sample_interval *= maxf(offscreen_sample_interval_multiplier, 1.0)
	if (
		_has_last_sample
		and distance_from_last < effective_sample_distance
		and _sample_elapsed < effective_sample_interval
	):
		return
	var forward := _real_movement_direction(sample_position)
	var horizontal_speed := _water_relative_horizontal_speed()
	var speed_factor := clampf(
		inverse_lerp(
			wake_minimum_speed,
			wake_full_speed,
			horizontal_speed
		),
		0.0,
		1.0
	)
	speed_factor = clampf(speed_factor * wake_strength_multiplier, 0.0, 1.0)
	var measured_half_width := _measured_hull_half_width()
	var initial_width := measured_half_width * wake_initial_width_multiplier
	initial_width *= lerpf(0.94, 1.08, speed_factor)
	var steering_bias := _current_steering_bias(forward)
	_samples.append(WakeSample.new(
		sample_position,
		forward,
		speed_factor,
		horizontal_speed,
		initial_width,
		steering_bias,
		_current_segment_id,
		_segment_break_pending
	))
	_physics_bounds_dirty = true
	_local_wake_cache_dirty = true
	_segment_break_pending = false
	_was_generating_wake = true
	_mesh_dirty = true
	while _samples.size() > maxi(wake_maximum_points, 2):
		_samples.pop_front()
	_last_sample_position = sample_position
	_has_last_sample = true
	_sample_elapsed = 0.0


func _can_add_sample() -> bool:
	if _external_source_enabled:
		return (
			wake_enabled
			and history_capture_enabled
			and _external_source_generating
			and is_instance_valid(_ocean)
			and is_instance_valid(_propulsion_point)
			and _external_horizontal_speed > wake_minimum_speed
		)
	return (
		wake_enabled
		and is_instance_valid(_vehicle)
		and is_instance_valid(_ocean)
		and is_instance_valid(_propulsion_point)
		and _vehicle.navigation_state != JetSkiController.NavigationState.AIRBORNE
		and _vehicle.rear_submerged_ratio > 0.0
		and _vehicle.propulsion_contact_factor > wake_minimum_contact
		and _water_relative_horizontal_speed() > wake_minimum_speed
	)


func mark_segment_break() -> void:
	if _segment_break_pending:
		return
	_current_segment_id += 1
	_segment_break_pending = true
	_has_last_sample = false
	_sample_elapsed = wake_sample_maximum_interval
	jump_discontinuity_count += 1
	_mesh_dirty = true


func _update_segment_continuity() -> void:
	if _external_source_enabled:
		var external_generating := (
			wake_enabled
			and history_capture_enabled
			and _external_source_generating
			and is_instance_valid(_ocean)
			and is_instance_valid(_propulsion_point)
			and _external_horizontal_speed > wake_minimum_speed
		)
		if _was_generating_wake and not external_generating:
			mark_segment_break()
		_was_generating_wake = external_generating
		return
	var generating_wake := (
		is_instance_valid(_vehicle)
		and _vehicle.navigation_state
			!= JetSkiController.NavigationState.AIRBORNE
		and _vehicle.rear_submerged_ratio > 0.0
		and _vehicle.propulsion_contact_factor > wake_minimum_contact
	)
	if _was_generating_wake and not generating_wake:
		mark_segment_break()
	_was_generating_wake = generating_wake


func _connect_vehicle_signals() -> void:
	if not is_instance_valid(_vehicle):
		return
	if not _vehicle.water_exited.is_connected(_on_vehicle_water_exited):
		_vehicle.water_exited.connect(_on_vehicle_water_exited)


func _disconnect_vehicle_signals() -> void:
	if (
		is_instance_valid(_vehicle)
		and _vehicle.water_exited.is_connected(_on_vehicle_water_exited)
	):
		_vehicle.water_exited.disconnect(_on_vehicle_water_exited)


func _unregister_ocean_material() -> void:
	if not is_instance_valid(_ocean):
		return
	if _external_source_enabled:
		_ocean.unregister_additional_directional_wake_source(self)
		_ocean.unregister_local_wake_physics_source(self)


func _on_vehicle_water_exited() -> void:
	mark_segment_break()


func _rebuild_mesh() -> void:
	mesh_rebuild_count += 1
	_array_mesh.clear_surfaces()
	_trail_length = 0.0
	_current_width = 0.0
	if _samples.size() < 2 or not is_instance_valid(_ocean):
		return
	_vertices.clear()
	_normals.clear()
	_colors.clear()
	_uvs.clear()
	_uv2s.clear()
	_indices.clear()
	var cumulative_length: float = 0.0
	for index in _samples.size():
		var sample := _samples[index]
		var connected_to_previous := (
			index > 0
			and not sample.break_before
			and sample.segment_id == _samples[index - 1].segment_id
		)
		if connected_to_previous:
			cumulative_length += Vector2(
				sample.position.x - _samples[index - 1].position.x,
				sample.position.z - _samples[index - 1].position.z
			).length()
		var base_surface := _ocean.sample_base_surface(
			sample.position,
			_base_surface_sample_scratch
		)
		if not base_surface.valid:
			continue
		var surface_position := base_surface.surface_position + (
			base_surface.normal * wake_surface_offset
		)
		var water_normal := base_surface.normal
		var tangent := _sample_tangent(index)
		var right := tangent.cross(water_normal)
		if right.length_squared() <= 0.000001:
			right = Vector3.RIGHT
		else:
			right = right.normalized()
		var lifetime_ratio := clampf(
			sample.age / maxf(wake_lifetime, 0.001),
			0.0,
			1.0
		)
		var age_ratio := lifetime_ratio
		var released_front := sample.initial_width + sample.age * (
			_ocean.directional_wake_propagation_speed
			+ sample.horizontal_speed * _ocean.directional_wake_opening_slope
		)
		var rail_half_width := clampf(
			_ocean.directional_wake_arm_width * local_visual_arm_half_width_multiplier,
			0.16,
			1.2
		)
		released_front = maxf(
			released_front,
			sample.initial_width + rail_half_width
		)
		var central_half_width := maxf(sample.initial_width * 0.68, 0.24)
		_current_width = maxf(
			_current_width,
			(released_front + rail_half_width) * 2.0
		)
		var fade := 1.0 - smoothstep(
			wake_fade_start_ratio,
			1.0,
			age_ratio
		)
		var alpha := fade * lerpf(0.012, 0.075, sample.speed_factor)
		var steering_bias := sample.steering_bias
		var left_color := Color(
			age_ratio,
			sample.speed_factor,
			0.5 + steering_bias * 0.5,
			alpha * 0.68 * (1.0 + steering_bias * 0.22)
		)
		var center_color := Color(
			age_ratio,
			sample.speed_factor,
			0.5 + steering_bias * 0.5,
			alpha * 0.42
		)
		var right_color := Color(
			age_ratio,
			sample.speed_factor,
			0.5 + steering_bias * 0.5,
			alpha * 0.68 * (1.0 - steering_bias * 0.22)
		)
		var head_weight := 1.0 if index == _samples.size() - 1 else 0.0
		var local_height_scale := (
			(1.0 - smoothstep(0.52, 1.0, age_ratio))
			* lerpf(0.45, 1.0, clampf(sample.speed_factor, 0.0, 1.0))
		)
		for lane_index in 10:
			var lateral_offset := 0.0
			match lane_index:
				0: lateral_offset = -released_front - rail_half_width
				1: lateral_offset = -released_front
				2: lateral_offset = -released_front + rail_half_width
				3: lateral_offset = -central_half_width
				4: lateral_offset = -central_half_width * 0.25
				5: lateral_offset = central_half_width * 0.25
				6: lateral_offset = central_half_width
				7: lateral_offset = released_front - rail_half_width
				8: lateral_offset = released_front
				9: lateral_offset = released_front + rail_half_width
			var strip_id := -1.0 if lane_index < 3 else 0.0 if lane_index < 7 else 1.0
			var strip_uv := (
				float(lane_index) * 0.5
				if lane_index < 3
				else float(lane_index - 3) / 3.0
				if lane_index < 7
				else float(lane_index - 7) * 0.5
			)
			var vertex_color := (
				left_color if lane_index < 3
				else center_color if lane_index < 7
				else right_color
			)
			var signed_amplitude := (
				local_visual_crest_height
				if absf(strip_id) > 0.5
				else -local_visual_center_depression + (
					local_visual_center_turbulence_height
					* (
						0.5 + 0.5 * sin(
							cumulative_length * 1.8
							- _ocean.get_simulation_time() * 4.2
						)
					)
				)
			)
			var profile_derivative := 0.0
			if not is_equal_approx(strip_uv, 0.5):
				profile_derivative = 1.0 if strip_uv < 0.5 else -1.0
				profile_derivative /= (
					rail_half_width
					if absf(strip_id) > 0.5
					else central_half_width
				)
			var local_slope := signed_amplitude * local_height_scale * profile_derivative
			var wake_normal := (water_normal - right * local_slope).normalized()
			_append_wake_vertex(
				surface_position + right * lateral_offset,
				wake_normal,
				vertex_color,
				Vector2(strip_uv, cumulative_length),
				Vector2(strip_id, head_weight)
			)
		if connected_to_previous:
			var previous_base := (index - 1) * 10
			var current_base := index * 10
			for strip_index in 3:
				var strip_start := 0 if strip_index == 0 else 3 if strip_index == 1 else 7
				var strip_vertex_count := 4 if strip_index == 1 else 3
				for lane_offset in range(strip_vertex_count - 1):
					_append_strip_indices(
						previous_base + strip_start + lane_offset,
						previous_base + strip_start + lane_offset + 1,
						current_base + strip_start + lane_offset,
						current_base + strip_start + lane_offset + 1
					)
	_trail_length = cumulative_length
	_mesh_head_anchor_position = _samples[-1].position
	if _indices.is_empty():
		return
	_mesh_arrays.fill(null)
	_mesh_arrays[Mesh.ARRAY_VERTEX] = _vertices
	_mesh_arrays[Mesh.ARRAY_NORMAL] = _normals
	_mesh_arrays[Mesh.ARRAY_COLOR] = _colors
	_mesh_arrays[Mesh.ARRAY_TEX_UV] = _uvs
	_mesh_arrays[Mesh.ARRAY_TEX_UV2] = _uv2s
	_mesh_arrays[Mesh.ARRAY_INDEX] = _indices
	_array_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, _mesh_arrays)
	var visual_bounds := _array_mesh.get_aabb().grow(
		maxf(local_visual_crest_height, local_visual_center_depression) + 1.0
	)
	_wake_mesh.custom_aabb = visual_bounds


func _sample_tangent(index: int) -> Vector3:
	var tangent := Vector3.ZERO
	var has_previous := (
		index > 0
		and not _samples[index].break_before
		and _samples[index].segment_id == _samples[index - 1].segment_id
	)
	var has_next := (
		index + 1 < _samples.size()
		and not _samples[index + 1].break_before
		and _samples[index].segment_id == _samples[index + 1].segment_id
	)
	if has_previous and has_next:
		tangent = _samples[index + 1].position - _samples[index - 1].position
	elif has_next:
		tangent = _samples[index + 1].position - _samples[index].position
	elif has_previous:
		tangent = _samples[index].position - _samples[index - 1].position
	tangent.y = 0.0
	if tangent.length_squared() <= 0.000001:
		tangent = _samples[index].forward_direction
	return tangent.normalized()


func _append_wake_vertex(
	vertex_position: Vector3,
	normal: Vector3,
	color: Color,
	uv: Vector2,
	uv2: Vector2
) -> void:
	_vertices.append(vertex_position)
	_normals.append(normal)
	_colors.append(color)
	_uvs.append(uv)
	_uv2s.append(uv2)


func _append_strip_indices(
	previous_left: int,
	previous_right: int,
	current_left: int,
	current_right: int
) -> void:
	_indices.append(previous_left)
	_indices.append(current_left)
	_indices.append(previous_right)
	_indices.append(previous_right)
	_indices.append(current_left)
	_indices.append(current_right)


func _measured_hull_half_width() -> float:
	if is_instance_valid(_rear_left) and is_instance_valid(_rear_right):
		var separation := Vector2(
			_rear_left.global_position.x - _rear_right.global_position.x,
			_rear_left.global_position.z - _rear_right.global_position.z
		).length()
		if separation > 0.1:
			return separation * 0.5
	return 0.5


func _real_movement_direction(sample_position: Vector3) -> Vector3:
	var movement := Vector3.ZERO
	if _has_last_sample:
		movement = sample_position - _last_sample_position
		movement.y = 0.0
	if movement.length_squared() <= 0.0001 and _external_source_enabled:
		movement = _external_forward_direction
	elif movement.length_squared() <= 0.0001 and is_instance_valid(_vehicle):
		movement = _water_relative_horizontal_velocity()
		movement.y = 0.0
	if movement.length_squared() <= 0.0001 or not movement.is_finite():
		movement = (
			_external_forward_direction
			if _external_source_enabled
			else -_vehicle.global_basis.z
			if is_instance_valid(_vehicle)
			else Vector3.FORWARD
		)
		movement.y = 0.0
	if movement.length_squared() <= 0.000001:
		return Vector3.FORWARD
	return movement.normalized()


func _current_steering_bias(movement_direction: Vector3) -> float:
	if not is_instance_valid(_vehicle):
		return 0.0
	var vehicle_right := _vehicle.global_basis.x
	vehicle_right.y = 0.0
	if vehicle_right.length_squared() <= 0.000001:
		vehicle_right = Vector3.RIGHT
	else:
		vehicle_right = vehicle_right.normalized()
	var slip_ratio := clampf(
		_vehicle.water_relative_lateral_speed
			/ maxf(absf(_vehicle.water_relative_forward_speed), 2.0),
		-1.0,
		1.0
	)
	var trajectory_misalignment := clampf(
		movement_direction.dot(vehicle_right),
		-1.0,
		1.0
	)
	var contact_mask := _vehicle.current_contact_mask
	var left_contact := float(
		int((contact_mask & 1) != 0) + int((contact_mask & 4) != 0)
	) * 0.5
	var right_contact := float(
		int((contact_mask & 2) != 0) + int((contact_mask & 8) != 0)
	) * 0.5
	return clampf(
		slip_ratio * 0.42
			+ trajectory_misalignment * 0.28
			+ _vehicle.steering_input * 0.22
			+ (right_contact - left_contact) * 0.18,
		-0.55,
		0.55
	)


func _water_relative_horizontal_velocity() -> Vector3:
	if _external_source_enabled:
		return _external_forward_direction * _external_horizontal_speed
	if not is_instance_valid(_vehicle):
		return Vector3.ZERO
	var relative_velocity := (
		_vehicle.linear_velocity
		- _vehicle.water_physics_system.state.average_water_velocity
	)
	relative_velocity.y = 0.0
	return relative_velocity


func _water_relative_horizontal_speed() -> float:
	return _water_relative_horizontal_velocity().length()


func _update_foam_intensity(delta: float) -> void:
	var target_intensity: float = 0.0
	if _external_source_enabled:
		if _external_source_generating:
			target_intensity = clampf(
				inverse_lerp(
					wake_minimum_speed,
					maxf(wake_full_speed, wake_minimum_speed + 0.001),
					_external_horizontal_speed
				) * wake_strength_multiplier,
				0.0,
				2.0
			)
	elif not (
		_foam_settings == null
		or not _foam_settings.foam_enabled
		or not is_instance_valid(_vehicle)
		or _vehicle.navigation_state == JetSkiController.NavigationState.AIRBORNE
	):
		var speed_factor := clampf(
			inverse_lerp(
				wake_minimum_speed,
				maxf(wake_full_speed, wake_minimum_speed + 0.001),
				_water_relative_horizontal_speed()
			),
			0.0,
			1.0
		)
		target_intensity = clampf(
			speed_factor
			* _vehicle.rear_submerged_ratio
			* _vehicle.propulsion_contact_factor
			* _foam_settings.wake_foam_strength,
			0.0,
			1.0
		)
	var response := 9.0 if target_intensity > foam_intensity else 1.35
	var blend := 1.0 - exp(-response * maxf(delta, 0.0))
	foam_intensity = lerpf(foam_intensity, target_intensity, blend)


func _update_live_visual_state(delta: float) -> void:
	_visual_fade = move_toward(
		_visual_fade,
		1.0,
		maxf(delta, 0.0) / maxf(visual_fade_duration, 0.001)
	)
	if not is_instance_valid(_propulsion_point):
		return
	var live_delta := _propulsion_point.global_position - _mesh_head_anchor_position
	live_delta.y = 0.0
	if not live_delta.is_finite() or live_delta.length() > wake_sample_minimum_distance * 3.0:
		live_delta = Vector3.ZERO
	if _normal_material != null:
		_normal_material.set_shader_parameter(&"live_head_delta_world", live_delta)
		_normal_material.set_shader_parameter(&"visual_fade", _visual_fade)
		_normal_material.set_shader_parameter(
			&"local_crest_height",
			local_visual_crest_height
		)
		_normal_material.set_shader_parameter(
			&"local_center_depression",
			local_visual_center_depression
		)
	live_head_update_count += 1


func _update_foam_material(force_update: bool) -> void:
	var signature := _foam_settings.configuration_signature() if _foam_settings != null else 0
	if not force_update and signature == _foam_settings_signature:
		var current_material := _wake_mesh.material_override as ShaderMaterial
		if current_material != null and is_instance_valid(_ocean):
			_apply_external_material_strength(current_material)
			current_material.set_shader_parameter(
				&"simulation_time",
				_ocean.get_simulation_time()
			)
			current_material.set_shader_parameter(&"foam_intensity", foam_intensity)
			current_material.set_shader_parameter(&"visual_fade", _visual_fade)
			current_material.set_shader_parameter(
				&"local_crest_height",
				local_visual_crest_height
			)
			current_material.set_shader_parameter(
				&"local_center_depression",
				local_visual_center_depression
			)
		return
	var material := _wake_mesh.material_override as ShaderMaterial
	if material != null:
		_apply_external_material_strength(material)
		material.set_shader_parameter(&"local_crest_height", local_visual_crest_height)
		material.set_shader_parameter(
			&"local_center_depression",
			local_visual_center_depression
		)
	if material != null and _foam_settings != null:
		material.set_shader_parameter(&"foam_noise_texture", _foam_noise_texture)
		material.set_shader_parameter(&"foam_color", _foam_settings.foam_color)
		material.set_shader_parameter(&"macro_noise_scale", _foam_settings.macro_noise_scale)
		material.set_shader_parameter(&"detail_noise_scale", _foam_settings.detail_noise_scale)
		material.set_shader_parameter(&"noise_scroll_speed", _foam_settings.noise_scroll_speed)
		material.set_shader_parameter(&"breakup_strength", _foam_settings.breakup_strength)
		material.set_shader_parameter(
			&"opacity_boost",
			_foam_settings.wake_foam_opacity_boost
		)
		material.set_shader_parameter(
			&"core_opacity",
			_foam_settings.wake_foam_core_opacity
		)
		material.set_shader_parameter(
			&"emission_strength",
			_foam_settings.wake_foam_emission
		)
	_foam_settings_signature = signature


func _apply_external_material_strength(material: ShaderMaterial) -> void:
	if not _external_source_enabled or material == null:
		return
	var strength := clampf(wake_strength_multiplier, 0.0, 4.0)
	var strength_ratio := strength * 0.25
	material.set_shader_parameter(
		&"opacity_boost",
		lerpf(1.25, 2.55, strength_ratio)
	)
	material.set_shader_parameter(
		&"core_opacity",
		lerpf(0.22, 0.46, strength_ratio)
	)
	material.set_shader_parameter(
		&"emission_strength",
		lerpf(0.035, 0.12, strength_ratio)
	)
