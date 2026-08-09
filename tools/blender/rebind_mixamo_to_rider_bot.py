#!/usr/bin/env python3
"""Map a normalized Mixamo skin onto rider_bot's exact rest armature."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

import bpy
from mathutils import Matrix, Vector

sys.path.insert(0, str(Path(__file__).resolve().parent))
import rider_bot_skinning_utils as shared


def arguments():
    parser = argparse.ArgumentParser()
    parser.add_argument("--source-blend", required=True)
    parser.add_argument("--reference-glb", required=True)
    parser.add_argument("--output-blend", required=True)
    parser.add_argument("--output-glb", required=True)
    parser.add_argument("--report", required=True)
    parser.add_argument("--expected-meshes", type=int, default=1)
    parser.add_argument("--max-influences", type=int, default=8)
    return parser.parse_args(
        sys.argv[sys.argv.index("--") + 1 :] if "--" in sys.argv else []
    )


def map_mesh_to_target_rest(mesh, source_armature, target_armature):
    source_bones = {
        bone.name: source_armature.matrix_world @ bone.matrix_local
        for bone in source_armature.data.bones
    }
    target_bones = {
        bone.name: target_armature.matrix_world @ bone.matrix_local
        for bone in target_armature.data.bones
    }
    if set(source_bones) != set(target_bones):
        raise RuntimeError("Source and target bone sets differ.")
    transforms = {
        name: target_bones[name] @ source_bones[name].inverted()
        for name in source_bones
    }
    group_names = {
        group.index: group.name for group in mesh.vertex_groups
    }
    world = mesh.matrix_world.copy()
    inverse_world = world.inverted()
    mapped = []
    maximum_influences = 0
    for vertex in mesh.data.vertices:
        influences = [
            element
            for element in vertex.groups
            if element.weight > 0.000001
            and group_names.get(element.group) in transforms
        ]
        if not influences:
            raise RuntimeError(
                f"{mesh.name}: vertex {vertex.index} has no valid influence."
            )
        maximum_influences = max(maximum_influences, len(influences))
        weight_sum = sum(element.weight for element in influences)
        source_world = world @ vertex.co
        target_world = Vector((0.0, 0.0, 0.0))
        for element in influences:
            bone_name = group_names[element.group]
            target_world += (
                transforms[bone_name] @ source_world
            ) * (element.weight / weight_sum)
        mapped.append(inverse_world @ target_world)
    for vertex, coordinate in zip(mesh.data.vertices, mapped):
        vertex.co = coordinate
    mesh.data.update()
    return maximum_influences


def main():
    args = arguments()
    source_path = Path(args.source_blend).resolve()
    reference_path = Path(args.reference_glb).resolve()
    output_blend = Path(args.output_blend).resolve()
    output_glb = Path(args.output_glb).resolve()
    report_path = Path(args.report).resolve()

    bpy.ops.wm.open_mainfile(filepath=str(source_path))
    source_armature, meshes = shared.find_source_character(
        args.expected_meshes
    )
    source_armature.data.pose_position = "REST"
    original_weights = {
        mesh.name: shared.weight_snapshot(mesh) for mesh in meshes
    }
    original_materials = {
        mesh.name: shared.material_names(mesh) for mesh in meshes
    }
    original_uvs = {
        mesh.name: [layer.name for layer in mesh.data.uv_layers]
        for mesh in meshes
    }

    previous_objects = set(bpy.data.objects)
    shared.import_glb(reference_path)
    imported = [
        obj for obj in bpy.data.objects if obj not in previous_objects
    ]
    target_armatures = [
        obj for obj in imported if obj.type == "ARMATURE"
    ]
    if len(target_armatures) != 1:
        raise RuntimeError(
            f"Reference import has {len(target_armatures)} armatures."
        )
    target_armature = target_armatures[0]
    target_armature.data.pose_position = "REST"
    source_records = shared.bone_records(source_armature)
    target_records = shared.bone_records(target_armature)
    rest_before = shared.compare_bone_records(
        source_records,
        target_records,
    )

    influence_counts = {}
    for mesh in meshes:
        influence_counts[mesh.name] = map_mesh_to_target_rest(
            mesh,
            source_armature,
            target_armature,
        )
        if influence_counts[mesh.name] > args.max_influences:
            raise RuntimeError(
                f"{mesh.name}: {influence_counts[mesh.name]} influences "
                f"exceed limit {args.max_influences}."
            )
        if shared.weight_snapshot(mesh) != original_weights[mesh.name]:
            raise RuntimeError(f"{mesh.name}: weights changed during mapping.")
        if shared.material_names(mesh) != original_materials[mesh.name]:
            raise RuntimeError(f"{mesh.name}: materials changed during mapping.")
        if [layer.name for layer in mesh.data.uv_layers] != original_uvs[mesh.name]:
            raise RuntimeError(f"{mesh.name}: UV layers changed during mapping.")
        world = mesh.matrix_world.copy()
        mesh.data.transform(world)
        mesh.matrix_world = Matrix.Identity(4)
        for modifier in list(mesh.modifiers):
            mesh.modifiers.remove(modifier)
        shared.rebind_mesh(mesh, target_armature)

    bpy.context.view_layer.update()
    rest_errors = {
        mesh.name: shared.rest_deformation_error(mesh) for mesh in meshes
    }
    if max(rest_errors.values(), default=0.0) > 0.00001:
        raise RuntimeError(f"Target rest deformation is non-zero: {rest_errors}")
    pose_tests, restore_error = shared.deformation_tests(
        target_armature,
        meshes,
    )
    shared.clear_animation()
    target_armature.name = "SKEL_Rider"
    target_armature.data.name = "SKEL_Rider"
    target_armature.data.pose_position = "REST"
    final_collection = shared.purge_to_final(target_armature, meshes)
    images = shared.pack_images()
    bpy.context.view_layer.update()

    output_blend.parent.mkdir(parents=True, exist_ok=True)
    output_glb.parent.mkdir(parents=True, exist_ok=True)
    report_path.parent.mkdir(parents=True, exist_ok=True)
    bpy.ops.wm.save_as_mainfile(
        filepath=str(output_blend),
        check_existing=False,
    )
    export_kwargs = shared.export_glb(
        output_glb,
        [target_armature, *meshes],
    )

    result = {
        "source": str(source_path),
        "reference": str(reference_path),
        "output_blend": str(output_blend),
        "output_glb": str(output_glb),
        "bones": len(target_armature.data.bones),
        "meshes": len(meshes),
        "vertices": sum(len(mesh.data.vertices) for mesh in meshes),
        "triangles": sum(shared.triangle_count(mesh) for mesh in meshes),
        "influences": influence_counts,
        "weights_preserved_exactly": True,
        "materials_preserved": True,
        "uvs_preserved": True,
        "rest_errors": rest_errors,
        "pose_tests": pose_tests,
        "pose_restore_error": restore_error,
        "rest_differences_before": shared.serializable_bone_rows(rest_before),
        "images": images,
        "final_collection": final_collection.name,
        "export_kwargs": export_kwargs,
        "glb_bytes": output_glb.stat().st_size,
        "status": "PASS",
    }
    report_path.write_text(
        json.dumps(result, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )
    print(
        "CODEX_MIXAMO_REBOUND="
        + json.dumps(
            {
                "bones": result["bones"],
                "meshes": result["meshes"],
                "vertices": result["vertices"],
                "triangles": result["triangles"],
                "max_influences": max(influence_counts.values()),
                "glb_bytes": result["glb_bytes"],
            }
        )
    )


if __name__ == "__main__":
    main()
