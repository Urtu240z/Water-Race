@tool
extends Node3D


# ============================================================
# REFERENCES
# ============================================================

@export_group("References")

# Opcionales.
# Si los dejas vacíos, el baker los busca solo.
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
	"res://levels/paradise_island/terrain/"
	+ "baked_tree_projected_shadows.png"
)

@export_range(256, 4096, 256)
var texture_resolution: int = 1024

@export_range(0.0, 100.0, 1.0)
var world_padding: float = 20.0


# ============================================================
# MASK
# ============================================================

@export_group("Mask")

# Multiplica la sombra detectada.
@export_range(0.1, 5.0, 0.05)
var mask_gain: float = 1.5

# Elimina pequeñas diferencias de iluminación/AA.
@export_range(0.0, 0.25, 0.001)
var mask_threshold: float = 0.01

@export_range(0.1, 3.0, 0.05)
var mask_gamma: float = 0.85


# ============================================================
# TERRAIN
# ============================================================

@export_group("Terrain Shader")

@export var auto_apply_to_terrain: bool = true

@export_range(0.0, 2.0, 0.01)
var terrain_shadow_strength: float = 1.0


# ============================================================
# EDITOR
# ============================================================

@export_group("Editor")

@export_tool_button("BAKE TREE SHADOWS")
var bake_button = bake_tree_shadows


# ============================================================
# INTERNAL
# ============================================================

var _baking: bool = false


# ============================================================
# BUTTON
# ============================================================

func bake_tree_shadows() -> void:

	if _baking:
		push_warning(
			"Tree shadow bake already running."
		)
		return

	if not Engine.is_editor_hint():
		push_error(
			"Tree shadow baker is editor-only."
		)
		return

	_baking = true

	call_deferred(
		"_run_bake"
	)


# ============================================================
# BAKE
# ============================================================

func _run_bake() -> void:

	print("")
	print("==========================================")
	print("TREE PROJECTED SHADOW BAKE")
	print("==========================================")


	var scene_root: Node = _get_scene_root()

	if scene_root == null:
		push_error(
			"BAKE: Could not find edited scene root."
		)
		_baking = false
		return


	# --------------------------------------------------------
	# TERRAIN
	# --------------------------------------------------------

	var terrain: MeshInstance3D = (
		_find_terrain(scene_root)
	)

	if terrain == null:
		push_error(
			"BAKE: Terrain_Master_VIS not found."
		)
		_baking = false
		return


	# --------------------------------------------------------
	# SUN
	# --------------------------------------------------------

	var sun: DirectionalLight3D = (
		_find_sun(scene_root)
	)

	if sun == null:
		push_error(
			"BAKE: DirectionalLight3D not found."
		)
		_baking = false
		return


	# --------------------------------------------------------
	# TREE NODES
	# --------------------------------------------------------

	var tree_nodes: Array[MultiMeshInstance3D] = []
	var shadow_nodes: Array[MultiMeshInstance3D] = []
	var canopy_nodes: Array[Decal] = []

	_collect_forest_nodes(
		scene_root,
		tree_nodes,
		shadow_nodes,
		canopy_nodes
	)


	print(
		"Trees found: ",
		tree_nodes.size()
	)

	print(
		"TreeShadows found: ",
		shadow_nodes.size()
	)


	if shadow_nodes.is_empty():
		push_error(
			"BAKE: No TreeShadows nodes found."
		)
		_baking = false
		return


	# --------------------------------------------------------
	# TERRAIN WORLD BOUNDS
	# --------------------------------------------------------

	var terrain_bounds: AABB = (
		_get_world_aabb(
			terrain
		)
	)


	var terrain_min: Vector3 = (
		terrain_bounds.position
	)

	var terrain_max: Vector3 = (
		terrain_bounds.position
		+ terrain_bounds.size
	)


	var center_x: float = (
		terrain_min.x
		+ terrain_max.x
	) * 0.5

	var center_z: float = (
		terrain_min.z
		+ terrain_max.z
	) * 0.5


	var terrain_width: float = (
		terrain_max.x
		- terrain_min.x
	)

	var terrain_depth: float = (
		terrain_max.z
		- terrain_min.z
	)


	var capture_size: float = (
		maxf(
			terrain_width,
			terrain_depth
		)
		+ world_padding * 2.0
	)


	var world_min: Vector2 = Vector2(
		center_x - capture_size * 0.5,
		center_z - capture_size * 0.5
	)

	var world_size: Vector2 = Vector2(
		capture_size,
		capture_size
	)


	print(
		"Capture world size: ",
		capture_size,
		" m"
	)


	# --------------------------------------------------------
	# SUBVIEWPORT
	# --------------------------------------------------------

	var bake_viewport: SubViewport = (
		SubViewport.new()
	)

	bake_viewport.name = (
		"__TreeShadowBakeViewport"
	)

	bake_viewport.size = Vector2i(
		texture_resolution,
		texture_resolution
	)

	bake_viewport.transparent_bg = false

	bake_viewport.render_target_update_mode = (
		SubViewport.UPDATE_DISABLED
	)

	bake_viewport.world_3d = get_world_3d()

	add_child(
		bake_viewport
	)


	# --------------------------------------------------------
	# CAMERA
	# --------------------------------------------------------

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

	bake_camera.size = capture_size

	bake_camera.near = 0.1


	var camera_height: float = maxf(
		capture_size * 0.75,
		250.0
	)


	bake_camera.position = Vector3(
		center_x,
		terrain_max.y + camera_height,
		center_z
	)

	bake_camera.rotation_degrees = Vector3(
		-90.0,
		0.0,
		0.0
	)

	bake_camera.far = (
		camera_height
		+ terrain_bounds.size.y
		+ 500.0
	)

	# Terrain está en visual layer 1.
	# Trees están en layer 2.
	bake_camera.cull_mask = 1

	bake_camera.current = true


	# ========================================================
	# SAVE ORIGINAL STATES
	# ========================================================

	var tree_states: Array[Dictionary] = []
	var shadow_states: Array[Dictionary] = []
	var canopy_states: Array[Dictionary] = []


	for tree_node: MultiMeshInstance3D in tree_nodes:

		tree_states.append({
			"node": tree_node,
			"visible": tree_node.visible
		})

		# No queremos ver copas desde arriba.
		tree_node.visible = false


	for shadow_node: MultiMeshInstance3D in shadow_nodes:

		shadow_states.append({
			"node": shadow_node,
			"visible": shadow_node.visible,
			"cast_shadow": shadow_node.cast_shadow
		})


	for canopy: Decal in canopy_nodes:

		canopy_states.append({
			"node": canopy,
			"visible": canopy.visible
		})

		# El canopy NO forma parte de este bake.
		canopy.visible = false


	# --------------------------------------------------------
	# SAVE SUN STATE
	# --------------------------------------------------------

	var old_shadow_enabled: bool = (
		sun.shadow_enabled
	)

	var old_shadow_distance: float = (
		sun.directional_shadow_max_distance
	)

	var old_shadow_fade: float = (
		sun.directional_shadow_fade_start
	)

	var old_shadow_mode: int = (
		sun.directional_shadow_mode
	)


	# ========================================================
	# BAKE SETTINGS FOR SUN
	# ========================================================

	sun.shadow_enabled = true

	# Para el bake queremos cubrir toda la isla.
	sun.directional_shadow_max_distance = maxf(
		bake_camera.far,
		capture_size * 2.0
	)

	sun.directional_shadow_fade_start = 1.0

	# Un único shadow map ortográfico evita
	# cortes de cascadas durante el bake.
	sun.directional_shadow_mode = (
		DirectionalLight3D.SHADOW_ORTHOGONAL
	)


	# ========================================================
	# CAPTURE WITH TREE SHADOWS
	# ========================================================

	print("Capturing WITH tree shadows...")


	for shadow_node: MultiMeshInstance3D in shadow_nodes:

		shadow_node.visible = true

		shadow_node.cast_shadow = (
			GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY
		)


	var image_with_shadows: Image = (
		await _capture_viewport(
			bake_viewport
		)
	)


	# ========================================================
	# CAPTURE WITHOUT TREE SHADOWS
	# ========================================================

	print("Capturing WITHOUT tree shadows...")


	for shadow_node: MultiMeshInstance3D in shadow_nodes:

		shadow_node.cast_shadow = (
			GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		)


	var image_without_shadows: Image = (
		await _capture_viewport(
			bake_viewport
		)
	)


	# ========================================================
	# RESTORE EVERYTHING
	# ========================================================

	for state: Dictionary in tree_states:

		var tree_node: MultiMeshInstance3D = (
			state["node"]
			as MultiMeshInstance3D
		)

		tree_node.visible = bool(
			state["visible"]
		)


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


	for state: Dictionary in canopy_states:

		var canopy: Decal = (
			state["node"]
			as Decal
		)

		canopy.visible = bool(
			state["visible"]
		)


	sun.shadow_enabled = old_shadow_enabled

	sun.directional_shadow_max_distance = (
		old_shadow_distance
	)

	sun.directional_shadow_fade_start = (
		old_shadow_fade
	)

	sun.directional_shadow_mode = (
		old_shadow_mode
	)


	bake_camera.current = false

	bake_viewport.queue_free()


	# ========================================================
	# VALIDATE CAPTURES
	# ========================================================

	if (
		image_with_shadows == null
		or image_without_shadows == null
	):

		push_error(
			"BAKE: Capture failed."
		)

		_baking = false
		return


	if (
		image_with_shadows.is_empty()
		or image_without_shadows.is_empty()
	):

		push_error(
			"BAKE: Captured image is empty."
		)

		_baking = false
		return


	# ========================================================
	# BUILD SHADOW DIFFERENCE
	# ========================================================

	print("Building shadow mask...")


	var shadow_mask: Image = (
		_build_shadow_mask(
			image_with_shadows,
			image_without_shadows
		)
	)


	if shadow_mask == null:

		push_error(
			"BAKE: Could not build shadow mask."
		)

		_baking = false
		return


	# ========================================================
	# SAVE PNG
	# ========================================================

	var absolute_output_path: String = (
		ProjectSettings.globalize_path(
			output_png_path
		)
	)


	var save_error: Error = (
		shadow_mask.save_png(
			absolute_output_path
		)
	)


	if save_error != OK:

		push_error(
			"BAKE: PNG save failed. Error: "
			+ str(save_error)
			+ " | "
			+ absolute_output_path
		)

		_baking = false
		return


	print("")
	print("PNG CREATED:")
	print(absolute_output_path)


	# ========================================================
	# REFRESH EDITOR FILESYSTEM
	# ========================================================

	var editor_filesystem: EditorFileSystem = (
		EditorInterface.get_resource_filesystem()
	)

	editor_filesystem.scan()


	while (
		editor_filesystem.is_scanning()
		or editor_filesystem.is_importing()
	):

		await get_tree().process_frame


	# ========================================================
	# APPLY TO TERRAIN
	# ========================================================

	if auto_apply_to_terrain:

		var loaded_texture: Texture2D = (
			load(
				output_png_path
			) as Texture2D
		)


		if loaded_texture != null:

			_apply_shadow_to_terrain(
				terrain,
				loaded_texture,
				world_min,
				world_size
			)

		else:

			# Si el importer todavía no lo devuelve,
			# por lo menos mostramos inmediatamente
			# el bake con ImageTexture.
			var preview_texture: ImageTexture = (
				ImageTexture.create_from_image(
					shadow_mask
				)
			)

			_apply_shadow_to_terrain(
				terrain,
				preview_texture,
				world_min,
				world_size
			)


	print("")
	print("==========================================")
	print("TREE SHADOW BAKE FINISHED")
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

	# Godot recomienda esperar hasta que RenderingServer
	# haya terminado de dibujar antes de leer ViewportTexture.
	await RenderingServer.frame_post_draw

	var result: Image = (
		bake_viewport
		.get_texture()
		.get_image()
	)

	return result


# ============================================================
# BUILD MASK
# ============================================================

func _build_shadow_mask(
	with_shadows: Image,
	without_shadows: Image
) -> Image:

	if (
		with_shadows.get_size()
		!= without_shadows.get_size()
	):
		return null


	with_shadows.convert(
		Image.FORMAT_RGBA8
	)

	without_shadows.convert(
		Image.FORMAT_RGBA8
	)


	var width: int = (
		with_shadows.get_width()
	)

	var height: int = (
		with_shadows.get_height()
	)

	var pixel_count: int = (
		width * height
	)


	var with_data: PackedByteArray = (
		with_shadows.get_data()
	)

	var without_data: PackedByteArray = (
		without_shadows.get_data()
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
			) / 255.0
		)

		var with_g: float = (
			float(
				with_data[
					byte_index + 1
				]
			) / 255.0
		)

		var with_b: float = (
			float(
				with_data[
					byte_index + 2
				]
			) / 255.0
		)


		var without_r: float = (
			float(
				without_data[
					byte_index
				]
			) / 255.0
		)

		var without_g: float = (
			float(
				without_data[
					byte_index + 1
				]
			) / 255.0
		)

		var without_b: float = (
			float(
				without_data[
					byte_index + 2
				]
			) / 255.0
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


		# Ratio de luz perdido debido exclusivamente
		# a TreeShadows.
		var shadow_amount: float = (
			(lum_without - lum_with)
			/ maxf(
				lum_without,
				0.05
			)
		)


		shadow_amount = maxf(
			shadow_amount
			- mask_threshold,
			0.0
		)


		shadow_amount *= (
			mask_gain
		)


		shadow_amount = pow(
			clampf(
				shadow_amount,
				0.0,
				1.0
			),
			maxf(
				mask_gamma,
				0.001
			)
		)


		var shadow_byte: int = int(
			round(
				shadow_amount
				* 255.0
			)
		)


		output_data[
			byte_index
		] = shadow_byte

		output_data[
			byte_index + 1
		] = shadow_byte

		output_data[
			byte_index + 2
		] = shadow_byte

		output_data[
			byte_index + 3
		] = 255


	var result: Image = (
		Image.create_from_data(
			width,
			height,
			false,
			Image.FORMAT_RGBA8,
			output_data
		)
	)


	return result


# ============================================================
# APPLY TO TERRAIN
# ============================================================

func _apply_shadow_to_terrain(
	terrain: MeshInstance3D,
	shadow_texture: Texture2D,
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
			terrain.mesh.surface_get_material(
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
		material as ShaderMaterial
	)


	shader_material.set_shader_parameter(
		"use_baked_tree_shadows",
		true
	)

	shader_material.set_shader_parameter(
		"tree_shadow_map",
		shadow_texture
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
# FIND SCENE
# ============================================================

func _get_scene_root() -> Node:

	if get_tree().edited_scene_root != null:
		return get_tree().edited_scene_root

	if get_tree().current_scene != null:
		return get_tree().current_scene

	return null


# ============================================================
# FIND TERRAIN
# ============================================================

func _find_terrain(
	scene_root: Node
) -> MeshInstance3D:

	if terrain_mesh_path != NodePath(""):

		var selected: Node = (
			get_node_or_null(
				terrain_mesh_path
			)
		)

		if selected is MeshInstance3D:
			return (
				selected as MeshInstance3D
			)


	var found: Node = (
		_find_node_by_name_recursive(
			scene_root,
			"Terrain_Master_VIS"
		)
	)

	if found is MeshInstance3D:
		return (
			found as MeshInstance3D
		)

	return null


# ============================================================
# FIND SUN
# ============================================================

func _find_sun(
	scene_root: Node
) -> DirectionalLight3D:

	if sun_light_path != NodePath(""):

		var selected: Node = (
			get_node_or_null(
				sun_light_path
			)
		)

		if selected is DirectionalLight3D:
			return (
				selected as DirectionalLight3D
			)


	return (
		_find_directional_light_recursive(
			scene_root
		)
	)


# ============================================================
# COLLECT FOREST NODES
# ============================================================

func _collect_forest_nodes(
	node: Node,
	trees: Array[MultiMeshInstance3D],
	shadows: Array[MultiMeshInstance3D],
	canopies: Array[Decal]
) -> void:

	if node is MultiMeshInstance3D:

		var multimesh_node: MultiMeshInstance3D = (
			node as MultiMeshInstance3D
		)


		if node.name == "Trees":

			trees.append(
				multimesh_node
			)


		elif node.name == "TreeShadows":

			shadows.append(
				multimesh_node
			)


	elif node is Decal:

		if node.name == "CanopyAmbientShadow":

			canopies.append(
				node as Decal
			)


	for child: Node in node.get_children():

		_collect_forest_nodes(
			child,
			trees,
			shadows,
			canopies
		)


# ============================================================
# RECURSIVE FINDERS
# ============================================================

func _find_node_by_name_recursive(
	node: Node,
	target_name: String
) -> Node:

	if node.name == target_name:
		return node


	for child: Node in node.get_children():

		var result: Node = (
			_find_node_by_name_recursive(
				child,
				target_name
			)
		)

		if result != null:
			return result


	return null


func _find_directional_light_recursive(
	node: Node
) -> DirectionalLight3D:

	if node is DirectionalLight3D:

		return (
			node as DirectionalLight3D
		)


	for child: Node in node.get_children():

		var result: DirectionalLight3D = (
			_find_directional_light_recursive(
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


	var world_min: Vector3 = first_world
	var world_max: Vector3 = first_world


	for index: int in range(
		1,
		corners.size()
	):

		var world_point: Vector3 = (
			mesh_instance.global_transform
			* corners[index]
		)


		world_min = Vector3(
			minf(
				world_min.x,
				world_point.x
			),

			minf(
				world_min.y,
				world_point.y
			),

			minf(
				world_min.z,
				world_point.z
			)
		)


		world_max = Vector3(
			maxf(
				world_max.x,
				world_point.x
			),

			maxf(
				world_max.y,
				world_point.y
			),

			maxf(
				world_max.z,
				world_point.z
			)
		)


	return AABB(
		world_min,
		world_max - world_min
	)
