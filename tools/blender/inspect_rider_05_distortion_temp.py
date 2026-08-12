import bpy
import json
from pathlib import Path
from mathutils import Vector

SOURCE = Path(r"C:\Users\ehort\Documents\GODOT PROJECTS\Water Race\source\riders\rider_05\rider_05.glb")
REFERENCE = Path(r"C:\Users\ehort\Documents\GODOT PROJECTS\Water Race\game\gameplay\riders\rider_bot\rider_bot.glb")


def import_one(path):
    before = set(bpy.data.objects)
    bpy.ops.import_scene.gltf(filepath=str(path))
    objects = [obj for obj in bpy.data.objects if obj not in before]
    armatures = [obj for obj in objects if obj.type == 'ARMATURE']
    meshes = [obj for obj in objects if obj.type == 'MESH' and obj.vertex_groups]
    return armatures[0], meshes


def bounds(mesh):
    points = [mesh.matrix_world @ Vector(corner) for corner in mesh.bound_box]
    low = Vector((min(p.x for p in points), min(p.y for p in points), min(p.z for p in points)))
    high = Vector((max(p.x for p in points), max(p.y for p in points), max(p.z for p in points)))
    return {'min': list(low), 'max': list(high), 'size': list(high-low)}


def record(label, armature, meshes):
    bones = armature.data.bones
    key = {}
    for name in ('mixamorig:Hips','mixamorig:Head','mixamorig:LeftUpLeg','mixamorig:LeftLeg','mixamorig:LeftFoot','mixamorig:LeftArm','mixamorig:LeftForeArm','mixamorig:LeftHand'):
        bone = bones.get(name)
        if bone:
            head = armature.matrix_world @ bone.head_local
            tail = armature.matrix_world @ bone.tail_local
            key[name] = {'head': list(head), 'tail': list(tail), 'length': (tail-head).length, 'parent': bone.parent.name if bone.parent else None}
    return {
        'label': label,
        'armature_matrix': [list(row) for row in armature.matrix_world],
        'armature_scale': list(armature.scale),
        'bones': len(bones),
        'key_bones': key,
        'meshes': [{'name': mesh.name, 'bounds': bounds(mesh), 'scale': list(mesh.scale)} for mesh in meshes],
    }


bpy.ops.wm.read_factory_settings(use_empty=True)
src_arm, src_meshes = import_one(SOURCE)
ref_arm, ref_meshes = import_one(REFERENCE)
print('RIDER_COMPARE=' + json.dumps([record('source',src_arm,src_meshes), record('reference',ref_arm,ref_meshes)]))
