@tool
extends Node3D

const EDITOR_INTERFACE_BRIDGE_PATH: String = (
	"res://dev/editor/editor_interface_bridge.gd"
)


const DEFAULT_OUTPUT_PATH: String = (
	"res://world/terrain/baked_tree_projected_shadows.png"
)

const DEFAULT_SHADOW_MATERIAL: Material = preload(
	"res://world/vegetation/trees/materials/"
	+ "tree_impostor_shadow_material.tres"
)

const BAKED_OVERLAY_SHADER: Shader = preload(
	"res://world/vegetation/trees/shaders/"
	+ "tree_baked_shadow_unshaded_overlay.gdshader"
)

const TEMP_VIEWPORT_NAME: StringName = (
	&"__StaticTreeShadowBakeViewport"
)

const MAX_EXTRA_SPOT_LIGHTS: int = 32


@export_group("References")

@export_node_path("MeshInstance3D")
var terrain_mesh_path: NodePath

@export_node_path("DirectionalLight3D")
var sun_light_path: NodePath

@export var extra_shadow_sources: Array[Node] = []


@export_group("Output")

@export_file("*.png")
var output_png_path: String = DEFAULT_OUTPUT_PATH

@export_range(512, 4096, 256)
var texture_resolution: int = 2048

# Ahora este valor controla aproximadamente la resolución
# individual de los shadow maps de los SpotLight3D durante el bake.
@export_range(256, 1024, 256)
var extra_light_texture_resolution: int = 512

@export_range(0.0, 100.0, 1.0)
var world_padding: float = 25.0


@export_group("Tree Mask")

@export var use_forced_alpha_cutoff: bool = true

@export_range(0.05, 0.95, 0.01)
var forced_alpha_cutoff: float = 0.70


@export_group("Shadow Mix")

@export_range(0.1, 4.0, 0.01)
var shadow_alpha_multiplier: float = 1.35

@export_range(0.1, 4.0, 0.01)
var shadow_alpha_power: float = 1.25

@export_range(0.0, 1.0, 0.01)
var extra_light_shadow_strength: float = 0.55


@export_group("Overlay")

@export var create_or_update_overlay: bool = true


@export_group("Editor")

@export_tool_button("BAKE TREE SHADOW OVERLAY")
var bake_button: Callable = bake_tree_shadow_overlay


var _baking: bool = false


class SunBakeResult:

	var image: Image

	var mask_center: Vector3
	var mask_right: Vector3
	var mask_up: Vector3
	var to_sun_direction: Vector3

	var capture_size: float

	var camera_transform: Transform3D
	var camera_near: float
	var camera_far: float


const TERRAIN_MASK_SHADER_CODE: String = """
shader_type spatial;

render_mode
	unshaded,
	cull_disabled,
	fog_disabled;


void fragment() {

	ALBEDO = vec3(
		1.0
	);

	ROUGHNESS = 1.0;
}
"""


const TREE_MASK_SHADER_CODE: String = """
shader_type spatial;

render_mode
	skip_vertex_transform,
	unshaded,
	cull_disabled,
	fog_disabled;


uniform sampler2D tree_tex : source_color;


uniform float alpha_cutoff
	: hint_range(0.0, 1.0, 0.01) = 0.70;


uniform vec3 fixed_to_camera_ws = vec3(
	0.0,
	0.0,
	1.0
);


void vertex() {

	vec3 origin_ws = (
		MODEL_MATRIX
		* vec4(
			0.0,
			0.0,
			0.0,
			1.0
		)
	).xyz;


	float instance_scale_x = length(
		MODEL_MATRIX[0].xyz
	);


	float instance_scale_y = length(
		MODEL_MATRIX[1].xyz
	);


	vec3 to_camera_ws = (
		fixed_to_camera_ws
	);


	to_camera_ws.y = 0.0;


	float flat_length = length(
		to_camera_ws
	);


	if (flat_length < 0.0001) {

		to_camera_ws = vec3(
			0.0,
			0.0,
			1.0
		);

	} else {

		to_camera_ws /= flat_length;
	}


	vec3 world_up = vec3(
		0.0,
		1.0,
		0.0
	);


	vec3 right_ws = normalize(
		cross(
			world_up,
			to_camera_ws
		)
	);


	vec3 world_vertex_position = (

		origin_ws

		+ right_ws
			* VERTEX.x
			* instance_scale_x

		+ world_up
			* VERTEX.y
			* instance_scale_y
	);


	vec4 view_position = (
		VIEW_MATRIX
		* vec4(
			world_vertex_position,
			1.0
		)
	);


	VERTEX = (
		view_position.xyz
	);
}


void fragment() {

	vec4 tree_sample = texture(
		tree_tex,
		UV
	);


	if (
		tree_sample.a
		< alpha_cutoff
	) {
		discard;
	}


	ALBEDO = vec3(
		0.0
	);
}
"""


const SPOT_TREE_SHADOW_SHADER_CODE: String = """
shader_type spatial;

render_mode
	skip_vertex_transform,
	cull_disabled;


uniform sampler2D tree_tex : source_color;

uniform float alpha_cutoff
	: hint_range(0.0, 1.0, 0.01) = 0.70;


// Position of the current SpotLight3D in world space.
uniform vec3 light_position_ws = vec3(
	0.0,
	0.0,
	0.0
);


void vertex() {

	vec3 origin_ws = (
		MODEL_MATRIX
		* vec4(
			0.0,
			0.0,
			0.0,
			1.0
		)
	).xyz;


	float instance_scale_x = length(
		MODEL_MATRIX[0].xyz
	);


	float instance_scale_y = length(
		MODEL_MATRIX[1].xyz
	);


	// Each tree faces the actual positional light.
	// Keep the billboard vertical: rotate only around world Y.
	vec3 to_light_ws = (
		light_position_ws
		- origin_ws
	);

	to_light_ws.y = 0.0;


	float horizontal_length = length(
		to_light_ws
	);


	if (horizontal_length < 0.0001) {

		to_light_ws = vec3(
			0.0,
			0.0,
			1.0
		);

	} else {

		to_light_ws /= horizontal_length;
	}


	vec3 world_up = vec3(
		0.0,
		1.0,
		0.0
	);


	vec3 right_ws = normalize(
		cross(
			world_up,
			to_light_ws
		)
	);


	vec3 world_vertex_position = (

		origin_ws

		+ right_ws
			* VERTEX.x
			* instance_scale_x

		+ world_up
			* VERTEX.y
			* instance_scale_y
	);


	vec4 view_position = (
		VIEW_MATRIX
		* vec4(
			world_vertex_position,
			1.0
		)
	);


	VERTEX = view_position.xyz;
}


void fragment() {

	vec4 tree_sample = texture(
		tree_tex,
		UV
	);


	if (
		tree_sample.a
		< alpha_cutoff
	) {
		discard;
	}
}
"""


func bake_tree_shadow_overlay() -> void:

	if _baking:
		return


	if not Engine.is_editor_hint():

		push_error(
			"Tree shadow bake is editor-only."
		)

		return


	_baking = true

	call_deferred(
		"_run_bake"
	)


func _run_bake() -> void:

	print("")
	print("==========================================")
	print("BAKE TREE SHADOW OVERLAY")
	print("==========================================")
	print("")


	await _cleanup_previous_temp_viewports()


	var scene_root: Node = (
		_get_scene_root()
	)


	if scene_root == null:

		_abort_bake(
			"BAKE: Scene root not found."
		)

		return


	var terrain: MeshInstance3D = (
		_find_terrain(
			scene_root
		)
	)


	if terrain == null:

		_abort_bake(
			"BAKE: Terrain MeshInstance3D not found."
		)

		return


	if terrain.mesh == null:

		_abort_bake(
			"BAKE: Terrain has no mesh."
		)

		return


	var sun: DirectionalLight3D = (
		_find_sun(
			scene_root
		)
	)


	if sun == null:

		_abort_bake(
			"BAKE: DirectionalLight3D not found."
		)

		return


	var shadow_nodes: Array[MultiMeshInstance3D] = []


	_collect_tree_shadows(
		scene_root,
		shadow_nodes
	)


	if shadow_nodes.is_empty():

		_abort_bake(
			"BAKE: No TreeShadows found."
		)

		return


	print(
		"TreeShadows found: ",
		shadow_nodes.size()
	)


	var combined_bounds: AABB = (
		_get_world_aabb(
			terrain
		)
	)


	for shadow_node: MultiMeshInstance3D in shadow_nodes:

		if shadow_node.multimesh == null:
			continue


		var tree_bounds: AABB = (
			_get_world_aabb(
				shadow_node
			)
		)


		combined_bounds = (
			_merge_aabbs(
				combined_bounds,
				tree_bounds
			)
		)


	var sun_bake: SunBakeResult = (
		await _bake_sun_mask(
			terrain,
			shadow_nodes,
			sun,
			combined_bounds
		)
	)


	if sun_bake == null:

		_abort_bake(
			"BAKE: Directional shadow mask failed."
		)

		return


	var spot_lights: Array[SpotLight3D] = (
		_collect_extra_spot_lights()
	)


	print(
		"Extra SpotLight3D found: ",
		spot_lights.size()
	)


	var spot_shadow_mask: Image = null


	if not spot_lights.is_empty():

		spot_shadow_mask = (
			await _bake_native_spot_shadow_mask(
				terrain,
				shadow_nodes,
				spot_lights,
				sun_bake
			)
		)


		if spot_shadow_mask == null:

			_abort_bake(
				"BAKE: Native SpotLight shadow bake failed."
			)

			return


	var final_image: Image = (
		_build_final_shadow_image(
			sun_bake.image,
			spot_shadow_mask
		)
	)


	if (
		final_image == null
		or final_image.is_empty()
	):

		_abort_bake(
			"BAKE: Final shadow image is empty."
		)

		return


	var resolved_output_path: String = (
		_resolve_output_path()
	)


	if not resolved_output_path.begins_with(
		"res://"
	):

		_abort_bake(
			"BAKE: Output path must be inside res://"
		)

		return


	var absolute_path: String = (
		ProjectSettings.globalize_path(
			resolved_output_path
		)
	)


	var save_error: Error = (
		final_image.save_png(
			absolute_path
		)
	)


	if save_error != OK:

		_abort_bake(
			"BAKE: Failed saving PNG. Error "
			+ str(
				save_error
			)
		)

		return


	print("")
	print("TREE SHADOW OVERLAY TEXTURE CREATED:")
	print(absolute_path)
	print("")


	var baked_texture: Texture2D = (
		await _refresh_and_load_texture(
			resolved_output_path
		)
	)


	if baked_texture == null:

		_abort_bake(
			"BAKE: PNG was saved, but Godot could not "
			+ "load the imported Texture2D."
		)

		return


	if create_or_update_overlay:

		var overlay_ok: bool = (
			_create_or_update_overlay(
				terrain,
				baked_texture,
				sun_bake
			)
		)


		if not overlay_ok:

			_abort_bake(
				"BAKE: Could not assign terrain material_overlay."
			)

			return


	var editor_bridge := _create_editor_interface_bridge()


	if editor_bridge != null:

		editor_bridge.call(&"mark_scene_as_unsaved")


	print("")
	print("==========================================")
	print("TREE SHADOW OVERLAY BAKE FINISHED")
	print("==========================================")
	print("")


	_baking = false


func _bake_sun_mask(
	terrain: MeshInstance3D,
	shadow_nodes: Array[MultiMeshInstance3D],
	sun: DirectionalLight3D,
	combined_bounds: AABB
) -> SunBakeResult:

	var bounds_center: Vector3 = (
		combined_bounds.position
		+ combined_bounds.size
			* 0.5
	)


	var bounds_radius: float = maxf(
		combined_bounds.size.length()
			* 0.5,
		100.0
	)


	var to_sun_ws: Vector3 = (
		sun.global_transform
			.basis
			.z
			.normalized()
	)


	if (
		to_sun_ws.length_squared()
		< 0.0001
	):

		push_error(
			"BAKE: Invalid sun direction."
		)

		return null


	var bake_viewport: SubViewport = (
		_create_bake_viewport(
			texture_resolution
		)
	)


	var bake_camera: Camera3D = (
		Camera3D.new()
	)


	bake_camera.name = (
		"__StaticTreeShadowSunCamera"
	)


	bake_viewport.add_child(
		bake_camera
	)


	bake_camera.environment = (
		_create_white_bake_environment()
	)


	var camera_distance: float = (
		bounds_radius
		+ 150.0
	)


	bake_camera.position = (
		bounds_center
		+ to_sun_ws
			* camera_distance
	)


	var up_hint: Vector3 = (
		Vector3.UP
	)


	if (
		absf(
			to_sun_ws.dot(
				Vector3.UP
			)
		)
		> 0.97
	):

		up_hint = (
			Vector3.FORWARD
		)


	bake_camera.look_at(
		bounds_center,
		up_hint
	)


	var camera_transform: Transform3D = (
		bake_camera.get_camera_transform()
	)


	var camera_right_ws: Vector3 = (
		camera_transform
			.basis
			.x
			.normalized()
	)


	var camera_up_ws: Vector3 = (
		camera_transform
			.basis
			.y
			.normalized()
	)


	var camera_plus_z_ws: Vector3 = (
		camera_transform
			.basis
			.z
			.normalized()
	)


	var maximum_projected_extent: float = 0.0


	for corner_index: int in range(
		8
	):

		var corner: Vector3 = (
			_get_aabb_corner(
				combined_bounds,
				corner_index
			)
		)


		var relative_corner: Vector3 = (
			corner
			- bounds_center
		)


		var projected_x: float = absf(
			relative_corner.dot(
				camera_right_ws
			)
		)


		var projected_y: float = absf(
			relative_corner.dot(
				camera_up_ws
			)
		)


		maximum_projected_extent = maxf(
			maximum_projected_extent,
			projected_x
		)


		maximum_projected_extent = maxf(
			maximum_projected_extent,
			projected_y
		)


	var capture_size: float = (
		maximum_projected_extent
			* 2.0
		+ world_padding
			* 2.0
	)


	capture_size = maxf(
		capture_size,
		10.0
	)


	var camera_near: float = 0.1


	var camera_far: float = (
		camera_distance
		+ bounds_radius
		+ 300.0
	)


	bake_camera.projection = (
		Camera3D.PROJECTION_ORTHOGONAL
	)


	bake_camera.size = (
		capture_size
	)


	bake_camera.near = (
		camera_near
	)


	bake_camera.far = (
		camera_far
	)


	bake_camera.current = true


	var caster_count: int = (
		_add_sun_mask_geometry(
			bake_viewport,
			terrain,
			shadow_nodes,
			camera_plus_z_ws
		)
	)


	if caster_count == 0:

		bake_camera.current = false

		bake_viewport.queue_free()

		await get_tree().process_frame

		return null


	print(
		"Resolution: ",
		texture_resolution,
		"x",
		texture_resolution
	)


	print(
		"Capture size: ",
		capture_size,
		" m"
	)


	print(
		"Mask center: ",
		bounds_center
	)


	print(
		"Mask right: ",
		camera_right_ws
	)


	print(
		"Mask up: ",
		camera_up_ws
	)


	print(
		"Mask +Z / to sun: ",
		camera_plus_z_ws
	)


	var captured_image: Image = (
		await _capture_viewport(
			bake_viewport
		)
	)


	bake_camera.current = false

	bake_viewport.queue_free()

	await get_tree().process_frame


	if (
		captured_image == null
		or captured_image.is_empty()
	):

		return null


	captured_image.convert(
		Image.FORMAT_L8
	)


	var result: SunBakeResult = (
		SunBakeResult.new()
	)


	result.image = (
		captured_image
	)


	result.mask_center = (
		bounds_center
	)


	result.mask_right = (
		camera_right_ws
	)


	result.mask_up = (
		camera_up_ws
	)


	result.to_sun_direction = (
		to_sun_ws
	)


	result.capture_size = (
		capture_size
	)


	result.camera_transform = (
		camera_transform
	)


	result.camera_near = (
		camera_near
	)


	result.camera_far = (
		camera_far
	)


	return result


func _bake_native_spot_shadow_mask(
	terrain: MeshInstance3D,
	shadow_nodes: Array[MultiMeshInstance3D],
	spot_lights: Array[SpotLight3D],
	sun_bake: SunBakeResult
) -> Image:

	print("")
	print("NATIVE SPOTLIGHT SHADOW PASS")
	print("----------------------------")
	print("Mode: one native shadow pass per SpotLight3D")


	var combined_mask: Image = (
		Image.create_empty(
			texture_resolution,
			texture_resolution,
			false,
			Image.FORMAT_L8
		)
	)


	combined_mask.fill(
		Color.BLACK
	)


	var successful_light_count: int = 0


	for light_index: int in range(
		spot_lights.size()
	):

		var source_light: SpotLight3D = (
			spot_lights[light_index]
		)


		print(
			"Baking native SpotLight3D ",
			light_index + 1,
			" / ",
			spot_lights.size(),
			": ",
			source_light.get_path()
		)


		var bake_viewport: SubViewport = (
			_create_bake_viewport(
				texture_resolution
			)
		)


		_configure_spot_shadow_atlas(
			bake_viewport
		)


		var bake_camera: Camera3D = (
			Camera3D.new()
		)


		bake_camera.name = (
			"__NativeSpotShadowBakeCamera"
		)


		bake_viewport.add_child(
			bake_camera
		)


		bake_camera.environment = (
			_create_black_bake_environment()
		)


		bake_camera.global_transform = (
			sun_bake.camera_transform
		)


		bake_camera.projection = (
			Camera3D.PROJECTION_ORTHOGONAL
		)


		bake_camera.size = (
			sun_bake.capture_size
		)


		bake_camera.near = (
			sun_bake.camera_near
		)


		bake_camera.far = (
			sun_bake.camera_far
		)


		bake_camera.cull_mask = 1

		bake_camera.current = true


		var terrain_material: StandardMaterial3D = (
			_create_spot_receiver_material()
		)


		var terrain_clone: MeshInstance3D = (
			MeshInstance3D.new()
		)


		terrain_clone.name = (
			"__NativeSpotShadowTerrain"
		)


		terrain_clone.mesh = (
			terrain.mesh
		)


		terrain_clone.material_override = (
			terrain_material
		)


		terrain_clone.layers = 1


		terrain_clone.cast_shadow = (
			GeometryInstance3D
				.SHADOW_CASTING_SETTING_OFF
		)


		terrain_clone.gi_mode = (
			GeometryInstance3D
				.GI_MODE_DISABLED
		)


		bake_viewport.add_child(
			terrain_clone
		)


		terrain_clone.global_transform = (
			terrain.global_transform
		)


		var cloned_light: SpotLight3D = (
			_clone_spot_light_for_bake(
				source_light
			)
		)


		bake_viewport.add_child(
			cloned_light
		)


		cloned_light.global_transform = (
			Transform3D(
				source_light
					.global_transform
					.basis
					.orthonormalized(),
				source_light.global_position
			)
		)


		# Warm the light and its positional shadow atlas.
		await _capture_viewport(
			bake_viewport
		)


		var without_tree_shadows: Image = (
			await _capture_viewport(
				bake_viewport
			)
		)


		if (
			without_tree_shadows == null
			or without_tree_shadows.is_empty()
		):

			bake_camera.current = false

			bake_viewport.queue_free()

			await get_tree().process_frame

			push_warning(
				"BAKE: Empty unshadowed capture for "
				+ String(
					source_light.get_path()
				)
			)

			continue


		var native_caster_count: int = (
			_add_native_spot_shadow_casters(
				bake_viewport,
				shadow_nodes,
				source_light
			)
		)


		if native_caster_count <= 0:

			bake_camera.current = false

			bake_viewport.queue_free()

			await get_tree().process_frame

			push_warning(
				"BAKE: No tree casters for "
				+ String(
					source_light.get_path()
				)
			)

			continue


		# Give Godot several draws to rebuild the shadow map
		# after adding the positional tree casters.
		await _capture_viewport(
			bake_viewport
		)

		await _capture_viewport(
			bake_viewport
		)


		var with_tree_shadows: Image = (
			await _capture_viewport(
				bake_viewport
			)
		)


		bake_camera.current = false

		bake_viewport.queue_free()

		await get_tree().process_frame


		if (
			with_tree_shadows == null
			or with_tree_shadows.is_empty()
		):

			push_warning(
				"BAKE: Empty shadowed capture for "
				+ String(
					source_light.get_path()
				)
			)

			continue


		var light_mask: Image = (
			_extract_native_spot_shadow_mask(
				without_tree_shadows,
				with_tree_shadows
			)
		)


		if (
			light_mask == null
			or light_mask.is_empty()
		):
			continue


		_merge_native_spot_shadow_mask(
			combined_mask,
			light_mask
		)


		successful_light_count += 1


	print("")
	print(
		"Native SpotLight passes completed: ",
		successful_light_count,
		" / ",
		spot_lights.size()
	)
	print("")


	return combined_mask


func _configure_spot_shadow_atlas(
	bake_viewport: SubViewport
) -> void:

	var requested_shadow_resolution: int = maxi(
		extra_light_texture_resolution,
		256
	)


	var atlas_size: int = (
		requested_shadow_resolution
		* 8
	)


	atlas_size = maxi(
		atlas_size,
		2048
	)


	atlas_size = mini(
		atlas_size,
		8192
	)


	bake_viewport.positional_shadow_atlas_size = (
		atlas_size
	)


	bake_viewport.positional_shadow_atlas_16_bits = (
		false
	)


	bake_viewport.positional_shadow_atlas_quad_0 = (
		Viewport
			.SHADOW_ATLAS_QUADRANT_SUBDIV_16
	)


	bake_viewport.positional_shadow_atlas_quad_1 = (
		Viewport
			.SHADOW_ATLAS_QUADRANT_SUBDIV_16
	)


	bake_viewport.positional_shadow_atlas_quad_2 = (
		Viewport
			.SHADOW_ATLAS_QUADRANT_SUBDIV_16
	)


	bake_viewport.positional_shadow_atlas_quad_3 = (
		Viewport
			.SHADOW_ATLAS_QUADRANT_SUBDIV_16
	)


	print(
		"Positional shadow atlas: ",
		atlas_size,
		"x",
		atlas_size
	)


func _clone_spot_light_for_bake(
	source: SpotLight3D
) -> SpotLight3D:

	var result: SpotLight3D = (
		SpotLight3D.new()
	)


	result.name = (
		"__BakedSpot_"
		+ String(
			source.name
		)
	)


	# White normalized light.
	#
	# We are measuring occlusion, not reproducing the
	# scene's exposure or lamp color.
	result.light_color = (
		Color.WHITE
	)


	result.light_energy = (
		1.0
	)


	result.light_specular = (
		0.0
	)


	result.light_volumetric_fog_energy = (
		0.0
	)


	result.light_size = (
		source.light_size
	)


	result.spot_range = (
		source.spot_range
	)


	result.spot_angle = (
		source.spot_angle
	)


	result.spot_attenuation = (
		source.spot_attenuation
	)


	result.spot_angle_attenuation = (
		source.spot_angle_attenuation
	)


	result.shadow_enabled = (
		true
	)


	result.shadow_bias = (
		source.shadow_bias
	)


	result.shadow_normal_bias = (
		source.shadow_normal_bias
	)


	result.shadow_blur = (
		source.shadow_blur
	)


	result.shadow_opacity = (
		source.shadow_opacity
	)


	result.shadow_reverse_cull_face = (
		source.shadow_reverse_cull_face
	)


	result.light_cull_mask = (
		1
	)


	result.shadow_caster_mask = (
		1
	)


	result.distance_fade_enabled = (
		false
	)


	return result


func _create_spot_receiver_material() -> StandardMaterial3D:

	var result: StandardMaterial3D = (
		StandardMaterial3D.new()
	)


	result.albedo_color = (
		Color.WHITE
	)


	result.metallic = (
		0.0
	)


	result.roughness = (
		1.0
	)


	return result


func _add_native_spot_shadow_casters(
	bake_viewport: SubViewport,
	shadow_nodes: Array[MultiMeshInstance3D],
	source_light: SpotLight3D
) -> int:

	var caster_count: int = 0


	var spot_shadow_shader: Shader = (
		Shader.new()
	)


	spot_shadow_shader.code = (
		SPOT_TREE_SHADOW_SHADER_CODE
	)


	for shadow_node: MultiMeshInstance3D in shadow_nodes:

		if shadow_node.multimesh == null:
			continue


		var source_material: Material = (
			_get_canonical_shadow_material(
				shadow_node
			)
		)


		if source_material == null:
			continue


		var caster_material: ShaderMaterial = (
			_create_spot_tree_shadow_material(
				source_material,
				spot_shadow_shader,
				source_light.global_position
			)
		)


		if caster_material == null:

			push_warning(
				"BAKE: Could not create positional "
				+ "tree caster material."
			)

			continue


		var caster_clone: MultiMeshInstance3D = (
			MultiMeshInstance3D.new()
		)


		caster_clone.name = (
			"__NativeTreeShadowCaster_"
			+ str(
				caster_count
			)
		)


		caster_clone.multimesh = (
			shadow_node.multimesh
		)


		caster_clone.material_override = (
			caster_material
		)


		caster_clone.layers = (
			1
		)


		caster_clone.gi_mode = (
			GeometryInstance3D
				.GI_MODE_DISABLED
		)


		caster_clone.cast_shadow = (
			GeometryInstance3D
				.SHADOW_CASTING_SETTING_SHADOWS_ONLY
		)


		caster_clone.extra_cull_margin = (
			1000.0
		)


		bake_viewport.add_child(
			caster_clone
		)


		caster_clone.global_transform = (
			shadow_node.global_transform
		)


		caster_count += 1


	return caster_count


func _create_spot_tree_shadow_material(
	source_material: Material,
	spot_shadow_shader: Shader,
	light_position_ws: Vector3
) -> ShaderMaterial:

	var tree_texture: Texture2D = null

	var source_alpha_cutoff: float = (
		forced_alpha_cutoff
	)


	if source_material is ShaderMaterial:

		var source_shader_material: ShaderMaterial = (
			source_material
				as ShaderMaterial
		)


		var texture_value: Variant = (
			source_shader_material
				.get_shader_parameter(
					"tree_tex"
				)
		)


		if texture_value is Texture2D:

			tree_texture = (
				texture_value
					as Texture2D
			)


		if not use_forced_alpha_cutoff:

			var cutoff_value: Variant = (
				source_shader_material
					.get_shader_parameter(
						"alpha_cutoff"
					)
			)


			if (
				cutoff_value is float
				or cutoff_value is int
			):

				source_alpha_cutoff = float(
					cutoff_value
				)


	elif source_material is BaseMaterial3D:

		var base_material: BaseMaterial3D = (
			source_material
				as BaseMaterial3D
		)


		tree_texture = (
			base_material.albedo_texture
		)


		if not use_forced_alpha_cutoff:

			source_alpha_cutoff = (
				base_material.alpha_scissor_threshold
			)


	if tree_texture == null:
		return null


	var result: ShaderMaterial = (
		ShaderMaterial.new()
	)


	result.shader = (
		spot_shadow_shader
	)


	result.set_shader_parameter(
		"tree_tex",
		tree_texture
	)


	result.set_shader_parameter(
		"alpha_cutoff",
		source_alpha_cutoff
	)


	result.set_shader_parameter(
		"light_position_ws",
		light_position_ws
	)


	return result


func _extract_native_spot_shadow_mask(
	without_shadows: Image,
	with_shadows: Image
) -> Image:

	if (
		without_shadows == null
		or with_shadows == null
	):

		return null


	if (
		without_shadows.is_empty()
		or with_shadows.is_empty()
	):

		return null


	var width: int = mini(
		without_shadows.get_width(),
		with_shadows.get_width()
	)


	var height: int = mini(
		without_shadows.get_height(),
		with_shadows.get_height()
	)


	var result: Image = (
		Image.create_empty(
			width,
			height,
			false,
			Image.FORMAT_L8
		)
	)


	result.fill(
		Color.BLACK
	)


	var affected_pixels: int = 0

	var maximum_shadow: float = 0.0


	for y: int in range(
		height
	):

		for x: int in range(
			width
		):

			var unshadowed_color: Color = (
				without_shadows.get_pixel(
					x,
					y
				)
			)


			var shadowed_color: Color = (
				with_shadows.get_pixel(
					x,
					y
				)
			)


			var open_level: float = maxf(
				unshadowed_color.r,
				maxf(
					unshadowed_color.g,
					unshadowed_color.b
				)
			)


			var blocked_level: float = maxf(
				shadowed_color.r,
				maxf(
					shadowed_color.g,
					shadowed_color.b
				)
			)


			var shadow_alpha: float = 0.0


			if open_level > 0.002:

				var difference: float = maxf(
					open_level
						- blocked_level,
					0.0
				)


				shadow_alpha = (
					difference
					/ maxf(
						open_level,
						0.002
					)
				)


				# Ignore almost-unlit numerical noise.
				var light_gate: float = clampf(
					(
						open_level
						- 0.002
					)
					/ 0.03,
					0.0,
					1.0
				)


				light_gate = (
					light_gate
					* light_gate
					* (
						3.0
						- 2.0
							* light_gate
					)
				)


				shadow_alpha *= (
					light_gate
				)


				shadow_alpha *= (
					extra_light_shadow_strength
				)


				shadow_alpha = clampf(
					shadow_alpha,
					0.0,
					1.0
				)


			maximum_shadow = maxf(
				maximum_shadow,
				shadow_alpha
			)


			if shadow_alpha > 0.02:
				affected_pixels += 1


			result.set_pixel(
				x,
				y,
				Color(
					shadow_alpha,
					shadow_alpha,
					shadow_alpha,
					1.0
				)
			)


	print(
		"Native Spot shadow pixels: ",
		affected_pixels
	)


	print(
		"Native Spot maximum shadow: ",
		maximum_shadow
	)


	return result


func _merge_native_spot_shadow_mask(
	destination: Image,
	source: Image
) -> void:

	if (
		destination == null
		or source == null
	):
		return


	if (
		destination.is_empty()
		or source.is_empty()
	):
		return


	if (
		source.get_format()
		!= Image.FORMAT_L8
	):

		source.convert(
			Image.FORMAT_L8
		)


	var width: int = mini(
		destination.get_width(),
		source.get_width()
	)


	var height: int = mini(
		destination.get_height(),
		source.get_height()
	)


	for y: int in range(
		height
	):

		for x: int in range(
			width
		):

			var existing_shadow: float = (
				destination.get_pixel(
					x,
					y
				).r
			)


			var new_shadow: float = (
				source.get_pixel(
					x,
					y
				).r
			)


			var combined_shadow: float = (
				1.0
				- (
					1.0
						- existing_shadow
				)
				* (
					1.0
						- new_shadow
				)
			)


			combined_shadow = clampf(
				combined_shadow,
				0.0,
				1.0
			)


			destination.set_pixel(
				x,
				y,
				Color(
					combined_shadow,
					combined_shadow,
					combined_shadow,
					1.0
				)
			)


func _build_final_shadow_image(
	sun_mask: Image,
	spot_mask: Image
) -> Image:

	if (
		sun_mask == null
		or sun_mask.is_empty()
	):

		return null


	if (
		sun_mask.get_format()
		!= Image.FORMAT_L8
	):

		sun_mask.convert(
			Image.FORMAT_L8
		)


	if (
		spot_mask != null
		and not spot_mask.is_empty()
		and spot_mask.get_format()
			!= Image.FORMAT_L8
	):

		spot_mask.convert(
			Image.FORMAT_L8
		)


	var width: int = (
		sun_mask.get_width()
	)


	var height: int = (
		sun_mask.get_height()
	)


	var result: Image = (
		Image.create_empty(
			width,
			height,
			false,
			Image.FORMAT_RGBA8
		)
	)


	var has_spot_mask: bool = (
		spot_mask != null
		and not spot_mask.is_empty()
		and spot_mask.get_width()
			== width
		and spot_mask.get_height()
			== height
	)


	for y: int in range(
		height
	):

		for x: int in range(
			width
		):

			var sun_gray: float = (
				sun_mask.get_pixel(
					x,
					y
				).r
			)


			var sun_alpha: float = (
				1.0
				- sun_gray
			)


			sun_alpha = clampf(
				sun_alpha
					* shadow_alpha_multiplier,
				0.0,
				1.0
			)


			sun_alpha = pow(
				sun_alpha,
				shadow_alpha_power
			)


			var spot_alpha: float = 0.0


			if has_spot_mask:

				spot_alpha = clampf(
					spot_mask.get_pixel(
						x,
						y
					).r,
					0.0,
					1.0
				)


			var combined_alpha: float = (
				1.0
				- (
					1.0
						- sun_alpha
				)
				* (
					1.0
						- spot_alpha
				)
			)


			result.set_pixel(
				x,
				y,
				Color(
					0.0,
					0.0,
					0.0,
					clampf(
						combined_alpha,
						0.0,
						1.0
					)
				)
			)


	return result


func _add_sun_mask_geometry(
	bake_viewport: SubViewport,
	terrain: MeshInstance3D,
	shadow_nodes: Array[MultiMeshInstance3D],
	fixed_to_camera_ws: Vector3
) -> int:

	var terrain_shader: Shader = (
		Shader.new()
	)


	terrain_shader.code = (
		TERRAIN_MASK_SHADER_CODE
	)


	var terrain_material: ShaderMaterial = (
		ShaderMaterial.new()
	)


	terrain_material.shader = (
		terrain_shader
	)


	var terrain_clone: MeshInstance3D = (
		MeshInstance3D.new()
	)


	terrain_clone.name = (
		"__ShadowReceiverTerrain"
	)


	terrain_clone.mesh = (
		terrain.mesh
	)


	terrain_clone.material_override = (
		terrain_material
	)


	terrain_clone.cast_shadow = (
		GeometryInstance3D
			.SHADOW_CASTING_SETTING_OFF
	)


	terrain_clone.gi_mode = (
		GeometryInstance3D
			.GI_MODE_DISABLED
	)


	bake_viewport.add_child(
		terrain_clone
	)


	terrain_clone.global_transform = (
		terrain.global_transform
	)


	var tree_shader: Shader = (
		Shader.new()
	)


	tree_shader.code = (
		TREE_MASK_SHADER_CODE
	)


	var caster_count: int = 0


	for shadow_node: MultiMeshInstance3D in shadow_nodes:

		if shadow_node.multimesh == null:
			continue


		var source_material: Material = (
			_get_canonical_shadow_material(
				shadow_node
			)
		)


		if source_material == null:

			push_warning(
				"BAKE: Missing source material on "
				+ String(
					shadow_node.get_path()
				)
			)

			continue


		var caster_material: ShaderMaterial = (
			_create_tree_mask_material(
				source_material,
				tree_shader,
				fixed_to_camera_ws
			)
		)


		if caster_material == null:

			push_warning(
				"BAKE: Could not create caster for "
				+ String(
					shadow_node.get_path()
				)
			)

			continue


		var caster_clone: MultiMeshInstance3D = (
			MultiMeshInstance3D.new()
		)


		caster_clone.name = (
			"__TreeMaskCaster_"
			+ str(
				caster_count
			)
		)


		caster_clone.multimesh = (
			shadow_node.multimesh
		)


		caster_clone.material_override = (
			caster_material
		)


		caster_clone.cast_shadow = (
			GeometryInstance3D
				.SHADOW_CASTING_SETTING_OFF
		)


		bake_viewport.add_child(
			caster_clone
		)


		caster_clone.global_transform = (
			shadow_node.global_transform
		)


		caster_count += 1


	return caster_count


func _create_tree_mask_material(
	source_material: Material,
	mask_shader: Shader,
	fixed_to_camera_ws: Vector3
) -> ShaderMaterial:

	var tree_texture: Texture2D = null

	var source_alpha_cutoff: float = 0.80


	if source_material is ShaderMaterial:

		var shader_material: ShaderMaterial = (
			source_material
				as ShaderMaterial
		)


		var texture_value: Variant = (
			shader_material
				.get_shader_parameter(
					"tree_tex"
				)
		)


		if texture_value is Texture2D:

			tree_texture = (
				texture_value
					as Texture2D
			)


		var cutoff_value: Variant = (
			shader_material
				.get_shader_parameter(
					"alpha_cutoff"
				)
		)


		if (
			cutoff_value is float
			or cutoff_value is int
		):

			source_alpha_cutoff = float(
				cutoff_value
			)


	elif source_material is BaseMaterial3D:

		var base_material: BaseMaterial3D = (
			source_material
				as BaseMaterial3D
		)


		tree_texture = (
			base_material.albedo_texture
		)


		source_alpha_cutoff = (
			base_material.alpha_scissor_threshold
		)


	if tree_texture == null:
		return null


	var final_alpha_cutoff: float = (
		source_alpha_cutoff
	)


	if use_forced_alpha_cutoff:

		final_alpha_cutoff = (
			forced_alpha_cutoff
		)


	var result: ShaderMaterial = (
		ShaderMaterial.new()
	)


	result.shader = (
		mask_shader
	)


	result.set_shader_parameter(
		"tree_tex",
		tree_texture
	)


	result.set_shader_parameter(
		"alpha_cutoff",
		final_alpha_cutoff
	)


	result.set_shader_parameter(
		"fixed_to_camera_ws",
		fixed_to_camera_ws
	)


	return result


func _get_canonical_shadow_material(
	shadow_node: MultiMeshInstance3D
) -> Material:

	var forest_root: Node = (
		shadow_node.get_parent()
	)


	if forest_root != null:

		if _has_property(
			forest_root,
			&"shadow_material_override"
		):

			var controller_value: Variant = (
				forest_root.get(
					"shadow_material_override"
				)
			)


			if controller_value is Material:

				return (
					controller_value
						as Material
				)


	if shadow_node.material_override != null:

		return (
			shadow_node.material_override
		)


	return (
		DEFAULT_SHADOW_MATERIAL
	)


func _create_bake_viewport(
	resolution: int
) -> SubViewport:

	var bake_viewport: SubViewport = (
		SubViewport.new()
	)


	bake_viewport.name = (
		TEMP_VIEWPORT_NAME
	)


	bake_viewport.size = Vector2i(
		resolution,
		resolution
	)


	bake_viewport.own_world_3d = (
		true
	)


	bake_viewport.transparent_bg = (
		false
	)


	bake_viewport.render_target_update_mode = (
		SubViewport.UPDATE_DISABLED
	)


	add_child(
		bake_viewport
	)


	return bake_viewport


func _create_white_bake_environment() -> Environment:

	var environment: Environment = (
		Environment.new()
	)


	environment.background_mode = (
		Environment.BG_COLOR
	)


	environment.background_color = (
		Color.WHITE
	)


	environment.background_energy_multiplier = (
		1.0
	)


	environment.ambient_light_source = (
		Environment.AMBIENT_SOURCE_DISABLED
	)


	environment.reflected_light_source = (
		Environment.REFLECTION_SOURCE_DISABLED
	)


	environment.tonemap_mode = (
		Environment.TONE_MAPPER_LINEAR
	)


	environment.tonemap_exposure = (
		1.0
	)


	environment.fog_enabled = (
		false
	)


	environment.volumetric_fog_enabled = (
		false
	)


	environment.glow_enabled = (
		false
	)


	environment.adjustment_enabled = (
		false
	)


	return environment


func _create_black_bake_environment() -> Environment:

	var environment: Environment = (
		Environment.new()
	)


	environment.background_mode = (
		Environment.BG_COLOR
	)


	environment.background_color = (
		Color.BLACK
	)


	environment.background_energy_multiplier = (
		0.0
	)


	environment.ambient_light_source = (
		Environment.AMBIENT_SOURCE_DISABLED
	)


	environment.reflected_light_source = (
		Environment.REFLECTION_SOURCE_DISABLED
	)


	environment.tonemap_mode = (
		Environment.TONE_MAPPER_LINEAR
	)


	environment.tonemap_exposure = (
		1.0
	)


	environment.fog_enabled = (
		false
	)


	environment.volumetric_fog_enabled = (
		false
	)


	environment.glow_enabled = (
		false
	)


	environment.adjustment_enabled = (
		false
	)


	return environment


func _capture_viewport(
	bake_viewport: SubViewport
) -> Image:

	bake_viewport.render_target_update_mode = (
		SubViewport.UPDATE_ONCE
	)


	await get_tree().process_frame

	await RenderingServer.frame_post_draw


	return (
		bake_viewport
			.get_texture()
			.get_image()
	)


func _collect_extra_spot_lights() -> Array[SpotLight3D]:

	var results: Array[SpotLight3D] = []

	var seen: Dictionary = {}


	for source: Node in extra_shadow_sources:

		if source == null:
			continue


		_collect_spot_lights_recursive(
			source,
			results,
			seen
		)


	if (
		results.size()
		> MAX_EXTRA_SPOT_LIGHTS
	):

		push_warning(
			"BAKE: More than "
			+ str(
				MAX_EXTRA_SPOT_LIGHTS
			)
			+ " extra SpotLight3D found. "
			+ "Only the first "
			+ str(
				MAX_EXTRA_SPOT_LIGHTS
			)
			+ " will be baked."
		)


		results.resize(
			MAX_EXTRA_SPOT_LIGHTS
		)


	return results


func _collect_spot_lights_recursive(
	node: Node,
	results: Array[SpotLight3D],
	seen: Dictionary
) -> void:

	if node is SpotLight3D:

		var spot: SpotLight3D = (
			node
				as SpotLight3D
		)


		var instance_id: int = (
			spot.get_instance_id()
		)


		if not seen.has(
			instance_id
		):

			seen[
				instance_id
			] = true


			if (
				spot.visible
				and spot.light_energy > 0.0
				and spot.spot_range > 0.01
			):

				results.append(
					spot
				)


	for child: Node in node.get_children():

		_collect_spot_lights_recursive(
			child,
			results,
			seen
		)


func _collect_tree_shadows(
	node: Node,
	results: Array[MultiMeshInstance3D]
) -> void:

	if (
		node is MultiMeshInstance3D
		and node.name == "TreeShadows"
	):

		results.append(
			node
				as MultiMeshInstance3D
		)


	for child: Node in node.get_children():

		_collect_tree_shadows(
			child,
			results
		)


func _find_terrain(
	scene_root: Node
) -> MeshInstance3D:

	if terrain_mesh_path != NodePath(""):

		var explicit_node: Node = (
			get_node_or_null(
				terrain_mesh_path
			)
		)


		if explicit_node is MeshInstance3D:

			return (
				explicit_node
					as MeshInstance3D
			)


	return (
		_find_mesh_by_name(
			scene_root,
			&"Terrain_Master_VIS"
		)
	)


func _find_mesh_by_name(
	node: Node,
	target_name: StringName
) -> MeshInstance3D:

	if (
		node is MeshInstance3D
		and node.name == target_name
	):

		return (
			node
				as MeshInstance3D
		)


	for child: Node in node.get_children():

		var result: MeshInstance3D = (
			_find_mesh_by_name(
				child,
				target_name
			)
		)


		if result != null:
			return result


	return null


func _find_sun(
	scene_root: Node
) -> DirectionalLight3D:

	if sun_light_path != NodePath(""):

		var explicit_node: Node = (
			get_node_or_null(
				sun_light_path
			)
		)


		if explicit_node is DirectionalLight3D:

			return (
				explicit_node
					as DirectionalLight3D
			)


	return (
		_find_first_directional_light(
			scene_root
		)
	)


func _find_first_directional_light(
	node: Node
) -> DirectionalLight3D:

	if (
		node is DirectionalLight3D
		and node.visible
	):

		return (
			node
				as DirectionalLight3D
		)


	for child: Node in node.get_children():

		var result: DirectionalLight3D = (
			_find_first_directional_light(
				child
			)
		)


		if result != null:
			return result


	return null


func _get_world_aabb(
	mesh_instance: VisualInstance3D
) -> AABB:

	var local_aabb: AABB = (
		mesh_instance.get_aabb()
	)


	var minimum: Vector3 = Vector3(
		INF,
		INF,
		INF
	)


	var maximum: Vector3 = Vector3(
		-INF,
		-INF,
		-INF
	)


	for corner_index: int in range(
		8
	):

		var local_corner: Vector3 = (
			_get_aabb_corner(
				local_aabb,
				corner_index
			)
		)


		var world_corner: Vector3 = (
			mesh_instance.global_transform
			* local_corner
		)


		minimum.x = minf(
			minimum.x,
			world_corner.x
		)


		minimum.y = minf(
			minimum.y,
			world_corner.y
		)


		minimum.z = minf(
			minimum.z,
			world_corner.z
		)


		maximum.x = maxf(
			maximum.x,
			world_corner.x
		)


		maximum.y = maxf(
			maximum.y,
			world_corner.y
		)


		maximum.z = maxf(
			maximum.z,
			world_corner.z
		)


	return AABB(
		minimum,
		maximum
			- minimum
	)


func _get_aabb_corner(
	bounds: AABB,
	corner_index: int
) -> Vector3:

	return Vector3(

		bounds.position.x
			+ (
				bounds.size.x
				if (
					corner_index & 1
				) != 0
				else 0.0
			),

		bounds.position.y
			+ (
				bounds.size.y
				if (
					corner_index & 2
				) != 0
				else 0.0
			),

		bounds.position.z
			+ (
				bounds.size.z
				if (
					corner_index & 4
				) != 0
				else 0.0
			)
	)


func _merge_aabbs(
	first: AABB,
	second: AABB
) -> AABB:

	var first_maximum: Vector3 = (
		first.position
		+ first.size
	)


	var second_maximum: Vector3 = (
		second.position
		+ second.size
	)


	var minimum: Vector3 = Vector3(
		minf(
			first.position.x,
			second.position.x
		),
		minf(
			first.position.y,
			second.position.y
		),
		minf(
			first.position.z,
			second.position.z
		)
	)


	var maximum: Vector3 = Vector3(
		maxf(
			first_maximum.x,
			second_maximum.x
		),
		maxf(
			first_maximum.y,
			second_maximum.y
		),
		maxf(
			first_maximum.z,
			second_maximum.z
		)
	)


	return AABB(
		minimum,
		maximum
			- minimum
	)


func _create_or_update_overlay(
	terrain: MeshInstance3D,
	baked_texture: Texture2D,
	sun_bake: SunBakeResult
) -> bool:

	if terrain == null:
		return false


	if baked_texture == null:
		return false


	var overlay_material: ShaderMaterial = null


	if terrain.material_overlay is ShaderMaterial:

		var existing_material: ShaderMaterial = (
			terrain.material_overlay
				as ShaderMaterial
		)


		if (
			existing_material.shader
			== BAKED_OVERLAY_SHADER
		):

			overlay_material = (
				existing_material
			)

		else:

			push_error(
				"BAKE: Terrain already has a different "
				+ "material_overlay. It was NOT replaced."
			)

			return false


	elif terrain.material_overlay != null:

		push_error(
			"BAKE: Terrain already has a non-ShaderMaterial "
			+ "overlay. It was NOT replaced."
		)

		return false


	if overlay_material == null:

		overlay_material = (
			ShaderMaterial.new()
		)


		overlay_material.shader = (
			BAKED_OVERLAY_SHADER
		)


		overlay_material.resource_local_to_scene = (
			true
		)


	overlay_material.set_shader_parameter(
		"shadow_texture",
		baked_texture
	)


	overlay_material.set_shader_parameter(
		"mask_center",
		sun_bake.mask_center
	)


	overlay_material.set_shader_parameter(
		"mask_right",
		sun_bake.mask_right
	)


	overlay_material.set_shader_parameter(
		"mask_up",
		sun_bake.mask_up
	)


	overlay_material.set_shader_parameter(
		"capture_size",
		sun_bake.capture_size
	)


	overlay_material.set_shader_parameter(
		"to_sun_direction",
		sun_bake.to_sun_direction
	)


	terrain.material_overlay = (
		overlay_material
	)


	print(
		"Material overlay updated: ",
		terrain.get_path()
	)


	return true


func _refresh_and_load_texture(
	resource_path: String
) -> Texture2D:

	var editor_bridge := _create_editor_interface_bridge()


	if editor_bridge == null:

		return null


	var filesystem: Object = (
		editor_bridge.call(&"get_resource_filesystem") as Object
	)


	if filesystem == null:

		return null


	while (
		filesystem.is_scanning()
		or filesystem.is_importing()
	):

		await get_tree().process_frame


	filesystem.update_file(
		resource_path
	)


	filesystem.reimport_files(
		PackedStringArray(
			[
				resource_path
			]
		)
	)


	var texture_resource: Resource = (
		ResourceLoader.load(
			resource_path,
			"Texture2D",
			ResourceLoader.CACHE_MODE_REPLACE
		)
	)


	if texture_resource is Texture2D:

		return (
			texture_resource
				as Texture2D
		)


	return null


func _create_editor_interface_bridge() -> RefCounted:

	if not Engine.is_editor_hint():

		return null


	var bridge_script := (
		load(EDITOR_INTERFACE_BRIDGE_PATH) as Script
	)


	if bridge_script == null:

		return null


	return bridge_script.new() as RefCounted


func _cleanup_previous_temp_viewports() -> void:

	for child: Node in get_children():

		if String(
			child.name
		).begins_with(
			String(
				TEMP_VIEWPORT_NAME
			)
		):

			child.queue_free()


	await get_tree().process_frame


func _has_property(
	object: Object,
	property_name: StringName
) -> bool:

	var property_list: Array[Dictionary] = (
		object.get_property_list()
	)


	for property_info: Dictionary in property_list:

		var raw_name: Variant = (
			property_info.get(
				"name",
				""
			)
		)


		var current_name: StringName = (
			StringName(
				String(
					raw_name
				)
			)
		)


		if current_name == property_name:
			return true


	return false


func _resolve_output_path() -> String:

	var path: String = (
		output_png_path.strip_edges()
	)


	if path.is_empty():
		return DEFAULT_OUTPUT_PATH


	if path.begins_with(
		"uid://"
	):

		var uid: int = (
			ResourceUID.text_to_id(
				path
			)
		)


		if (
			uid != ResourceUID.INVALID_ID
			and ResourceUID.has_id(
				uid
			)
		):

			var resolved_path: String = (
				ResourceUID.get_id_path(
					uid
				)
			)


			if not resolved_path.is_empty():
				return resolved_path


		return DEFAULT_OUTPUT_PATH


	return path


func _get_scene_root() -> Node:

	if get_tree() == null:
		return null


	if (
		get_tree().edited_scene_root
		!= null
	):

		return (
			get_tree()
				.edited_scene_root
		)


	return (
		get_tree()
			.current_scene
	)


func _abort_bake(
	message: String
) -> void:

	push_error(
		message
	)

	_baking = false
