extends SceneTree

const MAIN_SCENE := "res://scenes/levels/island_test/island_test_BLENDER.tscn"
const EPSILON := 0.001

var _failed := false


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var manager := root.get_node_or_null("GraphicsQualityManager")
	_expect(manager != null, "GraphicsQualityManager está registrado como Autoload.")
	_expect(
		Engine.max_fps == 0,
		"El juego arranca sin limitador interno de FPS."
	)
	var packed := load(MAIN_SCENE) as PackedScene
	_expect(packed != null, "La escena principal carga con el menú reutilizable.")
	if manager == null or packed == null:
		_finish()
		return
	_validate_command_line_overrides(manager)
	_validate_persistence(manager)
	var island := packed.instantiate()
	root.add_child(island)
	current_scene = island
	await _wait_frames(4)

	var viewport := root
	var world_environment := island.get_node_or_null(
		"Environment/WorldEnvironment"
	) as WorldEnvironment
	var directional_light := island.get_node_or_null(
		"Environment/DirectionalLight3D"
	) as DirectionalLight3D
	var omni_light := island.get_node_or_null(
		"Environment/Light/OmniLight3D"
	) as OmniLight3D
	var reflection_probe := island.get_node_or_null(
		"Environment/ReflectionProbe"
	) as ReflectionProbe
	var pause_menu := island.get_node_or_null("PauseMenu") as CanvasLayer
	_expect(world_environment != null, "El WorldEnvironment objetivo existe.")
	_expect(directional_light != null, "La luz direccional objetivo existe.")
	_expect(omni_light != null, "La luz Omni objetivo existe.")
	_expect(reflection_probe != null, "La ReflectionProbe objetivo existe.")
	_expect(pause_menu != null, "El menú de pausa está instanciado.")
	if (
		world_environment == null
		or directional_light == null
		or omni_light == null
		or reflection_probe == null
		or pause_menu == null
	):
		island.free()
		_finish()
		return

	_validate_low(
		manager,
		viewport,
		world_environment,
		directional_light,
		omni_light,
		reflection_probe
	)
	_validate_medium(
		manager,
		viewport,
		world_environment,
		directional_light,
		omni_light,
		reflection_probe
	)
	_validate_high(
		manager,
		viewport,
		world_environment,
		directional_light,
		omni_light,
		reflection_probe
	)
	await _validate_pause_menu(manager, pause_menu)

	manager.set_quality(manager.Quality.HIGH, false)
	current_scene = null
	island.free()
	packed = null
	await process_frame
	await process_frame
	_finish()


func _validate_low(
	manager: Node,
	viewport: Viewport,
	world_environment: WorldEnvironment,
	directional_light: DirectionalLight3D,
	omni_light: OmniLight3D,
	reflection_probe: ReflectionProbe
) -> void:
	Engine.max_fps = 37
	manager.set_quality(manager.Quality.LOW, false)
	var environment := world_environment.environment
	_expect(
		Engine.max_fps == 0,
		"LOW elimina cualquier limitador interno previo."
	)
	_expect(_near(viewport.scaling_3d_scale, 0.5), "LOW aplica escala 3D 0.50.")
	_expect(
		viewport.scaling_3d_mode == Viewport.SCALING_3D_MODE_FSR,
		"LOW utiliza FSR 1."
	)
	_expect(
		viewport.screen_space_aa == Viewport.SCREEN_SPACE_AA_FXAA,
		"LOW utiliza FXAA."
	)
	_expect(not environment.ssr_enabled, "LOW mantiene desactivado el SSR general.")
	_expect(
		not environment.ssao_enabled
		and not environment.ssil_enabled
		and not environment.glow_enabled,
		"LOW desactiva SSAO, SSIL y glow."
	)
	_expect(
		_near(directional_light.directional_shadow_max_distance, 120.0)
		and directional_light.directional_shadow_mode
			== DirectionalLight3D.SHADOW_ORTHOGONAL,
		"LOW aplica sombra direccional de una región a 120 m."
	)
	_expect(not omni_light.shadow_enabled, "LOW desactiva sombras Omni.")
	_expect(not reflection_probe.visible, "LOW desactiva la ReflectionProbe.")
	_expect(
		environment.sky.radiance_size == Sky.RADIANCE_SIZE_64,
		"LOW aplica radiancia de cielo 64."
	)


func _validate_medium(
	manager: Node,
	viewport: Viewport,
	world_environment: WorldEnvironment,
	directional_light: DirectionalLight3D,
	omni_light: OmniLight3D,
	reflection_probe: ReflectionProbe
) -> void:
	Engine.max_fps = 37
	manager.set_quality(manager.Quality.MEDIUM, false)
	var environment := world_environment.environment
	_expect(
		Engine.max_fps == 0,
		"MEDIUM elimina cualquier limitador interno previo."
	)
	_expect(_near(viewport.scaling_3d_scale, 0.67), "MEDIUM aplica escala 3D 0.67.")
	_expect(
		viewport.screen_space_aa == Viewport.SCREEN_SPACE_AA_SMAA,
		"MEDIUM utiliza SMAA."
	)
	_expect(not environment.ssr_enabled, "MEDIUM mantiene desactivado el SSR general.")
	_expect(
		environment.ssao_enabled
		and not environment.ssil_enabled
		and environment.glow_enabled,
		"MEDIUM activa SSAO y glow, y desactiva SSIL."
	)
	_expect(
		_near(directional_light.directional_shadow_max_distance, 250.0)
		and directional_light.directional_shadow_mode
			== DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS,
		"MEDIUM aplica PSSM 2 splits a 250 m."
	)
	_expect(not omni_light.shadow_enabled, "MEDIUM desactiva sombras Omni.")
	_expect(
		reflection_probe.visible and not reflection_probe.enable_shadows,
		"MEDIUM activa la probe sin sombras."
	)
	_expect(
		environment.sky.radiance_size == Sky.RADIANCE_SIZE_128,
		"MEDIUM aplica radiancia de cielo 128."
	)


func _validate_high(
	manager: Node,
	viewport: Viewport,
	world_environment: WorldEnvironment,
	directional_light: DirectionalLight3D,
	omni_light: OmniLight3D,
	reflection_probe: ReflectionProbe
) -> void:
	Engine.max_fps = 37
	manager.set_quality(manager.Quality.HIGH, false)
	var environment := world_environment.environment
	_expect(
		Engine.max_fps == 0,
		"HIGH elimina cualquier limitador interno previo."
	)
	var expected_scale := 0.77 if manager.is_steam_deck else 1.0
	_expect(
		_near(viewport.scaling_3d_scale, expected_scale),
		"HIGH aplica la escala 3D correcta para la plataforma."
	)
	_expect(not environment.ssr_enabled, "HIGH mantiene desactivado el SSR general.")
	_expect(
		environment.ssao_enabled
		and environment.ssil_enabled
		and environment.glow_enabled,
		"HIGH activa SSAO, SSIL y glow."
	)
	_expect(
		_near(environment.ssao_radius, 2.5)
		and _near(environment.ssao_detail, 0.7)
		and _near(environment.ssao_power, 1.35)
		and _near(environment.ssil_radius, 16.0)
		and _near(environment.ssil_intensity, 2.94),
		"HIGH conserva los parámetros visuales actuales de SSAO y SSIL."
	)
	_expect(
		_near(directional_light.directional_shadow_max_distance, 500.0)
		and _near(directional_light.shadow_blur, 3.796),
		"HIGH conserva distancia y blur de sombra actuales."
	)
	_expect(omni_light.shadow_enabled, "HIGH activa sombras Omni.")
	_expect(
		reflection_probe.visible and reflection_probe.enable_shadows,
		"HIGH activa la probe con sombras."
	)
	_expect(
		environment.sky.radiance_size == Sky.RADIANCE_SIZE_256,
		"HIGH aplica radiancia de cielo 256."
	)


func _validate_pause_menu(manager: Node, pause_menu: CanvasLayer) -> void:
	var open_event := InputEventAction.new()
	open_event.action = &"pause_menu"
	open_event.pressed = true
	Input.parse_input_event(open_event)
	await process_frame
	_expect(pause_menu.visible and paused, "La acción pause_menu abre y pausa el juego.")
	var original_path: String = manager.get("_settings_path")
	var test_path := "res://.godot/codex_pause_menu_settings_validation.cfg"
	var absolute_test_path := ProjectSettings.globalize_path(test_path)
	if FileAccess.file_exists(test_path):
		DirAccess.remove_absolute(absolute_test_path)
	manager.set("_settings_path", test_path)
	var low_button := pause_menu.get_node(
		"Overlay/CenterContainer/PanelContainer/MarginContainer/VBoxContainer/"
		+ "QualityButtons/LowButton"
	) as Button
	var applying_label := pause_menu.get_node(
		"Overlay/CenterContainer/PanelContainer/MarginContainer/VBoxContainer/"
		+ "ApplyingLabel"
	) as Label
	low_button.grab_focus()
	low_button.pressed.emit()
	_expect(applying_label.visible, "El menú muestra “Aplicando…” durante el cambio.")
	await _wait_frames(3)
	var config := ConfigFile.new()
	var load_error := config.load(test_path)
	_expect(
		manager.current_quality == manager.Quality.LOW
		and pause_menu.visible
		and paused,
		"El botón aplica LOW sin reanudar el juego."
	)
	_expect(
		Engine.max_fps == 0,
		"El cambio desde el menú mantiene los FPS internos ilimitados."
	)
	_expect(
		low_button.button_pressed
		and pause_menu.get_viewport().gui_get_focus_owner() == low_button,
		"El botón muestra la selección y conserva el foco."
	)
	_expect(
		load_error == OK
		and config.get_value("graphics", "quality", -1) == manager.Quality.LOW,
		"El cambio desde el menú se guarda inmediatamente."
	)
	if FileAccess.file_exists(test_path):
		DirAccess.remove_absolute(absolute_test_path)
	manager.set("_settings_path", original_path)
	var close_event := InputEventAction.new()
	close_event.action = &"pause_menu"
	close_event.pressed = true
	Input.parse_input_event(close_event)
	await process_frame
	_expect(not pause_menu.visible and not paused, "La acción pause_menu cierra y reanuda.")
	_expect(
		not bool(manager.restart_required),
		"Los presets y el menú no requieren reiniciar."
	)


func _validate_command_line_overrides(manager: Node) -> void:
	var arguments := OS.get_cmdline_args()
	for user_argument: String in OS.get_cmdline_user_args():
		if user_argument not in arguments:
			arguments.append(user_argument)
	if "--force-steam-deck" in arguments:
		_expect(manager.is_steam_deck, "--force-steam-deck activa la detección de Deck.")
	for argument: String in arguments:
		if not argument.begins_with("--graphics-preset="):
			continue
		var expected_quality: int = -1
		match argument.trim_prefix("--graphics-preset=").to_lower():
			"low":
				expected_quality = manager.Quality.LOW
			"medium":
				expected_quality = manager.Quality.MEDIUM
			"high":
				expected_quality = manager.Quality.HIGH
		if expected_quality >= 0:
			_expect(
				manager.current_quality == expected_quality,
				"El override %s selecciona el preset inicial." % argument
			)


func _validate_persistence(manager: Node) -> void:
	for argument: String in OS.get_cmdline_args():
		if argument.begins_with("--graphics-preset="):
			return
	for argument: String in OS.get_cmdline_user_args():
		if argument.begins_with("--graphics-preset="):
			return
	var original_path: String = manager.get("_settings_path")
	var test_path := "res://.godot/codex_graphics_settings_validation.cfg"
	var absolute_test_path := ProjectSettings.globalize_path(test_path)
	if FileAccess.file_exists(test_path):
		DirAccess.remove_absolute(absolute_test_path)
	manager.set("_settings_path", test_path)
	_expect(
		manager.current_quality == manager.Quality.HIGH,
		"El arranque normal selecciona siempre HIGH."
	)
	manager.set_quality(manager.Quality.LOW, true)
	var config := ConfigFile.new()
	var load_error := config.load(test_path)
	_expect(
		load_error == OK
		and config.get_value("graphics", "quality", -1) == manager.Quality.LOW,
		"La selección se guarda como [graphics] quality."
	)
	_expect(
		manager.call("_get_startup_quality") == manager.Quality.HIGH,
		"Una selección LOW guardada no sustituye HIGH al arrancar."
	)
	config.set_value("graphics", "quality", "corrupt")
	config.save(test_path)
	_expect(
		manager.call("_get_startup_quality") == manager.Quality.HIGH,
		"Un archivo corrupto tampoco sustituye HIGH al arrancar."
	)
	DirAccess.remove_absolute(absolute_test_path)
	_expect(
		manager.call("_get_startup_quality") == manager.Quality.HIGH,
		"La primera ejecución usa HIGH en todas las plataformas."
	)
	manager.set("_settings_path", original_path)


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
		print("GRAPHICS QUALITY VALIDATION: FAILED")
		quit(1)
	else:
		print("GRAPHICS QUALITY VALIDATION: PASS")
		quit(0)
