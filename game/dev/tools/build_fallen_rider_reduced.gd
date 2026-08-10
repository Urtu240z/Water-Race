@tool
extends EditorScript

const SEED_PATH := "res://gameplay/riders/common/fallen_rider_seed.tscn"
const OUTPUT_PATH := "res://gameplay/riders/common/fallen_rider_reduced_seed.tscn"

const SIMULATOR_PATH := NodePath(
	"RiderModelRoot/rider_bot/SKEL_Rider/Skeleton3D/PhysicalBoneSimulator3D"
)

# 13 cuerpos físicos reales.
const KEEP_BONES: Array[StringName] = [
	&"mixamorig_Hips",
	&"mixamorig_Spine2",
	&"mixamorig_Neck",

	&"mixamorig_LeftArm",
	&"mixamorig_LeftForeArm",
	&"mixamorig_RightArm",
	&"mixamorig_RightForeArm",

	&"mixamorig_LeftUpLeg",
	&"mixamorig_LeftLeg",
	&"mixamorig_LeftFoot",

	&"mixamorig_RightUpLeg",
	&"mixamorig_RightLeg",
	&"mixamorig_RightFoot",
]


# Total = 82 kg.
const BODY_MASSES := {
	&"mixamorig_Hips": 16.0,
	&"mixamorig_Spine2": 27.0,
	&"mixamorig_Neck": 5.0,

	&"mixamorig_LeftArm": 2.5,
	&"mixamorig_LeftForeArm": 1.5,
	&"mixamorig_RightArm": 2.5,
	&"mixamorig_RightForeArm": 1.5,

	&"mixamorig_LeftUpLeg": 8.0,
	&"mixamorig_LeftLeg": 4.0,
	&"mixamorig_LeftFoot": 1.0,

	&"mixamorig_RightUpLeg": 8.0,
	&"mixamorig_RightLeg": 4.0,
	&"mixamorig_RightFoot": 1.0,
}


# Vector2(radius, total_height), en metros.
#
# No tocamos transform/body_offset/joint_offset generados por Godot.
# Solo hacemos los colliders algo más humanos que los automáticos,
# que son extremadamente finos.
const CAPSULE_DIMENSIONS := {
	&"mixamorig_Hips": Vector2(0.14, 0.28),
	&"mixamorig_Spine2": Vector2(0.15, 0.34),
	&"mixamorig_Neck": Vector2(0.10, 0.22),

	&"mixamorig_LeftArm": Vector2(0.055, 0.28),
	&"mixamorig_LeftForeArm": Vector2(0.045, 0.285),
	&"mixamorig_RightArm": Vector2(0.055, 0.28),
	&"mixamorig_RightForeArm": Vector2(0.045, 0.285),

	&"mixamorig_LeftUpLeg": Vector2(0.085, 0.44),
	&"mixamorig_LeftLeg": Vector2(0.070, 0.445),
	&"mixamorig_LeftFoot": Vector2(0.060, 0.18),

	&"mixamorig_RightUpLeg": Vector2(0.085, 0.44),
	&"mixamorig_RightLeg": Vector2(0.070, 0.445),
	&"mixamorig_RightFoot": Vector2(0.060, 0.18),
}


func _run() -> void:
	print("")
	print("========================================")
	print(" BUILD FALLEN RIDER REDUCED RAGDOLL")
	print("========================================")

	var seed_resource := load(SEED_PATH) as PackedScene
	if seed_resource == null:
		push_error("Cannot load seed: %s" % SEED_PATH)
		return

	# Usamos estado de edición porque esto se ejecuta exclusivamente
	# dentro del editor.
	var rider_root := seed_resource.instantiate(
		PackedScene.GEN_EDIT_STATE_INSTANCE
	)

	if rider_root == null:
		push_error("Could not instantiate fallen rider seed.")
		return

	var simulator := rider_root.get_node_or_null(
		SIMULATOR_PATH
	) as PhysicalBoneSimulator3D

	if simulator == null:
		push_error(
			"PhysicalBoneSimulator3D not found at: %s"
			% SIMULATOR_PATH
		)
		rider_root.free()
		return

	var physical_bones := _collect_physical_bones(simulator)

	print("Seed physical bodies: %d" % physical_bones.size())

	if physical_bones.size() != 39:
		push_error(
			"Expected 39 PhysicalBone3D nodes in seed, found %d. "
			+ "Seed differs from the inspected version; aborting."
			% physical_bones.size()
		)
		rider_root.free()
		return

	if not _validate_required_bones(physical_bones):
		rider_root.free()
		return

	_prune_unused_bones(simulator, physical_bones)

	# Volvemos a recogerlos después de borrar.
	physical_bones = _collect_physical_bones(simulator)

	if physical_bones.size() != KEEP_BONES.size():
		push_error(
			"Pruning failed. Expected %d bodies, found %d."
			% [KEEP_BONES.size(), physical_bones.size()]
		)
		rider_root.free()
		return

	_configure_bodies(physical_bones)

	if not _validate_final_ragdoll(physical_bones):
		rider_root.free()
		return

	var packed := PackedScene.new()
	var pack_error := packed.pack(rider_root)

	if pack_error != OK:
		push_error(
			"PackedScene.pack failed with error: %s"
			% error_string(pack_error)
		)
		rider_root.free()
		return

	var save_error := ResourceSaver.save(
		packed,
		OUTPUT_PATH
	)

	if save_error != OK:
		push_error(
			"ResourceSaver.save failed with error: %s"
			% error_string(save_error)
		)
		rider_root.free()
		return

	print("")
	print("SUCCESS")
	print("Reduced ragdoll saved to:")
	print(OUTPUT_PATH)
	print("")
	print("Physical bodies: %d" % physical_bones.size())
	print("Total mass: %.2f kg" % _calculate_total_mass(physical_bones))

	for bone_name: StringName in KEEP_BONES:
		var pb := physical_bones[bone_name] as PhysicalBone3D
		print(
			"  %-28s mass=%5.1f kg  joint=%s"
			% [
				String(bone_name),
				pb.mass,
				_joint_type_name(pb.joint_type),
			]
		)

	print("========================================")
	print("")

	rider_root.free()


func _collect_physical_bones(
	simulator: PhysicalBoneSimulator3D
) -> Dictionary:
	var result := {}

	for child: Node in simulator.get_children():
		if child is not PhysicalBone3D:
			continue

		var physical_bone := child as PhysicalBone3D
		var bone_name := StringName(physical_bone.bone_name)

		if bone_name.is_empty():
			continue

		result[bone_name] = physical_bone

	return result


func _validate_required_bones(
	physical_bones: Dictionary
) -> bool:
	var valid := true

	for bone_name: StringName in KEEP_BONES:
		if not physical_bones.has(bone_name):
			push_error(
				"Required PhysicalBone3D missing: %s"
				% String(bone_name)
			)
			valid = false

	return valid


func _prune_unused_bones(
	simulator: PhysicalBoneSimulator3D,
	physical_bones: Dictionary
) -> void:
	var removed := 0

	# Hacemos primero la lista para no modificar mientras iteramos.
	var nodes_to_remove: Array[PhysicalBone3D] = []

	for bone_name_variant: Variant in physical_bones:
		var bone_name := StringName(bone_name_variant)

		if KEEP_BONES.has(bone_name):
			continue

		nodes_to_remove.append(
			physical_bones[bone_name] as PhysicalBone3D
		)

	for physical_bone: PhysicalBone3D in nodes_to_remove:
		print("Removing: %s" % physical_bone.bone_name)

		simulator.remove_child(physical_bone)
		physical_bone.free()
		removed += 1

	print("Removed physical bodies: %d" % removed)


func _configure_bodies(
	physical_bones: Dictionary
) -> void:
	for bone_name: StringName in KEEP_BONES:
		var pb := physical_bones[bone_name] as PhysicalBone3D

		# ------------------------------
		# MASS / BASIC PHYSICS
		# ------------------------------

		pb.mass = float(BODY_MASSES[bone_name])

		# Nada de pelotas de goma.
		pb.bounce = 0.0
		pb.friction = 0.65

		# Un poquito de damping ayuda a que cuando quede tirado
		# no esté temblando eternamente.
		pb.linear_damp = 0.05
		pb.angular_damp = 0.10
		pb.can_sleep = true

		# ------------------------------
		# COLLIDER
		# ------------------------------

		_configure_capsule(pb, bone_name)

		# ------------------------------
		# JOINT
		# ------------------------------

		_configure_joint(pb, bone_name)


func _configure_capsule(
	pb: PhysicalBone3D,
	bone_name: StringName
) -> void:
	var collision_shape: CollisionShape3D = null

	for child: Node in pb.get_children():
		if child is CollisionShape3D:
			collision_shape = child as CollisionShape3D
			break

	if collision_shape == null:
		push_error(
			"No CollisionShape3D under %s"
			% String(bone_name)
		)
		return

	var original_shape := collision_shape.shape

	if original_shape is not CapsuleShape3D:
		push_error(
			"Expected CapsuleShape3D for %s, got %s"
			% [
				String(bone_name),
				original_shape.get_class() if original_shape != null else "null",
			]
		)
		return

	# Duplica el recurso para garantizar que modificar este collider
	# no pueda tocar accidentalmente otro body.
	var capsule := original_shape.duplicate(true) as CapsuleShape3D

	var dimensions := CAPSULE_DIMENSIONS[bone_name] as Vector2

	capsule.radius = dimensions.x
	capsule.height = dimensions.y

	collision_shape.shape = capsule


func _configure_joint(
	pb: PhysicalBone3D,
	bone_name: StringName
) -> void:
	# Hips es la raíz física.
	if bone_name == &"mixamorig_Hips":
		pb.joint_type = PhysicalBone3D.JOINT_TYPE_NONE
		return

	match bone_name:
		# ----------------------------------
		# TORSO
		# ----------------------------------

		&"mixamorig_Spine2":
			_set_cone_joint(
				pb,
				25.0, # swing
				20.0  # twist
			)

		&"mixamorig_Neck":
			_set_cone_joint(
				pb,
				30.0,
				20.0
			)

		# ----------------------------------
		# SHOULDERS / UPPER ARMS
		# ----------------------------------

		&"mixamorig_LeftArm", \
		&"mixamorig_RightArm":
			_set_cone_joint(
				pb,
				60.0,
				45.0
			)

		# ----------------------------------
		# ELBOWS
		# ----------------------------------

		&"mixamorig_LeftForeArm", \
		&"mixamorig_RightForeArm":
			_set_hinge_joint(
				pb,
				-10.0,
				145.0
			)

		# ----------------------------------
		# HIPS / THIGHS
		# ----------------------------------

		&"mixamorig_LeftUpLeg", \
		&"mixamorig_RightUpLeg":
			_set_cone_joint(
				pb,
				55.0,
				35.0
			)

		# ----------------------------------
		# KNEES
		# ----------------------------------

		&"mixamorig_LeftLeg", \
		&"mixamorig_RightLeg":
			_set_hinge_joint(
				pb,
				-5.0,
				135.0
			)

		# ----------------------------------
		# ANKLES
		# ----------------------------------

		&"mixamorig_LeftFoot", \
		&"mixamorig_RightFoot":
			_set_cone_joint(
				pb,
				25.0,
				15.0
			)

		_:
			push_error(
				"No joint configuration for %s"
				% String(bone_name)
			)


func _set_cone_joint(
	pb: PhysicalBone3D,
	swing_degrees: float,
	twist_degrees: float
) -> void:
	pb.joint_type = PhysicalBone3D.JOINT_TYPE_CONE

	# Las propiedades dinámicas de PhysicalBone3D esperan grados
	# desde GDScript/Inspector y Godot los convierte internamente
	# a radianes.
	pb.set(
		"joint_constraints/swing_span",
		swing_degrees
	)
	pb.set(
		"joint_constraints/twist_span",
		twist_degrees
	)

	pb.set(
		"joint_constraints/bias",
		0.30
	)
	pb.set(
		"joint_constraints/softness",
		0.80
	)
	pb.set(
		"joint_constraints/relaxation",
		1.0
	)


func _set_hinge_joint(
	pb: PhysicalBone3D,
	lower_degrees: float,
	upper_degrees: float
) -> void:
	pb.joint_type = PhysicalBone3D.JOINT_TYPE_HINGE

	pb.set(
		"joint_constraints/angular_limit_enabled",
		true
	)
	pb.set(
		"joint_constraints/angular_limit_lower",
		lower_degrees
	)
	pb.set(
		"joint_constraints/angular_limit_upper",
		upper_degrees
	)

	pb.set(
		"joint_constraints/angular_limit_bias",
		0.30
	)
	pb.set(
		"joint_constraints/angular_limit_softness",
		0.90
	)
	pb.set(
		"joint_constraints/angular_limit_relaxation",
		1.0
	)


func _validate_final_ragdoll(
	physical_bones: Dictionary
) -> bool:
	if physical_bones.size() != 13:
		push_error(
			"Final ragdoll does not have exactly 13 PhysicalBone3D nodes."
		)
		return false

	var first_pb := physical_bones.values()[0] as PhysicalBone3D
	if first_pb == null:
		push_error("Could not resolve first PhysicalBone3D.")
		return false

	var simulator := first_pb.get_parent() as PhysicalBoneSimulator3D
	if simulator == null:
		push_error("Cannot resolve PhysicalBoneSimulator3D.")
		return false

	var skeleton := simulator.get_parent() as Skeleton3D
	if skeleton == null:
		push_error("Cannot resolve Skeleton3D.")
		return false

	var total_mass := 0.0

	for bone_name: StringName in KEEP_BONES:
		if not physical_bones.has(bone_name):
			push_error(
				"Final ragdoll missing: %s"
				% String(bone_name)
			)
			return false

		var pb := physical_bones[bone_name] as PhysicalBone3D

		if pb == null:
			push_error(
				"Invalid PhysicalBone3D for: %s"
				% String(bone_name)
			)
			return false

		# IMPORTANT:
		# We cannot use pb.get_bone_id() here because this scene is being
		# processed offline by EditorScript and has not entered the SceneTree.
		# Validate against the actual Skeleton3D bone names instead.
		if skeleton.find_bone(String(bone_name)) < 0:
			push_error(
				"Skeleton does not contain bone: %s"
				% String(bone_name)
			)
			return false

		if not is_finite(pb.mass) or pb.mass <= 0.0:
			push_error(
				"Invalid mass on %s"
				% String(bone_name)
			)
			return false

		if not pb.transform.is_finite():
			push_error(
				"Non-finite transform on %s"
				% String(bone_name)
			)
			return false

		if not pb.body_offset.is_finite():
			push_error(
				"Non-finite body_offset on %s"
				% String(bone_name)
			)
			return false

		if (
			pb.joint_type != PhysicalBone3D.JOINT_TYPE_NONE
			and not pb.joint_offset.is_finite()
		):
			push_error(
				"Non-finite joint_offset on %s"
				% String(bone_name)
			)
			return false

		var has_shape := false

		for child: Node in pb.get_children():
			if child is CollisionShape3D:
				var collision_shape := child as CollisionShape3D

				if collision_shape.shape != null:
					has_shape = true
					break

		if not has_shape:
			push_error(
				"No collider on %s"
				% String(bone_name)
			)
			return false

		total_mass += pb.mass

	if total_mass < 80.0 or total_mass > 85.0:
		push_error(
			"Total active ragdoll mass out of range: %.2f kg"
			% total_mass
		)
		return false

	print("Final validation OK.")
	print("Validated physical bodies: %d" % physical_bones.size())
	print("Validated total mass: %.2f kg" % total_mass)

	return true


func _calculate_total_mass(
	physical_bones: Dictionary
) -> float:
	var total := 0.0

	for bone_name: StringName in KEEP_BONES:
		total += (
			physical_bones[bone_name] as PhysicalBone3D
		).mass

	return total


func _joint_type_name(
	joint_type: PhysicalBone3D.JointType
) -> String:
	match joint_type:
		PhysicalBone3D.JOINT_TYPE_NONE:
			return "NONE"
		PhysicalBone3D.JOINT_TYPE_PIN:
			return "PIN"
		PhysicalBone3D.JOINT_TYPE_CONE:
			return "CONE"
		PhysicalBone3D.JOINT_TYPE_HINGE:
			return "HINGE"
		PhysicalBone3D.JOINT_TYPE_SLIDER:
			return "SLIDER"
		PhysicalBone3D.JOINT_TYPE_6DOF:
			return "6DOF"
		_:
			return "UNKNOWN"
