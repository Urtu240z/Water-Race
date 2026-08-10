class_name EventWaveProfile
extends Resource

@export_range(0.0, 50.0, 0.01, "suffix:m") var amplitude := 2.5
@export_range(0.01, 500.0, 0.01, "suffix:m") var width := 36.0
@export_range(-100.0, 100.0, 0.01, "suffix:m/s") var speed := 10.0
@export_range(0.0, 50.0, 0.01, "suffix:m") var trough_amplitude := 0.0
@export_range(0.01, 500.0, 0.01, "suffix:m") var trough_width := 36.0
@export_range(0.0, 500.0, 0.01, "suffix:m") var trough_offset := 0.0
@export_range(0.0, 20.0, 0.01, "suffix:m/s") var horizontal_flow := 1.5
@export_range(0.0, 30.0, 0.01, "suffix:s") var fade_in_time := 1.0
@export_range(0.0, 600.0, 0.01, "suffix:s") var lifetime := 30.0
@export_range(0.0, 30.0, 0.01, "suffix:s") var fade_out_time := 1.5
