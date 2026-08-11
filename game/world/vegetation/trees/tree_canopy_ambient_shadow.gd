@tool
extends Decal


# ============================================================
# SOURCE
# ============================================================

@export_group("Source")

# MultiMeshInstance3D que contiene los árboles.
# Si el Decal es hermano de Trees, esta ruta ya es correcta.
@export_node_path("MultiMeshInstance3D")
var trees_path: NodePath = NodePath("../Trees")


# ============================================================
# AMBIENT SHADOW
# ============================================================

@export_group("Ambient Shadow")

@export var ambient_shadow_enabled: bool = true


# Color de la sombra ambiental.
#
# No buscamos negro puro.
# Queremos simplemente ensuciar/oscurecer el suelo.
@export var shadow_color: Color = Color(
	0.045,
	0.038,
	0.025,
	1.0
)


# Fuerza global del oscurecimiento.
@export_range(0.0, 1.0, 0.01)
var shadow_strength: float = 0.55


# Cuánto aporta cada árbol individualmente.
#
# Cuando varios árboles se solapan,
# la densidad aumenta automáticamente.
@export_range(0.01, 1.0, 0.01)
var per_tree_density: float = 0.16


# Radio aproximado de sombra de cada copa.
#
# 1.0 = aproximadamente el semiancho visual del árbol.
# >1.0 hace que las sombras de árboles cercanos
# se unan formando una masa.
@export_range(0.1, 3.0, 0.05)
var canopy_radius_factor: float = 1.25


# Metros adicionales alrededor de cada copa.
@export_range(0.0, 10.0, 0.1)
var canopy_extra_radius: float = 1.5


# Forma de caída desde el centro de cada copa.
#
# Bajo = sombra ancha y suave.
# Alto = más concentrada.
@export_range(0.25, 5.0, 0.05)
var canopy_falloff_power: float = 1.25


# Modifica cómo responde la sombra a la densidad.
#
# < 1.0 expande las zonas oscuras.
# > 1.0 concentra las zonas oscuras.
@export_range(0.25, 3.0, 0.05)
var density_gamma: float = 0.75


# ============================================================
# TEXTURE
# ============================================================

@export_group("Texture")

# 256 debería bastar para la mayoría de bosques.
#
# Usa 512 solo si la mancha cubre un área enorme
# y necesitas más detalle.
@export_range(64, 1024, 64)
var texture_resolution: int = 256


# Suavizado final de toda la masa.
@export_range(0, 16, 1)
var blur_radius_pixels: int = 4


@export_range(0, 4, 1)
var blur_passes: int = 2


# Margen alrededor de todos los árboles.
@export_range(0.0, 30.0, 0.5)
var world_padding: float = 3.0


# Si la textura aparece invertida respecto a Z,
# basta con cambiar esto.
@export var flip_texture_z: bool = true


# ============================================================
# DECAL PROJECTION
# ============================================================

@export_group("Projection")

# Margen vertical por encima y debajo
# de las alturas reales del terreno.
@export_range(0.1, 50.0, 0.5)
var vertical_margin: float = 3.0


# Evita en gran medida que la sombra se pinte
# sobre paredes casi verticales.
@export_range(0.0, 1.0, 0.01)
var surface_normal_fade: float = 0.55


# ============================================================
# EDITOR
# ============================================================

@export_group("Editor")

@export var auto_sync_in_editor: bool = true

@export_range(0.1, 5.0, 0.1)
var editor_check_interval: float = 0.75


@export_tool_button("Rebuild Ambient Shadow")
var rebuild_shadow = rebuild_from_trees


@export_tool_button("Clear Ambient Shadow")
var clear_shadow_button = clear_shadow


# ============================================================
# INTERNAL
# ============================================================

var _generated_texture: ImageTexture = null

var _editor_elapsed: float = 0.0
var _last_tree_signature: String = ""
var _rebuild_queued: bool = false


# ============================================================
# READY
# ============================================================

func _ready() -> void:

	visible = ambient_shadow_enabled

	# El Trees actual genera su MultiMesh automáticamente.
	# Esperamos dos deferred para asegurarnos de que
	# sus transforms ya existen.
	call_deferred(
		"_queue_initial_rebuild"
	)

	set_process(
		Engine.is_editor_hint()
		and auto_sync_in_editor
	)


func _queue_initial_rebuild() -> void:

	call_deferred(
		"rebuild_from_trees"
	)


# ============================================================
# EDITOR AUTO SYNC
# ============================================================

func _process(delta: float) -> void:

	if not Engine.is_editor_hint():
		return

	if not auto_sync_in_editor:
		return


	_editor_elapsed += delta


	if _editor_elapsed < editor_check_interval:
		return


	_editor_elapsed = 0.0


	var trees: MultiMeshInstance3D = _get_trees()

	if trees == null:
		return


	var new_signature: String = _build_tree_signature(
		trees
	)


	if new_signature == _last_tree_signature:
		return


	if _rebuild_queued:
		return


	_rebuild_queued = true

	call_deferred(
		"_perform_queued_rebuild"
	)


func _perform_queued_rebuild() -> void:

	_rebuild_queued = false

	rebuild_from_trees()


# ============================================================
# REBUILD
# ============================================================

func rebuild_from_trees() -> void:

	visible = ambient_shadow_enabled


	if not ambient_shadow_enabled:

		clear_shadow()

		return


	var trees: MultiMeshInstance3D = _get_trees()


	if trees == null:

		push_warning(
			"CanopyAmbientShadow: Trees node not found."
		)

		clear_shadow()

		return


	var tree_multimesh: MultiMesh = trees.multimesh


	if tree_multimesh == null:

		clear_shadow()

		return


	var tree_count: int = _get_visible_tree_count(
		tree_multimesh
	)


	if tree_count <= 0:

		clear_shadow()

		return


	# ========================================================
	# COLLECT REAL TREE DATA
	#
	# Vector4:
	#
	# x = world X
	# y = world Z
	# z = canopy radius
	# w = ground Y
	# ========================================================

	var tree_data: Array[Vector4] = []


	var min_x: float = INF
	var max_x: float = -INF

	var min_z: float = INF
	var max_z: float = -INF

	var min_ground_y: float = INF
	var max_ground_y: float = -INF


	for index: int in range(
		tree_count
	):

		var instance_transform: Transform3D = (
			tree_multimesh.get_instance_transform(
				index
			)
		)


		# ----------------------------------------------------
		# INSTANCE CENTER IN WORLD SPACE
		# ----------------------------------------------------

		var center_world: Vector3 = (
			trees.global_transform
			* instance_transform.origin
		)


		# ----------------------------------------------------
		# REAL WORLD INSTANCE SCALE
		#
		# Quad = 2 x 2.
		#
		# Therefore basis axis length corresponds
		# approximately to half its final width/height.
		# ----------------------------------------------------

		var world_x_axis: Vector3 = (
			trees.global_transform.basis
			* instance_transform.basis.x
		)

		var world_y_axis: Vector3 = (
			trees.global_transform.basis
			* instance_transform.basis.y
		)


		var half_width_world: float = maxf(
			world_x_axis.length(),
			0.01
		)

		var half_height_world: float = maxf(
			world_y_axis.length(),
			0.01
		)


		# ----------------------------------------------------
		# CANOPY SHADOW RADIUS
		# ----------------------------------------------------

		var canopy_radius: float = maxf(
			half_width_world
				* canopy_radius_factor
				+ canopy_extra_radius,
			0.1
		)


		# ----------------------------------------------------
		# GROUND HEIGHT
		#
		# Tree center is half its height above the ground.
		# ----------------------------------------------------

		var ground_y: float = (
			center_world.y
			- half_height_world
		)


		tree_data.append(
			Vector4(
				center_world.x,
				center_world.z,
				canopy_radius,
				ground_y
			)
		)


		min_x = minf(
			min_x,
			center_world.x
				- canopy_radius
		)

		max_x = maxf(
			max_x,
			center_world.x
				+ canopy_radius
		)


		min_z = minf(
			min_z,
			center_world.z
				- canopy_radius
		)

		max_z = maxf(
			max_z,
			center_world.z
				+ canopy_radius
		)


		min_ground_y = minf(
			min_ground_y,
			ground_y
		)

		max_ground_y = maxf(
			max_ground_y,
			ground_y
		)


	# ========================================================
	# WORLD BOUNDS
	# ========================================================

	min_x -= world_padding
	max_x += world_padding

	min_z -= world_padding
	max_z += world_padding


	var world_width: float = maxf(
		max_x - min_x,
		0.1
	)

	var world_depth: float = maxf(
		max_z - min_z,
		0.1
	)


	var center_x: float = (
		min_x + max_x
	) * 0.5

	var center_z: float = (
		min_z + max_z
	) * 0.5


	var vertical_span: float = maxf(
		max_ground_y - min_ground_y,
		0.1
	)


	var decal_height: float = (
		vertical_span
		+ vertical_margin * 2.0
	)


	var decal_center_y: float = (
		min_ground_y
		+ max_ground_y
	) * 0.5


	# ========================================================
	# DECAL TRANSFORM
	#
	# Identity world basis means projection stays
	# straight downward along world Y.
	# ========================================================

	global_transform = Transform3D(
		Basis.IDENTITY,
		Vector3(
			center_x,
			decal_center_y,
			center_z
		)
	)


	size = Vector3(
		world_width,
		maxf(
			decal_height,
			0.1
		),
		world_depth
	)


	# No vertical intensity fade.
	upper_fade = 0.0
	lower_fade = 0.0

	normal_fade = surface_normal_fade

	albedo_mix = 1.0

	modulate = Color.WHITE


	# ========================================================
	# TEXTURE RESOLUTION
	# ========================================================

	var resolution: int = maxi(
		texture_resolution,
		32
	)


	var pixel_count: int = (
		resolution
		* resolution
	)


	var density: PackedFloat32Array = (
		PackedFloat32Array()
	)

	density.resize(
		pixel_count
	)

	density.fill(
		0.0
	)


	# ========================================================
	# DRAW EVERY TREE INTO THE DENSITY MAP
	# ========================================================

	for tree: Vector4 in tree_data:

		var normalized_x: float = (
			(tree.x - min_x)
			/ world_width
		)

		var normalized_z: float = (
			(tree.y - min_z)
			/ world_depth
		)


		if flip_texture_z:

			normalized_z = (
				1.0
				- normalized_z
			)


		var center_px_x: float = (
			normalized_x
			* float(
				resolution - 1
			)
		)

		var center_px_y: float = (
			normalized_z
			* float(
				resolution - 1
			)
		)


		var radius_px_x: float = maxf(
			tree.z
				/ world_width
				* float(resolution),
			1.0
		)

		var radius_px_y: float = maxf(
			tree.z
				/ world_depth
				* float(resolution),
			1.0
		)


		_paint_canopy_blob(
			density,
			resolution,
			center_px_x,
			center_px_y,
			radius_px_x,
			radius_px_y
		)


	# ========================================================
	# BLUR
	# ========================================================

	var safe_blur_radius: int = maxi(
		blur_radius_pixels,
		0
	)

	var safe_blur_passes: int = maxi(
		blur_passes,
		0
	)


	if (
		safe_blur_radius > 0
		and safe_blur_passes > 0
	):

		for blur_pass: int in range(
			safe_blur_passes
		):

			density = _blur_density(
				density,
				resolution,
				safe_blur_radius
			)


	# ========================================================
	# BUILD RGBA TEXTURE
	# ========================================================

	var image_data: PackedByteArray = (
		PackedByteArray()
	)


	image_data.resize(
		pixel_count * 4
	)


	var red_byte: int = int(
		clampf(
			shadow_color.r,
			0.0,
			1.0
		) * 255.0
	)

	var green_byte: int = int(
		clampf(
			shadow_color.g,
			0.0,
			1.0
		) * 255.0
	)

	var blue_byte: int = int(
		clampf(
			shadow_color.b,
			0.0,
			1.0
		) * 255.0
	)


	for pixel_index: int in range(
		pixel_count
	):

		var raw_density: float = clampf(
			density[pixel_index],
			0.0,
			1.0
		)


		var corrected_density: float = pow(
			raw_density,
			maxf(
				density_gamma,
				0.001
			)
		)


		var final_alpha: float = clampf(
			corrected_density
				* shadow_strength,
			0.0,
			1.0
		)


		var byte_index: int = (
			pixel_index * 4
		)


		image_data[
			byte_index
		] = red_byte

		image_data[
			byte_index + 1
		] = green_byte

		image_data[
			byte_index + 2
		] = blue_byte

		image_data[
			byte_index + 3
		] = int(
			final_alpha
			* 255.0
		)


	# ========================================================
	# IMAGE -> TEXTURE
	# ========================================================

	var image: Image = Image.create_from_data(
		resolution,
		resolution,
		false,
		Image.FORMAT_RGBA8,
		image_data
	)


	_generated_texture = (
		ImageTexture.create_from_image(
			image
		)
	)


	texture_albedo = (
		_generated_texture
	)


	visible = true


	_last_tree_signature = (
		_build_tree_signature(
			trees
		)
	)


	print(
		"Canopy ambient shadow | trees: ",
		tree_count,
		" | texture: ",
		resolution,
		"x",
		resolution,
		" | size: ",
		Vector2(
			world_width,
			world_depth
		)
	)


# ============================================================
# PAINT ONE TREE
# ============================================================

func _paint_canopy_blob(
	density: PackedFloat32Array,
	resolution: int,
	center_x: float,
	center_y: float,
	radius_x: float,
	radius_y: float
) -> void:

	var min_pixel_x: int = maxi(
		0,
		int(
			floor(
				center_x
				- radius_x
			)
		)
	)

	var max_pixel_x: int = mini(
		resolution - 1,
		int(
			ceil(
				center_x
				+ radius_x
			)
		)
	)


	var min_pixel_y: int = maxi(
		0,
		int(
			floor(
				center_y
				- radius_y
			)
		)
	)

	var max_pixel_y: int = mini(
		resolution - 1,
		int(
			ceil(
				center_y
				+ radius_y
			)
		)
	)


	for pixel_y: int in range(
		min_pixel_y,
		max_pixel_y + 1
	):

		var dy: float = (
			(float(pixel_y) - center_y)
			/ radius_y
		)


		for pixel_x: int in range(
			min_pixel_x,
			max_pixel_x + 1
		):

			var dx: float = (
				(float(pixel_x) - center_x)
				/ radius_x
			)


			var distance_squared: float = (
				dx * dx
				+ dy * dy
			)


			if distance_squared > 1.0:
				continue


			var distance: float = sqrt(
				distance_squared
			)


			var falloff: float = pow(
				maxf(
					1.0 - distance,
					0.0
				),
				canopy_falloff_power
			)


			var contribution: float = clampf(
				per_tree_density
					* falloff,
				0.0,
				0.95
			)


			var density_index: int = (
				pixel_y
					* resolution
				+ pixel_x
			)


			var old_density: float = (
				density[
					density_index
				]
			)


			# Alpha-style accumulation.
			#
			# More overlapping trees =
			# progressively darker shadow.
			density[
				density_index
			] = (
				1.0
				- (
					1.0
						- old_density
				)
				* (
					1.0
						- contribution
				)
			)


# ============================================================
# BLUR
# ============================================================

func _blur_density(
	source: PackedFloat32Array,
	resolution: int,
	radius: int
) -> PackedFloat32Array:

	if radius <= 0:
		return source


	var horizontal: PackedFloat32Array = (
		PackedFloat32Array()
	)

	horizontal.resize(
		source.size()
	)


	var output: PackedFloat32Array = (
		PackedFloat32Array()
	)

	output.resize(
		source.size()
	)


	# --------------------------------------------------------
	# HORIZONTAL
	# --------------------------------------------------------

	for y: int in range(
		resolution
	):

		for x: int in range(
			resolution
		):

			var sum: float = 0.0
			var sample_count: int = 0


			for offset: int in range(
				-radius,
				radius + 1
			):

				var sample_x: int = (
					x + offset
				)


				if (
					sample_x < 0
					or sample_x >= resolution
				):
					continue


				var source_index: int = (
					y
						* resolution
					+ sample_x
				)


				sum += source[
					source_index
				]

				sample_count += 1


			var destination_index: int = (
				y
					* resolution
				+ x
			)


			horizontal[
				destination_index
			] = (
				sum
				/ float(
					maxi(
						sample_count,
						1
					)
				)
			)


	# --------------------------------------------------------
	# VERTICAL
	# --------------------------------------------------------

	for y: int in range(
		resolution
	):

		for x: int in range(
			resolution
		):

			var sum: float = 0.0
			var sample_count: int = 0


			for offset: int in range(
				-radius,
				radius + 1
			):

				var sample_y: int = (
					y + offset
				)


				if (
					sample_y < 0
					or sample_y >= resolution
				):
					continue


				var source_index: int = (
					sample_y
						* resolution
					+ x
				)


				sum += horizontal[
					source_index
				]

				sample_count += 1


			var destination_index: int = (
				y
					* resolution
				+ x
			)


			output[
				destination_index
			] = (
				sum
				/ float(
					maxi(
						sample_count,
						1
					)
				)
			)


	return output


# ============================================================
# TREE ACCESS
# ============================================================

func _get_trees() -> MultiMeshInstance3D:

	if trees_path == NodePath(""):
		return null


	var node: Node = get_node_or_null(
		trees_path
	)


	if node is MultiMeshInstance3D:

		return (
			node
			as MultiMeshInstance3D
		)


	return null


func _get_visible_tree_count(
	tree_multimesh: MultiMesh
) -> int:

	var visible_count: int = (
		tree_multimesh.visible_instance_count
	)


	if visible_count < 0:

		visible_count = (
			tree_multimesh.instance_count
		)


	return mini(
		visible_count,
		tree_multimesh.instance_count
	)


# ============================================================
# EDITOR CHANGE DETECTION
# ============================================================

func _build_tree_signature(
	trees: MultiMeshInstance3D
) -> String:

	if trees.multimesh == null:
		return "no_multimesh"


	var tree_multimesh: MultiMesh = (
		trees.multimesh
	)


	var count: int = _get_visible_tree_count(
		tree_multimesh
	)


	if count <= 0:
		return "0"


	var first_index: int = 0

	var middle_index: int = int(
		float(count) * 0.5
	)

	var last_index: int = (
		count - 1
	)


	var first_transform: Transform3D = (
		tree_multimesh.get_instance_transform(
			first_index
		)
	)

	var middle_transform: Transform3D = (
		tree_multimesh.get_instance_transform(
			middle_index
		)
	)

	var last_transform: Transform3D = (
		tree_multimesh.get_instance_transform(
			last_index
		)
	)


	return (
		str(count)
		+ "|"
		+ str(
			first_transform.origin
		)
		+ "|"
		+ str(
			middle_transform.origin
		)
		+ "|"
		+ str(
			last_transform.origin
		)
		+ "|"
		+ str(
			first_transform.basis.get_scale()
		)
		+ "|"
		+ str(
			last_transform.basis.get_scale()
		)
	)


# ============================================================
# CLEAR
# ============================================================

func clear_shadow() -> void:

	texture_albedo = null

	_generated_texture = null

	visible = false

	_last_tree_signature = ""


# ============================================================
# EDITOR SAVE
#
# Do not serialize the dynamically generated 256x256/512x512
# texture into the .tscn.
# ============================================================

func _notification(
	what: int
) -> void:

	if not Engine.is_editor_hint():
		return


	if what == NOTIFICATION_EDITOR_PRE_SAVE:

		_clear_generated_texture_only()


	elif what == NOTIFICATION_EDITOR_POST_SAVE:

		call_deferred(
			"_queue_initial_rebuild"
		)


func _clear_generated_texture_only() -> void:

	texture_albedo = null

	_generated_texture = null
