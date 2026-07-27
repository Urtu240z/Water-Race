# Migración a Ocean3D

## Compatibilidad

La versión 1.1 es compatible con Windows PowerShell 5.1 y no depende de
`System.IO.Path.GetRelativePath()`.

Si la versión anterior falló con ese mensaje, no hace falta restaurar el
proyecto: sustituye la carpeta `Ocean3D_Migration` y vuelve a ejecutar el
script. La ejecución anterior solo pudo crear `scripts/water/ocean_3d.gd`
antes de detenerse; no llegó a reemplazar archivos existentes.

Este paquete convierte el sistema activo del proyecto en una única escena pública:

```text
Ocean3D
└── Surface: OceanSurface3D
    ├── NearGrid
    ├── MiddleRing
    ├── FarRing
    └── Debug
```

`Ocean3D` no hereda de `WaterBody3D`. Conserva el modelo actual de olas por texturas, el muestreo físico CPU, los ripples, la estela, las métricas de cresta, el material visual y el recentrado del mundo.

## Antes de ejecutar

1. Cierra Godot.
2. Comprueba que GitHub Desktop muestre **No local changes**.
3. Copia la carpeta `Ocean3D_Migration` dentro de la raíz del proyecto, junto a `project.godot`.

## Ejecutar

Abre PowerShell en la raíz del proyecto:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\Ocean3D_Migration\apply_ocean3d_migration.ps1
```

El script:

- crea una copia de seguridad `.ocean3d_backup_FECHA_HORA`;
- genera los archivos nuevos a partir de los archivos actuales del proyecto;
- conserva los valores afinados de `pixel_ocean_system_3d.tscn`;
- sustituye referencias en JetSki, efectos, fauna, boyas, recentrado y escena principal;
- no elimina todavía el sistema antiguo;
- informa de cualquier referencia legacy residual.

## Archivos nuevos

```text
scripts/water/ocean_3d.gd
scripts/water/ocean_surface_3d.gd
scenes/water/ocean_3d.tscn
scenes/water/ocean_surface_3d.tscn
shaders/ocean_water.gdshader
resources/water/ocean/*
```

También sustituye:

```text
scripts/levels/island_test_blender_bootstrap.gd
```

## Importante

No ejecutes la limpieza hasta completar `VALIDATION_CHECKLIST.md`. El sistema antiguo se conserva deliberadamente para poder comparar y recuperar.

La migración separa los parámetros del shader por frecuencia:

- tiempo de simulación: cada tick;
- parámetros estáticos: al iniciar o aplicar cambios;
- ripples: solo cuando cambian;
- origen lógico: solo al recentrar.

## Revertir

Cierra Godot y copia el contenido de `.ocean3d_backup_FECHA_HORA` de vuelta a la raíz del proyecto. Los archivos que no existían antes (`ocean_3d.*`, `ocean_surface_3d.*`) se pueden eliminar manualmente.
