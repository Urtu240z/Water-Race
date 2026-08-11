@tool
extends Node3D


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
var output_png_path: String = (
	"res://world/terrain/baked_tree_projected_shadows.png"
)

@export_range(512, 4096, 256)
var texture_resolution: int = 2048

# 4x4 = 16 capturas pequeñas.
# Mucho mejor que una captura ortográfica de 1100 m.
@export_range(1, 8, 1)
var tiles_per_axis: int = 4

@export_range(0.0, 100.0, 1.0)
var world_padding: float = 20.0


# ============================================================
# MASK
# ============================================================

@export_group("Mask")

@export_range(0.1, 5.0, 0.05)
var mask_gain: float = 1.5

@export_range(0.0, 0.25, 0.001)
var mask_threshold: float = 0.01

@export_range(0.1, 3.0, 0.05)
var mask_gamma: float = 0.85


# ============================================================
# TERRAIN SHADER
# ============================================================

@export_group("Terrain Shader")

@export var auto_apply_to_terrain: bool = true

@export_range(0.0, 2.0, 0.01)
var terrain_shadow_strength: float = 1.0


# ============================================================
# EDITOR
# ============================================================

@export_group("Editor")

@export_tool_button("BAKE REAL TREE SHADOWS")
var bake_button = bake_tree_shadows


# ============================================================
# INTERNAL
# ============================================================

var _baking: bool = false


const FIXED_SHADOW_SHADER_CODE: String = """
shader_type spatial;

render_mode skip_vertex_transform, cull_disabled;

uniform sampler2D tree_tex : source_color;
uniform float alpha_cutoff : hint_range(0.0, 1.0, 0.01) = 0.80;

uniform vec3 fixed_to_light_ws = vec3(0.0, 0.0, 1.0);


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
	print("REAL TREE PROJECTED SHADOW BAKE")
	print("==========================================")


	var scene_root: Node = _get_scene_root()

	if scene_root == null:
		push_error("BAKE: Scene root not found.")
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


	var shadow_nodes: Array[MultiMeshInstance3D] = []

	var canopy_nodes: Array[Decal] = []

	_collect_nodes(
		scene_root,
		shadow_nodes,
		canopy_nodes
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
	# TERRAIN BOUNDS
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


	var terrain_width: float = (
		terrain_bounds.size.x
	)

	var terrain_depth: float = (
		terrain_bounds.size.z
	)


	var capture_world_size: float = maxf(
		terrain_width,
		terrain_depth
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
		"Tile world size: ",
		tile_world_size,
		" m"
	)


	# ========================================================
	# OUTPUT IMAGE
	# ========================================================

	var final_image: Image = Image.create(
		final_resolution,
		final_resolution,
		false,
		Image.FORMAT_RGBA8
	)

	final_image.fill(
		Color(
			0.0,
			0.0,
			0.0,
			1.0
		)
	)


	# ========================================================
	# SAVE ORIGINAL SHADOW NODES
	# ========================================================

	var shadow_states: Array[Dictionary] = []


	var fixed_shader: Shader = Shader.new()

	fixed_shader.code = (
		FIXED_SHADOW_SHADER_CODE
	)


	# Direction from the scene TOWARDS the sun.
	#
	# This replaces INV_VIEW_MATRIX[2] during the bake,
	# so the quad orientation does not depend on our
	# temporary bake camera.
	var fixed_to_light_ws: Vector3 = (
		sun.global_transform.basis.z.normalized()
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

			var source_shader_material: ShaderMaterial = (
				original_material
				as ShaderMaterial
			)


			var source_tree_tex: Variant = (
				source_shader_material
				.get_shader_parameter(
					"tree_tex"
				)
			)


			if source_tree_tex != null:

				bake_material.set_shader_parameter(
					"tree_tex",
					source_tree_tex
				)


			var source_alpha_cutoff: Variant = (
				source_shader_material
					.get_shader_parameter(
						"alpha_cutoff"
					)
			)


			if source_alpha_cutoff != null:

				bake_material.set_shader_parameter(
					"alpha_cutoff",
					source_alpha_cutoff
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
	# HIDE CANOPY DURING BAKE
	# ========================================================

	var canopy_states: Array[Dictionary] = []


	for canopy: Decal in canopy_nodes:

		canopy_states.append({
			"node": canopy,
			"visible": canopy.visible
		})

		canopy.visible = false


	# ========================================================
	# SAVE SUN SETTINGS
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


	# IMPORTANT:
	#
	# NO tocamos directional_shadow_mode.
	#
	# Se mantiene exactamente el modo que ya usas
	# en Paradise Island.
	sun.shadow_enabled = true

	sun.directional_shadow_fade_start = 1.0


	# ========================================================
	# VIEWPORT
	# ========================================================

	var bake_viewport: SubViewport = (
		SubViewport.new()
	)

	bake_viewport.name = (
		"__TreeShadowBakeViewport"
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
		"__TreeShadowBakeCamera"
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


	# No hace falta poner la cámara a 1000 metros.
	#
	# Una cámara ortográfica puede estar cerca
	# aunque cubra un área horizontal enorme.
	var camera_height: float = maxf(
		terrain_bounds.size.y
			+ 80.0,
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

	bake_camera.cull_mask = 1

	bake_camera.current = true


	# Solo ampliamos la distancia.
	# NO cambiamos el modo de sombras.
	sun.directional_shadow_max_distance = maxf(
		old_max_distance,
		tile_world_size * 2.0
	)


	# ========================================================
	# BAKE TILE BY TILE
	# ========================================================

	for tile_z: int in range(
		tile_count
	):

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


			var tile_mask: Image = (
				_build_shadow_mask(
					image_with,
					image_without
				)
			)


			if tile_mask == null:

				push_error(
					"BAKE: Failed building tile."
				)

				_restore_everything(
					shadow_states,
					canopy_states,
					sun,
					old_shadow_enabled,
					old_max_distance,
					old_fade_start
				)

				bake_viewport.queue_free()

				_baking = false

				return


			final_image.blit_rect(
				tile_mask,
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
	# RESTORE
	# ========================================================

	_restore_everything(
		shadow_states,
		canopy_states,
		sun,
		old_shadow_enabled,
		old_max_distance,
		old_fade_start
	)


	bake_camera.current = false

	bake_viewport.queue_free()


	# ========================================================
	# SAVE
	# ========================================================

	var absolute_path: String = (
		ProjectSettings.globalize_path(
			output_png_path
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
	print("PNG CREATED:")
	print(absolute_path)


	# ========================================================
	# REFRESH
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
	# APPLY
	# ========================================================

	if auto_apply_to_terrain:

		var baked_texture: Texture2D = (
			load(
				output_png_path
			) as Texture2D
		)


		if baked_texture != null:

			_apply_to_terrain(
				terrain,
				baked_texture,
				world_min,
				world_size
			)

		else:

			var preview_texture: ImageTexture = (
				ImageTexture.create_from_image(
					final_image
				)
			)

			_apply_to_terrain(
				terrain,
				preview_texture,
				world_min,
				world_size
			)


	print("")
	print("==========================================")
	print("REAL TREE SHADOW BAKE FINISHED")
	print("==========================================")
	print("Texture: ", output_png_path)
	print("World Min: ", world_min)
	print("World Size: ", world_size)
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
# BUILD MASK
# ============================================================

func _build_shadow_mask(
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
		pixel_count * 4
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


		var amount: float = (
			(lum_without - lum_with)
			/ maxf(
				lum_without,
				0.05
			)
		)


		amount = maxf(
			amount
				- mask_threshold,
			0.0
		)


		amount = clampf(
			amount
				* mask_gain,
			0.0,
			1.0
		)


		amount = pow(
			amount,
			maxf(
				mask_gamma,
				0.001
			)
		)


		var value: int = int(
			round(
				amount * 255.0
			)
		)


		output_data[
			byte_index
		] = value

		output_data[
			byte_index + 1
		] = value

		output_data[
			byte_index + 2
		] = value

		output_data[
			byte_index + 3
		] = 255


	return Image.create_from_data(
		width,
		height,
		false,
		Image.FORMAT_RGBA8,
		output_data
	)


# ============================================================
# RESTORE
# ============================================================

func _restore_everything(
	shadow_states: Array[Dictionary],
	canopy_states: Array[Dictionary],
	sun: DirectionalLight3D,
	old_shadow_enabled: bool,
	old_max_distance: float,
	old_fade_start: float
) -> void:

	for state: Dictionary in shadow_states:

		var shadow_node: MultiMeshInstance3D = (
			state["node"]
				as MultiMeshInstance3D
		)

		shadow_node.visible = bool(
			state["visible"]
		)

		shadow_node.cast_shadow = int(
			state["cast_shadow"]
		)

		shadow_node.material_override = (
			state["material"]
				as Material
		)


	for state: Dictionary in canopy_states:

		var canopy: Decal = (
			state["node"]
				as Decal
		)

		canopy.visible = bool(
			state["visible"]
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


# ============================================================
# APPLY TERRAIN
# ============================================================

func _apply_to_terrain(
	terrain: MeshInstance3D,
	texture: Texture2D,
	world_min: Vector2,
	world_size: Vector2
) -> void:

	var material: Material = (
		terrain.material_override
	)


	if (
		material == null
		and terrain.mesh != null
		and terrain.mesh.get_surface_count() > 0
	):

		material = (
			terrain.mesh
				.surface_get_material(
					0
				)
		)


	if not (
		material is ShaderMaterial
	):

		push_error(
			"BAKE: Terrain material is not ShaderMaterial."
		)

		return


	var shader_material: ShaderMaterial = (
		material
			as ShaderMaterial
	)


	shader_material.set_shader_parameter(
		"use_baked_tree_shadows",
		true
	)

	shader_material.set_shader_parameter(
		"tree_shadow_map",
		texture
	)

	shader_material.set_shader_parameter(
		"tree_shadow_world_min",
		world_min
	)

	shader_material.set_shader_parameter(
		"tree_shadow_world_size",
		world_size
	)

	shader_material.set_shader_parameter(
		"tree_shadow_strength",
		terrain_shadow_strength
	)


# ============================================================
# SCENE FINDERS
# ============================================================

func _get_scene_root() -> Node:

	if get_tree().edited_scene_root != null:
		return get_tree().edited_scene_root

	return get_tree().current_scene


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


	var found: Node = (
		_find_by_name(
			scene_root,
			"Terrain_Master_VIS"
		)
	)


	if found is MeshInstance3D:

		return (
			found
				as MeshInstance3D
		)


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
		_find_directional_light(
			scene_root
		)
	)


func _collect_nodes(
	node: Node,
	shadows: Array[MultiMeshInstance3D],
	canopies: Array[Decal]
) -> void:

	if (
		node is MultiMeshInstance3D
		and node.name == "TreeShadows"
	):

		shadows.append(
			node as MultiMeshInstance3D
		)


	elif (
		node is Decal
		and node.name == "CanopyAmbientShadow"
	):

		canopies.append(
			node as Decal
		)


	for child: Node in node.get_children():

		_collect_nodes(
			child,
			shadows,
			canopies
		)


func _find_by_name(
	node: Node,
	target_name: String
) -> Node:

	if node.name == target_name:
		return node


	for child: Node in node.get_children():

		var result: Node = (
			_find_by_name(
				child,
				target_name
			)
		)

		if result != null:
			return result


	return null


func _find_directional_light(
	node: Node
) -> DirectionalLight3D:

	if node is DirectionalLight3D:

		return (
			node
				as DirectionalLight3D
		)


	for child: Node in node.get_children():

		var result: DirectionalLight3D = (
			_find_directional_light(
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


	var local_min: Vector3 = (
		local_aabb.position
	)

	var local_max: Vector3 = (
		local_aabb.position
			+ local_aabb.size
	)


	var corners: PackedVector3Array = (
		PackedVector3Array([
			Vector3(
				local_min.x,
				local_min.y,
				local_min.z
			),

			Vector3(
				local_max.x,
				local_min.y,
				local_min.z
			),

			Vector3(
				local_min.x,
				local_max.y,
				local_min.z
			),

			Vector3(
				local_max.x,
				local_max.y,
				local_min.z
			),

			Vector3(
				local_min.x,
				local_min.y,
				local_max.z
			),

			Vector3(
				local_max.x,
				local_min.y,
				local_max.z
			),

			Vector3(
				local_min.x,
				local_max.y,
				local_max.z
			),

			Vector3(
				local_max.x,
				local_max.y,
				local_max.z
			)
		])
	)


	var first_world: Vector3 = (
		mesh_instance.global_transform
			* corners[0]
	)


	var result_min: Vector3 = (
		first_world
	)

	var result_max: Vector3 = (
		first_world
	)


	for index: int in range(
		1,
		corners.size()
	):

		var world_point: Vector3 = (
			mesh_instance.global_transform
				* corners[index]
		)


		result_min = Vector3(
			minf(
				result_min.x,
				world_point.x
			),

			minf(
				result_min.y,
				world_point.y
			),

			minf(
				result_min.z,
				world_point.z
			)
		)


		result_max = Vector3(
			maxf(
				result_max.x,
				world_point.x
			),

			maxf(
				result_max.y,
				world_point.y
			),

			maxf(
				result_max.z,
				world_point.z
			)
		)


	return AABB(
		result_min,
		result_max - result_min
	)
