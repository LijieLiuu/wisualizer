extends SceneTree
## Run with the project's custom Godot build:
## godot --headless --path . --script res://tests/zip_workspace_test.gd -- --godot-dialogs
## Exercises the actual workspace scene, signals, dialogs and background saves.

const Workspace := preload("res://app/workspace.tscn")
const Draft := preload("res://app/draft.gd")

var _workspace: Window
var _root := ""
var _checks := 0
var _failures := 0
var _saved: Array[Dictionary] = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var temporary := OS.get_environment("TMPDIR")
	if temporary.is_empty():
		temporary = "/tmp"
	_root = temporary.path_join("wisualizer-workspace-tests-%d-%d" % [OS.get_process_id(), Time.get_ticks_usec()])
	_check(DirAccess.make_dir_recursive_absolute(_root) == OK, "Create isolated workspace fixture directory")
	root.gui_embed_subwindows = true
	_workspace = Workspace.instantiate()
	root.add_child(_workspace)
	if not _check(is_instance_valid(_workspace.get("draft")), "Workspace initializes its real draft script"):
		_workspace.queue_free()
		await process_frame
		quit(1)
		return
	_embed_for_headless(_workspace)
	_workspace.saved.connect(func(path: String, play: bool) -> void: _saved.append({path = path, play = play}))
	_check(_workspace.start(_root.path_join("original.zip")).is_empty(), "Instantiate and start the real workspace scene")
	for dialog: FileDialog in _workspace.find_children("*", "FileDialog", true, false):
		dialog.use_native_dialog = false
	await process_frame
	_test_files()
	await _test_notes()
	await _test_saves()
	await _test_statistics()
	_workspace.close()
	await process_frame
	print("ZIP workspace: %d checks, %d failures" % [_checks, _failures])
	if _failures == 0:
		_remove_tree(_root)
	else:
		print("Failure fixtures retained at: " + _root)
	quit(1 if _failures else 0)


func _embed_for_headless(window: Window) -> void:
	# The desktop layout autoload forces ordinary native windows. Embed only
	# this test's windows because the headless display cannot create them.
	window.force_native = false
	window.gui_embed_subwindows = true
	for child: Window in window.find_children("*", "Window", true, false):
		child.force_native = false


func _check(condition: bool, message: String) -> bool:
	_checks += 1
	if not condition:
		_failures += 1
		push_error("FAIL: " + message)
	return condition


func _write(relative: String, bytes: PackedByteArray) -> String:
	var path := _root.path_join(relative)
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var file := FileAccess.open(path, FileAccess.WRITE)
	if not _check(file != null, "Write fixture " + relative):
		return path
	file.store_buffer(bytes)
	file.close()
	return path


func _test_files() -> void:
	_workspace.get_node("Root/Sidebar/Column/FilesSection").pressed.emit()
	_check(_workspace.get_node("Root/Content/Pages/Files").visible, "Files sidebar opens its page")
	var vector := _write("source/velocity.vec", PackedByteArray([0, 255, 128, 42]))
	var text := _write("source/readme.txt", "Keep this source unchanged\n".to_utf8_buffer())
	_workspace.get_node("%AttachmentFiles").files_selected.emit(PackedStringArray([vector, text]))
	var list: ItemList = _workspace.get_node("%AttachmentList")
	_check(list.item_count == 2, "File picker signal adds both source files to the list")
	_check(list.get_item_text(0) == "attachments/velocity.vec" and list.get_item_text(1) == "attachments/readme.txt", "Files list shows the paths inside the ZIP")
	list.select(0)
	list.item_selected.emit(0)
	_check(_workspace.get_node("%AttachmentInfo").text.contains(vector), "Selecting a file shows its source")
	var before: Dictionary = _workspace.draft.attachments.duplicate()
	_workspace.get_node("%AttachmentFiles").files_selected.emit(PackedStringArray([vector]))
	_check(_workspace.draft.attachments == before and list.item_count == 2, "Duplicate import keeps the existing list")
	_check(not _workspace.get_node("%Status").text.is_empty(), "Duplicate import displays its error")
	_workspace.get_node("%RemoveAttachment").pressed.emit()
	_check(list.item_count == 1 and not _workspace.draft.attachments.has("attachments/velocity.vec"), "Remove button deletes only the selected attachment")
	_workspace.get_node("%AttachmentFiles").files_selected.emit(PackedStringArray([vector]))
	_check(list.item_count == 2, "Removed source file can be imported again")


func _test_notes() -> void:
	var notes := _write("notes/import.txt", "[b]First 速度[/b]\n".to_utf8_buffer())
	var choice: ConfirmationDialog = _workspace.get_node("%ImportNotesChoice")
	_workspace.get_node("%NotesFile").file_selected.emit(notes)
	_check(_workspace.draft.notes == "[b]First 速度[/b]\n", "Import TXT fills empty notes and preserves BBCode and Unicode")
	_check(_workspace.get_node("%Editor").text == _workspace.draft.notes, "TXT import updates the notes editor")
	_check(not choice.visible and _workspace.get_node("Root/Content/Pages/Notes").visible, "Empty notes import needs no replacement dialog and shows Notes")
	var original: String = _workspace.draft.notes
	_write("notes/import.txt", "Cancelled text".to_utf8_buffer())
	_workspace.get_node("%NotesFile").file_selected.emit(notes)
	_check(choice.visible and _workspace.draft.notes == original, "Existing notes stay unchanged while the choice is open")
	choice.get_cancel_button().pressed.emit()
	await process_frame
	_check(not choice.visible and _workspace.draft.notes == original, "Cancel button keeps the existing notes")
	choice.get_ok_button().pressed.emit()
	_check(_workspace.draft.notes == original, "A canceled import cannot be applied later")

	_write("notes/import.txt", "Append this original read".to_utf8_buffer())
	_workspace.get_node("%NotesFile").file_selected.emit(notes)
	_write("notes/import.txt", "Changed after dialog opened".to_utf8_buffer())
	var append_button: Button
	for button: Button in choice.find_children("*", "Button", true, false):
		if button.text == "Append":
			append_button = button
	if _check(append_button != null, "The import choice includes an Append button"):
		append_button.pressed.emit()
	_check(_workspace.draft.notes == original + "\n\nAppend this original read", "Append uses the pending first read, even if the file changed on disk")
	_check(not choice.visible, "Append dismisses the choice")

	_write("notes/import.txt", "[i]Replacement[/i]".to_utf8_buffer())
	_workspace.get_node("%NotesFile").file_selected.emit(notes)
	_write("notes/import.txt", "Do not read this again".to_utf8_buffer())
	choice.get_ok_button().pressed.emit()
	_check(_workspace.draft.notes == "[i]Replacement[/i]", "Replace button uses the pending first read")
	_check(_workspace.get_node("%NotesPreview").get_parsed_text() == "Replacement", "Imported BBCode is rendered by the real notes preview")
	var invalid := _write("notes/invalid.txt", PackedByteArray([0xFF, 0xFE, 0x41]))
	_workspace.get_node("%NotesFile").file_selected.emit(invalid)
	_check(_workspace.draft.notes == "[i]Replacement[/i]" and not choice.visible, "Invalid TXT leaves existing notes and the choice unchanged")
	_check(not _workspace.get_node("%Status").text.is_empty(), "Invalid TXT displays an error")
	var empty := _write("notes/empty.txt", PackedByteArray())
	_workspace.get_node("%NotesFile").file_selected.emit(empty)
	if append_button != null:
		append_button.pressed.emit()
	_check(_workspace.draft.notes == "[i]Replacement[/i]", "Appending an empty TXT does not add blank lines")
	_workspace.get_node("%NotesFile").file_selected.emit(empty)
	choice.get_ok_button().pressed.emit()
	_check(_workspace.draft.notes.is_empty() and _workspace.get_node("%Editor").text.is_empty(), "Replacing with an empty TXT clears notes intentionally")
	_write("notes/import.txt", "[i]Saved notes[/i]".to_utf8_buffer())
	_workspace.get_node("%NotesFile").file_selected.emit(notes)
	_check(_workspace.draft.notes == "[i]Saved notes[/i]", "Notes can be imported again after an empty replacement")


func _test_saves() -> void:
	var glb := _write("source/triangle.glb", _triangle_glb())
	_workspace.get_node("%GLBFiles").files_selected.emit(PackedStringArray([glb]))
	if not _check(_workspace.draft.models.size() == 1 and _workspace.draft.times.size() == 1, "Existing GLB picker creates a playable draft"):
		return
	var original_target: String = _workspace.target
	var original_notes: String = _workspace.draft.notes
	var original_title: String = _workspace.draft.title
	var attachments: Dictionary = _workspace.draft.attachments.duplicate()
	var pending := _write("notes/pending.txt", "Discard the pending import when saving".to_utf8_buffer())
	_workspace.get_node("%NotesFile").file_selected.emit(pending)
	_check(_workspace.get_node("%ImportNotesChoice").visible, "Set up a pending import before saving")
	_workspace.get_node("%Save").pressed.emit()
	_check(_workspace._busy and _workspace.gui_disable_input, "Background save blocks GUI mouse and keyboard input immediately")
	_check(not _workspace.get_node("%ImportNotesChoice").visible, "Starting a save dismisses an existing notes dialog")
	var editor: CodeEdit = _workspace.get_node("%Editor")
	editor.grab_focus()
	var key := InputEventKey.new()
	key.pressed = true
	key.keycode = KEY_X
	key.unicode = 120
	_workspace.push_input(key, true)
	_check(editor.text == original_notes, "Keyboard input cannot edit notes while the save is active")
	var import_button: Button = _workspace.get_node("Root/Content/Pages/Notes/ImportNotes")
	var click := InputEventMouseButton.new()
	click.button_index = MOUSE_BUTTON_LEFT
	click.pressed = true
	click.position = import_button.get_global_rect().get_center()
	_workspace.push_input(click, true)
	click.pressed = false
	_workspace.push_input(click, true)
	_check(not _workspace.get_node("%NotesFile").visible, "Mouse input cannot open the TXT picker during saving")
	_workspace.edit_title("Blocked title")
	_workspace.add_frame()
	_workspace.import_glbs(PackedStringArray([glb]))
	_workspace.import_files(PackedStringArray([pending]))
	_workspace.import_notes(pending)
	_workspace.remove_file()
	_workspace.apply_notes_import(false)
	_workspace.ask_import("AttachmentFiles")
	_workspace.save_as(_root.path_join("ignored-while-busy.zip"))
	_check(not _workspace.get_node("%AttachmentFiles").visible and _workspace.target == original_target, "Late import and Save As callbacks are ignored while busy")
	if not await _wait_save():
		return
	_check(not _workspace.gui_disable_input and not _workspace.get_node("%Save").disabled, "Save completion restores editing")
	_check(_workspace.draft.title == original_title and _workspace.draft.notes == original_notes, "Late editing and TXT callbacks cannot change a draft being saved")
	_check(_workspace.draft.models.size() == 1 and _workspace.draft.times.size() == 1 and _workspace.draft.attachments.keys() == attachments.keys(), "Late model, frame and file callbacks cannot mutate the save")
	_check(_saved.size() == 1 and _saved[0].path == original_target and not _saved[0].play, "Successful background save emits the correct target once")
	_check(_workspace.get_node("%Status").text == "Saved", "Successful save reports Saved")
	_check(_workspace.get_node("%AttachmentInfo").text.contains("Saved ZIP"), "File source details refresh after saving")
	_workspace.get_node("%ImportNotesChoice").get_ok_button().pressed.emit()
	_check(_workspace.draft.notes == original_notes, "Saving clears a dismissed pending notes import")

	# File dialogs are separate windows and must also close before writing.
	_workspace.ask_import("AttachmentFiles")
	_check(_workspace.get_node("%AttachmentFiles").visible, "The source picker can open after a completed save")
	_workspace.save()
	_check(_workspace._busy, "Second background save starts: " + _workspace.get_node("%Status").text)
	_check(not _workspace.get_node("%AttachmentFiles").visible, "Starting another save dismisses an already-open source picker")
	if not await _wait_save():
		return
	var original_bytes := FileAccess.get_file_as_bytes(original_target)
	var saves_before_failure := _saved.size()
	var invalid := _root.path_join("directory.zip")
	_check(DirAccess.make_dir_recursive_absolute(invalid) == OK, "Create a real invalid Save As destination")
	_workspace.get_node("%SaveAsFile").file_selected.emit(invalid)
	_check(_workspace.target == original_target, "Save As keeps the original target while its write is pending")
	if not await _wait_save():
		return
	_check(_workspace.target == original_target and _workspace.get_node("%File").text == original_target.get_file(), "Failed Save As preserves the original working target and label")
	_check(_saved.size() == saves_before_failure, "Failed Save As emits no saved signal")
	_check(_workspace.get_node("%Status").text != "Saved" and not _workspace.get_node("%Status").text.is_empty(), "Failed Save As reports its error")
	_check(not _workspace.gui_disable_input and FileAccess.get_file_as_bytes(original_target) == original_bytes, "Failed Save As restores input and keeps the prior ZIP intact")

	var copy := _root.path_join("copy.zip")
	_workspace.get_node("%SaveAsFile").file_selected.emit(copy)
	_check(_workspace.target == original_target, "Successful Save As also waits to change target")
	if not await _wait_save():
		return
	if not _check(_workspace.target == copy and _saved[-1].path == copy, "Successful Save As adopts the new target and reports it: " + _workspace.get_node("%Status").text):
		return
	var reopened: Window = Workspace.instantiate()
	root.add_child(reopened)
	_embed_for_headless(reopened)
	_check(reopened.start(copy).is_empty(), "The saved package reopens in a real workspace")
	_check(reopened.get_node("%AttachmentList").item_count == 2 and reopened.draft.notes == original_notes, "Reopening refreshes the Files list and imported notes")
	reopened.close()
	await process_frame


func _test_statistics() -> void:
	var button: Button = _workspace.get_node("%ExportStatistics")
	var dialog: FileDialog = _workspace.get_node("%StatisticsFile")
	button.pressed.emit()
	_check(not dialog.visible and not _workspace._busy, "Statistics export without fields does not open a save dialog")
	_check(_workspace.get_node("%Status").text.contains("scalar field"), "Statistics export explains the missing field")

	var source := _write("statistics/field-input.csv", PackedByteArray([1, 255]))
	var field := Draft.Field.new()
	field.name = "Unsaved scalar"
	field.quantity = "Speed"
	field.unit = "m/s"
	field.cells = Vector3i(2, 1, 1)
	field.range = Vector2(0.0, 254.0)
	field.origin = Vector3(10.0, 20.0, 30.0)
	field.size = Vector3(2.0, 3.0, 4.0)
	field.bricks[0] = source
	_workspace.draft.fields.append(field)
	_workspace.draft.times[0] = 7.5
	var extra_model := _write("statistics/extra-model.glb", _triangle_glb(1.0))
	_workspace.get_node("%GLBFiles").files_selected.emit(PackedStringArray([extra_model]))
	_check(field.origin == Vector3(10.0, 20.0, 30.0) and field.size == Vector3(2.0, 3.0, 4.0), "Importing a GLB preserves the field source geometry")
	_workspace.show_fields(0)
	_workspace.show_page("Fields")
	var original_target: String = _workspace.target
	var original_zip := FileAccess.get_file_as_bytes(original_target)
	var original_title: String = _workspace.draft.title
	var saves_before := _saved.size()
	button.pressed.emit()
	_check(dialog.visible and dialog.current_file == original_target.get_file().get_basename() + "-statistics.csv", "Statistics action opens a CSV dialog with a useful default name")
	dialog.get_cancel_button().pressed.emit()
	await process_frame
	_check(not dialog.visible and not _workspace._busy and _saved.size() == saves_before, "Canceling statistics export does not save or start work")

	var output := _root.path_join("statistics/current")
	dialog.file_selected.emit(output)
	_check(_workspace._busy and _workspace.gui_disable_input and button.disabled, "Statistics worker blocks editing and repeat exports")
	_workspace.edit_title("Must not change during export")
	_workspace.add_frame()
	_workspace.save()
	_workspace.ask_export_statistics()
	_workspace.export_statistics(_root.path_join("statistics/ignored.csv"))
	_check(not dialog.visible, "A late statistics dialog request is ignored while exporting")
	if not await _wait_save():
		return
	output += ".csv"
	_check(not _workspace.gui_disable_input and not button.disabled, "Statistics completion restores editing and export action")
	if not _check(FileAccess.file_exists(output), "Statistics export appends the CSV extension and writes a file"):
		return
	var csv := FileAccess.open(output, FileAccess.READ)
	var header := csv.get_csv_line()
	var row := csv.get_csv_line()
	csv.close()
	var expected := PackedStringArray(["field", "quantity", "unit", "frame", "solver_time", "source_file", "valid_count", "missing_count", "min", "max", "mean"])
	if _check(header == expected and row.size() == expected.size(), "Workspace export uses the documented CSV columns"):
		_check(row[0] == field.name and row[1] == field.quantity and row[2] == field.unit, "CSV uses the current unsaved field metadata")
		_check(row[3].to_int() == 1 and is_equal_approx(row[4].to_float(), 7.5), "CSV uses the current unsaved timeline")
		_check(row[6].to_int() == 2 and row[7].to_int() == 0 and is_equal_approx(row[8].to_float(), 0.0) and is_equal_approx(row[9].to_float(), 254.0) and is_equal_approx(row[10].to_float(), 127.0), "CSV statistics come from the unsaved field bytes and range")
	_check(_workspace.get_node("%Status").text == "Exported current.csv", "Statistics completion reports the exported file")
	_check(_workspace.target == original_target and FileAccess.get_file_as_bytes(original_target) == original_zip and _saved.size() == saves_before, "Statistics export never saves or changes the working ZIP")
	_check(_workspace.draft.fields[0] == field and _workspace.draft.times == PackedFloat64Array([7.5]) and _workspace.draft.title == original_title, "Statistics export retains all unsaved edits and ignores editing callbacks")
	_check(not FileAccess.file_exists(_root.path_join("statistics/ignored.csv")), "A repeated export callback cannot start a second output")

	var invalid := _root.path_join("statistics/directory.csv")
	_check(DirAccess.make_dir_recursive_absolute(invalid) == OK, "Create an invalid statistics destination")
	dialog.file_selected.emit(invalid)
	if not await _wait_save():
		return
	_check(not _workspace.gui_disable_input and not button.disabled, "Failed statistics export restores editing")
	_check(not _workspace.get_node("%Status").text.begins_with("Exported ") and not _workspace.get_node("%Status").text.is_empty(), "Failed statistics export displays its error")
	_check(DirAccess.dir_exists_absolute(invalid) and FileAccess.get_file_as_bytes(original_target) == original_zip, "Failed statistics export preserves the destination and ZIP")

	dialog.file_selected.emit(source)
	if not await _wait_save():
		return
	_check(FileAccess.get_file_as_bytes(source) == PackedByteArray([1, 255]), "Statistics export cannot overwrite a current field source")
	_check(not _workspace.get_node("%Status").text.begins_with("Exported "), "Source overwrite protection is reported in the workspace")
	_check(_workspace.target == original_target and _saved.size() == saves_before and _workspace.draft.fields[0] == field, "Export failures keep the draft and save target intact")


func _wait_save() -> bool:
	var deadline := Time.get_ticks_msec() + 15000
	while _workspace._busy and Time.get_ticks_msec() < deadline:
		await create_timer(0.01).timeout
	return _check(not _workspace._busy, "Background operation completes within 15 seconds")


func _triangle_glb(height := 0.0) -> PackedByteArray:
	var binary := PackedByteArray()
	binary.resize(44)
	var coordinates := [0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0, height]
	for index in coordinates.size():
		binary.encode_float(index * 4, coordinates[index])
	for index in 3:
		binary.encode_u16(36 + index * 2, index)
	var json := JSON.stringify({
		"asset": {"version": "2.0"}, "scene": 0, "scenes": [{"nodes": [0]}],
		"nodes": [{"mesh": 0}], "meshes": [{"primitives": [{"attributes": {"POSITION": 0}, "indices": 1}]}],
		"buffers": [{"byteLength": 42}],
		"bufferViews": [{"buffer": 0, "byteOffset": 0, "byteLength": 36, "target": 34962}, {"buffer": 0, "byteOffset": 36, "byteLength": 6, "target": 34963}],
		"accessors": [{"bufferView": 0, "componentType": 5126, "count": 3, "type": "VEC3", "min": [0, 0, 0], "max": [1, 1, height]}, {"bufferView": 1, "componentType": 5123, "count": 3, "type": "SCALAR"}],
	}).to_utf8_buffer()
	while json.size() % 4:
		json.append(32)
	var header := PackedByteArray()
	header.resize(20)
	header.encode_u32(0, 0x46546C67)
	header.encode_u32(4, 2)
	header.encode_u32(8, 20 + json.size() + 8 + binary.size())
	header.encode_u32(12, json.size())
	header.encode_u32(16, 0x4E4F534A)
	var binary_header := PackedByteArray()
	binary_header.resize(8)
	binary_header.encode_u32(0, binary.size())
	binary_header.encode_u32(4, 0x004E4942)
	return header + json + binary_header + binary


func _remove_tree(path: String) -> void:
	for child in DirAccess.get_directories_at(path):
		_remove_tree(path.path_join(child))
	for child in DirAccess.get_files_at(path):
		DirAccess.remove_absolute(path.path_join(child))
	DirAccess.remove_absolute(path)
