extends Node

## Headless validation for PersistentFoamMask3D ("Persistent Foam V2").
##
## Proves that deposited splats are anchored to fixed world XZ: steering,
## aging and repeated mask repaints never move old splats, and only an explicit
## world rebase shifts them (by the exact rebase shift). Also verifies Ocean3D
## provider registration (texture, anchor, world size, strength, enabled) and
## lifetime expiry.
##
## Run from the editor or CLI:
##   godot --headless --path game res://dev/tests/persistent_foam/validate_persistent_foam_v2.tscn

const MASK_SCENE_PATH := "res://gameplay/vehicles/common/water_effects/persistent_foam/persistent_foam_mask_3d.tscn"
const OCEAN_SHADER_PATH := "res://world/water/ocean/shaders/ocean_water_custom_ssr.gdshader"

var _failures: Array[String] = []


class FakeOcean extends Ocean3D:
	var sim_time: float = 17.0

	func get_simulation_time() -> float:
		return sim_time

	func sample_base_surface(
		world_position: Vector3,
		out_sample: WaterSample3D = null
	) -> WaterSample3D:
		var result := out_sample.reset() if out_sample != null else WaterSample3D.new()
		result.surface_position = Vector3(world_position.x, 1.0, world_position.z)
		result.normal = Vector3.UP
		result.signed_depth = 0.0
		result.provider = self
		result.valid = true
		return result


func _ready() -> void:
	call_deferred("_run_validation")


func _run_validation() -> void:
	var mask: PersistentFoamMask3D = load(MASK_SCENE_PATH).instantiate()
	get_tree().root.add_child(mask)

	var fake_ocean := FakeOcean.new()
	var probe := ShaderMaterial.new()
	probe.shader = load(OCEAN_SHADER_PATH)
	fake_ocean.register_external_water_material(probe)

	mask.configure(null, fake_ocean, null, null, null)
	mask.strength = 1.0
	mask.enabled = true

	## Provider registration must reach the ocean materials.
	_expect_equal("ocean mask enabled param", _read_param(probe, "persistent_foam_mask_enabled"), true)
	var mask_texture: Variant = probe.get_shader_parameter("persistent_foam_mask_texture")
	_expect_true("ocean mask texture is a Texture2D", mask_texture is Texture2D and mask_texture != null)
	_expect_vector2_close(
		"ocean mask anchor",
		_read_param(probe, "persistent_foam_mask_anchor_xz"),
		Vector2.ZERO,
		0.001
	)
	_expect_close(
		"ocean mask world size",
		_read_param(probe, "persistent_foam_mask_world_size"),
		512.0,
		0.001
	)
	_expect_close(
		"ocean mask strength",
		_read_param(probe, "persistent_foam_mask_strength"),
		1.0,
		0.001
	)
	_expect_true("mask reports enabled", mask.is_mask_enabled())
	## Appearance uniforms must reach the ocean from provider defaults.
	_expect_close(
		"ocean persistent foam irregularity",
		_read_param(probe, "persistent_foam_irregularity"),
		0.80,
		0.001
	)
	_expect_close(
		"ocean persistent foam noise scale",
		_read_param(probe, "persistent_foam_noise_scale"),
		0.12,
		0.001
	)
	_expect_close(
		"ocean persistent foam noise threshold",
		_read_param(probe, "persistent_foam_noise_threshold"),
		0.48,
		0.001
	)
	_expect_true(
		"ocean persistent foam color matches provider",
		_read_param(probe, "persistent_foam_color") == Color(0.90, 0.97, 1.0, 1.0)
	)
	_expect_close("ocean persistent foam emission", _read_param(probe, "persistent_foam_emission"), 0.0, 0.001)
	_expect_close("ocean persistent foam roughness", _read_param(probe, "persistent_foam_roughness"), 0.88, 0.001)
	_expect_close("ocean persistent foam specular", _read_param(probe, "persistent_foam_specular"), 0.16, 0.001)

	## Phase A/B: deposits, then strong heading changes and new deposits.
	var straight_forward := Vector2(1.0, 0.0)
	for index in 20:
		mask.call(
			"debug_deposit_sample",
			Vector3(float(index), 0.0, 0.0),
			straight_forward,
			1.2,
			1.0
		)
	_expect_equal("sample count after 20 deposits", mask.sample_count, 20)

	var captured_count: int = mask.begin_position_validation(20)
	_expect_equal("captured samples", captured_count, 20)
	var origin_positions: Array[Vector2] = []
	var origin_rotations: Array[float] = []
	var origin_scale_x: Array[float] = []
	var origin_scale_y: Array[float] = []
	var origin_seeds: Array[float] = []
	for index in 20:
		var splat := mask._splats[index]
		origin_positions.append(splat.position_xz)
		origin_rotations.append(splat.rotation)
		origin_scale_x.append(splat.scale_x)
		origin_scale_y.append(splat.scale_y)
		origin_seeds.append(splat.random_seed)

	var turn_forward := Vector2(1.0, 1.0).normalized()
	for index in 8:
		mask.call(
			"debug_deposit_sample",
			Vector3(20.0 + float(index) * 0.8, 0.0, 0.6 + float(index) * 0.6),
			turn_forward,
			1.2,
			1.0
		)
	for index in 8:
		mask.call(
			"debug_deposit_sample",
			Vector3(26.4 - float(index) * 0.7, 0.0, 5.4 - float(index) * 0.7),
			Vector2(-0.5, 0.8660254),
			1.2,
			1.0
		)

	## Age and repeatedly repaint the mask.
	fake_ocean.sim_time += 3.0
	var paint_before: int = mask.paint_count
	for repaint_index in 10:
		mask._sync_draw_dirty()
	_expect_true(
		"mask repainted at least 10 times",
		mask.paint_count - paint_before >= 10
	)

	var status: Dictionary = mask.get_position_validation_status()
	_expect_equal("living samples after heading/age/repaint", status.living_samples, 20)
	_expect_equal(
		"max_horizontal_position_delta = 0.0",
		status.max_horizontal_position_delta,
		0.0
	)
	var unchanged := true
	for index in 20:
		if not mask._splats[index].position_xz.is_equal_approx(origin_positions[index]):
			unchanged = false
			break
	_expect_true("stored XZ unchanged by deposits/age/repaints", unchanged)

	## Per-splat visual randomness must be generated once and stay frozen:
	## new deposits, aging and 10 repaints never change stored values.
	var rotation_delta := 0.0
	var scale_delta := 0.0
	var seed_delta := 0.0
	for index in 20:
		var splat := mask._splats[index]
		rotation_delta = maxf(rotation_delta, absf(splat.rotation - origin_rotations[index]))
		var sx := absf(splat.scale_x - origin_scale_x[index])
		var sy := absf(splat.scale_y - origin_scale_y[index])
		scale_delta = maxf(scale_delta, maxf(sx, sy))
		seed_delta = maxf(seed_delta, absf(splat.random_seed - origin_seeds[index]))
	_expect_close("random rotation delta = 0.0", rotation_delta, 0.0, 0.0)
	_expect_close("random scale delta = 0.0", scale_delta, 0.0, 0.0)
	_expect_close("random seed delta = 0.0", seed_delta, 0.0, 0.0)

	## Repaint stability: reread the same splat properties after a fresh paint.
	rotation_delta = 0.0
	scale_delta = 0.0
	seed_delta = 0.0
	mask._sync_draw_dirty()
	mask._sync_draw_dirty()
	for index in 20:
		var splat := mask._splats[index]
		rotation_delta = maxf(rotation_delta, absf(splat.rotation - origin_rotations[index]))
		scale_delta = maxf(
			scale_delta,
			maxf(
				absf(splat.scale_x - origin_scale_x[index]),
				absf(splat.scale_y - origin_scale_y[index])
			)
		)
		seed_delta = maxf(seed_delta, absf(splat.random_seed - origin_seeds[index]))
	_expect_close("random rotation delta after repaint = 0.0", rotation_delta, 0.0, 0.0)
	_expect_close("random scale delta after repaint = 0.0", scale_delta, 0.0, 0.0)
	_expect_close("random seed delta after repaint = 0.0", seed_delta, 0.0, 0.0)

	## Phase C: world rebase shifts stored XZ by EXACT shift only.
	var shift := Vector3(16.0, 0.0, 8.0)
	mask.apply_world_rebase(shift)
	status = mask.get_position_validation_status()
	var expected_shift_length := Vector2(shift.x, shift.z).length()
	_expect_close(
		"delta after rebase equals shift length",
		status.max_horizontal_position_delta,
		expected_shift_length,
		0.001
	)
	var exact_shift := true
	for index in 20:
		var expected := origin_positions[index] + Vector2(shift.x, shift.z)
		if not mask._splats[index].position_xz.is_equal_approx(expected):
			exact_shift = false
			break
	_expect_true("stored XZ shifted by EXACT rebase shift", exact_shift)
	fake_ocean._update_persistent_foam_mask_push_if_dirty()
	_expect_vector2_close(
		"ocean mask anchor updated after rebase",
		_read_param(probe, "persistent_foam_mask_anchor_xz"),
		Vector2(shift.x, shift.z),
		0.001
	)

	## Random properties survive world rebase unmodified.
	rotation_delta = 0.0
	scale_delta = 0.0
	seed_delta = 0.0
	for index in 20:
		var splat := mask._splats[index]
		rotation_delta = maxf(rotation_delta, absf(splat.rotation - origin_rotations[index]))
		scale_delta = maxf(
			scale_delta,
			maxf(
				absf(splat.scale_x - origin_scale_x[index]),
				absf(splat.scale_y - origin_scale_y[index])
			)
		)
		seed_delta = maxf(seed_delta, absf(splat.random_seed - origin_seeds[index]))
	_expect_close("random rotation delta after rebase = 0.0", rotation_delta, 0.0, 0.0)
	_expect_close("random scale delta after rebase = 0.0", scale_delta, 0.0, 0.0)
	_expect_close("random seed delta after rebase = 0.0", seed_delta, 0.0, 0.0)

	## Appearance changes must reach the ocean uniforms on push.
	var custom_color := Color(0.4, 0.5, 0.6, 1.0)
	mask.irregularity = 0.9
	mask.noise_scale = 0.2
	mask.noise_threshold = 0.4
	mask.foam_color = custom_color
	mask.emission = 1.5
	mask.roughness = 0.5
	mask.specular = 0.3
	fake_ocean._update_persistent_foam_mask_push_if_dirty()
	_expect_close("ocean persistent foam irregularity updated", _read_param(probe, "persistent_foam_irregularity"), 0.9, 0.001)
	_expect_close("ocean persistent foam noise scale updated", _read_param(probe, "persistent_foam_noise_scale"), 0.2, 0.001)
	_expect_close("ocean persistent foam noise threshold updated", _read_param(probe, "persistent_foam_noise_threshold"), 0.4, 0.001)
	_expect_true("ocean persistent foam color updated", _read_param(probe, "persistent_foam_color") == custom_color)
	_expect_close("ocean persistent foam emission updated", _read_param(probe, "persistent_foam_emission"), 1.5, 0.001)
	_expect_close("ocean persistent foam roughness updated", _read_param(probe, "persistent_foam_roughness"), 0.5, 0.001)
	_expect_close("ocean persistent foam specular updated", _read_param(probe, "persistent_foam_specular"), 0.3, 0.001)

	## Visual lifecycle mathematics: fade-in, stable middle, fade-out, growth.
	mask.size_min = 0.55
	mask.size_max = 1.55
	mask.fade_in_ratio = 0.10
	mask.fade_out_start_ratio = 0.70
	mask.lifetime = 10.0
	var painter := mask._canvas
	var birth_alpha: float = painter.evaluate_life_alpha(0.0)
	var early_alpha: float = painter.evaluate_life_alpha(0.02 * mask.lifetime)
	var after_fade_alpha: float = painter.evaluate_life_alpha(0.20 * mask.lifetime)
	var middle_alpha: float = painter.evaluate_life_alpha(0.40 * mask.lifetime)
	var death_alpha: float = painter.evaluate_life_alpha(0.99 * mask.lifetime)
	_expect_close("alpha at birth ~ 0", birth_alpha, 0.0, 0.001)
	_expect_true("alpha rises from zero early on", early_alpha > 0.0 and early_alpha < 0.5)
	_expect_close("alpha after fade-in ~ 1", after_fade_alpha, 1.0, 0.001)
	_expect_close("alpha in middle life ~ 1", middle_alpha, 1.0, 0.001)
	_expect_close("alpha at death ~ 0", death_alpha, 0.0, 0.02)
	var growth_birth: float = painter.evaluate_growth(0.0)
	var growth_mid: float = painter.evaluate_growth(0.5 * mask.lifetime)
	var growth_end: float = painter.evaluate_growth(mask.lifetime)
	_expect_close("growth at birth == size_min", growth_birth, 0.55, 0.001)
	_expect_true("growth mid strictly between min and max", growth_mid > 0.55 and growth_mid < 1.55)
	_expect_close("growth at end == size_max", growth_end, 1.55, 0.001)
	var splat_radius := 1.2
	var birth_radius := splat_radius * growth_birth
	var middle_radius := splat_radius * growth_mid
	var end_radius := splat_radius * growth_end
	_expect_true(
		"radius_at_birth < radius_at_middle < radius_at_end",
		birth_radius < middle_radius and middle_radius < end_radius
	)

	## Phase D: lifetime expiry removes splats and the mask empties.
	mask.clear_trail()
	mask.lifetime = 3.0
	for index in 10:
		mask.call(
			"debug_deposit_sample",
			Vector3(float(index), 0.0, 100.0),
			Vector2(0.0, 1.0),
			1.2,
			1.0
		)
	_expect_equal("sample count after expiry deposits", mask.sample_count, 10)
	fake_ocean.sim_time += 4.0
	mask._physics_process(0.016)
	_expect_equal("sample_count after lifetime expiry", mask.sample_count, 0)
	_expect_equal("canvas has no splats after expiry", mask._canvas.splats.size(), 0)

	## Phase E: disabled state must disable the ocean mask input.
	mask.enabled = false
	_expect_true("mask reports disabled", not mask.is_mask_enabled())
	_expect_close("mask strength reported as 0 when disabled", mask.get_mask_strength(), 0.0, 0.001)
	_expect_equal(
		"ocean mask enabled param after disable",
		_read_param(probe, "persistent_foam_mask_enabled"),
		false
	)

	print("PERSISTENT_FOAM_V2_VALIDATION")
	print("  mask_status=", status)
	print("  expected_rebase_shift_length=", expected_shift_length)
	print("  paint_count=", mask.paint_count)
	print("  rebase_count=", mask.rebase_count)

	if _failures.is_empty():
		print("RESULT: PASS")
		get_tree().quit(0)
	else:
		for failure in _failures:
			push_error("VALIDATION FAILURE: " + failure)
		print("RESULT: FAIL (%d)" % _failures.size())
		get_tree().quit(1)


func _read_param(material: ShaderMaterial, parameter: StringName) -> Variant:
	return material.get_shader_parameter(parameter)


func _expect_true(label: String, value: bool) -> void:
	if value:
		print("  OK ", label)
	else:
		_failures.append(label)
		print("  FAIL ", label)


func _expect_equal(label: String, actual: Variant, expected: Variant) -> void:
	if actual == expected:
		print("  OK ", label, " = ", str(actual))
	else:
		_failures.append(label + " -> expected " + str(expected) + " got " + str(actual))
		print("  FAIL ", label, " expected=", expected, " got=", actual)


func _expect_close(label: String, actual: Variant, expected: float, tolerance: float) -> void:
	if typeof(actual) != TYPE_FLOAT and typeof(actual) != TYPE_INT:
		_failures.append(label + " -> expected ~" + str(expected) + " got " + str(actual))
		print("  FAIL ", label, " expected~=", expected, " got=", actual)
		return
	var actual_float := float(actual)
	if absf(actual_float - expected) <= tolerance:
		print("  OK ", label, " = ", str(actual_float))
	else:
		_failures.append(label + " -> expected ~" + str(expected) + " got " + str(actual_float))
		print("  FAIL ", label, " expected~=", expected, " got=", actual_float)


func _expect_vector2_close(label: String, actual: Variant, expected: Vector2, tolerance: float) -> void:
	if typeof(actual) != TYPE_VECTOR2:
		_failures.append(label + " -> expected ~" + str(expected) + " got " + str(actual))
		print("  FAIL ", label, " expected~=", expected, " got=", actual)
		return
	var actual_vector: Vector2 = actual
	if actual_vector.distance_to(expected) <= tolerance:
		print("  OK ", label, " = ", str(actual_vector))
	else:
		_failures.append(label + " -> expected ~" + str(expected) + " got " + str(actual_vector))
		print("  FAIL ", label, " expected~=", expected, " got=", actual_vector)