@tool
class_name UnderwaterEffectController
extends Node3D

const UNDERWATER_POST_PROCESS_SHADER: Shader = preload(
    "res://systems/camera/underwater/shaders/underwater_split_view_post_process.gdshader"
)
const UNDERWATER_COMPOSITOR_EFFECT_SCRIPT: Script = preload(
    "res://systems/camera/underwater/underwater_fullscreen_compositor_effect.gd"
)
const EDITOR_INTERFACE_BRIDGE_PATH: String = (
	"res://dev/editor/editor_interface_bridge.gd"
)
const UNDERWATER_POST_PROCESS_RENDER_PRIORITY: int = -127
const DEFAULT_WET_LENS_HEIGHT: Texture2D = preload(
    "res://systems/camera/underwater/textures/wet_lens_height.png"
)

enum DebugForceMode {
	AUTOMATIC,
	FORCE_AIR,
	FORCE_UNDERWATER,
}

enum EditorPreviewMode {
	FOLLOW_VIEWPORT,
	FULLY_UNDERWATER,
}

enum WaterCrossingTransition {
	NONE,
	ENTERING,
	EXITING,
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

@export_group("Underwater Look")
@export var underwater_tint: Color = Color(0.10, 0.40, 0.50, 1.0)
@export_range(0.0, 1.0, 0.01) var tint_strength: float = 0.16
@export_range(0.25, 1.5, 0.01) var contrast: float = 0.94
## Final fog color. Geometry and ocean converge smoothly to this color.
@export var underwater_fog_color: Color = Color(0.03, 0.16, 0.21, 1.0)
@export_range(0.0, 0.1, 0.001) var fog_density: float = 0.009
@export_range(0.0, 50.0, 0.5, "suffix:m") var fog_start_distance: float = 5.0

@export_group("Underwater Blur")
## Uniform screen-space blur radius. It only affects the underwater mask.
@export_range(0.0, 24.0, 0.1, "suffix:px") var blur_strength: float = 6.0
## Number of separable Gaussian passes. More passes produce a smoother blur at
## additional GPU cost.
@export_range(1, 4, 1) var blur_passes: int = 2

@export_group("Underwater Visibility")
## Maximum visible distance below water. At this radius every scene element
## and the ocean surface converge completely to the underwater fog color.
@export_range(5.0, 300.0, 1.0, "suffix:m")
var underwater_visibility_radius: float = 80.0
## Distance over which the image blends smoothly into the underwater tint before
## reaching the visibility radius.
@export_range(1.0, 150.0, 1.0, "suffix:m")
var underwater_visibility_blend: float = 20.0

@export_group("Underwater Surface")
## Alpha of the ocean surface when viewed from below. Lower values let more
## sky light through without changing the surface alpha above water.
@export_range(0.0, 1.0, 0.01) var underwater_surface_alpha: float = 0.82

@export_group("Water Crossing Transition")
## Short bubble/refraction burst used when the camera enters the water.
@export_range(0.05, 2.0, 0.05, "suffix:s")
var entry_transition_duration: float = 0.45
## Wet-lens drain used when the camera exits the water.
@export_range(0.05, 3.0, 0.05, "suffix:s")
var exit_transition_duration: float = 0.90
@export_range(0.0, 2.0, 0.05)
var crossing_transition_strength: float = 1.0
## Grayscale height map used to refract realistic droplets on exit.
@export var wet_lens_height_texture: Texture2D = DEFAULT_WET_LENS_HEIGHT
## Zooms into the wet-lens texture. Higher values show fewer, larger drops.
@export_range(0.5, 4.0, 0.05) var wet_lens_zoom: float = 1.0
## Strength of the animated refraction and downward image drag.
@export_range(0.0, 3.0, 0.05) var wet_lens_warp_strength: float = 1.0
## Fraction of the screen travelled downward during the exit transition.
@export_range(0.0, 1.0, 0.01) var wet_lens_fall_distance: float = 0.28
## Vertical variation of the clearing edge. Zero produces a straight wash.
@export_range(0.0, 1.5, 0.01)
var wet_lens_wash_irregularity: float = 1.0
## Width of the blend between wet and clean areas.
@export_range(0.01, 0.5, 0.01)
var wet_lens_wash_softness: float = 0.18
## Soft fade applied where the moving droplet texture leaves its UV bounds.
@export_range(0.0, 0.25, 0.005)
var wet_lens_texture_edge_feather: float = 0.08

@export_group("Editor Preview")
## Shows this post-process in the 3D editor viewport only.
@export var editor_preview_enabled: bool = false
## FULLY_UNDERWATER makes tuning immediately visible from any editor camera position.
@export var editor_preview_mode: EditorPreviewMode = EditorPreviewMode.FULLY_UNDERWATER
## Fallback depth, also used by the two forced preview modes.
## Negative values are above the surface; positive values are below it.
@export_range(-2.0, 2.0, 0.01, "suffix:m")
var editor_preview_camera_depth: float = -0.10

@export_group("Debug")
@export var force_mode: DebugForceMode = DebugForceMode.AUTOMATIC
## Test-only escape hatch used to verify the legacy full-screen quad route.
@export var force_legacy_fallback: bool = false
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
var _fog_environment: Environment
var _fog_environment_original: Dictionary = {}
var _preview_environment_camera: Camera3D
var _preview_original_environment: Environment
var _preview_environment: Environment
var _compositor_effect: CompositorEffect
var _compositor_camera: Camera3D
var _original_compositor: Compositor
var _active_compositor: Compositor
var _bubble_particles: GPUParticles2D
var _crossing_transition: WaterCrossingTransition = (
	WaterCrossingTransition.NONE
)
var _crossing_transition_elapsed: float = 0.0
var _crossing_transition_progress: float = 1.0
var _base_wet_lens_zoom: float = 1.0
var _base_wet_lens_warp_strength: float = 1.0
var _compositor_prewarm_started := false
var _compositor_prewarm_in_progress := false
var _compositor_prewarm_complete := false
var _fallback_active := false
var _fallback_reason := ""


func _ready() -> void:
	process_priority = 100
	_compositor_effect = (
		UNDERWATER_COMPOSITOR_EFFECT_SCRIPT.new() as CompositorEffect
	)
	if not _initialize_post_process():
		push_warning(
			"UnderwaterEffect requires a Camera3D parent and a ShaderMaterial post-process."
		)
		if not Engine.is_editor_hint():
			set_process(false)
		return
	_base_wet_lens_zoom = wet_lens_zoom
	_base_wet_lens_warp_strength = wet_lens_warp_strength
	_push_look_parameters(true)
	call_deferred("_resolve_ocean")
	call_deferred("_prewarm_fullscreen_compositor")


func set_graphics_quality(
	_level: int,
	profile: GraphicsQualityProfile
) -> void:
	if profile == null:
		return
	blur_strength = profile.underwater_blur_strength
	blur_passes = profile.underwater_blur_passes
	wet_lens_zoom = (
		_base_wet_lens_zoom
		* profile.underwater_wet_lens_zoom_multiplier
	)
	wet_lens_warp_strength = (
		_base_wet_lens_warp_strength
		* profile.underwater_wet_lens_warp_multiplier
	)
	if _bubble_particles != null:
		_bubble_particles.amount = profile.underwater_entry_bubbles_amount
	if not _fog_environment_original.is_empty():
		# GraphicsQualityManager has just selected the new preset. Preserve it
		# as the state to restore when the camera leaves the water.
		_fog_environment_original[&"depth_fog_enabled"] = profile.fog
		_fog_environment_original[&"enabled"] = (
			profile.volumetric_fog
		)
	_push_look_parameters(true)
	if _material != null:
		_material.set_shader_parameter(
			&"camera_submersion",
			_effect_strength
		)
	_update_volumetric_fog(_effect_strength)
	_update_fullscreen_compositor(_effect_strength)


func get_graphics_quality_debug_status() -> Dictionary:
	var status := get_underwater_runtime_debug_status()
	status.merge({
		"postprocess_enabled": (
			(_compositor_effect != null and _compositor_effect.enabled)
			or _fallback_active
		),
		"blur_strength": blur_strength,
		"blur_passes": blur_passes,
		"entry_bubbles_amount": (
			_bubble_particles.amount if _bubble_particles != null else 0
		),
		"effect_strength": _effect_strength,
		"is_underwater": _is_underwater,
		"transition_active": (
			_crossing_transition != WaterCrossingTransition.NONE
		),
	}, true)
	return status


func get_underwater_runtime_debug_status() -> Dictionary:
	var compositor_status: Dictionary = {}
	if (
		_compositor_effect != null
		and _compositor_effect.has_method(&"get_runtime_debug_status")
	):
		compositor_status = _compositor_effect.call(
			&"get_runtime_debug_status"
		) as Dictionary
	var attached := (
		is_instance_valid(_compositor_camera)
		and _active_compositor != null
		and _compositor_camera.compositor == _active_compositor
	)
	var attached_effect_count := (
		_count_underwater_effects(_active_compositor) if attached else 0
	)
	var legacy_submersion := 0.0
	if _material != null:
		var shader_value: Variant = _material.get_shader_parameter(
			&"camera_submersion"
		)
		if shader_value is float:
			legacy_submersion = shader_value
	return {
		"effect_enabled": effect_enabled,
		"camera_valid": is_instance_valid(_camera),
		"post_process_valid": is_instance_valid(_post_process),
		"material_valid": is_instance_valid(_material),
		"ocean_valid": is_instance_valid(_ocean),
		"camera_position_y": (
			_camera.global_position.y if is_instance_valid(_camera) else INF
		),
		"sampled_surface_height": _sampled_surface_height,
		"camera_depth": _camera_depth,
		"enter_depth": enter_depth,
		"exit_clearance": exit_clearance,
		"is_underwater": _is_underwater,
		"effect_strength": _effect_strength,
		"force_mode": int(force_mode),
		"transition_mode": int(_crossing_transition),
		"transition_progress": _crossing_transition_progress,
		"compositor_effect_valid": _compositor_effect != null,
		"compositor_effect_enabled": (
			_compositor_effect != null and _compositor_effect.enabled
		),
		"compositor_attached": attached,
		"attached_underwater_effect_count": attached_effect_count,
		"compositor_prewarm_started": _compositor_prewarm_started,
		"compositor_prewarm_complete": _compositor_prewarm_complete,
		"compositor_runtime": compositor_status,
		"fallback_active": _fallback_active,
		"fallback_reason": _fallback_reason,
		"legacy_quad_visible": (
			is_instance_valid(_post_process) and _post_process.visible
		),
		"legacy_camera_submersion": legacy_submersion,
		"active_visual_route": (
			"legacy_quad"
			if _fallback_active
			else (
				"compositor"
				if _compositor_effect != null
				and _compositor_effect.enabled
				else "none"
			)
		),
	}


func _initialize_post_process() -> bool:
	_camera = get_parent() as Camera3D
	_post_process = get_node_or_null(post_process_path) as MeshInstance3D
	_bubble_particles = get_node_or_null(
		"WaterCrossingOverlay/EntryBubbles"
	) as GPUParticles2D
	if _post_process != null:
		var configured_material := (
			_post_process.material_override as ShaderMaterial
		)
		if (
			Engine.is_editor_hint()
			and configured_material != null
			and configured_material.shader == UNDERWATER_POST_PROCESS_SHADER
		):
			_material = configured_material
		elif configured_material != null:
			_material = configured_material.duplicate() as ShaderMaterial
		else:
			_material = ShaderMaterial.new()
		if _material.shader != UNDERWATER_POST_PROCESS_SHADER:
			_material.shader = UNDERWATER_POST_PROCESS_SHADER
		_material.render_priority = UNDERWATER_POST_PROCESS_RENDER_PRIORITY
		if _post_process.material_override != _material:
			_post_process.material_override = _material
		_post_process.visible = false
	return _camera != null and _material != null and _post_process != null


func _exit_tree() -> void:
	_restore_fullscreen_compositor()
	_restore_volumetric_fog()
	_restore_editor_preview_environment()
	_unregister_ocean_material()


func _process(delta: float) -> void:
	_update_bubble_particle_layout()
	if Engine.is_editor_hint():
		_process_editor_preview(delta)
		return

	if not effect_enabled:
		_effect_strength = 0.0
		_clear_crossing_transition()
		_update_fullscreen_compositor(0.0)
		_update_volumetric_fog(0.0)
		if _post_process != null:
			_post_process.visible = false
		return
	if not is_instance_valid(_ocean):
		_resolve_retry_time -= delta
		if _resolve_retry_time <= 0.0:
			_resolve_retry_time = 1.0
			_resolve_ocean()
		if not is_instance_valid(_ocean):
			_clear_crossing_transition()
			_update_fullscreen_compositor(0.0)
			_update_volumetric_fog(0.0)
			if _post_process != null:
				_post_process.visible = false
			return

	var camera_position := _camera.global_position
	_sampled_surface_height = _ocean.sample_height(camera_position)
	_camera_depth = _sampled_surface_height - camera_position.y
	var was_underwater := _is_underwater
	_update_detection_state()
	if _is_underwater != was_underwater:
		_start_crossing_transition(_is_underwater)
	_update_crossing_transition(delta)

	var target_strength := 0.0
	match force_mode:
		DebugForceMode.FORCE_AIR:
			target_strength = 0.0
		DebugForceMode.FORCE_UNDERWATER:
			target_strength = 1.0
		_:
			if _is_underwater:
				target_strength = 1.0
	# The visual state changes on the same frame as the water detector. Entry
	# and exit clearances remain as spatial hysteresis against wave flicker.
	_effect_strength = target_strength
	_push_look_parameters(false)
	_material.set_shader_parameter(&"camera_submersion", _effect_strength)
	_update_volumetric_fog(_effect_strength)
	_update_fullscreen_compositor(_effect_strength)


func _process_editor_preview(delta: float) -> void:
	if (
		_camera == null
		or _material == null
		or _post_process == null
	) and not _initialize_post_process():
		return
	var editor_camera := _get_editor_viewport_camera()
	if editor_camera != null:
		# The underwater preview is entirely compositor-driven. Clearing a
		# Camera3D override makes the viewport use the scene WorldEnvironment
		# again and also recovers overrides orphaned by tool-script hot reloads.
		editor_camera.environment = null
	if not editor_preview_enabled:
		_clear_crossing_transition()
		_update_fullscreen_compositor(0.0)
		_update_volumetric_fog(0.0)
		_post_process.visible = false
		return

	if not is_instance_valid(_ocean):
		_resolve_ocean()

	var preview_depth: float = editor_preview_camera_depth
	if editor_preview_mode == EditorPreviewMode.FOLLOW_VIEWPORT and is_instance_valid(_ocean):
		if is_instance_valid(editor_camera):
			var camera_position := editor_camera.global_position
			_sampled_surface_height = _ocean.sample_height(camera_position)
			preview_depth = _sampled_surface_height - camera_position.y

	var was_underwater := _is_underwater
	_camera_depth = preview_depth
	_update_detection_state()
	if editor_preview_mode == EditorPreviewMode.FULLY_UNDERWATER:
		_is_underwater = true
	if _is_underwater != was_underwater:
		_start_crossing_transition(_is_underwater)
	_update_crossing_transition(delta)
	var preview_submersion := 1.0 if _is_underwater else 0.0

	_effect_strength = preview_submersion
	_push_look_parameters(false)
	_material.set_shader_parameter(&"camera_submersion", preview_submersion)
	_update_volumetric_fog(preview_submersion)
	_update_fullscreen_compositor(preview_submersion)


func _update_fullscreen_compositor(strength: float) -> void:
	var active_strength := clampf(strength, 0.0, 1.0)
	var transition_active := (
		_crossing_transition != WaterCrossingTransition.NONE
		and crossing_transition_strength > 0.0001
	)
	var visual_active := active_strength > 0.0001 or transition_active
	if _compositor_effect == null:
		_set_legacy_fallback(
			visual_active,
			"compositor_effect_missing",
			active_strength
		)
		return
	var target_camera := _camera
	if Engine.is_editor_hint():
		target_camera = _get_editor_viewport_camera()
	if target_camera == null:
		_compositor_effect.enabled = false
		_set_legacy_fallback(
			visual_active,
			"target_camera_missing",
			active_strength
		)
		return
	if active_strength <= 0.0001 and not transition_active:
		if not _compositor_prewarm_in_progress:
			_compositor_effect.enabled = false
		_set_legacy_fallback(false, "", 0.0)
		return
	if not _ensure_fullscreen_compositor(target_camera):
		_compositor_effect.enabled = false
		_set_legacy_fallback(
			true,
			"compositor_attachment_failed",
			active_strength
		)
		return

	# Parameters must be current before the effect can receive its first render
	# callback. This avoids one-frame stale/default underwater output.
	_push_compositor_parameters(active_strength)

	var fallback_reason := ""
	var runtime_status := _get_compositor_runtime_status()
	if force_legacy_fallback:
		fallback_reason = "forced_for_testing"
	elif runtime_status.get("resource_initialization_failed", false):
		fallback_reason = str(
			runtime_status.get("last_error", "compute_initialization_failed")
		)
	elif (
		_compositor_prewarm_complete
		and runtime_status.get("resource_initialization_attempted", false)
		and not runtime_status.get("resources_ready", false)
	):
		fallback_reason = "compositor_compute_resources_unavailable"

	if not fallback_reason.is_empty():
		_compositor_effect.enabled = false
		_set_legacy_fallback(true, fallback_reason, active_strength)
		return

	_set_legacy_fallback(false, "", active_strength)
	_compositor_effect.enabled = true


func _push_compositor_parameters(active_strength: float) -> void:
	if _compositor_effect == null:
		return
	_compositor_effect.call(
		&"update_parameters",
		active_strength,
		blur_strength,
		blur_passes,
		int(_crossing_transition),
		_crossing_transition_progress,
		crossing_transition_strength,
		wet_lens_height_texture,
		wet_lens_zoom,
		wet_lens_warp_strength,
		wet_lens_fall_distance,
		wet_lens_wash_irregularity,
		wet_lens_wash_softness,
		wet_lens_texture_edge_feather,
		underwater_tint,
		underwater_fog_color,
		tint_strength,
		contrast,
		fog_density,
		fog_start_distance,
		underwater_visibility_radius,
		underwater_visibility_blend
	)


func _get_compositor_runtime_status() -> Dictionary:
	if (
		_compositor_effect == null
		or not _compositor_effect.has_method(&"get_runtime_debug_status")
	):
		return {}
	return _compositor_effect.call(&"get_runtime_debug_status") as Dictionary


func _set_legacy_fallback(
	active: bool,
	reason: String,
	active_strength: float
) -> void:
	_fallback_active = active
	_fallback_reason = reason if active else ""
	if _post_process == null:
		return
	var legacy_strength := clampf(active_strength, 0.0, 1.0)
	if active and legacy_strength <= 0.0001:
		match _crossing_transition:
			WaterCrossingTransition.ENTERING:
				legacy_strength = 1.0
			WaterCrossingTransition.EXITING:
				legacy_strength = 1.0 - _crossing_transition_progress
	if _material != null:
		_material.set_shader_parameter(
			&"camera_submersion",
			legacy_strength if active else active_strength
		)
	_post_process.visible = active and legacy_strength > 0.0001


func _prewarm_fullscreen_compositor() -> void:
	if (
		_compositor_prewarm_started
		or _compositor_effect == null
		or not is_inside_tree()
	):
		return
	_compositor_prewarm_started = true
	_compositor_prewarm_in_progress = true
	_trace_mark("UNDERWATER_PREWARM_BEGIN")
	var target_camera := _camera
	if Engine.is_editor_hint():
		target_camera = _get_editor_viewport_camera()
	if (
		target_camera == null
		or not _ensure_fullscreen_compositor(target_camera)
	):
		_trace_mark("UNDERWATER_PREWARM_END")
		_compositor_prewarm_in_progress = false
		_compositor_prewarm_complete = true
		return
	_push_compositor_parameters(0.0)
	_compositor_effect.enabled = false
	if _compositor_effect.has_method(&"initialize_compute_resources"):
		_compositor_effect.call(&"initialize_compute_resources")
	_trace_mark("UNDERWATER_PREWARM_END")
	_compositor_prewarm_in_progress = false
	_compositor_prewarm_complete = true


func _start_crossing_transition(entering_water: bool) -> void:
	_crossing_transition = (
		WaterCrossingTransition.ENTERING
		if entering_water
		else WaterCrossingTransition.EXITING
	)
	_crossing_transition_elapsed = 0.0
	_crossing_transition_progress = 0.0
	if _bubble_particles == null:
		return
	if entering_water:
		# The particle node owns its texture/material. This deliberately
		# preserves scene-local GradientTexture2D or sprite overrides.
		_bubble_particles.visible = _bubble_particles.texture != null
		if _bubble_particles.visible:
			_update_bubble_particle_layout()
			_bubble_particles.restart()
			_bubble_particles.emitting = true
	else:
		# A new crossing always replaces the previous one. Stop and hide the
		# entry burst immediately so bubbles can never remain visible in air.
		_bubble_particles.emitting = false
		_bubble_particles.visible = false


func _update_crossing_transition(delta: float) -> void:
	if _crossing_transition == WaterCrossingTransition.NONE:
		return
	var duration := (
		entry_transition_duration
		if _crossing_transition == WaterCrossingTransition.ENTERING
		else exit_transition_duration
	)
	_crossing_transition_elapsed += maxf(delta, 0.0)
	_crossing_transition_progress = clampf(
		_crossing_transition_elapsed / maxf(duration, 0.001),
		0.0,
		1.0
	)
	if _crossing_transition_progress >= 1.0:
		_clear_crossing_transition()


func _clear_crossing_transition() -> void:
	_crossing_transition = WaterCrossingTransition.NONE
	_crossing_transition_elapsed = 0.0
	_crossing_transition_progress = 1.0


func _update_bubble_particle_layout() -> void:
	if _bubble_particles == null:
		return
	var viewport_size := get_viewport().get_visible_rect().size
	if viewport_size.x <= 0.0 or viewport_size.y <= 0.0:
		return
	_bubble_particles.position = Vector2(
		viewport_size.x * 0.5,
		viewport_size.y * 0.88
	)
	var particle_material := (
		_bubble_particles.process_material as ParticleProcessMaterial
	)
	if particle_material != null:
		particle_material.emission_box_extents = Vector3(
			viewport_size.x * 0.48,
			viewport_size.y * 0.08,
			1.0
		)


func _ensure_fullscreen_compositor(target_camera: Camera3D) -> bool:
	if (
		target_camera == _compositor_camera
		and target_camera.compositor == _active_compositor
	):
		return _count_underwater_effects(_active_compositor) == 1
	_restore_fullscreen_compositor()
	_compositor_camera = target_camera
	_original_compositor = _remove_orphaned_underwater_effects(
		target_camera.compositor
	)
	if target_camera.compositor != _original_compositor:
		target_camera.compositor = _original_compositor
	if _original_compositor != null:
		_active_compositor = _original_compositor.duplicate(true) as Compositor
	else:
		_active_compositor = Compositor.new()
	var effects: Array[CompositorEffect] = []
	for existing_effect in _active_compositor.compositor_effects:
		effects.append(existing_effect)
	effects.append(_compositor_effect)
	_active_compositor.compositor_effects = effects
	target_camera.compositor = _active_compositor
	return (
		target_camera.compositor == _active_compositor
		and _count_underwater_effects(_active_compositor) == 1
	)


func _count_underwater_effects(compositor: Compositor) -> int:
	if compositor == null:
		return 0
	var count := 0
	for existing_effect in compositor.compositor_effects:
		if _is_underwater_compositor_effect(existing_effect):
			count += 1
	return count


func _remove_orphaned_underwater_effects(
	source_compositor: Compositor
) -> Compositor:
	if source_compositor == null:
		return null
	var contains_underwater_effect := false
	for existing_effect in source_compositor.compositor_effects:
		if _is_underwater_compositor_effect(existing_effect):
			contains_underwater_effect = true
			break
	if not contains_underwater_effect:
		return source_compositor

	var clean_compositor := source_compositor.duplicate(true) as Compositor
	var clean_effects: Array[CompositorEffect] = []
	for existing_effect in clean_compositor.compositor_effects:
		if not _is_underwater_compositor_effect(existing_effect):
			clean_effects.append(existing_effect)
	clean_compositor.compositor_effects = clean_effects
	return clean_compositor


func _is_underwater_compositor_effect(effect: CompositorEffect) -> bool:
	if effect == null:
		return false
	var effect_script := effect.get_script() as Script
	return (
		effect_script != null
		and effect_script.resource_path
		== UNDERWATER_COMPOSITOR_EFFECT_SCRIPT.resource_path
	)


func _restore_fullscreen_compositor() -> void:
	if (
		is_instance_valid(_compositor_camera)
		and _compositor_camera.compositor == _active_compositor
	):
		_compositor_camera.compositor = _original_compositor
	_compositor_camera = null
	_original_compositor = null
	_active_compositor = null


func _get_editor_viewport_camera() -> Camera3D:
	if Engine.is_editor_hint():
		var bridge_script := load(EDITOR_INTERFACE_BRIDGE_PATH) as Script
		if bridge_script != null:
			var bridge := bridge_script.new() as RefCounted
			var editor_camera := (
				bridge.call(&"get_editor_viewport_camera") as Camera3D
			)
			if editor_camera != null:
				return editor_camera
	return get_viewport().get_camera_3d()


func _update_volumetric_fog(strength: float) -> void:
	if Engine.is_editor_hint():
		# Never mutate the editor viewport Environment. Tool-script hot reloads
		# can outlive the controller state and leave the preview fog enabled
		# above water. The compositor already previews the complete underwater
		# look in the editor; real volumetric fog is runtime-only.
		_restore_volumetric_fog()
		_restore_editor_preview_environment()
		return
	var active_strength := clampf(strength, 0.0, 1.0)
	if active_strength <= 0.001:
		_restore_volumetric_fog()
		return
	var environment := _get_active_environment()
	if environment == null:
		return
	if environment != _fog_environment:
		_restore_volumetric_fog()
		_fog_environment = environment
		_fog_environment_original = {
			&"depth_fog_enabled": environment.fog_enabled,
			&"enabled": environment.volumetric_fog_enabled,
			&"density": environment.volumetric_fog_density,
			&"albedo": environment.volumetric_fog_albedo,
			&"emission": environment.volumetric_fog_emission,
			&"emission_energy": environment.volumetric_fog_emission_energy,
			&"length": environment.volumetric_fog_length,
			&"detail_spread": environment.volumetric_fog_detail_spread,
			&"ambient_inject": environment.volumetric_fog_ambient_inject,
			&"sky_affect": environment.volumetric_fog_sky_affect,
		}
	environment.fog_enabled = false
	environment.volumetric_fog_enabled = true
	environment.volumetric_fog_density = maxf(
		fog_density * active_strength,
		0.0001
	)
	environment.volumetric_fog_albedo = underwater_fog_color
	environment.volumetric_fog_emission = underwater_fog_color
	environment.volumetric_fog_emission_energy = 0.35 * active_strength
	# The volume's own edge is deliberately kept far behind the post-process
	# extinction radius. Otherwise its finite spherical boundary becomes visible.
	environment.volumetric_fog_length = maxf(
		underwater_visibility_radius + underwater_visibility_blend * 4.0,
		512.0
	)
	environment.volumetric_fog_detail_spread = 2.0
	environment.volumetric_fog_ambient_inject = 1.0
	environment.volumetric_fog_sky_affect = 1.0


func _get_active_environment() -> Environment:
	if Engine.is_editor_hint():
		var editor_camera := _get_editor_viewport_camera()
		if editor_camera != null:
			return _ensure_editor_preview_environment(editor_camera)
	if _camera != null and _camera.get_world_3d() != null:
		return _camera.get_world_3d().environment
	return null


func _ensure_editor_preview_environment(
	editor_camera: Camera3D
) -> Environment:
	if (
		editor_camera == _preview_environment_camera
		and editor_camera.environment == _preview_environment
	):
		return _preview_environment
	_restore_volumetric_fog()
	_restore_editor_preview_environment()
	var source_environment := editor_camera.environment
	if source_environment == null and editor_camera.get_world_3d() != null:
		source_environment = editor_camera.get_world_3d().environment
	if source_environment == null:
		return null
	_preview_environment_camera = editor_camera
	_preview_original_environment = editor_camera.environment
	_preview_environment = source_environment.duplicate(true) as Environment
	editor_camera.environment = _preview_environment
	return _preview_environment


func _restore_editor_preview_environment() -> void:
	if (
		is_instance_valid(_preview_environment_camera)
		and _preview_environment_camera.environment == _preview_environment
	):
		_preview_environment_camera.environment = _preview_original_environment
	_preview_environment_camera = null
	_preview_original_environment = null
	_preview_environment = null


func _restore_volumetric_fog() -> void:
	if _fog_environment == null or _fog_environment_original.is_empty():
		_fog_environment = null
		_fog_environment_original.clear()
		return
	_fog_environment.fog_enabled = _fog_environment_original[&"depth_fog_enabled"]
	_fog_environment.volumetric_fog_enabled = _fog_environment_original[&"enabled"]
	_fog_environment.volumetric_fog_density = _fog_environment_original[&"density"]
	_fog_environment.volumetric_fog_albedo = _fog_environment_original[&"albedo"]
	_fog_environment.volumetric_fog_emission = _fog_environment_original[&"emission"]
	_fog_environment.volumetric_fog_emission_energy = (
		_fog_environment_original[&"emission_energy"]
	)
	_fog_environment.volumetric_fog_length = _fog_environment_original[&"length"]
	_fog_environment.volumetric_fog_detail_spread = (
		_fog_environment_original[&"detail_spread"]
	)
	_fog_environment.volumetric_fog_ambient_inject = (
		_fog_environment_original[&"ambient_inject"]
	)
	_fog_environment.volumetric_fog_sky_affect = (
		_fog_environment_original[&"sky_affect"]
	)
	_fog_environment = null
	_fog_environment_original.clear()


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
		_push_look_parameters(true)


func _find_matching_ocean() -> Ocean3D:
	var tree := get_tree()
	if tree == null:
		return null
	var scene_root := tree.current_scene
	if scene_root == null:
		scene_root = tree.root
	if scene_root == null:
		return null
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
		underwater_fog_color,
		fog_density,
		fog_start_distance,
		blur_strength,
		underwater_visibility_radius,
		underwater_visibility_blend,
		underwater_surface_alpha,
		debug_mode,
	])
	if not force_update and signature == _look_signature:
		return
	_look_signature = signature
	_material.set_shader_parameter(&"underwater_tint", underwater_tint)
	_material.set_shader_parameter(&"tint_strength", tint_strength)
	_material.set_shader_parameter(&"contrast", contrast)
	_material.set_shader_parameter(&"fog_tint", underwater_fog_color)
	_material.set_shader_parameter(&"fog_density", fog_density)
	_material.set_shader_parameter(
		&"fog_start_distance",
		fog_start_distance
	)
	_material.set_shader_parameter(&"blur_strength", blur_strength)
	_material.set_shader_parameter(
		&"underwater_visibility_radius",
		underwater_visibility_radius
	)
	_material.set_shader_parameter(
		&"underwater_visibility_blend",
		underwater_visibility_blend
	)
	_material.set_shader_parameter(&"debug_mode", debug_mode)
	_push_ocean_underwater_parameters()


func _push_ocean_underwater_parameters() -> void:
	if not is_instance_valid(_ocean) or _ocean.ocean_material == null:
		return
	var ocean_material := _ocean.ocean_material
	ocean_material.set_shader_parameter(
		&"underwater_surface_fog_color",
		underwater_fog_color
	)
	ocean_material.set_shader_parameter(
		&"underwater_surface_fog_density",
		fog_density
	)
	ocean_material.set_shader_parameter(
		&"underwater_surface_fog_start_distance",
		fog_start_distance
	)
	ocean_material.set_shader_parameter(
		&"underwater_visibility_radius",
		underwater_visibility_radius
	)
	ocean_material.set_shader_parameter(
		&"underwater_visibility_blend",
		underwater_visibility_blend
	)
	ocean_material.set_shader_parameter(
		&"underwater_surface_alpha",
		underwater_surface_alpha
	)


func _trace_mark(label: String) -> void:
	if not Engine.is_editor_hint():
		LoadTrace.mark(label)
