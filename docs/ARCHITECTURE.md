# Architecture

## Godot project root

```text
Water-Race/game
```

## Startup

`project.godot` currently launches Paradise Island.

Race root:

```text
res://gameplay/race/race_level_bootstrap.gd
```

## Autoload order

Important order:

```text
LoadTrace
GraphicsQualityManager
```

## Level switching

Relevant script:

```text
res://ui/pause_menu/pause_menu.gd
```

Current flow:

```text
select scene path
→ ResourceLoader.load(scene_path, "PackedScene")
→ change_scene_to_packed()
→ level enters tree
→ RaceLevelBootstrap
→ first frame
```

## Graphics quality

```text
res://systems/graphics/graphics_quality_manager.gd
```

Profiles:

```text
LOW
MEDIUM
HIGH
```

## Ocean

Core files:

```text
res://world/water/ocean/ocean_3d.gd
res://world/water/ocean/ocean_surface_3d.gd
res://world/water/ocean/ocean_surface_mesh_cache.gd
```

Shared baked meshes:

```text
res://world/water/ocean/mesh_cache/
```

## Terrain

```text
res://world/terrain/terrain_quality_controller.gd
```

## Vegetation

```text
res://world/vegetation/trees/tree_impostor_multimesh.gd
```

## Rider and JetSki

```text
res://gameplay/riders/
res://gameplay/vehicles/
```

Rider docs:

```text
docs/riders/
```

## Environment

```text
res://world/environment/sky/sky_environment_controller.gd
```

## Development tooling

```text
res://dev/debug/load_trace.gd
res://dev/tools/bake_ocean_surface_meshes.gd
res://dev/tests/graphics/validate_ocean_mesh_cache.gd
```
