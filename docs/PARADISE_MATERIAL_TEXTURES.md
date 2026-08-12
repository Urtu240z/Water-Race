# Paradise Island Material Textures

## Storage rule

Paradise Island terrain materials remain editable text resources:

```text
material.tres
-> ExtResource
-> PortableCompressedTexture2D stored as texture.res
```

Large `PortableCompressedTexture2D` payloads must not be embedded as
`PackedByteArray` values inside terrain material `.tres` files. Parsing the
base64 text made `paradise_island.glb` several seconds slower to load.

Externalization does not change texture quality. The binary resources retain
the original compressed payload, dimensions, format, mipmaps,
`keep_compressed_buffer`, and `size_override`. Identical compressed payloads
share one `.res` file.

## Paths

Materials:

```text
res://levels/paradise_island/terrain/materials/
```

External textures and validation manifest:

```text
res://levels/paradise_island/terrain/materials/textures/
```

## Migration and validation

From the Godot project root (`Water Race/game`), run:

```powershell
Godot --headless --path . --script res://dev/tools/externalize_paradise_island_material_textures.gd
Godot --path . --script res://dev/tools/validate_paradise_island_material_textures.gd
```

The migration tool reads only materials mapped by
`paradise_island.glb.import`. It preserves material text and UID, externalizes
embedded portable textures, deduplicates by compressed-payload MD5, validates
the decoded texture, and writes `externalized_textures_manifest.json`.

The tool is idempotent. A second unchanged run must report:

```text
materials_modified: 0
textures_created: 0
```

The validator checks all mapped materials, texture slots, hashes, dimensions,
formats, mipmaps, UIDs, and material property snapshots. It also loads and
instantiates both `paradise_island.glb` and `paradise_island.tscn`.

## Adding or updating a terrain material

1. Keep the material as an editable `.tres` with its stable UID.
2. Add it to the GLB external-material mappings when applicable.
3. Do not commit a large embedded `PortableCompressedTexture2D` blob.
4. Run the migration tool. It will reuse an existing `.res` when the compressed
   payload is identical.
5. Run the validator and confirm it reports no failures.
6. Measure Paradise Island loading if the asset is large.

Do not manually convert the complete material to `.res`, export its texture to
PNG, recompress it, regenerate mipmaps, or change import settings as part of
this workflow.
