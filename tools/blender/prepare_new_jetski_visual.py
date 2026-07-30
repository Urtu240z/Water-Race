"""Prepare the replacement JetSki hull and handle as independent Godot GLBs.

Run with Blender:
    blender --background --factory-startup --python prepare_new_jetski_visual.py -- \
        <source.blend> <output_directory>

The source model uses Blender's X/Y/Z convention (width/length/up).  Both
exports retain one shared coordinate system, with the hull's minimum corner as
the origin.  This lets Godot rotate the handle around a dedicated HandlePivot
without changing the relative placement authored in Blender.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

import bmesh
import bpy
from mathutils import Vector


def _arguments() -> tuple[Path, Path]:
    if "--" not in sys.argv:
        raise RuntimeError("Expected: -- <source.blend> <output_directory>")
    arguments = sys.argv[sys.argv.index("--") + 1 :]
    if len(arguments) != 2:
        raise RuntimeError("Expected exactly two arguments after --")
    return Path(arguments[0]).resolve(), Path(arguments[1]).resolve()


def _mesh_object(name: str) -> bpy.types.Object:
    obj = bpy.data.objects.get(name)
    if obj is None or obj.type != "MESH":
        raise RuntimeError(f"Required mesh object not found: {name}")
    return obj


def _apply_object_transform(obj: bpy.types.Object) -> None:
    bpy.ops.object.select_all(action="DESELECT")
    obj.select_set(True)
    bpy.context.view_layer.objects.active = obj
    for modifier in tuple(obj.modifiers):
        bpy.ops.object.modifier_apply(modifier=modifier.name)
    bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)


def _clean_mesh(obj: bpy.types.Object) -> None:
    mesh = obj.data
    bm = bmesh.new()
    bm.from_mesh(mesh)
    bmesh.ops.remove_doubles(bm, verts=bm.verts, dist=0.000001)
    loose_vertices = [vertex for vertex in bm.verts if not vertex.link_faces]
    if loose_vertices:
        bmesh.ops.delete(bm, geom=loose_vertices, context="VERTS")
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    bm.to_mesh(mesh)
    bm.free()
    mesh.validate(clean_customdata=False)
    mesh.update()


def _make_materials_opaque(objects: tuple[bpy.types.Object, ...]) -> None:
    materials: set[bpy.types.Material] = set()
    for obj in objects:
        materials.update(material for material in obj.data.materials if material)

    for material in materials:
        material.diffuse_color[3] = 1.0
        if not material.use_nodes:
            continue
        principled = next(
            (
                node
                for node in material.node_tree.nodes
                if node.type == "BSDF_PRINCIPLED"
            ),
            None,
        )
        if principled is not None:
            principled.inputs["Alpha"].default_value = 1.0


def _export_selected(obj: bpy.types.Object, destination: Path) -> None:
    bpy.ops.object.select_all(action="DESELECT")
    obj.select_set(True)
    bpy.context.view_layer.objects.active = obj
    bpy.ops.export_scene.gltf(
        filepath=str(destination),
        export_format="GLB",
        use_selection=True,
        export_apply=False,
        export_yup=True,
        export_materials="EXPORT",
        export_image_format="AUTO",
    )


def main() -> None:
    source_path, output_directory = _arguments()
    if not source_path.is_file():
        raise FileNotFoundError(source_path)
    output_directory.mkdir(parents=True, exist_ok=True)

    bpy.ops.wm.open_mainfile(filepath=str(source_path))
    hull = _mesh_object("hull")
    handle = _mesh_object("handle")

    for obj in (hull, handle):
        _apply_object_transform(obj)

    hull_minimum = Vector(
        min(vertex.co[axis] for vertex in hull.data.vertices)
        for axis in range(3)
    )
    for obj in (hull, handle):
        for vertex in obj.data.vertices:
            vertex.co -= hull_minimum
        obj.location = Vector((0.0, 0.0, 0.0))
        _clean_mesh(obj)

    hull.name = "NewJetSki_Hull"
    hull.data.name = "NewJetSki_Hull_Mesh"
    handle.name = "NewJetSki_Handle"
    handle.data.name = "NewJetSki_Handle_Mesh"
    _make_materials_opaque((hull, handle))

    hull_path = output_directory / "NewJetSki_Hull.glb"
    handle_path = output_directory / "NewJetSki_Handle.glb"
    _export_selected(hull, hull_path)
    _export_selected(handle, handle_path)

    report = {
        "source": str(source_path),
        "hull_glb": str(hull_path),
        "handle_glb": str(handle_path),
        "shared_origin_blender": list(hull_minimum),
        "hull_vertices": len(hull.data.vertices),
        "hull_triangles": sum(len(p.loop_indices) - 2 for p in hull.data.polygons),
        "handle_vertices": len(handle.data.vertices),
        "handle_triangles": sum(
            len(p.loop_indices) - 2 for p in handle.data.polygons
        ),
    }
    print("CODEX_NEW_JETSKI=" + json.dumps(report))


if __name__ == "__main__":
    main()
