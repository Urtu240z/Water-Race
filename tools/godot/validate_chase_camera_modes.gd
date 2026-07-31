extends SceneTree

const VEHICLE_SCENE := preload("res://scenes/vehicle/jet_ski_with_rider.tscn")
const CAMERA_SCENE := preload("res://scenes/camera/chase_camera.tscn")

var _failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	_validate_input_map()
	var test_root := Node3D.new()
	test_root.name = "CameraModeValidation"
	get_root().add_child(test_root)
	var vehicle := VEHICLE_SCENE.instantiate() as JetSkiController
	vehicle.name = "Vehicle"
	vehicle.freeze = true
	test_root.add_child(vehicle)
	var camera := CAMERA_SCENE.instantiate() as ChaseCamera
	camera.name = "Camera"
	camera.vehicle_body_path = NodePath("../Vehicle")
	camera.camera_target_path = NodePath("../Vehicle/CameraTarget")
	camera.first_person_socket_path = NodePath(
		"../Vehicle/VisualRoot/RiderMount/FirstPersonSocket"
	)
	test_root.add_child(camera)
	await process_frame
	camera.set_process(false)
	_validate_scene_configuration(vehicle, camera)
	await _validate_camera_toggle(camera)
	_validate_normal_arcade_follow(vehicle, camera)
	_validate_arcade_stunt(vehicle, camera)
	_validate_first_person_orientation(vehicle, camera)
	_validate_reset_and_rebase(vehicle, camera)
	if not camera.global_transform.is_finite():
		_fail("Camera transform became non-finite.")
	test_root.queue_free()
	await process_frame
	if _failures.is_empty():
		print("CHASE_CAMERA_MODES_VALIDATION_OK")
		quit(0)
		return
	for failure: String in _failures:
		push_error(failure)
	print("CHASE_CAMERA_MODES_VALIDATION_FAILED count=%d" % _failures.size())
	quit(1)


func _validate_input_map() -> void:
	if not InputMap.has_action(&"camera_toggle"):
		_fail("Input Map is missing camera_toggle.")
		return
	var has_c_key := false
	var has_back_button := false
	for event: InputEvent in InputMap.action_get_events(&"camera_toggle"):
		if event is InputEventKey:
			var key_event := event as InputEventKey
			has_c_key = has_c_key or key_event.physical_keycode == 67
		elif event is InputEventJoypadButton:
			var button_event := event as InputEventJoypadButton
			has_back_button = has_back_button or button_event.button_index == 4
	if not has_c_key:
		_fail("camera_toggle is missing physical C.")
	if not has_back_button:
		_fail("camera_toggle is missing standard JoyButton BACK (index 4).")


func _validate_scene_configuration(
	vehicle: JetSkiController,
	camera: ChaseCamera
) -> void:
	if camera.get_vehicle_body() != vehicle:
		_fail("ChaseCamera did not resolve the vehicle reference.")
	if camera.get_camera_target() == null:
		_fail("ChaseCamera did not resolve CameraTarget.")
	else:
		# Match the override used by island_test_BLENDER.tscn.
		camera.get_camera_target().position = Vector3(0.0, 0.8, 0.35)
	var socket := camera.get_first_person_socket()
	if socket == null:
		_fail("ChaseCamera did not resolve FirstPersonSocket.")
		return
	if socket.get_parent() == null or socket.get_parent().name != &"RiderMount":
		_fail("FirstPersonSocket is not attached to RiderMount.")
	var camera_count := 0
	var pending: Array[Node] = [camera]
	while not pending.is_empty():
		var current := pending.pop_back() as Node
		if current is Camera3D:
			camera_count += 1
		for child: Node in current.get_children():
			pending.append(child)
	if camera_count != 1:
		_fail("Camera rig must contain exactly one Camera3D.")
	if camera.get_camera_node().get_node_or_null("UnderwaterEffect") == null:
		_fail("UnderwaterEffect is no longer attached to Camera3D.")
	var active_rider_mesh := vehicle.get_node_or_null(
		"VisualRoot/RiderMount/RiderAssetRoot/RiderRig/RiderModelRoot/"
		+ "Rider_Bot/SKEL_Rider/Skeleton3D/Rider05_Body"
	) as MeshInstance3D
	if active_rider_mesh == null or not active_rider_mesh.visible:
		_fail("Active rider body is unavailable before entering first person.")
	if socket.position.z >= -0.1:
		_fail("FirstPersonSocket is not far enough ahead of the rider head volume.")


func _validate_camera_toggle(camera: ChaseCamera) -> void:
	if camera.current_camera_mode != ChaseCamera.CameraMode.ARCADE:
		_fail("Camera did not start in ARCADE mode.")
	Input.action_press(&"camera_toggle")
	camera.call("_update_camera_mode_input")
	Input.action_release(&"camera_toggle")
	if camera.current_camera_mode != ChaseCamera.CameraMode.FIRST_PERSON:
		_fail("camera_toggle did not enter FIRST_PERSON.")
	await process_frame
	Input.action_press(&"camera_toggle")
	camera.call("_update_camera_mode_input")
	Input.action_release(&"camera_toggle")
	if camera.current_camera_mode != ChaseCamera.CameraMode.ARCADE:
		_fail("camera_toggle did not return to ARCADE.")
	await process_frame


func _validate_arcade_stunt(
	vehicle: JetSkiController,
	camera: ChaseCamera
) -> void:
	camera.camera_mode_transition_duration = 0.0
	camera.call("_enter_camera_mode", ChaseCamera.CameraMode.ARCADE)
	vehicle.global_transform = Transform3D(
		Basis.IDENTITY.scaled(Vector3.ONE * 1.5),
		Vector3.ZERO
	)
	vehicle.linear_velocity = Vector3(0.0, 0.0, -30.0)
	vehicle.navigation_system.state.navigation_state = (
		JetSkiController.NavigationState.AIRBORNE
	)
	vehicle.reset_physics_interpolation()
	camera.snap_to_target()
	vehicle.rider_trick_launched.emit(
		JetSkiTypes.RiderTrickLaunchType.BACKFLIP,
		Vector2.UP,
		Vector2.UP
	)
	if camera.arcade_camera_state != ChaseCamera.ArcadeCameraState.STUNT:
		_fail("rider_trick_launched did not activate the arcade stunt camera.")
	vehicle.global_transform = Transform3D(
		Basis.from_euler(Vector3(PI, 0.0, 0.0)).scaled(Vector3.ONE * 1.5),
		Vector3.ZERO
	)
	vehicle.reset_physics_interpolation()
	camera.call("_process", 1.0 / 60.0)
	if absf(camera.global_basis.x.dot(Vector3.UP)) > 0.001:
		_fail("Arcade stunt camera did not keep a stable world-up horizon.")
	var horizontal_camera_forward := Vector3(
		-camera.global_basis.z.x,
		0.0,
		-camera.global_basis.z.z
	).normalized()
	if horizontal_camera_forward.dot(Vector3.FORWARD) < 0.5:
		_fail("Arcade stunt camera reversed its horizontal follow direction.")
	var stable_target_offset := Vector3.ZERO
	var maximum_target_offset_error := 0.0
	var minimum_camera_behind_distance := INF
	var locked_stunt_rotation := (
		camera.global_basis.orthonormalized().get_rotation_quaternion()
	)
	var maximum_stunt_rotation_error := 0.0
	for flip_frame: int in 25:
		var flip_ratio := float(flip_frame) / 24.0
		var flip_angle := flip_ratio * TAU
		var vehicle_position := Vector3(0.0, 2.0, -flip_frame * 0.5)
		vehicle.global_transform = Transform3D(
			Basis.from_euler(Vector3(flip_angle, 0.0, 0.0)).scaled(
				Vector3.ONE * 1.5
			),
			vehicle_position
		)
		vehicle.navigation_system.state.navigation_state = (
			JetSkiController.NavigationState.IN_WATER
			if flip_frame == 12
			else JetSkiController.NavigationState.AIRBORNE
		)
		vehicle.reset_physics_interpolation()
		camera.call("_process", 1.0 / 60.0)
		maximum_stunt_rotation_error = maxf(
			maximum_stunt_rotation_error,
			locked_stunt_rotation.angle_to(
				camera.global_basis.orthonormalized().get_rotation_quaternion()
			)
		)
		var stabilized_target: Vector3 = camera.call(
			"_get_arcade_target_position",
			camera.get_camera_target().global_transform
		)
		var target_offset := stabilized_target - vehicle_position
		if flip_frame == 0:
			stable_target_offset = target_offset
		maximum_target_offset_error = maxf(
			maximum_target_offset_error,
			target_offset.distance_to(stable_target_offset)
		)
		var camera_from_vehicle := camera.global_position - vehicle_position
		minimum_camera_behind_distance = minf(
			minimum_camera_behind_distance,
			-camera_from_vehicle.dot(Vector3.FORWARD)
		)
		if flip_frame == 12 and (
			camera.arcade_camera_state != ChaseCamera.ArcadeCameraState.STUNT
		):
			_fail("An inverted one-frame water contact ended the stunt camera.")
	if maximum_target_offset_error > 0.001:
		_fail("CameraTarget orbited around the vehicle during a full flip.")
	if maximum_stunt_rotation_error > 0.001:
		_fail("Arcade camera orientation changed during a full flip.")
	if minimum_camera_behind_distance < 0.25:
		_fail("Arcade camera crossed in front of the rider during a full flip.")
	vehicle.navigation_system.state.navigation_state = (
		JetSkiController.NavigationState.IN_WATER
	)
	vehicle.global_transform = Transform3D(
		Basis.IDENTITY.scaled(Vector3.ONE * 1.5),
		Vector3(0.0, 0.0, -12.0)
	)
	vehicle.reset_physics_interpolation()
	for confirmation_frame: int in 9:
		camera.call("_process", 1.0 / 60.0)
	if camera.arcade_camera_state != ChaseCamera.ArcadeCameraState.RECOVERING:
		_fail("Stable landing did not start arcade camera recovery.")
	var previous_position := camera.global_position
	var maximum_step := 0.0
	for frame_index: int in 30:
		camera.call("_process", 1.0 / 60.0)
		maximum_step = maxf(
			maximum_step,
			camera.global_position.distance_to(previous_position)
		)
		previous_position = camera.global_position
	if camera.arcade_camera_state != ChaseCamera.ArcadeCameraState.NORMAL:
		_fail("Arcade stunt recovery did not return to NORMAL.")
	if maximum_step > 1.0:
		_fail("Arcade recovery produced an excessive per-frame position jump.")


func _validate_normal_arcade_follow(
	vehicle: JetSkiController,
	camera: ChaseCamera
) -> void:
	camera.camera_mode_transition_duration = 0.0
	camera.call("_enter_camera_mode", ChaseCamera.CameraMode.ARCADE)
	camera.base_distance = 3.0
	camera.base_height = 1.0
	camera.base_look_ahead = 3.0
	camera.maximum_speed_distance_extension = 0.0
	camera.airborne_extra_height = 0.2
	camera.airborne_extra_distance = 0.2
	camera.airborne_extra_look_ahead = 0.2
	vehicle.global_transform = Transform3D.IDENTITY
	vehicle.linear_velocity = Vector3(0.0, 0.0, -20.0)
	vehicle.navigation_system.state.navigation_state = (
		JetSkiController.NavigationState.IN_WATER
	)
	vehicle.reset_physics_interpolation()
	camera.snap_to_target()
	var worst_downward_forward := 0.0
	var minimum_behind_dot := 0.0
	for frame_index: int in 120:
		var wave_pitch := sin(float(frame_index) * 0.21) * deg_to_rad(18.0)
		var turn_yaw := sin(float(frame_index) * 0.035) * deg_to_rad(20.0)
		vehicle.global_transform = Transform3D(
			Basis.from_euler(Vector3(wave_pitch, turn_yaw, 0.0)),
			Vector3(0.0, sin(float(frame_index) * 0.21) * 0.25, -frame_index * 0.25)
		)
		vehicle.navigation_system.state.navigation_state = (
			JetSkiController.NavigationState.AIRBORNE
			if frame_index % 18 < 3
			else JetSkiController.NavigationState.IN_WATER
		)
		vehicle.reset_physics_interpolation()
		camera.call("_process", 1.0 / 60.0)
		var camera_forward := -camera.global_basis.z
		worst_downward_forward = minf(worst_downward_forward, camera_forward.y)
		var target := camera.get_camera_target()
		var vehicle_forward := Vector3(
			-vehicle.global_basis.z.x,
			0.0,
			-vehicle.global_basis.z.z
		).normalized()
		var camera_from_target := camera.global_position - target.global_position
		minimum_behind_dot = minf(
			minimum_behind_dot,
			camera_from_target.dot(vehicle_forward)
		)
	if worst_downward_forward < -0.35:
		_fail(
			"Normal arcade follow pitched down excessively while accelerating over waves."
		)
	if minimum_behind_dot >= -0.25:
		_fail("Normal arcade follow did not remain behind the rider.")


func _validate_first_person_orientation(
	vehicle: JetSkiController,
	camera: ChaseCamera
) -> void:
	vehicle.global_transform = Transform3D(
		Basis.from_euler(Vector3(PI * 0.65, PI * 0.2, PI * 0.5)),
		Vector3(4.0, 3.0, -2.0)
	)
	vehicle.reset_physics_interpolation()
	camera.call("_enter_camera_mode", ChaseCamera.CameraMode.FIRST_PERSON)
	camera.snap_to_target()
	var socket := camera.get_first_person_socket()
	var rotation_error := (
		camera.global_basis.orthonormalized().get_rotation_quaternion().angle_to(
			socket.global_basis.orthonormalized().get_rotation_quaternion()
		)
	)
	if rotation_error > 0.001:
		_fail("First person did not copy the socket's full pitch/yaw/roll orientation.")
	if not is_equal_approx(camera.get_camera_node().fov, camera.first_person_fov):
		_fail("First person FOV was not applied.")
	if not is_equal_approx(camera.get_camera_node().near, camera.first_person_near):
		_fail("First person near plane was not applied.")
	var active_rider_mesh := vehicle.get_node_or_null(
		"VisualRoot/RiderMount/RiderAssetRoot/RiderRig/RiderModelRoot/"
		+ "Rider_Bot/SKEL_Rider/Skeleton3D/Rider05_Body"
	) as MeshInstance3D
	if active_rider_mesh == null or not active_rider_mesh.visible:
		_fail("First person unexpectedly hid the rider arms/body mesh.")


func _validate_reset_and_rebase(
	vehicle: JetSkiController,
	camera: ChaseCamera
) -> void:
	var mode_before_reset := camera.current_camera_mode
	vehicle.reset_vehicle(&"camera_validation")
	camera.call("_process", 1.0 / 60.0)
	if camera.current_camera_mode != mode_before_reset:
		_fail("Vehicle reset did not preserve the selected camera mode.")
	if camera.arcade_camera_state != ChaseCamera.ArcadeCameraState.NORMAL:
		_fail("Vehicle reset did not cancel stunt/recovery state.")
	if camera.camera_mode_transition_ratio < 1.0:
		_fail("Vehicle reset did not cancel the active camera transition.")
	var shift := Vector3(128.0, 0.0, -64.0)
	var position_before_rebase := camera.global_position
	var mode_before_rebase := camera.current_camera_mode
	vehicle.apply_world_rebase(shift)
	camera.apply_world_rebase(shift)
	var expected_position := position_before_rebase - shift
	if camera.global_position.distance_to(expected_position) > 0.001:
		_fail("World rebase did not shift the camera's stored position.")
	if camera.current_camera_mode != mode_before_rebase:
		_fail("World rebase did not preserve the selected camera mode.")
	if not camera.global_transform.is_finite():
		_fail("World rebase produced a non-finite camera transform.")


func _fail(message: String) -> void:
	_failures.append(message)
