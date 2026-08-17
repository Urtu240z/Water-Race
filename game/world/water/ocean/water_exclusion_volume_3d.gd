@tool
class_name WaterExclusionVolume3D
extends Node3D

const OCEAN_GROUP := &"ocean_3d"
const REGISTRATION_RETRY_INTERVAL: float = 0.5
const MINIMUM_SIZE: float = 0.001

@export var enabled: bool = true:
	set(value):
		enabled = value
		_queue_ocean_update()
@export var size: Vector3 = Vector3(4.0, 2.0, 8.0):
	set(value):
		size = Vector3(
			maxf(value.x, MINIMUM_SIZE),
			maxf(value.y, MINIMUM_SIZE),
			maxf(value.z, MINIMUM_SIZE)
		)
		_queue_ocean_update()

var _registered_ocean: Node
var _registration_retry_elapsed: float = REGISTRATION_RETRY_INTERVAL


func _enter_tree() -> void:
	set_notify_transform(true)
	call_deferred(&"_register_with_ocean")


func _ready() -> void:
	set_process(true)


func _process(delta: float) -> void:
	if is_instance_valid(_registered_ocean):
		return
	_registration_retry_elapsed += maxf(delta, 0.0)
	if _registration_retry_elapsed < REGISTRATION_RETRY_INTERVAL:
		return
	_registration_retry_elapsed = 0.0
	_register_with_ocean()


func _exit_tree() -> void:
	if is_instance_valid(_registered_ocean):
		_registered_ocean.call(&"unregister_water_exclusion_volume", self)
	_registered_ocean = null


func _notification(what: int) -> void:
	if what == NOTIFICATION_TRANSFORM_CHANGED and is_inside_tree():
		_queue_ocean_update()


func _register_with_ocean() -> void:
	if not is_inside_tree() or is_instance_valid(_registered_ocean):
		return
	var ocean := get_tree().get_first_node_in_group(OCEAN_GROUP)
	if ocean == null or not ocean.has_method(&"register_water_exclusion_volume"):
		return
	_registered_ocean = ocean
	_registered_ocean.call(&"register_water_exclusion_volume", self)
	_registered_ocean.tree_exiting.connect(
		_on_registered_ocean_exiting,
		CONNECT_ONE_SHOT
	)
	set_process(false)


func _on_registered_ocean_exiting() -> void:
	_registered_ocean = null
	_registration_retry_elapsed = REGISTRATION_RETRY_INTERVAL
	set_process(true)


func _queue_ocean_update() -> void:
	if is_instance_valid(_registered_ocean):
		_registered_ocean.call(&"queue_water_exclusion_volume_update")
