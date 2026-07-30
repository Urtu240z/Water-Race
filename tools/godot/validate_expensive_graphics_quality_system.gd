extends SceneTree

const MAIN_SCENE := "res://scenes/levels/island_test/island_test_BLENDER.tscn"
const EPSILON := 0.001

var _failed := false
var _ocean_vertices_by_level: Dictionary = {}
var _ocean_triangles_by_level: Dictionary = {}
var _vegetation_by_level: Dictionary = {}
var _wildlife_by_level: Dictionary = {}


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var manager := root.get_node_or_null("GraphicsQualityManager")
	var packed := load(MAIN_SCENE) as PackedScene
	_expect(manager != null, "El manager específico existe.")
	_expect(
		Engine.max_fps == 0,
		"El juego arranca sin limitador interno de FPS."
	)
	_expect(packed != null, "La escena principal carga.")
	if manager == null or packed == null:
		_finish()
		return
	var island := packed.instantiate()
	root.add_child(island)
	current_scene = island
	await _wait_frames(5)

	var ocean := island.get_node_or_null("WaterIntegration/Ocean") as Ocean3D
	_expect(ocean != null, "Ocean3D está presente.")
	if ocean == null:
		_finish()
		return
	var physical_point := Vector3(23.5, -0.7, -11.25)
	paused = true
	for ripple_index in 6:
		ocean.add_ripple(
			Vector3(float(ripple_index) * 2.0, 0.0, float(ripple_index))
		)
	var physical_height := ocean.sample_height(physical_point)
	var physical_normal := ocean.sample_normal(physical_point)
	var logical_origin := ocean.get_logical_origin_offset_xz()
	var wildlife_count := _wildlife_actor_count(island)

	await _apply_and_validate(
		manager,
		manager.Quality.HIGH,
		12,
		16,
		4,
		2,
		24,
		2,
		216,
		60,
		1.0,
		60.0,
		5.0,
		500
	)
	_validate_underwater_live_toggle(island)
	await _apply_and_validate(
		manager,
		manager.Quality.MEDIUM,
		8,
		12,
		3,
		1,
		8,
		1,
		78,
		45,
		0.5,
		30.0,
		2.0,
		250
	)
	await _apply_and_validate(
		manager,
		manager.Quality.LOW,
		4,
		8,
		2,
		0,
		0,
		0,
		36,
		30,
		0.25,
		15.0,
		0.0,
		80
	)
	await _apply_and_validate(
		manager,
		manager.Quality.HIGH,
		12,
		16,
		4,
		2,
		24,
		2,
		216,
		60,
		1.0,
		60.0,
		5.0,
		500
	)

	_expect(
		_near(ocean.sample_height(physical_point), physical_height)
		and ocean.sample_normal(physical_point).is_equal_approx(physical_normal),
		"Los cambios visuales no alteran la muestra física del océano."
	)
	_expect(
		ocean.get_logical_origin_offset_xz() == logical_origin,
		"El cambio de preset conserva el origen lógico del océano."
	)
	_expect(
		int(_ocean_vertices_by_level[manager.Quality.LOW])
			< int(_ocean_vertices_by_level[manager.Quality.MEDIUM])
		and int(_ocean_vertices_by_level[manager.Quality.MEDIUM])
			< int(_ocean_vertices_by_level[manager.Quality.HIGH]),
		"Los vértices del clipmap crecen estrictamente LOW < MEDIUM < HIGH."
	)
	_validate_shader_early_exits()
	print(
		"OCEAN COUNTS LOW/MEDIUM/HIGH vertices=",
		[
			_ocean_vertices_by_level[manager.Quality.LOW],
			_ocean_vertices_by_level[manager.Quality.MEDIUM],
			_ocean_vertices_by_level[manager.Quality.HIGH],
		],
		" triangles=",
		[
			_ocean_triangles_by_level[manager.Quality.LOW],
			_ocean_triangles_by_level[manager.Quality.MEDIUM],
			_ocean_triangles_by_level[manager.Quality.HIGH],
		]
	)
	print(
		"VEGETATION LOW/MEDIUM/HIGH=",
		[
			_vegetation_by_level[manager.Quality.LOW],
			_vegetation_by_level[manager.Quality.MEDIUM],
			_vegetation_by_level[manager.Quality.HIGH],
		],
		" WILDLIFE ACTIVE=",
		[
			_wildlife_by_level[manager.Quality.LOW],
			_wildlife_by_level[manager.Quality.MEDIUM],
			_wildlife_by_level[manager.Quality.HIGH],
		]
	)
	_expect(
		_wildlife_actor_count(island) == wildlife_count
		and wildlife_count == 104,
		"La fauna conserva sus 104 nodos y sólo cambia su presupuesto activo."
	)
	_expect(
		not bool(manager.restart_required),
		"El sistema confirma que no requiere reinicio."
	)

	paused = false
	current_scene = null
	island.free()
	await _wait_frames(2)
	_finish()


func _apply_and_validate(
	manager: Node,
	level: int,
	ripples: int,
	directional_segments: int,
	landing_impacts: int,
	terrain_mode: int,
	ssr_steps: int,
	detail_quality: int,
	impact_maximum: int,
	particle_fps: int,
	population_ratio: float,
	wildlife_rate: float,
	underwater_blur: float,
	entry_bubbles: int
) -> void:
	var before: Dictionary = manager.get_graphics_quality_debug_status()
	var before_rebuilds := _surface_rebuild_count(before)
	Engine.max_fps = 37
	manager.set_quality(level, false)
	while manager.is_applying:
		await manager.graphics_quality_applied
	_expect(
		Engine.max_fps == 0,
		"El nivel %d mantiene los FPS internos ilimitados." % level
	)
	var status: Dictionary = manager.get_graphics_quality_debug_status()
	_expect(
		_group_count(status, "ocean") == 1
		and _group_count(status, "vehicle_effects") == 1
		and _group_count(status, "terrain") == 1
		and _group_count(status, "vegetation") == 1
		and _group_count(status, "wildlife") == 1
		and _group_count(status, "underwater") == 1,
		"El nivel %d tiene un único controlador por sistema." % level
	)
	var ocean: Dictionary = _first(status, "ocean")
	var vehicle: Dictionary = _first(status, "vehicle_effects")
	var terrain: Dictionary = _first(status, "terrain")
	var vegetation: Dictionary = _first(status, "vegetation")
	var wildlife: Dictionary = _first(status, "wildlife")
	var underwater: Dictionary = _first(status, "underwater")
	_vegetation_by_level[level] = {
		"full_3d_sectors": int(
			vegetation.get("full_3d_palm_sectors", -1)
		),
		"impostors": int(vegetation.get("impostor_palm_sectors", -1)),
		"ground_shadows": int(
			vegetation.get("ground_shadow_sectors", -1)
		),
		"visible_instances": int(
			vegetation.get("visible_palm_instances", -1)
		),
	}
	_wildlife_by_level[level] = int(
		wildlife.get("quality_active_actor_count", -1)
	)
	var surface := ocean.get("surface", {}) as Dictionary
	var expected_geometry := _expected_ocean_geometry(level)
	var vertices := surface.get("vertices", Vector3i.ZERO) as Vector3i
	var triangles := surface.get("triangles", Vector3i.ZERO) as Vector3i
	_ocean_vertices_by_level[level] = vertices.x + vertices.y + vertices.z
	_ocean_triangles_by_level[level] = (
		triangles.x + triangles.y + triangles.z
	)
	_expect(
		_near(
			float(surface.get("near_radius", 0.0)),
			float(expected_geometry.near_radius)
		)
		and _near(
			float(surface.get("near_cell_size", 0.0)),
			float(expected_geometry.near_cell_size)
		)
		and _near(
			float(surface.get("middle_radius", 0.0)),
			float(expected_geometry.middle_radius)
		)
		and _near(
			float(surface.get("middle_cell_size", 0.0)),
			float(expected_geometry.middle_cell_size)
		)
		and _near(
			float(surface.get("far_radius", 0.0)),
			float(expected_geometry.far_radius)
		)
		and _near(
			float(surface.get("far_cell_size", 0.0)),
			float(expected_geometry.far_cell_size)
		),
		"El nivel %d aplica radios y celdas exactos." % level
	)
	_expect(
		_near(
			float(expected_geometry.middle_cell_size)
				/ float(expected_geometry.near_cell_size),
			roundf(
				float(expected_geometry.middle_cell_size)
					/ float(expected_geometry.near_cell_size)
			)
		)
		and _near(
			float(expected_geometry.far_cell_size)
				/ float(expected_geometry.middle_cell_size),
			roundf(
				float(expected_geometry.far_cell_size)
					/ float(expected_geometry.middle_cell_size)
			)
		),
		"El nivel %d conserva relaciones enteras del clipmap." % level
	)
	_expect(
		int(ocean.get("effective_ripples", -1)) == ripples
		and int(ocean.get("active_ripples", -1)) == 6
		and int(ocean.get("effective_directional_segments", -1))
			== directional_segments
		and int(ocean.get("effective_landing_impacts", -1))
			== landing_impacts,
		"El nivel %d aplica los límites de interacción del océano." % level
	)
	_expect(
		int(ocean.get("custom_ssr_steps", -1)) == ssr_steps
		and int(ocean.get("surface_detail_quality", -1)) == detail_quality,
		"El nivel %d aplica SSR y detalle superficial autoritativos." % level
	)
	_expect(
		_surface_rebuild_count(status) == before_rebuilds + 1,
		"El nivel %d reconstruye el clipmap exactamente una vez." % level
	)
	_expect(
		int(vehicle.get("impact_target_maximum", -1)) == impact_maximum
		and int(vehicle.get("fixed_fps", -1)) == particle_fps,
		"El nivel %d limita partículas e impactos del vehículo." % level
	)
	_expect(
		int(terrain.get("hex_tiling_mode", -1)) == terrain_mode
		and int(terrain.get("terrain_material_count", -1)) == 1,
		"El nivel %d usa hex_tiling_mode sin duplicar materiales." % level
	)
	_expect(
		int(vegetation.get("stored_instance_count", -1)) == 948
		and _near(
			float(vegetation.get("update_rate_hz", 0.0)),
			4.0 if level == 0 else (8.0 if level == 1 else 12.0)
		),
		"El nivel %d conserva las instancias y regula vegetación." % level
	)
	_expect(
		_near(float(wildlife.get("population_ratio", -1.0)), population_ratio)
		and _near(float(wildlife.get("update_rate_hz", 0.0)), wildlife_rate)
		and int(wildlife.get("quality_active_actor_count", -1))
			== (26 if level == 0 else (52 if level == 1 else 104))
		and int(wildlife.get("animated_actor_count", -1))
			<= int(wildlife.get("quality_active_actor_count", -1)),
		"El nivel %d regula población y frecuencia de fauna." % level
	)
	_expect(
		_near(float(underwater.get("blur_strength", -1.0)), underwater_blur)
		and int(underwater.get("entry_bubbles_amount", -1)) == entry_bubbles
		and not bool(underwater.get("postprocess_enabled", true)),
		"El nivel %d regula el postproceso y no ejecuta un pase fuera del agua."
		% level
	)


func _wildlife_actor_count(island: Node) -> int:
	var wildlife := island.get_node_or_null("AmbientWildlife")
	return int(wildlife.wildlife_actor_count) if wildlife != null else -1


func _expected_ocean_geometry(level: int) -> Dictionary:
	match level:
		0:
			return {
				"near_radius": 150.0,
				"near_cell_size": 1.0,
				"middle_radius": 500.0,
				"middle_cell_size": 16.0,
				"far_radius": 2200.0,
				"far_cell_size": 128.0,
			}
		1:
			return {
				"near_radius": 190.0,
				"near_cell_size": 1.0,
				"middle_radius": 650.0,
				"middle_cell_size": 12.0,
				"far_radius": 2800.0,
				"far_cell_size": 96.0,
			}
		_:
			return {
				"near_radius": 220.0,
				"near_cell_size": 0.5,
				"middle_radius": 700.0,
				"middle_cell_size": 10.0,
				"far_radius": 3000.0,
				"far_cell_size": 100.0,
			}


func _validate_shader_early_exits() -> void:
	var base_source := FileAccess.get_file_as_string(
		"res://shaders/ocean_water.gdshader"
	)
	var ssr_source := FileAccess.get_file_as_string(
		"res://shaders/ocean_water_custom_ssr.gdshader"
	)
	var interaction_source := FileAccess.get_file_as_string(
		"res://shaders/includes/ocean_vehicle_interaction_functions.gdshaderinc"
	)
	_expect(
		"index >= ripple_effective_count" in base_source
		and "index >= ripple_effective_count" in ssr_source
		and "index >= directional_wake_effective_count" in interaction_source
		and "index >= landing_impact_effective_count" in interaction_source,
		"Los tres bucles caros contienen early exits efectivos."
	)
	_expect(
		"custom_ssr_enabled" in ssr_source
		and "custom_ssr_trace(" in ssr_source,
		"El shader SSR conserva el raymarch condicionado por su uniform."
	)


func _validate_underwater_live_toggle(island: Node) -> void:
	var underwater := island.get_node_or_null(
		"CameraSystem/ChaseCamera/Camera3D/UnderwaterEffect"
	)
	_expect(underwater != null, "El controlador submarino existe.")
	if underwater == null:
		return
	underwater.force_mode = 2
	underwater.call("_process", 0.016)
	var submerged: Dictionary = (
		underwater.get_graphics_quality_debug_status()
	)
	_expect(
		bool(submerged.get("postprocess_enabled", false)),
		"El postproceso se restaura al forzar la entrada en el agua."
	)
	underwater.force_mode = 1
	underwater.call("_process", 0.016)
	underwater.call("_clear_crossing_transition")
	underwater.call("_update_fullscreen_compositor", 0.0)
	var above_water: Dictionary = (
		underwater.get_graphics_quality_debug_status()
	)
	_expect(
		not bool(above_water.get("postprocess_enabled", true)),
		"El postproceso vuelve a apagarse fuera del agua."
	)
	underwater.force_mode = 0


func _surface_rebuild_count(status: Dictionary) -> int:
	var ocean := _first(status, "ocean")
	var surface := ocean.get("surface", {}) as Dictionary
	return int(surface.get("mesh_rebuild_count", 0))


func _group_count(status: Dictionary, key: String) -> int:
	return (status.get(key, []) as Array).size()


func _first(status: Dictionary, key: String) -> Dictionary:
	var values := status.get(key, []) as Array
	return values[0] as Dictionary if not values.is_empty() else {}


func _near(left: float, right: float) -> bool:
	return absf(left - right) <= EPSILON


func _wait_frames(frame_count: int) -> void:
	for _index in frame_count:
		await process_frame


func _expect(condition: bool, message: String) -> void:
	if condition:
		print("PASS: ", message)
		return
	_failed = true
	push_error("FAIL: " + message)


func _finish() -> void:
	if _failed:
		print("EXPENSIVE GRAPHICS QUALITY VALIDATION: FAILED")
		quit(1)
	else:
		print("EXPENSIVE GRAPHICS QUALITY VALIDATION: PASS")
		quit(0)
