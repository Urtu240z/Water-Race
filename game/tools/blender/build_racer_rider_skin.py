#!/usr/bin/env python3
"""Build a Racer skin that uses Rider_Bot's literal armature.

The build is deliberately split into ``build`` and ``validate`` modes so the
export is reopened in a clean Blender process.  The Godot integration must not
continue unless both modes succeed.
"""

from __future__ import annotations

import argparse
import math
import sys
import traceback
from pathlib import Path

import bpy
import numpy as np
from mathutils import Matrix, Vector


CRITICAL_JOINTS = (
    "Hips",
    "Head",
    "LeftShoulder",
    "RightShoulder",
    "LeftHand",
    "RightHand",
    "LeftFoot",
    "RightFoot",
)
DEFORMATION_TESTS = (
    ("LeftForeArm", 20.0, "Y"),
    ("RightForeArm", -20.0, "Y"),
    ("LeftLeg", 15.0, "X"),
    ("RightLeg", -15.0, "X"),
    ("Spine1", 10.0, "Z"),
    ("Hips", 10.0, "X"),
)
MAX_CRITICAL_ERROR_M = 0.08
MATRIX_TOLERANCE = 2.0e-4


def script_args() -> list[str]:
    return sys.argv[sys.argv.index("--") + 1 :] if "--" in sys.argv else []


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--mode", choices=("build", "validate"), default="build")
    parser.add_argument("--source-blend")
    parser.add_argument("--reference-glb", required=True)
    parser.add_argument("--output-blend")
    parser.add_argument("--output-glb")
    parser.add_argument("--input-glb")
    parser.add_argument("--report", required=True)
    args = parser.parse_args(script_args())
    required = (
        ("source_blend", "output_blend", "output_glb")
        if args.mode == "build"
        else ("input_glb",)
    )
    missing = [name for name in required if not getattr(args, name)]
    if missing:
        parser.error(f"Missing for {args.mode}: {', '.join(missing)}")
    return args


def report_write(path: str, lines: list[str], append: bool = False) -> None:
    output = Path(path)
    output.parent.mkdir(parents=True, exist_ok=True)
    with output.open("a" if append else "w", encoding="utf-8", newline="\n") as handle:
        if append and output.stat().st_size:
            handle.write("\n")
        handle.write("\n".join(lines))
        handle.write("\n")


def report_trim_from(path: str, markers: tuple[str, ...]) -> None:
    report_path = Path(path)
    if not report_path.exists():
        return
    existing = report_path.read_text(encoding="utf-8")
    indexes = [
        existing.find(marker)
        for marker in markers
        if existing.find(marker) >= 0
    ]
    if not indexes:
        return
    report_path.write_text(
        existing[: min(indexes)].rstrip() + "\n",
        encoding="utf-8",
        newline="\n",
    )


def supported_kwargs(operator, desired: dict) -> dict:
    supported = set(operator.get_rna_type().properties.keys())
    return {key: value for key, value in desired.items() if key in supported}


def import_glb(path: str) -> None:
    result = bpy.ops.import_scene.gltf(
        **supported_kwargs(bpy.ops.import_scene.gltf, {"filepath": path})
    )
    if "FINISHED" not in result:
        raise RuntimeError(f"glTF import failed: {result}")


def export_glb(path: str) -> dict:
    Path(path).parent.mkdir(parents=True, exist_ok=True)
    desired = {
        "filepath": path,
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
    kwargs = supported_kwargs(bpy.ops.export_scene.gltf, desired)
    result = bpy.ops.export_scene.gltf(**kwargs)
    if "FINISHED" not in result:
        raise RuntimeError(f"glTF export failed: {result}")
    return kwargs


def clear_scene() -> None:
    if bpy.context.mode != "OBJECT":
        bpy.ops.object.mode_set(mode="OBJECT")
    bpy.ops.object.select_all(action="SELECT")
    bpy.ops.object.delete(use_global=False)
    for datablocks in (
        bpy.data.armatures,
        bpy.data.meshes,
        bpy.data.cameras,
        bpy.data.lights,
    ):
        for datablock in list(datablocks):
            if datablock.users == 0:
                datablocks.remove(datablock)


def semantic(name: str) -> str:
    return name.rsplit(":", 1)[-1] if ":" in name else name


def semantic_map(names) -> dict[str, str]:
    result: dict[str, str] = {}
    collisions: dict[str, list[str]] = {}
    for name in names:
        key = semantic(name)
        if key in result:
            collisions.setdefault(key, [result[key]]).append(name)
        else:
            result[key] = name
    if collisions:
        raise RuntimeError(f"Semantic name collisions: {collisions}")
    return result


def armature_modifier(mesh: bpy.types.Object, armature=None):
    for modifier in mesh.modifiers:
        if modifier.type == "ARMATURE" and (
            armature is None or modifier.object == armature
        ):
            return modifier
    return None


def find_source_character() -> tuple[bpy.types.Object, bpy.types.Object]:
    armatures = [obj for obj in bpy.data.objects if obj.type == "ARMATURE"]
    candidates = [
        obj
        for obj in bpy.data.objects
        if obj.type == "MESH" and armature_modifier(obj) is not None
    ]
    if len(armatures) != 1 or len(candidates) != 1:
        raise RuntimeError(
            "Racer source must contain exactly one armature and one skinned mesh; "
            f"found {len(armatures)} armatures and {len(candidates)} skinned meshes."
        )
    return armatures[0], candidates[0]


def weighted_snapshot(mesh: bpy.types.Object) -> list[tuple[tuple[int, float], ...]]:
    return [
        tuple(sorted((item.group, float(item.weight)) for item in vertex.groups))
        for vertex in mesh.data.vertices
    ]


def ensure_all_weighted(mesh: bpy.types.Object) -> None:
    unweighted = [
        vertex.index
        for vertex in mesh.data.vertices
        if not any(item.weight > 0.0 for item in vertex.groups)
    ]
    if unweighted:
        raise RuntimeError(
            f"{len(unweighted)} Racer vertices have no positive influence; "
            f"first indices: {unweighted[:20]}"
        )


def bone_world_head(armature: bpy.types.Object, bone_name: str) -> Vector:
    bone = armature.data.bones[bone_name]
    return armature.matrix_world @ bone.head_local


def character_height_from_bones(armature: bpy.types.Object) -> float:
    points = [
        armature.matrix_world @ endpoint
        for bone in armature.data.bones
        for endpoint in (bone.head_local, bone.tail_local)
    ]
    return max(point.z for point in points) - min(point.z for point in points)


def similarity_fit(
    source_armature: bpy.types.Object,
    target_armature: bpy.types.Object,
    source_names: dict[str, str],
    target_names: dict[str, str],
) -> tuple[Matrix, float, np.ndarray, np.ndarray, dict[str, float]]:
    source = np.array(
        [
            tuple(bone_world_head(source_armature, source_names[name]))
            for name in CRITICAL_JOINTS
        ],
        dtype=np.float64,
    )
    target = np.array(
        [
            tuple(bone_world_head(target_armature, target_names[name]))
            for name in CRITICAL_JOINTS
        ],
        dtype=np.float64,
    )
    source_center = source.mean(axis=0)
    target_center = target.mean(axis=0)
    source_centered = source - source_center
    target_centered = target - target_center
    covariance = source_centered.T @ target_centered
    u, singular_values, vt = np.linalg.svd(covariance)
    rotation = vt.T @ u.T
    if np.linalg.det(rotation) < 0.0:
        vt[-1, :] *= -1.0
        rotation = vt.T @ u.T
    denominator = float(np.sum(source_centered * source_centered))
    if denominator <= 1.0e-12:
        raise RuntimeError("Critical Racer joints are degenerate.")
    scale = float(np.sum(singular_values) / denominator)
    translation = target_center - scale * (rotation @ source_center)
    fitted = (scale * (rotation @ source.T)).T + translation
    errors = {
        name: float(np.linalg.norm(fitted[index] - target[index]))
        for index, name in enumerate(CRITICAL_JOINTS)
    }
    matrix_np = np.eye(4, dtype=np.float64)
    matrix_np[:3, :3] = scale * rotation
    matrix_np[:3, 3] = translation
    matrix = Matrix(matrix_np.tolist())
    return matrix, scale, rotation, translation, errors


def rotation_euler_degrees(rotation: np.ndarray) -> tuple[float, float, float]:
    matrix = Matrix(rotation.tolist()).to_4x4()
    euler = matrix.to_euler("XYZ")
    return tuple(math.degrees(value) for value in euler)


def clear_animation_data() -> tuple[int, int]:
    action_count = len(bpy.data.actions)
    nla_count = 0
    for obj in bpy.data.objects:
        if obj.animation_data is not None:
            nla_count += len(obj.animation_data.nla_tracks)
            obj.animation_data_clear()
    for data in (bpy.data.armatures, bpy.data.meshes, bpy.data.materials):
        for item in data:
            if hasattr(item, "animation_data_clear"):
                item.animation_data_clear()
    for action in list(bpy.data.actions):
        bpy.data.actions.remove(action)
    return action_count, nla_count


def evaluated_sample(mesh: bpy.types.Object, maximum: int = 800) -> list[Vector]:
    depsgraph = bpy.context.evaluated_depsgraph_get()
    evaluated = mesh.evaluated_get(depsgraph)
    vertices = evaluated.data.vertices
    step = max(1, len(vertices) // maximum)
    return [
        evaluated.matrix_world @ vertices[index].co
        for index in range(0, len(vertices), step)
    ]


def deformation_tests(
    armature: bpy.types.Object,
    mesh: bpy.types.Object,
    target_names: dict[str, str],
) -> list[dict]:
    results = []
    original_bases = {
        pose_bone.name: pose_bone.matrix_basis.copy()
        for pose_bone in armature.pose.bones
    }
    armature.data.pose_position = "POSE"
    for semantic_name, degrees, axis in DEFORMATION_TESTS:
        literal = target_names[semantic_name]
        pose_bone = armature.pose.bones[literal]
        original = pose_bone.matrix_basis.copy()
        before = evaluated_sample(mesh)
        try:
            pose_bone.matrix_basis = original @ Matrix.Rotation(
                math.radians(degrees), 4, axis
            )
            bpy.context.view_layer.update()
            after = evaluated_sample(mesh)
            displacements = [(right - left).length for left, right in zip(before, after)]
            if not displacements or not all(math.isfinite(value) for value in displacements):
                raise RuntimeError(f"{semantic_name}: non-finite deformation.")
            changed = sum(value > 1.0e-6 for value in displacements)
            maximum = max(displacements)
            if changed == 0:
                raise RuntimeError(f"{semantic_name}: no sampled vertices moved.")
            if maximum > 2.0:
                raise RuntimeError(
                    f"{semantic_name}: implausible displacement {maximum:.6f} m."
                )
            results.append(
                {
                    "bone": literal,
                    "degrees": degrees,
                    "axis": axis,
                    "changed_samples": changed,
                    "max_displacement_m": maximum,
                }
            )
        finally:
            pose_bone.matrix_basis = original
            bpy.context.view_layer.update()
        if pose_bone.matrix_basis != original:
            raise RuntimeError(f"{semantic_name}: rest pose was not restored exactly.")
    for pose_bone in armature.pose.bones:
        if matrix_difference(
            pose_bone.matrix_basis,
            original_bases[pose_bone.name],
        ) > 1.0e-12:
            raise RuntimeError(f"Residual test pose on {pose_bone.name}.")
    armature.data.pose_position = "REST"
    bpy.context.view_layer.update()
    return results


def purge_non_final_objects(
    racer_mesh: bpy.types.Object,
    target_armature: bpy.types.Object,
) -> None:
    for obj in list(bpy.data.objects):
        if obj not in {racer_mesh, target_armature}:
            bpy.data.objects.remove(obj, do_unlink=True)
    for collection in list(bpy.data.collections):
        if collection.users == 0:
            bpy.data.collections.remove(collection)
    for material in list(bpy.data.materials):
        if material.users == 0:
            bpy.data.materials.remove(material)
    for image in list(bpy.data.images):
        if image.users == 0 and image.source != "VIEWER":
            bpy.data.images.remove(image)


def pack_images() -> list[dict]:
    result = []
    for image in bpy.data.images:
        if image.source in {"VIEWER", "GENERATED"}:
            continue
        if image.packed_file is None and image.has_data:
            image.pack()
        result.append(
            {
                "name": image.name,
                "size": tuple(image.size),
                "packed": image.packed_file is not None,
            }
        )
    return result


def build(args: argparse.Namespace) -> None:
    source_blend = str(Path(args.source_blend).resolve())
    reference_glb = str(Path(args.reference_glb).resolve())
    output_blend = str(Path(args.output_blend).resolve())
    output_glb = str(Path(args.output_glb).resolve())
    for required in (source_blend, reference_glb):
        if not Path(required).is_file():
            raise FileNotFoundError(required)

    bpy.ops.wm.open_mainfile(filepath=source_blend)
    racer_armature, racer_mesh = find_source_character()
    racer_armature.data.pose_position = "REST"
    source_bones = semantic_map(bone.name for bone in racer_armature.data.bones)
    source_groups = semantic_map(group.name for group in racer_mesh.vertex_groups)
    if len(source_bones) != 52 or len(source_groups) != 52:
        raise RuntimeError(
            f"Expected Racer 52 bones/groups, found {len(source_bones)}/{len(source_groups)}."
        )
    ensure_all_weighted(racer_mesh)
    weights_before = weighted_snapshot(racer_mesh)
    old_objects = set(bpy.data.objects)
    import_glb(reference_glb)
    imported_objects = [obj for obj in bpy.data.objects if obj not in old_objects]
    imported_armatures = [obj for obj in imported_objects if obj.type == "ARMATURE"]
    if len(imported_armatures) != 1:
        raise RuntimeError(
            f"Rider_Bot import produced {len(imported_armatures)} armatures."
        )
    target_armature = imported_armatures[0]
    target_armature.data.pose_position = "REST"
    target_bones = semantic_map(bone.name for bone in target_armature.data.bones)
    if len(target_bones) != 52:
        raise RuntimeError(f"Rider_Bot armature has {len(target_bones)} bones, expected 52.")
    if set(source_groups) != set(target_bones):
        raise RuntimeError(
            "Racer groups and Rider_Bot bones differ semantically. "
            f"Racer-only={sorted(set(source_groups) - set(target_bones))}; "
            f"Bot-only={sorted(set(target_bones) - set(source_groups))}"
        )
    if set(source_bones) != set(target_bones):
        raise RuntimeError("Racer and Rider_Bot bone sets differ semantically.")
    hierarchy_mismatches = []
    for key in sorted(source_bones):
        source_bone = racer_armature.data.bones[source_bones[key]]
        target_bone = target_armature.data.bones[target_bones[key]]
        source_parent = semantic(source_bone.parent.name) if source_bone.parent else None
        target_parent = semantic(target_bone.parent.name) if target_bone.parent else None
        if source_parent != target_parent:
            hierarchy_mismatches.append((key, source_parent, target_parent))
    if hierarchy_mismatches:
        raise RuntimeError(f"Semantic hierarchy mismatch: {hierarchy_mismatches}")

    alignment, scale, rotation, translation, errors = similarity_fit(
        racer_armature, target_armature, source_bones, target_bones
    )
    mean_error = sum(errors.values()) / len(errors)
    max_joint = max(errors, key=errors.get)
    max_error = errors[max_joint]
    mapping_lines = [
        f"{source_groups[key]} -> {target_bones[key]}"
        for key in sorted(source_groups)
    ]
    initial_lines = [
        "=== RACER RIDER-COMPATIBLE BUILD ===",
        f"Blender: {bpy.app.version_string}",
        f"Source blend: {source_blend}",
        f"Reference GLB: {reference_glb}",
        f"Racer bone height before fit: {character_height_from_bones(racer_armature):.9f} m",
        f"Rider_Bot bone height: {character_height_from_bones(target_armature):.9f} m",
        f"Uniform scale: {scale:.12f}",
        f"Rotation XYZ degrees: {rotation_euler_degrees(rotation)}",
        f"Translation XYZ m: {tuple(float(value) for value in translation)}",
        f"Critical mean error: {mean_error:.9f} m",
        f"Critical max error: {max_error:.9f} m at {max_joint}",
        "Critical joint errors:",
        *[f"  {name}: {errors[name]:.9f} m" for name in CRITICAL_JOINTS],
        f"Mappings: {len(mapping_lines)}",
        *[f"  {line}" for line in mapping_lines],
    ]
    report_write(args.report, initial_lines)
    if max_error > MAX_CRITICAL_ERROR_M:
        report_write(
            args.report,
            [
                "=== ALIGNMENT CUTOFF ===",
                f"Maximum critical error {max_error:.9f} m exceeds "
                f"{MAX_CRITICAL_ERROR_M:.3f} m.",
                "Godot integration must not continue.",
                "Joints above threshold:",
                *[
                    f"  {name}: {value:.9f} m"
                    for name, value in errors.items()
                    if value > MAX_CRITICAL_ERROR_M
                ],
            ],
            append=True,
        )
        raise RuntimeError("ALIGNMENT_CUTOFF")

    racer_mesh.matrix_world = alignment @ racer_mesh.matrix_world
    bpy.context.view_layer.update()
    for key in sorted(source_groups):
        racer_mesh.vertex_groups[source_groups[key]].name = target_bones[key]
    if len({group.name for group in racer_mesh.vertex_groups}) != 52:
        raise RuntimeError("Vertex-group rename produced a collision.")
    if weighted_snapshot(racer_mesh) != weights_before:
        raise RuntimeError("Numeric weights changed while renaming groups.")
    ensure_all_weighted(racer_mesh)

    for modifier in list(racer_mesh.modifiers):
        if modifier.type == "ARMATURE":
            racer_mesh.modifiers.remove(modifier)
    modifier = racer_mesh.modifiers.new(name="Rider_Bot_Armature", type="ARMATURE")
    modifier.object = target_armature
    mesh_world = racer_mesh.matrix_world.copy()
    racer_mesh.parent = target_armature
    racer_mesh.matrix_world = mesh_world
    bpy.context.view_layer.update()

    tests = deformation_tests(target_armature, racer_mesh, target_bones)
    action_count, nla_count = clear_animation_data()
    target_armature.name = "SKEL_Rider"
    target_armature.data.name = "SKEL_Rider"
    racer_mesh.name = "RacerSkinMesh"
    racer_mesh.data.name = "RacerSkinMesh_Data"
    purge_non_final_objects(racer_mesh, target_armature)
    images = pack_images()
    target_armature.data.pose_position = "REST"
    bpy.context.view_layer.update()
    if len([obj for obj in bpy.data.objects if obj.type == "ARMATURE"]) != 1:
        raise RuntimeError("Final Blender scene does not have exactly one armature.")
    if len([obj for obj in bpy.data.objects if obj.type == "MESH"]) != 1:
        raise RuntimeError("Final Blender scene does not have exactly one mesh.")
    if len(bpy.data.actions) != 0:
        raise RuntimeError("Final Blender scene still contains actions.")

    Path(output_blend).parent.mkdir(parents=True, exist_ok=True)
    bpy.ops.wm.save_as_mainfile(filepath=output_blend)
    bpy.ops.object.select_all(action="DESELECT")
    target_armature.select_set(True)
    racer_mesh.select_set(True)
    bpy.context.view_layer.objects.active = target_armature
    export_options = export_glb(output_glb)
    report_write(
        args.report,
        [
            "=== BLENDER BUILD RESULT ===",
            f"Output blend: {output_blend}",
            f"Output GLB: {output_glb}",
            f"Original Actions removed: {action_count}",
            f"Original NLA tracks removed: {nla_count}",
            f"Final armatures/meshes: 1/1",
            f"Final armature object/data: {target_armature.name}/{target_armature.data.name}",
            f"Final mesh: {racer_mesh.name}",
            f"Final bones/groups: {len(target_armature.data.bones)}/{len(racer_mesh.vertex_groups)}",
            f"All {len(racer_mesh.data.vertices)} vertices remain weighted: yes",
            f"Materials: {[slot.material.name for slot in racer_mesh.material_slots if slot.material]}",
            f"Images: {images}",
            "Deformation tests:",
            *[f"  {item}" for item in tests],
            "Rest pose restored exactly: yes",
            f"Export options used: {export_options}",
            "BUILD_STATUS=PASS",
        ],
        append=True,
    )


def matrix_difference(left: Matrix, right: Matrix) -> float:
    return max(
        abs(float(left[row][column] - right[row][column]))
        for row in range(4)
        for column in range(4)
    )


def glb_snapshot(path: str, label: str) -> dict:
    clear_scene()
    import_glb(path)
    armatures = [obj for obj in bpy.data.objects if obj.type == "ARMATURE"]
    if len(armatures) != 1:
        raise RuntimeError(f"{label}: expected one armature, got {len(armatures)}.")
    armature = armatures[0]
    meshes = [
        obj
        for obj in bpy.data.objects
        if obj.type == "MESH" and armature_modifier(obj, armature) is not None
    ]
    if len(meshes) != 1:
        raise RuntimeError(
            f"{label}: expected exactly one skinned mesh, got {len(meshes)}."
        )
    mesh = meshes[0]
    ensure_all_weighted(mesh)
    return {
        "armature_name": armature.name,
        "armature_data_name": armature.data.name,
        "mesh_name": mesh.name,
        "armature": armature,
        "mesh": mesh,
        "bone_names": [bone.name for bone in armature.data.bones],
        "parents": {
            bone.name: bone.parent.name if bone.parent else None
            for bone in armature.data.bones
        },
        "matrices": {
            bone.name: bone.matrix_local.copy() for bone in armature.data.bones
        },
        "groups": [group.name for group in mesh.vertex_groups],
        "materials": [
            slot.material.name for slot in mesh.material_slots if slot.material
        ],
        "images": [
            (image.name, tuple(image.size), bool(image.has_data))
            for image in bpy.data.images
            if image.source != "VIEWER"
        ],
        "actions": len(bpy.data.actions),
        "nla": sum(
            len(obj.animation_data.nla_tracks)
            for obj in bpy.data.objects
            if obj.animation_data is not None
        ),
    }


def plain_snapshot(snapshot: dict) -> dict:
    return {
        key: value
        for key, value in snapshot.items()
        if key not in {"armature", "mesh"}
    }


def validate(args: argparse.Namespace) -> None:
    input_glb = str(Path(args.input_glb).resolve())
    reference_glb = str(Path(args.reference_glb).resolve())
    if not Path(input_glb).is_file() or not Path(reference_glb).is_file():
        raise FileNotFoundError("Compatible or reference GLB is missing.")
    compatible_live = glb_snapshot(input_glb, "Compatible")
    compatible = plain_snapshot(compatible_live)
    compatible_armature = compatible_live["armature"]
    compatible_mesh = compatible_live["mesh"]
    compatible_bone_map = semantic_map(compatible["bone_names"])
    tests = deformation_tests(
        compatible_armature, compatible_mesh, compatible_bone_map
    )
    reference = plain_snapshot(glb_snapshot(reference_glb, "Rider_Bot"))
    if compatible["bone_names"] != reference["bone_names"]:
        raise RuntimeError("Literal bone name/order mismatch after clean reopen.")
    if compatible["parents"] != reference["parents"]:
        raise RuntimeError("Literal bone hierarchy mismatch after clean reopen.")
    matrix_errors = {
        name: matrix_difference(compatible["matrices"][name], reference["matrices"][name])
        for name in compatible["bone_names"]
    }
    max_matrix_bone = max(matrix_errors, key=matrix_errors.get)
    max_matrix_error = matrix_errors[max_matrix_bone]
    if max_matrix_error > MATRIX_TOLERANCE:
        raise RuntimeError(
            f"Rest matrix mismatch {max_matrix_error:.9g} on {max_matrix_bone}."
        )
    if set(compatible["groups"]) != set(reference["bone_names"]):
        raise RuntimeError("Compatible vertex groups do not exactly match Rider_Bot bones.")
    if compatible["actions"] or compatible["nla"]:
        raise RuntimeError("Compatible GLB contains animation data.")
    if not compatible["materials"] or not compatible["images"]:
        raise RuntimeError("Compatible GLB lost materials or images.")
    report_trim_from(
        args.report,
        ("=== VALIDATE FAILURE ===", "=== CLEAN GLB REOPEN VALIDATION ==="),
    )
    report_write(
        args.report,
        [
            "=== CLEAN GLB REOPEN VALIDATION ===",
            f"Compatible GLB: {input_glb}",
            f"Reference GLB: {reference_glb}",
            f"Armature object/data: {compatible['armature_name']}/{compatible['armature_data_name']}",
            f"Skinned meshes: 1 ({compatible['mesh_name']})",
            f"Bones/groups: {len(compatible['bone_names'])}/{len(compatible['groups'])}",
            "Literal names/order: identical",
            "Literal hierarchy: identical",
            f"Maximum matrix_local component error: {max_matrix_error:.12g} at {max_matrix_bone}",
            f"Matrix tolerance: {MATRIX_TOLERANCE}",
            f"Actions/NLA: {compatible['actions']}/{compatible['nla']}",
            f"Materials: {compatible['materials']}",
            f"Images: {compatible['images']}",
            "Clean-reopen deformation tests:",
            *[f"  {item}" for item in tests],
            "VALIDATION_STATUS=PASS",
        ],
        append=True,
    )


def main() -> None:
    args = parse_args()
    try:
        if args.mode == "build":
            build(args)
        else:
            validate(args)
    except Exception as error:
        report_write(
            args.report,
            [
                f"=== {args.mode.upper()} FAILURE ===",
                f"{type(error).__name__}: {error}",
                traceback.format_exc(),
            ],
            append=Path(args.report).exists(),
        )
        raise


if __name__ == "__main__":
    main()
