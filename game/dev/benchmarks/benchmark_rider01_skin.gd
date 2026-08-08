extends SceneTree

const MAIN_SCENE := \
	"res://levels/paradise_island/island_test_BLENDER.tscn"
const REPORT_PATH := \
	"user://rider_01_performance_report.txt"
const WARMUP_FRAMES := 90
const SAMPLE_FRAMES := 180

var _report: PackedStringArray = []
var _failed := false


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
	DisplayServer.window_set_size(Vector2i(960, 540))
	var packed := load(MAIN_SCENE) as PackedScene
	if packed == null:
		_finish_with_error("Could not load the main island scene.")
		return
	var island := packed.instantiate()
	root.add_child(island)
	var rider_rig := _find_named(island, &"RiderRig")
	if rider_rig == null or not rider_rig.has_method("set_rider_skin"):
		_finish_with_error("The main scene has no usable RiderRig.")
		return

	_report.append("=== RIDER01 BASIC FORWARD+ PERFORMANCE SAMPLE ===")
	_report.append("Godot: %s" % Engine.get_version_info().string)
	_report.append("Window: 960x540, main scene, %d measured frames/skin." % SAMPLE_FRAMES)
	await _wait_frames(WARMUP_FRAMES)

	# Prewarm both material families before recording either result.
	rider_rig.call("set_rider_skin", 0)
	await _wait_frames(WARMUP_FRAMES)
	rider_rig.call("set_rider_skin", 2)
	await _wait_frames(WARMUP_FRAMES)

	rider_rig.call("set_rider_skin", 0)
	await _wait_frames(30)
	var bot := await _sample_frames()
	rider_rig.call("set_rider_skin", 2)
	await _wait_frames(30)
	var rider01 := await _sample_frames()

	_report.append("BOT: %s" % bot)
	_report.append("RIDER01: %s" % rider01)
	_report.append(
		"Measured FPS difference RIDER01-BOT: %.2f FPS (%.2f%%)."
		% [
			rider01.measured_fps - bot.measured_fps,
			_percent_delta(
				rider01.measured_fps,
				bot.measured_fps
			),
		]
	)
	_report.append(
		"Average frame-time difference RIDER01-BOT: %.3f ms."
		% (
			rider01.average_frame_ms
			- bot.average_frame_ms
		)
	)
	_report.append(
		"Note: this is a short same-session sample, not a full benchmark; "
		+ "scene simulation and driver scheduling remain active."
	)
	_report.append("PERFORMANCE_SAMPLE_STATUS=PASS")
	_write_report()
	print("\n".join(_report))
	island.queue_free()
	await process_frame
	quit(0)


func _sample_frames() -> Dictionary:
	var start_usec := Time.get_ticks_usec()
	var fps_sum := 0.0
	var process_sum := 0.0
	var physics_sum := 0.0
	var draw_sum := 0.0
	var primitives_sum := 0.0
	for _frame: int in SAMPLE_FRAMES:
		await process_frame
		fps_sum += Performance.get_monitor(Performance.TIME_FPS)
		process_sum += Performance.get_monitor(Performance.TIME_PROCESS)
		physics_sum += Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS)
		draw_sum += Performance.get_monitor(
			Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME
		)
		primitives_sum += Performance.get_monitor(
			Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME
		)
	var elapsed_seconds := maxf(
		0.000001,
		float(Time.get_ticks_usec() - start_usec) / 1000000.0
	)
	return {
		"measured_fps": float(SAMPLE_FRAMES) / elapsed_seconds,
		"average_frame_ms": elapsed_seconds * 1000.0 / float(SAMPLE_FRAMES),
		"monitor_fps": fps_sum / float(SAMPLE_FRAMES),
		"process_ms": process_sum * 1000.0 / float(SAMPLE_FRAMES),
		"physics_ms": physics_sum * 1000.0 / float(SAMPLE_FRAMES),
		"draw_calls": draw_sum / float(SAMPLE_FRAMES),
		"primitives": primitives_sum / float(SAMPLE_FRAMES),
	}


func _wait_frames(count: int) -> void:
	for _frame: int in count:
		await process_frame


func _percent_delta(value: float, baseline: float) -> float:
	if is_zero_approx(baseline):
		return 0.0
	return (value - baseline) * 100.0 / baseline


func _find_named(node: Node, target_name: StringName) -> Node:
	var pending: Array[Node] = [node]
	while not pending.is_empty():
		var current := pending.pop_back() as Node
		if current.name == target_name:
			return current
		for child: Node in current.get_children():
			pending.append(child)
	return null


func _finish_with_error(message: String) -> void:
	_failed = true
	_report.append("PERFORMANCE_SAMPLE_STATUS=FAIL")
	_report.append(message)
	_write_report()
	push_error(message)
	quit(1)


func _write_report() -> void:
	var file := FileAccess.open(REPORT_PATH, FileAccess.WRITE)
	if file != null:
		file.store_string("\n".join(_report) + "\n")
