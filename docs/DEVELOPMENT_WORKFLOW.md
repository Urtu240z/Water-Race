# Development Workflow

## Repository vs Godot root

Repository:

```text
Water-Race/
```

Godot project:

```text
Water-Race/game/
```

## Before core changes

Read the relevant docs before changing ocean, graphics quality, level loading, level bootstrap, terrain, large assets or LightmapGI.

## After changing ocean structural profile values

If any of these changed:

```text
near_radius
near_cell_size
middle_radius
middle_cell_size
far_radius
far_cell_size
```

rebake the ocean caches.

## Performance-sensitive validation sequence

Use the same flow before and after:

```text
1. Start game
2. Reach Paradise Island
3. Change to Gold City
4. Wait until first rendered/playable frame
5. Change back to Paradise Island
6. Capture load_trace.log
```

## Git checks

Useful checks:

```bash
git status
git diff --check
git lfs status
```

## Validation expectations

For GDScript:

- review diff;
- run `git diff --check`;
- ensure no parse errors;
- exercise the affected runtime flow;
- inspect warnings/errors;
- run targeted tests when available.

For cache/bake changes:

- regenerate resources;
- confirm runtime cache hit;
- verify LOW/MEDIUM/HIGH changes;
- ensure fallback is not happening unexpectedly.

## Documentation rule

If a change introduces a manual maintenance step, document:

1. what triggers it;
2. which tool/script to run;
3. where output goes;
4. how to validate it;
5. what happens if skipped.
