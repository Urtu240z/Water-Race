# Material Texture Externalization

## Storage rule

Level materials remain editable text resources:

```text
material.tres
-> ExtResource
-> PortableCompressedTexture2D stored as texture.res
```

Large `PortableCompressedTexture2D` payloads must not be embedded as
`PackedByteArray` values inside material `.tres` files. Parsing the base64 text
made both Paradise Island and Gold City GLBs several seconds slower to load.

Externalization does not change texture quality. The binary resources retain
the original compressed payload, dimensions, format, mipmaps,
`keep_compressed_buffer`, and `size_override`. Identical compressed payloads
share one `.res` file.

## Configured targets and paths

Paradise Island textures and manifest:

```text
res://levels/paradise_island/terrain/materials/textures/
```

Gold City textures and manifest:

```text
res://levels/gold_city/material_textures/
```

## Migration and validation

From the Godot project root (`Water Race/game`), run:

```powershell
Godot --headless --path . --script res://dev/tools/externalize_material_textures.gd -- paradise_island
Godot --path . --script res://dev/tools/validate_material_textures.gd -- paradise_island
Godot --headless --path . --script res://dev/tools/externalize_material_textures.gd -- gold_city
Godot --path . --script res://dev/tools/validate_material_textures.gd -- gold_city
```

The generic migration tool scans only the configured material roots for the
selected target. It preserves material text and UID, externalizes embedded
portable textures, deduplicates by compressed-payload MD5, validates the
decoded texture, and writes an `externalized_textures_manifest.json` beside the
binary textures.

The tool is idempotent. A second unchanged run must report:

```text
materials_modified: 0
textures_created: 0
```

The validator checks all configured materials, texture slots, hashes,
dimensions, formats, mipmaps, UIDs, and material property snapshots. It also
loads and instantiates every configured GLB and the level scene.

## Adding or updating a material

1. Keep the material as an editable `.tres` with its stable UID.
2. Put it under one of the target's configured material roots and add it to the
   GLB external-material mappings when applicable.
3. Do not commit a large embedded `PortableCompressedTexture2D` blob.
4. Run the migration tool. It will reuse an existing `.res` when the compressed
   payload is identical.
5. Run the validator and confirm it reports no failures.
6. Measure Paradise Island loading if the asset is large.

Do not manually convert the complete material to `.res`, export its texture to
PNG, recompress it, regenerate mipmaps, or change import settings as part of
this workflow.
