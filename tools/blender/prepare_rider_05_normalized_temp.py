import bpy
import json
from pathlib import Path
from mathutils import Matrix, Vector

import sys
sys.path.insert(0, str(Path(__file__).resolve().parent))
import rider_bot_skinning_utils as shared

SOURCE = Path(r"C:\Users\ehort\Documents\GODOT PROJECTS\Water Race\source\riders\rider_05\rider_05.glb")
REFERENCE = Path(r"C:\Users\ehort\Documents\GODOT PROJECTS\Water Race\game\gameplay\riders\rider_bot\rider_bot.glb")
OUT_BLEND = Path(r"C:\Users\ehort\Documents\GODOT PROJECTS\Water Race\source\riders\rider_05\rider_05_compatible.blend")
OUT_GLB = Path(r"C:\Users\ehort\Documents\GODOT PROJECTS\Water Race\source\riders\rider_05\compatible\rider_05_compatible.glb")
REPORT = Path(r"C:\Users\ehort\Documents\GODOT PROJECTS\Water Race\source\riders\rider_05\rider_05_compatible_report.json")


def bounds(obj):
    points = [obj.matrix_world @ Vector(corner) for corner in obj.bound_box]
    low = Vector((min(p.x for p in points), min(p.y for p in points), min(p.z for p in points)))
    high = Vector((max(p.x for p in points), max(p.y for p in points), max(p.z for p in points)))
    return low, high


def imported(path):
    before = set(bpy.data.objects)
    shared.import_glb(path)
    objects = [obj for obj in bpy.data.objects if obj not in before]
    armature, meshes = shared.imported_character(objects)
    if len(meshes) != 1:
        raise RuntimeError(f'{path.name}: expected one skinned mesh, got {len(meshes)}')
    return armature, meshes[0], objects


bpy.ops.wm.read_factory_settings(use_empty=True)
source_arm, mesh, source_objects = imported(SOURCE)
source_arm.data.pose_position = 'REST'
source_stats = shared.weight_statistics(mesh, {bone.name for bone in source_arm.data.bones})
if source_stats['unweighted'] or source_stats['over_four'] or source_stats['invalid_groups']:
    raise RuntimeError(f'Invalid source weights: {source_stats}')

source_low, source_high = bounds(mesh)
source_size = source_high - source_low

target_arm, target_mesh, target_objects = imported(REFERENCE)
target_arm.data.pose_position = 'REST'
target_low, target_high = bounds(target_mesh)
target_size = target_high - target_low

# Preserve Rider 05's original proportions. Only normalize global height and
# floor/centre placement. Per-bone rest warping caused the previous distortion.
scale = target_size.z / source_size.z
world_vertices = [mesh.matrix_world @ vertex.co for vertex in mesh.data.vertices]
source_center_x = (source_low.x + source_high.x) * 0.5
source_center_y = (source_low.y + source_high.y) * 0.5
target_center_x = (target_low.x + target_high.x) * 0.5
target_center_y = (target_low.y + target_high.y) * 0.5
for vertex, world in zip(mesh.data.vertices, world_vertices):
    normalized = Vector((
        (world.x - source_center_x) * scale + target_center_x,
        (world.y - source_center_y) * scale + target_center_y,
        (world.z - source_low.z) * scale + target_low.z,
    ))
    vertex.co = normalized
mesh.data.update()
mesh.matrix_world = Matrix.Identity(4)

for modifier in list(mesh.modifiers):
    mesh.modifiers.remove(modifier)
shared.rebind_mesh(mesh, target_arm)

# Keep only the canonical armature and Rider 05 mesh.
for obj in list(bpy.data.objects):
    if obj not in {target_arm, mesh}:
        bpy.data.objects.remove(obj, do_unlink=True)
for action in list(bpy.data.actions):
    bpy.data.actions.remove(action)
for pose_bone in target_arm.pose.bones:
    pose_bone.custom_shape = None

target_arm.name = 'SKEL_Rider'
target_arm.data.name = 'SKEL_Rider'
target_arm.data.pose_position = 'REST'
mesh.name = 'rider_05_Body'
mesh.data.name = 'rider_05_Body_Data'

collection = bpy.data.collections.new('rider_05_RiderCompatible')
bpy.context.scene.collection.children.link(collection)
for obj in (target_arm, mesh):
    for current in list(obj.users_collection):
        current.objects.unlink(obj)
    collection.objects.link(obj)
for current in list(bpy.data.collections):
    if current != collection:
        bpy.data.collections.remove(current)

for image in bpy.data.images:
    if image.source not in {'VIEWER', 'GENERATED'} and image.packed_file is None and image.has_data:
        image.pack()

bpy.context.view_layer.update()
new_low, new_high = bounds(mesh)
rest_error = shared.rest_deformation_error(mesh)
if rest_error > 0.00001:
    raise RuntimeError(f'Rest deformation error: {rest_error}')

bpy.ops.wm.save_as_mainfile(filepath=str(OUT_BLEND), check_existing=False)
shared.export_glb(OUT_GLB, [target_arm, mesh])

result = {
    'status': 'PASS',
    'method': 'global_height_normalization_without_per_bone_warp',
    'source_bounds': {'min': list(source_low), 'max': list(source_high), 'size': list(source_size)},
    'target_bounds': {'min': list(target_low), 'max': list(target_high), 'size': list(target_size)},
    'normalization_scale': scale,
    'normalized_bounds': {'min': list(new_low), 'max': list(new_high), 'size': list(new_high-new_low)},
    'vertices': len(mesh.data.vertices),
    'triangles': shared.triangle_count(mesh),
    'bones': len(target_arm.data.bones),
    'weights': source_stats,
    'rest_deformation_error': rest_error,
}
REPORT.write_text(json.dumps(result, indent=2), encoding='utf-8')
print('RIDER_05_NORMALIZED=' + json.dumps(result))
