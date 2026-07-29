class_name JetSkiController
extends RigidBody3D

signal reset_completed(reason: StringName)
signal world_rebased(shift: Vector3)
signal water_entered(intensity: float, position: Vector3)
signal water_exited()
signal hard_landing(intensity: float, position: Vector3)
signal deeply_submerged()
signal rider_weight_shift_changed(shift: Vector2)
signal submarine_dive_started()
signal submarine_dive_ended(duration: float, max_depth: float)

const NavigationState = JetSkiTypes.NavigationState
const LandingEntryType = JetSkiTypes.LandingEntryType

signal rider_trick_launched(
	trick_type: JetSkiTypes.RiderTrickLaunchType,
	charge: Vector2,
	release_strength: Vector2
)

const BUOYANCY_POINT_COUNT: int = 4
const LEFT_CONTACT_MASK: int = 5

@export_group("Water")
@export_node_path("Ocean3D") var ocean_path: NodePath

@export_group("Buoyancy")
@export_range(0.0, 50000.0, 10.0, "or_greater", "suffix:N/m") var buoyancy_strength_per_point: float = 5500.0
@export_range(0.0, 20000.0, 10.0, "or_greater", "suffix:N*s/m") var buoyancy_damping_per_point: float = 2500.0
@export_range(0.01, 10.0, 0.01, "or_greater", "suffix:m") var max_submersion_depth: float = 0.8
@export_range(0.01, 10.0, 0.01, "or_greater", "suffix:m") var deep_buoyancy_start_depth: float = 1.0
@export_range(0.0, 50000.0, 10.0, "or_greater", "suffix:N/m") var deep_buoyancy_strength_per_point: float = 3500.0
@export_range(0.0, 50000.0, 10.0, "or_greater", "suffix:N/m") var deep_buoyancy_force_limit_per_meter: float = 5000.0
@export_range(0.0, 50000.0, 10.0, "or_greater", "suffix:N") var max_buoyancy_force_per_point: float = 5500.0

@export_group("Hydrodynamics")
@export_range(0.0, 10000.0, 0.1, "or_greater") var forward_drag_linear_per_point: float = 15.0
@export_range(0.0, 10000.0, 0.1, "or_greater") var forward_drag_quadratic_per_point: float = 1.5
@export_range(0.0, 10000.0, 0.1, "or_greater") var lateral_drag_linear_per_point: float = 80.0
@export_range(0.0, 10000.0, 0.1, "or_greater") var lateral_drag_quadratic_per_point: float = 7.0
@export_range(0.01, 8.0, 0.01, "or_greater") var drag_depth_exponent: float = 1.0
@export_range(0.0, 50000.0, 10.0, "or_greater", "suffix:N") var maximum_forward_drag_force_per_point: float = 3500.0
@export_range(0.0, 50000.0, 10.0, "or_greater", "suffix:N") var maximum_lateral_drag_force_per_point: float = 7000.0

@export_group("Propulsion")
@export_range(0.0, 50000.0, 10.0, "or_greater", "suffix:N") var forward_engine_force: float = 4200.0
@export_range(0.0, 50000.0, 10.0, "or_greater", "suffix:N") var reverse_engine_force: float = 1800.0
@export_range(0.01, 2.0, 0.01, "or_greater", "suffix:m") var propulsion_full_contact_depth: float = 0.3
@export_range(0.0, 100.0, 0.1, "or_greater", "suffix:m/s") var forward_thrust_falloff_start_speed: float = 18.0
@export_range(0.0, 200.0, 0.1, "or_greater", "suffix:m/s") var forward_thrust_falloff_end_speed: float = 28.0
@export_range(0.0, 50.0, 0.1, "or_greater", "suffix:m/s") var reverse_thrust_falloff_start_speed: float = 5.0
@export_range(0.0, 50.0, 0.1, "or_greater", "suffix:m/s") var reverse_thrust_falloff_end_speed: float = 9.0

@export_group("Steering")
@export_range(0.0, 90.0, 0.1, "or_greater", "degrees") var maximum_steering_angle_degrees: float = 12.0
@export_range(0.0, 100.0, 0.1, "or_greater", "suffix:m/s") var steering_reduction_start_speed: float = 12.0
@export_range(0.0, 100.0, 0.1, "or_greater", "suffix:m/s") var steering_reduction_end_speed: float = 25.0
@export_range(0.0, 1.0, 0.01) var high_speed_steering_factor: float = 0.45
@export_range(0.0, 500.0, 0.1, "or_greater", "suffix:N/(m/s)^2") var coasting_steering_force_per_speed_squared: float = 2.0
@export_range(0.0, 20000.0, 10.0, "or_greater", "suffix:N") var max_coasting_steering_force: float = 1500.0

@export_group("Turn Lean")
@export var turn_lean_enabled: bool = true
@export_range(0.0, 35.0, 0.5) var turn_lean_max_angle_degrees: float = 18.0
@export_range(0.0, 15.0, 0.25) var turn_lean_start_speed: float = 3.0:
	set(value):
		turn_lean_start_speed = clampf(value, 0.0, 15.0)
		if turn_lean_full_speed <= turn_lean_start_speed:
			turn_lean_full_speed = turn_lean_start_speed + 0.25
@export_range(4.0, 30.0, 0.25) var turn_lean_full_speed: float = 16.0:
	set(value):
		turn_lean_full_speed = clampf(
			value,
			turn_lean_start_speed + 0.25,
			30.0
		)
@export_range(1000.0, 40000.0, 250.0) var turn_lean_stiffness: float = 16000.0
@export_range(100.0, 12000.0, 100.0) var turn_lean_damping: float = 4200.0
@export_range(500.0, 25000.0, 250.0) var turn_lean_max_torque: float = 8500.0
@export_range(0.0, 1.0, 0.01) var turn_lean_reverse_factor: float = 0.35
@export_range(0.0, 0.5, 0.01) var turn_lean_landing_ramp_time: float = 0.12
@export_range(0.01, 0.5, 0.01) var turn_lean_support_normal_half_life: float = 0.08

@export_group("Rider Weight Shift")
@export var rider_weight_shift_enabled: bool = true
@export_range(0.01, 0.5, 0.01) var rider_shift_input_half_life: float = 0.10
@export_range(0.01, 0.8, 0.01) var rider_shift_release_half_life: float = 0.20

@export_group("Rider Weight Shift - Virtual Rider")
@export_range(20.0, 150.0, 1.0) var rider_effective_mass: float = 85.0
@export_range(0.05, 1.0, 0.01) var rider_lateral_shift_distance: float = 0.48
@export_range(0.05, 1.5, 0.01) var rider_longitudinal_shift_distance: float = 0.72
@export_range(0.1, 12.0, 0.1) var rider_weight_torque_multiplier: float = 6.0
@export_range(0.0, 12000.0, 100.0) var rider_roll_rate_damping: float = 1800.0
@export_range(0.0, 15000.0, 100.0) var rider_pitch_rate_damping: float = 2200.0

@export_group("Rider Weight Shift - Authority")
@export_range(0.0, 1.0, 0.01) var rider_shift_standstill_authority: float = 1.0
@export_range(1.0, 20.0, 0.25) var rider_shift_full_speed: float = 9.0
@export_range(0.0, 1.0, 0.01) var rider_shift_deep_submerged_authority: float = 0.65
@export_range(0.0, 0.5, 0.01) var rider_shift_landing_ramp_time: float = 0.15
@export_range(0.0, 1.0, 0.01) var rider_shift_auto_upright_factor: float = 0.20
@export_range(0.0, 30.0, 0.5, "degrees") var rider_manual_roll_max_angle_degrees: float = 16.0

@export_group("Rider Weight Shift - Dynamic Boost")
@export_range(0.0, 3.0, 0.05) var rider_wheelie_throttle_boost: float = 0.85
@export_range(0.0, 3.0, 0.05) var rider_nose_dive_speed_boost: float = 0.55

@export_group("Rider Weight Shift - Soft Limits")
@export_range(5.0, 60.0, 0.5) var rider_roll_soft_limit_degrees: float = 32.0
@export_range(5.0, 60.0, 0.5) var rider_nose_up_soft_limit_degrees: float = 34.0
@export_range(5.0, 50.0, 0.5) var rider_nose_down_soft_limit_degrees: float = 38.0
@export_range(0.0, 30000.0, 250.0) var rider_soft_limit_stiffness: float = 12000.0
@export_range(0.0, 15000.0, 100.0) var rider_soft_limit_damping: float = 3000.0

@export_group("Rider Weight Shift - Air Safety")
@export_range(2.0, 30.0, 0.25) var rider_air_max_roll_rate: float = 12.0
@export_range(2.0, 30.0, 0.25) var rider_air_max_pitch_rate: float = 10.0
@export_range(0.0, 10000.0, 100.0) var rider_air_overspeed_damping: float = 1800.0

@export_group("Rider Weight Shift - Submarine")
@export var submarine_dive_enabled: bool = true
@export_range(10.0, 60.0, 0.5) var submarine_entry_min_nose_down_degrees: float = 25.0
@export_range(10.0, 70.0, 0.5) var submarine_entry_max_nose_down_degrees: float = 48.0
@export_range(1.0, 30.0, 0.25) var submarine_entry_min_speed: float = 8.0
@export_range(20.0, 70.0, 0.5) var submarine_target_nose_down_degrees: float = 38.0
@export_range(0.2, 3.0, 0.05) var submarine_max_duration: float = 1.25
@export_range(0.0, 1.0, 0.01) var submarine_upright_factor: float = 0.12
@export_range(0.0, 1.0, 0.01) var submarine_buoyancy_factor: float = 0.72
@export_range(0.0, 1.0, 0.01) var submarine_propulsion_factor: float = 0.75
@export_range(0.05, 1.0, 0.01) var submarine_exit_blend_time: float = 0.30

@export_group("Rider Tricks - Preload")
@export var trick_preload_enabled: bool = true
@export_range(0.05, 1.0, 0.01) var trick_preload_min_hold_time: float = 0.10
@export_range(0.10, 1.5, 0.01) var trick_preload_full_charge_time: float = 0.35
@export_range(0.0, 1.0, 0.01) var trick_preload_min_input: float = 0.55
@export_range(0.0, 1.0, 0.01) var trick_reversal_min_input: float = 0.65
@export_range(0.05, 0.60, 0.01) var trick_reversal_takeoff_window: float = 0.35
@export_range(0.0, 0.25, 0.01) var trick_takeoff_coyote_time: float = 0.18
@export_range(0.1, 5.0, 0.05) var trick_preload_decay_rate: float = 1.5
@export_range(1.0, 30.0, 0.25) var trick_minimum_launch_speed: float = 5.0
@export_range(2.0, 35.0, 0.25) var trick_full_launch_speed: float = 15.0

@export_group("Rider Tricks - Release")
@export_range(1000.0, 20000.0, 100.0) var trick_roll_release_torque: float = 7000.0
@export_range(1000.0, 25000.0, 100.0) var trick_pitch_release_torque: float = 8500.0
@export_range(0.03, 0.30, 0.01) var trick_release_duration: float = 0.16
@export_range(0.0, 1.0, 0.01) var trick_minimum_release_charge: float = 0.15
@export_range(0.0, 2.0, 0.01) var trick_release_curve_power: float = 0.85

@export_group("Rider Tricks - Air Correction")
@export_range(100.0, 8000.0, 100.0) var air_correction_roll_torque: float = 1000.0
@export_range(100.0, 10000.0, 100.0) var air_correction_pitch_torque: float = 1300.0
@export_range(0.2, 6.0, 0.1) var air_correction_target_roll_rate: float = 1.8
@export_range(0.2, 6.0, 0.1) var air_correction_target_pitch_rate: float = 1.6
@export_range(1.0, 4.0, 0.05) var air_counter_input_brake_multiplier: float = 1.8

@export_group("Navigation Detection")
@export_range(0.0, 2.0, 0.01, "or_greater", "suffix:s") var airborne_confirmation_time: float = 0.1
@export_range(0.0, 2.0, 0.01, "or_greater", "suffix:m") var airborne_minimum_clearance: float = 0.05
@export_range(0.0, 2.0, 0.01, "or_greater", "suffix:s") var landing_state_duration: float = 0.2
@export_range(0.0, 50.0, 0.1, "or_greater", "suffix:m/s") var minimum_landing_speed: float = 1.0
@export_range(0.0, 50.0, 0.1, "or_greater", "suffix:m/s") var maximum_landing_speed: float = 12.0
@export_range(0.0, 50.0, 0.1, "or_greater", "suffix:m/s") var hard_landing_speed: float = 6.0
@export_range(0.0, 10.0, 0.01, "or_greater", "suffix:m") var deep_submersion_average_depth: float = 0.7
@export_range(0.0, 10.0, 0.01, "or_greater", "suffix:m") var deep_submersion_release_depth: float = 0.4
@export_range(1, BUOYANCY_POINT_COUNT, 1) var deep_submersion_required_points: int = 4

@export_group("Safety Reset")
@export var minimum_safe_y: float = -25.0
@export_range(10.0, 100000.0, 1.0, "or_greater", "suffix:m") var maximum_distance_from_spawn: float = 4096.0

var submerged_point_count: int:
	get:
		return water_physics_system.state.submerged_point_count

var submerged_ratio: float:
	get:
		return water_physics_system.state.submerged_ratio

var average_depth: float:
	get:
		return water_physics_system.state.average_depth

var maximum_depth: float:
	get:
		return water_physics_system.state.maximum_depth

var front_submerged_ratio: float:
	get:
		return water_physics_system.state.front_submerged_ratio

var rear_submerged_ratio: float:
	get:
		return water_physics_system.state.rear_submerged_ratio

var water_relative_forward_speed: float:
	get:
		return water_physics_system.state.water_relative_forward_speed

var water_relative_lateral_speed: float:
	get:
		return water_physics_system.state.water_relative_lateral_speed

var total_forward_drag_force: float:
	get:
		return water_physics_system.state.total_forward_drag_force

var total_lateral_drag_force: float:
	get:
		return water_physics_system.state.total_lateral_drag_force

var total_buoyancy_force: float:
	get:
		return water_physics_system.state.total_buoyancy_force

var maximum_point_buoyancy_force: float:
	get:
		return water_physics_system.state.maximum_point_buoyancy_force

var maximum_point_forward_drag: float:
	get:
		return water_physics_system.state.maximum_point_forward_drag

var maximum_point_lateral_drag: float:
	get:
		return water_physics_system.state.maximum_point_lateral_drag

var hydrodynamic_active_point_count: int:
	get:
		return water_physics_system.state.hydrodynamic_active_point_count

var throttle_input: float:
	get:
		return input_system.state.throttle

var brake_input: float:
	get:
		return input_system.state.brake

var steering_input: float:
	get:
		return input_system.state.steering

var propulsion_depth: float:
	get:
		return drive_system.state.propulsion_depth

var propulsion_contact_factor: float:
	get:
		return drive_system.state.propulsion_contact_factor

var turn_lean_speed_factor: float:
	get:
		return rider_dynamics_system.state.turn_lean_speed_factor

var turn_lean_contact_factor: float:
	get:
		return rider_dynamics_system.state.turn_lean_contact_factor

var turn_lean_roll_rate: float:
	get:
		return rider_dynamics_system.state.turn_lean_roll_rate

var turn_lean_requested_torque: float:
	get:
		return rider_dynamics_system.state.turn_lean_requested_torque

var turn_lean_applied_torque_vector: Vector3:
	get:
		return (
			rider_dynamics_system.state
			.turn_lean_applied_torque_vector
		)

var turn_lean_support_normal: Vector3:
	get:
		return rider_dynamics_system.state.smoothed_support_normal

var turn_lean_airborne_disabled: bool:
	get:
		return (
			rider_dynamics_system.state
			.turn_lean_airborne_disabled
		)

var turn_lean_landing_ramp: float:
	get:
		return rider_dynamics_system.state.turn_lean_landing_ramp

var rider_weight_shift_roll: float:
	get:
		return input_system.state.rider_shift_smoothed.x

var rider_weight_shift_pitch: float:
	get:
		return input_system.state.rider_shift_smoothed.y

var rider_shift_speed_authority: float:
	get:
		return (
			rider_dynamics_system.state
			.rider_shift_speed_authority
		)

var rider_shift_speed_factor: float:
	get:
		return rider_dynamics_system.state.rider_shift_speed_factor

var rider_shift_contact_authority: float:
	get:
		return (
			rider_dynamics_system.state
			.rider_shift_contact_authority
		)

var rider_shift_air_authority_active: float:
	get:
		return (
			rider_dynamics_system.state
			.rider_shift_air_authority_active
		)

var rider_shift_roll_torque: float:
	get:
		return rider_dynamics_system.state.rider_shift_roll_torque

var rider_shift_pitch_torque: float:
	get:
		return rider_dynamics_system.state.rider_shift_pitch_torque

var rider_shift_front_contact_ratio: float:
	get:
		return (
			rider_dynamics_system.state
			.rider_shift_front_contact_ratio
		)

var rider_shift_rear_contact_ratio: float:
	get:
		return (
			rider_dynamics_system.state
			.rider_shift_rear_contact_ratio
		)

var rider_shift_airborne: bool:
	get:
		return rider_dynamics_system.state.rider_shift_airborne

var rider_shift_landing_ramp: float:
	get:
		return rider_dynamics_system.state.rider_shift_landing_ramp

var rider_manual_medium_authority: float:
	get:
		return (
			rider_dynamics_system.state
			.rider_manual_medium_authority
		)

var submarine_dive_active: bool:
	get:
		return submarine_system.is_dive_active()

var solid_support_contact_count: int:
	get:
		return navigation_system.state.solid_support_contact_count

var physical_contact_count: int:
	get:
		return navigation_system.state.physical_contact_count

var physical_contact_delta_velocity: float:
	get:
		return navigation_system.state.physical_contact_delta_velocity

var physical_contact_position: Vector3:
	get:
		return navigation_system.state.physical_contact_position

var has_solid_support: bool:
	get:
		return navigation_system.state.has_solid_support

var has_water_support: bool:
	get:
		return navigation_system.state.has_water_support

var has_any_support: bool:
	get:
		return navigation_system.state.has_any_support

var previous_has_any_support: bool:
	get:
		return navigation_system.state.previous_has_any_support

var true_takeoff_this_tick: bool:
	get:
		return navigation_system.state.true_takeoff_this_tick

var air_correction_roll_torque_current: float:
	get:
		return (
			rider_dynamics_system.state
			.air_correction_roll_torque_current
		)

var air_correction_pitch_torque_current: float:
	get:
		return (
			rider_dynamics_system.state
			.air_correction_pitch_torque_current
		)

var is_propelling: bool:
	get:
		return drive_system.state.is_propelling

var navigation_state: JetSkiTypes.NavigationState:
	get:
		return navigation_system.state.navigation_state

var current_contact_mask: int:
	get:
		return navigation_system.state.current_contact_mask

var previous_contact_mask: int:
	get:
		return navigation_system.state.previous_contact_mask

var new_contact_mask: int:
	get:
		return navigation_system.state.new_contact_mask

var lost_contact_mask: int:
	get:
		return navigation_system.state.lost_contact_mask

var maximum_signed_point_depth: float:
	get:
		return water_physics_system.state.maximum_signed_point_depth

var dry_contact_time: float:
	get:
		return navigation_system.state.dry_contact_time

var current_airtime: float:
	get:
		return navigation_system.state.current_airtime

var last_airtime: float:
	get:
		return navigation_system.state.last_airtime

var maximum_recorded_airtime: float:
	get:
		return navigation_system.state.maximum_recorded_airtime

var takeoff_position: Vector3:
	get:
		return navigation_system.state.takeoff_position

var takeoff_linear_velocity: Vector3:
	get:
		return navigation_system.state.takeoff_linear_velocity

var last_landing_position: Vector3:
	get:
		return navigation_system.state.last_landing_position

var last_landing_normal_speed: float:
	get:
		return navigation_system.state.last_landing_normal_speed

var last_landing_intensity: float:
	get:
		return navigation_system.state.last_landing_intensity

var last_landing_contact_mask: int:
	get:
		return navigation_system.state.last_landing_contact_mask

var last_landing_contact_count: int:
	get:
		return navigation_system.state.last_landing_contact_count

var last_landing_entry_type: JetSkiTypes.LandingEntryType:
	get:
		return navigation_system.state.last_landing_entry_type

var water_entry_count: int:
	get:
		return navigation_system.state.water_entry_count

var water_exit_count: int:
	get:
		return navigation_system.state.water_exit_count

var hard_landing_count: int:
	get:
		return navigation_system.state.hard_landing_count

var deep_submersion_count: int:
	get:
		return navigation_system.state.deep_submersion_count

var _respawn_transform: Transform3D
var _has_respawn_transform: bool = false
var _ocean: Ocean3D
@onready var input_system: JetSkiInputSystem = $Systems/InputSystem
@onready var water_physics_system: JetSkiWaterPhysicsSystem = (
	$Systems/WaterPhysicsSystem
)
var _navigation_system: JetSkiNavigationSystem
var navigation_system: JetSkiNavigationSystem:
	get:
		if _navigation_system == null:
			_navigation_system = get_node_or_null(
				"Systems/NavigationSystem"
			) as JetSkiNavigationSystem
		return _navigation_system
var _drive_system: JetSkiDriveSystem
var drive_system: JetSkiDriveSystem:
	get:
		if _drive_system == null:
			_drive_system = get_node_or_null(
				"Systems/DriveSystem"
			) as JetSkiDriveSystem
		return _drive_system
var _rider_dynamics_system: JetSkiRiderDynamicsSystem
var rider_dynamics_system: JetSkiRiderDynamicsSystem:
	get:
		if _rider_dynamics_system == null:
			_rider_dynamics_system = get_node_or_null(
				"Systems/RiderDynamicsSystem"
			) as JetSkiRiderDynamicsSystem
		return _rider_dynamics_system
var _submarine_system: JetSkiSubmarineSystem
var submarine_system: JetSkiSubmarineSystem:
	get:
		if _submarine_system == null:
			_submarine_system = get_node_or_null(
				"Systems/SubmarineSystem"
			) as JetSkiSubmarineSystem
		return _submarine_system
var _trick_system: JetSkiTrickSystem
var trick_system: JetSkiTrickSystem:
	get:
		if _trick_system == null:
			_trick_system = get_node_or_null(
				"Systems/TrickSystem"
			) as JetSkiTrickSystem
		return _trick_system
var _water_warning_emitted: bool = false


func _ready() -> void:
	input_system.rider_weight_shift_changed.connect(
		_on_input_system_rider_weight_shift_changed
	)
	_respawn_transform = global_transform
	_has_respawn_transform = true
	_resolve_water_reference()
	_configure_water_physics_system()
	_configure_navigation_system()
	_connect_navigation_signals()
	_configure_drive_system()
	_configure_rider_dynamics_system()
	_configure_submarine_system()
	_configure_trick_system()
	_connect_submarine_signals()
	_connect_trick_signals()
	navigation_system.reset_runtime_state()
	drive_system.reset_runtime_state()
	rider_dynamics_system.reset_runtime_state()
	input_system.reset_rider_shift()
	submarine_system.reset_runtime_state(false)
	trick_system.reset_runtime_state()
	reset_physics_interpolation()


func _integrate_forces(state: PhysicsDirectBodyState3D) -> void:
	navigation_system.begin_physics_tick()
	drive_system.begin_physics_tick()
	rider_dynamics_system.begin_physics_tick()
	trick_system.begin_physics_tick()
	input_system.rider_weight_shift_enabled = rider_weight_shift_enabled
	input_system.rider_shift_input_half_life = rider_shift_input_half_life
	input_system.rider_shift_release_half_life = rider_shift_release_half_life
	input_system.rider_input_allowed = (
		not freeze
		and process_mode != Node.PROCESS_MODE_DISABLED
		and not get_tree().paused
	)
	input_system.sample_input(state.step)
	if not is_instance_valid(_ocean):
		water_physics_system.reset_runtime_state()
		_warn_about_missing_water_once()
		return
	if not water_physics_system.has_valid_buoyancy_points():
		water_physics_system.reset_runtime_state()
		return
	var current_attitude := (
		rider_dynamics_system.calculate_world_attitude(state.transform)
	)
	submarine_system.update_before_forces(
		state,
		input_system.state,
		current_attitude,
		state.step
	)
	var water_state := water_physics_system.step(
		state,
		_ocean,
		submarine_system.state.buoyancy_factor_current
	)
	navigation_system.prepare_support_state(state, water_state)
	if water_state.raw_contact_mask == 0:
		var pre_contact_attitude := (
			rider_dynamics_system.calculate_world_attitude(state.transform)
		)
		submarine_system.capture_pre_contact_state(
			state,
			pre_contact_attitude
		)
	navigation_system.step(
		state,
		water_physics_system,
		state.step
	)
	submarine_system.update_after_contacts(
		input_system.state,
		water_state,
		navigation_system.state,
		water_physics_system
	)
	trick_system.update_state(
		state,
		input_system.state,
		water_state,
		navigation_system.state,
		rider_weight_shift_enabled,
		trick_preload_enabled,
		submarine_system.is_dive_active(),
		state.step
	)
	drive_system.step(
		state,
		_ocean,
		input_system.state,
		submarine_system.state.propulsion_factor_current
	)
	_apply_rider_dynamics(state)


func _physics_process(_delta: float) -> void:
	if Input.is_action_just_pressed("reset_vehicle"):
		reset_vehicle(&"manual_input")
		return
	var safety_reason := _get_safety_reset_reason()
	if not safety_reason.is_empty():
		reset_vehicle(safety_reason)


func set_respawn_transform(value: Transform3D) -> void:
	_respawn_transform = Transform3D(value.basis.orthonormalized(), value.origin)
	_has_respawn_transform = true


func get_respawn_transform() -> Transform3D:
	return _respawn_transform


func get_ocean() -> Ocean3D:
	return _ocean


func apply_world_rebase(shift: Vector3) -> void:
	var horizontal_shift := Vector3(shift.x, 0.0, shift.z)
	if horizontal_shift.is_zero_approx() or not horizontal_shift.is_finite():
		return
	var preserved_linear_velocity := linear_velocity
	var preserved_angular_velocity := angular_velocity
	var preserved_sleeping := sleeping
	# Change only the origin. Reassigning the full transform can normalize a
	# physics-produced basis and introduce a tiny artificial rotation. The same
	# translated transform is also written to the physics server so Jolt starts
	# its integration from the rebased position instead of restoring stale state.
	var shifted_transform := global_transform
	shifted_transform.origin -= horizontal_shift
	PhysicsServer3D.body_set_state(
		get_rid(),
		PhysicsServer3D.BODY_STATE_TRANSFORM,
		shifted_transform
	)
	global_position -= horizontal_shift
	submarine_system.apply_world_rebase(horizontal_shift)
	PhysicsServer3D.body_set_state(
		get_rid(),
		PhysicsServer3D.BODY_STATE_LINEAR_VELOCITY,
		preserved_linear_velocity
	)
	PhysicsServer3D.body_set_state(
		get_rid(),
		PhysicsServer3D.BODY_STATE_ANGULAR_VELOCITY,
		preserved_angular_velocity
	)
	linear_velocity = preserved_linear_velocity
	angular_velocity = preserved_angular_velocity
	sleeping = preserved_sleeping
	reset_physics_interpolation()
	world_rebased.emit(horizontal_shift)


func reset_vehicle(reason: StringName = &"manual") -> void:
	if not _has_respawn_transform:
		_respawn_transform = global_transform
		_has_respawn_transform = true
	var was_frozen := freeze
	freeze = true
	global_transform = _respawn_transform
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO
	constant_force = Vector3.ZERO
	constant_torque = Vector3.ZERO
	freeze = was_frozen
	sleeping = false
	water_physics_system.reset_runtime_state()
	navigation_system.reset_runtime_state()
	drive_system.reset_runtime_state()
	rider_dynamics_system.reset_runtime_state()
	input_system.reset_rider_shift()
	submarine_system.reset_runtime_state(true)
	trick_system.reset_runtime_state()
	reset_physics_interpolation()
	reset_completed.emit(reason)


func _get_safety_reset_reason() -> StringName:
	if not _has_finite_state():
		return &"non_finite_state"
	if global_position.y < minimum_safe_y:
		return &"below_minimum_y"
	if _has_respawn_transform:
		var maximum_distance_squared := maximum_distance_from_spawn * maximum_distance_from_spawn
		if global_position.distance_squared_to(_respawn_transform.origin) > maximum_distance_squared:
			return &"beyond_maximum_distance"
	return &""


func _has_finite_state() -> bool:
	return (
		global_transform.is_finite()
		and linear_velocity.is_finite()
		and angular_velocity.is_finite()
	)


func _resolve_water_reference() -> void:
	if ocean_path.is_empty():
		_warn_about_missing_water_once()
		return
	_ocean = get_node_or_null(ocean_path) as Ocean3D
	if _ocean == null:
		_warn_about_missing_water_once()


func _configure_water_physics_system() -> void:
	water_physics_system.buoyancy_strength_per_point = (
		buoyancy_strength_per_point
	)
	water_physics_system.buoyancy_damping_per_point = (
		buoyancy_damping_per_point
	)
	water_physics_system.max_submersion_depth = max_submersion_depth
	water_physics_system.deep_buoyancy_start_depth = (
		deep_buoyancy_start_depth
	)
	water_physics_system.deep_buoyancy_strength_per_point = (
		deep_buoyancy_strength_per_point
	)
	water_physics_system.deep_buoyancy_force_limit_per_meter = (
		deep_buoyancy_force_limit_per_meter
	)
	water_physics_system.max_buoyancy_force_per_point = (
		max_buoyancy_force_per_point
	)
	water_physics_system.forward_drag_linear_per_point = (
		forward_drag_linear_per_point
	)
	water_physics_system.forward_drag_quadratic_per_point = (
		forward_drag_quadratic_per_point
	)
	water_physics_system.lateral_drag_linear_per_point = (
		lateral_drag_linear_per_point
	)
	water_physics_system.lateral_drag_quadratic_per_point = (
		lateral_drag_quadratic_per_point
	)
	water_physics_system.drag_depth_exponent = drag_depth_exponent
	water_physics_system.maximum_forward_drag_force_per_point = (
		maximum_forward_drag_force_per_point
	)
	water_physics_system.maximum_lateral_drag_force_per_point = (
		maximum_lateral_drag_force_per_point
	)
	var point_root := get_node_or_null("BuoyancyPoints") as Node3D
	water_physics_system.configure(point_root)


func _configure_navigation_system() -> void:
	navigation_system.airborne_confirmation_time = airborne_confirmation_time
	navigation_system.airborne_minimum_clearance = airborne_minimum_clearance
	navigation_system.landing_state_duration = landing_state_duration
	navigation_system.minimum_landing_speed = minimum_landing_speed
	navigation_system.maximum_landing_speed = maximum_landing_speed
	navigation_system.hard_landing_speed = hard_landing_speed
	navigation_system.deep_submersion_average_depth = (
		deep_submersion_average_depth
	)
	navigation_system.deep_submersion_release_depth = (
		deep_submersion_release_depth
	)
	navigation_system.deep_submersion_required_points = (
		deep_submersion_required_points
	)


func _configure_drive_system() -> void:
	drive_system.forward_engine_force = forward_engine_force
	drive_system.reverse_engine_force = reverse_engine_force
	drive_system.propulsion_full_contact_depth = (
		propulsion_full_contact_depth
	)
	drive_system.forward_thrust_falloff_start_speed = (
		forward_thrust_falloff_start_speed
	)
	drive_system.forward_thrust_falloff_end_speed = (
		forward_thrust_falloff_end_speed
	)
	drive_system.reverse_thrust_falloff_start_speed = (
		reverse_thrust_falloff_start_speed
	)
	drive_system.reverse_thrust_falloff_end_speed = (
		reverse_thrust_falloff_end_speed
	)
	drive_system.maximum_steering_angle_degrees = (
		maximum_steering_angle_degrees
	)
	drive_system.steering_reduction_start_speed = (
		steering_reduction_start_speed
	)
	drive_system.steering_reduction_end_speed = (
		steering_reduction_end_speed
	)
	drive_system.high_speed_steering_factor = (
		high_speed_steering_factor
	)
	drive_system.coasting_steering_force_per_speed_squared = (
		coasting_steering_force_per_speed_squared
	)
	drive_system.max_coasting_steering_force = (
		max_coasting_steering_force
	)
	var propulsion_marker := get_node_or_null(
		"PropulsionPoint"
	) as Marker3D
	drive_system.configure(propulsion_marker)


func _configure_rider_dynamics_system() -> void:
	rider_dynamics_system.turn_lean_enabled = turn_lean_enabled
	rider_dynamics_system.turn_lean_max_angle_degrees = (
		turn_lean_max_angle_degrees
	)
	rider_dynamics_system.turn_lean_start_speed = (
		turn_lean_start_speed
	)
	rider_dynamics_system.turn_lean_full_speed = (
		turn_lean_full_speed
	)
	rider_dynamics_system.turn_lean_stiffness = turn_lean_stiffness
	rider_dynamics_system.turn_lean_damping = turn_lean_damping
	rider_dynamics_system.turn_lean_max_torque = (
		turn_lean_max_torque
	)
	rider_dynamics_system.turn_lean_reverse_factor = (
		turn_lean_reverse_factor
	)
	rider_dynamics_system.turn_lean_landing_ramp_time = (
		turn_lean_landing_ramp_time
	)
	rider_dynamics_system.turn_lean_support_normal_half_life = (
		turn_lean_support_normal_half_life
	)
	rider_dynamics_system.rider_weight_shift_enabled = (
		rider_weight_shift_enabled
	)
	rider_dynamics_system.rider_shift_input_half_life = (
		rider_shift_input_half_life
	)
	rider_dynamics_system.rider_shift_release_half_life = (
		rider_shift_release_half_life
	)
	rider_dynamics_system.rider_effective_mass = rider_effective_mass
	rider_dynamics_system.rider_lateral_shift_distance = (
		rider_lateral_shift_distance
	)
	rider_dynamics_system.rider_longitudinal_shift_distance = (
		rider_longitudinal_shift_distance
	)
	rider_dynamics_system.rider_weight_torque_multiplier = (
		rider_weight_torque_multiplier
	)
	rider_dynamics_system.rider_roll_rate_damping = (
		rider_roll_rate_damping
	)
	rider_dynamics_system.rider_pitch_rate_damping = (
		rider_pitch_rate_damping
	)
	rider_dynamics_system.rider_shift_standstill_authority = (
		rider_shift_standstill_authority
	)
	rider_dynamics_system.rider_shift_full_speed = (
		rider_shift_full_speed
	)
	rider_dynamics_system.rider_shift_deep_submerged_authority = (
		rider_shift_deep_submerged_authority
	)
	rider_dynamics_system.rider_shift_landing_ramp_time = (
		rider_shift_landing_ramp_time
	)
	rider_dynamics_system.rider_shift_auto_upright_factor = (
		rider_shift_auto_upright_factor
	)
	rider_dynamics_system.rider_manual_roll_max_angle_degrees = (
		rider_manual_roll_max_angle_degrees
	)
	rider_dynamics_system.rider_wheelie_throttle_boost = (
		rider_wheelie_throttle_boost
	)
	rider_dynamics_system.rider_nose_dive_speed_boost = (
		rider_nose_dive_speed_boost
	)
	rider_dynamics_system.rider_roll_soft_limit_degrees = (
		rider_roll_soft_limit_degrees
	)
	rider_dynamics_system.rider_nose_up_soft_limit_degrees = (
		rider_nose_up_soft_limit_degrees
	)
	rider_dynamics_system.rider_nose_down_soft_limit_degrees = (
		rider_nose_down_soft_limit_degrees
	)
	rider_dynamics_system.rider_soft_limit_stiffness = (
		rider_soft_limit_stiffness
	)
	rider_dynamics_system.rider_soft_limit_damping = (
		rider_soft_limit_damping
	)
	rider_dynamics_system.rider_air_max_roll_rate = (
		rider_air_max_roll_rate
	)
	rider_dynamics_system.rider_air_max_pitch_rate = (
		rider_air_max_pitch_rate
	)
	rider_dynamics_system.rider_air_overspeed_damping = (
		rider_air_overspeed_damping
	)
	rider_dynamics_system.air_correction_roll_torque = (
		air_correction_roll_torque
	)
	rider_dynamics_system.air_correction_pitch_torque = (
		air_correction_pitch_torque
	)
	rider_dynamics_system.air_correction_target_roll_rate = (
		air_correction_target_roll_rate
	)
	rider_dynamics_system.air_correction_target_pitch_rate = (
		air_correction_target_pitch_rate
	)
	rider_dynamics_system.air_counter_input_brake_multiplier = (
		air_counter_input_brake_multiplier
	)
	rider_dynamics_system.buoyancy_strength_per_point = (
		buoyancy_strength_per_point
	)
	rider_dynamics_system.max_submersion_depth = (
		max_submersion_depth
	)
	rider_dynamics_system.configure(water_physics_system)


func _configure_submarine_system() -> void:
	submarine_system.dive_enabled = submarine_dive_enabled
	submarine_system.entry_min_nose_down_degrees = (
		submarine_entry_min_nose_down_degrees
	)
	submarine_system.entry_max_nose_down_degrees = (
		submarine_entry_max_nose_down_degrees
	)
	submarine_system.entry_min_speed = submarine_entry_min_speed
	submarine_system.target_nose_down_degrees = (
		submarine_target_nose_down_degrees
	)
	submarine_system.maximum_duration = submarine_max_duration
	submarine_system.upright_factor = submarine_upright_factor
	submarine_system.buoyancy_factor = submarine_buoyancy_factor
	submarine_system.propulsion_factor = submarine_propulsion_factor
	submarine_system.exit_blend_time = submarine_exit_blend_time
	submarine_system.rider_soft_limit_stiffness = (
		rider_soft_limit_stiffness
	)
	submarine_system.rider_soft_limit_damping = (
		rider_soft_limit_damping
	)


func _configure_trick_system() -> void:
	trick_system.trick_preload_min_hold_time = (
		trick_preload_min_hold_time
	)
	trick_system.trick_preload_full_charge_time = (
		trick_preload_full_charge_time
	)
	trick_system.trick_preload_min_input = trick_preload_min_input
	trick_system.trick_reversal_min_input = trick_reversal_min_input
	trick_system.trick_reversal_takeoff_window = (
		trick_reversal_takeoff_window
	)
	trick_system.trick_takeoff_coyote_time = trick_takeoff_coyote_time
	trick_system.trick_preload_decay_rate = trick_preload_decay_rate
	trick_system.trick_minimum_launch_speed = trick_minimum_launch_speed
	trick_system.trick_full_launch_speed = trick_full_launch_speed
	trick_system.trick_roll_release_torque = trick_roll_release_torque
	trick_system.trick_pitch_release_torque = trick_pitch_release_torque
	trick_system.trick_release_duration = trick_release_duration
	trick_system.trick_minimum_release_charge = (
		trick_minimum_release_charge
	)
	trick_system.trick_release_curve_power = trick_release_curve_power
	trick_system.max_submersion_depth = max_submersion_depth


func _connect_navigation_signals() -> void:
	navigation_system.water_entered.connect(
		_on_navigation_system_water_entered
	)
	navigation_system.water_exited.connect(
		_on_navigation_system_water_exited
	)
	navigation_system.hard_landing.connect(
		_on_navigation_system_hard_landing
	)
	navigation_system.deeply_submerged.connect(
		_on_navigation_system_deeply_submerged
	)


func _connect_submarine_signals() -> void:
	submarine_system.dive_started.connect(
		_on_submarine_system_dive_started
	)
	submarine_system.dive_ended.connect(
		_on_submarine_system_dive_ended
	)


func _connect_trick_signals() -> void:
	trick_system.trick_launched.connect(
		_on_trick_system_trick_launched
	)


func _on_submarine_system_dive_started() -> void:
	trick_system.cancel_for_submarine()
	submarine_dive_started.emit()


func _on_trick_system_trick_launched(
	trick_type: JetSkiTypes.RiderTrickLaunchType,
	launch_charge: Vector2,
	release_strength: Vector2
) -> void:
	rider_trick_launched.emit(
		trick_type,
		launch_charge,
		release_strength
	)


func _on_submarine_system_dive_ended(
	duration: float,
	maximum_depth: float
) -> void:
	submarine_dive_ended.emit(duration, maximum_depth)


func _on_navigation_system_water_entered(
	intensity: float,
	contact_position: Vector3
) -> void:
	water_entered.emit(intensity, contact_position)


func _on_navigation_system_water_exited() -> void:
	water_exited.emit()


func _on_navigation_system_hard_landing(
	intensity: float,
	impact_position: Vector3
) -> void:
	hard_landing.emit(intensity, impact_position)


func _on_navigation_system_deeply_submerged() -> void:
	deeply_submerged.emit()


func _apply_rider_dynamics(
	body_state: PhysicsDirectBodyState3D
) -> void:
	var using_air: bool = rider_dynamics_system.prepare_mode(
		body_state,
		navigation_system.state
	)
	if not rider_dynamics_system.has_valid_body_axes():
		return
	rider_dynamics_system.update_air_rotation_metrics(body_state)
	rider_dynamics_system.prepare_common_metrics(
		input_system.state,
		water_physics_system.state,
		navigation_system.state,
		drive_system.state,
		submarine_system.is_dive_active()
	)
	if using_air:
		if not rider_dynamics_system.prepare_air_metrics(
			body_state,
			input_system.state
		):
			return
		var external_trick_release_torque := (
			trick_system.calculate_release_torque(
				rider_dynamics_system
				.get_prepared_body_forward(),
				rider_dynamics_system
				.get_prepared_body_right(),
				body_state.step
			)
		)
		rider_dynamics_system.apply_air_torque(
			body_state,
			input_system.state,
			external_trick_release_torque
		)
		return
	if not rider_dynamics_system.prepare_supported(
		body_state,
		input_system.state,
		water_physics_system.state,
		navigation_system.state,
		drive_system.state
	):
		return
	var external_submarine_pitch_torque := Vector3.ZERO
	if (
		rider_weight_shift_enabled
		and not input_system.state.rider_shift_smoothed.is_zero_approx()
	):
		var body_right := (
			body_state.transform.basis.orthonormalized().x
		)
		external_submarine_pitch_torque = (
			submarine_system.calculate_pitch_target_torque(
				body_state,
				rider_dynamics_system.state,
				body_right
			)
		)
	rider_dynamics_system.apply_supported_torque(
		body_state,
		input_system.state,
		submarine_system.state.upright_factor_current,
		submarine_system.get_control_blend(),
		external_submarine_pitch_torque
	)


func _on_input_system_rider_weight_shift_changed(shift: Vector2) -> void:
	rider_weight_shift_changed.emit(shift)


func _warn_about_missing_water_once() -> void:
	if _water_warning_emitted:
		return
	_water_warning_emitted = true
	push_warning("JetSki buoyancy is disabled because its Ocean3D reference is invalid.")
