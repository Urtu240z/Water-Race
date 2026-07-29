extends SceneTree

class ControlledOcean:
	extends Ocean3D

	var test_height: float = 0.0
	var test_normal: Vector3 = Vector3.UP
	var test_velocity: Vector3 = Vector3.ZERO

	func sample_height(_world_position: Vector3) -> float:
		return test_height

	func sample_normal(_world_position: Vector3) -> Vector3:
		return test_normal

	func sample_water_velocity(_world_position: Vector3) -> Vector3:
		return test_velocity


class DriveHarness:
	extends RigidBody3D

	var drive_system: JetSkiDriveSystem
	var ocean: Ocean3D
	var input_state: JetSkiInputState = JetSkiInputState.new()
	var submarine_propulsion_factor: float = 1.0

	func _integrate_forces(body_state: PhysicsDirectBodyState3D) -> void:
		drive_system.begin_physics_tick()
		drive_system.step(
			body_state,
			ocean,
			input_state,
			submarine_propulsion_factor
		)


const JET_SKI_SCENE := "res://scenes/vehicle/jet_ski.tscn"
const MAIN_SCENE := (
	"res://scenes/levels/island_test/island_test_BLENDER.tscn"
)
const CONTROLLER_SOURCE := (
	"res://scripts/vehicle/jet_ski_controller.gd"
)
const DRIVE_SOURCE := (
	"res://scripts/vehicle/systems/jet_ski_drive_system.gd"
)
const RIDER_DYNAMICS_SOURCE := (
	"res://scripts/vehicle/systems/jet_ski_rider_dynamics_system.gd"
)
const SCALAR_EPSILON: float = 0.0001
const SCALAR_RELATIVE_EPSILON: float = 0.000001
const VECTOR_EPSILON: float = 0.0005
const LOCAL_PROPULSION_POINT := Vector3(0.0, -0.18, 1.25)

var _failed: bool = false
var _fixture: Node3D
var _vehicle_ocean: ControlledOcean
var _vehicle: JetSkiController
var _harness_ocean: ControlledOcean
var _harness: DriveHarness
var _drive: JetSkiDriveSystem
var _marker: Marker3D
var _main_instance: Node


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var jet_ski_packed := load(JET_SKI_SCENE) as PackedScene
	var main_packed := load(MAIN_SCENE) as PackedScene
	_expect_numbered(1, jet_ski_packed != null, "jet_ski.tscn carga.")
	_expect_numbered(2, main_packed != null, "La escena principal carga.")
	if jet_ski_packed == null or main_packed == null:
		_finish()
		return
	await _build_fixture(jet_ski_packed, main_packed)
	if _vehicle == null or _drive == null:
		_finish()
		return
	_validate_structure_and_configuration()
	await _validate_state_and_sampling()
	await _validate_contact_and_forward()
	await _validate_reverse_and_steering()
	await _validate_coasting_and_submarine()
	await _validate_legacy_equivalence()
	await _validate_compatibility()
	jet_ski_packed = null
	main_packed = null
	await _cleanup_fixture()
	_finish()


func _build_fixture(
	jet_ski_packed: PackedScene,
	main_packed: PackedScene
) -> void:
	_fixture = Node3D.new()
	_fixture.name = "DriveValidationFixture"

	_vehicle_ocean = ControlledOcean.new()
	_vehicle_ocean.name = "VehicleOcean"
	_vehicle_ocean.process_mode = Node.PROCESS_MODE_DISABLED
	_fixture.add_child(_vehicle_ocean)

	_vehicle = jet_ski_packed.instantiate() as JetSkiController
	if _vehicle == null:
		_fail("jet_ski.tscn no instancia JetSkiController.")
		return
	_vehicle.name = "JetSki"
	_vehicle.ocean_path = NodePath("../VehicleOcean")
	_vehicle.gravity_scale = 0.0
	_vehicle.collision_layer = 0
	_vehicle.collision_mask = 0
	_fixture.add_child(_vehicle)

	_harness_ocean = ControlledOcean.new()
	_harness_ocean.name = "HarnessOcean"
	_harness_ocean.process_mode = Node.PROCESS_MODE_DISABLED
	_fixture.add_child(_harness_ocean)

	_harness = DriveHarness.new()
	_harness.name = "DriveHarness"
	_harness.gravity_scale = 0.0
	_harness.custom_integrator = true
	_harness.can_sleep = false
	_harness.collision_layer = 0
	_harness.collision_mask = 0
	_drive = JetSkiDriveSystem.new()
	_drive.name = "DriveSystem"
	_marker = Marker3D.new()
	_marker.name = "PropulsionPoint"
	_marker.position = LOCAL_PROPULSION_POINT
	_harness.add_child(_drive)
	_harness.add_child(_marker)
	_harness.drive_system = _drive
	_harness.ocean = _harness_ocean
	_drive.configure(_marker)
	_fixture.add_child(_harness)

	_main_instance = main_packed.instantiate()
	root.add_child(_fixture)
	await process_frame
	_stop_audio_recursive(_fixture)
	_stop_audio_recursive(_main_instance)
	_vehicle.freeze = true


func _validate_structure_and_configuration() -> void:
	var scene_drive := _vehicle.get_node_or_null(
		"Systems/DriveSystem"
	) as JetSkiDriveSystem
	_expect_numbered(
		3,
		scene_drive != null,
		"Existe JetSki/Systems/DriveSystem."
	)
	var drive_source := FileAccess.get_file_as_string(DRIVE_SOURCE)
	_expect_numbered(
		4,
		not drive_source.contains("func _process(")
		and not drive_source.contains("func _physics_process(")
		and not drive_source.contains("func _integrate_forces("),
		"DriveSystem no tiene procesamiento autónomo."
	)
	_expect_numbered(
		5,
		drive_source.count("JetSkiDriveState.new()") == 1,
		"Existe un único DriveState persistente."
	)
	var controller_source := FileAccess.get_file_as_string(
		CONTROLLER_SOURCE
	)
	var duplicates_drive := false
	for forbidden: String in [
		"var _propulsion_depth",
		"var _propulsion_contact_factor",
		"var _current_steering_angle_degrees",
		"var _current_propulsion_force",
		"var _last_propulsion_world_position",
		"func _apply_propulsion",
		"func _apply_coasting_steering",
		"func _cache_propulsion_point",
	]:
		duplicates_drive = (
			duplicates_drive or controller_source.contains(forbidden)
		)
	_expect_numbered(
		6,
		not duplicates_drive,
		"JetSkiController no duplica estado ni lógica Drive."
	)
	var scene_marker := _vehicle.get_node_or_null(
		"PropulsionPoint"
	) as Marker3D
	_expect_numbered(
		7,
		scene_marker != null,
		"Existe PropulsionPoint."
	)
	_expect_numbered(
		8,
		scene_marker != null
		and _vector_close(
			scene_drive.get_propulsion_local_point(),
			scene_marker.transform.origin
		),
		"Se conserva exactamente la posición local."
	)
	var configuration_matches := (
		is_equal_approx(
			scene_drive.forward_engine_force,
			_vehicle.forward_engine_force
		)
		and is_equal_approx(
			scene_drive.reverse_engine_force,
			_vehicle.reverse_engine_force
		)
		and is_equal_approx(
			scene_drive.propulsion_full_contact_depth,
			_vehicle.propulsion_full_contact_depth
		)
		and is_equal_approx(
			scene_drive.forward_thrust_falloff_start_speed,
			_vehicle.forward_thrust_falloff_start_speed
		)
		and is_equal_approx(
			scene_drive.forward_thrust_falloff_end_speed,
			_vehicle.forward_thrust_falloff_end_speed
		)
		and is_equal_approx(
			scene_drive.reverse_thrust_falloff_start_speed,
			_vehicle.reverse_thrust_falloff_start_speed
		)
		and is_equal_approx(
			scene_drive.reverse_thrust_falloff_end_speed,
			_vehicle.reverse_thrust_falloff_end_speed
		)
		and is_equal_approx(
			scene_drive.maximum_steering_angle_degrees,
			_vehicle.maximum_steering_angle_degrees
		)
		and is_equal_approx(
			scene_drive.steering_reduction_start_speed,
			_vehicle.steering_reduction_start_speed
		)
		and is_equal_approx(
			scene_drive.steering_reduction_end_speed,
			_vehicle.steering_reduction_end_speed
		)
		and is_equal_approx(
			scene_drive.high_speed_steering_factor,
			_vehicle.high_speed_steering_factor
		)
		and is_equal_approx(
			scene_drive.coasting_steering_force_per_speed_squared,
			_vehicle.coasting_steering_force_per_speed_squared
		)
		and is_equal_approx(
			scene_drive.max_coasting_steering_force,
			_vehicle.max_coasting_steering_force
		)
	)
	_expect_numbered(
		9,
		configuration_matches,
		"Todos los exports Drive se copian correctamente."
	)
	var integrate_start := controller_source.find("func _integrate_forces(")
	var integrate_end := controller_source.find(
		"\n\nfunc ",
		integrate_start + 1
	)
	var integrate_source := controller_source.substr(
		integrate_start,
		integrate_end - integrate_start
	)
	_expect_numbered(
		10,
		not integrate_source.contains("_configure_drive_system")
		and controller_source.count("_configure_drive_system()") == 2,
		"La configuración se copia solo en _ready()."
	)
	var missing_system := JetSkiDriveSystem.new()
	missing_system.configure(null)
	missing_system.configure(null)
	_expect_numbered(
		11,
		missing_system.get_warning_emission_count() == 1
		and not missing_system.has_valid_propulsion_point()
		and _vehicle.water_physics_system != null
		and _vehicle.navigation_system != null,
		"Un marcador ausente avisa una vez y no rompe otros sistemas."
	)
	missing_system.free()


func _validate_state_and_sampling() -> void:
	var persistent_state := _drive.state
	_drive.state.propulsion_depth = 9.0
	_drive.state.propulsion_contact_factor = 1.0
	_drive.state.steering_angle_degrees = 7.0
	_drive.state.propulsion_force = 123.0
	_drive.state.propulsion_force_vector = Vector3.ONE
	_drive.state.is_propelling = true
	_drive.begin_physics_tick()
	_expect_numbered(
		12,
		_frame_metrics_are_zero(_drive.state),
		"Las métricas se limpian al principio del tick."
	)
	var scene_drive := _vehicle.drive_system
	scene_drive.state.propulsion_force = 777.0
	scene_drive.state.propulsion_force_vector = Vector3.ONE
	scene_drive.state.is_propelling = true
	_vehicle.set("_ocean", null)
	_vehicle.freeze = false
	_vehicle.sleeping = false
	await physics_frame
	_vehicle.freeze = true
	_expect_numbered(
		13,
		is_zero_approx(scene_drive.state.propulsion_force)
		and scene_drive.state.propulsion_force_vector.is_zero_approx()
		and not scene_drive.state.is_propelling,
		"Un early return del controlador no deja fuerza obsoleta."
	)
	_vehicle.set("_ocean", _vehicle_ocean)
	await _run_case(
		Vector3.ZERO,
		Vector3.ZERO,
		0.5,
		Vector3.UP,
		Vector3.ZERO,
		0.0,
		0.0,
		0.0,
		1.0
	)
	var preserved_world_position := _drive.state.propulsion_world_position
	_drive.begin_physics_tick()
	var preserved_on_begin := (
		_drive.state.propulsion_world_position == preserved_world_position
	)
	_drive.reset_runtime_state()
	_expect_numbered(
		14,
		preserved_on_begin
		and _drive.state.propulsion_world_position
		== preserved_world_position,
		"propulsion_world_position conserva la última muestra."
	)
	var local_point_before := _drive.get_propulsion_local_point()
	_drive.reset_runtime_state()
	_expect_numbered(
		15,
		_drive.has_valid_propulsion_point()
		and _drive.get_propulsion_local_point() == local_point_before
		and is_equal_approx(_drive.forward_engine_force, 4200.0),
		"Reset conserva marcador y configuración."
	)
	await _run_case(
		Vector3.ZERO,
		Vector3.ZERO,
		0.5,
		Vector3.UP,
		Vector3.ZERO,
		0.0,
		0.0,
		0.0,
		1.0
	)
	_expect_numbered(
		16,
		_drive.state == persistent_state,
		"DriveState no cambia de identidad entre steps."
	)
	var world_y := _drive.state.propulsion_world_position.y
	var sampled_height := world_y + 0.21
	await _run_case(
		Vector3.ZERO,
		Vector3.ZERO,
		sampled_height,
		Vector3.UP,
		Vector3.ZERO,
		0.0,
		0.0,
		0.0,
		1.0
	)
	_expect_numbered(
		17,
		_scalar_close(_drive.state.propulsion_depth, 0.21),
		"La altura del agua produce la profundidad esperada."
	)
	var sloped_normal := Vector3(0.0, 1.0, 0.25).normalized()
	await _run_case(
		Vector3.ZERO,
		Vector3.ZERO,
		1.0,
		sloped_normal,
		Vector3.ZERO,
		1.0,
		0.0,
		0.0,
		1.0
	)
	_expect_numbered(
		18,
		absf(
			_drive.state.propulsion_force_vector.dot(sloped_normal)
		) <= VECTOR_EPSILON,
		"La dirección base utiliza la normal muestreada."
	)
	await _run_case(
		Vector3(0.0, 0.0, -20.0),
		Vector3.ZERO,
		1.0,
		Vector3.UP,
		Vector3(0.0, 0.0, -5.0),
		1.0,
		0.0,
		0.0,
		1.0
	)
	var expected_forward_factor := 1.0 - _inverse_lerp_clamped(
		18.0,
		28.0,
		15.0
	)
	_expect_numbered(
		19,
		_scalar_close(
			_drive.state.forward_speed_factor,
			expected_forward_factor
		),
		"La velocidad del agua se resta de la velocidad física."
	)
	await _run_case(
		Vector3.ZERO,
		Vector3.ZERO,
		1.0,
		Vector3.DOWN,
		Vector3.ZERO,
		1.0,
		0.0,
		0.0,
		1.0
	)
	_expect_numbered(
		20,
		_vector_close(
			_drive.state.propulsion_force_vector,
			Vector3(0.0, 0.0, -4200.0)
		),
		"Una normal invertida se corrige antes de aplicar fuerza."
	)
	await _run_case(
		Vector3.ZERO,
		Vector3.ZERO,
		1.0,
		Vector3(NAN, 1.0, 0.0),
		Vector3.ZERO,
		1.0,
		0.0,
		0.0,
		1.0
	)
	_expect_numbered(
		21,
		not _drive.state.is_propelling
		and _drive.state.propulsion_force_vector.is_zero_approx(),
		"Una muestra inválida no aplica fuerza."
	)
	await _run_case(
		Vector3.ZERO,
		Vector3.ZERO,
		1.0,
		Vector3.FORWARD,
		Vector3.ZERO,
		1.0,
		0.0,
		0.0,
		1.0
	)
	_expect_numbered(
		22,
		not _drive.state.is_propelling,
		"Un eje tangencial degenerado no aplica fuerza."
	)
	_expect_numbered(
		23,
		_drive_state_is_finite(_drive.state),
		"Los valores no finitos no contaminan DriveState."
	)


func _validate_contact_and_forward() -> void:
	await _run_case(
		Vector3.ZERO,
		Vector3.ZERO,
		-0.3,
		Vector3.UP,
		Vector3.ZERO,
		1.0,
		0.0,
		0.0,
		1.0
	)
	_expect_numbered(
		24,
		_drive.state.propulsion_depth < 0.0
		and is_zero_approx(_drive.state.propulsion_contact_factor)
		and not _drive.state.is_propelling,
		"El propulsor seco no aplica fuerza."
	)
	var propulsion_y := LOCAL_PROPULSION_POINT.y
	await _run_case(
		Vector3.ZERO,
		Vector3.ZERO,
		propulsion_y + 0.15,
		Vector3.UP,
		Vector3.ZERO,
		1.0,
		0.0,
		0.0,
		1.0
	)
	_expect_numbered(
		25,
		_scalar_close(_drive.state.propulsion_contact_factor, 0.5),
		"El contacto parcial conserva depth/full_contact_depth."
	)
	await _run_case(
		Vector3.ZERO,
		Vector3.ZERO,
		propulsion_y + 0.3,
		Vector3.UP,
		Vector3.ZERO,
		1.0,
		0.0,
		0.0,
		1.0
	)
	_expect_numbered(
		26,
		_scalar_close(_drive.state.propulsion_contact_factor, 1.0),
		"El contacto completo alcanza factor uno."
	)
	await _run_case(
		Vector3.ZERO,
		Vector3.ZERO,
		propulsion_y + 30.0,
		Vector3.UP,
		Vector3.ZERO,
		1.0,
		0.0,
		0.0,
		1.0
	)
	var upper_clamped := _drive.state.propulsion_contact_factor == 1.0
	await _run_case(
		Vector3.ZERO,
		Vector3.ZERO,
		propulsion_y - 30.0,
		Vector3.UP,
		Vector3.ZERO,
		1.0,
		0.0,
		0.0,
		1.0
	)
	_expect_numbered(
		27,
		upper_clamped
		and _drive.state.propulsion_contact_factor == 0.0,
		"El factor queda limitado entre cero y uno."
	)
	await _full_contact_case(
		Vector3.ZERO,
		0.0,
		0.0,
		0.0,
		1.0
	)
	_expect_numbered(
		28,
		not _drive.state.is_propelling
		and is_zero_approx(_drive.state.propulsion_force),
		"Throttle cero no aplica propulsión."
	)
	await _full_contact_case(
		Vector3.ZERO,
		0.5,
		0.0,
		0.0,
		1.0
	)
	_expect_numbered(
		29,
		_scalar_close(_drive.state.propulsion_force, 2100.0),
		"Throttle parcial escala linealmente."
	)
	await _full_contact_case(
		Vector3.ZERO,
		1.0,
		0.0,
		0.0,
		1.0
	)
	_expect_numbered(
		30,
		_scalar_close(_drive.state.propulsion_force, 4200.0),
		"Throttle completo conserva la fuerza configurada."
	)
	_expect_numbered(
		31,
		_vector_close(
			_drive.state.propulsion_force_vector,
			Vector3(0.0, 0.0, -4200.0)
		),
		"La fuerza base y la convención forward=-Z coinciden."
	)
	await _full_contact_case(
		Vector3(0.0, 0.0, -10.0),
		1.0,
		0.0,
		0.0,
		1.0
	)
	_expect_numbered(
		32,
		_scalar_close(_drive.state.forward_speed_factor, 1.0),
		"Antes del inicio del falloff el factor es uno."
	)
	await _full_contact_case(
		Vector3(0.0, 0.0, -23.0),
		1.0,
		0.0,
		0.0,
		1.0
	)
	_expect_numbered(
		33,
		_scalar_close(_drive.state.forward_speed_factor, 0.5),
		"El falloff dentro del intervalo es idéntico."
	)
	await _full_contact_case(
		Vector3(0.0, 0.0, -30.0),
		1.0,
		0.0,
		0.0,
		1.0
	)
	_expect_numbered(
		34,
		is_zero_approx(_drive.state.forward_speed_factor)
		and not _drive.state.is_propelling,
		"Después del falloff la fuerza llega a cero."
	)
	await _full_contact_case(
		Vector3.ZERO,
		1.0,
		0.0,
		0.0,
		1.0
	)
	_expect_numbered(
		35,
		_vector_close(
			_drive.state.propulsion_force_application_offset,
			LOCAL_PROPULSION_POINT
		),
		"La propulsión se aplica en el offset del marcador."
	)


func _validate_reverse_and_steering() -> void:
	await _full_contact_case(
		Vector3.ZERO,
		0.0,
		0.5,
		0.0,
		1.0
	)
	_expect_numbered(
		36,
		_scalar_close(_drive.state.propulsion_force, 900.0),
		"Brake parcial escala la marcha atrás."
	)
	await _full_contact_case(
		Vector3.ZERO,
		0.0,
		1.0,
		0.0,
		1.0
	)
	_expect_numbered(
		37,
		_scalar_close(_drive.state.propulsion_force, 1800.0),
		"Brake completo conserva la fuerza inversa."
	)
	await _full_contact_case(
		Vector3(0.0, 0.0, 7.0),
		0.0,
		1.0,
		0.0,
		1.0
	)
	_expect_numbered(
		38,
		_scalar_close(_drive.state.reverse_speed_factor, 0.5)
		and _scalar_close(_drive.state.propulsion_force, 900.0),
		"El falloff de marcha atrás coincide."
	)
	_expect_numbered(
		39,
		_drive.state.propulsion_force_vector.z > 0.0,
		"La dirección de marcha atrás conserva el signo."
	)
	_expect_numbered(
		40,
		_vector_close(
			_drive.state.propulsion_force_application_offset,
			LOCAL_PROPULSION_POINT
		),
		"La marcha atrás se aplica en el offset del propulsor."
	)
	await _full_contact_case(
		Vector3.ZERO,
		1.0,
		0.0,
		0.0,
		1.0
	)
	_expect_numbered(
		41,
		is_zero_approx(_drive.state.steering_angle_degrees),
		"Steering cero no rota la dirección."
	)
	await _full_contact_case(
		Vector3.ZERO,
		1.0,
		0.0,
		-1.0,
		1.0
	)
	var left_vector := _drive.state.propulsion_force_vector
	var left_angle := _drive.state.steering_angle_degrees
	_expect_numbered(
		42,
		_scalar_close(left_angle, -12.0),
		"Steering izquierdo conserva su ángulo."
	)
	await _full_contact_case(
		Vector3.ZERO,
		1.0,
		0.0,
		1.0,
		1.0
	)
	var right_vector := _drive.state.propulsion_force_vector
	var right_angle := _drive.state.steering_angle_degrees
	_expect_numbered(
		43,
		_scalar_close(right_angle, 12.0),
		"Steering derecho conserva su ángulo."
	)
	_expect_numbered(
		44,
		_scalar_close(absf(left_angle), 12.0)
		and _scalar_close(absf(right_angle), 12.0),
		"El ángulo máximo configurado se conserva."
	)
	var high_speed := 18.0
	await _full_contact_case(
		Vector3(0.0, 0.0, -high_speed),
		1.0,
		0.0,
		1.0,
		1.0
	)
	var expected_steering_factor := lerpf(
		1.0,
		0.45,
		_inverse_lerp_clamped(12.0, 25.0, high_speed)
	)
	_expect_numbered(
		45,
		_scalar_close(
			_drive.state.steering_angle_degrees,
			12.0 * expected_steering_factor
		),
		"La reducción de steering a alta velocidad coincide."
	)
	await _full_contact_case(
		Vector3(0.0, 0.0, -25.0),
		1.0,
		0.0,
		1.0,
		1.0
	)
	_expect_numbered(
		46,
		_scalar_close(_drive.state.steering_angle_degrees, 5.4),
		"El factor mínimo de alta velocidad es 0.45."
	)
	var angled_normal := Vector3(0.2, 1.0, 0.1).normalized()
	await _run_case(
		Vector3.ZERO,
		Vector3.ZERO,
		1.0,
		angled_normal,
		Vector3.ZERO,
		1.0,
		0.0,
		1.0,
		1.0
	)
	_expect_numbered(
		47,
		absf(
			_drive.state.propulsion_force_vector.dot(angled_normal)
		) <= VECTOR_EPSILON,
		"Steering rota alrededor de la normal del agua."
	)
	_expect_numbered(
		48,
		left_vector.x * right_vector.x < 0.0
		and signf(left_angle) == -signf(right_angle)
		and _scalar_close(left_vector.z, right_vector.z),
		"Los signos izquierdo/derecho coinciden con el código anterior."
	)


func _validate_coasting_and_submarine() -> void:
	await _full_contact_case(
		Vector3(0.0, 0.0, -10.0),
		0.1,
		0.0,
		1.0,
		1.0
	)
	_expect_numbered(
		49,
		_drive.state.coasting_steering_force_vector.is_zero_approx(),
		"Coasting no se aplica con input neto distinto de cero."
	)
	await _full_contact_case(
		Vector3(0.0, 0.0, -10.0),
		0.0,
		0.0,
		0.0,
		1.0
	)
	_expect_numbered(
		50,
		_drive.state.coasting_steering_force_vector.is_zero_approx(),
		"Coasting no se aplica sin steering."
	)
	await _full_contact_case(
		Vector3.ZERO,
		0.0,
		0.0,
		1.0,
		1.0
	)
	_expect_numbered(
		51,
		_drive.state.coasting_steering_force_vector.is_zero_approx(),
		"Coasting no se aplica sin velocidad."
	)
	await _full_contact_case(
		Vector3(0.0, 0.0, -10.0),
		0.0,
		0.0,
		1.0,
		1.0
	)
	var coasting_speed_10 := (
		_drive.state.coasting_steering_force_vector.length()
	)
	_expect_numbered(
		52,
		coasting_speed_10 > 0.0
		and not _drive.state.is_propelling,
		"Coasting se aplica sin gas a velocidad suficiente."
	)
	await _full_contact_case(
		Vector3(0.0, 0.0, -5.0),
		0.0,
		0.0,
		1.0,
		1.0
	)
	var coasting_speed_5 := (
		_drive.state.coasting_steering_force_vector.length()
	)
	_expect_numbered(
		53,
		_scalar_close(coasting_speed_10, coasting_speed_5 * 4.0),
		"Coasting escala con velocidad al cuadrado."
	)
	await _run_case(
		Vector3(0.0, 0.0, -10.0),
		Vector3.ZERO,
		LOCAL_PROPULSION_POINT.y + 0.15,
		Vector3.UP,
		Vector3.ZERO,
		0.0,
		0.0,
		1.0,
		1.0
	)
	_expect_numbered(
		54,
		_scalar_close(
			_drive.state.coasting_steering_force_vector.length(),
			coasting_speed_10 * 0.5
		),
		"Coasting escala con el contacto del propulsor."
	)
	await _full_contact_case(
		Vector3(0.0, 0.0, -100.0),
		0.0,
		0.0,
		1.0,
		1.0
	)
	_expect_numbered(
		55,
		_scalar_close(
			_drive.state.coasting_steering_force_vector.length(),
			1500.0
		),
		"Coasting respeta su fuerza máxima."
	)
	_expect_numbered(
		56,
		_vector_close(
			_drive.state.coasting_force_application_offset,
			LOCAL_PROPULSION_POINT
		),
		"Coasting se aplica en el punto del propulsor."
	)
	await _full_contact_case(
		Vector3.ZERO,
		1.0,
		0.0,
		0.5,
		1.0
	)
	var factor_one_force := _drive.state.propulsion_force
	var factor_one_angle := _drive.state.steering_angle_degrees
	var factor_one_contact := _drive.state.propulsion_contact_factor
	_expect_numbered(
		57,
		_scalar_close(factor_one_force, 4200.0),
		"Submarine factor 1.0 conserva la fuerza."
	)
	await _full_contact_case(
		Vector3.ZERO,
		1.0,
		0.0,
		0.5,
		0.75
	)
	var factor_075_force := _drive.state.propulsion_force
	_expect_numbered(
		58,
		_scalar_close(factor_075_force, 3150.0),
		"Submarine factor 0.75 escala la fuerza."
	)
	await _full_contact_case(
		Vector3.ZERO,
		1.0,
		0.0,
		0.5,
		0.0
	)
	_expect_numbered(
		59,
		is_zero_approx(_drive.state.propulsion_force)
		and not _drive.state.is_propelling,
		"Submarine factor 0.0 anula la propulsión."
	)
	_expect_numbered(
		60,
		_scalar_close(factor_075_force, factor_one_force * 0.75),
		"El factor submarine se aplica en el mismo punto del cálculo."
	)
	_expect_numbered(
		61,
		_scalar_close(
			_drive.state.steering_angle_degrees,
			factor_one_angle
		)
		and _scalar_close(
			_drive.state.propulsion_contact_factor,
			factor_one_contact
		),
		"Submarine no altera steering ni contacto."
	)


func _validate_compatibility() -> void:
	var scene_drive := _vehicle.drive_system
	scene_drive.state.propulsion_depth = 0.2
	scene_drive.state.propulsion_contact_factor = 0.75
	scene_drive.state.steering_angle_degrees = -4.0
	scene_drive.state.forward_speed_factor = 0.8
	scene_drive.state.reverse_speed_factor = 0.6
	scene_drive.state.propulsion_force = 1234.0
	scene_drive.state.propulsion_force_vector = Vector3(1.0, 2.0, 3.0)
	scene_drive.state.propulsion_world_position = Vector3(4.0, 5.0, 6.0)
	scene_drive.state.is_propelling = true
	_expect_numbered(
		62,
		_scalar_close(_vehicle.propulsion_depth, 0.2)
		and _scalar_close(_vehicle.propulsion_contact_factor, 0.75)
		and _scalar_close(_vehicle.current_steering_angle_degrees, -4.0)
		and _scalar_close(_vehicle.current_forward_speed_factor, 0.8)
		and _scalar_close(_vehicle.current_reverse_speed_factor, 0.6)
		and _scalar_close(_vehicle.current_propulsion_force, 1234.0)
		and _vehicle.current_propulsion_force_vector
		== Vector3(1.0, 2.0, 3.0)
		and _vehicle.last_propulsion_force_vector
		== Vector3(1.0, 2.0, 3.0)
		and _vehicle.last_propulsion_world_position
		== Vector3(4.0, 5.0, 6.0)
		and _vehicle.is_propelling,
		"Todos los proxies coinciden con DriveState."
	)
	_expect_numbered(
		63,
		_vehicle.get_propulsion_local_point()
		== scene_drive.get_propulsion_local_point(),
		"get_propulsion_local_point coincide."
	)
	_expect_numbered(
		64,
		_vehicle.get_node_or_null("EngineAudio") != null,
		"EngineAudio carga."
	)
	_expect_numbered(
		65,
		_vehicle.get_node_or_null("WaterAudio") != null,
		"WaterAudio carga."
	)
	_expect_numbered(
		66,
		_vehicle.get_node_or_null(
			"Effects/VehicleWaterEffects3D"
		) != null,
		"VehicleWaterEffects3D carga."
	)
	_expect_numbered(
		67,
		_vehicle.get_node_or_null("Effects/TurbineExhaust") != null,
		"TurbineExhaust carga."
	)
	_expect_numbered(
		68,
		_vehicle.get_node_or_null("ArcadeHandling") != null
		and not FileAccess.get_file_as_string(
			"res://scripts/vehicle/jet_ski_arcade_handling.gd"
		).contains("JetSkiDriveSystem"),
		"ArcadeHandling carga y continúa separado."
	)
	var controller_source := FileAccess.get_file_as_string(
		CONTROLLER_SOURCE
	)
	var rider_dynamics_source := FileAccess.get_file_as_string(
		RIDER_DYNAMICS_SOURCE
	)
	_expect_numbered(
		69,
		rider_dynamics_source.contains(
			"drive_state.propulsion_contact_factor"
		)
		and not controller_source.contains("_propulsion_contact_factor"),
		"Turn lean recibe el mismo factor mediante DriveState."
	)
	_expect_numbered(
		70,
		_main_instance.get_node_or_null("Debug") != null
		and _vehicle.current_propulsion_force == 1234.0,
		"Debug continúa recibiendo métricas públicas."
	)
	var position_before_reset := (
		scene_drive.state.propulsion_world_position
	)
	_vehicle.reset_vehicle(&"drive_validation")
	_expect_numbered(
		71,
		_frame_metrics_are_zero(scene_drive.state)
		and scene_drive.state.propulsion_world_position
		== position_before_reset
		and scene_drive.has_valid_propulsion_point(),
		"Reset limpia runtime y conserva posición/configuración."
	)
	_vehicle.set("_ocean", _vehicle_ocean)
	_vehicle_ocean.test_height = -100.0
	_vehicle.freeze = false
	_vehicle.global_transform = Transform3D.IDENTITY
	_vehicle.linear_velocity = Vector3.ZERO
	_vehicle.angular_velocity = Vector3.ZERO
	_vehicle.sleeping = false
	await physics_frame
	var drive_identity := scene_drive.state
	var velocity_before_rebase := _vehicle.linear_velocity
	_vehicle.apply_world_rebase(Vector3(20.0, 0.0, -13.0))
	_vehicle.sleeping = false
	await physics_frame
	_vehicle.freeze = true
	var expected_world_point := (
		_vehicle.global_transform
		* scene_drive.get_propulsion_local_point()
	)
	_expect_numbered(
		72,
		scene_drive.state == drive_identity
		and _vector_close(
			scene_drive.state.propulsion_world_position,
			expected_world_point
		)
		and _vector_close(
			_vehicle.linear_velocity,
			velocity_before_rebase
		),
		"Rebase actualiza la muestra siguiente sin alterar velocidad."
	)
	_expect_numbered(
		73,
		_vehicle.get_script() != null
		and scene_drive.get_script() != null,
		"No existen errores de parser."
	)
	var git_output: Array = []
	var git_exit := OS.execute(
		"git",
		PackedStringArray(["diff", "--check"]),
		git_output,
		true
	)
	_expect_numbered(
		74,
		git_exit == 0,
		"git diff --check queda limpio."
	)


func _validate_legacy_equivalence() -> void:
	var cases: Array[Dictionary] = [
		{
			"name": "propulsor seco",
			"velocity": Vector3.ZERO,
			"height": -0.3,
			"throttle": 1.0,
			"brake": 0.0,
			"steering": 0.0,
			"submarine": 1.0,
		},
		{
			"name": "contacto parcial",
			"velocity": Vector3.ZERO,
			"height": LOCAL_PROPULSION_POINT.y + 0.15,
			"throttle": 1.0,
			"brake": 0.0,
			"steering": 0.0,
			"submarine": 1.0,
		},
		{
			"name": "contacto completo",
			"velocity": Vector3.ZERO,
			"height": LOCAL_PROPULSION_POINT.y + 0.6,
			"throttle": 1.0,
			"brake": 0.0,
			"steering": 0.0,
			"submarine": 1.0,
		},
		{
			"name": "throttle parcial",
			"velocity": Vector3.ZERO,
			"height": LOCAL_PROPULSION_POINT.y + 0.6,
			"throttle": 0.35,
			"brake": 0.0,
			"steering": 0.0,
			"submarine": 1.0,
		},
		{
			"name": "throttle completo",
			"velocity": Vector3.ZERO,
			"height": LOCAL_PROPULSION_POINT.y + 0.6,
			"throttle": 1.0,
			"brake": 0.0,
			"steering": 0.0,
			"submarine": 1.0,
		},
		{
			"name": "marcha atrás",
			"velocity": Vector3.ZERO,
			"height": LOCAL_PROPULSION_POINT.y + 0.6,
			"throttle": 0.0,
			"brake": 1.0,
			"steering": 0.0,
			"submarine": 1.0,
		},
		{
			"name": "velocidad baja",
			"velocity": Vector3(0.0, 0.0, -5.0),
			"height": LOCAL_PROPULSION_POINT.y + 0.6,
			"throttle": 1.0,
			"brake": 0.0,
			"steering": 0.0,
			"submarine": 1.0,
		},
		{
			"name": "velocidad dentro del falloff",
			"velocity": Vector3(0.0, 0.0, -23.0),
			"height": LOCAL_PROPULSION_POINT.y + 0.6,
			"throttle": 1.0,
			"brake": 0.0,
			"steering": 0.0,
			"submarine": 1.0,
		},
		{
			"name": "velocidad sobre el falloff",
			"velocity": Vector3(0.0, 0.0, -40.0),
			"height": LOCAL_PROPULSION_POINT.y + 0.6,
			"throttle": 1.0,
			"brake": 0.0,
			"steering": 0.0,
			"submarine": 1.0,
		},
		{
			"name": "steering izquierdo",
			"velocity": Vector3.ZERO,
			"height": LOCAL_PROPULSION_POINT.y + 0.6,
			"throttle": 1.0,
			"brake": 0.0,
			"steering": -1.0,
			"submarine": 1.0,
		},
		{
			"name": "steering derecho",
			"velocity": Vector3.ZERO,
			"height": LOCAL_PROPULSION_POINT.y + 0.6,
			"throttle": 1.0,
			"brake": 0.0,
			"steering": 1.0,
			"submarine": 1.0,
		},
		{
			"name": "steering a alta velocidad",
			"velocity": Vector3(0.0, 0.0, -25.0),
			"height": LOCAL_PROPULSION_POINT.y + 0.6,
			"throttle": 1.0,
			"brake": 0.0,
			"steering": 1.0,
			"submarine": 1.0,
		},
		{
			"name": "coasting sin steering",
			"velocity": Vector3(0.0, 0.0, -12.0),
			"height": LOCAL_PROPULSION_POINT.y + 0.6,
			"throttle": 0.0,
			"brake": 0.0,
			"steering": 0.0,
			"submarine": 1.0,
		},
		{
			"name": "coasting con steering",
			"velocity": Vector3(0.0, 0.0, -12.0),
			"height": LOCAL_PROPULSION_POINT.y + 0.6,
			"throttle": 0.0,
			"brake": 0.0,
			"steering": 0.5,
			"submarine": 1.0,
		},
		{
			"name": "submarine 1.0",
			"velocity": Vector3.ZERO,
			"height": LOCAL_PROPULSION_POINT.y + 0.6,
			"throttle": 1.0,
			"brake": 0.0,
			"steering": 0.5,
			"submarine": 1.0,
		},
		{
			"name": "submarine 0.75",
			"velocity": Vector3.ZERO,
			"height": LOCAL_PROPULSION_POINT.y + 0.6,
			"throttle": 1.0,
			"brake": 0.0,
			"steering": 0.5,
			"submarine": 0.75,
		},
		{
			"name": "submarine 0.0",
			"velocity": Vector3.ZERO,
			"height": LOCAL_PROPULSION_POINT.y + 0.6,
			"throttle": 1.0,
			"brake": 0.0,
			"steering": 0.5,
			"submarine": 0.0,
		},
	]
	for test_case: Dictionary in cases:
		var velocity: Vector3 = test_case["velocity"]
		var water_height: float = test_case["height"]
		var throttle: float = test_case["throttle"]
		var brake: float = test_case["brake"]
		var steering: float = test_case["steering"]
		var submarine_factor: float = test_case["submarine"]
		await _run_case(
			velocity,
			Vector3.ZERO,
			water_height,
			Vector3.UP,
			Vector3.ZERO,
			throttle,
			brake,
			steering,
			submarine_factor
		)
		var expected := _legacy_drive_snapshot(
			velocity,
			water_height,
			throttle,
			brake,
			steering,
			submarine_factor,
			_harness.global_transform * LOCAL_PROPULSION_POINT
		)
		var matches := _drive_matches_snapshot(expected)
		if matches:
			print(
				"PASS: Legacy/delegado: %s coincide."
				% String(test_case["name"])
			)
		else:
			_fail(
				"Legacy/delegado: %s difiere."
				% String(test_case["name"])
			)


func _legacy_drive_snapshot(
	linear_velocity: Vector3,
	water_height: float,
	throttle: float,
	brake: float,
	steering: float,
	submarine_factor: float,
	propulsion_world_position: Vector3
) -> Dictionary:
	var snapshot := {
		"depth": water_height - propulsion_world_position.y,
		"contact": 0.0,
		"angle": 0.0,
		"forward_factor": 0.0,
		"reverse_factor": 0.0,
		"force": 0.0,
		"force_vector": Vector3.ZERO,
		"world_position": propulsion_world_position,
		"is_propelling": false,
		"coasting_force": Vector3.ZERO,
	}
	snapshot["contact"] = clampf(
		snapshot["depth"] / _drive.propulsion_full_contact_depth,
		0.0,
		1.0
	)
	if snapshot["contact"] <= 0.0:
		return snapshot
	var base_direction := Vector3.FORWARD
	var longitudinal_speed := linear_velocity.dot(base_direction)
	var absolute_speed := absf(longitudinal_speed)
	var steering_speed_factor := lerpf(
		1.0,
		_drive.high_speed_steering_factor,
		_inverse_lerp_clamped(
			_drive.steering_reduction_start_speed,
			_drive.steering_reduction_end_speed,
			absolute_speed
		)
	)
	snapshot["angle"] = (
		steering
		* _drive.maximum_steering_angle_degrees
		* steering_speed_factor
	)
	var propulsion_direction := base_direction.rotated(
		Vector3.UP,
		deg_to_rad(snapshot["angle"])
	).normalized()
	var forward_factor := 1.0 - _inverse_lerp_clamped(
		_drive.forward_thrust_falloff_start_speed,
		_drive.forward_thrust_falloff_end_speed,
		maxf(longitudinal_speed, 0.0)
	)
	var reverse_factor := 1.0 - _inverse_lerp_clamped(
		_drive.reverse_thrust_falloff_start_speed,
		_drive.reverse_thrust_falloff_end_speed,
		maxf(-longitudinal_speed, 0.0)
	)
	var net_input := throttle - brake
	var force_vector := Vector3.ZERO
	if net_input > 0.0:
		snapshot["forward_factor"] = forward_factor
		force_vector = (
			propulsion_direction
			* _drive.forward_engine_force
			* net_input
			* snapshot["contact"]
			* forward_factor
		)
	elif net_input < 0.0:
		snapshot["reverse_factor"] = reverse_factor
		force_vector = (
			-propulsion_direction
			* _drive.reverse_engine_force
			* -net_input
			* snapshot["contact"]
			* reverse_factor
		)
	force_vector *= submarine_factor
	if force_vector.is_finite() and not force_vector.is_zero_approx():
		snapshot["force_vector"] = force_vector
		snapshot["force"] = force_vector.length()
		snapshot["is_propelling"] = true
	if is_zero_approx(net_input):
		var lateral_direction := propulsion_direction - base_direction
		if (
			absf(steering) > 0.001
			and absolute_speed > 0.01
			and lateral_direction.length_squared() > 0.000001
		):
			var coasting_magnitude := minf(
				absolute_speed * absolute_speed
				* _drive.coasting_steering_force_per_speed_squared
				* absf(steering)
				* snapshot["contact"],
				_drive.max_coasting_steering_force
			)
			snapshot["coasting_force"] = (
				lateral_direction.normalized() * coasting_magnitude
			)
	return snapshot


func _drive_matches_snapshot(snapshot: Dictionary) -> bool:
	return (
		_scalar_close(_drive.state.propulsion_depth, snapshot["depth"])
		and _scalar_close(
			_drive.state.propulsion_contact_factor,
			snapshot["contact"]
		)
		and _scalar_close(
			_drive.state.steering_angle_degrees,
			snapshot["angle"]
		)
		and _scalar_close(
			_drive.state.forward_speed_factor,
			snapshot["forward_factor"]
		)
		and _scalar_close(
			_drive.state.reverse_speed_factor,
			snapshot["reverse_factor"]
		)
		and _scalar_close(
			_drive.state.propulsion_force,
			snapshot["force"]
		)
		and _vector_close(
			_drive.state.propulsion_force_vector,
			snapshot["force_vector"]
		)
		and _vector_close(
			_drive.state.propulsion_world_position,
			snapshot["world_position"]
		)
		and _drive.state.is_propelling == snapshot["is_propelling"]
		and _vector_close(
			_drive.state.coasting_steering_force_vector,
			snapshot["coasting_force"]
		)
	)


func _run_case(
	linear_velocity: Vector3,
	angular_velocity: Vector3,
	water_height: float,
	water_normal: Vector3,
	water_velocity: Vector3,
	throttle: float,
	brake: float,
	steering: float,
	submarine_factor: float
) -> void:
	_harness_ocean.test_height = water_height
	_harness_ocean.test_normal = water_normal
	_harness_ocean.test_velocity = water_velocity
	_harness.input_state.throttle = throttle
	_harness.input_state.brake = brake
	_harness.input_state.steering = steering
	_harness.submarine_propulsion_factor = submarine_factor
	_harness.global_transform = Transform3D.IDENTITY
	_harness.linear_velocity = linear_velocity
	_harness.angular_velocity = angular_velocity
	_harness.sleeping = false
	await physics_frame


func _full_contact_case(
	linear_velocity: Vector3,
	throttle: float,
	brake: float,
	steering: float,
	submarine_factor: float
) -> void:
	await _run_case(
		linear_velocity,
		Vector3.ZERO,
		LOCAL_PROPULSION_POINT.y + 0.6,
		Vector3.UP,
		Vector3.ZERO,
		throttle,
		brake,
		steering,
		submarine_factor
	)


func _frame_metrics_are_zero(state: JetSkiDriveState) -> bool:
	return (
		is_zero_approx(state.propulsion_depth)
		and is_zero_approx(state.propulsion_contact_factor)
		and is_zero_approx(state.steering_angle_degrees)
		and is_zero_approx(state.forward_speed_factor)
		and is_zero_approx(state.reverse_speed_factor)
		and is_zero_approx(state.propulsion_force)
		and state.propulsion_force_vector.is_zero_approx()
		and state.propulsion_force_application_offset.is_zero_approx()
		and state.coasting_steering_force_vector.is_zero_approx()
		and state.coasting_force_application_offset.is_zero_approx()
		and not state.is_propelling
	)


func _drive_state_is_finite(state: JetSkiDriveState) -> bool:
	return (
		is_finite(state.propulsion_depth)
		and is_finite(state.propulsion_contact_factor)
		and is_finite(state.steering_angle_degrees)
		and is_finite(state.forward_speed_factor)
		and is_finite(state.reverse_speed_factor)
		and is_finite(state.propulsion_force)
		and state.propulsion_force_vector.is_finite()
		and state.propulsion_world_position.is_finite()
		and state.coasting_steering_force_vector.is_finite()
	)


func _inverse_lerp_clamped(from: float, to: float, value: float) -> float:
	if to <= from:
		return 1.0 if value >= to else 0.0
	return clampf(inverse_lerp(from, to, value), 0.0, 1.0)


func _scalar_close(actual: float, expected: float) -> bool:
	var scaled_epsilon := maxf(
		SCALAR_EPSILON,
		maxf(absf(actual), absf(expected)) * SCALAR_RELATIVE_EPSILON
	)
	return absf(actual - expected) <= scaled_epsilon


func _vector_close(actual: Vector3, expected: Vector3) -> bool:
	return actual.distance_to(expected) <= VECTOR_EPSILON


func _expect_numbered(
	number: int,
	condition: bool,
	message: String
) -> void:
	if condition:
		print("PASS: %d. %s" % [number, message])
		return
	_fail("%d. %s" % [number, message])


func _fail(message: String) -> void:
	_failed = true
	push_error("FAIL: %s" % message)


func _cleanup_fixture() -> void:
	if is_instance_valid(_main_instance):
		_stop_audio_recursive(_main_instance)
		_main_instance.free()
	if is_instance_valid(_fixture):
		_stop_audio_recursive(_fixture)
		_fixture.free()
	_vehicle = null
	_drive = null
	_harness = null
	_marker = null
	_vehicle_ocean = null
	_harness_ocean = null
	_fixture = null
	_main_instance = null
	await physics_frame
	await process_frame
	await process_frame


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


func _finish() -> void:
	print(
		"DRIVE_SYSTEM_VALIDATION=%s"
		% ("FAIL" if _failed else "PASS")
	)
	quit(1 if _failed else 0)
