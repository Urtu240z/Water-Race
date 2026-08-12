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

## Main-scene limitation

Paradise Island is currently the main scene.

Main-scene dependency loading can happen before `LoadTrace` starts, so `GAME START → FIRST_FRAME_DRAWN` does not represent complete process launch time.

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

## Optimization workflow

1. Capture baseline.
2. Change one system.
3. Repeat the same load sequence.
4. Compare paired trace events.
5. Keep visual/gameplay quality constant unless intentionally changed.
6. Document new cache/bake requirements.
