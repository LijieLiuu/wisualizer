extends RefCounted
## What the workspace edits: the contents of a ZIP, as the workspace builds
## them up from files on disk and from the ZIP it was opened from, until
## they are saved as a ZIP; see docs/zip-format.md.
##
## Each GLB, brick and image is a source: a path on disk, or a path in the
## opened ZIP with the [constant IN_ZIP] prefix. Sources are copied as they
## are when the draft is saved; nothing is decoded.
##
## A model derives its timeline from its parts and fields. A legacy ZIP with
## repeated or unordered times keeps the explicit frames it was authored with.

const Meta := preload("res://app/meta.gd")
const GLBInfo := preload("res://app/glb_info.gd")
const ScalarData := preload("res://app/scalar_data.gd")
const BOV := preload("res://app/bov.gd")
const NotesImages := preload("res://app/notes_images.gd")
const IN_ZIP := "zip://"
const NOTES_FILE := "notes.txt"
const IMAGES_FOLDER := "images"
const ATTACHMENTS_FOLDER := "attachments"
const COPY_CHUNK := 1 << 20
## ZIPReader returns a PackedByteArray; keep saved files readable on reopen.
const MAX_FILE_SIZE := 0x7fffffff
const MODELS_FOLDER := "models"
## Saving writes beside the target first, so a failure leaves the old ZIP.
const TEMPORARY_SUFFIX := ".saving"


class Part:
	var name := ""
	## Its GLBs in time order, with each one's solver time; or one GLB with no
	## time, for a part that doesn't change.
	var files := PackedStringArray()
	var times := PackedFloat64Array()

	func changes() -> bool:
		return not times.is_empty()


class Field:
	var name := ""
	var quantity := ""
	var unit := ""
	var range := Vector2(0.0, 1.0)
	var cells := Vector3i.ZERO
	var origin := Vector3.ZERO
	var size := Vector3.ONE
	var axes := Basis()
	## Its bricks by solver time.
	var bricks := {}

	## A single untimed brick contributes no time to a model's timeline.
	var untimed := false
	## A flat archive with repeated or out-of-order times identifies bricks by frame.
	var indexed_frames := false

	func source_at(time: float, frame := -1) -> String:
		if indexed_frames:
			return bricks.get(frame, "")
		if bricks.is_empty() or not is_finite(time):
			return ""
		var steps := PackedFloat64Array(bricks.keys())
		steps.sort()
		return bricks[steps[Meta.step_at(steps, time)]]

	## The time among its bricks' that is [param time], or [param time].
	func key_for(time: float) -> float:
		for at: float in bricks:
			if Meta.same_time(at, time):
				return at
		return time


class PointLabel:
	var text := ""
	var position := Vector3.ZERO
	## 0 for the default.
	var radius := 0.0
	## The first and last solver times it shows at; -INF and INF reach the
	## ends of the timeline, however it grows.
	var span := Vector2(-INF, INF)

	## The first line of its text, to list it by.
	func title() -> String:
		var line := text.strip_edges().get_slice("\n", 0)
		return line if not line.is_empty() else "(no text)"


class Model:
	var name := ""
	var parts: Array[Part] = []
	var fields: Array[Field] = []
	var labels: Array[PointLabel] = []
	var first_field := 0
	var legacy_times := PackedFloat64Array()

	## The solver time of each frame: every time its parts and fields have.
	func times() -> PackedFloat64Array:
		if not legacy_times.is_empty():
			return legacy_times.duplicate()
		var all := PackedFloat64Array()
		for part in parts:
			all.append_array(part.times)
		for field in fields:
			if not field.untimed:
				all.append_array(PackedFloat64Array(field.bricks.keys()))
		return Meta.timeline(all)

	## The frames, counted from 0, that [param label] shows at, as [first,
	## last]; last is below first if it shows at none.
	func label_frames(label: PointLabel) -> Vector2i:
		var frames := times()
		var first := frames.size()
		var last := -1
		for index in frames.size():
			var time := frames[index]
			var after_first := time >= label.span.x or Meta.same_time(time, label.span.x)
			var before_last := time <= label.span.y or Meta.same_time(time, label.span.y)
			if after_first and before_last:
				first = mini(first, index)
				last = index
		return Vector2i(first, last)

	## The span that shows [param label] from frame [param first] to frame
	## [param last], counted from 0; the ends of the timeline stay open.
	func span_of(first: int, last: int) -> Vector2:
		var frames := times()
		return Vector2(-INF if first <= 0 else frames[first], INF if last >= frames.size() - 1 else frames[last])


var title := ""
var models: Array[Model] = []
var notes := ""
## Keep the original notes location so relative links survive a round trip.
var notes_path := NOTES_FILE
## Archive-relative paths mapped to sources; these files are copied unchanged.
var attachments := {}
## The images the notes can show, by file name, as sources.
var images := {}

var _zip: ZIPReader
var _zip_path := ""
var _zip_entries := {}
## A ZIPReader reads one file at a time: the notes preview may read while a
## save does.
var _zip_lock := Mutex.new()
## Bounds by GLB source, once read.
var _bounds := {}


## Takes the contents of the ZIP at [param zip_path]. Returns an empty
## string, or what is wrong with it.
func open(zip_path: String) -> String:
	var meta := Meta.new()
	var error := meta.open(zip_path)
	if not error.is_empty():
		meta.close()
		return error
	var notes_read := meta.read_checked(meta.notes)
	if not notes_read.error.is_empty():
		meta.close()
		return notes_read.error
	var decoded_notes := _decode_notes(notes_read.bytes)
	if not decoded_notes.error.is_empty():
		meta.close()
		return decoded_notes.error
	var zip := ZIPReader.new()
	if zip.open(zip_path) != OK:
		meta.close()
		return "Couldn't read %s." % zip_path
	var used := {Meta.MANIFEST: true}
	for entry in meta.models:
		for part in entry.parts:
			for file in part.step_files:
				used[file] = true
		for field in entry.fields:
			for file in field.step_files:
				used[file] = true
	if not meta.notes.is_empty():
		used[meta.notes] = true
	for file in meta.attachments:
		if used.has(file):
			meta.close()
			zip.close()
			return "The attachment %s is already used by the document." % file
	close()
	_zip_lock.lock()
	_zip = zip
	_zip_path = zip_path
	_zip_entries = meta.entries.duplicate(true)
	_zip_lock.unlock()
	title = meta.title
	models = []
	images = {}
	attachments = {}
	_bounds.clear()
	for entry in meta.models:
		var model := Model.new()
		model.name = entry.name
		if meta.legacy and entry.times != Meta.timeline(entry.times):
			model.legacy_times = entry.times.duplicate()
		for part_entry in entry.parts:
			var part := Part.new()
			part.name = part_entry.name
			part.times = part_entry.step_times.duplicate()
			for file in part_entry.step_files:
				part.files.append(IN_ZIP + file)
			model.parts.append(part)
		for field_entry in entry.fields:
			var field := Field.new()
			field.name = field_entry.name
			field.quantity = field_entry.quantity
			field.unit = field_entry.unit
			field.range = field_entry.range
			field.cells = field_entry.cells
			field.origin = field_entry.box.origin
			field.size = field_entry.size
			field.axes = field_entry.axes
			field.indexed_frames = not model.legacy_times.is_empty()
			field.untimed = field_entry.step_times.is_empty()
			if field.indexed_frames:
				for frame in field_entry.files.size():
					field.bricks[frame] = IN_ZIP + field_entry.files[frame]
			elif field.untimed:
				field.bricks[0.0] = IN_ZIP + field_entry.step_files[0]
			else:
				for step in field_entry.step_files.size():
					field.bricks[field_entry.step_times[step]] = IN_ZIP + field_entry.step_files[step]
			model.fields.append(field)
		# A flat ZIP can specify extra frames even when every part is static.
		if meta.legacy and model.legacy_times.is_empty() and model.times() != entry.times:
			var part := model.parts[0]
			part.times = entry.times.duplicate()
			part.files.clear()
			for file in entry.parts[0].files:
				part.files.append(IN_ZIP + file)
		model.first_field = entry.first_field
		for label_entry in entry.labels:
			var label := PointLabel.new()
			label.text = label_entry.text
			label.position = label_entry.position
			label.radius = label_entry.radius
			model.labels.append(label)
			label.span = model.span_of(label_entry.frames.x, label_entry.frames.y)
		models.append(model)
	notes = decoded_notes.text
	notes_path = meta.notes if not meta.notes.is_empty() else NOTES_FILE
	var images_folder := notes_path.get_base_dir().path_join(IMAGES_FOLDER)
	for file in meta.file_names:
		if used.has(file):
			continue
		if file.get_base_dir() == images_folder and NotesImages.is_image(file) and file not in meta.attachments:
			images[file.get_file()] = IN_ZIP + file
		else:
			# Keep unlisted source files too, including packages made by older tools.
			attachments[file] = IN_ZIP + file
	meta.close()
	return ""


func close() -> void:
	_zip_lock.lock()
	if _zip:
		_zip.close()
		_zip = null
	_zip_lock.unlock()


## Adds an empty model, named to stand apart from the others, and returns it.
func add_model() -> Model:
	var model := Model.new()
	var number := models.size() + 1
	model.name = "Model %d" % number
	while models.any(func(other: Model) -> bool: return _folder(other.name) == _folder(model.name)):
		number += 1
		model.name = "Model %d" % number
	models.append(model)
	return model


## Adds the GLBs at [param paths] to [param model] as parts. GLBs named alike
## but for a number, as EnSight writes one per time step, become one part
## that changes, at their solver times; any other becomes a part shown at
## every frame. Returns an empty string, or what is wrong with the GLBs.
func add_glbs(model: Model, paths: PackedStringArray) -> String:
	if paths.is_empty():
		return "Choose at least one GLB."
	var groups := {}
	for file in paths:
		var stem := file.get_file().get_basename().rstrip("0123456789").rstrip("_-. ")
		if stem.is_empty():
			stem = file.get_file().get_basename()
		if not groups.has(stem):
			groups[stem] = PackedStringArray()
		groups[stem].append(file)
	var added: Array[Part] = []
	for stem: String in groups:
		var files: PackedStringArray = groups[stem]
		files.sort()
		var part := Part.new()
		part.name = stem
		var times := PackedFloat64Array()
		var timed := true
		for file in files:
			var json := GLBInfo.json(FileAccess.get_file_as_bytes(file))
			if json.is_empty():
				return "%s isn't a GLB." % file.get_file()
			if GLBInfo.scene_count(json) > 1:
				return "%s has a scene for each time step. Export a GLB for each time step instead." % file.get_file()
			var time := GLBInfo.time(json)
			timed = timed and not is_nan(time)
			times.append(time)
		part.files = files
		if files.size() > 1:
			# Without solver times, the steps are 0, 1, 2… in name order.
			for index in times.size():
				if not timed:
					times[index] = index
			part.times = times
			_sort_steps(part)
		added.append(part)
	model.parts.append_array(added)
	_bounds.clear()
	return ""


## Orders a part's steps by time, in case its names didn't.
static func _sort_steps(part: Part) -> void:
	var order := range(part.files.size())
	order.sort_custom(func(a: int, b: int) -> bool: return part.times[a] < part.times[b])
	var files := PackedStringArray()
	var times := PackedFloat64Array()
	for index in order:
		files.append(part.files[index])
		times.append(part.times[index])
	part.files = files
	part.times = times


## Adds the bricks whose headers are at [param paths] to [param model], as
## a field per variable, each brick at its solver time: the steps can come
## in any order, a few at a time. A brick at a time its field already has
## replaces that one. Returns an empty string, or what is wrong with the
## bricks.
func add_bovs(model: Model, paths: PackedStringArray) -> String:
	if paths.is_empty():
		return "Choose at least one brick header."
	var candidate_fields: Array[Field] = []
	var by_name := {}
	for existing in model.fields:
		var problem := ScalarData.validate_metadata(existing.range, existing.cells, _field_box(existing))
		if not problem.is_empty():
			return "%s: %s" % [existing.name, problem]
		if by_name.has(existing.name):
			return "Two fields are named %s. Rename one before importing." % existing.name
		var copied := _copy_field(existing)
		candidate_fields.append(copied)
		by_name[copied.name] = copied
	var added := {}
	for file in paths:
		var result := BOV.read_checked(file)
		if not result.error.is_empty():
			return result.error
		var bov: BOV = result.value
		var field: Field = by_name.get(bov.variable)
		if field == null:
			field = Field.new()
			field.name = bov.variable
			field.range = bov.range
			field.cells = bov.cells
			field.origin = bov.origin
			field.size = bov.size
			field.axes = bov.axes
			field.indexed_frames = not model.legacy_times.is_empty()
			candidate_fields.append(field)
			by_name[field.name] = field
		elif field.cells != bov.cells or field.range != bov.range or _field_box(field) != Transform3D(bov.axes * Basis.from_scale(bov.size), bov.origin):
			return "%s has a different grid, value range, or spatial box from %s." % [bov.data.get_file(), field.name]
		var key: Variant = field.key_for(bov.time)
		if field.indexed_frames:
			key = model.legacy_times.find(bov.time)
			if key < 0 or model.legacy_times.count(bov.time) != 1:
				return "Solver time %s must identify one frame in this legacy timeline." % bov.time
		if not added.has(field.name):
			added[field.name] = {}
		if added[field.name].has(key):
			return "Multiple input bricks for %s have the same solver time." % field.name
		added[field.name][key] = true
		if field.untimed:
			if not field.indexed_frames:
				field.bricks.clear()
			field.untimed = false
		field.bricks[key] = bov.data
	model.fields = candidate_fields
	return ""


static func _copy_field(source: Field) -> Field:
	var copied := Field.new()
	copied.name = source.name
	copied.quantity = source.quantity
	copied.unit = source.unit
	copied.range = source.range
	copied.cells = source.cells
	copied.origin = source.origin
	copied.size = source.size
	copied.axes = source.axes
	copied.untimed = source.untimed
	copied.indexed_frames = source.indexed_frames
	copied.bricks = source.bricks.duplicate()
	return copied


static func _field_box(field: Field) -> Transform3D:
	return Transform3D(field.axes * Basis.from_scale(field.size), field.origin)


## Grows or shrinks [param field]'s box about its center until it spans
## [param model]'s parts along their longest side. EnSight doesn't say what
## scale it writes bricks at, and it isn't the geometry's: the Hall sensor's
## brick says it is 40 across, around a model 80 across. Does nothing
## without parts.
func fit_field(model: Model, field: Field) -> void:
	var bounds := model_bounds(model)
	if not bounds.has_volume():
		return
	var axis := bounds.size.max_axis_index()
	if field.size[axis] <= 0.0:
		return
	var scale := bounds.size[axis] / field.size[axis]
	var center := field.origin + field.size * 0.5
	field.size *= scale
	field.origin = center - field.size * 0.5


## The bounds of each of [param model]'s parts' first GLB, together.
func model_bounds(model: Model) -> AABB:
	var bounds := AABB()
	for part in model.parts:
		var source := part.files[0]
		if not _bounds.has(source):
			_bounds[source] = GLBInfo.bounds(GLBInfo.json(read_source(source)))
		bounds = GLBInfo.merge(bounds, _bounds[source])
	return bounds


func add_images(paths: PackedStringArray) -> void:
	for file in paths:
		if NotesImages.is_image(file):
			images[file.get_file()] = file


## The bytes of [param file], as the saved ZIP would hold it, for the
## notes' images; none if it isn't an image here.
func read_file(file: String) -> PackedByteArray:
	if file.get_base_dir() == notes_path.get_base_dir().path_join(IMAGES_FOLDER) and images.has(file.get_file()):
		return read_source(images[file.get_file()])
	if attachments.has(file):
		return read_source(attachments[file])
	return PackedByteArray()


func read_source(source: String) -> PackedByteArray:
	if source.begins_with(IN_ZIP):
		_zip_lock.lock()
		var bytes := _zip.read_file(source.trim_prefix(IN_ZIP)) if _zip else PackedByteArray()
		_zip_lock.unlock()
		return bytes
	return FileAccess.get_file_as_bytes(source)


## Read the step displayed at a solver time, or the exact frame for legacy
## ZIPs whose timeline cannot identify a unique frame by time.
func read_brick_checked(field: Field, time: float, frame := -1) -> Dictionary:
	var error := ScalarData.validate_metadata(field.range, field.cells, _field_box(field))
	if not error.is_empty():
		return {bytes = PackedByteArray(), error = error}
	var expected := ScalarData.cell_count(field.cells)
	var source := field.source_at(time, frame)
	var bytes := PackedByteArray()
	if source.is_empty():
		if field.indexed_frames and frame >= 0 and bytes.resize(expected) == OK:
			return {bytes = bytes, error = ""}
		return {bytes = bytes, error = "The requested scalar step is unavailable."}
	if source.begins_with(IN_ZIP):
		var path := source.trim_prefix(IN_ZIP)
		_zip_lock.lock()
		var found: bool = _zip != null and _zip_entries.has(path) and not _zip_entries[path].directory
		var length: int = _zip_entries[path].size if found else -1
		if found and length == expected:
			bytes = _zip.read_file(path)
		_zip_lock.unlock()
		if not found or length != expected:
			return {bytes = PackedByteArray(), error = "The source brick %s is missing or has the wrong size." % path}
	else:
		var handle := FileAccess.open(source, FileAccess.READ)
		if handle == null:
			return {bytes = PackedByteArray(), error = "Couldn't read %s." % source}
		if handle.get_length() != expected:
			handle.close()
			return {bytes = PackedByteArray(), error = "%s must contain exactly %d scalar bytes." % [source.get_file(), expected]}
		bytes = handle.get_buffer(expected)
		handle.close()
	error = ScalarData.validate(bytes, field.range, field.cells)
	return {bytes = bytes if error.is_empty() else PackedByteArray(), error = error}


func source_zip_path() -> String:
	return _zip_path


## Local source files must never be replaced by a statistics export.
func source_files() -> PackedStringArray:
	var paths := {}
	for model in models:
		for part in model.parts:
			for path in part.files:
				paths[path] = true
		for field in model.fields:
			for path in field.bricks.values():
					paths[path] = true
	for path in images.values():
		paths[path] = true
	for path in attachments.values():
		paths[path] = true
	var result := PackedStringArray()
	for path: String in paths:
		if not path.begins_with(IN_ZIP):
			result.append(path)
	return result


## Adds supporting files as one batch. Existing entries are never overwritten.
func add_attachments(paths: PackedStringArray) -> String:
	if paths.is_empty():
		return "Choose at least one file."
	var added := {}
	var names := {}
	for file: String in attachments:
		names[file.to_lower()] = true
	for source in paths:
		var file := ATTACHMENTS_FOLDER.path_join(source.get_file())
		if not Meta.is_file_path(file):
			return "%s cannot be used as a file name in the ZIP." % source.get_file()
		if names.has(file.to_lower()):
			return "A file named %s is already included. Rename one or remove it first." % source.get_file()
		var handle := FileAccess.open(source, FileAccess.READ)
		if handle == null:
			return "Couldn't read %s." % source
		var length := handle.get_length()
		handle.close()
		if length > MAX_FILE_SIZE:
			return "%s must be smaller than 2 GiB to reopen it with the ZIP reader." % source.get_file()
		names[file.to_lower()] = true
		added[file] = source
	attachments.merge(added)
	return ""


## Reads text before the workspace asks whether to replace or append notes.
static func read_notes_file(path: String) -> Dictionary:
	var handle := FileAccess.open(path, FileAccess.READ)
	if handle == null:
		return {text = "", error = "Couldn't read %s." % path}
	var length := handle.get_length()
	if length > MAX_FILE_SIZE:
		handle.close()
		return {text = "", error = "The text file must be smaller than 2 GiB."}
	var bytes := handle.get_buffer(length)
	handle.close()
	if bytes.size() != length:
		return {text = "", error = "Couldn't read all of %s." % path}
	return _decode_notes(bytes)


static func _decode_notes(bytes: PackedByteArray) -> Dictionary:
	if bytes.slice(0, 3) == PackedByteArray([0xef, 0xbb, 0xbf]):
		bytes = bytes.slice(3)
	if 0 in bytes:
		return {text = "", error = "Choose a UTF-8 text file without null characters."}
	var text := bytes.get_string_from_utf8()
	if text.to_utf8_buffer() != bytes:
		return {text = "", error = "Save the notes as UTF-8 text, then import them again."}
	return {text = text, error = ""}


## What keeps the draft from being saved, or an empty string.
func problems() -> String:
	if models.is_empty():
		return "Add a model."
	var model_names := {}
	for model in models:
		if model.name.strip_edges().is_empty():
			return "A model has no name."
		if model_names.has(_folder(model.name)):
			return "Two models are both named %s." % model.name
		model_names[_folder(model.name)] = true
		if model.parts.is_empty():
			return "%s has no parts: import a GLB." % model.name
		if not model.legacy_times.is_empty() and (models.size() != 1 or not model.labels.is_empty()):
			return "This legacy frame order cannot represent extra volumes or labels without changing its frames."
		var names := {}
		for part in model.parts:
			if part.name.strip_edges().is_empty():
				return "A part of %s has no name." % model.name
			if part.files.is_empty() or (part.changes() and part.files.size() != part.times.size()):
				return "%s needs a GLB for each step." % part.name
			if not model.legacy_times.is_empty() and part.changes() and part.times != model.legacy_times:
				return "%s needs the original frame times in this legacy ZIP." % part.name
			for time in part.times:
				if not is_finite(time):
					return "Every solver time must be finite."
			if names.has(_folder(part.name)):
				return "%s has two parts named %s." % [model.name, part.name]
			names[_folder(part.name)] = true
		names.clear()
		for field in model.fields:
			if field.name.strip_edges().is_empty():
				return "A field of %s has no name." % model.name
			var error := ScalarData.validate_metadata(field.range, field.cells, _field_box(field))
			if not error.is_empty():
				return "%s: %s" % [field.name, error]
			for time in field.bricks:
				if not (time is float or time is int) or not is_finite(float(time)):
					return "%s has an invalid solver time." % field.name
				if not field.bricks[time] is String or field.bricks[time].is_empty():
					return "%s has an invalid brick source." % field.name
			if field.bricks.is_empty():
				return "%s has no bricks." % field.name
			if names.has(_folder(field.name)):
				return "%s has two fields named %s." % [model.name, field.name]
			names[_folder(field.name)] = true
		var problem := label_problems(model)
		if not problem.is_empty():
			return problem
	var plan := _plan()
	if not plan.error.is_empty():
		return plan.error
	for source: String in plan.sources.values():
		if source.begins_with(IN_ZIP):
			_zip_lock.lock()
			var file := source.trim_prefix(IN_ZIP)
			var exists: bool = _zip != null and _zip_entries.has(file) and not _zip_entries[file].directory
			var size: int = _zip_entries[file].size if exists else 0
			_zip_lock.unlock()
			if not exists:
				return "The source file %s is missing from the opened ZIP." % file
			if size > MAX_FILE_SIZE:
				return "The ZIP file %s exceeds the reader's limit of less than 2 GiB." % file
		else:
			var handle := FileAccess.open(source, FileAccess.READ)
			if handle == null:
				return "Couldn't read %s." % source
			var length := handle.get_length()
			handle.close()
			if length > MAX_FILE_SIZE:
				return "%s must be smaller than 2 GiB to reopen it with the ZIP reader." % source.get_file()
	for value in plan.generated.values():
		var length: int = value if value is int else value.size()
		if length < 0 or length > MAX_FILE_SIZE:
			return "Every file in the ZIP must be smaller than 2 GiB."
	return ""



func label_problems(model: Model) -> String:
	for label in model.labels:
		if label.text.strip_edges().is_empty():
			return "A label of %s has no text." % model.name
		if not label.position.is_finite() or not is_finite(label.radius) or label.radius < 0.0:
			return "A label needs a finite position and a nonnegative radius."
		var frames := model.label_frames(label)
		if frames.y < frames.x:
			return "The label %s shows at none of %s's frames." % [label.title(), model.name]
	return ""


## Plan all entries before writing so attachments cannot collide with generated names.
func _plan() -> Dictionary:
	var manifest := {title = title, models = []}
	var generated := {}
	var seen := {Meta.MANIFEST.to_lower(): true}
	var plan := {manifest = manifest, sources = {}, generated = generated, error = ""}
	for model in models:
		var model_folder := "%s/%s" % [MODELS_FOLDER, _folder(model.name)]
		var entry := {name = model.name, parts = [], fields = []}
		var flat := not model.legacy_times.is_empty()
		if flat:
			manifest.frames = []
			for time in model.legacy_times:
				manifest.frames.append({time = time})
			manifest.fields = entry.fields
		for part in model.parts:
			var path := "%s/parts/%s" % [model_folder, _folder(part.name)]
			if part.changes():
				for step in part.files.size():
					_plan_file(plan, seen, "%s/%04d.glb" % [path, step + 1], part.files[step])
				entry.parts.append({name = part.name, path = path, times = Array(part.times)})
			else:
				_plan_file(plan, seen, path + ".glb", part.files[0])
				entry.parts.append({name = part.name, path = path + ".glb"})
		for field in model.fields:
			var path := "%s/fields/%s" % [model_folder, _folder(field.name)]
			var times: Array = range(model.legacy_times.size()) if flat else field.bricks.keys()
			times.sort()
			if field.untimed:
				path += ".bin"
				_plan_file(plan, seen, path, field.bricks[times[0]])
			else:
				for step in times.size():
					var file := "%s/%04d.bin" % [path, step + 1]
					_plan_file(plan, seen, file, field.bricks.get(times[step], ""))
					if not field.bricks.has(times[step]):
						generated[file] = ScalarData.cell_count(field.cells)
			entry.fields.append({
				name = field.name,
				quantity = field.quantity,
				unit = field.unit,
				range = [field.range.x, field.range.y],
				cells = [field.cells.x, field.cells.y, field.cells.z],
				box = {origin = _array(field.origin), size = _array(field.size), axes = [_array(field.axes.x), _array(field.axes.y), _array(field.axes.z)]},
				path = path,
			})
			if not flat and not field.untimed:
				entry.fields[-1].times = times
		if not model.fields.is_empty():
			entry.field = model.fields[clampi(model.first_field, 0, model.fields.size() - 1)].name
		var frame_count := model.times().size()
		if not model.labels.is_empty():
			entry.labels = []
		for label in model.labels:
			var label_entry := {text = label.text.strip_edges(), position = _array(label.position)}
			if label.radius > 0.0:
				label_entry.radius = label.radius
			var frames := model.label_frames(label)
			if frames != Vector2i(0, frame_count - 1):
				label_entry.frames = [frames.x + 1, frames.y + 1]
			entry.labels.append(label_entry)
		if flat:
			for part: Dictionary in entry.parts:
				manifest.models.append({name = part.name, path = part.path})
			if entry.has("field"):
				manifest.field = entry.field
		else:
			manifest.models.append(entry)
	if not notes.is_empty():
		_plan_file(plan, seen, notes_path, "")
		generated[notes_path] = notes.to_utf8_buffer()
		manifest.notes = notes_path
	for name: String in images:
		_plan_file(plan, seen, notes_path.get_base_dir().path_join(IMAGES_FOLDER).path_join(name), images[name])
	if not attachments.is_empty():
		manifest.attachments = []
		for file: String in attachments:
			_plan_file(plan, seen, file, attachments[file])
			manifest.attachments.append(file)
	generated[Meta.MANIFEST] = JSON.stringify(manifest, "\t", true, true).to_utf8_buffer()
	return plan


static func _plan_file(plan: Dictionary, seen: Dictionary, file: String, source: String) -> void:
	if not plan.error.is_empty():
		return
	if not Meta.is_file_path(file):
		plan.error = "The ZIP path %s is invalid." % file
		return
	var key := file.to_lower()
	if seen.has(key):
		plan.error = "Two files would be saved as %s. Rename or remove one before saving." % file
		return
	# A file must not also be the parent folder of another entry.
	for other: String in seen:
		if key.begins_with(other + "/") or other.begins_with(key + "/"):
			plan.error = "The ZIP path %s conflicts with another file." % file
			return
	seen[key] = true
	if not source.is_empty():
		plan.sources[file] = source


## Writes beside the target and replaces it only after every entry has succeeded.
func save(target: String) -> String:
	var error := problems()
	if not error.is_empty():
		return error
	var plan := _plan()
	var temporary := "%s.%d.%d%s" % [target, get_instance_id(), Time.get_ticks_usec(), TEMPORARY_SUFFIX]
	var packer := ZIPPacker.new()
	if packer.open(temporary) != OK:
		return "Couldn't write %s." % target
	for file: String in plan.sources:
		error = _store_source(packer, file, plan.sources[file])
		if not error.is_empty():
			break
	if error.is_empty():
		for file: String in plan.generated:
			var value = plan.generated[file]
			var bytes := PackedByteArray()
			if value is int:
				bytes.resize(value)
			else:
				bytes = value
			if _store(packer, file, bytes) != OK:
				error = "Couldn't write %s into the ZIP." % file
				break
	var finish := packer.close()
	if error.is_empty() and finish != OK:
		error = "Couldn't finish writing the ZIP."
	if error.is_empty():
		var check := Meta.new()
		error = check.open(temporary)
		check.close()
	if not error.is_empty():
		DirAccess.remove_absolute(temporary)
		return error

	# Some platforms cannot replace an open file. If replacement fails, reopen
	# the original reader without changing any of the user's edits.
	var previous := _zip_path
	close()
	if _replace_zip(temporary, target) != OK:
		_restore_reader(previous)
		DirAccess.remove_absolute(temporary)
		return "Couldn't replace %s. The previous ZIP was kept." % target
	return open(target)


func _restore_reader(path: String) -> void:
	if path.is_empty():
		return
	var reader := ZIPReader.new()
	if reader.open(path) == OK:
		_zip_lock.lock()
		_zip = reader
		_zip_lock.unlock()


func _replace_zip(temporary: String, target: String) -> Error:
	return DirAccess.rename_absolute(temporary, target)


## Local files are streamed, so adding a large vector file does not load it all.
func _store_source(packer: ZIPPacker, file: String, source: String) -> String:
	if source.begins_with(IN_ZIP):
		_zip_lock.lock()
		var path := source.trim_prefix(IN_ZIP)
		var found: bool = _zip != null and _zip_entries.has(path) and not _zip_entries[path].directory
		var size: int = _zip_entries[path].size if found else 0
		var bytes := _zip.read_file(path) if found and size <= MAX_FILE_SIZE else PackedByteArray()
		_zip_lock.unlock()
		if not found or size > MAX_FILE_SIZE or bytes.size() != size:
			return "Couldn't read all of %s. The ZIP may be damaged or the file too large." % path
		return "" if _store(packer, file, bytes) == OK else "Couldn't write %s into the ZIP." % file
	var handle := FileAccess.open(source, FileAccess.READ)
	if handle == null:
		return "Couldn't read %s." % source
	var remaining := handle.get_length()
	if remaining > MAX_FILE_SIZE:
		handle.close()
		return "%s must be smaller than 2 GiB." % source.get_file()
	var result := packer.start_file(file)
	while result == OK and remaining > 0:
		var count := mini(COPY_CHUNK, remaining)
		var bytes := handle.get_buffer(count)
		if bytes.size() != count:
			result = ERR_FILE_CANT_READ
			break
		result = packer.write_file(bytes)
		remaining -= count
	handle.close()
	var end := packer.close_file()
	return "" if result == OK and end == OK else "Couldn't copy %s into the ZIP." % source


static func _folder(name: String) -> String:
	return name.strip_edges().validate_filename()


func _store(packer: ZIPPacker, file: String, bytes: PackedByteArray) -> Error:
	var error := packer.start_file(file)
	if error != OK:
		return error
	error = packer.write_file(bytes)
	var finish := packer.close_file()
	return error if error != OK else finish


static func _array(vector: Vector3) -> Array:
	return [vector.x, vector.y, vector.z]
