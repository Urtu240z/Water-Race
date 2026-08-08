extends SceneTree

const MAIN_SCENE := "res://levels/paradise_island/island_test_BLENDER.tscn"
const CAPTURE_DIRECTORY := "res://.godot"
const MINIMUM_VISIBLE_DIFFERENCE := 0.025

var _failed := false


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var packed := load(MAIN_SCENE) as PackedScene
	if packed == null:
		_fail("Could not load main scene.")
		quit(1)
		return
	var island := packed.instantiate()
	root.add_child(island)
	current_scene = island
	await _wait_frames(30)
	var manager := root.get_node_or_null("GraphicsQualityManager")
	var underwater := island.get_node_or_null(
		"CameraSystem/ChaseCamera/Camera3D/UnderwaterEffect"
	) as UnderwaterEffectController
	if manager == null or underwater == null:
		_fail("Missing graphics manager or underwater controller.")
		quit(1)
		return
	underwater.process_mode = Node.PROCESS_MODE_ALWAYS
	paused = true
	manager.set_quality(manager.Quality.HIGH, false)
	while manager.is_applying:
		await process_frame
	await _wait_frames(3)
	var camera := underwater.get("_camera") as Camera3D
	var environment := camera.get_world_3d().environment
	var original_environment := _capture_environment_state(environment)

	underwater.force_mode = UnderwaterEffectController.DebugForceMode.FORCE_AIR
	await _wait_frames(12)
	var air_image := await _capture("underwater_runtime_air.png")
	_validate_air_state(underwater)

	for quality: int in [
		manager.Quality.HIGH,
		manager.Quality.MEDIUM,
		manager.Quality.LOW,
		manager.Quality.HIGH,
	]:
		underwater.force_mode = (
			UnderwaterEffectController.DebugForceMode.FORCE_UNDERWATER
		)
		manager.set_quality(quality, false)
		while manager.is_applying:
			await process_frame
		await _wait_frames(8)
		var quality_name: String = manager.get_quality_name(quality).to_lower()
		var image := await _capture(
			"underwater_runtime_%s.png" % quality_name
		)
		var difference := _sample_image_difference(air_image, image)
		var status := underwater.get_underwater_runtime_debug_status()
		print(
			"UNDERWATER_%s_STATUS=" % quality_name.to_upper(),
			status
		)
		print(
			"UNDERWATER_%s_IMAGE_DIFFERENCE=" % quality_name.to_upper(),
			difference
		)
		_validate_underwater_state(
			underwater,
			status,
			difference,
			quality_name
		)
		_expect(
			environment.volumetric_fog_enabled,
			"%s: underwater volumetric fog was not restored." % quality_name
		)
		_expect(
			not environment.fog_enabled,
			"%s: depth fog overlaps underwater volumetric fog." % quality_name
		)

	# Exercise the existing legacy quad deliberately and prove that only one
	# visual route is enabled.
	underwater.force_legacy_fallback = true
	await _wait_frames(4)
	var fallback_image := await _capture(
		"underwater_runtime_fallback.png"
	)
	var fallback_status := underwater.get_underwater_runtime_debug_status()
	var fallback_difference := _sample_image_difference(
		air_image,
		fallback_image
	)
	print("UNDERWATER_FALLBACK_STATUS=", fallback_status)
	print("UNDERWATER_FALLBACK_IMAGE_DIFFERENCE=", fallback_difference)
	_expect(
		fallback_status.get("active_visual_route") == "legacy_quad",
		"Fallback did not select the legacy quad."
	)
	_expect(
		not fallback_status.get("compositor_effect_enabled", true),
		"Fallback left the compositor enabled."
	)
	_expect(
		fallback_status.get("legacy_quad_visible", false),
		"Fallback quad is not visible."
	)
	_expect(
		fallback_difference >= MINIMUM_VISIBLE_DIFFERENCE,
		"Fallback image is visually indistinguishable from air."
	)
	underwater.force_legacy_fallback = false
	await _wait_frames(4)

	# Automatic detection uses the exact Ocean3D sample under the camera.
	var ocean := underwater.get("_ocean") as Ocean3D
	underwater.force_mode = UnderwaterEffectController.DebugForceMode.AUTOMATIC
	var automatic_position := camera.global_position
	automatic_position.y = ocean.sample_height(automatic_position) - 1.0
	camera.global_position = automatic_position
	await _wait_frames(8)
	var automatic_image := await _capture(
		"underwater_runtime_automatic.png"
	)
	var automatic_status := underwater.get_underwater_runtime_debug_status()
	var automatic_difference := _sample_image_difference(
		air_image,
		automatic_image
	)
	print("UNDERWATER_AUTOMATIC_STATUS=", automatic_status)
	print(
		"UNDERWATER_AUTOMATIC_IMAGE_DIFFERENCE=",
		automatic_difference
	)
	_expect(
		automatic_status.get("camera_depth", -INF) >= underwater.enter_depth,
		"Automatic camera depth did not cross enter_depth."
	)
	_validate_underwater_state(
		underwater,
		automatic_status,
		automatic_difference,
		"automatic"
	)

	# Ten repeat entries must reuse the one attached compositor effect.
	for cycle: int in range(10):
		underwater.force_mode = (
			UnderwaterEffectController.DebugForceMode.FORCE_AIR
		)
		await _wait_frames(2)
		underwater.force_mode = (
			UnderwaterEffectController.DebugForceMode.FORCE_UNDERWATER
		)
		await _wait_frames(2)
		var cycle_status := underwater.get_underwater_runtime_debug_status()
		_expect(
			cycle_status.get("attached_underwater_effect_count", 0) == 1,
			"Cycle %s duplicated or lost the compositor effect." % cycle
		)
		_expect(
			cycle_status.get("active_visual_route") == "compositor",
			"Cycle %s lost the underwater compositor route." % cycle
		)

	underwater.force_mode = UnderwaterEffectController.DebugForceMode.FORCE_AIR
	await _wait_frames(90)
	_validate_air_state(underwater)
	_validate_environment_restored(environment, original_environment)
	var manager_status: Dictionary = manager.get_graphics_quality_debug_status()
	_expect(
		not manager_status.get("restart_required", true),
		"Graphics quality unexpectedly requires restart."
	)
	print("UNDERWATER_FINAL_STATUS=", underwater.get_underwater_runtime_debug_status())
	print("UNDERWATER_GRAPHICAL_VALIDATION=", "FAIL" if _failed else "PASS")
	print(
		"UNDERWATER_CAPTURE_DIRECTORY=",
		ProjectSettings.globalize_path(CAPTURE_DIRECTORY)
	)

	paused = false
	current_scene = null
	island.free()
	await _wait_frames(2)
	quit(1 if _failed else 0)


func _validate_underwater_state(
	underwater: UnderwaterEffectController,
	status: Dictionary,
	image_difference: float,
	label: String
) -> void:
	_expect(status.get("effect_enabled", false), "%s: effect disabled." % label)
	_expect(status.get("camera_valid", false), "%s: camera missing." % label)
	_expect(
		status.get("post_process_valid", false),
		"%s: legacy post-process missing." % label
	)
	_expect(status.get("material_valid", false), "%s: material missing." % label)
	_expect(status.get("ocean_valid", false), "%s: ocean missing." % label)
	_expect(status.get("is_underwater", false), "%s: detector is false." % label)
	_expect(
		is_equal_approx(status.get("effect_strength", 0.0), 1.0),
		"%s: effect strength is not 1." % label
	)
	_expect(
		status.get("compositor_attached", false),
		"%s: compositor not attached." % label
	)
	_expect(
		status.get("attached_underwater_effect_count", 0) == 1,
		"%s: underwater compositor is not attached exactly once." % label
	)
	_expect(
		status.get("active_visual_route") == "compositor",
		"%s: compositor is not the active visual route." % label
	)
	_expect(
		not status.get("legacy_quad_visible", true),
		"%s: compositor and legacy quad are visible together." % label
	)
	var runtime := status.get("compositor_runtime", {}) as Dictionary
	_expect(
		runtime.get("rendering_device_valid", false),
		"%s: RenderingDevice is unavailable." % label
	)
	_expect(
		runtime.get("resources_ready", false),
		"%s: compute resources are not ready." % label
	)
	_expect(
		runtime.get("pipeline_valid", false),
		"%s: compute pipeline is invalid." % label
	)
	_expect(
		runtime.get("successful_render_count", 0) > 0,
		"%s: compositor never rendered successfully." % label
	)
	_expect(
		image_difference >= MINIMUM_VISIBLE_DIFFERENCE,
		"%s: underwater image is visually indistinguishable from air." % label
	)
	_expect(
		underwater.effect_strength == 1.0,
		"%s: controller lost effect strength." % label
	)


func _validate_air_state(underwater: UnderwaterEffectController) -> void:
	var status := underwater.get_underwater_runtime_debug_status()
	_expect(
		not status.get("compositor_effect_enabled", true),
		"Compositor remained enabled in stable air."
	)
	_expect(
		not status.get("legacy_quad_visible", true),
		"Legacy quad remained visible in stable air."
	)
	_expect(
		status.get("active_visual_route") == "none",
		"Air has an active underwater visual route."
	)


func _capture(filename: String) -> Image:
	await RenderingServer.frame_post_draw
	var image := root.get_texture().get_image()
	var path := "%s/%s" % [CAPTURE_DIRECTORY, filename]
	var error := image.save_png(path)
	if error != OK:
		_fail("Could not save %s: %s." % [path, error_string(error)])
	return image


func _capture_environment_state(environment: Environment) -> Dictionary:
	return {
		"fog_enabled": environment.fog_enabled,
		"volumetric_fog_enabled": environment.volumetric_fog_enabled,
		"volumetric_fog_density": environment.volumetric_fog_density,
		"volumetric_fog_albedo": environment.volumetric_fog_albedo,
		"volumetric_fog_emission": environment.volumetric_fog_emission,
		"volumetric_fog_emission_energy":
			environment.volumetric_fog_emission_energy,
		"volumetric_fog_length": environment.volumetric_fog_length,
		"volumetric_fog_detail_spread":
			environment.volumetric_fog_detail_spread,
		"volumetric_fog_ambient_inject":
			environment.volumetric_fog_ambient_inject,
		"volumetric_fog_sky_affect": environment.volumetric_fog_sky_affect,
	}


func _validate_environment_restored(
	environment: Environment,
	original: Dictionary
) -> void:
	var restored := _capture_environment_state(environment)
	for key: String in original:
		var expected: Variant = original[key]
		var actual: Variant = restored[key]
		var equal: bool = expected == actual
		if expected is float:
			equal = is_equal_approx(expected, actual)
		elif expected is Color:
			equal = expected.is_equal_approx(actual)
		_expect(
			equal,
			"Environment field %s was not restored exactly." % key
		)


func _sample_image_difference(left: Image, right: Image) -> float:
	if left == null or right == null or left.get_size() != right.get_size():
		return -1.0
	var accumulated := 0.0
	var sample_count := 0
	for y: int in range(0, left.get_height(), 8):
		for x: int in range(0, left.get_width(), 8):
			var left_color := left.get_pixel(x, y)
			var right_color := right.get_pixel(x, y)
			accumulated += (
				absf(left_color.r - right_color.r)
				+ absf(left_color.g - right_color.g)
				+ absf(left_color.b - right_color.b)
			) / 3.0
			sample_count += 1
	return accumulated / float(maxi(sample_count, 1))


func _expect(condition: bool, message: String) -> void:
	if not condition:
		_fail(message)


func _fail(message: String) -> void:
	_failed = true
	push_error(message)


func _wait_frames(frame_count: int) -> void:
	for _index: int in frame_count:
		await process_frame
