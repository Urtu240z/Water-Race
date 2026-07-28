class_name RiderMountedLeanController
extends Node

@export_group("Visual Scale")
@export_range(0.0, 2.0, 0.01) var automatic_turn_visual_scale: float = 1.0
@export_range(0.0, 2.0, 0.01) var manual_roll_visual_scale: float = 1.0
@export_range(0.0, 2.0, 0.01) var manual_pitch_visual_scale: float = 1.0

@export_group("Response")
@export_range(0.1, 30.0, 0.1) var automatic_turn_response_speed: float = 10.0
@export_range(0.1, 30.0, 0.1) var manual_lean_response_speed: float = 12.0

@export_group("Manual Preview")
@export var manual_preview_enabled: bool = false
@export_range(-1.0, 1.0, 0.01) var preview_automatic_turn: float = 0.0
@export_range(-1.0, 1.0, 0.01) var preview_manual_roll: float = 0.0
@export_range(-1.0, 1.0, 0.01) var preview_manual_pitch: float = 0.0

@export_group("Node Paths")
@export_node_path("Node3D") var rider_rig_path := NodePath(
	"../VisualRoot/RiderMount/RiderAssetRoot/RiderRig"
)

var _vehicle: JetSkiController
var _rider_rig: RiderRig
var _current_automatic_turn: float = 0.0
var _current_manual_roll: float = 0.0
var _current_manual_pitch: float = 0.0
var _reset_hold_physics_frames: int = 0


func _ready() -> void:
	_vehicle = get_parent() as JetSkiController
	_rider_rig = get_node_or_null(rider_rig_path) as RiderRig
	if not is_instance_valid(_vehicle):
		push_error(
			"RiderMountedLeanController requires "
			+ "a JetSkiController parent."
		)
		set_physics_process(false)
		return
	if not is_instance_valid(_rider_rig):
		push_error(
			"RiderMountedLeanController could not resolve RiderRig."
		)
		set_physics_process(false)
		return
	_vehicle.reset_completed.connect(_on_vehicle_reset_completed)
	_vehicle.world_rebased.connect(_on_vehicle_world_rebased)
	_reset_blends(false)


func _physics_process(delta: float) -> void:
	if _reset_hold_physics_frames > 0:
		_reset_hold_physics_frames -= 1
		_reset_blends(false)
		return
	if manual_preview_enabled:
		_apply_manual_preview()
		return
	var automatic_turn_target := _automatic_turn_target()
	var manual_roll_target := clampf(
		_vehicle.rider_weight_shift_roll
		* manual_roll_visual_scale,
		-1.0,
		1.0
	)
	var manual_pitch_target := clampf(
		_vehicle.rider_weight_shift_pitch
		* manual_pitch_visual_scale,
		-1.0,
		1.0
	)
	if (
		_vehicle.navigation_state
		== JetSkiController.NavigationState.DEEP_SUBMERGED
	):
		manual_roll_target = 0.0
		manual_pitch_target = 0.0
	var automatic_weight := 1.0 - exp(
		-automatic_turn_response_speed * maxf(delta, 0.0)
	)
	var manual_weight := 1.0 - exp(
		-manual_lean_response_speed * maxf(delta, 0.0)
	)
	_current_automatic_turn = lerpf(
		_current_automatic_turn,
		automatic_turn_target,
		clampf(automatic_weight, 0.0, 1.0)
	)
	_current_manual_roll = lerpf(
		_current_manual_roll,
		manual_roll_target,
		clampf(manual_weight, 0.0, 1.0)
	)
	_current_manual_pitch = lerpf(
		_current_manual_pitch,
		manual_pitch_target,
		clampf(manual_weight, 0.0, 1.0)
	)
	_apply_current_blends()


func _automatic_turn_target() -> float:
	if (
		_vehicle.navigation_state
		== JetSkiController.NavigationState.DEEP_SUBMERGED
		or _vehicle.submarine_dive_active
	):
		return 0.0
	return clampf(
		_vehicle.steering_input * automatic_turn_visual_scale,
		-1.0,
		1.0
	)


func _apply_manual_preview() -> void:
	_current_automatic_turn = clampf(
		preview_automatic_turn * automatic_turn_visual_scale,
		-1.0,
		1.0
	)
	_current_manual_roll = clampf(
		preview_manual_roll * manual_roll_visual_scale,
		-1.0,
		1.0
	)
	_current_manual_pitch = clampf(
		preview_manual_pitch * manual_pitch_visual_scale,
		-1.0,
		1.0
	)
	_apply_current_blends()


func _apply_current_blends() -> void:
	_rider_rig.set_automatic_turn_blend(
		_current_automatic_turn
	)
	_rider_rig.set_manual_roll_blend(
		_current_manual_roll
	)
	_rider_rig.set_manual_pitch_blend(
		_current_manual_pitch
	)


func _reset_blends(hold_next_physics_frame: bool) -> void:
	_current_automatic_turn = 0.0
	_current_manual_roll = 0.0
	_current_manual_pitch = 0.0
	if hold_next_physics_frame:
		_reset_hold_physics_frames = 1
	if is_instance_valid(_rider_rig):
		_rider_rig.reset_mounted_lean_blends()


func _on_vehicle_reset_completed(_reason: StringName) -> void:
	_reset_blends(true)


func _on_vehicle_world_rebased(_shift: Vector3) -> void:
	_reset_blends(true)
