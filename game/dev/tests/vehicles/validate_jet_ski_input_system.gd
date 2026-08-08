extends SceneTree

const JET_SKI_SCENE := "res://gameplay/vehicles/jet_ski_01/jet_ski_01.tscn"
const MAIN_SCENE := "res://levels/paradise_island/island_test_BLENDER.tscn"
const STEP := 1.0 / 60.0
const EPSILON := 0.00001
const INPUT_ACTIONS: Array[StringName] = [
	&"throttle",
	&"brake",
	&"steer_left",
	&"steer_right",
	&"rider_shift_left",
	&"rider_shift_right",
	&"rider_shift_forward",
	&"rider_shift_back",
]

var _failed := false
var _shift_signal_count := 0
var _last_shift_signal := Vector2.ZERO
var _rebase_signal_count := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var jet_ski_packed := load(JET_SKI_SCENE) as PackedScene
	var main_packed := load(MAIN_SCENE) as PackedScene
	_expect(jet_ski_packed != null, "jet_ski.tscn loads.")
	_expect(main_packed != null, "The main scene loads.")
	if jet_ski_packed == null:
		_finish()
		return

	var vehicle := jet_ski_packed.instantiate() as JetSkiController
	_expect(vehicle != null, "jet_ski.tscn instantiates as JetSkiController.")
	if vehicle == null:
		_finish()
		return
	vehicle.freeze = true
	root.add_child(vehicle)
	await process_frame

	var input_system := vehicle.get_node_or_null(
		"Systems/InputSystem"
	) as JetSkiInputSystem
	_expect(input_system != null, "Systems/InputSystem exists.")
	if input_system == null:
		vehicle.queue_free()
		_finish()
		return
	_expect(
		not _script_declares_method(input_system.get_script(), &"_physics_process"),
		"InputSystem has no independent _physics_process()."
	)
	_expect(
		JetSkiController.NavigationState.AIRBORNE
		== JetSkiTypes.NavigationState.AIRBORNE,
		"JetSkiController enum aliases remain compatible."
	)

	vehicle.rider_weight_shift_changed.connect(_on_shift_changed)
	vehicle.world_rebased.connect(_on_world_rebased)
	input_system.rider_weight_shift_enabled = true
	input_system.rider_input_allowed = true
	input_system.rider_shift_input_half_life = (
		vehicle.rider_shift_input_half_life
	)
	input_system.rider_shift_release_half_life = (
		vehicle.rider_shift_release_half_life
	)
	var persistent_state := input_system.state

	_release_all_inputs()
	Input.action_press(&"throttle", 0.75)
	Input.action_press(&"brake", 0.25)
	Input.action_press(&"steer_left", 0.20)
	Input.action_press(&"steer_right", 0.80)
	Input.action_press(&"rider_shift_right", 1.0)
	Input.action_press(&"rider_shift_back", 1.0)
	input_system.sample_input(STEP)

	var expected_raw := Vector2.ONE.normalized()
	var input_alpha := _half_life_alpha(
		STEP,
		vehicle.rider_shift_input_half_life
	)
	var expected_smoothed := expected_raw * input_alpha
	_expect(is_equal_approx(input_system.state.throttle, 0.75), "Throttle updates.")
	_expect(is_equal_approx(input_system.state.brake, 0.25), "Brake updates.")
	_expect(is_equal_approx(input_system.state.steering, 0.60), "Steering updates.")
	_expect(
		input_system.state.rider_shift_raw.distance_to(expected_raw) < EPSILON,
		"Diagonal rider shift is normalized."
	)
	_expect(
		input_system.state.rider_shift_smoothed.distance_to(expected_smoothed)
		< EPSILON,
		"Rider shift uses the configured input half-life."
	)
	_expect(vehicle.throttle_input == input_system.state.throttle, "Throttle proxy works.")
	_expect(vehicle.brake_input == input_system.state.brake, "Brake proxy works.")
	_expect(vehicle.steering_input == input_system.state.steering, "Steering proxy works.")
	_expect(
		vehicle.input_system.state.rider_shift_smoothed
		== input_system.state.rider_shift_smoothed,
		"Rider shift proxy works."
	)
	_expect(_shift_signal_count > 0, "rider_weight_shift_changed is retransmitted.")
	_expect(
		_last_shift_signal == input_system.state.rider_shift_smoothed,
		"The public rider shift signal carries the sampled value."
	)

	_release_all_inputs()
	var before_release := input_system.state.rider_shift_smoothed
	input_system.sample_input(STEP)
	var release_alpha := _half_life_alpha(
		STEP,
		vehicle.rider_shift_release_half_life
	)
	var expected_release := before_release.lerp(Vector2.ZERO, release_alpha)
	_expect(
		input_system.state.rider_shift_smoothed.distance_to(expected_release)
		< EPSILON,
		"Rider shift uses the configured release half-life."
	)

	input_system.reset()
	Input.action_press(&"throttle", 0.42)
	Input.action_press(&"steer_left", 0.30)
	Input.action_press(&"rider_shift_forward", 0.50)
	vehicle.freeze = false
	await physics_frame
	await physics_frame
	vehicle.freeze = true
	_expect(
		is_equal_approx(vehicle.throttle_input, 0.42),
		"_integrate_forces() samples throttle through InputSystem."
	)
	_expect(
		is_equal_approx(vehicle.steering_input, -0.30),
		"_integrate_forces() samples steering through InputSystem."
	)
	_expect(
		is_equal_approx(
			vehicle.input_system.state.rider_shift_raw.y,
			-0.50
		),
		"_integrate_forces() samples rider shift through InputSystem."
	)
	_release_all_inputs()

	var throttle_before_reset := vehicle.throttle_input
	var brake_before_reset := vehicle.brake_input
	var steering_before_reset := vehicle.steering_input
	vehicle.reset_vehicle(&"input_system_validation")
	_expect(input_system.state == persistent_state, "Input state remains persistent.")
	_expect(_rider_shift_is_zero(input_system.state), "Reset clears rider shift state.")
	_expect(
		is_equal_approx(vehicle.throttle_input, throttle_before_reset)
		and is_equal_approx(vehicle.brake_input, brake_before_reset)
		and is_equal_approx(vehicle.steering_input, steering_before_reset),
		"Reset preserves the pre-existing basic-input behavior."
	)
	vehicle.apply_world_rebase(Vector3(25.0, 9.0, -12.0))
	_expect(_rebase_signal_count == 1, "World rebase remains operational.")
	vehicle.reset_vehicle(&"post_rebase_validation")
	_expect(
		_rider_shift_is_zero(input_system.state),
		"Reset after rebase remains operational."
	)

	_release_all_inputs()
	persistent_state = null
	input_system = null
	vehicle.free()
	jet_ski_packed = null
	main_packed = null
	await physics_frame
	await process_frame
	await process_frame
	_finish()


func _script_declares_method(script: Script, method_name: StringName) -> bool:
	if script == null:
		return false
	for method in script.get_script_method_list():
		if StringName(method.name) == method_name:
			return true
	return false


func _rider_shift_is_zero(state: JetSkiInputState) -> bool:
	return (
		state.rider_shift_raw.is_zero_approx()
		and state.rider_shift_smoothed.is_zero_approx()
	)


func _half_life_alpha(delta: float, half_life: float) -> float:
	return clampf(
		1.0 - exp(
			-JetSkiInputSystem.HALF_LIFE_LOG_TWO
			* maxf(delta, 0.0)
			/ maxf(half_life, 0.0001)
		),
		0.0,
		1.0
	)


func _release_all_inputs() -> void:
	for action in INPUT_ACTIONS:
		Input.action_release(action)


func _on_shift_changed(shift: Vector2) -> void:
	_shift_signal_count += 1
	_last_shift_signal = shift


func _on_world_rebased(_shift: Vector3) -> void:
	_rebase_signal_count += 1


func _expect(condition: bool, message: String) -> void:
	if condition:
		print("PASS: ", message)
		return
	_failed = true
	push_error("FAIL: %s" % message)


func _finish() -> void:
	_release_all_inputs()
	quit(1 if _failed else 0)
