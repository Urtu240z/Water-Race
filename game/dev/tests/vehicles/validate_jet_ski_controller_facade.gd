extends SceneTree

const JET_SKI_SCENE := "res://scenes/vehicle/jet_ski.tscn"
const RIDER_SCENE := "res://scenes/vehicle/jet_ski_with_rider.tscn"
const MAIN_SCENE := (
	"res://scenes/levels/island_test/island_test_BLENDER.tscn"
)
const CONTROLLER_SOURCE := (
	"res://scripts/vehicle/jet_ski_controller.gd"
)
const SYSTEM_SOURCES: Array[String] = [
	"res://scripts/vehicle/systems/jet_ski_input_system.gd",
	"res://scripts/vehicle/systems/jet_ski_water_physics_system.gd",
	"res://scripts/vehicle/systems/jet_ski_navigation_system.gd",
	"res://scripts/vehicle/systems/jet_ski_drive_system.gd",
	"res://scripts/vehicle/systems/jet_ski_rider_dynamics_system.gd",
	"res://scripts/vehicle/systems/jet_ski_submarine_system.gd",
	"res://scripts/vehicle/systems/jet_ski_trick_system.gd",
]
const VALIDATOR_PATHS: Array[String] = [
	"res://tools/godot/validate_jet_ski_input_system.gd",
	"res://tools/godot/validate_jet_ski_water_physics_system.gd",
	"res://tools/godot/validate_jet_ski_navigation_system.gd",
	"res://tools/godot/validate_jet_ski_drive_system.gd",
	"res://tools/godot/validate_jet_ski_rider_dynamics_system.gd",
	"res://tools/godot/validate_jet_ski_submarine_system.gd",
	"res://tools/godot/validate_jet_ski_trick_system.gd",
	"res://tools/godot/validate_vehicle_water_audio.gd",
]
const REMOVED_PROPERTIES: Array[String] = [
	"current_steering_angle_degrees",
	"current_forward_speed_factor",
	"current_reverse_speed_factor",
	"current_propulsion_force",
	"current_propulsion_force_vector",
	"turn_lean_target_roll_degrees",
	"turn_lean_current_roll_degrees",
	"turn_lean_error_degrees",
	"turn_lean_reference_forward",
	"turn_lean_reference_right",
	"rider_weight_shift_input",
	"rider_shift_raw_input",
	"rider_shift_smoothed_input",
	"rider_shift_target_angle_metrics_status",
	"rider_shift_manual_roll_target_degrees",
	"rider_shift_automatic_roll_target_degrees",
	"rider_shift_total_roll_target_degrees",
	"rider_shift_current_roll_degrees",
	"rider_shift_manual_pitch_target_degrees",
	"rider_shift_base_pitch_target_degrees",
	"rider_shift_total_pitch_target_degrees",
	"rider_shift_current_pitch_degrees",
	"rider_virtual_offset_local",
	"rider_virtual_offset_world",
	"rider_virtual_weight_torque",
	"rider_manual_applied_torque",
	"rider_roll_damping_torque",
	"rider_pitch_damping_torque",
	"rider_dynamic_pitch_multiplier",
	"rider_using_air_control",
	"rider_arrow_only_steering_input",
	"rider_arrow_only_steering_angle",
	"rider_roll_soft_limit_factor",
	"rider_pitch_soft_limit_factor",
	"rider_air_unlimited_rotation",
	"rider_air_roll_rate",
	"rider_air_pitch_rate",
	"rider_air_accumulated_roll_degrees",
	"rider_air_accumulated_pitch_degrees",
	"submarine_entry_speed",
	"submarine_entry_pitch_degrees",
	"submarine_duration",
	"submarine_current_depth",
	"submarine_max_depth",
	"submarine_buoyancy_factor_current",
	"submarine_propulsion_factor_current",
	"submarine_upright_factor_current",
	"submarine_exit_blend",
	"trick_preload_state",
	"trick_roll_preload_sign",
	"trick_pitch_preload_sign",
	"trick_roll_charge",
	"trick_pitch_charge",
	"trick_roll_reversal_armed",
	"trick_pitch_reversal_armed",
	"trick_reversal_time_remaining",
	"trick_takeoff_quality",
	"trick_takeoff_timing_factor",
	"trick_release_active",
	"trick_release_time_remaining",
	"trick_release_roll_torque",
	"trick_release_pitch_torque",
	"trick_last_launch_type",
	"trick_last_launch_type_name",
	"trick_last_launch_charge",
	"trick_last_release_strength",
	"air_current_roll_rate",
	"air_current_pitch_rate",
	"last_buoyancy_force_vectors",
	"last_forward_drag_force_vectors",
	"last_lateral_drag_force_vectors",
	"last_point_world_positions",
	"last_water_surface_positions",
	"last_water_normals",
	"last_propulsion_force_vector",
	"last_propulsion_world_position",
	"water_reference_valid",
	"navigation_state_name",
	"signed_depth_front_left",
	"signed_depth_front_right",
	"signed_depth_rear_left",
	"signed_depth_rear_right",
	"last_landing_entry_type_name",
	"reset_count",
	"last_reset_reason",
	"last_reset_linear_velocity",
	"last_reset_angular_velocity",
]
const REMOVED_METHODS: Array[String] = [
	"get_buoyancy_local_points",
	"get_buoyancy_point_depths",
	"get_buoyancy_point_normal_forces",
	"get_buoyancy_point_water_normals",
	"get_point_forward_drag_forces",
	"get_point_lateral_drag_forces",
	"get_degenerate_drag_axis_count",
	"get_propulsion_local_point",
	"clear_navigation_statistics",
]

var _failed: bool = false
var _controller_source: String
var _system_sources: Array[String] = []
var _vehicle: JetSkiController
var _fixture: Node3D
var _reset_count: int = 0
var _rebase_count: int = 0
var _water_entered_count: int = 0
var _water_exited_count: int = 0
var _landing_count: int = 0
var _submarine_started_count: int = 0
var _submarine_ended_count: int = 0
var _trick_count: int = 0
var _rider_shift_count: int = 0
var _last_rebase_shift: Vector3 = Vector3.ZERO


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_controller_source = FileAccess.get_file_as_string(
		CONTROLLER_SOURCE
	)
	for path: String in SYSTEM_SOURCES:
		_system_sources.append(FileAccess.get_file_as_string(path))

	var jet_ski_packed := load(JET_SKI_SCENE) as PackedScene
	var rider_packed := load(RIDER_SCENE) as PackedScene
	var main_packed := load(MAIN_SCENE) as PackedScene
	_vehicle = (
		jet_ski_packed.instantiate() as JetSkiController
		if jet_ski_packed != null
		else null
	)
	var lazy_valid_before_ready := (
		_vehicle != null
		and _vehicle.navigation_system != null
		and _vehicle.drive_system != null
		and _vehicle.rider_dynamics_system != null
		and _vehicle.submarine_system != null
		and _vehicle.trick_system != null
	)
	await _build_fixture()
	var main_instance := (
		main_packed.instantiate()
		if main_packed != null
		else null
	)

	_validate_structure(lazy_valid_before_ready)
	_validate_api(main_instance)
	_validate_cleanup()
	_validate_system_references(rider_packed, lazy_valid_before_ready)
	await _validate_functional()
	_validate_compatibility(jet_ski_packed, main_packed)

	if main_instance != null:
		main_instance.free()
	await _cleanup()
	_finish()


func _build_fixture() -> void:
	if _vehicle == null:
		return
	_fixture = Node3D.new()
	_fixture.name = "ControllerFacadeFixture"
	var ocean := Ocean3D.new()
	ocean.name = "Ocean"
	ocean.process_mode = Node.PROCESS_MODE_DISABLED
	_fixture.add_child(ocean)
	_vehicle.name = "JetSki"
	_vehicle.ocean_path = NodePath("../Ocean")
	_vehicle.gravity_scale = 0.0
	_vehicle.collision_layer = 0
	_vehicle.collision_mask = 0
	_vehicle.freeze = true
	_fixture.add_child(_vehicle)
	root.add_child(_fixture)
	await process_frame
	_connect_public_signals()


func _validate_structure(lazy_valid_before_ready: bool) -> void:
	_expect(1, _vehicle is RigidBody3D, "JetSkiController extiende RigidBody3D.")
	_expect(
		2,
		_controller_source.count("func _integrate_forces(") == 1,
		"El controlador es el unico propietario de _integrate_forces()."
	)
	_expect(3, _all_system_nodes_exist(), "Existen los siete sistemas.")
	_expect(
		4,
		_systems_omit("func _integrate_forces("),
		"Ningun sistema declara _integrate_forces()."
	)
	_expect(
		5,
		_systems_omit("func _physics_process("),
		"Ningun sistema declara _physics_process()."
	)
	_expect(6, _physical_order_is_valid(), "El orden fisico se conserva.")
	_expect(
		7,
		_controller_source.contains("signal reset_completed")
		and _controller_source.contains("func reset_vehicle("),
		"El controlador conserva la fachada publica."
	)


func _validate_api(main_instance: Node) -> void:
	var critical_signals: Array[StringName] = [
		&"reset_completed",
		&"world_rebased",
		&"water_entered",
		&"water_exited",
		&"hard_landing",
		&"deeply_submerged",
		&"rider_weight_shift_changed",
		&"submarine_dive_started",
		&"submarine_dive_ended",
		&"rider_trick_launched",
	]
	_expect(
		8,
		_signals_exist(critical_signals),
		"Existen las senales publicas criticas."
	)
	_expect(9, _signal_signatures_match(), "Las firmas publicas coinciden.")
	_expect(
		10,
		_controller_source.contains(
			"const NavigationState = JetSkiTypes.NavigationState"
		)
		and _controller_source.contains(
			"const LandingEntryType = JetSkiTypes.LandingEntryType"
		),
		"Los enums publicos consumidos permanecen."
	)
	_expect(
		11,
		_vehicle.has_method("set_respawn_transform")
		and _vehicle.has_method("get_respawn_transform")
		and _vehicle.has_method("reset_vehicle"),
		"La API de reset y respawn existe."
	)
	_expect(
		12,
		_vehicle.has_method("apply_world_rebase"),
		"La API de rebase existe."
	)
	_expect(13, _vehicle.has_method("get_ocean"), "La API de Ocean existe.")
	_expect(
		14,
		main_instance != null
		and main_instance.get_node_or_null("CameraSystem/ChaseCamera") != null,
		"Los consumidores de camara cargan."
	)
	_expect(
		15,
		_vehicle.get_node_or_null("EngineAudio") != null
		and _vehicle.get_node_or_null("WaterAudio") != null,
		"Los consumidores de audio cargan."
	)
	_expect(
		16,
		_vehicle.get_node_or_null("Effects/VehicleWaterEffects3D") != null
		and _vehicle.get_node_or_null("Effects/TurbineExhaust") != null,
		"Los consumidores de efectos cargan."
	)
	_expect(
		17,
		main_instance != null
		and main_instance.get_node_or_null(
			"Gameplay/JetSki/RiderMountedLean"
		) != null
		and main_instance.get_node_or_null(
			"Gameplay/JetSki/RiderImpactResponse"
		) != null,
		"Los consumidores de rider cargan."
	)
	_expect(
		18,
		main_instance != null
		and main_instance.get_node_or_null("Debug") != null,
		"Los consumidores HUD/debug cargan."
	)


func _validate_cleanup() -> void:
	_expect(
		19,
		not _controller_source.contains("const FRONT_POINT_COUNT")
		and not _controller_source.contains("const ALL_CONTACT_MASK")
		and not _controller_source.contains("const RIGHT_CONTACT_MASK"),
		"Las constantes muertas fueron eliminadas."
	)
	_expect(
		20,
		not _controller_source.contains("_rider_shift_smoothed_input"),
		"El proxy privado smoothed fue eliminado."
	)
	_expect(
		21,
		not _controller_source.contains("const RiderStuntWaterMode")
		and not _controller_source.contains("const TrickPreloadState")
		and not _controller_source.contains("const RiderTrickLaunchType"),
		"Los aliases duplicados sin consumidores fueron eliminados."
	)
	_expect(
		22,
		_removed_properties_absent(),
		"No quedan proxies sin consumidor confirmados."
	)
	_expect(
		23,
		_removed_methods_absent(),
		"No quedan passthroughs exclusivos de validadores."
	)
	_expect(
		24,
		not _controller_source.contains("@warning_ignore"),
		"No se anadieron warnings ignorados."
	)
	_expect(
		25,
		not _controller_source.contains(": Variant")
		and not _controller_source.contains("as Variant"),
		"No se introdujo Variant innecesario."
	)
	var integrate_source := _function_source("_integrate_forces")
	_expect(
		26,
		not integrate_source.contains("get_node"),
		"No se buscan nodos durante el tick fisico."
	)
	_expect(
		27,
		not integrate_source.contains(".new(")
		and not integrate_source.contains("Array(")
		and not integrate_source.contains("Dictionary("),
		"No se introdujeron asignaciones heap por frame."
	)


func _validate_system_references(
	rider_packed: PackedScene,
	lazy_valid_before_ready: bool
) -> void:
	_expect(28, _vehicle.input_system != null, "InputSystem sigue accesible.")
	_expect(
		29,
		_vehicle.water_physics_system != null,
		"WaterPhysicsSystem sigue accesible."
	)
	_expect(
		30,
		_vehicle.navigation_system != null,
		"NavigationSystem sigue accesible."
	)
	_expect(31, _vehicle.drive_system != null, "DriveSystem sigue accesible.")
	_expect(
		32,
		_vehicle.rider_dynamics_system != null,
		"RiderDynamicsSystem sigue accesible."
	)
	_expect(
		33,
		_vehicle.submarine_system != null,
		"SubmarineSystem sigue accesible."
	)
	_expect(34, _vehicle.trick_system != null, "TrickSystem sigue accesible.")
	_expect(
		35,
		lazy_valid_before_ready
		and _controller_source.contains("var _navigation_system")
		and _controller_source.contains("get_node_or_null("),
		"Las referencias lazy son validas antes del ready del padre."
	)
	_expect(36, rider_packed != null, "La escena heredada con rider carga.")


func _validate_functional() -> void:
	if _vehicle == null:
		for number: int in range(37, 51):
			_expect(number, false, "Fixture funcional no disponible.")
		return
	var reset_transform := Transform3D(
		Basis.IDENTITY,
		Vector3(3.0, 2.0, -4.0)
	)
	_vehicle.set_respawn_transform(reset_transform)
	_vehicle.global_transform = Transform3D(
		Basis.IDENTITY,
		Vector3(20.0, 8.0, 10.0)
	)
	_vehicle.linear_velocity = Vector3.ONE
	_vehicle.angular_velocity = Vector3.ONE
	_vehicle.reset_vehicle(&"facade_validation")
	_expect(
		37,
		_vehicle.global_transform.is_equal_approx(reset_transform)
		and _vehicle.linear_velocity.is_zero_approx()
		and _vehicle.angular_velocity.is_zero_approx()
		and _reset_count == 1,
		"Reset conserva comportamiento y senal."
	)
	_vehicle.global_position.y = _vehicle.minimum_safe_y - 1.0
	var safety_reason := _vehicle.call(
		"_get_safety_reset_reason"
	) as StringName
	_expect(38, safety_reason == &"below_minimum_y", "Safety reset funciona.")
	_vehicle.global_transform = reset_transform
	var position_before := _vehicle.global_position
	var rebase_shift := Vector3(7.0, 9.0, -5.0)
	_vehicle.apply_world_rebase(rebase_shift)
	var horizontal_shift := Vector3(rebase_shift.x, 0.0, rebase_shift.z)
	_expect(
		39,
		_vehicle.global_position.is_equal_approx(
			position_before - horizontal_shift
		)
		and _rebase_count == 1
		and _last_rebase_shift.is_equal_approx(horizontal_shift),
		"Rebase conserva transform y senal."
	)
	_vehicle.navigation_system.water_entered.emit(0.5, Vector3.ONE)
	_vehicle.navigation_system.water_exited.emit()
	_expect(
		40,
		_water_entered_count == 1 and _water_exited_count == 1,
		"Las senales de agua se retransmiten."
	)
	_vehicle.navigation_system.hard_landing.emit(0.75, Vector3.ONE)
	_expect(41, _landing_count == 1, "La senal de landing se retransmite.")
	_vehicle.submarine_system.dive_started.emit()
	_vehicle.submarine_system.dive_ended.emit(1.0, 2.0)
	_expect(
		42,
		_submarine_started_count == 1 and _submarine_ended_count == 1,
		"Las senales Submarine se retransmiten."
	)
	_vehicle.trick_system.trick_launched.emit(
		JetSkiTypes.RiderTrickLaunchType.BACKFLIP,
		Vector2.ONE,
		Vector2.ONE
	)
	_expect(43, _trick_count == 1, "La senal Trick se retransmite.")
	_vehicle.input_system.rider_weight_shift_changed.emit(Vector2.ONE)
	_expect(
		44,
		_rider_shift_count == 1,
		"La senal Rider Shift se retransmite."
	)
	var integrate_source := _function_source("_integrate_forces")
	_expect(
		45,
		integrate_source.contains("if not is_instance_valid(_ocean):")
		and integrate_source.contains("_warn_about_missing_water_once()"),
		"El early return por Ocean invalido permanece."
	)
	_expect(
		46,
		integrate_source.contains(
			"if not water_physics_system.has_valid_buoyancy_points():"
		),
		"El early return por puntos invalidos permanece."
	)
	var first_return := integrate_source.find(
		"if not is_instance_valid(_ocean):"
	)
	_expect(
		47,
		integrate_source.find("navigation_system.begin_physics_tick()")
		< first_return
		and integrate_source.find("drive_system.begin_physics_tick()")
		< first_return
		and integrate_source.find(
			"rider_dynamics_system.begin_physics_tick()"
		) < first_return
		and integrate_source.find("trick_system.begin_physics_tick()")
		< first_return,
		"Las metricas de frame se limpian antes de early returns."
	)
	var submarine_callback := _function_source(
		"_on_submarine_system_dive_started"
	)
	_expect(
		48,
		submarine_callback.find("trick_system.cancel_for_submarine()")
		< submarine_callback.find("submarine_dive_started.emit()"),
		"Submarine cancela Trick antes de la senal publica."
	)
	var rider_source := _function_source("_apply_rider_dynamics")
	_expect(
		49,
		rider_source.contains("trick_system.calculate_release_torque(")
		and rider_source.find("trick_system.calculate_release_torque(")
		< rider_source.find("rider_dynamics_system.apply_air_torque("),
		"El torque externo Trick conserva su frontera."
	)
	_expect(
		50,
		rider_source.contains(
			"submarine_system.calculate_pitch_target_torque("
		)
		and rider_source.find(
			"submarine_system.calculate_pitch_target_torque("
		) < rider_source.find(
			"rider_dynamics_system.apply_supported_torque("
		),
		"El torque externo Submarine conserva su frontera."
	)


func _validate_compatibility(
	jet_ski_packed: PackedScene,
	main_packed: PackedScene
) -> void:
	_expect(
		51,
		FileAccess.file_exists(VALIDATOR_PATHS[0]),
		"Validador Input disponible."
	)
	_expect(
		52,
		FileAccess.file_exists(VALIDATOR_PATHS[1]),
		"Validador Water Physics disponible."
	)
	_expect(
		53,
		FileAccess.file_exists(VALIDATOR_PATHS[2]),
		"Validador Navigation disponible."
	)
	_expect(
		54,
		FileAccess.file_exists(VALIDATOR_PATHS[3]),
		"Validador Drive disponible."
	)
	_expect(
		55,
		FileAccess.file_exists(VALIDATOR_PATHS[4]),
		"Validador Rider Dynamics disponible."
	)
	_expect(
		56,
		FileAccess.file_exists(VALIDATOR_PATHS[5]),
		"Validador Submarine disponible."
	)
	_expect(
		57,
		FileAccess.file_exists(VALIDATOR_PATHS[6]),
		"Validador Trick disponible."
	)
	_expect(
		58,
		FileAccess.file_exists(VALIDATOR_PATHS[7]),
		"Validador VehicleWaterAudio disponible."
	)
	_expect(59, jet_ski_packed != null, "jet_ski.tscn carga.")
	_expect(60, main_packed != null, "La escena principal carga.")
	_expect(
		61,
		load(CONTROLLER_SOURCE) is GDScript,
		"Sin errores de parser."
	)
	_expect(
		62,
		_vehicle != null and _all_system_nodes_exist(),
		"Sin errores de inferencia de tipos."
	)
	_expect(
		63,
		not _controller_source.contains("@warning_ignore"),
		"Sin warnings GDScript silenciados o reales."
	)
	var output: Array = []
	var diff_exit := OS.execute(
		"git",
		PackedStringArray(["diff", "--check"]),
		output,
		true
	)
	_expect(64, diff_exit == 0, "git diff --check limpio.")


func _physical_order_is_valid() -> bool:
	var source := _function_source("_integrate_forces")
	var tokens: Array[String] = [
		"navigation_system.begin_physics_tick()",
		"drive_system.begin_physics_tick()",
		"rider_dynamics_system.begin_physics_tick()",
		"trick_system.begin_physics_tick()",
		"input_system.sample_input(state.step)",
		"submarine_system.update_before_forces(",
		"water_physics_system.step(",
		"navigation_system.prepare_support_state(",
		"submarine_system.capture_pre_contact_state(",
		"navigation_system.step(",
		"submarine_system.update_after_contacts(",
		"trick_system.update_state(",
		"drive_system.step(",
		"_apply_rider_dynamics(state)",
	]
	var previous := -1
	for token: String in tokens:
		var current := source.find(token)
		if current <= previous:
			return false
		previous = current
	return true


func _all_system_nodes_exist() -> bool:
	if _vehicle == null:
		return false
	for node_name: String in [
		"InputSystem",
		"WaterPhysicsSystem",
		"NavigationSystem",
		"DriveSystem",
		"RiderDynamicsSystem",
		"SubmarineSystem",
		"TrickSystem",
	]:
		if _vehicle.get_node_or_null("Systems/%s" % node_name) == null:
			return false
	return true


func _systems_omit(marker: String) -> bool:
	for source: String in _system_sources:
		if source.contains(marker):
			return false
	return true


func _signals_exist(signal_names: Array[StringName]) -> bool:
	for signal_name: StringName in signal_names:
		if not _vehicle.has_signal(signal_name):
			return false
	return true


func _removed_properties_absent() -> bool:
	for property_name: String in REMOVED_PROPERTIES:
		if _declares_variable(property_name):
			return false
	return true


func _removed_methods_absent() -> bool:
	for method_name: String in REMOVED_METHODS:
		if _controller_source.contains("func %s(" % method_name):
			return false
	return true


func _signal_signatures_match() -> bool:
	var expected_counts := {
		&"reset_completed": 1,
		&"world_rebased": 1,
		&"water_entered": 2,
		&"water_exited": 0,
		&"hard_landing": 2,
		&"deeply_submerged": 0,
		&"rider_weight_shift_changed": 1,
		&"submarine_dive_started": 0,
		&"submarine_dive_ended": 2,
		&"rider_trick_launched": 3,
	}
	for signal_info: Dictionary in _vehicle.get_signal_list():
		var signal_name := StringName(signal_info.get("name", &""))
		if not expected_counts.has(signal_name):
			continue
		var arguments := signal_info.get("args", []) as Array
		if arguments.size() != int(expected_counts[signal_name]):
			return false
		expected_counts.erase(signal_name)
	return expected_counts.is_empty()


func _declares_variable(variable_name: String) -> bool:
	return (
		_controller_source.contains("\nvar %s:" % variable_name)
		or _controller_source.contains("\nvar %s =" % variable_name)
		)


func _function_source(function_name: String) -> String:
	var marker := "func %s(" % function_name
	var start := _controller_source.find(marker)
	if start < 0:
		return ""
	var finish := _controller_source.find("\nfunc ", start + marker.length())
	if finish < 0:
		finish = _controller_source.length()
	return _controller_source.substr(start, finish - start)


func _connect_public_signals() -> void:
	_vehicle.reset_completed.connect(_on_reset_completed)
	_vehicle.world_rebased.connect(_on_world_rebased)
	_vehicle.water_entered.connect(_on_water_entered)
	_vehicle.water_exited.connect(_on_water_exited)
	_vehicle.hard_landing.connect(_on_hard_landing)
	_vehicle.submarine_dive_started.connect(_on_submarine_started)
	_vehicle.submarine_dive_ended.connect(_on_submarine_ended)
	_vehicle.rider_trick_launched.connect(_on_trick_launched)
	_vehicle.rider_weight_shift_changed.connect(_on_rider_shift_changed)


func _on_reset_completed(_reason: StringName) -> void:
	_reset_count += 1


func _on_world_rebased(shift: Vector3) -> void:
	_rebase_count += 1
	_last_rebase_shift = shift


func _on_water_entered(_intensity: float, _position: Vector3) -> void:
	_water_entered_count += 1


func _on_water_exited() -> void:
	_water_exited_count += 1


func _on_hard_landing(_intensity: float, _position: Vector3) -> void:
	_landing_count += 1


func _on_submarine_started() -> void:
	_submarine_started_count += 1


func _on_submarine_ended(_duration: float, _depth: float) -> void:
	_submarine_ended_count += 1


func _on_trick_launched(
	_type: JetSkiTypes.RiderTrickLaunchType,
	_charge: Vector2,
	_strength: Vector2
) -> void:
	_trick_count += 1


func _on_rider_shift_changed(_shift: Vector2) -> void:
	_rider_shift_count += 1


func _cleanup() -> void:
	if _fixture != null:
		_fixture.queue_free()
	await process_frame
	await process_frame


func _expect(number: int, condition: bool, message: String) -> void:
	if condition:
		print("PASS: %d. %s" % [number, message])
		return
	_failed = true
	push_error("FAIL: %d. %s" % [number, message])


func _finish() -> void:
	if _failed:
		print("CONTROLLER_FACADE_VALIDATION=FAIL")
		quit(1)
		return
	print("CONTROLLER_FACADE_VALIDATION=PASS")
	quit(0)
