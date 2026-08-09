#!/usr/bin/env python3
"""Shared Blender helpers for rebinding Rider meshes to rider_bot.

This module intentionally contains no Rider-specific CLI or legacy character
pipeline.  It preserves weights and materials while exposing common import,
rest-pose comparison, rebinding, deformation-test and export utilities.
"""

from __future__ import annotations

import json
import math
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
    modifier = obj.modifiers.new("rider_bot_armature", "ARMATURE")
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
    final_collection = bpy.data.collections.get("rider_compatible")
    if final_collection is None:
        final_collection = bpy.data.collections.new("rider_compatible")
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

