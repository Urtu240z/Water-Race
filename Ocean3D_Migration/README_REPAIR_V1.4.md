# Ocean3D resource identity repair v1.4

This patch fixes the first editor load after the Ocean3D migration.

It removes duplicate class templates accidentally left inside `res://`, removes
stale resource UIDs from the renamed scenes, forces the new script paths and
clears Godot's generated global class cache.

## Run

Close Godot, extract the ZIP into the project root and overwrite the existing
`Ocean3D_Migration` folder. Then run:

```powershell
.\Ocean3D_Migration\repair_ocean3d_resource_identity.ps1
```

Reopen Godot only after the command ends with:

```text
Ocean3D resource identity repair completed successfully.
```
