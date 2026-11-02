extends RefCounted
## Summarizes decoded scalar byte samples, excluding byte 0 as missing.
## Values describe the exported, quantized samples; they are not solver validation.

const Meta := preload("res://app/meta.gd")
const ScalarData := preload("res://app/scalar_data.gd")
const COLUMNS := ["field", "quantity", "unit", "frame", "solver_time", "source_file", "valid_count", "missing_count", "min", "max", "mean"]


static func summarize(data: PackedByteArray, value_range: Vector2, cells: Vector3i) -> Dictionary:
	var error: String = ScalarData.validate(data, value_range, cells)
	var result := {error = error, valid_count = 0, missing_count = 0, min = null, max = null, mean = null}
	if not error.is_empty():
		return result
	var histogram := PackedInt64Array()
	histogram.resize(256)
	for byte in data:
		histogram[byte] += 1
	result.missing_count = histogram[0]
	result.valid_count = data.size() - histogram[0]
	if result.valid_count == 0:
		return result
	var first := 0
	var last := 0
	var weighted_sum: int = 0
	for byte in range(1, 256):
		if histogram[byte] == 0:
			continue
		if first == 0:
			first = byte
		last = byte
		weighted_sum += byte * histogram[byte]
	result.min = _decode(float(first), value_range)
	result.max = _decode(float(last), value_range)
	# The byte sum is exact for supported brick sizes. Decode only once, avoiding
	# repeated summation of large physical values or cancellation between them.
	result.mean = _decode(float(weighted_sum) / float(result.valid_count), value_range)
	return result


static func _decode(byte: float, value_range: Vector2) -> float:
	if value_range.x == value_range.y:
		return float(value_range.x)
	var weight := (byte - 1.0) / 254.0
	return float(value_range.x) * (1.0 - weight) + float(value_range.y) * weight


## Export the current in-memory workspace without saving or mutating its ZIP.
## The workspace keeps edits locked while this synchronous method runs on a worker.
func export_draft(draft, target: String) -> String:
	var protected: PackedStringArray = draft.source_files()
	var zip_path: String = draft.source_zip_path()
	if not zip_path.is_empty():
		protected.append(zip_path)
	return _export(draft.fields, draft.times,
		func(field, frame: int) -> Dictionary: return draft.read_brick_checked(field, frame),
		func(field, frame: int) -> String: return str(field.bricks.get(frame, "")).trim_prefix("zip://"),
		target, protected)


## Export an existing package, reading at most one scalar frame at a time.
func export_zip(zip_path: String, target: String) -> String:
	var meta := Meta.new()
	var error: String = meta.open(zip_path)
	if not error.is_empty():
		meta.close()
		return error
	error = _export(meta.fields, meta.times,
		func(field, frame: int) -> Dictionary: return meta.read_checked(field.files[frame]),
		func(field, frame: int) -> String: return field.files[frame],
		target, PackedStringArray([zip_path]))
	meta.close()
	return error


func _export(fields: Array, times: PackedFloat64Array, read: Callable, source: Callable, target: String, protected: PackedStringArray) -> String:
	if fields.is_empty():
		return "Add a scalar field before exporting statistics."
	if times.is_empty():
		return "Add a frame before exporting statistics."
	for time in times:
		if not is_finite(time):
			return "Every solver time must be finite."
	for field in fields:
		var problem: String = ScalarData.validate_metadata(field.range, field.cells)
		if not problem.is_empty():
			return "%s: %s" % [field.name, problem]
	var destination := _destination(target, protected)
	if not destination.error.is_empty():
		return destination.error
	var output_path: String = destination.path
	var temporary := output_path + ".%d.%s.tmp" % [OS.get_process_id(), Crypto.new().generate_random_bytes(12).hex_encode()]
	if FileAccess.file_exists(temporary) or DirAccess.dir_exists_absolute(temporary):
		return "Couldn't create a unique statistics temporary file."
	var output := FileAccess.open(temporary, FileAccess.WRITE)
	if output == null:
		return "Couldn't write statistics beside %s." % output_path
	var error := ""
	if _write_row(output, PackedStringArray(COLUMNS)) != OK:
		error = "Couldn't write the statistics header."
	for field in fields:
		if not error.is_empty():
			break
		for frame in times.size():
			var loaded: Dictionary = read.call(field, frame)
			if not loaded.error.is_empty():
				error = "%s, frame %d: %s" % [field.name, frame + 1, loaded.error]
				break
			var summary := summarize(loaded.bytes, field.range, field.cells)
			# Release this frame before reading the next one.
			loaded.clear()
			if not summary.error.is_empty():
				error = "%s, frame %d: %s" % [field.name, frame + 1, summary.error]
				break
			var row := PackedStringArray([str(field.name), str(field.quantity), str(field.unit), str(frame + 1),
				_number(times[frame]), str(source.call(field, frame)), str(summary.valid_count), str(summary.missing_count),
				_number(summary.min), _number(summary.max), _number(summary.mean)])
			if _write_row(output, row) != OK:
				error = "Couldn't write statistics for %s, frame %d." % [field.name, frame + 1]
				break
	if error.is_empty() and _flush(output) != OK:
		error = "Couldn't finish writing the statistics file."
	output.close()
	if not error.is_empty():
		DirAccess.remove_absolute(temporary)
		return error
	if _replace_file(temporary, output_path) != OK:
		DirAccess.remove_absolute(temporary)
		return "Couldn't replace %s. The previous file was kept." % output_path
	return ""


## Seams used by failure tests; production writes and replaces real files.
func _write_row(file: FileAccess, values: PackedStringArray) -> Error:
	var escaped := PackedStringArray()
	for value in values:
		if "," in value or '"' in value or "\n" in value or "\r" in value:
			value = '"' + value.replace('"', '""') + '"'
		escaped.append(value)
	file.store_string(",".join(escaped) + "\r\n")
	return file.get_error()


func _flush(file: FileAccess) -> Error:
	file.flush()
	return file.get_error()


func _replace_file(temporary: String, target: String) -> Error:
	return DirAccess.rename_absolute(temporary, target)


static func _number(value: Variant) -> String:
	# Full precision retains the double's round-trip digits, including solver times.
	return "" if value == null else JSON.stringify(value, "", true, true)


static func _destination(target: String, protected: PackedStringArray) -> Dictionary:
	var result := _canonical_path(target)
	if not result.error.is_empty():
		return result
	if DirAccess.dir_exists_absolute(result.path):
		return {path = "", error = "Choose a CSV file, not a directory."}
	var key := _path_key(result.path)
	for source in protected:
		if source.is_empty() or source.begins_with("zip://"):
			continue
		var resolved := _canonical_path(source)
		if not resolved.error.is_empty():
			return {path = "", error = "Couldn't resolve a source file safely: %s." % source}
		if _path_key(resolved.path) == key:
			return {path = "", error = "Choose a different destination. Statistics cannot replace a source ZIP or source file."}
	return result


static func _path_key(path: String) -> String:
	# Conservatively protect aliases on the usual case-insensitive desktop volumes.
	return path.to_lower() if OS.has_feature("macos") or OS.has_feature("windows") else path


## Resolve file and parent-directory symlinks before comparing or writing paths.
## Relative links are interpreted beside the link, not beside the process.
static func _canonical_path(path: String) -> Dictionary:
	if path.is_empty():
		return {path = "", error = "Choose a statistics output file."}
	var expanded := ProjectSettings.globalize_path(path)
	if not expanded.is_absolute_path():
		var working := DirAccess.open(".")
		if working == null:
			return {path = "", error = "Couldn't resolve the current directory."}
		expanded = working.get_current_dir().path_join(expanded)
	for _attempt in 32:
		var parts := expanded.split("/", false)
		var current := "/"
		if not expanded.begins_with("/"):
			current = parts[0] + "/"
			parts.remove_at(0)
		var followed := false
		for index in parts.size():
			var part: String = parts[index]
			if part == ".":
				continue
			if part == "..":
				current = current.get_base_dir()
				continue
			var parent := DirAccess.open(current)
			if parent == null:
				return {path = "", error = "The output or source folder is unavailable: %s." % current}
			if parent.is_link(part):
				var link := parent.read_link(part)
				if link.is_empty():
					return {path = "", error = "Couldn't resolve the file link: %s." % current.path_join(part)}
				expanded = link if link.is_absolute_path() else current.path_join(link)
				if index + 1 < parts.size():
					expanded = expanded.path_join("/".join(parts.slice(index + 1)))
				followed = true
				break
			current = current.path_join(part)
		if not followed:
			return {path = current.simplify_path(), error = ""}
	return {path = "", error = "The selected path contains a file-link loop."}
