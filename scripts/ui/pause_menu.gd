extends CanvasLayer

@onready var _low_button: Button = %LowButton
@onready var _medium_button: Button = %MediumButton
@onready var _high_button: Button = %HighButton
@onready var _preset_label: Label = %PresetLabel
@onready var _applying_label: Label = %ApplyingLabel
@onready var _fps_label: Label = %FpsLabel
@onready var _continue_button: Button = %ContinueButton

var _quality_buttons: Dictionary = {}
var _last_toggle_frame: int = -1
var _applying_quality: bool = false
var _previous_mouse_mode: Input.MouseMode = Input.MOUSE_MODE_VISIBLE
var _fps_refresh_time: float = 0.0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_quality_buttons = {
		GraphicsQualityManager.Quality.LOW: _low_button,
		GraphicsQualityManager.Quality.MEDIUM: _medium_button,
		GraphicsQualityManager.Quality.HIGH: _high_button,
	}
	_low_button.pressed.connect(
		_on_quality_button_pressed.bind(GraphicsQualityManager.Quality.LOW)
	)
	_medium_button.pressed.connect(
		_on_quality_button_pressed.bind(GraphicsQualityManager.Quality.MEDIUM)
	)
	_high_button.pressed.connect(
		_on_quality_button_pressed.bind(GraphicsQualityManager.Quality.HIGH)
	)
	_continue_button.pressed.connect(_close_menu)
	GraphicsQualityManager.quality_changed.connect(_on_quality_changed)
	_fps_label.visible = OS.is_debug_build()
	_applying_label.visible = false
	visible = false
	_update_quality_display()


func _input(event: InputEvent) -> void:
	if not event.is_action_pressed(&"pause_menu"):
		return
	if event is InputEventKey and event.echo:
		return
	get_viewport().set_input_as_handled()
	var event_frame := Engine.get_process_frames()
	if event_frame == _last_toggle_frame or _applying_quality:
		return
	_last_toggle_frame = event_frame
	if visible:
		_close_menu()
	else:
		_open_menu()


func _process(delta: float) -> void:
	if not visible or not OS.is_debug_build():
		return
	_fps_refresh_time -= delta
	if _fps_refresh_time > 0.0:
		return
	_fps_refresh_time = 0.25
	_fps_label.text = "FPS actuales: %d" % Engine.get_frames_per_second()


func _exit_tree() -> void:
	if visible and get_tree() != null:
		get_tree().paused = false


func _open_menu() -> void:
	_previous_mouse_mode = Input.mouse_mode
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	visible = true
	get_tree().paused = true
	_applying_label.visible = false
	_fps_refresh_time = 0.0
	_update_quality_display()
	_get_current_quality_button().grab_focus()


func _close_menu() -> void:
	if not visible or _applying_quality:
		return
	visible = false
	get_tree().paused = false
	Input.mouse_mode = _previous_mouse_mode


func _on_quality_button_pressed(quality: int) -> void:
	if _applying_quality:
		return
	_applying_quality = true
	var focused_button := _quality_buttons.get(quality) as Button
	_set_quality_buttons_disabled(true)
	_continue_button.disabled = true
	_applying_label.text = "Aplicando…"
	_applying_label.visible = true
	await get_tree().process_frame
	GraphicsQualityManager.set_quality(quality, true)
	while GraphicsQualityManager.is_applying:
		await GraphicsQualityManager.graphics_quality_applied
	_update_quality_display()
	_applying_label.visible = false
	_set_quality_buttons_disabled(false)
	_continue_button.disabled = false
	_applying_quality = false
	if focused_button != null:
		focused_button.grab_focus()


func _on_quality_changed(_quality: int) -> void:
	if visible and not _applying_quality:
		_update_quality_display()


func _update_quality_display() -> void:
	var current_quality: int = GraphicsQualityManager.current_quality
	for quality: int in _quality_buttons:
		var button := _quality_buttons[quality] as Button
		if button != null:
			button.set_pressed_no_signal(quality == current_quality)
	_preset_label.text = (
		"Preset actual: %s · Escala 3D: %d%%"
		% [
			GraphicsQualityManager.get_quality_name(),
			roundi(GraphicsQualityManager.get_applied_3d_scale() * 100.0),
		]
	)


func _get_current_quality_button() -> Button:
	return (
		_quality_buttons.get(GraphicsQualityManager.current_quality, _medium_button)
		as Button
	)


func _set_quality_buttons_disabled(disabled: bool) -> void:
	for button_value: Variant in _quality_buttons.values():
		var button := button_value as Button
		if button != null:
			button.disabled = disabled
