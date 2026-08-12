extends Node

const OCEAN_SCENE := preload("res://world/water/ocean/ocean_3d.tscn")
const CACHE_PATHS := {
	0: "res://world/water/ocean/mesh_cache/ocean_surface_low.res",
	1: "res://world/water/ocean/mesh_cache/ocean_surface_medium.res",
	2: "res://world/water/ocean/mesh_cache/ocean_surface_high.res",
}

var _failures: PackedStringArray = []


func _ready() -> void:
	var ocean := OCEAN_SCENE.instantiate() as Ocean3D
	add_child(ocean)
	var surface := ocean.get_surface()
	_check(surface != null, "OceanSurface3D exists.")
	if surface == null:
		_finish()
		return

	_check(surface.mesh_rebuild_count == 1, "Initial HIGH cache is applied once.")
	_validate_active_cache(surface, GraphicsQualityManager.Quality.HIGH)

	var previous_rebuild_count := surface.mesh_rebuild_count
	GraphicsQualityManager.set_quality(GraphicsQualityManager.Quality.HIGH, false)
	_check(
		surface.mesh_rebuild_count == previous_rebuild_count,
		"Reapplying HIGH does not reassign the meshes."
	)

	for quality: int in [
		GraphicsQualityManager.Quality.MEDIUM,
		GraphicsQualityManager.Quality.LOW,
		GraphicsQualityManager.Quality.HIGH,
	]:
		previous_rebuild_count = surface.mesh_rebuild_count
		GraphicsQualityManager.set_quality(quality, false)
		_check(
			surface.mesh_rebuild_count == previous_rebuild_count + 1,
			"Changing to quality %d applies one mesh set." % quality
		)
		_validate_active_cache(surface, quality)
	_validate_high_cache_content()

	_finish()


func _validate_active_cache(surface: OceanSurface3D, quality: int) -> void:
	var cache := load(CACHE_PATHS[quality])
	var profile := GraphicsQualityManager.current_profile
	_check(cache != null, "Cache %d loads." % quality)
	if cache == null:
		return
	_check(
		cache.matches_geometry(
			profile.ocean_near_radius,
			profile.ocean_near_cell_size,
			profile.ocean_middle_radius,
			profile.ocean_middle_cell_size,
			profile.ocean_far_radius,
			profile.ocean_far_cell_size
		),
		"Cache %d matches its profile geometry." % quality
	)
	_check(surface.get_node("NearGrid").mesh == cache.near_mesh, "Near mesh %d is shared." % quality)
	_check(
		surface.get_node("MiddleRing").mesh == cache.middle_mesh,
		"Middle mesh %d is shared." % quality
	)
	_check(surface.get_node("FarRing").mesh == cache.far_mesh, "Far mesh %d is shared." % quality)


func _validate_high_cache_content() -> void:
	var profile := load(
		"res://systems/graphics/profiles/graphics_high.tres"
	) as GraphicsQualityProfile
	var baked_cache := load(CACHE_PATHS[GraphicsQualityManager.Quality.HIGH])
	var builder := OceanSurface3D.new()
	var generated_cache := builder.build_mesh_cache_for_profile(profile)
	builder.free()
	_check(
		_mesh_arrays_match(baked_cache.near_mesh, generated_cache.near_mesh),
		"Baked HIGH NearGrid arrays exactly match procedural generation."
	)
	_check(
		_mesh_arrays_match(baked_cache.middle_mesh, generated_cache.middle_mesh),
		"Baked HIGH MiddleRing arrays exactly match procedural generation."
	)
	_check(
		_mesh_arrays_match(baked_cache.far_mesh, generated_cache.far_mesh),
		"Baked HIGH FarRing arrays exactly match procedural generation."
	)


func _mesh_arrays_match(mesh_a: ArrayMesh, mesh_b: ArrayMesh) -> bool:
	return mesh_a.surface_get_arrays(0) == mesh_b.surface_get_arrays(0)


func _check(condition: bool, message: String) -> void:
	print("%s: %s" % ["PASS" if condition else "FAIL", message])
	if not condition:
		_failures.append(message)


func _finish() -> void:
	print("OCEAN_MESH_CACHE_STATUS=%s" % ("PASS" if _failures.is_empty() else "FAIL"))
	get_tree().quit(0 if _failures.is_empty() else 1)
