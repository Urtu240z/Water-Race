class_name JetSkiWipeoutSystem
extends Node

signal wipeout_started(context: WipeoutContext)
signal rider_fallen(context: WipeoutContext)
signal recovery_ready(context: WipeoutContext)
signal recovery_started(context: WipeoutContext)
signal recovery_completed(context: WipeoutContext, reason: StringName)
signal wipeout_failed(context: WipeoutContext, reason: StringName)

enum State {
	MOUNTED,
	HANDOFF_PENDING,
	FALLEN,
	RECOVERY_READY,
	RECOVERING,
}

@export_node_path("JetSkiController") var vehicle_path: NodePath
@export_node_path("RiderRagdollHandoff") var handoff_path: NodePath
@export_range(0.0, 30.0, 0.1, "suffix:s") var minimum_fallen_duration := 2.0
@export var auto_recover_when_ready := true

var _vehicle: JetSkiController
var _handoff: RiderRagdollHandoff
var _state := State.MOUNTED
var _context: WipeoutContext
var _fallen_elapsed := 0.0


func _ready() -> void:
	_vehicle = get_node_or_null(vehicle_path) as JetSkiController
	_handoff = get_node_or_null(handoff_path) as RiderRagdollHandoff
	if _vehicle == null or _handoff == null:
		push_error("JetSkiWipeoutSystem requires valid vehicle and handoff paths.")
		return
	_handoff.handoff_completed.connect(_on_handoff_completed)
	_handoff.handoff_failed.connect(_on_handoff_failed)
	if not _vehicle.reset_completed.is_connected(_on_vehicle_reset_completed):
		_vehicle.reset_completed.connect(_on_vehicle_reset_completed)


func request_wipeout(context: WipeoutContext) -> bool:
	if (
		_state != State.MOUNTED
		or context == null
		or _vehicle == null
		or _handoff == null
	):
		return false
	if not _handoff.request_handoff(
		context.incident_impulse,
		_vehicle.get_water_provider()
	):
		return false
	_context = context
	_state = State.HANDOFF_PENDING
	_vehicle.clear_wipeout_control_state()
	wipeout_started.emit(_context)
	return true


func is_wipeout_active() -> bool:
	return _state != State.MOUNTED


func is_vehicle_control_locked() -> bool:
	return is_wipeout_active()


func request_recovery() -> bool:
	if _state != State.RECOVERY_READY or _vehicle == null:
		return false
	_state = State.RECOVERING
	recovery_started.emit(_context)
	if _vehicle.water_recovery_enabled:
		_vehicle.recover_vehicle()
	else:
		_vehicle.reset_vehicle(&"wipeout_recovery")
	return true


func get_state() -> State:
	return _state


func _physics_process(delta: float) -> void:
	if _state != State.FALLEN:
		return
	_fallen_elapsed += maxf(delta, 0.0)
	if _fallen_elapsed < minimum_fallen_duration:
		return
	_state = State.RECOVERY_READY
	recovery_ready.emit(_context)
	if auto_recover_when_ready:
		request_recovery()


func _on_handoff_completed() -> void:
	if _state != State.HANDOFF_PENDING:
		return
	_state = State.FALLEN
	_fallen_elapsed = 0.0
	rider_fallen.emit(_context)


func _on_handoff_failed(reason: StringName) -> void:
	if _state != State.HANDOFF_PENDING:
		return
	var failed_context := _context
	_handoff.restore_mounted_state()
	_state = State.MOUNTED
	_context = null
	_fallen_elapsed = 0.0
	wipeout_failed.emit(failed_context, reason)


func _on_vehicle_reset_completed(reason: StringName) -> void:
	if _state == State.MOUNTED:
		return
	var completed_context := _context
	_handoff.restore_mounted_state()
	_context = null
	_fallen_elapsed = 0.0
	_state = State.MOUNTED
	recovery_completed.emit(completed_context, reason)
