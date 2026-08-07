@tool
class_name WaveComponent
extends Resource

const MIN_WAVELENGTH: float = 0.01

@export var direction: Vector2 = Vector2.RIGHT:
	set(value):
		if value.length_squared() <= 0.000001:
			direction = Vector2.RIGHT
			push_warning("WaveComponent received a zero direction; Vector2.RIGHT is used instead.")
		else:
			direction = value.normalized()
		emit_changed()

@export_range(0.0, 10.0, 0.01, "or_greater") var amplitude: float = 0.5:
	set(value):
		amplitude = maxf(value, 0.0)
		emit_changed()

@export_range(MIN_WAVELENGTH, 200.0, 0.01, "or_greater") var wavelength: float = 20.0:
	set(value):
		if value < MIN_WAVELENGTH:
			push_warning("WaveComponent wavelength was clamped to %s metres." % MIN_WAVELENGTH)
		wavelength = maxf(value, MIN_WAVELENGTH)
		emit_changed()

@export_range(0.0, 50.0, 0.01, "or_greater") var speed: float = 5.0:
	set(value):
		speed = maxf(value, 0.0)
		emit_changed()

@export_range(-TAU, TAU, 0.01, "or_less", "or_greater", "radians") var phase_offset: float = 0.0:
	set(value):
		phase_offset = value
		emit_changed()
