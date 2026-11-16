extends SceneTree
## Real ZIP/document integration. Scene signals exercise controls and routing;
## this suite does not emulate a pointer device or native headset gestures.

const Document := preload("res://app/document.tscn")
const POINTS := {0: Vector3(0.625, 0.5, 0.5), 1: Vector3(0.875, 0.5, 0.5)}

var _checks := 0
var _failures := 0
var _directory := ""


func _initialize() -> void:
	_run.call_deferred()


func _check(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error("FAIL: " + message)


func _control(history: Node, unique_name: String) -> Node:
	return history.get_node("%" + unique_name)


func _settle() -> void:
	for index in 4:
		await process_frame


func _wait_idle(history: Node) -> void:
	var deadline := Time.get_ticks_msec() + 10000
	while history.is_busy() and Time.get_ticks_msec() < deadline:
		await create_timer(0.01).timeout
	_check(not history.is_busy(), "History worker completes and is joined within the test deadline")
	if history.is_busy():
		history.cancel_analysis()


func _glb() -> PackedByteArray:
	var binary := PackedByteArray()
	binary.resize(44)
	var coordinates := [0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0, 1.0]
	for index in coordinates.size():
		binary.encode_float(index * 4, coordinates[index])
	for index in 3:
		binary.encode_u16(36 + index * 2, index)
	var body := JSON.stringify({
		"asset": {"version": "2.0"}, "scene": 0, "scenes": [{"nodes": [0]}],
		"nodes": [{"mesh": 0}], "meshes": [{"primitives": [{"attributes": {"POSITION": 0}, "indices": 1}]}],
		"buffers": [{"byteLength": 42}],
		"bufferViews": [{"buffer": 0, "byteOffset": 0, "byteLength": 36, "target": 34962}, {"buffer": 0, "byteOffset": 36, "byteLength": 6, "target": 34963}],
		"accessors": [{"bufferView": 0, "componentType": 5126, "count": 3, "type": "VEC3", "min": [0, 0, 0], "max": [1, 1, 1]}, {"bufferView": 1, "componentType": 5123, "count": 3, "type": "SCALAR"}],
	}).to_utf8_buffer()
	while body.size() % 4:
		body.append(32)
	var header := PackedByteArray()
	header.resize(20)
	header.encode_u32(0, 0x46546c67)
	header.encode_u32(4, 2)
	header.encode_u32(8, 28 + body.size() + binary.size())
	header.encode_u32(12, body.size())
	header.encode_u32(16, 0x4e4f534a)
	var binary_header := PackedByteArray()
	binary_header.resize(8)
	binary_header.encode_u32(0, binary.size())
	binary_header.encode_u32(4, 0x004e4942)
	return header + body + binary_header + binary


func _fixture(path: String) -> void:
	var manifest := {
		"title": "Probe history integration", "frames": [{"time": 2}, {"time": 0}, {"time": 2}, {"time": 3}],
		"models": [{"name": "Model", "path": "model.glb"}],
		"fields": [
			{"name": "Pressure", "quantity": "Pressure", "unit": "Pa", "range": [-2, 2], "cells": [4, 1, 1], "box": {"origin": [0, 0, 0], "size": [1, 1, 1]}, "path": "pressure"},
			{"name": "Temperature", "quantity": "Temperature", "unit": "K", "range": [10, 30], "cells": [4, 1, 1], "box": {"origin": [100, 0, 0], "size": [8, 2, 3]}, "path": "temperature.bin"},
		],
	}
	var files := {
		"meta.json": JSON.stringify(manifest).to_utf8_buffer(), "model.glb": _glb(),
		"pressure/0001.bin": PackedByteArray([0, 1, 128, 255]),
		"pressure/0002.bin": PackedByteArray([255, 128, 0, 1]),
		"pressure/0003.bin": PackedByteArray([1, 255, 128, 0]),
		"pressure/0004.bin": PackedByteArray([0, 1, 255, 128]),
		"temperature.bin": PackedByteArray([1, 128, 255, 0]),
	}
	var zip := ZIPPacker.new()
	_check(zip.open(path) == OK, "Create disposable real ZIP fixture")
	for name in files:
		_check(zip.start_file(name) == OK and zip.write_file(files[name]) == OK and zip.close_file() == OK, "Write fixture entry " + name)
	_check(zip.close() == OK, "Finish ZIP central directory")


func _document(path: String) -> Node:
	var document := Document.instantiate()
	root.add_child(document)
	# Hold playback at the chosen frame while retaining the real playing flag.
	# Inspector processing and its worker thread remain enabled.
	document.set_process(false)
	_check(document.open(path).is_empty(), "Open actual document scene and ZIP metadata")
	document.touch.set_process(false)
	document.probes.set_process(false)
	document.show_probe_history()
	return document


func _place(history: Node, slot: int, x: int) -> void:
	_control(history, "CellX").value = x
	_control(history, "CellY").value = 0
	_control(history, "CellZ").value = 0
	_control(history, "SetA" if slot == 0 else "SetB").pressed.emit()


func _analyze(history: Node) -> void:
	_control(history, "Analyze").pressed.emit()
	_check(history.is_busy(), "Analyze signal launches a document worker")
	_check(_control(history, "Analyze").disabled and _control(history, "Export").disabled and not _control(history, "Cancel").disabled, "Busy state disables analysis/export and enables cancellation")
	await _wait_idle(history)
	_check(not history.result.is_empty() and history.result.error.is_empty(), "Worker result reaches the real inspector")


func _run() -> void:
	_directory = OS.get_temp_dir().path_join("wisualizer-history-document-%d" % Time.get_ticks_usec())
	_check(DirAccess.make_dir_recursive_absolute(_directory) == OK, "Create isolated fixture directory")
	var source := _directory.path_join("source.zip")
	_fixture(source)
	var document := _document(source)
	var history: Window = document.history
	await _settle()
	_check(history.visible and document.source_path == source, "Document opens its own history window with the original source path")
	_check(_control(history, "Analyze").disabled and _control(history, "SavePoints").disabled, "Empty points cannot be analyzed or saved")
	_check(_control(history, "CellX").max_value == 3 and _control(history, "CellY").max_value == 0, "Cell editors use the selected field's zero-based grid limits")
	_place(history, 0, 2)
	_place(history, 1, 3)
	_check(document.inspection.get_committed_points() == POINTS, "Set A/B signals place normalized cell centers in the document")
	_test_point_validation(document)
	_check(not document.probing and document.probes.inspection_points == POINTS and document.field.visible, "Desktop history shows the exact-cell pins without enabling hand gestures")
	_check(history.readout.text.contains("A: 0.0 Pa") and history.readout.text.contains("B: 2.0 Pa"), "Current-frame inspector readout preserves physical zero")
	_check(history.title == "Probe history integration – Probe history", "Inspection window identifies its source document")
	_check(history.readout.text.contains("B − A: 2.0 Pa"), "Inspector shows the exact signed difference for the current frame")
	var frame_before: int = document.frame
	var playing_before: bool = document.playing
	await _analyze(history)
	if history.result.is_empty():
		document.free()
		_finish()
		return
	_check(document.frame == frame_before and document.playing == playing_before, "Scanning history leaves playback position and play state unchanged")
	_check(history.result.rows.size() == 4 and history.timeline._frame_count == 4, "All archive frames reach the timeline")
	var rows: Array = history.result.rows
	_check(rows[0].a == 0.0 and rows[0].b == 2.0 and rows[0].delta == 2.0, "First history row retains physical zero and B minus A")
	_check(rows[1].a == null and rows[1].b == -2.0 and rows[1].delta == null and rows[2].b == null, "Missing data remains absent in integrated results")
	_check(rows[3].a == 2.0 and rows[3].b == 0.0 and rows[3].delta == -2.0, "Final row retains the opposite signed difference")
	_check(rows.map(func(row: Dictionary): return row.solver_time) == [2.0, 0.0, 2.0, 3.0], "Duplicate and backward solver times retain archive order")
	_check(history.result.cells[0] == Vector3i(2, 0, 0) and history.result.cells[1] == Vector3i(3, 0, 0), "Analyzed cells agree with placement and current-frame sampling")
	var result_before: Dictionary = history.result.duplicate(true)
	history.timeline.frame_selected.emit(2)
	_check(document.frame == 2 and not document.playing and history.timeline._frame == 2, "Timeline selection seeks the document, pauses playback, and updates its cursor")
	_check(history.result == result_before and document.inspection.get_committed_points() == POINTS, "Seeking retains the analyzed history and committed positions")
	_check(history.readout.text.contains("frame 3 / 4") and history.readout.text.contains("B: No data"), "Timeline seek refreshes the visible current-frame values")
	_check(history.readout.text.contains("B − A: place both probes on valid data"), "Missing current-frame data clears the previous numeric difference")
	document.seek(1)
	_check(history.timeline._frame == 1 and history.result == result_before, "Ordinary document seek updates only the timeline cursor")
	await _test_scroll(history)
	await _test_files(document)
	await _test_source_error(document, source)
	await _test_invalidation(document)
	await _test_isolation(document, source)
	document.close()
	await _settle()
	_check(not is_instance_valid(document), "Closing document releases inspector and joins its worker")
	_finish()


func _test_files(document: Node) -> void:
	var history: Window = document.history
	var csv := _directory.path_join("history.csv")
	history.export_to(csv)
	_check(history.is_busy(), "Export launches through the inspector")
	await _wait_idle(history)
	_check(FileAccess.file_exists(csv) and history.status.text.contains("Exported"), "Inspector writes a completed CSV")
	var csv_file := FileAccess.open(csv, FileAccess.READ)
	if csv_file != null:
		var columns := csv_file.get_csv_line()
		var records := []
		while csv_file.get_position() < csv_file.get_length():
			records.append(csv_file.get_csv_line())
		csv_file.close()
		_check(records.size() == 4 and columns.has("b_minus_a") and columns.has("source_identity"), "Export contains the complete plotted history and its source identity")
		_check(records[1][columns.find("a_value")] == "" and records[0][columns.find("a_value")].to_float() == 0.0, "CSV distinguishes missing samples from physical zero")
	var session := _directory.path_join("points.json")
	history.save_points(session)
	_check(FileAccess.file_exists(session) and history.status.text.contains("Saved"), "Inspector saves committed locations")
	var previous_radius: float = document._radius
	document.select_field(1)
	_check(document._radius > previous_radius * 10.0, "Selecting a distant field refits the desktop model while history is visible")
	for corner in 8:
		var point: Vector3 = document.meta.fields[1].box * Vector3(corner & 1, (corner >> 1) & 1, (corner >> 2) & 1)
		_check(point.distance_to(document._center) <= document._radius + 0.0001, "Selected field corner stays within the fitted model volume")
	_place(history, 0, 0)
	_check(history.result.is_empty() and history.readout.text.contains("Temperature"), "Field selection invalidates the previous history and switches readout metadata")
	history.load_points(session)
	_check(document.field_index == 0 and document.inspection.get_committed_points() == POINTS, "Loading points selects the saved field and atomically restores both positions: " + history.status.text)
	_check(history.result.is_empty() and history.timeline._frame_count == 0, "Session restoration requires fresh analysis rather than restoring readings")
	var selected_fields := []
	for button in document.get_node("Model/Options/Bar").get_children():
		if button.has_meta("field_index") and button.button_pressed:
			selected_fields.append(button.get_meta("field_index"))
	_check(selected_fields == [0], "Restored field updates the real field-picker button group")
	var invalid := _directory.path_join("invalid.json")
	var invalid_file := FileAccess.open(invalid, FileAccess.WRITE)
	invalid_file.store_string('{"version":999,"points":{}}')
	invalid_file.close()
	history.load_points(invalid)
	_check(document.field_index == 0 and document.inspection.get_committed_points() == POINTS and not history.status.text.contains("Restored"), "Invalid session leaves the displayed field and pins unchanged")
	await _analyze(history)
	var session_before := FileAccess.get_file_as_bytes(session)
	history.export_to(session.trim_suffix(".json") + ".csv")
	await _wait_idle(history)
	_check(FileAccess.get_file_as_bytes(session) == session_before, "History export leaves saved point locations intact")


func _test_invalidation(document: Node) -> void:
	var history: Window = document.history
	var committed: Dictionary = document.inspection.get_committed_points()
	var start: Vector3 = document.field.global_transform * Vector3(0.125, 0.5, 0.5)
	_check(document.inspection.begin(101, start, Vector3.ZERO, document.field.global_transform), "Begin controlled live candidate through the real probe state")
	_check(document.inspection.get_committed_points() == committed and document.inspection.get_points() != committed, "Candidate remains separate from committed history locations")
	_check(history.result.is_empty() and _control(history, "Analyze").disabled and _control(history, "SavePoints").disabled, "Starting movement invalidates results and blocks analyze/save")
	var live_session := _directory.path_join("live.json")
	history.analyze()
	history.save_points(live_session)
	_check(not history.is_busy() and not FileAccess.file_exists(live_session), "Programmatic analyze/save also refuse a live candidate")
	document.inspection.cancel()
	_check(document.inspection.get_committed_points() == committed and not _control(history, "Analyze").disabled, "Canceling movement restores committed locations and analysis availability")
	history.analyze()
	_control(history, "Cancel").pressed.emit()
	await _wait_idle(history)
	_check(history.result.is_empty() and history.timeline._frame_count == 0 and history.status.text.to_lower().contains("canceled"), "Cancel signal prevents a worker result from appearing")
	history.analyze()
	_place(history, 0, 1)
	await _wait_idle(history)
	_check(history.result.is_empty() and history.timeline._frame_count == 0, "A changed point invalidates an in-flight result even if the worker already completed")
	_check(document.inspection.get_committed_points()[0] == Vector3(0.375, 0.5, 0.5), "New placement survives stale worker completion")
	history.analyze()
	document.select_field(1)
	await _wait_idle(history)
	_check(history.result.is_empty() and document.inspection.get_committed_points().is_empty(), "Field switch drops old positions and prevents old-field result adoption")
	_place(history, 0, 0)
	history.analyze()
	_control(history, "Clear").pressed.emit()
	await _wait_idle(history)
	_check(document.inspection.get_committed_points().is_empty() and history.result.is_empty() and _control(history, "Analyze").disabled, "Clear signal cancels analysis and removes history together")
	document.select_field(0)
	document.inspection.set_points(POINTS)
	_test_cell_precision(document)
	await _analyze(history)
	history.ask_file("save")
	_place(history, 0, 1)
	history.file_dialog.file_selected.emit(_directory.path_join("stale-dialog.json"))
	_check(not FileAccess.file_exists(_directory.path_join("stale-dialog.json")), "A file-dialog selection from an older placement cannot save new positions")
	document.inspection.set_points(POINTS)


func _test_scroll(history: Window) -> void:
	var previous_size := history.size
	var previous_minimum := history.min_size
	var previous_scale := history.content_scale_factor
	var previous_status: String = history.status.text
	var scroll: ScrollContainer = history.get_node("Margin/Scroll")
	var help: Label = scroll.get_node("Column/Help")
	history.status.text = "Cannot read source. " + "The selected ZIP is unavailable. ".repeat(12)
	for scale in [1.0, 2.0]:
		history.content_scale_factor = scale
		history.min_size = Vector2i(Vector2(520, 560) * scale)
		history.size = history.min_size
		scroll.scroll_vertical = 0
		await _settle()
		var bounds: Rect2 = scroll.get_global_rect()
		_check(help.get_global_rect().position.y >= bounds.position.y - 1.0, "Minimum window retains the top instructions at scale %s" % scale)
		_check(scroll.get_v_scroll_bar().visible and scroll.get_node("Column").size.x <= scroll.size.x, "Overflow uses vertical scrolling without horizontal clipping at scale %s" % scale)
		scroll.scroll_vertical = int(scroll.get_v_scroll_bar().max_value)
		await _settle()
		_check(history.status.get_global_rect().position.y >= bounds.position.y - 1.0 and history.status.get_global_rect().end.y <= bounds.end.y + 1.0, "Scrolling reaches the complete status at scale %s" % scale)
	history.content_scale_factor = previous_scale
	history.min_size = previous_minimum
	history.size = previous_size
	history.status.text = previous_status
	scroll.scroll_vertical = 0
	await _settle()


func _test_source_error(document: Node, source: String) -> void:
	var history: Window = document.history
	var preserved: Dictionary = history.result.duplicate(true)
	history.export_to(_directory.path_join("missing-directory/history.csv"))
	await _wait_idle(history)
	_check(history.result == preserved and not _control(history, "Export").disabled and not history.status.text.contains("Exported"), "An output-path error retains valid analysis and allows export retry")
	var backup := source + ".backup"
	_check(DirAccess.rename_absolute(source, backup) == OK, "Temporarily remove the source path while its document is open")
	history.analyze()
	await _wait_idle(history)
	_check(history.result.is_empty() and history.timeline._frame_count == 0 and _control(history, "Export").disabled, "A terminal source error cannot leave old history values or an enabled export action")
	_check(_control(history, "Cancel").disabled and not history.progress.visible and not _control(history, "Analyze").disabled, "Failed worker leaves a settled, retryable control state")
	_check(document.inspection.get_committed_points() == POINTS and not history.status.text.is_empty(), "Source failure preserves positions and reports its error")
	_check(DirAccess.rename_absolute(backup, source) == OK, "Restore the unchanged fixture source")
	await _analyze(history)


func _test_point_validation(document: Node) -> void:
	var inspection: RefCounted = document.inspection
	var returned: Dictionary = inspection.get_committed_points()
	returned[0] = Vector3.ZERO
	_check(inspection.get_committed_points() == POINTS, "Reading committed positions returns an independent snapshot")
	for invalid in [{0: Vector3.ZERO, 2: Vector3.ONE * 0.5}, {0: Vector3(NAN, 0.5, 0.5)}, {0: Vector3.ONE}, {"0": Vector3.ZERO}]:
		_check(not inspection.set_points(invalid) and inspection.get_committed_points() == POINTS, "Invalid point restoration is atomic and preserves both pins")
	var restored: Dictionary = POINTS.duplicate()
	_check(inspection.set_points(restored), "Valid committed locations are accepted")
	restored.clear()
	_check(inspection.get_committed_points() == POINTS, "Restored locations are copied rather than shared with the caller")


func _test_cell_precision(document: Node) -> void:
	var history: Window = document.history
	var entry: RefCounted = document.meta.fields[0]
	var previous: Vector3i = entry.cells
	# A metadata-only stress case: no large allocation or fixture brick is needed.
	entry.cells = Vector3i(33554432, 1, 1)
	history.refresh()
	_place(history, 0, 16777217)
	_check(document.inspection.get_committed_points() == POINTS and history.status.text.contains("precision"), "An unrepresentable exact cell is rejected without silently moving a pin")
	entry.cells = previous
	history.refresh()


func _test_isolation(document: Node, source: String) -> void:
	var history: Window = document.history
	var second := _document(source)
	await _settle()
	_check(second.history != history and second.inspection != document.inspection, "Each document owns separate history and probe state")
	_place(second.history, 0, 1)
	history.analyze()
	second.history.analyze()
	_check(history.is_busy() and second.history.is_busy(), "Two documents can analyze independently")
	await _wait_idle(history)
	await _wait_idle(second.history)
	_check(history.result.points == POINTS and second.history.result.points == {0: Vector3(0.375, 0.5, 0.5)}, "Concurrent workers return each document's own point snapshot")
	_check(second.history.result.rows[0].a == -2.0 and second.history.result.rows[0].b == null, "Single-point document retains its own samples and absent B")
	second.history.timeline.frame_selected.emit(3)
	_check(second.frame == 3 and document.frame == 1, "Selecting a frame in one timeline does not seek another document")
	var preserved: Dictionary = history.result.duplicate(true)
	second.history.analyze()
	second.close()
	await _settle()
	_check(not is_instance_valid(second) and history.result == preserved, "Closing an analyzing document joins its task without altering another result")
	history.analyze()


func _finish() -> void:
	for file in DirAccess.get_files_at(_directory):
		DirAccess.remove_absolute(_directory.path_join(file))
	DirAccess.remove_absolute(_directory)
	print("Probe history document: %d checks, %d failures" % [_checks, _failures])
	quit(1 if _failures else 0)
