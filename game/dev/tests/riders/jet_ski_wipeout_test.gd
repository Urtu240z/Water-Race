extends Node3D

const RELOAD_START_META := &"water_race_wipeout_test_reload_start_usec"
const RELOAD_COUNT_META := &"water_race_wipeout_test_reload_count"

@export_group("Ragdoll Launch Test")

@export_range(0.0, 500.0, 1.0)
var test_forward_impulse := 4.0

@export_range(0.0, 500.0, 1.0)
var test_up_impulse := 3.0

@onready var vehicle: JetSkiController = $JetSki


func _ready() -> void:
	var test_wipeout_system := vehicle.get_node_or_null("Systems/WipeoutSystem") as JetSkiWipeoutSystem
	if test_wipeout_system != null:
		test_wipeout_system.minimum_fallen_duration = 5.0
	print("SPACE: wipeout, zero impulse | I: wipeout, forward/up impulse | R: reload test fallback")
	print("Each wipeout recovers automatically; repeat SPACE or I without reloading.")
	var wipeout_system := vehicle.wipeout_system as JetSkiWipeoutSystem
	if wipeout_system != null:
		wipeout_system.recovery_completed.connect(_on_recovery_completed)
	if Engine.has_meta(RELOAD_START_META):
		var start_usec := int(Engine.get_meta(RELOAD_START_META))
		var elapsed_msec := (Time.get_ticks_usec() - start_usec) / 1000.0
		var reload_count := int(Engine.get_meta(RELOAD_COUNT_META, 0))
		print("WIPEOUT TEST RELOAD #%d: %.1f ms" % [reload_count, elapsed_msec])
		Engine.remove_meta(RELOAD_START_META)


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_accept"):
		print("Wipeout request accepted: %s" % vehicle.request_wipeout(
			WipeoutContext.new(&"test", Vector3.ZERO)
		))
	elif event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_I:
			var forward := -vehicle.global_transform.basis.z.normalized()
			var impulse := forward * test_forward_impulse + Vector3.UP * test_up_impulse
			print("Wipeout request accepted: %s" % vehicle.request_wipeout(
				WipeoutContext.new(&"test_impulse", impulse)
			))
		elif event.keycode == KEY_R:
			Engine.set_meta(RELOAD_START_META, Time.get_ticks_usec())
			Engine.set_meta(RELOAD_COUNT_META, int(Engine.get_meta(RELOAD_COUNT_META, 0)) + 1)
			get_tree().reload_current_scene()


func _on_recovery_completed(context: WipeoutContext, reason: StringName) -> void:
	print("Wipeout recovery completed: %s (%s)" % [context.reason, reason])
