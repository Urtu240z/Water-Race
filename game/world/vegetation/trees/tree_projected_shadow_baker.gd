@tool
extends Node3D


# ============================================================
# PATHS
# ============================================================

const DEFAULT_OUTPUT_PATH: String = (
	"res://world/terrain/baked_tree_projected_shadows.png"
)


# ============================================================
# TEMPORARY RENDER LAYERS
#
# Layer 19 = receiver terrain.
# Layer 20 = tree shadow casters.
#
# Both are restored after the bake.
# ============================================================

const BAKE_RECEIVER_LAYER_MASK: int = (
	1 << 18
)

const BAKE_CASTER_LAYER_MASK: int = (
	1 << 19
)

const MASK_32: int = 0xFFFFFFFF


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

@export_range(1, 8, 1)
var tiles_per_axis: int = 4

@export_range(0.0, 100.0, 1.0)
var world_padding: float = 20.0


# ============================================================
# EDITOR
# ============================================================

@export_group("Editor")

@export_tool_button("BAKE PURE TREE SHADOW MASK")
var bake_button = bake_tree_shadows


# ============================================================
# INTERNAL
# ============================================================

var _baking: bool = false


# ============================================================
# TEMP TREE CASTER SHADER
#
# Rebuilds every tree quad as a fixed Y-billboard facing
# the sun, independent of the top-down bake camera.
# ============================================================

const FIXED_SHADOW_SHADER_CODE: String = """
shader_type spatial;

render_mode skip_vertex_transform, cull_disabled;

uniform sampler2D tree_tex : source_color;

uniform float alpha_cutoff
	: hint_range(0.0, 1.0, 0.01) = 0.80;

uniform vec3 fixed_to_light_ws = vec3(
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


	vec3 to_light_ws = fixed_to_light_ws;

	to_light_ws.y = 0.0;


	float flat_length = length(
		to_light_ws
	);


	if (flat_length < 0.0001) {

		to_light_ws = vec3(
			0.0,
			0.0,
			1.0
		);

	} else {

		to_light_ws /= flat_length;
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

	vec4 tex = texture(
		tree_tex,
		UV
	);


	if (tex.a < alpha_cutoff) {
		discard;
	}
}
"""


# ============================================================
# PURE SHADOW RECEIVER
#
# IMPORTANT:
#
# We do NOT render the real terrain color.
# We do NOT divide two captures.
#
# The directional light's ATTENUATION is rendered directly:
#
# 1.0 = receives full sun
# 0.0 = fully shadowed
#
# This gives us the multiplier map directly.
# ============================================================

const SHADOW_RECEIVER_SHADER_CODE: String = """
shader_type spatial;

render_mode
	ambient_light_disabled,
	specular_disabled,
	cull_disabled,
	fog_disabled;


void fragment() {

	ALBEDO = vec3(1.0);

	METALLIC = 0.0;

	ROUGHNESS = 1.0;

	SPECULAR = 0.0;

	AO = 1.0;
}


void light() {

	if (LIGHT_IS_DIRECTIONAL) {

		DIFFUSE_LIGHT += vec3(
			ATTENUATION
		);
	}
}
"""


# ============================================================
# BUTTON
# ============================================================

func bake_tree_shadows() -> void:

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
	print("PURE TREE SHADOW MASK BAKE")
	print("==========================================")


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
	# TREE SHADOW SOURCES
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
	# TERRAIN WORLD BOUNDS
	# ========================================================

	var terrain_bounds: AABB = (
		_get_world_aabb(
			terrain
		)
	)


	var terrain_center: Vector3 = (
		terrain_bounds.position
		+ terrain_bounds.size * 0.5
	)


	var capture_world_size: float = maxf(
		terrain_bounds.size.x,
		terrain_bounds.size.z
	)


	capture_world_size += (
		world_padding * 2.0
	)


	var world_min: Vector2 = Vector2(
		terrain_center.x
			- capture_world_size * 0.5,

		terrain_center.z
			- capture_world_size * 0.5
	)


	var world_size: Vector2 = Vector2(
		capture_world_size,
		capture_world_size
	)


	# ========================================================
	# TILES
	# ========================================================

	var tile_count: int = maxi(
		tiles_per_axis,
		1
	)


	var tile_resolution: int = int(
		ceil(
			float(texture_resolution)
			/ float(tile_count)
		)
	)


	var final_resolution: int = (
		tile_resolution
		* tile_count
	)


	var tile_world_size: float = (
		capture_world_size
		/ float(tile_count)
	)


	print(
		"Final texture: ",
		final_resolution,
		"x",
		final_resolution
	)

	print(
		"Tiles: ",
		tile_count,
		"x",
		tile_count
	)

	print(
		"World size: ",
		capture_world_size,
		" m"
	)

	print(
		"Tile world size: ",
		tile_world_size,
		" m"
	)


	# ========================================================
	# BUILD TEMP CASTER MATERIALS BEFORE CHANGING SCENE
	# ========================================================

	var fixed_shadow_shader: Shader = (
		Shader.new()
	)

	fixed_shadow_shader.code = (
		FIXED_SHADOW_SHADER_CODE
	)


	var fixed_to_light_ws: Vector3 = (
		sun.global_transform
			.basis
			.z
			.normalized()
	)


	var shadow_states: Array[Dictionary] = []


	for shadow_node: MultiMeshInstance3D in shadow_nodes:

		var source_material: Material = (
			_get_canonical_shadow_material(
				shadow_node
			)
		)


		if source_material == null:

			push_error(
				"BAKE: Missing shadow material on "
				+ String(shadow_node.get_path())
			)

			_baking = false

			return


		var bake_material: ShaderMaterial = (
			_create_bake_tree_material(
				source_material,
				fixed_shadow_shader,
				fixed_to_light_ws
			)
		)


		if bake_material == null:

			push_error(
				"BAKE: Could not create caster material for "
				+ String(shadow_node.get_path())
			)

			_baking = false

			return


		shadow_states.append({
			"node": shadow_node,
			"visible": shadow_node.visible,
			"layers": shadow_node.layers,
			"cast_shadow": shadow_node.cast_shadow,

			# Canonical controller material, not necessarily the
			# currently corrupted material left by an old bake.
			"restore_material": source_material,

			"bake_material": bake_material
		})


	# ========================================================
	# RECEIVER MATERIAL
	# ========================================================

	var receiver_shader: Shader = (
		Shader.new()
	)

	receiver_shader.code = (
		SHADOW_RECEIVER_SHADER_CODE
	)


	var receiver_material: ShaderMaterial = (
		ShaderMaterial.new()
	)

	receiver_material.shader = (
		receiver_shader
	)


	# ========================================================
	# SAVE TERRAIN STATE
	# ========================================================

	var old_terrain_material: Material = (
		terrain.material_override
	)

	var old_terrain_layers: int = (
		terrain.layers
	)

	var old_terrain_gi_mode: GeometryInstance3D.GIMode = (
		terrain.gi_mode
	)


	# ========================================================
	# SAVE SUN STATE
	# ========================================================

	var old_sun_visible: bool = (
		sun.visible
	)

	var old_shadow_enabled: bool = (
		sun.shadow_enabled
	)

	var old_shadow_opacity: float = (
		sun.shadow_opacity
	)

	var old_sun_light_cull_mask: int = (
		sun.light_cull_mask
	)

	var old_sun_shadow_caster_mask: int = (
		sun.shadow_caster_mask
	)

	var old_sun_bake_mode: Light3D.BakeMode = (
		sun.light_bake_mode
	)

	var old_shadow_max_distance: float = (
		sun.directional_shadow_max_distance
	)

	var old_shadow_fade_start: float = (
		sun.directional_shadow_fade_start
	)


	# ========================================================
	# OTHER LIGHTS
	#
	# Remove our temporary receiver layer from every other
	# light so only the selected sun can affect the mask.
	# ========================================================

	var other_lights: Array[Light3D] = []

	_collect_lights(
		scene_root,
		other_lights
	)


	var other_light_states: Array[Dictionary] = []


	for other_light: Light3D in other_lights:

		if other_light == sun:
			continue


		other_light_states.append({
			"node": other_light,
			"light_cull_mask": other_light.light_cull_mask
		})


		other_light.light_cull_mask = (
			other_light.light_cull_mask
			& (
				MASK_32
				^ BAKE_RECEIVER_LAYER_MASK
			)
		)


	# ========================================================
	# DECALS
	#
	# Disable all decals during the mask capture so no decal
	# can modify the white receiver surface.
	# ========================================================

	var decals: Array[Decal] = []

	_collect_decals(
		scene_root,
		decals
	)


	var decal_states: Array[Dictionary] = []


	for decal: Decal in decals:

		decal_states.append({
			"node": decal,
			"visible": decal.visible
		})

		decal.visible = false


	# ========================================================
	# APPLY TEMP TERRAIN RECEIVER
	# ========================================================

	terrain.material_override = (
		receiver_material
	)

	terrain.layers = (
		BAKE_RECEIVER_LAYER_MASK
	)

	terrain.gi_mode = (
		GeometryInstance3D.GI_MODE_DISABLED
	)


	# ========================================================
	# APPLY TEMP TREE CASTERS
	# ========================================================

	for state: Dictionary in shadow_states:

		var shadow_node_value: Variant = (
			state.get(
				"node"
			)
		)


		if not shadow_node_value is MultiMeshInstance3D:
			continue


		var shadow_node: MultiMeshInstance3D = (
			shadow_node_value
				as MultiMeshInstance3D
		)


		var bake_material_value: Variant = (
			state.get(
				"bake_material"
			)
		)


		if bake_material_value is ShaderMaterial:

			shadow_node.material_override = (
				bake_material_value
					as ShaderMaterial
			)


		shadow_node.layers = (
			BAKE_CASTER_LAYER_MASK
		)

		shadow_node.visible = true

		shadow_node.cast_shadow = (
			GeometryInstance3D
				.SHADOW_CASTING_SETTING_SHADOWS_ONLY
		)


	# ========================================================
	# CONFIGURE SUN FOR ISOLATED CAPTURE
	# ========================================================

	sun.visible = true

	sun.shadow_enabled = true

	sun.shadow_opacity = 1.0

	# The sun illuminates ONLY the temporary terrain receiver.
	sun.light_cull_mask = (
		old_sun_light_cull_mask
		| BAKE_RECEIVER_LAYER_MASK
		| BAKE_CASTER_LAYER_MASK
	)

	# ONLY our temporary TreeShadows can enter the shadow map.
	sun.shadow_caster_mask = (
		BAKE_CASTER_LAYER_MASK
	)

	# Force realtime lighting for this editor capture.
	sun.light_bake_mode = (
		Light3D.BAKE_DISABLED
	)

	sun.directional_shadow_fade_start = 1.0


	# ========================================================
	# BAKE VIEWPORT
	# ========================================================

	var bake_viewport: SubViewport = (
		SubViewport.new()
	)

	bake_viewport.name = (
		"__PureTreeShadowBakeViewport"
	)

	bake_viewport.size = Vector2i(
		tile_resolution,
		tile_resolution
	)

	bake_viewport.transparent_bg = false

	bake_viewport.render_target_update_mode = (
		SubViewport.UPDATE_DISABLED
	)

	bake_viewport.world_3d = (
		get_world_3d()
	)

	add_child(
		bake_viewport
	)


	# ========================================================
	# CLEAN BAKE ENVIRONMENT
	#
	# White background means:
	# outside the terrain = multiplier 1.0.
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
	# CAMERA
	# ========================================================

	var bake_camera: Camera3D = (
		Camera3D.new()
	)

	bake_camera.name = (
		"__PureTreeShadowBakeCamera"
	)

	bake_viewport.add_child(
		bake_camera
	)


	bake_camera.environment = (
		bake_environment
	)

	bake_camera.projection = (
		Camera3D.PROJECTION_ORTHOGONAL
	)

	bake_camera.size = (
		tile_world_size
	)

	bake_camera.near = 0.1


	var camera_height: float = maxf(
		terrain_bounds.size.y
			+ 80.0,

		120.0
	)


	bake_camera.far = (
		camera_height
		+ terrain_bounds.size.y
		+ 300.0
	)

	bake_camera.rotation_degrees = Vector3(
		-90.0,
		0.0,
		0.0
	)

	# Camera sees ONLY the terrain receiver.
	bake_camera.cull_mask = (
		BAKE_RECEIVER_LAYER_MASK
	)

	bake_camera.current = true


	# Make sure directional shadow coverage is large enough
	# for every tile.
	sun.directional_shadow_max_distance = maxf(
		old_shadow_max_distance,

		maxf(
			tile_world_size * 3.0,
			camera_height * 3.0
		)
	)


	# ========================================================
	# FINAL OUTPUT
	# ========================================================

	var final_image: Image = (
		Image.create(
			final_resolution,
			final_resolution,
			false,
			Image.FORMAT_L8
		)
	)

	final_image.fill(
		Color.WHITE
	)


	# Let RenderingServer receive all temporary state.
	await get_tree().process_frame

	await RenderingServer.frame_post_draw


	# ========================================================
	# CAPTURE
	# ========================================================

	var bake_failed: bool = false


	for tile_z: int in range(
		tile_count
	):

		if bake_failed:
			break


		for tile_x: int in range(
			tile_count
		):

			var tile_min_x: float = (
				world_min.x
				+ float(tile_x)
					* tile_world_size
			)


			var tile_min_z: float = (
				world_min.y
				+ float(tile_z)
					* tile_world_size
			)


			var tile_center_x: float = (
				tile_min_x
				+ tile_world_size * 0.5
			)


			var tile_center_z: float = (
				tile_min_z
				+ tile_world_size * 0.5
			)


			bake_camera.position = Vector3(
				tile_center_x,

				terrain_bounds.position.y
					+ terrain_bounds.size.y
					+ camera_height,

				tile_center_z
			)


			print(
				"Baking tile ",
				tile_x + 1,
				",",
				tile_z + 1,
				" / ",
				tile_count,
				"x",
				tile_count
			)


			var captured_image: Image = (
				await _capture_viewport(
					bake_viewport
				)
			)


			if (
				captured_image == null
				or captured_image.is_empty()
			):

				push_error(
					"BAKE: Empty capture."
				)

				bake_failed = true

				break


			captured_image.convert(
				Image.FORMAT_L8
			)


			final_image.blit_rect(
				captured_image,

				Rect2i(
					0,
					0,
					tile_resolution,
					tile_resolution
				),

				Vector2i(
					tile_x
						* tile_resolution,

					tile_z
						* tile_resolution
				)
			)


	# ========================================================
	# RESTORE EVERYTHING
	# ========================================================

	bake_camera.current = false

	bake_viewport.queue_free()


	terrain.material_override = (
		old_terrain_material
	)

	terrain.layers = (
		old_terrain_layers
	)

	terrain.gi_mode = (
		old_terrain_gi_mode
	)


	_restore_tree_states(
		shadow_states
	)

	_restore_other_light_states(
		other_light_states
	)

	_restore_decal_states(
		decal_states
	)


	sun.visible = (
		old_sun_visible
	)

	sun.shadow_enabled = (
		old_shadow_enabled
	)

	sun.shadow_opacity = (
		old_shadow_opacity
	)

	sun.light_cull_mask = (
		old_sun_light_cull_mask
	)

	sun.shadow_caster_mask = (
		old_sun_shadow_caster_mask
	)

	sun.light_bake_mode = (
		old_sun_bake_mode
	)

	sun.directional_shadow_max_distance = (
		old_shadow_max_distance
	)

	sun.directional_shadow_fade_start = (
		old_shadow_fade_start
	)


	if bake_failed:

		_baking = false

		return


	# ========================================================
	# MASK STATS
	# ========================================================

	_print_mask_stats(
		final_image
	)


	# ========================================================
	# SAVE
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
		final_image.save_png(
			absolute_path
		)
	)


	if save_error != OK:

		push_error(
			"BAKE: Failed saving PNG. Error "
			+ str(save_error)
		)

		_baking = false

		return


	print("")
	print("PURE SHADOW MASK CREATED:")
	print(absolute_path)
	print("")
	print("WHITE = no tree shadow")
	print("DARK  = tree shadow")
	print("")
	print("World Min: ", world_min)
	print("World Size: ", world_size)
	print("")


	# ========================================================
	# IMPORT REFRESH
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


	print("==========================================")
	print("PURE TREE SHADOW MASK BAKE FINISHED")
	print("==========================================")
	print("")


	_baking = false


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
# CREATE TREE CASTER MATERIAL
# ============================================================

func _create_bake_tree_material(
	source_material: Material,
	fixed_shader: Shader,
	fixed_to_light_ws: Vector3
) -> ShaderMaterial:

	var tree_texture: Texture2D = null

	var alpha_cutoff: float = 0.80


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

			alpha_cutoff = float(
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

		alpha_cutoff = (
			base_material.alpha_scissor_threshold
		)


	if tree_texture == null:

		push_error(
			"BAKE: Shadow source material has no tree texture."
		)

		return null


	var bake_material: ShaderMaterial = (
		ShaderMaterial.new()
	)

	bake_material.shader = (
		fixed_shader
	)


	bake_material.set_shader_parameter(
		"tree_tex",
		tree_texture
	)

	bake_material.set_shader_parameter(
		"alpha_cutoff",
		alpha_cutoff
	)

	bake_material.set_shader_parameter(
		"fixed_to_light_ws",
		fixed_to_light_ws
	)


	return bake_material


# ============================================================
# CANONICAL SHADOW MATERIAL
#
# Important because the previous failed bake left a temporary
# ShaderMaterial serialized on one TreeShadows node.
#
# The forest controller's shadow_material_override is the
# authoritative material when available.
# ============================================================

func _get_canonical_shadow_material(
	shadow_node: MultiMeshInstance3D
) -> Material:

	var forest_root: Node = (
		shadow_node.get_parent()
	)


	if (
		forest_root != null
		and _has_property(
			forest_root,
			&"shadow_material_override"
		)
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


	return (
		shadow_node.material_override
	)


# ============================================================
# RESTORE TREES
# ============================================================

func _restore_tree_states(
	states: Array[Dictionary]
) -> void:

	for state: Dictionary in states:

		var node_value: Variant = (
			state.get(
				"node"
			)
		)


		if not node_value is MultiMeshInstance3D:
			continue


		var shadow_node: MultiMeshInstance3D = (
			node_value
				as MultiMeshInstance3D
		)


		shadow_node.visible = bool(
			state.get(
				"visible",
				true
			)
		)


		shadow_node.layers = int(
			state.get(
				"layers",
				1
			)
		)


		var stored_cast_shadow: int = int(
			state.get(
				"cast_shadow",
				GeometryInstance3D
					.SHADOW_CASTING_SETTING_OFF
			)
		)


		shadow_node.cast_shadow = (
			stored_cast_shadow
			as GeometryInstance3D.ShadowCastingSetting
		)


		var material_value: Variant = (
			state.get(
				"restore_material"
			)
		)


		if material_value is Material:

			shadow_node.material_override = (
				material_value
					as Material
			)

		else:

			shadow_node.material_override = null


# ============================================================
# RESTORE OTHER LIGHTS
# ============================================================

func _restore_other_light_states(
	states: Array[Dictionary]
) -> void:

	for state: Dictionary in states:

		var node_value: Variant = (
			state.get(
				"node"
			)
		)


		if not node_value is Light3D:
			continue


		var light: Light3D = (
			node_value
				as Light3D
		)


		light.light_cull_mask = int(
			state.get(
				"light_cull_mask",
				MASK_32
			)
		)


# ============================================================
# RESTORE DECALS
# ============================================================

func _restore_decal_states(
	states: Array[Dictionary]
) -> void:

	for state: Dictionary in states:

		var node_value: Variant = (
			state.get(
				"node"
			)
		)


		if not node_value is Decal:
			continue


		var decal: Decal = (
			node_value
				as Decal
		)


		decal.visible = bool(
			state.get(
				"visible",
				true
			)
		)


# ============================================================
# MASK ANALYSIS
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


	if data.is_empty():
		return


	var minimum_value: int = 255

	var maximum_value: int = 0

	var shadow_pixel_count: int = 0

	var strong_shadow_pixel_count: int = 0


	for byte_value: int in data:

		minimum_value = mini(
			minimum_value,
			byte_value
		)

		maximum_value = maxi(
			maximum_value,
			byte_value
		)


		if byte_value < 250:

			shadow_pixel_count += 1


		if byte_value < 128:

			strong_shadow_pixel_count += 1


	var pixel_count: int = (
		data.size()
	)


	var shadow_percent: float = (
		float(shadow_pixel_count)
		/ float(
			maxi(
				pixel_count,
				1
			)
		)
		* 100.0
	)


	var strong_percent: float = (
		float(strong_shadow_pixel_count)
		/ float(
			maxi(
				pixel_count,
				1
			)
		)
		* 100.0
	)


	print("")
	print("MASK STATISTICS")
	print("--------------------------")
	print("Minimum value: ", minimum_value)
	print("Maximum value: ", maximum_value)
	print(
		"Shadow pixels (<250): ",
		shadow_pixel_count,
		" / ",
		pixel_count,
		" = ",
		shadow_percent,
		" %"
	)
	print(
		"Strong pixels (<128): ",
		strong_shadow_pixel_count,
		" = ",
		strong_percent,
		" %"
	)
	print("--------------------------")
	print("")


	if shadow_pixel_count < 1000:

		push_warning(
			"BAKE: Shadow mask still contains almost no "
			+ "shadow pixels. Do not use this PNG."
		)


# ============================================================
# COLLECT TREE SHADOWS
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
# COLLECT LIGHTS
# ============================================================

func _collect_lights(
	node: Node,
	results: Array[Light3D]
) -> void:

	if node is Light3D:

		results.append(
			node
				as Light3D
		)


	for child: Node in node.get_children():

		_collect_lights(
			child,
			results
		)


# ============================================================
# COLLECT DECALS
# ============================================================

func _collect_decals(
	node: Node,
	results: Array[Decal]
) -> void:

	if node is Decal:

		results.append(
			node
				as Decal
		)


	for child: Node in node.get_children():

		_collect_decals(
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
	mesh_instance: MeshInstance3D
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

		var corner: Vector3 = Vector3(

			local_aabb.position.x
				+ (
					local_aabb.size.x
					if (
						corner_index & 1
					) != 0
					else 0.0
				),

			local_aabb.position.y
				+ (
					local_aabb.size.y
					if (
						corner_index & 2
					) != 0
					else 0.0
				),

			local_aabb.position.z
				+ (
					local_aabb.size.z
					if (
						corner_index & 4
					) != 0
					else 0.0
				)
		)


		var world_corner: Vector3 = (
			mesh_instance.global_transform
			* corner
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

		var current_name: StringName = (
			StringName(
				String(
					property_info.get(
						"name",
						""
					)
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
