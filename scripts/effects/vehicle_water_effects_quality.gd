class_name VehicleWaterEffectsQuality
extends Resource

@export_group("Continuous Droplets")
@export_range(0, 512, 1) var bow_particles_per_side: int = 72
@export_range(0, 256, 1) var rail_particles_per_side: int = 28
@export_range(0, 512, 1) var jet_breakup_particles: int = 56
@export_range(1, 500, 1) var impact_maximum_particles: int = 140

@export_group("Wake")
@export_range(8, 256, 1) var wake_maximum_points: int = 96
@export_range(0.01, 0.25, 0.005, "suffix:s") var wake_mesh_update_interval: float = 0.05
@export_range(0.1, 2.0, 0.05, "suffix:m") var wake_sample_distance: float = 0.28

@export_group("Jet Stream")
@export_range(6, 64, 1) var jet_maximum_sections: int = 24
@export_range(2, 8, 1) var jet_cross_section_sides: int = 6

@export_group("Optics")
@export var refraction_enabled: bool = true

