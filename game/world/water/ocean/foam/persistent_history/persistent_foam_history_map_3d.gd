class_name PersistentFoamHistoryMap3D
extends Node3D

## Persistent Foam V2 - HISTORY MAP backend.
##
## A GPU-backed global foam history for the ocean. THE OCEAN OWNS ONE INSTANCE
## AS A CHILD; water vehicles are only deposit SOURCES. This replaces the
## CPU-authoritative splat list of PersistentFoamMask3D: there is NO long-lived
## CPU history. Vehicles submit short-lived PersistentFoamDepositCommands that
## are rasterized into the single-use deposit viewport, merged into the history
## texture by the update pass, then forgotten.
##
## History = two ping-pong SubViewports holding RGBA state per pixel (see
## PersistentFoamHistoryState for the channel layout). State advances on a
## fixed 30 Hz cadence with no catch-up loop (a slow frame advances only one
## step, clamped). Growth, fade-in and reinforcement are pure shader math.

const DEFAULT_HISTORY_TEXTURE_RESOLUTION := 1024
const DEFAULT_HISTORY_WORLD_SIZE := 512.0
const DEFAULT_HISTORY_UPDATE_HZ := 30.0
const ANCHOR_STEP := 128.0
const ANCHOR_FOLLOW_MARGIN := 42.0
const MAX_DT_RATIO_PER_STEP := 0.15

@export_enum("1024", "2048") var history_texture_resolution: int = DEFAULT_HISTORY_TEXTURE_RESOLUTION:
	set(value):
		var supported := 2048 if value >= 2048 else 1024
		if history_texture_resolution == supported:
			return
		history_texture_resolution = supported
		_reconfigure_history_storage()
@export_range(64.0, 4096.0, 1.0, "suffix:m") var history_world_size: float = DEFAULT_HISTORY_WORLD_SIZE:
	set(value):
		var sanitized := maxf(value, 1.0)
		if is_equal_approx(history_world_size, sanitized):
			return
		history_world_size = sanitized
		_reconfigure_history_storage()
@export_enum("15", "20", "30") var history_update_hz: int = int(DEFAULT_HISTORY_UPDATE_HZ):
	set(value):
		var supported := 30 if value >= 25 else (20 if value >= 18 else 15)
		if history_update_hz == supported:
			return
		history_update_hz = supported
		_touch_history_params()

var enabled: bool = false:
	set(value):
		if enabled == value:
			return
		enabled = value
		_touch_history_params()
		_update_active()
		_register_with_ocean()
		if enabled:
			_clear_all_viewports()

var lifetime: float = 20.0:
	set(value):
		if is_equal_approx(lifetime, value):
			return
		lifetime = value
		_touch_history_params()
var size_min: float = 0.65:
	set(value):
		if is_equal_approx(size_min, value):
			return
		size_min = value
		_touch_history_params()
var size_max: float = 1.65:
	set(value):
		if is_equal_approx(size_max, value):
			return
		size_max = value
		_touch_history_params()
var fade_in_ratio: float = 0.10:
	set(value):
		if is_equal_approx(fade_in_ratio, value):
			return
		fade_in_ratio = value
		_touch_history_params()
var fade_out_start_ratio: float = 0.70:
	set(value):
		if is_equal_approx(fade_out_start_ratio, value):
			return
		fade_out_start_ratio = value
		_touch_history_params()

var strength: float = 1.0:
	set(value):
		if is_equal_approx(strength, value):
			return
		strength = value
		_touch_history_params()

var position_jitter: float = 0.65:
	set(value):
		if is_equal_approx(position_jitter, value):
			return
		position_jitter = value
		_touch_history_params()
var rotation_random_deg: float = 55.0:
	set(value):
		if is_equal_approx(rotation_random_deg, value):
			return
		rotation_random_deg = value
		_touch_history_params()
var scale_random_min: float = 0.65:
	set(value):
		if is_equal_approx(scale_random_min, value):
			return
		scale_random_min = value
		_touch_history_params()
var scale_random_max: float = 1.35:
	set(value):
		if is_equal_approx(scale_random_max, value):
			return
		scale_random_max = value
		_touch_history_params()
var aspect_min: float = 0.55:
	set(value):
		if is_equal_approx(aspect_min, value):
			return
		aspect_min = value
		_touch_history_params()
var aspect_max: float = 1.45:
	set(value):
		if is_equal_approx(aspect_max, value):
			return
		aspect_max = value
		_touch_history_params()

var irregularity: float = 0.80:
	set(value):
		if is_equal_approx(irregularity, value):
			return
		irregularity = value
		_touch_history_params()
var noise_scale: float = 0.12:
	set(value):
		if is_equal_approx(noise_scale, value):
			return
		noise_scale = value
		_touch_history_params()
var noise_threshold: float = 0.48:
	set(value):
		if is_equal_approx(noise_threshold, value):
			return
		noise_threshold = value
		_touch_history_params()
var foam_color: Color = Color(0.90, 0.97, 1.0, 1.0):
	set(value):
		if foam_color == value:
			return
		foam_color = value
		_touch_history_params()
var emission: float = 0.0:
	set(value):
		if is_equal_approx(emission, value):
			return
		emission = value
		_touch_history_params()
var roughness: float = 0.88:
	set(value):
		if is_equal_approx(roughness, value):
			return
		roughness = value
		_touch_history_params()
var specular: float = 0.16:
	set(value):
		if is_equal_approx(specular, value):
			return
		specular = value
		_touch_history_params()

var deposit_count: int = 0
var update_count: int = 0
var rebase_count: int = 0
var anchor_count: int = 0

var _ocean: Ocean3D
var _write_index: int = 0
var _accumulated_time: float = 0.0
var _pending: Array[PersistentFoamDepositCommand] = []
var _published_anchor_xz := Vector2.ZERO
var _target_anchor_xz := Vector2.ZERO
var _anchor_initialized: bool = false
var _last_deposit_xz := Vector2.ZERO
var _has_last_deposit: bool = false
var _rng := RandomNumberGenerator.new()
var _rng_seeded: bool = false

var _history_viewports: Array[SubViewport] = []
var _update_rects: Array[ColorRect] = []
var _clear_rects: Array[ColorRect] = []
var _deposit_viewport: SubViewport
var _deposit_canvas: Control
var _deposit_clear_rect: ColorRect
var _history_params_version: int = 0
var _clear_serial: int = 0
var _update_serial: int = 0
var _update_in_flight: bool = false
var _queued_dt_ratio: float = 0.0
var _queued_remap_delta_uv := Vector2.ZERO
var _queued_anchor_xz := Vector2.ZERO
var _settings_owner_source_id: int = 0
var _settings_owner_conflict_reported: bool = false


func _ready() -> void:
	## Runs after vehicles (priority 20) and the splat mask (priority 22) so
	## this frame's deposit submissions are consumed by the next GPU pass.
	process_physics_priority = 23
	_history_viewports = [
		$HistoryA as SubViewport,
		$HistoryB as SubViewport,
	]
	_update_rects = [
		$HistoryA/UpdateRect as ColorRect,
		$HistoryB/UpdateRect as ColorRect,
	]
	_clear_rects = [
		$HistoryA/ClearRect as ColorRect,
		$HistoryB/ClearRect as ColorRect,
	]
	_deposit_viewport = $DepositViewport as SubViewport
	_deposit_canvas = $DepositViewport/DepositCanvas as Control
	_deposit_clear_rect = $DepositViewport/ClearRect as ColorRect
	if is_instance_valid(_deposit_canvas):
		_deposit_canvas.world_size = history_world_size
	for history_viewport in _history_viewports:
		history_viewport.size = Vector2i(history_texture_resolution, history_texture_resolution)
	if is_instance_valid(_deposit_viewport):
		_deposit_viewport.size = Vector2i(history_texture_resolution, history_texture_resolution)
	_update_active()
	if enabled:
		_clear_all_viewports()


func configure(ocean: Ocean3D, initial_world_xz: Vector2) -> void:
	_ocean = ocean
	if not _anchor_initialized:
		_published_anchor_xz = _snap_anchor(initial_world_xz)
		_target_anchor_xz = _published_anchor_xz
		_anchor_initialized = true
		_sync_anchor()
	_register_with_ocean()


func _register_with_ocean() -> void:
	if not is_instance_valid(_ocean):
		return
	if enabled:
		_ocean.set_persistent_foam_history_provider(self)
	else:
		_ocean.clear_persistent_foam_history_provider()


## Called by a water vehicle (or anything) to request a new foam stamp. The
## command is consumed on the next history update; nothing is kept on the CPU
## afterward.
func submit_deposit(
	source_id: int,
	world_xz: Vector2,
	forward_xz: Vector2,
	radius: float,
	intensity: float
) -> PersistentFoamDepositCommand:
	if not enabled:
		return null
	if not world_xz.is_finite() or radius <= 0.0:
		return null
	_roll_randomness()
	var randomness := PersistentFoamDepositCommand.roll_randomness(
		_rng,
		world_xz,
		forward_xz,
		position_jitter,
		rotation_random_deg,
		scale_random_min,
		scale_random_max,
		aspect_min,
		aspect_max
	)
	var deposit := PersistentFoamDepositCommand.new()
	deposit.source_id = source_id
	deposit.world_xz = randomness.get(&"position")
	deposit.forward_xz = forward_xz
	## The history texture stores the final footprint; growth in the ocean shader
	## reveals it from size_min to this true size_max multiplier.
	deposit.radius = maxf(radius * size_max, 0.05)
	deposit.intensity = clampf(intensity, 0.05, 1.0)
	deposit.rotation = randomness.get(&"rotation")
	deposit.scale_x = randomness.get(&"scale_x")
	deposit.scale_y = randomness.get(&"scale_y")
	_pending.append(deposit)
	_last_deposit_xz = deposit.world_xz
	_has_last_deposit = true
	deposit_count += 1
	return deposit


func apply_world_rebase(shift: Vector3) -> void:
	## WorldOriginController increases logical_origin by shift and moves local
	## nodes by -shift. The map stores local XZ, so its anchor must move by
	## -shift to preserve each foam sample's logical world location.
	var shift_xz := Vector2(shift.x, shift.z)
	_published_anchor_xz -= shift_xz
	_target_anchor_xz -= shift_xz
	_queued_anchor_xz -= shift_xz
	if _has_last_deposit:
		_last_deposit_xz -= shift_xz
	for pending_deposit: PersistentFoamDepositCommand in _pending:
		pending_deposit.world_xz -= shift_xz
	rebase_count += 1
	_touch_history_params()
	_sync_anchor()


func clear_history() -> void:
	_pending.clear()
	_update_in_flight = false
	if is_instance_valid(_deposit_canvas):
		_deposit_canvas.clear_stamps()
	_clear_all_viewports()
	_accumulated_time = 0.0
	update_count = 0
	_write_index = 0
	_touch_history_params()


func request_settings_owner(source_id: int) -> bool:
	if source_id == 0:
		return false
	if _settings_owner_source_id == 0 or _settings_owner_source_id == source_id:
		_settings_owner_source_id = source_id
		return true
	if not _settings_owner_conflict_reported:
		push_warning("Persistent Foam HISTORY_MAP already has a global settings owner; later sources remain deposit-only.")
		_settings_owner_conflict_reported = true
	return false


func release_settings_owner(source_id: int) -> void:
	if _settings_owner_source_id == source_id:
		_settings_owner_source_id = 0
		_settings_owner_conflict_reported = false


func apply_owner_settings(source_id: int, settings: Dictionary) -> void:
	if not request_settings_owner(source_id):
		return
	for property_name: StringName in settings:
		set(property_name, settings[property_name])


func _physics_process(delta: float) -> void:
	if not enabled or Engine.is_editor_hint():
		return
	_track_anchor()
	## Time is always accumulated, including while an asynchronous GPU pass is
	## in flight. Work remains bounded to one pass per physics opportunity.
	_accumulated_time += maxf(delta, 0.0)
	if _update_in_flight or _accumulated_time < _update_interval():
		return
	## Preserve backlog for later bounded passes; never discard elapsed time and
	## never launch a catch-up loop.
	var step_time := minf(_accumulated_time, lifetime * MAX_DT_RATIO_PER_STEP)
	_accumulated_time -= step_time
	var dt_ratio := clampf(
		step_time / maxf(lifetime, 0.001),
		0.0,
		MAX_DT_RATIO_PER_STEP
	)
	_run_update_pass(dt_ratio)


func _track_anchor() -> void:
	if not is_instance_valid(_ocean):
		return
	var target := _resolve_anchor_target()
	if not target.is_finite():
		return
	if not _anchor_initialized:
		_published_anchor_xz = _snap_anchor(target)
		_target_anchor_xz = _published_anchor_xz
		_anchor_initialized = true
		_sync_anchor()
		return
	var offset := target - _target_anchor_xz
	var safe_half := history_world_size * 0.5 - ANCHOR_FOLLOW_MARGIN
	if absf(offset.x) <= safe_half and absf(offset.y) <= safe_half:
		return
	var shift := Vector2(
		floorf(offset.x / ANCHOR_STEP) * ANCHOR_STEP,
		floorf(offset.y / ANCHOR_STEP) * ANCHOR_STEP
	)
	if shift.is_zero_approx():
		return
	_target_anchor_xz += shift
	anchor_count += 1
	_touch_history_params()
	if is_instance_valid(_deposit_canvas):
		_deposit_canvas.anchor_xz = _target_anchor_xz


func _snap_anchor(value: Vector2) -> Vector2:
	return Vector2(
		floorf(value.x / ANCHOR_STEP) * ANCHOR_STEP,
		floorf(value.y / ANCHOR_STEP) * ANCHOR_STEP
	)


func _resolve_anchor_target() -> Vector2:
	if is_instance_valid(_ocean.follow_target):
		return Vector2(_ocean.follow_target.global_position.x, _ocean.follow_target.global_position.z)
	if is_instance_valid(_ocean.follow_camera):
		return Vector2(_ocean.follow_camera.global_position.x, _ocean.follow_camera.global_position.z)
	var viewport := get_viewport()
	var active_camera := viewport.get_camera_3d() if is_instance_valid(viewport) else null
	if is_instance_valid(active_camera):
		return Vector2(active_camera.global_position.x, active_camera.global_position.z)
	if _has_last_deposit:
		return _last_deposit_xz
	return _target_anchor_xz if _anchor_initialized else Vector2.ZERO


func _update_interval() -> float:
	return 1.0 / maxf(float(history_update_hz), 1.0)


func _reconfigure_history_storage() -> void:
	if is_instance_valid(_deposit_canvas):
		_deposit_canvas.world_size = history_world_size
		_deposit_canvas.anchor_xz = _target_anchor_xz
	for history_viewport in _history_viewports:
		if is_instance_valid(history_viewport):
			history_viewport.size = Vector2i(history_texture_resolution, history_texture_resolution)
	if is_instance_valid(_deposit_viewport):
		_deposit_viewport.size = Vector2i(history_texture_resolution, history_texture_resolution)
	clear_history()


func _sync_anchor() -> void:
	if is_instance_valid(_deposit_canvas):
		_deposit_canvas.anchor_xz = _target_anchor_xz


## Re-centers the GPU map by a discrete anchor step. The stored foam pattern is
## REMAPPED on the GPU in the next update pass: the update shader re-samples the
## old history at UV + shift, so no CPU rebuild is needed.
func _run_update_pass(dt_ratio: float) -> void:
	## Rasterize deposits first. The history pass is deferred until the next
	## frame because SubViewports update asynchronously in Godot 4.7.
	if _update_in_flight or not is_inside_tree():
		return
	_update_in_flight = true
	_update_serial += 1
	var serial := _update_serial
	_queued_dt_ratio = dt_ratio
	_queued_anchor_xz = _target_anchor_xz
	_queued_remap_delta_uv = (_queued_anchor_xz - _published_anchor_xz) / history_world_size
	if is_instance_valid(_deposit_canvas):
		_deposit_canvas.stamps = _pending.duplicate()
		_deposit_canvas.mark_dirty()
	_pending.clear()
	_render_viewport_now(_deposit_viewport)
	call_deferred("_complete_update_pass", serial)


func _complete_update_pass(serial: int) -> void:
	## UPDATE_ONCE is completed by the renderer, not by the next CPU process
	## tick. Gold City can execute several process ticks while a heavy frame is
	## still rendering, so process_frame could merge or clear a deposit texture
	## before the requested viewport draw had happened.
	await RenderingServer.frame_post_draw
	if serial != _update_serial or not _update_in_flight:
		return
	var read_viewport := _history_viewports[1 - _write_index]
	var write_viewport := _history_viewports[_write_index]
	var history_update_rect := _update_rects[_write_index]
	history_update_rect.material.set_shader_parameter(
		&"history_texture",
		read_viewport.get_texture()
	)
	history_update_rect.material.set_shader_parameter(
		&"deposit_texture",
		_deposit_viewport.get_texture()
	)
	history_update_rect.material.set_shader_parameter(&"dt_ratio", _queued_dt_ratio)
	history_update_rect.material.set_shader_parameter(&"fade_out_start_ratio", fade_out_start_ratio)
	history_update_rect.material.set_shader_parameter(&"remap_delta_uv", _queued_remap_delta_uv)
	_render_viewport_now(write_viewport)
	await RenderingServer.frame_post_draw
	if serial != _update_serial:
		return
	_write_index = 1 - _write_index
	## Publish the matching anchor only after its remapped texture is current.
	_published_anchor_xz = _queued_anchor_xz
	update_count += 1
	_touch_history_params()
	## Deposit viewport is single-use: clear it for the next pass.
	if is_instance_valid(_deposit_canvas):
		_deposit_canvas.clear_stamps()
		## Clearing the Control queues a redraw, but this viewport otherwise
		## remains UPDATE_ONCE with its previous stamp pixels still readable.
		_render_viewport_now(_deposit_viewport)
	_update_in_flight = false


func _render_viewport_now(viewport: SubViewport) -> void:
	if not is_instance_valid(viewport):
		return
	viewport.render_target_update_mode = SubViewport.UPDATE_ONCE


func _clear_all_viewports() -> void:
	_clear_serial += 1
	_update_serial += 1
	for index in _history_viewports.size():
		var viewport := _history_viewports[index]
		if not is_instance_valid(viewport):
			continue
		var history_update_rect := _update_rects[index] if index < _update_rects.size() else null
		var history_clear_rect := _clear_rects[index] if index < _clear_rects.size() else null
		if is_instance_valid(history_update_rect):
			history_update_rect.visible = false
		if is_instance_valid(history_clear_rect):
			history_clear_rect.visible = true
		_render_viewport_now(viewport)
	if is_instance_valid(_deposit_viewport):
		if is_instance_valid(_deposit_canvas):
			_deposit_canvas.visible = false
		if is_instance_valid(_deposit_clear_rect):
			_deposit_clear_rect.visible = true
		_render_viewport_now(_deposit_viewport)
	if is_inside_tree():
		call_deferred("_finish_gpu_clear", _clear_serial)


func _finish_gpu_clear(serial: int) -> void:
	## UPDATE_ONCE renders on the next frame. Keep the clear rects visible until
	## that frame has completed, otherwise the old feedback texture survives.
	await RenderingServer.frame_post_draw
	if serial != _clear_serial:
		return
	for index in _history_viewports.size():
		var history_update_rect := _update_rects[index] if index < _update_rects.size() else null
		var history_clear_rect := _clear_rects[index] if index < _clear_rects.size() else null
		if is_instance_valid(history_clear_rect):
			history_clear_rect.visible = false
		if is_instance_valid(history_update_rect):
			history_update_rect.visible = true
	if is_instance_valid(_deposit_clear_rect):
		_deposit_clear_rect.visible = false
	if is_instance_valid(_deposit_canvas):
		_deposit_canvas.visible = true


func _roll_randomness() -> void:
	if _rng_seeded:
		return
	_rng.randomize()
	_rng_seeded = true


func _update_active() -> void:
	set_physics_process(not Engine.is_editor_hint() and enabled)


func get_history_texture() -> Texture2D:
	if _history_viewports.is_empty():
		return null
	return _history_viewports[1 - _write_index].get_texture()


func get_history_anchor_xz() -> Vector2:
	return _published_anchor_xz


func get_history_world_size() -> float:
	return history_world_size


func get_history_strength() -> float:
	return strength if enabled else 0.0


func get_history_size_min() -> float:
	return size_min


func get_history_size_max() -> float:
	return size_max


func get_history_fade_in_ratio() -> float:
	return fade_in_ratio


func get_history_fade_out_start_ratio() -> float:
	return fade_out_start_ratio


func get_history_irregularity() -> float:
	return irregularity


func get_history_noise_scale() -> float:
	return noise_scale


func get_history_noise_threshold() -> float:
	return noise_threshold


func get_history_color() -> Color:
	return foam_color


func get_history_emission() -> float:
	return emission


func get_history_roughness() -> float:
	return roughness


func get_history_specular() -> float:
	return specular


func is_history_enabled() -> bool:
	return enabled and is_inside_tree()


func get_history_params_version() -> int:
	return _history_params_version


func _touch_history_params() -> void:
	_history_params_version += 1


func begin_deposit_validation(count: int) -> int:
	return mini(count, _pending.size())


func get_deposit_validation_status() -> Dictionary:
	return {
		&"pending_count": _pending.size(),
		&"consumed_count": deposit_count - _pending.size(),
	}


func clear_deposit_validation() -> void:
	pass
