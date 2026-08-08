#!/usr/bin/env python3
"""Normalize a prepared Mixamo character to metric, identity transforms."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

import bpy
from mathutils import Vector


def args():
    parser = argparse.ArgumentParser()
    parser.add_argument("--input-blend", required=True)
    parser.add_argument("--output-blend", required=True)
    parser.add_argument("--output-glb", required=True)
    parser.add_argument("--report", required=True)
    return parser.parse_args(
        sys.argv[sys.argv.index("--") + 1 :] if "--" in sys.argv else []
    )


def supported_kwargs(operator, desired):
    properties = set(operator.get_rna_type().properties.keys())
    return {key: value for key, value in desired.items() if key in properties}


def bounds(meshes):
    points = [
        obj.matrix_world @ Vector(corner)
        for obj in meshes
        for corner in obj.bound_box
    ]
    minimum = [min(point[index] for point in points) for index in range(3)]
    maximum = [max(point[index] for point in points) for index in range(3)]
    return {
        "min": minimum,
        "max": maximum,
        "size": [
            maximum[index] - minimum[index] for index in range(3)
        ],
    }


def transform_record(obj):
    return {
        "name": obj.name,
        "type": obj.type,
        "parent": obj.parent.name if obj.parent else None,
        "location": list(obj.location),
        "rotation": list(obj.rotation_euler),
        "scale": list(obj.scale),
        "matrix_world": [list(row) for row in obj.matrix_world],
    }


def main():
    arguments = args()
    source = Path(arguments.input_blend).resolve()
    output_blend = Path(arguments.output_blend).resolve()
    output_glb = Path(arguments.output_glb).resolve()
    report = Path(arguments.report).resolve()

    bpy.ops.wm.open_mainfile(filepath=str(source))
    armatures = [
        obj for obj in bpy.context.scene.objects if obj.type == "ARMATURE"
    ]
    meshes = [
        obj for obj in bpy.context.scene.objects if obj.type == "MESH"
    ]
    if len(armatures) != 1 or not meshes:
        raise RuntimeError(
            f"Expected one armature and meshes, found {len(armatures)}/{len(meshes)}"
        )
    armature = armatures[0]
    armature.data.pose_position = "REST"
    before = {
        "bounds": bounds(meshes),
        "objects": [transform_record(obj) for obj in [armature, *meshes]],
    }

    bpy.ops.object.select_all(action="DESELECT")
    armature.select_set(True)
    for mesh in meshes:
        mesh.select_set(True)
    bpy.context.view_layer.objects.active = armature
    bpy.ops.object.transform_apply(
        location=False,
        rotation=True,
        scale=True,
        properties=False,
    )
    bpy.context.view_layer.update()

    armature.name = "SKEL_Rider"
    armature.data.name = "SKEL_Rider"
    for index, mesh in enumerate(sorted(meshes, key=lambda item: item.name), 1):
        mesh.name = f"Rider01_Mesh_{index:02d}"
        mesh.data.name = f"{mesh.name}_Data"

    after = {
        "bounds": bounds(meshes),
        "objects": [transform_record(obj) for obj in [armature, *meshes]],
    }
    height = after["bounds"]["size"][2]
    if not 1.4 <= height <= 2.2:
        raise RuntimeError(f"Normalized height is implausible: {height}")
    if any(
        abs(component - 1.0) > 0.000001
        for component in armature.scale
    ):
        raise RuntimeError(f"Armature scale is not identity: {armature.scale[:]}")

    output_blend.parent.mkdir(parents=True, exist_ok=True)
    output_glb.parent.mkdir(parents=True, exist_ok=True)
    report.parent.mkdir(parents=True, exist_ok=True)
    bpy.ops.wm.save_as_mainfile(
        filepath=str(output_blend),
        check_existing=False,
    )

    bpy.ops.object.select_all(action="DESELECT")
    armature.select_set(True)
    for mesh in meshes:
        mesh.select_set(True)
    bpy.context.view_layer.objects.active = armature
    desired = {
        "filepath": str(output_glb),
        "export_format": "GLB",
        "use_selection": True,
        "export_selected": True,
        "export_selected_objects": True,
        "export_animations": False,
        "export_skins": True,
        "export_morph": True,
        "export_normals": True,
        "export_tangents": True,
        "export_texcoords": True,
        "export_materials": "EXPORT",
        "export_yup": True,
        "export_apply": False,
        "export_all_influences": True,
        "export_draco_mesh_compression_enable": False,
    }
    export_kwargs = supported_kwargs(bpy.ops.export_scene.gltf, desired)
    result = bpy.ops.export_scene.gltf(**export_kwargs)
    if "FINISHED" not in result:
        raise RuntimeError(f"GLB export failed: {result}")

    data = {
        "source": str(source),
        "output_blend": str(output_blend),
        "output_glb": str(output_glb),
        "armature": armature.name,
        "bones": len(armature.data.bones),
        "meshes": len(meshes),
        "height_m": height,
        "before": before,
        "after": after,
        "export_kwargs": export_kwargs,
        "glb_bytes": output_glb.stat().st_size,
        "status": "PASS",
    }
    report.write_text(
        json.dumps(data, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )
    print("CODEX_MIXAMO_NORMALIZED=" + json.dumps(
        {
            "bones": data["bones"],
            "meshes": data["meshes"],
            "height_m": data["height_m"],
            "glb_bytes": data["glb_bytes"],
        }
    ))


if __name__ == "__main__":
    main()
