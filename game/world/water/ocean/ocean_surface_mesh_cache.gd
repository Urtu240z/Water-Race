class_name OceanSurfaceMeshCache
extends Resource

@export var near_radius: float
@export var near_cell_size: float
@export var middle_radius: float
@export var middle_cell_size: float
@export var far_radius: float
@export var far_cell_size: float

@export var effective_near_radius: float
@export var effective_middle_radius: float
@export var effective_far_radius: float

@export var near_mesh: ArrayMesh
@export var middle_mesh: ArrayMesh
@export var far_mesh: ArrayMesh

@export var near_vertex_count: int
@export var middle_vertex_count: int
@export var far_vertex_count: int
@export var near_triangle_count: int
@export var middle_triangle_count: int
@export var far_triangle_count: int


func matches_geometry(
	expected_near_radius: float,
	expected_near_cell_size: float,
	expected_middle_radius: float,
	expected_middle_cell_size: float,
	expected_far_radius: float,
	expected_far_cell_size: float
) -> bool:
	return (
		is_equal_approx(near_radius, expected_near_radius)
		and is_equal_approx(near_cell_size, expected_near_cell_size)
		and is_equal_approx(middle_radius, expected_middle_radius)
		and is_equal_approx(middle_cell_size, expected_middle_cell_size)
		and is_equal_approx(far_radius, expected_far_radius)
		and is_equal_approx(far_cell_size, expected_far_cell_size)
		and near_mesh != null
		and middle_mesh != null
		and far_mesh != null
	)
