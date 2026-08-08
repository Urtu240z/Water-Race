#!/usr/bin/env python3
"""Prepare and validate a skinned Mixamo character for Water Race.

Default mode is ``prepare`` and accepts the four arguments requested by the
project workflow. ``validate`` and ``compare`` are intentionally part of the
same script so both follow-up audits can run in separate, clean Blender
processes without duplicating Blender-specific logic.
"""

from __future__ import annotations

import argparse
import math
import os
import sys
import traceback
from pathlib import Path

import bmesh
import bpy
from mathutils import Matrix, Vector


REQUIRED_BONES = [
    "mixamorig_Hips",
    "mixamorig_Spine",
    "mixamorig_Spine1",
    "mixamorig_Spine2",
    "mixamorig_Neck",
    "mixamorig_Head",
    "mixamorig_LeftShoulder",
    "mixamorig_LeftArm",
    "mixamorig_LeftForeArm",
    "mixamorig_LeftHand",
    "mixamorig_RightShoulder",
    "mixamorig_RightArm",
    "mixamorig_RightForeArm",
    "mixamorig_RightHand",
    "mixamorig_LeftUpLeg",
    "mixamorig_LeftLeg",
    "mixamorig_LeftFoot",
    "mixamorig_LeftToeBase",
    "mixamorig_RightUpLeg",
    "mixamorig_RightLeg",
    "mixamorig_RightFoot",
    "mixamorig_RightToeBase",
]


def script_arguments() -> list[str]:
    return sys.argv[sys.argv.index("--") + 1 :] if "--" in sys.argv else []


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--mode", choices=("prepare", "validate", "compare"), default="prepare")
    parser.add_argument("--input-fbx")
    parser.add_argument("--output-blend")
    parser.add_argument("--output-glb")
    parser.add_argument("--input-glb")
    parser.add_argument("--reference-glb")
    parser.add_argument("--report", required=True)
    args = parser.parse_args(script_arguments())
    required_by_mode = {
        "prepare": ("input_fbx", "output_blend", "output_glb"),
        "validate": ("input_glb",),
        "compare": ("input_glb", "reference_glb"),
    }
    missing = [name for name in required_by_mode[args.mode] if not getattr(args, name)]
    if missing:
        parser.error(f"Missing arguments for {args.mode}: {', '.join(missing)}")
    return args


def write_report(report_path: str, lines: list[str], append: bool = False) -> None:
    path = Path(report_path)
    path.parent.mkdir(parents=True, exist_ok=True)
    mode = "a" if append else "w"
    with path.open(mode, encoding="utf-8", newline="\n") as handle:
        if append:
            handle.write("\n")
        handle.write("\n".join(lines))
        handle.write("\n")


def replace_report_section(report_path: str, marker: str, lines: list[str]) -> None:
    path = Path(report_path)
    existing = path.read_text(encoding="utf-8") if path.exists() else ""
    marker_index = existing.find(marker)
    if marker_index >= 0:
        existing = existing[:marker_index].rstrip()
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8", newline="\n") as handle:
        if existing:
            handle.write(existing)
            handle.write("\n\n")
        handle.write("\n".join(lines))
        handle.write("\n")


def empty_scene() -> None:
    if bpy.context.mode != "OBJECT":
        bpy.ops.object.mode_set(mode="OBJECT")
    bpy.ops.object.select_all(action="SELECT")
    bpy.ops.object.delete(use_global=False)
    for collection in list(bpy.data.collections):
        if collection.users == 0:
            bpy.data.collections.remove(collection)


def supported_operator_kwargs(operator, desired: dict) -> dict:
    supported = set(operator.get_rna_type().properties.keys())
    return {key: value for key, value in desired.items() if key in supported}


def import_fbx(filepath: str) -> dict:
    desired = {
        "filepath": filepath,
        "use_prepost_rot": True,
        "ignore_leaf_bones": True,
        "automatic_bone_orientation": False,
        "use_anim": False,
        "use_image_search": True,
        "global_scale": 1.0,
    }
    operator = getattr(bpy.ops.import_scene, "fbx", None)
    if operator is None:
        operator = getattr(bpy.ops.wm, "fbx_import", None)
    if operator is None:
        raise RuntimeError("This Blender installation has no available FBX importer.")
    kwargs = supported_operator_kwargs(operator, desired)
    result = operator(**kwargs)
    if "FINISHED" not in result:
        raise RuntimeError(f"FBX import failed: {result}")
    return kwargs


def import_glb(filepath: str) -> dict:
    operator = bpy.ops.import_scene.gltf
    kwargs = supported_operator_kwargs(operator, {"filepath": filepath})
    result = operator(**kwargs)
    if "FINISHED" not in result:
        raise RuntimeError(f"glTF import failed: {result}")
    return kwargs


def export_glb(filepath: str) -> dict:
    operator = bpy.ops.export_scene.gltf
    desired = {
        "filepath": filepath,
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
    kwargs = supported_operator_kwargs(operator, desired)
    result = operator(**kwargs)
    if "FINISHED" not in result:
        raise RuntimeError(f"GLB export failed: {result}")
    return kwargs


def object_inventory() -> dict[str, list[bpy.types.Object]]:
    return {
        kind: [obj for obj in bpy.data.objects if obj.type == kind]
        for kind in ("ARMATURE", "MESH", "CAMERA", "LIGHT", "EMPTY")
    }


def count_nla() -> tuple[int, int]:
    tracks = 0
    strips = 0
    for obj in bpy.data.objects:
        data = obj.animation_data
        if data is None:
            continue
        tracks += len(data.nla_tracks)
        strips += sum(len(track.strips) for track in data.nla_tracks)
    return tracks, strips


def clear_animation() -> tuple[int, int, int]:
    action_count = len(bpy.data.actions)
    nla_tracks, nla_strips = count_nla()
    datablocks = list(bpy.data.objects)
    datablocks += list(bpy.data.armatures)
    datablocks += list(bpy.data.meshes)
    datablocks += list(bpy.data.materials)
    for datablock in datablocks:
        if hasattr(datablock, "animation_data_clear"):
            datablock.animation_data_clear()
    for action in list(bpy.data.actions):
        bpy.data.actions.remove(action)
    return action_count, nla_tracks, nla_strips


def remove_unnecessary_objects() -> dict[str, int]:
    removed = {"CAMERA": 0, "LIGHT": 0, "EMPTY": 0, "OTHER": 0}
    for obj in list(bpy.data.objects):
        if obj.type in {"CAMERA", "LIGHT"}:
            removed[obj.type] += 1
            bpy.data.objects.remove(obj, do_unlink=True)
    for empty in [obj for obj in list(bpy.data.objects) if obj.type == "EMPTY"]:
        parent = empty.parent
        for child in list(empty.children):
            world = child.matrix_world.copy()
            child.parent = parent
            child.matrix_world = world
        bpy.data.objects.remove(empty, do_unlink=True)
        removed["EMPTY"] += 1
    for obj in list(bpy.data.objects):
        if obj.type not in {"ARMATURE", "MESH"}:
            bpy.data.objects.remove(obj, do_unlink=True)
            removed["OTHER"] += 1
    return removed


def remove_unused_datablocks() -> dict[str, int]:
    removed = {"materials": 0, "images": 0, "meshes": 0, "armatures": 0}
    for material in list(bpy.data.materials):
        if material.users == 0:
            bpy.data.materials.remove(material)
            removed["materials"] += 1
    for image in list(bpy.data.images):
        if image.users == 0 and image.source not in {"VIEWER"}:
            bpy.data.images.remove(image)
            removed["images"] += 1
    for mesh in list(bpy.data.meshes):
        if mesh.users == 0:
            bpy.data.meshes.remove(mesh)
            removed["meshes"] += 1
    for armature in list(bpy.data.armatures):
        if armature.users == 0:
            bpy.data.armatures.remove(armature)
            removed["armatures"] += 1
    return removed


def combined_world_bounds(meshes: list[bpy.types.Object]) -> tuple[list[float], list[float], float]:
    if not meshes:
        raise RuntimeError("No meshes available for bounding-box measurement.")
    points = [
        obj.matrix_world @ Vector(corner)
        for obj in meshes
        for corner in obj.bound_box
    ]
    minimum = [min(point[index] for point in points) for index in range(3)]
    maximum = [max(point[index] for point in points) for index in range(3)]
    return minimum, maximum, maximum[2] - minimum[2]


def uniformly_scale_character(objects: list[bpy.types.Object], factor: float) -> None:
    desired_world = {
        obj: Matrix.Scale(factor, 4) @ obj.matrix_world.copy()
        for obj in objects
    }
    for obj in sorted(objects, key=lambda item: len(item.parent_recursive)):
        obj.matrix_world = desired_world[obj]
    bpy.context.view_layer.update()


def validate_and_fix_height(armature: bpy.types.Object, meshes: list[bpy.types.Object]) -> tuple[float, float]:
    _minimum, _maximum, height = combined_world_bounds(meshes)
    factor = 1.0
    if height > 20.0:
        factor = 0.01
    elif 0.0 < height < 0.10:
        factor = 100.0
    elif not 1.4 <= height <= 2.2:
        raise RuntimeError(
            f"Character height {height:.6f} m is outside the plausible range "
            "and does not indicate an unambiguous x100 unit error."
        )
    if factor != 1.0:
        uniformly_scale_character([armature, *meshes], factor)
        _minimum, _maximum, height = combined_world_bounds(meshes)
    if not 1.4 <= height <= 2.2:
        raise RuntimeError(f"Height remains implausible after uniform correction: {height:.6f} m")
    return height, factor


def armature_modifier(mesh: bpy.types.Object, armature: bpy.types.Object):
    for modifier in mesh.modifiers:
        if modifier.type == "ARMATURE" and modifier.object == armature:
            return modifier
    return None


def weighted_vertex_count(mesh: bpy.types.Object) -> int:
    return sum(1 for vertex in mesh.data.vertices if any(group.weight > 0.0 for group in vertex.groups))


def validate_skin(armature: bpy.types.Object, meshes: list[bpy.types.Object]) -> list[dict]:
    results = []
    deformed_count = 0
    for mesh in meshes:
        modifier = armature_modifier(mesh, armature)
        weighted = weighted_vertex_count(mesh)
        result = {
            "name": mesh.name,
            "vertices": len(mesh.data.vertices),
            "groups": len(mesh.vertex_groups),
            "weighted_vertices": weighted,
            "armature_modifier": modifier is not None,
        }
        results.append(result)
        if modifier is not None and len(mesh.vertex_groups) > 0 and weighted > 0:
            deformed_count += 1
    if deformed_count == 0:
        raise RuntimeError("No mesh is validly deformed by the main armature.")
    return results


def triangulate_ngons(meshes: list[bpy.types.Object]) -> int:
    triangulated = 0
    for mesh_object in meshes:
        if mesh_object.data.shape_keys is not None:
            if any(len(polygon.vertices) > 4 for polygon in mesh_object.data.polygons):
                raise RuntimeError(
                    f"{mesh_object.name} contains n-gons and shape keys; "
                    "automatic triangulation would risk morph data."
                )
            continue
        edit_mesh = bmesh.new()
        edit_mesh.from_mesh(mesh_object.data)
        ngons = [face for face in edit_mesh.faces if len(face.verts) > 4]
        triangulated += len(ngons)
        if ngons:
            bmesh.ops.triangulate(edit_mesh, faces=ngons)
            edit_mesh.to_mesh(mesh_object.data)
            mesh_object.data.update()
        edit_mesh.free()
    return triangulated


def rename_character(armature: bpy.types.Object, meshes: list[bpy.types.Object]) -> None:
    armature.name = "SKEL_Racer"
    armature.data.name = "SKEL_Racer"
    for index, mesh in enumerate(meshes, start=1):
        mesh.name = "Racer_Mesh" if len(meshes) == 1 else f"Racer_Mesh_{index:02d}"
        mesh.data.name = f"{mesh.name}_Data"


def find_texture(root: Path, basename: str) -> Path | None:
    if not basename:
        return None
    basename_lower = basename.lower()
    for directory, _subdirs, filenames in os.walk(root):
        for filename in filenames:
            if filename.lower() == basename_lower:
                return Path(directory) / filename
    return None


def relink_and_pack_images(fbx_path: str) -> tuple[list[dict], list[str]]:
    root = Path(fbx_path).parent
    image_results = []
    missing = []
    for image in bpy.data.images:
        if image.source in {"VIEWER", "GENERATED"}:
            continue
        absolute = Path(bpy.path.abspath(image.filepath)) if image.filepath else None
        if (absolute is None or not absolute.exists()) and image.packed_file is None:
            candidate = find_texture(root, Path(image.filepath).name if image.filepath else image.name)
            if candidate is not None:
                image.filepath = str(candidate)
                try:
                    image.reload()
                except RuntimeError:
                    pass
                absolute = candidate
        loaded = bool(image.has_data or image.packed_file is not None)
        if not loaded:
            missing.append(image.name if not image.filepath else image.filepath)
        if loaded and image.packed_file is None:
            try:
                image.pack()
            except RuntimeError:
                pass
        image_results.append(
            {
                "name": image.name,
                "path": str(absolute) if absolute else image.filepath,
                "loaded": loaded,
                "packed": image.packed_file is not None,
            }
        )
    return image_results, missing


def material_audit(meshes: list[bpy.types.Object] | None = None) -> list[dict]:
    results = []
    materials = list(bpy.data.materials)
    if meshes is not None:
        used = {
            slot.material
            for mesh in meshes
            for slot in mesh.material_slots
            if slot.material is not None
        }
        materials = sorted(used, key=lambda material: material.name)
    for material in materials:
        nodes = list(material.node_tree.nodes) if material.use_nodes and material.node_tree else []
        images = [
            node.image.name
            for node in nodes
            if node.type == "TEX_IMAGE" and node.image is not None
        ]
        results.append(
            {
                "name": material.name,
                "nodes": [node.bl_idname for node in nodes],
                "principled": any(node.type == "BSDF_PRINCIPLED" for node in nodes),
                "images": images,
            }
        )
    return results


def bone_audit(armature: bpy.types.Object) -> dict:
    names = [bone.name for bone in armature.data.bones]
    semantic_names = {_bone_semantic(name) for name in names}
    required_semantics = {_bone_semantic(name) for name in REQUIRED_BONES}
    hierarchy = [(bone.name, bone.parent.name if bone.parent else "<ROOT>") for bone in armature.data.bones]
    return {
        "names": names,
        "hierarchy": hierarchy,
        "deforming": [bone.name for bone in armature.data.bones if bone.use_deform],
        "present": [name for name in REQUIRED_BONES if name in names],
        "missing": [name for name in REQUIRED_BONES if name not in names],
        "semantic_present": sorted(required_semantics & semantic_names),
        "semantic_missing": sorted(required_semantics - semantic_names),
    }


def _bone_semantic(name: str) -> str:
    if ":" in name:
        return name.rsplit(":", 1)[-1]
    if name.startswith("mixamorig_"):
        return name[len("mixamorig_") :]
    return name


def finite_values(values) -> bool:
    return all(math.isfinite(float(value)) for value in values)


def validate_finite_transforms(objects: list[bpy.types.Object], armature: bpy.types.Object) -> None:
    for obj in objects:
        values = [component for row in obj.matrix_world for component in row]
        if not finite_values(values):
            raise RuntimeError(f"Non-finite object transform: {obj.name}")
    for bone in armature.data.bones:
        values = [component for row in bone.matrix_local for component in row]
        if not finite_values(values):
            raise RuntimeError(f"Non-finite bone matrix: {bone.name}")


def mesh_world_sample(mesh: bpy.types.Object, maximum: int = 400) -> list:
    depsgraph = bpy.context.evaluated_depsgraph_get()
    evaluated = mesh.evaluated_get(depsgraph)
    vertices = evaluated.data.vertices
    step = max(1, len(vertices) // maximum)
    return [evaluated.matrix_world @ vertices[index].co for index in range(0, len(vertices), step)]


def forearm_deformation_test(armature: bpy.types.Object, meshes: list[bpy.types.Object]) -> dict:
    bone_name = next(
        (name for name in ("mixamorig_LeftForeArm", "mixamorig:LeftForeArm") if name in armature.pose.bones),
        None,
    )
    if bone_name is None:
        bone_name = next(
            (bone.name for bone in armature.pose.bones if bone.name.endswith("LeftForeArm")),
            None,
        )
    if bone_name is None:
        return {"performed": False, "reason": "Left forearm bone not found"}
    before = {mesh.name: mesh_world_sample(mesh) for mesh in meshes}
    pose_bone = armature.pose.bones[bone_name]
    original = pose_bone.matrix_basis.copy()
    pose_bone.matrix_basis = original @ Matrix.Rotation(math.radians(7.0), 4, "Y")
    bpy.context.view_layer.update()
    maximum_displacement = 0.0
    changed_vertices = 0
    try:
        for mesh in meshes:
            after = mesh_world_sample(mesh)
            for first, second in zip(before[mesh.name], after):
                displacement = (second - first).length
                if not math.isfinite(displacement):
                    raise RuntimeError("Forearm pose test produced a non-finite vertex.")
                maximum_displacement = max(maximum_displacement, displacement)
                if displacement > 0.00001:
                    changed_vertices += 1
    finally:
        pose_bone.matrix_basis = original
        bpy.context.view_layer.update()
    if changed_vertices == 0:
        raise RuntimeError("Forearm pose test did not deform any sampled vertex.")
    if maximum_displacement > 1.0:
        raise RuntimeError(
            f"Forearm pose test produced implausible displacement: {maximum_displacement:.6f} m"
        )
    return {
        "performed": True,
        "bone": bone_name,
        "changed_samples": changed_vertices,
        "maximum_displacement_m": maximum_displacement,
        "restored": pose_bone.matrix_basis == original,
    }


def report_common(
    title: str,
    armature: bpy.types.Object,
    meshes: list[bpy.types.Object],
    height: float,
    skin: list[dict],
    bones: dict,
    materials: list[dict],
    images: list[dict],
) -> list[str]:
    lines = [
        f"=== {title} ===",
        f"Blender: {bpy.app.version_string}",
        f"Armatures: {len([obj for obj in bpy.data.objects if obj.type == 'ARMATURE'])}",
        f"Meshes: {len(meshes)}",
        f"Materials: {len(materials)}",
        f"Images: {len(images)}",
        f"Bones: {len(bones['names'])}",
        f"Deforming bones: {len(bones['deforming'])}",
        f"Armature pose position: {armature.data.pose_position}",
        f"Height: {height:.6f} m",
        f"Actions: {len(bpy.data.actions)}",
        f"NLA tracks/strips: {count_nla()[0]}/{count_nla()[1]}",
        f"Required bones missing: {', '.join(bones['missing']) if bones['missing'] else '<none>'}",
        (
            "Required semantic bones missing: "
            + (
                ", ".join(bones["semantic_missing"])
                if bones["semantic_missing"]
                else "<none>"
            )
        ),
        "",
        "Meshes / skin:",
    ]
    for item in skin:
        lines.append(
            f"- {item['name']}: vertices={item['vertices']}, groups={item['groups']}, "
            f"weighted={item['weighted_vertices']}, armature_modifier={item['armature_modifier']}"
        )
    lines += ["", "Materials:"]
    for item in materials:
        lines.append(
            f"- {item['name']}: principled={item['principled']}, "
            f"nodes={item['nodes']}, images={item['images']}"
        )
    lines += ["", "Images:"]
    for item in images:
        lines.append(
            f"- {item['name']}: loaded={item['loaded']}, packed={item['packed']}, "
            f"path={item['path']}"
        )
    lines += ["", "Bone hierarchy (bone <- parent):"]
    lines.extend(f"- {name} <- {parent}" for name, parent in bones["hierarchy"])
    lines += ["", "All bones:"]
    lines.extend(f"- {name}" for name in bones["names"])
    return lines


def prepare(args: argparse.Namespace) -> None:
    fbx = Path(args.input_fbx).resolve()
    output_blend = Path(args.output_blend).resolve()
    output_glb = Path(args.output_glb).resolve()
    if not fbx.is_file():
        raise RuntimeError(f"Input FBX does not exist: {fbx}")
    output_blend.parent.mkdir(parents=True, exist_ok=True)
    output_glb.parent.mkdir(parents=True, exist_ok=True)
    empty_scene()
    bpy.context.scene.unit_settings.system = "METRIC"
    bpy.context.scene.unit_settings.scale_length = 1.0
    bpy.context.scene.unit_settings.length_unit = "METERS"
    import_kwargs = import_fbx(str(fbx))
    inventory = object_inventory()
    if len(inventory["ARMATURE"]) != 1:
        hierarchy = [
            f"{obj.name} ({obj.type}) parent={obj.parent.name if obj.parent else '<ROOT>'}"
            for obj in bpy.data.objects
        ]
        raise RuntimeError(
            f"Expected exactly one armature, found {len(inventory['ARMATURE'])}.\n"
            + "\n".join(hierarchy)
        )
    armature = inventory["ARMATURE"][0]
    if not inventory["MESH"]:
        raise RuntimeError("The imported FBX contains no mesh.")
    actions_removed, nla_tracks_removed, nla_strips_removed = clear_animation()
    removed = remove_unnecessary_objects()
    removed_datablocks = remove_unused_datablocks()
    armature = [obj for obj in bpy.data.objects if obj.type == "ARMATURE"][0]
    meshes = [obj for obj in bpy.data.objects if obj.type == "MESH"]
    armature.data.pose_position = "REST"
    bpy.context.view_layer.update()
    skin = validate_skin(armature, meshes)
    height, scale_factor = validate_and_fix_height(armature, meshes)
    rename_character(armature, meshes)
    triangulated_ngons = triangulate_ngons(meshes)
    skin = validate_skin(armature, meshes)
    images, missing_images = relink_and_pack_images(str(fbx))
    if missing_images:
        raise RuntimeError("Missing textures: " + ", ".join(missing_images))
    materials = material_audit(meshes)
    bones = bone_audit(armature)
    validate_finite_transforms([armature, *meshes], armature)
    if bpy.context.mode != "OBJECT":
        bpy.ops.object.mode_set(mode="OBJECT")
    bpy.ops.wm.save_as_mainfile(filepath=str(output_blend), check_existing=False)
    bpy.ops.object.select_all(action="DESELECT")
    armature.select_set(True)
    for mesh in meshes:
        mesh.select_set(True)
    bpy.context.view_layer.objects.active = armature
    export_kwargs = export_glb(str(output_glb))
    if not output_glb.is_file() or output_glb.stat().st_size == 0:
        raise RuntimeError("GLB exporter did not produce a non-empty file.")
    lines = report_common(
        "RACER PREPARATION",
        armature,
        meshes,
        height,
        skin,
        bones,
        materials,
        images,
    )
    lines[1:1] = [
        f"Input FBX: {fbx}",
        f"Output BLEND: {output_blend}",
        f"Output GLB: {output_glb}",
        f"FBX bytes: {fbx.stat().st_size}",
        f"BLEND bytes: {output_blend.stat().st_size}",
        f"GLB bytes: {output_glb.stat().st_size}",
        f"Import arguments used: {import_kwargs}",
        f"Export arguments used: {export_kwargs}",
        f"Uniform scale correction: {scale_factor}",
        f"N-gons triangulated for tangent export: {triangulated_ngons}",
        f"Removed objects: {removed}",
        f"Removed unused datablocks: {removed_datablocks}",
        f"Actions removed: {actions_removed}",
        f"NLA tracks removed: {nla_tracks_removed}",
        f"NLA strips removed: {nla_strips_removed}",
        f"Missing images: {missing_images if missing_images else '<none>'}",
    ]
    write_report(args.report, lines, append=False)


def audit_loaded_character(title: str) -> tuple:
    inventory = object_inventory()
    if len(inventory["ARMATURE"]) != 1:
        raise RuntimeError(f"{title}: expected one armature, found {len(inventory['ARMATURE'])}")
    armature = inventory["ARMATURE"][0]
    meshes = [
        mesh
        for mesh in inventory["MESH"]
        if armature_modifier(mesh, armature) is not None
    ]
    if not meshes:
        raise RuntimeError(f"{title}: no skinned meshes found")
    skin = validate_skin(armature, meshes)
    _minimum, _maximum, height = combined_world_bounds(meshes)
    if not 1.4 <= height <= 2.2:
        raise RuntimeError(f"{title}: implausible height {height:.6f} m")
    bones = bone_audit(armature)
    materials = material_audit(meshes)
    images = [
        {
            "name": image.name,
            "path": image.filepath,
            "loaded": bool(image.has_data or image.packed_file is not None),
            "packed": image.packed_file is not None,
        }
        for image in bpy.data.images
        if image.source not in {"VIEWER", "GENERATED"}
    ]
    missing = [item["name"] for item in images if not item["loaded"]]
    if missing:
        raise RuntimeError(f"{title}: unloaded images: {missing}")
    if bpy.data.actions or count_nla() != (0, 0):
        raise RuntimeError(f"{title}: unexpected Actions or NLA data")
    validate_finite_transforms([armature, *meshes], armature)
    return armature, meshes, height, skin, bones, materials, images


def validate_glb(args: argparse.Namespace) -> None:
    glb = Path(args.input_glb).resolve()
    if not glb.is_file():
        raise RuntimeError(f"GLB does not exist: {glb}")
    empty_scene()
    import_glb(str(glb))
    armature, meshes, height, skin, bones, materials, images = audit_loaded_character(
        "Racer clean GLB"
    )
    pose_test = forearm_deformation_test(armature, meshes)
    lines = report_common(
        "CLEAN GLB VALIDATION",
        armature,
        meshes,
        height,
        skin,
        bones,
        materials,
        images,
    )
    lines[1:1] = [
        f"Validated GLB: {glb}",
        f"GLB bytes: {glb.stat().st_size}",
        f"Forearm deformation test: {pose_test}",
        "Result: PASS",
    ]
    write_report(args.report, lines, append=True)


def joint_distance(
    armature: bpy.types.Object,
    semantic_name: str,
    child_semantic_name: str,
) -> float | None:
    bone = next(
        (
            candidate
            for candidate in armature.data.bones
            if _bone_semantic(candidate.name) == semantic_name
        ),
        None,
    )
    child = next(
        (
            candidate
            for candidate in armature.data.bones
            if _bone_semantic(candidate.name) == child_semantic_name
        ),
        None,
    )
    if bone is None or child is None:
        return None
    return (
        armature.matrix_world.to_3x3()
        @ (child.head_local - bone.head_local)
    ).length


def comparison_snapshot(filepath: str, label: str) -> dict:
    empty_scene()
    import_glb(filepath)
    inventory = object_inventory()
    if len(inventory["ARMATURE"]) != 1 or not inventory["MESH"]:
        raise RuntimeError(
            f"{label}: expected one armature and at least one mesh, "
            f"found {len(inventory['ARMATURE'])}/{len(inventory['MESH'])}"
        )
    armature = inventory["ARMATURE"][0]
    meshes = [
        mesh
        for mesh in inventory["MESH"]
        if armature_modifier(mesh, armature) is not None
    ]
    if not meshes:
        raise RuntimeError(f"{label}: no skinned meshes found")
    _minimum, _maximum, height = combined_world_bounds(meshes)
    bones = {bone.name for bone in armature.data.bones}
    semantic_to_actual = {_bone_semantic(name): name for name in bones}
    parents = {
        bone.name: bone.parent.name if bone.parent else None
        for bone in armature.data.bones
    }
    semantic_parents = {
        _bone_semantic(bone.name): (
            _bone_semantic(bone.parent.name) if bone.parent else None
        )
        for bone in armature.data.bones
    }
    lengths = {
        name: joint_distance(armature, name, child_name)
        for name, child_name in {
            "LeftArm": "LeftForeArm",
            "LeftForeArm": "LeftHand",
            "RightArm": "RightForeArm",
            "RightForeArm": "RightHand",
            "LeftUpLeg": "LeftLeg",
            "LeftLeg": "LeftFoot",
            "RightUpLeg": "RightLeg",
            "RightLeg": "RightFoot",
        }.items()
    }
    rest = {
        semantic_name: [
            list(row)
            for row in armature.data.bones[semantic_to_actual[semantic_name]].matrix_local
        ]
        for semantic_name in (
            "Hips",
            "Spine",
            "LeftArm",
            "RightArm",
            "LeftUpLeg",
            "RightUpLeg",
        )
        if semantic_name in semantic_to_actual
    }
    return {
        "label": label,
        "height": height,
        "bones": bones,
        "parents": parents,
        "semantic_to_actual": semantic_to_actual,
        "semantic_parents": semantic_parents,
        "lengths": lengths,
        "rest": rest,
    }


def compare(args: argparse.Namespace) -> None:
    racer_path = str(Path(args.input_glb).resolve())
    reference_path = str(Path(args.reference_glb).resolve())
    racer = comparison_snapshot(racer_path, "Racer")
    reference = comparison_snapshot(reference_path, "Rider_Bot")
    common = sorted(racer["bones"] & reference["bones"])
    racer_only = sorted(racer["bones"] - reference["bones"])
    reference_only = sorted(reference["bones"] - racer["bones"])
    hierarchy_differences = [
        (
            name,
            racer["parents"].get(name),
            reference["parents"].get(name),
        )
        for name in common
        if racer["parents"].get(name) != reference["parents"].get(name)
    ]
    common_semantic = sorted(
        set(racer["semantic_to_actual"]) & set(reference["semantic_to_actual"])
    )
    racer_only_semantic = sorted(
        set(racer["semantic_to_actual"]) - set(reference["semantic_to_actual"])
    )
    reference_only_semantic = sorted(
        set(reference["semantic_to_actual"]) - set(racer["semantic_to_actual"])
    )
    semantic_hierarchy_differences = [
        (
            name,
            racer["semantic_parents"].get(name),
            reference["semantic_parents"].get(name),
        )
        for name in common_semantic
        if (
            racer["semantic_parents"].get(name)
            != reference["semantic_parents"].get(name)
        )
    ]
    lines = [
        "=== RACER / RIDER_BOT COMPARISON ===",
        f"Racer: {racer_path}",
        f"Rider_Bot: {reference_path}",
        f"Racer height: {racer['height']:.6f} m",
        f"Rider_Bot height: {reference['height']:.6f} m",
        f"Racer bones: {len(racer['bones'])}",
        f"Rider_Bot bones: {len(reference['bones'])}",
        f"Common bones ({len(common)}): {common}",
        f"Racer-only bones ({len(racer_only)}): {racer_only}",
        f"Rider_Bot-only bones ({len(reference_only)}): {reference_only}",
        f"Hierarchy differences ({len(hierarchy_differences)}): {hierarchy_differences}",
        (
            f"Semantic common bones ({len(common_semantic)}): "
            f"{common_semantic}"
        ),
        (
            f"Semantic Racer-only bones ({len(racer_only_semantic)}): "
            f"{racer_only_semantic}"
        ),
        (
            f"Semantic Rider_Bot-only bones ({len(reference_only_semantic)}): "
            f"{reference_only_semantic}"
        ),
        (
            "Semantic hierarchy differences "
            f"({len(semantic_hierarchy_differences)}): "
            f"{semantic_hierarchy_differences}"
        ),
        f"Racer namespace map: {racer['semantic_to_actual']}",
        f"Rider_Bot namespace map: {reference['semantic_to_actual']}",
        f"Racer limb bone lengths: {racer['lengths']}",
        f"Rider_Bot limb bone lengths: {reference['lengths']}",
        f"Racer selected rest matrices: {racer['rest']}",
        f"Rider_Bot selected rest matrices: {reference['rest']}",
    ]
    replace_report_section(args.report, "=== RACER / RIDER_BOT COMPARISON ===", lines)


def main() -> None:
    args = parse_arguments()
    try:
        if args.mode == "prepare":
            prepare(args)
        elif args.mode == "validate":
            validate_glb(args)
        else:
            compare(args)
    except Exception as error:
        failure_lines = [
            f"=== {args.mode.upper()} FAILURE ===",
            f"{type(error).__name__}: {error}",
            traceback.format_exc(),
        ]
        write_report(args.report, failure_lines, append=Path(args.report).exists())
        raise


if __name__ == "__main__":
    main()
