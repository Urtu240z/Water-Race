extends SceneTree

class SubmarineHarness:
	extends RigidBody3D

	enum Action {
		NONE,
		CAPTURE,
		BEFORE,
		TORQUE,
	}

	var system: JetSkiSubmarineSystem
	var input_state: JetSkiInputState
	var rider_state: JetSkiRiderDynamicsState
	var action: Action = Action.NONE
	var attitude: Vector2 = Vector2.ZERO
	var delta: float = 0.0
	var torque: Vector3 = Vector3.ZERO
	var body_right: Vector3 = Vector3.RIGHT

	func _integrate_forces(body_state: PhysicsDirectBodyState3D) -> void:
		match action:
			Action.CAPTURE:
				system.capture_pre_contact_state(body_state, attitude)
			Action.BEFORE:
				system.update_before_forces(
					body_state,
					input_state,
					attitude,
					delta
				)
			Action.TORQUE:
				torque = system.calculate_pitch_target_torque(
					body_state,
					rider_state,
					body_right
				)
		action = Action.NONE


const JET_SKI_SCENE := "res://scenes/vehicle/jet_ski.tscn"
const MAIN_SCENE := (
	"res://scenes/levels/island_test/island_test_BLENDER.tscn"
)
const CONTROLLER_SOURCE := (
	"res://scripts/vehicle/jet_ski_controller.gd"
)
const SYSTEM_SOURCE := (
	"res://scripts/vehicle/systems/jet_ski_submarine_system.gd"
)
const STATE_SOURCE := (
	"res://scripts/vehicle/state/jet_ski_submarine_state.gd"
)
const SCALAR_EPSILON: float = 0.0001
const VECTOR_EPSILON: float = 0.0005

var _failed: bool = false
var _comparison_failed: bool = false
var _fixture: Node3D
var _vehicle: JetSkiController
var _system: JetSkiSubmarineSystem
var _harness: SubmarineHarness
var _input_state: JetSkiInputState = JetSkiInputState.new()
var _water_state: JetSkiWaterState = JetSkiWaterState.new()
var _navigation_state: JetSkiNavigationState = JetSkiNavigationState.new()
var _rider_state: JetSkiRiderDynamicsState = (
	JetSkiRiderDynamicsState.new()
)
var _controller_source: String
var _system_source: String
var _state_source: String
var _internal_started_count: int = 0
var _internal_ended_count: int = 0
var _last_ended_duration: float = 0.0
var _last_ended_depth: float = 0.0


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
	await _validate_snapshot()
	_validate_entry_rejections()
	_validate_valid_entry()
	await _validate_active_dive()
	await _validate_exits()
	await _validate_recovery()
	_validate_depth()
	await _validate_pitch_target()
	_validate_integration_and_reset()
	await _cleanup()
	_finish()


func _build_fixture(jet_ski_packed: PackedScene) -> void:
	_fixture = Node3D.new()
	_fixture.name = "SubmarineValidationFixture"

	_vehicle = jet_ski_packed.instantiate() as JetSkiController
	if _vehicle == null:
		_fail("jet_ski.tscn no instancia JetSkiController.")
		return
	_vehicle.name = "JetSki"
	_vehicle.freeze = true
	_vehicle.process_mode = Node.PROCESS_MODE_DISABLED
	_fixture.add_child(_vehicle)

	_system = _vehicle.get_node_or_null(
		"Systems/SubmarineSystem"
	) as JetSkiSubmarineSystem

	_harness = SubmarineHarness.new()
	_harness.name = "SubmarineHarness"
	_harness.gravity_scale = 0.0
	_harness.custom_integrator = true
	_harness.can_sleep = false
	_harness.collision_layer = 0
	_harness.collision_mask = 0
	_harness.system = _system
	_harness.input_state = _input_state
	_harness.rider_state = _rider_state
	_fixture.add_child(_harness)

	root.add_child(_fixture)
	await physics_frame
	await process_frame
	if _system != null:
		_system.dive_started.connect(_on_internal_started)
		_system.dive_ended.connect(_on_internal_ended)


func _read_sources() -> void:
	_controller_source = FileAccess.get_file_as_string(
		CONTROLLER_SOURCE
	)
	_system_source = FileAccess.get_file_as_string(SYSTEM_SOURCE)
	_state_source = FileAccess.get_file_as_string(STATE_SOURCE)


func _validate_structure_and_configuration() -> void:
	var system_count := _count_nodes_named(_vehicle, &"SubmarineSystem")
	var state_identity := _system.state
	_expect(
		3,
		_system != null,
		"Existe JetSki/Systems/SubmarineSystem."
	)
	_expect(
		4,
		not _system.has_method("_process")
		and not _system.has_method("_physics_process")
		and not _system.has_method("_integrate_forces")
		and not _system.is_processing()
		and not _system.is_physics_processing(),
		"SubmarineSystem no tiene procesamiento autónomo."
	)
	_system.reset_runtime_state(false)
	_expect(
		5,
		system_count == 1 and is_same(state_identity, _system.state),
		"Existe un único state persistente."
	)
	_expect(
		6,
		not _controller_source.contains("var _rider_stunt_water_mode")
		and not _controller_source.contains("var _submarine_entry_speed")
		and not _controller_source.contains(
			"var _submarine_pre_contact_valid"
		),
		"No queda estado runtime submarino duplicado."
	)
	_expect(
		7,
		not _controller_source.contains(
			"func _update_submarine_before_forces"
		)
		and not _controller_source.contains(
			"func _try_start_submarine_dive"
		)
		and not _controller_source.contains(
			"func _calculate_submarine_pitch_target_torque"
		),
		"No quedan fórmulas submarinas en el controlador."
	)
	_expect(
		8,
		_controller_source.contains(
			"const RiderStuntWaterMode = JetSkiTypes.RiderStuntWaterMode"
		)
		and _state_source.contains(
			"JetSkiTypes.RiderStuntWaterMode"
		),
		"El enum compartido y su alias público se conservan."
	)
	_expect(
		9,
		_configuration_matches_controller(),
		"Los exports se copian correctamente."
	)
	var integrate_source := _function_source(
		_controller_source,
		"func _integrate_forces("
	)
	_expect(
		10,
		not integrate_source.contains("_configure_submarine_system")
		and _controller_source.count(
			"_configure_submarine_system()"
		) == 2,
		"La configuración se copia sólo en _ready()."
	)
	_expect(
		11,
		_system.SUBMARINE_MAX_ENTRY_ROLL_DEGREES == 45.0
		and _system.SUBMARINE_MIN_EXIT_SPEED == 3.0
		and _system.SUBMARINE_SAFETY_DEPTH == 3.0
		and _system.SUBMARINE_CLEAR_NOSE_UP_DEGREES == 10.0
		and _system.SUBMARINE_ENTRY_BUOYANCY_BLEND_TIME == 0.12,
		"Valores y thresholds coinciden con legacy."
	)
	_expect(
		12,
		not _system_source.contains("TrickPreloadState")
		and not _system_source.contains("trick_release"),
		"Tricks no se copian al sistema."
	)
	_expect(
		13,
		not _system_source.contains("air_correction")
		and not _system_source.contains("apply_air_torque"),
		"Rider Air no se copia al sistema."
	)


func _validate_snapshot() -> void:
	var sample_transform := Transform3D(
		Basis.from_euler(Vector3(0.1, 0.2, -0.15)),
		Vector3(4.0, 5.0, 6.0)
	)
	var sample_linear := Vector3(3.0, -2.0, -4.0)
	var sample_angular := Vector3(0.4, -0.2, 0.1)
	var sample_attitude := Vector2(0.2, -0.35)
	await _capture(
		sample_transform,
		sample_linear,
		sample_angular,
		sample_attitude
	)
	_expect(14, _system.state.pre_contact_valid, "Snapshot válido.")
	_expect(
		16,
		_transform_close(
			_system.state.pre_contact_transform,
			sample_transform
		),
		"Transform almacenado."
	)
	_expect(
		17,
		_vector_close(
			_system.state.pre_contact_linear_velocity,
			sample_linear
		),
		"Velocidad lineal almacenada."
	)
	_expect(
		18,
		_vector_close(
			_system.state.pre_contact_angular_velocity,
			sample_angular
		),
		"Velocidad angular almacenada."
	)
	_expect(
		19,
		_scalar_close(
			_system.state.pre_contact_roll_degrees,
			rad_to_deg(sample_attitude.x)
		),
		"Roll almacenado."
	)
	_expect(
		20,
		_scalar_close(
			_system.state.pre_contact_pitch_degrees,
			rad_to_deg(sample_attitude.y)
		),
		"Pitch almacenado."
	)
	_expect(
		21,
		_scalar_close(
			_system.state.pre_contact_horizontal_speed,
			Vector2(sample_linear.x, sample_linear.z).length()
		),
		"Velocidad horizontal almacenada."
	)
	var stored_transform := _system.state.pre_contact_transform
	var stored_linear := _system.state.pre_contact_linear_velocity
	var stored_angular := _system.state.pre_contact_angular_velocity
	var stored_roll := _system.state.pre_contact_roll_degrees
	var stored_pitch := _system.state.pre_contact_pitch_degrees
	await _capture(
		sample_transform,
		sample_linear,
		sample_angular,
		Vector2(NAN, 0.0)
	)
	_expect(
		15,
		not _system.state.pre_contact_valid,
		"Snapshot no finito queda inválido."
	)
	var capture_index := _controller_source.find(
		"submarine_system.capture_pre_contact_state("
	)
	var dry_guard_index := _controller_source.rfind(
		"water_state.raw_contact_mask == 0",
		capture_index
	)
	_expect(
		22,
		dry_guard_index >= 0 and dry_guard_index < capture_index,
		"No se captura con contacto de agua."
	)
	_system.state.pre_contact_valid = true
	_system.state.pre_contact_transform = stored_transform
	_system.state.pre_contact_linear_velocity = stored_linear
	_system.state.pre_contact_angular_velocity = stored_angular
	_system.state.pre_contact_roll_degrees = stored_roll
	_system.state.pre_contact_pitch_degrees = stored_pitch
	var shift := Vector3(100.0, 0.0, -60.0)
	_system.apply_world_rebase(shift)
	var expected_rebased := stored_transform
	expected_rebased.origin -= shift
	_expect(
		23,
		_transform_close(
			_system.state.pre_contact_transform,
			expected_rebased
		),
		"Rebase desplaza sólo el origin."
	)
	_expect(
		24,
		_vector_close(
			_system.state.pre_contact_linear_velocity,
			stored_linear
		)
		and _vector_close(
			_system.state.pre_contact_angular_velocity,
			stored_angular
		)
		and _scalar_close(
			_system.state.pre_contact_roll_degrees,
			stored_roll
		)
		and _scalar_close(
			_system.state.pre_contact_pitch_degrees,
			stored_pitch
		),
		"Rebase no cambia velocidades ni actitud."
	)


func _validate_entry_rejections() -> void:
	_prepare_entry()
	_system.dive_enabled = false
	_attempt_entry()
	_expect(25, not _system.is_dive_active(), "Rechaza sistema deshabilitado.")

	_prepare_entry()
	_system.state.pre_contact_valid = false
	_attempt_entry()
	_expect(26, not _system.is_dive_active(), "Rechaza snapshot inválido.")

	_prepare_entry()
	_system.state.water_mode = (
		JetSkiTypes.RiderStuntWaterMode.SUBMARINE_DIVE
	)
	_attempt_entry()
	_expect(
		27,
		_system.state.entry_speed == 0.0,
		"Rechaza modo no NORMAL."
	)

	_prepare_entry()
	_system.state.recovery_active = true
	_attempt_entry()
	_expect(28, not _system.is_dive_active(), "Rechaza recovery activo.")

	_prepare_entry()
	_input_state.rider_shift_raw.y = -0.599
	_attempt_entry()
	_expect(29, not _system.is_dive_active(), "Rechaza input menor que 0.60.")

	_prepare_entry()
	_system.state.pre_contact_horizontal_speed = (
		_system.entry_min_speed - 0.001
	)
	_attempt_entry()
	_expect(30, not _system.is_dive_active(), "Rechaza velocidad insuficiente.")

	_prepare_entry()
	_system.state.pre_contact_pitch_degrees = (
		-_system.entry_min_nose_down_degrees + 0.001
	)
	_attempt_entry()
	_expect(31, not _system.is_dive_active(), "Rechaza nose down bajo.")

	_prepare_entry()
	_system.state.pre_contact_pitch_degrees = (
		-_system.entry_max_nose_down_degrees - 0.001
	)
	_attempt_entry()
	_expect(32, not _system.is_dive_active(), "Rechaza nose down alto.")

	_prepare_entry()
	_system.state.pre_contact_roll_degrees = 45.0
	_attempt_entry()
	_expect(33, not _system.is_dive_active(), "Rechaza roll en el límite.")

	_prepare_entry()
	_system.state.pre_contact_transform = Transform3D(
		Basis.from_euler(Vector3(PI, 0.0, 0.0)),
		Vector3.ZERO
	)
	_attempt_entry()
	_expect(34, not _system.is_dive_active(), "Rechaza vehicle up invertido.")

	_prepare_entry()
	var shallow_up := Vector3(0.0, 0.24, sqrt(1.0 - 0.24 * 0.24))
	_system.state.pre_contact_transform.basis.y = shallow_up
	_attempt_entry()
	_expect(35, not _system.is_dive_active(), "Rechaza vehicle up dot bajo.")

	_prepare_entry()
	_navigation_state.new_contact_mask = 5
	_set_point_depths([0.1, 0.1, 0.1, 0.1])
	_attempt_entry()
	_expect(36, not _system.is_dive_active(), "Rechaza entrada no frontal.")

	_prepare_entry()
	_navigation_state.new_contact_mask = 12
	_attempt_entry()
	_expect(37, not _system.is_dive_active(), "Rechaza contacto sólo trasero.")

	_prepare_entry()
	_navigation_state.new_contact_mask = 5
	_set_point_depths([0.10, 0.10, 0.08, 0.08])
	_attempt_entry()
	_expect(
		38,
		not _system.is_dive_active(),
		"Rechaza diferencia frontal insuficiente."
	)


func _validate_valid_entry() -> void:
	_prepare_entry()
	_navigation_state.new_contact_mask = 3
	_attempt_entry()
	_expect(39, _system.is_dive_active(), "Entrada por más contactos frontales.")

	_prepare_entry()
	_navigation_state.new_contact_mask = 5
	_set_point_depths([0.20, 0.20, 0.10, 0.10])
	_attempt_entry()
	_expect(40, _system.is_dive_active(), "Entrada por profundidad frontal.")

	_prepare_entry()
	_input_state.rider_shift_raw.y = -0.60
	_attempt_entry()
	_expect(41, _system.is_dive_active(), "Acepta threshold exacto de input.")

	_prepare_entry()
	_system.state.pre_contact_horizontal_speed = _system.entry_min_speed
	_attempt_entry()
	_expect(42, _system.is_dive_active(), "Acepta threshold exacto de velocidad.")

	_prepare_entry()
	_system.state.pre_contact_pitch_degrees = (
		-_system.entry_min_nose_down_degrees
	)
	_attempt_entry()
	_expect(43, _system.is_dive_active(), "Acepta nose down mínimo exacto.")

	_prepare_entry()
	_system.state.pre_contact_pitch_degrees = (
		-_system.entry_max_nose_down_degrees
	)
	_attempt_entry()
	_expect(44, _system.is_dive_active(), "Acepta nose down máximo exacto.")

	_prepare_entry()
	_system.state.pre_contact_roll_degrees = 44.999
	_attempt_entry()
	_expect(45, _system.is_dive_active(), "Roll estrictamente menor pasa.")

	_prepare_entry()
	var expected_speed := _system.state.pre_contact_horizontal_speed
	var expected_pitch := _system.state.pre_contact_pitch_degrees
	var started_before := _internal_started_count
	_attempt_entry()
	_expect(
		46,
		_system.state.water_mode
		== JetSkiTypes.RiderStuntWaterMode.SUBMARINE_DIVE,
		"Cambia al modo SUBMARINE_DIVE."
	)
	_expect(
		47,
		_scalar_close(_system.state.entry_speed, expected_speed),
		"Entry speed coincide."
	)
	_expect(
		48,
		_scalar_close(_system.state.entry_pitch_degrees, expected_pitch),
		"Entry pitch coincide."
	)
	_expect(49, _system.state.duration == 0.0, "Duration comienza a cero.")
	_expect(
		50,
		_scalar_close(
			_system.state.current_depth,
			_water_state.average_depth
		),
		"Current depth inicial coincide."
	)
	_expect(
		51,
		_scalar_close(
			_system.state.maximum_depth,
			_water_state.average_depth
		),
		"Maximum depth inicial coincide."
	)
	_expect(
		52,
		_scalar_close(_system.state.buoyancy_factor_current, 1.0)
		and _scalar_close(
			_system.state.propulsion_factor_current,
			_system.propulsion_factor
		)
		and _scalar_close(
			_system.state.upright_factor_current,
			_system.upright_factor
		),
		"Factores iniciales conservan semántica legacy."
	)
	_expect(
		53,
		not _system.state.recovery_active,
		"Recovery queda desactivado."
	)
	_expect(
		54,
		_internal_started_count == started_before + 1,
		"Señal interna de inicio se emite una vez."
	)
	var callback_source := _function_source(
		_controller_source,
		"func _on_submarine_system_dive_started("
	)
	_expect(
		55,
		callback_source.find(
			"_cancel_rider_trick_state_for_submarine()"
		) < callback_source.find("submarine_dive_started.emit()"),
		"Tricks se cancela antes de la señal pública."
	)


func _validate_active_dive() -> void:
	_prepare_active_dive()
	_system.state.buoyancy_factor_current = 1.0
	_input_state.rider_shift_raw = Vector2(0.0, -0.75)
	_input_state.rider_shift_smoothed = Vector2(0.0, 0.0)
	var delta := 0.03
	await _before(
		Vector3(0.0, 0.0, -8.0),
		Vector2.ZERO,
		delta
	)
	var legacy_buoyancy := move_toward(
		1.0,
		_system.buoyancy_factor,
		delta * absf(1.0 - _system.buoyancy_factor)
		/ _system.SUBMARINE_ENTRY_BUOYANCY_BLEND_TIME
	)
	_expect(56, _scalar_close(_system.state.duration, delta), "Duration aumenta.")
	_expect(
		57,
		_scalar_close(
			_system.state.buoyancy_factor_current,
			legacy_buoyancy
		),
		"Buoyancy blend coincide con legacy."
	)
	_expect(
		58,
		_scalar_close(
			_system.state.propulsion_factor_current,
			_system.propulsion_factor
		),
		"Propulsion factor aplicado."
	)
	_expect(
		59,
		_scalar_close(
			_system.state.upright_factor_current,
			_system.upright_factor
		),
		"Upright factor aplicado."
	)
	_expect(60, _system.state.exit_blend == 0.0, "Exit blend queda a cero.")
	_expect(
		61,
		not _system.state.recovery_active,
		"Recovery permanece desactivado durante dive."
	)
	_expect(62, _system.is_dive_active(), "Se utiliza el input raw mantenido.")
	_expect(
		63,
		_system.is_dive_active()
		and _input_state.rider_shift_smoothed.is_zero_approx(),
		"El input smoothed se ignora para mantener el dive."
	)


func _validate_exits() -> void:
	await _run_exit_case(false, -0.75, 0.0, 8.0, 0.0, 0.0)
	_expect(64, not _system.is_dive_active(), "Salida al deshabilitar submarine.")

	await _run_exit_case(true, -0.59, 0.0, 8.0, 0.0, 0.0)
	_expect(65, not _system.is_dive_active(), "Salida al liberar input.")

	await _run_exit_case(
		true,
		-0.75,
		_system.maximum_duration,
		8.0,
		0.0,
		0.0
	)
	_expect(66, not _system.is_dive_active(), "Salida por duración máxima.")

	await _run_exit_case(true, -0.75, 0.0, 2.999, 0.0, 0.0)
	_expect(67, not _system.is_dive_active(), "Salida por velocidad mínima.")

	await _run_exit_case(
		true,
		-0.75,
		0.0,
		8.0,
		deg_to_rad(10.001),
		0.0
	)
	_expect(68, not _system.is_dive_active(), "Salida por nose up claro.")

	await _run_exit_case(true, -0.75, 0.0, 8.0, 0.0, 3.0)
	_expect(69, not _system.is_dive_active(), "Salida por profundidad segura.")

	await _run_exit_case(true, -0.75, 0.2, 8.0, 0.0, 0.5)
	_expect(70, _system.is_dive_active(), "Sin condición de salida mantiene dive.")

	_system.reset_runtime_state(false)
	var ended_before := _internal_ended_count
	_system._end_dive()
	_expect(
		71,
		_internal_ended_count == ended_before,
		"Sólo finaliza desde modo activo."
	)

	_prepare_active_dive()
	_system.state.duration = 0.8
	_system.state.maximum_depth = 1.4
	ended_before = _internal_ended_count
	_system._end_dive()
	_expect(
		72,
		_internal_ended_count == ended_before + 1,
		"Señal ended se emite una vez."
	)
	_expect(
		73,
		_scalar_close(_last_ended_duration, 0.8),
		"Duración correcta en señal."
	)
	_expect(
		74,
		_scalar_close(_last_ended_depth, 1.4),
		"Maximum depth correcta en señal."
	)


func _validate_recovery() -> void:
	_prepare_active_dive()
	_system.state.buoyancy_factor_current = 0.81
	_system._end_dive()
	_expect(75, _system.state.recovery_active, "Recovery se activa al finalizar.")
	_expect(
		76,
		_scalar_close(
			_system.state.exit_start_buoyancy_factor,
			0.81
		),
		"Captura factor inicial de flotación."
	)
	_expect(77, _system.state.exit_blend == 0.0, "Exit blend empieza a cero.")

	var half_delta := _system.exit_blend_time * 0.5
	await _before(Vector3(0.0, 0.0, -8.0), Vector2.ZERO, half_delta)
	var expected_weight := smoothstep(0.0, 1.0, 0.5)
	_expect(
		78,
		_scalar_close(_system.state.exit_blend, 0.5),
		"Recovery progresa temporalmente."
	)
	_expect(
		79,
		_scalar_close(expected_weight, 0.5),
		"Recovery utiliza smoothstep."
	)
	_expect(
		80,
		_scalar_close(
			_system.state.buoyancy_factor_current,
			lerpf(0.81, 1.0, expected_weight)
		),
		"Recovery de buoyancy coincide."
	)
	_expect(
		81,
		_scalar_close(
			_system.state.propulsion_factor_current,
			lerpf(_system.propulsion_factor, 1.0, expected_weight)
		),
		"Recovery de propulsion coincide."
	)
	_expect(
		82,
		_scalar_close(
			_system.state.upright_factor_current,
			lerpf(_system.upright_factor, 1.0, expected_weight)
		),
		"Recovery de upright coincide."
	)
	await _before(
		Vector3(0.0, 0.0, -8.0),
		Vector2.ZERO,
		_system.exit_blend_time
	)
	_expect(
		83,
		_system.state.exit_blend == 1.0
		and _system.state.buoyancy_factor_current == 1.0
		and _system.state.propulsion_factor_current == 1.0
		and _system.state.upright_factor_current == 1.0,
		"Recovery finaliza exactamente en uno."
	)
	_expect(
		84,
		not _system.state.recovery_active,
		"Recovery se desactiva al terminar."
	)
	_prepare_active_dive()
	_system._end_dive()
	_system.state.exit_blend = 0.35
	_expect(
		85,
		_scalar_close(_system.get_control_blend(), 0.65),
		"Control blend durante recovery."
	)
	_system.state.water_mode = (
		JetSkiTypes.RiderStuntWaterMode.SUBMARINE_DIVE
	)
	_expect(86, _system.get_control_blend() == 1.0, "Control blend durante dive.")
	_system.reset_runtime_state(false)
	_expect(87, _system.get_control_blend() == 0.0, "Control blend normal.")


func _validate_depth() -> void:
	_prepare_active_dive()
	_water_state.average_depth = 0.8
	_navigation_state.previous_contact_mask = 1
	_navigation_state.current_contact_mask = 1
	_system.update_after_contacts(
		_input_state,
		_water_state,
		_navigation_state,
		_vehicle.water_physics_system
	)
	_expect(
		88,
		_scalar_close(_system.state.current_depth, 0.8),
		"Profundidad actual durante dive."
	)
	_system._end_dive()
	_water_state.average_depth = 1.1
	_system.update_after_contacts(
		_input_state,
		_water_state,
		_navigation_state,
		_vehicle.water_physics_system
	)
	_expect(
		89,
		_scalar_close(_system.state.current_depth, 1.1),
		"Profundidad actual durante recovery."
	)
	_water_state.average_depth = 0.4
	_system.update_after_contacts(
		_input_state,
		_water_state,
		_navigation_state,
		_vehicle.water_physics_system
	)
	_expect(
		90,
		_scalar_close(_system.state.maximum_depth, 1.1),
		"Maximum depth sólo aumenta."
	)
	_system.reset_runtime_state(false)
	_system.state.current_depth = 0.6
	_navigation_state.current_contact_mask = 0
	_system.update_after_contacts(
		_input_state,
		_water_state,
		_navigation_state,
		_vehicle.water_physics_system
	)
	_expect(91, _system.state.current_depth == 0.0, "Depth vuelve a cero en seco.")
	_system.state.current_depth = 0.6
	_navigation_state.previous_contact_mask = 1
	_navigation_state.current_contact_mask = 1
	_system.update_after_contacts(
		_input_state,
		_water_state,
		_navigation_state,
		_vehicle.water_physics_system
	)
	_expect(
		92,
		_system.state.current_depth == 0.6,
		"Contacto normal conserva semántica legacy."
	)


func _validate_pitch_target() -> void:
	_system.reset_runtime_state(false)
	_rider_state.rider_shift_current_pitch = 0.0
	_rider_state.rider_manual_medium_authority = 1.0
	await _torque(Vector3.ZERO, Vector3.RIGHT)
	_expect(93, _harness.torque.is_zero_approx(), "Inactivo devuelve cero.")

	_prepare_active_dive()
	_rider_state.rider_shift_current_pitch = (
		-deg_to_rad(_system.target_nose_down_degrees) + 0.1
	)
	_rider_state.rider_manual_medium_authority = 1.0
	await _torque(Vector3.ZERO, Vector3.RIGHT)
	var expected_error := wrapf(
		-deg_to_rad(_system.target_nose_down_degrees)
		- _rider_state.rider_shift_current_pitch,
		-PI,
		PI
	)
	var expected_torque := _legacy_pitch_torque(
		Vector3.ZERO,
		Vector3.RIGHT
	)
	_expect(
		94,
		_system_source.contains(
			"-deg_to_rad(target_nose_down_degrees)"
		),
		"Target nose down conserva signo."
	)
	_expect(95, expected_error < 0.0, "Pitch error conserva dirección.")
	_expect(
		96,
		_system_source.contains("wrapf(")
		and _system_source.contains("-PI, PI"),
		"Pitch error usa wrapf(-PI, PI)."
	)
	_expect(
		97,
		_system_source.contains(
			"body_state.angular_velocity.dot(body_right)"
		),
		"Pitch rate usa el eje body right."
	)
	_expect(
		98,
		_system_source.contains(
			"rider_soft_limit_stiffness * 0.30"
		),
		"Stiffness conserva factor 0.30."
	)
	_expect(
		99,
		_system_source.contains(
			"rider_soft_limit_damping * 0.20"
		),
		"Damping conserva factor 0.20."
	)
	_expect(
		100,
		_system_source.contains("deg_to_rad(20.0)"),
		"Maximum torque se basa en 20 grados."
	)
	_expect(
		102,
		_vector_close(_harness.torque, expected_torque)
		and _harness.torque.x < 0.0,
		"Clamp negativo y fórmula legacy coinciden."
	)
	_rider_state.rider_shift_current_pitch = (
		-deg_to_rad(_system.target_nose_down_degrees) - 0.1
	)
	await _torque(Vector3.ZERO, Vector3.RIGHT)
	expected_torque = _legacy_pitch_torque(
		Vector3.ZERO,
		Vector3.RIGHT
	)
	_expect(
		101,
		_vector_close(_harness.torque, expected_torque)
		and _harness.torque.x > 0.0,
		"Clamp positivo y fórmula legacy coinciden."
	)
	_expect(
		103,
		absf(_harness.torque.y) <= VECTOR_EPSILON
		and absf(_harness.torque.z) <= VECTOR_EPSILON,
		"Torque sigue body right."
	)
	var full_torque := _harness.torque
	_rider_state.rider_manual_medium_authority = 0.35
	await _torque(Vector3.ZERO, Vector3.RIGHT)
	_expect(
		104,
		_vector_close(_harness.torque, full_torque * 0.35),
		"Manual authority escala el torque."
	)
	var rider_source := _function_source(
		_controller_source,
		"func _apply_rider_dynamics("
	)
	_expect(
		105,
		rider_source.contains("rider_weight_shift_enabled")
		and rider_source.contains(
			"not _rider_shift_smoothed_input.is_zero_approx()"
		)
		and rider_source.contains(
			"submarine_system.calculate_pitch_target_torque("
		),
		"Gating legacy permanece en el controlador."
	)


func _validate_integration_and_reset() -> void:
	var integrate_source := _function_source(
		_controller_source,
		"func _integrate_forces("
	)
	var rider_source := _function_source(
		_controller_source,
		"func _apply_rider_dynamics("
	)
	_expect(
		106,
		integrate_source.contains(
			"submarine_system.state.buoyancy_factor_current"
		),
		"Water Physics recibe buoyancy factor."
	)
	_expect(
		107,
		integrate_source.contains(
			"submarine_system.state.propulsion_factor_current"
		),
		"Drive recibe propulsion factor."
	)
	_expect(
		108,
		rider_source.contains(
			"submarine_system.state.upright_factor_current"
		),
		"Rider Dynamics recibe upright factor."
	)
	_expect(
		109,
		rider_source.contains("submarine_system.get_control_blend()"),
		"Rider Dynamics recibe control blend."
	)
	_expect(
		110,
		rider_source.contains("external_submarine_pitch_torque"),
		"Rider Dynamics recibe pitch torque externo."
	)
	_expect(
		111,
		not _system_source.contains("JetSkiNavigationSystem")
		and _system_source.contains("JetSkiNavigationState"),
		"Navigation mantiene autoridad independiente."
	)
	_expect(
		112,
		not _system_source.contains("DEEP_SUBMERGED")
		and _controller_source.contains("deeply_submerged"),
		"Deep submersion permanece independiente."
	)
	_expect(
		113,
		_controller_source.contains(
			"func _calculate_trick_release_torque("
		),
		"Trick Release permanece en el controlador."
	)
	_expect(
		114,
		_controller_source.contains("var _trick_preload_state")
		and not _system_source.contains("_trick_"),
		"Trick state no se mueve."
	)
	_expect(
		115,
		_controller_source.contains("signal submarine_dive_started()")
		and _controller_source.contains(
			"signal submarine_dive_ended(duration: float, max_depth: float)"
		),
		"Señales públicas conservan firma."
	)

	var state_identity := _system.state
	_system.reset_runtime_state(false)
	var ended_before := _internal_ended_count
	_system.reset_runtime_state(true)
	_expect(
		116,
		is_same(state_identity, _system.state)
		and _internal_ended_count == ended_before
		and _state_is_reset(),
		"Reset normal preserva identidad y no emite."
	)
	_prepare_active_dive()
	_system.state.duration = 0.7
	_system.state.maximum_depth = 1.2
	ended_before = _internal_ended_count
	_system.reset_runtime_state(true)
	_expect(
		117,
		_internal_ended_count == ended_before + 1
		and _scalar_close(_last_ended_duration, 0.7)
		and _scalar_close(_last_ended_depth, 1.2)
		and _state_is_reset(),
		"Reset durante dive emite una vez y limpia."
	)
	_prepare_active_dive()
	_system._end_dive()
	ended_before = _internal_ended_count
	_system.reset_runtime_state(true)
	_expect(
		118,
		_internal_ended_count == ended_before and _state_is_reset(),
		"Reset durante recovery no duplica señal."
	)
	var rebase_source := _function_source(
		_controller_source,
		"func apply_world_rebase("
	)
	_expect(
		119,
		rebase_source.contains(
			"submarine_system.apply_world_rebase(horizontal_shift)"
		),
		"Rebase se delega."
	)
	_expect(
		120,
		load("res://scripts/vehicle/systems/jet_ski_input_system.gd")
		!= null,
		"Contrato Input disponible para su validador."
	)
	_expect(
		121,
		load(
			"res://scripts/vehicle/systems/jet_ski_water_physics_system.gd"
		) != null,
		"Contrato Water Physics disponible para su validador."
	)
	_expect(
		122,
		load(
			"res://scripts/vehicle/systems/jet_ski_navigation_system.gd"
		) != null,
		"Contrato Navigation disponible para su validador."
	)
	_expect(
		123,
		load("res://scripts/vehicle/systems/jet_ski_drive_system.gd")
		!= null,
		"Contrato Drive disponible para su validador."
	)
	_expect(
		124,
		load(
			"res://scripts/vehicle/systems/jet_ski_rider_dynamics_system.gd"
		) != null,
		"Contrato Rider Dynamics disponible para su validador."
	)
	_expect(
		125,
		load("res://scripts/vehicle/vehicle_water_audio.gd") != null,
		"Contrato VehicleWaterAudio disponible para su validador."
	)
	_expect(
		126,
		load(SYSTEM_SOURCE) != null and load(STATE_SOURCE) != null,
		"Sin errores de parser."
	)
	_expect(
		127,
		_system is JetSkiSubmarineSystem
		and _system.state is JetSkiSubmarineState,
		"Sin errores de inferencia de tipos globales."
	)
	_expect(
		128,
		not _system_source.contains("@warning_ignore")
		and not _state_source.contains("@warning_ignore")
		and not _controller_source.contains(
			"SHADOWED_VARIABLE_BASE_CLASS"
		),
		"Sin warnings silenciados ni warnings GDScript reales."
	)
	var git_output: Array = []
	var git_exit := OS.execute(
		"git",
		PackedStringArray(["diff", "--check"]),
		git_output,
		true
	)
	_expect(129, git_exit == 0, "git diff --check limpio.")
	_expect_order(integrate_source)


func _configuration_matches_controller() -> bool:
	return (
		_system.dive_enabled == _vehicle.submarine_dive_enabled
		and _scalar_close(
			_system.entry_min_nose_down_degrees,
			_vehicle.submarine_entry_min_nose_down_degrees
		)
		and _scalar_close(
			_system.entry_max_nose_down_degrees,
			_vehicle.submarine_entry_max_nose_down_degrees
		)
		and _scalar_close(
			_system.entry_min_speed,
			_vehicle.submarine_entry_min_speed
		)
		and _scalar_close(
			_system.target_nose_down_degrees,
			_vehicle.submarine_target_nose_down_degrees
		)
		and _scalar_close(
			_system.maximum_duration,
			_vehicle.submarine_max_duration
		)
		and _scalar_close(
			_system.upright_factor,
			_vehicle.submarine_upright_factor
		)
		and _scalar_close(
			_system.buoyancy_factor,
			_vehicle.submarine_buoyancy_factor
		)
		and _scalar_close(
			_system.propulsion_factor,
			_vehicle.submarine_propulsion_factor
		)
		and _scalar_close(
			_system.exit_blend_time,
			_vehicle.submarine_exit_blend_time
		)
	)


func _prepare_entry() -> void:
	_system.reset_runtime_state(false)
	_system.dive_enabled = true
	_system.state.pre_contact_valid = true
	_system.state.pre_contact_transform = Transform3D.IDENTITY
	_system.state.pre_contact_roll_degrees = 0.0
	_system.state.pre_contact_pitch_degrees = -30.0
	_system.state.pre_contact_horizontal_speed = 10.0
	_input_state.rider_shift_raw = Vector2(0.0, -0.75)
	_input_state.rider_shift_smoothed = Vector2.ZERO
	_water_state.average_depth = 0.2
	_navigation_state.previous_contact_mask = 0
	_navigation_state.current_contact_mask = 3
	_navigation_state.new_contact_mask = 3
	_set_point_depths([0.1, 0.1, 0.1, 0.1])


func _attempt_entry() -> void:
	_system._try_start_dive(
		_input_state,
		_water_state,
		_navigation_state,
		_vehicle.water_physics_system
	)


func _prepare_active_dive() -> void:
	_system.reset_runtime_state(false)
	_system.dive_enabled = true
	_system.state.water_mode = (
		JetSkiTypes.RiderStuntWaterMode.SUBMARINE_DIVE
	)
	_system.state.exit_blend = 0.0
	_system.state.recovery_active = false
	_input_state.rider_shift_raw = Vector2(0.0, -0.75)
	_input_state.rider_shift_smoothed = Vector2(0.0, -0.75)


func _run_exit_case(
	enabled: bool,
	raw_y: float,
	duration: float,
	speed: float,
	pitch: float,
	depth: float
) -> void:
	_prepare_active_dive()
	_system.dive_enabled = enabled
	_system.state.duration = duration
	_system.state.current_depth = depth
	_input_state.rider_shift_raw.y = raw_y
	await _before(
		Vector3(0.0, 0.0, -speed),
		Vector2(0.0, pitch),
		0.0
	)


func _capture(
	body_transform: Transform3D,
	linear: Vector3,
	angular: Vector3,
	attitude: Vector2
) -> void:
	_harness.global_transform = body_transform
	_harness.linear_velocity = linear
	_harness.angular_velocity = angular
	_harness.attitude = attitude
	_harness.action = SubmarineHarness.Action.CAPTURE
	await _wait_for_harness()


func _before(
	linear: Vector3,
	attitude: Vector2,
	delta: float
) -> void:
	_harness.linear_velocity = linear
	_harness.attitude = attitude
	_harness.delta = delta
	_harness.action = SubmarineHarness.Action.BEFORE
	await _wait_for_harness()


func _torque(angular: Vector3, body_right: Vector3) -> void:
	_harness.angular_velocity = angular
	_harness.body_right = body_right
	_harness.torque = Vector3.ZERO
	_harness.action = SubmarineHarness.Action.TORQUE
	await _wait_for_harness()


func _wait_for_harness() -> void:
	_harness.sleeping = false
	for frame_index in 4:
		await physics_frame
		if _harness.action == SubmarineHarness.Action.NONE:
			return
	_fail("El harness no recibió un tick físico.")


func _set_point_depths(values: Array[float]) -> void:
	_vehicle.water_physics_system.set(
		"_point_depths",
		PackedFloat32Array(values)
	)


func _legacy_pitch_torque(
	angular_velocity: Vector3,
	body_right: Vector3
) -> Vector3:
	var pitch_error := wrapf(
		-deg_to_rad(_system.target_nose_down_degrees)
		- _rider_state.rider_shift_current_pitch,
		-PI,
		PI
	)
	var pitch_rate := angular_velocity.dot(body_right)
	var maximum_torque := (
		_system.rider_soft_limit_stiffness * deg_to_rad(20.0)
	)
	var torque := clampf(
		pitch_error * _system.rider_soft_limit_stiffness * 0.30
		- pitch_rate * _system.rider_soft_limit_damping * 0.20,
		-maximum_torque,
		maximum_torque
	)
	return (
		body_right
		* torque
		* _rider_state.rider_manual_medium_authority
	)


func _state_is_reset() -> bool:
	return (
		not _system.is_dive_active()
		and _system.state.entry_speed == 0.0
		and _system.state.entry_pitch_degrees == 0.0
		and _system.state.duration == 0.0
		and _system.state.current_depth == 0.0
		and _system.state.maximum_depth == 0.0
		and _system.state.buoyancy_factor_current == 1.0
		and _system.state.propulsion_factor_current == 1.0
		and _system.state.upright_factor_current == 1.0
		and _system.state.exit_blend == 1.0
		and not _system.state.recovery_active
		and not _system.state.pre_contact_valid
	)


func _expect_order(integrate_source: String) -> void:
	var positions := PackedInt32Array([
		integrate_source.find("input_system.sample_input("),
		integrate_source.find("submarine_system.update_before_forces("),
		integrate_source.find("water_physics_system.step("),
		integrate_source.find("navigation_system.prepare_support_state("),
		integrate_source.find("submarine_system.capture_pre_contact_state("),
		integrate_source.find("navigation_system.step("),
		integrate_source.find("submarine_system.update_after_contacts("),
		integrate_source.find("_update_rider_trick_state("),
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
		print("PASS: ORDEN_FISICO_1_A_10")
	else:
		_fail("El orden físico Input→Submarine→Water→Navigation→Tricks→Drive→Rider cambió.")


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


func _transform_close(
	actual: Transform3D,
	expected: Transform3D
) -> bool:
	return (
		_vector_close(actual.origin, expected.origin)
		and _vector_close(actual.basis.x, expected.basis.x)
		and _vector_close(actual.basis.y, expected.basis.y)
		and _vector_close(actual.basis.z, expected.basis.z)
	)


func _vector_close(actual: Vector3, expected: Vector3) -> bool:
	return actual.distance_to(expected) <= VECTOR_EPSILON


func _scalar_close(actual: float, expected: float) -> bool:
	var tolerance := maxf(
		SCALAR_EPSILON,
		maxf(absf(actual), absf(expected)) * 0.000001
	)
	return absf(actual - expected) <= tolerance


func _on_internal_started() -> void:
	_internal_started_count += 1


func _on_internal_ended(duration: float, maximum_depth: float) -> void:
	_internal_ended_count += 1
	_last_ended_duration = duration
	_last_ended_depth = maximum_depth


func _expect(number: int, condition: bool, message: String) -> void:
	if condition:
		print("PASS: %d. %s" % [number, message])
		return
	if number >= 14 and number <= 119:
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
		"LEGACY_DELEGATED_COMPARISON=%s"
		% ("FAIL" if _comparison_failed else "PASS")
	)
	print(
		"SUBMARINE_SYSTEM_VALIDATION=%s"
		% ("FAIL" if _failed else "PASS")
	)
	quit(1 if _failed else 0)
