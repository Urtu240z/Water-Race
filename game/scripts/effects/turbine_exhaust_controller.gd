class_name TurbineExhaustController
extends Node3D

const STREAM_SHADER := preload("res://shaders/water_stream.gdshader")
const DROPLET_SHADER := preload("res://shaders/water_particle.gdshader")
const QUALITY_LOW := preload("res://resources/water/vehicle_effects_quality_low.tres")
const QUALITY_MEDIUM := preload("res://resources/water/vehicle_effects_quality_medium.tres")
const QUALITY_HIGH := preload("res://resources/water/vehicle_effects_quality_high.tres")

enum QualityLevel {
	LOW,
	MEDIUM,
	HIGH,
}

class JetSample:
	var position: Vector3
	var velocity: Vector3
	var age: float
	var lifetime: float
	var intensity: float

	func _init(
		initial_position: Vector3,
		initial_velocity: Vector3,
		sample_lifetime: float,
		sample_intensity: float
	) -> void:
		position = initial_position
		velocity = initial_velocity
		age = 0.0
		lifetime = sample_lifetime
		intensity = sample_intensity


@export_group("References")
@export_node_path("RigidBody3D") var vehicle_path: NodePath = NodePath("../..")
@export_node_path("MeshInstance3D") var jet_core_path: NodePath = NodePath(
	"TurbineOutlet/JetCore"
)
@export_node_path("GPUParticles3D") var jet_spray_path: NodePath = NodePath(
	"TurbineOutlet/JetSpray"
)

@export_group("Quality")
@export var quality_level: QualityLevel = QualityLevel.HIGH:
	set(value):
		quality_level = value
		if is_inside_tree():
			_apply_quality_profile()

@export_group("Jet Stream")
@export var exhaust_enabled: bool = true
@export_range(0.0, 4.0, 0.01, "suffix:m") var idle_core_length: float = 0.0
@export_range(0.5, 8.0, 0.05, "suffix:m") var full_core_length: float = 3.8
@export_range(0.1, 30.0, 0.1, "suffix:1/s") var core_response_speed: float = 9.0
@export_range(0.1, 30.0, 0.1, "suffix:1/s") var core_shutdown_speed: float = 14.0

@export_group("Jet Appearance")
@export_range(0.0, 1.0, 0.01) var jet_ocean_alpha: float = 0.58
@export_range(0.0, 2.0, 0.01) var jet_foam_core_strength: float = 0.92
@export_range(0.0, 1.0, 0.01) var jet_foam_core_opacity: float = 0.68
@export_range(0.0, 2.0, 0.01) var jet_foam_emission: float = 0.18
@export_range(0.5, 3.0, 0.01) var jet_radius_multiplier: float = 1.15
@export var jet_droplet_quad_size: Vector2 = Vector2(0.12, 0.42)
@export_range(0, 127, 1) var jet_render_priority: int = 5

@export_group("Jet Breakup")
@export_range(0.0, 1.0, 0.01) var full_spray_ratio: float = 0.72
@export_range(0.0, 30.0, 0.1, "suffix:m/s") var idle_spray_velocity: float = 5.0
@export_range(0.0, 30.0, 0.1, "suffix:m/s") var full_spray_velocity: float = 14.0
@export_range(0.1, 30.0, 0.1, "suffix:1/s") var spray_response_speed: float = 10.0

@export_group("Debug")
@export var force_ocean_mode: bool = false
@export var force_air_mode: bool = false

var airborne_mode: bool:
	get:
		return _airborne_mode

var current_core_length: float:
	get:
		return _current_core_length

var current_core_opacity: float:
	get:
		return _current_core_opacity

var current_jet_spray_ratio: float:
	get:
		return _current_spray_ratio

var stream_vertex_count: int:
	get:
		return _vertices.size()

var stream_sample_count: int:
	get:
		return _samples.size()

var estimated_active_particle_count: int:
	get:
		if not is_instance_valid(_jet_spray) or not _jet_spray.emitting:
			return 0
		return roundi(float(_jet_spray.amount) * _jet_spray.amount_ratio)

var _vehicle: JetSkiController
var _ocean: Ocean3D
var _outlet: Marker3D
var _jet_core: MeshInstance3D
var _jet_spray: GPUParticles3D
var _stream_material: ShaderMaterial
var _spray_material: ParticleProcessMaterial
var _quality_profile: VehicleWaterEffectsQuality
var _airborne_mode: bool = false
var _current_core_length: float = 0.0
var _current_core_opacity: float = 0.0
var _current_spray_ratio: float = 0.0
var _simulation_time: float = 0.0
var _emission_elapsed: float = 0.0
var _reverse_churn: float = 0.0
var _samples: Array[JetSample] = []
var _array_mesh := ArrayMesh.new()
var _vertices := PackedVector3Array()
var _normals := PackedVector3Array()
var _colors := PackedColorArray()
var _uvs := PackedVector2Array()
var _indices := PackedInt32Array()
var _mesh_arrays: Array = []


func _ready() -> void:
	process_physics_priority = 30
	_cache_references()
	if not _references_valid():
		set_physics_process(false)
		return
	_configure_runtime_resources()
	_connect_vehicle_signals()
	_apply_quality_profile()
	_airborne_mode = _read_airborne_mode()


func _physics_process(delta: float) -> void:
	var safe_delta := maxf(delta, 0.0)
	if safe_delta <= 0.0:
		return
	_simulation_time += safe_delta
	_airborne_mode = _read_airborne_mode()
	var throttle_ratio := clampf(_vehicle.throttle_input, 0.0, 1.0)
	var reverse_ratio := clampf(_vehicle.brake_input, 0.0, 1.0)
	var contact := clampf(_vehicle.propulsion_contact_factor, 0.0, 1.0)
	var forward_mode := (
		not _airborne_mode
		and reverse_ratio <= throttle_ratio
		and _vehicle.water_relative_forward_speed > -0.5
	)
	var target_intensity := (
		throttle_ratio * contact
		if exhaust_enabled and forward_mode and _vehicle.is_propelling
		else 0.0
	)
	_reverse_churn = (
		reverse_ratio * contact * 0.24
		if exhaust_enabled and not _airborne_mode and reverse_ratio > throttle_ratio
		else 0.0
	)
	var response := (
		maxf(core_response_speed, 0.1)
		if target_intensity > _current_core_opacity
		else maxf(core_shutdown_speed, 0.1)
	)
	_current_core_opacity = _smooth_toward(
		_current_core_opacity,
		target_intensity,
		response,
		safe_delta
	)
	_current_spray_ratio = _smooth_toward(
		_current_spray_ratio,
		target_intensity,
		maxf(spray_response_speed, 0.1),
		safe_delta
	)
	_update_samples(safe_delta)
	_emit_stream_samples(safe_delta, target_intensity)
	_rebuild_stream_mesh()
	_update_breakup_droplets()


func set_quality_level(level: int) -> void:
	quality_level = clampi(
		level,
		QualityLevel.LOW,
		QualityLevel.HIGH
	) as QualityLevel


func set_graphics_quality(
	_level: int,
	profile: GraphicsQualityProfile
) -> void:
	if profile != null:
		set_quality_level(profile.vehicle_effects_quality_level)


func get_graphics_quality_debug_status() -> Dictionary:
	return {
		"quality_level": quality_level,
		"maximum_sections": (
			_quality_profile.jet_maximum_sections
			if _quality_profile != null
			else 0
		),
		"cross_section_sides": (
			_quality_profile.jet_cross_section_sides
			if _quality_profile != null
			else 0
		),
		"sample_count": _samples.size(),
		"stream_vertex_count": stream_vertex_count,
		"jet_particles": (
			_jet_spray.amount if is_instance_valid(_jet_spray) else 0
		),
		"fixed_fps": (
			_jet_spray.fixed_fps if is_instance_valid(_jet_spray) else 0
		),
	}


func _cache_references() -> void:
	_vehicle = get_node_or_null(vehicle_path) as JetSkiController
	_outlet = get_node_or_null("TurbineOutlet") as Marker3D
	_jet_core = get_node_or_null(jet_core_path) as MeshInstance3D
	_jet_spray = get_node_or_null(jet_spray_path) as GPUParticles3D
	if is_instance_valid(_vehicle):
		_ocean = _vehicle.get_ocean()


func _references_valid() -> bool:
	var valid := (
		is_instance_valid(_vehicle)
		and is_instance_valid(_outlet)
		and is_instance_valid(_jet_core)
		and is_instance_valid(_jet_spray)
	)
	if not valid:
		push_warning(
			"TurbineExhaust requires JetSki, TurbineOutlet, JetCore, and JetSpray."
		)
	return valid


func _configure_runtime_resources() -> void:
	_mesh_arrays.resize(Mesh.ARRAY_MAX)
	_stream_material = ShaderMaterial.new()
	_stream_material.shader = STREAM_SHADER
	_stream_material.render_priority = jet_render_priority
	_stream_material.set_shader_parameter(&"sheet_mode", false)
	_stream_material.set_shader_parameter(&"water_alpha", jet_ocean_alpha)
	_stream_material.set_shader_parameter(
		&"foam_core_strength",
		jet_foam_core_strength
	)
	_stream_material.set_shader_parameter(
		&"foam_core_opacity",
		jet_foam_core_opacity
	)
	_stream_material.set_shader_parameter(
		&"foam_emission_strength",
		jet_foam_emission
	)
	if is_instance_valid(_ocean):
		var stream_color := _ocean.wave_crest_color.lightened(0.66)
		stream_color.a = 1.0
		_stream_material.set_shader_parameter(
			&"water_tint",
			stream_color
		)
		if _ocean.foam_settings != null:
			_stream_material.set_shader_parameter(
				&"foam_tint",
				_ocean.foam_settings.foam_color
			)
	_jet_core.top_level = true
	_jet_core.global_transform = Transform3D.IDENTITY
	_jet_core.mesh = _array_mesh
	_jet_core.material_override = _stream_material
	_jet_core.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

	var droplet_material := ShaderMaterial.new()
	droplet_material.shader = DROPLET_SHADER
	droplet_material.render_priority = jet_render_priority + 1
	if is_instance_valid(_ocean):
		var droplet_color := _ocean.wave_crest_color
		droplet_color.a = 0.86
		droplet_material.set_shader_parameter(&"particle_color", droplet_color)
	var droplet_quad := QuadMesh.new()
	droplet_quad.size = jet_droplet_quad_size
	droplet_quad.material = droplet_material
	_spray_material = ParticleProcessMaterial.new()
	_spray_material.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_POINT
	_spray_material.direction = Vector3.UP
	_spray_material.spread = 16.0
	_spray_material.gravity = Vector3(0.0, -16.0, 0.0)
	_spray_material.initial_velocity_min = 2.0
	_spray_material.initial_velocity_max = 5.0
	_spray_material.damping_min = 0.05
	_spray_material.damping_max = 0.25
	_spray_material.scale_min = 0.20
	_spray_material.scale_max = 0.42
	_spray_material.particle_flag_align_y = true
	_jet_spray.top_level = true
	_jet_spray.local_coords = false
	_jet_spray.lifetime = 0.32
	_jet_spray.randomness = 0.42
	_jet_spray.visibility_aabb = AABB(
		Vector3(-20.0, -12.0, -20.0),
		Vector3(40.0, 32.0, 40.0)
	)
	_jet_spray.process_material = _spray_material
	_jet_spray.draw_pass_1 = droplet_quad
	_jet_spray.emitting = false


func _apply_quality_profile() -> void:
	match quality_level:
		QualityLevel.LOW:
			_quality_profile = QUALITY_LOW
		QualityLevel.MEDIUM:
			_quality_profile = QUALITY_MEDIUM
		_:
			_quality_profile = QUALITY_HIGH
	if not is_inside_tree() or _quality_profile == null:
		return
	if is_instance_valid(_jet_spray):
		_jet_spray.amount = _quality_profile.jet_breakup_particles
		_jet_spray.fixed_fps = _quality_profile.particles_fixed_fps
	if _stream_material != null:
		_stream_material.set_shader_parameter(
			&"refraction_enabled",
			_quality_profile.refraction_enabled
		)
	while _samples.size() > _quality_profile.jet_maximum_sections:
		_samples.pop_front()


func _connect_vehicle_signals() -> void:
	if not _vehicle.water_exited.is_connected(_on_vehicle_ocean_exited):
		_vehicle.water_exited.connect(_on_vehicle_ocean_exited)
	if not _vehicle.water_entered.is_connected(_on_vehicle_ocean_entered):
		_vehicle.water_entered.connect(_on_vehicle_ocean_entered)
	if not _vehicle.reset_completed.is_connected(_on_vehicle_reset_completed):
		_vehicle.reset_completed.connect(_on_vehicle_reset_completed)
	if not _vehicle.world_rebased.is_connected(_on_vehicle_world_rebased):
		_vehicle.world_rebased.connect(_on_vehicle_world_rebased)


func _emit_stream_samples(delta: float, intensity: float) -> void:
	if (
		intensity <= 0.025
		or _quality_profile == null
		or not is_instance_valid(_outlet)
	):
		_emission_elapsed = 0.0
		return
	var maximum_sections := maxi(_quality_profile.jet_maximum_sections, 6)
	var jet_speed := lerpf(
		maxf(idle_spray_velocity, 0.1),
		maxf(full_spray_velocity, idle_spray_velocity),
		intensity
	)
	var target_length := lerpf(
		maxf(idle_core_length, 0.0),
		maxf(full_core_length, idle_core_length),
		sqrt(intensity)
	)
	var sample_lifetime := clampf(
		target_length / maxf(jet_speed, 0.1),
		0.10,
		0.42
	)
	var sample_interval := sample_lifetime / float(maximum_sections - 1)
	_emission_elapsed += delta
	while _emission_elapsed >= sample_interval:
		_emission_elapsed -= sample_interval
		var outlet_transform := _outlet.get_global_transform_interpolated()
		var marker_direction := outlet_transform.basis.z.normalized()
		var backward := _horizontal_direction(
			_vehicle.global_basis.z,
			Vector3.BACK
		)
		var direction := (
			marker_direction + backward * 0.65 + Vector3.UP * 0.20
		).normalized()
		var inherited_velocity := _vehicle.linear_velocity
		inherited_velocity.y = 0.0
		var initial_velocity := inherited_velocity + direction * jet_speed
		_samples.append(JetSample.new(
			outlet_transform.origin,
			initial_velocity,
			sample_lifetime,
			intensity
		))
		while _samples.size() > maximum_sections:
			_samples.pop_front()


func _update_samples(delta: float) -> void:
	for sample in _samples:
		sample.age += delta
		sample.velocity += Vector3(0.0, -9.8, 0.0) * delta
		sample.velocity *= exp(-0.30 * delta)
		sample.position += sample.velocity * delta
	for index in range(_samples.size() - 1, -1, -1):
		var sample := _samples[index]
		var hit_ocean := false
		if is_instance_valid(_ocean) and sample.age > 0.08:
			hit_ocean = (
				sample.velocity.y < 0.0
				and sample.position.y <= _ocean.sample_height(sample.position)
			)
		if sample.age >= sample.lifetime or hit_ocean:
			_samples.remove_at(index)


func _rebuild_stream_mesh() -> void:
	_array_mesh.clear_surfaces()
	_vertices.clear()
	_normals.clear()
	_colors.clear()
	_uvs.clear()
	_indices.clear()
	_current_core_length = 0.0
	if _samples.is_empty() or _quality_profile == null:
		_jet_core.visible = false
		return
	var positions := PackedVector3Array()
	var intensities := PackedFloat32Array()
	var ages := PackedFloat32Array()
	positions.append(_outlet.get_global_transform_interpolated().origin)
	intensities.append(_current_core_opacity)
	ages.append(0.0)
	for index in range(_samples.size() - 1, -1, -1):
		var sample := _samples[index]
		positions.append(sample.position)
		intensities.append(sample.intensity)
		ages.append(clampf(sample.age / maxf(sample.lifetime, 0.001), 0.0, 1.0))
	if positions.size() < 2:
		_jet_core.visible = false
		return
	var sides := maxi(_quality_profile.jet_cross_section_sides, 2)
	var cumulative_length := 0.0
	for ring_index in positions.size():
		if ring_index > 0:
			cumulative_length += positions[ring_index].distance_to(
				positions[ring_index - 1]
			)
		var tangent := _path_tangent(positions, ring_index)
		var ring_right := tangent.cross(Vector3.UP)
		if ring_right.length_squared() <= 0.000001:
			ring_right = _vehicle.global_basis.x.normalized()
		else:
			ring_right = ring_right.normalized()
		var ring_up := ring_right.cross(tangent).normalized()
		var age_ratio := ages[ring_index]
		var intensity := intensities[ring_index]
		var radius := lerpf(0.048, 0.090, intensity) * jet_radius_multiplier
		radius *= lerpf(0.86, 1.20, age_ratio)
		radius *= 1.0 + sin(age_ratio * 31.0 + ring_index * 1.7) * 0.16
		var end_taper := 1.0 - smoothstep(0.72, 1.0, age_ratio) * 0.72
		radius *= end_taper
		for side in sides:
			var angle := TAU * float(side) / float(sides)
			var normal := (
				ring_right * cos(angle) + ring_up * sin(angle)
			).normalized()
			_vertices.append(positions[ring_index] + normal * radius)
			_normals.append(normal)
			_colors.append(Color(
				1.0,
				1.0,
				1.0,
				intensity * (1.0 - smoothstep(0.82, 1.0, age_ratio))
			))
			_uvs.append(Vector2(
				float(side) / float(maxi(sides - 1, 1)),
				age_ratio
			))
		if ring_index == 0:
			continue
		var current_base := ring_index * sides
		var previous_base := current_base - sides
		for side in sides:
			var next_side := (side + 1) % sides
			_indices.append_array(PackedInt32Array([
				previous_base + side,
				current_base + side,
				previous_base + next_side,
				previous_base + next_side,
				current_base + side,
				current_base + next_side,
			]))
	_current_core_length = cumulative_length
	_mesh_arrays.fill(null)
	_mesh_arrays[Mesh.ARRAY_VERTEX] = _vertices
	_mesh_arrays[Mesh.ARRAY_NORMAL] = _normals
	_mesh_arrays[Mesh.ARRAY_COLOR] = _colors
	_mesh_arrays[Mesh.ARRAY_TEX_UV] = _uvs
	_mesh_arrays[Mesh.ARRAY_INDEX] = _indices
	_array_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, _mesh_arrays)
	_jet_core.visible = _array_mesh.get_surface_count() > 0
	_stream_material.set_shader_parameter(&"simulation_time", _simulation_time)


func _update_breakup_droplets() -> void:
	if not is_instance_valid(_jet_spray) or _spray_material == null:
		return
	var breakup_intensity := _current_spray_ratio * full_spray_ratio
	var endpoint_position := _outlet.get_global_transform_interpolated().origin
	var endpoint_velocity := _outlet.global_basis.z.normalized() * 2.0
	if not _samples.is_empty():
		var endpoint := _samples[0]
		endpoint_position = endpoint.position
		endpoint_velocity = endpoint.velocity
	var reverse_only := _reverse_churn > breakup_intensity
	var final_intensity := maxf(breakup_intensity, _reverse_churn)
	var direction := endpoint_velocity.normalized()
	if reverse_only:
		var backward := _horizontal_direction(
			_vehicle.global_basis.z,
			Vector3.BACK
		)
		direction = (Vector3.UP * 0.42 + backward * 0.58).normalized()
		endpoint_position = _outlet.get_global_transform_interpolated().origin
	var speed := endpoint_velocity.length()
	_spray_material.initial_velocity_min = (
		lerpf(1.0, 3.0, final_intensity)
		if reverse_only
		else clampf(speed * 0.38, 2.0, 7.5)
	)
	_spray_material.initial_velocity_max = _spray_material.initial_velocity_min * 1.35
	_spray_material.scale_min = lerpf(0.14, 0.24, final_intensity)
	_spray_material.scale_max = lerpf(0.26, 0.44, final_intensity)
	_spray_material.spread = 34.0 if reverse_only else 16.0
	_jet_spray.global_transform = Transform3D(
		_basis_with_y(direction, _vehicle.global_basis.z),
		endpoint_position
	)
	_jet_spray.amount_ratio = clampf(final_intensity, 0.0, 1.0)
	_jet_spray.emitting = final_intensity > 0.025


func _path_tangent(points: PackedVector3Array, index: int) -> Vector3:
	var tangent := Vector3.ZERO
	if index > 0 and index + 1 < points.size():
		tangent = points[index + 1] - points[index - 1]
	elif index + 1 < points.size():
		tangent = points[index + 1] - points[index]
	elif index > 0:
		tangent = points[index] - points[index - 1]
	if tangent.length_squared() <= 0.000001:
		return _outlet.global_basis.z.normalized()
	return tangent.normalized()


func _stop_all_visuals() -> void:
	_samples.clear()
	_array_mesh.clear_surfaces()
	_current_core_length = 0.0
	_current_core_opacity = 0.0
	_current_spray_ratio = 0.0
	_reverse_churn = 0.0
	if is_instance_valid(_jet_core):
		_jet_core.visible = false
	if is_instance_valid(_jet_spray):
		_jet_spray.amount_ratio = 0.0
		_jet_spray.emitting = false


func _read_airborne_mode() -> bool:
	if force_air_mode:
		return true
	if force_ocean_mode:
		return false
	return _vehicle.navigation_state == JetSkiController.NavigationState.AIRBORNE


func _on_vehicle_ocean_exited() -> void:
	_airborne_mode = true


func _on_vehicle_ocean_entered(_intensity: float, _position: Vector3) -> void:
	_airborne_mode = false


func _on_vehicle_reset_completed(_reason: StringName) -> void:
	_stop_all_visuals()
	_airborne_mode = _read_airborne_mode()


func _on_vehicle_world_rebased(shift: Vector3) -> void:
	var horizontal_shift := Vector3(shift.x, 0.0, shift.z)
	for sample in _samples:
		sample.position -= horizontal_shift
	_rebuild_stream_mesh()


func _basis_with_y(direction: Vector3, reference_forward: Vector3) -> Basis:
	var y_axis := direction.normalized()
	var reference := reference_forward.normalized()
	if reference.is_zero_approx() or absf(reference.dot(y_axis)) > 0.96:
		reference = Vector3.FORWARD
	var x_axis := y_axis.cross(reference)
	if x_axis.length_squared() <= 0.000001:
		x_axis = y_axis.cross(Vector3.RIGHT)
	x_axis = x_axis.normalized()
	var z_axis := x_axis.cross(y_axis).normalized()
	return Basis(x_axis, y_axis, z_axis).orthonormalized()


func _horizontal_direction(source: Vector3, fallback: Vector3) -> Vector3:
	var direction := source
	direction.y = 0.0
	if direction.length_squared() <= 0.000001 or not direction.is_finite():
		return fallback
	return direction.normalized()


func _smooth_toward(
	current_value: float,
	target_value: float,
	response_speed: float,
	delta: float
) -> float:
	var blend := 1.0 - exp(-maxf(response_speed, 0.1) * maxf(delta, 0.0))
	return lerpf(current_value, target_value, blend)
