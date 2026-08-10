class_name FallenRider3D
extends Node3D

const RETAINED_BONES: Array[StringName] = [&"mixamorig_Hips", &"mixamorig_Spine2", &"mixamorig_Head", &"mixamorig_LeftArm", &"mixamorig_LeftForeArm", &"mixamorig_RightArm", &"mixamorig_RightForeArm", &"mixamorig_LeftUpLeg", &"mixamorig_LeftLeg", &"mixamorig_LeftFoot", &"mixamorig_RightUpLeg", &"mixamorig_RightLeg", &"mixamorig_RightFoot"]

@onready var rider_rig: RiderRig = $RiderRig
@onready var simulator: PhysicalBoneSimulator3D = $RiderRig/RiderModelRoot/rider_bot/SKEL_Rider/Skeleton3D/PhysicalBoneSimulator3D

func _ready() -> void:
	for child in simulator.get_children():
		if child is PhysicalBone3D:
			var physical_bone := child as PhysicalBone3D
			var retained := RETAINED_BONES.has(StringName(physical_bone.bone_name))
			physical_bone.process_mode = Node.PROCESS_MODE_INHERIT if retained else Node.PROCESS_MODE_DISABLED
	prepare_dormant()

func set_rider_skin(value: RiderRig.RiderSkin) -> void:
	rider_rig.set_rider_skin(value)

func get_skeleton() -> Skeleton3D:
	return rider_rig.get_skeleton()

func get_physical_bone_simulator() -> PhysicalBoneSimulator3D:
	return simulator

func start_simulation() -> void:
	rider_rig.set_mounted_pose_enabled(false)
	visible = true
	simulator.physical_bones_start_simulation(RETAINED_BONES)

func stop_simulation() -> void:
	simulator.physical_bones_stop_simulation()
	prepare_dormant()

func prepare_dormant() -> void:
	visible = false
	if is_instance_valid(simulator):
		simulator.physical_bones_stop_simulation()
