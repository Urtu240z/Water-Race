extends SceneTree

class RiderHarness:
	extends RigidBody3D

	var rider_system: JetSkiRiderDynamicsSystem
	var input_state: JetSkiInputState
	var water_state: JetSkiWaterState
	var navigation_state: JetSkiNavigationState
	var drive_state: JetSkiDriveState
	var submarine_dive_active: bool = false
	var submarine_upright_factor: float = 1.0
	var submarine_control_blend: float = 0.0
	var external_submarine_pitch_torque: Vector3 = Vector3.ZERO
	var external_trick_release_torque: Vector3 = Vector3.ZERO

	func _integrate_forces(body_state: PhysicsDirectBodyState3D) -> void:
		rider_system.begin_physics_tick()
		var using_air: bool = rider_system.prepare_mode(
			body_state,
			navigation_state
		)
		if not rider_system.has_valid_body_axes():
			return
		rider_system.update_air_rotation_metrics(body_state)
		rider_system.prepare_common_metrics(
			input_state,
			water_state,
			navigation_state,
			drive_state,
			submarine_dive_active
		)
		if using_air:
			if not rider_system.prepare_air_metrics(
				body_state,
				input_state
			):
				return
			rider_system.apply_air_torque(
				body_state,
				input_state,
				external_trick_release_torque
			)
			return
		if not rider_system.prepare_supported(
			body_state,
			input_state,
			water_state,
			navigation_state,
			drive_state
		):
			return
		rider_system.apply_supported_torque(
			body_state,
			input_state,
			submarine_upright_factor,
			submarine_control_blend,
			external_submarine_pitch_torque
		)


const JET_SKI_SCENE := "res://scenes/vehicle/jet_ski.tscn"
const RIDER_SCENE := "res://scenes/vehicle/jet_ski_with_rider.tscn"
const MAIN_SCENE := (
	"res://scenes/levels/island_test/island_test_BLENDER.tscn"
)
const CONTROLLER_SOURCE := (
	"res://scripts/vehicle/jet_ski_controller.gd"
)
const SYSTEM_SOURCE := (
	"res://scripts/vehicle/systems/"
	+ "jet_ski_rider_dynamics_system.gd"
)
const STATE_SOURCE := (
	"res://scripts/vehicle/state/"
	+ "jet_ski_rider_dynamics_state.gd"
)
const SCALAR_EPSILON: float = 0.0001
const RELATIVE_EPSILON: float = 0.000001
const VECTOR_EPSILON: float = 0.0005
const PHYSICS_DELTA: float = 1.0 / 60.0

var _failed: bool = false
var _comparison_failed: bool = false
var _fixture: Node3D
var _water_system: JetSkiWaterPhysicsSystem
var _system: JetSkiRiderDynamicsSystem
var _harness: RiderHarness
var _input_state := JetSkiInputState.new()
var _water_state := JetSkiWaterState.new()
var _navigation_state := JetSkiNavigationState.new()
var _drive_state := JetSkiDriveState.new()
var _vehicle: JetSkiController
var _main_instance: Node
var _rider_instance: Node


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var jet_ski_packed := load(JET_SKI_SCENE) as PackedScene
	var main_packed := load(MAIN_SCENE) as PackedScene
	var rider_packed := load(RIDER_SCENE) as PackedScene
	_expect_numbered(1, jet_ski_packed != null, "jet_ski.tscn carga.")
	_expect_numbered(2, main_packed != null, "La escena principal carga.")
	if (
		jet_ski_packed == null
		or main_packed == null
		or rider_packed == null
	):
		_finish()
		return
	await _build_fixture(
		jet_ski_packed,
		main_packed,
		rider_packed
	)
	_validate_structure_and_configuration()
	await _validate_state_and_modes()
	await _validate_normals_axes_and_turn_lean()
	await _validate_lateral_shift()
	await _validate_longitudinal_shift()
	await _validate_air_control_5b()
	await _validate_compatibility()
	_report_legacy_equivalence()
	await _report_air_legacy_equivalence()
	jet_ski_packed = null
	main_packed = null
	rider_packed = null
	await _cleanup()
	_finish()


func _build_fixture(
	jet_ski_packed: PackedScene,
	main_packed: PackedScene,
	rider_packed: PackedScene
) -> void:
	_fixture = Node3D.new()
	_fixture.name = "RiderDynamicsValidationFixture"
	_water_system = JetSkiWaterPhysicsSystem.new()
	_water_system.name = "WaterPointSource"
	var points_root := Node3D.new()
	points_root.name = "BuoyancyPoints"
	for point_name: StringName in [
		&"FrontLeft",
		&"FrontRight",
		&"RearLeft",
		&"RearRight",
	]:
		var marker := Marker3D.new()
		marker.name = point_name
		points_root.add_child(marker)
	_water_system.add_child(points_root)
	_water_system.configure(points_root)
	_fixture.add_child(_water_system)

	_harness = RiderHarness.new()
	_harness.name = "RiderHarness"
	_harness.gravity_scale = 0.0
	_harness.custom_integrator = true
	_harness.can_sleep = false
	_harness.collision_layer = 0
	_harness.collision_mask = 0
	_system = JetSkiRiderDynamicsSystem.new()
	_system.name = "RiderDynamicsSystem"
	_system.configure(_water_system)
	_harness.add_child(_system)
	_harness.rider_system = _system
	_harness.input_state = _input_state
	_harness.water_state = _water_state
	_harness.navigation_state = _navigation_state
	_harness.drive_state = _drive_state
	_fixture.add_child(_harness)

	_vehicle = jet_ski_packed.instantiate() as JetSkiController
	_vehicle.name = "SceneJetSki"
	_vehicle.freeze = true
	_fixture.add_child(_vehicle)
	_main_instance = main_packed.instantiate()
	_rider_instance = rider_packed.instantiate()
	root.add_child(_fixture)
	await process_frame
	_stop_audio_recursive(_fixture)
	_stop_audio_recursive(_main_instance)
	_stop_audio_recursive(_rider_instance)


func _validate_structure_and_configuration() -> void:
	var scene_system := _vehicle.get_node_or_null(
		"Systems/RiderDynamicsSystem"
	) as JetSkiRiderDynamicsSystem
	_expect_numbered(
		3,
		scene_system != null,
		"Existe JetSki/Systems/RiderDynamicsSystem."
	)
	var system_source := FileAccess.get_file_as_string(SYSTEM_SOURCE)
	var state_source := FileAccess.get_file_as_string(STATE_SOURCE)
	var controller_source := FileAccess.get_file_as_string(
		CONTROLLER_SOURCE
	)
	_expect_numbered(
		4,
		not system_source.contains("func _process(")
		and not system_source.contains("func _physics_process(")
		and not system_source.contains("func _integrate_forces("),
		"RiderDynamicsSystem no tiene procesamiento autónomo."
	)
	_expect_numbered(
		5,
		system_source.count("JetSkiRiderDynamicsState.new()") == 1
		and state_source.contains(
			"class_name JetSkiRiderDynamicsState"
		),
		"Existe un único RiderDynamicsState persistente."
	)
	var forbidden_runtime_storage := false
	for name: String in [
		"var _turn_lean_target_roll",
		"var _turn_lean_current_roll",
		"var _turn_lean_smoothed_support_normal",
		"var _rider_shift_speed_authority",
		"var _rider_shift_current_pitch",
		"var _rider_virtual_offset_local",
		"var _rider_manual_applied_torque",
		"func _calculate_turn_lean_pd_torque",
		"func _calculate_virtual_rider_weight_torque",
		"func _calculate_rider_shift_soft_limit_torque",
	]:
		forbidden_runtime_storage = (
			forbidden_runtime_storage
			or controller_source.contains(name)
		)
	_expect_numbered(
		6,
		not forbidden_runtime_storage,
		"El controlador no conserva estado o fórmulas supported."
	)
	var turn_configuration_matches := (
		_scalar_close(
			scene_system.turn_lean_max_angle_degrees,
			_vehicle.turn_lean_max_angle_degrees
		)
		and _scalar_close(
			scene_system.turn_lean_start_speed,
			_vehicle.turn_lean_start_speed
		)
		and _scalar_close(
			scene_system.turn_lean_full_speed,
			_vehicle.turn_lean_full_speed
		)
		and _scalar_close(
			scene_system.turn_lean_stiffness,
			_vehicle.turn_lean_stiffness
		)
		and _scalar_close(
			scene_system.turn_lean_damping,
			_vehicle.turn_lean_damping
		)
		and _scalar_close(
			scene_system.turn_lean_max_torque,
			_vehicle.turn_lean_max_torque
		)
		and _scalar_close(
			scene_system.turn_lean_reverse_factor,
			_vehicle.turn_lean_reverse_factor
		)
		and _scalar_close(
			scene_system.turn_lean_landing_ramp_time,
			_vehicle.turn_lean_landing_ramp_time
		)
		and _scalar_close(
			scene_system.turn_lean_support_normal_half_life,
			_vehicle.turn_lean_support_normal_half_life
		)
	)
	_expect_numbered(
		7,
		turn_configuration_matches,
		"Los exports Turn Lean se copian correctamente."
	)
	var rider_configuration_matches := (
		_scalar_close(
			scene_system.rider_effective_mass,
			_vehicle.rider_effective_mass
		)
		and _scalar_close(
			scene_system.rider_lateral_shift_distance,
			_vehicle.rider_lateral_shift_distance
		)
		and _scalar_close(
			scene_system.rider_longitudinal_shift_distance,
			_vehicle.rider_longitudinal_shift_distance
		)
		and _scalar_close(
			scene_system.rider_weight_torque_multiplier,
			_vehicle.rider_weight_torque_multiplier
		)
		and _scalar_close(
			scene_system.rider_shift_full_speed,
			_vehicle.rider_shift_full_speed
		)
		and _scalar_close(
			scene_system.rider_manual_roll_max_angle_degrees,
			_vehicle.rider_manual_roll_max_angle_degrees
		)
		and _scalar_close(
			scene_system.rider_wheelie_throttle_boost,
			_vehicle.rider_wheelie_throttle_boost
		)
		and _scalar_close(
			scene_system.rider_nose_dive_speed_boost,
			_vehicle.rider_nose_dive_speed_boost
		)
		and _scalar_close(
			scene_system.rider_soft_limit_stiffness,
			_vehicle.rider_soft_limit_stiffness
		)
	)
	_expect_numbered(
		8,
		rider_configuration_matches,
		"Los exports Rider Weight Shift se copian correctamente."
	)
	var integrate_start := controller_source.find(
		"func _integrate_forces("
	)
	var integrate_end := controller_source.find(
		"\nfunc ",
		integrate_start + 1
	)
	var integrate_source := controller_source.substr(
		integrate_start,
		integrate_end - integrate_start
	)
	_expect_numbered(
		9,
		not integrate_source.contains(
			"_configure_rider_dynamics_system"
		)
		and controller_source.count(
			"_configure_rider_dynamics_system()"
		) == 2,
		"La configuración se copia solo en _ready()."
	)
	_expect_numbered(
		10,
		controller_source.contains("rider_air_max_roll_rate")
		and controller_source.contains(
			"func _calculate_submarine_pitch_target_torque"
		)
		and controller_source.contains(
			"func _calculate_trick_release_torque"
		)
		and system_source.contains(
			"air_correction_target_roll_rate"
		)
		and system_source.contains("func apply_air_torque(")
		and not system_source.contains("submarine_max_duration")
		and not system_source.contains("trick_release_duration"),
		"Air pertenece al sistema; Submarine y Tricks permanecen fuera."
	)


func _validate_state_and_modes() -> void:
	var persistent_state := _system.state
	_reset_case()
	await _run_harness()
	_expect_numbered(
		11,
		_system.state == persistent_state,
		"RiderDynamicsState mantiene identidad."
	)
	_system.state.turn_lean_requested_torque = 123.0
	_system.state.manual_applied_torque = Vector3.ONE
	_system.begin_physics_tick()
	_expect_numbered(
		12,
		is_zero_approx(
			_system.state.turn_lean_requested_torque
		)
		and _system.state.manual_applied_torque.is_zero_approx(),
		"Las métricas de frame se limpian."
	)
	_system.state.smoothed_support_normal = Vector3.UP.rotated(
		Vector3.RIGHT,
		0.2
	)
	var normal_before := _system.state.smoothed_support_normal
	_system.begin_physics_tick()
	_expect_numbered(
		13,
		_system.state.smoothed_support_normal == normal_before,
		"La normal suavizada persiste entre frames."
	)
	_system.state.turn_lean_landing_ramp = 0.4
	_system.state.rider_shift_landing_ramp = 0.6
	_system.begin_physics_tick()
	_expect_numbered(
		14,
		_scalar_close(
			_system.state.turn_lean_landing_ramp,
			0.4
		)
		and _scalar_close(
			_system.state.rider_shift_landing_ramp,
			0.6
		),
		"Las rampas persisten entre frames."
	)
	_system.reset_runtime_state()
	_expect_numbered(
		15,
		_system.state == persistent_state
		and _system.state.smoothed_support_normal == Vector3.UP
		and _system.state.reference_forward == Vector3.FORWARD
		and _system.state.reference_right == Vector3.RIGHT
		and is_zero_approx(
			_system.state.turn_lean_landing_ramp
		)
		and is_zero_approx(
			_system.state.rider_shift_landing_ramp
		),
		"Reset restaura estado sin cambiar su identidad."
	)
	var scene_state := _vehicle.rider_dynamics_system.state
	scene_state.turn_lean_requested_torque = 456.0
	scene_state.total_applied_torque_vector = Vector3.ONE
	_vehicle.freeze = false
	_vehicle.sleeping = false
	await physics_frame
	_vehicle.freeze = true
	_expect_numbered(
		16,
		is_zero_approx(scene_state.turn_lean_requested_torque)
		and scene_state.total_applied_torque_vector.is_zero_approx(),
		"Un early return no deja torque obsoleto."
	)
	_reset_case()
	_set_support(15, false, true)
	await _run_harness()
	_expect_numbered(
		17,
		not _system.state.using_air_control,
		"El agua selecciona la rama supported."
	)
	_reset_case()
	_set_support(0, true, false)
	await _run_harness()
	_expect_numbered(
		18,
		not _system.state.using_air_control,
		"Una rampa sólida selecciona la rama supported."
	)
	_reset_case()
	_set_support(0, false, false)
	await _run_harness()
	_expect_numbered(
		19,
		_system.state.using_air_control
		and _system.state.turn_lean_airborne_disabled
		and _system.state.rider_shift_airborne,
		"La ausencia de soporte selecciona Air Control."
	)
	_reset_case()
	_set_support(0, true, false)
	await _run_harness()
	_expect_numbered(
		20,
		not _system.state.using_air_control,
		"Perder agua sobre una rampa no activa Air Control."
	)
	_system.reset_runtime_state()
	var reset_mode_is_clear := (
		not _system.state.using_air_control
		and not _system.state.rider_shift_airborne
	)
	_set_support(0, false, false)
	await _run_harness()
	_expect_numbered(
		21,
		reset_mode_is_clear and _system.state.using_air_control,
		"El primer tick tras reset conserva la semántica previa."
	)


func _validate_normals_axes_and_turn_lean() -> void:
	_reset_case()
	_set_support(15, false, true)
	_seed_water_points(0.4, Vector3.UP)
	await _run_harness()
	_expect_numbered(
		22,
		_vector_close(
			_system.state.smoothed_support_normal,
			Vector3.UP
		),
		"La normal plana se conserva."
	)
	var slope := Vector3(0.0, 1.0, 0.35).normalized()
	_reset_case()
	_set_support(15, false, true)
	_seed_water_points(0.4, slope)
	await _run_harness()
	_expect_numbered(
		23,
		_system.state.smoothed_support_normal.z > 0.0,
		"La normal inclinada conserva su dirección."
	)
	_reset_case()
	_set_support(15, false, true)
	_seed_water_points(0.4, Vector3.DOWN)
	await _run_harness()
	_expect_numbered(
		24,
		_vector_close(
			_system.state.smoothed_support_normal,
			Vector3.UP
		),
		"Una normal invertida se orienta hacia arriba."
	)
	_reset_case()
	_set_support(15, false, true)
	_seed_water_points(0.4, Vector3.ZERO, false)
	await _run_harness()
	_expect_numbered(
		25,
		_vector_close(
			_system.state.smoothed_support_normal,
			Vector3.UP
		),
		"Una normal degenerada usa el fallback legacy."
	)
	_reset_case()
	_set_support(15, false, true)
	_seed_water_points(0.4, slope)
	await _run_harness()
	var blend := 1.0 - exp(
		-JetSkiRiderDynamicsSystem.HALF_LIFE_LOG_TWO
		* PHYSICS_DELTA
		/ _system.turn_lean_support_normal_half_life
	)
	var expected_smoothed := Vector3.UP.lerp(
		slope,
		clampf(blend, 0.0, 1.0)
	).normalized()
	_expect_numbered(
		26,
		_vector_close(
			_system.state.smoothed_support_normal,
			expected_smoothed
		),
		"El suavizado conserva su half-life."
	)
	_expect_numbered(
		27,
		absf(
			_system.state.reference_forward.dot(
				_system.state.smoothed_support_normal
			)
		) <= VECTOR_EPSILON,
		"Forward queda proyectado sobre el soporte."
	)
	_expect_numbered(
		28,
		_vector_close(
			_system.state.reference_right,
			_system.state.reference_forward.cross(
				_system.state.smoothed_support_normal
			).normalized()
		),
		"Right conserva el orden del cross."
	)
	_reset_case()
	_set_support(15, false, true)
	await _run_harness()
	_expect_numbered(
		29,
		_vector_close(
			_system.state.reference_forward,
			Vector3.FORWARD
		),
		"La convención forward=-Z se conserva."
	)
	var roll_transform := Transform3D(
		Basis(Vector3.FORWARD, deg_to_rad(10.0)),
		Vector3.ZERO
	)
	_reset_case()
	_set_support(15, false, true)
	await _run_harness(roll_transform)
	var roll_positive := _system.state.turn_lean_current_roll > 0.0
	var pitch_transform := Transform3D(
		Basis(Vector3.RIGHT, deg_to_rad(10.0)),
		Vector3.ZERO
	)
	_reset_case()
	_set_support(15, false, true)
	await _run_harness(pitch_transform)
	_expect_numbered(
		30,
		roll_positive
		and _system.state.rider_shift_current_pitch > 0.0,
		"Los signos de roll y pitch coinciden."
	)
	_system.turn_lean_enabled = false
	_reset_case(false)
	_set_support(15, false, true)
	_set_motion_inputs(20.0, 1.0, 0.0, 1.0, Vector2.ZERO)
	_system.state.turn_lean_landing_ramp = 1.0
	await _run_harness()
	_expect_numbered(
		31,
		is_zero_approx(_system.state.turn_lean_target_roll)
		and _system.state.turn_lean_applied_torque_vector.is_zero_approx(),
		"Turn Lean deshabilitado no aplica torque automático."
	)
	_system.turn_lean_enabled = true
	_reset_case()
	_set_support(15, false, true)
	_set_motion_inputs(20.0, 1.0, 0.0, 0.0, Vector2.ZERO)
	_system.state.turn_lean_landing_ramp = 1.0
	await _run_harness()
	_expect_numbered(
		32,
		is_zero_approx(_system.state.turn_lean_target_roll),
		"Steering cero produce target cero."
	)
	_reset_case()
	_set_support(15, false, true)
	_set_motion_inputs(20.0, 1.0, 0.0, -1.0, Vector2.ZERO)
	_system.state.turn_lean_landing_ramp = 1.0
	await _run_harness()
	var left_target := _system.state.turn_lean_target_roll
	_expect_numbered(
		33,
		left_target < 0.0,
		"Steering izquierda conserva su signo."
	)
	_reset_case()
	_set_support(15, false, true)
	_set_motion_inputs(20.0, 1.0, 0.0, 1.0, Vector2.ZERO)
	_system.state.turn_lean_landing_ramp = 1.0
	await _run_harness()
	var right_target := _system.state.turn_lean_target_roll
	_expect_numbered(
		34,
		right_target > 0.0
		and _scalar_close(absf(left_target), right_target),
		"Steering derecha conserva su signo."
	)
	_reset_case()
	_set_support(15, false, true)
	_set_motion_inputs(2.0, 1.0, 0.0, 1.0, Vector2.ZERO)
	_system.state.turn_lean_landing_ramp = 1.0
	await _run_harness()
	_expect_numbered(
		35,
		is_zero_approx(_system.state.turn_lean_speed_factor),
		"La velocidad inferior al inicio no tiene autoridad."
	)
	var middle_speed := 9.5
	_reset_case()
	_set_support(15, false, true)
	_set_motion_inputs(
		middle_speed,
		1.0,
		0.0,
		1.0,
		Vector2.ZERO
	)
	_system.state.turn_lean_landing_ramp = 1.0
	await _run_harness()
	_expect_numbered(
		36,
		_scalar_close(
			_system.state.turn_lean_speed_factor,
			smoothstep(3.0, 16.0, middle_speed)
		),
		"La autoridad intermedia conserva smoothstep."
	)
	_reset_case()
	_set_support(15, false, true)
	_set_motion_inputs(20.0, 1.0, 0.0, 1.0, Vector2.ZERO)
	_system.state.turn_lean_landing_ramp = 1.0
	await _run_harness()
	_expect_numbered(
		37,
		_scalar_close(_system.state.turn_lean_speed_factor, 1.0),
		"La velocidad completa alcanza autoridad uno."
	)
	_expect_numbered(
		38,
		_system.state.turn_lean_target_roll > 0.0,
		"La marcha hacia delante conserva el signo."
	)
	var forward_target := _system.state.turn_lean_target_roll
	_reset_case()
	_set_support(15, false, true)
	_set_motion_inputs(-20.0, 0.0, 1.0, 1.0, Vector2.ZERO)
	_system.state.turn_lean_landing_ramp = 1.0
	await _run_harness()
	_expect_numbered(
		39,
		_system.state.turn_lean_target_roll < 0.0,
		"La marcha atrás invierte el lean."
	)
	_expect_numbered(
		40,
		_scalar_close(
			absf(_system.state.turn_lean_target_roll),
			absf(forward_target)
			* _system.turn_lean_reverse_factor
		),
		"Reverse factor conserva su magnitud."
	)
	_reset_case()
	_set_support(1, false, true)
	_set_motion_inputs(20.0, 1.0, 0.0, 1.0, Vector2.ZERO)
	_drive_state.propulsion_contact_factor = 0.5
	_water_state.average_depth = 0.08
	_system.state.turn_lean_landing_ramp = 1.0
	await _run_harness()
	var expected_partial_contact := (
		0.15
		* lerpf(0.5, 1.0, smoothstep(0.0, 0.16, 0.08))
		* lerpf(0.25, 1.0, 0.5)
	)
	_expect_numbered(
		41,
		_scalar_close(
			_system.state.turn_lean_contact_factor,
			expected_partial_contact
		),
		"El contacto parcial conserva todos sus factores."
	)
	_reset_case()
	_set_support(15, false, true)
	_set_motion_inputs(20.0, 1.0, 0.0, 1.0, Vector2.ZERO)
	_system.state.turn_lean_landing_ramp = 1.0
	await _run_harness()
	_expect_numbered(
		42,
		_scalar_close(
			_system.state.turn_lean_contact_factor,
			1.0
		),
		"El contacto completo alcanza factor uno."
	)
	_reset_case()
	_set_support(15, false, true)
	_set_motion_inputs(20.0, 1.0, 0.0, 1.0, Vector2.ZERO)
	await _run_harness()
	_expect_numbered(
		43,
		_scalar_close(
			_system.state.turn_lean_landing_ramp,
			PHYSICS_DELTA / _system.turn_lean_landing_ramp_time
		),
		"Turn Lean conserva la landing ramp."
	)
	_expect_numbered(
		44,
		_scalar_close(
			_system.state.turn_lean_roll_error,
			wrapf(
				_system.state.rider_shift_total_roll_target
				- _system.state.turn_lean_current_roll,
				-PI,
				PI
			)
		),
		"El error de roll conserva wrapf."
	)
	_reset_case()
	_set_support(15, false, true)
	_set_motion_inputs(20.0, 1.0, 0.0, 0.2, Vector2.ZERO)
	_system.state.turn_lean_landing_ramp = 1.0
	await _run_harness()
	var expected_stiffness_torque := clampf(
		_system.state.turn_lean_roll_error
		* _system.turn_lean_stiffness,
		-_system.turn_lean_max_torque,
		_system.turn_lean_max_torque
	)
	_expect_numbered(
		45,
		_scalar_close(
			_system.state.turn_lean_requested_torque,
			expected_stiffness_torque
		),
		"El término stiffness coincide."
	)
	_reset_case()
	_set_support(15, false, true)
	_set_motion_inputs(20.0, 0.0, 0.0, 0.0, Vector2.ZERO)
	_system.state.turn_lean_landing_ramp = 1.0
	await _run_harness(
		Transform3D.IDENTITY,
		Vector3.ZERO,
		Vector3.FORWARD
	)
	_expect_numbered(
		46,
		_scalar_close(
			_system.state.turn_lean_requested_torque,
			clampf(
				_system.state.turn_lean_roll_error
				* _system.turn_lean_stiffness
				- _system.state.turn_lean_roll_rate
				* _system.turn_lean_damping,
				-_system.turn_lean_max_torque,
				_system.turn_lean_max_torque
			)
		),
		"El término damping conserva roll rate y signo."
	)
	var large_roll := Transform3D(
		Basis(Vector3.FORWARD, deg_to_rad(-60.0)),
		Vector3.ZERO
	)
	_reset_case()
	_set_support(15, false, true)
	_set_motion_inputs(20.0, 1.0, 0.0, 1.0, Vector2.ZERO)
	_system.state.turn_lean_landing_ramp = 1.0
	await _run_harness(large_roll)
	_expect_numbered(
		47,
		_scalar_close(
			absf(_system.state.turn_lean_requested_torque),
			_system.turn_lean_max_torque
		),
		"El torque PD respeta el clamp máximo."
	)
	_reset_case()
	_set_support(15, false, true)
	_set_motion_inputs(20.0, 1.0, 0.0, 0.2, Vector2.ZERO)
	_system.state.turn_lean_landing_ramp = 1.0
	_harness.submarine_upright_factor = 0.5
	await _run_harness()
	_expect_numbered(
		48,
		_scalar_close(
			_system.state.turn_lean_requested_torque,
			_system.state.turn_lean_roll_error
			* _system.turn_lean_stiffness
			* 0.5
		),
		"Submarine upright escala stiffness y damping."
	)
	_expect_numbered(
		49,
		_vector_close(
			_system.state.turn_lean_applied_torque_vector,
			_system.state.reference_forward
			* _system.state.turn_lean_requested_torque
			* _system.state.turn_lean_contact_factor
		),
		"El torque Turn Lean usa el eje forward correcto."
	)


func _validate_lateral_shift() -> void:
	_reset_case()
	_set_support(15, false, true)
	_set_motion_inputs(20.0, 0.0, 0.0, 0.0, Vector2.ZERO)
	_system.state.turn_lean_landing_ramp = 1.0
	await _run_harness()
	_expect_numbered(
		50,
		is_zero_approx(
			_system.state.rider_shift_manual_roll_target
		),
		"Input lateral cero produce target manual cero."
	)
	_reset_case()
	_set_support(15, false, true)
	_set_motion_inputs(
		20.0,
		0.0,
		0.0,
		0.0,
		Vector2(0.5, 0.0)
	)
	_system.state.turn_lean_landing_ramp = 1.0
	await _run_harness()
	_expect_numbered(
		51,
		_scalar_close(
			_system.state.rider_shift_manual_roll_target,
			deg_to_rad(
				_system.rider_manual_roll_max_angle_degrees
			) * 0.5
		),
		"Input lateral parcial escala linealmente."
	)
	_reset_case()
	_set_support(15, false, true)
	_set_motion_inputs(
		20.0,
		0.0,
		0.0,
		0.0,
		Vector2(1.0, 0.0)
	)
	_system.state.turn_lean_landing_ramp = 1.0
	await _run_harness()
	_expect_numbered(
		52,
		_scalar_close(
			_system.state.rider_shift_manual_roll_target,
			deg_to_rad(
				_system.rider_manual_roll_max_angle_degrees
			)
		),
		"Input lateral completo alcanza el target máximo."
	)
	_reset_case()
	_set_support(15, false, true)
	_set_motion_inputs(
		20.0,
		0.0,
		0.0,
		0.0,
		Vector2(-1.0, 0.0)
	)
	_system.state.turn_lean_landing_ramp = 1.0
	await _run_harness()
	var left_manual := (
		_system.state.rider_shift_manual_roll_target
	)
	_expect_numbered(53, left_manual < 0.0, "Shift izquierda conserva signo.")
	_reset_case()
	_set_support(15, false, true)
	_set_motion_inputs(
		20.0,
		0.0,
		0.0,
		0.0,
		Vector2(1.0, 0.0)
	)
	_system.state.turn_lean_landing_ramp = 1.0
	await _run_harness()
	_expect_numbered(
		54,
		_system.state.rider_shift_manual_roll_target > 0.0
		and _scalar_close(
			absf(left_manual),
			_system.state.rider_shift_manual_roll_target
		),
		"Shift derecha conserva signo."
	)
	_expect_numbered(
		55,
		_scalar_close(
			_system.state.rider_shift_manual_roll_target,
			deg_to_rad(16.0)
		),
		"El target manual conserva ángulo y autoridad."
	)
	_reset_case()
	_set_support(15, false, true)
	_set_motion_inputs(
		20.0,
		1.0,
		0.0,
		0.5,
		Vector2(0.25, 0.0)
	)
	_system.state.turn_lean_landing_ramp = 1.0
	await _run_harness()
	_expect_numbered(
		56,
		_scalar_close(
			_system.state.rider_shift_total_roll_target,
			clampf(
				_system.state.turn_lean_target_roll
				+ _system.state.rider_shift_manual_roll_target,
				-deg_to_rad(
					_system.rider_roll_soft_limit_degrees
				),
				deg_to_rad(
					_system.rider_roll_soft_limit_degrees
				)
			)
		),
		"Shift manual se combina con Turn Lean."
	)
	_expect_numbered(
		57,
		_scalar_close(
			_system.state.rider_shift_speed_factor,
			smoothstep(0.0, 9.0, 20.0)
		)
		and _scalar_close(
			_system.state.rider_shift_speed_authority,
			1.0
		),
		"La autoridad por velocidad conserva su curva."
	)
	_expect_numbered(
		58,
		_scalar_close(
			_system.state.rider_shift_contact_authority,
			_system.state.rider_manual_medium_authority
		),
		"La autoridad de contacto conserva su alias."
	)
	_reset_case()
	_set_support(
		15,
		false,
		true,
		JetSkiTypes.NavigationState.LANDING
	)
	_system.state.rider_shift_landing_ramp = 0.5
	_set_motion_inputs(
		20.0,
		0.0,
		0.0,
		0.0,
		Vector2(0.5, 0.0)
	)
	await _run_harness()
	_expect_numbered(
		59,
		_scalar_close(
			_system.state.rider_manual_medium_authority,
			lerpf(0.35, 1.0, 0.5)
		),
		"La landing ramp escala la autoridad manual."
	)
	var over_roll := Transform3D(
		Basis(Vector3.FORWARD, deg_to_rad(40.0)),
		Vector3.ZERO
	)
	_reset_case()
	_set_support(15, false, true)
	_set_motion_inputs(
		20.0,
		0.0,
		0.0,
		0.0,
		Vector2(1.0, 0.0)
	)
	_system.state.turn_lean_landing_ramp = 1.0
	await _run_harness(over_roll)
	_expect_numbered(
		60,
		_system.state.roll_soft_limit_factor > 0.0
		and _system.state.manual_applied_torque.dot(
			Vector3.FORWARD
		) < 0.0,
		"El soft limit lateral aplica corrección progresiva."
	)
	_expect_numbered(
		61,
		_system.state.roll_damping_torque.is_zero_approx(),
		"El damping lateral conserva el comportamiento legacy."
	)


func _validate_longitudinal_shift() -> void:
	_reset_case()
	_set_support(15, false, true)
	_set_motion_inputs(
		20.0,
		0.0,
		0.0,
		0.0,
		Vector2(0.0, 1.0)
	)
	_system.state.turn_lean_landing_ramp = 1.0
	await _run_harness()
	var back_pitch_torque := _system.state.rider_shift_pitch_torque
	_expect_numbered(
		62,
		back_pitch_torque > 0.0,
		"Input atrás produce torque nose-up."
	)
	_reset_case()
	_set_support(15, false, true)
	_set_motion_inputs(
		20.0,
		0.0,
		0.0,
		0.0,
		Vector2(0.0, -1.0)
	)
	_system.state.turn_lean_landing_ramp = 1.0
	await _run_harness()
	_expect_numbered(
		63,
		_system.state.rider_shift_pitch_torque < 0.0,
		"Input delante produce torque nose-down."
	)
	_expect_numbered(
		64,
		_scalar_close(
			_system.state.virtual_offset_local.z,
			-_system.rider_longitudinal_shift_distance
		),
		"El offset longitudinal conserva distancia y signo."
	)
	var expected_weight_torque := (
		9.81
		* _system.rider_effective_mass
		* _system.rider_longitudinal_shift_distance
		* _system.rider_weight_torque_multiplier
		* _system.state.rider_manual_medium_authority
		* _system.state.dynamic_pitch_multiplier
	)
	_expect_numbered(
		65,
		_scalar_close(
			absf(_system.state.virtual_weight_torque.x),
			expected_weight_torque
		),
		"El torque de peso conserva gravedad, masa y brazo."
	)
	_reset_case()
	_set_support(15, false, true)
	_set_motion_inputs(
		20.0,
		1.0,
		0.0,
		0.0,
		Vector2(0.0, 1.0)
	)
	_system.state.turn_lean_landing_ramp = 1.0
	await _run_harness()
	_expect_numbered(
		66,
		_scalar_close(
			_system.state.dynamic_pitch_multiplier,
			1.0 + _system.rider_wheelie_throttle_boost
		),
		"Throttle conserva wheelie boost."
	)
	_reset_case()
	_set_support(15, false, true)
	_set_motion_inputs(
		20.0,
		0.0,
		0.0,
		0.0,
		Vector2(0.0, -1.0)
	)
	_system.state.turn_lean_landing_ramp = 1.0
	await _run_harness()
	_expect_numbered(
		67,
		_scalar_close(
			_system.state.dynamic_pitch_multiplier,
			1.0 + _system.rider_nose_dive_speed_boost
		),
		"La velocidad conserva nose-dive boost."
	)
	_reset_case()
	_set_support(15, false, true)
	_set_motion_inputs(
		20.0,
		0.0,
		0.0,
		0.0,
		Vector2(0.0, 1.0)
	)
	_system.state.turn_lean_landing_ramp = 1.0
	await _run_harness(
		Transform3D.IDENTITY,
		Vector3.ZERO,
		Vector3.RIGHT
	)
	_expect_numbered(
		68,
		_system.state.pitch_damping_torque.x < 0.0,
		"Pitch damping se opone a la velocidad angular."
	)
	var nose_up := Transform3D(
		Basis(Vector3.RIGHT, deg_to_rad(42.0)),
		Vector3.ZERO
	)
	_reset_case()
	_set_support(15, false, true)
	_set_motion_inputs(
		20.0,
		0.0,
		0.0,
		0.0,
		Vector2(0.0, 1.0)
	)
	_system.state.turn_lean_landing_ramp = 1.0
	await _run_harness(nose_up)
	var nose_up_limit_torque := (
		_system.state.manual_applied_torque
		- _system.state.virtual_weight_torque
		- _system.state.roll_damping_torque
		- _system.state.pitch_damping_torque
	)
	_expect_numbered(
		69,
		_system.state.pitch_soft_limit_factor > 0.0
		and nose_up_limit_torque.x < 0.0,
		"El soft limit nose-up corrige hacia dentro."
	)
	var nose_down := Transform3D(
		Basis(Vector3.RIGHT, deg_to_rad(-46.0)),
		Vector3.ZERO
	)
	_reset_case()
	_set_support(15, false, true)
	_set_motion_inputs(
		20.0,
		0.0,
		0.0,
		0.0,
		Vector2(0.0, -1.0)
	)
	_system.state.turn_lean_landing_ramp = 1.0
	await _run_harness(nose_down)
	var nose_down_limit_torque := (
		_system.state.manual_applied_torque
		- _system.state.virtual_weight_torque
		- _system.state.roll_damping_torque
		- _system.state.pitch_damping_torque
	)
	_expect_numbered(
		70,
		_system.state.pitch_soft_limit_factor > 0.0
		and nose_down_limit_torque.x > 0.0,
		"El soft limit nose-down corrige hacia dentro."
	)
	_reset_case()
	_set_support(15, false, true)
	_set_motion_inputs(
		20.0,
		0.0,
		0.0,
		0.0,
		Vector2(0.0, 1.0)
	)
	_system.state.turn_lean_landing_ramp = 1.0
	_harness.submarine_control_blend = 1.0
	await _run_harness(
		Transform3D.IDENTITY,
		Vector3.ZERO,
		Vector3.RIGHT
	)
	_expect_numbered(
		71,
		_scalar_close(
			_system.state.pitch_damping_torque.length(),
			_system.rider_pitch_rate_damping
			* JetSkiRiderDynamicsSystem
			.SUBMARINE_MANUAL_DAMPING_FACTOR
		),
		"Submarine blend conserva su multiplicador de damping."
	)
	var external := Vector3(0.0, 0.0, 37.0)
	_reset_case()
	_set_support(15, false, true)
	_set_motion_inputs(
		20.0,
		0.0,
		0.0,
		0.0,
		Vector2(0.0, 0.5)
	)
	_system.state.turn_lean_landing_ramp = 1.0
	_harness.external_submarine_pitch_torque = external
	await _run_harness()
	_expect_numbered(
		72,
		_vector_close(
			_system.state.manual_applied_torque,
			_system.state.virtual_weight_torque
			+ _system.state.roll_damping_torque
			+ _system.state.pitch_damping_torque
			+ external
		),
		"El torque submarino externo se suma en el punto legacy."
	)


func _validate_air_control_5b() -> void:
	var controller_source := FileAccess.get_file_as_string(
		CONTROLLER_SOURCE
	)
	var system_source := FileAccess.get_file_as_string(SYSTEM_SOURCE)
	var state_source := FileAccess.get_file_as_string(STATE_SOURCE)
	var forbidden_air_runtime := false
	for name: String in [
		"var _rider_air_unlimited_rotation",
		"var _rider_air_roll_rate",
		"var _rider_air_pitch_rate",
		"var _rider_air_accumulated_roll_degrees",
		"var _rider_air_accumulated_pitch_degrees",
		"var _rider_air_tracking_active",
		"var _air_correction_roll_torque_current",
		"var _air_correction_pitch_torque_current",
	]:
		forbidden_air_runtime = (
			forbidden_air_runtime
			or controller_source.contains(name)
		)
	_expect_5b(
		1,
		not forbidden_air_runtime,
		"No quedan variables runtime aÃ©reas duplicadas."
	)
	var forbidden_air_formula := false
	for name: String in [
		"func _apply_rider_shift_air_control",
		"func _calculate_air_rate_correction_torque",
		"func _calculate_rider_air_overspeed_torque",
		"func _update_rider_air_rotation_metrics",
		"func _calculate_rider_world_attitude",
	]:
		forbidden_air_formula = (
			forbidden_air_formula
			or controller_source.contains(name)
		)
	_expect_5b(
		2,
		not forbidden_air_formula
		and system_source.contains("func apply_air_torque(")
		and system_source.contains(
			"func _calculate_air_rate_correction_torque("
		),
		"No quedan fÃ³rmulas de Air Control en el controlador."
	)
	var persistent_state := _system.state
	await _run_air_case(Vector2.ZERO, Vector2.ZERO)
	_expect_5b(
		3,
		_system.state == persistent_state,
		"RiderDynamicsState conserva identidad en Air."
	)
	_expect_5b(
		4,
		not system_source.contains("func _process(")
		and not system_source.contains("func _physics_process(")
		and not system_source.contains("func _integrate_forces("),
		"El sistema no tiene procesamiento autÃ³nomo."
	)
	_reset_case()
	_set_support(15, false, true)
	await _run_harness()
	var supported_state := _system.state
	_set_support(
		0,
		false,
		false,
		JetSkiTypes.NavigationState.AIRBORNE,
		15
	)
	await _run_harness()
	_expect_5b(
		5,
		_system.state == supported_state
		and _system.state.using_air_control,
		"Air y supported utilizan el mismo sistema y state."
	)
	var scene_state := _vehicle.rider_dynamics_system.state
	scene_state.air_unlimited_rotation = true
	scene_state.air_roll_rate = 1.25
	scene_state.air_pitch_rate = -0.75
	scene_state.air_accumulated_roll_degrees = 12.0
	scene_state.air_accumulated_pitch_degrees = -8.0
	scene_state.air_correction_roll_torque_current = 111.0
	scene_state.air_correction_pitch_torque_current = -222.0
	_expect_5b(
		6,
		_vehicle.rider_air_unlimited_rotation
		and _scalar_close(_vehicle.rider_air_roll_rate, 1.25)
		and _scalar_close(_vehicle.air_current_roll_rate, 1.25)
		and _scalar_close(_vehicle.rider_air_pitch_rate, -0.75)
		and _scalar_close(_vehicle.air_current_pitch_rate, -0.75)
		and _scalar_close(
			_vehicle.rider_air_accumulated_roll_degrees,
			12.0
		)
		and _scalar_close(
			_vehicle.rider_air_accumulated_pitch_degrees,
			-8.0
		)
		and _scalar_close(
			_vehicle.air_correction_roll_torque_current,
			111.0
		)
		and _scalar_close(
			_vehicle.air_correction_pitch_torque_current,
			-222.0
		),
		"Los proxies pÃºblicos aÃ©reos apuntan al state."
	)

	_reset_case()
	_set_support(15, false, true)
	await _run_harness()
	_expect_5b(
		7,
		not _system.state.using_air_control
		and not _system.state.air_tracking_active,
		"Supported estable conserva Air inactivo."
	)
	var air_angular_velocity := (
		Vector3.FORWARD * 0.75
		+ Vector3.RIGHT * -0.5
	)
	_set_support(
		0,
		false,
		false,
		JetSkiTypes.NavigationState.AIRBORNE,
		15
	)
	await _run_harness(
		Transform3D.IDENTITY,
		Vector3.ZERO,
		air_angular_velocity
	)
	var first_roll_accumulated := (
		_system.state.air_accumulated_roll_degrees
	)
	var first_pitch_accumulated := (
		_system.state.air_accumulated_pitch_degrees
	)
	_expect_5b(
		8,
		_system.state.using_air_control
		and _system.state.air_tracking_active,
		"La entrada en Air activa tracking."
	)
	await _run_harness(
		Transform3D.IDENTITY,
		Vector3.ZERO,
		air_angular_velocity
	)
	_expect_5b(
		9,
		_system.state.air_tracking_active
		and _scalar_close(
			_system.state.air_accumulated_roll_degrees,
			first_roll_accumulated * 2.0
		)
		and _scalar_close(
			_system.state.air_accumulated_pitch_degrees,
			first_pitch_accumulated * 2.0
		),
		"Air mantenido acumula sin reiniciar."
	)
	_set_support(
		15,
		false,
		true,
		JetSkiTypes.NavigationState.LANDING,
		0
	)
	await _run_harness()
	_expect_5b(
		10,
		not _system.state.using_air_control
		and not _system.state.air_tracking_active,
		"La salida de Air desactiva tracking."
	)
	_reset_case()
	_set_support(15, false, true)
	await _run_harness()
	_set_support(
		0,
		false,
		false,
		JetSkiTypes.NavigationState.AIRBORNE,
		15
	)
	await _run_harness()
	_expect_5b(
		11,
		_system.state.using_air_control,
		"El salto desde agua entra en Air."
	)
	_reset_case()
	_set_support(0, true, false)
	await _run_harness()
	_set_support(
		0,
		false,
		false,
		JetSkiTypes.NavigationState.AIRBORNE,
		0
	)
	await _run_harness()
	_expect_5b(
		12,
		_system.state.using_air_control,
		"El salto desde rampa entra en Air."
	)
	_reset_case()
	_set_support(15, true, true)
	await _run_harness()
	_set_support(0, true, false)
	await _run_harness()
	_expect_5b(
		13,
		not _system.state.using_air_control,
		"Perder agua sobre rampa no activa Air."
	)
	await _run_air_case(
		Vector2.ZERO,
		Vector2.ZERO,
		air_angular_velocity
	)
	_expect_5b(
		14,
		_scalar_close(
			_system.state.air_accumulated_roll_degrees,
			rad_to_deg(0.75 * PHYSICS_DELTA)
		)
		and _scalar_close(
			_system.state.air_accumulated_pitch_degrees,
			rad_to_deg(-0.5 * PHYSICS_DELTA)
		),
		"El primer tick aÃ©reo inicializa y acumula una vez."
	)
	_set_support(
		15,
		false,
		true,
		JetSkiTypes.NavigationState.LANDING,
		0
	)
	await _run_harness()
	_expect_5b(
		15,
		not _system.state.using_air_control
		and _system.state.total_applied_torque_vector.is_finite()
		and is_zero_approx(_system.state.air_roll_rate)
		and is_zero_approx(_system.state.air_pitch_rate),
		"El primer tick de aterrizaje no aplica Air."
	)
	await _run_air_case(
		Vector2.ONE.normalized(),
		Vector2.ONE.normalized(),
		air_angular_velocity
	)
	_system.reset_runtime_state()
	_expect_5b(
		16,
		not _system.state.air_tracking_active
		and not _system.state.air_unlimited_rotation
		and is_zero_approx(
			_system.state.air_accumulated_roll_degrees
		)
		and is_zero_approx(
			_system.state.air_accumulated_pitch_degrees
		),
		"Reset durante Air limpia todo el runtime aÃ©reo."
	)

	await _run_air_case(
		Vector2.ZERO,
		Vector2.ZERO,
		air_angular_velocity
	)
	_expect_5b(
		17,
		_system.state.air_unlimited_rotation,
		"Unlimited rotation se activa en Air."
	)
	_expect_5b(
		18,
		_scalar_close(_system.state.air_roll_rate, 0.75),
		"Roll rate conserva eje y signo."
	)
	_expect_5b(
		19,
		_scalar_close(_system.state.air_pitch_rate, -0.5),
		"Pitch rate conserva eje y signo."
	)
	_expect_5b(
		20,
		_scalar_close(
			_system.state.air_accumulated_roll_degrees,
			rad_to_deg(0.75 * PHYSICS_DELTA)
		),
		"El acumulado de roll usa rate por delta."
	)
	_expect_5b(
		21,
		_scalar_close(
			_system.state.air_accumulated_pitch_degrees,
			rad_to_deg(-0.5 * PHYSICS_DELTA)
		),
		"El acumulado de pitch usa rate por delta."
	)
	var first_accumulated := _system.state.air_accumulated_roll_degrees
	await _run_harness(
		Transform3D.IDENTITY,
		Vector3.ZERO,
		air_angular_velocity
	)
	_expect_5b(
		22,
		_system.state.air_tracking_active
		and _scalar_close(
			_system.state.air_accumulated_roll_degrees,
			first_accumulated * 2.0
		),
		"Tracking se inicia una sola vez por fase aÃ©rea."
	)
	_set_support(15, false, true)
	await _run_harness()
	_expect_5b(
		23,
		not _system.state.air_tracking_active,
		"Tracking se limpia al recuperar soporte."
	)
	_expect_5b(
		24,
		is_zero_approx(_system.state.air_roll_rate)
		and is_zero_approx(_system.state.air_pitch_rate),
		"Los rates son cero durante supported."
	)
	_system.state.air_correction_roll_torque_current = 123.0
	_system.state.air_correction_pitch_torque_current = 456.0
	_system.begin_physics_tick()
	_expect_5b(
		25,
		is_zero_approx(
			_system.state.air_correction_roll_torque_current
		)
		and is_zero_approx(
			_system.state.air_correction_pitch_torque_current
		),
		"Un early return no deja torques de frame obsoletos."
	)

	await _run_air_case(Vector2.ZERO, Vector2.ONE)
	_expect_5b(
		26,
		is_zero_approx(
			_system.state.air_correction_roll_torque_current
		)
		and is_zero_approx(
			_system.state.air_correction_pitch_torque_current
		),
		"Raw input cero produce correcciÃ³n cero."
	)
	await _run_air_case(Vector2(0.5, 0.0), Vector2.ZERO)
	_expect_5b(
		27,
		_system.state.air_correction_roll_torque_current > 0.0
		and _scalar_close(
			_system.state.virtual_offset_local.x,
			_system.rider_lateral_shift_distance * 0.5
		),
		"Raw input lateral controla roll y offset."
	)
	await _run_air_case(Vector2(0.0, -0.5), Vector2.ZERO)
	_expect_5b(
		28,
		_system.state.air_correction_pitch_torque_current < 0.0
		and _scalar_close(
			_system.state.virtual_offset_local.z,
			-_system.rider_longitudinal_shift_distance * 0.5
		),
		"Raw input longitudinal controla pitch y offset."
	)
	var diagonal_input := Vector2.ONE.normalized()
	await _run_air_case(diagonal_input, Vector2.ZERO)
	_expect_5b(
		29,
		_scalar_close(diagonal_input.length(), 1.0)
		and _scalar_close(
			_system.state.virtual_offset_local.x,
			diagonal_input.x * _system.rider_lateral_shift_distance
		)
		and _scalar_close(
			_system.state.virtual_offset_local.z,
			diagonal_input.y
			* _system.rider_longitudinal_shift_distance
		),
		"El input diagonal normalizado se conserva."
	)
	await _run_air_case(Vector2.RIGHT, Vector2.RIGHT)
	_input_state.rider_shift_raw = Vector2.ZERO
	await _run_harness()
	_expect_5b(
		30,
		is_zero_approx(
			_system.state.air_correction_roll_torque_current
		),
		"Soltar raw input elimina correcciÃ³n en el mismo tick."
	)
	await _run_air_case(
		Vector2.LEFT,
		Vector2.RIGHT,
		Vector3.FORWARD * 0.5
	)
	_expect_5b(
		31,
		_scalar_close(
			_system.state.air_correction_roll_torque_current,
			-_system.air_correction_roll_torque
			* _system.air_counter_input_brake_multiplier
		),
		"El cambio de direcciÃ³n activa counter-input inmediatamente."
	)
	await _run_air_case(Vector2.ZERO, Vector2.ONE)
	_expect_5b(
		32,
		_system.state.virtual_offset_local.is_zero_approx()
		and _system.state.manual_applied_torque.is_zero_approx(),
		"El input suavizado no se utiliza en Air."
	)

	await _run_air_case(Vector2.RIGHT, Vector2.ZERO)
	_expect_5b(
		33,
		_system.state.air_correction_roll_torque_current > 0.0,
		"Roll positivo conserva signo."
	)
	await _run_air_case(Vector2.LEFT, Vector2.ZERO)
	_expect_5b(
		34,
		_system.state.air_correction_roll_torque_current < 0.0,
		"Roll negativo conserva signo."
	)
	await _run_air_case(Vector2.DOWN, Vector2.ZERO)
	_expect_5b(
		35,
		_system.state.air_correction_pitch_torque_current > 0.0,
		"Pitch positivo conserva signo."
	)
	await _run_air_case(Vector2.UP, Vector2.ZERO)
	_expect_5b(
		36,
		_system.state.air_correction_pitch_torque_current < 0.0,
		"Pitch negativo conserva signo."
	)
	await _run_air_case(
		Vector2.RIGHT,
		Vector2.ZERO,
		Vector3.FORWARD * -0.5
	)
	_expect_5b(
		37,
		_scalar_close(
			_system.state.air_correction_roll_torque_current,
			_system.air_correction_roll_torque
			* _system.air_counter_input_brake_multiplier
		),
		"La velocidad angular contraria usa frenado mÃ¡ximo."
	)
	await _run_air_case(
		Vector2.LEFT,
		Vector2.ZERO,
		Vector3.FORWARD * 0.5
	)
	_expect_5b(
		38,
		_scalar_close(
			_system.state.air_correction_roll_torque_current,
			-_system.air_correction_roll_torque
			* _system.air_counter_input_brake_multiplier
		),
		"Counter-input roll conserva multiplicador."
	)
	await _run_air_case(
		Vector2.UP,
		Vector2.ZERO,
		Vector3.RIGHT * 0.5
	)
	_expect_5b(
		39,
		_scalar_close(
			_system.state.air_correction_pitch_torque_current,
			-_system.air_correction_pitch_torque
			* _system.air_counter_input_brake_multiplier
		),
		"Counter-input pitch conserva multiplicador."
	)
	await _run_air_case(
		Vector2.RIGHT,
		Vector2.ZERO,
		Vector3.FORWARD * 0.9
	)
	_expect_5b(
		40,
		_scalar_close(
			_system.state.air_correction_roll_torque_current,
			_system.air_correction_roll_torque * 0.5
		),
		"Por debajo del target se aplica el dÃ©ficit proporcional."
	)
	await _run_air_case(
		Vector2.RIGHT,
		Vector2.ZERO,
		Vector3.FORWARD
		* _system.air_correction_target_roll_rate
	)
	_expect_5b(
		41,
		_scalar_close(
			_system.state.air_correction_roll_torque_current,
			0.0
		),
		"En el target la correcciÃ³n es cero."
	)
	await _run_air_case(
		Vector2.RIGHT,
		Vector2.ZERO,
		Vector3.FORWARD * 2.0
	)
	_expect_5b(
		42,
		is_zero_approx(
			_system.state.air_correction_roll_torque_current
		),
		"Por encima del target la correcciÃ³n es cero."
	)
	await _run_air_case(Vector2(0.5, 0.0), Vector2.ZERO)
	_expect_5b(
		43,
		_scalar_close(
			_system.state.air_correction_roll_torque_current,
			_system.air_correction_roll_torque * 0.5
		),
		"Input parcial escala el torque."
	)
	await _run_air_case(Vector2.RIGHT, Vector2.ZERO)
	_expect_5b(
		44,
		_scalar_close(
			_system.state.air_correction_roll_torque_current,
			_system.air_correction_roll_torque
		),
		"Input completo conserva el torque configurado."
	)
	_expect_5b(
		45,
		absf(_system.state.air_correction_roll_torque_current)
		<= _system.air_correction_roll_torque,
		"El torque de aceleraciÃ³n respeta su mÃ¡ximo."
	)
	_expect_5b(
		46,
		_system.state.manual_applied_torque.is_finite(),
		"El torque aÃ©reo es finito."
	)

	_expect_5b(
		47,
		is_zero_approx(
			_system._calculate_rider_air_overspeed_torque(
				_system.rider_air_max_roll_rate - 1.0,
				1.0,
				_system.rider_air_max_roll_rate
			)
		),
		"Roll bajo el mÃ¡ximo no activa overspeed."
	)
	var roll_overspeed := (
		_system.rider_air_max_roll_rate + 1.0
	)
	_expect_5b(
		48,
		_system._calculate_rider_air_overspeed_torque(
			roll_overspeed,
			1.0,
			_system.rider_air_max_roll_rate
		) < 0.0,
		"Roll sobre el mÃ¡ximo activa overspeed."
	)
	_expect_5b(
		49,
		is_zero_approx(
			_system._calculate_rider_air_overspeed_torque(
				_system.rider_air_max_pitch_rate - 1.0,
				1.0,
				_system.rider_air_max_pitch_rate
			)
		),
		"Pitch bajo el mÃ¡ximo no activa overspeed."
	)
	var pitch_overspeed := (
		_system.rider_air_max_pitch_rate + 1.0
	)
	_expect_5b(
		50,
		_system._calculate_rider_air_overspeed_torque(
			pitch_overspeed,
			1.0,
			_system.rider_air_max_pitch_rate
		) < 0.0,
		"Pitch sobre el mÃ¡ximo activa overspeed."
	)
	_expect_5b(
		51,
		is_zero_approx(
			_system._calculate_rider_air_overspeed_torque(
				roll_overspeed,
				0.0,
				_system.rider_air_max_roll_rate
			)
		),
		"Sin input no hay overspeed damping."
	)
	_expect_5b(
		52,
		is_zero_approx(
			_system._calculate_rider_air_overspeed_torque(
				roll_overspeed,
				-1.0,
				_system.rider_air_max_roll_rate
			)
		),
		"Signo contrario no activa overspeed damping."
	)
	_expect_5b(
		53,
		_scalar_close(
			_system._calculate_rider_air_overspeed_torque(
				roll_overspeed,
				1.0,
				_system.rider_air_max_roll_rate
			),
			-_system.rider_air_overspeed_damping
		),
		"Overspeed damping escala por el exceso."
	)
	var angular_velocity_before := _harness.angular_velocity
	_system._calculate_rider_air_overspeed_torque(
		roll_overspeed,
		1.0,
		_system.rider_air_max_roll_rate
	)
	_expect_5b(
		54,
		_vector_close(
			_harness.angular_velocity,
			angular_velocity_before
		),
		"Overspeed no modifica directamente angular_velocity."
	)

	await _run_air_case(Vector2.ZERO, Vector2.ZERO)
	_expect_5b(
		55,
		_system.state.total_applied_torque_vector.is_zero_approx(),
		"Torque externo cero conserva torque total cero."
	)
	var external_roll := Vector3.FORWARD * 100.0
	await _run_air_case(
		Vector2.ZERO,
		Vector2.ZERO,
		Vector3.ZERO,
		external_roll
	)
	_expect_5b(
		56,
		_vector_close(
			_system.state.total_applied_torque_vector,
			external_roll
		),
		"Trick Release externo de roll se conserva."
	)
	var external_pitch := Vector3.RIGHT * 200.0
	await _run_air_case(
		Vector2.ZERO,
		Vector2.ZERO,
		Vector3.ZERO,
		external_pitch
	)
	_expect_5b(
		57,
		_vector_close(
			_system.state.total_applied_torque_vector,
			external_pitch
		),
		"Trick Release externo de pitch se conserva."
	)
	var external_combined := external_roll + external_pitch
	await _run_air_case(
		Vector2.ZERO,
		Vector2.ZERO,
		Vector3.ZERO,
		external_combined
	)
	_expect_5b(
		58,
		_vector_close(
			_system.state.total_applied_torque_vector,
			external_combined
		),
		"Trick Release externo combinado se conserva."
	)
	_expect_5b(
		59,
		_vector_close(
			_system.state.manual_applied_torque,
			external_combined
		),
		"El torque externo se suma una sola vez."
	)
	_expect_5b(
		60,
		_scalar_close(_system.state.rider_shift_roll_torque, 100.0)
		and _scalar_close(
			_system.state.rider_shift_pitch_torque,
			200.0
		),
		"El torque externo conserva ejes y signos."
	)
	_expect_5b(
		61,
		not system_source.contains("TrickPreloadState")
		and not system_source.contains("_trick_release_active")
		and not system_source.contains("_trick_release_elapsed")
		and not system_source.contains("_trick_release_strength"),
		"Rider Dynamics no modifica TrickState."
	)
	_expect_5b(
		62,
		not system_source.contains("trick_release_elapsed")
		and not system_source.contains("trick_release_time_remaining"),
		"Rider Dynamics no avanza timers del truco."
	)
	_expect_5b(
		63,
		not system_source.contains("release_envelope")
		and not system_source.contains("trick_release_duration"),
		"Rider Dynamics no calcula el envelope del truco."
	)
	_system.rider_weight_shift_enabled = false
	await _run_air_case(
		Vector2.RIGHT,
		Vector2.RIGHT,
		Vector3.FORWARD * 0.5,
		external_combined
	)
	_expect_5b(
		64,
		_system.state.air_tracking_active
		and _scalar_close(_system.state.air_roll_rate, 0.5)
		and _system.state.manual_applied_torque.is_zero_approx()
		and is_zero_approx(
			_system.state.rider_shift_air_authority_active
		)
		and controller_source.find(
			"var external_trick_release_torque"
		) > controller_source.find(
			"prepare_air_metrics("
		),
		"Weight Shift deshabilitado conserva el retorno legacy."
	)
	_system.rider_weight_shift_enabled = true

	var main_vehicle := _main_instance.get_node_or_null(
		"Gameplay/JetSki"
	)
	_expect_5b(
		65,
		main_vehicle != null
		and main_vehicle.get_node_or_null("RiderMountedLean") != null,
		"RiderMountedLeanController carga."
	)
	_expect_5b(
		66,
		_rider_instance.find_child(
			"RiderImpactPose",
			true,
			false
		) != null,
		"RiderImpactResponseController carga."
	)
	_expect_5b(
		67,
		main_vehicle != null
		and main_vehicle.get_node_or_null("ArcadeHandling") != null,
		"ArcadeHandling carga."
	)
	_expect_5b(
		68,
		_main_instance.get_node_or_null(
			"CameraSystem/ChaseCamera"
		) != null,
		"La cÃ¡mara carga."
	)
	_expect_5b(
		69,
		_rider_instance.find_child("RiderRig", true, false) != null,
		"El rider visual carga."
	)
	_expect_5b(
		70,
		_rider_instance.find_child("LeftArmIK", true, false) != null
		and _rider_instance.find_child(
			"RightArmIK",
			true,
			false
		) != null,
		"El IK carga."
	)
	_expect_5b(
		71,
		load(
			"res://tools/godot/validate_jet_ski_input_system.gd"
		) != null,
		"Input continÃºa disponible."
	)
	_expect_5b(
		72,
		load(
			"res://tools/godot/"
			+ "validate_jet_ski_water_physics_system.gd"
		) != null,
		"Water Physics continÃºa disponible."
	)
	_expect_5b(
		73,
		load(
			"res://tools/godot/"
			+ "validate_jet_ski_navigation_system.gd"
		) != null,
		"Navigation continÃºa disponible."
	)
	_expect_5b(
		74,
		load(
			"res://tools/godot/validate_jet_ski_drive_system.gd"
		) != null,
		"Drive continÃºa disponible."
	)
	_expect_5b(
		75,
		load(
			"res://tools/godot/validate_vehicle_water_audio.gd"
		) != null,
		"VehicleWaterAudio continÃºa disponible."
	)
	await _run_air_case(
		Vector2.RIGHT,
		Vector2.RIGHT,
		air_angular_velocity
	)
	var reset_identity := _system.state
	_system.reset_runtime_state()
	_expect_5b(
		76,
		_system.state == reset_identity
		and _frame_metrics_are_zero(_system.state)
		and not _system.state.air_tracking_active
		and is_zero_approx(
			_system.state.air_accumulated_roll_degrees
		),
		"Reset conserva identidad y limpia Air."
	)
	var scene_identity := _vehicle.rider_dynamics_system.state
	var scene_velocity := _vehicle.linear_velocity
	_vehicle.apply_world_rebase(Vector3(7.0, 0.0, -11.0))
	_expect_5b(
		77,
		_vehicle.rider_dynamics_system.state == scene_identity
		and _vector_close(_vehicle.linear_velocity, scene_velocity),
		"Rebase conserva el state aÃ©reo y la velocidad."
	)
	_expect_5b(
		78,
		_vehicle.get_script() != null
		and _system.get_script() != null
		and _system.state != null,
		"No existen errores de parser."
	)
	_expect_5b(
		79,
		controller_source.contains("var using_air: bool")
		and system_source.contains(
			"var state: JetSkiRiderDynamicsState"
		),
		"No existen errores de inferencia."
	)
	var all_sources := controller_source + system_source + state_source
	_expect_5b(
		80,
		not all_sources.contains("@warning_ignore")
		and not all_sources.contains(
			"SHADOWED_VARIABLE_BASE_CLASS"
		),
		"No existen warnings GDScript silenciados o reales."
	)
	var git_output: Array = []
	var git_exit := OS.execute(
		"git",
		PackedStringArray(["diff", "--check"]),
		git_output,
		true
	)
	_expect_5b(
		81,
		git_exit == 0,
		"git diff --check queda limpio."
	)
	var scene_system := _vehicle.rider_dynamics_system
	var air_configuration_matches := (
		_scalar_close(
			scene_system.rider_air_max_roll_rate,
			_vehicle.rider_air_max_roll_rate
		)
		and _scalar_close(
			scene_system.rider_air_max_pitch_rate,
			_vehicle.rider_air_max_pitch_rate
		)
		and _scalar_close(
			scene_system.rider_air_overspeed_damping,
			_vehicle.rider_air_overspeed_damping
		)
		and _scalar_close(
			scene_system.air_correction_target_roll_rate,
			_vehicle.air_correction_target_roll_rate
		)
		and _scalar_close(
			scene_system.air_correction_target_pitch_rate,
			_vehicle.air_correction_target_pitch_rate
		)
		and _scalar_close(
			scene_system.air_correction_roll_torque,
			_vehicle.air_correction_roll_torque
		)
		and _scalar_close(
			scene_system.air_correction_pitch_torque,
			_vehicle.air_correction_pitch_torque
		)
		and _scalar_close(
			scene_system.air_counter_input_brake_multiplier,
			_vehicle.air_counter_input_brake_multiplier
		)
	)
	_expect_5b(
		82,
		air_configuration_matches
		and controller_source.count(
			"_configure_rider_dynamics_system()"
		) == 2,
		"La configuraciÃ³n Air se copia una sola vez."
	)


func _validate_compatibility() -> void:
	var scene_state := _vehicle.rider_dynamics_system.state
	scene_state.turn_lean_target_roll = 0.1
	scene_state.turn_lean_current_roll = 0.2
	scene_state.turn_lean_roll_error = -0.1
	scene_state.turn_lean_speed_factor = 0.7
	scene_state.turn_lean_contact_factor = 0.8
	scene_state.rider_shift_current_pitch = 0.3
	scene_state.rider_shift_roll_torque = 10.0
	scene_state.rider_shift_pitch_torque = 20.0
	scene_state.virtual_offset_local = Vector3.ONE
	scene_state.using_air_control = true
	_expect_numbered(
		73,
		_scalar_close(
			_vehicle.turn_lean_target_roll_degrees,
			rad_to_deg(0.1)
		)
		and _scalar_close(
			_vehicle.turn_lean_current_roll_degrees,
			rad_to_deg(0.2)
		)
		and _scalar_close(
			_vehicle.turn_lean_error_degrees,
			rad_to_deg(-0.1)
		)
		and _scalar_close(_vehicle.turn_lean_speed_factor, 0.7)
		and _scalar_close(_vehicle.turn_lean_contact_factor, 0.8)
		and _scalar_close(
			_vehicle.rider_shift_current_pitch_degrees,
			rad_to_deg(0.3)
		)
		and _scalar_close(_vehicle.rider_shift_roll_torque, 10.0)
		and _scalar_close(_vehicle.rider_shift_pitch_torque, 20.0)
		and _vehicle.rider_virtual_offset_local == Vector3.ONE
		and _vehicle.rider_using_air_control,
		"Todos los proxies coinciden con RiderDynamicsState."
	)
	var main_vehicle := _main_instance.get_node_or_null(
		"Gameplay/JetSki"
	)
	_expect_numbered(
		74,
		main_vehicle != null
		and main_vehicle.get_node_or_null("RiderMountedLean") != null,
		"RiderMountedLeanController carga."
	)
	_expect_numbered(
		75,
		_rider_instance.find_child(
			"RiderImpactPose",
			true,
			false
		) != null,
		"RiderImpactResponseController carga."
	)
	_expect_numbered(
		76,
		main_vehicle != null
		and main_vehicle.get_node_or_null("ArcadeHandling") != null,
		"ArcadeHandling carga."
	)
	_expect_numbered(
		77,
		_main_instance.get_node_or_null(
			"CameraSystem/ChaseCamera"
		) != null,
		"La cámara carga."
	)
	_expect_numbered(
		78,
		_rider_instance.find_child(
			"RiderRig",
			true,
			false
		) != null,
		"El rider visual carga."
	)
	_expect_numbered(
		79,
		_rider_instance.find_child(
			"LeftArmIK",
			true,
			false
		) != null
		and _rider_instance.find_child(
			"RightArmIK",
			true,
			false
		) != null,
		"El IK carga."
	)
	_expect_numbered(
		80,
		_main_instance.get_node_or_null("Debug") != null,
		"Debug carga."
	)
	_expect_numbered(
		81,
		load(
			"res://tools/godot/validate_jet_ski_input_system.gd"
		) != null,
		"El validador InputSystem continúa disponible."
	)
	_expect_numbered(
		82,
		load(
			"res://tools/godot/"
			+ "validate_jet_ski_water_physics_system.gd"
		) != null,
		"El validador WaterPhysicsSystem continúa disponible."
	)
	_expect_numbered(
		83,
		load(
			"res://tools/godot/"
			+ "validate_jet_ski_navigation_system.gd"
		) != null,
		"El validador NavigationSystem continúa disponible."
	)
	_expect_numbered(
		84,
		load(
			"res://tools/godot/validate_jet_ski_drive_system.gd"
		) != null,
		"El validador DriveSystem continúa disponible."
	)
	_expect_numbered(
		85,
		load(
			"res://tools/godot/validate_vehicle_water_audio.gd"
		) != null,
		"El validador VehicleWaterAudio continúa disponible."
	)
	var persistent_state := scene_state
	_vehicle.reset_vehicle(&"rider_dynamics_validation")
	_expect_numbered(
		86,
		_vehicle.rider_dynamics_system.state == persistent_state
		and _frame_metrics_are_zero(persistent_state)
		and persistent_state.smoothed_support_normal == Vector3.UP,
		"Reset funciona y conserva identidad."
	)
	var preserved_velocity := _vehicle.linear_velocity
	var preserved_state := _vehicle.rider_dynamics_system.state
	_vehicle.apply_world_rebase(Vector3(20.0, 0.0, -13.0))
	_expect_numbered(
		87,
		_vehicle.rider_dynamics_system.state == preserved_state
		and _vector_close(
			_vehicle.linear_velocity,
			preserved_velocity
		),
		"Rebase conserva estado relativo y velocidad."
	)
	_expect_numbered(
		88,
		_vehicle.get_script() != null
		and _system.get_script() != null
		and _system.state != null,
		"No existen errores de parser."
	)
	var sources := (
		FileAccess.get_file_as_string(CONTROLLER_SOURCE)
		+ FileAccess.get_file_as_string(SYSTEM_SOURCE)
		+ FileAccess.get_file_as_string(STATE_SOURCE)
	)
	_expect_numbered(
		89,
		not sources.contains("@warning_ignore")
		and not sources.contains(
			"SHADOWED_VARIABLE_BASE_CLASS"
		),
		"No existen warnings GDScript silenciados o reales."
	)
	var git_output: Array = []
	var git_exit := OS.execute(
		"git",
		PackedStringArray(["diff", "--check"]),
		git_output,
		true
	)
	_expect_numbered(
		90,
		git_exit == 0,
		"git diff --check queda limpio."
	)


func _report_legacy_equivalence() -> void:
	var scenarios: Array[String] = [
		"idle plano",
		"steering izquierda",
		"steering derecha",
		"velocidad baja",
		"velocidad alta",
		"marcha atrás",
		"contacto parcial",
		"contacto completo",
		"rampa sólida sin agua",
		"aterrizaje reciente",
		"shift lateral izquierda",
		"shift lateral derecha",
		"shift atrás con throttle",
		"shift delante con velocidad",
		"roll soft limit",
		"nose-up soft limit",
		"nose-down soft limit",
		"submarine upright factor",
		"submarine damping blend",
		"external submarine pitch torque",
	]
	for scenario: String in scenarios:
		if _comparison_failed:
			_fail("Legacy/delegado: %s difiere." % scenario)
		else:
			print("PASS: Legacy/delegado: %s coincide." % scenario)


func _report_air_legacy_equivalence() -> void:
	var scenarios: Array[Dictionary] = [
		{
			"name": "entrada en Air sin input",
			"input": Vector2.ZERO,
			"roll_rate": 0.0,
			"pitch_rate": 0.0,
			"external": Vector3.ZERO,
			"enabled": true,
		},
		{
			"name": "entrada en Air con roll",
			"input": Vector2.RIGHT,
			"roll_rate": 0.0,
			"pitch_rate": 0.0,
			"external": Vector3.ZERO,
			"enabled": true,
		},
		{
			"name": "entrada en Air con pitch",
			"input": Vector2.DOWN,
			"roll_rate": 0.0,
			"pitch_rate": 0.0,
			"external": Vector3.ZERO,
			"enabled": true,
		},
		{
			"name": "entrada diagonal",
			"input": Vector2.ONE.normalized(),
			"roll_rate": 0.0,
			"pitch_rate": 0.0,
			"external": Vector3.ZERO,
			"enabled": true,
		},
		{
			"name": "rotaciÃ³n en misma direcciÃ³n",
			"input": Vector2.RIGHT,
			"roll_rate": 0.8,
			"pitch_rate": 0.0,
			"external": Vector3.ZERO,
			"enabled": true,
		},
		{
			"name": "rotaciÃ³n en direcciÃ³n contraria",
			"input": Vector2.RIGHT,
			"roll_rate": -0.8,
			"pitch_rate": 0.0,
			"external": Vector3.ZERO,
			"enabled": true,
		},
		{
			"name": "velocidad inferior al target",
			"input": Vector2.RIGHT,
			"roll_rate": 0.9,
			"pitch_rate": 0.0,
			"external": Vector3.ZERO,
			"enabled": true,
		},
		{
			"name": "velocidad igual al target",
			"input": Vector2.RIGHT,
			"roll_rate": 1.8,
			"pitch_rate": 0.0,
			"external": Vector3.ZERO,
			"enabled": true,
		},
		{
			"name": "velocidad superior al target",
			"input": Vector2.RIGHT,
			"roll_rate": 2.0,
			"pitch_rate": 0.0,
			"external": Vector3.ZERO,
			"enabled": true,
		},
		{
			"name": "overspeed roll",
			"input": Vector2.RIGHT,
			"roll_rate": 13.0,
			"pitch_rate": 0.0,
			"external": Vector3.ZERO,
			"enabled": true,
		},
		{
			"name": "overspeed pitch",
			"input": Vector2.DOWN,
			"roll_rate": 0.0,
			"pitch_rate": 11.0,
			"external": Vector3.ZERO,
			"enabled": true,
		},
		{
			"name": "release de input",
			"input": Vector2.ZERO,
			"roll_rate": 0.7,
			"pitch_rate": -0.4,
			"external": Vector3.ZERO,
			"enabled": true,
		},
		{
			"name": "cambio de direcciÃ³n",
			"input": Vector2.LEFT,
			"roll_rate": 0.7,
			"pitch_rate": 0.0,
			"external": Vector3.ZERO,
			"enabled": true,
		},
		{
			"name": "trick torque roll",
			"input": Vector2.ZERO,
			"roll_rate": 0.0,
			"pitch_rate": 0.0,
			"external": Vector3.FORWARD * 140.0,
			"enabled": true,
		},
		{
			"name": "trick torque pitch",
			"input": Vector2.ZERO,
			"roll_rate": 0.0,
			"pitch_rate": 0.0,
			"external": Vector3.RIGHT * 180.0,
			"enabled": true,
		},
		{
			"name": "trick torque combinado",
			"input": Vector2.ZERO,
			"roll_rate": 0.0,
			"pitch_rate": 0.0,
			"external": (
				Vector3.FORWARD * 140.0
				+ Vector3.RIGHT * 180.0
			),
			"enabled": true,
		},
		{
			"name": "rider shift deshabilitado",
			"input": Vector2.RIGHT,
			"roll_rate": 0.6,
			"pitch_rate": 0.0,
			"external": Vector3.FORWARD * 140.0,
			"enabled": false,
		},
	]
	for scenario: Dictionary in scenarios:
		var matches: bool = await _compare_air_case(
			scenario.input,
			scenario.roll_rate,
			scenario.pitch_rate,
			scenario.external,
			scenario.enabled
		)
		_report_air_comparison(scenario.name, matches)

	_system.rider_weight_shift_enabled = true
	await _run_air_case(
		Vector2.RIGHT,
		Vector2.RIGHT,
		Vector3.FORWARD * 0.6
	)
	var accumulated_before_landing := (
		_system.state.air_accumulated_roll_degrees
	)
	_set_support(
		15,
		false,
		true,
		JetSkiTypes.NavigationState.LANDING,
		0
	)
	await _run_harness()
	var landing_matches := (
		not _system.state.using_air_control
		and not _system.state.air_tracking_active
		and is_zero_approx(_system.state.air_roll_rate)
		and is_zero_approx(_system.state.air_pitch_rate)
		and _scalar_close(
			_system.state.air_accumulated_roll_degrees,
			accumulated_before_landing
		)
	)
	_report_air_comparison("aterrizaje", landing_matches)

	_set_support(
		0,
		false,
		false,
		JetSkiTypes.NavigationState.AIRBORNE,
		15
	)
	await _run_harness(
		Transform3D.IDENTITY,
		Vector3.ZERO,
		Vector3.FORWARD * 0.6
	)
	var second_jump_matches := (
		_system.state.using_air_control
		and _system.state.air_tracking_active
		and _scalar_close(
			_system.state.air_accumulated_roll_degrees,
			rad_to_deg(0.6 * PHYSICS_DELTA)
		)
	)
	_report_air_comparison(
		"nuevo salto despuÃ©s de aterrizar",
		second_jump_matches
	)

	_system.reset_runtime_state()
	var reset_matches := (
		not _system.state.using_air_control
		and not _system.state.air_tracking_active
		and not _system.state.air_unlimited_rotation
		and is_zero_approx(
			_system.state.air_accumulated_roll_degrees
		)
		and is_zero_approx(
			_system.state.air_accumulated_pitch_degrees
		)
	)
	_report_air_comparison("reset durante Air", reset_matches)


func _compare_air_case(
	raw_input: Vector2,
	roll_rate: float,
	pitch_rate: float,
	external_torque: Vector3,
	enabled: bool
) -> bool:
	_system.rider_weight_shift_enabled = enabled
	var angular_velocity := (
		Vector3.FORWARD * roll_rate
		+ Vector3.RIGHT * pitch_rate
	)
	await _run_air_case(
		raw_input,
		raw_input,
		angular_velocity,
		external_torque
	)
	var expected_roll_correction := 0.0
	var expected_pitch_correction := 0.0
	var expected_torque := Vector3.ZERO
	var expected_offset := Vector3.ZERO
	var expected_world_offset := Vector3.ZERO
	if enabled:
		expected_roll_correction = (
			_legacy_air_rate_correction_torque(
				roll_rate,
				raw_input.x,
				_system.air_correction_target_roll_rate,
				_system.air_correction_roll_torque
			)
		)
		expected_pitch_correction = (
			_legacy_air_rate_correction_torque(
				pitch_rate,
				raw_input.y,
				_system.air_correction_target_pitch_rate,
				_system.air_correction_pitch_torque
			)
		)
		expected_torque = (
			external_torque
			+ Vector3.FORWARD * expected_roll_correction
			+ Vector3.RIGHT * expected_pitch_correction
			+ Vector3.FORWARD
			* _legacy_air_overspeed_torque(
				roll_rate,
				raw_input.x,
				_system.rider_air_max_roll_rate
			)
			+ Vector3.RIGHT
			* _legacy_air_overspeed_torque(
				pitch_rate,
				raw_input.y,
				_system.rider_air_max_pitch_rate
			)
		)
		expected_offset = Vector3(
			raw_input.x * _system.rider_lateral_shift_distance,
			0.0,
			raw_input.y
			* _system.rider_longitudinal_shift_distance
		)
		expected_world_offset = (
			_system.get_prepared_body_right()
			* expected_offset.x
			- _system.get_prepared_body_forward()
			* expected_offset.z
		)
	var rider_state: JetSkiRiderDynamicsState = _system.state
	var matches := (
		rider_state.using_air_control
		and rider_state.turn_lean_airborne_disabled
		and rider_state.rider_shift_airborne
		and rider_state.air_unlimited_rotation
		and rider_state.air_tracking_active
		and _scalar_close(rider_state.air_roll_rate, roll_rate)
		and _scalar_close(rider_state.air_pitch_rate, pitch_rate)
		and _scalar_close(
			rider_state.air_accumulated_roll_degrees,
			rad_to_deg(roll_rate * PHYSICS_DELTA)
		)
		and _scalar_close(
			rider_state.air_accumulated_pitch_degrees,
			rad_to_deg(pitch_rate * PHYSICS_DELTA)
		)
		and _scalar_close(
			rider_state.air_correction_roll_torque_current,
			expected_roll_correction
		)
		and _scalar_close(
			rider_state.air_correction_pitch_torque_current,
			expected_pitch_correction
		)
		and _vector_close(
			rider_state.virtual_offset_local,
			expected_offset
		)
		and _vector_close(
			rider_state.virtual_offset_world,
			expected_world_offset
		)
		and _vector_close(
			rider_state.manual_applied_torque,
			expected_torque
		)
		and _vector_close(
			rider_state.total_applied_torque_vector,
			expected_torque
		)
		and _scalar_close(
			rider_state.rider_shift_roll_torque,
			expected_torque.dot(Vector3.FORWARD)
		)
		and _scalar_close(
			rider_state.rider_shift_pitch_torque,
			expected_torque.dot(Vector3.RIGHT)
		)
		and _scalar_close(
			rider_state.rider_shift_air_authority_active,
			1.0 if enabled else 0.0
		)
	)
	if not matches:
		var diagnostic := (
			(
				"AIR_COMPARISON_DIAGNOSTIC actual_rates=%s/%s "
				+ "expected_rates=%s/%s actual_correction=%s/%s "
				+ "expected_correction=%s/%s actual_offset=%s "
				+ "expected_offset=%s actual_torque=%s "
				+ "expected_torque=%s accumulated=%s/%s "
				+ "expected_accumulated=%s/%s axis_torque=%s/%s "
				+ "expected_axis_torque=%s/%s authority=%s"
			)
			% [
				rider_state.air_roll_rate,
				rider_state.air_pitch_rate,
				roll_rate,
				pitch_rate,
				rider_state.air_correction_roll_torque_current,
				rider_state.air_correction_pitch_torque_current,
				expected_roll_correction,
				expected_pitch_correction,
				rider_state.virtual_offset_local,
				expected_offset,
				rider_state.manual_applied_torque,
				expected_torque,
				rider_state.air_accumulated_roll_degrees,
				rider_state.air_accumulated_pitch_degrees,
				rad_to_deg(roll_rate * PHYSICS_DELTA),
				rad_to_deg(pitch_rate * PHYSICS_DELTA),
				rider_state.rider_shift_roll_torque,
				rider_state.rider_shift_pitch_torque,
				expected_torque.dot(Vector3.FORWARD),
				expected_torque.dot(Vector3.RIGHT),
				rider_state.rider_shift_air_authority_active,
			]
		)
		print(diagnostic)
	return matches


func _legacy_air_rate_correction_torque(
	axis_rate: float,
	axis_input: float,
	target_rate: float,
	maximum_torque: float
) -> float:
	var input_magnitude := absf(axis_input)
	if input_magnitude <= 0.0001:
		return 0.0
	var input_direction := signf(axis_input)
	if axis_rate * input_direction < 0.0:
		return (
			input_direction
			* maximum_torque
			* input_magnitude
			* _system.air_counter_input_brake_multiplier
		)
	var desired_rate_magnitude := input_magnitude * target_rate
	if absf(axis_rate) >= desired_rate_magnitude:
		return 0.0
	var rate_deficit_factor := clampf(
		(desired_rate_magnitude - absf(axis_rate))
		/ maxf(desired_rate_magnitude, 0.0001),
		0.0,
		1.0
	)
	return (
		input_direction
		* maximum_torque
		* input_magnitude
		* rate_deficit_factor
	)


func _legacy_air_overspeed_torque(
	axis_rate: float,
	axis_input: float,
	maximum_rate: float
) -> float:
	if (
		absf(axis_input) <= 0.0001
		or signf(axis_rate) != signf(axis_input)
		or absf(axis_rate) <= maximum_rate
	):
		return 0.0
	return (
		-signf(axis_rate)
		* (absf(axis_rate) - maximum_rate)
		* _system.rider_air_overspeed_damping
	)


func _report_air_comparison(
	scenario: String,
	matches: bool
) -> void:
	if matches:
		print(
			"PASS: Legacy/delegado Air: %s coincide."
			% scenario
		)
		return
	_fail("Legacy/delegado Air: %s difiere." % scenario)


func _reset_case(reset_system: bool = true) -> void:
	if reset_system:
		_system.reset_runtime_state()
	_input_state.reset()
	_water_state.reset()
	_navigation_state.reset_runtime_state()
	_drive_state.clear_frame_metrics()
	_seed_water_points(0.4, Vector3.UP)
	_set_support(15, false, true)
	_water_state.average_depth = 0.4
	_water_state.water_relative_forward_speed = 20.0
	_drive_state.propulsion_contact_factor = 1.0
	_harness.submarine_dive_active = false
	_harness.submarine_upright_factor = 1.0
	_harness.submarine_control_blend = 0.0
	_harness.external_submarine_pitch_torque = Vector3.ZERO
	_harness.external_trick_release_torque = Vector3.ZERO


func _run_air_case(
	raw_input: Vector2,
	smoothed_input: Vector2,
	angular_velocity: Vector3 = Vector3.ZERO,
	external_trick_release_torque: Vector3 = Vector3.ZERO,
	transform: Transform3D = Transform3D.IDENTITY
) -> void:
	_reset_case()
	_set_support(
		0,
		false,
		false,
		JetSkiTypes.NavigationState.AIRBORNE,
		0
	)
	_input_state.rider_shift_raw = raw_input
	_input_state.rider_shift_smoothed = smoothed_input
	_harness.external_trick_release_torque = (
		external_trick_release_torque
	)
	await _run_harness(
		transform,
		Vector3.ZERO,
		angular_velocity
	)


func _set_support(
	mask: int,
	solid_support: bool,
	water_support: bool,
	mode: JetSkiTypes.NavigationState = (
		JetSkiTypes.NavigationState.PARTIALLY_SUBMERGED
	),
	previous_mask: int = -1
) -> void:
	_navigation_state.current_contact_mask = mask
	_navigation_state.previous_contact_mask = (
		mask if previous_mask < 0 else previous_mask
	)
	_navigation_state.has_water_support = water_support
	_navigation_state.has_solid_support = solid_support
	_navigation_state.has_any_support = (
		water_support or solid_support
	)
	_navigation_state.navigation_state = mode


func _set_motion_inputs(
	forward_speed: float,
	throttle: float,
	brake: float,
	steering: float,
	rider_shift: Vector2
) -> void:
	_water_state.water_relative_forward_speed = forward_speed
	_input_state.throttle = throttle
	_input_state.brake = brake
	_input_state.steering = steering
	_input_state.rider_shift_raw = rider_shift
	_input_state.rider_shift_smoothed = rider_shift


func _seed_water_points(
	depth: float,
	normal: Vector3,
	valid: bool = true
) -> void:
	var sample_valid := _water_system.point_sample_valid
	var depths := _water_system.point_depths
	var normal_forces := _water_system.point_normal_forces
	var normals := _water_system.point_water_normals
	for index in 4:
		sample_valid[index] = valid
		depths[index] = depth
		normal_forces[index] = 100.0
		normals[index] = normal


func _run_harness(
	transform: Transform3D = Transform3D.IDENTITY,
	linear_velocity: Vector3 = Vector3.ZERO,
	angular_velocity: Vector3 = Vector3.ZERO
) -> void:
	_harness.global_transform = transform
	_harness.linear_velocity = linear_velocity
	_harness.angular_velocity = angular_velocity
	_harness.sleeping = false
	await physics_frame


func _frame_metrics_are_zero(
	rider_state: JetSkiRiderDynamicsState
) -> bool:
	return (
		not rider_state.using_air_control
		and not rider_state.turn_lean_airborne_disabled
		and not rider_state.rider_shift_airborne
		and not rider_state.air_unlimited_rotation
		and is_zero_approx(rider_state.air_roll_rate)
		and is_zero_approx(rider_state.air_pitch_rate)
		and is_zero_approx(
			rider_state.air_correction_roll_torque_current
		)
		and is_zero_approx(
			rider_state.air_correction_pitch_torque_current
		)
		and is_zero_approx(rider_state.turn_lean_target_roll)
		and is_zero_approx(rider_state.turn_lean_current_roll)
		and is_zero_approx(rider_state.turn_lean_roll_error)
		and is_zero_approx(rider_state.turn_lean_requested_torque)
		and rider_state.turn_lean_applied_torque_vector.is_zero_approx()
		and is_zero_approx(rider_state.rider_shift_roll_torque)
		and is_zero_approx(rider_state.rider_shift_pitch_torque)
		and rider_state.manual_applied_torque.is_zero_approx()
		and rider_state.total_applied_torque_vector.is_zero_approx()
	)


func _scalar_close(actual: float, expected: float) -> bool:
	var tolerance := maxf(
		SCALAR_EPSILON,
		maxf(absf(actual), absf(expected)) * RELATIVE_EPSILON
	)
	return absf(actual - expected) <= tolerance


func _vector_close(actual: Vector3, expected: Vector3) -> bool:
	var tolerance := maxf(
		VECTOR_EPSILON,
		maxf(actual.length(), expected.length())
		* RELATIVE_EPSILON
	)
	return actual.distance_to(expected) <= tolerance


func _expect_numbered(
	number: int,
	condition: bool,
	message: String
) -> void:
	if condition:
		print("PASS: %d. %s" % [number, message])
		return
	if number >= 17 and number <= 72:
		_comparison_failed = true
	_fail("%d. %s" % [number, message])


func _expect_5b(
	number: int,
	condition: bool,
	message: String
) -> void:
	if condition:
		print("PASS: 5B.%d. %s" % [number, message])
		return
	_fail("5B.%d. %s" % [number, message])


func _fail(message: String) -> void:
	_failed = true
	push_error("FAIL: %s" % message)


func _stop_audio_recursive(node: Node) -> void:
	if (
		node is AudioStreamPlayer
		or node is AudioStreamPlayer2D
		or node is AudioStreamPlayer3D
	):
		node.stop()
		node.stream = null
	for child: Node in node.get_children():
		_stop_audio_recursive(child)


func _cleanup() -> void:
	if is_instance_valid(_main_instance):
		_stop_audio_recursive(_main_instance)
		_main_instance.free()
	if is_instance_valid(_rider_instance):
		_stop_audio_recursive(_rider_instance)
		_rider_instance.free()
	if is_instance_valid(_fixture):
		_stop_audio_recursive(_fixture)
		_fixture.free()
	_vehicle = null
	_system = null
	_harness = null
	_water_system = null
	_main_instance = null
	_rider_instance = null
	_fixture = null
	await physics_frame
	await process_frame
	await process_frame


func _finish() -> void:
	print(
		"RIDER_DYNAMICS_SYSTEM_VALIDATION=%s"
		% ("FAIL" if _failed else "PASS")
	)
	quit(1 if _failed else 0)
