extends Node

var _failures: int = 0


func _ready() -> void:
	call_deferred(&"_run_validation")


func _run_validation() -> void:
	var actor_scene := load("res://world/props/boats/traffic/boat_traffic_actor.tscn") as PackedScene
	var ocean_scene := load("res://world/water/ocean/ocean_3d.tscn") as PackedScene
	var gold_city_scene := load("res://levels/gold_city/gold_city.tscn") as PackedScene
	_check(actor_scene != null, "BoatTrafficActor scene loads")
	_check(ocean_scene != null, "Ocean3D scene loads")
	_check(gold_city_scene != null, "Gold City scene still parses")
	if actor_scene == null or ocean_scene == null:
		_finish()
		return

	var test_root := Node3D.new()
	test_root.name = "BoatTrafficValidation"
	get_tree().root.add_child(test_root)

	var ocean := ocean_scene.instantiate() as Ocean3D
	ocean.name = "Ocean"
	test_root.add_child(ocean)

	var path := Path3D.new()
	path.name = "Path"
	var curve := Curve3D.new()
	curve.closed = true
	curve.add_point(Vector3(-8.0, 0.0, -8.0))
	curve.add_point(Vector3(8.0, 0.0, -8.0))
	curve.add_point(Vector3(8.0, 0.0, 8.0))
	curve.add_point(Vector3(-8.0, 0.0, 8.0))
	path.curve = curve
	test_root.add_child(path)

	var follow := PathFollow3D.new()
	follow.name = "PathFollow"
	follow.rotation_mode = PathFollow3D.ROTATION_ORIENTED
	follow.use_model_front = true
	follow.tilt_enabled = false
	path.add_child(follow)

	var actor := actor_scene.instantiate() as BoatTrafficActor
	actor.name = "Actor"
	actor.water_provider_path = NodePath("../../../Ocean")
	actor.speed_mps = 24.0
	actor.sample_length = 12.0
	actor.sample_width = 4.0
	actor.wake_width = 4.0
	actor.physical_wake_interval_distance = 3.0
	follow.add_child(actor)
	var wake := actor.get_node_or_null("WakeRoot/BoatWake") as WakeTrail3D

	var initial_progress := follow.progress
	var previous_progress := initial_progress
	var observed_loop_wrap := false
	var previous_heading := actor.global_basis.z
	var maximum_heading_step := 0.0
	var observed_heading_lag := false
	for _frame in 210:
		await get_tree().physics_frame
		if follow.progress + 0.01 < previous_progress:
			observed_loop_wrap = true
		previous_progress = follow.progress
		var current_heading := actor.global_basis.z
		current_heading.y = 0.0
		current_heading = current_heading.normalized()
		previous_heading.y = 0.0
		previous_heading = previous_heading.normalized()
		maximum_heading_step = maxf(
			maximum_heading_step,
			previous_heading.angle_to(current_heading)
		)
		var target_heading := follow.global_basis.z
		target_heading.y = 0.0
		if target_heading.length_squared() > 0.000001:
			observed_heading_lag = observed_heading_lag or (
				current_heading.angle_to(target_heading.normalized()) > deg_to_rad(2.0)
			)
		previous_heading = current_heading

	var path_length := curve.get_baked_length()
	_check(follow.progress >= 0.0 and follow.progress < path_length, "Looped progress remains in range")
	_check(not is_equal_approx(follow.progress, initial_progress), "Physics-step path movement advances")
	_check(observed_loop_wrap, "Closed PathFollow loops cleanly")
	_check(actor.global_position.is_finite(), "Actor transform remains finite")
	_check(actor.global_transform.basis.determinant() > 0.5, "Water-follow basis remains valid")
	_check(absf(actor.global_position.y - ocean.sample_height(actor.global_position)) < 2.0, "Actor follows Ocean3D height")
	_check(
		maximum_heading_step <= deg_to_rad(actor.maximum_yaw_rate_degrees) / 60.0 * 1.35,
		"Heading inertia respects the angular speed limit"
	)
	_check(observed_heading_lag, "Heading inertia produces controlled sliding through turns")
	var wake_runtime_status := wake.get_graphics_quality_debug_status() if wake != null else {}
	var live_head_updates := int(wake_runtime_status.get("live_head_update_count", 0))
	var mesh_rebuilds := int(wake_runtime_status.get("mesh_rebuild_count", 0))
	var default_player_wake := WakeTrail3D.new()
	_check(
		wake != null
			and wake.directional_persistent_foam_enabled
			and not default_player_wake.directional_persistent_foam_enabled,
		"Traffic foam is opt-in while the JetSki keeps its original foam channel"
	)
	default_player_wake.free()
	_check(live_head_updates == 0, "Detached traffic-boat foam ribbon stays disabled")
	_check(
		mesh_rebuilds == 0,
		"Traffic wake history does not rebuild a detached foam mesh"
	)
	var physics_velocity: Vector3 = PhysicsServer3D.body_get_state(
		actor.get_rid(),
		PhysicsServer3D.BODY_STATE_LINEAR_VELOCITY
	)
	_check(physics_velocity.is_finite() and physics_velocity.length() > 1.0, "AnimatableBody3D reports controlled motion to physics")
	var progress_before_reverse := follow.progress
	actor.reverse = true
	for _frame in 6:
		await get_tree().physics_frame
	var reverse_velocity: Vector3 = PhysicsServer3D.body_get_state(
		actor.get_rid(),
		PhysicsServer3D.BODY_STATE_LINEAR_VELOCITY
	)
	_check(follow.progress < progress_before_reverse, "Reverse mode decreases path progress")
	_check(reverse_velocity.is_finite(), "Reverse mode keeps a finite controlled velocity")
	actor.reverse = false

	var model_collision := (
		actor.get_node_or_null("ModelHullCollision") as CollisionShape3D
	)
	var imported_hull_shape := (
		model_collision.shape as ConcavePolygonShape3D
		if model_collision != null
		else null
	)
	var imported_hull_faces := (
		imported_hull_shape.get_faces()
		if imported_hull_shape != null
		else PackedVector3Array()
	)
	_check(
		imported_hull_shape != null and imported_hull_faces.size() >= 3,
		"Traffic collision uses the model's imported -colonly hull"
	)
	_check(
		actor.find_children("*", "StaticBody3D", true, false).is_empty(),
		"Imported nested StaticBody3D is folded into the moving actor"
	)
	var physics_shape_count := PhysicsServer3D.body_get_shape_count(actor.get_rid())
	_check(physics_shape_count == 1, "AnimatableBody3D registers one exact hull shape")
	var physics_body_transform: Transform3D = PhysicsServer3D.body_get_state(
		actor.get_rid(),
		PhysicsServer3D.BODY_STATE_TRANSFORM
	)
	var physics_shape_transform := PhysicsServer3D.body_get_shape_transform(actor.get_rid(), 0)
	var actor_was_hit := false
	if imported_hull_faces.size() >= 3:
		var local_a := imported_hull_faces[0]
		var local_b := imported_hull_faces[1]
		var local_c := imported_hull_faces[2]
		var local_normal := (local_b - local_a).cross(local_c - local_a).normalized()
		var local_center := (local_a + local_b + local_c) / 3.0
		var shape_world_transform := physics_body_transform * physics_shape_transform
		var world_center := shape_world_transform * local_center
		var world_normal := (shape_world_transform.basis * local_normal).normalized()
		var ray_query := PhysicsRayQueryParameters3D.create(
			world_center + world_normal * 1.0,
			world_center - world_normal * 1.0,
			actor.collision_layer
		)
		ray_query.collide_with_bodies = true
		ray_query.collide_with_areas = false
		ray_query.hit_back_faces = true
		var ray_hit := actor.get_world_3d().direct_space_state.intersect_ray(
			ray_query
		)
		actor_was_hit = ray_hit.get("collider") == actor
	_check(actor_was_hit, "JetSki collision layer can query the traffic body")

	_check(wake != null and wake.sample_count >= 2 and wake.sample_count <= 128, "Foam history accumulates a bounded trail")
	var wake_mesh := wake.get_node_or_null("WakeMesh") as MeshInstance3D if wake != null else null
	var wake_material := wake_mesh.material_override as ShaderMaterial if wake_mesh != null else null
	_check(
		wake_mesh != null
			and not wake_mesh.visible
			and wake.surface_count == 0
			and not wake.ribbon_render_enabled,
		"Traffic wake does not use an intersecting foam ribbon"
	)
	_check(
		wake.get_node_or_null("WakeWaterPatch") == null,
		"Traffic wake does not render low-resolution water-patch fins"
	)
	_check(
		wake.vertex_count == 0,
		"Ocean-integrated traffic foam requires no ribbon vertices"
	)
	var wake_shader_code := ""
	if wake_material != null and wake_material.shader != null:
		wake_shader_code = wake_material.shader.code
	_check(
		not wake_shader_code.contains("sample_vehicle_interaction_state"),
		"Ribbon shader does not evaluate the legacy global interaction loop"
	)
	var ocean_status := ocean.get_graphics_quality_debug_status()
	_check(
		int(ocean_status.get("active_ripples", 0)) == 0,
		"Traffic wake does not activate the legacy global ripple field"
	)
	_check(
		int(ocean_status.get("active_directional_segments", 0)) > 0
			and wake.legacy_global_deformation_enabled,
		"Traffic wake deforms the real Ocean3D directional field"
	)
	var ocean_material := ocean.get_active_water_material()
	var foam_history_durations: PackedFloat32Array = (
		ocean_material.get_shader_parameter(
			&"directional_wake_foam_history_durations"
		)
	)
	var persistent_foam_weights: PackedFloat32Array = (
		ocean_material.get_shader_parameter(
			&"directional_wake_persistent_foam_weights"
		)
	)
	_check(
		ocean_material != null
			and ocean_material.shader != null
			and ocean_material.shader.code.contains("vehicle_wake_foam_strength")
			and ocean_material.shader.code.contains("vehicle_foam_uv")
			and ocean_material.shader.code.contains(
				"interpolated_traffic_foam_energy"
			)
			and ocean_material.shader.code.contains(
				"interaction.w * interaction_scale"
			),
		"Ocean shader isolates persistent traffic foam from ordinary ripple foam"
	)
	_check(
		wake.wake_lifetime >= 19.5
			and wake.wake_sample_maximum_interval >= 0.24
			and wake.local_physics_lifetime <= 6.5
			and ocean.directional_wake_duration >= 19.5
			and ocean.directional_wake_deformation_duration <= 6.5
			and is_equal_approx(
				ocean.directional_wake_foam_fade_start
					/ ocean.directional_wake_duration,
				0.75
			)
			and ocean.directional_wake_foam_end_width_multiplier >= 2.0
			and ocean.directional_wake_foam_irregularity >= 0.4
			and foam_history_durations.size() == 16
			and foam_history_durations[0] >= wake.oldest_age - 0.2
			and persistent_foam_weights.size() == 16
			and persistent_foam_weights[0] > 0.99,
		"Foam keeps a short wave lifetime and an irregular fading final quarter"
	)
	var bounds_min: Vector2 = ocean_material.get_shader_parameter(
		&"directional_wake_bounds_min"
	)
	var bounds_max: Vector2 = ocean_material.get_shader_parameter(
		&"directional_wake_bounds_max"
	)
	_check(
		bounds_min.is_finite()
			and bounds_max.is_finite()
			and bounds_max.x > bounds_min.x
			and bounds_max.y > bounds_min.y,
		"Directional deformation publishes finite spatial shader bounds"
	)
	_check(
		int(ocean_status.get("local_wake_physics_sources", 0)) == 1,
		"Ocean3D registers one simplified local traffic-wake source"
	)
	var base_surface_samples := int(ocean_status.get("base_surface_sample_count", 0))
	_check(
		base_surface_samples <= mesh_rebuilds * wake.wake_maximum_points,
		"Ribbon mesh uses at most one base-ocean sample per rebuilt section"
	)
	var strongest_navigable_height := 0.0
	var strongest_navigable_position := Vector3.ZERO
	var wake_positions := wake.get_sample_positions()
	for segment_index in range(wake_positions.size() - 1):
		var start_xz := Vector2(
			wake_positions[segment_index].x,
			wake_positions[segment_index].z
		)
		var end_xz := Vector2(
			wake_positions[segment_index + 1].x,
			wake_positions[segment_index + 1].z
		)
		var segment := end_xz - start_xz
		if segment.length_squared() <= 0.0001:
			continue
		var midpoint := (start_xz + end_xz) * 0.5
		var direction := segment.normalized()
		var right := Vector2(-direction.y, direction.x)
		for lateral_step in range(-24, 25):
			var world_xz := midpoint + right * float(lateral_step) * 0.5
			var world_position := Vector3(world_xz.x, 0.0, world_xz.y)
			var wake_height := absf(ocean.sample_local_wake_height(world_position))
			if wake_height > strongest_navigable_height:
				strongest_navigable_height = wake_height
				strongest_navigable_position = world_position
	_check(
		strongest_navigable_height >= 0.04,
		"Simplified local wake exposes navigable center and arm displacement"
	)
	var navigable_sample := ocean.sample_water(strongest_navigable_position)
	_check(
		navigable_sample.valid and navigable_sample.normal.is_finite(),
		"Navigable wake participates in Ocean3D water samples"
	)
	var progress_before_suspension := follow.progress
	var history_before_suspension := wake.sample_count
	actor.call(&"_set_camera_effects_active", false)
	# This scene has no gameplay camera. Keep the manually forced off-screen
	# state from being replaced by the actor's periodic camera probe.
	actor.set(&"_camera_optimization_elapsed", -1.0)
	for _frame in 10:
		await get_tree().physics_frame
	var suspended_ocean_status := ocean.get_graphics_quality_debug_status()
	var suspended_deformation_weights: PackedFloat32Array = (
		ocean_material.get_shader_parameter(
			&"directional_wake_deformation_weights"
		)
	)
	var suspended_deformation_is_zero := true
	for segment_index in int(suspended_ocean_status.get("active_directional_segments", 0)):
		if suspended_deformation_weights[segment_index] > 0.0001:
			suspended_deformation_is_zero = false
			break
	_check(
			wake.directional_source_active
			and not wake.directional_deformation_active
			and wake.sample_count > history_before_suspension
			and wake_mesh != null
			and not wake_mesh.visible
			and not wake.is_local_wake_physics_active(),
		"Off-screen suspension keeps sparse world-space foam capture active"
	)
	_check(
		int(suspended_ocean_status.get("active_directional_segments", 0)) > 0
			and suspended_deformation_is_zero,
		"Off-screen traffic retains foam but no longer deforms Ocean3D"
	)
	_check(
		not is_equal_approx(follow.progress, progress_before_suspension),
		"Off-screen traffic continues following its route"
	)
	actor.call(&"_set_camera_effects_active", true)
	for _frame in 15:
		await get_tree().physics_frame
	_check(
		not wake_mesh.visible
			and wake.is_local_wake_physics_active()
			and wake.directional_source_active
			and wake.directional_deformation_active,
		"Returning on-screen restores ocean foam and local wake physics"
	)

	var actor_count := 0
	var gold_city_state := gold_city_scene.get_state()
	# Absence of an instance override means the actor script's enabled default.
	var gold_city_wake_deformation_enabled := true
	for node_index in gold_city_state.get_node_count():
		if gold_city_state.get_node_name(node_index) == &"BoatTrafficActor":
			actor_count += 1
			for property_index in gold_city_state.get_node_property_count(node_index):
				if (
					gold_city_state.get_node_property_name(
						node_index,
						property_index
					) == &"legacy_global_deformation_enabled"
				):
					gold_city_wake_deformation_enabled = bool(
						gold_city_state.get_node_property_value(
							node_index,
							property_index
						)
					)
	_check(actor_count == 1, "Gold City contains exactly one BoatTrafficActor prototype")
	_check(
		gold_city_wake_deformation_enabled,
		"Gold City keeps real traffic-boat ocean deformation enabled"
	)

	test_root.queue_free()
	await get_tree().process_frame
	_finish()


func _check(condition: bool, label: String) -> void:
	if condition:
		print("PASS: ", label)
		return
	_failures += 1
	push_error("FAIL: " + label)


func _finish() -> void:
	print("BOAT_TRAFFIC_VALIDATION failures=", _failures)
	get_tree().quit(0 if _failures == 0 else 1)
