extends Node3D

@onready var handoff: RiderRagdollHandoff = $JetSki/Systems/RiderRagdollHandoff

func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_accept"):
		handoff.request_handoff()
	elif event is InputEventKey and event.pressed and event.keycode == KEY_I:
		handoff.request_handoff(Vector3(0.0, 3.0, -4.0))
	elif event is InputEventKey and event.pressed and event.keycode == KEY_R:
		get_tree().reload_current_scene()
