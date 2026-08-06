"""Generate the island-style palm impostor ribbons from Blender curves.

Usage in Blender 4.5:
1. Open this file in the Scripting workspace and press Run Script.
2. Select one or more Curve objects (or place them in PALM_IMPOSTOR_CURVES).
3. Open the 3D View sidebar (N) > Palm Ribbons > Generate From Curves.

The source curves are never modified. Generated meshes are rebuilt inside the
PALM_IMPOSTOR_GENERATED collection and marked with custom properties.
"""

import math
import random
import zlib
from pathlib import Path

import bpy
from bpy.props import FloatProperty, IntProperty
from bpy.types import Operator, Panel
from mathutils import Vector


PROJECT_ROOT = Path(r"C:\Users\ehort\Documents\GODOT PROJECTS\Water Race")
ATLAS_PATH = (
    PROJECT_ROOT
    / "assets"
    / "3D"
    / "Terrain"
    / "test_island_palm_billboard_continuous_atlas.png"
)
SOURCE_COLLECTION_NAME = "PALM_IMPOSTOR_CURVES"
OUTPUT_COLLECTION_NAME = "PALM_IMPOSTOR_GENERATED"
MATERIAL_NAME = "MAT_Palm_Billboard_Continuous"
ATLAS_U_MIN = 0.038
ATLAS_U_MAX = 0.960
ATLAS_BANDS = (
    (0.0006, 0.3328),
    (0.3339, 0.6661),
    (0.6672, 0.9994),
)


def _bezier_point(p0, p1, p2, p3, t):
    inverse = 1.0 - t
    return (
        p0 * (inverse ** 3)
        + p1 * (3.0 * inverse * inverse * t)
        + p2 * (3.0 * inverse * t * t)
        + p3 * (t ** 3)
    )


def _evaluated_bezier_polyline(curve_object, spline, spacing):
    points = spline.bezier_points
    if len(points) < 2:
        return []
    segment_count = len(points) if spline.use_cyclic_u else len(points) - 1
    result = []
    for segment_index in range(segment_count):
        current = points[segment_index]
        following = points[(segment_index + 1) % len(points)]
        local_length_hint = (following.co - current.co).length
        subdivisions = max(8, int(math.ceil(local_length_hint / max(spacing * 0.35, 0.25))))
        for step in range(subdivisions):
            if segment_index > 0 and step == 0:
                continue
            t = step / float(subdivisions)
            local_point = _bezier_point(
                current.co,
                current.handle_right,
                following.handle_left,
                following.co,
                t,
            )
            result.append(curve_object.matrix_world @ local_point)
    if not spline.use_cyclic_u:
        result.append(curve_object.matrix_world @ points[-1].co)
    elif result:
        result.append(result[0].copy())
    return result


def _evaluated_poly_spline(curve_object, spline):
    if len(spline.points) < 2:
        return []
    result = [curve_object.matrix_world @ point.co.xyz for point in spline.points]
    if spline.use_cyclic_u:
        result.append(result[0].copy())
    return result


def _resample_polyline(points, spacing):
    if len(points) < 2:
        return points
    cumulative = [0.0]
    for index in range(1, len(points)):
        cumulative.append(cumulative[-1] + (points[index] - points[index - 1]).length)
    total_length = cumulative[-1]
    if total_length <= 0.0001:
        return [points[0]]
    targets = []
    target = 0.0
    while target < total_length:
        targets.append(target)
        target += spacing
    targets.append(total_length)
    result = []
    segment_index = 0
    for distance in targets:
        while (
            segment_index + 1 < len(cumulative)
            and cumulative[segment_index + 1] < distance
        ):
            segment_index += 1
        if segment_index + 1 >= len(points):
            result.append(points[-1].copy())
            continue
        start_distance = cumulative[segment_index]
        end_distance = cumulative[segment_index + 1]
        factor = 0.0
        if end_distance > start_distance:
            factor = (distance - start_distance) / (end_distance - start_distance)
        result.append(points[segment_index].lerp(points[segment_index + 1], factor))
    return result


def _curve_polylines(curve_object, spacing):
    output = []
    for spline in curve_object.data.splines:
        if spline.type == "BEZIER":
            dense = _evaluated_bezier_polyline(curve_object, spline, spacing)
        elif spline.type in {"POLY", "NURBS"}:
            dense = _evaluated_poly_spline(curve_object, spline)
        else:
            dense = []
        sampled = _resample_polyline(dense, spacing)
        if len(sampled) >= 2:
            output.append(sampled)
    return output


def _get_or_create_output_collection(scene):
    collection = bpy.data.collections.get(OUTPUT_COLLECTION_NAME)
    if collection is None:
        collection = bpy.data.collections.new(OUTPUT_COLLECTION_NAME)
        scene.collection.children.link(collection)
    elif collection.name not in {child.name for child in scene.collection.children}:
        scene.collection.children.link(collection)
    return collection


def _clear_generated_objects():
    collection = bpy.data.collections.get(OUTPUT_COLLECTION_NAME)
    if collection is None:
        return 0
    removed = 0
    for obj in list(collection.objects):
        if obj.get("palm_impostor_generated", False):
            bpy.data.objects.remove(obj, do_unlink=True)
            removed += 1
    return removed


def _get_or_create_material():
    material = bpy.data.materials.get(MATERIAL_NAME)
    if material is None:
        material = bpy.data.materials.new(MATERIAL_NAME)
    material.use_nodes = True
    material.diffuse_color = (0.42, 0.52, 0.28, 1.0)
    nodes = material.node_tree.nodes
    links = material.node_tree.links
    nodes.clear()
    output = nodes.new("ShaderNodeOutputMaterial")
    principled = nodes.new("ShaderNodeBsdfPrincipled")
    texture = nodes.new("ShaderNodeTexImage")
    output.location = (420.0, 0.0)
    principled.location = (120.0, 0.0)
    texture.location = (-220.0, 40.0)
    if ATLAS_PATH.exists():
        image = bpy.data.images.get(ATLAS_PATH.name)
        if image is None:
            image = bpy.data.images.load(str(ATLAS_PATH), check_existing=True)
        texture.image = image
        texture.interpolation = "Linear"
    links.new(texture.outputs["Color"], principled.inputs["Base Color"])
    links.new(texture.outputs["Alpha"], principled.inputs["Alpha"])
    links.new(principled.outputs["BSDF"], output.inputs["Surface"])
    principled.inputs["Roughness"].default_value = 0.72
    principled.inputs["Metallic"].default_value = 0.0
    try:
        material.surface_render_method = "DITHERED"
    except (AttributeError, TypeError):
        pass
    material.use_transparency_overlap = False
    material["godot_alpha_scissor_threshold"] = 0.665
    material["source_atlas"] = str(ATLAS_PATH)
    return material


def _create_ribbon_mesh(
    collection,
    material,
    name,
    points,
    height,
    z_offset,
    atlas_band,
    source_curve,
):
    vertices = []
    for point in points:
        bottom = Vector((point.x, point.y, point.z + z_offset))
        top = bottom + Vector((0.0, 0.0, height))
        vertices.extend((bottom, top))
    faces = []
    for index in range(len(points) - 1):
        bottom_a = index * 2
        top_a = bottom_a + 1
        bottom_b = bottom_a + 2
        top_b = bottom_a + 3
        faces.append((bottom_a, bottom_b, top_b, top_a))
    mesh = bpy.data.meshes.new(f"{name}_Mesh")
    mesh.from_pydata(vertices, [], faces)
    mesh.update()
    uv_layer = mesh.uv_layers.new(name="UVMap")
    v_min, v_max = ATLAS_BANDS[atlas_band]
    station_denominator = max(len(points) - 1, 1)
    for polygon in mesh.polygons:
        for loop_index in polygon.loop_indices:
            vertex_index = mesh.loops[loop_index].vertex_index
            station_index = vertex_index // 2
            factor = station_index / float(station_denominator)
            u = ATLAS_U_MIN + (ATLAS_U_MAX - ATLAS_U_MIN) * factor
            v = v_min if vertex_index % 2 == 0 else v_max
            uv_layer.data[loop_index].uv = (u, v)
    obj = bpy.data.objects.new(name, mesh)
    collection.objects.link(obj)
    mesh.materials.append(material)
    obj["palm_impostor_generated"] = True
    obj["source_curve"] = source_curve.name
    obj["atlas_band"] = atlas_band + 1
    obj["panel_count"] = len(points) - 1
    return obj


def _selected_or_collection_curves(context):
    selected = [obj for obj in context.selected_objects if obj.type == "CURVE"]
    if selected:
        return sorted(selected, key=lambda obj: obj.name)
    collection = bpy.data.collections.get(SOURCE_COLLECTION_NAME)
    if collection is None:
        return []
    return sorted(
        [obj for obj in collection.all_objects if obj.type == "CURVE"],
        key=lambda obj: obj.name,
    )


class PALM_OT_generate_impostor_ribbons(Operator):
    bl_idname = "object.generate_palm_impostor_ribbons"
    bl_label = "Generate From Curves"
    bl_description = "Rebuild connected palm billboard panels along selected curves"
    bl_options = {"REGISTER", "UNDO"}

    def execute(self, context):
        if context.mode != "OBJECT":
            bpy.ops.object.mode_set(mode="OBJECT")
        curves = _selected_or_collection_curves(context)
        if not curves:
            self.report(
                {"ERROR"},
                "Select Curve objects or place them in PALM_IMPOSTOR_CURVES",
            )
            return {"CANCELLED"}
        _clear_generated_objects()
        output_collection = _get_or_create_output_collection(context.scene)
        material = _get_or_create_material()
        spacing = context.scene.palm_ribbon_spacing
        chunk_length = context.scene.palm_ribbon_chunk_length
        maximum_segments = max(1, int(round(chunk_length / spacing)))
        generated_count = 0
        panel_count = 0
        for curve_index, curve in enumerate(curves):
            stable_name_seed = zlib.crc32(curve.name.encode("utf-8"))
            generator = random.Random(
                context.scene.palm_ribbon_random_seed + stable_name_seed
            )
            curve_polylines = _curve_polylines(curve, spacing)
            ribbon_index = 0
            for sampled_points in curve_polylines:
                for start in range(0, len(sampled_points) - 1, maximum_segments):
                    end = min(start + maximum_segments, len(sampled_points) - 1)
                    chunk_points = sampled_points[start : end + 1]
                    if len(chunk_points) < 2:
                        continue
                    height_factor = generator.uniform(
                        1.0 - context.scene.palm_ribbon_height_variation,
                        1.0 + context.scene.palm_ribbon_height_variation,
                    )
                    height = context.scene.palm_ribbon_height * height_factor
                    atlas_band = generator.randrange(len(ATLAS_BANDS))
                    ribbon_index += 1
                    name = (
                        f"SM_Palm_Impostor_{curve.name}_"
                        f"{ribbon_index:03d}_VIS"
                    )
                    _create_ribbon_mesh(
                        output_collection,
                        material,
                        name,
                        chunk_points,
                        height,
                        context.scene.palm_ribbon_z_offset,
                        atlas_band,
                        curve,
                    )
                    generated_count += 1
                    panel_count += len(chunk_points) - 1
        self.report(
            {"INFO"},
            f"Generated {generated_count} ribbons with {panel_count} panels",
        )
        return {"FINISHED"}


class PALM_OT_clear_impostor_ribbons(Operator):
    bl_idname = "object.clear_palm_impostor_ribbons"
    bl_label = "Clear Generated"
    bl_description = "Remove generated ribbon meshes without touching source curves"
    bl_options = {"REGISTER", "UNDO"}

    def execute(self, _context):
        removed = _clear_generated_objects()
        self.report({"INFO"}, f"Removed {removed} generated ribbon objects")
        return {"FINISHED"}


class PALM_PT_impostor_ribbons(Panel):
    bl_label = "Palm Ribbons"
    bl_idname = "PALM_PT_impostor_ribbons"
    bl_space_type = "VIEW_3D"
    bl_region_type = "UI"
    bl_category = "Palm Ribbons"

    def draw(self, context):
        layout = self.layout
        scene = context.scene
        layout.label(text="Island-style connected panels")
        layout.prop(scene, "palm_ribbon_spacing")
        layout.prop(scene, "palm_ribbon_chunk_length")
        layout.prop(scene, "palm_ribbon_height")
        layout.prop(scene, "palm_ribbon_height_variation")
        layout.prop(scene, "palm_ribbon_z_offset")
        layout.prop(scene, "palm_ribbon_random_seed")
        layout.separator()
        layout.operator(
            PALM_OT_generate_impostor_ribbons.bl_idname,
            icon="OUTLINER_OB_CURVE",
        )
        layout.operator(
            PALM_OT_clear_impostor_ribbons.bl_idname,
            icon="TRASH",
        )


CLASSES = (
    PALM_OT_generate_impostor_ribbons,
    PALM_OT_clear_impostor_ribbons,
    PALM_PT_impostor_ribbons,
)


def register():
    for cls in CLASSES:
        try:
            bpy.utils.unregister_class(cls)
        except (RuntimeError, ValueError):
            pass
        bpy.utils.register_class(cls)
    bpy.types.Scene.palm_ribbon_spacing = FloatProperty(
        name="Panel Spacing",
        description="Distance between connected vertical panel edges",
        default=2.75,
        min=0.5,
        max=20.0,
        unit="LENGTH",
    )
    bpy.types.Scene.palm_ribbon_chunk_length = FloatProperty(
        name="Atlas Repeat Length",
        description="Maximum ribbon length before the atlas starts again",
        default=120.0,
        min=10.0,
        max=500.0,
        unit="LENGTH",
    )
    bpy.types.Scene.palm_ribbon_height = FloatProperty(
        name="Height",
        default=42.0,
        min=1.0,
        max=150.0,
        unit="LENGTH",
    )
    bpy.types.Scene.palm_ribbon_height_variation = FloatProperty(
        name="Height Variation",
        subtype="FACTOR",
        default=0.18,
        min=0.0,
        max=0.75,
    )
    bpy.types.Scene.palm_ribbon_z_offset = FloatProperty(
        name="Ground Offset",
        default=0.08,
        min=-10.0,
        max=10.0,
        unit="LENGTH",
    )
    bpy.types.Scene.palm_ribbon_random_seed = IntProperty(
        name="Random Seed",
        default=4701,
        min=0,
    )


def unregister():
    for property_name in (
        "palm_ribbon_spacing",
        "palm_ribbon_chunk_length",
        "palm_ribbon_height",
        "palm_ribbon_height_variation",
        "palm_ribbon_z_offset",
        "palm_ribbon_random_seed",
    ):
        if hasattr(bpy.types.Scene, property_name):
            delattr(bpy.types.Scene, property_name)
    for cls in reversed(CLASSES):
        try:
            bpy.utils.unregister_class(cls)
        except (RuntimeError, ValueError):
            pass


if __name__ == "__main__":
    register()
