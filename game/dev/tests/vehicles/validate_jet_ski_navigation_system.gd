extends SceneTree

const JET_SKI_SCENE := "res://gameplay/vehicles/jet_ski_01/jet_ski_01.tscn"
const MAIN_SCENE := (
	"res://levels/paradise_island/island_test_BLENDER.tscn"
)
const CONTROLLER_SOURCE := (
	"res://gameplay/vehicles/common/core/jet_ski_controller.gd"
)
const NAVIGATION_SOURCE := (
	"res://gameplay/vehicles/common/systems/jet_ski_navigation_system.gd"
)
const FLOAT_TOLERANCE: float = 0.00001

var _main_instance: Node
var _vehicle: JetSkiController
var _system: JetSkiNavigationSystem
var _water_system: JetSkiWaterPhysicsSystem
var _failed: bool = false
var _internal_water_entered_count: int = 0
var _internal_water_exited_count: int = 0
var _internal_hard_landing_count: int = 0
var _internal_deep_submersion_count: int = 0
var _public_water_entered_count: int = 0
var _public_water_exited_count: int = 0
var _public_hard_landing_count: int = 0
var _public_deep_submersion_count: int = 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var jet_ski_packed := load(JET_SKI_SCENE) as PackedScene
	_expect_numbered(1, jet_ski_packed != null, "jet_ski.tscn carga.")
	var main_packed := load(MAIN_SCENE) as PackedScene
	_expect_numbered(2, main_packed != null, "La escena principal carga.")
	if jet_ski_packed == null or main_packed == null:
		_finish()
		return
	var jet_ski_instance := jet_ski_packed.instantiate()
	var navigation_node := jet_ski_instance.get_node_or_null(
		"Systems/NavigationSystem"
	)
	_expect_numbered(
		3,
		navigation_node is JetSkiNavigationSystem,
		"Existe JetSki/Systems/NavigationSystem."
	)
	var navigation_source := FileAccess.get_file_as_string(
		NAVIGATION_SOURCE
	)
	_expect_numbered(
		4,
		not navigation_source.contains("func _process(")
		and not navigation_source.contains("func _physics_process(")
		and not navigation_source.contains("func _integrate_forces("),
		"NavigationSystem no tiene procesamiento autónomo."
	)
	_expect_numbered(
		5,
		navigation_source.count("JetSkiNavigationState.new()") == 1,
		"Existe un único NavigationState persistente."
	)
	var controller_source := FileAccess.get_file_as_string(
		CONTROLLER_SOURCE
	)
	var duplicated_state := false
	for forbidden: String in [
		"var _navigation_state",
		"var _current_contact_mask",
		"var _has_any_support",
		"func _update_navigation_detection",
		"func _update_trick_support_state",
	]:
		duplicated_state = duplicated_state or controller_source.contains(
			forbidden
		)
	_expect_numbered(
		6,
		not duplicated_state,
		"JetSkiController no duplica estado ni lógica de navegación."
	)
	jet_ski_instance.free()

	_main_instance = main_packed.instantiate()
	_main_instance.process_mode = Node.PROCESS_MODE_DISABLED
	_vehicle = _main_instance.get_node_or_null(
		"Gameplay/JetSki"
	) as JetSkiController
	if _vehicle != null:
		_vehicle.freeze = true
	if _vehicle == null:
		_fail("La escena principal no contiene Gameplay/JetSki.")
		_finish()
		return
	_vehicle.call("_configure_navigation_system")
	_vehicle.call("_connect_navigation_signals")

	_system = JetSkiNavigationSystem.new()
	_water_system = JetSkiWaterPhysicsSystem.new()
	_prepare_water_arrays(_water_system)
	_connect_internal_signals()

	_validate_masks()
	_validate_support()
	_validate_airborne()
	_validate_landings()
	_validate_classification()
	_validate_deep_submersion()
	_validate_compatibility(controller_source)
	_validate_legacy_golden_sequence()
	_finish()


func _validate_masks() -> void:
	_system.reset_runtime_state()
	_set_water_sample(18, 0.1, 1, 0.1)
	_step(Vector3.ZERO, Vector3.ZERO, 0.016)
	_expect_numbered(
		7,
		_system.state.current_contact_mask == 2
		and _system.state.previous_contact_mask == 2
		and _system.state.new_contact_mask == 0
		and _system.state.lost_contact_mask == 0,
		"Inicialización de máscaras conserva la semántica del primer tick."
	)
	_system.reset_runtime_state()
	_set_water_sample(0, 0.0, 0, 0.0)
	_step(Vector3.ZERO, Vector3.ZERO, 0.016)
	_set_water_sample(1, 0.1, 1, 0.1)
	_step(Vector3.ZERO, Vector3.ZERO, 0.016)
	_expect_numbered(
		8,
		_system.state.previous_contact_mask == 0
		and _system.state.current_contact_mask == 1
		and _system.state.new_contact_mask == 1,
		"El primer contacto posterior a seco aparece como nuevo."
	)
	_set_water_sample(1, 0.1, 1, 0.1)
	_step(Vector3.ZERO, Vector3.ZERO, 0.016)
	_expect_numbered(
		9,
		_system.state.new_contact_mask == 0
		and _system.state.lost_contact_mask == 0,
		"El contacto mantenido no genera deltas."
	)
	_set_water_sample(7, 0.2, 3, 0.2)
	_step(Vector3.ZERO, Vector3.ZERO, 0.016)
	_expect_numbered(
		10,
		_system.state.new_contact_mask == 6,
		"Los nuevos contactos conservan sus bits."
	)
	_set_water_sample(5, 0.2, 2, 0.2)
	_step(Vector3.ZERO, Vector3.ZERO, 0.016)
	_expect_numbered(
		11,
		_system.state.lost_contact_mask == 2,
		"Los contactos perdidos conservan sus bits."
	)
	_set_water_sample(15, 0.2, 4, 0.2)
	_step(Vector3.ZERO, Vector3.ZERO, 0.016)
	_expect_numbered(
		12,
		_system.state.current_contact_mask == 15,
		"El contacto completo usa ALL_CONTACT_MASK."
	)
	_set_water_sample(0, 0.0, 0, 0.0)
	_step(Vector3.ZERO, Vector3.ZERO, 0.016)
	_expect_numbered(
		13,
		_system.state.current_contact_mask == 0
		and _system.state.lost_contact_mask == 15,
		"La pérdida completa marca los cuatro bits."
	)
	_set_water_sample(255, 0.2, 4, 0.2)
	_step(Vector3.ZERO, Vector3.ZERO, 0.016)
	_expect_numbered(
		14,
		_system.state.current_contact_mask == 15
		and _system.state.new_contact_mask == 15,
		"Los bits quedan limitados a los cuatro puntos."
	)


func _validate_support() -> void:
	_system.reset_runtime_state()
	_support(1, 0, 0, 0.0, Vector3.ZERO)
	_expect_numbered(
		15,
		_system.state.has_water_support
		and not _system.state.has_solid_support
		and _system.state.has_any_support,
		"El agua puede ser el único soporte."
	)
	_support(0, 2, 1, 0.4, Vector3(1.0, 2.0, 3.0))
	_expect_numbered(
		16,
		not _system.state.has_water_support
		and _system.state.has_solid_support
		and _system.state.has_any_support,
		"Un sólido puede ser el único soporte."
	)
	_support(3, 2, 1, 0.4, Vector3.ONE)
	_expect_numbered(
		17,
		_system.state.has_water_support
		and _system.state.has_solid_support
		and _system.state.has_any_support,
		"El soporte combinado se conserva."
	)
	_support(0, 0, 0, 0.0, Vector3.ZERO)
	_expect_numbered(
		18,
		not _system.state.has_any_support,
		"La ausencia total de soporte se detecta."
	)
	_expect_numbered(
		19,
		_system.state.previous_has_any_support
		and _system.state.true_takeoff_this_tick,
		"La transición real de soporte a aire produce takeoff."
	)
	_system.reset_runtime_state()
	_support(3, 0, 0, 0.0, Vector3.ZERO)
	_support(0, 1, 1, 0.8, Vector3(0.2, -0.1, 0.3))
	_expect_numbered(
		20,
		_system.state.has_solid_support
		and _system.state.has_any_support
		and not _system.state.true_takeoff_this_tick,
		"Una rampa sin agua no produce un despegue falso."
	)
	_support(0, 0, 0, 0.0, Vector3.ZERO)
	var takeoff_tick := _system.state.true_takeoff_this_tick
	_support(0, 0, 0, 0.0, Vector3.ZERO)
	_expect_numbered(
		21,
		takeoff_tick and not _system.state.true_takeoff_this_tick,
		"true_takeoff_this_tick dura un único tick."
	)
	_system.reset_runtime_state()
	_support(0, 0, 0, 0.0, Vector3.ZERO)
	_expect_numbered(
		22,
		not _system.state.true_takeoff_this_tick,
		"El primer tick sin soporte no produce un takeoff falso."
	)


func _validate_airborne() -> void:
	_system.reset_runtime_state()
	_reset_internal_signal_counts()
	_set_water_sample(15, 0.2, 4, 0.2)
	_step(Vector3.ZERO, Vector3.ZERO, 0.016)
	_set_water_sample(0, 0.0, 0, 0.0)
	_step(Vector3(1.0, 2.0, 3.0), Vector3(4.0, 5.0, 6.0), 0.2)
	_expect_numbered(
		23,
		_system.state.navigation_state
		!= JetSkiTypes.NavigationState.AIRBORNE
		and is_zero_approx(_system.state.dry_contact_time),
		"La pérdida instantánea sin clearance no confirma airborne."
	)
	_set_water_sample(0, -0.1, 0, 0.0)
	_step(Vector3(1.0, 2.0, 3.0), Vector3(4.0, 5.0, 6.0), 0.05)
	_expect_numbered(
		24,
		_system.state.navigation_state
		!= JetSkiTypes.NavigationState.AIRBORNE
		and is_equal_approx(_system.state.dry_contact_time, 0.05),
		"Clearance sin tiempo suficiente no confirma airborne."
	)
	var expected_takeoff_position := Vector3(2.0, 3.0, 4.0)
	var expected_takeoff_velocity := Vector3(5.0, 6.0, 7.0)
	_step(
		expected_takeoff_position,
		expected_takeoff_velocity,
		0.05
	)
	_expect_numbered(
		25,
		_system.state.navigation_state
		== JetSkiTypes.NavigationState.AIRBORNE,
		"Clearance y tiempo suficiente confirman airborne."
	)
	_expect_numbered(
		26,
		_system.state.takeoff_position == expected_takeoff_position,
		"Se captura la posición de despegue."
	)
	_expect_numbered(
		27,
		_system.state.takeoff_linear_velocity == expected_takeoff_velocity,
		"Se captura la velocidad de despegue."
	)
	_expect_numbered(
		28,
		is_zero_approx(_system.state.current_airtime),
		"El airtime empieza en cero."
	)
	_step(expected_takeoff_position, expected_takeoff_velocity, 0.02)
	_expect_numbered(
		29,
		is_equal_approx(_system.state.current_airtime, 0.02),
		"El airtime aumenta con physics_delta."
	)
	_expect_numbered(
		30,
		_internal_water_exited_count == 1
		and _system.state.water_exit_count == 1,
		"water_exited se emite una sola vez."
	)


func _validate_landings() -> void:
	_reset_internal_signal_counts()
	_set_water_sample(
		3,
		0.2,
		2,
		0.2,
		PackedFloat32Array([-3.0, -2.0, 0.0, 0.0]),
		PackedVector3Array([
			Vector3(-1.0, 0.0, -1.0),
			Vector3(1.0, 0.0, -1.0),
			Vector3.ZERO,
			Vector3.ZERO,
		])
	)
	_step(Vector3.ZERO, Vector3(0.0, -3.0, 5.0), 0.016)
	_expect_numbered(
		31,
		_system.state.water_entry_count == 1
		and _system.state.last_landing_contact_mask == 3,
		"El primer contacto después de airborne registra landing."
	)
	_expect_numbered(
		32,
		_system.state.navigation_state
		== JetSkiTypes.NavigationState.LANDING,
		"El estado cambia a LANDING."
	)
	_expect_numbered(
		33,
		is_equal_approx(
			_system.state.landing_state_time_remaining,
			_system.landing_state_duration
		),
		"La duración de LANDING conserva el valor configurado."
	)
	_expect_numbered(
		34,
		_system.state.last_landing_position == Vector3(0.0, 0.0, -1.0),
		"La posición de aterrizaje promedia el primer contacto."
	)
	_expect_numbered(
		35,
		is_equal_approx(_system.state.last_landing_normal_speed, 3.0),
		"La velocidad normal usa el máximo relativo por punto."
	)
	var expected_intensity := (3.0 - 1.0) / (12.0 - 1.0)
	_expect_numbered(
		36,
		is_equal_approx(
			_system.state.last_landing_intensity,
			expected_intensity
		),
		"La intensidad mantiene inverse_lerp con clamp."
	)
	_expect_numbered(
		37,
		is_equal_approx(_system.state.last_airtime, 0.02),
		"Se conserva el último airtime."
	)
	_expect_numbered(
		38,
		is_equal_approx(_system.state.maximum_recorded_airtime, 0.02),
		"Se actualiza el airtime máximo."
	)
	_expect_numbered(
		39,
		_internal_water_entered_count == 1,
		"water_entered se emite una sola vez."
	)
	var hard_before := _system.state.hard_landing_count
	_system.reset_runtime_state()
	_system.state.navigation_initialized = true
	_system.state.current_contact_mask = 0
	_system.state.has_confirmed_airborne = true
	_system.state.navigation_state = JetSkiTypes.NavigationState.AIRBORNE
	_system.state.current_airtime = 0.4
	_set_water_sample(
		15,
		0.3,
		4,
		0.3,
		PackedFloat32Array([-6.0, -5.0, -4.0, -3.0])
	)
	_step(Vector3.ZERO, Vector3(0.0, -6.0, 0.0), 0.016)
	_expect_numbered(
		40,
		is_equal_approx(_system.state.last_landing_normal_speed, 6.0)
		and _system.state.hard_landing_count == hard_before + 1,
		"Hard landing usa el threshold original inclusivo."
	)
	_expect_numbered(
		41,
		_internal_hard_landing_count == 1,
		"hard_landing se emite una sola vez."
	)


func _validate_classification() -> void:
	_expect_numbered(
		42,
		_system.classify_landing_entry(1)
		== JetSkiTypes.LandingEntryType.SINGLE_POINT,
		"SINGLE_POINT se conserva."
	)
	_expect_numbered(
		43,
		_system.classify_landing_entry(3)
		== JetSkiTypes.LandingEntryType.FRONT,
		"FRONT se conserva."
	)
	_expect_numbered(
		44,
		_system.classify_landing_entry(12)
		== JetSkiTypes.LandingEntryType.REAR,
		"REAR se conserva."
	)
	_expect_numbered(
		45,
		_system.classify_landing_entry(5)
		== JetSkiTypes.LandingEntryType.LEFT,
		"LEFT se conserva."
	)
	_expect_numbered(
		46,
		_system.classify_landing_entry(10)
		== JetSkiTypes.LandingEntryType.RIGHT,
		"RIGHT se conserva."
	)
	_expect_numbered(
		47,
		_system.classify_landing_entry(15)
		== JetSkiTypes.LandingEntryType.FLAT,
		"FLAT se conserva."
	)
	_expect_numbered(
		48,
		_system.classify_landing_entry(6)
		== JetSkiTypes.LandingEntryType.DIAGONAL
		and _system.classify_landing_entry(9)
		== JetSkiTypes.LandingEntryType.DIAGONAL,
		"Ambas diagonales actuales se conservan."
	)
	_expect_numbered(
		49,
		_system.classify_landing_entry(0)
		== JetSkiTypes.LandingEntryType.UNKNOWN,
		"UNKNOWN se conserva."
	)


func _validate_deep_submersion() -> void:
	_system.reset_runtime_state()
	_reset_internal_signal_counts()
	var deep_count_before := _system.state.deep_submersion_count
	_set_water_sample(15, 0.8, 3, 0.8)
	_step(Vector3.ZERO, Vector3.ZERO, 0.016)
	_expect_numbered(
		50,
		not _system.state.deep_submersion_latched,
		"No se activa con pocos puntos."
	)
	_set_water_sample(15, 0.69, 4, 0.69)
	_step(Vector3.ZERO, Vector3.ZERO, 0.016)
	_expect_numbered(
		51,
		not _system.state.deep_submersion_latched,
		"No se activa con profundidad insuficiente."
	)
	_set_water_sample(15, 0.7, 4, 0.7)
	_step(Vector3.ZERO, Vector3.ZERO, 0.016)
	_expect_numbered(
		52,
		_system.state.deep_submersion_latched
		and _system.state.navigation_state
		== JetSkiTypes.NavigationState.DEEP_SUBMERGED,
		"Se activa al cumplir puntos y profundidad."
	)
	_expect_numbered(
		53,
		_system.state.deep_submersion_latched,
		"La entrada queda latched."
	)
	_step(Vector3.ZERO, Vector3.ZERO, 0.016)
	_expect_numbered(
		54,
		_system.state.deep_submersion_count == deep_count_before + 1,
		"El contador no aumenta cada tick."
	)
	_set_water_sample(15, 0.4, 4, 0.4)
	_step(Vector3.ZERO, Vector3.ZERO, 0.016)
	_expect_numbered(
		55,
		not _system.state.deep_submersion_latched,
		"El latch se libera con el threshold original."
	)
	_set_water_sample(15, 0.8, 4, 0.8)
	_step(Vector3.ZERO, Vector3.ZERO, 0.016)
	_expect_numbered(
		56,
		_system.state.deep_submersion_count == deep_count_before + 2,
		"Puede activarse de nuevo tras liberarse."
	)
	_expect_numbered(
		57,
		_internal_deep_submersion_count == 2,
		"deeply_submerged se emite una vez por entrada."
	)


func _validate_compatibility(controller_source: String) -> void:
	var vehicle_state := _vehicle.navigation_system.state
	vehicle_state.navigation_state = JetSkiTypes.NavigationState.LANDING
	vehicle_state.current_contact_mask = 5
	vehicle_state.previous_contact_mask = 3
	vehicle_state.new_contact_mask = 4
	vehicle_state.lost_contact_mask = 2
	vehicle_state.has_any_support = true
	vehicle_state.true_takeoff_this_tick = true
	_expect_numbered(
		58,
		_vehicle.navigation_state == vehicle_state.navigation_state
		and _vehicle.current_contact_mask == vehicle_state.current_contact_mask
		and _vehicle.previous_contact_mask == vehicle_state.previous_contact_mask
		and _vehicle.new_contact_mask == vehicle_state.new_contact_mask
		and _vehicle.lost_contact_mask == vehicle_state.lost_contact_mask
		and _vehicle.has_any_support == vehicle_state.has_any_support
		and _vehicle.true_takeoff_this_tick
		== vehicle_state.true_takeoff_this_tick,
		"Los getters proxy coinciden con NavigationState."
	)
	_expect_numbered(
		59,
		_system.get_navigation_state_name(
			JetSkiTypes.NavigationState.IN_WATER
		) == &"IN_WATER"
		and _system.get_navigation_state_name(
			JetSkiTypes.NavigationState.DEEP_SUBMERGED
		) == &"DEEP_SUBMERGED",
		"Los nombres de estados coinciden."
	)
	_expect_numbered(
		60,
		_system.get_landing_entry_type_name(
			JetSkiTypes.LandingEntryType.SINGLE_POINT
		) == &"SINGLE_POINT"
		and _system.get_landing_entry_type_name(
			JetSkiTypes.LandingEntryType.UNKNOWN
		) == &"UNKNOWN",
		"Los nombres de aterrizaje coinciden."
	)
	var consumers_load := (
	load("res://systems/camera/chase_camera.gd") != null
		and load("res://gameplay/vehicles/common/audio/vehicle_water_audio.gd") != null
		and load(
			"res://gameplay/vehicles/common/water_effects/vehicle_water_effects_3d.gd"
		) != null
		and load(
			"res://gameplay/vehicles/jet_ski_01/jet_ski_with_rider.tscn"
		) != null
	)
	_expect_numbered(
		61,
		consumers_load,
		"Los consumidores principales cargan."
	)
	_expect_numbered(
		62,
		_signal_argument_count(_vehicle, &"water_entered") == 2
		and _signal_argument_count(_vehicle, &"water_exited") == 0
		and _signal_argument_count(_vehicle, &"hard_landing") == 2
		and _signal_argument_count(_vehicle, &"deeply_submerged") == 0,
		"Las señales públicas mantienen su firma."
	)
	var runtime_airtime := 0.6
	_system.state.current_airtime = runtime_airtime
	_system.state.current_contact_mask = 5
	_system.state.last_airtime = 1.0
	_system.state.maximum_recorded_airtime = 2.0
	_system.state.water_entry_count = 3
	_system.state.water_exit_count = 4
	_system.state.hard_landing_count = 5
	_system.state.deep_submersion_count = 6
	_system.clear_navigation_statistics()
	_expect_numbered(
		63,
		is_equal_approx(_system.state.current_airtime, runtime_airtime)
		and _system.state.current_contact_mask == 5
		and is_zero_approx(_system.state.last_airtime)
		and is_zero_approx(_system.state.maximum_recorded_airtime)
		and _system.state.water_entry_count == 0
		and _system.state.water_exit_count == 0
		and _system.state.hard_landing_count == 0
		and _system.state.deep_submersion_count == 0,
		"clear_navigation_statistics conserva su semántica."
	)
	var state_identity := _system.state
	var signal_total_before := _internal_signal_total()
	_system.reset_runtime_state()
	_expect_numbered(
		64,
		_system.state == state_identity
		and _internal_signal_total() == signal_total_before,
		"Reset reutiliza el estado y no genera eventos."
	)
	vehicle_state.current_contact_mask = 7
	var vehicle_state_identity := vehicle_state
	var rebase_start := controller_source.find("func apply_world_rebase(")
	var rebase_end := controller_source.find(
		"\n\nfunc ",
		rebase_start + 1
	)
	var rebase_source := controller_source.substr(
		rebase_start,
		rebase_end - rebase_start
	)
	_expect_numbered(
		65,
		_vehicle.navigation_system.state == vehicle_state_identity
		and _vehicle.current_contact_mask == 7
		and rebase_start >= 0
		and rebase_end > rebase_start
		and not rebase_source.contains("navigation_system"),
		"Rebase no invalida NavigationSystem."
	)
	_expect_numbered(
		66,
		controller_source.contains("navigation_system.state,")
		and FileAccess.get_file_as_string(
			"res://gameplay/vehicles/common/systems/jet_ski_trick_system.gd"
		).contains(
			"if navigation_state.true_takeoff_this_tick:"
		),
		"El sistema de trucos recibe true_takeoff_this_tick."
	)
	_expect_numbered(
		67,
		controller_source.contains("water_state.raw_contact_mask == 0")
		and controller_source.contains(
			"submarine_system.capture_pre_contact_state("
		)
		and controller_source.find(
			"submarine_system.capture_pre_contact_state("
		) < controller_source.find("navigation_system.step(")
		and controller_source.find("navigation_system.step(") < (
			controller_source.find(
				"submarine_system.update_after_contacts("
			)
		),
		"Submarine conserva contactos y snapshot previo."
	)
	var arcade := _vehicle.get_node_or_null("ArcadeHandling")
	var rider_impact := _vehicle.get_node_or_null("RiderImpactResponse")
	_expect_numbered(
		68,
		arcade != null and rider_impact != null,
		"Rider y ArcadeHandling siguen instanciados."
	)
	_expect_numbered(
		69,
		_vehicle.get_script() != null
		and _vehicle.navigation_system.get_script() != null,
		"No hay errores de parser."
	)
	var git_output: Array = []
	var git_exit := OS.execute(
		"git",
		PackedStringArray(["diff", "--check"]),
		git_output,
		true
	)
	_expect_numbered(
		70,
		git_exit == 0,
		"git diff --check queda limpio."
	)


func _validate_legacy_golden_sequence() -> void:
	var comparison_system := JetSkiNavigationSystem.new()
	var comparison_water := JetSkiWaterPhysicsSystem.new()
	_prepare_water_arrays(comparison_water)
	var comparison_state := comparison_system.state
	_set_water_sample_for(comparison_water, 15, 0.2, 4, 0.2)
	comparison_system.call(
		"_update_support_state",
		15,
		0,
		0,
		0.0,
		Vector3.ZERO
	)
	comparison_system.call(
		"_step_navigation_state",
		Vector3.ZERO,
		Vector3.ZERO,
		comparison_water,
		0.016
	)
	_expect(
		comparison_state.navigation_state
		== JetSkiTypes.NavigationState.IN_WATER
		and comparison_state.current_contact_mask == 15
		and comparison_state.previous_contact_mask == 15
		and comparison_state.new_contact_mask == 0
		and comparison_state.lost_contact_mask == 0
		and comparison_state.has_water_support
		and comparison_state.has_any_support,
		"Legacy/delegado: agua estable coincide."
	)
	_set_water_sample_for(comparison_water, 3, 0.1, 2, 0.1)
	comparison_system.call(
		"_update_support_state",
		3,
		0,
		0,
		0.0,
		Vector3.ZERO
	)
	comparison_system.call(
		"_step_navigation_state",
		Vector3.ZERO,
		Vector3.ZERO,
		comparison_water,
		0.016
	)
	_expect(
		comparison_state.navigation_state
		== JetSkiTypes.NavigationState.PARTIALLY_SUBMERGED
		and comparison_state.current_contact_mask == 3
		and comparison_state.previous_contact_mask == 15
		and comparison_state.lost_contact_mask == 12,
		"Legacy/delegado: contacto parcial coincide."
	)
	_set_water_sample_for(comparison_water, 0, 0.0, 0, 0.0)
	comparison_system.call(
		"_update_support_state",
		0,
		1,
		1,
		0.75,
		Vector3(0.0, -0.2, 0.5)
	)
	comparison_system.call(
		"_step_navigation_state",
		Vector3.ZERO,
		Vector3.ZERO,
		comparison_water,
		0.2
	)
	_expect(
		comparison_state.has_solid_support
		and comparison_state.has_any_support
		and not comparison_state.true_takeoff_this_tick
		and comparison_state.physical_contact_count == 1
		and comparison_state.solid_support_contact_count == 1
		and is_equal_approx(
			comparison_state.physical_contact_delta_velocity,
			0.75
		),
		"Legacy/delegado: rampa sin agua coincide."
	)
	_set_water_sample_for(comparison_water, 0, -0.1, 0, 0.0)
	comparison_system.call(
		"_update_support_state",
		0,
		0,
		0,
		0.0,
		Vector3.ZERO
	)
	comparison_system.call(
		"_step_navigation_state",
		Vector3(1.0, 2.0, 3.0),
		Vector3(4.0, 5.0, 6.0),
		comparison_water,
		0.1
	)
	_expect(
		comparison_state.true_takeoff_this_tick
		and comparison_state.navigation_state
		== JetSkiTypes.NavigationState.AIRBORNE
		and is_equal_approx(comparison_state.dry_contact_time, 0.1)
		and is_zero_approx(comparison_state.current_airtime)
		and comparison_state.water_exit_count == 1,
		"Legacy/delegado: salida real y airborne coinciden."
	)
	comparison_system.call(
		"_update_support_state",
		0,
		0,
		0,
		0.0,
		Vector3.ZERO
	)
	comparison_system.call(
		"_step_navigation_state",
		Vector3.ZERO,
		Vector3.ZERO,
		comparison_water,
		0.02
	)
	_expect(
		not comparison_state.true_takeoff_this_tick
		and is_equal_approx(comparison_state.current_airtime, 0.02),
		"Legacy/delegado: airtime coincide."
	)
	_set_water_sample_for(
		comparison_water,
		3,
		0.2,
		2,
		0.2,
		PackedFloat32Array([-3.0, -2.0, 0.0, 0.0])
	)
	comparison_system.call(
		"_update_support_state",
		3,
		0,
		0,
		0.0,
		Vector3.ZERO
	)
	comparison_system.call(
		"_step_navigation_state",
		Vector3.ZERO,
		Vector3.ZERO,
		comparison_water,
		0.016
	)
	_expect(
		comparison_state.navigation_state
		== JetSkiTypes.NavigationState.LANDING
		and is_equal_approx(
			comparison_state.last_landing_normal_speed,
			3.0
		)
		and absf(
			comparison_state.last_landing_intensity
			- (2.0 / 11.0)
		) <= FLOAT_TOLERANCE
		and comparison_state.last_landing_contact_mask == 3
		and comparison_state.last_landing_contact_count == 2
		and comparison_state.last_landing_entry_type
		== JetSkiTypes.LandingEntryType.FRONT
		and comparison_state.water_entry_count == 1,
		"Legacy/delegado: aterrizaje suave coincide."
	)
	comparison_system.reset_runtime_state()
	comparison_state.navigation_initialized = true
	comparison_state.has_confirmed_airborne = true
	comparison_state.navigation_state = JetSkiTypes.NavigationState.AIRBORNE
	_set_water_sample_for(
		comparison_water,
		15,
		0.8,
		4,
		0.8,
		PackedFloat32Array([-6.0, -5.0, -4.0, -3.0])
	)
	comparison_system.call(
		"_step_navigation_state",
		Vector3.ZERO,
		Vector3.ZERO,
		comparison_water,
		0.016
	)
	_expect(
		comparison_state.hard_landing_count == 1
		and comparison_state.last_landing_entry_type
		== JetSkiTypes.LandingEntryType.FLAT,
		"Legacy/delegado: aterrizaje fuerte coincide."
	)
	comparison_system.reset_runtime_state()
	var deep_count_before := comparison_state.deep_submersion_count
	_set_water_sample_for(comparison_water, 15, 0.8, 4, 0.8)
	comparison_system.call(
		"_step_navigation_state",
		Vector3.ZERO,
		Vector3.ZERO,
		comparison_water,
		0.016
	)
	var entered_deep := (
		comparison_state.deep_submersion_latched
		and comparison_state.deep_submersion_count == deep_count_before + 1
	)
	_set_water_sample_for(comparison_water, 15, 0.4, 4, 0.4)
	comparison_system.call(
		"_step_navigation_state",
		Vector3.ZERO,
		Vector3.ZERO,
		comparison_water,
		0.016
	)
	_expect(
		entered_deep
		and not comparison_state.deep_submersion_latched
		and comparison_state.deep_submersion_count == deep_count_before + 1,
		"Legacy/delegado: sumersión profunda y liberación coinciden."
	)
	comparison_system.free()
	comparison_water.free()


func _support(
	raw_mask: int,
	physical_count: int,
	solid_count: int,
	delta_velocity: float,
	position: Vector3
) -> void:
	_system.call(
		"_update_support_state",
		raw_mask,
		physical_count,
		solid_count,
		delta_velocity,
		position
	)


func _step(
	body_position: Vector3,
	body_velocity: Vector3,
	physics_delta: float
) -> void:
	_system.call(
		"_step_navigation_state",
		body_position,
		body_velocity,
		_water_system,
		physics_delta
	)


func _set_water_sample(
	mask: int,
	maximum_signed_depth: float,
	submerged_count: int,
	average_depth: float,
	normal_speeds: PackedFloat32Array = PackedFloat32Array(),
	positions: PackedVector3Array = PackedVector3Array()
) -> void:
	_set_water_sample_for(
		_water_system,
		mask,
		maximum_signed_depth,
		submerged_count,
		average_depth,
		normal_speeds,
		positions
	)


func _set_water_sample_for(
	water_system: JetSkiWaterPhysicsSystem,
	mask: int,
	maximum_signed_depth: float,
	submerged_count: int,
	average_depth: float,
	normal_speeds: PackedFloat32Array = PackedFloat32Array(),
	positions: PackedVector3Array = PackedVector3Array()
) -> void:
	var water_state := water_system.state
	water_state.raw_contact_mask = mask
	water_state.maximum_signed_point_depth = maximum_signed_depth
	water_state.submerged_point_count = submerged_count
	water_state.average_depth = average_depth
	var resolved_speeds := normal_speeds
	if resolved_speeds.size() != 4:
		resolved_speeds = PackedFloat32Array([0.0, 0.0, 0.0, 0.0])
	var resolved_positions := positions
	if resolved_positions.size() != 4:
		resolved_positions = PackedVector3Array([
			Vector3(-1.0, 0.0, -1.0),
			Vector3(1.0, 0.0, -1.0),
			Vector3(-1.0, 0.0, 1.0),
			Vector3(1.0, 0.0, 1.0),
		])
	var valid_samples: Array[bool] = [false, false, false, false]
	for index in 4:
		valid_samples[index] = (mask & (1 << index)) != 0
	water_system.set("_point_relative_normal_speeds", resolved_speeds)
	water_system.set("_point_world_positions", resolved_positions)
	water_system.set("_point_sample_valid", valid_samples)


func _prepare_water_arrays(
	water_system: JetSkiWaterPhysicsSystem
) -> void:
	water_system.set(
		"_point_depths",
		PackedFloat32Array([0.0, 0.0, 0.0, 0.0])
	)
	_set_water_sample_for(water_system, 0, 0.0, 0, 0.0)


func _connect_internal_signals() -> void:
	_system.water_entered.connect(_on_internal_water_entered)
	_system.water_exited.connect(_on_internal_water_exited)
	_system.hard_landing.connect(_on_internal_hard_landing)
	_system.deeply_submerged.connect(_on_internal_deep_submersion)
	_vehicle.water_entered.connect(_on_public_water_entered)
	_vehicle.water_exited.connect(_on_public_water_exited)
	_vehicle.hard_landing.connect(_on_public_hard_landing)
	_vehicle.deeply_submerged.connect(_on_public_deep_submersion)
	_vehicle.navigation_system.water_entered.emit(0.25, Vector3.ONE)
	_vehicle.navigation_system.water_exited.emit()
	_vehicle.navigation_system.hard_landing.emit(0.75, Vector3.ONE)
	_vehicle.navigation_system.deeply_submerged.emit()
	_expect(
		_public_water_entered_count == 1
		and _public_water_exited_count == 1
		and _public_hard_landing_count == 1
		and _public_deep_submersion_count == 1,
		"Las señales internas se retransmiten una vez por el controlador."
	)


func _reset_internal_signal_counts() -> void:
	_internal_water_entered_count = 0
	_internal_water_exited_count = 0
	_internal_hard_landing_count = 0
	_internal_deep_submersion_count = 0


func _internal_signal_total() -> int:
	return (
		_internal_water_entered_count
		+ _internal_water_exited_count
		+ _internal_hard_landing_count
		+ _internal_deep_submersion_count
	)


func _signal_argument_count(object: Object, signal_name: StringName) -> int:
	for signal_info: Dictionary in object.get_signal_list():
		if StringName(signal_info.get("name", &"")) != signal_name:
			continue
		var arguments := signal_info.get("args", []) as Array
		return arguments.size()
	return -1


func _on_internal_water_entered(
	_intensity: float,
	_position: Vector3
) -> void:
	_internal_water_entered_count += 1


func _on_internal_water_exited() -> void:
	_internal_water_exited_count += 1


func _on_internal_hard_landing(
	_intensity: float,
	_position: Vector3
) -> void:
	_internal_hard_landing_count += 1


func _on_internal_deep_submersion() -> void:
	_internal_deep_submersion_count += 1


func _on_public_water_entered(
	_intensity: float,
	_position: Vector3
) -> void:
	_public_water_entered_count += 1


func _on_public_water_exited() -> void:
	_public_water_exited_count += 1


func _on_public_hard_landing(
	_intensity: float,
	_position: Vector3
) -> void:
	_public_hard_landing_count += 1


func _on_public_deep_submersion() -> void:
	_public_deep_submersion_count += 1


func _expect_numbered(
	number: int,
	condition: bool,
	message: String
) -> void:
	_expect(condition, "%d. %s" % [number, message])


func _expect(condition: bool, message: String) -> void:
	if condition:
		print("PASS: %s" % message)
	else:
		_fail(message)


func _fail(message: String) -> void:
	_failed = true
	push_error("FAIL: %s" % message)


func _finish() -> void:
	if is_instance_valid(_main_instance):
		_stop_all_audio(_main_instance)
		_main_instance.free()
	if is_instance_valid(_system):
		_system.free()
	if is_instance_valid(_water_system):
		_water_system.free()
	_vehicle = null
	_system = null
	_water_system = null
	_main_instance = null
	await physics_frame
	await process_frame
	print(
		"NAVIGATION_SYSTEM_VALIDATION=%s"
		% ("FAIL" if _failed else "PASS")
	)
	quit(1 if _failed else 0)


func _stop_all_audio(node: Node) -> void:
	var pending: Array[Node] = [node]
	while not pending.is_empty():
		var current := pending.pop_back() as Node
		if current is AudioStreamPlayer:
			var player := current as AudioStreamPlayer
			player.stop()
			player.stream = null
		elif current is AudioStreamPlayer3D:
			var player_3d := current as AudioStreamPlayer3D
			player_3d.stop()
			player_3d.stream = null
		for child: Node in current.get_children():
			pending.append(child)
