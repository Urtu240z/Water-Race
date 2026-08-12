import bpy
from pathlib import Path
from mathutils import Vector

ROOT = Path(r"C:\Users\ehort\Documents\GODOT PROJECTS\Water Race")
FILES = [
    ROOT / "source/riders/rider_05/compatible/rider_05_compatible.glb",
    ROOT / "game/gameplay/riders/rider_bot/rider_bot.glb",
]
OUT = ROOT / "source/riders/rider_05/rider_05_visual_compare.png"

bpy.ops.wm.read_factory_settings(use_empty=True)
characters = []
for index, path in enumerate(FILES):
    before = set(bpy.data.objects)
    bpy.ops.import_scene.gltf(filepath=str(path))
    imported = [obj for obj in bpy.data.objects if obj not in before]
    arm = next(obj for obj in imported if obj.type == 'ARMATURE')
    meshes = [obj for obj in imported if obj.type == 'MESH']
    arm.location.x = -1.2 if index == 0 else 1.2
    arm.data.pose_position = 'POSE'
    # Comparable athletic bend, deliberately exercising all visibly broken chains.
    rotations = {
        'mixamorig:Spine': (0.22, 0.0, 0.0),
        'mixamorig:Spine1': (0.12, 0.0, 0.0),
        'mixamorig:LeftUpLeg': (-0.48, 0.0, 0.06),
        'mixamorig:RightUpLeg': (-0.58, 0.0, -0.06),
        'mixamorig:LeftLeg': (0.78, 0.0, 0.0),
        'mixamorig:RightLeg': (0.86, 0.0, 0.0),
        'mixamorig:LeftArm': (0.25, 0.10, -0.55),
        'mixamorig:RightArm': (0.25, -0.10, 0.55),
        'mixamorig:LeftForeArm': (0.0, 0.0, -0.72),
        'mixamorig:RightForeArm': (0.0, 0.0, 0.72),
    }
    for name, euler in rotations.items():
        bone = arm.pose.bones.get(name)
        if bone:
            bone.rotation_mode = 'XYZ'
            bone.rotation_euler = euler
    characters.append((arm, meshes))

bpy.context.view_layer.update()

# Ground, camera and soft studio light.
bpy.ops.mesh.primitive_plane_add(size=10, location=(0, 0, 0))
ground = bpy.context.object
mat = bpy.data.materials.new('Ground')
mat.diffuse_color = (0.045, 0.055, 0.07, 1)
ground.data.materials.append(mat)

bpy.ops.object.camera_add(location=(4.8, -7.8, 3.0))
camera = bpy.context.object
direction = Vector((0.0, 0.0, 1.0)) - camera.location
camera.rotation_euler = direction.to_track_quat('-Z', 'Y').to_euler()
bpy.context.scene.camera = camera

for loc, energy, size in [((-4, -4, 6), 1300, 4.0), ((4, -1, 4), 900, 3.0)]:
    bpy.ops.object.light_add(type='AREA', location=loc)
    light = bpy.context.object
    light.data.energy = energy
    light.data.shape = 'DISK'
    light.data.size = size

scene = bpy.context.scene
scene.render.engine = 'BLENDER_EEVEE_NEXT'
scene.render.resolution_x = 1200
scene.render.resolution_y = 720
scene.render.resolution_percentage = 100
scene.render.image_settings.file_format = 'PNG'
scene.render.filepath = str(OUT)
scene.world = bpy.data.worlds.new('World')
scene.world.color = (0.12, 0.14, 0.18)
scene.render.film_transparent = False
bpy.ops.render.render(write_still=True)
print('COMPARE=' + str(OUT))
