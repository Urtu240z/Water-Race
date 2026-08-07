@tool
class_name SeabedBody3D
extends Node3D

signal mesh_rebuilt

enum SeabedPattern {
	FLAT,
	SOFT_SAND,
	DUNES,
	ROLLING,
	ROUGH,
	CUSTOM,
}

const DETAIL_SEED_OFFSET: int = 7919
const MINIMUM_NORMAL_SAMPLE_DISTANCE: float = 0.05

@export_group("Patch")
@export_range(256.0, 2048.0, 64.0) var patch_size: float = 768.0:
	set(value):
		var validated_value := clampf(value, 256.0, 2048.0)
		if is_equal_approx(patch_size, validated_value):
			return
		patch_size = validated_value
		_queue_mesh_rebuild()
@export_range(33, 257, 2) var vertex_resolution: int = 129:
	set(value):
		var validated_value := clampi(value, 33, 257)
		if validated_value % 2 == 0:
			validated_value = mini(validated_value + 1, 257)
		if vertex_resolution == validated_value:
			return
		vertex_resolution = validated_value
		_queue_mesh_rebuild()
@export_range(8.0, 256.0, 8.0) var follow_snap_size: float = 64.0:
	set(value):
		var validated_value := clampf(value, 8.0, 256.0)
		if is_equal_approx(follow_snap_size, validated_value):
			return
		follow_snap_size = validated_value
		_follow_cell_initialized = false
		_queue_follow_update()

@export_group("Depth")
@export_range(2.0, 100.0, 0.5) var base_depth: float = 10.0:
	set(value):
		var validated_value := clampf(value, 2.0, 100.0)
		if is_equal_approx(base_depth, validated_value):
			return
		base_depth = validated_value
		_queue_mesh_rebuild()
@export_range(0.5, 20.0, 0.5) var minimum_depth_below_water: float = 3.0:
	set(value):
		var validated_value := clampf(value, 0.5, 20.0)
		if is_equal_approx(minimum_depth_below_water, validated_value):
			return
		minimum_depth_below_water = validated_value
		_queue_mesh_rebuild()

@export_group("Procedural Pattern")
@export var seabed_pattern: SeabedPattern = SeabedPattern.SOFT_SAND:
	set(value):
		var validated_value := clampi(int(value), 0, SeabedPattern.size() - 1)
		if int(seabed_pattern) == validated_value:
			return
		seabed_pattern = validated_value as SeabedPattern
		_queue_mesh_rebuild()
@export_range(0.0, 3.0, 0.05) var pattern_strength: float = 1.0:
	set(value):
		var validated_value := clampf(value, 0.0, 3.0)
		if is_equal_approx(pattern_strength, validated_value):
			return
		pattern_strength = validated_value
		_queue_mesh_rebuild()
@export var noise_seed: int = 1847:
	set(value):
		if noise_seed == value:
			return
		noise_seed = value
		_queue_mesh_rebuild()

@export_group("Custom Primary Noise")
@export_range(0.0, 20.0, 0.1) var custom_height_amplitude: float = 2.0:
	set(value):
		custom_height_amplitude = clampf(value, 0.0, 20.0)
		_queue_custom_mesh_rebuild()
@export_range(0.0005, 0.1, 0.0005) var custom_primary_frequency: float = 0.005:
	set(value):
		custom_primary_frequency = clampf(value, 0.0005, 0.1)
		_queue_custom_mesh_rebuild()
@export_range(1, 8, 1) var custom_octaves: int = 4:
	set(value):
		custom_octaves = clampi(value, 1, 8)
		_queue_custom_mesh_rebuild()
@export_range(1.0, 4.0, 0.05) var custom_lacunarity: float = 2.0:
	set(value):
		custom_lacunarity = clampf(value, 1.0, 4.0)
		_queue_custom_mesh_rebuild()
@export_range(0.0, 1.0, 0.01) var custom_gain: float = 0.5:
	set(value):
		custom_gain = clampf(value, 0.0, 1.0)
		_queue_custom_mesh_rebuild()

@export_group("Custom Detail")
@export_range(0.0, 5.0, 0.05) var custom_detail_amplitude: float = 0.35:
	set(value):
		custom_detail_amplitude = clampf(value, 0.0, 5.0)
		_queue_custom_mesh_rebuild()
@export_range(0.001, 0.2, 0.001) var custom_detail_frequency: float = 0.02:
	set(value):
		custom_detail_frequency = clampf(value, 0.001, 0.2)
		_queue_custom_mesh_rebuild()

@export_group("Custom Dunes")
@export_range(0.0, 5.0, 0.05) var custom_dune_amplitude: float = 0.0:
	set(value):
		custom_dune_amplitude = clampf(value, 0.0, 5.0)
		_queue_custom_mesh_rebuild()
@export_range(2.0, 100.0, 1.0) var custom_dune_wavelength: float = 24.0:
	set(value):
		custom_dune_wavelength = clampf(value, 2.0, 100.0)
		_queue_custom_mesh_rebuild()
@export_range(-180.0, 180.0, 1.0) var custom_dune_direction_degrees: float = 25.0:
	set(value):
		custom_dune_direction_degrees = clampf(value, -180.0, 180.0)
		_queue_custom_mesh_rebuild()

@export_group("Custom Shape")
@export_range(0.0, 1.0, 0.01) var custom_ridge_strength: float = 0.0:
	set(value):
		custom_ridge_strength = clampf(value, 0.0, 1.0)
		_queue_custom_mesh_rebuild()

@export_group("Material Mapping")
@export_range(0.001, 2.0, 0.001) var uv_world_scale: float = 0.08:
	set(value):
		var validated_value := clampf(value, 0.001, 2.0)
		if is_equal_approx(uv_world_scale, validated_value):
			return
		uv_world_scale = validated_value
		_queue_mesh_rebuild()

@export_group("Material")
@export var seabed_material: Material:
	set(value):
		seabed_material = value
		_apply_material()
@export_color_no_alpha var visibility_emission_color: Color = Color(0.42, 0.30, 0.14, 1.0):
	set(value):
		visibility_emission_color = value
		_apply_material()
@export_range(0.0, 8.0, 0.05) var visibility_emission_energy: float = 2.5:
	set(value):
		visibility_emission_energy = clampf(value, 0.0, 8.0)
		_apply_material()
@export var double_sided: bool = true:
	set(value):
		double_sided = value
		_apply_material()

@export_group("References")
@export var follow_target: Node3D
@export_node_path("Node3D") var follow_target_path: NodePath
@export_node_path("Node") var world_origin_controller_path: NodePath

var seabed_pattern_name: StringName:
	get:
		return _get_pattern_name(seabed_pattern)

var effective_pattern_strength: float:
	get:
		return pattern_strength

var current_patch_local_center: Vector3:
	get:
		return position

var current_patch_logical_center: Vector3:
	get:
		return _current_logical_center

var generated_vertex_count: int:
	get:
		return _generated_vertex_count

var generated_triangle_count: int:
	get:
		return _generated_triangle_count

var last_rebuild_duration_ms: float:
	get:
		return _last_rebuild_duration_ms

var minimum_generated_height: float:
	get:
		return _minimum_generated_height

var maximum_generated_height: float:
	get:
		return _maximum_generated_height

var rebuild_count: int:
	get:
		return _rebuild_count

var rebase_count: int:
	get:
		return _rebase_count

var seabed_reference_valid: bool:
	get:
		return (
			is_instance_valid(_mesh_instance)
			and is_instance_valid(follow_target)
			and is_instance_valid(_world_origin)
		)

@onready var _mesh_instance: MeshInstance3D = $SeabedMesh as MeshInstance3D

var _array_mesh: ArrayMesh
var _fallback_material: StandardMaterial3D
var _display_material: Material
var _primary_noise := FastNoiseLite.new()
var _detail_noise := FastNoiseLite.new()
var _world_origin: WorldOriginController
var _current_logical_center: Vector3 = Vector3.ZERO
var _follow_cell_initialized: bool = false
var _follow_update_queued: bool = false
var _rebuild_queued: bool = false
var _rebuild_in_progress: bool = false
var _rebuild_requested_again: bool = false
var _generated_vertex_count: int = 0
var _generated_triangle_count: int = 0
var _last_rebuild_duration_ms: float = 0.0
var _minimum_generated_height: float = 0.0
var _maximum_generated_height: float = 0.0
var _rebuild_count: int = 0
var _rebase_count: int = 0
var _reference_warning_emitted: bool = false


func _ready() -> void:
	process_physics_priority = -90
	_array_mesh = _mesh_instance.mesh as ArrayMesh
	if _array_mesh == null:
		_array_mesh = ArrayMesh.new()
		_mesh_instance.mesh = _array_mesh
	_resolve_references()
	_configure_fallback_material()
	_apply_material()
	_connect_world_origin()
	if not seabed_reference_valid:
		_warn_invalid_references_once()
	_update_follow_cell(true)
	# Build a preview even when this scene is opened on its own in the editor,
	# where the follow target and world-origin controller do not exist.
	_queue_mesh_rebuild()


func _physics_process(_delta: float) -> void:
	_update_follow_cell(false)


func get_effective_pattern_parameters() -> Dictionary:
	return _effective_pattern_parameters().duplicate(true)


func sample_height_logical(logical_xz: Vector2) -> float:
	var parameters := _effective_pattern_parameters()
	_configure_noises(parameters)
	return _sample_height_with_parameters(logical_xz, parameters)


func sample_normal_logical(logical_xz: Vector2) -> Vector3:
	var parameters := _effective_pattern_parameters()
	_configure_noises(parameters)
	return _sample_normal_with_parameters(logical_xz, parameters)


func sample_uv_logical(logical_xz: Vector2) -> Vector2:
	return logical_xz * uv_world_scale


func rebuild_mesh_now() -> void:
	if not is_inside_tree() or not is_node_ready():
		return
	_rebuild_queued = false
	_rebuild_mesh()


func update_follow_now() -> void:
	_follow_update_queued = false
	_update_follow_cell(false)


func get_mesh_instance() -> MeshInstance3D:
	return _mesh_instance


func _effective_pattern_parameters() -> Dictionary:
	match seabed_pattern:
		SeabedPattern.FLAT:
			return _make_parameters(0.0, 0.004, 0.0, 0.018, 3, 2.0, 0.5, 0.0, 24.0, 25.0, 0.0)
		SeabedPattern.SOFT_SAND:
			return _make_parameters(1.5, 0.004, 0.25, 0.018, 3, 2.0, 0.5, 0.0, 24.0, 25.0, 0.0)
		SeabedPattern.DUNES:
			return _make_parameters(0.8, 0.004, 0.20, 0.020, 3, 2.0, 0.5, 0.75, 24.0, 25.0, 0.0)
		SeabedPattern.ROLLING:
			return _make_parameters(3.0, 0.003, 0.35, 0.014, 4, 2.0, 0.5, 0.0, 24.0, 25.0, 0.0)
		SeabedPattern.ROUGH:
			return _make_parameters(4.0, 0.006, 0.8, 0.025, 5, 2.1, 0.52, 0.0, 24.0, 25.0, 0.65)
		SeabedPattern.CUSTOM:
			return _make_parameters(
				custom_height_amplitude,
				custom_primary_frequency,
				custom_detail_amplitude,
				custom_detail_frequency,
				custom_octaves,
				custom_lacunarity,
				custom_gain,
				custom_dune_amplitude,
				custom_dune_wavelength,
				custom_dune_direction_degrees,
				custom_ridge_strength
			)
	return _make_parameters(0.0, 0.004, 0.0, 0.018, 3, 2.0, 0.5, 0.0, 24.0, 25.0, 0.0)


func _make_parameters(
	height_amplitude: float,
	primary_frequency: float,
	detail_amplitude: float,
	detail_frequency: float,
	octaves: int,
	lacunarity: float,
	gain: float,
	dune_amplitude: float,
	dune_wavelength: float,
	dune_direction_degrees: float,
	ridge_strength: float
) -> Dictionary:
	return {
		&"height_amplitude": height_amplitude,
		&"primary_frequency": primary_frequency,
		&"detail_amplitude": detail_amplitude,
		&"detail_frequency": detail_frequency,
		&"octaves": octaves,
		&"lacunarity": lacunarity,
		&"gain": gain,
		&"dune_amplitude": dune_amplitude,
		&"dune_wavelength": dune_wavelength,
		&"dune_direction_degrees": dune_direction_degrees,
		&"ridge_strength": ridge_strength,
	}


func _configure_noises(parameters: Dictionary) -> void:
	_primary_noise.seed = noise_seed
	_primary_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_primary_noise.frequency = float(parameters[&"primary_frequency"])
	_primary_noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	_primary_noise.fractal_octaves = int(parameters[&"octaves"])
	_primary_noise.fractal_lacunarity = float(parameters[&"lacunarity"])
	_primary_noise.fractal_gain = float(parameters[&"gain"])
	_detail_noise.seed = noise_seed + DETAIL_SEED_OFFSET
	_detail_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_detail_noise.frequency = float(parameters[&"detail_frequency"])
	_detail_noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	_detail_noise.fractal_octaves = maxi(int(parameters[&"octaves"]) - 1, 1)
	_detail_noise.fractal_lacunarity = float(parameters[&"lacunarity"])
	_detail_noise.fractal_gain = float(parameters[&"gain"])


func _sample_height_with_parameters(logical_xz: Vector2, parameters: Dictionary) -> float:
	var primary_value := _primary_noise.get_noise_2d(logical_xz.x, logical_xz.y)
	var detail_value := _detail_noise.get_noise_2d(logical_xz.x, logical_xz.y)
	var ridged := 1.0 - absf(primary_value)
	ridged *= ridged
	var final_primary := lerpf(
		primary_value,
		ridged * 2.0 - 1.0,
		float(parameters[&"ridge_strength"])
	)
	var displacement := (
		final_primary * float(parameters[&"height_amplitude"])
		+ detail_value * float(parameters[&"detail_amplitude"])
	)
	var dune_amplitude := float(parameters[&"dune_amplitude"])
	if dune_amplitude > 0.0:
		var angle := deg_to_rad(float(parameters[&"dune_direction_degrees"]))
		var direction := Vector2(cos(angle), sin(angle))
		var dune_coordinate := logical_xz.dot(direction)
		var dune_wavelength := maxf(float(parameters[&"dune_wavelength"]), 0.001)
		var warped_coordinate := dune_coordinate + primary_value * dune_wavelength * 0.2
		displacement += sin(TAU * warped_coordinate / dune_wavelength) * dune_amplitude
	var height := -base_depth + displacement * pattern_strength
	if not is_finite(height):
		height = -base_depth
	return minf(height, -minimum_depth_below_water)


func _sample_normal_with_parameters(logical_xz: Vector2, parameters: Dictionary) -> Vector3:
	var sample_distance := maxf(
		patch_size / float(maxi(vertex_resolution - 1, 1)),
		MINIMUM_NORMAL_SAMPLE_DISTANCE
	)
	var left := _sample_height_with_parameters(logical_xz - Vector2(sample_distance, 0.0), parameters)
	var right := _sample_height_with_parameters(logical_xz + Vector2(sample_distance, 0.0), parameters)
	var back := _sample_height_with_parameters(logical_xz - Vector2(0.0, sample_distance), parameters)
	var forward := _sample_height_with_parameters(logical_xz + Vector2(0.0, sample_distance), parameters)
	var normal := Vector3(
		left - right,
		2.0 * sample_distance,
		back - forward
	).normalized()
	return normal if normal.is_finite() and not normal.is_zero_approx() else Vector3.UP


func _rebuild_mesh() -> void:
	if _rebuild_in_progress or not is_instance_valid(_mesh_instance) or _array_mesh == null:
		_rebuild_requested_again = true
		return
	_rebuild_in_progress = true
	var started_usec := Time.get_ticks_usec()
	var parameters := _effective_pattern_parameters()
	_configure_noises(parameters)
	var resolution := maxi(vertex_resolution, 2)
	var spacing := patch_size / float(resolution - 1)
	var half_size := patch_size * 0.5
	var logical_start_x: float = floor(
		(_current_logical_center.x - half_size) / spacing
	) * spacing
	var logical_start_z: float = floor(
		(_current_logical_center.z - half_size) / spacing
	) * spacing
	var vertex_count := resolution * resolution
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	vertices.resize(vertex_count)
	normals.resize(vertex_count)
	uvs.resize(vertex_count)
	var minimum_height := INF
	var maximum_height := -INF
	for z_index in resolution:
		var logical_z: float = logical_start_z + float(z_index) * spacing
		for x_index in resolution:
			var logical_x: float = logical_start_x + float(x_index) * spacing
			var logical_xz := Vector2(logical_x, logical_z)
			var height := _sample_height_with_parameters(logical_xz, parameters)
			var index := z_index * resolution + x_index
			vertices[index] = Vector3(
				logical_x - _current_logical_center.x,
				height,
				logical_z - _current_logical_center.z
			)
			normals[index] = Vector3.UP
			uvs[index] = logical_xz * uv_world_scale
			minimum_height = minf(minimum_height, height)
			maximum_height = maxf(maximum_height, height)
	for z_index in resolution:
		var back_z := maxi(z_index - 1, 0)
		var forward_z := mini(z_index + 1, resolution - 1)
		var z_sample_span := float(forward_z - back_z) * spacing
		for x_index in resolution:
			var left_x := maxi(x_index - 1, 0)
			var right_x := mini(x_index + 1, resolution - 1)
			var x_sample_span := float(right_x - left_x) * spacing
			var index := z_index * resolution + x_index
			var left_height := vertices[z_index * resolution + left_x].y
			var right_height := vertices[z_index * resolution + right_x].y
			var back_height := vertices[back_z * resolution + x_index].y
			var forward_height := vertices[forward_z * resolution + x_index].y
			var derivative_x := (right_height - left_height) / maxf(x_sample_span, 0.001)
			var derivative_z := (forward_height - back_height) / maxf(z_sample_span, 0.001)
			var normal := Vector3(-derivative_x, 1.0, -derivative_z).normalized()
			normals[index] = normal if normal.is_finite() else Vector3.UP
	var indices := PackedInt32Array()
	indices.resize((resolution - 1) * (resolution - 1) * 6)
	var write_index := 0
	for z_index in resolution - 1:
		for x_index in resolution - 1:
			var top_left := z_index * resolution + x_index
			var top_right := top_left + 1
			var bottom_left := top_left + resolution
			var bottom_right := bottom_left + 1
			indices[write_index] = top_left
			indices[write_index + 1] = bottom_left
			indices[write_index + 2] = top_right
			indices[write_index + 3] = top_right
			indices[write_index + 4] = bottom_left
			indices[write_index + 5] = bottom_right
			write_index += 6
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices
	_array_mesh.clear_surfaces()
	_array_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	_apply_material()
	_generated_vertex_count = vertex_count
	_generated_triangle_count = int(float(indices.size()) / 3.0)
	_minimum_generated_height = minimum_height
	_maximum_generated_height = maximum_height
	_last_rebuild_duration_ms = float(Time.get_ticks_usec() - started_usec) / 1000.0
	_rebuild_count += 1
	_rebuild_in_progress = false
	mesh_rebuilt.emit()
	if _rebuild_requested_again:
		_rebuild_requested_again = false
		_queue_mesh_rebuild()


func _update_follow_cell(force_update: bool) -> void:
	if not is_instance_valid(follow_target):
		return
	var logical_target := _local_to_logical(follow_target.global_position)
	var snap_size := maxf(follow_snap_size, 0.001)
	var next_center := Vector3(
		roundf(logical_target.x / snap_size) * snap_size,
		0.0,
		roundf(logical_target.z / snap_size) * snap_size
	)
	if (
		not force_update
		and _follow_cell_initialized
		and next_center.is_equal_approx(_current_logical_center)
	):
		return
	_current_logical_center = next_center
	_follow_cell_initialized = true
	_update_local_position_from_logical_center()
	_queue_mesh_rebuild()


func _update_local_position_from_logical_center() -> void:
	var logical_origin := (
		_world_origin.logical_origin_offset
		if is_instance_valid(_world_origin) and not Engine.is_editor_hint()
		else Vector3.ZERO
	)
	position = Vector3(
		_current_logical_center.x - logical_origin.x,
		0.0,
		_current_logical_center.z - logical_origin.z
	)
	if not Engine.is_editor_hint():
		reset_physics_interpolation()


func _local_to_logical(local_position: Vector3) -> Vector3:
	return (
		_world_origin.local_to_logical_position(local_position)
		if is_instance_valid(_world_origin) and not Engine.is_editor_hint()
		else local_position
	)


func _resolve_references() -> void:
	if follow_target == null and not follow_target_path.is_empty():
		follow_target = get_node_or_null(follow_target_path) as Node3D
	_world_origin = get_node_or_null(world_origin_controller_path) as WorldOriginController


func _connect_world_origin() -> void:
	if Engine.is_editor_hint() or not is_instance_valid(_world_origin):
		return
	if not _world_origin.world_rebased.is_connected(_on_world_rebased):
		_world_origin.world_rebased.connect(_on_world_rebased)


func _on_world_rebased(shift: Vector3) -> void:
	if not shift.is_finite():
		return
	_rebase_count += 1
	_update_local_position_from_logical_center()


func _queue_follow_update() -> void:
	if not is_inside_tree() or not is_node_ready() or _follow_update_queued:
		return
	_follow_update_queued = true
	call_deferred("_apply_queued_follow_update")


func _apply_queued_follow_update() -> void:
	if not _follow_update_queued:
		return
	_follow_update_queued = false
	_update_follow_cell(true)


func _queue_mesh_rebuild() -> void:
	if not is_inside_tree() or not is_node_ready():
		return
	if _rebuild_in_progress:
		_rebuild_requested_again = true
		return
	if _rebuild_queued:
		return
	_rebuild_queued = true
	call_deferred("_apply_queued_mesh_rebuild")


func _apply_queued_mesh_rebuild() -> void:
	if not _rebuild_queued:
		return
	_rebuild_queued = false
	_rebuild_mesh()


func _queue_custom_mesh_rebuild() -> void:
	if seabed_pattern == SeabedPattern.CUSTOM:
		_queue_mesh_rebuild()


func _configure_fallback_material() -> void:
	if _fallback_material == null:
		_fallback_material = StandardMaterial3D.new()
	_fallback_material.albedo_color = Color(0.46, 0.34, 0.18, 1.0)
	_fallback_material.roughness = 1.0
	_fallback_material.metallic = 0.0
	_fallback_material.transparency = BaseMaterial3D.TRANSPARENCY_DISABLED


func _apply_material() -> void:
	if not is_instance_valid(_mesh_instance):
		return
	if _fallback_material == null:
		_configure_fallback_material()
	var source_material: Material = seabed_material if seabed_material != null else _fallback_material
	if source_material is BaseMaterial3D:
		var visible_material := source_material.duplicate() as BaseMaterial3D
		visible_material.emission_enabled = visibility_emission_energy > 0.0
		visible_material.emission = visibility_emission_color
		visible_material.emission_energy_multiplier = visibility_emission_energy
		# A solid emissive color hides the contrast of textured materials when seen
		# through the water. Reusing the albedo texture keeps its sand detail in the
		# visibility boost without changing the source material resource.
		visible_material.emission_texture = visible_material.albedo_texture
		visible_material.cull_mode = (
			BaseMaterial3D.CULL_DISABLED if double_sided else BaseMaterial3D.CULL_BACK
		)
		_display_material = visible_material
	else:
		_display_material = source_material
	_mesh_instance.material_override = _display_material


func _warn_invalid_references_once() -> void:
	if _reference_warning_emitted:
		return
	_reference_warning_emitted = true
	push_warning(
		"SeabedBody3D follow or world-origin reference is invalid; visual continuity may be disabled."
	)


func _get_pattern_name(pattern: SeabedPattern) -> StringName:
	match pattern:
		SeabedPattern.FLAT:
			return &"FLAT"
		SeabedPattern.SOFT_SAND:
			return &"SOFT_SAND"
		SeabedPattern.DUNES:
			return &"DUNES"
		SeabedPattern.ROLLING:
			return &"ROLLING"
		SeabedPattern.ROUGH:
			return &"ROUGH"
		SeabedPattern.CUSTOM:
			return &"CUSTOM"
	return &"SOFT_SAND"
