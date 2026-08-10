@tool
class_name EventWave3D
extends Node3D

const EventWaveProfile = preload("res://world/water/ocean/events/event_wave_profile.gd")

signal activated
signal deactivated
signal completed
signal activation_rejected

@export_node_path("Ocean3D") var ocean_path: NodePath
@export var profile: EventWaveProfile
@export var auto_activate := false
@export_range(0.0, 10.0, 0.01) var amplitude_multiplier := 1.0
@export_range(0.0, 10.0, 0.01) var speed_multiplier := 1.0
@export_range(0.0, 10.0, 0.01) var flow_multiplier := 1.0

var active := false
var activation_logical_origin := Vector2.ZERO
var activation_direction := Vector2.ZERO
var activation_simulation_time := 0.0
var _ocean: Ocean3D

func _ready() -> void:
	_resolve_ocean()
	if auto_activate and not Engine.is_editor_hint():
		call_deferred("activate")

func _exit_tree() -> void:
	deactivate(false)

func activate() -> bool:
	_resolve_ocean()
	if active or _ocean == null or profile == null:
		activation_rejected.emit()
		return false
	var forward := -global_basis.z
	var direction := Vector2(forward.x, forward.z)
	if not direction.is_finite() or direction.length_squared() <= 0.000001:
		push_warning("EventWave3D requires a non-degenerate XZ forward direction.")
		activation_rejected.emit()
		return false
	activation_logical_origin = _ocean.world_to_logical_xz(global_position)
	activation_direction = direction.normalized()
	activation_simulation_time = _ocean.get_simulation_time()
	if not _ocean.activate_event_wave(self, _event_parameters()):
		activation_rejected.emit()
		return false
	active = true
	activated.emit()
	return true

func deactivate(was_completed := false) -> void:
	if not active:
		return
	if is_instance_valid(_ocean):
		_ocean.deactivate_event_wave(self)
	active = false
	deactivated.emit()
	if was_completed:
		completed.emit()

func notify_event_wave_completed() -> void:
	deactivate(true)

func get_debug_status() -> Dictionary:
	return {"active": active, "origin": activation_logical_origin, "direction": activation_direction, "start_time": activation_simulation_time}

func _event_parameters() -> Dictionary:
	return {"origin": activation_logical_origin, "direction": activation_direction, "start": activation_simulation_time, "amplitude": profile.amplitude * amplitude_multiplier, "width": profile.width, "speed": profile.speed * speed_multiplier, "trough_amplitude": profile.trough_amplitude * amplitude_multiplier, "trough_width": profile.trough_width, "trough_offset": profile.trough_offset, "flow": profile.horizontal_flow * flow_multiplier, "fade_in": profile.fade_in_time, "lifetime": profile.lifetime, "fade_out": profile.fade_out_time}

func _resolve_ocean() -> void:
	if not ocean_path.is_empty():
		_ocean = get_node_or_null(ocean_path) as Ocean3D
	if _ocean == null:
		_ocean = get_tree().get_first_node_in_group(&"ocean_3d") as Ocean3D
