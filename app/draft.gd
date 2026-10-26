extends RefCounted
## What the workspace edits: the contents of a ZIP, as the workspace builds
## them up from files on disk and from the ZIP it was opened from, until
## they are saved as a ZIP; see docs/zip-format.md.
##
## Each GLB, brick and image is a source: a path on disk, or a path in the
## opened ZIP with the [constant IN_ZIP] prefix. Sources are copied as they
## are when the draft is saved; nothing is decoded.

const Meta := preload("res://app/meta.gd")
const GLBInfo := preload("res://app/glb_info.gd")
const BOV := preload("res://app/bov.gd")
const NotesImages := preload("res://app/notes_images.gd")
const IN_ZIP := "zip://"
const NOTES_FILE := "notes.txt"
const IMAGES_FOLDER := "images"
const ATTACHMENTS_FOLDER := "attachments"
const COPY_CHUNK := 1 << 20
## ZIPReader returns a PackedByteArray; keep saved files readable on reopen.
const MAX_FILE_SIZE := 0x7fffffff
## Saving writes beside the target first, so a failure leaves the old ZIP.
const TEMPORARY_SUFFIX := ".saving"


class Model:
	var name := ""
	## One source, shown at every frame, or one per frame.
	var files := PackedStringArray()

	func changes() -> bool:
		return files.size() > 1


class Field:
	var name := ""
	var quantity := ""
	var unit := ""
	var range := Vector2(0.0, 1.0)
	var cells := Vector3i.ZERO
	var origin := Vector3.ZERO
	var size := Vector3.ONE
	var axes := Basis()
	## The brick source at each frame that has one.
	var bricks := {}


var title := ""
var times := PackedFloat64Array()
## A provisional single frame created by importing a static model.
var auto_frame := false
var models: Array[Model] = []
var fields: Array[Field] = []
var first_field := 0
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
## Model bounds by GLB source, once read.
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
		for file in entry.files:
			used[file] = true
	for entry in meta.fields:
		for file in entry.files:
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
	times = meta.times.duplicate()
	auto_frame = false
	models = []
	fields = []
	images = {}
	attachments = {}
	_bounds.clear()
	for entry in meta.models:
		var model := Model.new()
		model.name = entry.name
		# A model shown at every frame has the same file at each.
		var files := entry.files if entry.files.count(entry.files[0]) < entry.files.size() else PackedStringArray([entry.files[0]])
		for file in files:
			model.files.append(IN_ZIP + file)
		models.append(model)
	for entry in meta.fields:
		var field := Field.new()
		field.name = entry.name
		field.quantity = entry.quantity
		field.unit = entry.unit
		field.range = entry.range
		field.cells = entry.cells
		field.origin = entry.box.origin
		field.size = entry.box.basis.get_scale()
		field.axes = entry.box.basis.orthonormalized()
		for frame in entry.files.size():
			# Preserve every source brick, including explicit all-zero frames.
			field.bricks[frame] = IN_ZIP + entry.files[frame]
		fields.append(field)
	first_field = meta.first_field
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


## Adds the GLBs at [param paths] as models. GLBs named alike but for a
## number, as EnSight writes one per time step, become one model with a GLB
## per frame; any other becomes a model shown at every frame. Without frames
## yet, the frames come from the GLBs' solver times. Returns an empty string,
## or what is wrong with the GLBs.
func add_glbs(paths: PackedStringArray) -> String:
	if paths.is_empty():
		return "Choose at least one GLB."
	var frame_times_candidate := PackedFloat64Array() if auto_frame else times.duplicate()
	var static_time := times[0] if not times.is_empty() else 0.0
	var groups := {}
	for file in paths:
		var stem := file.get_file().get_basename().rstrip("0123456789").rstrip("_-. ")
		if stem.is_empty():
			stem = file.get_file().get_basename()
		if not groups.has(stem):
			groups[stem] = PackedStringArray()
		groups[stem].append(file)
	var added: Array[Model] = []
	for stem: String in groups:
		var files: PackedStringArray = groups[stem]
		files.sort()
		var model := Model.new()
		model.name = stem
		var frame_times := PackedFloat64Array()
		for file in files:
			var json := GLBInfo.json(FileAccess.get_file_as_bytes(file))
			if json.is_empty():
				return "%s isn't a GLB." % file.get_file()
			if GLBInfo.scene_count(json) > 1:
				return "%s has a scene for each time step. Export a GLB for each time step instead." % file.get_file()
			var time := GLBInfo.time(json)
			frame_times.append(time if not is_nan(time) else frame_times.size())
			model.files.append(file)
		if model.changes():
			if frame_times_candidate.is_empty():
				frame_times_candidate = frame_times
			elif frame_times_candidate.size() != model.files.size():
				return "%s has %d GLBs, but there are %d frames." % [stem, model.files.size(), frame_times_candidate.size()]
		elif added.is_empty():
			static_time = frame_times[0]
		added.append(model)
	auto_frame = frame_times_candidate.is_empty()
	if auto_frame:
		frame_times_candidate.append(static_time)
	times = frame_times_candidate
	models.append_array(added)
	_bounds.clear()
	return ""


## Adds the bricks whose headers are at [param paths] as fields, one per
## variable. Without frames yet, the frames come from the bricks' solver
## times; otherwise each brick goes to the frame nearest its time. Returns an
## empty string, or what is wrong with the bricks.
func add_bovs(paths: PackedStringArray) -> String:
	var bovs := []
	for file in paths:
		var bov = BOV.read(file)
		if bov == null:
			return "%s isn't a brick header with its data beside it." % file.get_file()
		bovs.append(bov)
	if bovs.is_empty():
		return "Choose at least one brick header."
	if auto_frame:
		times = PackedFloat64Array()
		auto_frame = false
	if times.is_empty():
		var steps := {}
		for bov in bovs:
			steps[bov.time] = true
		times = PackedFloat64Array(steps.keys())
		times.sort()
	for bov in bovs:
		var field: Field = null
		for existing in fields:
			if existing.name == bov.variable:
				field = existing
		if field == null:
			field = Field.new()
			field.name = bov.variable
			field.range = bov.range
			field.cells = bov.cells
			field.origin = bov.origin
			field.size = bov.size
			field.axes = bov.axes
			fields.append(field)
			fit_field(field)
		elif field.cells != bov.cells:
			return "%s has %s cells, but %s has %s." % [bov.data.get_file(), bov.cells, field.name, field.cells]
		field.bricks[_nearest(bov.time)] = bov.data
	return ""


## Grows or shrinks [param field]'s box about its center until it spans
## the models along their longest side. EnSight doesn't say what scale it
## writes bricks at, and it isn't the geometry's: the Hall sensor's brick
## says it is 40 across, around a model 80 across. Does nothing without
## models.
func fit_field(field: Field) -> void:
	var bounds := model_bounds()
	if not bounds.has_volume():
		return
	var axis := bounds.size.max_axis_index()
	if field.size[axis] <= 0.0:
		return
	var scale := bounds.size[axis] / field.size[axis]
	var center := field.origin + field.size * 0.5
	field.size *= scale
	field.origin = center - field.size * 0.5


## The bounds of every model's first GLB, together.
func model_bounds() -> AABB:
	var bounds := AABB()
	for model in models:
		var source := model.files[0]
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
	if times.is_empty():
		return "Add a frame, or import GLBs or bricks that have solver times."
	if models.is_empty():
		return "Import a GLB."
	for model in models:
		if model.name.strip_edges().is_empty() or model.files.is_empty():
			return "A model needs a name and a GLB."
		if model.changes() and model.files.size() != times.size():
			return "%s has %d GLBs, but there are %d frames." % [model.name, model.files.size(), times.size()]
	for field in fields:
		if field.name.strip_edges().is_empty():
			return "A field has no name."
		if field.cells.x <= 0 or field.cells.y <= 0 or field.cells.z <= 0:
			return "%s has no cells." % field.name
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


## Plan archive names before writing, catching collisions across all file roles.
func _plan() -> Dictionary:
	var manifest := {title = title, frames = [], models = [], fields = []}
	var sources := {}
	var generated := {}
	var seen := {Meta.MANIFEST.to_lower(): true}
	var plan := {manifest = manifest, sources = sources, generated = generated, error = ""}
	for time in times:
		manifest.frames.append({time = time})
	for model in models:
		var folder := "models/%s" % _folder(model.name)
		if model.changes():
			for frame in model.files.size():
				_plan_file(plan, seen, "%s/%04d.glb" % [folder, frame + 1], model.files[frame])
			manifest.models.append({name = model.name, path = folder})
		else:
			if not model.files.is_empty():
				_plan_file(plan, seen, folder + ".glb", model.files[0])
			manifest.models.append({name = model.name, path = folder + ".glb"})
	for field in fields:
		var folder := "fields/%s" % _folder(field.name)
		for frame in times.size():
			var file := "%s/%04d.bin" % [folder, frame + 1]
			if field.bricks.has(frame):
				_plan_file(plan, seen, file, field.bricks[frame])
			else:
				_plan_file(plan, seen, file, "")
				# Store a length, allocating missing scalar bricks one at a time.
				generated[file] = field.cells.x * field.cells.y * field.cells.z
		manifest.fields.append({
			name = field.name, quantity = field.quantity, unit = field.unit,
			range = [field.range.x, field.range.y],
			cells = [field.cells.x, field.cells.y, field.cells.z],
			box = {origin = _array(field.origin), size = _array(field.size), axes = [_array(field.axes.x), _array(field.axes.y), _array(field.axes.z)]},
			path = folder,
		})
	if not fields.is_empty():
		manifest.field = fields[clampi(first_field, 0, fields.size() - 1)].name
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
	generated[Meta.MANIFEST] = JSON.stringify(manifest, "\t").to_utf8_buffer()
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


func _nearest(time: float) -> int:
	var best := 0
	for index in times.size():
		if absf(times[index] - time) < absf(times[best] - time):
			best = index
	return best


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
