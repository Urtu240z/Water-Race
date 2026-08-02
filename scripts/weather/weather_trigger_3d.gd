class_name WeatherTrigger3D
extends Area3D

@export_node_path("WeatherController3D") var weather_controller_path: NodePath
@export var one_shot: bool = true

var _triggered: bool = false
var _weather_controller: WeatherController3D


func _ready() -> void:
	_weather_controller = get_node_or_null(weather_controller_path) as WeatherController3D
	if _weather_controller == null:
		push_error("WeatherTrigger3D: WeatherController3D reference is missing.")
	body_entered.connect(_on_body_entered)


func _on_body_entered(body: Node3D) -> void:
	if _triggered or not body is JetSkiController:
		return
	if _weather_controller == null:
		return
	_weather_controller.start_storm_sequence()
	if one_shot:
		_triggered = true
		monitoring = false
