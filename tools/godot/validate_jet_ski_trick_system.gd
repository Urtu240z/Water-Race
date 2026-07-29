extends SceneTree

class TrickHarness:
	extends RigidBody3D

	var system: JetSkiTrickSystem
	var input_state: JetSkiInputState
	var water_state: JetSkiWaterState
	var navigation_state: JetSkiNavigationState
	var rider_enabled: bool = true
	var preload_enabled: bool = true
	var submarine_active: bool = false
	var delta: float = 0.0
	var run_update: bool = false

	func _integrate_forces(body_state: PhysicsDirectBodyState3D) -> void:
		if not run_update:
			return
		system.update_state(
			body_state,
			input_state,
			water_state,
			navigation_state,
			rider_enabled,
			preload_enabled,
			submarine_active,
			delta
		)
		run_update = false


const JET_SKI_SCENE := "res://scenes/vehicle/jet_ski.tscn"
const MAIN_SCENE := (
	"res://scenes/levels/island_test/island_test_BLENDER.tscn"
)
const CONTROLLER_SOURCE := (
	"res://scripts/vehicle/jet_ski_controller.gd"
)
const SYSTEM_SOURCE := (
	"res://scripts/vehicle/systems/jet_ski_trick_system.gd"
)
const STATE_SOURCE := (
	"res://scripts/vehicle/state/jet_ski_trick_state.gd"
)
const SCALAR_EPSILON: float = 0.0001
const VECTOR_EPSILON: float = 0.0005

var _failed: bool = false
var _comparison_failed: bool = false
var _fixture: Node3D
var _vehicle: JetSkiController
var _system: JetSkiTrickSystem
var _harness: TrickHarness
var _input_state: JetSkiInputState = JetSkiInputState.new()
var _water_state: JetSkiWaterState = JetSkiWaterState.new()
var _navigation_state: JetSkiNavigationState = (
	JetSkiNavigationState.new()
)
var _controller_source: String
var _system_source: String
var _state_source: String
var _launch_count: int = 0
var _signal_state_complete: bool = false
var _last_launch_type: JetSkiTypes.RiderTrickLaunchType = (
	JetSkiTypes.RiderTrickLaunchType.NONE
)
var _last_launch_charge: Vector2 = Vector2.ZERO
var _last_release_strength: Vector2 = Vector2.ZERO


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var jet_ski_packed := load(JET_SKI_SCENE) as PackedScene
	var main_packed := load(MAIN_SCENE) as PackedScene
	_expect(1, jet_ski_packed != null, "jet_ski.tscn carga.")
	_expect(2, main_packed != null, "La escena principal carga.")
	if jet_ski_packed == null or main_packed == null:
		_finish()
		return
	await _build_fixture(jet_ski_packed)
	if _vehicle == null or _system == null:
		_finish()
		return
	_read_sources()
	_validate_structure_and_configuration()
	await _validate_frame_metrics()
	_validate_preloads()
	_validate_reversals()
	await _validate_support_and_takeoff()
	_validate_timing_and_quality()
	_validate_release_and_classification()
	_validate_torque()
	await _validate_cancellations()
	_validate_integration()
	await _cleanup()
	_finish()


func _build_fixture(jet_ski_packed: PackedScene) -> void:
	_fixture = Node3D.new()
	_fixture.name = "TrickValidationFixture"
	_vehicle = jet_ski_packed.instantiate() as JetSkiController
	if _vehicle == null:
		_fail("jet_ski.tscn no instancia JetSkiController.")
		return
	_vehicle.name = "JetSki"
	_vehicle.freeze = true
	_vehicle.process_mode = Node.PROCESS_MODE_DISABLED
	_fixture.add_child(_vehicle)
	_system = _vehicle.get_node_or_null(
		"Systems/TrickSystem"
	) as JetSkiTrickSystem
	_harness = TrickHarness.new()
	_harness.name = "TrickHarness"
	_harness.gravity_scale = 0.0
	_harness.custom_integrator = true
	_harness.can_sleep = false
	_harness.collision_layer = 0
	_harness.collision_mask = 0
	_harness.system = _system
	_harness.input_state = _input_state
	_harness.water_state = _water_state
	_harness.navigation_state = _navigation_state
	_fixture.add_child(_harness)
	root.add_child(_fixture)
	await physics_frame
	await process_frame
	if _system != null:
		_system.trick_launched.connect(_on_trick_launched)


func _read_sources() -> void:
	_controller_source = FileAccess.get_file_as_string(
		CONTROLLER_SOURCE
	)
	_system_source = FileAccess.get_file_as_string(SYSTEM_SOURCE)
	_state_source = FileAccess.get_file_as_string(STATE_SOURCE)


func _validate_structure_and_configuration() -> void:
	var state_identity := _system.state
	_expect(3, _system != null, "Existe Systems/TrickSystem.")
	_expect(
		4,
		not _system_source.contains("func _process(")
		and not _system_source.contains("func _physics_process(")
		and not _system_source.contains("func _integrate_forces("),
		"TrickSystem no tiene procesamiento autónomo."
	)
	_expect(
		5,
		_count_nodes_named(_vehicle, &"TrickSystem") == 1
		and _system_source.count("JetSkiTrickState.new()") == 1,
		"Existe un único TrickState."
	)
	_system.reset_runtime_state()
	_expect(6, is_same(state_identity, _system.state), "El state conserva identidad.")
	var forbidden_runtime := [
		"var _trick_preload_state",
		"var _trick_roll_preload_sign",
		"var _trick_pitch_preload_sign",
		"var _trick_release_active",
		"var _trick_launch_consumed",
	]
	var has_runtime := false
	for forbidden: String in forbidden_runtime:
		has_runtime = has_runtime or _controller_source.contains(forbidden)
	_expect(7, not has_runtime, "No queda runtime Trick duplicado.")
	_expect(
		8,
		not _controller_source.contains("func _update_rider_trick_state")
		and not _controller_source.contains(
			"func _calculate_trick_release_torque"
		)
		and not _controller_source.contains(
			"func _classify_rider_trick_launch"
		),
		"No quedan fórmulas Trick en el controlador."
	)
	_expect(
		9,
		_controller_source.contains(
			"const TrickPreloadState = JetSkiTypes.TrickPreloadState"
		)
		and _controller_source.contains(
			"const RiderTrickLaunchType = JetSkiTypes.RiderTrickLaunchType"
		),
		"Los enums compartidos conservan sus aliases."
	)
	_expect(
		10,
		_controller_source.contains("signal rider_trick_launched(")
		and _controller_source.contains(
			"trick_type: JetSkiTypes.RiderTrickLaunchType"
		),
		"La señal pública conserva firma."
	)
	_expect(11, _preload_configuration_matches(), "Tuning Preload copiado.")
	_expect(12, _release_configuration_matches(), "Tuning Release copiado.")
	_expect(
		13,
		_system.TRICK_PRE_TAKEOFF_OPTIMAL_TIME == 0.22
		and _system.TRICK_PRE_TAKEOFF_MINIMUM_TIMING == 0.65
		and _system.TRICK_POST_TAKEOFF_OPTIMAL_TIME == 0.10
		and _system.TRICK_POST_TAKEOFF_MINIMUM_TIMING == 0.50,
		"Constantes Trick correctas."
	)
	_expect(
		14,
		not _system_source.contains("air_correction"),
		"No se copia Air Correction."
	)
	_expect(
		15,
		not _system_source.contains("JetSkiSubmarineState")
		and not _system_source.contains("JetSkiSubmarineSystem"),
		"No se copia Submarine."
	)
	var integrate_source := _function_source(
		_controller_source,
		"func _integrate_forces("
	)
	_expect(
		16,
		not integrate_source.contains("_configure_trick_system")
		and _controller_source.count("_configure_trick_system()") == 2,
		"Configuración copiada sólo en _ready()."
	)
	_expect(
		17,
		_scalar_close(
			_system.max_submersion_depth,
			_vehicle.max_submersion_depth
		),
		"max_submersion_depth coincide."
	)
	_expect(
		18,
		integrate_source.contains("rider_weight_shift_enabled,")
		and integrate_source.contains("trick_preload_enabled,")
		and not _system_source.contains(
			"var rider_weight_shift_enabled"
		)
		and not _system_source.contains("var trick_preload_enabled"),
		"Flags runtime pasan explícitamente."
	)


func _validate_frame_metrics() -> void:
	_system.reset_runtime_state()
	_system.state.release_roll_torque = 12.0
	_system.state.release_pitch_torque = -8.0
	_system.state.release_active = true
	_system.state.release_elapsed = 0.04
	_system.state.roll_charge = 0.5
	_system.begin_physics_tick()
	_expect(19, _system.state.release_roll_torque == 0.0, "Limpia roll torque.")
	_expect(20, _system.state.release_pitch_torque == 0.0, "Limpia pitch torque.")
	_expect(21, _system.state.release_active, "Release active persiste.")
	_expect(22, _system.state.release_elapsed == 0.04, "Release elapsed persiste.")
	_expect(23, _system.state.roll_charge == 0.5, "Preloads persisten.")
	var integrate_source := _function_source(
		_controller_source,
		"func _integrate_forces("
	)
	_expect(
		24,
		integrate_source.find("trick_system.begin_physics_tick()")
		>= 0
		and integrate_source.find("trick_system.begin_physics_tick()")
		< integrate_source.find("if not is_instance_valid(_ocean):"),
		"Early return no deja torque obsoleto."
	)


func _validate_preloads() -> void:
	_validate_roll_preload()
	_validate_pitch_preload()


func _validate_roll_preload() -> void:
	_system.reset_runtime_state()
	_system._update_roll_preload(0.0, 0.1, false)
	_expect(25, _system.state.roll_charge == 0.0, "Roll input cero.")
	_system._update_roll_preload(0.54, 0.1, false)
	_expect(26, _system.state.roll_charge == 0.0, "Roll bajo mínimo.")
	_system._update_roll_preload(0.55, 0.1, false)
	_expect(27, _system.state.roll_charge > 0.0, "Roll en threshold.")

	_system.reset_runtime_state()
	_system._update_roll_preload(0.7, 0.1, false)
	var expected_partial := 0.1 / 0.35 * 0.7
	_expect(
		28,
		_scalar_close(_system.state.roll_charge, expected_partial),
		"Roll input parcial."
	)
	_system.reset_runtime_state()
	_system._update_roll_preload(1.0, 0.35, false)
	_expect(29, _system.state.roll_charge == 1.0, "Roll input completo.")
	_expect(30, _system.state.roll_preload_sign == 1.0, "Roll signo positivo.")
	_system.reset_runtime_state()
	_system._update_roll_preload(-1.0, 0.1, false)
	_expect(31, _system.state.roll_preload_sign == -1.0, "Roll signo negativo.")
	_expect(32, _system.state.roll_hold_time == 0.1, "Roll hold time.")
	_expect(
		33,
		_scalar_close(_system.state.roll_charge, 0.1 / 0.35),
		"Roll carga temporal."
	)
	_system._update_roll_preload(-1.0, 1.0, false)
	_expect(34, _system.state.roll_charge == 1.0, "Roll clamp en uno.")
	_system._update_roll_preload(0.0, 0.2, false)
	_expect(
		35,
		_scalar_close(_system.state.roll_charge, 0.7),
		"Roll decay con move_toward."
	)
	_system.state.roll_charge = 0.0001
	_system._update_roll_preload(0.0, 0.0, false)
	_expect(
		36,
		_system.state.roll_charge == 0.0
		and _system.state.roll_preload_sign == 0.0,
		"Roll limpia bajo epsilon."
	)
	_expect(37, _system.state.pitch_charge == 0.0, "Pitch permanece independiente.")


func _validate_pitch_preload() -> void:
	_system.reset_runtime_state()
	_system._update_pitch_preload(0.0, 0.1, false)
	_expect(38, _system.state.pitch_charge == 0.0, "Pitch input cero.")
	_system._update_pitch_preload(0.54, 0.1, false)
	_expect(39, _system.state.pitch_charge == 0.0, "Pitch bajo mínimo.")
	_system._update_pitch_preload(0.55, 0.1, false)
	_expect(40, _system.state.pitch_charge > 0.0, "Pitch en threshold.")
	_system.reset_runtime_state()
	_system._update_pitch_preload(0.7, 0.1, false)
	var expected_partial := 0.1 / 0.35 * 0.7
	_expect(
		41,
		_scalar_close(_system.state.pitch_charge, expected_partial),
		"Pitch input parcial."
	)
	_system.reset_runtime_state()
	_system._update_pitch_preload(1.0, 0.35, false)
	_expect(42, _system.state.pitch_charge == 1.0, "Pitch input completo.")
	_expect(43, _system.state.pitch_preload_sign == 1.0, "Pitch signo positivo.")
	_system.reset_runtime_state()
	_system._update_pitch_preload(-1.0, 0.1, false)
	_expect(44, _system.state.pitch_preload_sign == -1.0, "Pitch signo negativo.")
	_expect(45, _system.state.pitch_hold_time == 0.1, "Pitch hold time.")
	_expect(
		46,
		_scalar_close(_system.state.pitch_charge, 0.1 / 0.35),
		"Pitch carga temporal."
	)
	_system._update_pitch_preload(-1.0, 1.0, false)
	_expect(47, _system.state.pitch_charge == 1.0, "Pitch clamp en uno.")
	_system._update_pitch_preload(0.0, 0.2, false)
	_expect(
		48,
		_scalar_close(_system.state.pitch_charge, 0.7),
		"Pitch decay con move_toward."
	)
	_system.state.pitch_charge = 0.0001
	_system._update_pitch_preload(0.0, 0.0, false)
	_expect(
		49,
		_system.state.pitch_charge == 0.0
		and _system.state.pitch_preload_sign == 0.0,
		"Pitch limpia bajo epsilon."
	)
	_expect(50, _system.state.roll_charge == 0.0, "Roll permanece independiente.")


func _validate_reversals() -> void:
	_prepare_roll_preload()
	_system._update_roll_preload(-0.65, 0.01, false)
	_expect(51, _system.state.roll_reversal_armed, "Reversal roll válido.")

	_prepare_pitch_preload()
	_system._update_pitch_preload(-0.65, 0.01, false)
	_expect(52, _system.state.pitch_reversal_armed, "Reversal pitch válido.")

	_prepare_roll_preload()
	_system._update_roll_preload(-0.64, 0.01, false)
	_expect(53, not _system.state.roll_reversal_armed, "Reversal input insuficiente.")

	_prepare_roll_preload()
	_system._update_roll_preload(0.8, 0.01, false)
	_expect(54, not _system.state.roll_reversal_armed, "Reversal mismo signo.")

	_system.reset_runtime_state()
	_system._update_roll_preload(-0.8, 0.01, false)
	_expect(
		55,
		not _system.state.roll_reversal_armed,
		"Reversal sin preload previo."
	)

	_prepare_roll_preload()
	_system.state.roll_hold_time = 0.099
	_system._update_roll_preload(-0.8, 0.01, false)
	_expect(56, not _system.state.roll_reversal_armed, "Hold insuficiente.")

	_prepare_roll_preload()
	_system.state.roll_charge = 0.149
	_system._update_roll_preload(-0.8, 0.01, false)
	_expect(57, not _system.state.roll_reversal_armed, "Charge insuficiente.")

	_prepare_roll_preload()
	_system._update_roll_preload(-0.8, 0.01, false)
	_expect(58, _system.state.roll_reversal_direction == -1.0, "Dirección guardada.")
	_expect(59, _system.state.roll_armed_charge == 0.6, "Carga armada guardada.")
	_expect(
		60,
		_system.state.roll_reversal_time_remaining
		== _system.trick_reversal_takeoff_window,
		"Ventana pre-takeoff."
	)

	_prepare_roll_preload()
	_system.state.time_since_takeoff = 0.04
	_system._update_roll_preload(-0.8, 0.0, true)
	_expect(
		61,
		_scalar_close(
			_system.state.roll_reversal_time_remaining,
			_system.trick_takeoff_coyote_time - 0.04
		),
		"Ventana coyote."
	)

	_expect(
		62,
		_system.state.roll_reversal_armed
		and not _system.state.pitch_reversal_armed,
		"Roll y pitch independientes."
	)
	_system.state.roll_reversal_time_remaining = 0.0
	_system._update_reversal_timers(0.0002)
	_expect(
		63,
		not _system.state.roll_reversal_armed,
		"Expira bajo -0.0001."
	)
	_prepare_roll_preload()
	_system._update_roll_preload(-0.8, 0.01, false)
	_system.state.roll_reversal_time_remaining = 0.0
	_system._update_reversal_timers(0.0)
	_expect(64, _system.state.roll_reversal_armed, "Cero exacto no expira.")


func _validate_support_and_takeoff() -> void:
	_prepare_supported_state(true, false)
	_water_state.average_depth = 0.32
	await _run_update(Vector3(0.0, 0.0, -8.0), 0.0)
	_expect(
		65,
		_scalar_close(_system.state.last_contact_average_depth, 0.32),
		"Agua actualiza profundidad media."
	)

	_system.reset_runtime_state()
	_prepare_supported_state(false, true)
	await _run_update(Vector3(0.0, 0.0, -8.0), 0.0)
	_expect(
		66,
		_scalar_close(
			_system.state.last_contact_average_depth,
			_system.max_submersion_depth * 0.25
		),
		"Rampa usa max depth por 0.25."
	)

	_system.state.release_active = true
	_system.state.launch_consumed = true
	_navigation_state.previous_has_any_support = false
	_navigation_state.has_any_support = true
	await _run_update(Vector3(0.0, 0.0, -8.0), 0.0)
	_expect(
		67,
		not _system.state.release_active
		and not _system.state.launch_consumed,
		"Ganar soporte ejecuta reset de contacto."
	)
	_system.state.last_launch_type = (
		JetSkiTypes.RiderTrickLaunchType.BACKFLIP
	)
	_navigation_state.previous_has_any_support = false
	_navigation_state.has_any_support = true
	await _run_update(Vector3(0.0, 0.0, -8.0), 0.0)
	_expect(
		68,
		_system.state.last_launch_type
		== JetSkiTypes.RiderTrickLaunchType.BACKFLIP,
		"Reset de contacto no es reset completo."
	)
	_navigation_state.previous_has_any_support = true
	_navigation_state.has_any_support = true
	_navigation_state.has_water_support = false
	_navigation_state.has_solid_support = true
	_navigation_state.true_takeoff_this_tick = false
	await _run_update(Vector3(0.0, 0.0, -8.0), 0.01)
	_expect(
		69,
		not _system.state.takeoff_pending,
		"Perder agua sobre rampa no produce takeoff."
	)
	_expect(
		70,
		_system_source.contains(
			"if navigation_state.true_takeoff_this_tick:"
		),
		"true_takeoff_this_tick es la autoridad."
	)

	_system.reset_runtime_state()
	_prepare_air_takeoff()
	await _run_update(Vector3(0.0, 2.0, -5.0), 0.0)
	_expect(71, _system.state.takeoff_pending, "Contexto queda pendiente.")
	_expect(72, _system.state.time_since_takeoff == 0.0, "Tiempo inicia en cero.")
	_expect(
		73,
		_system.state.pending_speed_factor == 0.0,
		"Speed factor mínimo."
	)

	_system.reset_runtime_state()
	_prepare_air_takeoff()
	await _run_update(Vector3(0.0, 2.0, -10.0), 0.0)
	_expect(
		74,
		_system.state.pending_speed_factor > 0.0
		and _system.state.pending_speed_factor < 1.0,
		"Speed factor intermedio."
	)

	_system.reset_runtime_state()
	_prepare_air_takeoff()
	await _run_update(Vector3(0.0, 6.0, -15.0), 0.0)
	_expect(75, _system.state.pending_speed_factor == 1.0, "Speed factor completo.")

	_system.reset_runtime_state()
	_prepare_air_takeoff()
	await _run_update(Vector3(0.0, 0.0, -4.999), 0.0)
	_expect(
		76,
		not _system.state.pending_launch_speed_valid,
		"Speed valid false."
	)
	_system.reset_runtime_state()
	_prepare_air_takeoff()
	await _run_update(Vector3(0.0, 0.0, -5.0), 0.0)
	_expect(77, _system.state.pending_launch_speed_valid, "Speed valid true.")

	_system.reset_runtime_state()
	_system.state.last_contact_average_depth = 0.2
	_prepare_air_takeoff()
	await _run_update(Vector3(0.0, 3.0, -10.0), 0.0)
	_expect(
		78,
		_scalar_close(
			_system.state.pending_upward_factor,
			smoothstep(0.0, 6.0, 3.0)
		),
		"Upward factor."
	)
	_expect(
		79,
		_scalar_close(
			_system.state.pending_depth_factor,
			smoothstep(
				0.0,
				maxf(_system.max_submersion_depth * 0.5, 0.001),
				0.2
			)
		),
		"Depth factor."
	)
	_expect(
		80,
		_system.state.takeoff_quality == 0.0
		and _system.state.takeoff_timing_factor == 0.0,
		"Quality y timing se limpian al preparar takeoff."
	)

	await _validate_coyote()


func _validate_coyote() -> void:
	_prepare_release_candidate(true, false)
	_system._try_start_release(false)
	_expect(81, _system.state.release_active, "Release pre-takeoff.")

	_system.reset_runtime_state()
	_prepare_roll_preload()
	_prepare_air_takeoff()
	_input_state.rider_shift_raw = Vector2(-0.8, 0.0)
	await _run_update(Vector3(0.0, 2.0, -10.0), 0.0)
	_expect(
		82,
		_system.state.release_active,
		"Reversal en primer tick de takeoff."
	)

	_system.reset_runtime_state()
	_prepare_roll_preload()
	_system.state.takeoff_pending = true
	_system.state.pending_launch_speed_valid = true
	_system.state.pending_speed_factor = 1.0
	_system.state.pending_upward_factor = 0.5
	_system.state.pending_depth_factor = 0.5
	_system.state.time_since_takeoff = 0.05
	_navigation_state.true_takeoff_this_tick = false
	_navigation_state.has_any_support = false
	_input_state.rider_shift_raw = Vector2(-0.8, 0.0)
	await _run_update(Vector3(0.0, 2.0, -10.0), 0.01)
	_expect(83, _system.state.release_active, "Coyote dentro de ventana.")

	_system.reset_runtime_state()
	_system.state.takeoff_pending = true
	_system.state.pending_launch_speed_valid = true
	_system.state.time_since_takeoff = (
		_system.trick_takeoff_coyote_time
	)
	_navigation_state.true_takeoff_this_tick = false
	_navigation_state.has_any_support = false
	await _run_update(Vector3(0.0, 0.0, -10.0), 0.0)
	_expect(
		84,
		_system.state.takeoff_pending,
		"Coyote permanece en límite exacto."
	)
	await _run_update(Vector3(0.0, 0.0, -10.0), 0.001)
	_expect(85, not _system.state.takeoff_pending, "Coyote expirado.")
	_expect(86, _system.state.launch_consumed, "Cancelación del takeoff.")

	_prepare_release_candidate(true, false)
	_system._try_start_release(false)
	_expect(87, _system.state.launch_consumed, "Launch consumed tras release.")
	var update_source := _function_source(
		_system_source,
		"func update_state("
	)
	var prepare_index := update_source.find("_prepare_takeoff_context(")
	var first_try_index := update_source.find("_try_start_release(false)")
	var coyote_index := update_source.find("_detect_coyote_reversals(")
	var second_try_index := update_source.find("_try_start_release(true)")
	_expect(
		88,
		prepare_index < first_try_index
		and first_try_index < coyote_index
		and coyote_index < second_try_index,
		"Orden de intentos en primer tick."
	)


func _validate_timing_and_quality() -> void:
	_system.reset_runtime_state()
	_system.state.time_since_takeoff = 0.0
	_expect(
		89,
		_system._reversal_timing_factor(
			_system.trick_reversal_takeoff_window,
			false
		) == 1.0,
		"Timing pre óptimo."
	)
	var pre_mid_remaining := (
		_system.trick_reversal_takeoff_window
		- (
			_system.TRICK_PRE_TAKEOFF_OPTIMAL_TIME
			+ _system.trick_reversal_takeoff_window
		) * 0.5
	)
	var pre_mid := _system._reversal_timing_factor(
		pre_mid_remaining,
		false
	)
	_expect(90, pre_mid < 1.0 and pre_mid > 0.65, "Timing pre intermedio.")
	_expect(
		91,
		_scalar_close(
			_system._reversal_timing_factor(0.0, false),
			0.65
		),
		"Timing pre mínimo."
	)
	_system.state.time_since_takeoff = 0.0
	_expect(
		92,
		_system._reversal_timing_factor(0.0, true) == 1.0,
		"Timing post óptimo."
	)
	_system.state.time_since_takeoff = 0.14
	var post_mid := _system._reversal_timing_factor(0.0, true)
	_expect(93, post_mid < 1.0 and post_mid > 0.5, "Timing post intermedio.")
	_system.state.time_since_takeoff = _system.trick_takeoff_coyote_time
	_expect(
		94,
		_scalar_close(
			_system._reversal_timing_factor(0.0, true),
			0.5
		),
		"Timing post mínimo."
	)
	var saved_coyote := _system.trick_takeoff_coyote_time
	_system.trick_takeoff_coyote_time = 0.0
	_system.state.time_since_takeoff = 0.0
	_expect(
		95,
		_system._reversal_timing_factor(0.0, true) == 1.0,
		"Coyote time cero."
	)
	_system.trick_takeoff_coyote_time = saved_coyote
	_expect(
		96,
		_system_source.contains(
			"TRICK_POST_TAKEOFF_OPTIMAL_TIME + 0.001"
		)
		and _system_source.contains(
			"TRICK_PRE_TAKEOFF_OPTIMAL_TIME + 0.001"
		),
		"Fallback +0.001 conservado."
	)

	_system.state.pending_speed_factor = 0.5
	_system.state.pending_upward_factor = 0.5
	_system.state.pending_depth_factor = 0.5
	var speed_quality := lerpf(0.65, 1.0, 0.5)
	var upward_bonus := lerpf(0.90, 1.05, 0.5)
	var depth_bonus := lerpf(0.95, 1.05, 0.5)
	var quality := _system._calculate_takeoff_quality(1.0)
	_expect(97, _scalar_close(speed_quality, 0.825), "Speed quality.")
	_expect(98, _scalar_close(upward_bonus, 0.975), "Upward bonus.")
	_expect(99, _scalar_close(depth_bonus, 1.0), "Depth bonus.")
	_expect(
		100,
		_scalar_close(
			quality,
			speed_quality * upward_bonus * depth_bonus
		),
		"Quality multiplica factores."
	)
	_expect(
		101,
		_system._calculate_takeoff_quality(-1.0) == 0.0,
		"Quality clamp inferior."
	)
	_system.state.pending_speed_factor = 2.0
	_system.state.pending_upward_factor = 2.0
	_system.state.pending_depth_factor = 2.0
	_expect(
		102,
		_system._calculate_takeoff_quality(2.0) == 1.1,
		"Quality clamp superior 1.1."
	)


func _validate_release_and_classification() -> void:
	_prepare_release_candidate(true, false)
	_system.state.launch_consumed = true
	_system._try_start_release(false)
	_expect(103, not _system.state.release_active, "Rechaza launch consumed.")

	_prepare_release_candidate(true, false)
	_system.state.release_active = true
	_system._try_start_release(false)
	_expect(104, _system.state.last_launch_type == 0, "Rechaza release activo.")

	_prepare_release_candidate(true, false)
	_system.state.pending_launch_speed_valid = false
	_system._try_start_release(false)
	_expect(105, not _system.state.release_active, "Rechaza por velocidad.")

	_prepare_release_candidate(true, false)
	_system.state.roll_armed_charge = 0.149
	_system._try_start_release(false)
	_expect(106, not _system.state.release_active, "Rechaza carga roll.")

	_prepare_release_candidate(false, true)
	_system.state.pitch_armed_charge = 0.149
	_system._try_start_release(false)
	_expect(107, not _system.state.release_active, "Rechaza carga pitch.")

	_prepare_release_candidate(true, false)
	var launches_before := _launch_count
	_system._try_start_release(false)
	_expect(
		108,
		_system.state.release_active
		and not is_zero_approx(_system.state.release_strength.x)
		and is_zero_approx(_system.state.release_strength.y),
		"Release roll."
	)

	_prepare_release_candidate(false, true)
	_system._try_start_release(false)
	_expect(
		109,
		_system.state.release_active
		and is_zero_approx(_system.state.release_strength.x)
		and not is_zero_approx(_system.state.release_strength.y),
		"Release pitch."
	)

	_prepare_release_candidate(true, true)
	_system._try_start_release(false)
	_expect(
		110,
		not is_zero_approx(_system.state.release_strength.x)
		and not is_zero_approx(_system.state.release_strength.y),
		"Release combinado."
	)
	var expected_component := (
		pow(0.8, _system.trick_release_curve_power)
		* _system._calculate_takeoff_quality(1.0)
	)
	_expect(
		111,
		_scalar_close(
			absf(_system.state.last_release_strength.x),
			minf(expected_component, 1.0 / sqrt(2.0))
		),
		"Curve power conservado."
	)
	_expect(
		112,
		_system.state.last_release_strength.length() <= 1.0001,
		"Normalización vectorial."
	)
	_prepare_release_candidate(false, false)
	_system._try_start_release(false)
	_expect(113, not _system.state.release_active, "Strength cero se rechaza.")

	_prepare_release_candidate(true, false)
	launches_before = _launch_count
	_system._try_start_release(false)
	_expect(
		114,
		_system.state.preload_state
		== JetSkiTypes.TrickPreloadState.RELEASE_ACTIVE,
		"Estado RELEASE_ACTIVE."
	)
	_expect(
		115,
		_system.state.roll_charge == 0.0
		and _system.state.pitch_charge == 0.0,
		"Preloads limpiados."
	)
	_expect(
		116,
		_system.state.last_launch_charge == Vector2(0.8, 0.0),
		"Último charge."
	)
	_expect(
		117,
		_system.state.last_release_strength
		== _system.state.release_strength,
		"Último strength."
	)
	_expect(
		118,
		_launch_count == launches_before + 1
		and _last_launch_type == _system.state.last_launch_type
		and _last_launch_charge == _system.state.last_launch_charge
		and _last_release_strength
		== _system.state.last_release_strength,
		"Señal emitida una vez."
	)
	_expect(119, _signal_state_complete, "State completo antes de señal.")

	_expect(
		120,
		_system.classify_launch(Vector2.ZERO)
		== JetSkiTypes.RiderTrickLaunchType.NONE,
		"Clasificación NONE."
	)
	_expect(
		121,
		_system.classify_launch(Vector2(-1.0, 0.0))
		== JetSkiTypes.RiderTrickLaunchType.BARREL_LEFT,
		"Clasificación BARREL_LEFT."
	)
	_expect(
		122,
		_system.classify_launch(Vector2(1.0, 0.0))
		== JetSkiTypes.RiderTrickLaunchType.BARREL_RIGHT,
		"Clasificación BARREL_RIGHT."
	)
	_expect(
		123,
		_system.classify_launch(Vector2(0.0, 1.0))
		== JetSkiTypes.RiderTrickLaunchType.BACKFLIP,
		"Clasificación BACKFLIP."
	)
	_expect(
		124,
		_system.classify_launch(Vector2(0.0, -1.0))
		== JetSkiTypes.RiderTrickLaunchType.FRONTFLIP,
		"Clasificación FRONTFLIP."
	)
	_expect(
		125,
		_system.classify_launch(Vector2(0.5, 0.5))
		== JetSkiTypes.RiderTrickLaunchType.COMBINED,
		"Clasificación COMBINED."
	)
	_expect(
		126,
		_system.classify_launch(Vector2(0.0001, 0.0))
		== JetSkiTypes.RiderTrickLaunchType.BARREL_RIGHT
		and _system.classify_launch(Vector2(0.0001, 0.0001))
		== JetSkiTypes.RiderTrickLaunchType.BARREL_RIGHT
		and _system.classify_launch(Vector2(0.00011, 0.00011))
		== JetSkiTypes.RiderTrickLaunchType.COMBINED,
		"Epsilon y signos legacy exactos."
	)
	_expect(
		127,
		_system.get_launch_type_name(
			JetSkiTypes.RiderTrickLaunchType.BARREL_LEFT
		) == &"BARREL_L"
		and _system.get_launch_type_name(
			JetSkiTypes.RiderTrickLaunchType.BARREL_RIGHT
		) == &"BARREL_R"
		and _system.get_launch_type_name(
			JetSkiTypes.RiderTrickLaunchType.BACKFLIP
		) == &"BACKFLIP"
		and _system.get_launch_type_name(
			JetSkiTypes.RiderTrickLaunchType.FRONTFLIP
		) == &"FRONTFLIP"
		and _system.get_launch_type_name(
			JetSkiTypes.RiderTrickLaunchType.COMBINED
		) == &"COMBINED"
		and _system.get_launch_type_name(
			JetSkiTypes.RiderTrickLaunchType.NONE
		) == &"NONE",
		"Nombres públicos."
	)


func _validate_torque() -> void:
	_system.reset_runtime_state()
	var torque := _system.calculate_release_torque(
		Vector3.FORWARD,
		Vector3.RIGHT,
		0.01
	)
	_expect(128, torque.is_zero_approx(), "Release inactivo devuelve cero.")

	_system.reset_runtime_state()
	_system.state.release_active = true
	_system.state.release_strength = Vector2(0.5, -0.25)
	_system.state.release_time_remaining = _system.trick_release_duration
	var delta := 0.02
	var sampled := delta * 0.5
	var normalized := sampled / _system.trick_release_duration
	var envelope := sin(normalized * PI)
	torque = _system.calculate_release_torque(
		Vector3.FORWARD,
		Vector3.RIGHT,
		delta
	)
	_expect(129, not torque.is_zero_approx(), "Primer tick produce torque.")
	_expect(
		130,
		_system_source.contains(
			"state.release_elapsed + maxf(physics_delta, 0.0) * 0.5"
		),
		"Muestreo en punto medio."
	)
	_expect(
		131,
		_system_source.contains(
			"sin(normalized_release_time * PI)"
		),
		"Envelope sinusoidal."
	)

	_system.state.release_active = true
	_system.state.release_elapsed = (
		_system.trick_release_duration * 0.5
	)
	_system.state.release_strength = Vector2.ONE
	_system.calculate_release_torque(
		Vector3.FORWARD,
		Vector3.RIGHT,
		0.0
	)
	_expect(
		132,
		_scalar_close(
			_system.state.release_roll_torque,
			_system.trick_roll_release_torque
		),
		"Pico del envelope."
	)

	_system.state.release_active = true
	_system.state.release_elapsed = _system.trick_release_duration
	_system.state.release_strength = Vector2.ONE
	torque = _system.calculate_release_torque(
		Vector3.FORWARD,
		Vector3.RIGHT,
		0.0
	)
	_expect(133, torque.length() <= VECTOR_EPSILON, "Final del envelope.")

	_system.reset_runtime_state()
	_system.state.release_active = true
	_system.state.release_strength = Vector2(0.5, -0.25)
	torque = _system.calculate_release_torque(
		Vector3.FORWARD,
		Vector3.RIGHT,
		delta
	)
	_expect(
		134,
		_scalar_close(
			_system.state.release_roll_torque,
			0.5 * _system.trick_roll_release_torque * envelope
		),
		"Roll torque."
	)
	_expect(
		135,
		_scalar_close(
			_system.state.release_pitch_torque,
			-0.25 * _system.trick_pitch_release_torque * envelope
		),
		"Pitch torque."
	)
	var expected_torque := (
		Vector3.FORWARD * _system.state.release_roll_torque
		+ Vector3.RIGHT * _system.state.release_pitch_torque
	)
	_expect(136, _vector_close(torque, expected_torque), "Torque combinado.")
	_expect(
		137,
		_scalar_close(torque.z, -_system.state.release_roll_torque),
		"Eje forward."
	)
	_expect(
		138,
		_scalar_close(torque.x, _system.state.release_pitch_torque),
		"Eje right."
	)
	_expect(
		139,
		_system.state.release_roll_torque > 0.0
		and _system.state.release_pitch_torque < 0.0,
		"Signos conservados."
	)
	_expect(
		140,
		_scalar_close(_system.state.release_elapsed, delta),
		"Elapsed avanza."
	)
	_expect(
		141,
		_scalar_close(
			_system.state.release_time_remaining,
			_system.trick_release_duration - delta
		),
		"Remaining se actualiza."
	)
	_system.state.release_active = true
	_system.state.release_elapsed = (
		_system.trick_release_duration - 0.01
	)
	_system.calculate_release_torque(
		Vector3.FORWARD,
		Vector3.RIGHT,
		0.02
	)
	_expect(
		142,
		not _system.state.release_active
		and _system.state.release_time_remaining == 0.0,
		"Release finaliza."
	)
	_expect(
		143,
		_system.state.preload_state
		== JetSkiTypes.TrickPreloadState.IDLE,
		"Preload state tras finalizar."
	)
	var rider_source := _function_source(
		_controller_source,
		"func _apply_rider_dynamics("
	)
	_expect(
		144,
		rider_source.count(
			"trick_system.calculate_release_torque("
		) == 1,
		"Torque se evalúa una vez por tick Air válido."
	)


func _validate_cancellations() -> void:
	_prepare_active_release()
	_harness.rider_enabled = false
	await _run_update(Vector3(0.0, 0.0, -10.0), 0.01)
	_expect(145, _cancelled(), "Cancela Rider Shift deshabilitado.")

	_prepare_active_release()
	_harness.rider_enabled = true
	_harness.preload_enabled = false
	await _run_update(Vector3(0.0, 0.0, -10.0), 0.01)
	_expect(146, _cancelled(), "Cancela preload deshabilitado.")

	_prepare_active_release()
	_harness.preload_enabled = true
	_navigation_state.navigation_state = (
		JetSkiTypes.NavigationState.DEEP_SUBMERGED
	)
	await _run_update(Vector3(0.0, 0.0, -10.0), 0.01)
	_expect(147, _cancelled(), "Cancela Deep Submerged.")

	_prepare_active_release()
	_navigation_state.navigation_state = (
		JetSkiTypes.NavigationState.AIRBORNE
	)
	_harness.submarine_active = true
	await _run_update(Vector3(0.0, 0.0, -10.0), 0.01)
	_expect(148, _cancelled(), "Cancela Submarine activo.")

	var callback_source := _function_source(
		_controller_source,
		"func _on_submarine_system_dive_started("
	)
	_expect(
		149,
		callback_source.contains("trick_system.cancel_for_submarine()"),
		"Callback submarine cancela TrickSystem."
	)
	_expect(
		150,
		callback_source.find("trick_system.cancel_for_submarine()")
		< callback_source.find("submarine_dive_started.emit()"),
		"Cancelación precede señal pública."
	)
	_system.cancel_for_submarine()
	var state_snapshot := _state_signature()
	_system.cancel_for_submarine()
	_expect(
		151,
		_state_signature() == state_snapshot,
		"Cancelación idempotente."
	)

	_prepare_active_release()
	_harness.submarine_active = false
	_navigation_state.previous_has_any_support = false
	_navigation_state.has_any_support = true
	_navigation_state.has_water_support = true
	_navigation_state.navigation_state = (
		JetSkiTypes.NavigationState.PARTIALLY_SUBMERGED
	)
	await _run_update(Vector3(0.0, 0.0, -10.0), 0.01)
	_expect(152, not _system.state.release_active, "Nuevo soporte cancela release.")

	var state_identity := _system.state
	_system.state.last_launch_type = (
		JetSkiTypes.RiderTrickLaunchType.COMBINED
	)
	_system.reset_runtime_state()
	_expect(
		153,
		is_same(state_identity, _system.state)
		and _state_is_reset(),
		"Reset completo conserva identidad."
	)


func _validate_integration() -> void:
	var update_source := _function_source(
		_system_source,
		"func update_state("
	)
	var integrate_source := _function_source(
		_controller_source,
		"func _integrate_forces("
	)
	var rider_source := _function_source(
		_controller_source,
		"func _apply_rider_dynamics("
	)
	_expect(
		154,
		update_source.contains("input_state.rider_shift_raw.x")
		and update_source.contains("input_state.rider_shift_raw.y"),
		"Usa InputState raw."
	)
	_expect(
		155,
		update_source.contains("water_state.average_depth"),
		"Usa WaterState."
	)
	_expect(
		156,
		update_source.contains("navigation_state.has_any_support")
		and update_source.contains(
			"navigation_state.true_takeoff_this_tick"
		),
		"Usa NavigationState."
	)
	_expect(
		157,
		integrate_source.contains("submarine_system.is_dive_active(),")
		and not _system_source.contains("JetSkiSubmarineState"),
		"Submarine se integra por booleano."
	)
	_expect(
		158,
		rider_source.contains("external_trick_release_torque")
		and rider_source.contains(
			"trick_system.calculate_release_torque("
		)
		and rider_source.contains("apply_air_torque("),
		"RiderDynamics recibe torque externo."
	)
	_expect(
		159,
		integrate_source.find("trick_system.update_state(")
		< integrate_source.find("drive_system.step(")
		and integrate_source.find("drive_system.step(")
		< integrate_source.find("_apply_rider_dynamics("),
		"Drive mantiene orden."
	)
	_expect(
		160,
		load(
			"res://tools/godot/validate_jet_ski_input_system.gd"
		) != null,
		"Validador Input disponible."
	)
	_expect(
		161,
		load(
			"res://tools/godot/validate_jet_ski_water_physics_system.gd"
		) != null,
		"Validador Water Physics disponible."
	)
	_expect(
		162,
		load(
			"res://tools/godot/validate_jet_ski_navigation_system.gd"
		) != null,
		"Validador Navigation disponible."
	)
	_expect(
		163,
		load(
			"res://tools/godot/validate_jet_ski_drive_system.gd"
		) != null,
		"Validador Drive disponible."
	)
	_expect(
		164,
		load(
			"res://tools/godot/validate_jet_ski_rider_dynamics_system.gd"
		) != null,
		"Validador Rider Dynamics disponible."
	)
	_expect(
		165,
		load(
			"res://tools/godot/validate_jet_ski_submarine_system.gd"
		) != null,
		"Validador Submarine disponible."
	)
	_expect(
		166,
		load("res://tools/godot/validate_vehicle_water_audio.gd")
		!= null,
		"Validador VehicleWaterAudio disponible."
	)
	var ready_source := _function_source(
		_controller_source,
		"func _ready("
	)
	var reset_source := _function_source(
		_controller_source,
		"func reset_vehicle("
	)
	_expect(
		167,
		ready_source.contains("trick_system.reset_runtime_state()")
		and reset_source.contains("trick_system.reset_runtime_state()"),
		"Reset delegado en ready y reset_vehicle."
	)
	_expect(
		168,
		not _state_source.contains("Vector3")
		and not _state_source.contains("Transform3D")
		and not _system_source.contains("apply_world_rebase"),
		"TrickState no necesita rebase."
	)
	_expect(
		169,
		load(SYSTEM_SOURCE) != null and load(STATE_SOURCE) != null,
		"Sin errores de parser."
	)
	_expect(
		170,
		_system is JetSkiTrickSystem
		and _system.state is JetSkiTrickState,
		"Sin errores de inferencia."
	)
	_expect(
		171,
		not _system_source.contains("@warning_ignore")
		and not _state_source.contains("@warning_ignore"),
		"Sin warnings GDScript silenciados o reales."
	)
	var git_output: Array = []
	var git_exit := OS.execute(
		"git",
		PackedStringArray(["diff", "--check"]),
		git_output,
		true
	)
	_expect(172, git_exit == 0, "git diff --check limpio.")
	_validate_order(integrate_source)


func _preload_configuration_matches() -> bool:
	return (
		_scalar_close(
			_system.trick_preload_min_hold_time,
			_vehicle.trick_preload_min_hold_time
		)
		and _scalar_close(
			_system.trick_preload_full_charge_time,
			_vehicle.trick_preload_full_charge_time
		)
		and _scalar_close(
			_system.trick_preload_min_input,
			_vehicle.trick_preload_min_input
		)
		and _scalar_close(
			_system.trick_reversal_min_input,
			_vehicle.trick_reversal_min_input
		)
		and _scalar_close(
			_system.trick_reversal_takeoff_window,
			_vehicle.trick_reversal_takeoff_window
		)
		and _scalar_close(
			_system.trick_takeoff_coyote_time,
			_vehicle.trick_takeoff_coyote_time
		)
		and _scalar_close(
			_system.trick_preload_decay_rate,
			_vehicle.trick_preload_decay_rate
		)
		and _scalar_close(
			_system.trick_minimum_launch_speed,
			_vehicle.trick_minimum_launch_speed
		)
		and _scalar_close(
			_system.trick_full_launch_speed,
			_vehicle.trick_full_launch_speed
		)
	)


func _release_configuration_matches() -> bool:
	return (
		_scalar_close(
			_system.trick_roll_release_torque,
			_vehicle.trick_roll_release_torque
		)
		and _scalar_close(
			_system.trick_pitch_release_torque,
			_vehicle.trick_pitch_release_torque
		)
		and _scalar_close(
			_system.trick_release_duration,
			_vehicle.trick_release_duration
		)
		and _scalar_close(
			_system.trick_minimum_release_charge,
			_vehicle.trick_minimum_release_charge
		)
		and _scalar_close(
			_system.trick_release_curve_power,
			_vehicle.trick_release_curve_power
		)
	)


func _prepare_roll_preload() -> void:
	_system.reset_runtime_state()
	_system.state.roll_preload_sign = 1.0
	_system.state.roll_hold_time = 0.1
	_system.state.roll_charge = 0.6


func _prepare_pitch_preload() -> void:
	_system.reset_runtime_state()
	_system.state.pitch_preload_sign = 1.0
	_system.state.pitch_hold_time = 0.1
	_system.state.pitch_charge = 0.6


func _prepare_supported_state(
	water_support: bool,
	solid_support: bool
) -> void:
	_navigation_state.reset_runtime_state()
	_navigation_state.navigation_state = (
		JetSkiTypes.NavigationState.PARTIALLY_SUBMERGED
	)
	_navigation_state.previous_has_any_support = true
	_navigation_state.has_any_support = true
	_navigation_state.has_water_support = water_support
	_navigation_state.has_solid_support = solid_support
	_navigation_state.true_takeoff_this_tick = false
	_input_state.rider_shift_raw = Vector2.ZERO
	_harness.rider_enabled = true
	_harness.preload_enabled = true
	_harness.submarine_active = false


func _prepare_air_takeoff() -> void:
	_navigation_state.reset_runtime_state()
	_navigation_state.navigation_state = (
		JetSkiTypes.NavigationState.AIRBORNE
	)
	_navigation_state.previous_has_any_support = true
	_navigation_state.has_any_support = false
	_navigation_state.has_water_support = false
	_navigation_state.has_solid_support = false
	_navigation_state.true_takeoff_this_tick = true
	_input_state.rider_shift_raw = Vector2.ZERO
	_harness.rider_enabled = true
	_harness.preload_enabled = true
	_harness.submarine_active = false


func _prepare_release_candidate(
	roll: bool,
	pitch: bool
) -> void:
	_system.reset_runtime_state()
	_system.state.pending_launch_speed_valid = true
	_system.state.pending_speed_factor = 1.0
	_system.state.pending_upward_factor = 0.5
	_system.state.pending_depth_factor = 0.5
	_system.state.roll_reversal_armed = roll
	_system.state.roll_reversal_direction = -1.0 if roll else 0.0
	_system.state.roll_armed_charge = 0.8 if roll else 0.0
	_system.state.roll_preload_sign = 1.0 if roll else 0.0
	_system.state.roll_reversal_time_remaining = (
		_system.trick_reversal_takeoff_window
	)
	_system.state.pitch_reversal_armed = pitch
	_system.state.pitch_reversal_direction = 1.0 if pitch else 0.0
	_system.state.pitch_armed_charge = 0.8 if pitch else 0.0
	_system.state.pitch_preload_sign = -1.0 if pitch else 0.0
	_system.state.pitch_reversal_time_remaining = (
		_system.trick_reversal_takeoff_window
	)


func _prepare_active_release() -> void:
	_system.reset_runtime_state()
	_system.state.release_active = true
	_system.state.release_elapsed = 0.04
	_system.state.release_time_remaining = 0.12
	_system.state.release_strength = Vector2(0.8, 0.4)
	_system.state.release_charge = Vector2(0.9, 0.5)
	_system.state.release_roll_torque = 50.0
	_system.state.release_pitch_torque = 25.0
	_system.state.roll_preload_sign = 1.0
	_system.state.roll_charge = 0.5
	_system.state.takeoff_pending = true
	_system.state.pending_launch_speed_valid = true
	_harness.rider_enabled = true
	_harness.preload_enabled = true
	_harness.submarine_active = false
	_navigation_state.reset_runtime_state()
	_navigation_state.navigation_state = (
		JetSkiTypes.NavigationState.AIRBORNE
	)
	_navigation_state.has_any_support = false
	_navigation_state.previous_has_any_support = false


func _run_update(linear_velocity: Vector3, delta: float) -> void:
	_harness.linear_velocity = linear_velocity
	_harness.delta = delta
	_harness.run_update = true
	_harness.sleeping = false
	for _frame_index in 4:
		await physics_frame
		if not _harness.run_update:
			return
	_fail("El harness Trick no recibió un tick físico.")


func _cancelled() -> bool:
	return (
		not _system.state.takeoff_pending
		and not _system.state.release_active
		and _system.state.release_elapsed == 0.0
		and _system.state.release_time_remaining == 0.0
		and _system.state.release_strength.is_zero_approx()
		and _system.state.release_charge.is_zero_approx()
		and _system.state.launch_consumed
		and _system.state.roll_charge == 0.0
		and _system.state.pitch_charge == 0.0
	)


func _state_is_reset() -> bool:
	return (
		_system.state.preload_state
		== JetSkiTypes.TrickPreloadState.IDLE
		and not _system.state.launch_consumed
		and _system.state.roll_charge == 0.0
		and _system.state.pitch_charge == 0.0
		and not _system.state.takeoff_pending
		and not _system.state.release_active
		and _system.state.release_elapsed == 0.0
		and _system.state.last_launch_type
		== JetSkiTypes.RiderTrickLaunchType.NONE
	)


func _state_signature() -> String:
	return "%s|%s|%s|%s|%s|%s|%s" % [
		_system.state.preload_state,
		_system.state.launch_consumed,
		_system.state.roll_charge,
		_system.state.pitch_charge,
		_system.state.takeoff_pending,
		_system.state.release_active,
		_system.state.release_strength,
	]


func _validate_order(integrate_source: String) -> void:
	var positions := PackedInt32Array([
		integrate_source.find("trick_system.begin_physics_tick()"),
		integrate_source.find("input_system.sample_input("),
		integrate_source.find("submarine_system.update_before_forces("),
		integrate_source.find("water_physics_system.step("),
		integrate_source.find("navigation_system.prepare_support_state("),
		integrate_source.find("submarine_system.capture_pre_contact_state("),
		integrate_source.find("navigation_system.step("),
		integrate_source.find("submarine_system.update_after_contacts("),
		integrate_source.find("trick_system.update_state("),
		integrate_source.find("drive_system.step("),
		integrate_source.find("_apply_rider_dynamics("),
	])
	var valid := true
	for index in positions.size():
		if positions[index] < 0:
			valid = false
		elif index > 0 and positions[index] <= positions[index - 1]:
			valid = false
	if valid:
		print("PASS: ORDEN_FISICO_TRICK")
	else:
		_fail("El orden físico de TrickSystem cambió.")


func _function_source(source: String, signature: String) -> String:
	var start := source.find(signature)
	if start < 0:
		return ""
	var finish := source.find("\nfunc ", start + signature.length())
	if finish < 0:
		finish = source.length()
	return source.substr(start, finish - start)


func _count_nodes_named(node: Node, target_name: StringName) -> int:
	var count: int = 1 if node.name == target_name else 0
	for child: Node in node.get_children():
		count += _count_nodes_named(child, target_name)
	return count


func _scalar_close(actual: float, expected: float) -> bool:
	var tolerance := maxf(
		SCALAR_EPSILON,
		maxf(absf(actual), absf(expected)) * 0.000001
	)
	return absf(actual - expected) <= tolerance


func _vector_close(actual: Vector3, expected: Vector3) -> bool:
	return actual.distance_to(expected) <= VECTOR_EPSILON


func _on_trick_launched(
	launch_type: JetSkiTypes.RiderTrickLaunchType,
	launch_charge: Vector2,
	release_strength: Vector2
) -> void:
	_launch_count += 1
	_last_launch_type = launch_type
	_last_launch_charge = launch_charge
	_last_release_strength = release_strength
	_signal_state_complete = (
		_system.state.release_active
		and _system.state.launch_consumed
		and _system.state.last_launch_type == launch_type
		and _system.state.last_launch_charge == launch_charge
		and _system.state.last_release_strength == release_strength
		and _system.state.preload_state
		== JetSkiTypes.TrickPreloadState.RELEASE_ACTIVE
	)


func _expect(number: int, condition: bool, message: String) -> void:
	if condition:
		print("PASS: %d. %s" % [number, message])
		return
	if number >= 19 and number <= 153:
		_comparison_failed = true
	_fail("%d. %s" % [number, message])


func _fail(message: String) -> void:
	_failed = true
	push_error("FAIL: %s" % message)


func _cleanup() -> void:
	if is_instance_valid(_fixture):
		_fixture.free()
	_vehicle = null
	_system = null
	_harness = null
	_fixture = null
	await physics_frame
	await process_frame


func _finish() -> void:
	print(
		"TRICK_LEGACY_DELEGATED_COMPARISON=%s"
		% ("FAIL" if _comparison_failed else "PASS")
	)
	print(
		"TRICK_SYSTEM_VALIDATION=%s"
		% ("FAIL" if _failed else "PASS")
	)
	quit(1 if _failed else 0)
