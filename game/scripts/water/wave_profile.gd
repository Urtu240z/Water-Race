@tool
class_name WaveProfile
extends Resource

const WAVE_COUNT: int = 4

@export_group("Fixed Wave Slots")
@export var wave_1: WaveComponent
@export var wave_2: WaveComponent
@export var wave_3: WaveComponent
@export var wave_4: WaveComponent


func get_waves() -> Array[WaveComponent]:
	var waves: Array[WaveComponent] = [wave_1, wave_2, wave_3, wave_4]
	return waves
