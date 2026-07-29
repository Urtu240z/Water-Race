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
const RiderStuntWaterMode = JetSkiTypes.RiderStuntWaterMode
const TrickPreloadState = JetSkiTypes.TrickPreloadState
const RiderTrickLaunchType = JetSkiTypes.RiderTrickLaunchType

signal rider_trick_launched(
	trick_type: JetSkiTypes.RiderTrickLaunchType,
	charge: Vector2,
	release_strength: Vector2
)

const BUOYANCY_POINT_COUNT: int = 4
const FRONT_POINT_COUNT: int = 2
const ALL_CONTACT_MASK: int = 15
const FRONT_CONTACT_MASK: int = 3
const REAR_CONTACT_MASK: int = 12
const LEFT_CONTACT_MASK: int = 5
const RIGHT_CONTACT_MASK: int = 10
const SUBMARINE_MAX_ENTRY_ROLL_DEGREES: float = 45.0
const SUBMARINE_MIN_EXIT_SPEED: float = 3.0
const SUBMARINE_SAFETY_DEPTH: float = 3.0
const SUBMARINE_CLEAR_NOSE_UP_DEGREES: float = 10.0
const SUBMARINE_ENTRY_BUOYANCY_BLEND_TIME: float = 0.12
const TRICK_PRE_TAKEOFF_OPTIMAL_TIME: float = 0.22
const TRICK_PRE_TAKEOFF_MINIMUM_TIMING: float = 0.65
const TRICK_POST_TAKEOFF_OPTIMAL_TIME: float = 0.10
const TRICK_POST_TAKEOFF_MINIMUM_TIMING: float = 0.50

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

var current_steering_angle_degrees: float:
	get:
		return drive_system.state.steering_angle_degrees

var current_forward_speed_factor: float:
	get:
		return drive_system.state.forward_speed_factor

var current_reverse_speed_factor: float:
	get:
		return drive_system.state.reverse_speed_factor

var current_propulsion_force: float:
	get:
		return drive_system.state.propulsion_force

var current_propulsion_force_vector: Vector3:
	get:
		return drive_system.state.propulsion_force_vector

var turn_lean_target_roll_degrees: float:
	get:
		return rad_to_deg(
			rider_dynamics_system.state.turn_lean_target_roll
		)

var turn_lean_current_roll_degrees: float:
	get:
		return rad_to_deg(
			rider_dynamics_system.state.turn_lean_current_roll
		)

var turn_lean_error_degrees: float:
	get:
		return rad_to_deg(
			rider_dynamics_system.state.turn_lean_roll_error
		)

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

var turn_lean_reference_forward: Vector3:
	get:
		return rider_dynamics_system.state.reference_forward

var turn_lean_reference_right: Vector3:
	get:
		return rider_dynamics_system.state.reference_right

var turn_lean_airborne_disabled: bool:
	get:
		return (
			rider_dynamics_system.state
			.turn_lean_airborne_disabled
		)

var turn_lean_landing_ramp: float:
	get:
		return rider_dynamics_system.state.turn_lean_landing_ramp

var rider_weight_shift_input: Vector2:
	get:
		return input_system.state.rider_shift_smoothed

var rider_weight_shift_roll: float:
	get:
		return input_system.state.rider_shift_smoothed.x

var rider_weight_shift_pitch: float:
	get:
		return input_system.state.rider_shift_smoothed.y

var rider_shift_raw_input: Vector2:
	get:
		return input_system.state.rider_shift_raw

var rider_shift_smoothed_input: Vector2:
	get:
		return input_system.state.rider_shift_smoothed

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

# Active combined roll-target telemetry for automatic and manual water lean.
var rider_shift_target_angle_metrics_status: StringName:
	get:
		return &"ACTIVE_COMBINED_ROLL_TARGET"

var rider_shift_manual_roll_target_degrees: float:
	get:
		return rad_to_deg(
			rider_dynamics_system.state
			.rider_shift_manual_roll_target
		)

var rider_shift_automatic_roll_target_degrees: float:
	get:
		return rad_to_deg(
			rider_dynamics_system.state.turn_lean_target_roll
		)

var rider_shift_total_roll_target_degrees: float:
	get:
		return rad_to_deg(
			rider_dynamics_system.state
			.rider_shift_total_roll_target
		)

var rider_shift_current_roll_degrees: float:
	get:
		return rad_to_deg(
			rider_dynamics_system.state.turn_lean_current_roll
		)

var rider_shift_manual_pitch_target_degrees: float:
	get:
		return rad_to_deg(
			rider_dynamics_system.state
			.rider_shift_manual_pitch_target
		)

var rider_shift_base_pitch_target_degrees: float:
	get:
		return rad_to_deg(
			rider_dynamics_system.state
			.rider_shift_base_pitch_target
		)

var rider_shift_total_pitch_target_degrees: float:
	get:
		return rad_to_deg(
			rider_dynamics_system.state
			.rider_shift_total_pitch_target
		)

var rider_shift_current_pitch_degrees: float:
	get:
		return rad_to_deg(
			rider_dynamics_system.state.rider_shift_current_pitch
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

var rider_virtual_offset_local: Vector3:
	get:
		return rider_dynamics_system.state.virtual_offset_local

var rider_virtual_offset_world: Vector3:
	get:
		return rider_dynamics_system.state.virtual_offset_world

var rider_virtual_weight_torque: Vector3:
	get:
		return rider_dynamics_system.state.virtual_weight_torque

var rider_manual_applied_torque: Vector3:
	get:
		return rider_dynamics_system.state.manual_applied_torque

var rider_roll_damping_torque: Vector3:
	get:
		return rider_dynamics_system.state.roll_damping_torque

var rider_pitch_damping_torque: Vector3:
	get:
		return rider_dynamics_system.state.pitch_damping_torque

var rider_dynamic_pitch_multiplier: float:
	get:
		return rider_dynamics_system.state.dynamic_pitch_multiplier

var rider_manual_medium_authority: float:
	get:
		return (
			rider_dynamics_system.state
			.rider_manual_medium_authority
		)

var rider_using_air_control: bool:
	get:
		return rider_dynamics_system.state.using_air_control

var rider_arrow_only_steering_input: float:
	get:
		return (
			rider_dynamics_system.state
			.arrow_only_steering_input
		)

var rider_arrow_only_steering_angle: float:
	get:
		return (
			rider_dynamics_system.state
			.arrow_only_steering_angle
		)

var rider_roll_soft_limit_factor: float:
	get:
		return rider_dynamics_system.state.roll_soft_limit_factor

var rider_pitch_soft_limit_factor: float:
	get:
		return rider_dynamics_system.state.pitch_soft_limit_factor

var rider_air_unlimited_rotation: bool:
	get:
		return _rider_air_unlimited_rotation

var rider_air_roll_rate: float:
	get:
		return _rider_air_roll_rate

var rider_air_pitch_rate: float:
	get:
		return _rider_air_pitch_rate

var rider_air_accumulated_roll_degrees: float:
	get:
		return _rider_air_accumulated_roll_degrees

var rider_air_accumulated_pitch_degrees: float:
	get:
		return _rider_air_accumulated_pitch_degrees

var submarine_dive_active: bool:
	get:
		return _rider_stunt_water_mode == RiderStuntWaterMode.SUBMARINE_DIVE

var submarine_entry_speed: float:
	get:
		return _submarine_entry_speed

var submarine_entry_pitch_degrees: float:
	get:
		return _submarine_entry_pitch_degrees

var submarine_duration: float:
	get:
		return _submarine_duration

var submarine_current_depth: float:
	get:
		return _submarine_current_depth

var submarine_max_depth: float:
	get:
		return _submarine_max_depth

var submarine_buoyancy_factor_current: float:
	get:
		return _submarine_buoyancy_factor_current

var submarine_exit_blend: float:
	get:
		return _submarine_exit_blend

var trick_preload_state: JetSkiTypes.TrickPreloadState:
	get:
		return _trick_preload_state

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

var trick_roll_preload_sign: float:
	get:
		return _trick_roll_preload_sign

var trick_pitch_preload_sign: float:
	get:
		return _trick_pitch_preload_sign

var trick_roll_charge: float:
	get:
		return _trick_roll_charge

var trick_pitch_charge: float:
	get:
		return _trick_pitch_charge

var trick_roll_reversal_armed: bool:
	get:
		return _trick_roll_reversal_armed

var trick_pitch_reversal_armed: bool:
	get:
		return _trick_pitch_reversal_armed

var trick_reversal_time_remaining: float:
	get:
		return maxf(
			maxf(
				_trick_roll_reversal_time_remaining,
				_trick_pitch_reversal_time_remaining
			),
			0.0
		)

var trick_takeoff_quality: float:
	get:
		return _trick_takeoff_quality

var trick_takeoff_timing_factor: float:
	get:
		return _trick_takeoff_timing_factor

var trick_release_active: bool:
	get:
		return _trick_release_active

var trick_release_time_remaining: float:
	get:
		return _trick_release_time_remaining

var trick_release_roll_torque: float:
	get:
		return _trick_release_roll_torque

var trick_release_pitch_torque: float:
	get:
		return _trick_release_pitch_torque

var trick_last_launch_type: JetSkiTypes.RiderTrickLaunchType:
	get:
		return _trick_last_launch_type

var trick_last_launch_type_name: StringName:
	get:
		return _get_rider_trick_launch_type_name(_trick_last_launch_type)

var trick_last_launch_charge: Vector2:
	get:
		return _trick_last_launch_charge

var trick_last_release_strength: Vector2:
	get:
		return _trick_last_release_strength

var air_correction_roll_torque_current: float:
	get:
		return _air_correction_roll_torque_current

var air_correction_pitch_torque_current: float:
	get:
		return _air_correction_pitch_torque_current

var air_current_roll_rate: float:
	get:
		return _rider_air_roll_rate

var air_current_pitch_rate: float:
	get:
		return _rider_air_pitch_rate

var last_buoyancy_force_vectors: PackedVector3Array:
	get:
		return water_physics_system.point_buoyancy_force_vectors

var last_forward_drag_force_vectors: PackedVector3Array:
	get:
		return water_physics_system.point_forward_drag_forces

var last_lateral_drag_force_vectors: PackedVector3Array:
	get:
		return water_physics_system.point_lateral_drag_forces

var last_point_world_positions: PackedVector3Array:
	get:
		return water_physics_system.point_world_positions

var last_water_surface_positions: PackedVector3Array:
	get:
		return water_physics_system.point_water_surface_positions

var last_water_normals: PackedVector3Array:
	get:
		return water_physics_system.point_water_normals

var last_propulsion_force_vector: Vector3:
	get:
		return drive_system.state.propulsion_force_vector

var last_propulsion_world_position: Vector3:
	get:
		return drive_system.state.propulsion_world_position

var water_reference_valid: bool:
	get:
		return is_instance_valid(_ocean)

var is_propelling: bool:
	get:
		return drive_system.state.is_propelling

var navigation_state: JetSkiTypes.NavigationState:
	get:
		return navigation_system.state.navigation_state

var navigation_state_name: StringName:
	get:
		return navigation_system.get_navigation_state_name(navigation_state)

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

var signed_depth_front_left: float:
	get:
		return water_physics_system.get_signed_point_depth(0)

var signed_depth_front_right: float:
	get:
		return water_physics_system.get_signed_point_depth(1)

var signed_depth_rear_left: float:
	get:
		return water_physics_system.get_signed_point_depth(2)

var signed_depth_rear_right: float:
	get:
		return water_physics_system.get_signed_point_depth(3)

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

var last_landing_entry_type_name: StringName:
	get:
		return navigation_system.get_landing_entry_type_name(
			last_landing_entry_type
		)

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

var reset_count: int = 0
var last_reset_reason: StringName = &""
var last_reset_linear_velocity: Vector3 = Vector3.ZERO
var last_reset_angular_velocity: Vector3 = Vector3.ZERO

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
var _water_warning_emitted: bool = false
var _rider_shift_raw_input: Vector2:
	get:
		return input_system.state.rider_shift_raw
var _rider_shift_smoothed_input: Vector2:
	get:
		return input_system.state.rider_shift_smoothed
var _rider_air_unlimited_rotation: bool = false
var _rider_air_roll_rate: float = 0.0
var _rider_air_pitch_rate: float = 0.0
var _rider_air_accumulated_roll_degrees: float = 0.0
var _rider_air_accumulated_pitch_degrees: float = 0.0
var _rider_air_tracking_active: bool = false
var _rider_stunt_water_mode: JetSkiTypes.RiderStuntWaterMode = RiderStuntWaterMode.NORMAL
var _submarine_entry_speed: float = 0.0
var _submarine_entry_pitch_degrees: float = 0.0
var _submarine_duration: float = 0.0
var _submarine_current_depth: float = 0.0
var _submarine_max_depth: float = 0.0
var _submarine_buoyancy_factor_current: float = 1.0
var _submarine_propulsion_factor_current: float = 1.0
var _submarine_upright_factor_current: float = 1.0
var _submarine_exit_blend: float = 1.0
var _submarine_exit_start_buoyancy_factor: float = 1.0
var _submarine_recovery_active: bool = false
var _submarine_pre_contact_valid: bool = false
var _submarine_pre_contact_transform: Transform3D = Transform3D.IDENTITY
var _submarine_pre_contact_linear_velocity: Vector3 = Vector3.ZERO
var _submarine_pre_contact_angular_velocity: Vector3 = Vector3.ZERO
var _submarine_pre_contact_roll_degrees: float = 0.0
var _submarine_pre_contact_pitch_degrees: float = 0.0
var _submarine_pre_contact_horizontal_speed: float = 0.0
var _trick_preload_state: JetSkiTypes.TrickPreloadState = TrickPreloadState.IDLE
var _trick_roll_preload_sign: float = 0.0
var _trick_pitch_preload_sign: float = 0.0
var _trick_roll_hold_time: float = 0.0
var _trick_pitch_hold_time: float = 0.0
var _trick_roll_charge: float = 0.0
var _trick_pitch_charge: float = 0.0
var _trick_roll_reversal_armed: bool = false
var _trick_pitch_reversal_armed: bool = false
var _trick_roll_reversal_direction: float = 0.0
var _trick_pitch_reversal_direction: float = 0.0
var _trick_roll_armed_charge: float = 0.0
var _trick_pitch_armed_charge: float = 0.0
var _trick_roll_reversal_time_remaining: float = 0.0
var _trick_pitch_reversal_time_remaining: float = 0.0
var _trick_takeoff_pending: bool = false
var _trick_time_since_takeoff: float = 0.0
var _trick_pending_speed_factor: float = 0.0
var _trick_pending_upward_factor: float = 0.0
var _trick_pending_depth_factor: float = 0.0
var _trick_pending_launch_speed_valid: bool = false
var _trick_last_contact_average_depth: float = 0.0
var _trick_takeoff_quality: float = 0.0
var _trick_takeoff_timing_factor: float = 0.0
var _trick_release_active: bool = false
var _trick_release_elapsed: float = 0.0
var _trick_release_time_remaining: float = 0.0
var _trick_release_strength: Vector2 = Vector2.ZERO
var _trick_release_charge: Vector2 = Vector2.ZERO
var _trick_release_roll_torque: float = 0.0
var _trick_release_pitch_torque: float = 0.0
var _trick_launch_consumed: bool = false
var _trick_last_launch_type: JetSkiTypes.RiderTrickLaunchType = RiderTrickLaunchType.NONE
var _trick_last_launch_charge: Vector2 = Vector2.ZERO
var _trick_last_release_strength: Vector2 = Vector2.ZERO
var _air_correction_roll_torque_current: float = 0.0
var _air_correction_pitch_torque_current: float = 0.0
var _rider_air_warning_emitted: bool = false


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
	navigation_system.reset_runtime_state()
	drive_system.reset_runtime_state()
	rider_dynamics_system.reset_runtime_state()
	_reset_air_control_state()
	_reset_submarine_state(false)
	_reset_trick_state()
	reset_physics_interpolation()


func _integrate_forces(state: PhysicsDirectBodyState3D) -> void:
	navigation_system.begin_physics_tick()
	drive_system.begin_physics_tick()
	rider_dynamics_system.begin_physics_tick()
	_clear_air_control_frame_metrics()
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
	_update_submarine_before_forces(state, state.step)
	var water_state := water_physics_system.step(
		state,
		_ocean,
		_submarine_buoyancy_factor_current
	)
	navigation_system.prepare_support_state(state, water_state)
	if water_state.raw_contact_mask == 0:
		_capture_submarine_pre_contact_state(state)
	navigation_system.step(
		state,
		water_physics_system,
		state.step
	)
	_update_submarine_after_contacts(state)
	_update_rider_trick_state(state, state.step)
	drive_system.step(
		state,
		_ocean,
		input_system.state,
		_submarine_propulsion_factor_current
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
	if _submarine_pre_contact_valid:
		_submarine_pre_contact_transform.origin -= horizontal_shift
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


func get_buoyancy_local_points() -> PackedVector3Array:
	return water_physics_system.get_buoyancy_local_points()


func get_buoyancy_point_depths() -> PackedFloat32Array:
	return water_physics_system.get_buoyancy_point_depths()


func get_buoyancy_point_normal_forces() -> PackedFloat32Array:
	return water_physics_system.get_buoyancy_point_normal_forces()


func get_buoyancy_point_water_normals() -> PackedVector3Array:
	return water_physics_system.get_buoyancy_point_water_normals()


func get_point_forward_drag_forces() -> PackedVector3Array:
	return water_physics_system.get_point_forward_drag_forces()


func get_point_lateral_drag_forces() -> PackedVector3Array:
	return water_physics_system.get_point_lateral_drag_forces()


func get_degenerate_drag_axis_count() -> int:
	return water_physics_system.get_degenerate_drag_axis_count()


func get_propulsion_local_point() -> Vector3:
	return drive_system.get_propulsion_local_point()


func clear_navigation_statistics() -> void:
	navigation_system.clear_navigation_statistics()


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
	_reset_air_control_state()
	_reset_submarine_state(true)
	_reset_trick_state()
	reset_physics_interpolation()
	last_reset_linear_velocity = linear_velocity
	last_reset_angular_velocity = angular_velocity
	last_reset_reason = reason
	reset_count += 1
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
	rider_dynamics_system.buoyancy_strength_per_point = (
		buoyancy_strength_per_point
	)
	rider_dynamics_system.max_submersion_depth = (
		max_submersion_depth
	)
	rider_dynamics_system.configure(water_physics_system)


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
	var vehicle_basis := (
		body_state.transform.basis.orthonormalized()
	)
	_update_rider_air_rotation_metrics(
		body_state,
		vehicle_basis
	)
	rider_dynamics_system.prepare_common_metrics(
		input_system.state,
		water_physics_system.state,
		navigation_system.state,
		drive_system.state,
		_rider_stunt_water_mode
		== RiderStuntWaterMode.SUBMARINE_DIVE
	)
	if using_air:
		var air_attitude := _calculate_rider_world_attitude(
			body_state.transform
		)
		rider_dynamics_system.state.turn_lean_current_roll = (
			air_attitude.x
		)
		rider_dynamics_system.state.rider_shift_current_pitch = (
			air_attitude.y
		)
		_apply_rider_shift_air_control(body_state)
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
		and not _rider_shift_smoothed_input.is_zero_approx()
	):
		var body_right := (
			body_state.transform.basis.orthonormalized().x
		)
		external_submarine_pitch_torque = (
			_calculate_submarine_pitch_target_torque(
				body_state,
				body_right
			)
		)
	rider_dynamics_system.apply_supported_torque(
		body_state,
		input_system.state,
		_submarine_upright_factor_current,
		_submarine_control_blend(),
		external_submarine_pitch_torque
	)


func _apply_rider_shift_air_control(state: PhysicsDirectBodyState3D) -> void:
	if not rider_weight_shift_enabled:
		return
	var rider_state: JetSkiRiderDynamicsState = (
		rider_dynamics_system.state
	)
	rider_state.rider_shift_air_authority_active = 1.0
	var vehicle_basis := state.transform.basis.orthonormalized()
	var body_forward := -vehicle_basis.z
	var body_right := vehicle_basis.x
	if (
		not body_forward.is_finite()
		or not body_right.is_finite()
		or body_forward.length_squared() <= 0.000001
		or body_right.length_squared() <= 0.000001
	):
		_warn_about_invalid_rider_air_once(
			"Rider weight-shift air axes are degenerate."
		)
		return
	rider_state.virtual_offset_local = Vector3(
		_rider_shift_raw_input.x * rider_lateral_shift_distance,
		0.0,
		_rider_shift_raw_input.y * rider_longitudinal_shift_distance
	)
	rider_state.virtual_offset_world = (
		vehicle_basis * rider_state.virtual_offset_local
	)
	# Air control uses the normalized raw input so releasing the arrows produces
	# zero correction torque in the same physics tick. Water retains smooth weight shift.
	var roll_rate := state.angular_velocity.dot(body_forward)
	var pitch_rate := state.angular_velocity.dot(body_right)
	_air_correction_roll_torque_current = _calculate_air_rate_correction_torque(
		roll_rate,
		_rider_shift_raw_input.x,
		air_correction_target_roll_rate,
		air_correction_roll_torque
	)
	_air_correction_pitch_torque_current = _calculate_air_rate_correction_torque(
		pitch_rate,
		_rider_shift_raw_input.y,
		air_correction_target_pitch_rate,
		air_correction_pitch_torque
	)
	var release_torque := _calculate_trick_release_torque(
		body_forward,
		body_right,
		state.step
	)
	var air_torque := (
		release_torque
		+ body_forward * _air_correction_roll_torque_current
		+ body_right * _air_correction_pitch_torque_current
		+ body_forward * _calculate_rider_air_overspeed_torque(
			roll_rate,
			_rider_shift_raw_input.x,
			rider_air_max_roll_rate
		)
		+ body_right * _calculate_rider_air_overspeed_torque(
			pitch_rate,
			_rider_shift_raw_input.y,
			rider_air_max_pitch_rate
		)
	)
	if not air_torque.is_finite():
		rider_state.rider_shift_roll_torque = 0.0
		rider_state.rider_shift_pitch_torque = 0.0
		_warn_about_invalid_rider_air_once(
			"Rider weight-shift air torque is not finite."
		)
		return
	rider_state.rider_shift_roll_torque = air_torque.dot(
		body_forward
	)
	rider_state.rider_shift_pitch_torque = air_torque.dot(body_right)
	rider_state.manual_applied_torque = air_torque
	rider_state.total_applied_torque_vector = air_torque
	if not air_torque.is_zero_approx():
		state.apply_torque(air_torque)


func _calculate_air_rate_correction_torque(
	axis_rate: float,
	axis_input: float,
	target_rate: float,
	maximum_torque: float
) -> float:
	var input_magnitude := absf(axis_input)
	if input_magnitude <= 0.0001:
		return 0.0
	var input_direction := signf(axis_input)
	if axis_rate * input_direction < 0.0:
		return (
			input_direction
			* maximum_torque
			* input_magnitude
			* air_counter_input_brake_multiplier
		)
	var desired_rate_magnitude := input_magnitude * target_rate
	if absf(axis_rate) >= desired_rate_magnitude:
		return 0.0
	var rate_deficit_factor := clampf(
		(desired_rate_magnitude - absf(axis_rate))
		/ maxf(desired_rate_magnitude, 0.0001),
		0.0,
		1.0
	)
	return input_direction * maximum_torque * input_magnitude * rate_deficit_factor


func _calculate_trick_release_torque(
	body_forward: Vector3,
	body_right: Vector3,
	physics_delta: float
) -> Vector3:
	if not _trick_release_active:
		return Vector3.ZERO
	var safe_duration := maxf(trick_release_duration, 0.001)
	var sampled_release_time := minf(
		_trick_release_elapsed + maxf(physics_delta, 0.0) * 0.5,
		safe_duration
	)
	var normalized_release_time := clampf(
		sampled_release_time / safe_duration,
		0.0,
		1.0
	)
	var release_envelope := sin(normalized_release_time * PI)
	_trick_release_roll_torque = (
		_trick_release_strength.x
		* trick_roll_release_torque
		* release_envelope
	)
	_trick_release_pitch_torque = (
		_trick_release_strength.y
		* trick_pitch_release_torque
		* release_envelope
	)
	var release_torque := (
		body_forward * _trick_release_roll_torque
		+ body_right * _trick_release_pitch_torque
	)
	_trick_release_elapsed = minf(
		_trick_release_elapsed + maxf(physics_delta, 0.0),
		safe_duration
	)
	_trick_release_time_remaining = maxf(
		safe_duration - _trick_release_elapsed,
		0.0
	)
	if _trick_release_elapsed >= safe_duration:
		_trick_release_active = false
		_update_trick_preload_state_metric()
	return release_torque


func _calculate_rider_air_overspeed_torque(
	axis_rate: float,
	axis_input: float,
	maximum_rate: float
) -> float:
	if (
		absf(axis_input) <= 0.0001
		or signf(axis_rate) != signf(axis_input)
		or absf(axis_rate) <= maximum_rate
	):
		return 0.0
	return (
		-signf(axis_rate)
		* (absf(axis_rate) - maximum_rate)
		* rider_air_overspeed_damping
	)


func _update_rider_air_rotation_metrics(
	state: PhysicsDirectBodyState3D,
	vehicle_basis: Basis
) -> void:
	if not rider_dynamics_system.state.using_air_control:
		_rider_air_unlimited_rotation = false
		_rider_air_roll_rate = 0.0
		_rider_air_pitch_rate = 0.0
		_rider_air_tracking_active = false
		return
	if not _rider_air_tracking_active:
		_rider_air_accumulated_roll_degrees = 0.0
		_rider_air_accumulated_pitch_degrees = 0.0
		_rider_air_tracking_active = true
	var body_forward := -vehicle_basis.z
	var body_right := vehicle_basis.x
	_rider_air_unlimited_rotation = true
	_rider_air_roll_rate = state.angular_velocity.dot(body_forward)
	_rider_air_pitch_rate = state.angular_velocity.dot(body_right)
	_rider_air_accumulated_roll_degrees += rad_to_deg(
		_rider_air_roll_rate * state.step
	)
	_rider_air_accumulated_pitch_degrees += rad_to_deg(
		_rider_air_pitch_rate * state.step
	)


func _calculate_rider_world_attitude(vehicle_transform: Transform3D) -> Vector2:
	var vehicle_basis := vehicle_transform.basis.orthonormalized()
	var vehicle_forward := -vehicle_basis.z
	var vehicle_up := vehicle_basis.y
	var pitch := asin(clampf(vehicle_forward.y, -1.0, 1.0))
	var horizontal_forward := vehicle_forward.slide(Vector3.UP)
	var reference_right := vehicle_basis.x
	if horizontal_forward.length_squared() > 0.000001:
		horizontal_forward = horizontal_forward.normalized()
		reference_right = horizontal_forward.cross(Vector3.UP).normalized()
	var roll := atan2(
		vehicle_up.dot(reference_right),
		vehicle_up.dot(Vector3.UP)
	)
	return Vector2(roll, pitch)


func _capture_submarine_pre_contact_state(state: PhysicsDirectBodyState3D) -> void:
	var attitude := _calculate_rider_world_attitude(state.transform)
	_submarine_pre_contact_valid = (
		state.transform.is_finite()
		and state.linear_velocity.is_finite()
		and state.angular_velocity.is_finite()
		and attitude.is_finite()
	)
	if not _submarine_pre_contact_valid:
		return
	_submarine_pre_contact_transform = state.transform
	_submarine_pre_contact_linear_velocity = state.linear_velocity
	_submarine_pre_contact_angular_velocity = state.angular_velocity
	_submarine_pre_contact_roll_degrees = rad_to_deg(attitude.x)
	_submarine_pre_contact_pitch_degrees = rad_to_deg(attitude.y)
	_submarine_pre_contact_horizontal_speed = Vector2(
		state.linear_velocity.x,
		state.linear_velocity.z
	).length()


func _update_submarine_before_forces(
	state: PhysicsDirectBodyState3D,
	physics_delta: float
) -> void:
	if _rider_stunt_water_mode == RiderStuntWaterMode.SUBMARINE_DIVE:
		_submarine_duration += maxf(physics_delta, 0.0)
		var forward_input := maxf(-_rider_shift_raw_input.y, 0.0)
		var horizontal_speed := Vector2(
			state.linear_velocity.x,
			state.linear_velocity.z
		).length()
		var current_attitude := _calculate_rider_world_attitude(state.transform)
		var exit_requested := (
			not submarine_dive_enabled
			or forward_input < 0.60
			or _submarine_duration >= submarine_max_duration
			or horizontal_speed < SUBMARINE_MIN_EXIT_SPEED
			or rad_to_deg(current_attitude.y) > SUBMARINE_CLEAR_NOSE_UP_DEGREES
			or _submarine_current_depth >= SUBMARINE_SAFETY_DEPTH
		)
		if exit_requested:
			_end_submarine_dive()
	if _rider_stunt_water_mode == RiderStuntWaterMode.SUBMARINE_DIVE:
		_submarine_buoyancy_factor_current = move_toward(
			_submarine_buoyancy_factor_current,
			submarine_buoyancy_factor,
			maxf(physics_delta, 0.0)
			* absf(1.0 - submarine_buoyancy_factor)
			/ SUBMARINE_ENTRY_BUOYANCY_BLEND_TIME
		)
		_submarine_propulsion_factor_current = submarine_propulsion_factor
		_submarine_upright_factor_current = submarine_upright_factor
		_submarine_exit_blend = 0.0
		_submarine_recovery_active = false
		return
	if _submarine_recovery_active:
		_submarine_exit_blend = minf(
			_submarine_exit_blend
			+ maxf(physics_delta, 0.0) / maxf(submarine_exit_blend_time, 0.0001),
			1.0
		)
		var recovery_weight := smoothstep(0.0, 1.0, _submarine_exit_blend)
		_submarine_buoyancy_factor_current = lerpf(
			_submarine_exit_start_buoyancy_factor,
			1.0,
			recovery_weight
		)
		_submarine_propulsion_factor_current = lerpf(
			submarine_propulsion_factor,
			1.0,
			recovery_weight
		)
		_submarine_upright_factor_current = lerpf(
			submarine_upright_factor,
			1.0,
			recovery_weight
		)
		if _submarine_exit_blend >= 1.0:
			_submarine_recovery_active = false
		return
	_submarine_buoyancy_factor_current = 1.0
	_submarine_propulsion_factor_current = 1.0
	_submarine_upright_factor_current = 1.0
	_submarine_exit_blend = 1.0


func _update_submarine_after_contacts(state: PhysicsDirectBodyState3D) -> void:
	var first_water_contact := (
		previous_contact_mask == 0
		and current_contact_mask != 0
	)
	if first_water_contact:
		_try_start_submarine_dive(state)
		_submarine_pre_contact_valid = false
	if (
		_rider_stunt_water_mode == RiderStuntWaterMode.SUBMARINE_DIVE
		or _submarine_recovery_active
	):
		_submarine_current_depth = maxf(
			water_physics_system.state.average_depth,
			0.0
		)
		_submarine_max_depth = maxf(
			_submarine_max_depth,
			_submarine_current_depth
		)
	elif current_contact_mask == 0:
		_submarine_current_depth = 0.0


func _try_start_submarine_dive(_state: PhysicsDirectBodyState3D) -> void:
	if (
		not submarine_dive_enabled
		or not _submarine_pre_contact_valid
		or _rider_stunt_water_mode != RiderStuntWaterMode.NORMAL
		or _submarine_recovery_active
	):
		return
	var forward_input := maxf(-_rider_shift_raw_input.y, 0.0)
	var nose_down_degrees := -_submarine_pre_contact_pitch_degrees
	var vehicle_up := _submarine_pre_contact_transform.basis.y.normalized()
	var valid_entry := (
		forward_input >= 0.60
		and _submarine_pre_contact_horizontal_speed >= submarine_entry_min_speed
		and nose_down_degrees >= submarine_entry_min_nose_down_degrees
		and nose_down_degrees <= submarine_entry_max_nose_down_degrees
		and absf(_submarine_pre_contact_roll_degrees) < SUBMARINE_MAX_ENTRY_ROLL_DEGREES
		and vehicle_up.dot(Vector3.UP) > 0.25
		and _front_leads_submarine_entry()
	)
	if not valid_entry:
		return
	_rider_stunt_water_mode = RiderStuntWaterMode.SUBMARINE_DIVE
	_submarine_entry_speed = _submarine_pre_contact_horizontal_speed
	_submarine_entry_pitch_degrees = _submarine_pre_contact_pitch_degrees
	_submarine_duration = 0.0
	_submarine_current_depth = maxf(
		water_physics_system.state.average_depth,
		0.0
	)
	_submarine_max_depth = _submarine_current_depth
	_submarine_exit_blend = 0.0
	_submarine_recovery_active = false
	_submarine_propulsion_factor_current = submarine_propulsion_factor
	_submarine_upright_factor_current = submarine_upright_factor
	_cancel_rider_trick_state_for_submarine()
	submarine_dive_started.emit()


func _front_leads_submarine_entry() -> bool:
	var front_contacts := navigation_system.count_contact_bits(
		new_contact_mask & FRONT_CONTACT_MASK
	)
	var rear_contacts := navigation_system.count_contact_bits(
		new_contact_mask & REAR_CONTACT_MASK
	)
	var point_depths := water_physics_system.point_depths
	var front_depth := (point_depths[0] + point_depths[1]) * 0.5
	var rear_depth := (point_depths[2] + point_depths[3]) * 0.5
	return (
		front_contacts > 0
		and (
			front_contacts > rear_contacts
			or front_depth > rear_depth + 0.05
		)
	)


func _calculate_submarine_pitch_target_torque(
	state: PhysicsDirectBodyState3D,
	body_right: Vector3
) -> Vector3:
	if _rider_stunt_water_mode != RiderStuntWaterMode.SUBMARINE_DIVE:
		return Vector3.ZERO
	var target_pitch := -deg_to_rad(submarine_target_nose_down_degrees)
	var pitch_error := wrapf(
		target_pitch
		- rider_dynamics_system.state.rider_shift_current_pitch,
		-PI,
		PI
	)
	var pitch_rate := state.angular_velocity.dot(body_right)
	var target_stiffness := rider_soft_limit_stiffness * 0.30
	var target_damping := rider_soft_limit_damping * 0.20
	var maximum_target_torque := (
		rider_soft_limit_stiffness * deg_to_rad(20.0)
	)
	var target_torque := clampf(
		pitch_error * target_stiffness - pitch_rate * target_damping,
		-maximum_target_torque,
		maximum_target_torque
	)
	return (
		body_right
		* target_torque
		* rider_dynamics_system.state.rider_manual_medium_authority
	)


func _submarine_control_blend() -> float:
	if _rider_stunt_water_mode == RiderStuntWaterMode.SUBMARINE_DIVE:
		return 1.0
	if _submarine_recovery_active:
		return 1.0 - _submarine_exit_blend
	return 0.0


func _end_submarine_dive() -> void:
	if _rider_stunt_water_mode != RiderStuntWaterMode.SUBMARINE_DIVE:
		return
	_rider_stunt_water_mode = RiderStuntWaterMode.NORMAL
	_submarine_recovery_active = true
	_submarine_exit_start_buoyancy_factor = _submarine_buoyancy_factor_current
	_submarine_exit_blend = 0.0
	submarine_dive_ended.emit(_submarine_duration, _submarine_max_depth)


func _reset_submarine_state(emit_end_signal: bool) -> void:
	if (
		emit_end_signal
		and _rider_stunt_water_mode == RiderStuntWaterMode.SUBMARINE_DIVE
	):
		submarine_dive_ended.emit(_submarine_duration, _submarine_max_depth)
	_rider_stunt_water_mode = RiderStuntWaterMode.NORMAL
	_submarine_entry_speed = 0.0
	_submarine_entry_pitch_degrees = 0.0
	_submarine_duration = 0.0
	_submarine_current_depth = 0.0
	_submarine_max_depth = 0.0
	_submarine_buoyancy_factor_current = 1.0
	_submarine_propulsion_factor_current = 1.0
	_submarine_upright_factor_current = 1.0
	_submarine_exit_blend = 1.0
	_submarine_exit_start_buoyancy_factor = 1.0
	_submarine_recovery_active = false
	_submarine_pre_contact_valid = false
	_submarine_pre_contact_transform = Transform3D.IDENTITY
	_submarine_pre_contact_linear_velocity = Vector3.ZERO
	_submarine_pre_contact_angular_velocity = Vector3.ZERO
	_submarine_pre_contact_roll_degrees = 0.0
	_submarine_pre_contact_pitch_degrees = 0.0
	_submarine_pre_contact_horizontal_speed = 0.0


func _update_rider_trick_state(
	state: PhysicsDirectBodyState3D,
	physics_delta: float
) -> void:
	var gained_support := not previous_has_any_support and has_any_support
	if gained_support:
		_reset_trick_for_new_support_contact()
	if (
		not rider_weight_shift_enabled
		or not trick_preload_enabled
		or navigation_state == NavigationState.DEEP_SUBMERGED
		or _rider_stunt_water_mode == RiderStuntWaterMode.SUBMARINE_DIVE
	):
		_cancel_rider_trick_state_for_submarine()
		return
	_update_trick_reversal_timers(physics_delta)
	var horizontal_speed := Vector2(
		state.linear_velocity.x,
		state.linear_velocity.z
	).length()
	var launch_speed_factor := smoothstep(
		trick_minimum_launch_speed,
		maxf(trick_full_launch_speed, trick_minimum_launch_speed + 0.001),
		horizontal_speed
	)
	if has_any_support:
		if has_water_support:
			_trick_last_contact_average_depth = (
				water_physics_system.state.average_depth
			)
		elif has_solid_support:
			# A solid ramp has no buoyancy depth. Use the neutral midpoint of the
			# small 0.95-1.05 depth modifier instead of penalizing it.
			_trick_last_contact_average_depth = max_submersion_depth * 0.25
		_trick_takeoff_pending = false
		_trick_time_since_takeoff = 0.0
		_update_trick_roll_preload(
			_rider_shift_raw_input.x,
			physics_delta,
			false
		)
		_update_trick_pitch_preload(
			_rider_shift_raw_input.y,
			physics_delta,
			false
		)
	if true_takeoff_this_tick:
		_prepare_trick_takeoff_context(
			state,
			launch_speed_factor,
			horizontal_speed >= trick_minimum_launch_speed
		)
		_try_start_trick_release(false)
		if not _trick_launch_consumed:
			_detect_coyote_reversals()
			_try_start_trick_release(true)
	elif _trick_takeoff_pending and not _trick_launch_consumed:
		_trick_time_since_takeoff += maxf(physics_delta, 0.0)
		if _trick_time_since_takeoff <= trick_takeoff_coyote_time:
			_detect_coyote_reversals()
			_try_start_trick_release(true)
		else:
			_cancel_expired_trick_takeoff()
	_update_trick_preload_state_metric()


func _update_trick_roll_preload(
	axis_input: float,
	physics_delta: float,
	allow_air_reversal: bool
) -> void:
	if _trick_roll_reversal_armed:
		return
	var input_magnitude := absf(axis_input)
	var input_sign := signf(axis_input)
	if (
		input_magnitude >= trick_reversal_min_input
		and input_sign == -_trick_roll_preload_sign
		and _trick_roll_preload_sign != 0.0
		and _trick_roll_hold_time >= trick_preload_min_hold_time
		and _trick_roll_charge >= trick_minimum_release_charge
	):
		_trick_roll_reversal_armed = true
		_trick_roll_reversal_direction = input_sign
		_trick_roll_armed_charge = _trick_roll_charge
		_trick_roll_reversal_time_remaining = (
			trick_takeoff_coyote_time - _trick_time_since_takeoff
			if allow_air_reversal
			else trick_reversal_takeoff_window
		)
		return
	if allow_air_reversal:
		return
	if input_magnitude >= trick_preload_min_input:
		if _trick_roll_preload_sign == 0.0:
			_trick_roll_preload_sign = input_sign
		if input_sign == _trick_roll_preload_sign:
			_trick_roll_hold_time += maxf(physics_delta, 0.0)
			_trick_roll_charge = minf(
				_trick_roll_charge
				+ maxf(physics_delta, 0.0)
				/ maxf(trick_preload_full_charge_time, 0.001)
				* input_magnitude,
				1.0
			)
			return
	_decay_trick_roll_preload(physics_delta)


func _update_trick_pitch_preload(
	axis_input: float,
	physics_delta: float,
	allow_air_reversal: bool
) -> void:
	if _trick_pitch_reversal_armed:
		return
	var input_magnitude := absf(axis_input)
	var input_sign := signf(axis_input)
	if (
		input_magnitude >= trick_reversal_min_input
		and input_sign == -_trick_pitch_preload_sign
		and _trick_pitch_preload_sign != 0.0
		and _trick_pitch_hold_time >= trick_preload_min_hold_time
		and _trick_pitch_charge >= trick_minimum_release_charge
	):
		_trick_pitch_reversal_armed = true
		_trick_pitch_reversal_direction = input_sign
		_trick_pitch_armed_charge = _trick_pitch_charge
		_trick_pitch_reversal_time_remaining = (
			trick_takeoff_coyote_time - _trick_time_since_takeoff
			if allow_air_reversal
			else trick_reversal_takeoff_window
		)
		return
	if allow_air_reversal:
		return
	if input_magnitude >= trick_preload_min_input:
		if _trick_pitch_preload_sign == 0.0:
			_trick_pitch_preload_sign = input_sign
		if input_sign == _trick_pitch_preload_sign:
			_trick_pitch_hold_time += maxf(physics_delta, 0.0)
			_trick_pitch_charge = minf(
				_trick_pitch_charge
				+ maxf(physics_delta, 0.0)
				/ maxf(trick_preload_full_charge_time, 0.001)
				* input_magnitude,
				1.0
			)
			return
	_decay_trick_pitch_preload(physics_delta)


func _detect_coyote_reversals() -> void:
	_update_trick_roll_preload(
		_rider_shift_raw_input.x,
		0.0,
		true
	)
	_update_trick_pitch_preload(
		_rider_shift_raw_input.y,
		0.0,
		true
	)


func _prepare_trick_takeoff_context(
	state: PhysicsDirectBodyState3D,
	launch_speed_factor: float,
	launch_speed_valid: bool
) -> void:
	_trick_takeoff_pending = true
	_trick_time_since_takeoff = 0.0
	_trick_takeoff_quality = 0.0
	_trick_takeoff_timing_factor = 0.0
	_trick_pending_speed_factor = launch_speed_factor
	_trick_pending_launch_speed_valid = launch_speed_valid
	_trick_pending_upward_factor = smoothstep(
		0.0,
		6.0,
		maxf(state.linear_velocity.y, 0.0)
	)
	_trick_pending_depth_factor = smoothstep(
		0.0,
		maxf(max_submersion_depth * 0.5, 0.001),
		_trick_last_contact_average_depth
	)


func _try_start_trick_release(using_coyote_time: bool) -> void:
	if _trick_launch_consumed or _trick_release_active:
		return
	if not _trick_pending_launch_speed_valid:
		return
	var roll_charge := (
		_trick_roll_armed_charge
		if _trick_roll_reversal_armed
		else 0.0
	)
	var pitch_charge := (
		_trick_pitch_armed_charge
		if _trick_pitch_reversal_armed
		else 0.0
	)
	if (
		roll_charge < trick_minimum_release_charge
		and pitch_charge < trick_minimum_release_charge
	):
		return
	var roll_timing_factor := (
		_trick_reversal_timing_factor(
			_trick_roll_reversal_time_remaining,
			using_coyote_time
		)
		if _trick_roll_reversal_armed
		else 0.0
	)
	var pitch_timing_factor := (
		_trick_reversal_timing_factor(
			_trick_pitch_reversal_time_remaining,
			using_coyote_time
		)
		if _trick_pitch_reversal_armed
		else 0.0
	)
	_trick_takeoff_timing_factor = maxf(
		roll_timing_factor,
		pitch_timing_factor
	)
	var roll_quality := _calculate_trick_takeoff_quality(roll_timing_factor)
	var pitch_quality := _calculate_trick_takeoff_quality(pitch_timing_factor)
	var release_strength := Vector2(
		_trick_roll_reversal_direction
			* pow(roll_charge, trick_release_curve_power)
			* roll_quality,
		_trick_pitch_reversal_direction
			* pow(pitch_charge, trick_release_curve_power)
			* pitch_quality
	)
	if release_strength.length_squared() > 1.0:
		release_strength = release_strength.normalized()
	if release_strength.is_zero_approx():
		return
	_trick_takeoff_quality = maxf(roll_quality, pitch_quality)
	_start_trick_release(
		release_strength,
		Vector2(
			_trick_roll_preload_sign * roll_charge,
			_trick_pitch_preload_sign * pitch_charge
		)
	)


func _trick_reversal_timing_factor(
	reversal_time_remaining: float,
	using_coyote_time: bool
) -> float:
	if using_coyote_time:
		if trick_takeoff_coyote_time <= 0.0:
			return 1.0 if _trick_time_since_takeoff <= 0.0 else 0.0
		if _trick_time_since_takeoff <= TRICK_POST_TAKEOFF_OPTIMAL_TIME:
			return 1.0
		var post_takeoff_blend := smoothstep(
			TRICK_POST_TAKEOFF_OPTIMAL_TIME,
			maxf(trick_takeoff_coyote_time, TRICK_POST_TAKEOFF_OPTIMAL_TIME + 0.001),
			_trick_time_since_takeoff
		)
		return lerpf(1.0, TRICK_POST_TAKEOFF_MINIMUM_TIMING, post_takeoff_blend)
	var reversal_age := maxf(
		trick_reversal_takeoff_window - reversal_time_remaining,
		0.0
	)
	if reversal_age <= TRICK_PRE_TAKEOFF_OPTIMAL_TIME:
		return 1.0
	var pre_takeoff_blend := smoothstep(
		TRICK_PRE_TAKEOFF_OPTIMAL_TIME,
		maxf(trick_reversal_takeoff_window, TRICK_PRE_TAKEOFF_OPTIMAL_TIME + 0.001),
		reversal_age
	)
	return lerpf(1.0, TRICK_PRE_TAKEOFF_MINIMUM_TIMING, pre_takeoff_blend)


func _calculate_trick_takeoff_quality(reversal_timing_factor: float) -> float:
	var speed_quality := lerpf(0.65, 1.0, _trick_pending_speed_factor)
	var upward_bonus := lerpf(0.90, 1.05, _trick_pending_upward_factor)
	var depth_bonus := lerpf(0.95, 1.05, _trick_pending_depth_factor)
	return clampf(
		reversal_timing_factor
		* speed_quality
		* upward_bonus
		* depth_bonus,
		0.0,
		1.1
	)


func _start_trick_release(
	release_strength: Vector2,
	launch_charge: Vector2
) -> void:
	_trick_release_active = true
	_trick_release_elapsed = 0.0
	_trick_release_time_remaining = trick_release_duration
	_trick_release_strength = release_strength
	_trick_release_charge = launch_charge
	_trick_launch_consumed = true
	_trick_takeoff_pending = false
	_trick_pending_launch_speed_valid = false
	_trick_last_launch_type = _classify_rider_trick_launch(release_strength)
	_trick_last_launch_charge = launch_charge
	_trick_last_release_strength = release_strength
	_clear_trick_roll_preload()
	_clear_trick_pitch_preload()
	_trick_preload_state = TrickPreloadState.RELEASE_ACTIVE
	rider_trick_launched.emit(
		_trick_last_launch_type,
		launch_charge,
		release_strength
	)


func _classify_rider_trick_launch(
	release_strength: Vector2
) -> JetSkiTypes.RiderTrickLaunchType:
	var has_roll := absf(release_strength.x) > 0.0001
	var has_pitch := absf(release_strength.y) > 0.0001
	if has_roll and has_pitch:
		return RiderTrickLaunchType.COMBINED
	if release_strength.x > 0.0:
		return RiderTrickLaunchType.BARREL_RIGHT
	if release_strength.x < 0.0:
		return RiderTrickLaunchType.BARREL_LEFT
	if release_strength.y > 0.0:
		return RiderTrickLaunchType.BACKFLIP
	if release_strength.y < 0.0:
		return RiderTrickLaunchType.FRONTFLIP
	return RiderTrickLaunchType.NONE


func _get_rider_trick_launch_type_name(
	trick_type: JetSkiTypes.RiderTrickLaunchType
) -> StringName:
	match trick_type:
		RiderTrickLaunchType.BARREL_LEFT:
			return &"BARREL_L"
		RiderTrickLaunchType.BARREL_RIGHT:
			return &"BARREL_R"
		RiderTrickLaunchType.BACKFLIP:
			return &"BACKFLIP"
		RiderTrickLaunchType.FRONTFLIP:
			return &"FRONTFLIP"
		RiderTrickLaunchType.COMBINED:
			return &"COMBINED"
	return &"NONE"


func _update_trick_reversal_timers(physics_delta: float) -> void:
	if _trick_roll_reversal_armed:
		_trick_roll_reversal_time_remaining = (
			_trick_roll_reversal_time_remaining - maxf(physics_delta, 0.0)
		)
		if _trick_roll_reversal_time_remaining < -0.0001:
			_clear_trick_roll_preload()
	if _trick_pitch_reversal_armed:
		_trick_pitch_reversal_time_remaining = (
			_trick_pitch_reversal_time_remaining - maxf(physics_delta, 0.0)
		)
		if _trick_pitch_reversal_time_remaining < -0.0001:
			_clear_trick_pitch_preload()


func _decay_trick_roll_preload(physics_delta: float) -> void:
	_trick_roll_charge = move_toward(
		_trick_roll_charge,
		0.0,
		maxf(physics_delta, 0.0) * trick_preload_decay_rate
	)
	if _trick_roll_charge <= 0.0001:
		_clear_trick_roll_preload()


func _decay_trick_pitch_preload(physics_delta: float) -> void:
	_trick_pitch_charge = move_toward(
		_trick_pitch_charge,
		0.0,
		maxf(physics_delta, 0.0) * trick_preload_decay_rate
	)
	if _trick_pitch_charge <= 0.0001:
		_clear_trick_pitch_preload()


func _clear_trick_roll_preload() -> void:
	_trick_roll_preload_sign = 0.0
	_trick_roll_hold_time = 0.0
	_trick_roll_charge = 0.0
	_trick_roll_reversal_armed = false
	_trick_roll_reversal_direction = 0.0
	_trick_roll_armed_charge = 0.0
	_trick_roll_reversal_time_remaining = 0.0


func _clear_trick_pitch_preload() -> void:
	_trick_pitch_preload_sign = 0.0
	_trick_pitch_hold_time = 0.0
	_trick_pitch_charge = 0.0
	_trick_pitch_reversal_armed = false
	_trick_pitch_reversal_direction = 0.0
	_trick_pitch_armed_charge = 0.0
	_trick_pitch_reversal_time_remaining = 0.0


func _cancel_expired_trick_takeoff() -> void:
	_trick_takeoff_pending = false
	_trick_pending_launch_speed_valid = false
	_trick_launch_consumed = true
	_clear_trick_roll_preload()
	_clear_trick_pitch_preload()


func _reset_trick_for_new_support_contact() -> void:
	_trick_launch_consumed = false
	_trick_takeoff_pending = false
	_trick_time_since_takeoff = 0.0
	_trick_pending_launch_speed_valid = false
	_trick_release_active = false
	_trick_release_elapsed = 0.0
	_trick_release_time_remaining = 0.0
	_trick_release_strength = Vector2.ZERO
	_trick_release_charge = Vector2.ZERO
	_trick_release_roll_torque = 0.0
	_trick_release_pitch_torque = 0.0
	_clear_trick_roll_preload()
	_clear_trick_pitch_preload()


func _cancel_rider_trick_state_for_submarine() -> void:
	_trick_takeoff_pending = false
	_trick_pending_launch_speed_valid = false
	_trick_release_active = false
	_trick_release_elapsed = 0.0
	_trick_release_time_remaining = 0.0
	_trick_release_strength = Vector2.ZERO
	_trick_release_charge = Vector2.ZERO
	_trick_release_roll_torque = 0.0
	_trick_release_pitch_torque = 0.0
	_trick_launch_consumed = true
	_clear_trick_roll_preload()
	_clear_trick_pitch_preload()
	_update_trick_preload_state_metric()


func _update_trick_preload_state_metric() -> void:
	if _trick_release_active:
		_trick_preload_state = TrickPreloadState.RELEASE_ACTIVE
	elif _trick_roll_reversal_armed or _trick_pitch_reversal_armed:
		_trick_preload_state = TrickPreloadState.REVERSAL_ARMED
	elif _trick_roll_charge > 0.0 or _trick_pitch_charge > 0.0:
		_trick_preload_state = TrickPreloadState.CHARGING
	else:
		_trick_preload_state = TrickPreloadState.IDLE


func _reset_trick_state() -> void:
	_trick_preload_state = TrickPreloadState.IDLE
	_trick_takeoff_pending = false
	_trick_time_since_takeoff = 0.0
	_trick_pending_speed_factor = 0.0
	_trick_pending_upward_factor = 0.0
	_trick_pending_depth_factor = 0.0
	_trick_pending_launch_speed_valid = false
	_trick_last_contact_average_depth = 0.0
	_trick_takeoff_quality = 0.0
	_trick_takeoff_timing_factor = 0.0
	_trick_release_active = false
	_trick_release_elapsed = 0.0
	_trick_release_time_remaining = 0.0
	_trick_release_strength = Vector2.ZERO
	_trick_release_charge = Vector2.ZERO
	_trick_release_roll_torque = 0.0
	_trick_release_pitch_torque = 0.0
	_trick_launch_consumed = false
	_trick_last_launch_type = RiderTrickLaunchType.NONE
	_trick_last_launch_charge = Vector2.ZERO
	_trick_last_release_strength = Vector2.ZERO
	_air_correction_roll_torque_current = 0.0
	_air_correction_pitch_torque_current = 0.0
	_clear_trick_roll_preload()
	_clear_trick_pitch_preload()


func _clear_air_control_frame_metrics() -> void:
	_rider_air_unlimited_rotation = false
	_rider_air_roll_rate = 0.0
	_rider_air_pitch_rate = 0.0
	_trick_release_roll_torque = 0.0
	_trick_release_pitch_torque = 0.0
	_air_correction_roll_torque_current = 0.0
	_air_correction_pitch_torque_current = 0.0


func _reset_air_control_state() -> void:
	input_system.reset_rider_shift()
	_rider_air_accumulated_roll_degrees = 0.0
	_rider_air_accumulated_pitch_degrees = 0.0
	_rider_air_tracking_active = false
	_clear_air_control_frame_metrics()


func _on_input_system_rider_weight_shift_changed(shift: Vector2) -> void:
	rider_weight_shift_changed.emit(shift)


func _warn_about_missing_water_once() -> void:
	if _water_warning_emitted:
		return
	_water_warning_emitted = true
	push_warning("JetSki buoyancy is disabled because its Ocean3D reference is invalid.")


func _warn_about_invalid_rider_air_once(message: String) -> void:
	if _rider_air_warning_emitted:
		return
	_rider_air_warning_emitted = true
	push_warning(message)
