class_name PersistentFoamMask3D
extends Node3D

## Persistent Foam V2.
##
## CPU-authoritative deposited foam splats are rasterized into a bounded
## world-XZ mask texture (a SubViewport) that the ocean surface shader samples
## as foam coverage. The mask is NOT geometry: foam appears only through the
## ocean material, rides the exact displaced surface, and can never sink below
## waves. Deposited world XZ is immutable; only an explicit world rebase may
## shift it.
##
## The mask world area may follow the player in DISCRETE anchor steps. Moving
## the anchor only re-maps the same stored world XZ into the viewport; it never
## modifies stored positions.

const MASK_TEXTURE_PIXELS := 2048.0
const MASK_WORLD_SIZE := 512.0
const ANCHOR_STEP := 128.0
const ANCHOR_FOLLOW_MARGIN := 42.0
const FADE_REPAINT_INTERVAL := 0.1

const MINIMUM_SPEED := 4.0
const MINIMUM_CONTACT := 0.1

var enabled: bool = false:
	set(value):
		if enabled == value:
			return
		enabled = value
		_bump_mask_params()
		_register_with_ocean()
		_set_active()
var lifetime: float = 20.0:
	set(value):
		lifetime = value
		_sync_draw_dirty()
var sample_distance: float = 0.8:
	set(value):
		sample_distance = value
var maximum_points: int = 256:
	set(value):
		maximum_points = value
		_cull_to_limit()
		_sync_draw_dirty()
var width_multiplier: float = 1.0:
	set(value):
		width_multiplier = value
var strength: float = 1.0:
	set(value):
		if strength == value:
			return
		strength = value
		_bump_mask_params()
var fade_start_ratio: float = 0.70

var sample_count: int:
	get:
		return _splats.size()

var paint_count: int = 0
var rebase_count: int = 0

var _vehicle: JetSkiController
var _ocean: Ocean3D
var _propulsion_point: Marker3D
var _rear_left: Marker3D
var _rear_right: Marker3D
var _foam_settings: WaterFoamSettings
var _foam_noise_texture: Texture2D
var _splats: Array[PersistentFoamSplat] = []
var _sample_serial: int = 0
var _has_last_sample: bool = false
var _last_sample_position := Vector2.ZERO
var _was_generating: bool = false
var _anchor_xz := Vector2.ZERO
var _anchor_initialized: bool = false
var _mask_params_version: int = 0
var _fade_repaint_elapsed: float = 0.0
var _validation_origin_positions: Array[Vector2] = []
var _validation_serials: Array[int] = []

@onready var _viewport: SubViewport = $MaskViewport
@onready var _canvas: Control = $MaskViewport/MaskCanvas


func _ready() -> void:
	process_physics_priority = 22
	_configure_canvas()
	_sync_draw_dirty()
	_set_active()


func configure(
	vehicle: JetSkiController,
	ocean: Ocean3D,
	propulsion_point: Marker3D,
	rear_left: Marker3D = null,
	rear_right: Marker3D = null
) -> void:
	_vehicle = vehicle
	_ocean = ocean
	_propulsion_point = propulsion_point
	_rear_left = rear_left
	_rear_right = rear_right
	_bump_mask_params()
	_register_with_ocean()
	_update_anchor_from_vehicle()


func configure_foam(settings: WaterFoamSettings, noise_texture: Texture2D) -> void:
	_foam_settings = settings
	_foam_noise_texture = noise_texture


func clear_trail() -> void:
	_splats.clear()
	_has_last_sample = false
	_was_generating = false
	_last_sample_position = Vector2.ZERO
	_sync_draw_dirty()


func apply_world_rebase(shift: Vector3) -> void:
	var shift_xz := Vector2(shift.x, shift.z)
	for splat: PersistentFoamSplat in _splats:
		splat.position_xz += shift_xz
	_anchor_xz += shift_xz
	rebase_count += 1
	_bump_mask_params()
	_sync_draw_dirty()


func _physics_process(delta: float) -> void:
	if not enabled:
		return
	_update_anchor_from_vehicle()
	_update_deposition()
	_expire_splats()
	if _any_splat_fading():
		_fade_repaint_elapsed += delta
		if _fade_repaint_elapsed >= FADE_REPAINT_INTERVAL:
			_fade_repaint_elapsed = 0.0
			_sync_draw_dirty()
	else:
		_fade_repaint_elapsed = 0.0


func _set_active() -> void:
	set_physics_process(not Engine.is_editor_hint() and enabled)


func _can_deposit() -> bool:
	if (
		not is_instance_valid(_vehicle)
		or not is_instance_valid(_ocean)
		or not is_instance_valid(_propulsion_point)
	):
		return false
	if _vehicle.navigation_state == JetSkiController.NavigationState.AIRBORNE:
		return false
	if _vehicle.rear_submerged_ratio <= 0.0:
		return false
	if _vehicle.propulsion_contact_factor < MINIMUM_CONTACT:
		return false
	if absf(_vehicle.water_relative_forward_speed) < MINIMUM_SPEED:
		return false
	return true


func _update_deposition() -> void:
	var generating := _can_deposit()
	_was_generating = generating
	if not generating:
		return
	var position := _propulsion_point.global_position
	var position_xz := Vector2(position.x, position.z)
	if _has_last_sample and position_xz.distance_to(_last_sample_position) < sample_distance:
		return
	_append_sample(
		position_xz,
		_measured_hull_half_width() * width_multiplier,
		_measure_intensity()
	)


func _append_sample(
	position_xz: Vector2,
	half_width: float,
	foam_intensity: float
) -> PersistentFoamSplat:
	if not position_xz.is_finite():
		return null
	var splat := PersistentFoamSplat.new()
	splat.position_xz = position_xz
	splat.radius = maxf(half_width, 0.05)
	splat.intensity = clampf(foam_intensity, 0.05, 1.0)
	splat.birth_time = _viewport_time_now()
	splat.serial = _sample_serial
	_sample_serial += 1
	_splats.append(splat)
	_last_sample_position = position_xz
	_has_last_sample = true
	_cull_to_limit()
	_sync_draw_dirty()
	return splat


func _measured_hull_half_width() -> float:
	if (
		not is_instance_valid(_propulsion_point)
		or not is_instance_valid(_rear_left)
		or not is_instance_valid(_rear_right)
	):
		return 1.2
	var interior_separation := _rear_left.global_position.distance_to(
		_rear_right.global_position
	)
	if interior_separation > 0.01:
		return interior_separation * 0.5
	return 1.2


func _measure_intensity() -> float:
	if not is_instance_valid(_vehicle):
		return 1.0
	var speed_factor := clampf(
		absf(_vehicle.water_relative_forward_speed) / 14.0,
		0.35,
		1.0
	)
	return speed_factor


func _cull_to_limit() -> void:
	if maximum_points <= 0:
		return
	while _splats.size() > maximum_points:
		_splats.pop_front()
	if _splats.is_empty():
		_has_last_sample = false


func _any_splat_fading() -> bool:
	var now := _viewport_time_now()
	for splat: PersistentFoamSplat in _splats:
		var ratio := (now - splat.birth_time) / maxf(lifetime, 0.001)
		if ratio >= fade_start_ratio and ratio < 1.0:
			return true
	return false


func _expire_splats() -> void:
	var now := _viewport_time_now()
	var removed := false
	for index in range(_splats.size() - 1, -1, -1):
		if now - _splats[index].birth_time >= lifetime:
			_splats.remove_at(index)
			removed = true
	if removed:
		if _splats.is_empty():
			_has_last_sample = false
		_sync_draw_dirty()


func _update_anchor_from_vehicle() -> void:
	if not is_instance_valid(_vehicle):
		return
	var vehicle_xz := Vector2(_vehicle.global_position.x, _vehicle.global_position.z)
	if not _anchor_initialized:
		_anchor_xz = _snap_anchor(vehicle_xz)
		_anchor_initialized = true
		_bump_mask_params()
		_sync_draw_dirty()
		return
	var offset := vehicle_xz - _anchor_xz
	var safe_half := MASK_WORLD_SIZE * 0.5 - ANCHOR_FOLLOW_MARGIN
	if absf(offset.x) <= safe_half and absf(offset.y) <= safe_half:
		return
	var shift := Vector2(
		floorf(offset.x / ANCHOR_STEP) * ANCHOR_STEP,
		floorf(offset.y / ANCHOR_STEP) * ANCHOR_STEP
	)
	if shift.is_zero_approx():
		return
	_anchor_xz += shift
	_bump_mask_params()
	_sync_draw_dirty()


func _snap_anchor(value: Vector2) -> Vector2:
	return Vector2(
		floorf(value.x / ANCHOR_STEP) * ANCHOR_STEP,
		floorf(value.y / ANCHOR_STEP) * ANCHOR_STEP
	)


func _configure_canvas() -> void:
	if not is_instance_valid(_canvas):
		return
	_canvas.splats = _splats
	_canvas.mask_world_size = MASK_WORLD_SIZE
	_canvas.lifetime = lifetime
	_canvas.fade_start_ratio = fade_start_ratio


func _viewport_time_now() -> float:
	if is_instance_valid(_ocean):
		return _ocean.get_simulation_time()
	return Time.get_ticks_msec() * 0.001


func _sync_draw_dirty() -> void:
	if not is_instance_valid(_canvas) or not is_instance_valid(_viewport):
		return
	_canvas.viewport_time = _viewport_time_now()
	_canvas.mask_anchor_xz = _anchor_xz
	_canvas.lifetime = lifetime
	_canvas.fade_start_ratio = fade_start_ratio
	_canvas.mark_dirty()
	_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	paint_count += 1


func get_mask_texture() -> Texture2D:
	if not is_instance_valid(_viewport):
		return null
	return _viewport.get_texture()


func get_mask_anchor_xz() -> Vector2:
	return _anchor_xz


func get_mask_world_size() -> float:
	return MASK_WORLD_SIZE


func get_mask_strength() -> float:
	return strength if enabled else 0.0


func is_mask_enabled() -> bool:
	return enabled and is_inside_tree()


func get_mask_params_version() -> int:
	return _mask_params_version


func _bump_mask_params() -> void:
	_mask_params_version += 1


func _register_with_ocean() -> void:
	if not is_instance_valid(_ocean):
		return
	if enabled:
		_ocean.set_persistent_foam_mask_provider(self)
	else:
		_ocean.clear_persistent_foam_mask_provider()


func begin_position_validation(count: int) -> int:
	_validation_origin_positions.clear()
	_validation_serials.clear()
	var captured := mini(count, _splats.size())
	for splat_index in captured:
		var splat := _splats[splat_index]
		_validation_origin_positions.append(splat.position_xz)
		_validation_serials.append(splat.serial)
	return captured


func get_position_validation_status() -> Dictionary:
	var max_delta := 0.0
	var living := 0
	for validation_index in _validation_serials.size():
		var serial := _validation_serials[validation_index]
		for splat: PersistentFoamSplat in _splats:
			if splat.serial != serial:
				continue
			living += 1
			max_delta = maxf(
				max_delta,
				splat.position_xz.distance_to(_validation_origin_positions[validation_index])
			)
			break
	return {
		&"snapshot_count": _validation_origin_positions.size(),
		&"living_samples": living,
		&"max_horizontal_position_delta": max_delta,
	}


func clear_position_validation() -> void:
	_validation_origin_positions.clear()
	_validation_serials.clear()


func debug_deposit_sample(
	position: Vector3,
	_forward: Vector2 = Vector2.ZERO,
	half_width: float = 1.2,
	intensity: float = 1.0
) -> void:
	_append_sample(Vector2(position.x, position.z), half_width, intensity)