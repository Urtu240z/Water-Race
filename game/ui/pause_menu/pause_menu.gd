extends CanvasLayer

const RIDER_SETTINGS_PATH := "user://rider_settings.cfg"
const RIDER_SETTINGS_SECTION := "rider"
const RIDER_SETTINGS_KEY := "selected_id"
const AUDIO_SETTINGS_PATH := "user://audio_settings.cfg"
const AUDIO_SETTINGS_SECTION := "audio"
const AUDIO_SETTINGS_KEY := "master_volume_percent"
const MASTER_BUS_NAME := &"Master"
const MINIMUM_VOLUME_DB := -80.0
const LEVEL_OPTIONS: Array[Dictionary] = [
	{
		"display_name": "Island Test Blender",
		"scene_path": "res://levels/paradise_island/island_test_BLENDER.tscn",
	},
	{
		"display_name": "Night City",
		"scene_path": "res://levels/gold_city/night_city.tscn",
	},
]

@onready var _low_button: Button = %LowButton
@onready var _medium_button: Button = %MediumButton
@onready var _high_button: Button = %HighButton
@onready var _preset_label: Label = %PresetLabel
@onready var _applying_label: Label = %ApplyingLabel
@onready var _fps_label: Label = %FpsLabel
@onready var _volume_slider: HSlider = %VolumeSlider
@onready var _volume_value_label: Label = %VolumeValueLabel
@onready var _previous_rider_button: Button = %PreviousRiderButton
@onready var _rider_option_button: OptionButton = %RiderOptionButton
@onready var _next_rider_button: Button = %NextRiderButton
@onready var _rider_status_label: Label = %RiderStatusLabel
@onready var _previous_level_button: Button = %PreviousLevelButton
@onready var _level_option_button: OptionButton = %LevelOptionButton
@onready var _next_level_button: Button = %NextLevelButton
@onready var _load_level_button: Button = %LoadLevelButton
@onready var _continue_button: Button = %ContinueButton

var _quality_buttons: Dictionary = {}
var _rider_rig: RiderRig
var _rider_options: Array[Dictionary] = []
var _rider_settings_path: String = RIDER_SETTINGS_PATH
var _audio_settings_path: String = AUDIO_SETTINGS_PATH
var _last_toggle_frame: int = -1
var _applying_quality: bool = false
var _changing_level: bool = false
var _previous_mouse_mode: Input.MouseMode = Input.MOUSE_MODE_VISIBLE
var _fps_refresh_time: float = 0.0
var _master_bus_index: int = -1
var _volume_dirty: bool = false


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
	_volume_slider.value_changed.connect(_on_volume_changed)
	_previous_rider_button.pressed.connect(_cycle_rider.bind(-1))
	_rider_option_button.item_selected.connect(_on_rider_selected)
	_next_rider_button.pressed.connect(_cycle_rider.bind(1))
	_previous_level_button.pressed.connect(_cycle_level.bind(-1))
	_level_option_button.item_selected.connect(_on_level_selected)
	_next_level_button.pressed.connect(_cycle_level.bind(1))
	_load_level_button.pressed.connect(_on_load_level_pressed)
	GraphicsQualityManager.quality_changed.connect(_on_quality_changed)
	_fps_label.visible = OS.is_debug_build()
	_applying_label.visible = false
	visible = false
	_initialize_volume_control()
	_refresh_level_selector()
	_update_quality_display()
	call_deferred("_initialize_rider_selector")


func _input(event: InputEvent) -> void:
	if not event.is_action_pressed(&"pause_menu"):
		return
	if event is InputEventKey and event.echo:
		return
	get_viewport().set_input_as_handled()
	var event_frame := Engine.get_process_frames()
	if event_frame == _last_toggle_frame or _applying_quality or _changing_level:
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
	_save_volume_if_needed()
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
	_refresh_level_selector()
	_get_current_quality_button().grab_focus()


func _close_menu() -> void:
	if not visible or _applying_quality or _changing_level:
		return
	_save_volume_if_needed()
	visible = false
	get_tree().paused = false
	Input.mouse_mode = _previous_mouse_mode


func _initialize_volume_control() -> void:
	_master_bus_index = AudioServer.get_bus_index(MASTER_BUS_NAME)
	if _master_bus_index < 0:
		_volume_slider.editable = false
		_volume_value_label.text = "No disponible"
		push_warning("PauseMenu could not find the Master audio bus.")
		return
	var current_percent := 100.0
	if AudioServer.is_bus_mute(_master_bus_index):
		current_percent = 0.0
	else:
		current_percent = clampf(
			db_to_linear(AudioServer.get_bus_volume_db(_master_bus_index)) * 100.0,
			0.0,
			100.0
		)
	var saved_percent := _load_saved_volume_percent(current_percent)
	_volume_slider.set_value_no_signal(saved_percent)
	_apply_master_volume(saved_percent)
	_update_volume_label(saved_percent)
	_volume_dirty = false


func _on_volume_changed(value: float) -> void:
	if _master_bus_index < 0:
		return
	_apply_master_volume(value)
	_update_volume_label(value)
	_volume_dirty = true


func _apply_master_volume(volume_percent: float) -> void:
	var clamped_percent := clampf(volume_percent, 0.0, 100.0)
	var muted := is_zero_approx(clamped_percent)
	AudioServer.set_bus_mute(_master_bus_index, muted)
	AudioServer.set_bus_volume_db(
		_master_bus_index,
		MINIMUM_VOLUME_DB
		if muted
		else linear_to_db(clamped_percent / 100.0)
	)


func _update_volume_label(volume_percent: float) -> void:
	_volume_value_label.text = "%d%%" % roundi(volume_percent)


func _load_saved_volume_percent(fallback: float) -> float:
	var config := ConfigFile.new()
	if config.load(_audio_settings_path) != OK:
		return fallback
	var stored_value: Variant = config.get_value(
		AUDIO_SETTINGS_SECTION,
		AUDIO_SETTINGS_KEY,
		fallback
	)
	if stored_value is not int and stored_value is not float:
		return fallback
	return clampf(float(stored_value), 0.0, 100.0)


func _save_volume_if_needed() -> void:
	if not _volume_dirty or _master_bus_index < 0:
		return
	var config := ConfigFile.new()
	if FileAccess.file_exists(_audio_settings_path):
		config.load(_audio_settings_path)
	config.set_value(
		AUDIO_SETTINGS_SECTION,
		AUDIO_SETTINGS_KEY,
		clampf(_volume_slider.value, 0.0, 100.0)
	)
	var error := config.save(_audio_settings_path)
	if error != OK:
		push_warning(
			"PauseMenu could not save master volume: %s."
			% error_string(error)
		)
		return
	_volume_dirty = false


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


func _refresh_level_selector() -> void:
	var current_path := _get_current_level_path()
	var previous_selection_path := _get_selected_level_path()
	_level_option_button.clear()
	var selected_index := -1
	for option_index: int in LEVEL_OPTIONS.size():
		var option := LEVEL_OPTIONS[option_index]
		var scene_path := String(option["scene_path"])
		_level_option_button.add_item(String(option["display_name"]))
		_level_option_button.set_item_metadata(option_index, scene_path)
		if scene_path == current_path:
			selected_index = option_index
		elif selected_index < 0 and scene_path == previous_selection_path:
			selected_index = option_index
	if selected_index < 0 and not LEVEL_OPTIONS.is_empty():
		selected_index = 0
	if selected_index >= 0:
		_level_option_button.select(selected_index)
	_set_level_controls_disabled(LEVEL_OPTIONS.is_empty())
	_update_level_load_button()


func _on_level_selected(option_index: int) -> void:
	if option_index < 0 or option_index >= LEVEL_OPTIONS.size():
		return
	_level_option_button.select(option_index)
	_update_level_load_button()


func _cycle_level(direction: int) -> void:
	if _changing_level or LEVEL_OPTIONS.size() <= 1:
		return
	var current_index := _level_option_button.selected
	if current_index < 0 or current_index >= LEVEL_OPTIONS.size():
		current_index = 0
	var next_index := wrapi(
		current_index + signi(direction),
		0,
		LEVEL_OPTIONS.size()
	)
	_on_level_selected(next_index)
	_level_option_button.grab_focus()


func _on_load_level_pressed() -> void:
	if _changing_level:
		return
	var scene_path := _get_selected_level_path()
	if scene_path.is_empty() or scene_path == _get_current_level_path():
		return
	if not ResourceLoader.exists(scene_path, "PackedScene"):
		_applying_label.text = "No se ha encontrado el nivel"
		_applying_label.visible = true
		push_warning("PauseMenu could not find level scene: %s." % scene_path)
		return
	_changing_level = true
	_save_volume_if_needed()
	_set_level_controls_disabled(true)
	_set_quality_buttons_disabled(true)
	_set_rider_controls_disabled(true)
	_volume_slider.editable = false
	_continue_button.disabled = true
	_applying_label.text = "Cargando nivel…"
	_applying_label.visible = true
	await get_tree().process_frame
	get_tree().paused = false
	visible = false
	Input.mouse_mode = _previous_mouse_mode
	var error := get_tree().change_scene_to_file(scene_path)
	if error == OK:
		return
	_changing_level = false
	visible = true
	get_tree().paused = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_set_level_controls_disabled(false)
	_set_quality_buttons_disabled(false)
	_set_rider_controls_disabled(false)
	_volume_slider.editable = _master_bus_index >= 0
	_continue_button.disabled = false
	_applying_label.text = "No se pudo cargar el nivel"
	push_warning(
		"PauseMenu could not change level to %s: %s."
		% [scene_path, error_string(error)]
	)


func _get_current_level_path() -> String:
	if get_tree() == null or get_tree().current_scene == null:
		return ""
	return get_tree().current_scene.scene_file_path


func _get_selected_level_path() -> String:
	var selected_index := _level_option_button.selected
	if selected_index < 0 or selected_index >= _level_option_button.item_count:
		return ""
	var metadata: Variant = _level_option_button.get_item_metadata(selected_index)
	return String(metadata) if metadata != null else ""


func _update_level_load_button() -> void:
	var selected_path := _get_selected_level_path()
	var is_current := (
		selected_path.is_empty() or selected_path == _get_current_level_path()
	)
	_load_level_button.disabled = is_current or _changing_level
	_load_level_button.text = "ACTUAL" if is_current else "CARGAR"


func _set_level_controls_disabled(disabled: bool) -> void:
	_level_option_button.disabled = disabled
	var cycle_disabled := disabled or LEVEL_OPTIONS.size() <= 1
	_previous_level_button.disabled = cycle_disabled
	_next_level_button.disabled = cycle_disabled
	if disabled:
		_load_level_button.disabled = true
	else:
		_update_level_load_button()


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
