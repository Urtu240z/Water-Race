#!/usr/bin/env python3
"""Bake Rider01 geometry onto Rider_Bot's exact rest skeleton.

The source weights are never generated or transferred.  Rider01's source
armature is temporarily posed so every bone matches Rider_Bot's world-space
rest matrix.  The evaluated meshes are baked, their original vertex-group
weights are verified/restored exactly, and they are rebound to a literal copy
of Rider_Bot's armature.
"""

from __future__ import annotations

import argparse
import json
import math
import sys
from pathlib import Path

import bpy
from mathutils import Matrix, Vector


MATRIX_TOLERANCE = 2.0e-4
POSE_TESTS = (
    "mixamorig:Hips",
    "mixamorig:Spine",
    "mixamorig:Spine1",
    "mixamorig:Spine2",
    "mixamorig:Neck",
    "mixamorig:Head",
    "mixamorig:LeftArm",
    "mixamorig:LeftForeArm",
    "mixamorig:LeftHand",
    "mixamorig:LeftUpLeg",
    "mixamorig:LeftLeg",
    "mixamorig:LeftFoot",
    "mixamorig:RightArm",
    "mixamorig:RightForeArm",
    "mixamorig:RightHand",
    "mixamorig:RightUpLeg",
    "mixamorig:RightLeg",
    "mixamorig:RightFoot",
)


def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("--mode", choices=("build", "validate"), required=True)
    parser.add_argument("--source-blend")
    parser.add_argument("--reference-glb", required=True)
    parser.add_argument("--output-blend")
    parser.add_argument("--output-glb")
    parser.add_argument("--input-glb")
    parser.add_argument("--json", required=True)
    parser.add_argument("--report", required=True)
    parser.add_argument("--expected-meshes", type=int, default=10)
    parser.add_argument("--max-influences", type=int, default=4)
    args = parser.parse_args(
        sys.argv[sys.argv.index("--") + 1 :] if "--" in sys.argv else []
    )
    if args.mode == "build":
        required = ("source_blend", "output_blend", "output_glb")
    else:
        required = ("input_glb",)
    missing = [name for name in required if not getattr(args, name)]
    if missing:
        parser.error("Missing arguments: " + ", ".join(missing))
    return args


def supported_kwargs(operator, desired):
    properties = set(operator.get_rna_type().properties.keys())
    return {key: value for key, value in desired.items() if key in properties}


def import_glb(path):
    result = bpy.ops.import_scene.gltf(
        **supported_kwargs(bpy.ops.import_scene.gltf, {"filepath": str(path)})
    )
    if "FINISHED" not in result:
        raise RuntimeError(f"glTF import failed: {result}")


def export_glb(path, objects):
    bpy.ops.object.select_all(action="DESELECT")
    for obj in objects:
        obj.hide_set(False)
        obj.hide_viewport = False
        obj.hide_render = False
        obj.select_set(True)
    bpy.context.view_layer.objects.active = next(
        obj for obj in objects if obj.type == "ARMATURE"
    )
    desired = {
        "filepath": str(path),
        "export_format": "GLB",
        "use_selection": True,
        "export_selected": True,
        "export_selected_objects": True,
        "export_animations": False,
        "export_skins": True,
        "export_morph": False,
        "export_normals": True,
        "export_tangents": True,
        "export_texcoords": True,
        "export_materials": "EXPORT",
        "export_yup": True,
        "export_apply": False,
        "export_all_influences": True,
        "export_cameras": False,
        "export_lights": False,
        "export_extras": False,
        "export_draco_mesh_compression_enable": False,
        "export_rest_position_armature": True,
    }
    kwargs = supported_kwargs(bpy.ops.export_scene.gltf, desired)
    result = bpy.ops.export_scene.gltf(**kwargs)
    if "FINISHED" not in result:
        raise RuntimeError(f"glTF export failed: {result}")
    return kwargs


def matrix_values(value):
    return [float(value[row][column]) for row in range(4) for column in range(4)]


def matrix_error(left, right):
    return max(
        abs(a - b)
        for a, b in zip(matrix_values(left), matrix_values(right))
    )


def vector_tuple(value):
    return tuple(float(component) for component in value)


def quaternion_angle_degrees(left, right):
    delta = left.rotation_difference(right)
    degrees = math.degrees(delta.angle)
    return min(degrees, 360.0 - degrees)


def bone_depth(bone):
    depth = 0
    parent = bone.parent
    while parent:
        depth += 1
        parent = parent.parent
    return depth


def bone_records(armature):
    records = {}
    for bone in armature.data.bones:
        parent_local = (
            bone.parent.matrix_local.inverted() @ bone.matrix_local
            if bone.parent
            else bone.matrix_local.copy()
        )
        world = armature.matrix_world @ bone.matrix_local
        head_world = armature.matrix_world @ bone.head_local
        tail_world = armature.matrix_world @ bone.tail_local
        direction = tail_world - head_world
        records[bone.name] = {
            "name": bone.name,
            "parent": bone.parent.name if bone.parent else None,
            "armature_matrix": bone.matrix_local.copy(),
            "parent_local_matrix": parent_local,
            "world_matrix": world,
            "head_world": head_world,
            "tail_world": tail_world,
            "direction": direction.normalized() if direction.length else Vector((0, 0, 0)),
            "length": float((tail_world - head_world).length),
            "use_deform": bool(bone.use_deform),
        }
    return records


def compare_bone_records(source, target):
    source_names = set(source)
    target_names = set(target)
    if source_names != target_names:
        raise RuntimeError(
            "Bone sets differ: "
            f"source-only={sorted(source_names - target_names)}, "
            f"target-only={sorted(target_names - source_names)}"
        )
    rows = []
    parent_mismatches = []
    for name in sorted(source):
        left = source[name]
        right = target[name]
        if left["parent"] != right["parent"]:
            parent_mismatches.append(
                (name, left["parent"], right["parent"])
            )
        rows.append(
            {
                "bone": name,
                "source_parent": left["parent"],
                "target_parent": right["parent"],
                "parent_match": left["parent"] == right["parent"],
                "local_matrix_error": matrix_error(
                    left["parent_local_matrix"],
                    right["parent_local_matrix"],
                ),
                "armature_matrix_error": matrix_error(
                    left["armature_matrix"],
                    right["armature_matrix"],
                ),
                "world_matrix_error": matrix_error(
                    left["world_matrix"],
                    right["world_matrix"],
                ),
                "head_distance_m": (left["head_world"] - right["head_world"]).length,
                "tail_distance_m": (left["tail_world"] - right["tail_world"]).length,
                "length_difference_m": left["length"] - right["length"],
                "direction_angle_degrees": quaternion_angle_degrees(
                    left["world_matrix"].to_quaternion(),
                    right["world_matrix"].to_quaternion(),
                ),
            }
        )
    if parent_mismatches:
        raise RuntimeError(f"Hierarchy mismatch: {parent_mismatches}")
    return rows


def serializable_bone_rows(rows):
    result = []
    for row in rows:
        result.append(
            {
                key: (
                    round(float(value), 9)
                    if isinstance(value, float)
                    else value
                )
                for key, value in row.items()
            }
        )
    return result


def armature_modifier(obj, armature=None):
    modifiers = [
        modifier
        for modifier in obj.modifiers
        if modifier.type == "ARMATURE"
        and (armature is None or modifier.object == armature)
    ]
    return modifiers[0] if len(modifiers) == 1 else None


def find_source_character(expected_meshes):
    armatures = [obj for obj in bpy.context.scene.objects if obj.type == "ARMATURE"]
    if len(armatures) != 1:
        raise RuntimeError(f"Source has {len(armatures)} armatures; expected 1")
    armature = armatures[0]
    meshes = sorted(
        (
            obj
            for obj in bpy.context.scene.objects
            if obj.type == "MESH" and armature_modifier(obj, armature)
        ),
        key=lambda item: item.name,
    )
    if len(meshes) != expected_meshes:
        raise RuntimeError(
            f"Source has {len(meshes)} skinned meshes; expected {expected_meshes}"
        )
    return armature, meshes


def weight_snapshot(obj):
    groups = {group.index: group.name for group in obj.vertex_groups}
    return [
        tuple(
            sorted(
                (groups[element.group], float(element.weight))
                for element in vertex.groups
                if element.group in groups and element.weight > 0.0
            )
        )
        for vertex in obj.data.vertices
    ]


def weight_statistics(obj, valid_bones):
    groups = {group.index: group.name for group in obj.vertex_groups}
    unweighted = 0
    over_four = 0
    invalid_groups = set()
    maximum = 0
    for vertex in obj.data.vertices:
        influences = [
            element
            for element in vertex.groups
            if element.group in groups and element.weight > 0.000001
        ]
        maximum = max(maximum, len(influences))
        if not influences:
            unweighted += 1
        if len(influences) > 4:
            over_four += 1
        for element in influences:
            name = groups[element.group]
            if name not in valid_bones:
                invalid_groups.add(name)
    return {
        "unweighted": unweighted,
        "over_four": over_four,
        "max_influences": maximum,
        "invalid_groups": sorted(invalid_groups),
    }


def restore_weight_snapshot(obj, group_order, snapshot):
    for group in list(obj.vertex_groups):
        obj.vertex_groups.remove(group)
    groups = {name: obj.vertex_groups.new(name=name) for name in group_order}
    for vertex_index, influences in enumerate(snapshot):
        for group_name, weight in influences:
            groups[group_name].add([vertex_index], weight, "REPLACE")


def material_names(obj):
    return [
        slot.material.name if slot.material else None for slot in obj.material_slots
    ]


def object_bounds(obj):
    points = [obj.matrix_world @ Vector(corner) for corner in obj.bound_box]
    minimum = Vector(
        tuple(min(point[axis] for point in points) for axis in range(3))
    )
    maximum = Vector(
        tuple(max(point[axis] for point in points) for axis in range(3))
    )
    return {
        "min": vector_tuple(minimum),
        "max": vector_tuple(maximum),
        "size": vector_tuple(maximum - minimum),
    }


def apply_target_rest_pose(source_armature, target_armature):
    bpy.ops.object.select_all(action="DESELECT")
    source_armature.select_set(True)
    bpy.context.view_layer.objects.active = source_armature
    bpy.ops.object.mode_set(mode="EDIT")
    disconnected = 0
    for edit_bone in source_armature.data.edit_bones:
        if edit_bone.use_connect:
            edit_bone.use_connect = False
            disconnected += 1
    bpy.ops.object.mode_set(mode="OBJECT")
    source_armature.data.pose_position = "POSE"
    target_armature.data.pose_position = "REST"
    for pose_bone in source_armature.pose.bones:
        pose_bone.matrix_basis = Matrix.Identity(4)
    bpy.context.view_layer.update()
    ordered = sorted(source_armature.data.bones, key=bone_depth)
    source_inverse = source_armature.matrix_world.inverted()
    target_records = bone_records(target_armature)
    for bone in ordered:
        desired_world = target_records[bone.name]["world_matrix"]
        source_armature.pose.bones[bone.name].matrix = source_inverse @ desired_world
        bpy.context.view_layer.update()
    maximum_error = 0.0
    for bone in source_armature.data.bones:
        posed_world = (
            source_armature.matrix_world
            @ source_armature.pose.bones[bone.name].matrix
        )
        desired_world = target_records[bone.name]["world_matrix"]
        maximum_error = max(
            maximum_error,
            matrix_error(posed_world, desired_world),
        )
    if maximum_error > MATRIX_TOLERANCE:
        raise RuntimeError(
            f"Temporary target pose error {maximum_error:.9f} exceeds tolerance"
        )
    return maximum_error, disconnected


def bake_mesh(obj):
    source_data = obj.data
    source_vertex_count = len(source_data.vertices)
    source_weights = weight_snapshot(obj)
    source_group_order = [group.name for group in obj.vertex_groups]
    source_materials = [slot.material for slot in obj.material_slots]
    source_material_names = material_names(obj)
    source_uvs = [layer.name for layer in source_data.uv_layers]
    source_world = obj.matrix_world.copy()
    before_bounds = object_bounds(obj)

    for modifier in obj.modifiers:
        if modifier.type != "ARMATURE":
            modifier.show_viewport = False
    depsgraph = bpy.context.evaluated_depsgraph_get()
    evaluated = obj.evaluated_get(depsgraph)
    baked = bpy.data.meshes.new_from_object(
        evaluated,
        preserve_all_data_layers=True,
        depsgraph=depsgraph,
    )
    baked.name = obj.name + "_RiderBotRest"
    if len(baked.vertices) != source_vertex_count:
        raise RuntimeError(
            f"{obj.name}: bake changed vertex count "
            f"{source_vertex_count} -> {len(baked.vertices)}"
        )
    obj.data = baked
    obj.matrix_world = source_world
    for modifier in list(obj.modifiers):
        obj.modifiers.remove(modifier)
    if material_names(obj) != source_material_names:
        obj.data.materials.clear()
        for material in source_materials:
            obj.data.materials.append(material)
    if [layer.name for layer in obj.data.uv_layers] != source_uvs:
        raise RuntimeError(f"{obj.name}: UV layers changed during bake")
    if weight_snapshot(obj) != source_weights:
        restore_weight_snapshot(obj, source_group_order, source_weights)
    if weight_snapshot(obj) != source_weights:
        raise RuntimeError(f"{obj.name}: exact weights were not preserved")
    if source_data.users == 0:
        bpy.data.meshes.remove(source_data)
    obj.data.update()
    return {
        "mesh": obj.name,
        "vertices": source_vertex_count,
        "triangles": triangle_count(obj),
        "groups": len(source_group_order),
        "uv_layers": source_uvs,
        "materials": source_material_names,
        "weights_preserved_exactly": True,
        "bounds_before_source_rest": before_bounds,
        "bounds_after_target_bake": object_bounds(obj),
    }


def triangle_count(obj):
    obj.data.calc_loop_triangles()
    return len(obj.data.loop_triangles)


def rebind_mesh(obj, target_armature):
    world = obj.matrix_world.copy()
    obj.parent = target_armature
    obj.matrix_parent_inverse = target_armature.matrix_world.inverted()
    obj.matrix_world = world
    modifier = obj.modifiers.new("Rider_Bot_Armature", "ARMATURE")
    modifier.object = target_armature


def bake_object_world_transform(obj):
    world = obj.matrix_world.copy()
    obj.data.transform(world)
    obj.matrix_world = Matrix.Identity(4)
    obj.data.update()


def evaluated_positions(obj, maximum=None):
    depsgraph = bpy.context.evaluated_depsgraph_get()
    evaluated = obj.evaluated_get(depsgraph)
    mesh = evaluated.to_mesh()
    step = 1
    if maximum:
        step = max(1, len(mesh.vertices) // maximum)
    points = [
        evaluated.matrix_world @ mesh.vertices[index].co
        for index in range(0, len(mesh.vertices), step)
    ]
    evaluated.to_mesh_clear()
    return points


def rest_deformation_error(mesh):
    base = [mesh.matrix_world @ vertex.co for vertex in mesh.data.vertices]
    evaluated = evaluated_positions(mesh)
    if len(base) != len(evaluated):
        raise RuntimeError(f"{mesh.name}: rest evaluation changed topology")
    return max(
        ((left - right).length for left, right in zip(base, evaluated)),
        default=0.0,
    )


def reset_pose(armature):
    for pose_bone in armature.pose.bones:
        pose_bone.matrix_basis = Matrix.Identity(4)
    bpy.context.view_layer.update()


def deformation_tests(armature, meshes):
    armature.data.pose_position = "POSE"
    reset_pose(armature)
    base = {
        mesh.name: evaluated_positions(mesh, maximum=1500) for mesh in meshes
    }
    results = []
    for bone_name in POSE_TESTS:
        reset_pose(armature)
        pose_bone = armature.pose.bones.get(bone_name)
        if pose_bone is None:
            raise RuntimeError(f"Missing pose-test bone: {bone_name}")
        pose_bone.matrix_basis = (
            pose_bone.matrix_basis
            @ Matrix.Rotation(math.radians(12.0), 4, "X")
        )
        bpy.context.view_layer.update()
        moved_meshes = []
        maximum = 0.0
        for mesh in meshes:
            posed = evaluated_positions(mesh, maximum=1500)
            rest = base[mesh.name]
            displacements = [
                (left - right).length for left, right in zip(rest, posed)
            ]
            mesh_maximum = max(displacements, default=0.0)
            maximum = max(maximum, mesh_maximum)
            if any(value > 0.00001 for value in displacements):
                moved_meshes.append(mesh.name)
        if not moved_meshes:
            raise RuntimeError(f"{bone_name}: no geometry moved")
        if not math.isfinite(maximum) or maximum > 3.0:
            raise RuntimeError(
                f"{bone_name}: implausible displacement {maximum}"
            )
        results.append(
            {
                "bone": bone_name,
                "degrees": 12.0,
                "axis": "X",
                "moved_meshes": moved_meshes,
                "max_displacement_m": maximum,
            }
        )
    reset_pose(armature)
    restore_error = max(
        (
            matrix_error(pose_bone.matrix_basis, Matrix.Identity(4))
            for pose_bone in armature.pose.bones
        ),
        default=0.0,
    )
    if restore_error > 1.0e-12:
        raise RuntimeError(f"Pose tests left residual error {restore_error}")
    armature.data.pose_position = "REST"
    bpy.context.view_layer.update()
    return results, restore_error


def clear_animation():
    action_names = [action.name for action in bpy.data.actions]
    nla_tracks = []
    for obj in bpy.data.objects:
        if obj.animation_data:
            nla_tracks.extend(
                f"{obj.name}:{track.name}" for track in obj.animation_data.nla_tracks
            )
            obj.animation_data_clear()
    for datablocks in (bpy.data.armatures, bpy.data.meshes, bpy.data.materials):
        for datablock in datablocks:
            if hasattr(datablock, "animation_data_clear"):
                datablock.animation_data_clear()
    for action in list(bpy.data.actions):
        bpy.data.actions.remove(action)
    return action_names, nla_tracks


def pack_images():
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
            }
        )
    return records


def purge_to_final(target_armature, meshes):
    keep = {target_armature, *meshes}
    for obj in list(bpy.data.objects):
        if obj not in keep:
            bpy.data.objects.remove(obj, do_unlink=True)
    final_collection = bpy.data.collections.get("Rider01_RiderCompatible")
    if final_collection is None:
        final_collection = bpy.data.collections.new("Rider01_RiderCompatible")
        bpy.context.scene.collection.children.link(final_collection)
    for obj in keep:
        for collection in list(obj.users_collection):
            collection.objects.unlink(obj)
        final_collection.objects.link(obj)
    for collection in list(bpy.data.collections):
        if collection != final_collection:
            bpy.data.collections.remove(collection)
    for datablocks in (bpy.data.meshes, bpy.data.armatures, bpy.data.materials):
        for datablock in list(datablocks):
            if datablock.users == 0:
                datablocks.remove(datablock)
    return final_collection


def report_write(path, lines, append=False):
    output = Path(path)
    output.parent.mkdir(parents=True, exist_ok=True)
    with output.open("a" if append else "w", encoding="utf-8", newline="\n") as handle:
        if append and output.exists() and output.stat().st_size:
            handle.write("\n")
        handle.write("\n".join(lines) + "\n")


def write_json(path, data):
    output = Path(path)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(
        json.dumps(data, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )


def build(args):
    source_path = Path(args.source_blend).resolve()
    reference_path = Path(args.reference_glb).resolve()
    output_blend = Path(args.output_blend).resolve()
    output_glb = Path(args.output_glb).resolve()
    for path in (source_path, reference_path):
        if not path.is_file():
            raise FileNotFoundError(path)

    bpy.ops.wm.open_mainfile(filepath=str(source_path))
    source_armature, meshes = find_source_character(args.expected_meshes)
    source_armature_name = source_armature.name
    source_armature.data.pose_position = "REST"
    source_bones = bone_records(source_armature)
    valid_bones = set(source_bones)
    original_weights = {
        mesh.name: weight_snapshot(mesh) for mesh in meshes
    }
    original_weight_stats = {
        mesh.name: weight_statistics(mesh, valid_bones) for mesh in meshes
    }
    for mesh_name, stats in original_weight_stats.items():
        if (
            stats["unweighted"]
            or stats["max_influences"] > args.max_influences
            or stats["invalid_groups"]
        ):
            raise RuntimeError(f"{mesh_name}: invalid source weights {stats}")

    previous_objects = set(bpy.data.objects)
    import_glb(reference_path)
    imported = [obj for obj in bpy.data.objects if obj not in previous_objects]
    target_armatures = [obj for obj in imported if obj.type == "ARMATURE"]
    if len(target_armatures) != 1:
        raise RuntimeError(
            f"Rider_Bot import produced {len(target_armatures)} armatures"
        )
    target_armature = target_armatures[0]
    target_armature.data.pose_position = "REST"
    target_bones = bone_records(target_armature)
    rest_differences = compare_bone_records(source_bones, target_bones)

    temporary_pose_error, temporarily_disconnected = apply_target_rest_pose(
        source_armature,
        target_armature,
    )
    bake_records = []
    for mesh in meshes:
        bake_records.append(bake_mesh(mesh))
        if weight_snapshot(mesh) != original_weights[mesh.name]:
            raise RuntimeError(f"{mesh.name}: weights changed after bake")

    source_armature.data.pose_position = "REST"
    for mesh in meshes:
        bake_object_world_transform(mesh)
        rebind_mesh(mesh, target_armature)
    target_armature.data.pose_position = "REST"
    bpy.context.view_layer.update()
    rest_errors = {
        mesh.name: rest_deformation_error(mesh) for mesh in meshes
    }
    if max(rest_errors.values(), default=0.0) > 0.00001:
        raise RuntimeError(f"Non-zero target rest deformation: {rest_errors}")

    print(
        "CODEX_RIDER01_PREPOSE="
        + json.dumps(
            {
                "armature_matrix": [
                    list(row) for row in target_armature.matrix_world
                ],
                "meshes": {
                    mesh.name: {
                        "matrix": [list(row) for row in mesh.matrix_world],
                        "bounds": object_bounds(mesh),
                    }
                    for mesh in meshes
                },
            }
        )
    )
    pose_tests, pose_restore_error = deformation_tests(target_armature, meshes)
    actions_removed, nla_removed = clear_animation()
    target_armature.name = "SKEL_Rider"
    target_armature.data.name = "SKEL_Rider"
    target_armature.data.pose_position = "REST"
    final_collection = purge_to_final(target_armature, meshes)
    images = pack_images()
    bpy.context.view_layer.update()

    if len([obj for obj in bpy.context.scene.objects if obj.type == "ARMATURE"]) != 1:
        raise RuntimeError("Final blend does not contain exactly one armature")
    final_mesh_count = len(
        [obj for obj in bpy.context.scene.objects if obj.type == "MESH"]
    )
    if final_mesh_count != args.expected_meshes:
        raise RuntimeError(
            "Final blend does not contain the expected mesh count: "
            f"{final_mesh_count} != {args.expected_meshes}"
        )
    if bpy.data.actions:
        raise RuntimeError("Final blend still contains actions")

    output_blend.parent.mkdir(parents=True, exist_ok=True)
    output_glb.parent.mkdir(parents=True, exist_ok=True)
    bpy.ops.wm.save_as_mainfile(
        filepath=str(output_blend),
        check_existing=False,
    )
    export_kwargs = export_glb(
        output_glb,
        [target_armature, *meshes],
    )
    if not output_glb.is_file() or output_glb.stat().st_size == 0:
        raise RuntimeError("Compatible GLB was not created")

    result = {
        "mode": "build",
        "blender": bpy.app.version_string,
        "source_blend": str(source_path),
        "reference_glb": str(reference_path),
        "output_blend": str(output_blend),
        "output_glb": str(output_glb),
        "source_armature": source_armature_name,
        "target_armature": target_armature.name,
        "bone_count": len(target_bones),
        "rest_differences_before": serializable_bone_rows(rest_differences),
        "temporary_pose_max_matrix_error": temporary_pose_error,
        "source_bones_temporarily_disconnected": temporarily_disconnected,
        "bake": bake_records,
        "weights_before": original_weight_stats,
        "rest_deformation_errors": rest_errors,
        "pose_tests": pose_tests,
        "pose_restore_error": pose_restore_error,
        "actions_removed": actions_removed,
        "nla_removed": nla_removed,
        "images": images,
        "final_collection": final_collection.name,
        "final_objects": sorted(obj.name for obj in final_collection.objects),
        "triangles": sum(triangle_count(mesh) for mesh in meshes),
        "vertices": sum(len(mesh.data.vertices) for mesh in meshes),
        "materials": sorted(
            {
                slot.material.name
                for mesh in meshes
                for slot in mesh.material_slots
                if slot.material
            }
        ),
        "export_kwargs": export_kwargs,
        "glb_bytes": output_glb.stat().st_size,
    }
    write_json(args.json, result)

    table_lines = [
        "bone | source_parent | target_parent | local_error | global_error "
        "| head_m | tail_m | length_delta_m | direction_deg"
    ]
    table_lines.extend(
        (
            f"{row['bone']} | {row['source_parent']} | {row['target_parent']} "
            f"| {row['local_matrix_error']:.9f} "
            f"| {row['world_matrix_error']:.9f} "
            f"| {row['head_distance_m']:.9f} "
            f"| {row['tail_distance_m']:.9f} "
            f"| {row['length_difference_m']:.9f} "
            f"| {row['direction_angle_degrees']:.6f}"
        )
        for row in rest_differences
    )
    report_write(
        args.report,
        [
            "=== RIDER01 -> RIDER_BOT REST-POSE BUILD ===",
            f"Blender: {bpy.app.version_string}",
            f"Source: {source_path}",
            f"Reference: {reference_path}",
            f"Output blend: {output_blend}",
            f"Output GLB: {output_glb}",
            f"Bones: {len(target_bones)}",
            f"Meshes: {len(meshes)}",
            f"Vertices/triangles: {result['vertices']}/{result['triangles']}",
            f"Temporary pose max error: {temporary_pose_error:.9f}",
            "Source connected flags temporarily disabled: "
            f"{temporarily_disconnected}",
            "Weights preserved exactly: yes",
            "Automatic Weights: no",
            "Data Transfer: no",
            "Target-rest deformation max: "
            f"{max(rest_errors.values(), default=0.0):.9f}",
            f"Pose tests: {len(pose_tests)}",
            f"Pose restore error: {pose_restore_error:.12f}",
            f"Actions/NLA removed: {len(actions_removed)}/{len(nla_removed)}",
            "=== REST DIFFERENCES BEFORE BAKE ===",
            *table_lines,
            "BUILD_STATUS=PASS",
        ],
    )
    print(
        "CODEX_RIDER01_REST_BUILD="
        + json.dumps(
            {
                "bones": len(target_bones),
                "meshes": len(meshes),
                "vertices": result["vertices"],
                "triangles": result["triangles"],
                "pose_error": temporary_pose_error,
                "rest_error": max(rest_errors.values(), default=0.0),
                "pose_tests": len(pose_tests),
            }
        )
    )


def imported_character(objects):
    armatures = [obj for obj in objects if obj.type == "ARMATURE"]
    if len(armatures) != 1:
        raise RuntimeError(f"Import has {len(armatures)} armatures")
    armature = armatures[0]
    meshes = sorted(
        (
            obj
            for obj in objects
            if obj.type == "MESH" and armature_modifier(obj, armature)
        ),
        key=lambda item: item.name,
    )
    return armature, meshes


def validate(args):
    input_path = Path(args.input_glb).resolve()
    reference_path = Path(args.reference_glb).resolve()
    if not input_path.is_file() or not reference_path.is_file():
        raise FileNotFoundError(input_path if not input_path.is_file() else reference_path)

    bpy.ops.wm.read_factory_settings(use_empty=True)
    import_glb(input_path)
    compatible_objects = list(bpy.context.scene.objects)
    armature, meshes = imported_character(compatible_objects)
    if len(meshes) != args.expected_meshes:
        raise RuntimeError(
            "Compatible import has an unexpected skinned mesh count: "
            f"{len(meshes)} != {args.expected_meshes}"
        )
    compatible_records = bone_records(armature)
    valid_bones = set(compatible_records)
    weight_stats = {
        mesh.name: weight_statistics(mesh, valid_bones) for mesh in meshes
    }
    for name, stats in weight_stats.items():
        if (
            stats["unweighted"]
            or stats["max_influences"] > args.max_influences
            or stats["invalid_groups"]
        ):
            raise RuntimeError(f"{name}: invalid imported weights {stats}")
    rest_errors = {mesh.name: rest_deformation_error(mesh) for mesh in meshes}
    if max(rest_errors.values(), default=0.0) > 0.00001:
        raise RuntimeError(f"Imported rest deformation: {rest_errors}")
    pose_tests, restore_error = deformation_tests(armature, meshes)
    compatible_object_names = {obj.name for obj in bpy.context.scene.objects}

    before_reference = set(bpy.data.objects)
    import_glb(reference_path)
    reference_objects = [
        obj for obj in bpy.data.objects if obj not in before_reference
    ]
    reference_armature, _reference_meshes = imported_character(reference_objects)
    reference_records = bone_records(reference_armature)
    final_comparison = compare_bone_records(
        compatible_records,
        reference_records,
    )
    maximums = {
        "local_matrix_error": max(
            row["local_matrix_error"] for row in final_comparison
        ),
        "armature_matrix_error": max(
            row["armature_matrix_error"] for row in final_comparison
        ),
        "world_matrix_error": max(
            row["world_matrix_error"] for row in final_comparison
        ),
        "head_distance_m": max(
            row["head_distance_m"] for row in final_comparison
        ),
        "tail_distance_m": max(
            row["tail_distance_m"] for row in final_comparison
        ),
        "length_difference_m": max(
            abs(row["length_difference_m"]) for row in final_comparison
        ),
        "direction_angle_degrees": max(
            row["direction_angle_degrees"] for row in final_comparison
        ),
    }
    if max(
        maximums["local_matrix_error"],
        maximums["armature_matrix_error"],
        maximums["world_matrix_error"],
        maximums["head_distance_m"],
        maximums["tail_distance_m"],
        maximums["length_difference_m"],
    ) > MATRIX_TOLERANCE:
        raise RuntimeError(f"Final rest mismatch: {maximums}")
    if maximums["direction_angle_degrees"] > 0.02:
        raise RuntimeError(f"Final orientation mismatch: {maximums}")
    if bpy.data.actions:
        raise RuntimeError(
            f"Compatible import has actions: {[action.name for action in bpy.data.actions]}"
        )

    existing = {}
    json_path = Path(args.json)
    if json_path.is_file():
        existing = json.loads(json_path.read_text(encoding="utf-8"))
    existing["validation"] = {
        "blender": bpy.app.version_string,
        "input_glb": str(input_path),
        "reference_glb": str(reference_path),
        "armature": armature.name,
        "bone_count": len(compatible_records),
        "mesh_count": len(meshes),
        "mesh_names": sorted(mesh.name for mesh in meshes),
        "weight_stats": weight_stats,
        "rest_deformation_errors": rest_errors,
        "pose_tests": pose_tests,
        "pose_restore_error": restore_error,
        "final_rest_maximums": maximums,
        "materials": sorted(
            {
                slot.material.name
                for mesh in meshes
                for slot in mesh.material_slots
                if slot.material
            }
        ),
        "images": [
            {
                "name": image.name,
                "size": [int(image.size[0]), int(image.size[1])],
                "packed": bool(image.packed_file),
            }
            for image in bpy.data.images
            if image.name in {
                node.image.name
                for material in bpy.data.materials
                if material.use_nodes and material.node_tree
                for node in material.node_tree.nodes
                if node.type == "TEX_IMAGE" and node.image
            }
        ],
        "actions": [action.name for action in bpy.data.actions],
        "compatible_object_names": sorted(compatible_object_names),
        "status": "PASS",
    }
    write_json(args.json, existing)
    report_write(
        args.report,
        [
            "=== CLEAN BLENDER REOPEN ===",
            f"Input: {input_path}",
            f"Armature/bones: {armature.name}/{len(compatible_records)}",
            f"Skinned meshes: {len(meshes)}",
            f"Final rest maximums: {maximums}",
            f"Target-rest deformation max: {max(rest_errors.values()):.9f}",
            f"Pose tests/restore error: {len(pose_tests)}/{restore_error:.12f}",
            (
                "Unweighted/max-influences/invalid groups: "
                f"0/{max((item['max_influences'] for item in weight_stats.values()), default=0)}/0"
            ),
            "Animations: 0",
            "VALIDATION_STATUS=PASS",
        ],
        append=True,
    )
    print(
        "CODEX_RIDER01_REST_VALIDATE="
        + json.dumps(
            {
                "bones": len(compatible_records),
                "meshes": len(meshes),
                "rest_maximums": maximums,
                "pose_tests": len(pose_tests),
                "status": "PASS",
            }
        )
    )


def main():
    args = parse_args()
    if args.mode == "build":
        build(args)
    else:
        validate(args)


if __name__ == "__main__":
    main()
