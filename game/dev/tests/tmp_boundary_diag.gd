extends SceneTree

const PARADISE_SCENE := "res://levels/paradise_island/paradise_island.tscn"

var _jet: JetSkiController
var _wipeout_system: JetSkiWipeoutSystem
var _controller: BoundaryWipeoutController3D
var _boundary_wave: EventWave3D


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var scene := (load(PARADISE_SCENE) as PackedScene).instantiate() as Node3D
	root.add_child(scene)
	for i in 30:
		await physics_frame
	_jet = scene.get_node("Gameplay/JetSki") as JetSkiController
	_wipeout_system = _jet.get_node("Systems/WipeoutSystem") as JetSkiWipeoutSystem
	_controller = scene.get_node("Gameplay/BoundaryWipeoutController") as BoundaryWipeoutController3D
	_boundary_wave = scene.get_node("Gameplay/BoundaryWipeoutController/BoundaryEventWave") as EventWave3D
	var handoff := _wipeout_system.get_node_or_null("RiderRagdollHandoff")
	print("HANDOFF_NODE=%s" % handoff)
	_jet.global_position = Vector3(1010.0, 2.0, 0.0)
	_jet.linear_velocity = Vector3.ZERO
	_jet.angular_velocity = Vector3.ZERO
	_jet.reset_physics_interpolation()
	for frame in 1500:
		await physics_frame
		if frame % 60 == 0 or frame < 5:
			print(
				"t=%05.2f wipeout_state=%s controller_state=%s wave_active=%s pos=(%.1f, %.1f, %.1f) linvel=%.2f frozen=%s" % [
					frame / 60.0,
					_wipeout_system.get_state(),
					_controller.get_state(),
					_boundary_wave.active,
					_jet.global_position.x,
					_jet.global_position.y,
					_jet.global_position.z,
					_jet.linear_velocity.length(),
					_jet.freeze,
				]
			)
	quit(0)
