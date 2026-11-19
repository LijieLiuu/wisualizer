extends RefCounted
## A ZIP's contents, read through its meta.json; see docs/zip-format.md.
## Keeps the ZIP open, so steps can be read as they are needed.

const MANIFEST := "meta.json"
const ZipFiles := preload("res://app/zip_files.gd")
const ScalarData := preload("res://app/scalar_data.gd")


## One of a model's parts.
class Part:
	var name := ""
	## The part's GLB at each frame of its model. A part that doesn't change
	## has the same GLB at every frame.
	var files := PackedStringArray()
	## Its steps as the ZIP has them: a GLB per solver time, in order, or
	## one GLB with no time.
	var step_times := PackedFloat64Array()
	var step_files := PackedStringArray()
	## Index into step_files for each displayed model frame.
	var frame_steps := PackedInt32Array()


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
	var size := Vector3.ONE
	var axes := Basis()
	## The field's brick at each frame of its model.
	var files := PackedStringArray()
	## Its steps as the ZIP has them: a brick per solver time, in order.
	var step_times := PackedFloat64Array()
	var step_files := PackedStringArray()
	## Index into step_files for each displayed model frame.
	var frame_steps := PackedInt32Array()
	## The largest byte in any of its bricks, or 0 until it is measured.
	var peak := 0

	## The value [param byte] stands for, or NAN for a cell with no value.
	func value_of(byte: int) -> float:
		return NAN if byte == 0 else lerpf(range.x, range.y, (byte - 1) / 254.0)

	## A value with its unit, such as "0.067 T".
	func format(value: float) -> String:
		var text := String.num(value, 3) if absf(value) >= 0.01 or value == 0.0 else _scientific(value)
		return text if unit.is_empty() else "%s %s" % [text, unit]

	## [param value] as "9.38e-05". GDScript's % has no %e: it fails the call.
	static func _scientific(value: float) -> String:
		var exponent := floori(log(absf(value)) / log(10.0))
		var mantissa := value / pow(10.0, exponent)
		# Rounding to two decimals can carry 9.996 up to 10.00.
		if absf(mantissa) >= 9.995:
			mantissa /= 10.0
			exponent += 1
		return "%.2fe%s%02d" % [mantissa, "-" if exponent < 0 else "+", absi(exponent)]


## Text shown in the volume at a point, while a controller is near it.
class PointLabel:
	var text := ""
	## The point, in model units.
	var position := Vector3.ZERO
	## How near a controller comes for the text to show, in model units, or
	## 0 for the default.
	var radius := 0.0
	## The first and last frames it shows at, counted from 0.
	var frames := Vector2i.ZERO

	func shows_at(frame: int) -> bool:
		return frame >= frames.x and frame <= frames.y


## One model: its own volume, timeline, parts, fields and labels.
class Model:
	var name := ""
	## The solver time of each frame.
	var times := PackedFloat64Array()
	var parts: Array[Part] = []
	var fields: Array[Field] = []
	var labels: Array[PointLabel] = []
	## The index of the field shown first.
	var first_field := 0


var title := ""
var models: Array[Model] = []
## Flat archives become one model with their original geometry entries as parts.
var legacy := false
## Compatibility aliases for older single-model analysis callers.
var times: PackedFloat64Array:
	get: return models[0].times if not models.is_empty() else PackedFloat64Array()
var fields: Array[Field]:
	get: return models[0].fields if not models.is_empty() else []
var first_field: int:
	get: return models[0].first_field if not models.is_empty() else 0
var notes := ""
var attachments := PackedStringArray()
var _zip := ZIPReader.new()
var _is_open := false
var entries := {}
var file_names := PackedStringArray()


func open(path: String) -> String:
	var error := _open(path)
	if not error.is_empty():
		close()
	return error


func _open(path: String) -> String:
	close()
	title = ""
	models.clear()
	legacy = false
	attachments = PackedStringArray()
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
	legacy = manifest.has("frames")
	if legacy:
		var model := Model.new()
		model.name = title
		var error := _read_legacy(model, manifest)
		if not error.is_empty():
			return error
		models.append(model)
	else:
		for entry in manifest.get("models", []):
			if not entry is Dictionary:
				return "Each model must be an object."
			var model := Model.new()
			var error := _read_model(model, entry)
			if not error.is_empty():
				return error
			models.append(model)
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
	return ""


func _read_model(model: Model, entry: Dictionary) -> String:
	var error := _string_keys(entry, ["name", "field"])
	if not error.is_empty():
		return "Model: " + error
	model.name = entry.get("name", "Model %d" % (models.size() + 1))
	for key in ["parts", "fields", "labels"]:
		if entry.has(key) and not entry[key] is Array:
			return "Model %s: %s must be an array." % [model.name, key]
	var all_times := PackedFloat64Array()
	for value in entry.get("parts", []):
		if not value is Dictionary or not _string_keys(value, ["name", "path"]).is_empty():
			return "Model %s has invalid part metadata." % model.name
		var part := Part.new()
		part.name = value.get("name", "Part %d" % (model.parts.size() + 1))
		var steps := _steps(value, "glb")
		if steps.is_empty():
			return "Part %s needs a GLB or a folder with a finite solver time for every GLB." % part.name
		part.step_times = steps[0]
		part.step_files = steps[1]
		all_times.append_array(part.step_times)
		model.parts.append(part)
	if model.parts.is_empty():
		return "The model %s has no parts." % model.name
	for value in entry.get("fields", []):
		if not value is Dictionary:
			return "Each field must be an object."
		var field := Field.new()
		error = _read_field(field, value, model.fields.size())
		if not error.is_empty():
			return error
		var steps := _steps(value, "bin")
		if steps.is_empty():
			return "Field %s needs a brick or a folder with a finite solver time for every brick." % field.name
		field.step_times = steps[0]
		field.step_files = steps[1]
		error = _field_sizes(field)
		if not error.is_empty():
			return error
		all_times.append_array(field.step_times)
		model.fields.append(field)
	model.times = timeline(all_times)
	for part in model.parts:
		_map_frames(part, model.times)
	for field in model.fields:
		_map_frames(field, model.times)
	_select_first(model, entry.get("field", ""), true)
	return _read_labels(model, entry.get("labels", []))


func _read_legacy(model: Model, manifest: Dictionary) -> String:
	for entry in manifest.get("frames", []):
		if not entry is Dictionary or not ScalarData.is_finite_number(entry.get("time")):
			return "Frame %d needs a finite numeric solver time." % (model.times.size() + 1)
		model.times.append(float(entry.time))
	if model.times.is_empty():
		return "The ZIP has no frames."
	for entry in manifest.get("models", []):
		if not entry is Dictionary or entry.has("parts") or not _string_keys(entry, ["name", "path"]).is_empty():
			return "Each legacy model must name a GLB or frame folder."
		var part := Part.new()
		part.name = entry.get("name", "Part %d" % (model.parts.size() + 1))
		var error := _legacy_steps(part, entry.get("path", ""), "glb", model.times)
		if not error.is_empty():
			return "Part %s: %s" % [part.name, error]
		model.parts.append(part)
	if model.parts.is_empty():
		return "The ZIP has no models."
	for entry in manifest.get("fields", []):
		if not entry is Dictionary:
			return "Each field must be an object."
		var field := Field.new()
		var error := _read_field(field, entry, model.fields.size())
		if error.is_empty():
			error = _legacy_steps(field, entry.get("path", ""), "bin", model.times)
		if error.is_empty():
			error = _field_sizes(field)
		if not error.is_empty():
			return "Field %s: %s" % [field.name, error]
		model.fields.append(field)
	_select_first(model, manifest.get("field", ""))
	return ""


func _read_field(field: Field, entry: Dictionary, index: int) -> String:
	var error := _string_keys(entry, ["name", "quantity", "unit", "path"])
	if not error.is_empty():
		return "Field: " + error
	field.name = entry.get("name", "Field %d" % (index + 1))
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
	return ""


func _field_sizes(field: Field) -> String:
	var expected := ScalarData.cell_count(field.cells)
	for file in field.step_files:
		if entries[file].size != expected:
			return "%s has %d bytes; its grid requires exactly %d." % [file, entries[file].size, expected]
	return ""


static func _select_first(model: Model, name: String, last_match := false) -> void:
	for index in model.fields.size():
		if model.fields[index].name == name:
			model.first_field = index
			if not last_match:
				break


func _read_labels(model: Model, entries: Array) -> String:
	for entry in entries:
		if not entry is Dictionary or not entry.get("text") is String or entry.text.strip_edges().is_empty():
			return "A point label needs text and a position."
		var position := ScalarData.parse_vector(entry.get("position"), "Label position")
		if not position.error.is_empty():
			return position.error
		var radius = entry.get("radius", 0.0)
		if not ScalarData.is_finite_number(radius):
			return "A label radius must be finite."
		var label := PointLabel.new()
		label.text = entry.text.strip_edges()
		label.position = position.value
		label.radius = maxf(float(radius), 0.0)
		var span = entry.get("frames", [1, model.times.size()])
		if not span is Array or span.is_empty() or span.size() > 2:
			return "Label frames must be [n] or [first, last]."
		for value in span:
			if not ScalarData.is_finite_number(value) or value != floor(float(value)) or value < 1 or value > model.times.size():
				return "Label frames must be whole model frame numbers in range."
		label.frames = Vector2i(int(span[0]) - 1, int(span[-1]) - 1)
		if label.frames.x > label.frames.y:
			return "Label frames must be in order."
		model.labels.append(label)
	return ""


func _legacy_steps(item, path: String, extension: String, frames: PackedFloat64Array) -> String:
	if not is_file_path(path.trim_suffix("/")):
		return "Invalid archive path."
	if path.get_extension().to_lower() == extension and _file_exists(path):
		item.step_files = PackedStringArray([path])
		for frame in frames.size():
			item.files.append(path)
			item.frame_steps.append(0)
		return ""
	var files := _folder_files(path, extension)
	if files.size() != frames.size():
		return "The folder needs one file for each of the %d frames." % frames.size()
	item.step_times = frames.duplicate()
	item.step_files = files
	item.files = files.duplicate()
	for index in frames.size():
		item.frame_steps.append(index)
	return ""


func _folder_files(path: String, extension: String) -> PackedStringArray:
	var files := PackedStringArray()
	var folder := path.trim_suffix("/") + "/"
	for file in file_names:
		if file.begins_with(folder) and file.get_base_dir() + "/" == folder and file.get_extension().to_lower() == extension:
			files.append(file)
	files.sort()
	return files


func _steps(entry: Dictionary, extension: String) -> Array:
	var path: String = entry.get("path", "")
	if not is_file_path(path.trim_suffix("/")) or not entry.get("times", []) is Array:
		return []
	var times := PackedFloat64Array()
	for time in entry.get("times", []):
		if not ScalarData.is_finite_number(time):
			return []
		times.append(float(time))
	if path.get_extension().to_lower() == extension and _file_exists(path):
		return [PackedFloat64Array(), PackedStringArray([path])]
	var files := _folder_files(path, extension)
	if files.is_empty() or times.size() != files.size():
		return []
	var order := range(files.size())
	order.sort_custom(func(a: int, b: int) -> bool: return times[a] < times[b] if times[a] != times[b] else a < b)
	var sorted_times := PackedFloat64Array()
	var sorted_files := PackedStringArray()
	for index in order:
		sorted_times.append(times[index])
		sorted_files.append(files[index])
	return [sorted_times, sorted_files]


static func _map_frames(item, frames: PackedFloat64Array) -> void:
	for time in frames:
		var index := 0 if item.step_times.is_empty() else step_at(item.step_times, time)
		item.frame_steps.append(index)
		item.files.append(item.step_files[index])


## The held source step, independent of the displayed model time. Steps are 1-based.
static func frame_source(field: Field, frame: int) -> Dictionary:
	var step := field.frame_steps[frame]
	var is_static := field.step_times.is_empty()
	return {source_step = step + 1, source_time = null if is_static else field.step_times[step],
		source_static = is_static, source_file = field.files[frame]}


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


## Team timeline: sorted union, merging exporter rounding within same_time.
## A model with only static sources has one displayed frame at zero.
static func timeline(times: PackedFloat64Array) -> PackedFloat64Array:
	var sorted := times.duplicate()
	sorted.sort()
	var frames := PackedFloat64Array()
	for time in sorted:
		if frames.is_empty() or not same_time(frames[-1], time):
			frames.append(time)
	if frames.is_empty():
		frames.append(0.0)
	return frames


## Whether two solver times are one: exporters round them differently.
static func same_time(a: float, b: float) -> bool:
	return absf(a - b) <= maxf(absf(a), absf(b)) * 1e-6


## The index of the step that shows at [param time], given the steps'
## [param times] in order: the last one at or before it, or the first.
static func step_at(times: PackedFloat64Array, time: float) -> int:
	var step := 0
	for index in times.size():
		if times[index] <= time or same_time(times[index], time):
			step = index
	return step


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
