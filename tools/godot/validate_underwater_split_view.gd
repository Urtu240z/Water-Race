extends SceneTree

const CHASE_CAMERA_SCENE := "res://scenes/camera/chase_camera.tscn"
const MAIN_SCENE := "res://scenes/levels/island_test/island_test_BLENDER.tscn"
const CONTROLLER_PATH := "res://scripts/camera/underwater_effect_controller.gd"
const COMPOSITOR_PATH := (
	"res://scripts/camera/underwater_fullscreen_compositor_effect.gd"
)
const COMPOSITOR_SHADER_PATH := (
	"res://shaders/effects/underwater_fullscreen_compositor.glsl"
)
const LEGACY_SHADER_PATH := (
	"res://shaders/effects/underwater_split_view_post_process.gdshader"
)

var _failed := false


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var packed_camera := load(CHASE_CAMERA_SCENE) as PackedScene
	var packed_main := load(MAIN_SCENE) as PackedScene
	var controller_script := load(CONTROLLER_PATH) as GDScript
	var compositor_script := load(COMPOSITOR_PATH) as GDScript
	var legacy_shader := load(LEGACY_SHADER_PATH) as Shader
	_expect(packed_camera != null, "chase_camera.tscn carga.")
	_expect(packed_main != null, "La escena principal carga.")
	_expect(
		controller_script != null,
		"UnderwaterEffectController carga sin errores."
	)
	_expect(
		compositor_script != null,
		"UnderwaterFullscreenCompositorEffect carga sin errores."
	)
	_expect(legacy_shader != null, "El shader de fallback carga.")
	_expect(
		FileAccess.file_exists(COMPOSITOR_SHADER_PATH),
		"El compute shader submarino existe."
	)
	if packed_camera != null:
		_validate_packed_camera(packed_camera)
	if controller_script != null and legacy_shader != null:
		await _validate_runtime_contract(controller_script, legacy_shader)
	_validate_shader_contracts()
	print(
		"UNDERWATER_SPLIT_VIEW_VALIDATION=",
		"FAIL" if _failed else "PASS"
	)
	quit(1 if _failed else 0)


func _validate_packed_camera(packed_camera: PackedScene) -> void:
	var instance := packed_camera.instantiate()
	var controller := instance.get_node_or_null(
		"Camera3D/UnderwaterEffect"
	) as UnderwaterEffectController
	var quad := instance.get_node_or_null(
		"Camera3D/UnderwaterEffect/UnderwaterPostProcess"
	) as MeshInstance3D
	var material := (
		quad.material_override as ShaderMaterial if quad != null else null
	)
	_expect(controller != null, "La cámara conserva UnderwaterEffect.")
	_expect(quad != null, "La cámara conserva el quad de fallback.")
	_expect(
		quad != null and not quad.visible,
		"El fallback parte oculto."
	)
	_expect(
		material != null
		and material.shader != null
		and material.shader.resource_path == LEGACY_SHADER_PATH,
		"El fallback usa el shader split-view."
	)
	instance.free()


func _validate_runtime_contract(
	controller_script: GDScript,
	legacy_shader: Shader
) -> void:
	var fixture := Node3D.new()
	fixture.process_mode = Node.PROCESS_MODE_DISABLED
	var ocean := Ocean3D.new()
	ocean.water_level = 0.0
	ocean.process_mode = Node.PROCESS_MODE_DISABLED
	fixture.add_child(ocean)
	var camera := Camera3D.new()
	fixture.add_child(camera)
	var controller := controller_script.new() as UnderwaterEffectController
	controller.ocean_path = NodePath("../../Ocean")
	controller.process_mode = Node.PROCESS_MODE_DISABLED
	camera.add_child(controller)
	var quad := MeshInstance3D.new()
	quad.name = "UnderwaterPostProcess"
	quad.mesh = QuadMesh.new()
	var material := ShaderMaterial.new()
	material.shader = legacy_shader
	quad.material_override = material
	controller.add_child(quad)
	root.add_child(fixture)
	await process_frame
	controller.call("_resolve_ocean")

	controller.force_mode = UnderwaterEffectController.DebugForceMode.FORCE_AIR
	camera.global_position.y = 2.0
	controller.call("_process", 0.016)
	var air_status := controller.get_underwater_runtime_debug_status()
	_expect(
		air_status.get("active_visual_route") == "none",
		"Fuera del agua no se ejecuta ningún postproceso."
	)

	controller.force_mode = (
		UnderwaterEffectController.DebugForceMode.FORCE_UNDERWATER
	)
	controller.call("_process", 0.016)
	var forced_status := controller.get_underwater_runtime_debug_status()
	_expect(
		forced_status.get("effect_strength") == 1.0,
		"FORCE_UNDERWATER conserva fuerza completa."
	)
	_expect(
		forced_status.get("is_underwater", false),
		"FORCE_UNDERWATER activa el detector."
	)
	_expect(
		forced_status.get("attached_underwater_effect_count", 0) == 1,
		"El compositor queda adjunto exactamente una vez."
	)
	_validate_exclusive_route(forced_status, "FORCE_UNDERWATER")

	controller.force_mode = UnderwaterEffectController.DebugForceMode.AUTOMATIC
	camera.global_position.y = -0.25
	controller.call("_process", 0.016)
	var automatic_status := controller.get_underwater_runtime_debug_status()
	_expect(
		automatic_status.get("camera_depth", -INF) >= controller.enter_depth,
		"La detección automática usa profundidad positiva bajo el agua."
	)
	_expect(
		automatic_status.get("is_underwater", false),
		"La detección automática entra bajo la superficie."
	)
	_validate_exclusive_route(automatic_status, "AUTOMATIC")

	camera.global_position.y = (
		controller.sampled_surface_height + controller.exit_clearance + 0.02
	)
	controller.call("_process", 0.016)
	_expect(
		not controller.is_underwater,
		"La histéresis sale al superar exit_clearance."
	)

	controller.force_mode = UnderwaterEffectController.DebugForceMode.FORCE_AIR
	controller.call("_clear_crossing_transition")
	controller.call("_process", 0.016)
	var final_air_status := controller.get_underwater_runtime_debug_status()
	_expect(
		final_air_status.get("active_visual_route") == "none",
		"El postproceso vuelve a apagarse en aire estable."
	)
	_expect(
		not final_air_status.get("legacy_quad_visible", true),
		"El fallback no queda visible fuera del agua."
	)

	fixture.queue_free()
	await process_frame


func _validate_exclusive_route(status: Dictionary, label: String) -> void:
	var compositor_enabled: bool = status.get(
		"compositor_effect_enabled",
		false
	)
	var fallback_visible: bool = status.get("legacy_quad_visible", false)
	_expect(
		compositor_enabled != fallback_visible,
		"%s selecciona exactamente una ruta visual." % label
	)
	_expect(
		status.get("active_visual_route") in ["compositor", "legacy_quad"],
		"%s conserva un efecto submarino activo." % label
	)


func _validate_shader_contracts() -> void:
	var legacy_source := FileAccess.get_file_as_string(LEGACY_SHADER_PATH)
	for token: String in [
		"camera_submersion",
		"underwater_tint",
		"tint_strength",
		"contrast",
		"fog_density",
		"blur_strength",
	]:
		_expect(
			legacy_source.contains(token),
			"El fallback conserva %s." % token
		)
	var compositor_source := FileAccess.get_file_as_string(
		COMPOSITOR_SHADER_PATH
	)
	_expect(
		compositor_source.contains("layout(local_size_x"),
		"El compositor conserva su compute shader."
	)
	_expect(
		compositor_source.contains("effect_strength"),
		"El compositor recibe effect_strength."
	)
	_expect(
		compositor_source.contains("underwater_tint"),
		"El compositor conserva el tinte submarino."
	)


func _expect(condition: bool, message: String) -> void:
	if condition:
		print("PASS: ", message)
		return
	_failed = true
	push_error("FAIL: %s" % message)
