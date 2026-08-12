@tool
class_name OceanSurface3D
extends Node3D

enum CenterMode {
	CAMERA,
	JET_SKI,
	MIDPOINT,
}

# The red channel carries a compact ring id for the optional shader debug view.
const RING_COLOR_NEAR := Color(0.0, 0.0, 0.0, 1.0)
const RING_COLOR_MIDDLE := Color(0.5, 0.0, 0.0, 1.0)
const RING_COLOR_FAR := Color(1.0, 0.0, 0.0, 1.0)
const MAX_SAFE_ESTIMATED_VERTICES: int = 1_500_000
const DEBUG_CIRCLE_SEGMENTS: int = 128

class MeshBuffers:
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	var colors := PackedColorArray()
	var indices := PackedInt32Array()
	var vertex_lookup: Dictionary = {}
	var ring_color: Color

	func _init(color: Color) -> void:
		ring_color = color

	func add_vertex(point: Vector2) -> int:
		if vertex_lookup.has(point):
			return int(vertex_lookup[point])
		var vertex_index := vertices.size()
		vertices.append(Vector3(point.x, 0.0, point.y))
		normals.append(Vector3.UP)
		uvs.append(point * 0.01)
		colors.append(ring_color)
		vertex_lookup[point] = vertex_index
		return vertex_index

	func add_triangle(point_a: Vector2, point_b: Vector2, point_c: Vector2) -> void:
		var index_a := add_vertex(point_a)
		var index_b := add_vertex(point_b)
		var index_c := add_vertex(point_c)
		var edge_a := vertices[index_b] - vertices[index_a]
		var edge_b := vertices[index_c] - vertices[index_a]
		# Godot's front face for PlaneMesh uses clockwise winding when viewed
		# from above (geometric cross points down while the shading normal is UP).
		if edge_a.cross(edge_b).y > 0.0:
			var swap_index := index_b
			index_b = index_c
			index_c = swap_index
		indices.append(index_a)
		indices.append(index_b)
		indices.append(index_c)

	func add_quad(
		point_a: Vector2,
		point_b: Vector2,
		point_c: Vector2,
		point_d: Vector2
	) -> void:
		add_triangle(point_a, point_b, point_c)
		add_triangle(point_a, point_c, point_d)

	func to_array_mesh(surface_name: StringName) -> ArrayMesh:
		var mesh_arrays: Array = []
		mesh_arrays.resize(Mesh.ARRAY_MAX)
		mesh_arrays[Mesh.ARRAY_VERTEX] = vertices
		mesh_arrays[Mesh.ARRAY_NORMAL] = normals
		mesh_arrays[Mesh.ARRAY_TEX_UV] = uvs
		mesh_arrays[Mesh.ARRAY_COLOR] = colors
		mesh_arrays[Mesh.ARRAY_INDEX] = indices
		var result := ArrayMesh.new()
		result.resource_name = surface_name
		result.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, mesh_arrays)
		result.surface_set_name(0, surface_name)
		return result


@export_group("Target")
@export var follow_target: Node3D
@export var follow_camera: Camera3D
@export var center_mode: CenterMode = CenterMode.CAMERA
@export var fallback_to_active_camera: bool = true

@export_group("Water Source")
@export var ocean: Ocean3D
@export var ocean_material: ShaderMaterial:
	set(value):
		if ocean_material == value:
			return
		ocean_material = value
		_request_material_rebind()
@export var water_level: float = 0.0:
	set(value):
		water_level = value
		_request_uniform_update()

@export_group("Coverage")
@export var near_radius: float = 220.0:
	set(value):
		near_radius = value
		_request_mesh_rebuild()
@export var middle_radius: float = 650.0:
	set(value):
		middle_radius = value
		_request_mesh_rebuild()
@export var far_radius: float = 3000.0:
	set(value):
		far_radius = value
		_request_mesh_rebuild()

@export_group("Resolution")
@export var near_cell_size: float = 2.0:
	set(value):
		near_cell_size = value
		_request_mesh_rebuild()
@export var middle_cell_size: float = 8.0:
	set(value):
		middle_cell_size = value
		_request_mesh_rebuild()
@export var far_cell_size: float = 40.0:
	set(value):
		far_cell_size = value
		_request_mesh_rebuild()

@export_group("Following")
@export var snap_to_grid: bool = true
@export var snap_step: float = 2.0:
	set(value):
		snap_step = value
		_request_uniform_update()
@export var update_in_physics: bool = false:
	set(value):
		update_in_physics = value
		_configure_processing()

@export_group("Wave Detail")
@export var detailed_wave_fade_start: float = 170.0:
	set(value):
		detailed_wave_fade_start = value
		_request_uniform_update()
@export var detailed_wave_fade_end: float = 280.0:
	set(value):
		detailed_wave_fade_end = value
		_request_uniform_update()
@export_range(0.0, 1.0, 0.01) var middle_wave_amplitude_ratio: float = 0.55:
	set(value):
		middle_wave_amplitude_ratio = clampf(value, 0.0, 1.0)
		_request_uniform_update()
@export_range(0.0, 1.0, 0.01) var far_wave_amplitude_ratio: float = 0.08:
	set(value):
		far_wave_amplitude_ratio = clampf(value, 0.0, 1.0)
		_request_uniform_update()

@export_group("Rendering")
@export var cast_shadows: bool = false:
	set(value):
		cast_shadows = value
		_apply_rendering_settings()
@export var extra_cull_margin: float = 8.0:
	set(value):
		extra_cull_margin = maxf(value, 0.0)
		_apply_rendering_settings()
@export var debug_show_rings: bool = false:
	set(value):
		debug_show_rings = value
		_request_uniform_update()
		_update_debug_visibility()
		if debug_show_rings and is_node_ready():
			call_deferred(&"_print_mesh_statistics")
@export var rebuild_preview: bool = false:
	set(value):
		rebuild_preview = false
		if value:
			_request_mesh_rebuild()

var near_vertex_count: int = 0
var middle_vertex_count: int = 0
var far_vertex_count: int = 0
var near_triangle_count: int = 0
var middle_triangle_count: int = 0
var far_triangle_count: int = 0
var snapped_origin_xz := Vector2.ZERO
var logical_origin_offset_xz := Vector2.ZERO
var detail_center_xz := Vector2.ZERO
var effective_near_radius: float = 0.0
var effective_middle_radius: float = 0.0
var effective_far_radius: float = 0.0
var mesh_rebuild_count: int = 0
var _surface_static_uniform_signature: int = -1

@onready var _near_grid: MeshInstance3D = get_node("NearGrid") as MeshInstance3D
@onready var _middle_ring: MeshInstance3D = get_node("MiddleRing") as MeshInstance3D
@onready var _far_ring: MeshInstance3D = get_node("FarRing") as MeshInstance3D
@onready var _debug_root: Node3D = get_node("Debug") as Node3D
@onready var _debug_lines: MeshInstance3D = get_node(
	"Debug/TransitionGuides"
) as MeshInstance3D

var _visual_material: ShaderMaterial
var _registered_ocean: Ocean3D
var _mesh_rebuild_queued: bool = false
var _uniform_update_queued: bool = false
var _warned_missing_material: bool = false
var _has_snapped_origin: bool = false
var _quality_application_active: bool = false


func _enter_tree() -> void:
	if Engine.is_editor_hint():
		call_deferred(&"_ensure_editor_preview")


func _ready() -> void:
	_trace_mark("OCEAN_SURFACE_READY_BEGIN")
	_configure_processing()
	_ensure_meshes()
	_trace_mark("OCEAN_SURFACE_MESHES_ENSURED")
	_bind_visual_material()
	_update_following(true)
	_update_debug_visibility()
	_trace_mark("OCEAN_SURFACE_READY_END")


func _process(_delta: float) -> void:
	if Engine.is_editor_hint() or not update_in_physics:
		_update_following(false)


func _physics_process(_delta: float) -> void:
	if not Engine.is_editor_hint() and update_in_physics:
		_update_following(false)


func _exit_tree() -> void:
	if is_instance_valid(_registered_ocean) and _visual_material != null:
		_registered_ocean.unregister_external_water_material(_visual_material)
	_registered_ocean = null
	if _visual_material != null:
		_visual_material.set_shader_parameter(&"ocean_surface_enabled", false)
		_visual_material.set_shader_parameter(&"ocean_debug_show_rings", false)


func _get_configuration_warnings() -> PackedStringArray:
	var warnings := PackedStringArray()
	if near_radius <= 0.0:
		warnings.append("near_radius must be greater than zero.")
	if middle_radius <= near_radius:
		warnings.append("middle_radius must be greater than near_radius.")
	if far_radius <= middle_radius:
		warnings.append("far_radius must be greater than middle_radius.")
	if near_cell_size <= 0.0 or middle_cell_size <= 0.0 or far_cell_size <= 0.0:
		warnings.append("All cell sizes must be greater than zero.")
	if (
		near_cell_size > 0.0
		and middle_cell_size > 0.0
		and not _is_integer_ratio(middle_cell_size, near_cell_size)
	):
		warnings.append(
			"middle_cell_size must be an integer multiple of near_cell_size "
			+ "for a watertight transition."
		)
	if (
		middle_cell_size > 0.0
		and far_cell_size > 0.0
		and not _is_integer_ratio(far_cell_size, middle_cell_size)
	):
		warnings.append(
			"far_cell_size must be an integer multiple of middle_cell_size "
			+ "for a watertight transition."
		)
	if detailed_wave_fade_end <= detailed_wave_fade_start:
		warnings.append(
			"detailed_wave_fade_end must be greater than detailed_wave_fade_start."
		)
	if snap_to_grid and snap_step <= 0.0:
		warnings.append("snap_step must be greater than zero when snap is enabled.")
	if _estimate_vertex_count() > MAX_SAFE_ESTIMATED_VERTICES:
		warnings.append(
			"The current coverage/resolution combination is estimated to exceed "
			+ "%d vertices." % MAX_SAFE_ESTIMATED_VERTICES
		)
	if ocean == null:
		warnings.append("Assign the Ocean3D used as the physical water provider.")
	var selected_material := _resolve_visual_material()
	if selected_material == null or selected_material.shader == null:
		warnings.append(
			"Assign a persistent ShaderMaterial for the selected water render mode."
		)
	if follow_camera == null and follow_target == null and not fallback_to_active_camera:
		warnings.append("Assign a camera or target, or enable the active-camera fallback.")
	for node_name in [&"NearGrid", &"MiddleRing", &"FarRing"]:
		var mesh_instance := get_node_or_null(NodePath(node_name)) as MeshInstance3D
		if mesh_instance == null or mesh_instance.mesh == null:
			warnings.append("%s has no generated mesh." % node_name)
	return warnings


func get_total_vertex_count() -> int:
	return near_vertex_count + middle_vertex_count + far_vertex_count


func get_total_triangle_count() -> int:
	return near_triangle_count + middle_triangle_count + far_triangle_count


func get_estimated_draw_call_count() -> int:
	return 3


func get_debug_status() -> Dictionary:
	return {
		"detail_center_xz": detail_center_xz,
		"snapped_origin_xz": snapped_origin_xz,
		"logical_origin_offset_xz": logical_origin_offset_xz,
		"effective_radii": Vector3(
			effective_near_radius,
			effective_middle_radius,
			effective_far_radius
		),
		"vertices": Vector3i(
			near_vertex_count,
			middle_vertex_count,
			far_vertex_count
		),
		"triangles": Vector3i(
			near_triangle_count,
			middle_triangle_count,
			far_triangle_count
		),
		"draw_calls": get_estimated_draw_call_count(),
		"mesh_rebuild_count": mesh_rebuild_count,
	}


func set_graphics_quality(
	_level: int,
	profile: GraphicsQualityProfile
) -> void:
	if profile == null:
		return
	_quality_application_active = true
	near_radius = profile.ocean_near_radius
	near_cell_size = profile.ocean_near_cell_size
	middle_radius = profile.ocean_middle_radius
	middle_cell_size = profile.ocean_middle_cell_size
	far_radius = profile.ocean_far_radius
	far_cell_size = profile.ocean_far_cell_size
	snap_step = profile.ocean_snap_step
	detailed_wave_fade_start = profile.ocean_detailed_wave_fade_start
	detailed_wave_fade_end = profile.ocean_detailed_wave_fade_end
	middle_wave_amplitude_ratio = profile.ocean_middle_wave_amplitude_ratio
	far_wave_amplitude_ratio = profile.ocean_far_wave_amplitude_ratio
	_quality_application_active = false
	_mesh_rebuild_queued = false
	if not _structural_parameters_are_valid():
		push_error("OceanSurface3D: rejected invalid graphics-quality geometry.")
		return
	if is_node_ready():
		_rebuild_meshes()
	else:
		_request_mesh_rebuild()


func get_graphics_quality_debug_status() -> Dictionary:
	var status := get_debug_status()
	status.merge(
		{
			"near_radius": near_radius,
			"near_cell_size": near_cell_size,
			"middle_radius": middle_radius,
			"middle_cell_size": middle_cell_size,
			"far_radius": far_radius,
			"far_cell_size": far_cell_size,
		},
		true
	)
	return status


func rebuild_meshes() -> void:
	_rebuild_meshes()


func _request_mesh_rebuild() -> void:
	if Engine.is_editor_hint():
		update_configuration_warnings()
	if _quality_application_active:
		return
	if not is_inside_tree() or _mesh_rebuild_queued:
		return
	_mesh_rebuild_queued = true
	call_deferred(&"_flush_requested_mesh_rebuild")


func _request_uniform_update() -> void:
	if Engine.is_editor_hint():
		update_configuration_warnings()
	if not is_inside_tree() or _uniform_update_queued:
		return
	_uniform_update_queued = true
	call_deferred(&"_flush_uniform_update")


func _request_material_rebind() -> void:
	if Engine.is_editor_hint():
		update_configuration_warnings()
	if not is_inside_tree():
		return
	call_deferred(&"_bind_visual_material")


func _ensure_editor_preview() -> void:
	if not Engine.is_editor_hint() or not is_node_ready():
		return
	_ensure_meshes()
	_bind_visual_material()
	_update_following(true)
	_apply_rendering_settings()
	update_configuration_warnings()


func _ensure_meshes() -> void:
	if (
		_near_grid == null
		or _middle_ring == null
		or _far_ring == null
	):
		return
	if (
		_near_grid.mesh == null
		or _middle_ring.mesh == null
		or _far_ring.mesh == null
	):
		_rebuild_meshes()
	else:
		_apply_rendering_settings()


func _flush_uniform_update() -> void:
	_uniform_update_queued = false
	_update_material_uniforms(true)
	_build_debug_guides()


func _flush_requested_mesh_rebuild() -> void:
	if not _mesh_rebuild_queued:
		return
	_rebuild_meshes()


func _configure_processing() -> void:
	if not is_inside_tree():
		return
	set_process(Engine.is_editor_hint() or not update_in_physics)
	set_physics_process(not Engine.is_editor_hint() and update_in_physics)


func _rebuild_meshes() -> void:
	_trace_mark("OCEAN_MESH_REBUILD_BEGIN #%d" % (mesh_rebuild_count + 1))
	_mesh_rebuild_queued = false
	if (
		_near_grid == null
		or _middle_ring == null
		or _far_ring == null
		or not _structural_parameters_are_valid()
	):
		return
	if _estimate_vertex_count() > MAX_SAFE_ESTIMATED_VERTICES:
		push_error(
			"OceanSurface3D: refusing to build an unsafe mesh estimate above %d vertices."
			% MAX_SAFE_ESTIMATED_VERTICES
		)
		return
	mesh_rebuild_count += 1

	effective_near_radius = _ceil_to_step(near_radius, middle_cell_size)
	effective_middle_radius = _ceil_to_step(middle_radius, far_cell_size)
	effective_far_radius = _ceil_to_step(far_radius, far_cell_size)
	effective_middle_radius = maxf(
		effective_middle_radius,
		effective_near_radius + middle_cell_size * 2.0
	)
	effective_far_radius = maxf(
		effective_far_radius,
		effective_middle_radius + far_cell_size * 2.0
	)

	var near_buffers := MeshBuffers.new(RING_COLOR_NEAR)
	_append_full_grid(
		near_buffers,
		effective_near_radius,
		near_cell_size
	)
	_near_grid.mesh = near_buffers.to_array_mesh(&"NearGrid")
	near_vertex_count = near_buffers.vertices.size()
	near_triangle_count = floori(float(near_buffers.indices.size()) / 3.0)

	var middle_buffers := MeshBuffers.new(RING_COLOR_MIDDLE)
	var middle_transition_outer := effective_near_radius + middle_cell_size
	_append_coarse_ring(
		middle_buffers,
		effective_middle_radius,
		middle_transition_outer,
		middle_cell_size
	)
	_append_transition_ring(
		middle_buffers,
		effective_near_radius,
		near_cell_size,
		middle_cell_size
	)
	_middle_ring.mesh = middle_buffers.to_array_mesh(&"MiddleRing")
	middle_vertex_count = middle_buffers.vertices.size()
	middle_triangle_count = floori(float(middle_buffers.indices.size()) / 3.0)

	var far_buffers := MeshBuffers.new(RING_COLOR_FAR)
	var far_transition_outer := effective_middle_radius + far_cell_size
	_append_coarse_ring(
		far_buffers,
		effective_far_radius,
		far_transition_outer,
		far_cell_size
	)
	_append_transition_ring(
		far_buffers,
		effective_middle_radius,
		middle_cell_size,
		far_cell_size
	)
	_far_ring.mesh = far_buffers.to_array_mesh(&"FarRing")
	far_vertex_count = far_buffers.vertices.size()
	far_triangle_count = floori(float(far_buffers.indices.size()) / 3.0)

	_apply_rendering_settings()
	_bind_visual_material()
	_update_material_uniforms(true)
	_build_debug_guides()
	if debug_show_rings:
		_print_mesh_statistics()
	_trace_mark("OCEAN_MESH_REBUILD_END #%d" % mesh_rebuild_count)


func _trace_mark(label: String) -> void:
	if not Engine.is_editor_hint():
		LoadTrace.mark(label)

func _append_full_grid(
	buffers: MeshBuffers,
	half_extent: float,
	cell_size: float
) -> void:
	var segment_count := maxi(1, int(round(half_extent * 2.0 / cell_size)))
	for z_index in segment_count:
		var z_0 := -half_extent + float(z_index) * cell_size
		var z_1 := z_0 + cell_size
		for x_index in segment_count:
			var x_0 := -half_extent + float(x_index) * cell_size
			var x_1 := x_0 + cell_size
			buffers.add_quad(
				Vector2(x_0, z_0),
				Vector2(x_1, z_0),
				Vector2(x_1, z_1),
				Vector2(x_0, z_1)
			)


func _append_coarse_ring(
	buffers: MeshBuffers,
	outer_half_extent: float,
	hole_half_extent: float,
	cell_size: float
) -> void:
	var segment_count := maxi(
		1,
		int(round(outer_half_extent * 2.0 / cell_size))
	)
	var epsilon := cell_size * 0.001
	for z_index in segment_count:
		var z_0 := -outer_half_extent + float(z_index) * cell_size
		var z_1 := z_0 + cell_size
		for x_index in segment_count:
			var x_0 := -outer_half_extent + float(x_index) * cell_size
			var x_1 := x_0 + cell_size
			var inside_hole := (
				x_0 >= -hole_half_extent - epsilon
				and x_1 <= hole_half_extent + epsilon
				and z_0 >= -hole_half_extent - epsilon
				and z_1 <= hole_half_extent + epsilon
			)
			if inside_hole:
				continue
			buffers.add_quad(
				Vector2(x_0, z_0),
				Vector2(x_1, z_0),
				Vector2(x_1, z_1),
				Vector2(x_0, z_1)
			)


func _append_transition_ring(
	buffers: MeshBuffers,
	inner_half_extent: float,
	fine_cell_size: float,
	coarse_cell_size: float
) -> void:
	var outer_half_extent := inner_half_extent + coarse_cell_size
	var fine_positions := _axis_positions(
		-inner_half_extent,
		inner_half_extent,
		fine_cell_size
	)
	var coarse_positions := _axis_positions(
		-inner_half_extent,
		inner_half_extent,
		coarse_cell_size
	)

	_connect_transition_polylines(
		buffers,
		_horizontal_polyline(fine_positions, -inner_half_extent),
		_horizontal_polyline(coarse_positions, -outer_half_extent)
	)
	_connect_transition_polylines(
		buffers,
		_horizontal_polyline(fine_positions, inner_half_extent),
		_horizontal_polyline(coarse_positions, outer_half_extent)
	)
	_connect_transition_polylines(
		buffers,
		_vertical_polyline(fine_positions, -inner_half_extent),
		_vertical_polyline(coarse_positions, -outer_half_extent)
	)
	_connect_transition_polylines(
		buffers,
		_vertical_polyline(fine_positions, inner_half_extent),
		_vertical_polyline(coarse_positions, outer_half_extent)
	)

	buffers.add_quad(
		Vector2(-outer_half_extent, -outer_half_extent),
		Vector2(-inner_half_extent, -outer_half_extent),
		Vector2(-inner_half_extent, -inner_half_extent),
		Vector2(-outer_half_extent, -inner_half_extent)
	)
	buffers.add_quad(
		Vector2(inner_half_extent, -outer_half_extent),
		Vector2(outer_half_extent, -outer_half_extent),
		Vector2(outer_half_extent, -inner_half_extent),
		Vector2(inner_half_extent, -inner_half_extent)
	)
	buffers.add_quad(
		Vector2(-outer_half_extent, inner_half_extent),
		Vector2(-inner_half_extent, inner_half_extent),
		Vector2(-inner_half_extent, outer_half_extent),
		Vector2(-outer_half_extent, outer_half_extent)
	)
	buffers.add_quad(
		Vector2(inner_half_extent, inner_half_extent),
		Vector2(outer_half_extent, inner_half_extent),
		Vector2(outer_half_extent, outer_half_extent),
		Vector2(inner_half_extent, outer_half_extent)
	)


func _connect_transition_polylines(
	buffers: MeshBuffers,
	fine_points: PackedVector2Array,
	coarse_points: PackedVector2Array
) -> void:
	var fine_index: int = 0
	var coarse_index: int = 0
	var fine_last := fine_points.size() - 1
	var coarse_last := coarse_points.size() - 1
	while fine_index < fine_last or coarse_index < coarse_last:
		var next_fine_t := (
			float(fine_index + 1) / float(fine_last)
			if fine_index < fine_last
			else INF
		)
		var next_coarse_t := (
			float(coarse_index + 1) / float(coarse_last)
			if coarse_index < coarse_last
			else INF
		)
		if is_equal_approx(next_fine_t, next_coarse_t):
			buffers.add_triangle(
				fine_points[fine_index],
				fine_points[fine_index + 1],
				coarse_points[coarse_index]
			)
			buffers.add_triangle(
				fine_points[fine_index + 1],
				coarse_points[coarse_index + 1],
				coarse_points[coarse_index]
			)
			fine_index += 1
			coarse_index += 1
		elif next_fine_t < next_coarse_t:
			buffers.add_triangle(
				fine_points[fine_index],
				fine_points[fine_index + 1],
				coarse_points[coarse_index]
			)
			fine_index += 1
		else:
			buffers.add_triangle(
				fine_points[fine_index],
				coarse_points[coarse_index + 1],
				coarse_points[coarse_index]
			)
			coarse_index += 1


func _axis_positions(start: float, end: float, step: float) -> PackedFloat32Array:
	var result := PackedFloat32Array()
	var segment_count := maxi(1, int(round((end - start) / step)))
	for index in range(segment_count + 1):
		result.append(start + float(index) * (end - start) / float(segment_count))
	return result


func _horizontal_polyline(
	axis_positions: PackedFloat32Array,
	z_position: float
) -> PackedVector2Array:
	var result := PackedVector2Array()
	for x_position in axis_positions:
		result.append(Vector2(x_position, z_position))
	return result


func _vertical_polyline(
	axis_positions: PackedFloat32Array,
	x_position: float
) -> PackedVector2Array:
	var result := PackedVector2Array()
	for z_position in axis_positions:
		result.append(Vector2(x_position, z_position))
	return result


func _bind_visual_material() -> void:
	var candidate := _resolve_visual_material()
	if candidate == null:
		if not Engine.is_editor_hint() and not _warned_missing_material:
			push_warning(
				"OceanSurface3D: waiting for its persistent ocean ShaderMaterial."
			)
		_warned_missing_material = true
		return

	_warned_missing_material = false

	var material_changed := candidate != _visual_material
	var ocean_changed := _registered_ocean != ocean
	if not material_changed and not ocean_changed:
		return

	if is_instance_valid(_registered_ocean) and _visual_material != null:
		_registered_ocean.unregister_external_water_material(_visual_material)

	if material_changed:
		if _visual_material != null:
			_visual_material.set_shader_parameter(&"ocean_surface_enabled", false)
			_visual_material.set_shader_parameter(&"ocean_debug_show_rings", false)

		_visual_material = candidate
		_surface_static_uniform_signature = -1

		for mesh_instance in _ocean_mesh_instances():
			mesh_instance.material_override = _visual_material

	_registered_ocean = ocean

	if is_instance_valid(_registered_ocean):
		_registered_ocean.register_external_water_material(_visual_material)

	_update_material_uniforms(true)


func _resolve_visual_material() -> ShaderMaterial:
	return ocean_material


func _update_following(force_update: bool) -> void:
	_bind_visual_material()
	var center_node := _resolve_center_node()
	if center_node == null:
		return
	var target_position := center_node.global_position
	if (
		center_mode == CenterMode.MIDPOINT
		and is_instance_valid(follow_camera)
		and is_instance_valid(follow_target)
	):
		target_position = (
			follow_camera.global_position + follow_target.global_position
		) * 0.5
	detail_center_xz = Vector2(target_position.x, target_position.z)
	var next_origin := detail_center_xz
	if snap_to_grid and snap_step > 0.0:
		next_origin.x = snappedf(next_origin.x, snap_step)
		next_origin.y = snappedf(next_origin.y, snap_step)
	var resolved_water_level := water_level
	if is_instance_valid(ocean):
		resolved_water_level = ocean.water_level
		if not is_equal_approx(water_level, resolved_water_level):
			water_level = resolved_water_level
	var water_level_changed := not is_equal_approx(
		global_position.y,
		resolved_water_level
	)
	if (
		force_update
		or not _has_snapped_origin
		or next_origin != snapped_origin_xz
		or water_level_changed
	):
		snapped_origin_xz = next_origin
		_has_snapped_origin = true
		global_position = Vector3(
			snapped_origin_xz.x,
			resolved_water_level,
			snapped_origin_xz.y
		)
		reset_physics_interpolation()
	if is_instance_valid(ocean):
		logical_origin_offset_xz = ocean.get_logical_origin_offset_xz()
	if _debug_root != null:
		_debug_root.position = Vector3(
			detail_center_xz.x - snapped_origin_xz.x,
			0.0,
			detail_center_xz.y - snapped_origin_xz.y
		)
	_update_material_uniforms()


func _resolve_center_node() -> Node3D:
	match center_mode:
		CenterMode.JET_SKI:
			if is_instance_valid(follow_target):
				return follow_target
			if is_instance_valid(follow_camera):
				return follow_camera
		CenterMode.MIDPOINT:
			if is_instance_valid(follow_camera):
				return follow_camera
			if is_instance_valid(follow_target):
				return follow_target
		_:
			if is_instance_valid(follow_camera):
				return follow_camera
			if is_instance_valid(follow_target):
				return follow_target
	if fallback_to_active_camera and get_viewport() != null:
		return get_viewport().get_camera_3d()
	return null


func _update_material_uniforms(force_static: bool = false) -> void:
	_uniform_update_queued = false
	if _visual_material == null:
		return

	var resolved_water_level := water_level
	if is_instance_valid(ocean):
		resolved_water_level = ocean.water_level

	# Parámetros dinámicos de la superficie.
	_visual_material.set_shader_parameter(&"water_level", resolved_water_level)
	_visual_material.set_shader_parameter(
		&"ocean_logical_origin_offset_xz",
		logical_origin_offset_xz
	)
	_visual_material.set_shader_parameter(
		&"ocean_detail_center_xz",
		detail_center_xz
	)

	var static_signature := hash([
		detailed_wave_fade_start,
		detailed_wave_fade_end,
		effective_middle_radius,
		middle_wave_amplitude_ratio,
		far_wave_amplitude_ratio,
		debug_show_rings,
	])

	if (
		not force_static
		and static_signature == _surface_static_uniform_signature
	):
		return

	_surface_static_uniform_signature = static_signature

	_visual_material.set_shader_parameter(&"ocean_surface_enabled", true)
	_visual_material.set_shader_parameter(
		&"ocean_detailed_wave_fade_start",
		detailed_wave_fade_start
	)
	_visual_material.set_shader_parameter(
		&"ocean_detailed_wave_fade_end",
		detailed_wave_fade_end
	)
	_visual_material.set_shader_parameter(
		&"ocean_medium_wave_fade_end",
		maxf(effective_middle_radius, detailed_wave_fade_end + 1.0)
	)
	_visual_material.set_shader_parameter(
		&"ocean_middle_wave_amplitude_ratio",
		middle_wave_amplitude_ratio
	)
	_visual_material.set_shader_parameter(
		&"ocean_far_wave_amplitude_ratio",
		far_wave_amplitude_ratio
	)
	_visual_material.set_shader_parameter(
		&"ocean_debug_show_rings",
		debug_show_rings
	)


func _apply_rendering_settings() -> void:
	if not is_node_ready():
		return
	var shadow_setting := (
		GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		if cast_shadows
		else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	)
	var vertical_margin := maxf(extra_cull_margin, 4.0)
	for mesh_instance in _ocean_mesh_instances():
		mesh_instance.cast_shadow = shadow_setting
		mesh_instance.extra_cull_margin = extra_cull_margin
		var mesh_half_extent := effective_far_radius
		if mesh_instance == _near_grid:
			mesh_half_extent = effective_near_radius
		elif mesh_instance == _middle_ring:
			mesh_half_extent = effective_middle_radius
		mesh_instance.custom_aabb = AABB(
			Vector3(-mesh_half_extent, -vertical_margin, -mesh_half_extent),
			Vector3(
				mesh_half_extent * 2.0,
				vertical_margin * 2.0,
				mesh_half_extent * 2.0
			)
		)


func _ocean_mesh_instances() -> Array[MeshInstance3D]:
	var result: Array[MeshInstance3D] = []
	if _near_grid != null:
		result.append(_near_grid)
	if _middle_ring != null:
		result.append(_middle_ring)
	if _far_ring != null:
		result.append(_far_ring)
	return result


func _build_debug_guides() -> void:
	if _debug_lines == null:
		return
	if not debug_show_rings:
		_debug_lines.mesh = null
		return
	var immediate_mesh := ImmediateMesh.new()
	var debug_material := StandardMaterial3D.new()
	debug_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	debug_material.albedo_color = Color(1.0, 0.92, 0.15, 1.0)
	immediate_mesh.surface_begin(Mesh.PRIMITIVE_LINES, debug_material)
	_append_debug_circle(immediate_mesh, detailed_wave_fade_start)
	_append_debug_circle(immediate_mesh, detailed_wave_fade_end)
	var cross_size := maxf(snap_step * 2.0, 2.0)
	immediate_mesh.surface_add_vertex(Vector3(-cross_size, 0.12, 0.0))
	immediate_mesh.surface_add_vertex(Vector3(cross_size, 0.12, 0.0))
	immediate_mesh.surface_add_vertex(Vector3(0.0, 0.12, -cross_size))
	immediate_mesh.surface_add_vertex(Vector3(0.0, 0.12, cross_size))
	immediate_mesh.surface_end()
	_debug_lines.mesh = immediate_mesh


func _append_debug_circle(mesh: ImmediateMesh, radius: float) -> void:
	if radius <= 0.0:
		return
	for index in DEBUG_CIRCLE_SEGMENTS:
		var angle_a := TAU * float(index) / float(DEBUG_CIRCLE_SEGMENTS)
		var angle_b := TAU * float(index + 1) / float(DEBUG_CIRCLE_SEGMENTS)
		mesh.surface_add_vertex(
			Vector3(cos(angle_a) * radius, 0.12, sin(angle_a) * radius)
		)
		mesh.surface_add_vertex(
			Vector3(cos(angle_b) * radius, 0.12, sin(angle_b) * radius)
		)


func _update_debug_visibility() -> void:
	if _debug_root != null:
		_debug_root.visible = debug_show_rings


func _print_mesh_statistics() -> void:
	print(
		"OceanSurface3D: Near ",
		near_vertex_count,
		" vertices / ",
		near_triangle_count,
		" triangles; Middle ",
		middle_vertex_count,
		" / ",
		middle_triangle_count,
		"; Far ",
		far_vertex_count,
		" / ",
		far_triangle_count,
		"; total ",
		get_total_vertex_count(),
		" / ",
		get_total_triangle_count(),
		"; 3 draw calls; detail center=",
		detail_center_xz,
		"; snapped origin=",
		snapped_origin_xz,
		"; logical offset=",
		logical_origin_offset_xz,
		"; radii=",
		Vector3(
			effective_near_radius,
			effective_middle_radius,
			effective_far_radius
		),
		"."
	)


func _structural_parameters_are_valid() -> bool:
	return (
		near_radius > 0.0
		and middle_radius > near_radius
		and far_radius > middle_radius
		and near_cell_size > 0.0
		and middle_cell_size > 0.0
		and far_cell_size > 0.0
		and _is_integer_ratio(middle_cell_size, near_cell_size)
		and _is_integer_ratio(far_cell_size, middle_cell_size)
	)


func _is_integer_ratio(larger_value: float, smaller_value: float) -> bool:
	if larger_value <= 0.0 or smaller_value <= 0.0:
		return false
	var ratio := larger_value / smaller_value
	return is_equal_approx(ratio, roundf(ratio))


func _ceil_to_step(value: float, step: float) -> float:
	if step <= 0.0:
		return value
	return ceilf(value / step) * step


func _estimate_vertex_count() -> int:
	if near_cell_size <= 0.0 or middle_cell_size <= 0.0 or far_cell_size <= 0.0:
		return MAX_SAFE_ESTIMATED_VERTICES + 1
	var near_segments: int = ceili(near_radius * 2.0 / near_cell_size) + 1
	var middle_segments: int = ceili(
		middle_radius * 2.0 / middle_cell_size
	) + 1
	var far_segments: int = ceili(far_radius * 2.0 / far_cell_size) + 1
	return (
		near_segments * near_segments
		+ middle_segments * middle_segments
		+ far_segments * far_segments
	)
