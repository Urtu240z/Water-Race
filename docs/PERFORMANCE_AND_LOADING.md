# Performance and Loading

## LoadTrace

Runtime tracing:

```text
res://dev/debug/load_trace.gd
```

Important events include:

```text
GAME START
LEVEL_RESOURCE_LOAD_BEGIN
LEVEL_RESOURCE_LOADED
CHANGE_SCENE_BEGIN
CHANGE_SCENE_QUEUED
LEVEL_ENTER_TREE
LEVEL_ROOT_READY
OCEAN_MESH_CACHE_LOAD_BEGIN
OCEAN_MESH_CACHE_LOAD_END
GRAPHICS_APPLY_BEGIN
UNDERWATER_PREWARM_BEGIN
FIRST_PROCESS_FRAME
FIRST_FRAME_DRAWN
```

## Diagnostic startup bootstrap

The current main scene is the lightweight diagnostic bootstrap:

```text
res://startup/startup_bootstrap.tscn
```

It profiles the initial level resource synchronously before changing to
Paradise Island. Paradise remains the default. To profile Gold City with the
same bootstrap, pass
`initial_level=res://levels/gold_city/gold_city.tscn` as a user argument.

Engine and rendering-device startup still happens before `LoadTrace`; use an
external process stopwatch when the complete launch-to-frame time is required.

## Baseline after ocean cache

### Gold City

```text
PackedScene/dependencies: ~3.97 s
Ocean cache load:         ~0.165 s
Load click → first frame: ~4.45 s
```

### Paradise Island

```text
PackedScene/dependencies: ~6.13 s
Ocean cache load:         ~0.127 s
Load click → first frame: ~6.49 s
```

The major remaining bottleneck is PackedScene/dependency loading.

## Historical issue: double ocean rebuild

Previously:

```text
OceanSurface3D._ready()
→ provisional rebuild

GraphicsQualityManager applies profile
→ second rebuild
```

This has been fixed and must not be reintroduced.

## Cold-load profiling rule

Do not benchmark many dependencies sequentially in one process and call the result cold-load data.

Prefer one candidate resource per clean Godot process.

## Interpret timing categories separately

### Resource load

```text
LEVEL_RESOURCE_LOAD_BEGIN
→ LEVEL_RESOURCE_LOADED
```

### Scene switch / handoff

```text
CHANGE_SCENE_BEGIN
→ LEVEL_ENTER_TREE
```

### Node initialization

```text
LEVEL_ENTER_TREE
→ LEVEL_ROOT_READY
```

### Deferred / first-use work

```text
LEVEL_ROOT_READY
→ FIRST_FRAME_DRAWN
```

## Current profiling priority

Investigate the dependencies behind:

```text
Paradise Island ~6.1 s
Gold City       ~4.0 s
```

Pay attention to large GLBs, imported textures, LightmapGI data, duplicated resources and transitive dependencies.

## Paradise Island terrain-material externalization

The terrain GLB previously loaded editable `.tres` materials containing large
base64 `PackedByteArray` texture payloads. These portable compressed textures
now live in shared binary `.res` resources while the materials remain `.tres`.

Final process-cold measurements after the complete migration:

```text
paradise_island.glb:       1.162-1.184 s
paradise_island.tscn:      6.492-6.574 s
Gold City -> Paradise:     1.179-1.196 s
```

The comparable Gold City to Paradise transition was `5.243-5.332 s` after the
single-material pilot and approximately `6.509 s` before externalization.

See `MATERIAL_TEXTURE_EXTERNALIZATION.md` for the required migration and validation
workflow.

## Gold City material externalization

The same binary-texture pipeline covers the terrain, animated roller coaster,
ferris wheel, and casino material roots used by Gold City.

Final process-cold measurements after migration:

```text
animated_roller_coaster.glb: 0.476-0.496 s
gold_city.glb:               0.258-0.261 s
gold_city.tscn:              6.366-6.626 s
Paradise -> Gold City:       1.478-1.527 s
Gold City -> Paradise:       1.161-1.280 s
```

Before migration, the corresponding ranges were `2.484-3.050 s`,
`1.295-1.598 s`, `8.520-10.012 s`, and `3.893-4.014 s`. The reverse transition
remains near the Paradise Island post-migration baseline of approximately
`1.2 s`.

## Shared gameplay/world material externalization

The Paradise/Gold dependency intersection contained 22 editable materials with
25 embedded portable textures across the JetSki, ramps, buoys, and shared
boats. Migration created 24 shared binary texture resources and reused one
byte-identical Gold City resource.

Post-migration process-clean measurements:

```text
jet_ski_01_hull.tres:    0.206-0.212 s  (before ~1.668 s)
jet_ski_with_rider:      1.015-1.050 s  (before ~2.179 s)
ramp_01.tscn:            0.071-0.127 s  (before ~0.351 s)
ramp_02.tscn:            0.072-0.077 s  (before ~0.356 s)
boat_01.glb:             0.097-0.135 s  (before ~0.432 s)
boat_02.glb:             0.062-0.087 s  (before ~0.186 s)
shared dependency union: 1.547-1.813 s  (before 5.828-5.961 s)
bootstrap Paradise load: 4.024 s        (before 6.398 s)
bootstrap Gold load:     4.287 s
```

This migration does not address the separate first-render interval between
`FIRST_RENDER_PRE_DRAW` and `FIRST_RENDER_POST_DRAW`.

## Optimization workflow

1. Capture baseline.
2. Change one system.
3. Repeat the same load sequence.
4. Compare paired trace events.
5. Keep visual/gameplay quality constant unless intentionally changed.
6. Document new cache/bake requirements.
