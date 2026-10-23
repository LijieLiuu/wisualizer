extends RefCounted
## A ZIP's contents, read through its meta.json; see docs/zip-format.md.
## Keeps the ZIP open, so frames can be read as they are needed.

const MANIFEST := "meta.json"


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

var _zip := ZIPReader.new()


## Opens the ZIP at [param path]. Returns an empty string, or what is
## wrong with it.
func open(path: String) -> String:
	if _zip.open(path) != OK:
		return "This file isn't a ZIP."
	if not _zip.file_exists(MANIFEST):
		return "This ZIP has no %s." % MANIFEST
	var manifest = JSON.parse_string(_zip.read_file(MANIFEST).get_string_from_utf8())
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
	return ""


func close() -> void:
	_zip.close()


## The bytes of [param file] in the ZIP, or none if it isn't there.
func read(file: String) -> PackedByteArray:
	return _zip.read_file(file) if not file.is_empty() and _zip.file_exists(file) else PackedByteArray()


## The file at each frame for [param path]: a file, the same at every
## frame, or a folder of [param extension] files, one per frame in name order.
## Empty if it's neither.
func _per_frame(path: String, extension: String) -> PackedStringArray:
	var files := PackedStringArray()
	if path.get_extension().to_lower() == extension and _zip.file_exists(path):
		for index in times.size():
			files.append(path)
		return files
	var folder := path.trim_suffix("/") + "/"
	for file in _zip.get_files():
		if file.begins_with(folder) and file.get_base_dir() + "/" == folder and file.get_extension().to_lower() == extension:
			files.append(file)
	files.sort()
	return files if files.size() == times.size() else PackedStringArray()


static func _vector(values: Array) -> Vector3:
	return Vector3(values[0], values[1], values[2])
