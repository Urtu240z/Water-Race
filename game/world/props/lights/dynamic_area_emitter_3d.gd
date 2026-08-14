@tool
class_name DynamicAreaEmitter3D
extends Node3D

## A visible rectangular emitter backed either by one AreaLight3D or by an
## automatically distributed chain of cubemap-shadowed OmniLight3D nodes.

const EPSILON: float = 0.000001
const POSITIONAL_LIGHT_GROUP: StringName = &"graphics_quality_positional_light"

enum LightMode {
	AREA,
	OMNI_CHAIN,
}

@export_group("Size")
@export var size: Vector2 = Vector2(10.0, 1.0):
	set(value):
		size = value
		_apply_configuration()

@export_group("Light")
@export var light_mode: LightMode = LightMode.AREA:
	set(value):
		light_mode = value
		_apply_configuration()
@export var light_color: Color = Color.WHITE:
	set(value):
		light_color = value
		_apply_color()
@export_range(0.0, 100.0, 0.01) var light_energy: float = 1.0:
	set(value):
		light_energy = value
		_apply_light_properties()
@export_range(0.0, 10.0, 0.01) var light_specular: float = 1.0:
	set(value):
		light_specular = value
		_apply_light_properties()
@export_range(0.0, 10000.0, 0.01, "suffix:m") var light_range: float = 5.0:
	set(value):
		light_range = value
		_apply_configuration()
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
@export_range(0.0, 1.0, 0.01) var shadow_opacity: float = 1.0:
	set(value):
		shadow_opacity = value
		_apply_light_properties()
@export_range(0.0, 10.0, 0.01) var shadow_blur: float = 1.0:
	set(value):
		shadow_blur = value
		_apply_light_properties()

@export_group("Omni Chain")
## Fraction of each OmniLight3D diameter shared with its neighbours.
## Higher values make illumination more uniform, but require more lights.
@export_range(0.0, 0.95, 0.01) var omni_overlap: float = 0.75:
	set(value):
		omni_overlap = value
		_apply_configuration()
## Upper spacing limit. This prevents a large range from creating visible
## bright/dark bands along an emitter that is close to the receiving surface.
@export_range(0.1, 100.0, 0.1, "suffix:m") var omni_max_spacing: float = 12.0:
	set(value):
		omni_max_spacing = value
		_apply_configuration()
## Safety limit: cubemap shadows render six shadow-map faces per OmniLight3D.
@export_range(1, 64, 1) var omni_max_lights: int = 16:
	set(value):
		omni_max_lights = value
		_apply_configuration()
## Extra multiplier applied after automatic overlap-energy normalization.
@export_range(0.0, 10.0, 0.01) var omni_energy_scale: float = 1.0:
	set(value):
		omni_energy_scale = value
		_apply_light_properties()
## Moves the point lights towards the emitting side of the QuadMesh (-Z).
@export_range(0.0, 10.0, 0.01, "suffix:m") var omni_surface_offset: float = 0.1:
	set(value):
		omni_surface_offset = value
		_apply_configuration()
@export_range(0.0, 10.0, 0.001) var omni_shadow_bias: float = 0.05:
	set(value):
		omni_shadow_bias = value
		_apply_light_properties()
@export_range(0.0, 10.0, 0.01) var omni_shadow_normal_bias: float = 1.0:
	set(value):
		omni_shadow_normal_bias = value
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
@onready var _omni_lights: Node3D = $OmniLights

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
	_sync_light_layout()
	_apply_light_properties()
	_apply_visual_properties()
	_apply_color()


func _apply_light_properties() -> void:
	if not is_node_ready():
		return
	var resolved_specular := light_specular if light_specular != null else 1.0
	var resolved_shadow_opacity := shadow_opacity if shadow_opacity != null else 1.0
	var resolved_shadow_blur := shadow_blur if shadow_blur != null else 1.0
	_area_light.light_energy = light_energy
	_area_light.light_specular = resolved_specular
	_area_light.area_range = light_range
	_area_light.area_attenuation = attenuation
	_area_light.area_normalize_energy = normalize_energy
	_area_light.shadow_enabled = shadows_enabled
	_area_light.shadow_opacity = resolved_shadow_opacity
	# During a @tool script reload, newly added exports can briefly be null
	# before Godot restores their default or serialized value.
	_area_light.shadow_blur = resolved_shadow_blur
	var omni_energy := light_energy * omni_energy_scale
	if normalize_energy:
		omni_energy /= _get_effective_omni_overlap()
	for omni_light: OmniLight3D in _get_omni_lights():
		omni_light.light_color = _get_current_color()
		omni_light.light_energy = omni_energy
		omni_light.light_specular = resolved_specular
		omni_light.omni_range = light_range
		omni_light.omni_attenuation = attenuation
		omni_light.shadow_enabled = shadows_enabled
		omni_light.shadow_opacity = resolved_shadow_opacity
		omni_light.shadow_blur = resolved_shadow_blur
		omni_light.shadow_bias = omni_shadow_bias
		omni_light.shadow_normal_bias = omni_shadow_normal_bias


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
	for omni_light: OmniLight3D in _get_omni_lights():
		omni_light.light_color = current_color
	var material := _get_emission_material()
	if material != null:
		material.albedo_color = current_color
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


func _sync_light_layout() -> void:
	if not is_node_ready():
		return
	var use_omni_chain := light_mode == LightMode.OMNI_CHAIN
	_area_light.visible = not use_omni_chain
	_omni_lights.visible = use_omni_chain
	var required_count := _get_required_omni_count() if use_omni_chain else 0
	var target_count := mini(required_count, maxi(omni_max_lights, 1))
	var lights := _get_omni_lights()
	while lights.size() > target_count:
		var removed_light: OmniLight3D = lights.pop_back()
		removed_light.free()
	while lights.size() < target_count:
		var omni_light := OmniLight3D.new()
		omni_light.name = "OmniLight%02d" % (lights.size() + 1)
		omni_light.omni_shadow_mode = OmniLight3D.SHADOW_CUBE
		_omni_lights.add_child(omni_light)
		omni_light.add_to_group(POSITIONAL_LIGHT_GROUP)
		lights.append(omni_light)
	if target_count > 0:
		var emitter_length := _get_emitter_length()
		var segment_length := emitter_length / float(target_count)
		var along_x := absf(size.x) >= absf(size.y)
		for index in target_count:
			var axis_position := -0.5 * emitter_length + (index + 0.5) * segment_length
			lights[index].position = Vector3(
				axis_position if along_x else 0.0,
				0.0 if along_x else axis_position,
				-omni_surface_offset
			)
	if Engine.is_editor_hint():
		update_configuration_warnings()


func _get_omni_lights() -> Array[OmniLight3D]:
	var result: Array[OmniLight3D] = []
	if not is_node_ready():
		return result
	for child: Node in _omni_lights.get_children():
		if child is OmniLight3D:
			result.append(child as OmniLight3D)
	return result


func _get_emitter_length() -> float:
	return maxf(absf(size.x), absf(size.y))


func _get_requested_omni_spacing() -> float:
	var overlap_spacing := 2.0 * maxf(light_range, EPSILON) * (1.0 - omni_overlap)
	return maxf(minf(overlap_spacing, omni_max_spacing), EPSILON)


func _get_required_omni_count() -> int:
	var emitter_length := _get_emitter_length()
	if emitter_length <= EPSILON or light_range <= EPSILON:
		return 0
	return maxi(ceili(emitter_length / _get_requested_omni_spacing()), 1)


func _get_effective_omni_overlap() -> float:
	var count := _get_omni_lights().size()
	if count <= 1:
		return 1.0
	var actual_spacing := _get_emitter_length() / float(count)
	# Approximate the average contribution of overlapping linear falloff curves.
	# This keeps local brightness broadly stable when size changes the light count.
	var falloff_divisor := maxf(attenuation + 1.0, 1.0)
	var effective_overlap := 2.0 * light_range / (actual_spacing * falloff_divisor)
	return clampf(effective_overlap, 1.0, float(count))


func _get_configuration_warnings() -> PackedStringArray:
	var warnings := PackedStringArray()
	if light_mode == LightMode.OMNI_CHAIN:
		var required_count := _get_required_omni_count()
		if required_count > omni_max_lights:
			warnings.append(
				(
					"Omni Chain needs %d lights for the requested overlap/spacing, but "
					+ "Omni Max Lights limits it to %d. Increase the limit or expect "
					+ "less uniform illumination."
				)
				% [required_count, omni_max_lights]
			)
	return warnings


func _update_processing() -> void:
	if not is_inside_tree():
		return
	set_process(animate_hue and absf(hue_speed) > EPSILON)
