@tool
class_name DynamicAreaEmitter3D
extends Node3D

## A visible rectangular emitter whose QuadMesh and AreaLight3D always share
## their size and the colour calculated by this root node.

const EPSILON: float = 0.000001

@export_group("Size")
@export var size: Vector2 = Vector2(10.0, 1.0):
	set(value):
		size = value
		_apply_configuration()

@export_group("Light")
@export var light_color: Color = Color.WHITE:
	set(value):
		light_color = value
		_apply_color()
@export_range(0.0, 100.0, 0.01) var light_energy: float = 1.0:
	set(value):
		light_energy = value
		_apply_light_properties()
@export_range(0.0, 10000.0, 0.01, "suffix:m") var light_range: float = 5.0:
	set(value):
		light_range = value
		_apply_light_properties()
@export_range(0.0, 10.0, 0.01) var attenuation: float = 1.0:
	set(value):
		attenuation = value
		_apply_light_properties()
@export var normalize_energy: bool = true:
	set(value):
		normalize_energy = value
		_apply_light_properties()
@export var shadows_enabled: bool = false:
	set(value):
		shadows_enabled = value
		_apply_light_properties()

@export_group("Emitter Visual")
@export_range(0.0, 100.0, 0.01) var emission_energy: float = 1.0:
	set(value):
		emission_energy = value
		_apply_visual_properties()
@export var show_emitter: bool = true:
	set(value):
		show_emitter = value
		_apply_visual_properties()

@export_group("Hue Animation")
@export var animate_hue: bool = false:
	set(value):
		animate_hue = value
		_update_processing()
		_apply_color()
## Complete hue rotations per second. Negative values rotate in reverse.
@export_range(-1.0, 1.0, 0.005) var hue_speed: float = 0.05:
	set(value):
		hue_speed = value
		_update_processing()
@export_range(0.0, 2.0, 0.01) var hue_saturation: float = 1.0:
	set(value):
		hue_saturation = value
		_apply_color()
@export_range(0.0, 4.0, 0.01) var hue_value: float = 1.0:
	set(value):
		hue_value = value
		_apply_color()
@export_range(0.0, 1.0, 0.005) var hue_offset: float = 0.0:
	set(value):
		hue_offset = value
		_apply_color()

@onready var _emitter_mesh: MeshInstance3D = $EmitterMesh
@onready var _area_light: AreaLight3D = $AreaLight3D

var _hue_elapsed: float = 0.0


func _ready() -> void:
	_apply_configuration()
	_update_processing()


func _process(delta: float) -> void:
	_hue_elapsed += delta
	_apply_color()


func _apply_configuration() -> void:
	if not is_node_ready():
		return
	if _emitter_mesh.mesh is QuadMesh:
		(_emitter_mesh.mesh as QuadMesh).size = size
	_area_light.area_size = size
	_apply_light_properties()
	_apply_visual_properties()
	_apply_color()


func _apply_light_properties() -> void:
	if not is_node_ready():
		return
	_area_light.light_energy = light_energy
	_area_light.area_range = light_range
	_area_light.area_attenuation = attenuation
	_area_light.area_normalize_energy = normalize_energy
	_area_light.shadow_enabled = shadows_enabled


func _apply_visual_properties() -> void:
	if not is_node_ready():
		return
	_emitter_mesh.visible = show_emitter
	var material := _get_emission_material()
	if material != null:
		material.emission_energy_multiplier = emission_energy


func _apply_color() -> void:
	if not is_node_ready():
		return
	var current_color := _get_current_color()
	_area_light.light_color = current_color
	var material := _get_emission_material()
	if material != null:
		material.emission = current_color


func _get_current_color() -> Color:
	if not animate_hue:
		return light_color
	var hue := fposmod(light_color.h + hue_offset + _hue_elapsed * hue_speed, 1.0)
	var saturation := clampf(light_color.s * hue_saturation, 0.0, 1.0)
	var value := maxf(light_color.v * hue_value, 0.0)
	return Color.from_hsv(hue, saturation, value, light_color.a)


func _get_emission_material() -> StandardMaterial3D:
	if not is_node_ready() or not (_emitter_mesh.mesh is QuadMesh):
		return null
	return (_emitter_mesh.mesh as QuadMesh).material as StandardMaterial3D


func _update_processing() -> void:
	if not is_inside_tree():
		return
	set_process(animate_hue and absf(hue_speed) > EPSILON)
