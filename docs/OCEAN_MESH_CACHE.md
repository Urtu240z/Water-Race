# Ocean Mesh Cache

## Purpose

`OceanSurface3D` uses a large deterministic surface split into:

- NearGrid
- MiddleRing
- FarRing

Originally this geometry was rebuilt procedurally every race load. HIGH quality took roughly four seconds in normal runtime.

The current system loads baked cache resources instead.

## Why caching is valid

Geometry is deterministic for:

```text
near_radius
near_cell_size
middle_radius
middle_cell_size
far_radius
far_cell_size
```

Runtime ocean movement does not modify the stored topology. It remains dynamic through transforms, uniforms, shader parameters and time.

## What remains dynamic

No rebake is required for changes such as:

- wave height/amplitude
- wave speed
- wave direction
- foam
- water color
- normals
- roughness/reflectivity
- shader-driven storm intensity
- runtime visual water tuning

## Graphics profiles

LOW, MEDIUM and HIGH each have their own baked cache.

Runtime flow:

```text
graphics profile selected
→ structural values applied
→ matching cache loaded
→ six structural values validated
→ Near/Middle/Far meshes assigned
```

## When a rebake is required

Rebake after permanently changing:

```text
near_radius
near_cell_size
middle_radius
middle_cell_size
far_radius
far_cell_size
```

If you forget, runtime can fall back to procedural generation, but the new result is not automatically persisted for future loads.

## Baker

Run:

```text
res://dev/tools/bake_ocean_surface_meshes.gd
```

It reads:

```text
res://systems/graphics/profiles/graphics_low.tres
res://systems/graphics/profiles/graphics_medium.tres
res://systems/graphics/profiles/graphics_high.tres
```

and writes:

```text
res://world/water/ocean/mesh_cache/ocean_surface_low.res
res://world/water/ocean/mesh_cache/ocean_surface_medium.res
res://world/water/ocean/mesh_cache/ocean_surface_high.res
```

## Rebake procedure

1. Save graphics profile changes.
2. Run `res://dev/tools/bake_ocean_surface_meshes.gd` as an EditorScript.
3. Confirm LOW, MEDIUM and HIGH are generated successfully.
4. Run validation if the change is significant.
5. Launch the game.
6. Confirm `LoadTrace` reports `OCEAN_MESH_CACHE_HIT`.

## Validation

Test:

```text
res://dev/tests/graphics/validate_ocean_mesh_cache.gd
```

The baked HIGH cache has been compared against procedural NearGrid, MiddleRing and FarRing arrays for exact logical equivalence.

## Performance baseline

Before caching:

```text
~4.0 s
```

After caching:

```text
~0.13–0.17 s
```

Approximate 96% reduction.

## Runtime quality changes

Expected behavior:

```text
HIGH → HIGH
no mesh replacement

HIGH → MEDIUM
assign MEDIUM cache

MEDIUM → LOW
assign LOW cache

LOW → HIGH
assign HIGH cache
```

## Important rule

The cache stores the base ocean surface geometry, **not the waves themselves**.
