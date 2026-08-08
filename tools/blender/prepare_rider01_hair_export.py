#!/usr/bin/env python3
"""Audit, prepare and validate the MPFB hair export copy in rider 1.blend."""

from __future__ import annotations

import argparse
import math
import sys
import traceback
from pathlib import Path

import bpy
from mathutils import Matrix, Vector


HAIR_HINTS = ("hair", "fur", "hedgehog", "scalp")
ORIGINAL_COLLECTION = "Collection"
EXPORT_COLLECTION = "export copy"
HAIR_SOURCES = ("fur_head_export", "hedgehog_export")
HAIR_TARGET_COUNTS = {
    "fur_head_export": 2000,
    "hedgehog_export": 2000,
}
HAIR_RADIUS_MULTIPLIERS = {
    "fur_head_export": 3.2,
    "hedgehog_export": 2.2,
}
FINAL_HAIR_NAME = "Rider01_HairMesh"
HEAD_BONE_CANDIDATES = ("mixamorig:Head", "mixamorig_Head", "Head")


def arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--mode",
        choices=("audit", "probe", "compare_render", "build", "validate"),
        required=True,
    )
    parser.add_argument("--input-blend", required=True)
    parser.add_argument("--output-blend")
    parser.add_argument("--save-current")
    parser.add_argument("--report", required=True)
    values = sys.argv[sys.argv.index("--") + 1 :] if "--" in sys.argv else []
    args = parser.parse_args(values)
    if args.mode == "build" and not args.output_blend:
        parser.error("--output-blend is required in build mode")
    return args


def write_report(path: str, lines: list[str], append: bool = False) -> None:
    output = Path(path)
    output.parent.mkdir(parents=True, exist_ok=True)
    with output.open("a" if append else "w", encoding="utf-8", newline="\n") as handle:
        if append and output.exists() and output.stat().st_size:
            handle.write("\n")
        handle.write("\n".join(lines))
        handle.write("\n")


def clean_report_failures(path: str) -> None:
    report = Path(path)
    if not report.exists():
        return
    text = report.read_text(encoding="utf-8")
    failure_marker = "=== BUILD FAILURE ==="
    success_marker = "=== HAIR EXPORT BUILD ==="
    failure_index = text.find(failure_marker)
    if failure_index >= 0:
        success_index = text.find(success_marker, failure_index)
        if success_index >= 0:
            text = text[:failure_index].rstrip() + "\n\n" + text[success_index:]
    validation_index = text.find("=== CLEAN PROCESS VALIDATION ===")
    if validation_index >= 0:
        text = text[:validation_index].rstrip() + "\n"
    report.write_text(text.rstrip() + "\n", encoding="utf-8", newline="\n")


def clean_report_for_rebuild(path: str) -> None:
    report = Path(path)
    if not report.exists():
        return
    text = report.read_text(encoding="utf-8")
    indexes = [
        text.find(marker)
        for marker in (
            "=== HAIR EXPORT BUILD ===",
            "=== CLEAN PROCESS VALIDATION ===",
            "=== ORIGINAL HAIR VISUAL REFERENCE ===",
        )
        if text.find(marker) >= 0
    ]
    if indexes:
        report.write_text(
            text[: min(indexes)].rstrip() + "\n",
            encoding="utf-8",
            newline="\n",
        )


def collection_paths_for_object(obj: bpy.types.Object) -> list[str]:
    return sorted(collection.name for collection in obj.users_collection)


def id_reference(value):
    return isinstance(value, bpy.types.ID)


def modifier_details(modifier: bpy.types.Modifier) -> list[str]:
    lines = [f"    Modifier: {modifier.name} ({modifier.type})"]
    for prop in modifier.bl_rna.properties:
        if prop.identifier in {"rna_type", "name", "type"} or prop.is_readonly:
            continue
        try:
            value = getattr(modifier, prop.identifier)
        except Exception:
            continue
        if id_reference(value):
            lines.append(
                f"      {prop.identifier}: {value.__class__.__name__}:{value.name}"
            )
    if modifier.type == "NODES":
        node_group = getattr(modifier, "node_group", None)
        lines.append(
            f"      node_group: {node_group.name if node_group else '<NONE>'}"
        )
        for key in sorted(modifier.keys()):
            try:
                value = modifier[key]
            except Exception:
                continue
            if id_reference(value):
                lines.append(
                    f"      GN input {key}: {value.__class__.__name__}:{value.name}"
                )
            elif isinstance(value, (str, int, float, bool)):
                lines.append(f"      GN input {key}: {value!r}")
    return lines


def constraint_details(obj: bpy.types.Object) -> list[str]:
    lines = []
    for constraint in obj.constraints:
        lines.append(f"    Constraint: {constraint.name} ({constraint.type})")
        target = getattr(constraint, "target", None)
        if target is not None:
            lines.append(f"      target: {target.name}")
        subtarget = getattr(constraint, "subtarget", "")
        if subtarget:
            lines.append(f"      subtarget: {subtarget}")
    return lines


def driver_details(id_block) -> list[str]:
    lines = []
    animation_data = getattr(id_block, "animation_data", None)
    if animation_data is None:
        return lines
    for fcurve in animation_data.drivers:
        refs = []
        for variable in fcurve.driver.variables:
            for target in variable.targets:
                if target.id is not None:
                    refs.append(f"{target.id.__class__.__name__}:{target.id.name}")
        lines.append(
            f"    Driver: {fcurve.data_path}[{fcurve.array_index}] -> {refs}"
        )
    return lines


def material_details(obj: bpy.types.Object) -> list[str]:
    lines = []
    for index, slot in enumerate(obj.material_slots):
        material = slot.material
        if material is None:
            lines.append(f"    Material[{index}]: <NONE>")
            continue
        lines.append(
            f"    Material[{index}]: {material.name}; "
            f"blend={getattr(material, 'surface_render_method', '<NA>')}"
        )
        if material.use_nodes and material.node_tree:
            lines.append(
                "      Nodes: "
                f"{[(node.name, node.bl_idname) for node in material.node_tree.nodes]}"
            )
            for node in material.node_tree.nodes:
                if node.type == "GROUP" and node.node_tree is not None:
                    lines.append(
                        f"      Group {node.node_tree.name}: "
                        f"{[(inner.name, inner.bl_idname) for inner in node.node_tree.nodes]}"
                    )
                    lines.append(
                        "      Group inputs: "
                        f"{[(socket.name, tuple(socket.default_value) if hasattr(getattr(socket, 'default_value', None), '__len__') and not isinstance(socket.default_value, str) else getattr(socket, 'default_value', '<NA>')) for socket in node.inputs]}"
                    )
                if node.type == "BSDF_PRINCIPLED":
                    base = node.inputs.get("Base Color")
                    roughness = node.inputs.get("Roughness")
                    alpha = node.inputs.get("Alpha")
                    lines.append(
                        "      Principled: "
                        f"base={tuple(base.default_value) if base else '<NA>'}; "
                        f"roughness={roughness.default_value if roughness else '<NA>'}; "
                        f"alpha={alpha.default_value if alpha else '<NA>'}"
                    )
                if node.type == "TEX_IMAGE" and node.image is not None:
                    image = node.image
                    lines.append(
                        f"      Image: {image.name}; "
                        f"path={bpy.path.abspath(image.filepath)}; "
                        f"packed={image.packed_file is not None}; "
                        f"size={tuple(image.size)}; loaded={image.has_data}"
                    )
    return lines


def evaluated_geometry(obj: bpy.types.Object) -> dict:
    result = {
        "vertices": None,
        "edges": None,
        "polygons": None,
        "triangles": None,
        "finite": None,
        "error": None,
    }
    if obj.type not in {"MESH", "CURVE", "CURVES", "SURFACE", "FONT", "META"}:
        return result
    depsgraph = bpy.context.evaluated_depsgraph_get()
    evaluated = obj.evaluated_get(depsgraph)
    try:
        mesh = bpy.data.meshes.new_from_object(
            evaluated,
            preserve_all_data_layers=True,
            depsgraph=depsgraph,
        )
    except Exception as error:
        result["error"] = f"{type(error).__name__}: {error}"
        return result
    if mesh is None:
        result["error"] = "new_from_object returned None"
        return result
    try:
        mesh.calc_loop_triangles()
        result.update(
            {
                "vertices": len(mesh.vertices),
                "edges": len(mesh.edges),
                "polygons": len(mesh.polygons),
                "triangles": len(mesh.loop_triangles),
                "finite": all(
                    all(math.isfinite(float(value)) for value in vertex.co)
                    for vertex in mesh.vertices
                ),
            }
        )
    finally:
        bpy.data.meshes.remove(mesh)
    return result


def object_details(obj: bpy.types.Object) -> list[str]:
    lines = [
        f"  Object: {obj.name}",
        f"    type/data: {obj.type}/{obj.data.name if obj.data else '<NONE>'}",
        f"    collections: {collection_paths_for_object(obj)}",
        f"    parent: {obj.parent.name if obj.parent else '<NONE>'}",
        f"    parent_type/bone: {obj.parent_type}/{obj.parent_bone or '<NONE>'}",
        f"    visible viewport/render: {not obj.hide_viewport}/{not obj.hide_render}",
        f"    modifiers: {len(obj.modifiers)}",
        f"    particle systems: {len(obj.particle_systems)}",
        f"    geometry: {evaluated_geometry(obj)}",
        f"    custom properties: {sorted(obj.keys())}",
    ]
    for modifier in obj.modifiers:
        lines.extend(modifier_details(modifier))
    lines.extend(constraint_details(obj))
    lines.extend(driver_details(obj))
    if obj.data is not None:
        lines.extend(driver_details(obj.data))
        for prop in obj.data.bl_rna.properties:
            if prop.type != "POINTER":
                continue
            try:
                value = getattr(obj.data, prop.identifier)
            except Exception:
                continue
            if id_reference(value):
                lines.append(
                    f"    Data pointer {prop.identifier}: "
                    f"{value.__class__.__name__}:{value.name}"
                )
    lines.extend(material_details(obj))
    return lines


def audit(args: argparse.Namespace) -> None:
    input_path = str(Path(args.input_blend).resolve())
    bpy.ops.wm.open_mainfile(filepath=input_path)
    collections = sorted(bpy.data.collections, key=lambda item: item.name.lower())
    hair_objects = sorted(
        [
            obj
            for obj in bpy.data.objects
            if any(hint in obj.name.lower() for hint in HAIR_HINTS)
        ],
        key=lambda item: item.name.lower(),
    )
    rigs = sorted(
        [obj for obj in bpy.data.objects if obj.type == "ARMATURE"],
        key=lambda item: item.name.lower(),
    )
    lines = [
        "=== MPFB HAIR EXPORT AUDIT (PRE-MODIFICATION) ===",
        f"Blender: {bpy.app.version_string}",
        f"File: {input_path}",
        f"Collections ({len(collections)}):",
    ]
    for collection in collections:
        lines.append(
            f"  {collection.name}: {[obj.name for obj in collection.objects]}"
        )
    lines.append(f"Hair-name candidates ({len(hair_objects)}):")
    for obj in hair_objects:
        lines.extend(object_details(obj))
    lines.append(f"Armatures ({len(rigs)}):")
    for rig in rigs:
        head_bones = [
            bone.name
            for bone in rig.data.bones
            if "head" in bone.name.lower() or "neck" in bone.name.lower()
        ]
        lines.extend(
            [
                f"  {rig.name}: data={rig.data.name}; "
                f"collections={collection_paths_for_object(rig)}; "
                f"bones={len(rig.data.bones)}",
                f"    head/neck candidates: {head_bones}",
            ]
        )
    lines.append("AUDIT_STATUS=PASS")
    write_report(args.report, lines)


def mesh_geometry(mesh: bpy.types.Mesh) -> dict:
    mesh.calc_loop_triangles()
    finite = all(
        all(math.isfinite(float(value)) for value in vertex.co)
        for vertex in mesh.vertices
    )
    return {
        "vertices": len(mesh.vertices),
        "edges": len(mesh.edges),
        "polygons": len(mesh.polygons),
        "triangles": len(mesh.loop_triangles),
        "materials": len(mesh.materials),
        "finite": finite,
        "approx_bytes": (
            len(mesh.vertices) * 12
            + len(mesh.edges) * 8
            + len(mesh.loops) * 4
            + len(mesh.polygons) * 16
        ),
    }


def convert_hair_copy(
    source: bpy.types.Object,
    surface: bpy.types.Object,
    collection: bpy.types.Collection,
    suffix: str,
) -> bpy.types.Object:
    duplicate = source.copy()
    duplicate.data = source.data.copy()
    duplicate.name = f"{source.name}_{suffix}"
    collection.objects.link(duplicate)
    if hasattr(duplicate.data, "surface"):
        duplicate.data.surface = surface
    for modifier in duplicate.modifiers:
        if modifier.type == "NODES":
            for key in modifier.keys():
                try:
                    value = modifier[key]
                except Exception:
                    continue
                if value == bpy.data.objects.get("Human"):
                    modifier[key] = surface
    bpy.context.view_layer.update()
    bpy.ops.object.select_all(action="DESELECT")
    duplicate.hide_set(False)
    duplicate.hide_viewport = False
    duplicate.hide_render = False
    duplicate.select_set(True)
    bpy.context.view_layer.objects.active = duplicate
    result = bpy.ops.object.convert(target="MESH", keep_original=False)
    if "FINISHED" not in result:
        raise RuntimeError(f"Could not convert {source.name} to MESH: {result}")
    converted = bpy.context.view_layer.objects.active
    if converted is None or converted.type != "MESH":
        raise RuntimeError(f"{source.name} conversion did not produce a MESH.")
    return converted


def curves_stats(obj: bpy.types.Object) -> dict:
    result = {
        "object_type": obj.type,
        "source_points": None,
        "source_curves": None,
        "evaluated_type": None,
        "evaluated_points": None,
        "evaluated_curves": None,
        "curve_point_samples": [],
        "attributes": [],
    }
    if obj.type == "CURVES":
        result["source_points"] = len(obj.data.points)
        result["source_curves"] = len(obj.data.curves)
    depsgraph = bpy.context.evaluated_depsgraph_get()
    evaluated = obj.evaluated_get(depsgraph)
    result["evaluated_type"] = evaluated.type
    data = evaluated.data
    if evaluated.type == "CURVES":
        result["evaluated_points"] = len(data.points)
        result["evaluated_curves"] = len(data.curves)
        result["attributes"] = sorted(attribute.name for attribute in data.attributes)
        for curve in list(data.curves)[:5]:
            result["curve_point_samples"].append(len(curve.points))
    return result


def probe(args: argparse.Namespace) -> None:
    input_path = str(Path(args.input_blend).resolve())
    bpy.ops.wm.open_mainfile(filepath=input_path)
    required = (
        "fur_head_export",
        "hedgehog_export",
        "Human_export",
    )
    missing = [name for name in required if bpy.data.objects.get(name) is None]
    if missing:
        raise RuntimeError(f"Probe objects missing: {missing}")
    temporary = bpy.data.collections.new("_HAIR_CONVERSION_PROBE")
    bpy.context.scene.collection.children.link(temporary)
    surface = bpy.data.objects["Human_export"]
    remapped = []
    for name in ("fur_head_export", "hedgehog_export"):
        source = bpy.data.objects[name]
        duplicate = source.copy()
        duplicate.data = source.data.copy()
        duplicate.name = f"{source.name}_stats_probe"
        temporary.objects.link(duplicate)
        duplicate.data.surface = surface
        remapped.append(duplicate)
    bpy.context.view_layer.update()
    curve_measurements = {
        obj.name: curves_stats(obj)
        for obj in remapped
    }
    for obj in remapped:
        bpy.data.objects.remove(obj, do_unlink=True)
    converted = [
        convert_hair_copy(
            bpy.data.objects[name],
            surface,
            temporary,
            "probe",
        )
        for name in ("fur_head_export", "hedgehog_export")
    ]
    lines = [
        "=== HAIR CONVERSION PROBE (NOT SAVED) ===",
        f"Surface remap: Human -> {surface.name}",
        f"Evaluated Curves: {curve_measurements}",
    ]
    total_triangles = 0
    for obj in converted:
        geometry = mesh_geometry(obj.data)
        total_triangles += geometry["triangles"]
        lines.append(
            f"  {obj.name}: materials="
            f"{[slot.material.name for slot in obj.material_slots if slot.material]}; "
            f"geometry={geometry}"
        )
    lines.append(f"Combined triangles before joining: {total_triangles}")
    lines.append("PROBE_STATUS=PASS")
    write_report(args.report, lines, append=True)


def original_to_export_map() -> dict[bpy.types.Object, bpy.types.Object]:
    result = {}
    for original in bpy.data.objects:
        if original.name.endswith("_export"):
            continue
        exported = bpy.data.objects.get(f"{original.name}_export")
        if exported is not None:
            result[original] = exported
    if (
        bpy.data.objects.get("Human.rig") is not None
        and bpy.data.objects.get("Human.rig_export") is not None
    ):
        result[bpy.data.objects["Human.rig"]] = bpy.data.objects["Human.rig_export"]
    if (
        bpy.data.objects.get("Human") is not None
        and bpy.data.objects.get("Human_export") is not None
    ):
        result[bpy.data.objects["Human"]] = bpy.data.objects["Human_export"]
    return result


def remap_export_object_dependencies(
    obj: bpy.types.Object,
    mapping: dict[bpy.types.Object, bpy.types.Object],
) -> list[str]:
    changes = []
    if obj.parent in mapping:
        world = obj.matrix_world.copy()
        old = obj.parent
        obj.parent = mapping[old]
        obj.matrix_world = world
        changes.append(f"{obj.name}.parent: {old.name} -> {obj.parent.name}")
    for modifier in obj.modifiers:
        for prop in modifier.bl_rna.properties:
            if prop.type != "POINTER" or prop.is_readonly:
                continue
            try:
                value = getattr(modifier, prop.identifier)
            except Exception:
                continue
            if value in mapping:
                setattr(modifier, prop.identifier, mapping[value])
                changes.append(
                    f"{obj.name}.{modifier.name}.{prop.identifier}: "
                    f"{value.name} -> {mapping[value].name}"
                )
        if modifier.type == "NODES":
            for key in modifier.keys():
                try:
                    value = modifier[key]
                except Exception:
                    continue
                if value in mapping:
                    modifier[key] = mapping[value]
                    changes.append(
                        f"{obj.name}.{modifier.name}[{key}]: "
                        f"{value.name} -> {mapping[value].name}"
                    )
    for constraint in obj.constraints:
        target = getattr(constraint, "target", None)
        if target in mapping:
            constraint.target = mapping[target]
            changes.append(
                f"{obj.name}.{constraint.name}.target: "
                f"{target.name} -> {mapping[target].name}"
            )
    if obj.data is not None and hasattr(obj.data, "surface"):
        surface = obj.data.surface
        if surface in mapping:
            obj.data.surface = mapping[surface]
            changes.append(
                f"{obj.name}.data.surface: "
                f"{surface.name} -> {mapping[surface].name}"
            )
    for owner in (obj, obj.data):
        if owner is None:
            continue
        animation_data = getattr(owner, "animation_data", None)
        if animation_data is None:
            continue
        for fcurve in animation_data.drivers:
            for variable in fcurve.driver.variables:
                for target in variable.targets:
                    if target.id in mapping:
                        old = target.id
                        target.id = mapping[old]
                        changes.append(
                            f"{obj.name}.driver: {old.name} -> {target.id.name}"
                        )
    return changes


def dependency_references_to_original(
    obj: bpy.types.Object,
    original_objects: set[bpy.types.Object],
) -> list[str]:
    references = []
    if obj.parent in original_objects:
        references.append(f"parent:{obj.parent.name}")
    for modifier in obj.modifiers:
        for prop in modifier.bl_rna.properties:
            if prop.type != "POINTER":
                continue
            try:
                value = getattr(modifier, prop.identifier)
            except Exception:
                continue
            if value in original_objects:
                references.append(
                    f"modifier:{modifier.name}.{prop.identifier}:{value.name}"
                )
        if modifier.type == "NODES":
            for key in modifier.keys():
                try:
                    value = modifier[key]
                except Exception:
                    continue
                if value in original_objects:
                    references.append(f"GN:{modifier.name}[{key}]:{value.name}")
    for constraint in obj.constraints:
        target = getattr(constraint, "target", None)
        if target in original_objects:
            references.append(f"constraint:{constraint.name}:{target.name}")
    if obj.data is not None and hasattr(obj.data, "surface"):
        surface = obj.data.surface
        if surface in original_objects:
            references.append(f"data.surface:{surface.name}")
    for owner in (obj, obj.data):
        if owner is None:
            continue
        animation_data = getattr(owner, "animation_data", None)
        if animation_data is None:
            continue
        for fcurve in animation_data.drivers:
            for variable in fcurve.driver.variables:
                for target in variable.targets:
                    if target.id in original_objects:
                        references.append(
                            f"driver:{fcurve.data_path}:{target.id.name}"
                        )
    return references


def evenly_spaced_indices(length: int, target: int) -> list[int]:
    if length <= 0 or target <= 0:
        return []
    if target >= length:
        return list(range(length))
    return sorted(
        {
            int(round(index * (length - 1) / (target - 1)))
            for index in range(target)
        }
    )


def sampled_point_indices(point_count: int, maximum_points: int = 7) -> list[int]:
    if point_count <= maximum_points:
        return list(range(point_count))
    return evenly_spaced_indices(point_count, maximum_points)


def original_hair_colors(material: bpy.types.Material) -> tuple[tuple, tuple]:
    if material.use_nodes and material.node_tree:
        group = next(
            (
                node
                for node in material.node_tree.nodes
                if node.type == "GROUP" and len(node.inputs) >= 2
            ),
            None,
        )
        if group is not None:
            return (
                tuple(float(value) for value in group.inputs[0].default_value),
                tuple(float(value) for value in group.inputs[1].default_value),
            )
    return ((0.117, 0.093, 0.047, 1.0), (0.031, 0.016, 0.004, 1.0))


def mesh_compatible_hair_material(
    source: bpy.types.Material,
    suffix: str,
    dark_mix: float,
) -> bpy.types.Material:
    color_one, color_two = original_hair_colors(source)
    base_color = tuple(
        color_one[index] * (1.0 - dark_mix) + color_two[index] * dark_mix
        for index in range(4)
    )
    material = source.copy()
    material.name = f"{source.name}_{suffix}"
    material.use_nodes = True
    material.node_tree.nodes.clear()
    output = material.node_tree.nodes.new("ShaderNodeOutputMaterial")
    shader = material.node_tree.nodes.new("ShaderNodeBsdfPrincipled")
    shader.inputs["Base Color"].default_value = base_color
    shader.inputs["Roughness"].default_value = 0.52
    shader.inputs["Alpha"].default_value = 1.0
    material.node_tree.links.new(shader.outputs["BSDF"], output.inputs["Surface"])
    if hasattr(material, "surface_render_method"):
        material.surface_render_method = "DITHERED"
    return material


def point_radius(data, point_index: int, fallback: float) -> float:
    attribute = data.attributes.get("radius")
    if attribute is None:
        return fallback
    try:
        value = float(attribute.data[point_index].value)
    except Exception:
        return fallback
    return value if math.isfinite(value) and value > 0.0 else fallback


def build_hair_tube_mesh(
    source_objects: list[bpy.types.Object],
    material_slots: list[bpy.types.Material],
) -> tuple[bpy.types.Mesh, dict]:
    vertices: list[tuple[float, float, float]] = []
    faces: list[tuple[int, ...]] = []
    material_indices: list[int] = []
    report = {
        "sources": {},
        "selected_curves": 0,
        "evaluated_curves": 0,
        "evaluated_points": 0,
        "radius_ranges": {},
    }
    depsgraph = bpy.context.evaluated_depsgraph_get()
    for material_index, source in enumerate(source_objects):
        evaluated = source.evaluated_get(depsgraph)
        if evaluated.type != "CURVES":
            raise RuntimeError(
                f"{source.name} evaluates as {evaluated.type}, expected CURVES."
            )
        data = evaluated.data
        target = HAIR_TARGET_COUNTS[source.name]
        selected_curve_indices = evenly_spaced_indices(len(data.curves), target)
        fallback_radius = 0.0008
        radius_multiplier = HAIR_RADIUS_MULTIPLIERS[source.name]
        radius_min = float("inf")
        radius_max = 0.0
        source_face_start = len(faces)
        source_vertex_start = len(vertices)
        for curve_index in selected_curve_indices:
            curve = data.curves[curve_index]
            curve_points = list(curve.points)
            if len(curve_points) < 2:
                continue
            local_indices = sampled_point_indices(len(curve_points), 3)
            points = [
                evaluated.matrix_world @ curve_points[index].position
                for index in local_indices
            ]
            point_data_indices = [
                curve_points[index].index for index in local_indices
            ]
            previous_side = None
            frame_sides = []
            frame_binormals = []
            frame_radii = []
            for point_number, (position, data_index) in enumerate(
                zip(points, point_data_indices)
            ):
                if point_number == 0:
                    tangent = points[1] - points[0]
                elif point_number == len(points) - 1:
                    tangent = points[-1] - points[-2]
                else:
                    tangent = points[point_number + 1] - points[point_number - 1]
                if tangent.length_squared < 1.0e-16:
                    tangent = Vector((0.0, 0.0, 1.0))
                tangent.normalize()
                if previous_side is None:
                    reference = (
                        Vector((0.0, 0.0, 1.0))
                        if abs(tangent.z) < 0.9
                        else Vector((1.0, 0.0, 0.0))
                    )
                    side = tangent.cross(reference)
                else:
                    side = previous_side - tangent * previous_side.dot(tangent)
                if side.length_squared < 1.0e-16:
                    side = tangent.cross(Vector((0.0, 1.0, 0.0)))
                side.normalize()
                binormal = tangent.cross(side).normalized()
                previous_side = side
                source_radius = point_radius(data, data_index, fallback_radius)
                taper = 1.0 - 0.78 * (
                    point_number / max(1, len(points) - 1)
                )
                radius = max(
                    0.00018,
                    min(0.0030, source_radius * radius_multiplier * taper),
                )
                radius_min = min(radius_min, radius)
                radius_max = max(radius_max, radius)
                frame_sides.append(side)
                frame_binormals.append(binormal)
                frame_radii.append(radius)
            for orientation_vectors in (frame_sides, frame_binormals):
                strip_starts = []
                for position, orientation, radius in zip(
                    points, orientation_vectors, frame_radii
                ):
                    strip_start = len(vertices)
                    strip_starts.append(strip_start)
                    vertices.append(tuple(position - orientation * radius))
                    vertices.append(tuple(position + orientation * radius))
                for strip_index in range(len(strip_starts) - 1):
                    first = strip_starts[strip_index]
                    second = strip_starts[strip_index + 1]
                    faces.append(
                        (
                            first,
                            first + 1,
                            second + 1,
                        )
                    )
                    material_indices.append(material_index)
                    faces.append(
                        (
                            first,
                            second + 1,
                            second,
                        )
                    )
                    material_indices.append(material_index)
        source_faces = len(faces) - source_face_start
        source_vertices = len(vertices) - source_vertex_start
        report["sources"][source.name] = {
            "evaluated_curves": len(data.curves),
            "evaluated_points": len(data.points),
            "selected_curves": len(selected_curve_indices),
            "generated_vertices": source_vertices,
            "generated_triangles": source_faces,
        }
        report["selected_curves"] += len(selected_curve_indices)
        report["evaluated_curves"] += len(data.curves)
        report["evaluated_points"] += len(data.points)
        report["radius_ranges"][source.name] = (
            radius_min if math.isfinite(radius_min) else None,
            radius_max,
        )
    mesh = bpy.data.meshes.new(f"{FINAL_HAIR_NAME}_Data")
    mesh.from_pydata(vertices, [], faces)
    mesh.update()
    for material in material_slots:
        mesh.materials.append(material)
    for polygon, material_index in zip(mesh.polygons, material_indices):
        polygon.material_index = material_index
        polygon.use_smooth = True
    mesh.validate(verbose=True)
    geometry = mesh_geometry(mesh)
    report["final_geometry"] = geometry
    if not geometry["finite"]:
        raise RuntimeError("Generated hair contains non-finite vertices.")
    if geometry["triangles"] >= 50000:
        raise RuntimeError(
            f"Generated hair has {geometry['triangles']} triangles; target is < 50000."
        )
    return mesh, report


def find_head_bone(rig: bpy.types.Object) -> str:
    for candidate in HEAD_BONE_CANDIDATES:
        if candidate in rig.data.bones:
            return candidate
    semantic = [
        bone.name for bone in rig.data.bones if bone.name.lower().endswith("head")
    ]
    if len(semantic) != 1:
        raise RuntimeError(f"Could not resolve a unique head bone: {semantic}")
    return semantic[0]


def clear_export_animation(export_collection: bpy.types.Collection) -> list[str]:
    cleared = []
    for obj in export_collection.all_objects:
        if obj is None:
            continue
        for owner in (obj, obj.data):
            if owner is not None and getattr(owner, "animation_data", None) is not None:
                owner.animation_data_clear()
                cleared.append(f"{obj.name}:{owner.__class__.__name__}")
    return cleared


def world_bbox(objects: list[bpy.types.Object]) -> tuple[Vector, Vector]:
    points = [
        obj.matrix_world @ Vector(corner)
        for obj in objects
        if obj.type == "MESH"
        for corner in obj.bound_box
    ]
    if not points:
        raise RuntimeError("No mesh bounds available for render.")
    minimum = Vector(
        tuple(min(point[axis] for point in points) for axis in range(3))
    )
    maximum = Vector(
        tuple(max(point[axis] for point in points) for axis in range(3))
    )
    return minimum, maximum


def point_camera(camera: bpy.types.Object, target: Vector) -> None:
    direction = target - camera.location
    camera.rotation_euler = direction.to_track_quat("-Z", "Y").to_euler()


def render_validation(
    export_collection: bpy.types.Collection,
    filepath: str,
) -> None:
    temporary = bpy.data.collections.new("_HAIR_VALIDATION_RENDER")
    bpy.context.scene.collection.children.link(temporary)
    objects = list(export_collection.all_objects)
    minimum, maximum = world_bbox(objects)
    center = (minimum + maximum) * 0.5
    height = max(0.1, maximum.z - minimum.z)
    camera_data = bpy.data.cameras.new("_HairValidationCamera")
    camera = bpy.data.objects.new("_HairValidationCamera", camera_data)
    temporary.objects.link(camera)
    camera.location = center + Vector((0.9 * height, -2.4 * height, 0.25 * height))
    point_camera(camera, center + Vector((0.0, 0.0, 0.1 * height)))
    camera_data.lens = 58.0
    bpy.context.scene.camera = camera
    for index, offset in enumerate(
        (
            Vector((-1.5, -1.8, 2.2)),
            Vector((1.8, -0.8, 1.2)),
        )
    ):
        light_data = bpy.data.lights.new(f"_HairValidationLight{index}", "AREA")
        light_data.energy = 900.0 if index == 0 else 500.0
        light_data.shape = "DISK"
        light_data.size = 3.0
        light = bpy.data.objects.new(light_data.name, light_data)
        temporary.objects.link(light)
        light.location = center + offset * height
        point_camera(light, center)
    scene = bpy.context.scene
    scene.render.engine = "BLENDER_EEVEE_NEXT"
    scene.render.resolution_x = 640
    scene.render.resolution_y = 640
    scene.render.resolution_percentage = 100
    scene.render.image_settings.file_format = "PNG"
    scene.render.filepath = filepath
    scene.render.film_transparent = False
    scene.world.color = (0.035, 0.04, 0.05)
    bpy.ops.render.render(write_still=True)
    scene.camera = None
    for obj in list(temporary.objects):
        bpy.data.objects.remove(obj, do_unlink=True)
    bpy.data.collections.remove(temporary)


def render_head_validation(
    visible_collection: bpy.types.Collection,
    hair_objects: list[bpy.types.Object],
    filepath: str,
) -> None:
    temporary = bpy.data.collections.new("_HAIR_HEAD_VALIDATION_RENDER")
    bpy.context.scene.collection.children.link(temporary)
    corners = [
        hair.matrix_world @ Vector(corner)
        for hair in hair_objects
        for corner in hair.bound_box
    ]
    minimum = Vector(
        tuple(min(point[axis] for point in corners) for axis in range(3))
    )
    maximum = Vector(
        tuple(max(point[axis] for point in corners) for axis in range(3))
    )
    center = (minimum + maximum) * 0.5
    extent = max(0.12, *(maximum - minimum))
    camera_data = bpy.data.cameras.new("_HairHeadValidationCamera")
    camera = bpy.data.objects.new("_HairHeadValidationCamera", camera_data)
    temporary.objects.link(camera)
    camera.location = center + Vector((0.7 * extent, -3.1 * extent, 0.2 * extent))
    point_camera(camera, center)
    camera_data.lens = 62.0
    bpy.context.scene.camera = camera
    for index, offset in enumerate(
        (Vector((-2.2, -2.0, 2.5)), Vector((2.0, -1.0, 0.7)))
    ):
        data = bpy.data.lights.new(f"_HairHeadLight{index}", "AREA")
        data.energy = 550.0 if index == 0 else 350.0
        data.size = 1.2
        light = bpy.data.objects.new(data.name, data)
        temporary.objects.link(light)
        light.location = center + offset * extent
        point_camera(light, center)
    scene = bpy.context.scene
    scene.render.engine = "BLENDER_EEVEE_NEXT"
    scene.render.resolution_x = 768
    scene.render.resolution_y = 768
    scene.render.resolution_percentage = 100
    scene.render.image_settings.file_format = "PNG"
    scene.render.filepath = filepath
    scene.render.film_transparent = False
    scene.world.color = (0.035, 0.04, 0.05)
    bpy.ops.render.render(write_still=True)
    scene.camera = None
    for obj in list(temporary.objects):
        bpy.data.objects.remove(obj, do_unlink=True)
    bpy.data.collections.remove(temporary)


def compare_render(args: argparse.Namespace) -> None:
    input_path = str(Path(args.input_blend).resolve())
    bpy.ops.wm.open_mainfile(filepath=input_path)
    original_collection = bpy.data.collections.get(ORIGINAL_COLLECTION)
    export_collection = bpy.data.collections.get(EXPORT_COLLECTION)
    if original_collection is None or export_collection is None:
        raise RuntimeError("Comparison render collections are missing.")
    original_hair = [
        bpy.data.objects.get("fur_head"),
        bpy.data.objects.get("hedgehog"),
    ]
    if any(obj is None for obj in original_hair):
        raise RuntimeError("Original procedural hair is missing.")
    original_collection.hide_viewport = False
    original_collection.hide_render = False
    export_collection.hide_viewport = True
    export_collection.hide_render = True
    for obj in original_collection.all_objects:
        if obj is not None:
            obj.hide_render = False
            obj.hide_viewport = False
            obj.hide_set(False)
    bpy.context.view_layer.update()
    output = str(
        Path(input_path).with_name("rider_01_hair_original_head_reference.png")
    )
    render_head_validation(original_collection, original_hair, output)
    write_report(
        args.report,
        [
            "=== ORIGINAL HAIR VISUAL REFERENCE ===",
            f"Original-only close-up: {output}",
            "COMPARE_RENDER_STATUS=PASS",
        ],
        append=True,
    )


def evaluated_world_sample(
    obj: bpy.types.Object,
    maximum: int = 250,
) -> list[Vector]:
    if obj.type != "MESH":
        return []
    depsgraph = bpy.context.evaluated_depsgraph_get()
    evaluated = obj.evaluated_get(depsgraph)
    mesh = evaluated.data
    step = max(1, len(mesh.vertices) // maximum)
    return [
        evaluated.matrix_world @ mesh.vertices[index].co
        for index in range(0, len(mesh.vertices), step)
    ]


def maximum_sample_displacement(
    before: list[Vector],
    after: list[Vector],
) -> float:
    return max(
        ((right - left).length for left, right in zip(before, after)),
        default=0.0,
    )


def deformation_validation(
    rig: bpy.types.Object,
    hair: bpy.types.Object,
    export_collection: bpy.types.Collection,
    head_bone: str,
) -> dict:
    original_bases = {
        bone.name: bone.matrix_basis.copy() for bone in rig.pose.bones
    }
    original_pose_position = rig.data.pose_position
    rig.data.pose_position = "POSE"
    body_candidates = [
        obj
        for obj in export_collection.all_objects
        if obj.type == "MESH"
        and obj != hair
        and any(
            modifier.type == "ARMATURE" and modifier.object == rig
            for modifier in obj.modifiers
        )
    ]
    glasses = bpy.data.objects.get("Human.punkduck_sport-sunglasses_export")
    results = {}
    tests = (
        (head_bone, 15.0, "Y"),
        ("mixamorig:Neck", 10.0, "X"),
        ("mixamorig:Spine2", 10.0, "Z"),
    )
    try:
        for bone_name, degrees, axis in tests:
            if bone_name not in rig.pose.bones:
                raise RuntimeError(f"Pose test bone missing: {bone_name}")
            hair_before = hair.matrix_world.copy()
            body_before = (
                evaluated_world_sample(body_candidates[0])
                if body_candidates
                else []
            )
            glasses_before = (
                evaluated_world_sample(glasses)
                if glasses is not None and glasses.type == "MESH"
                else []
            )
            pose_bone = rig.pose.bones[bone_name]
            pose_bone.matrix_basis = (
                original_bases[bone_name]
                @ Matrix.Rotation(math.radians(degrees), 4, axis)
            )
            bpy.context.view_layer.update()
            hair_translation = (
                hair.matrix_world.translation - hair_before.translation
            ).length
            hair_rotation_change = max(
                abs(
                    float(
                        hair.matrix_world[row][column]
                        - hair_before[row][column]
                    )
                )
                for row in range(3)
                for column in range(3)
            )
            body_after = (
                evaluated_world_sample(body_candidates[0])
                if body_candidates
                else []
            )
            glasses_after = (
                evaluated_world_sample(glasses)
                if glasses is not None and glasses.type == "MESH"
                else []
            )
            results[bone_name] = {
                "degrees": degrees,
                "hair_translation_m": hair_translation,
                "hair_rotation_component_change": hair_rotation_change,
                "body_max_displacement_m": maximum_sample_displacement(
                    body_before, body_after
                ),
                "glasses_max_displacement_m": maximum_sample_displacement(
                    glasses_before, glasses_after
                ),
            }
            if hair_translation <= 1.0e-8 and hair_rotation_change <= 1.0e-8:
                raise RuntimeError(f"Hair did not follow {bone_name}.")
            pose_bone.matrix_basis = original_bases[bone_name].copy()
            bpy.context.view_layer.update()
        unaffected_name = next(
            (
                name
                for name in ("mixamorig:LeftArm", "mixamorig_LeftArm", "LeftArm")
                if name in rig.pose.bones
            ),
            None,
        )
        if unaffected_name is None:
            raise RuntimeError("Could not resolve LeftArm for isolation test.")
        hair_before = hair.matrix_world.copy()
        pose_bone = rig.pose.bones[unaffected_name]
        pose_bone.matrix_basis = (
            original_bases[unaffected_name]
            @ Matrix.Rotation(math.radians(15.0), 4, "Y")
        )
        bpy.context.view_layer.update()
        arm_effect = max(
            abs(float(hair.matrix_world[row][column] - hair_before[row][column]))
            for row in range(4)
            for column in range(4)
        )
        results["arm_isolation"] = {
            "bone": unaffected_name,
            "max_matrix_component_change": arm_effect,
        }
        if arm_effect > 1.0e-7:
            raise RuntimeError(
                f"Arm pose unexpectedly moved rigid hair: {arm_effect:.9g}"
            )
    finally:
        for bone_name, matrix in original_bases.items():
            rig.pose.bones[bone_name].matrix_basis = matrix
        rig.data.pose_position = original_pose_position
        bpy.context.view_layer.update()
    for bone_name, matrix in original_bases.items():
        if max(
            abs(
                float(
                    rig.pose.bones[bone_name].matrix_basis[row][column]
                    - matrix[row][column]
                )
            )
            for row in range(4)
            for column in range(4)
        ) > 1.0e-12:
            raise RuntimeError(f"Pose was not restored on {bone_name}.")
    results["restored_exactly"] = True
    results["body_candidates"] = [obj.name for obj in body_candidates]
    results["glasses"] = glasses.name if glasses else None
    return results


def pack_available_images() -> tuple[list[dict], list[str]]:
    packed = []
    missing = []
    for image in bpy.data.images:
        if image.source in {"VIEWER", "GENERATED"}:
            continue
        absolute = Path(bpy.path.abspath(image.filepath)) if image.filepath else None
        available = image.packed_file is not None or (
            absolute is not None and absolute.exists()
        )
        if available and image.packed_file is None and image.has_data:
            try:
                image.pack()
            except RuntimeError:
                pass
        if not available and image.packed_file is None:
            missing.append(image.name)
        packed.append(
            {
                "name": image.name,
                "path": str(absolute) if absolute else image.filepath,
                "packed": image.packed_file is not None,
                "size": tuple(image.size),
            }
        )
    return packed, missing


def material_images(material: bpy.types.Material) -> set[bpy.types.Image]:
    images: set[bpy.types.Image] = set()
    visited = set()

    def visit_tree(tree) -> None:
        if tree is None or tree in visited:
            return
        visited.add(tree)
        for node in tree.nodes:
            if node.type == "TEX_IMAGE" and node.image is not None:
                images.add(node.image)
            if node.type == "GROUP" and node.node_tree is not None:
                visit_tree(node.node_tree)

    if material.use_nodes:
        visit_tree(material.node_tree)
    return images


def export_image_audit(
    export_collection: bpy.types.Collection,
) -> tuple[list[dict], list[str]]:
    images = set()
    for obj in export_collection.all_objects:
        if obj is None:
            continue
        for slot in obj.material_slots:
            if slot.material is not None:
                images.update(material_images(slot.material))
    results = []
    missing = []
    for image in sorted(images, key=lambda item: item.name.lower()):
        absolute = Path(bpy.path.abspath(image.filepath)) if image.filepath else None
        available = (
            image.packed_file is not None
            or image.has_data
            or (absolute is not None and absolute.exists())
        )
        results.append(
            {
                "name": image.name,
                "path": str(absolute) if absolute else image.filepath,
                "packed": image.packed_file is not None,
                "loaded": image.has_data,
                "size": tuple(image.size),
            }
        )
        if not available:
            missing.append(image.name)
    return results, missing


def build(args: argparse.Namespace) -> None:
    input_path = str(Path(args.input_blend).resolve())
    current_output_path = str(
        Path(args.save_current).resolve()
        if args.save_current
        else Path(args.input_blend).resolve()
    )
    output_path = str(Path(args.output_blend).resolve())
    bpy.ops.wm.open_mainfile(filepath=input_path)
    original_collection = bpy.data.collections.get(ORIGINAL_COLLECTION)
    export_collection = bpy.data.collections.get(EXPORT_COLLECTION)
    if original_collection is None or export_collection is None:
        raise RuntimeError("Original or export copy collection is missing.")
    required = [
        "Human",
        "Human.rig",
        "Human_export",
        "Human.rig_export",
        *HAIR_SOURCES,
        "fur_head",
        "hedgehog",
    ]
    missing = [name for name in required if bpy.data.objects.get(name) is None]
    if missing:
        raise RuntimeError(f"Required objects missing: {missing}")
    original_objects = set(original_collection.all_objects)
    original_snapshot = {
        obj.name: (
            obj.type,
            obj.data.name if obj.data else None,
            obj.parent.name if obj.parent else None,
            tuple(modifier.name for modifier in obj.modifiers),
        )
        for obj in original_objects
    }
    mapping = original_to_export_map()
    remaps = []
    for obj in list(export_collection.all_objects):
        remaps.extend(remap_export_object_dependencies(obj, mapping))
    bpy.context.view_layer.update()
    sources = [bpy.data.objects[name] for name in HAIR_SOURCES]
    for source in sources:
        if source.type != "CURVES":
            raise RuntimeError(f"{source.name} is {source.type}, expected CURVES.")
        if source.data.surface != bpy.data.objects["Human_export"]:
            raise RuntimeError(f"{source.name} surface remap failed.")
    existing_final = bpy.data.objects.get(FINAL_HAIR_NAME)
    if existing_final is not None:
        if existing_final not in export_collection.all_objects:
            raise RuntimeError(
                f"Existing {FINAL_HAIR_NAME} is outside export copy."
            )
        bpy.data.objects.remove(existing_final, do_unlink=True)
    source_materials = []
    for source in sources:
        material = source.material_slots[0].material if source.material_slots else None
        if material is None:
            raise RuntimeError(f"{source.name} has no visible material.")
        source_materials.append(material)
    materials = [
        mesh_compatible_hair_material(
            source_materials[0],
            "Rider01_Mesh",
            0.0,
        ),
        mesh_compatible_hair_material(
            source_materials[1],
            "Rider01_Mesh",
            0.18,
        ),
    ]
    hair_mesh, generation_report = build_hair_tube_mesh(sources, materials)
    hair = bpy.data.objects.new(FINAL_HAIR_NAME, hair_mesh)
    export_collection.objects.link(hair)
    hair.matrix_world = Matrix.Identity(4)
    rig = bpy.data.objects["Human.rig_export"]
    if rig.type != "ARMATURE":
        raise RuntimeError("Human.rig_export is not an ARMATURE.")
    head_bone = find_head_bone(rig)
    hair_world = hair.matrix_world.copy()
    hair.parent = rig
    hair.parent_type = "BONE"
    hair.parent_bone = head_bone
    hair.matrix_world = hair_world
    bpy.context.view_layer.update()
    if hair.parent != rig or hair.parent_bone != head_bone:
        raise RuntimeError("Final hair bone parenting failed.")
    dependencies_before_cleanup = {
        source.name: dependency_references_to_original(source, original_objects)
        for source in sources
    }
    final_dependencies = dependency_references_to_original(hair, original_objects)
    if final_dependencies:
        raise RuntimeError(
            f"Final hair still references original objects: {final_dependencies}"
        )
    for source in sources:
        bpy.data.objects.remove(source, do_unlink=True)
    bpy.context.view_layer.update()
    cleared_animation = clear_export_animation(export_collection)
    for collection in (original_collection,):
        collection.hide_render = True
        collection.hide_viewport = True
    export_collection.hide_render = False
    export_collection.hide_viewport = False
    for obj in list(export_collection.all_objects):
        if obj is None:
            continue
        obj.hide_render = False
        obj.hide_viewport = False
        obj.hide_set(False)
    bpy.context.view_layer.update()
    deformation = deformation_validation(
        rig,
        hair,
        export_collection,
        head_bone,
    )
    render_path = str(Path(output_path).with_name("rider_01_hair_export_validation.png"))
    render_validation(export_collection, render_path)
    packed_images, missing_images = pack_available_images()
    after_snapshot = {
        obj.name: (
            obj.type,
            obj.data.name if obj.data else None,
            obj.parent.name if obj.parent else None,
            tuple(modifier.name for modifier in obj.modifiers),
        )
        for obj in original_objects
    }
    if after_snapshot != original_snapshot:
        raise RuntimeError("Original collection object structure changed.")
    export_dependencies = {
        obj.name: dependency_references_to_original(obj, original_objects)
        for obj in export_collection.all_objects
    }
    export_dependencies = {
        name: refs for name, refs in export_dependencies.items() if refs
    }
    if export_dependencies:
        raise RuntimeError(
            f"Export copy still depends on original objects: {export_dependencies}"
        )
    if any(
        obj.type in {"CAMERA", "LIGHT"} for obj in export_collection.all_objects
    ):
        raise RuntimeError("Camera or light remains inside export copy.")
    hair_geometry = mesh_geometry(hair.data)
    Path(output_path).parent.mkdir(parents=True, exist_ok=True)
    bpy.ops.wm.save_as_mainfile(filepath=current_output_path)
    bpy.ops.wm.save_as_mainfile(filepath=output_path, copy=True)
    clean_report_for_rebuild(args.report)
    lines = [
        "=== HAIR EXPORT BUILD ===",
        f"Build source: {input_path}",
        f"Current file saved: {current_output_path}",
        f"Export-ready copy: {output_path}",
        f"Original collection preserved: {after_snapshot == original_snapshot}",
        "Original hair objects: fur_head (CURVES), hedgehog (CURVES)",
        "Original hair surface: Human",
        "Existing export intermediates: fur_head_export, hedgehog_export",
        f"Dependency remaps: {remaps}",
        f"Intermediate original references before cleanup: {dependencies_before_cleanup}",
        "Conversion method: evaluated Hair Curves sampled uniformly, "
        "simplified to 3 points, converted to two tapered crossed ribbons, "
        "then combined into one independent mesh.",
        f"Generation: {generation_report}",
        f"Final geometry: {hair_geometry}",
        f"Parent rig/bone: {rig.name}/{head_bone}; type={hair.parent_type}",
        f"Source material colors: "
        f"{[original_hair_colors(material) for material in source_materials]}",
        f"Mesh-compatible materials: {[material.name for material in materials]}",
        f"Packed images: {packed_images}",
        f"Missing images: {missing_images}",
        f"Cleared export animation data: {cleared_animation}",
        f"Final dependencies to original: {final_dependencies}",
        f"All export dependencies to original: {export_dependencies}",
        f"Deformation validation: {deformation}",
        f"Validation render: {render_path}",
        "Procedural export intermediates removed: fur_head_export, hedgehog_export",
        "No GLB exported.",
        "BUILD_STATUS=PASS",
    ]
    write_report(args.report, lines, append=True)


def validate(args: argparse.Namespace) -> None:
    input_path = str(Path(args.input_blend).resolve())
    bpy.ops.wm.open_mainfile(filepath=input_path)
    original_collection = bpy.data.collections.get(ORIGINAL_COLLECTION)
    export_collection = bpy.data.collections.get(EXPORT_COLLECTION)
    if original_collection is None or export_collection is None:
        raise RuntimeError("Clean reopen is missing required collections.")
    hair = bpy.data.objects.get(FINAL_HAIR_NAME)
    rig = bpy.data.objects.get("Human.rig_export")
    if hair is None or hair.type != "MESH":
        raise RuntimeError("Rider01_HairMesh is missing or is not MESH.")
    if rig is None or rig.type != "ARMATURE":
        raise RuntimeError("Human.rig_export is missing or invalid.")
    head_bone = find_head_bone(rig)
    if (
        hair.parent != rig
        or hair.parent_type != "BONE"
        or hair.parent_bone != head_bone
    ):
        raise RuntimeError("Clean-reopen hair parenting is invalid.")
    if list(obj for obj in export_collection.all_objects if obj.name in HAIR_SOURCES):
        raise RuntimeError("Procedural export hair intermediates remain.")
    original_objects = set(original_collection.all_objects)
    dependencies = {
        obj.name: dependency_references_to_original(obj, original_objects)
        for obj in export_collection.all_objects
    }
    dependencies = {name: refs for name, refs in dependencies.items() if refs}
    if dependencies:
        raise RuntimeError(f"Clean-reopen original dependencies: {dependencies}")
    geometry = mesh_geometry(hair.data)
    if not geometry["finite"] or geometry["triangles"] >= 50000:
        raise RuntimeError(f"Clean-reopen geometry invalid: {geometry}")
    if any(modifier.type == "NODES" for modifier in hair.modifiers):
        raise RuntimeError("Final hair still has Geometry Nodes.")
    if hair.data.materials[:].count(None) or len(hair.data.materials) < 2:
        raise RuntimeError("Final hair materials are missing.")
    deformation = deformation_validation(
        rig,
        hair,
        export_collection,
        head_bone,
    )
    visible_export = [
        obj.name
        for obj in export_collection.all_objects
        if not obj.hide_render and not obj.hide_viewport
    ]
    required_visible = (
        "Human_export",
        "Human.elvs_male_athletic_tank1_export",
        "Human.elvs_male_swim_shorts1_export",
        "Human.eyebrow004_export",
        "Human.eyelashes01_export",
        "Human.high-poly_export",
        "Human.punkduck_sport-sunglasses_export",
        "Human.teeth_base_export",
        "Human.tongue01_export",
        FINAL_HAIR_NAME,
    )
    missing_visible = [
        name for name in required_visible if name not in visible_export
    ]
    if missing_visible:
        raise RuntimeError(
            f"Required export objects are not visible: {missing_visible}"
        )
    used_images, missing_images = export_image_audit(export_collection)
    if missing_images:
        raise RuntimeError(f"Visible export textures are missing: {missing_images}")
    head_render = str(
        Path(input_path).with_name("rider_01_hair_export_head_validation.png")
    )
    render_head_validation(export_collection, [hair], head_render)
    clean_report_failures(args.report)
    lines = [
        "=== CLEAN PROCESS VALIDATION ===",
        f"File: {input_path}",
        f"Original collection hidden viewport/render: "
        f"{original_collection.hide_viewport}/{original_collection.hide_render}",
        f"Visible export objects: {visible_export}",
        f"Final hair geometry: {geometry}",
        f"Final hair materials: {[material.name for material in hair.data.materials]}",
        "Final hair material audit:",
        *material_details(hair),
        f"Visible export texture audit: {used_images}",
        f"Missing visible export textures: {missing_images}",
        f"Final parent: {rig.name}/{head_bone} ({hair.parent_type})",
        f"Dependencies to original: {dependencies}",
        f"Geometry Nodes on final hair: "
        f"{[modifier.name for modifier in hair.modifiers if modifier.type == 'NODES']}",
        f"Clean deformation validation: {deformation}",
        f"Actions on export rig: "
        f"{rig.animation_data.action.name if rig.animation_data and rig.animation_data.action else None}",
        f"NLA tracks on export rig: "
        f"{len(rig.animation_data.nla_tracks) if rig.animation_data else 0}",
        f"Head close-up validation render: {head_render}",
        "No GLB exported.",
        "VALIDATION_STATUS=PASS",
    ]
    write_report(args.report, lines, append=True)


def main() -> None:
    args = arguments()
    try:
        if args.mode == "audit":
            audit(args)
        elif args.mode == "probe":
            probe(args)
        elif args.mode == "compare_render":
            compare_render(args)
        elif args.mode == "build":
            build(args)
        else:
            validate(args)
    except Exception as error:
        write_report(
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
