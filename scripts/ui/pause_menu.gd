extends CanvasLayer

const RIDER_SETTINGS_PATH := "user://rider_settings.cfg"
const RIDER_SETTINGS_SECTION := "rider"
const RIDER_SETTINGS_KEY := "selected_id"

@onready var _low_button: Button = %LowButton
@onready var _medium_button: Button = %MediumButton
@onready var _high_button: Button = %HighButton
@onready var _preset_label: Label = %PresetLabel
@onready var _applying_label: Label = %ApplyingLabel
@onready var _fps_label: Label = %FpsLabel
@onready var _previous_rider_button: Button = %PreviousRiderButton
@onready var _rider_option_button: OptionButton = %RiderOptionButton
@onready var _next_rider_button: Button = %NextRiderButton
@onready var _rider_status_label: Label = %RiderStatusLabel
@onready var _continue_button: Button = %ContinueButton

var _quality_buttons: Dictionary = {}
var _rider_rig: RiderRig
var _rider_options: Array[Dictionary] = []
var _rider_settings_path: String = RIDER_SETTINGS_PATH
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
	_previous_rider_button.pressed.connect(_cycle_rider.bind(-1))
	_rider_option_button.item_selected.connect(_on_rider_selected)
	_next_rider_button.pressed.connect(_cycle_rider.bind(1))
	GraphicsQualityManager.quality_changed.connect(_on_quality_changed)
	_fps_label.visible = OS.is_debug_build()
	_applying_label.visible = false
	visible = false
	_update_quality_display()
	call_deferred("_initialize_rider_selector")


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
	_refresh_rider_selector()
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


func _initialize_rider_selector() -> void:
	_refresh_rider_selector(true)


func _refresh_rider_selector(restore_saved_selection: bool = false) -> void:
	_rider_rig = _find_rider_rig()
	_rider_options.clear()
	_rider_option_button.clear()
	if _rider_rig == null:
		_rider_option_button.add_item("No disponible")
		_set_rider_controls_disabled(true)
		_rider_status_label.text = "No se ha encontrado un rider seleccionable"
		return
	_rider_options = _rider_rig.get_available_rider_skin_options()
	if _rider_options.is_empty():
		_rider_option_button.add_item("No disponible")
		_set_rider_controls_disabled(true)
		_rider_status_label.text = "No hay riders disponibles"
		return
	var selected_value := int(_rider_rig.rider_skin)
	if restore_saved_selection:
		var saved_id := _load_saved_rider_id()
		var saved_value := RiderRig.find_rider_skin_by_id(
			saved_id,
			selected_value
		)
		if _rider_rig.is_rider_skin_available(saved_value):
			selected_value = saved_value
			_rider_rig.set_rider_skin(selected_value)
	var selected_index := -1
	for option_index: int in _rider_options.size():
		var option := _rider_options[option_index]
		var option_value := int(option["value"])
		_rider_option_button.add_item(String(option["display_name"]))
		_rider_option_button.set_item_metadata(option_index, option_value)
		if option_value == selected_value:
			selected_index = option_index
	if selected_index < 0:
		selected_index = 0
		selected_value = int(_rider_options[0]["value"])
		_rider_rig.set_rider_skin(selected_value)
	_rider_option_button.select(selected_index)
	_set_rider_controls_disabled(false)
	_update_rider_status(selected_index)


func _on_rider_selected(option_index: int) -> void:
	if (
		_rider_rig == null
		or option_index < 0
		or option_index >= _rider_options.size()
	):
		return
	var selected_value := int(
		_rider_option_button.get_item_metadata(option_index)
	)
	if not _rider_rig.is_rider_skin_available(selected_value):
		_refresh_rider_selector()
		return
	_rider_option_button.select(option_index)
	_rider_rig.set_rider_skin(selected_value)
	_save_rider_id(RiderRig.get_rider_skin_id(selected_value))
	_update_rider_status(option_index)


func _cycle_rider(direction: int) -> void:
	if _rider_options.size() <= 1:
		return
	var current_index := _rider_option_button.selected
	if current_index < 0 or current_index >= _rider_options.size():
		current_index = 0
	var next_index := wrapi(
		current_index + signi(direction),
		0,
		_rider_options.size()
	)
	_on_rider_selected(next_index)
	_rider_option_button.grab_focus()


func _find_rider_rig() -> RiderRig:
	if get_tree() == null:
		return null
	for node: Node in get_tree().get_nodes_in_group(&"rider_selectable"):
		if node is RiderRig and node.is_inside_tree():
			return node as RiderRig
	return null


func _load_saved_rider_id() -> StringName:
	var config := ConfigFile.new()
	if config.load(_rider_settings_path) != OK:
		return &""
	var stored_id: Variant = config.get_value(
		RIDER_SETTINGS_SECTION,
		RIDER_SETTINGS_KEY,
		""
	)
	if stored_id is not String and stored_id is not StringName:
		return &""
	return StringName(stored_id)


func _save_rider_id(skin_id: StringName) -> void:
	var config := ConfigFile.new()
	if FileAccess.file_exists(_rider_settings_path):
		config.load(_rider_settings_path)
	config.set_value(
		RIDER_SETTINGS_SECTION,
		RIDER_SETTINGS_KEY,
		String(skin_id)
	)
	var error := config.save(_rider_settings_path)
	if error != OK:
		push_warning(
			"PauseMenu could not save rider selection: %s."
			% error_string(error)
		)


func _update_rider_status(option_index: int) -> void:
	if option_index < 0 or option_index >= _rider_options.size():
		_rider_status_label.text = ""
		return
	_rider_status_label.text = (
		"Rider actual: %s · %d de %d"
		% [
			String(_rider_options[option_index]["display_name"]),
			option_index + 1,
			_rider_options.size(),
		]
	)


func _set_rider_controls_disabled(disabled: bool) -> void:
	_rider_option_button.disabled = disabled
	var cycle_disabled := disabled or _rider_options.size() <= 1
	_previous_rider_button.disabled = cycle_disabled
	_next_rider_button.disabled = cycle_disabled


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
