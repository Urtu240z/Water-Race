@tool
extends Node3D


# ============================================================
# CONSTANTS
# ============================================================

const TREES_NODE_PATH: NodePath = NodePath("Trees")
const SHADOWS_NODE_PATH: NodePath = NodePath("TreeShadows")

const DEFAULT_SHADOW_MATERIAL: Material = preload(
	"res://world/vegetation/trees/materials/tree_impostor_shadow_material.tres"
)

const DEFAULT_TREE_MATERIAL: Material = preload(
	"res://world/vegetation/trees/materials/tree_impostor_material_paradise_island.tres"
)


# ============================================================
# TREES - GENERAL
# ============================================================

@export_group("Trees")

@export var trees_enabled: bool = true

@export_subgroup("Material")

@export var tree_material: Material = DEFAULT_TREE_MATERIAL


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

# Visual meshes used only while baking tree placement. These paths are chosen
# from the forest root and converted automatically for the Trees child.
@export var ground_visual_meshes: Array[NodePath] = []

# A level can mark one shared Terrain_VIS with this group so every forest zone
# uses it without repeating a NodePath override.
@export var use_grouped_visual_ground: bool = true

@export var ground_visual_group: StringName = (
	&"tree_impostor_ground"
)


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


# ============================================================
# INTERNAL
# ============================================================

var _editor_elapsed: float = 0.0

var _last_tree_signature: String = ""
var _last_shadow_signature: String = ""
var _last_tree_material_signature: String = ""

var _editor_rebuild_queued: bool = false


# ============================================================
# ENTER TREE
# ============================================================

func _enter_tree() -> void:

	# Parent entra en el árbol antes que sus hijos.
	#
	# Aplicamos aquí los parámetros para que Trees
	# ya tenga los valores correctos cuando ejecute _ready().
	_apply_tree_properties(
		false
	)

	_apply_shadow_properties()


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

	var new_tree_material_signature: String = (
		_build_tree_material_signature()
	)


	var trees_changed: bool = (
		new_tree_signature
		!= _last_tree_signature
	)

	var shadows_changed: bool = (
		new_shadow_signature
		!= _last_shadow_signature
	)

	var tree_material_changed: bool = (
		new_tree_material_signature
		!= _last_tree_material_signature
	)


	if trees_changed:

		_queue_full_editor_rebuild()

		return


	if tree_material_changed:

		_apply_tree_material()

		_last_tree_material_signature = (
			new_tree_material_signature
		)


	if shadows_changed:

		_apply_shadow_properties()

		_last_shadow_signature = (
			new_shadow_signature
		)


# ============================================================
# PUBLIC - REGENERATE EVERYTHING
# ============================================================

func regenerate_forest() -> void:

	_apply_tree_properties(
		true
	)

	_apply_shadow_properties()

	_sync_shadow_multimesh()

	_capture_signatures()


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
	trees.layers = 2


	# TreeShadows se encarga de las sombras.
	trees.cast_shadow = (
		GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	)


	# Material visual de este bosque.
	#
	# Utilizamos material_override (no mesh.material) para que
	# cada instancia de la escena tenga su propio material sin
	# duplicar ni compartir la geometría ni el recurso de malla.
	_apply_tree_material()


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

	trees.set(
		"ground_visual_mesh_paths",
		_convert_paths_for_child(
			trees,
			ground_visual_meshes
		)
	)

	trees.set(
		"use_grouped_visual_ground",
		use_grouped_visual_ground
	)

	trees.set(
		"ground_visual_group",
		ground_visual_group
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
# APPLY TREE MATERIAL
# ============================================================

func _apply_tree_material() -> void:

	var trees: MultiMeshInstance3D = (
		_get_trees()
	)


	if trees == null:
		return


	trees.material_override = (
		tree_material
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
		ground_visual_meshes,
		use_grouped_visual_ground,
		ground_visual_group,

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


func _build_tree_material_signature() -> String:

	return str([
		tree_material
	])


func _capture_signatures() -> void:

	_last_tree_signature = (
		_build_tree_signature()
	)

	_last_shadow_signature = (
		_build_shadow_signature()
	)

	_last_tree_material_signature = (
		_build_tree_material_signature()
	)
