import json
import sys

import bpy


path = sys.argv[sys.argv.index("--") + 1]
bpy.ops.wm.open_mainfile(filepath=path)

records = []
for obj in bpy.context.scene.objects:
    records.append(
        {
            "name": obj.name,
            "type": obj.type,
            "parent": obj.parent.name if obj.parent else None,
            "location": list(obj.location),
            "rotation_euler": list(obj.rotation_euler),
            "scale": list(obj.scale),
            "matrix_world": [list(row) for row in obj.matrix_world],
            "dimensions": list(obj.dimensions),
            "modifiers": [
                {
                    "name": modifier.name,
                    "type": modifier.type,
                    "object": (
                        modifier.object.name
                        if modifier.type == "ARMATURE" and modifier.object
                        else None
                    ),
                }
                for modifier in obj.modifiers
            ],
        }
    )

print("CODEX_CH42_TRANSFORMS=" + json.dumps(records))
