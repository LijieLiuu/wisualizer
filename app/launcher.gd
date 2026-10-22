extends MarginContainer
## The app's first window: a library of the ZIPs added so far. Each ZIP opens
## in its own document windows, so several can be open at once.

const Document := preload("res://app/document.tscn")
## Added ZIPs are copied here, so they can be opened again after the app
## restarts without access to where they came from.
const LIBRARY := "user://library"
## When each ZIP in the library was last opened, by file name.
const OPENED_FILE := "user://opened.cfg"
const COPY_CHUNK := 1 << 20

@onready var library_list: VBoxContainer = %Library
## A hidden row, copied for each ZIP so its look is set in the editor.
@onready var row_template: HBoxContainer = %Row
@onready var confirm_delete: ConfirmationDialog = %ConfirmDelete

var _pending_delete := ""


func _ready() -> void:
	%Version.text = "Version %s" % ProjectSettings.get_setting("application/config/version", "")
	DirAccess.make_dir_recursive_absolute(LIBRARY)
	show_library()
	# ZIPs passed on the command line, after "--", are added as if picked.
	for argument in OS.get_cmdline_user_args():
		if argument.get_extension().to_lower() == "zip" and FileAccess.file_exists(argument):
			import_zip(argument)


## Copies a picked ZIP into the library and opens it.
func import_zip(path: String) -> void:
	var copy := LIBRARY.path_join(path.get_file())
	var source := FileAccess.open(path, FileAccess.READ)
	var target := FileAccess.open(copy, FileAccess.WRITE)
	if source == null or target == null:
		push_error("Couldn't copy %s into the library." % path)
		return
	while source.get_position() < source.get_length():
		target.store_buffer(source.get_buffer(COPY_CHUNK))
	target.close()
	open_zip(copy)


func open_zip(path: String) -> void:
	var opened := ConfigFile.new()
	opened.load(OPENED_FILE)
	opened.set_value("opened", path.get_file(), Time.get_unix_time_from_system())
	opened.save(OPENED_FILE)
	show_library()

	var document := Document.instantiate()
	add_child(document)
	document.open(path)


## Asks before deleting a ZIP from the library; the file it came from stays.
## Uses the system's own alert where there is one.
func ask_delete(path: String) -> void:
	_pending_delete = path
	var message := "%s is removed from the library. The original file isn't affected." % path.get_file().get_basename()
	if DisplayServer.has_feature(DisplayServer.FEATURE_NATIVE_DIALOG):
		DisplayServer.dialog_show(confirm_delete.title, message, PackedStringArray(["Delete", "Cancel"]), _on_delete_answered, 0, 1)
	else:
		confirm_delete.dialog_text = message
		confirm_delete.popup_centered()


func _on_delete_answered(button: int) -> void:
	if button == 0:
		delete_pending()


func delete_pending() -> void:
	DirAccess.remove_absolute(_pending_delete)
	var opened := ConfigFile.new()
	opened.load(OPENED_FILE)
	if opened.has_section_key("opened", _pending_delete.get_file()):
		opened.erase_section_key("opened", _pending_delete.get_file())
		opened.save(OPENED_FILE)
	_pending_delete = ""
	show_library()


## The library's ZIPs, most recently opened first; never-opened ones by when
## they were added.
func read_library() -> Array[String]:
	var opened := ConfigFile.new()
	opened.load(OPENED_FILE)
	var paths: Array[String] = []
	for file in DirAccess.get_files_at(LIBRARY):
		if file.get_extension().to_lower() == "zip":
			paths.append(LIBRARY.path_join(file))
	var last_used := func(path: String) -> float:
		return opened.get_value("opened", path.get_file(), FileAccess.get_modified_time(path))
	paths.sort_custom(func(a: String, b: String) -> bool: return last_used.call(a) > last_used.call(b))
	return paths


func show_library() -> void:
	for child in library_list.get_children():
		if child != row_template:
			child.queue_free()
	var paths := read_library()
	%Empty.visible = paths.is_empty()
	for path in paths:
		var row := row_template.duplicate() as HBoxContainer
		row.visible = true
		var open_button := row.get_node("Open") as Button
		open_button.text = path.get_file().get_basename()
		open_button.pressed.connect(open_zip.bind(path))
		(row.get_node("Delete") as Button).pressed.connect(ask_delete.bind(path))
		library_list.add_child(row)
