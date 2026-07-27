# Ocean3D completion patch v1.3

Apply this only after the v1.1 migration produced the residual-reference list.

## Steps

1. Keep Godot closed.
2. Extract this ZIP in the project root and overwrite the existing
   `Ocean3D_Migration` folder when Windows asks.
3. In the existing PowerShell window run:

```powershell
.\Ocean3D_Migration\complete_ocean3d_migration.ps1
```

The patch:

- migrates underwater detection to `Ocean3D`;
- migrates hull foam, spray sheet, turbine exhaust and wake trail;
- adds the typed foam settings and crest color still consumed by those effects;
- replaces the underwater shader with a clean texture-driven Ocean3D version;
- removes obsolete `WaterBody3D` properties copied to the new ocean scene;
- creates a separate `.ocean3d_completion_backup_*` backup;
- refuses to continue if active legacy references remain.

Only after the command ends with:

```text
No active legacy type references were detected.
```

open Godot and wait for import and script parsing.

Do not run `remove_legacy_ocean_files.ps1` yet. First validate the game.


## Corrección v1.3

Corrige una comilla escapada con sintaxis de C (`\"`) que Windows PowerShell 5.1 no puede analizar. El fallo anterior ocurría antes de ejecutar el script, por lo que no modificó el proyecto.
