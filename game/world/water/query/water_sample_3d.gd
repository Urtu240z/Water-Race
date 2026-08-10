class_name WaterSample3D
extends RefCounted

## Coherent result of querying a water provider at a world-space point.
##
## signed_depth is geometric: positive means the queried point is inside
## water, zero is on its surface, and negative is outside water. Providers
## must not assume this is a vertical distance unless their geometry is a
## heightfield.

var valid: bool = false
var surface_position: Vector3 = Vector3.ZERO
var normal: Vector3 = Vector3.UP
var velocity: Vector3 = Vector3.ZERO
var signed_depth: float = 0.0
var provider: Node
