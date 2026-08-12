@tool
extends EditorScript

const PROFILE_PATHS := {
	0: "res://systems/graphics/profiles/graphics_low.tres",
	1: "res://systems/graphics/profiles/graphics_medium.tres",
	2: "res://systems/graphics/profiles/graphics_high.tres",
}
const OUTPUT_PATHS := {
	0: "res://world/water/ocean/mesh_cache/ocean_surface_low.res",
	1: "res://world/water/ocean/mesh_cache/ocean_surface_medium.res",
	2: "res://world/water/ocean/mesh_cache/ocean_surface_high.res",
}


func _run() -> void:
	DirAccess.make_dir_recursive_absolute(
		ProjectSettings.globalize_path("res://world/water/ocean/mesh_cache")
	)
	for quality: int in PROFILE_PATHS:
		var profile := load(PROFILE_PATHS[quality]) as GraphicsQualityProfile
		if profile == null:
			push_error("Could not load ocean graphics profile %d." % quality)
			return
		var builder := OceanSurface3D.new()
		var cache := builder.build_mesh_cache_for_profile(profile)
		builder.free()
		if cache == null:
			push_error("Could not build ocean mesh cache %d." % quality)
			return
		var error := ResourceSaver.save(
			cache,
			OUTPUT_PATHS[quality],
			ResourceSaver.FLAG_COMPRESS
		)
		if error != OK:
			push_error(
				"Could not save ocean mesh cache %d: %s" % [quality, error_string(error)]
			)
			return
		print(
			"Baked ocean mesh cache ",
			OUTPUT_PATHS[quality],
			" (",
			cache.near_vertex_count + cache.middle_vertex_count + cache.far_vertex_count,
			" vertices)."
		)
	print("Ocean surface mesh caches baked successfully.")
