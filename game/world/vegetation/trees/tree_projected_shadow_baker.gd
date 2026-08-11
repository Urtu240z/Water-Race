@tool
extends Node3D


# ============================================================
# PATHS
# ============================================================

const DEFAULT_OUTPUT_PATH: String = (
	"res://world/terrain/baked_tree_projected_shadows.png"
)

const OVERLAY_SHADER_PATH: String = (
	"res://world/vegetation/trees/shaders/"
	+ "tree_projected_shadow_overlay.gdshader"
)

# Temporary camera-only layer used so the bake sees
# Terrain_Master_VIS and nothing else.
const BAKE_VISUAL_LAYER_MASK: int = (
	1 << 19
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

@export_range(1, 8, 1)
var tiles_per_axis: int = 4

@export_range(0.0, 100.0, 1.0)
var world_padding: float = 20.0


# ============================================================
# BAKE FILTER
# ============================================================

@export_group("Bake Filter")

# Ignore tiny differences between the two captures.
@export_range(0.0, 0.10, 0.001)
var noise_threshold: float = 0.005

# Avoid divisions/noise in pixels that are already almost black.
@export_range(0.001, 0.20, 0.001)
var minimum_reference_luminance: float = 0.025


# ============================================================
# OVERLAY
# ============================================================

@export_group("Overlay")

@export_range(0.0, 3.0, 0.01)
var overlay_shadow_strength: float = 1.35

@export_range(0.10, 3.0, 0.01)
var overlay_shadow_gamma: float = 0.75

@export_range(0.0, 0.20, 0.001)
var overlay_shadow_threshold: float = 0.005

@export_range(0.0, 1.0, 0.01)
var overlay_minimum_multiplier: float = 0.05

@export_range(0.0, 0.20, 0.001)
var overlay_surface_offset: float = 0.025


# ============================================================
# EDITOR
# ============================================================

@export_group("Editor")

@export_tool_button("BAKE SHADOW MULTIPLIER")
var bake_button = bake_tree_shadows

@export_tool_button("APPLY OVERLAY SETTINGS")
var apply_settings_button = apply_overlay_settings


# ============================================================
# INTERNAL
# ============================================================

var _baking: bool = false


# ============================================================
# FIXED TREE SHADOW SHADER
#
# Same principle as the working TreeShadows shader, but
# orientation is fixed to the actual sun instead of depending
# on the temporary bake camera.
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
# BAKE BUTTON
# ============================================================

func bake_tree_shadows() -> void:

	if _baking:
		return


	if not Engine.is_editor_hint():

		push_error(
			"Tree projected shadow bake is editor-only."
		)

		return


	_baking = true

	call_deferred(
		"_run_bake"
	)


# ============================================================
# APPLY SETTINGS WITHOUT REBAKING
# ============================================================

func apply_overlay_settings() -> void:

	if not Engine.is_editor_hint():
		return


	var scene_root: Node = _get_scene_root()

	if scene_root == null:

		push_error(
			"OVERLAY: Scene root not found."
		)

		return


	var terrain: MeshInstance3D = _find_terrain(
		scene_root
	)

	if terrain == null:

		push_error(
			"OVERLAY: Terrain_Master_VIS not found."
		)

		return


	var base_material: Material = (
		_get_terrain_material(
			terrain
		)
	)

	if base_material == null:

		push_error(
			"OVERLAY: Terrain material not found."
		)

		return


	var overlay_material: ShaderMaterial = (
		_find_overlay_material(
			base_material
		)
	)

	if overlay_material == null:

		push_error(
			"OVERLAY: No baked shadow overlay exists. "
			+ "Bake first."
		)

		return


	_apply_overlay_visual_settings(
		overlay_material
	)


	print("")
	print("Shadow overlay settings updated.")
	print("Strength: ", overlay_shadow_strength)
	print("Gamma: ", overlay_shadow_gamma)
	print(
		"Minimum multiplier: ",
		overlay_minimum_multiplier
	)
	print("")


# ============================================================
# MAIN BAKE
# ============================================================

func _run_bake() -> void:

	print("")
	print("==========================================")
	print("TREE SHADOW MULTIPLIER BAKE")
	print("==========================================")


	var scene_root: Node = _get_scene_root()

	if scene_root == null:

		push_error(
			"BAKE: Scene root not found."
		)

		_baking = false

		return


	var terrain: MeshInstance3D = _find_terrain(
		scene_root
	)

	if terrain == null:

		push_error(
			"BAKE: Terrain_Master_VIS not found."
		)

		_baking = false

		return


	var sun: DirectionalLight3D = _find_sun(
		scene_root
	)

	if sun == null:

		push_error(
			"BAKE: DirectionalLight3D not found."
		)

		_baking = false

		return


	var base_material: Material = (
		_get_terrain_material(
			terrain
		)
	)

	if base_material == null:

		push_error(
			"BAKE: Terrain_Master_VIS has no "
			+ "material_override."
		)

		_baking = false

		return


	# --------------------------------------------------------
	# Defensive cleanup of the OLD experiment.
	#
	# If the old terrain shader still has
	# use_baked_tree_shadows, disable it so it does not
	# contaminate the capture.
	# --------------------------------------------------------

	_disable_legacy_terrain_shadow(
		base_material
	)


	# --------------------------------------------------------
	# Temporarily remove our previous multiply next pass,
	# otherwise an old bake would contaminate the new bake.
	# --------------------------------------------------------

	var detached_overlay: Dictionary = (
		_detach_existing_overlay(
			base_material
		)
	)


	# --------------------------------------------------------
	# Tree shadow sources.
	# --------------------------------------------------------

	var shadow_nodes: Array[MultiMeshInstance3D] = []

	var canopy_nodes: Array[Decal] = []

	var old_caster_nodes: Array[GeometryInstance3D] = []


	_collect_nodes(
		scene_root,
		shadow_nodes,
		canopy_nodes,
		old_caster_nodes
	)


	if shadow_nodes.is_empty():

		_restore_detached_overlay(
			detached_overlay
		)

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
	# TILE SETUP
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


	# ========================================================
	# MULTIPLIER IMAGE
	#
	# WHITE = no change.
	# DARK = multiply final terrain.
	# ========================================================

	var final_image: Image = Image.create(
		final_resolution,
		final_resolution,
		false,
		Image.FORMAT_L8
	)

	final_image.fill(
		Color.WHITE
	)


	# ========================================================
	# TREE SHADOW MATERIAL STATES
	# ========================================================

	var shadow_states: Array[Dictionary] = []

	var fixed_shader: Shader = Shader.new()

	fixed_shader.code = (
		FIXED_SHADOW_SHADER_CODE
	)


	var fixed_to_light_ws: Vector3 = (
		sun.global_transform
			.basis
			.z
			.normalized()
	)


	for shadow_node: MultiMeshInstance3D in shadow_nodes:

		shadow_states.append({
			"node": shadow_node,
			"visible": shadow_node.visible,
			"cast_shadow": shadow_node.cast_shadow,
			"material": shadow_node.material_override
		})


		var original_material: Material = (
			shadow_node.material_override
		)


		var bake_material: ShaderMaterial = (
			ShaderMaterial.new()
		)

		bake_material.shader = (
			fixed_shader
		)


		if original_material is ShaderMaterial:

			var source_material: ShaderMaterial = (
				original_material
				as ShaderMaterial
			)


			var texture_value: Variant = (
				source_material
					.get_shader_parameter(
						"tree_tex"
					)
			)


			if texture_value is Texture2D:

				bake_material.set_shader_parameter(
					"tree_tex",
					texture_value
				)


			var cutoff_value: Variant = (
				source_material
					.get_shader_parameter(
						"alpha_cutoff"
					)
			)


			if (
				cutoff_value is float
				or cutoff_value is int
			):

				bake_material.set_shader_parameter(
					"alpha_cutoff",
					float(cutoff_value)
				)


		bake_material.set_shader_parameter(
			"fixed_to_light_ws",
			fixed_to_light_ws
		)


		shadow_node.material_override = (
			bake_material
		)

		shadow_node.visible = true

		shadow_node.cast_shadow = (
			GeometryInstance3D
				.SHADOW_CASTING_SETTING_SHADOWS_ONLY
		)


	# ========================================================
	# HIDE CANOPY
	# ========================================================

	var canopy_states: Array[Dictionary] = []


	for canopy: Decal in canopy_nodes:

		canopy_states.append({
			"node": canopy,
			"visible": canopy.visible
		})

		canopy.visible = false


	# ========================================================
	# HIDE OLD LIGHTMAP CASTER MESH
	# ========================================================

	var old_caster_states: Array[Dictionary] = []


	for old_caster: GeometryInstance3D in old_caster_nodes:

		old_caster_states.append({
			"node": old_caster,
			"visible": old_caster.visible
		})

		old_caster.visible = false


	# ========================================================
	# TEMPORARILY DISABLE LIGHTMAPGI DATA
	#
	# We want the captures to contain only the current
	# realtime sun + realtime TreeShadows difference.
	# ========================================================

	var lightmap_states: Array[Dictionary] = []

	_suspend_lightmaps(
		scene_root,
		lightmap_states
	)


	# ========================================================
	# SUN STATE
	# ========================================================

	var old_shadow_enabled: bool = (
		sun.shadow_enabled
	)

	var old_max_distance: float = (
		sun.directional_shadow_max_distance
	)

	var old_fade_start: float = (
		sun.directional_shadow_fade_start
	)

	var old_sun_cull_mask: int = (
		sun.light_cull_mask
	)

	var old_bake_mode: Light3D.BakeMode = (
		sun.light_bake_mode
	)


	sun.shadow_enabled = true

	sun.directional_shadow_fade_start = 1.0

	sun.light_cull_mask = (
		old_sun_cull_mask
		| BAKE_VISUAL_LAYER_MASK
	)

	# Guarantee realtime direct lighting while capturing.
	sun.light_bake_mode = (
		Light3D.BAKE_DISABLED
	)


	# ========================================================
	# TERRAIN TEMPORARY VISUAL LAYER
	#
	# This makes the bake camera render only the terrain,
	# not buildings, water, rocks, etc.
	# ========================================================

	var old_terrain_layers: int = (
		terrain.layers
	)

	terrain.layers = (
		BAKE_VISUAL_LAYER_MASK
	)


	# ========================================================
	# VIEWPORT
	# ========================================================

	var bake_viewport: SubViewport = (
		SubViewport.new()
	)

	bake_viewport.name = (
		"__TreeShadowMultiplierViewport"
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


	var bake_camera: Camera3D = (
		Camera3D.new()
	)

	bake_camera.name = (
		"__TreeShadowMultiplierCamera"
	)

	bake_viewport.add_child(
		bake_camera
	)


	bake_camera.projection = (
		Camera3D.PROJECTION_ORTHOGONAL
	)

	bake_camera.size = (
		tile_world_size
	)

	bake_camera.near = 0.1


	var camera_height: float = maxf(
		terrain_bounds.size.y + 80.0,
		120.0
	)


	bake_camera.far = (
		camera_height
		+ terrain_bounds.size.y
		+ 200.0
	)

	bake_camera.rotation_degrees = Vector3(
		-90.0,
		0.0,
		0.0
	)

	bake_camera.cull_mask = (
		BAKE_VISUAL_LAYER_MASK
	)

	bake_camera.current = true


	sun.directional_shadow_max_distance = maxf(
		old_max_distance,
		tile_world_size * 2.0
	)


	# Let all temporary state reach RenderingServer.
	await get_tree().process_frame

	await RenderingServer.frame_post_draw


	# ========================================================
	# CAPTURE TILE BY TILE
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


			# ----------------------------------------------
			# WITH TREE SHADOWS
			# ----------------------------------------------

			for shadow_node: MultiMeshInstance3D in shadow_nodes:

				shadow_node.cast_shadow = (
					GeometryInstance3D
						.SHADOW_CASTING_SETTING_SHADOWS_ONLY
				)


			var image_with: Image = (
				await _capture_viewport(
					bake_viewport
				)
			)


			# ----------------------------------------------
			# WITHOUT TREE SHADOWS
			# ----------------------------------------------

			for shadow_node: MultiMeshInstance3D in shadow_nodes:

				shadow_node.cast_shadow = (
					GeometryInstance3D
						.SHADOW_CASTING_SETTING_OFF
				)


			var image_without: Image = (
				await _capture_viewport(
					bake_viewport
				)
			)


			# ----------------------------------------------
			# MULTIPLIER
			# ----------------------------------------------

			var tile_multiplier: Image = (
				_build_multiplier_map(
					image_with,
					image_without
				)
			)


			if tile_multiplier == null:

				push_error(
					"BAKE: Failed building multiplier tile."
				)

				bake_failed = true

				break


			final_image.blit_rect(
				tile_multiplier,

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
	# RESTORE TEMPORARY SCENE STATE
	# ========================================================

	bake_camera.current = false

	bake_viewport.queue_free()


	terrain.layers = (
		old_terrain_layers
	)


	_restore_tree_states(
		shadow_states
	)

	_restore_canopy_states(
		canopy_states
	)

	_restore_geometry_states(
		old_caster_states
	)

	_restore_lightmaps(
		lightmap_states
	)


	sun.shadow_enabled = (
		old_shadow_enabled
	)

	sun.directional_shadow_max_distance = (
		old_max_distance
	)

	sun.directional_shadow_fade_start = (
		old_fade_start
	)

	sun.light_cull_mask = (
		old_sun_cull_mask
	)

	sun.light_bake_mode = (
		old_bake_mode
	)


	if bake_failed:

		_restore_detached_overlay(
			detached_overlay
		)

		_baking = false

		return


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
		final_image.save_png(
			absolute_path
		)
	)


	if save_error != OK:

		_restore_detached_overlay(
			detached_overlay
		)

		push_error(
			"BAKE: Could not save PNG. Error "
			+ str(save_error)
		)

		_baking = false

		return


	print("")
	print("MULTIPLIER MAP CREATED:")
	print(absolute_path)


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
	# LOAD MULTIPLIER TEXTURE
	# ========================================================

	var loaded_resource: Resource = (
		load(
			resolved_output_path
		)
	)


	if not loaded_resource is Texture2D:

		_restore_detached_overlay(
			detached_overlay
		)

		push_error(
			"BAKE: Multiplier texture could not be loaded."
		)

		_baking = false

		return


	var multiplier_texture: Texture2D = (
		loaded_resource
			as Texture2D
	)


	# ========================================================
	# APPLY AS NEXT PASS
	# ========================================================

	var detached_material: ShaderMaterial = null


	if not detached_overlay.is_empty():

		var detached_value: Variant = (
			detached_overlay.get(
				"overlay"
			)
		)

		if detached_value is ShaderMaterial:

			detached_material = (
				detached_value
					as ShaderMaterial
			)


	var apply_ok: bool = (
		_install_overlay(
			base_material,
			detached_material,
			multiplier_texture,
			world_min,
			world_size
		)
	)


	if not apply_ok:

		_restore_detached_overlay(
			detached_overlay
		)

		_baking = false

		return


	print("")
	print("==========================================")
	print("TREE SHADOW MULTIPLIER BAKE FINISHED")
	print("==========================================")
	print(
		"Texture: ",
		resolved_output_path
	)
	print(
		"World Min: ",
		world_min
	)
	print(
		"World Size: ",
		world_size
	)
	print("")
	print("The PNG should now look mostly WHITE.")
	print("Dark pixels are projected tree shadows.")
	print("")
	print(
		"Disable realtime TreeShadows to compare."
	)
	print(
		"Then tune Overlay Strength/Gamma and press:"
	)
	print(
		"APPLY OVERLAY SETTINGS"
	)
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
# BUILD MULTIPLIER MAP
#
# We store:
#
# multiplier = luminance_with_shadow /
#              luminance_without_shadow
#
# Therefore:
#
# 1.0 = no shadow.
# 0.5 = multiply final terrain by 0.5.
# 0.0 = complete darkness.
# ============================================================

func _build_multiplier_map(
	image_with: Image,
	image_without: Image
) -> Image:

	if (
		image_with == null
		or image_without == null
	):
		return null


	if (
		image_with.is_empty()
		or image_without.is_empty()
	):
		return null


	if (
		image_with.get_size()
		!= image_without.get_size()
	):
		return null


	image_with.convert(
		Image.FORMAT_RGBA8
	)

	image_without.convert(
		Image.FORMAT_RGBA8
	)


	var width: int = (
		image_with.get_width()
	)

	var height: int = (
		image_with.get_height()
	)

	var pixel_count: int = (
		width * height
	)


	var with_data: PackedByteArray = (
		image_with.get_data()
	)

	var without_data: PackedByteArray = (
		image_without.get_data()
	)


	var output_data: PackedByteArray = (
		PackedByteArray()
	)

	output_data.resize(
		pixel_count
	)


	for pixel_index: int in range(
		pixel_count
	):

		var byte_index: int = (
			pixel_index * 4
		)


		var with_r: float = (
			float(
				with_data[
					byte_index
				]
			)
			/ 255.0
		)

		var with_g: float = (
			float(
				with_data[
					byte_index + 1
				]
			)
			/ 255.0
		)

		var with_b: float = (
			float(
				with_data[
					byte_index + 2
				]
			)
			/ 255.0
		)


		var without_r: float = (
			float(
				without_data[
					byte_index
				]
			)
			/ 255.0
		)

		var without_g: float = (
			float(
				without_data[
					byte_index + 1
				]
			)
			/ 255.0
		)

		var without_b: float = (
			float(
				without_data[
					byte_index + 2
				]
			)
			/ 255.0
		)


		var lum_with: float = (
			with_r * 0.2126
			+ with_g * 0.7152
			+ with_b * 0.0722
		)


		var lum_without: float = (
			without_r * 0.2126
			+ without_g * 0.7152
			+ without_b * 0.0722
		)


		var multiplier: float = 1.0


		if (
			lum_without
			>= minimum_reference_luminance
		):

			var shadow_amount: float = clampf(
				(
					lum_without
					- lum_with
				)
				/ maxf(
					lum_without,
					minimum_reference_luminance
				),
				0.0,
				1.0
			)


			if (
				shadow_amount
				>= noise_threshold
			):

				multiplier = clampf(
					lum_with
					/ maxf(
						lum_without,
						minimum_reference_luminance
					),
					0.0,
					1.0
				)


		var value: int = int(
			round(
				multiplier
				* 255.0
			)
		)


		output_data[
			pixel_index
		] = value


	return Image.create_from_data(
		width,
		height,
		false,
		Image.FORMAT_L8,
		output_data
	)


# ============================================================
# OVERLAY INSTALLATION
# ============================================================

func _install_overlay(
	base_material: Material,
	existing_overlay: ShaderMaterial,
	multiplier_texture: Texture2D,
	world_min: Vector2,
	world_size: Vector2
) -> bool:

	var overlay_shader_resource: Resource = (
		load(
			OVERLAY_SHADER_PATH
		)
	)


	if not overlay_shader_resource is Shader:

		push_error(
			"OVERLAY: Shader not found: "
			+ OVERLAY_SHADER_PATH
		)

		return false


	var overlay_shader: Shader = (
		overlay_shader_resource
			as Shader
	)


	var overlay_material: ShaderMaterial = (
		existing_overlay
	)


	if overlay_material == null:

		overlay_material = (
			ShaderMaterial.new()
		)


	overlay_material.resource_name = (
		"TreeProjectedShadowMultiply"
	)

	overlay_material.resource_local_to_scene = true

	overlay_material.shader = (
		overlay_shader
	)

	overlay_material.render_priority = 1


	overlay_material.set_shader_parameter(
		"shadow_multiplier_map",
		multiplier_texture
	)

	overlay_material.set_shader_parameter(
		"shadow_world_min",
		world_min
	)

	overlay_material.set_shader_parameter(
		"shadow_world_size",
		world_size
	)


	_apply_overlay_visual_settings(
		overlay_material
	)


	# Our multiply pass goes immediately after the
	# terrain material.
	var previous_next_pass: Material = (
		base_material.next_pass
	)

	overlay_material.next_pass = (
		previous_next_pass
	)

	base_material.next_pass = (
		overlay_material
	)

	base_material.emit_changed()


	return true


func _apply_overlay_visual_settings(
	overlay_material: ShaderMaterial
) -> void:

	overlay_material.set_shader_parameter(
		"shadow_strength",
		overlay_shadow_strength
	)

	overlay_material.set_shader_parameter(
		"shadow_gamma",
		overlay_shadow_gamma
	)

	overlay_material.set_shader_parameter(
		"shadow_threshold",
		overlay_shadow_threshold
	)

	overlay_material.set_shader_parameter(
		"minimum_multiplier",
		overlay_minimum_multiplier
	)

	overlay_material.set_shader_parameter(
		"surface_offset",
		overlay_surface_offset
	)

	overlay_material.emit_changed()


# ============================================================
# DETACH OLD OVERLAY DURING BAKE
# ============================================================

func _detach_existing_overlay(
	base_material: Material
) -> Dictionary:

	var previous_material: Material = (
		base_material
	)

	var current_material: Material = (
		base_material.next_pass
	)


	while current_material != null:

		if _is_overlay_material(
			current_material
		):

			previous_material.next_pass = (
				current_material.next_pass
			)


			return {
				"previous": previous_material,
				"overlay": current_material
			}


		previous_material = (
			current_material
		)

		current_material = (
			current_material.next_pass
		)


	return {}


func _restore_detached_overlay(
	state: Dictionary
) -> void:

	if state.is_empty():
		return


	var previous_value: Variant = (
		state.get(
			"previous"
		)
	)

	var overlay_value: Variant = (
		state.get(
			"overlay"
		)
	)


	if (
		previous_value is Material
		and overlay_value is Material
	):

		var previous_material: Material = (
			previous_value
				as Material
		)

		var overlay_material: Material = (
			overlay_value
				as Material
		)


		overlay_material.next_pass = (
			previous_material.next_pass
		)

		previous_material.next_pass = (
			overlay_material
		)


func _find_overlay_material(
	base_material: Material
) -> ShaderMaterial:

	var current_material: Material = (
		base_material.next_pass
	)


	while current_material != null:

		if _is_overlay_material(
			current_material
		):

			return (
				current_material
					as ShaderMaterial
			)


		current_material = (
			current_material.next_pass
		)


	return null


func _is_overlay_material(
	material: Material
) -> bool:

	if not material is ShaderMaterial:
		return false


	var shader_material: ShaderMaterial = (
		material
			as ShaderMaterial
	)


	if shader_material.shader == null:
		return false


	if (
		shader_material.shader.resource_path
		== OVERLAY_SHADER_PATH
	):
		return true


	return (
		shader_material.resource_name
		== "TreeProjectedShadowMultiply"
	)


# ============================================================
# OLD TERRAIN EXPERIMENT
# ============================================================

func _disable_legacy_terrain_shadow(
	base_material: Material
) -> void:

	if not base_material is ShaderMaterial:
		return


	var shader_material: ShaderMaterial = (
		base_material
			as ShaderMaterial
	)


	if shader_material.shader == null:
		return


	var shader_code: String = (
		shader_material.shader.code
	)


	if (
		shader_code.find(
			"use_baked_tree_shadows"
		)
		< 0
	):
		return


	shader_material.set_shader_parameter(
		"use_baked_tree_shadows",
		false
	)


# ============================================================
# TEMPORARILY DISABLE LIGHTMAPGI
# ============================================================

func _suspend_lightmaps(
	node: Node,
	states: Array[Dictionary]
) -> void:

	if node is LightmapGI:

		var lightmap: LightmapGI = (
			node
				as LightmapGI
		)


		states.append({
			"node": lightmap,
			"light_data": lightmap.light_data
		})


		lightmap.light_data = null


	for child: Node in node.get_children():

		_suspend_lightmaps(
			child,
			states
		)


func _restore_lightmaps(
	states: Array[Dictionary]
) -> void:

	for state: Dictionary in states:

		var node_value: Variant = (
			state.get(
				"node"
			)
		)

		if not node_value is LightmapGI:
			continue


		var lightmap: LightmapGI = (
			node_value
				as LightmapGI
		)


		var data_value: Variant = (
			state.get(
				"light_data"
			)
		)


		if data_value is LightmapGIData:

			lightmap.light_data = (
				data_value
					as LightmapGIData
			)

		else:

			lightmap.light_data = null


# ============================================================
# RESTORE TREE / CANOPY / OLD CASTER STATES
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
				"material"
			)
		)


		if material_value is Material:

			shadow_node.material_override = (
				material_value
					as Material
			)

		else:

			shadow_node.material_override = null


func _restore_canopy_states(
	states: Array[Dictionary]
) -> void:

	for state: Dictionary in states:

		var node_value: Variant = (
			state.get(
				"node"
			)
		)


		if node_value is Decal:

			var canopy: Decal = (
				node_value
					as Decal
			)

			canopy.visible = bool(
				state.get(
					"visible",
					true
				)
			)


func _restore_geometry_states(
	states: Array[Dictionary]
) -> void:

	for state: Dictionary in states:

		var node_value: Variant = (
			state.get(
				"node"
			)
		)


		if node_value is GeometryInstance3D:

			var geometry: GeometryInstance3D = (
				node_value
					as GeometryInstance3D
			)

			geometry.visible = bool(
				state.get(
					"visible",
					true
				)
			)


# ============================================================
# COLLECT
# ============================================================

func _collect_nodes(
	node: Node,
	shadow_nodes: Array[MultiMeshInstance3D],
	canopy_nodes: Array[Decal],
	old_caster_nodes: Array[GeometryInstance3D]
) -> void:

	if (
		node is MultiMeshInstance3D
		and node.name == "TreeShadows"
	):

		shadow_nodes.append(
			node
				as MultiMeshInstance3D
		)


	if (
		node is Decal
		and node.name == "CanopyAmbientShadow"
	):

		canopy_nodes.append(
			node
				as Decal
		)


	if (
		node is GeometryInstance3D
		and node.name == "TreeLightmapCasters"
	):

		old_caster_nodes.append(
			node
				as GeometryInstance3D
		)


	for child: Node in node.get_children():

		_collect_nodes(
			child,
			shadow_nodes,
			canopy_nodes,
			old_caster_nodes
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


	return _find_mesh_by_name(
		scene_root,
		&"Terrain_Master_VIS"
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


func _get_terrain_material(
	terrain: MeshInstance3D
) -> Material:

	if terrain.material_override != null:

		return (
			terrain.material_override
		)


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


	return _find_first_directional_light(
		scene_root
	)


func _find_first_directional_light(
	node: Node
) -> DirectionalLight3D:

	if node is DirectionalLight3D:

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

	if (
		get_tree()
		== null
	):
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
