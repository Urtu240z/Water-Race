@tool
class_name CalmWaterArea3D
extends Area3D

## Defines a spatial region where Ocean3D reduces its natural waves.
## Vehicle wakes, landing ripples and hull interactions remain unaffected.

const OCEAN_GROUP: StringName = &"ocean_3d"
const SHAPE_BOX: int = 0
const SHAPE_CIRCLE: int = 1
const SIGNATURE_UPDATE_INTERVAL: float = 0.25

@export_group("Ocean")
@export_node_path("Ocean3D") var ocean_path: NodePath:
	set(value):
		ocean_path = value
		_queue_ocean_resolution()
@export var area_enabled: bool = true:
	set(value):
		area_enabled = value
		_notify_ocean_changed()

@export_group("Calm Water")
## Remaining natural macro-wave amplitude at the center of the area.
@export_range(0.0, 1.0, 0.01) var wave_strength: float = 0.20:
	set(value):
		wave_strength = clampf(value, 0.0, 1.0)
		_notify_ocean_changed()
## Remaining small surface-normal detail at the center of the area.
@export_range(0.0, 1.0, 0.01) var surface_detail_strength: float = 0.35:
	set(value):
		surface_detail_strength = clampf(value, 0.0, 1.0)
		_notify_ocean_changed()
## Remaining natural crest foam at the center of the area.
@export_range(0.0, 1.0, 0.01) var crest_foam_strength: float = 0.25:
	set(value):
		crest_foam_strength = clampf(value, 0.0, 1.0)
		_notify_ocean_changed()
## Distance outside the CollisionShape3D over which open-sea waves return.
@export_range(0.25, 100.0, 0.25, "suffix:m") var transition_distance: float = 20.0:
	set(value):
		transition_distance = maxf(value, 0.25)
		_notify_ocean_changed()

var _ocean: Ocean3D
var _signature_elapsed: float = 0.0
var _last_signature: int = 0
var _resolution_queued: bool = false


func _enter_tree() -> void:
	set_notify_transform(true)


func _ready() -> void:
	monitoring = false
	monitorable = false
	collision_layer = 0
	collision_mask = 0
	_resolve_ocean()
	_last_signature = _build_signature()
	set_process(true)
	update_configuration_warnings()


func _process(delta: float) -> void:
	_signature_elapsed += maxf(delta, 0.0)
	if _signature_elapsed < SIGNATURE_UPDATE_INTERVAL:
		return
	_signature_elapsed = 0.0
	if not is_instance_valid(_ocean):
		_resolve_ocean()
	var current_signature := _build_signature()
	if current_signature == _last_signature:
		return
	_last_signature = current_signature
	_notify_ocean_changed()
	if Engine.is_editor_hint():
		update_configuration_warnings()


func _exit_tree() -> void:
	if is_instance_valid(_ocean):
		_ocean.unregister_calm_water_area(self)
	_ocean = null


func _notification(what: int) -> void:
	if what == NOTIFICATION_TRANSFORM_CHANGED and is_node_ready():
		_notify_ocean_changed()


func _get_configuration_warnings() -> PackedStringArray:
	var warnings := PackedStringArray()
	var collision_shape := _get_collision_shape()
	if collision_shape == null:
		warnings.append("CalmWaterArea3D requires a CollisionShape3D child.")
		return warnings
	if collision_shape.shape == null:
		warnings.append("Assign a BoxShape3D, SphereShape3D or CylinderShape3D.")
	elif not (
		collision_shape.shape is BoxShape3D
		or collision_shape.shape is SphereShape3D
		or collision_shape.shape is CylinderShape3D
	):
		warnings.append(
			"Only BoxShape3D, SphereShape3D and CylinderShape3D are supported."
		)
	if not ocean_path.is_empty() and get_node_or_null(ocean_path) == null:
		warnings.append("The configured Ocean3D cannot be resolved.")
	return warnings


func get_calm_zone_data() -> Dictionary:
	var collision_shape := _get_collision_shape()
	if (
		not area_enabled
		or collision_shape == null
		or collision_shape.disabled
		or collision_shape.shape == null
	):
		return {}
	var shape_transform := collision_shape.global_transform
	var shape_scale := shape_transform.basis.get_scale().abs()
	var center_xz := Vector2(shape_transform.origin.x, shape_transform.origin.z)
	var axis_x := Vector2(shape_transform.basis.x.x, shape_transform.basis.x.z)
	var axis_z := Vector2(shape_transform.basis.z.x, shape_transform.basis.z.z)
	axis_x = axis_x.normalized() if axis_x.length_squared() > 0.000001 else Vector2.RIGHT
	axis_z = axis_z.normalized() if axis_z.length_squared() > 0.000001 else Vector2.DOWN

	var shape_type := SHAPE_BOX
	var half_extents := Vector2.ONE
	if collision_shape.shape is BoxShape3D:
		var box := collision_shape.shape as BoxShape3D
		half_extents = Vector2(
			box.size.x * shape_scale.x * 0.5,
			box.size.z * shape_scale.z * 0.5
		)
	elif collision_shape.shape is SphereShape3D:
		var sphere := collision_shape.shape as SphereShape3D
		var sphere_radius := sphere.radius * maxf(shape_scale.x, shape_scale.z)
		shape_type = SHAPE_CIRCLE
		half_extents = Vector2(sphere_radius, sphere_radius)
	elif collision_shape.shape is CylinderShape3D:
		var cylinder := collision_shape.shape as CylinderShape3D
		var cylinder_radius := cylinder.radius * maxf(shape_scale.x, shape_scale.z)
		shape_type = SHAPE_CIRCLE
		half_extents = Vector2(cylinder_radius, cylinder_radius)
	else:
		return {}

	return {
		"center": center_xz,
		"axis_x": axis_x,
		"axis_z": axis_z,
		"half_extents": half_extents,
		"shape_type": shape_type,
		"transition_distance": transition_distance,
		"wave_strength": wave_strength,
		"surface_detail_strength": surface_detail_strength,
		"crest_foam_strength": crest_foam_strength,
	}


func _get_collision_shape() -> CollisionShape3D:
	return get_node_or_null("CollisionShape3D") as CollisionShape3D


func _resolve_ocean() -> void:
	var resolved_ocean: Ocean3D
	if not ocean_path.is_empty():
		resolved_ocean = get_node_or_null(ocean_path) as Ocean3D
	if resolved_ocean == null and get_tree() != null:
		for candidate: Node in get_tree().get_nodes_in_group(OCEAN_GROUP):
			resolved_ocean = candidate as Ocean3D
			if resolved_ocean != null:
				break
	if resolved_ocean == _ocean:
		return
	if is_instance_valid(_ocean):
		_ocean.unregister_calm_water_area(self)
	_ocean = resolved_ocean
	if is_instance_valid(_ocean):
		_ocean.register_calm_water_area(self)


func _queue_ocean_resolution() -> void:
	if not is_inside_tree() or _resolution_queued:
		return
	_resolution_queued = true
	call_deferred("_finish_ocean_resolution")


func _finish_ocean_resolution() -> void:
	_resolution_queued = false
	_resolve_ocean()
	_notify_ocean_changed()


func _notify_ocean_changed() -> void:
	if is_instance_valid(_ocean):
		_ocean.queue_calm_water_area_update()


func _build_signature() -> int:
	var collision_shape := _get_collision_shape()
	var shape_signature: Variant = null
	if collision_shape != null and collision_shape.shape != null:
		var shape_resource := collision_shape.shape
		if shape_resource is BoxShape3D:
			shape_signature = (shape_resource as BoxShape3D).size
		elif shape_resource is SphereShape3D:
			shape_signature = (shape_resource as SphereShape3D).radius
		elif shape_resource is CylinderShape3D:
			var cylinder := shape_resource as CylinderShape3D
			shape_signature = Vector2(cylinder.radius, cylinder.height)
	return hash(
		[
			global_transform,
			shape_signature,
			area_enabled,
			wave_strength,
			surface_detail_strength,
			crest_foam_strength,
			transition_distance,
		]
	)
