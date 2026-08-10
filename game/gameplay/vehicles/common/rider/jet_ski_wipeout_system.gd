class_name JetSkiWipeoutSystem
extends Node

signal wipeout_started(context: WipeoutContext)
signal rider_fallen(context: WipeoutContext)
signal recovery_ready(context: WipeoutContext)
signal wipeout_failed(context: WipeoutContext, reason: StringName)

enum State {
	MOUNTED,
	HANDOFF_PENDING,
	FALLEN,
	RECOVERY_READY,
}

@export_node_path("JetSkiController") var vehicle_path: NodePath
@export_node_path("RiderRagdollHandoff") var handoff_path: NodePath
@export_range(0.0, 30.0, 0.1, "suffix:s") var minimum_fallen_duration := 2.0

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


func request_wipeout(context: WipeoutContext) -> bool:
	if (
		_state != State.MOUNTED
		or context == null
		or _vehicle == null
		or _handoff == null
	):
		return false
	if not _handoff.request_handoff(context.incident_impulse):
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
	_state = State.MOUNTED
	_context = null
	_fallen_elapsed = 0.0
	wipeout_failed.emit(failed_context, reason)
