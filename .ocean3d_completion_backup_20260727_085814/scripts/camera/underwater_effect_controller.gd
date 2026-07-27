class_name UnderwaterEffectController
extends Node3D

enum DebugForceMode {
	AUTOMATIC,
	FORCE_AIR,
	FORCE_UNDERWATER,
}

@export_group("References")
@export_node_path("WaterBody3D") var water_body_path: NodePath
@export_node_path("MeshInstance3D") var post_process_path: NodePath = NodePath(
	"UnderwaterPostProcess"
)
@export var effect_enabled: bool = true

@export_group("Detection")
@export_range(0.0, 0.5, 0.005, "suffix:m") var enter_depth: float = 0.03
@export_range(0.0, 0.5, 0.005, "suffix:m") var exit_clearance: float = 0.05
@export_range(0.1, 30.0, 0.1) var transition_sharpness: float = 8.0

@export_group("Underwater Look")
@export var underwater_tint: Color = Color(0.18, 0.58, 0.68, 1.0)
@export_range(0.0, 1.0, 0.01) var tint_strength: float = 0.24
@export_range(0.25, 1.5, 0.01) var contrast: float = 0.86
@export var fog_color: Color = Color(0.025, 0.22, 0.29, 1.0)
@export_range(0.0, 0.5, 0.0025) var fog_density: float = 0.0325
@export_range(0.0, 0.5, 0.0025) var absorption_density: float = 0.055
@export_range(0.0, 0.01, 0.0001) var distortion_strength: float = 0.0014
@export_range(0.0, 5.0, 0.05) var distortion_speed: float = 0.7
@export_range(0.01, 1.0, 0.01, "suffix:m") var waterline_blend_width: float = 0.12
@export_range(0.0, 1.0, 0.01) var maximum_effect_strength: float = 1.0

@export_group("Debug")
@export var force_mode: DebugForceMode = DebugForceMode.AUTOMATIC
@export var show_underwater_mask: bool = false

var is_underwater: bool:
	get:
		return _is_underwater

var camera_depth: float:
	get:
		return _camera_depth

var sampled_surface_height: float:
	get:
		return _sampled_surface_height

var effect_strength: float:
	get:
		return _effect_strength

var _camera: Camera3D
var _post_process: MeshInstance3D
var _material: ShaderMaterial
var _water_body: WaterBody3D
var _is_underwater: bool = false
var _camera_depth: float = -INF
var _sampled_surface_height: float = -INF
var _effect_strength: float = 0.0
var _resolve_retry_time: float = 0.0
var _look_signature: int = 0


func _ready() -> void:
	process_priority = 100
	_camera = get_parent() as Camera3D
	_post_process = get_node_or_null(post_process_path) as MeshInstance3D
	if _post_process != null:
		_material = _post_process.material_override as ShaderMaterial
		_post_process.visible = false
	if _camera == null or _material == null:
		push_warning(
			"UnderwaterEffect requires a Camera3D parent and a ShaderMaterial post-process."
		)
		set_process(false)
		return
	_push_look_parameters(true)
	call_deferred("_resolve_water_body")


func _exit_tree() -> void:
	_unregister_water_material()


func _process(delta: float) -> void:
	if not effect_enabled:
		_effect_strength = 0.0
		if _post_process != null:
			_post_process.visible = false
		return
	if not is_instance_valid(_water_body):
		_resolve_retry_time -= delta
		if _resolve_retry_time <= 0.0:
			_resolve_retry_time = 1.0
			_resolve_water_body()
		if not is_instance_valid(_water_body):
			if _post_process != null:
				_post_process.visible = false
			return

	var camera_position := _camera.global_position
	_sampled_surface_height = _water_body.sample_height(camera_position)
	_camera_depth = _sampled_surface_height - camera_position.y
	_update_detection_state()

	var target_strength := 1.0 if _is_underwater else 0.0
	var blend := 1.0 - exp(
		-maxf(transition_sharpness, 0.0) * maxf(delta, 0.0)
	)
	_effect_strength = lerpf(_effect_strength, target_strength, blend)
	if absf(_effect_strength - target_strength) <= 0.0001:
		_effect_strength = target_strength

	_push_look_parameters(false)
	_material.set_shader_parameter(&"camera_submersion", _effect_strength)
	_material.set_shader_parameter(&"camera_depth", _camera_depth)
	_post_process.visible = (
		force_mode != DebugForceMode.FORCE_AIR
		and (
			_is_underwater
			or _effect_strength > 0.001
			or force_mode == DebugForceMode.FORCE_UNDERWATER
		)
	)


func _update_detection_state() -> void:
	match force_mode:
		DebugForceMode.FORCE_AIR:
			_is_underwater = false
		DebugForceMode.FORCE_UNDERWATER:
			_is_underwater = true
		_:
			if _is_underwater:
				if _camera_depth <= -exit_clearance:
					_is_underwater = false
			elif _camera_depth >= enter_depth:
				_is_underwater = true


func _resolve_water_body() -> void:
	var resolved: WaterBody3D
	if not water_body_path.is_empty():
		resolved = get_node_or_null(water_body_path) as WaterBody3D
	if resolved == null:
		resolved = _find_matching_water_body()
	if resolved == _water_body:
		return
	_unregister_water_material()
	_water_body = resolved
	if _water_body != null and _material != null:
		_water_body.register_external_water_material(_material)


func _find_matching_water_body() -> WaterBody3D:
	var scene_root := get_tree().current_scene
	if scene_root == null:
		scene_root = get_tree().root
	var fallback: WaterBody3D = null
	var pending: Array[Node] = [scene_root]
	while not pending.is_empty():
		var candidate: Node = pending.pop_back()
		if candidate is WaterBody3D:
			var water := candidate as WaterBody3D
			if fallback == null:
				fallback = water
			if water.follow_target == _camera:
				return water
		for child in candidate.get_children():
			pending.append(child)
	return fallback


func _unregister_water_material() -> void:
	if is_instance_valid(_water_body) and _material != null:
		_water_body.unregister_external_water_material(_material)
	_water_body = null


func _push_look_parameters(force_update: bool) -> void:
	if _material == null:
		return
	var signature := hash([
		underwater_tint,
		tint_strength,
		contrast,
		fog_color,
		fog_density,
		absorption_density,
		distortion_strength,
		distortion_speed,
		waterline_blend_width,
		maximum_effect_strength,
		show_underwater_mask,
	])
	if not force_update and signature == _look_signature:
		return
	_look_signature = signature
	_material.set_shader_parameter(&"underwater_tint", underwater_tint)
	_material.set_shader_parameter(&"tint_strength", tint_strength)
	_material.set_shader_parameter(&"contrast", contrast)
	_material.set_shader_parameter(&"fog_color", fog_color)
	_material.set_shader_parameter(&"fog_density", fog_density)
	_material.set_shader_parameter(&"absorption_density", absorption_density)
	_material.set_shader_parameter(&"distortion_strength", distortion_strength)
	_material.set_shader_parameter(&"distortion_speed", distortion_speed)
	_material.set_shader_parameter(&"waterline_blend_width", waterline_blend_width)
	_material.set_shader_parameter(
		&"maximum_effect_strength",
		maximum_effect_strength
	)
	_material.set_shader_parameter(
		&"debug_mask_enabled",
		show_underwater_mask
	)
