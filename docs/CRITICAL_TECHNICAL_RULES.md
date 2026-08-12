# Critical Technical Rules

## 1. Godot project root

The Godot project is:

```text
Water-Race/game
```

Therefore `res://` maps to `Water-Race/game`.

## 2. Ocean geometry is cached

Ocean geometry is baked per graphics profile: LOW, MEDIUM and HIGH.

Structural values:

- `near_radius`
- `near_cell_size`
- `middle_radius`
- `middle_cell_size`
- `far_radius`
- `far_cell_size`

If any of these change permanently, rebake the ocean mesh caches.

## 3. Shader/wave changes do not require rebake

Changing wave amplitude, speed, direction, foam, color, normals or other shader-driven behavior does not require rebaking unless topology changes.

## 4. Graphics profiles own ocean structural quality

Do not reintroduce:

```text
Ocean builds provisional geometry
→ GraphicsQualityManager applies profile
→ Ocean rebuilds again
```

The project previously suffered this double-rebuild regression.

## 5. Reapplying the same profile must not rebuild geometry

HIGH → HIGH should do no expensive geometry work.

HIGH → MEDIUM may assign a different baked mesh.

## 6. Runtime fallback is not a persistent rebake

If cache validation fails, procedural generation keeps the game working, but that does not automatically save a new cache.

## 7. Measure before optimizing

Use `LoadTrace`.

Do not reduce visual quality before identifying the actual bottleneck.

## 8. Large assets use Git LFS

Do not break LFS tracking for large binary assets.

## 9. Keep per-level artistic intent separate from global graphics scaling

Do not let global quality silently erase level-specific fog, water or environment intent.

## 10. Profile startup and transitions separately

Cold application startup and level-to-level transitions are not equivalent.
