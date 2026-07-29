extends SceneTree

const CHASE_CAMERA_SCENE := "res://scenes/camera/chase_camera.tscn"
const RIDER_SCENE := "res://scenes/vehicle/jet_ski_with_rider.tscn"
const MAIN_SCENE := (
	"res://scenes/levels/island_test/island_test_BLENDER.tscn"
)
const CONTROLLER_PATH := (
	"res://scripts/camera/underwater_effect_controller.gd"
)
const ORIGINAL_SHADER_PATH := (
	"res://shaders/effects/underwater_wave_post_process.gdshader"
)
const SPLIT_SHADER_PATH := (
	"res://shaders/effects/underwater_split_view_post_process.gdshader"
)
const ORIGINAL_SHADER_SHA256 := (
	"622f5793bee4c3c86955347fb681cc58fb957cc0fca9da4c40a8b7f57221c117"
)

var _failed: bool = false
var _fixture: Node3D
var _effect: UnderwaterEffectController
var _camera: Camera3D
var _ocean: Ocean3D
var _post_process: MeshInstance3D
var _material: ShaderMaterial
var _shader_source: String


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var packed_camera := load(CHASE_CAMERA_SCENE) as PackedScene
	var controller_script := load(CONTROLLER_PATH) as GDScript
	var split_shader := load(SPLIT_SHADER_PATH) as Shader
	_shader_source = FileAccess.get_file_as_string(SPLIT_SHADER_PATH)

	_validate_resources(packed_camera, controller_script, split_shader)
	_validate_packed_scene(packed_camera)
	await _build_fixture(controller_script, split_shader)
	_validate_visibility_and_force_modes()
	_validate_depth_and_hysteresis()
	_validate_shader_contract()
	_validate_ocean_integration()
	_validate_worktree_guards()
	await _cleanup()
	_finish()


func _validate_resources(
	packed_camera: PackedScene,
	controller_script: GDScript,
	split_shader: Shader
) -> void:
	_expect(1, packed_camera != null, "chase_camera.tscn carga.")
	_expect(
		2,
		controller_script != null,
		"UnderwaterEffectController carga sin error de parser."
	)
	_expect(3, split_shader != null, "El shader split-view carga.")
	_expect(
		4,
		FileAccess.file_exists(ORIGINAL_SHADER_PATH),
		"El shader submarino original sigue existiendo."
	)
	_expect(
		5,
		FileAccess.get_sha256(ORIGINAL_SHADER_PATH)
		== ORIGINAL_SHADER_SHA256,
		"El shader submarino original permanece byte a byte intacto."
	)


func _validate_packed_scene(packed_camera: PackedScene) -> void:
	if packed_camera == null:
		for check_number: int in range(6, 10):
			_expect(check_number, false, "Escena de camara no disponible.")
		return
	var instance := packed_camera.instantiate()
	var effect := instance.get_node_or_null(
		"Camera3D/UnderwaterEffect"
	) as UnderwaterEffectController
	var post_process := instance.get_node_or_null(
		"Camera3D/UnderwaterEffect/UnderwaterPostProcess"
	) as MeshInstance3D
	var material := (
		post_process.material_override as ShaderMaterial
		if post_process != null
		else null
	)
	_expect(
		6,
		effect != null and post_process != null,
		"La jerarquia submarina existente se conserva."
	)
	_expect(
		7,
		material != null
		and material.shader != null
		and material.shader.resource_path == SPLIT_SHADER_PATH,
		"UnderwaterPostProcess usa el shader split-view."
	)
	_expect(
		8,
		material != null and material.resource_local_to_scene,
		"El ShaderMaterial sigue siendo local a la escena."
	)
	_expect(
		9,
		post_process != null and not post_process.visible,
		"El quad parte oculto."
	)
	instance.free()


func _build_fixture(
	controller_script: GDScript,
	split_shader: Shader
) -> void:
	if controller_script == null or split_shader == null:
		return
	_fixture = Node3D.new()
	_fixture.name = "UnderwaterSplitViewFixture"
	_fixture.process_mode = Node.PROCESS_MODE_DISABLED

	_ocean = Ocean3D.new()
	_ocean.name = "Ocean"
	_ocean.water_level = 0.0
	_ocean.process_mode = Node.PROCESS_MODE_DISABLED
	_fixture.add_child(_ocean)

	_camera = Camera3D.new()
	_camera.name = "Camera3D"
	_fixture.add_child(_camera)

	_effect = controller_script.new() as UnderwaterEffectController
	_effect.name = "UnderwaterEffect"
	_effect.ocean_path = NodePath("../../Ocean")
	_effect.process_mode = Node.PROCESS_MODE_DISABLED
	_camera.add_child(_effect)

	_post_process = MeshInstance3D.new()
	_post_process.name = "UnderwaterPostProcess"
	_material = ShaderMaterial.new()
	_material.resource_local_to_scene = true
	_material.shader = split_shader
	_post_process.material_override = _material
	_post_process.mesh = QuadMesh.new()
	_effect.add_child(_post_process)

	root.add_child(_fixture)
	await process_frame
	_effect.call("_resolve_ocean")


func _validate_visibility_and_force_modes() -> void:
	if _effect == null:
		for check_number: int in range(10, 15):
			_expect(check_number, false, "Fixture funcional no disponible.")
		return
	_effect.force_mode = UnderwaterEffectController.DebugForceMode.AUTOMATIC
	_camera.global_position.y = 2.0
	_effect.call("_process", 1.0)
	_expect(
		10,
		not _post_process.visible,
		"El quad permanece oculto lejos por encima del agua."
	)
	_camera.global_position.y = 1.0
	_effect.call("_process", 1.0)
	_expect(
		11,
		_post_process.visible and not _effect.is_underwater,
		"El quad se activa cerca de superficie sin exigir is_underwater."
	)
	_effect.force_mode = UnderwaterEffectController.DebugForceMode.FORCE_AIR
	_camera.global_position.y = -1.0
	_effect.call("_process", 10.0)
	_expect(
		12,
		not _post_process.visible and _effect.effect_strength <= 0.0001,
		"FORCE_AIR oculta el quad y lleva la intensidad a cero."
	)
	_effect.force_mode = (
		UnderwaterEffectController.DebugForceMode.FORCE_UNDERWATER
	)
	_camera.global_position.y = 2.0
	_effect.call("_process", 10.0)
	_expect(
		13,
		_post_process.visible
		and _effect.effect_strength >= 0.9999
		and _effect.is_underwater,
		"FORCE_UNDERWATER muestra el quad a intensidad completa."
	)
	_expect(
		14,
		is_equal_approx(
			float(_material.get_shader_parameter("camera_submersion")),
			_effect.effect_strength
		),
		"camera_submersion recibe effect_strength."
	)


func _validate_depth_and_hysteresis() -> void:
	if _effect == null:
		for check_number: int in range(15, 20):
			_expect(check_number, false, "Fixture funcional no disponible.")
		return
	_effect.force_mode = UnderwaterEffectController.DebugForceMode.AUTOMATIC
	_effect.set("_effect_strength", 0.0)
	_camera.global_position.y = -0.04
	_effect.call("_process", 10.0)
	_expect(
		15,
		_effect.camera_depth > 0.0 and _effect.is_underwater,
		"camera_depth es positivo bajo agua y activa la entrada."
	)
	_camera.global_position.y = (
		_effect.sampled_surface_height + 0.02
	)
	_effect.call("_process", 0.0)
	_expect(
		16,
		_effect.camera_depth < 0.0 and _effect.is_underwater,
		"La histeresis conserva el estado con clearance intermedio."
	)
	_camera.global_position.y = (
		_effect.sampled_surface_height
		+ _effect.exit_clearance
		+ 0.01
	)
	_effect.call("_process", 0.0)
	_expect(
		17,
		not _effect.is_underwater,
		"La histeresis sale al superar exit_clearance."
	)
	_effect.set("_effect_strength", 0.0)
	_camera.global_position.y = -0.20
	_effect.call("_process", 10.0)
	var middle_strength := _effect.effect_strength
	_effect.set("_effect_strength", 0.0)
	_camera.global_position.y = -0.50
	_effect.call("_process", 10.0)
	_expect(
		18,
		middle_strength > 0.0
		and middle_strength < 1.0
		and _effect.effect_strength >= 0.9999,
		"effect_strength progresa con la profundidad real."
	)
	_expect(
		19,
		is_equal_approx(
			float(_material.get_shader_parameter("camera_depth")),
			_effect.camera_depth
		),
		"camera_depth conserva signo y se envia al shader."
	)


func _validate_shader_contract() -> void:
	var partial_assignment := _function_block(
		_shader_source,
		"float partial_underwater_mask",
		"float full_submersion_mask"
	)
	_expect(
		20,
		not partial_assignment.contains("* camera_submersion")
		and not partial_assignment.contains("*camera_submersion"),
		"La mascara parcial no depende de camera_submersion."
	)
	_expect(
		21,
		_shader_source.contains(
			"mix(\n        partial_underwater_mask,\n        1.0,"
		),
		"La mascara final combina partial y full submersion."
	)
	_expect(
		22,
		_shader_source.contains("raw_depth <= 0.000001")
		and _shader_source.contains("underwater_sky_distance"),
		"El cielo Reverse-Z usa un rayo con distancia finita."
	)
	_expect(
		23,
		_shader_source.contains("POSITION = vec4(VERTEX.xy, 1.0, 1.0)")
		and _shader_source.contains(
			"screen_uv * 2.0 - 1.0,\n        1.0,"
		),
		"Quad y rayo respetan Reverse Z de Forward+."
	)
	_expect(
		24,
		_shader_source.contains("abs(ray_world.y) <= 0.00001")
		and is_inf(_flat_water_hit_distance(1.0, Vector3.RIGHT, 100.0)),
		"Los rayos casi paralelos se rechazan."
	)
	_expect(
		25,
		_flat_water_hit_distance(1.0, Vector3.UP, 100.0) < 0.0,
		"Los hits detras de camara se rechazan."
	)
	_expect(
		26,
		_flat_water_hit_distance(
			10.0,
			Vector3.DOWN,
			5.0
		) > 5.0
		and _shader_source.contains(
			"candidate_distance > maximum_distance"
		),
		"Los hits posteriores a escena o rango maximo se rechazan."
	)
	_expect(
		27,
		_shader_source.contains(
			"const int MAX_WATERLINE_ITERATIONS = 2"
		)
		and _shader_source.contains("iteration < MAX_WATERLINE_ITERATIONS"),
		"Las correcciones de superficie estan limitadas a dos."
	)
	_expect(
		28,
		_shader_source.contains("uniform bool waterline_include_ripples = false")
		and _shader_source.contains("sample_macro_height(logical_xz)"),
		"La linea usa olas macro y deja ripples desactivados por defecto."
	)
	_expect(
		29,
		_shader_source.contains("filter_linear_mipmap")
		and _shader_source.contains("textureLod("),
		"El desenfoque real usa mip LOD."
	)
	_expect(
		30,
		_shader_source.contains(
			"scene_distance - water_hit_distance"
		)
		and _shader_source.contains(
			"-fog_density * max(water_distance, 0.0)"
		),
		"Fog y blur dependen de la distancia recorrida bajo agua."
	)
	_expect(
		31,
		_shader_source.contains(
			"mix(scene_color, tinted_color, underwater_mask)"
		),
		"La zona con mascara cero conserva el color original."
	)


func _validate_ocean_integration() -> void:
	if _effect == null or _ocean == null:
		for check_number: int in range(32, 34):
			_expect(check_number, false, "Fixture funcional no disponible.")
		return
	var registered := _ocean.get("_external_materials") as Array
	_expect(
		32,
		registered.has(_material),
		"Ocean3D registra y sincroniza el material externo una sola vez."
	)
	_ocean.apply_world_rebase(Vector3.ZERO, 37.0, -19.0)
	var pushed_origin := (
		_material.get_shader_parameter("ocean_logical_origin_offset_xz")
		as Vector2
	)
	_expect(
		33,
		pushed_origin.is_equal_approx(Vector2(37.0, -19.0))
		and registered.count(_material) == 1,
		"El rebase actualiza el origen sin duplicar ni romper el material."
	)


func _validate_worktree_guards() -> void:
	var changed_output: Array = []
	var changed_exit := OS.execute(
		"git",
		PackedStringArray(["diff", "--name-only"]),
		changed_output,
		true
	)
	var changed_paths := "\n".join(changed_output)
	var protected_clean := (
		not changed_paths.contains("shaders/ocean_water.gdshader")
		and not changed_paths.contains(
			"shaders/ocean_water_custom_ssr.gdshader"
		)
		and not changed_paths.contains("resources/water/ocean/")
		and not changed_paths.contains(
			"resources/environment/environment_1.tres"
		)
		and not changed_paths.contains(
			"scenes/levels/island_test/island_test_BLENDER.tscn"
		)
	)
	_expect(
		34,
		changed_exit == 0 and protected_clean,
		"Custom SSR, entorno, escena principal y tuning de oceano no se tocaron."
	)
	var check_output: Array = []
	var check_exit := OS.execute(
		"git",
		PackedStringArray(["diff", "--check"]),
		check_output,
		true
	)
	_expect(35, check_exit == 0, "git diff --check limpio.")
	_expect(
		36,
		load(RIDER_SCENE) is PackedScene,
		"jet_ski_with_rider.tscn carga."
	)
	_expect(
		37,
		load(MAIN_SCENE) is PackedScene,
		"island_test_BLENDER.tscn carga sin guardarse."
	)


func _flat_water_hit_distance(
	camera_height: float,
	ray_direction: Vector3,
	max_distance: float
) -> float:
	if absf(ray_direction.y) <= 0.00001:
		return INF
	var distance := -camera_height / ray_direction.y
	if distance <= 0.00001 or distance > max_distance:
		return distance
	return distance


func _function_block(
	source: String,
	start_marker: String,
	end_marker: String
) -> String:
	var start := source.find(start_marker)
	if start < 0:
		return ""
	var finish := source.find(end_marker, start + start_marker.length())
	if finish < 0:
		finish = source.length()
	return source.substr(start, finish - start)


func _cleanup() -> void:
	if _fixture != null:
		_fixture.queue_free()
	await process_frame
	await process_frame


func _expect(number: int, condition: bool, message: String) -> void:
	if condition:
		print("PASS: %d. %s" % [number, message])
		return
	_failed = true
	push_error("FAIL: %d. %s" % [number, message])


func _finish() -> void:
	if _failed:
		print("UNDERWATER_SPLIT_VIEW_VALIDATION=FAIL")
		quit(1)
		return
	print("UNDERWATER_SPLIT_VIEW_VALIDATION=PASS")
	quit(0)
