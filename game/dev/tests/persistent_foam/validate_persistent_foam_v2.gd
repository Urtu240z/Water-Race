extends Node

## Headless validation for PersistentFoamTrail3D ("Persistent Foam V2").
## Proves that stored foam samples are anchored to fixed world XZ:
## turning, aging, new deposits and mesh rebuilds never move old samples,
## and only an explicit world rebase shifts them (the documented exception).
##
## Run from the editor or CLI:
##   godot --headless --path game res://dev/tests/persistent_foam/validate_persistent_foam_v2.tscn

const TRAIL_SCENE_PATH := "res://gameplay/vehicles/common/water_effects/persistent_foam/persistent_foam_trail_3d.tscn"
const DEFAULT_FOAM_SETTINGS_PATH := "res://world/water/ocean/foam/default_foam_settings.tres"
const FOAM_NOISE_PATH := "res://world/water/ocean/foam/foam_breakup_noise.tres"

var _failures: Array[String] = []


class FakeOcean extends Ocean3D:
	var sample_height_value: float = 1.0

	func sample_base_surface(
		world_position: Vector3,
		out_sample: WaterSample3D = null
	) -> WaterSample3D:
		var result := out_sample.reset() if out_sample != null else WaterSample3D.new()
		result.surface_position = Vector3(
			world_position.x,
			sample_height_value,
			world_position.z
		)
		result.normal = Vector3.UP
		result.signed_depth = 0.0
		result.provider = self
		result.valid = true
		return result

	func get_simulation_time() -> float:
		return 17.0


func _ready() -> void:
	var trail: Node3D = load(TRAIL_SCENE_PATH).instantiate()
	get_tree().root.add_child(trail)

	var foam_settings := load(DEFAULT_FOAM_SETTINGS_PATH) as WaterFoamSettings
	var noise_texture := load(FOAM_NOISE_PATH) as Texture2D
	var fake_ocean := FakeOcean.new()

	trail.call("configure", null, fake_ocean, null, null, null)
	trail.call("configure_foam", foam_settings, noise_texture)
	trail.enabled = true
	trail.lifetime = 20.0
	trail.sample_distance = 0.8
	trail.maximum_points = 256
	trail.width_multiplier = 1.0
	trail.strength = 1.0

	## Phase A/B: straight run, turn, aging, extra deposits, rebuilds.
	## All old samples must keep their exact deposited XZ.
	var straight_forward := Vector2(1.0, 0.0)
	for index in 20:
		trail.call(
			"debug_deposit_sample",
			Vector3(float(index), 0.0, 0.0),
			straight_forward,
			1.2,
			1.0
		)
	trail._force_mesh_rebuild = true
	trail._update_mesh_tick(1.0 / 30.0)
	var first_vertex_xz := _capture_vertex_xz(trail)

	var captured_count: int = trail.begin_position_validation(20)

	# Boat turns hard 90 then 180 degrees: subsequent deposits use new headings,
	# while the old ribbon region must keep its geometry byte-for-byte in XZ.
	var turn_forward := Vector2(1.0, 1.0).normalized()
	for index in 8:
		trail.call(
			"debug_deposit_sample",
			Vector3(20.0 + float(index) * 0.8, 0.0, 0.6 + float(index) * 0.6),
			turn_forward,
			1.2,
			1.0
		)
	var reverse_half_turn := Vector2(-0.5, 0.8660254)
	for index in 8:
		trail.call(
			"debug_deposit_sample",
			Vector3(26.4 - float(index) * 0.7, 0.0, 5.4 - float(index) * 0.7),
			reverse_half_turn,
			1.2,
			1.0
		)

	# Aging a few seconds and many rebuilds must not disturb stored positions.
	trail._age_samples(3.0)
	for tick in 30:
		trail._update_mesh_tick(1.0 / 30.0)

	var status: Dictionary = trail.get_position_validation_status()
	var second_vertex_xz := _capture_vertex_xz(trail)
	var geometry_region_delta := _region_delta(first_vertex_xz, second_vertex_xz, 40)

	_expect_equal("captured samples", captured_count, 20)
	_expect_equal(
		"living samples after 3 s aging",
		status.living_samples, 20
	)
	_expect_equal(
		"max_horizontal_position_delta (turn/age/rebuild)",
		status.max_horizontal_position_delta, 0.0
	)
	_expect_true(
		"old-region vertex XZ identical across rebuilds",
		geometry_region_delta < 1e-9
	)

	## Phase C: explicit world rebase is the ONLY thing allowed to move samples.
	var shift := Vector3(16.0, 0.0, 8.0)
	trail.apply_world_rebase(shift)
	var after_rebase: Dictionary = trail.get_position_validation_status()
	var expected_shift := Vector2(shift.x, shift.z).length()
	_expect_equal("living samples after rebase", after_rebase.living_samples, 20)
	_expect_close(
		"delta after explicit rebase equals shift length",
		after_rebase.max_horizontal_position_delta, expected_shift, 0.001
	)

	## Phase D: lifetime expiry removes all foam and empties the mesh.
	trail.clear_trail()
	trail.lifetime = 3.0
	for index in 10:
		trail.call(
			"debug_deposit_sample",
			Vector3(float(index), 0.0, 100.0),
			Vector2(0.0, 1.0),
			1.2,
			1.0
		)
	trail._age_samples(4.0)
	trail._update_mesh_tick(1.0 / 30.0)
	_expect_equal("sample_count after lifetime expiry", trail.sample_count, 0)
	_expect_equal(
		"mesh surface count after expiry",
		trail._array_mesh.get_surface_count(), 0
	)

	print("PERSISTENT_FOAM_V2_VALIDATION")
	print("  src_status=", status)
	print("  after_rebase_status=", after_rebase)
	print("  old_region_vertex_xz_delta=", geometry_region_delta)
	print("  expected_rebase_shift_length=", expected_shift)

	if _failures.is_empty():
		print("RESULT: PASS")
		get_tree().quit(0)
	else:
		for failure in _failures:
			push_error("VALIDATION FAILURE: " + failure)
		print("RESULT: FAIL (%d)" % _failures.size())
		get_tree().quit(1)


func _capture_vertex_xz(trail: Node3D) -> PackedVector2Array:
	var out := PackedVector2Array()
	if trail._array_mesh.get_surface_count() <= 0:
		return out
	var arrays: Array = trail._array_mesh.surface_get_arrays(0)
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	for vertex in vertices:
		out.append(Vector2(vertex.x, vertex.z))
	return out


func _region_delta(first: PackedVector2Array, second: PackedVector2Array, count: int) -> float:
	var limit := mini(mini(count, first.size()), second.size())
	var delta := 0.0
	for index in limit:
		delta = maxf(delta, first[index].distance_to(second[index]))
	return delta


func _expect_true(label: String, value: bool) -> void:
	if value:
		print("  OK ", label)
	else:
		_failures.append(label)


func _expect_equal(label: String, actual: Variant, expected: Variant) -> void:
	if actual == expected:
		print("  OK ", label, " = ", str(actual))
	else:
		_failures.append(
			label + " -> expected " + str(expected) + " got " + str(actual)
		)
		print("  FAIL ", label, " expected=", expected, " got=", actual)


func _expect_close(label: String, actual: float, expected: float, tolerance: float) -> void:
	if absf(actual - expected) <= tolerance:
		print("  OK ", label, " = ", str(actual))
	else:
		_failures.append(
			label + " -> expected ~" + str(expected) + " got " + str(actual)
		)
		print("  FAIL ", label, " expected~=", expected, " got=", actual)