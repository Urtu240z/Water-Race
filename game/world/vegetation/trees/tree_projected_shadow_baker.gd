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


# ============================================================
# REFERENCES
# ============================================================

@export_group("References")

@export_node_path("MeshInstance3D")
var terrain_mesh_path: NodePath

@export_node_path("DirectionalLight3D")
var sun_light_path: NodePath


# You can drag:
#
# - a SpotLight3D directly
# - a StadiumLight parent
# - Atrezzo itself
#
# The baker searches recursively for SpotLight3D children.
@export var extra_shadow_sources: Array[Node] = []


# ============================================================
# OUTPUT
# ============================================================

@export_group("Output")

@export_file("*.png")
var output_png_path: String = DEFAULT_OUTPUT_PATH

@export_range(512, 4096, 256)
var texture_resolution: int = 2048

@export_range(256, 1024, 256)
var extra_light_texture_resolution: int = 512

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
# SHADOW MIX
# ============================================================

@export_group("Shadow Mix")

# Applied to the directional/sun mask before storing alpha.
@export_range(0.1, 4.0, 0.01)
var shadow_alpha_multiplier: float = 1.35

@export_range(0.1, 4.0, 0.01)
var shadow_alpha_power: float = 1.25

# Strength of the baked SpotLight contribution.
#
# This is intentionally independent from the realtime
# light energy. It controls how much those baked local
# shadows darken the final static overlay.
@export_range(0.0, 1.0, 0.01)
var extra_light_shadow_strength: float = 0.55


# ============================================================
# OVERLAY
# ============================================================

@export_group("Overlay")

@export var create_or_update_overlay: bool = true


# ============================================================
# EDITOR
# ============================================================

@export_group("Editor")

@export_tool_button("BAKE TREE SHADOW OVERLAY")
var bake_button: Callable = bake_tree_shadow_overlay


# ============================================================
# INTERNAL
# ============================================================

var _baking: bool = false


# ============================================================
# RESULT TYPES
# ============================================================

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


class SpotBakeResult:

	var image: Image

	var view_transform: Transform3D

	var tan_half_fov: float
	var cos_outer_angle: float
	var light_range: float

	var angle_attenuation: float
	var distance_attenuation: float
	var shadow_opacity: float


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


	// Match the realtime TreeShadows shader:
	//
	// the billboard stays vertical and rotates only around Y,
	// using the orientation of the light/shadow camera.
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


# ============================================================
# BUTTON
# ============================================================

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


# ============================================================
# MAIN
# ============================================================

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


	# ========================================================
	# TREE SOURCES
	# ========================================================

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


	# ========================================================
	# SUN
	# ========================================================

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


	# ========================================================
	# EXTRA SPOT LIGHTS
	# ========================================================

	var spot_lights: Array[SpotLight3D] = (
		_collect_extra_spot_lights()
	)


	print(
		"Extra SpotLight3D found: ",
		spot_lights.size()
	)


	var spot_bakes: Array[SpotBakeResult] = []


	for index: int in range(
		spot_lights.size()
	):

		var spot: SpotLight3D = (
			spot_lights[index]
		)


		print(
			"Baking SpotLight3D ",
			index + 1,
			" / ",
			spot_lights.size(),
			": ",
			spot.get_path()
		)


		var spot_bake: SpotBakeResult = (
			await _bake_spot_mask(
				terrain,
				shadow_nodes,
				spot
			)
		)


		if spot_bake == null:

			push_warning(
				"BAKE: SpotLight skipped: "
				+ String(
					spot.get_path()
				)
			)

			continue


		spot_bakes.append(
			spot_bake
		)


	# ========================================================
	# PROJECT EXTRA SPOT SHADOWS INTO SUN-SPACE
	# ========================================================

	var spot_shadow_mask: Image = null


	if not spot_bakes.is_empty():

		spot_shadow_mask = (
			await _compose_spot_masks_in_sun_space(
				terrain,
				sun_bake,
				spot_bakes
			)
		)


		if spot_shadow_mask == null:

			_abort_bake(
				"BAKE: Failed composing SpotLight masks."
			)

			return


	# ========================================================
	# FINAL RGBA
	# ========================================================

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


	# ========================================================
	# SAVE
	# ========================================================

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


	# ========================================================
	# IMPORT / RELOAD
	# ========================================================

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


	# ========================================================
	# MATERIAL OVERLAY
	# ========================================================

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


	# ========================================================
	# DONE
	# ========================================================

	EditorInterface.mark_scene_as_unsaved()


	print("")
	print("==========================================")
	print("TREE SHADOW OVERLAY BAKE FINISHED")
	print("==========================================")
	print("")


	_baking = false


# ============================================================
# SUN BAKE
# ============================================================

func _bake_sun_mask(
	terrain: MeshInstance3D,
	shadow_nodes: Array[MultiMeshInstance3D],
	sun: DirectionalLight3D,
	combined_bounds: AABB
) -> SunBakeResult:

	var bounds_center: Vector3 = (
		combined_bounds.position
		+ combined_bounds.size * 0.5
	)


	var bounds_radius: float = maxf(
		combined_bounds.size.length() * 0.5,
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
		_create_bake_environment()
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
		_add_mask_geometry(
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


# ============================================================
# SPOTLIGHT BAKE
# ============================================================

func _bake_spot_mask(
	terrain: MeshInstance3D,
	shadow_nodes: Array[MultiMeshInstance3D],
	spot: SpotLight3D
) -> SpotBakeResult:

	if spot == null:
		return null


	if not spot.visible:
		return null


	if spot.light_energy <= 0.0:
		return null


	if spot.spot_range <= 0.01:
		return null


	var bake_viewport: SubViewport = (
		_create_bake_viewport(
			extra_light_texture_resolution
		)
	)


	var bake_camera: Camera3D = (
		Camera3D.new()
	)


	bake_camera.name = (
		"__StaticTreeShadowSpotCamera"
	)

	bake_viewport.add_child(
		bake_camera
	)

	bake_camera.environment = (
		_create_bake_environment()
	)


	var camera_basis: Basis = (
		spot.global_transform
			.basis
			.orthonormalized()
	)


	var camera_transform: Transform3D = (
		Transform3D(
			camera_basis,
			spot.global_position
		)
	)


	bake_camera.global_transform = (
		camera_transform
	)


	var full_fov: float = clampf(
		spot.spot_angle * 2.0,
		1.0,
		179.0
	)


	bake_camera.projection = (
		Camera3D.PROJECTION_PERSPECTIVE
	)

	bake_camera.keep_aspect = (
		Camera3D.KEEP_HEIGHT
	)

	bake_camera.fov = (
		full_fov
	)

	bake_camera.near = 0.05

	bake_camera.far = maxf(
		spot.spot_range,
		0.1
	)

	bake_camera.current = true


	# Matches TreeShadows' shadow shader:
	# use the shadow camera's +Z orientation,
	# not its position.
	var fixed_to_camera_ws: Vector3 = (
		camera_transform
			.basis
			.z
			.normalized()
	)


	var caster_count: int = (
		_add_mask_geometry(
			bake_viewport,
			terrain,
			shadow_nodes,
			fixed_to_camera_ws
		)
	)


	if caster_count == 0:

		bake_camera.current = false

		bake_viewport.queue_free()

		await get_tree().process_frame

		return null


	var captured_image: Image = (
		await _capture_viewport(
			bake_viewport
		)
	)


	var actual_camera_transform: Transform3D = (
		bake_camera.get_camera_transform()
	)


	var view_transform: Transform3D = (
		actual_camera_transform.affine_inverse()
	)


	var tan_half_fov: float = tan(
		deg_to_rad(
			full_fov * 0.5
		)
	)


	var cos_outer_angle: float = cos(
		deg_to_rad(
			clampf(
				spot.spot_angle,
				0.1,
				89.5
			)
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


	var result: SpotBakeResult = (
		SpotBakeResult.new()
	)


	result.image = (
		captured_image
	)

	result.view_transform = (
		view_transform
	)

	result.tan_half_fov = (
		tan_half_fov
	)

	result.cos_outer_angle = (
		cos_outer_angle
	)

	result.light_range = (
		spot.spot_range
	)

	result.angle_attenuation = (
		spot.spot_angle_attenuation
	)

	result.distance_attenuation = (
		spot.spot_attenuation
	)

	result.shadow_opacity = (
		spot.shadow_opacity
	)


	return result


# ============================================================
# COMPOSE SPOT MASKS INTO SUN-SPACE
# ============================================================

func _compose_spot_masks_in_sun_space(
	terrain: MeshInstance3D,
	sun_bake: SunBakeResult,
	spot_bakes: Array[SpotBakeResult]
) -> Image:

	var spot_count: int = (
		spot_bakes.size()
	)


	if spot_count <= 0:
		return null


	# --------------------------------------------------------
	# BUILD TEMP ATLAS
	# --------------------------------------------------------

	var atlas_columns: int = int(
		ceil(
			sqrt(
				float(
					spot_count
				)
			)
		)
	)


	atlas_columns = maxi(
		atlas_columns,
		1
	)


	var atlas_rows: int = int(
		ceil(
			float(
				spot_count
			)
			/ float(
				atlas_columns
			)
		)
	)


	atlas_rows = maxi(
		atlas_rows,
		1
	)


	var atlas_size: Vector2i = Vector2i(
		atlas_columns
			* extra_light_texture_resolution,
		atlas_rows
			* extra_light_texture_resolution
	)


	var atlas_image: Image = (
		Image.create_empty(
			atlas_size.x,
			atlas_size.y,
			false,
			Image.FORMAT_L8
		)
	)


	atlas_image.fill(
		Color.WHITE
	)


	for index: int in range(
		spot_count
	):

		var spot_bake: SpotBakeResult = (
			spot_bakes[index]
		)


		var column: int = (
			index
			% atlas_columns
		)


		var row: int = floori(
			float(index)
			/ float(atlas_columns)
		)


		var destination: Vector2i = Vector2i(
			column
				* extra_light_texture_resolution,
			row
				* extra_light_texture_resolution
		)


		atlas_image.blit_rect(
			spot_bake.image,
			Rect2i(
				Vector2i.ZERO,
				spot_bake.image.get_size()
			),
			destination
		)


	var atlas_texture: ImageTexture = (
		ImageTexture.create_from_image(
			atlas_image
		)
	)


	# --------------------------------------------------------
	# COMPOSE SHADER
	# --------------------------------------------------------

	var compose_shader: Shader = (
		Shader.new()
	)


	compose_shader.code = (
		_build_spot_compose_shader_code(
			spot_count
		)
	)


	var compose_material: ShaderMaterial = (
		ShaderMaterial.new()
	)


	compose_material.shader = (
		compose_shader
	)


	compose_material.set_shader_parameter(
		"spot_atlas",
		atlas_texture
	)


	compose_material.set_shader_parameter(
		"extra_shadow_strength",
		extra_light_shadow_strength
	)


	for index: int in range(
		spot_count
	):

		var spot_bake: SpotBakeResult = (
			spot_bakes[index]
		)


		var suffix: String = (
			str(
				index
			)
		)


		var column: int = (
			index
			% atlas_columns
		)


		var row: int = floori(
			float(index)
			/ float(atlas_columns)
		)


		var atlas_rect: Vector4 = Vector4(

			float(
				column
			)
			/ float(
				atlas_columns
			),

			float(
				row
			)
			/ float(
				atlas_rows
			),

			1.0
			/ float(
				atlas_columns
			),

			1.0
			/ float(
				atlas_rows
			)
		)


		compose_material.set_shader_parameter(
			"spot_view_" + suffix,
			spot_bake.view_transform
		)


		compose_material.set_shader_parameter(
			"spot_atlas_rect_" + suffix,
			atlas_rect
		)


		compose_material.set_shader_parameter(
			"spot_tan_half_fov_" + suffix,
			spot_bake.tan_half_fov
		)


		compose_material.set_shader_parameter(
			"spot_cos_outer_" + suffix,
			spot_bake.cos_outer_angle
		)


		compose_material.set_shader_parameter(
			"spot_range_" + suffix,
			spot_bake.light_range
		)


		compose_material.set_shader_parameter(
			"spot_angle_attenuation_" + suffix,
			spot_bake.angle_attenuation
		)


		compose_material.set_shader_parameter(
			"spot_distance_attenuation_" + suffix,
			spot_bake.distance_attenuation
		)


		compose_material.set_shader_parameter(
			"spot_shadow_opacity_" + suffix,
			spot_bake.shadow_opacity
		)


	# --------------------------------------------------------
	# RENDER TERRAIN FROM SAME SUN CAMERA
	# --------------------------------------------------------

	var bake_viewport: SubViewport = (
		_create_bake_viewport(
			texture_resolution
		)
	)


	var bake_camera: Camera3D = (
		Camera3D.new()
	)


	bake_camera.name = (
		"__StaticTreeShadowComposeCamera"
	)

	bake_viewport.add_child(
		bake_camera
	)

	bake_camera.environment = (
		_create_bake_environment()
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

	bake_camera.current = true


	var terrain_clone: MeshInstance3D = (
		MeshInstance3D.new()
	)


	terrain_clone.name = (
		"__SpotShadowReceiverTerrain"
	)

	terrain_clone.mesh = (
		terrain.mesh
	)

	terrain_clone.material_override = (
		compose_material
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


	return captured_image


# ============================================================
# SPOT COMPOSE SHADER
# ============================================================

func _build_spot_compose_shader_code(
	spot_count: int
) -> String:

	var code: String = """
shader_type spatial;

render_mode
	unshaded,
	cull_disabled,
	fog_disabled;


uniform sampler2D spot_atlas
	: repeat_disable, filter_nearest;


uniform float extra_shadow_strength
	: hint_range(0.0, 1.0, 0.01) = 0.55;


varying vec3 world_position;


void vertex() {

	world_position = (
		MODEL_MATRIX
		* vec4(
			VERTEX,
			1.0
		)
	).xyz;
}


"""


	for index: int in range(
		spot_count
	):

		var suffix: String = (
			str(
				index
			)
		)


		code += (
			"uniform mat4 spot_view_"
			+ suffix
			+ ";\n"
		)

		code += (
			"uniform vec4 spot_atlas_rect_"
			+ suffix
			+ ";\n"
		)

		code += (
			"uniform float spot_tan_half_fov_"
			+ suffix
			+ ";\n"
		)

		code += (
			"uniform float spot_cos_outer_"
			+ suffix
			+ ";\n"
		)

		code += (
			"uniform float spot_range_"
			+ suffix
			+ ";\n"
		)

		code += (
			"uniform float spot_angle_attenuation_"
			+ suffix
			+ ";\n"
		)

		code += (
			"uniform float spot_distance_attenuation_"
			+ suffix
			+ ";\n"
		)

		code += (
			"uniform float spot_shadow_opacity_"
			+ suffix
			+ ";\n\n"
		)


	code += """
void fragment() {

	float combined_shadow = 0.0;

"""


	for index: int in range(
		spot_count
	):

		var suffix: String = (
			str(
				index
			)
		)


		code += "\t{\n"

		code += (
			"\t\tvec4 spot_view_position = "
			+ "spot_view_"
			+ suffix
			+ " * vec4(world_position, 1.0);\n"
		)

		code += (
			"\t\tfloat spot_depth = "
			+ "-spot_view_position.z;\n"
		)

		code += "\n"

		code += (
			"\t\tif (spot_depth > 0.001) {\n"
		)

		code += (
			"\t\t\tfloat distance_to_light = "
			+ "length(spot_view_position.xyz);\n"
		)

		code += "\n"

		code += (
			"\t\t\tif (distance_to_light > 0.001 "
			+ "&& distance_to_light <= spot_range_"
			+ suffix
			+ ") {\n"
		)

		code += (
			"\t\t\t\tfloat cone_cos = "
			+ "spot_depth / distance_to_light;\n"
		)

		code += "\n"

		code += (
			"\t\t\t\tif (cone_cos >= spot_cos_outer_"
			+ suffix
			+ ") {\n"
		)

		code += (
			"\t\t\t\t\tvec2 ndc_xy = "
			+ "spot_view_position.xy / max("
			+ "spot_depth * spot_tan_half_fov_"
			+ suffix
			+ ", 0.0001);\n"
		)

		code += (
			"\t\t\t\t\tvec2 spot_uv = vec2("
			+ "ndc_xy.x * 0.5 + 0.5, "
			+ "0.5 - ndc_xy.y * 0.5);\n"
		)

		code += "\n"

		code += (
			"\t\t\t\t\tif ("
			+ "spot_uv.x >= 0.0 "
			+ "&& spot_uv.x <= 1.0 "
			+ "&& spot_uv.y >= 0.0 "
			+ "&& spot_uv.y <= 1.0) {\n"
		)

		code += (
			"\t\t\t\t\t\tspot_uv = clamp("
			+ "spot_uv, vec2(0.001), vec2(0.999));\n"
		)

		code += (
			"\t\t\t\t\t\tvec4 atlas_rect = "
			+ "spot_atlas_rect_"
			+ suffix
			+ ";\n"
		)

		code += (
			"\t\t\t\t\t\tvec2 atlas_uv = "
			+ "atlas_rect.xy "
			+ "+ spot_uv * atlas_rect.zw;\n"
		)

		code += "\n"

		code += (
			"\t\t\t\t\t\tfloat raw_shadow = "
			+ "1.0 - texture("
			+ "spot_atlas, atlas_uv).r;\n"
		)

		code += "\n"

		code += (
			"\t\t\t\t\t\tfloat cone_span = "
			+ "max(1.0 - spot_cos_outer_"
			+ suffix
			+ ", 0.0001);\n"
		)

		code += (
			"\t\t\t\t\t\tfloat cone_weight = "
			+ "clamp(("
			+ "cone_cos - spot_cos_outer_"
			+ suffix
			+ ") / cone_span, 0.0, 1.0);\n"
		)

		code += (
			"\t\t\t\t\t\tcone_weight = pow("
			+ "cone_weight, max("
			+ "spot_angle_attenuation_"
			+ suffix
			+ ", 0.001));\n"
		)

		code += "\n"

		code += (
			"\t\t\t\t\t\tfloat distance_weight = "
			+ "clamp(1.0 - distance_to_light / max("
			+ "spot_range_"
			+ suffix
			+ ", 0.001), 0.0, 1.0);\n"
		)

		code += (
			"\t\t\t\t\t\tdistance_weight = pow("
			+ "distance_weight, max("
			+ "spot_distance_attenuation_"
			+ suffix
			+ ", 0.001));\n"
		)

		code += "\n"

		code += (
			"\t\t\t\t\t\tfloat shadow_alpha = "
			+ "raw_shadow "
			+ "* cone_weight "
			+ "* distance_weight "
			+ "* spot_shadow_opacity_"
			+ suffix
			+ " "
			+ "* extra_shadow_strength;\n"
		)

		code += (
			"\t\t\t\t\t\tshadow_alpha = clamp("
			+ "shadow_alpha, 0.0, 1.0);\n"
		)

		code += "\n"

		code += (
			"\t\t\t\t\t\tcombined_shadow = "
			+ "1.0 "
			+ "- (1.0 - combined_shadow) "
			+ "* (1.0 - shadow_alpha);\n"
		)

		code += "\t\t\t\t\t}\n"
		code += "\t\t\t\t}\n"
		code += "\t\t\t}\n"
		code += "\t\t}\n"
		code += "\t}\n\n"


	code += """
	ALBEDO = vec3(
		1.0 - clamp(
			combined_shadow,
			0.0,
			1.0
		)
	);

	ROUGHNESS = 1.0;
}
"""


	return code


# ============================================================
# BUILD FINAL IMAGE
# ============================================================

func _build_final_shadow_image(
	sun_mask: Image,
	spot_mask: Image
) -> Image:

	if (
		sun_mask == null
		or sun_mask.is_empty()
	):

		return null


	if sun_mask.get_format() != Image.FORMAT_L8:

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
		and spot_mask.get_width() == width
		and spot_mask.get_height() == height
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

				var spot_gray: float = (
					spot_mask.get_pixel(
						x,
						y
					).r
				)


				spot_alpha = clampf(
					1.0
						- spot_gray,
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


# ============================================================
# MATERIAL OVERLAY
# ============================================================

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


# ============================================================
# IMPORT PNG
# ============================================================

func _refresh_and_load_texture(
	resource_path: String
) -> Texture2D:

	var filesystem: EditorFileSystem = (
		EditorInterface
			.get_resource_filesystem()
	)


	while (
		filesystem.is_scanning()
		or filesystem.is_importing()
	):

		await get_tree().process_frame


	# Important for a newly created PNG.
	filesystem.update_file(
		resource_path
	)


	var files_to_import: PackedStringArray = (
		PackedStringArray(
			[
				resource_path
			]
		)
	)


	filesystem.reimport_files(
		files_to_import
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


# ============================================================
# BAKE VIEWPORT
# ============================================================

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


	bake_viewport.own_world_3d = true

	bake_viewport.transparent_bg = false


	bake_viewport.render_target_update_mode = (
		SubViewport.UPDATE_DISABLED
	)


	add_child(
		bake_viewport
	)


	return bake_viewport


# ============================================================
# ENVIRONMENT
# ============================================================

func _create_bake_environment() -> Environment:

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


	environment.fog_enabled = false

	environment.volumetric_fog_enabled = false

	environment.glow_enabled = false

	environment.adjustment_enabled = false


	return environment


# ============================================================
# MASK GEOMETRY
# ============================================================

func _add_mask_geometry(
	bake_viewport: SubViewport,
	terrain: MeshInstance3D,
	shadow_nodes: Array[MultiMeshInstance3D],
	fixed_to_camera_ws: Vector3
) -> int:

	# --------------------------------------------------------
	# WHITE TERRAIN
	# --------------------------------------------------------

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


	# --------------------------------------------------------
	# BLACK TREE CASTERS
	# --------------------------------------------------------

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


		caster_clone.transform = (
			shadow_node.global_transform
		)


		caster_count += 1


	return caster_count


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
# CREATE TREE MASK MATERIAL
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
# EXTRA SPOTLIGHTS
# ============================================================

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


# ============================================================
# TREE SHADOW NODES
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
# CLEAN TEMP VIEWPORTS
# ============================================================

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


# ============================================================
# ABORT
# ============================================================

func _abort_bake(
	message: String
) -> void:

	push_error(
		message
	)

	_baking = false
