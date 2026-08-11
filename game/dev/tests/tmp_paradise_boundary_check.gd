extends SceneTree

const PARADISE_SCENE := "res://levels/paradise_island/paradise_island.tscn"
const CENTER := Vector2(200.0, 0.0)
const RADIUS := 800.0
const REARM_RADIUS := 750.0

const ARMED := BoundaryWipeoutController3D.State.ARMED
const WAVE_ACTIVE := BoundaryWipeoutController3D.State.WAVE_ACTIVE
const WAITING_FOR_RECOVERY := BoundaryWipeoutController3D.State.WAITING_FOR_RECOVERY
const WAITING_FOR_REARM := BoundaryWipeoutController3D.State.WAITING_FOR_REARM

var _failures: PackedStringArray = []
var _reasons: Array[StringName] = []
var _impulses: Array[Vector3] = []
var _state_trace: Array[int] = []

var _jet: JetSkiController
var _controller: BoundaryWipeoutController3D
var _boundary_wave: EventWave3D
var _test_wave: EventWave3D
var _wipeout_system: JetSkiWipeoutSystem
var _done := false
var _cycle_recovering := false


# Paradise uses manual recovery (auto_recover_when_ready=false): the rider stays
# down until the player presses the recover key. Emulate that input so the
# boundary loop can complete without modifying production behavior.
func _monitor_recovery() -> void:
	_jockey_for_recovery.call_deferred()

func _jockey_for_recovery() -> void:
	while not _done:
		if not _cycle_recovering and _wipeout_system.is_wipeout_active():
			while not _done and not _wipeout_system.is_wipeout_active():
				await physics_frame
			if _done:
				return
			# Wait until the wipeout is in a state that accepts recovery.
			while not _done:
				var ws := int(_wipeout_system.get_state())
				if ws == 2 or ws == 3:  # FALLEN / RECOVERY_READY
					_cycle_recovering = true
					_jockey_recover_once()
					break
				await physics_frame
		else:
			await physics_frame


func _jockey_recover_once() -> void:
	await _pump(2)
	_jet.request_wipeout_recovery()
	while not _done and _wipeout_system.is_wipeout_active():
		await physics_frame
	_cycle_recovering = false


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	print("=== PARADISE BOUNDARY TSUNAMI INTEGRATION HARNESS ===")
	var packed := load(PARADISE_SCENE) as PackedScene
	_expect(packed != null, "Paradise scene loads.")
	if packed == null:
		_finish()
		return
	var scene := packed.instantiate() as Node3D
	root.add_child(scene)
	await _pump(30)

	_jet = scene.get_node("Gameplay/JetSki") as JetSkiController
	_controller = scene.get_node(
		"Gameplay/BoundaryWipeoutController"
	) as BoundaryWipeoutController3D
	_boundary_wave = scene.get_node(
		"Gameplay/BoundaryWipeoutController/BoundaryEventWave"
	) as EventWave3D
	_test_wave = scene.get_node(
		"WaterIntegration/TestEventWave"
	) as EventWave3D
	_expect(
		_jet != null and _controller != null
		and _boundary_wave != null and _test_wave != null,
		"All boundary NodePaths resolve."
	)
	if _jet == null or _controller == null or _boundary_wave == null or _test_wave == null:
		_finish()
		return
	var wipeout_system := _jet.get_node("Systems/WipeoutSystem") as JetSkiWipeoutSystem
	wipeout_system.wipeout_started.connect(_on_wipeout_started)

	# --- A. INITIAL ---
	_expect(_controller.get_state() == ARMED, "A: controller starts ARMED.")
	_expect(not _boundary_wave.active, "A: BoundaryEventWave starts inactive.")
	_expect(not _test_wave.active, "A: TestEventWave starts inactive (auto_activate=false).")

	# --- B. INSIDE ---
	var spawn_offset := Vector2(
		_jet.global_position.x - CENTER.x,
		_jet.global_position.z - CENTER.y
	)
	_expect(spawn_offset.length() < RADIUS, "B: spawn is inside boundary (%.1f m)." % spawn_offset.length())
	await _pump(120)
	_expect(_controller.get_state() == ARMED, "B: no tsunami while inside.")
	_expect(_reasons.is_empty(), "B: no wipeout requests while inside.")
	_expect(not _boundary_wave.active, "B: boundary wave stays inactive while inside.")

	# --- C. CROSS BOUNDARY ---
	_teleport_vehicle(Vector3(CENTER.x + RADIUS + 10.0, 2.0, 0.0))
	_expect(
		await _wait_for_state(WAVE_ACTIVE, 60),
		"C: crossing boundary enters WAVE_ACTIVE."
	)
	_expect(_boundary_wave.active, "C: BoundaryEventWave activated.")
	_expect(
		_controller._previous_signed_distance > 50.0
		and _controller._previous_signed_distance < 70.0,
		"C: initial crest signed distance ~ +60 (%.2f)."
		% _controller._previous_signed_distance
	)
	_expect(_reasons.is_empty(), "C: no wipeout at violation start (player keeps control).")
	_expect(not _jet.is_wipeout_active(), "C: vehicle still mounted/controllable.")

	# --- D. APPROACH ---
	var distance_before := _controller._previous_signed_distance
	await _pump(30)
	_expect(
		_controller.get_state() == WAVE_ACTIVE
		and _controller._previous_signed_distance < distance_before - 5.0,
		"D: crest distance decreases over time (%.2f -> %.2f)."
		% [distance_before, _controller._previous_signed_distance]
	)

	# --- E. IMPACT ---
	_expect(
		await _wait_for_state(WAITING_FOR_RECOVERY, 300),
		"E: crest crossing reaches WAITING_FOR_RECOVERY."
	)
	_expect(
		_reasons.size() == 1 and _reasons[0] == &"boundary_tsunami",
		"E: exactly one boundary_tsunami wipeout request."
	)
	_expect(_jet.is_wipeout_active(), "E: vehicle wipeout active (rider ragdolling).")
	var expected_impulse := Vector3(-1.0, 0.0, 0.0) * 8.0 + Vector3.UP * 5.0
	_expect(
		_impulses.size() == 1 and _impulses[0].distance_to(expected_impulse) < 0.01,
		"E: wipeout impulse matches wave travel direction (%s)." % str(_impulses[0])
	)

	# --- F/G. RECOVERY + SAFE RETURN ---
	# Production minimum_fallen_duration is 15 s, so recovery needs a long budget.
	_expect(
		await _wait_for_state(WAITING_FOR_REARM, 1500),
		"F: reset_completed transitions to WAITING_FOR_REARM."
	)
	_expect(not _boundary_wave.active, "F: boundary wave deactivated after reset.")
	var recovery_offset := Vector2(
		_jet.global_position.x - CENTER.x,
		_jet.global_position.z - CENTER.y
	)
	_expect(
		recovery_offset.length() <= RADIUS,
		"G: recovery returns vehicle inside boundary (%.1f m)." % recovery_offset.length()
	)
	# Emulate the player driving back into the safe rearm zone.
	_teleport_vehicle(Vector3(597.0, 2.0, 464.0))
	_expect(
		await _wait_for_state(ARMED, 120),
		"G: radial rearm restores ARMED once safely inside."
	)

	# --- H. SECOND INCIDENT ---
	_teleport_vehicle(Vector3(CENTER.x + RADIUS + 10.0, 2.0, 0.0))
	_expect(
		await _wait_for_state(WAVE_ACTIVE, 60),
		"H: second crossing activates a second incident."
	)
	_expect(
		await _wait_for_state(WAITING_FOR_RECOVERY, 300),
		"H: second crest crossing triggers wipeout."
	)
	_expect(
		_reasons.size() == 2 and _reasons[1] == &"boundary_tsunami",
		"H: second boundary_tsunami request issued (EventWave reused)."
	)
	_expect(
		await _wait_for_state(WAITING_FOR_REARM, 1500),
		"H: cleanup after second incident."
	)
	_teleport_vehicle(Vector3(597.0, 2.0, 464.0))
	_expect(
		await _wait_for_state(ARMED, 120),
		"H: controller rearms after second incident."
	)

	# --- I. MANUAL EJECTION DURING APPROACH ---
	_teleport_vehicle(Vector3(CENTER.x + RADIUS + 10.0, 2.0, 0.0))
	_expect(
		await _wait_for_state(WAVE_ACTIVE, 60),
		"I: third incident started."
	)
	_expect(_jet.request_manual_ejection(), "I: manual ejection accepted during approach.")
	await _pump(3)
	_expect(
		_controller.get_state() == WAITING_FOR_RECOVERY,
		"I: controller yields to manual ejection."
	)
	_expect(
		_reasons.size() == 3 and _reasons[2] == &"manual_ejection",
		"I: manual_ejection is the only new request (no duplicate boundary_tsunami)."
	)
	_expect(
		await _wait_for_state(WAITING_FOR_REARM, 1500),
		"I: cleanup after manual ejection recovery."
	)
	_expect(not _boundary_wave.active, "I: boundary wave cleaned up after recovery.")
	_teleport_vehicle(Vector3(597.0, 2.0, 464.0))
	_expect(
		await _wait_for_state(ARMED, 120),
		"I: controller rearms after manual ejection recovery."
	)

	# --- J. NORMAL EVENTWAVE REGRESSION ---
	_expect(_test_wave.activate(), "J: TestEventWave activates manually.")
	await _pump(240)
	_expect(_test_wave.active, "J: TestEventWave remains active during regression window.")
	_expect(
		_controller.get_state() == ARMED,
		"J: normal EventWave does not engage boundary controller."
	)
	_expect(_reasons.size() == 3, "J: normal EventWave causes no wipeout requests.")
	_test_wave.deactivate()
	await _pump(5)
	_expect(not _test_wave.active, "J: TestEventWave deactivated cleanly.")

	_finish()


func _teleport_vehicle(position: Vector3) -> void:
	_jet.global_position = position
	_jet.linear_velocity = Vector3.ZERO
	_jet.angular_velocity = Vector3.ZERO
	_jet.reset_physics_interpolation()


func _pump(frames: int) -> void:
	for i in frames:
		_trace()
		await physics_frame


func _trace() -> void:
	if _controller == null:
		return
	var state := int(_controller.get_state())
	if _state_trace.is_empty() or _state_trace.back() != state:
		_state_trace.append(state)


func _wait_for_state(
	state: BoundaryWipeoutController3D.State,
	max_frames: int
) -> bool:
	for i in max_frames:
		_trace()
		if _controller.get_state() == state:
			return true
		await physics_frame
	_trace()
	return _controller.get_state() == state


func _on_wipeout_started(context: WipeoutContext) -> void:
	_reasons.append(context.reason)
	_impulses.append(context.incident_impulse)


func _finish() -> void:
	print("STATE_TRACE=%s" % str(_state_trace))
	print("WIPEOUT_REASONS=%s" % str(_reasons))
	print("PARADISE_BOUNDARY_STATUS=%s" % ("PASS" if _failures.is_empty() else "FAIL"))
	quit(0 if _failures.is_empty() else 1)


func _expect(condition: bool, message: String) -> void:
	print("%s: %s" % ["PASS" if condition else "FAIL", message])
	if not condition:
		_failures.append(message)
