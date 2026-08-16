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
	_check(live_head_updates >= 180, "Ribbon live head updates at physics-frame cadence")
	_check(
		mesh_rebuilds > 0 and mesh_rebuilds < live_head_updates,
		"Ribbon mesh rebuild cadence stays below the 60 Hz live head"
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

	var main_collision := actor.get_node_or_null("MainHullCollision") as CollisionShape3D
	var bow_collision := actor.get_node_or_null("BowCollision") as CollisionShape3D
	_check(main_collision != null and main_collision.shape is BoxShape3D, "Main collision is a simple box")
	_check(bow_collision != null and bow_collision.shape is BoxShape3D, "Bow collision is a simple box")
	_check(actor.find_children("*", "StaticBody3D", true, false).is_empty(), "Imported concave StaticBody3D is removed")
	var physics_shape_count := PhysicsServer3D.body_get_shape_count(actor.get_rid())
	_check(physics_shape_count == 2, "AnimatableBody3D registers both collision shapes")
	var point_query := PhysicsPointQueryParameters3D.new()
	var physics_body_transform: Transform3D = PhysicsServer3D.body_get_state(
		actor.get_rid(),
		PhysicsServer3D.BODY_STATE_TRANSFORM
	)
	var physics_shape_transform := PhysicsServer3D.body_get_shape_transform(actor.get_rid(), 0)
	point_query.position = (physics_body_transform * physics_shape_transform).origin
	point_query.collision_mask = actor.collision_layer
	point_query.collide_with_bodies = true
	point_query.collide_with_areas = false
	var point_hits := actor.get_world_3d().direct_space_state.intersect_point(point_query, 8)
	var actor_was_hit := false
	for hit in point_hits:
		if hit.get("collider") == actor:
			actor_was_hit = true
			break
	_check(actor_was_hit, "JetSki collision layer can query the traffic body")

	_check(wake != null and wake.sample_count >= 2 and wake.sample_count <= 40, "Visual wake accumulates a bounded trail")
	var wake_mesh := wake.get_node_or_null("WakeMesh") as MeshInstance3D if wake != null else null
	var wake_material := wake_mesh.material_override as ShaderMaterial if wake_mesh != null else null
	var opacity_boost := (
		float(wake_material.get_shader_parameter(&"opacity_boost"))
		if wake_material != null
		else 0.0
	)
	_check(opacity_boost >= 3.0, "Traffic wake uses a clearly visible foam material")
	var wake_vertex_count := 0
	if wake_mesh != null and wake_mesh.mesh != null and wake_mesh.mesh.get_surface_count() > 0:
		var wake_arrays := wake_mesh.mesh.surface_get_arrays(0)
		wake_vertex_count = (wake_arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
	_check(wake_vertex_count == wake.sample_count * 10, "Ribbon uses one ten-vertex tangent frame per section")
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
		int(ocean_status.get("active_directional_segments", 0)) == 0
			and not wake.legacy_global_deformation_enabled,
		"Traffic ribbon stays out of Ocean3D's global directional field"
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
	var suspended_ocean_status := ocean.get_graphics_quality_debug_status()
	_check(
		not wake.directional_source_active
			and wake.sample_count == history_before_suspension
			and wake_mesh != null
			and not wake_mesh.visible
			and not wake.is_local_wake_physics_active(),
		"Off-screen suspension preserves history while hiding visuals and physics"
	)
	_check(
		int(suspended_ocean_status.get("active_directional_segments", 0)) == 0,
		"Off-screen traffic no longer deforms Ocean3D"
	)
	await get_tree().physics_frame
	_check(
		not is_equal_approx(follow.progress, progress_before_suspension),
		"Off-screen traffic continues following its route"
	)
	actor.call(&"_set_camera_effects_active", true)
	for _frame in 15:
		await get_tree().physics_frame
	var resumed_wake_status := wake.get_graphics_quality_debug_status()
	_check(
		wake_mesh.visible
			and wake.is_local_wake_physics_active()
			and float(resumed_wake_status.get("visual_fade", 0.0)) >= 0.9,
		"Returning on-screen restores local physics and fades the preserved ribbon in"
	)

	var actor_count := 0
	for node_index in gold_city_scene.get_state().get_node_count():
		if gold_city_scene.get_state().get_node_name(node_index) == &"BoatTrafficActor":
			actor_count += 1
	_check(actor_count == 1, "Gold City contains exactly one BoatTrafficActor prototype")

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
