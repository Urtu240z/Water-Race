@tool
class_name CourseBuoy3D
extends Node3D

## Course buoy with a side-specific passage area.
##
## The root remains fixed horizontally. At runtime it samples the active
## Ocean3D and follows only its surface height. The passage Area3D stays
## upright and can be consumed later by a lap/checkpoint controller.

signal valid_passage_entered(body: Node3D, required_side: int)
signal valid_passage_exited(body: Node3D, required_side: int)

enum BuoySide {
	LEFT,
	RIGHT,
}

@export_group("Buoy")
@export var buoy_side: BuoySide = BuoySide.LEFT:
	set(value):
		buoy_side = value
		_request_editor_refresh()
@export var visual_offset := Vector3.ZERO:
	set(value):
		visual_offset = value
		_request_editor_refresh()
@export var visual_scale := Vector3.ONE:
	set(value):
		visual_scale = value
		_request_editor_refresh()

@export_group("Valid Passage Area")
## Half-size of the valid passage volume.
@export var passage_half_extents := Vector3(4.0, 2.5, 6.0):
	set(value):
		passage_half_extents = Vector3(
			maxf(value.x, 0.05),
			maxf(value.y, 0.05),
			maxf(value.z, 0.05)
		)
		_request_editor_refresh()
## Empty space maintained between the buoy and the passage volume.
@export_range(0.0, 20.0, 0.05, "suffix:m") var buoy_clearance: float = 0.75:
	set(value):
		buoy_clearance = maxf(value, 0.0)
		_request_editor_refresh()
@export_range(-50.0, 50.0, 0.05, "suffix:m") var passage_longitudinal_offset: float = 0.0:
	set(value):
		passage_longitudinal_offset = value
		_request_editor_refresh()
@export_range(-10.0, 20.0, 0.05, "suffix:m") var passage_height_offset: float = 1.5:
	set(value):
		passage_height_offset = value
		_request_editor_refresh()
@export_flags_3d_physics var detection_mask: int = 1:
	set(value):
		detection_mask = value
		_request_editor_refresh()
## Optional group filter. Leave empty to accept any body detected by the mask.
@export var required_body_group: StringName

@export_group("Floating")
@export_node_path("Ocean3D") var ocean_path: NodePath:
	set(value):
		ocean_path = value
		_ocean = null
@export var auto_find_water: bool = true
@export_range(-10.0, 10.0, 0.01, "suffix:m") var waterline_offset: float = 0.0
@export var snap_to_water_on_start: bool = true
@export_range(0.0, 30.0, 0.1) var vertical_follow_speed: float = 8.0
@export var follow_water_normal: bool = true
@export_range(0.0, 1.0, 0.01) var water_normal_influence: float = 0.35
@export_range(0.0, 30.0, 0.1) var tilt_follow_speed: float = 5.0

@onready var _visuals: Node3D = $Visuals
@onready var _left_model: Node3D = $Visuals/BuoyLeft
@onready var _right_model: Node3D = $Visuals/BuoyRight
@onready var _passage_area: Area3D = $PassageArea
@onready var _passage_shape: CollisionShape3D = $PassageArea/CollisionShape3D

var _ocean: Ocean3D
var _water_lookup_cooldown: float = 0.0
var _editor_refresh_queued: bool = false


func _enter_tree() -> void:
	if Engine.is_editor_hint():
		call_deferred(&"_refresh_configuration")


func _ready() -> void:
	_refresh_configuration()
	if Engine.is_editor_hint():
		set_physics_process(false)
		return
	_resolve_ocean()
	if snap_to_water_on_start and is_instance_valid(_ocean):
		var start_position := global_position
		start_position.y = (
			_ocean.sample_height(start_position) + waterline_offset
		)
		global_position = start_position
	_passage_area.body_entered.connect(_on_passage_body_entered)
	_passage_area.body_exited.connect(_on_passage_body_exited)


func _physics_process(delta: float) -> void:
	if not is_instance_valid(_ocean):
		_water_lookup_cooldown -= delta
		if _water_lookup_cooldown <= 0.0:
			_water_lookup_cooldown = 1.0
			_resolve_ocean()
		if not is_instance_valid(_ocean):
			return
	var sample_position := global_position
	var target_height := (
		_ocean.sample_height(sample_position) + waterline_offset
	)
	var height_weight := 1.0 - exp(-maxf(vertical_follow_speed, 0.0) * delta)
	var next_position := global_position
	next_position.y = lerpf(next_position.y, target_height, height_weight)
	global_position = next_position
	_update_visual_tilt(delta, sample_position)


func get_required_side() -> BuoySide:
	return buoy_side


func get_passage_area() -> Area3D:
	return _passage_area


func is_body_inside_valid_passage(body: Node3D) -> bool:
	return is_instance_valid(_passage_area) and _passage_area.overlaps_body(body)


func _refresh_configuration() -> void:
	_editor_refresh_queued = false
	if not is_inside_tree():
		return
	_visuals = get_node_or_null("Visuals") as Node3D
	_left_model = get_node_or_null("Visuals/BuoyLeft") as Node3D
	_right_model = get_node_or_null("Visuals/BuoyRight") as Node3D
	_passage_area = get_node_or_null("PassageArea") as Area3D
	_passage_shape = get_node_or_null(
		"PassageArea/CollisionShape3D"
	) as CollisionShape3D
	if is_instance_valid(_left_model):
		_left_model.visible = buoy_side == BuoySide.LEFT
	if is_instance_valid(_right_model):
		_right_model.visible = buoy_side == BuoySide.RIGHT
	if is_instance_valid(_visuals):
		_visuals.position = visual_offset
		_visuals.scale = visual_scale
	if is_instance_valid(_passage_area):
		_passage_area.collision_layer = 0
		_passage_area.collision_mask = detection_mask
		var side_sign := -1.0 if buoy_side == BuoySide.LEFT else 1.0
		_passage_area.position = Vector3(
			side_sign * (buoy_clearance + passage_half_extents.x),
			passage_height_offset,
			passage_longitudinal_offset
		)
	if is_instance_valid(_passage_shape):
		var box := _passage_shape.shape as BoxShape3D
		if box == null:
			box = BoxShape3D.new()
			_passage_shape.shape = box
		elif not box.resource_local_to_scene:
			box = box.duplicate() as BoxShape3D
			box.resource_local_to_scene = true
			_passage_shape.shape = box
		box.size = passage_half_extents * 2.0


func _request_editor_refresh() -> void:
	if not is_inside_tree() or _editor_refresh_queued:
		return
	_editor_refresh_queued = true
	call_deferred(&"_refresh_configuration")


func _resolve_ocean() -> void:
	_ocean = null
	if not ocean_path.is_empty():
		_ocean = get_node_or_null(ocean_path) as Ocean3D
	if _ocean == null and auto_find_water and is_inside_tree():
		_ocean = _find_ocean(get_tree().current_scene)


func _find_ocean(root: Node) -> Ocean3D:
	if root == null:
		return null
	if root is Ocean3D:
		return root as Ocean3D
	for child in root.get_children():
		var result := _find_ocean(child)
		if result != null:
			return result
	return null


func _update_visual_tilt(delta: float, sample_position: Vector3) -> void:
	if not is_instance_valid(_visuals):
		return
	var target_basis := global_basis.orthonormalized()
	if follow_water_normal:
		var sampled_normal := _ocean.sample_normal(sample_position)
		var influenced_up := Vector3.UP.lerp(
			sampled_normal,
			clampf(water_normal_influence, 0.0, 1.0)
		).normalized()
		var forward := -global_basis.z.normalized()
		forward = (forward - influenced_up * forward.dot(influenced_up)).normalized()
		if forward.length_squared() > 0.0001:
			target_basis = Basis.looking_at(forward, influenced_up)
	var tilt_weight := 1.0 - exp(-maxf(tilt_follow_speed, 0.0) * delta)
	_visuals.global_basis = _visuals.global_basis.orthonormalized().slerp(
		target_basis,
		tilt_weight
	).scaled(visual_scale)


func _body_passes_filter(body: Node3D) -> bool:
	return (
		required_body_group.is_empty()
		or body.is_in_group(required_body_group)
	)


func _on_passage_body_entered(body: Node3D) -> void:
	if _body_passes_filter(body):
		valid_passage_entered.emit(body, int(buoy_side))


func _on_passage_body_exited(body: Node3D) -> void:
	if _body_passes_filter(body):
		valid_passage_exited.emit(body, int(buoy_side))
