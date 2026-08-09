#!/usr/bin/env python3
"""Build a single-mesh Mixamo character on rider_bot's canonical skeleton.

The source GLB is read-only. Helper geometry and source animation data are
discarded. Vertex weights, UVs and materials are preserved while the mesh is
rebaked from its source rest pose to rider_bot's exact rest skeleton.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

import bpy
from mathutils import Matrix, Vector

sys.path.insert(0, str(Path(__file__).resolve().parent))
import rider_bot_skinning_utils as shared


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--skin-id", required=True)
    parser.add_argument("--source-glb", required=True)
    parser.add_argument("--reference-glb", required=True)
    parser.add_argument("--output-blend", required=True)
    parser.add_argument("--output-glb", required=True)
    parser.add_argument("--report", required=True)
    arguments = parser.parse_args(
        sys.argv[sys.argv.index("--") + 1 :] if "--" in sys.argv else []
    )
    if not arguments.skin_id.replace("_", "").isalnum():
        parser.error("--skin-id must contain only letters, numbers or underscores")
    return arguments


def rigid(matrix: Matrix) -> Matrix:
    return Matrix.LocRotScale(
        matrix.translation,
        matrix.to_quaternion(),
        Vector((1.0, 1.0, 1.0)),
    )


def map_mesh_to_target_rest(
    mesh: bpy.types.Object,
    source_armature: bpy.types.Object,
    target_armature: bpy.types.Object,
) -> tuple[int, list[str]]:
    source_bones = {
        bone.name: rigid(source_armature.matrix_world @ bone.matrix_local)
        for bone in source_armature.data.bones
    }
    target_bones = {
        bone.name: rigid(target_armature.matrix_world @ bone.matrix_local)
        for bone in target_armature.data.bones
    }
    source_only = sorted(set(source_bones) - set(target_bones))
    if source_only:
        raise RuntimeError(
            f"Source-only bones cannot be mapped: {source_only}"
        )
    missing_source_bones = sorted(set(target_bones) - set(source_bones))
    transforms = {
        name: target_bones[name] @ source_matrix.inverted()
        for name, source_matrix in source_bones.items()
    }
    group_names = {group.index: group.name for group in mesh.vertex_groups}
    mesh_world = mesh.matrix_world.copy()
    inverse_world = mesh_world.inverted()
    mapped: list[Vector] = []
    maximum_influences = 0

    for vertex in mesh.data.vertices:
        influences = [
            element
            for element in vertex.groups
            if (
                element.weight > 0.000001
                and group_names.get(element.group) in transforms
            )
        ]
        if not influences:
            raise RuntimeError(
                f"{mesh.name}: vertex {vertex.index} has no canonical influence"
            )
        maximum_influences = max(maximum_influences, len(influences))
        weight_sum = sum(element.weight for element in influences)
        source_world = mesh_world @ vertex.co
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
    return maximum_influences, missing_source_bones


def purge_to_final(
    skin_id: str,
    armature: bpy.types.Object,
    mesh: bpy.types.Object,
) -> bpy.types.Collection:
    keep = {armature, mesh}
    for obj in list(bpy.data.objects):
        if obj not in keep:
            bpy.data.objects.remove(obj, do_unlink=True)

    collection = bpy.data.collections.get(f"{skin_id}_RiderCompatible")
    if collection is None:
        collection = bpy.data.collections.new(
            f"{skin_id}_RiderCompatible"
        )
        bpy.context.scene.collection.children.link(collection)
    for obj in keep:
        for current in list(obj.users_collection):
            current.objects.unlink(obj)
        collection.objects.link(obj)
    for current in list(bpy.data.collections):
        if current != collection:
            bpy.data.collections.remove(current)
    for datablocks in (
        bpy.data.meshes,
        bpy.data.armatures,
        bpy.data.materials,
    ):
        for datablock in list(datablocks):
            if datablock.users == 0:
                datablocks.remove(datablock)
    for image in list(bpy.data.images):
        if image.users == 0:
            bpy.data.images.remove(image)
    return collection


def persistent_image_records() -> list[dict]:
    records = []
    for image in bpy.data.images:
        if image.source in {"VIEWER", "GENERATED"}:
            continue
        if image.packed_file is None and image.has_data:
            image.pack()
        records.append(
            {
                "name": image.name,
                "size": [int(image.size[0]), int(image.size[1])],
                "packed": bool(image.packed_file),
                "colorspace": image.colorspace_settings.name,
            }
        )
    return records


def validate_clean_glb(
    compatible_path: Path,
    reference_path: Path,
) -> dict:
    bpy.ops.wm.read_factory_settings(use_empty=True)
    shared.import_glb(compatible_path)
    compatible_objects = list(bpy.context.scene.objects)
    armature, meshes = shared.imported_character(compatible_objects)
    if len(meshes) != 1:
        raise RuntimeError(
            f"Compatible GLB has {len(meshes)} skinned meshes; expected 1"
        )
    importer_helpers = [
        obj.name
        for obj in compatible_objects
        if (
            obj not in {armature, *meshes}
            and obj.name.startswith("Icosphere")
            and obj.parent is None
            and not obj.vertex_groups
        )
    ]
    extra_objects = [
        obj.name
        for obj in compatible_objects
        if (
            obj not in {armature, *meshes}
            and obj.name not in importer_helpers
        )
    ]
    if extra_objects:
        raise RuntimeError(
            f"Compatible GLB still contains helper objects: {extra_objects}"
        )
    records = shared.bone_records(armature)
    stats = shared.weight_statistics(meshes[0], set(records))
    if (
        stats["unweighted"]
        or stats["max_influences"] > 4
        or stats["invalid_groups"]
    ):
        raise RuntimeError(f"Compatible GLB has invalid weights: {stats}")
    rest_error = shared.rest_deformation_error(meshes[0])
    if rest_error > 0.00001:
        raise RuntimeError(
            f"Compatible GLB rest deformation is {rest_error:.9f}"
        )

    before_reference = set(bpy.data.objects)
    shared.import_glb(reference_path)
    reference_objects = [
        obj for obj in bpy.data.objects if obj not in before_reference
    ]
    reference_armature, _ = shared.imported_character(reference_objects)
    comparison = shared.compare_bone_records(
        records,
        shared.bone_records(reference_armature),
    )
    maximum_local_error = max(
        (row["local_matrix_error"] for row in comparison),
        default=0.0,
    )
    maximum_world_error = max(
        (row["world_matrix_error"] for row in comparison),
        default=0.0,
    )
    if maximum_local_error > shared.MATRIX_TOLERANCE:
        raise RuntimeError(
            f"Compatible GLB local rest error {maximum_local_error:.9f}"
        )
    if maximum_world_error > shared.MATRIX_TOLERANCE:
        raise RuntimeError(
            f"Compatible GLB world rest error {maximum_world_error:.9f}"
        )
    return {
        "objects": sorted(
            {armature.name, *(mesh.name for mesh in meshes)}
        ),
        "blender_import_visualization_helpers": importer_helpers,
        "skeletons": 1,
        "skinned_meshes": 1,
        "bones": len(records),
        "weight_stats": stats,
        "rest_deformation_error": rest_error,
        "max_local_rest_error": maximum_local_error,
        "max_world_rest_error": maximum_world_error,
    }


def main() -> None:
    args = parse_args()
    source_path = Path(args.source_glb).resolve()
    reference_path = Path(args.reference_glb).resolve()
    output_blend = Path(args.output_blend).resolve()
    output_glb = Path(args.output_glb).resolve()
    report_path = Path(args.report).resolve()
    for required in (source_path, reference_path):
        if not required.is_file():
            raise FileNotFoundError(required)

    bpy.ops.wm.read_factory_settings(use_empty=True)
    shared.import_glb(source_path)
    source_objects = list(bpy.context.scene.objects)
    source_armature, meshes = shared.imported_character(source_objects)
    if len(meshes) != 1:
        raise RuntimeError(
            f"{args.skin_id} has {len(meshes)} skinned meshes; expected 1"
        )
    mesh = meshes[0]
    source_armature_name = source_armature.name
    source_armature.data.pose_position = "REST"
    source_records = shared.bone_records(source_armature)
    source_stats = shared.weight_statistics(mesh, set(source_records))
    if (
        source_stats["unweighted"]
        or source_stats["max_influences"] > 4
        or source_stats["invalid_groups"]
    ):
        raise RuntimeError(
            f"{args.skin_id} source weights are invalid: {source_stats}"
        )

    helpers = sorted(
        obj.name
        for obj in source_objects
        if obj not in {source_armature, mesh}
    )
    original_weights = shared.weight_snapshot(mesh)
    original_materials = shared.material_names(mesh)
    original_uvs = [layer.name for layer in mesh.data.uv_layers]
    source_bounds = shared.object_bounds(mesh)
    source_actions = [action.name for action in bpy.data.actions]

    before_reference = set(bpy.data.objects)
    shared.import_glb(reference_path)
    reference_objects = [
        obj for obj in bpy.data.objects if obj not in before_reference
    ]
    target_armature, _ = shared.imported_character(reference_objects)
    target_armature.data.pose_position = "REST"
    target_records = shared.bone_records(target_armature)

    maximum_influences, missing_source_bones = map_mesh_to_target_rest(
        mesh,
        source_armature,
        target_armature,
    )
    if maximum_influences > 4:
        raise RuntimeError(
            f"{args.skin_id} has {maximum_influences} influences; maximum is 4"
        )
    if shared.weight_snapshot(mesh) != original_weights:
        raise RuntimeError(
            f"{args.skin_id} numeric weights changed during mapping"
        )
    if shared.material_names(mesh) != original_materials:
        raise RuntimeError(
            f"{args.skin_id} material slots changed during mapping"
        )
    if [layer.name for layer in mesh.data.uv_layers] != original_uvs:
        raise RuntimeError(
            f"{args.skin_id} UV layers changed during mapping"
        )

    mesh.data.transform(mesh.matrix_world)
    mesh.matrix_world = Matrix.Identity(4)
    for modifier in list(mesh.modifiers):
        mesh.modifiers.remove(modifier)
    shared.rebind_mesh(mesh, target_armature)
    bpy.context.view_layer.update()

    rest_error = shared.rest_deformation_error(mesh)
    if rest_error > 0.00001:
        raise RuntimeError(
            f"Mapped {args.skin_id} rest deformation is {rest_error:.9f}"
        )
    pose_tests, pose_restore_error = shared.deformation_tests(
        target_armature,
        [mesh],
    )
    actions_removed, nla_removed = shared.clear_animation()
    custom_shapes_removed = 0
    for pose_bone in target_armature.pose.bones:
        if pose_bone.custom_shape is not None:
            pose_bone.custom_shape = None
            custom_shapes_removed += 1

    target_armature.name = "SKEL_Rider"
    target_armature.data.name = "SKEL_Rider"
    target_armature.data.pose_position = "REST"
    mesh.name = f"{args.skin_id}_Body"
    mesh.data.name = f"{args.skin_id}_Body_Data"
    final_collection = purge_to_final(
        args.skin_id,
        target_armature,
        mesh,
    )
    images = persistent_image_records()
    bpy.context.view_layer.update()

    for output in (output_blend, output_glb, report_path):
        output.parent.mkdir(parents=True, exist_ok=True)
    bpy.ops.wm.save_as_mainfile(
        filepath=str(output_blend),
        check_existing=False,
    )
    export_kwargs = shared.export_glb(
        output_glb,
        [target_armature, mesh],
    )
    final_vertices = len(mesh.data.vertices)
    final_triangles = shared.triangle_count(mesh)
    final_bounds = shared.object_bounds(mesh)
    final_collection_name = final_collection.name
    final_mesh_name = mesh.name
    final_armature_name = target_armature.name
    clean_validation = validate_clean_glb(output_glb, reference_path)

    result = {
        "title": f"{args.skin_id} RiderRig-compatible build",
        "status": "PASS",
        "blender": bpy.app.version_string,
        "source_glb": str(source_path),
        "source_unchanged": True,
        "reference_glb": str(reference_path),
        "output_blend": str(output_blend),
        "output_glb": str(output_glb),
        "source_armature": source_armature_name,
        "source_bones": len(source_records),
        "canonical_bones": len(target_records),
        "canonical_bones_missing_in_source": missing_source_bones,
        "source_actions_removed": source_actions,
        "source_helper_objects_removed": helpers,
        "source_bounds": source_bounds,
        "vertices": final_vertices,
        "triangles": final_triangles,
        "materials": original_materials,
        "uv_layers": original_uvs,
        "images": images,
        "weight_stats": source_stats,
        "weights_preserved_exactly": True,
        "maximum_influences": maximum_influences,
        "mapped_bounds": final_bounds,
        "rest_deformation_error": rest_error,
        "pose_tests": pose_tests,
        "pose_restore_error": pose_restore_error,
        "actions_removed_during_cleanup": actions_removed,
        "nla_removed_during_cleanup": nla_removed,
        "custom_bone_shapes_removed": custom_shapes_removed,
        "final_collection": final_collection_name,
        "final_objects": [final_mesh_name, final_armature_name],
        "export_kwargs": export_kwargs,
        "output_glb_bytes": output_glb.stat().st_size,
        "clean_reopen_validation": clean_validation,
    }
    report_path.write_text(
        json.dumps(result, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )
    print(
        "CODEX_RIDER_SKIN_BUILD="
        + json.dumps(
            {
                "skin": args.skin_id,
                "status": result["status"],
                "source_bones": result["source_bones"],
                "canonical_bones": result["canonical_bones"],
                "missing_source_bones": missing_source_bones,
                "vertices": result["vertices"],
                "triangles": result["triangles"],
                "helpers_removed": helpers,
                "output_glb_bytes": result["output_glb_bytes"],
            }
        )
    )


if __name__ == "__main__":
    main()

