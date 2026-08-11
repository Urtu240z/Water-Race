@tool
extends Node3D


# ============================================================
# PATHS
# ============================================================

const DEFAULT_OUTPUT_PATH: String = (
	"res://world/terrain/baked_tree_projected_shadows_decal.png"
)

const DEFAULT_SHADOW_MATERIAL: Material = preload(
	"res://world/vegetation/trees/materials/"
	+ "tree_impostor_shadow_beech_a.tres"
)

const TEMP_VIEWPORT_NAME: StringName = (
	&"__StaticTreeShadowBakeViewport"
)

const DECAL_NODE_NAME: StringName = (
	&"BakedTreeShadowDecal"
)


# ============================================================
# REFERENCES
# ============================================================

@export_group("References")

@export_node_path("MeshInstance3D")
var terrain_mesh_path: NodePath

@export_node_path("DirectionalLight3D")
var sun_light_path: NodePath


# ============================================================
# OUTPUT
# ============================================================

@export_group("Output")

@export_file("*.png")
var output_png_path: String = DEFAULT_OUTPUT_PATH

@export_range(512, 4096, 256)
var texture_resolution: int = 2048

@export_range(0.0, 100.0, 1.0)
var world_padding: float = 25.0


# ============================================================
# TREE MASK
# ============================================================

@export_group("Tree Mask")

@export var use_forced_alpha_cutoff: bool = true

@export_range(0.05, 0.95, 0.01)
var forced_alpha_cutoff: float = 0.70


# ============================================================
# DECAL
# ============================================================

@export_group("Decal")

@export var create_or_update_decal: bool = true

@export var disable_realtime_tree_shadows_after_bake: bool = true

@export_range(0.0, 1.0, 0.01)
var decal_albedo_mix: float = 0.80

@export_range(0.1, 4.0, 0.01)
var decal_alpha_multiplier: float = 1.35

@export_range(0.1, 4.0, 0.01)
var decal_alpha_power: float = 1.25

@export_range(1.0, 5000.0, 1.0)
var decal_depth_margin: float = 200.0

# 0 = usar layers del terreno.
@export var decal_cull_mask_override: int = 0


# ============================================================
# EDITOR
# ============================================================

@export_group("Editor")

@export_tool_button("BAKE TREE SHADOW DECAL")
var bake_button = bake_tree_shadow_decal


# ============================================================
# INTERNAL
# ============================================================

var _baking: bool = false


# ============================================================
# TERRAIN MASK SHADER
# ============================================================

const TERRAIN_MASK_SHADER_CODE: String = """
shader_type spatial;

render_mode
	unshaded,
	cull_disabled,
	fog_disabled;


void fragment() {

	ALBEDO = vec3(
		1.0,
		1.0,
		1.0
	);

	ROUGHNESS = 1.0;
}
"""


# ============================================================
# TREE MASK SHADER
# ============================================================

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
		0.0,
		0.0,
		0.0
	);
}
"""


# ============================================================
# BUTTON
# ============================================================

func bake_tree_shadow_decal() -> void:

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


# ============================================================
# MAIN
# ============================================================

func _run_bake() -> void:

	print("")
	print("==========================================")
	print("BAKE TREE SHADOW DECAL")
	print("==========================================")


	await _cleanup_previous_temp_viewport()


	var scene_root: Node = (
		_get_scene_root()
	)


	if scene_root == null:

		push_error(
			"BAKE: Scene root not found."
		)

		_baking = false

		return


	var terrain: MeshInstance3D = (
		_find_terrain(
			scene_root
		)
	)


	if terrain == null:

		push_error(
			"BAKE: Terrain_Master_VIS not found."
		)

		_baking = false

		return


	if terrain.mesh == null:

		push_error(
			"BAKE: Terrain_Master_VIS has no mesh."
		)

		_baking = false

		return


	var sun: DirectionalLight3D = (
		_find_sun(
			scene_root
		)
	)


	if sun == null:

		push_error(
			"BAKE: DirectionalLight3D not found."
		)

		_baking = false

		return


	# ========================================================
	# SOURCE TREE NODES
	# ========================================================

	var shadow_nodes: Array[MultiMeshInstance3D] = []

	_collect_tree_shadows(
		scene_root,
		shadow_nodes
	)


	if shadow_nodes.is_empty():

		push_error(
			"BAKE: No TreeShadows found."
		)

		_baking = false

		return


	print(
		"TreeShadows found: ",
		shadow_nodes.size()
	)


	# ========================================================
	# WORLD BOUNDS
	# ========================================================

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


	var bounds_center: Vector3 = (
		combined_bounds.position
		+ combined_bounds.size * 0.5
	)


	var bounds_radius: float = maxf(
		combined_bounds.size.length() * 0.5,
		100.0
	)


	# ========================================================
	# SUN SPACE
	# ========================================================

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

		_baking = false

		return


	# ========================================================
	# ISOLATED VIEWPORT
	# ========================================================

	var bake_viewport: SubViewport = (
		SubViewport.new()
	)

	bake_viewport.name = (
		TEMP_VIEWPORT_NAME
	)

	bake_viewport.size = Vector2i(
		texture_resolution,
		texture_resolution
	)

	bake_viewport.own_world_3d = true

	bake_viewport.transparent_bg = false

	bake_viewport.render_target_update_mode = (
		SubViewport.UPDATE_DISABLED
	)

	add_child(
		bake_viewport
	)


	# ========================================================
	# ENVIRONMENT
	# ========================================================

	var bake_environment: Environment = (
		Environment.new()
	)

	bake_environment.background_mode = (
		Environment.BG_COLOR
	)

	bake_environment.background_color = (
		Color.WHITE
	)

	bake_environment.background_energy_multiplier = 1.0

	bake_environment.ambient_light_source = (
		Environment.AMBIENT_SOURCE_DISABLED
	)

	bake_environment.reflected_light_source = (
		Environment.REFLECTION_SOURCE_DISABLED
	)

	bake_environment.tonemap_mode = (
		Environment.TONE_MAPPER_LINEAR
	)

	bake_environment.tonemap_exposure = 1.0

	bake_environment.fog_enabled = false

	bake_environment.volumetric_fog_enabled = false

	bake_environment.glow_enabled = false

	bake_environment.adjustment_enabled = false


	# ========================================================
	# CAMERA FROM THE SUN
	# ========================================================

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
		bake_environment
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


	var camera_right_ws: Vector3 = (
		bake_camera.transform
			.basis
			.x
			.normalized()
	)

	var camera_up_ws: Vector3 = (
		bake_camera.transform
			.basis
			.y
			.normalized()
	)

	var camera_plus_z_ws: Vector3 = (
		bake_camera.transform
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


	bake_camera.projection = (
		Camera3D.PROJECTION_ORTHOGONAL
	)

	bake_camera.size = (
		capture_size
	)

	bake_camera.near = 0.1

	bake_camera.far = (
		camera_distance
		+ bounds_radius
		+ 300.0
	)

	bake_camera.current = true


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


	# ========================================================
	# WHITE TERRAIN CLONE
	# ========================================================

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

	terrain_clone.transform = (
		terrain.global_transform
	)


	# ========================================================
	# BLACK TREE CLONES
	# ========================================================

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
				camera_plus_z_ws
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

		caster_clone.transform = (
			shadow_node.global_transform
		)


		caster_count += 1


	if caster_count == 0:

		bake_camera.current = false

		bake_viewport.queue_free()

		push_error(
			"BAKE: No valid tree mask casters."
		)

		_baking = false

		return


	print(
		"Tree mask casters: ",
		caster_count
	)


	# ========================================================
	# RENDER
	# ========================================================

	await get_tree().process_frame
	await RenderingServer.frame_post_draw


	var captured_image: Image = (
		await _capture_viewport(
			bake_viewport
		)
	)


	bake_camera.current = false
	bake_viewport.queue_free()


	if (
		captured_image == null
		or captured_image.is_empty()
	):

		push_error(
			"BAKE: Empty capture."
		)

		_baking = false

		return


	captured_image.convert(
		Image.FORMAT_L8
	)


	_print_mask_stats(
		captured_image
	)


	# ========================================================
	# BUILD RGBA DECAL TEXTURE
	# ========================================================

	var decal_image: Image = (
		_build_decal_image_from_mask(
			captured_image
		)
	)


	# ========================================================
	# SAVE PNG
	# ========================================================

	var resolved_output_path: String = (
		_resolve_output_path()
	)

	var absolute_path: String = (
		ProjectSettings.globalize_path(
			resolved_output_path
		)
	)


	var save_error: Error = (
		decal_image.save_png(
			absolute_path
		)
	)


	if save_error != OK:

		push_error(
			"BAKE: Failed saving PNG. Error "
			+ str(
				save_error
			)
		)

		_baking = false

		return


	print("")
	print("TREE SHADOW DECAL TEXTURE CREATED:")
	print(absolute_path)
	print("")


	# ========================================================
	# REFRESH IMPORT
	# ========================================================

	var filesystem: EditorFileSystem = (
		EditorInterface
			.get_resource_filesystem()
	)

	filesystem.scan()

	while (
		filesystem.is_scanning()
		or filesystem.is_importing()
	):

		await get_tree().process_frame


	# ========================================================
	# CREATE / UPDATE DECAL
	# ========================================================

	if create_or_update_decal:

		var texture_resource: Resource = (
			ResourceLoader.load(
				resolved_output_path
			)
		)


		if texture_resource is Texture2D:

			var decal_texture: Texture2D = (
				texture_resource
					as Texture2D
			)


			_create_or_update_shadow_decal(
				scene_root,
				terrain,
				decal_texture,
				bounds_center,
				camera_right_ws,
				camera_up_ws,
				to_sun_ws,
				capture_size,
				combined_bounds.size.length()
					+ decal_depth_margin
			)

		else:

			push_warning(
				"BAKE: Could not load imported decal texture."
			)


	# ========================================================
	# OPTIONAL: disable realtime tree shadows
	# ========================================================

	if disable_realtime_tree_shadows_after_bake:

		_disable_realtime_tree_shadows(
			scene_root
		)


	print("")
	print("==========================================")
	print("TREE SHADOW DECAL BAKE FINISHED")
	print("==========================================")
	print("")


	_baking = false


# ============================================================
# BUILD DECAL IMAGE
# ============================================================

func _build_decal_image_from_mask(
	mask_image: Image
) -> Image:

	var width: int = (
		mask_image.get_width()
	)

	var height: int = (
		mask_image.get_height()
	)


	var result: Image = Image.create(
		width,
		height,
		false,
		Image.FORMAT_RGBA8
	)


	for y: int in range(
		height
	):

		for x: int in range(
			width
		):

			var mask_color: Color = (
				mask_image.get_pixel(
					x,
					y
				)
			)


			var gray: float = (
				mask_color.r
			)


			var shadow_alpha: float = (
				1.0 - gray
			)


			shadow_alpha = clampf(
				shadow_alpha
					* decal_alpha_multiplier,
				0.0,
				1.0
			)


			shadow_alpha = pow(
				shadow_alpha,
				decal_alpha_power
			)


			result.set_pixel(
				x,
				y,
				Color(
					0.0,
					0.0,
					0.0,
					shadow_alpha
				)
			)


	return result


# ============================================================
# CREATE / UPDATE DECAL
# ============================================================

func _create_or_update_shadow_decal(
	scene_root: Node,
	terrain: MeshInstance3D,
	decal_texture: Texture2D,
	bounds_center: Vector3,
	mask_right_ws: Vector3,
	mask_up_ws: Vector3,
	to_sun_ws: Vector3,
	capture_size: float,
	decal_depth: float
) -> void:

	var decal_node: Decal = (
		_find_existing_decal(
			scene_root
		)
	)


	if decal_node == null:

		decal_node = Decal.new()
		decal_node.name = DECAL_NODE_NAME
		scene_root.add_child(
			decal_node
		)
		decal_node.owner = (
			scene_root
		)


	# --------------------------------------------------------
	# ORIENTATION
	#
	# Decal projects along local -Y.
	#
	# We want local -Y = light -> scene direction = -to_sun_ws
	# therefore local +Y = to_sun_ws
	#
	# Local X = mask right
	# Local Z = -mask up
	# to keep texture rows aligned with the baked image.
	# --------------------------------------------------------

	var x_axis: Vector3 = (
		mask_right_ws.normalized()
	)

	var y_axis: Vector3 = (
		to_sun_ws.normalized()
	)

	var z_axis: Vector3 = (
		-mask_up_ws.normalized()
	)

	var decal_basis: Basis = Basis(
		x_axis,
		y_axis,
		z_axis
	).orthonormalized()


	decal_node.transform = Transform3D(
		decal_basis,
		bounds_center
	)


	# --------------------------------------------------------
	# SIZE
	#
	# X / Z = baked texture coverage
	# Y     = projection depth
	# --------------------------------------------------------

	decal_node.size = Vector3(
		capture_size,
		decal_depth,
		capture_size
	)


	# --------------------------------------------------------
	# TEXTURE / BLEND
	# --------------------------------------------------------

	decal_node.texture_albedo = (
		decal_texture
	)

	decal_node.modulate = Color(
		1.0,
		1.0,
		1.0,
		1.0
	)

	decal_node.albedo_mix = (
		decal_albedo_mix
	)


	# --------------------------------------------------------
	# CLEANUP OF OTHER CHANNELS
	# --------------------------------------------------------

	decal_node.texture_emission = null
	decal_node.texture_normal = null
	decal_node.texture_orm = null

	decal_node.emission_energy = 0.0

	decal_node.upper_fade = 0.0
	decal_node.lower_fade = 0.0

	decal_node.distance_fade_enabled = false


	# --------------------------------------------------------
	# CULL MASK
	# --------------------------------------------------------

	if decal_cull_mask_override != 0:

		decal_node.cull_mask = (
			decal_cull_mask_override
		)

	else:

		decal_node.cull_mask = (
			terrain.layers
		)


	print(
		"Decal updated: ",
		decal_node.get_path()
	)
	print(
		"Decal size: ",
		decal_node.size
	)
	print(
		"Decal cull mask: ",
		decal_node.cull_mask
	)


# ============================================================
# FIND EXISTING DECAL
# ============================================================

func _find_existing_decal(
	node: Node
) -> Decal:

	if (
		node is Decal
		and node.name == DECAL_NODE_NAME
	):

		return (
			node
				as Decal
		)


	for child: Node in node.get_children():

		var result: Decal = (
			_find_existing_decal(
				child
			)
		)

		if result != null:
			return result


	return null


# ============================================================
# DISABLE REALTIME TREE SHADOWS
# ============================================================

func _disable_realtime_tree_shadows(
	node: Node
) -> void:

	if _has_property(
		node,
		&"tree_shadows_enabled"
	):

		node.set(
			"tree_shadows_enabled",
			false
		)


	for child: Node in node.get_children():

		_disable_realtime_tree_shadows(
			child
		)


# ============================================================
# CAPTURE
# ============================================================

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


# ============================================================
# CREATE TREE MATERIAL
# ============================================================

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


# ============================================================
# CANONICAL SHADOW MATERIAL
# ============================================================

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


# ============================================================
# MASK STATS
# ============================================================

func _print_mask_stats(
	image: Image
) -> void:

	if image == null:
		return

	if image.is_empty():
		return

	if image.get_format() != Image.FORMAT_L8:

		image.convert(
			Image.FORMAT_L8
		)


	var data: PackedByteArray = (
		image.get_data()
	)

	var pixel_count: int = (
		data.size()
	)

	if pixel_count <= 0:
		return


	var minimum_value: int = 255
	var maximum_value: int = 0
	var dark_pixel_count: int = 0
	var black_pixel_count: int = 0


	for byte_value: int in data:

		minimum_value = mini(
			minimum_value,
			byte_value
		)

		maximum_value = maxi(
			maximum_value,
			byte_value
		)

		if byte_value < 240:
			dark_pixel_count += 1

		if byte_value < 64:
			black_pixel_count += 1


	var dark_percent: float = (
		float(dark_pixel_count)
		/ float(pixel_count)
		* 100.0
	)

	var black_percent: float = (
		float(black_pixel_count)
		/ float(pixel_count)
		* 100.0
	)


	print("")
	print("MASK STATISTICS")
	print("--------------------------")
	print(
		"Minimum value: ",
		minimum_value
	)
	print(
		"Maximum value: ",
		maximum_value
	)
	print(
		"Dark pixels (<240): ",
		dark_pixel_count,
		" / ",
		pixel_count,
		" = ",
		dark_percent,
		" %"
	)
	print(
		"Black pixels (<64): ",
		black_pixel_count,
		" = ",
		black_percent,
		" %"
	)
	print("--------------------------")
	print("")


# ============================================================
# CLEAN OLD TEMP VIEWPORT
# ============================================================

func _cleanup_previous_temp_viewport() -> void:

	for child: Node in get_children():

		if child.name == TEMP_VIEWPORT_NAME:

			child.queue_free()


	await get_tree().process_frame


# ============================================================
# COLLECT TREES
# ============================================================

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


# ============================================================
# TERRAIN
# ============================================================

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


# ============================================================
# SUN
# ============================================================

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


# ============================================================
# WORLD AABB
# ============================================================

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
		maximum - minimum
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
		maximum - minimum
	)


# ============================================================
# PROPERTY HELPER
# ============================================================

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


# ============================================================
# OUTPUT PATH
# ============================================================

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
			and ResourceUID.has_id(uid)
		):

			var resolved_path: String = (
				ResourceUID.get_id_path(uid)
			)

			if not resolved_path.is_empty():
				return resolved_path


		return DEFAULT_OUTPUT_PATH


	return path


# ============================================================
# SCENE ROOT
# ============================================================

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
