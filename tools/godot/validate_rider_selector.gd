extends Node

@onready var _rider_rig: RiderRig = $RiderRig
@onready var _pause_menu: CanvasLayer = $PauseMenu

var _failures: PackedStringArray = []


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	call_deferred("_run")


func _run() -> void:
	await get_tree().process_frame
	await get_tree().process_frame

	var expected_options := RiderRig.get_rider_skin_options()
	var available_options := _rider_rig.get_available_rider_skin_options()
	_expect(
		available_options.size() == expected_options.size(),
		"All RiderRig skins must be available to the selector."
	)
	var option_button := _pause_menu.get_node(
		"%RiderOptionButton"
	) as OptionButton
	var previous_button := _pause_menu.get_node(
		"%PreviousRiderButton"
	) as Button
	var next_button := _pause_menu.get_node(
		"%NextRiderButton"
	) as Button
	_expect(option_button != null, "Pause menu must expose RiderOptionButton.")
	_expect(previous_button != null, "Pause menu must expose PreviousRiderButton.")
	_expect(next_button != null, "Pause menu must expose NextRiderButton.")
	if (
		option_button == null
		or previous_button == null
		or next_button == null
	):
		_finish()
		return
	_expect(
		option_button.item_count == available_options.size(),
		"Pause menu rider count must match RiderRig catalog."
	)
	if option_button.item_count != available_options.size():
		_finish()
		return

	var test_path := "res://.godot/codex_rider_selector_validation.cfg"
	var absolute_test_path := ProjectSettings.globalize_path(test_path)
	if FileAccess.file_exists(test_path):
		DirAccess.remove_absolute(absolute_test_path)
	_pause_menu.set("_rider_settings_path", test_path)
	var open_event := InputEventAction.new()
	open_event.action = &"pause_menu"
	open_event.pressed = true
	Input.parse_input_event(open_event)
	await get_tree().process_frame
	_expect(
		_pause_menu.visible and get_tree().paused,
		"Rider selector must remain interactive while the game is paused."
	)
	var panel := _pause_menu.get_node(
		"Overlay/CenterContainer/PanelContainer"
	) as Control
	var viewport_size := get_viewport().get_visible_rect().size
	_expect(
		panel != null
		and panel.size.x <= viewport_size.x
		and panel.size.y <= viewport_size.y,
		"Pause menu panel must fit inside the active viewport."
	)

	var initial_value := int(_rider_rig.rider_skin)
	var initial_index := 0
	for option_index: int in available_options.size():
		var option := available_options[option_index]
		var skin_value := int(option["value"])
		_expect(
			int(option_button.get_item_metadata(option_index)) == skin_value,
			"Selector metadata must match %s." % option["display_name"]
		)
		option_button.select(option_index)
		option_button.item_selected.emit(option_index)
		_expect(
			int(_rider_rig.rider_skin) == skin_value,
			"Pause menu must apply %s immediately." % option["display_name"]
		)
		_expect_selected_skin_visibility(skin_value, available_options)
		var config := ConfigFile.new()
		_expect(
			config.load(test_path) == OK
			and String(
				config.get_value("rider", "selected_id", "")
			) == String(option["id"]),
			"Pause menu must persist %s by stable id."
			% option["display_name"]
		)
		if skin_value == initial_value:
			initial_index = option_index
	if available_options.size() > 1:
		option_button.select(0)
		next_button.pressed.emit()
		_expect(
			option_button.selected == 1,
			"Next button must advance the rider selection."
		)
		previous_button.pressed.emit()
		_expect(
			option_button.selected == 0,
			"Previous button must return to the prior rider."
		)
	option_button.item_selected.emit(initial_index)
	_pause_menu.call("_initialize_rider_selector")
	_expect(
		int(_rider_rig.rider_skin) == initial_value,
		"Saved rider must be restored on selector initialization."
	)
	var close_event := InputEventAction.new()
	close_event.action = &"pause_menu"
	close_event.pressed = true
	Input.parse_input_event(close_event)
	await get_tree().process_frame
	_expect(
		not _pause_menu.visible and not get_tree().paused,
		"Pause menu must close normally after rider selection."
	)
	if FileAccess.file_exists(test_path):
		DirAccess.remove_absolute(absolute_test_path)
	_finish(available_options.size())


func _finish(discovered_count: int = 0) -> void:
	if _failures.is_empty():
		print(
			"RIDER SELECTOR VALIDATION PASS: %d riders discovered and applied."
			% discovered_count
		)
		get_tree().quit(0)
		return
	for failure: String in _failures:
		push_error(failure)
	get_tree().quit(1)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)


func _expect_selected_skin_visibility(
	selected_value: int,
	options: Array[Dictionary]
) -> void:
	for option: Dictionary in options:
		var skin_value := int(option["value"])
		if skin_value == RiderRig.RiderSkin.BOT:
			continue
		var skin_group := StringName(
			"rider_skin_%s" % String(option["id"]).to_lower()
		)
		var group_mesh_count := 0
		for node: Node in get_tree().get_nodes_in_group(skin_group):
			if (
				node is MeshInstance3D
				and _rider_rig.is_ancestor_of(node)
			):
				group_mesh_count += 1
				_expect(
					node.visible == (skin_value == selected_value),
					"%s mesh visibility must follow the selected rider."
					% option["display_name"]
				)
		_expect(
			group_mesh_count > 0,
			"%s must expose at least one selectable mesh."
			% option["display_name"]
		)
