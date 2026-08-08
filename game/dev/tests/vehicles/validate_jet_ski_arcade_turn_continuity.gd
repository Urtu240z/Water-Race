extends SceneTree

class ControlledOcean:
	extends Ocean3D

	func sample_height(_world_position: Vector3) -> float:
		return 0.0

	func sample_normal(_world_position: Vector3) -> Vector3:
		return Vector3.UP

	func sample_water_velocity(_world_position: Vector3) -> Vector3:
		return Vector3.ZERO


const JET_SKI_SCENE := "res://gameplay/vehicles/jet_ski_01/jet_ski_01.tscn"
const EPSILON: float = 0.0001

var _failed: bool = false
var _fixture: Node3D
var _vehicle: JetSkiController
var _handling: JetSkiArcadeHandling


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var packed := load(JET_SKI_SCENE) as PackedScene
	_expect(packed != null, "La escena JetSki carga.")
	if packed == null:
		_finish()
		return
	_fixture = Node3D.new()
	var ocean := ControlledOcean.new()
	ocean.name = "TestOcean"
	ocean.process_mode = Node.PROCESS_MODE_DISABLED
	_fixture.add_child(ocean)
	_vehicle = packed.instantiate() as JetSkiController
	_vehicle.ocean_path = NodePath("../TestOcean")
	_vehicle.gravity_scale = 0.0
	_vehicle.collision_layer = 0
	_vehicle.collision_mask = 0
	_fixture.add_child(_vehicle)
	root.add_child(_fixture)
	await process_frame
	_handling = _vehicle.get_node_or_null("ArcadeHandling") as JetSkiArcadeHandling

	_validate_inspector_configuration()
	_validate_contact_memory()
	_validate_long_air_release()
	_validate_landing_blend()
	_validate_independent_contact_toggle()
	_validate_drive_input_routing()
	_validate_telemetry()
	await _validate_opt_in_physics_route()

	_fixture.queue_free()
	await process_frame
	await process_frame
	_finish()


func _validate_inspector_configuration() -> void:
	_expect(_handling != null, "ArcadeHandling sigue separado del controlador.")
	if _handling == null:
		return
	_expect(
		not _vehicle.use_arcade_turn_continuity,
		"El toggle maestro conserva legacy por defecto."
	)
	_expect(
		_handling.use_effective_water_contact
		and _handling.use_yaw_rate_controller
		and _handling.use_progressive_lateral_grip
		and _handling.use_landing_blend,
		"Las cuatro ayudas A/B están expuestas y activas dentro del modo opt-in."
	)
	_expect(
		_close(_handling.water_contact_release_time, 0.22)
		and _close(_handling.micro_air_steering_ratio, 0.30)
		and _close(_handling.landing_blend_time, 0.14),
		"Los valores iniciales solicitados están configurados."
	)


func _validate_contact_memory() -> void:
	if _handling == null:
		return
	_handling.reset_turn_continuity_state()
	_handling.water_contact_ratio = 0.25
	_handling._update_contact_memory(0.06)
	var wet_contact := _handling.effective_water_contact
	_handling.water_contact_ratio = 0.0
	_handling._update_contact_memory(0.05)
	_expect(
		_close(wet_contact, 1.0)
		and _handling.effective_water_contact > 0.7
		and _close(_handling.airborne_time, 0.05),
		"Un solo punto de agua eleva contacto efectivo y el microbote lo conserva."
	)


func _validate_long_air_release() -> void:
	if _handling == null:
		return
	_handling._update_contact_memory(0.17)
	_expect(
		_close(_handling.effective_water_contact, 0.0)
		and _close(_handling.airborne_time, 0.22),
		"Tras el margen configurado el salto pierde la asistencia acuática."
	)


func _validate_landing_blend() -> void:
	if _handling == null:
		return
	_handling.reset_turn_continuity_state()
	_handling.water_contact_ratio = 0.0
	_handling._update_landing_blend(0.05)
	_handling._update_contact_memory(0.05)
	_handling.water_contact_ratio = 1.0
	_handling._update_landing_blend(0.01)
	_expect(
		_handling.landing_timer > 0.0
		and _handling.landing_timer < _handling.landing_blend_time
		and _handling.landing_blend > 0.0
		and _handling.landing_blend < 1.0,
		"AIR a WATER inicia una recuperación progresiva corta."
	)


func _validate_independent_contact_toggle() -> void:
	if _handling == null:
		return
	_handling.reset_turn_continuity_state()
	_handling.use_effective_water_contact = false
	_handling.water_contact_ratio = 1.0
	_handling._update_contact_memory(0.01)
	_handling.water_contact_ratio = 0.0
	_handling._update_contact_memory(0.01)
	_expect(
		_close(_handling.effective_water_contact, 0.0),
		"El toggle de memoria restaura contacto instantáneo para A/B."
	)
	_handling.use_effective_water_contact = true


func _validate_drive_input_routing() -> void:
	if _handling == null:
		return
	var input_state := JetSkiInputState.new()
	input_state.throttle = 0.75
	input_state.brake = 0.10
	input_state.steering = -0.60
	_handling.use_yaw_rate_controller = true
	var yaw_rate_input := _handling.get_drive_input(input_state)
	var yaw_controller_routing := (
		_close(yaw_rate_input.throttle, input_state.throttle)
		and _close(yaw_rate_input.brake, input_state.brake)
		and _close(yaw_rate_input.steering, 0.0)
	)
	_handling.use_yaw_rate_controller = false
	var legacy_steering_input := _handling.get_drive_input(input_state)
	_expect(
		yaw_controller_routing
		and _close(legacy_steering_input.steering, input_state.steering),
		"Solo el yaw-rate controller neutraliza el steering legacy del propulsor."
	)
	_handling.use_yaw_rate_controller = true


func _validate_telemetry() -> void:
	if _handling == null:
		return
	var status := _vehicle.get_turn_continuity_debug_status()
	var required_keys: Array[StringName] = [
		&"water_contact_ratio",
		&"effective_water_contact",
		&"airborne_time",
		&"steering_input",
		&"desired_yaw_rate",
		&"actual_yaw_rate",
		&"lateral_speed",
		&"landing_blend",
		&"landing_timer",
	]
	var has_all_keys := true
	for key in required_keys:
		has_all_keys = has_all_keys and status.has(key)
	_expect(has_all_keys, "La telemetría mínima está disponible en una sola API.")


func _validate_opt_in_physics_route() -> void:
	if _handling == null:
		return
	_handling.reset_turn_continuity_state()
	_vehicle.use_arcade_turn_continuity = true
	Input.action_press(&"throttle", 0.5)
	Input.action_press(&"steer_right", 0.5)
	for _index in 5:
		await physics_frame
	Input.action_release(&"throttle")
	Input.action_release(&"steer_right")
	_expect(
		_handling.effective_water_contact > 0.0
		and _handling.desired_yaw_rate < 0.0
		and is_finite(_handling.actual_yaw_rate)
		and is_zero_approx(_vehicle.drive_system.state.steering_angle_degrees),
		"La ruta opt-in ejecuta yaw-rate y evita acumular steering del propulsor."
	)
	_vehicle.use_arcade_turn_continuity = false


func _close(first: float, second: float) -> bool:
	return absf(first - second) <= EPSILON


func _expect(condition: bool, message: String) -> void:
	if condition:
		print("PASS: %s" % message)
		return
	_failed = true
	push_error("FAIL: %s" % message)


func _finish() -> void:
	if _failed:
		print("JET_SKI_ARCADE_TURN_CONTINUITY_VALIDATION=FAIL")
		quit(1)
		return
	print("JET_SKI_ARCADE_TURN_CONTINUITY_VALIDATION=PASS")
	quit(0)
