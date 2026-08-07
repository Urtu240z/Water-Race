class_name HangingLightSway3D
extends Node3D

@export_group("Pivot")
@export var pivot_offset_local: Vector3 = Vector3.ZERO

@export_group("Sway")
@export_range(0.0, 8.0, 0.1, "suffix:deg") var sway_x_degrees: float = 2.0
@export_range(0.0, 8.0, 0.1, "suffix:deg") var sway_z_degrees: float = 1.2
@export_range(0.05, 1.0, 0.01, "suffix:Hz") var sway_frequency_hz: float = 0.22
@export_range(0.1, 2.0, 0.01) var secondary_frequency_ratio: float = 0.73

var _elapsed_time: float = 0.0
var _rest_transform: Transform3D
var _pivot_position: Vector3


func _ready() -> void:
	_rest_transform = transform
	_pivot_position = _rest_transform * pivot_offset_local


func _process(delta: float) -> void:
	_elapsed_time += maxf(delta, 0.0)
	var phase := _elapsed_time * TAU * sway_frequency_hz
	var sway_rotation := Vector3(
		deg_to_rad(sway_x_degrees) * sin(phase),
		0.0,
		deg_to_rad(sway_z_degrees) * sin(
			phase * secondary_frequency_ratio
		)
	)
	var swayed_basis := (
		Basis.from_euler(sway_rotation) * _rest_transform.basis
	)
	transform = Transform3D(
		swayed_basis,
		_pivot_position - swayed_basis * pivot_offset_local
	)
