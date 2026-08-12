# Material Texture Externalization

## Storage rule

Materials remain editable text resources, whether they belong to a level,
gameplay, a vehicle, a rider, a prop, UI, or another shared system:

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

Shared gameplay and world resources:

```text
res://shared/material_textures/
```

Deduplication is global across these manifests. A migration reuses an existing
binary texture when its compressed-payload hash already exists. Existing
resources are not moved merely to centralize them, since that could invalidate
UIDs or references.

## Migration and validation

From the Godot project root (`Water Race/game`), run:

```powershell
Godot --headless --path . --script res://dev/tools/externalize_material_textures.gd -- paradise_island
Godot --path . --script res://dev/tools/validate_material_textures.gd -- paradise_island
Godot --headless --path . --script res://dev/tools/externalize_material_textures.gd -- gold_city
Godot --path . --script res://dev/tools/validate_material_textures.gd -- gold_city
Godot --headless --path . --script res://dev/tools/externalize_material_textures.gd -- shared_common
Godot --path . --script res://dev/tools/validate_material_textures.gd -- shared_common
```

The generic migration tool scans the configured material roots for a level
target. The `shared_common` target instead derives its material set from the
transitive dependency intersection of Paradise Island and Gold City. It
preserves material text and UID, externalizes embedded portable textures,
deduplicates by compressed-payload MD5 across all configured manifests,
validates the decoded texture, and writes an
`externalized_textures_manifest.json` beside the binary textures.

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
6. Measure every affected startup or transition if the asset is shared or large.

Do not manually convert the complete material to `.res`, export its texture to
PNG, recompress it, regenerate mipmaps, or change import settings as part of
this workflow.
