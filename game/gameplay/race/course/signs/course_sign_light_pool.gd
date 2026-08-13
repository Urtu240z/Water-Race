class_name CourseSignLightPool
extends Node3D

## Reuses a small number of shadowless OmniLight3D nodes around the rider.
## Sign shaders keep using TIME; this manager only mirrors their sine pulse.

const ARROW_SIGN_GROUP: StringName = &"course_emissive_arrow_sign"
const WRONG_SIGN_GROUP: StringName = &"course_emissive_wrong_sign"
const MEDIUM_QUALITY_LEVEL: int = 1
const HIGH_QUALITY_LEVEL: int = 2


class SignRecord:
	extends RefCounted

	var root: Node3D
	var mesh_instance: MeshInstance3D
	var surface_index: int = 0
	var vertices: PackedVector3Array = PackedVector3Array()
	var indices: PackedInt32Array = PackedInt32Array()
	var primitive_type: Mesh.PrimitiveType = Mesh.PRIMITIVE_TRIANGLES
	var material: ShaderMaterial
	var light_color: Color = Color.WHITE
	var light_energy_multiplier: float = 1.0
	var minimum_light_energy: float = 0.0
	var maximum_light_energy: float = 1.0
	var pulse_speed: float = 1.0


@export_group("References")
@export_node_path("Node3D") var vehicle_path: NodePath

@export_group("Pool")
@export_range(1, 8, 1) var maximum_pool_size: int = 4
@export_range(0, 8, 1) var medium_quality_pool_size: int = 2
@export var enable_on_low_quality: bool = false
@export_range(1.0, 120.0, 0.5, "suffix:m") var activation_distance: float = 30.0
@export_range(1.0, 60.0, 1.0, "suffix:Hz") var selection_update_rate_hz: float = 12.0

@export_group("Light Shape")
@export_range(0.1, 50.0, 0.1, "suffix:m") var light_range: float = 13.0
@export_range(0.0, 4.0, 0.01) var light_attenuation: float = 1.15
@export_range(0.0, 4.0, 0.05, "suffix:m") var surface_offset: float = 0.75
@export_range(0.0, 1.0, 0.01) var light_specular: float = 0.65
@export_range(0.0, 1.0, 0.01) var volumetric_fog_energy: float = 0.12

@export_group("Light Smoothing")
## Keeps the shader pulse visible while preventing transparent spray from flashing.
@export_range(0.0, 1.0, 0.01) var light_pulse_influence: float = 0.15
@export_range(0.0, 60.0, 0.5) var position_smoothing_speed: float = 20.0
@export_range(0.0, 60.0, 0.5) var energy_smoothing_speed: float = 16.0
@export_range(0.1, 20.0, 0.1) var activation_fade_speed: float = 6.0

@export_group("Arrow Light")
@export var arrow_light_color: Color = Color(1.0, 0.62, 0.08)
@export_range(0.0, 4.0, 0.01) var arrow_light_energy_multiplier: float = 0.45
@export_range(0.1, 10.0, 0.01, "suffix:s") var arrow_pulse_period: float = 1.4

@export_group("Wrong Light")
@export var wrong_light_color: Color = Color(1.0, 0.055, 0.02)
@export_range(0.0, 4.0, 0.01) var wrong_light_energy_multiplier: float = 0.5
@export_range(0.1, 10.0, 0.01, "suffix:s") var wrong_pulse_period: float = 0.8

var _vehicle: Node3D
var _signs: Array[SignRecord] = []
var _slots: Array[Dictionary] = []
var _selection_elapsed: float = 0.0
var _active_light_limit: int = 0
var _rescan_queued: bool = false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_resolve_vehicle()
	_create_light_pool()
	_rebuild_sign_records()
	_connect_runtime_sign_discovery()
	_connect_quality_manager()
	_apply_current_quality()
	_refresh_light_assignments()


func _process(delta: float) -> void:
	if not is_instance_valid(_vehicle):
		_resolve_vehicle()
	if not is_instance_valid(_vehicle):
		_deactivate_all_slots()
		_update_lights(delta)
		return

	_selection_elapsed += maxf(delta, 0.0)
	var update_interval := 1.0 / maxf(selection_update_rate_hz, 1.0)
	if _selection_elapsed >= update_interval:
		_selection_elapsed = fmod(_selection_elapsed, update_interval)
		_refresh_light_assignments()
	_update_lights(delta)


func force_refresh() -> void:
	_rebuild_sign_records()
	_refresh_light_assignments()
	_update_lights(0.0)


func get_registered_sign_count() -> int:
	return _signs.size()


func get_pool_light_count() -> int:
	return _slots.size()


func get_active_light_count() -> int:
	var count := 0
	for slot: Dictionary in _slots:
		var light := slot.get("light") as OmniLight3D
		if is_instance_valid(light) and light.visible:
			count += 1
	return count


func _resolve_vehicle() -> void:
	_vehicle = get_node_or_null(vehicle_path) as Node3D


func _create_light_pool() -> void:
	for slot: Dictionary in _slots:
		var old_light := slot.get("light") as OmniLight3D
		if is_instance_valid(old_light):
			old_light.queue_free()
	_slots.clear()
	for index in maximum_pool_size:
		var light := OmniLight3D.new()
		light.name = "PooledSignLight%d" % (index + 1)
		light.omni_range = light_range
		light.omni_attenuation = light_attenuation
		light.light_specular = light_specular
		light.light_indirect_energy = 0.0
		light.light_volumetric_fog_energy = volumetric_fog_energy
		light.light_bake_mode = Light3D.BAKE_DISABLED
		light.shadow_enabled = false
		light.visible = false
		add_child(light)
		_slots.append(
			{
				"light": light,
				"sign": null,
				"target_active": false,
				"fade": 0.0,
			}
		)


func _rebuild_sign_records() -> void:
	_signs.clear()
	_register_group_signs(ARROW_SIGN_GROUP, false)
	_register_group_signs(WRONG_SIGN_GROUP, true)


func _register_group_signs(group: StringName, is_wrong_sign: bool) -> void:
	for candidate: Node in get_tree().get_nodes_in_group(group):
		var sign_root := candidate as Node3D
		if sign_root == null:
			continue
		var mesh_instance := sign_root.find_child("*_VIS", true, false) as MeshInstance3D
		if mesh_instance == null or mesh_instance.mesh == null:
			continue
		var surface_index := 0 if is_wrong_sign else 1
		if surface_index >= mesh_instance.mesh.get_surface_count():
			continue
		var arrays := mesh_instance.mesh.surface_get_arrays(surface_index)
		if arrays.is_empty():
			continue
		var vertices_value: Variant = arrays[Mesh.ARRAY_VERTEX]
		if not vertices_value is PackedVector3Array:
			continue

		var record := SignRecord.new()
		record.root = sign_root
		record.mesh_instance = mesh_instance
		record.surface_index = surface_index
		record.vertices = vertices_value as PackedVector3Array
		record.material = mesh_instance.get_active_material(
			surface_index
		) as ShaderMaterial
		var indices_value: Variant = arrays[Mesh.ARRAY_INDEX]
		if indices_value is PackedInt32Array:
			record.indices = indices_value as PackedInt32Array
		record.primitive_type = mesh_instance.mesh.surface_get_primitive_type(
			surface_index
		)
		if is_wrong_sign:
			record.light_color = wrong_light_color
			record.light_energy_multiplier = wrong_light_energy_multiplier
			record.minimum_light_energy = 2.0 * wrong_light_energy_multiplier
			record.maximum_light_energy = 16.0 * wrong_light_energy_multiplier
			record.pulse_speed = TAU / maxf(wrong_pulse_period, 0.001)
		else:
			record.light_color = arrow_light_color
			record.light_energy_multiplier = arrow_light_energy_multiplier
			record.minimum_light_energy = 4.0 * arrow_light_energy_multiplier
			record.maximum_light_energy = 12.0 * arrow_light_energy_multiplier
			record.pulse_speed = TAU / maxf(arrow_pulse_period, 0.001)
		_sync_record_with_material(record)
		_signs.append(record)


func _refresh_light_assignments() -> void:
	if not is_instance_valid(_vehicle) or _active_light_limit <= 0:
		_deactivate_all_slots()
		return
	var maximum_distance_squared := activation_distance * activation_distance
	var vehicle_position := _vehicle.global_position
	var candidates: Array[Dictionary] = []
	for sign_record: SignRecord in _signs:
		if not is_instance_valid(sign_record.root) or not is_instance_valid(sign_record.mesh_instance):
			continue
		var surface_point := _closest_surface_point(sign_record, vehicle_position)
		var distance_squared := vehicle_position.distance_squared_to(surface_point)
		if distance_squared <= maximum_distance_squared:
			candidates.append(
				{
					"sign": sign_record,
					"surface_point": surface_point,
					"distance_squared": distance_squared,
				}
			)
	candidates.sort_custom(_sort_candidates_by_distance)

	var usable_count := mini(
		mini(_active_light_limit, _slots.size()),
		candidates.size()
	)
	var selected_signs: Array[SignRecord] = []
	var selected_points: Dictionary = {}
	for candidate_index in usable_count:
		var selected: Dictionary = candidates[candidate_index]
		var selected_sign := selected.get("sign") as SignRecord
		selected_signs.append(selected_sign)
		var selected_point: Vector3 = selected.get("surface_point")
		selected_points[selected_sign] = selected_point

	# Keep stable assignments so two nearby signs cannot make their lights swap.
	for slot: Dictionary in _slots:
		var assigned_sign := slot.get("sign") as SignRecord
		slot["target_active"] = (
			assigned_sign != null and assigned_sign in selected_signs
		)

	for selected_sign: SignRecord in selected_signs:
		if not _find_slot_for_sign(selected_sign).is_empty():
			continue
		var available_slot := _find_available_slot(selected_signs)
		if available_slot.is_empty():
			continue
		var first_point: Vector3 = selected_points.get(
			selected_sign,
			selected_sign.root.global_position
		)
		_activate_slot(available_slot, selected_sign, first_point, vehicle_position)


func _update_lights(delta: float) -> void:
	var global_time := Time.get_ticks_msec() * 0.001
	for slot: Dictionary in _slots:
		var light := slot.get("light") as OmniLight3D
		var sign_record := slot.get("sign") as SignRecord
		if not is_instance_valid(light):
			continue
		var target_active := bool(slot.get("target_active", false))
		if sign_record == null or not is_instance_valid(sign_record.root):
			target_active = false
			slot["target_active"] = false

		var target_fade := 1.0 if target_active else 0.0
		var fade := move_toward(
			float(slot.get("fade", 0.0)),
			target_fade,
			maxf(delta, 0.0) * activation_fade_speed
		)
		slot["fade"] = fade
		if sign_record == null:
			light.visible = false
			continue
		if not target_active and is_zero_approx(fade):
			light.light_energy = 0.0
			light.visible = false
			slot["sign"] = null
			continue

		light.visible = true
		light.shadow_enabled = false
		if target_active and is_instance_valid(_vehicle):
			var desired_position := _light_position_for_sign(
				sign_record,
				_vehicle.global_position
			)
			var position_weight := _exponential_weight(
				position_smoothing_speed,
				delta
			)
			light.global_position = light.global_position.lerp(
				desired_position,
				position_weight
			)

		_sync_record_with_material(sign_record)
		var average_energy := (
			sign_record.minimum_light_energy + sign_record.maximum_light_energy
		) * 0.5
		var pulse_amplitude := (
			sign_record.maximum_light_energy - sign_record.minimum_light_energy
		) * 0.5 * light_pulse_influence
		var target_energy := maxf(
			average_energy
			+ sin(global_time * sign_record.pulse_speed) * pulse_amplitude,
			0.0
		)
		var energy_weight := _exponential_weight(energy_smoothing_speed, delta)
		light.light_energy = lerpf(
			light.light_energy,
			target_energy * fade,
			energy_weight
		)


func _find_slot_for_sign(sign_record: SignRecord) -> Dictionary:
	for slot: Dictionary in _slots:
		if slot.get("sign") == sign_record:
			slot["target_active"] = true
			return slot
	return {}


func _find_available_slot(selected_signs: Array[SignRecord]) -> Dictionary:
	for slot: Dictionary in _slots:
		if slot.get("sign") == null:
			return slot
	for slot: Dictionary in _slots:
		var assigned_sign := slot.get("sign") as SignRecord
		if assigned_sign not in selected_signs:
			return slot
	return {}


func _activate_slot(
	slot: Dictionary,
	sign_record: SignRecord,
	surface_point: Vector3,
	vehicle_position: Vector3
) -> void:
	var light := slot.get("light") as OmniLight3D
	if not is_instance_valid(light):
		return
	var first_position := _offset_surface_point(surface_point, vehicle_position)
	slot["sign"] = sign_record
	slot["target_active"] = true
	slot["fade"] = 0.0
	light.global_position = first_position
	light.light_color = sign_record.light_color
	light.light_energy = 0.0
	light.shadow_enabled = false
	light.visible = true


func _light_position_for_sign(
	sign_record: SignRecord,
	vehicle_position: Vector3
) -> Vector3:
	var mesh_aabb := sign_record.mesh_instance.mesh.get_aabb()
	var sign_center_world := sign_record.mesh_instance.to_global(
		mesh_aabb.get_center()
	)

	var tracking_point := vehicle_position
	tracking_point.y = sign_center_world.y

	var surface_point := _closest_surface_point(
		sign_record,
		tracking_point
	)

	return _offset_surface_point(surface_point, vehicle_position)


func _offset_surface_point(surface_point: Vector3, vehicle_position: Vector3) -> Vector3:
	var toward_vehicle := vehicle_position - surface_point
	if toward_vehicle.length_squared() > 0.000001:
		return surface_point + toward_vehicle.normalized() * surface_offset
	return surface_point


func _exponential_weight(speed: float, delta: float) -> float:
	if speed <= 0.0:
		return 1.0
	return 1.0 - exp(-speed * maxf(delta, 0.0))


func _sync_record_with_material(sign_record: SignRecord) -> void:
	if not is_instance_valid(sign_record.material):
		return
	var emission_minimum: Variant = sign_record.material.get_shader_parameter(
		"emission_min"
	)
	var emission_maximum: Variant = sign_record.material.get_shader_parameter(
		"emission_max"
	)
	var pulse_speed: Variant = sign_record.material.get_shader_parameter("pulse_speed")
	if emission_minimum is float:
		sign_record.minimum_light_energy = maxf(
			emission_minimum * sign_record.light_energy_multiplier,
			0.0
		)
	if emission_maximum is float:
		sign_record.maximum_light_energy = maxf(
			emission_maximum * sign_record.light_energy_multiplier,
			sign_record.minimum_light_energy
		)
	if pulse_speed is float and pulse_speed > 0.0:
		sign_record.pulse_speed = pulse_speed


func _closest_surface_point(sign_record: SignRecord, world_point: Vector3) -> Vector3:
	var local_point := sign_record.mesh_instance.to_local(world_point)
	var closest_local := _closest_mesh_point(sign_record, local_point)
	return sign_record.mesh_instance.to_global(closest_local)


func _closest_mesh_point(sign_record: SignRecord, point: Vector3) -> Vector3:
	var best_point := Vector3.ZERO
	var best_distance_squared := INF
	var triangle_found := false
	if sign_record.indices.size() >= 3:
		for index_offset in range(0, sign_record.indices.size() - 2, 3):
			var index_a := sign_record.indices[index_offset]
			var index_b := sign_record.indices[index_offset + 1]
			var index_c := sign_record.indices[index_offset + 2]
			if not _valid_triangle_indices(sign_record.vertices, index_a, index_b, index_c):
				continue
			var candidate := _closest_point_on_triangle(
				point,
				sign_record.vertices[index_a],
				sign_record.vertices[index_b],
				sign_record.vertices[index_c]
			)
			var distance_squared := point.distance_squared_to(candidate)
			if distance_squared < best_distance_squared:
				best_distance_squared = distance_squared
				best_point = candidate
				triangle_found = true
	else:
		var triangle_indices := _build_unindexed_triangles(
			sign_record.vertices.size(),
			sign_record.primitive_type
		)
		for index_offset in range(0, triangle_indices.size() - 2, 3):
			var candidate := _closest_point_on_triangle(
				point,
				sign_record.vertices[triangle_indices[index_offset]],
				sign_record.vertices[triangle_indices[index_offset + 1]],
				sign_record.vertices[triangle_indices[index_offset + 2]]
			)
			var distance_squared := point.distance_squared_to(candidate)
			if distance_squared < best_distance_squared:
				best_distance_squared = distance_squared
				best_point = candidate
				triangle_found = true
	if triangle_found:
		return best_point
	return _closest_point_in_aabb(point, sign_record.mesh_instance.mesh.get_aabb())


func _build_unindexed_triangles(
	vertex_count: int,
	primitive_type: Mesh.PrimitiveType
) -> PackedInt32Array:
	var result := PackedInt32Array()
	match primitive_type:
		Mesh.PRIMITIVE_TRIANGLES:
			for index in range(0, vertex_count - 2, 3):
				result.append_array([index, index + 1, index + 2])
		Mesh.PRIMITIVE_TRIANGLE_STRIP:
			for index in maxi(vertex_count - 2, 0):
				result.append_array([index, index + 1, index + 2])
	return result


func _valid_triangle_indices(
	vertices: PackedVector3Array,
	index_a: int,
	index_b: int,
	index_c: int
) -> bool:
	return (
		index_a >= 0
		and index_b >= 0
		and index_c >= 0
		and index_a < vertices.size()
		and index_b < vertices.size()
		and index_c < vertices.size()
	)


func _closest_point_on_triangle(
	point: Vector3,
	vertex_a: Vector3,
	vertex_b: Vector3,
	vertex_c: Vector3
) -> Vector3:
	var edge_ab := vertex_b - vertex_a
	var edge_ac := vertex_c - vertex_a
	var from_a := point - vertex_a
	var dot_ab_a := edge_ab.dot(from_a)
	var dot_ac_a := edge_ac.dot(from_a)
	if dot_ab_a <= 0.0 and dot_ac_a <= 0.0:
		return vertex_a

	var from_b := point - vertex_b
	var dot_ab_b := edge_ab.dot(from_b)
	var dot_ac_b := edge_ac.dot(from_b)
	if dot_ab_b >= 0.0 and dot_ac_b <= dot_ab_b:
		return vertex_b

	var edge_region_c := dot_ab_a * dot_ac_b - dot_ab_b * dot_ac_a
	if edge_region_c <= 0.0 and dot_ab_a >= 0.0 and dot_ab_b <= 0.0:
		var edge_weight := dot_ab_a / (dot_ab_a - dot_ab_b)
		return vertex_a + edge_ab * edge_weight

	var from_c := point - vertex_c
	var dot_ab_c := edge_ab.dot(from_c)
	var dot_ac_c := edge_ac.dot(from_c)
	if dot_ac_c >= 0.0 and dot_ab_c <= dot_ac_c:
		return vertex_c

	var edge_region_b := dot_ab_c * dot_ac_a - dot_ab_a * dot_ac_c
	if edge_region_b <= 0.0 and dot_ac_a >= 0.0 and dot_ac_c <= 0.0:
		var edge_weight := dot_ac_a / (dot_ac_a - dot_ac_c)
		return vertex_a + edge_ac * edge_weight

	var edge_region_a := dot_ab_b * dot_ac_c - dot_ab_c * dot_ac_b
	var edge_bc_test_a := dot_ac_b - dot_ab_b
	var edge_bc_test_b := dot_ab_c - dot_ac_c
	if edge_region_a <= 0.0 and edge_bc_test_a >= 0.0 and edge_bc_test_b >= 0.0:
		var edge_weight := edge_bc_test_a / (edge_bc_test_a + edge_bc_test_b)
		return vertex_b + (vertex_c - vertex_b) * edge_weight

	var denominator := edge_region_a + edge_region_b + edge_region_c
	if is_zero_approx(denominator):
		return vertex_a
	var inverse_denominator := 1.0 / denominator
	var weight_b := edge_region_b * inverse_denominator
	var weight_c := edge_region_c * inverse_denominator
	return vertex_a + edge_ab * weight_b + edge_ac * weight_c


func _closest_point_in_aabb(point: Vector3, bounds: AABB) -> Vector3:
	var bounds_end := bounds.end
	return Vector3(
		clampf(point.x, bounds.position.x, bounds_end.x),
		clampf(point.y, bounds.position.y, bounds_end.y),
		clampf(point.z, bounds.position.z, bounds_end.z)
	)


func _sort_candidates_by_distance(first: Dictionary, second: Dictionary) -> bool:
	return float(first.get("distance_squared")) < float(second.get("distance_squared"))


func _deactivate_all_slots() -> void:
	for slot: Dictionary in _slots:
		slot["target_active"] = false


func _connect_runtime_sign_discovery() -> void:
	if not get_tree().node_added.is_connected(_on_tree_node_added):
		get_tree().node_added.connect(_on_tree_node_added)


func _on_tree_node_added(node: Node) -> void:
	if (
		node.is_in_group(ARROW_SIGN_GROUP)
		or node.is_in_group(WRONG_SIGN_GROUP)
	):
		_queue_sign_rescan()


func _queue_sign_rescan() -> void:
	if _rescan_queued:
		return
	_rescan_queued = true
	call_deferred("_finish_sign_rescan")


func _finish_sign_rescan() -> void:
	_rescan_queued = false
	_rebuild_sign_records()
	_refresh_light_assignments()


func _connect_quality_manager() -> void:
	var quality_manager := get_node_or_null("/root/GraphicsQualityManager")
	if (
		quality_manager != null
		and quality_manager.has_signal(&"quality_changed")
		and not quality_manager.is_connected(
			&"quality_changed",
			_on_quality_changed
		)
	):
		quality_manager.connect(&"quality_changed", _on_quality_changed)


func _apply_current_quality() -> void:
	var quality_manager := get_node_or_null("/root/GraphicsQualityManager")
	var quality_level := HIGH_QUALITY_LEVEL
	if quality_manager != null:
		quality_level = int(quality_manager.get("current_quality"))
	_on_quality_changed(quality_level)


func _on_quality_changed(quality_level: int) -> void:
	match quality_level:
		0:
			_active_light_limit = 1 if enable_on_low_quality else 0
		MEDIUM_QUALITY_LEVEL:
			_active_light_limit = mini(medium_quality_pool_size, maximum_pool_size)
		_:
			_active_light_limit = maximum_pool_size
	_refresh_light_assignments()
