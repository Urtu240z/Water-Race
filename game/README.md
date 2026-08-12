# Water Race

**Water Race** is a 3D arcade jet ski racing game built with **Godot 4.7**. The project focuses on responsive arcade handling, physically reactive water, large race environments, riders, tricks, scalable graphics quality and fast level transitions.

> Development is active. Systems, content and performance targets may continue to change.

## Project status

- Engine: **Godot 4.7**
- Renderer: **Forward Plus**
- Godot project root: `game/`
- Project file: `game/project.godot`
- Current main scene: `Paradise Island`
- Current levels:
  - `res://levels/paradise_island/paradise_island.tscn`
  - `res://levels/gold_city/gold_city.tscn`
- Graphics presets: LOW / MEDIUM / HIGH
- Large binary assets use **Git LFS**

## Getting started

### Requirements

- Godot 4.7
- Git
- Git LFS

### Clone and open

```bash
git clone <repository-url>
cd Water-Race
git lfs pull
```

Open:

```text
game/project.godot
```

**Important:** the repository root is not the Godot project root. `res://` starts inside `game/`.

## Repository layout

```text
Water-Race/
├── game/
├── docs/
├── source/
├── tools/
├── debug/
└── README.md
```

## Controls

| Action | Keyboard |
|---|---|
| Throttle | W |
| Brake | S |
| Steer left | A |
| Steer right | D |
| Camera toggle | C |
| Pause menu | Esc |

## Documentation

Start with [`docs/README.md`](docs/README.md).

Important documents:

- [`docs/CRITICAL_TECHNICAL_RULES.md`](docs/CRITICAL_TECHNICAL_RULES.md)
- [`docs/OCEAN_MESH_CACHE.md`](docs/OCEAN_MESH_CACHE.md)
- [`docs/PERFORMANCE_AND_LOADING.md`](docs/PERFORMANCE_AND_LOADING.md)
- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md)
- [`docs/DEVELOPMENT_WORKFLOW.md`](docs/DEVELOPMENT_WORKFLOW.md)

## Performance philosophy

1. Measure before reducing quality.
2. Avoid rebuilding deterministic heavy data at runtime when it can be cached or baked.
3. Keep load tracing available while core systems are evolving.
4. Validate both cold startup and level-to-level loading.
5. Do not silently change graphics preset geometry or import settings without documenting the consequence.

## Ocean mesh cache — important

Ocean surface geometry for LOW, MEDIUM and HIGH is baked into shared cache resources.

Shader-driven water behavior remains dynamic. Changing wave height, speed, direction, foam, normals, color or similar runtime/shader properties **does not require rebaking the ocean mesh**.

Changing any structural grid parameter **does require a rebake** if the fast cached path must remain valid:

- `near_radius`
- `near_cell_size`
- `middle_radius`
- `middle_cell_size`
- `far_radius`
- `far_cell_size`

See [`docs/OCEAN_MESH_CACHE.md`](docs/OCEAN_MESH_CACHE.md).
