extends Node3D


@onready var fallen_rider: FallenRider3D = $FallenRider3D

var started := false


func _ready() -> void:
	print("")
	print("FALLEN RIDER TEST")
	print("SPACE = start ragdoll")
	print("R = reload/reset")
	print("1 = BOT")
	print("2 = RIDER 01")
	print("3 = RIDER 02")
	print("4 = RIDER 03")
	print("5 = RIDER 04")
	print("6 = RIDER 05")
	print("")


func _unhandled_input(event: InputEvent) -> void:
	if event is not InputEventKey:
		return

	var key_event := event as InputEventKey

	if not key_event.pressed or key_event.echo:
		return

	match key_event.keycode:
		KEY_SPACE:
			_start_ragdoll()

		KEY_R:
			get_tree().reload_current_scene()

		KEY_1:
			_set_skin(RiderRig.RiderSkin.RIDER_BOT)

		KEY_2:
			_set_skin(RiderRig.RiderSkin.RIDER_01)

		KEY_3:
			_set_skin(RiderRig.RiderSkin.RIDER_02)

		KEY_4:
			_set_skin(RiderRig.RiderSkin.RIDER_03)

		KEY_5:
			_set_skin(RiderRig.RiderSkin.RIDER_04)

		KEY_6:
			_set_skin(RiderRig.RiderSkin.RIDER_05)


func _start_ragdoll() -> void:
	if started:
		return

	started = true

	print("Starting ragdoll...")

	fallen_rider.start_simulation()


func _set_skin(skin: RiderRig.RiderSkin) -> void:
	if started:
		print("Reload with R before changing rider skin.")
		return

	fallen_rider.set_rider_skin(skin)

	var skin_id := RiderRig.get_rider_skin_id(int(skin))
	print("Rider skin: ", skin_id)
