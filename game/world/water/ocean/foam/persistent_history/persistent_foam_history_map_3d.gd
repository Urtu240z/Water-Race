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

const HISTORY_TEXTURE_PIXELS := 1024.0
const HISTORY_WORLD_SIZE := 512.0
const ANCHOR_STEP := 128.0
const ANCHOR_FOLLOW_MARGIN := 42.0
const UPDATE_RATE := 30.0
const UPDATE_INTERVAL := 1.0 / UPDATE_RATE
const MAX_DT_RATIO_PER_STEP := 0.15

var enabled: bool = false:
	set(value):
		if enabled == value:
			return
		enabled = value
		_update_active()
		_register_with_ocean()
		if enabled:
			_clear_all_viewports()

var lifetime: float = 20.0:
	set(value):
		lifetime = value
var size_min: float = 0.65:
	set(value):
		size_min = value
var size_max: float = 1.65:
	set(value):
		size_max = value
var fade_in_ratio: float = 0.10:
	set(value):
		fade_in_ratio = value
var fade_out_start_ratio: float = 0.70:
	set(value):
		fade_out_start_ratio = value
var position_jitter: float = 0.65
var rotation_random_deg: float = 55.0
var scale_random_min: float = 0.65
var scale_random_max: float = 1.35
var aspect_min: float = 0.55
var aspect_max: float = 1.45

var irregularity: float = 0.80
var noise_scale: float = 0.12
var noise_threshold: float = 0.48
var foam_color: Color = Color(0.90, 0.97, 1.0, 1.0)
var emission: float = 0.0
var roughness: float = 0.88
var specular: float = 0.16

var deposit_count: int = 0
var update_count: int = 0
var rebase_count: int = 0
var anchor_count: int = 0

var _ocean: Ocean3D
var _write_index: int = 0
var _accumulated_time: float = 0.0
var _pending: Array[PersistentFoamDepositCommand] = []
var _anchor_xz := Vector2.ZERO
var _anchor_initialized: bool = false
var _remap_delta_uv := Vector2.ZERO
var _rng := RandomNumberGenerator.new()
var _rng_seeded: bool = false

var _history_viewports: Array[SubViewport] = []
var _update_rects: Array[ColorRect] = []
var _deposit_viewport: SubViewport
var _deposit_canvas: Control


func _ready() -> void:
	## Runs after vehicles (priority 20) and the splat mask (priority 22) so
	## this frame's deposit submissions are consumed in the same pass.
	process_physics_priority = 23
	_history_viewports = [
		$HistoryA as SubViewport,
		$HistoryB as SubViewport,
	]
	_update_rects = [
		$HistoryA/UpdateRect as ColorRect,
		$HistoryB/UpdateRect as ColorRect,
	]
	_deposit_viewport = $DepositViewport as SubViewport
	_deposit_canvas = $DepositViewport/DepositCanvas as Control
	if is_instance_valid(_deposit_canvas):
		_deposit_canvas.world_size = HISTORY_WORLD_SIZE
	_update_active()


func configure(ocean: Ocean3D, initial_world_xz: Vector2) -> void:
	_ocean = ocean
	if not _anchor_initialized:
		_anchor_xz = _snap_anchor(initial_world_xz)
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
	deposit.radius = maxf(radius, 0.05)
	deposit.intensity = clampf(intensity, 0.05, 1.0)
	deposit.rotation = randomness.get(&"rotation")
	deposit.scale_x = randomness.get(&"scale_x")
	deposit.scale_y = randomness.get(&"scale_y")
	_pending.append(deposit)
	deposit_count += 1
	return deposit


func apply_world_rebase(shift: Vector3) -> void:
	## The whole world shifted by `shift`; ONE global GPU map follows by moving
	## its anchor the same amount, so stored foam stays at the same logical
	## world XZ (REAL WorldOriginController semantics: foam shifts by
	## -horizontal_shift in the moved domain).
	_anchor_xz += Vector2(shift.x, shift.z)
	rebase_count += 1
	_sync_anchor()


func clear_history() -> void:
	_pending.clear()
	_clear_all_viewports()
	update_count = 0


func _physics_process(delta: float) -> void:
	if not enabled or Engine.is_editor_hint():
		return
	_track_anchor()
	_accumulated_time += delta
	if _accumulated_time < UPDATE_INTERVAL:
		return
	## Single step only: no catch-up loop. A slow frame advances the state by
	## just this one accumulated step (clamped), keeping the whole update in
	## sync with real elapsed time without stacking work.
	var step_time := minf(_accumulated_time, UPDATE_INTERVAL * 2.0)
	_accumulated_time = 0.0
	var dt_ratio := clampf(
		step_time / maxf(lifetime, 0.001),
		0.0,
		MAX_DT_RATIO_PER_STEP
	)
	_run_update_pass(dt_ratio)


func _track_anchor() -> void:
	if not is_instance_valid(_ocean):
		return
	var target := Vector2.ZERO
	if is_instance_valid(_ocean.follow_target):
		target = Vector2(_ocean.follow_target.global_position.x, _ocean.follow_target.global_position.z)
	if not _anchor_initialized:
		_anchor_xz = _snap_anchor(target)
		_anchor_initialized = true
		_sync_anchor()
		return
	var offset := target - _anchor_xz
	var safe_half := HISTORY_WORLD_SIZE * 0.5 - ANCHOR_FOLLOW_MARGIN
	if absf(offset.x) <= safe_half and absf(offset.y) <= safe_half:
		return
	var shift := Vector2(
		floorf(offset.x / ANCHOR_STEP) * ANCHOR_STEP,
		floorf(offset.y / ANCHOR_STEP) * ANCHOR_STEP
	)
	if shift.is_zero_approx():
		return
	_anchor_xz += shift
	anchor_count += 1
	_queue_anchor_remap(shift)
	_deposit_canvas.anchor_xz = _anchor_xz


func _snap_anchor(value: Vector2) -> Vector2:
	return Vector2(
		floorf(value.x / ANCHOR_STEP) * ANCHOR_STEP,
		floorf(value.y / ANCHOR_STEP) * ANCHOR_STEP
	)


func _sync_anchor() -> void:
	_remap_delta_uv = Vector2.ZERO
	if is_instance_valid(_deposit_canvas):
		_deposit_canvas.anchor_xz = _anchor_xz


## Re-centers the GPU map by a discrete anchor step. The stored foam pattern is
## REMAPPED on the GPU in the next update pass: the update shader re-samples the
## old history at UV + shift, so no CPU rebuild is needed.
func _queue_anchor_remap(shift_xz: Vector2) -> void:
	if shift_xz.is_zero_approx():
		return
	_remap_delta_uv = shift_xz / HISTORY_WORLD_SIZE
	anchor_count += 1


func _run_update_pass(dt_ratio: float) -> void:
	## Rasterize any pending stamps (single-use deposit map), then advance the
	## history state sampling the deposit map in the same pass.
	if is_instance_valid(_deposit_canvas):
		_deposit_canvas.stamps = _pending.duplicate()
		_deposit_canvas.mark_dirty()
	_pending.clear()
	_render_viewport_now(_deposit_viewport)
	var read_viewport := _history_viewports[1 - _write_index]
	var write_viewport := _history_viewports[_write_index]
	var update_rect := _update_rects[_write_index]
	update_rect.material.set_shader_parameter(
		&"history_texture",
		read_viewport.get_texture()
	)
	update_rect.material.set_shader_parameter(
		&"deposit_texture",
		_deposit_viewport.get_texture()
	)
	update_rect.material.set_shader_parameter(&"dt_ratio", dt_ratio)
	update_rect.material.set_shader_parameter(&"fade_in_ratio", fade_in_ratio)
	update_rect.material.set_shader_parameter(&"remap_delta_uv", _remap_delta_uv)
	_remap_delta_uv = Vector2.ZERO
	_render_viewport_now(write_viewport)
	_write_index = 1 - _write_index
	update_count += 1
	## Deposit viewport is single-use: clear it for the next pass.
	if is_instance_valid(_deposit_canvas):
		_deposit_canvas.clear_stamps()


func _render_viewport_now(viewport: SubViewport) -> void:
	if not is_instance_valid(viewport):
		return
	viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	viewport.update_worlds()


func _clear_all_viewports() -> void:
	for viewport in _history_viewports:
		if is_instance_valid(viewport):
			_render_viewport_now(viewport)
	if is_instance_valid(_deposit_viewport):
		_render_viewport_now(_deposit_viewport)


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
	return _anchor_xz


func get_history_world_size() -> float:
	return HISTORY_WORLD_SIZE


func get_history_strength() -> float:
	return 1.0 if enabled else 0.0


func get_history_size_min() -> float:
	return size_min


func get_history_size_max() -> float:
	return size_max


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
	return update_count


func begin_deposit_validation(count: int) -> int:
	return mini(count, _pending.size())


func get_deposit_validation_status() -> Dictionary:
	return {
		&"pending_count": _pending.size(),
		&"consumed_count": deposit_count - _pending.size(),
	}


func clear_deposit_validation() -> void:
	pass