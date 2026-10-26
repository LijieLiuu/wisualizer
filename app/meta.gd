extends RefCounted
## A ZIP's contents, read through its meta.json; see docs/zip-format.md.
## Keeps the ZIP open, so frames can be read as they are needed.

const MANIFEST := "meta.json"
const ZipFiles := preload("res://app/zip_files.gd")


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
	## The field's brick at each frame.
	var files := PackedStringArray()

	## The value [param byte] stands for, or NAN for a cell with no value.
	func value_of(byte: int) -> float:
		return NAN if byte == 0 else lerpf(range.x, range.y, (byte - 1) / 254.0)

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
	close()
	times = PackedFloat64Array()
	models.clear()
	fields.clear()
	attachments = PackedStringArray()
	first_field = 0
	notes = ""
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
	title = str(manifest.get("title", path.get_file().get_basename()))
	for entry in manifest.get("frames", []):
		times.append(float(entry.get("time", times.size())))
	if times.is_empty():
		return "The ZIP has no frames."
	for entry in manifest.get("models", []):
		var model := Model.new()
		model.name = str(entry.get("name", "Model %d" % (models.size() + 1)))
		model.files = _per_frame(str(entry.get("path", "")), "glb")
		if model.files.is_empty():
			return "The model %s needs a GLB, or a folder with a GLB for each of the %d frames." % [model.name, times.size()]
		models.append(model)
	for entry in manifest.get("fields", []):
		var field := Field.new()
		field.name = str(entry.get("name", "Field %d" % (fields.size() + 1)))
		field.quantity = str(entry.get("quantity", ""))
		field.unit = str(entry.get("unit", ""))
		var span: Array = entry.get("range", [0.0, 1.0])
		field.range = Vector2(span[0], span[1])
		var cells: Array = entry.get("cells", [])
		field.cells = Vector3i(cells[0], cells[1], cells[2]) if cells.size() == 3 else Vector3i.ZERO
		var box: Dictionary = entry.get("box", {})
		var axes: Array = box.get("axes", [[1, 0, 0], [0, 1, 0], [0, 0, 1]])
		var basis := Basis(_vector(axes[0]), _vector(axes[1]), _vector(axes[2])) * Basis.from_scale(_vector(box.get("size", [1, 1, 1])))
		field.box = Transform3D(basis, _vector(box.get("origin", [0, 0, 0])))
		field.files = _per_frame(str(entry.get("path", "")), "bin")
		if field.files.is_empty() or field.cells.x * field.cells.y * field.cells.z == 0:
			return "The field %s needs cells, and a folder with a brick for each of the %d frames." % [field.name, times.size()]
		fields.append(field)
	if models.is_empty():
		return "The ZIP has no models."
	notes = str(manifest.get("notes", ""))
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
		if fields[index].name == str(manifest.get("field", "")):
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


static func _vector(values: Array) -> Vector3:
	return Vector3(values[0], values[1], values[2])


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
