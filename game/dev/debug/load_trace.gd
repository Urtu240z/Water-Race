extends Node

var _start_usec: int
var _last_usec: int
var _file: FileAccess
var _lines: PackedStringArray = PackedStringArray()

func _enter_tree() -> void:
	_start_usec = Time.get_ticks_usec()
	_last_usec = _start_usec

	var log_path := "C:/Users/ehort/Documents/GODOT PROJECTS/Water Race/debug/load_trace.log"

	DirAccess.make_dir_recursive_absolute(
		log_path.get_base_dir()
	)

	_file = FileAccess.open(
		log_path,
		FileAccess.WRITE
	)

	section("WATER RACE LOAD TRACE")
	mark("GAME START")


func mark(label: String) -> void:
	var now := Time.get_ticks_usec()

	var total_ms := float(now - _start_usec) / 1000.0
	var delta_ms := float(now - _last_usec) / 1000.0

	var text := "[%9.3f ms] %-35s +%8.3f ms" % [
		total_ms,
		label,
		delta_ms
	]

	print(text)

	if _file:
		_lines.append(text)

	_last_usec = now


func section(title: String) -> void:
	var text := "\n========== %s ==========" % title

	print(text)

	if _file:
		_flush_lines()
		_file.store_line(text)
		_file.flush()


func memory(label: String = "MEMORY") -> void:
	var ram_bytes := Performance.get_monitor(
		Performance.MEMORY_STATIC
	)

	var ram_mb := ram_bytes / (1024.0 * 1024.0)

	mark("%s | RAM %.1f MB" % [label, ram_mb])


func flush() -> void:
	_flush_lines()


func _flush_lines() -> void:
	if _file == null or _lines.is_empty():
		return
	for line: String in _lines:
		_file.store_line(line)
	_lines.clear()
	_file.flush()


func _exit_tree() -> void:
	_flush_lines()
