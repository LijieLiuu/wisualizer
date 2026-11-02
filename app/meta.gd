extends RefCounted
## A ZIP's contents, read through its meta.json; see docs/zip-format.md.
## Keeps the ZIP open, so frames can be read as they are needed.

const MANIFEST := "meta.json"
const ZipFiles := preload("res://app/zip_files.gd")
const ScalarData := preload("res://app/scalar_data.gd")


## One model in the ZIP.
class Model:
	var name := ""
	## The model's GLB at each frame. A model that doesn't change has the same
	## GLB at every frame.
	var files := PackedStringArray()


## One field in the ZIP.
class Field:
	var name := ""
	var quantity := ""
	var unit := ""
	## The values bytes 1 and 255 stand for.
	var range := Vector2.ZERO
	var cells := Vector3i.ZERO
	## Maps a unit cube onto the grid, in model units.
	var box := Transform3D()
	## Retain the original factors so editing does not normalize or round them.
	var size := Vector3.ONE
	var axes := Basis()
	## The field's brick at each frame.
	var files := PackedStringArray()

	## The value [param byte] stands for, or NAN for a cell with no value.
	func value_of(byte: int) -> float:
		if byte == 0:
			return NAN
		if range.x == range.y:
			return range.x
		var weight := (byte - 1) / 254.0
		return range.x * (1.0 - weight) + range.y * weight

	## A value with its unit, such as "0.067 T".
	func format(value: float) -> String:
		var text := String.num(value, 3) if absf(value) >= 0.01 or value == 0.0 else "%.2e" % value
		return text if unit.is_empty() else "%s %s" % [text, unit]


var title := ""
var times := PackedFloat64Array()
var models: Array[Model] = []
var fields: Array[Field] = []
## The index of the field shown first.
var first_field := 0
## Where the notes are in the ZIP, or "" without notes.
var notes := ""
## Supporting source files, preserved without interpreting their contents.
var attachments := PackedStringArray()

var _zip := ZIPReader.new()
var _is_open := false
## ZIP central-directory metadata distinguishes empty files from read failures.
var entries := {}
var file_names := PackedStringArray()


## Opens the ZIP at [param path]. Returns an empty string, or what is
## wrong with it.
func open(path: String) -> String:
	var error := _open(path)
	if not error.is_empty():
		close()
	return error


func _open(path: String) -> String:
	close()
	title = ""
	times = PackedFloat64Array()
	models.clear()
	fields.clear()
	attachments = PackedStringArray()
	first_field = 0
	notes = ""
	entries = {}
	file_names = PackedStringArray()
	if _zip.open(path) != OK:
		return "This file isn't a ZIP."
	_is_open = true
	var inventory := ZipFiles.inspect(path, _zip.get_files())
	if not inventory.error.is_empty():
		return inventory.error
	entries = inventory.entries
	file_names = PackedStringArray()
	var seen := {}
	for file: String in entries:
		if entries[file].directory:
			continue
		file_names.append(file)
		if not is_file_path(file):
			return "The ZIP contains an invalid file path: %s." % file
		if seen.has(file.to_lower()):
			return "The ZIP contains duplicate file names: %s." % file
		seen[file.to_lower()] = true
	if not _file_exists(MANIFEST):
		return "This ZIP has no %s." % MANIFEST
	var manifest_read := read_checked(MANIFEST)
	if not manifest_read.error.is_empty():
		return manifest_read.error
	var manifest = JSON.parse_string(manifest_read.bytes.get_string_from_utf8())
	if not manifest is Dictionary:
		return "%s isn't valid JSON." % MANIFEST
	var text_error := _string_keys(manifest, ["title", "field", "notes"])
	if not text_error.is_empty():
		return "Manifest: " + text_error
	for key in ["frames", "models", "fields", "attachments"]:
		if manifest.has(key) and not manifest[key] is Array:
			return "The manifest's %s must be an array." % key
	title = manifest.get("title", path.get_file().get_basename())
	for entry in manifest.get("frames", []):
		if not entry is Dictionary or not ScalarData.is_finite_number(entry.get("time")):
			return "Frame %d needs a finite numeric solver time." % (times.size() + 1)
		times.append(float(entry.time))
	if times.is_empty():
		return "The ZIP has no frames."
	for entry in manifest.get("models", []):
		if not entry is Dictionary:
			return "Each model must be an object."
		text_error = _string_keys(entry, ["name", "path"])
		if not text_error.is_empty():
			return "Model: " + text_error
		var model := Model.new()
		model.name = entry.get("name", "Model %d" % (models.size() + 1))
		model.files = _per_frame(entry.get("path", ""), "glb")
		if model.files.is_empty():
			return "The model %s needs a GLB, or a folder with a GLB for each of the %d frames." % [model.name, times.size()]
		models.append(model)
	for entry in manifest.get("fields", []):
		if not entry is Dictionary:
			return "Each field must be an object."
		text_error = _string_keys(entry, ["name", "quantity", "unit", "path"])
		if not text_error.is_empty():
			return "Field: " + text_error
		var field := Field.new()
		field.name = entry.get("name", "Field %d" % (fields.size() + 1))
		field.quantity = entry.get("quantity", "")
		field.unit = entry.get("unit", "")
		var span := ScalarData.parse_range(entry.get("range", [0.0, 1.0]))
		if not span.error.is_empty():
			return "Field %s: %s" % [field.name, span.error]
		field.range = span.value
		var cells := ScalarData.parse_cells(entry.get("cells"))
		if not cells.error.is_empty():
			return "Field %s: %s" % [field.name, cells.error]
		field.cells = cells.value
		var box := ScalarData.parse_box(entry.get("box", {}))
		if not box.error.is_empty():
			return "Field %s: %s" % [field.name, box.error]
		field.box = box.value
		field.size = box.size
		field.axes = box.axes
		field.files = _per_frame(entry.get("path", ""), "bin")
		if field.files.is_empty():
			return "The field %s needs cells, and a folder with a brick for each of the %d frames." % [field.name, times.size()]
		var expected := ScalarData.cell_count(field.cells)
		for file in field.files:
			if entries[file].size != expected:
				return "Field %s: %s has %d bytes; its grid requires exactly %d." % [field.name, file, entries[file].size, expected]
		fields.append(field)
	if models.is_empty():
		return "The ZIP has no models."
	notes = manifest.get("notes", "")
	if not notes.is_empty() and (not is_file_path(notes) or not _file_exists(notes)):
		return "The notes file is missing or has an invalid path."
	var extra = manifest.get("attachments", [])
	if not extra is Array:
		return "The attachments must be a list of file paths."
	var listed := {}
	for file in extra:
		if not file is String or not is_file_path(file) or not _file_exists(file):
			return "An attachment is missing or has an invalid path."
		if listed.has(file.to_lower()):
			return "The attachment %s is listed more than once." % file
		listed[file.to_lower()] = true
		attachments.append(file)
	for index in fields.size():
		if fields[index].name == manifest.get("field", ""):
			first_field = index
			break
	return ""


func _file_exists(path: String) -> bool:
	return entries.has(path) and not entries[path].directory


func close() -> void:
	if _is_open:
		_zip.close()
		_is_open = false


## The bytes of [param file] in the ZIP, or none if it isn't there.
func read(file: String) -> PackedByteArray:
	var result := read_checked(file)
	if not result.error.is_empty():
		push_error(result.error)
	return result.bytes


func read_checked(file: String) -> Dictionary:
	if file.is_empty():
		return {bytes = PackedByteArray(), error = ""}
	if not _is_open or not entries.has(file) or entries[file].directory:
		return {bytes = PackedByteArray(), error = "The ZIP file %s is missing." % file}
	var size: int = entries[file].size
	if size > 0x7fffffff:
		return {bytes = PackedByteArray(), error = "The ZIP file %s exceeds the reader's limit of less than 2 GiB." % file}
	var bytes := _zip.read_file(file)
	if bytes.size() != size:
		return {bytes = PackedByteArray(), error = "Couldn't read all of %s. The ZIP may be damaged." % file}
	return {bytes = bytes, error = ""}


## The file at each frame for [param path]: a file, the same at every
## frame, or a folder of [param extension] files, one per frame in name order.
## Empty if it's neither.
func _per_frame(path: String, extension: String) -> PackedStringArray:
	var files := PackedStringArray()
	if path.get_extension().to_lower() == extension and _file_exists(path):
		for index in times.size():
			files.append(path)
		return files
	var folder := path.trim_suffix("/") + "/"
	for file in file_names:
		if file.begins_with(folder) and file.get_base_dir() + "/" == folder and file.get_extension().to_lower() == extension:
			files.append(file)
	files.sort()
	return files if files.size() == times.size() else PackedStringArray()


static func _string_keys(value: Dictionary, keys: Array) -> String:
	for key in keys:
		if value.has(key) and not value[key] is String:
			return "%s must be text." % key
	return ""


## File paths stay relative to the archive, and portable between computers.
static func is_file_path(path: String) -> bool:
	if path.is_empty() or path.begins_with("/") or "\\" in path or ":" in path:
		return false
	for part in path.split("/", true):
		if part.is_empty() or part in [".", ".."] or part != part.validate_filename():
			return false
		for index in part.length():
			if part.unicode_at(index) < 32:
				return false
	return true
