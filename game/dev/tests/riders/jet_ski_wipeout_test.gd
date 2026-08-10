extends Node3D

const WipeoutContext = preload(
	"res://gameplay/vehicles/common/rider/wipeout_context.gd"
)

@onready var vehicle: JetSkiController = $JetSki


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_accept"):
		vehicle.request_wipeout(WipeoutContext.new(&"test", Vector3.ZERO))
	elif event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_I:
			vehicle.request_wipeout(
				WipeoutContext.new(&"test_impulse", Vector3(0.0, 3.0, -4.0))
			)
		elif event.keycode == KEY_R:
			get_tree().reload_current_scene()
