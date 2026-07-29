class_name UnderwaterEffectController
extends Node3D

const UNDERWATER_POST_PROCESS_SHADER: Shader = preload(
	"res://shaders/effects/underwater_split_view_post_process.gdshader"
)

enum DebugForceMode {
	AUTOMATIC,
	FORCE_AIR,
	FORCE_UNDERWATER,
}

@export_group("References")
@export_node_path("Ocean3D") var ocean_path: NodePath
@export_node_path("MeshInstance3D") var post_process_path: NodePath = NodePath(
	"UnderwaterPostProcess"
)
@export var effect_enabled: bool = true

@export_group("Detection")
@export_range(0.0, 0.5, 0.005, "suffix:m") var enter_depth: float = 0.03
@export_range(0.0, 0.5, 0.005, "suffix:m") var exit_clearance: float = 0.05
@export_range(0.1, 30.0, 0.1) var transition_sharpness: float = 8.0

@export_group("Partial Underwater View")
@export_range(0.10, 5.0, 0.05, "suffix:m")
var partial_view_activation_distance: float = 1.50
@export_range(0.0, 1.0, 0.01, "suffix:m")
var full_submersion_start_depth: float = 0.05
@export_range(0.05, 2.0, 0.01, "suffix:m")
var full_submersion_end_depth: float = 0.35
@export_range(1, 2, 1) var waterline_iterations: int = 1
@export var waterline_include_ripples: bool = false
@export_range(10.0, 200.0, 1.0, "suffix:m")
var underwater_sky_distance: float = 45.0

@export_group("Underwater Look")
@export var underwater_tint: Color = Color(0.10, 0.40, 0.50, 1.0)
@export_range(0.0, 1.0, 0.01) var tint_strength: float = 0.16
@export_range(0.25, 1.5, 0.01) var contrast: float = 0.94
@export var fog_color: Color = Color(0.015, 0.095, 0.13, 1.0)
@export_range(0.0, 0.1, 0.001) var fog_density: float = 0.009
@export_range(0.0, 0.1, 0.001) var sky_fog_density: float = 0.007
@export_range(0.0, 1.0, 0.01) var sky_maximum_fog: float = 0.72
@export_range(0.0, 1.0, 0.01) var geometry_maximum_fog: float = 0.88
@export var absorption_coefficients: Vector3 = Vector3(0.022, 0.010, 0.005)
@export_range(0.0, 1.0, 0.01) var minimum_scene_visibility: float = 0.18
@export_range(0.0, 30.0, 0.5, "suffix:m") var near_clarity_distance: float = 7.0
@export_range(0.0, 50.0, 0.5, "suffix:m") var fog_start_distance: float = 5.0
@export_range(0.0, 50.0, 0.5, "suffix:m") var blur_start_distance: float = 8.0
@export_range(0.0, 0.01, 0.0001) var distortion_strength: float = 0.0008
@export_range(0.0, 5.0, 0.05) var distortion_speed: float = 0.7
@export_range(0.01, 1.0, 0.01, "suffix:m") var waterline_blend_width: float = 0.28
@export_range(0.0, 0.1, 0.001, "suffix:m")
var waterline_distortion_strength: float = 0.012
@export_range(1.0, 100.0, 1.0, "suffix:m")
var waterline_distortion_scale: float = 28.0
@export_range(0.0, 0.5, 0.01) var waterline_band_strength: float = 0.08
@export_range(0.001, 0.5, 0.001, "suffix:m")
var waterline_band_width: float = 0.06
@export_range(0.0, 1.0, 0.01) var maximum_effect_strength: float = 1.0
@export_range(0.0, 0.25, 0.001) var blur_density: float = 0.010
@export_range(0.0, 4.0, 0.05) var blur_near_lod: float = 0.0
@export_range(0.0, 1.2, 0.05) var blur_far_lod: float = 0.85

@export_group("Debug")
@export var force_mode: DebugForceMode = DebugForceMode.AUTOMATIC
@export_enum(
	"Final",
	"Underwater Mask",
	"Water Distance",
	"Fog Amount",
	"RGB Transmission",
	"Blur Amount",
	"Scene Color Before Effects",
	"Final Underwater Color",
) var debug_mode: int = 0

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
var _ocean: Ocean3D
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
		var configured_material := (
			_post_process.material_override as ShaderMaterial
		)
		if configured_material != null:
			_material = configured_material.duplicate() as ShaderMaterial
		else:
			_material = ShaderMaterial.new()
		_material.shader = UNDERWATER_POST_PROCESS_SHADER
		_post_process.material_override = _material
		_post_process.visible = false
	if _camera == null or _material == null:
		push_warning(
			"UnderwaterEffect requires a Camera3D parent and a ShaderMaterial post-process."
		)
		set_process(false)
		return
	_push_look_parameters(true)
	call_deferred("_resolve_ocean")


func _exit_tree() -> void:
	_unregister_ocean_material()


func _process(delta: float) -> void:
	if not effect_enabled:
		_effect_strength = 0.0
		if _post_process != null:
			_post_process.visible = false
		return
	if not is_instance_valid(_ocean):
		_resolve_retry_time -= delta
		if _resolve_retry_time <= 0.0:
			_resolve_retry_time = 1.0
			_resolve_ocean()
		if not is_instance_valid(_ocean):
			if _post_process != null:
				_post_process.visible = false
			return

	var camera_position := _camera.global_position
	_sampled_surface_height = _ocean.sample_height(camera_position)
	_camera_depth = _sampled_surface_height - camera_position.y
	_update_detection_state()

	var depth_submersion := smoothstep(
		full_submersion_start_depth,
		maxf(
			full_submersion_end_depth,
			full_submersion_start_depth + 0.001
		),
		maxf(_camera_depth, 0.0)
	)
	var target_strength := depth_submersion
	match force_mode:
		DebugForceMode.FORCE_AIR:
			target_strength = 0.0
		DebugForceMode.FORCE_UNDERWATER:
			target_strength = 1.0
	var blend := 1.0 - exp(
		-maxf(transition_sharpness, 0.0) * maxf(delta, 0.0)
	)
	_effect_strength = lerpf(_effect_strength, target_strength, blend)
	if absf(_effect_strength - target_strength) <= 0.0001:
		_effect_strength = target_strength

	_push_look_parameters(false)
	_material.set_shader_parameter(&"camera_submersion", _effect_strength)
	_material.set_shader_parameter(&"camera_depth", _camera_depth)
	var near_surface := (
		_camera_depth >= -partial_view_activation_distance
	)
	_post_process.visible = (
		force_mode != DebugForceMode.FORCE_AIR
		and (
			near_surface
			or _is_underwater
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


func _resolve_ocean() -> void:
	var resolved: Ocean3D
	if not ocean_path.is_empty():
		resolved = get_node_or_null(ocean_path) as Ocean3D
	if resolved == null:
		resolved = _find_matching_ocean()
	if resolved == _ocean:
		return
	_unregister_ocean_material()
	_ocean = resolved
	if _ocean != null and _material != null:
		_ocean.register_external_water_material(_material)


func _find_matching_ocean() -> Ocean3D:
	var scene_root := get_tree().current_scene
	if scene_root == null:
		scene_root = get_tree().root
	var fallback: Ocean3D = null
	var pending: Array[Node] = [scene_root]
	while not pending.is_empty():
		var candidate: Node = pending.pop_back()
		if candidate is Ocean3D:
			var ocean := candidate as Ocean3D
			if fallback == null:
				fallback = ocean
			if ocean.follow_camera == _camera:
				return ocean
		for child in candidate.get_children():
			pending.append(child)
	return fallback


func _unregister_ocean_material() -> void:
	if is_instance_valid(_ocean) and _material != null:
		_ocean.unregister_external_water_material(_material)
	_ocean = null


func _push_look_parameters(force_update: bool) -> void:
	if _material == null:
		return
	var signature := hash([
		underwater_tint,
		tint_strength,
		contrast,
		fog_color,
		fog_density,
		sky_fog_density,
		sky_maximum_fog,
		geometry_maximum_fog,
		absorption_coefficients,
		minimum_scene_visibility,
		near_clarity_distance,
		fog_start_distance,
		blur_start_distance,
		distortion_strength,
		distortion_speed,
		waterline_blend_width,
		waterline_distortion_strength,
		waterline_distortion_scale,
		waterline_band_strength,
		waterline_band_width,
		maximum_effect_strength,
		waterline_iterations,
		waterline_include_ripples,
		underwater_sky_distance,
		blur_density,
		blur_near_lod,
		blur_far_lod,
		debug_mode,
	])
	if not force_update and signature == _look_signature:
		return
	_look_signature = signature
	_material.set_shader_parameter(&"underwater_tint", underwater_tint)
	_material.set_shader_parameter(&"tint_strength", tint_strength)
	_material.set_shader_parameter(&"contrast", contrast)
	_material.set_shader_parameter(&"fog_color", fog_color)
	_material.set_shader_parameter(&"fog_density", fog_density)
	_material.set_shader_parameter(&"sky_fog_density", sky_fog_density)
	_material.set_shader_parameter(&"sky_maximum_fog", sky_maximum_fog)
	_material.set_shader_parameter(
		&"geometry_maximum_fog",
		geometry_maximum_fog
	)
	_material.set_shader_parameter(
		&"absorption_coefficients",
		absorption_coefficients
	)
	_material.set_shader_parameter(
		&"minimum_scene_visibility",
		minimum_scene_visibility
	)
	_material.set_shader_parameter(
		&"near_clarity_distance",
		near_clarity_distance
	)
	_material.set_shader_parameter(
		&"fog_start_distance",
		fog_start_distance
	)
	_material.set_shader_parameter(
		&"blur_start_distance",
		blur_start_distance
	)
	_material.set_shader_parameter(&"distortion_strength", distortion_strength)
	_material.set_shader_parameter(&"distortion_speed", distortion_speed)
	_material.set_shader_parameter(&"waterline_blend_width", waterline_blend_width)
	_material.set_shader_parameter(
		&"waterline_distortion_strength",
		waterline_distortion_strength
	)
	_material.set_shader_parameter(
		&"waterline_distortion_scale",
		waterline_distortion_scale
	)
	_material.set_shader_parameter(
		&"waterline_band_strength",
		waterline_band_strength
	)
	_material.set_shader_parameter(
		&"waterline_band_width",
		waterline_band_width
	)
	_material.set_shader_parameter(
		&"maximum_effect_strength",
		maximum_effect_strength
	)
	_material.set_shader_parameter(&"waterline_iterations", waterline_iterations)
	_material.set_shader_parameter(
		&"waterline_include_ripples",
		waterline_include_ripples
	)
	_material.set_shader_parameter(
		&"underwater_sky_distance",
		underwater_sky_distance
	)
	_material.set_shader_parameter(&"blur_density", blur_density)
	_material.set_shader_parameter(&"blur_near_lod", blur_near_lod)
	_material.set_shader_parameter(&"blur_far_lod", blur_far_lod)
	_material.set_shader_parameter(&"debug_mode", debug_mode)
