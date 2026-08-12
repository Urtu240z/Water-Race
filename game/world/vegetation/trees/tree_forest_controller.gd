@tool
extends Node3D


# ============================================================
# CONSTANTS
# ============================================================

const TREES_NODE_PATH: NodePath = NodePath("Trees")
const SHADOWS_NODE_PATH: NodePath = NodePath("TreeShadows")
const CANOPY_NODE_PATH: NodePath = NodePath("CanopyAmbientShadow")

const DEFAULT_SHADOW_MATERIAL: Material = preload(
	"res://world/vegetation/trees/materials/tree_impostor_shadow_material.tres"
)


# ============================================================
# TREES - GENERAL
# ============================================================

@export_group("Trees")

@export var trees_enabled: bool = true


# ============================================================
# TREES - DISTRIBUTION
# ============================================================

@export_subgroup("Distribution")

@export_range(1, 5000, 1)
var target_count: int = 625

@export_range(5.0, 1000.0, 1.0)
var area_radius_x: float = 100.0

@export_range(5.0, 1000.0, 1.0)
var area_radius_z: float = 80.0

# Tus valores actuales.
@export_range(0.1, 50.0, 0.05)
var min_spacing: float = 0.25

@export_range(0.1, 50.0, 0.05)
var max_spacing: float = 2.35

@export_range(4, 64, 1)
var poisson_attempts_per_point: int = 24

@export_range(1.0, 5.0, 0.1)
var candidate_pool_multiplier: float = 2.0

@export var random_seed: int = 12345


# ============================================================
# TREES - SCALE
# ============================================================

@export_subgroup("Scale")

# Tus valores actuales.
@export_range(0.1, 20.0, 0.05)
var min_scale: float = 4.0

@export_range(0.1, 20.0, 0.05)
var max_scale: float = 10.0

@export_range(0.0, 100.0, 1.0)
var center_scale_bias_percent: float = 66.0


# ============================================================
# TREES - GROUND
# ============================================================

@export_subgroup("Ground Placement")

@export var snap_to_ground: bool = true

@export_range(1.0, 500.0, 1.0)
var ray_above_height: float = 100.0

@export_range(1.0, 1000.0, 1.0)
var ray_below_depth: float = 300.0

@export_flags_3d_physics
var ground_collision_mask: int = 0xFFFFFFFF

@export var valid_ground_name_contains: PackedStringArray = PackedStringArray([
	"Terrain_Master_COL"
])


# ============================================================
# TREES - SLOPE
# ============================================================

@export_subgroup("Slope Filter")

@export var reject_steep_slopes: bool = true

@export_range(0.0, 89.0, 1.0)
var max_ground_slope_degrees: float = 40.0


# ============================================================
# TREES - VISUAL EXCLUSION
# ============================================================

@export_subgroup("Visual Geometry Exclusion")

@export var avoid_visual_geometry: bool = true

# Estos NodePath se seleccionan DESDE EL ROOT.
#
# El controlador los convierte automáticamente
# a rutas relativas válidas para Trees.
@export var visual_exclusion_roots: Array[NodePath] = []

@export_range(0.10, 1.50, 0.05)
var visual_radius_factor: float = 0.80

@export_range(0.0, 10.0, 0.1)
var visual_extra_clearance: float = 1.0


# ============================================================
# TREES - WATER
# ============================================================

@export_subgroup("Water Exclusion")

@export var avoid_water: bool = true

# También se selecciona DESDE EL ROOT.
@export var water_provider_path: NodePath

@export_range(0.0, 20.0, 0.1)
var minimum_height_above_water: float = 1.0


# ============================================================
# TREE SHADOWS
# ============================================================

@export_group("Tree Shadows")

@export var tree_shadows_enabled: bool = true

@export var shadow_material_override: Material = (
	DEFAULT_SHADOW_MATERIAL
)


# ============================================================
# CANOPY AMBIENT SHADOW
# ============================================================

@export_group("Canopy Ambient Shadow")

@export var canopy_enabled: bool = true


# ============================================================
# CANOPY - AMBIENT
# ============================================================

@export_subgroup("Ambient Shadow")

@export var canopy_shadow_color: Color = Color(
	0.045,
	0.038,
	0.025,
	1.0
)

@export_range(0.0, 1.0, 0.01)
var canopy_shadow_strength: float = 0.55

@export_range(0.01, 1.0, 0.01)
var canopy_per_tree_density: float = 0.16

@export_range(0.1, 3.0, 0.05)
var canopy_radius_factor: float = 1.25

@export_range(0.0, 10.0, 0.1)
var canopy_extra_radius: float = 1.5

@export_range(0.25, 5.0, 0.05)
var canopy_falloff_power: float = 1.25

@export_range(0.25, 3.0, 0.05)
var canopy_density_gamma: float = 0.75


# ============================================================
# CANOPY - TEXTURE
# ============================================================

@export_subgroup("Texture")

@export_range(64, 1024, 64)
var canopy_texture_resolution: int = 256

@export_range(0, 16, 1)
var canopy_blur_radius_pixels: int = 4

@export_range(0, 4, 1)
var canopy_blur_passes: int = 2

@export_range(0.0, 30.0, 0.5)
var canopy_world_padding: float = 3.0

@export var canopy_flip_texture_z: bool = true


# ============================================================
# CANOPY - PROJECTION
# ============================================================

@export_subgroup("Projection")

@export_range(0.1, 50.0, 0.5)
var canopy_vertical_margin: float = 3.0

@export_range(0.0, 1.0, 0.01)
var canopy_surface_normal_fade: float = 0.55


# ============================================================
# ROOT EDITOR
# ============================================================

@export_group("Editor")

# Si está activo, al cambiar parámetros en el root
# los hijos se actualizan automáticamente.
@export var auto_apply_in_editor: bool = true

@export_range(0.1, 2.0, 0.1)
var editor_update_interval: float = 0.35


@export_tool_button("Regenerate Forest")
var regenerate_forest_button = regenerate_forest


@export_tool_button("Rebuild Canopy")
var rebuild_canopy_button = rebuild_canopy


# ============================================================
# INTERNAL
# ============================================================

var _editor_elapsed: float = 0.0

var _last_tree_signature: String = ""
var _last_shadow_signature: String = ""
var _last_canopy_signature: String = ""

var _editor_rebuild_queued: bool = false


# ============================================================
# ENTER TREE
# ============================================================

func _enter_tree() -> void:

	# Parent entra en el árbol antes que sus hijos.
	#
	# Aplicamos aquí los parámetros para que Trees y Canopy
	# ya tengan los valores correctos cuando ejecuten _ready().
	_apply_tree_properties(
		false
	)

	_apply_shadow_properties()

	_apply_canopy_properties(
		false
	)


# ============================================================
# READY
# ============================================================

func _ready() -> void:

	# Segunda aplicación para asegurar NodePaths hacia nodos
	# externos a esta escena.
	_apply_tree_properties(
		false
	)

	_apply_shadow_properties()

	_apply_canopy_properties(
		false
	)

	_capture_signatures()

	set_process(
		Engine.is_editor_hint()
	)


# ============================================================
# EDITOR AUTO UPDATE
# ============================================================

func _process(delta: float) -> void:

	if not Engine.is_editor_hint():
		return

	if not auto_apply_in_editor:
		return


	_editor_elapsed += delta


	if _editor_elapsed < editor_update_interval:
		return


	_editor_elapsed = 0.0


	var new_tree_signature: String = (
		_build_tree_signature()
	)

	var new_shadow_signature: String = (
		_build_shadow_signature()
	)

	var new_canopy_signature: String = (
		_build_canopy_signature()
	)


	var trees_changed: bool = (
		new_tree_signature
		!= _last_tree_signature
	)

	var shadows_changed: bool = (
		new_shadow_signature
		!= _last_shadow_signature
	)

	var canopy_changed: bool = (
		new_canopy_signature
		!= _last_canopy_signature
	)


	if trees_changed:

		_queue_full_editor_rebuild()

		return


	if shadows_changed:

		_apply_shadow_properties()

		_last_shadow_signature = (
			new_shadow_signature
		)


	if canopy_changed:

		_apply_canopy_properties(
			true
		)

		_last_canopy_signature = (
			new_canopy_signature
		)


# ============================================================
# PUBLIC - REGENERATE EVERYTHING
# ============================================================

func regenerate_forest() -> void:

	_apply_tree_properties(
		true
	)

	_apply_shadow_properties()

	_apply_canopy_properties(
		false
	)

	_sync_shadow_multimesh()

	call_deferred(
		"_deferred_rebuild_canopy"
	)

	_capture_signatures()


# ============================================================
# PUBLIC - CANOPY ONLY
# ============================================================

func rebuild_canopy() -> void:

	_apply_canopy_properties(
		true
	)

	_last_canopy_signature = (
		_build_canopy_signature()
	)


# ============================================================
# EDITOR QUEUE
# ============================================================

func _queue_full_editor_rebuild() -> void:

	if _editor_rebuild_queued:
		return


	_editor_rebuild_queued = true

	call_deferred(
		"_perform_full_editor_rebuild"
	)


func _perform_full_editor_rebuild() -> void:

	_editor_rebuild_queued = false

	regenerate_forest()


# ============================================================
# APPLY TREES
# ============================================================

func _apply_tree_properties(
	regenerate: bool
) -> void:

	var trees: MultiMeshInstance3D = (
		_get_trees()
	)


	if trees == null:
		return


	# --------------------------------------------------------
	# NODE
	# --------------------------------------------------------

	trees.visible = trees_enabled

	# Layer 2.
	#
	# Así el Decal del canopy, que usa Cull Mask 1,
	# nunca oscurece los árboles.
	trees.layers = 2


	# TreeShadows se encarga de las sombras.
	trees.cast_shadow = (
		GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	)


	# --------------------------------------------------------
	# DISTRIBUTION
	# --------------------------------------------------------

	trees.set(
		"target_count",
		target_count
	)

	trees.set(
		"area_radius_x",
		area_radius_x
	)

	trees.set(
		"area_radius_z",
		area_radius_z
	)

	trees.set(
		"min_spacing",
		min_spacing
	)

	trees.set(
		"max_spacing",
		max_spacing
	)

	trees.set(
		"poisson_attempts_per_point",
		poisson_attempts_per_point
	)

	trees.set(
		"candidate_pool_multiplier",
		candidate_pool_multiplier
	)

	trees.set(
		"random_seed",
		random_seed
	)


	# --------------------------------------------------------
	# SCALE
	# --------------------------------------------------------

	trees.set(
		"min_scale",
		min_scale
	)

	trees.set(
		"max_scale",
		max_scale
	)

	trees.set(
		"center_scale_bias_percent",
		center_scale_bias_percent
	)


	# --------------------------------------------------------
	# GROUND
	# --------------------------------------------------------

	trees.set(
		"snap_to_ground",
		snap_to_ground
	)

	trees.set(
		"ray_above_height",
		ray_above_height
	)

	trees.set(
		"ray_below_depth",
		ray_below_depth
	)

	trees.set(
		"ground_collision_mask",
		ground_collision_mask
	)

	trees.set(
		"valid_ground_name_contains",
		valid_ground_name_contains
	)


	# --------------------------------------------------------
	# SLOPE
	# --------------------------------------------------------

	trees.set(
		"reject_steep_slopes",
		reject_steep_slopes
	)

	trees.set(
		"max_ground_slope_degrees",
		max_ground_slope_degrees
	)


	# --------------------------------------------------------
	# VISUAL GEOMETRY
	# --------------------------------------------------------

	trees.set(
		"avoid_visual_geometry",
		avoid_visual_geometry
	)

	trees.set(
		"visual_exclusion_roots",
		_convert_paths_for_child(
			trees,
			visual_exclusion_roots
		)
	)

	trees.set(
		"visual_radius_factor",
		visual_radius_factor
	)

	trees.set(
		"visual_extra_clearance",
		visual_extra_clearance
	)


	# --------------------------------------------------------
	# WATER
	# --------------------------------------------------------

	trees.set(
		"avoid_water",
		avoid_water
	)

	trees.set(
		"water_provider_path",
		_convert_path_for_child(
			trees,
			water_provider_path
		)
	)

	trees.set(
		"minimum_height_above_water",
		minimum_height_above_water
	)


	# --------------------------------------------------------
	# GENERATE
	# --------------------------------------------------------

	if regenerate:

		if trees.has_method(
			"_generate"
		):

			trees.call(
				"_generate"
			)


# ============================================================
# APPLY TREE SHADOWS
# ============================================================

func _apply_shadow_properties() -> void:

	var trees: MultiMeshInstance3D = (
		_get_trees()
	)

	var tree_shadows: MultiMeshInstance3D = (
		_get_tree_shadows()
	)


	if tree_shadows == null:
		return


	tree_shadows.visible = (
		tree_shadows_enabled
	)


	if tree_shadows_enabled:

		tree_shadows.cast_shadow = (
			GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY
		)

	else:

		tree_shadows.cast_shadow = (
			GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		)


	tree_shadows.material_override = (
		shadow_material_override
	)


	# Importantísimo:
	# el mismo recurso MultiMesh que Trees.
	if (
		trees != null
		and trees.multimesh != null
	):

		tree_shadows.multimesh = (
			trees.multimesh
		)


# ============================================================
# SYNC SHADOW MULTIMESH
# ============================================================

func _sync_shadow_multimesh() -> void:

	var trees: MultiMeshInstance3D = (
		_get_trees()
	)

	var tree_shadows: MultiMeshInstance3D = (
		_get_tree_shadows()
	)


	if (
		trees == null
		or tree_shadows == null
	):
		return


	tree_shadows.multimesh = (
		trees.multimesh
	)


# ============================================================
# APPLY CANOPY
# ============================================================

func _apply_canopy_properties(
	rebuild: bool
) -> void:

	var canopy: Decal = (
		_get_canopy()
	)


	if canopy == null:
		return


	# --------------------------------------------------------
	# DECAL NODE
	# --------------------------------------------------------

	# SOLO terrain visual layer 1.
	canopy.cull_mask = 1


	# --------------------------------------------------------
	# SOURCE
	# --------------------------------------------------------

	canopy.set(
		"trees_path",
		NodePath("../Trees")
	)


	# --------------------------------------------------------
	# AMBIENT
	# --------------------------------------------------------

	canopy.set(
		"ambient_shadow_enabled",
		canopy_enabled
	)

	canopy.set(
		"shadow_color",
		canopy_shadow_color
	)

	canopy.set(
		"shadow_strength",
		canopy_shadow_strength
	)

	canopy.set(
		"per_tree_density",
		canopy_per_tree_density
	)

	canopy.set(
		"canopy_radius_factor",
		canopy_radius_factor
	)

	canopy.set(
		"canopy_extra_radius",
		canopy_extra_radius
	)

	canopy.set(
		"canopy_falloff_power",
		canopy_falloff_power
	)

	canopy.set(
		"density_gamma",
		canopy_density_gamma
	)


	# --------------------------------------------------------
	# TEXTURE
	# --------------------------------------------------------

	canopy.set(
		"texture_resolution",
		canopy_texture_resolution
	)

	canopy.set(
		"blur_radius_pixels",
		canopy_blur_radius_pixels
	)

	canopy.set(
		"blur_passes",
		canopy_blur_passes
	)

	canopy.set(
		"world_padding",
		canopy_world_padding
	)

	canopy.set(
		"flip_texture_z",
		canopy_flip_texture_z
	)


	# --------------------------------------------------------
	# PROJECTION
	# --------------------------------------------------------

	canopy.set(
		"vertical_margin",
		canopy_vertical_margin
	)

	canopy.set(
		"surface_normal_fade",
		canopy_surface_normal_fade
	)


	# El root se encarga de detectar cambios.
	# Evitamos que el Canopy haga otro polling por su cuenta.
	canopy.set(
		"auto_sync_in_editor",
		false
	)


	if rebuild:

		if canopy.has_method(
			"rebuild_from_trees"
		):

			canopy.call(
				"rebuild_from_trees"
			)


# ============================================================
# DEFERRED CANOPY
# ============================================================

func _deferred_rebuild_canopy() -> void:

	_sync_shadow_multimesh()

	var canopy: Decal = (
		_get_canopy()
	)


	if canopy == null:
		return


	if canopy.has_method(
		"rebuild_from_trees"
	):

		canopy.call(
			"rebuild_from_trees"
		)


# ============================================================
# CHILD ACCESS
# ============================================================

func _get_trees() -> MultiMeshInstance3D:

	var node: Node = get_node_or_null(
		TREES_NODE_PATH
	)


	if node is MultiMeshInstance3D:

		return (
			node as MultiMeshInstance3D
		)


	return null


func _get_tree_shadows() -> MultiMeshInstance3D:

	var node: Node = get_node_or_null(
		SHADOWS_NODE_PATH
	)


	if node is MultiMeshInstance3D:

		return (
			node as MultiMeshInstance3D
		)


	return null


func _get_canopy() -> Decal:

	var node: Node = get_node_or_null(
		CANOPY_NODE_PATH
	)


	if node is Decal:

		return (
			node as Decal
		)


	return null


# ============================================================
# ROOT PATH -> CHILD PATH
# ============================================================

func _convert_path_for_child(
	child: Node,
	root_path: NodePath
) -> NodePath:

	if root_path == NodePath(""):
		return NodePath("")


	var target: Node = get_node_or_null(
		root_path
	)


	if target == null:

		return root_path


	return child.get_path_to(
		target
	)


func _convert_paths_for_child(
	child: Node,
	root_paths: Array[NodePath]
) -> Array[NodePath]:

	var result: Array[NodePath] = []


	for root_path: NodePath in root_paths:

		if root_path == NodePath(""):
			continue


		var target: Node = get_node_or_null(
			root_path
		)


		if target == null:

			result.append(
				root_path
			)

			continue


		result.append(
			child.get_path_to(
				target
			)
		)


	return result


# ============================================================
# SIGNATURES
# ============================================================

func _build_tree_signature() -> String:

	return str([
		trees_enabled,

		target_count,
		area_radius_x,
		area_radius_z,

		min_spacing,
		max_spacing,

		poisson_attempts_per_point,
		candidate_pool_multiplier,

		random_seed,

		min_scale,
		max_scale,
		center_scale_bias_percent,

		snap_to_ground,
		ray_above_height,
		ray_below_depth,
		ground_collision_mask,

		valid_ground_name_contains,

		reject_steep_slopes,
		max_ground_slope_degrees,

		avoid_visual_geometry,
		visual_exclusion_roots,
		visual_radius_factor,
		visual_extra_clearance,

		avoid_water,
		water_provider_path,
		minimum_height_above_water
	])


func _build_shadow_signature() -> String:

	return str([
		tree_shadows_enabled,
		shadow_material_override
	])


func _build_canopy_signature() -> String:

	return str([
		canopy_enabled,

		canopy_shadow_color,
		canopy_shadow_strength,
		canopy_per_tree_density,

		canopy_radius_factor,
		canopy_extra_radius,
		canopy_falloff_power,
		canopy_density_gamma,

		canopy_texture_resolution,
		canopy_blur_radius_pixels,
		canopy_blur_passes,
		canopy_world_padding,
		canopy_flip_texture_z,

		canopy_vertical_margin,
		canopy_surface_normal_fade
	])


func _capture_signatures() -> void:

	_last_tree_signature = (
		_build_tree_signature()
	)

	_last_shadow_signature = (
		_build_shadow_signature()
	)

	_last_canopy_signature = (
		_build_canopy_signature()
	)
