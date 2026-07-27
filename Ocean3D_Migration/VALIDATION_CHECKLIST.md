# Validación antes de borrar lo antiguo

## 1. Importación y parseo

- Abre Godot 4.7.1.
- Espera a que termine la importación.
- La consola no debe mostrar errores de parseo, clases duplicadas ni recursos ausentes.
- Abre `scenes/water/ocean_3d.tscn` de forma aislada.
- Debe verse un único nodo raíz `Ocean3D` con un hijo `Surface`.

## 2. Escena principal

Abre `scenes/levels/island_test/island_test_BLENDER.tscn` y comprueba:

```text
WaterIntegration
└── Ocean
    └── Surface
```

En el Inspector:

- `Ocean.follow_target_path` apunta al JetSki.
- `Ocean.follow_camera_path` apunta a ChaseCamera.
- `Ocean.ripple_emitter_target_path` apunta al JetSki.
- `Ocean.water_level` mantiene el valor actual, normalmente `-1.02`.
- JetSki usa `ocean_path`, no `water_body_path`.
- WorldOriginController usa `ocean_path`.
- VehicleWaterEffects3D usa `ocean_path` o resuelve el océano desde el JetSki.
- AmbientWildlifeController y las boyas apuntan a `Ocean3D`.

## 3. Pruebas mínimas

1. Arranca la escena y deja el JetSki quieto 30 segundos.
2. Navega recto y gira en ambos sentidos.
3. Salta y aterriza suave y fuerte.
4. Comprueba spray, wake, impactos, espuma y audio.
5. Pasa cerca de una boya y confirma que flota y se inclina con la normal.
6. Comprueba peces y delfines respecto a la superficie.
7. Recorre más de 512 m para forzar un rebase.
8. Confirma que no hay salto visual, cambio de fase de olas ni pérdida de estela.
9. Prueba inmersión y salida del agua.

## 4. Coincidencia visual/física

Con el HUD/debug disponible:

- las posiciones físicas de superficie deben coincidir con la malla;
- las normales de flotación deben seguir las olas visibles;
- no debe aparecer una superficie plana mientras la malla tiene olas;
- los ripples de aterrizaje deben afectar tanto al shader como al muestreo CPU.

## 5. Búsqueda final

En Godot usa `Ctrl + Shift + F` y busca:

```text
WaterBody3D
PixelOcean
OceanClipmap3D
pixel_ocean
water_body_path
physical_water_path
ocean_clipmap_path
```

Los únicos resultados aceptables antes de limpiar son los archivos antiguos que se van a borrar y la copia de seguridad.

## 6. Limpieza

Solo cuando todo lo anterior esté validado:

```powershell
.\Ocean3D_Migration\remove_legacy_ocean_files.ps1
```

Después vuelve a abrir Godot y repite una prueba corta de arranque, navegación, aterrizaje y rebase.
