class_name WaterSurfaceProvider3D
extends Node3D

const WaterSample3D = preload("res://world/water/query/water_sample_3d.gd")

## Minimal authoritative water-query contract.
##
## A provider returns one coherent surface position, normal, velocity, and
## geometric signed depth for an arbitrary world-space point. This supports
## both heightfield and non-heightfield water volumes.

func sample_water(_world_position: Vector3) -> WaterSample3D:
	push_error("WaterSurfaceProvider3D subclasses must implement sample_water().")
	return WaterSample3D.new()
