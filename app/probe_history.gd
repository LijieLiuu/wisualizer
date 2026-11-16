extends "res://app/field_analysis.gd"
## Worker-compatible history of committed A/B points. Each frame is decoded
## independently; solver times retain archive order, including repeated times.
## Sessions contain locations and source identity, never authoritative readings.

const SESSION_VERSION := 1
const IDENTITY_ALGORITHM := "zip-index-crc32-v1"
const MAX_SESSION_BYTES := 65536
const HISTORY_COLUMNS := ["source_zip", "source_identity", "field", "quantity", "unit", "frame", "solver_time", "source_file", "a_u", "a_v", "a_w", "a_cell_x", "a_cell_y", "a_cell_z", "a_byte", "a_valid", "a_value", "b_u", "b_v", "b_w", "b_cell_x", "b_cell_y", "b_cell_z", "b_byte", "b_valid", "b_value", "b_minus_a"]

## Uses the already-opened metadata and cached ZIP index, without inflating
## bricks or scanning the archive. The digest is a change detector based on
## ZIP CRCs, not a cryptographic assertion about the archive's provenance.
static func snapshot(meta: RefCounted, field_index: int) -> Dictionary:
	if field_index < 0 or field_index >= meta.fields.size():
		return {error = "Choose a scalar field before analyzing probes.", identity = {}}
	var field: Meta.Field = meta.fields[field_index]
	var entries := []
	var names: Array = meta.entries.keys()
	names.sort()
	for name in names:
		var entry: Dictionary = meta.entries[name]
		if not entry.has("crc32"):
			return {error = "The ZIP index does not contain checksums. Reopen the document with the current application.", identity = {}}
		entries.append([name, entry.size, entry.crc32, entry.directory])
	var payload := {entries = entries, field_index = field_index, name = field.name,
		quantity = field.quantity, unit = field.unit, range = [field.range.x, field.range.y],
		cells = [field.cells.x, field.cells.y, field.cells.z], files = Array(field.files),
		times = Array(meta.times), box = []}
	for vector in [field.box.basis.x, field.box.basis.y, field.box.basis.z, field.box.origin]:
		payload.box.append([vector.x, vector.y, vector.z])
	return {error = "", identity = {algorithm = IDENTITY_ALGORITHM,
		digest = JSON.stringify(payload, "", true, true).sha256_text(), field_index = field_index}}


func analyze(zip_path: String, field_index: int, points: Dictionary, expected_identity: Dictionary,
		canceled: Callable = Callable(), progress: Callable = Callable()) -> Dictionary:
	var checked := _checked_points(points)
	if not checked.error.is_empty():
		return _failure(checked.error)
	if not _valid_identity(expected_identity) or expected_identity.field_index != field_index:
		return _failure("The source snapshot is invalid. Reopen the document before analyzing.")
	if _is_canceled(canceled):
		return _failure("Probe history canceled.", true)
	var source := _canonical_path(zip_path)
	if not source.error.is_empty():
		return _failure(source.error)
	var meta := Meta.new()
	var error := meta.open(source.path)
	if error.is_empty():
		error = _matches(meta, field_index, expected_identity)
	if not error.is_empty():
		meta.close()
		return _failure(error)
	var field: Meta.Field = meta.fields[field_index]
	var cells := {}
	for slot in checked.points:
		var cell := _cell(checked.points[slot], field.cells)
		if cell.x < 0:
			meta.close()
			return _failure("A probe location cannot be represented in this grid.")
		cells[slot] = cell
	var result := {error = "", canceled = false, source = source.path,
		identity = expected_identity.duplicate(true), field_index = field_index,
		field = field.name, quantity = field.quantity, unit = field.unit,
		points = checked.points, cells = cells, rows = []}
	for frame in meta.times.size():
		if _is_canceled(canceled):
			meta.close()
			return _failure("Probe history canceled.", true)
		var path: String = field.files[frame]
		var loaded := meta.read_checked(path)
		if not loaded.error.is_empty():
			meta.close()
			return _failure("Frame %d: %s" % [frame + 1, loaded.error])
		error = ScalarData.validate(loaded.bytes, field.range, field.cells)
		if not error.is_empty():
			meta.close()
			return _failure("Frame %d: %s" % [frame + 1, error])
		# ZIPReader verifies the inflated data's CRC before returning it; Meta
		# additionally verifies its exact size. Avoid a second GDScript pass
		# over a large brick. Native decompression cannot be interrupted, so
		# cancellation is checked immediately on both sides of the read.
		if _is_canceled(canceled):
			meta.close()
			return _failure("Probe history canceled.", true)
		var row := {frame = frame + 1, solver_time = meta.times[frame], source_file = path,
			a_byte = null, b_byte = null, a = null, b = null, delta = null}
		for slot in cells:
			var cell: Vector3i = cells[slot]
			var offset := cell.x + field.cells.x * (cell.y + field.cells.y * cell.z)
			var byte: int = loaded.bytes[offset]
			var name := "a" if slot == 0 else "b"
			row[name + "_byte"] = byte
			row[name] = null if byte == 0 else field.value_of(byte)
		if row.a != null and row.b != null:
			row.delta = float(row.b) - float(row.a)
		result.rows.append(row)
		# No brick is retained in results or across reads.
		loaded.clear()
		if progress.is_valid():
			progress.call(frame + 1, meta.times.size())
	meta.close()
	if _is_canceled(canceled):
		return _failure("Probe history canceled.", true)
	error = _verify_source(source.path, field_index, expected_identity)
	return result if error.is_empty() else _failure(error)


## Export only a successful result, preserving the old output until writing,
## flushing, source verification, and cancellation checks all succeed.
func export_csv(result: Dictionary, target: String, canceled: Callable = Callable(),
		protected: PackedStringArray = PackedStringArray()) -> String:
	var error := _result_error(result)
	if not error.is_empty():
		return error
	if _is_canceled(canceled):
		return "Probe history export canceled."
	error = _verify_source(result.source, result.field_index, result.identity)
	if not error.is_empty():
		return error
	var sources := protected.duplicate()
	sources.append(result.source)
	var destination := _probe_destination(target, sources)
	if not destination.error.is_empty():
		return destination.error
	var temporary := _temporary_path(destination.path)
	if temporary.is_empty():
		return "Couldn't create a unique probe-history temporary file."
	var output := FileAccess.open(temporary, FileAccess.WRITE)
	if output == null:
		return "Couldn't write probe history beside %s." % destination.path
	if _write_row(output, PackedStringArray(HISTORY_COLUMNS)) != OK:
		error = "Couldn't write the probe-history header."
	for row in result.rows:
		if not error.is_empty():
			break
		if _is_canceled(canceled):
			error = "Probe history export canceled."
			break
		var columns := PackedStringArray([result.source, result.identity.digest, result.field,
			result.quantity, result.unit, str(row.frame), _number(row.solver_time), row.source_file])
		for slot in [0, 1]:
			if result.points.has(slot):
				var point: Vector3 = result.points[slot]
				var cell: Vector3i = result.cells[slot]
				columns.append_array(PackedStringArray([_number(point.x), _number(point.y), _number(point.z), str(cell.x), str(cell.y), str(cell.z)]))
			else:
				columns.append_array(PackedStringArray(["", "", "", "", "", ""]))
			var name := "a" if slot == 0 else "b"
			columns.append(_number(row[name + "_byte"]))
			columns.append(_number(null if row[name + "_byte"] == null else row[name + "_byte"] != 0))
			columns.append(_number(row[name]))
		columns.append(_number(row.delta))
		if _write_row(output, columns) != OK:
			error = "Couldn't write probe history for frame %d." % row.frame
	return _finish_output(output, temporary, destination.path, error,
		result.source, result.field_index, result.identity, canceled)


## The caller supplies committed points, never a live gesture candidate.
## This small JSON operation may run synchronously against an open Meta.
func save_session(meta: RefCounted, field_index: int, points: Dictionary, zip_path: String,
		target: String, canceled: Callable = Callable()) -> String:
	var checked := _checked_points(points)
	if not checked.error.is_empty():
		return checked.error
	var captured := snapshot(meta, field_index)
	if not captured.error.is_empty():
		return captured.error
	var source := _canonical_path(zip_path)
	if not source.error.is_empty():
		return source.error
	if _is_canceled(canceled):
		return "Probe session save canceled."
	var error := _verify_source(source.path, field_index, captured.identity)
	if not error.is_empty():
		return error
	var destination := _probe_destination(target, PackedStringArray([source.path]))
	if not destination.error.is_empty():
		return destination.error
	var stored_points := {}
	for slot in checked.points:
		var point: Vector3 = checked.points[slot]
		stored_points[str(slot)] = [point.x, point.y, point.z]
	var session := {version = SESSION_VERSION, source = source.path, field_index = field_index,
		identity = captured.identity, points = stored_points}
	var temporary := _temporary_path(destination.path)
	if temporary.is_empty():
		return "Couldn't create a unique probe-session temporary file."
	var output := FileAccess.open(temporary, FileAccess.WRITE)
	if output == null:
		return "Couldn't write the probe session beside %s." % destination.path
	if _write_session(output, JSON.stringify(session, "\t", true, true) + "\n") != OK:
		error = "Couldn't write the probe session."
	return _finish_output(output, temporary, destination.path, error,
		source.path, field_index, captured.identity, canceled)


## Validate all fields before returning any points. Readings are recomputed
## from the current package after restoration; JSON never supplies values.
func restore_session(path: String, meta: RefCounted, zip_path: String) -> Dictionary:
	var failed := {error = "", field_index = -1, points = {}, source_session = ""}
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		failed.error = "Couldn't open the probe session."
		return failed
	if file.get_length() > MAX_SESSION_BYTES:
		file.close()
		failed.error = "The probe session is too large."
		return failed
	var data := file.get_buffer(file.get_length())
	var complete := file.get_position() == file.get_length()
	file.close()
	var parser := JSON.new()
	var parse_error := parser.parse(data.get_string_from_utf8())
	var parsed: Variant = parser.data
	if not complete or parse_error != OK or not parsed is Dictionary:
		failed.error = "The probe session is not valid JSON."
		return failed
	var session: Dictionary = parsed
	if session.size() != 5 or not _integer(session.get("version")) or session.get("version") != SESSION_VERSION or not session.get("source") is String \
			or not _integer(session.get("field_index")) or not session.get("identity") is Dictionary or not session.get("points") is Dictionary:
		failed.error = "The probe session schema or version is unsupported."
		return failed
	var index := int(session.field_index)
	if not _valid_identity(session.identity) or int(session.identity.field_index) != index:
		failed.error = "The probe session has an invalid source identity."
		return failed
	var points := {}
	for key in session.points:
		var value: Variant = session.points[key]
		if key not in ["0", "1"] or not value is Array or value.size() != 3:
			failed.error = "The probe session has an invalid A/B location."
			return failed
		for number in value:
			if not ScalarData.is_finite_number(number) or float(number) < 0.0 or float(number) >= 1.0:
				failed.error = "Probe session locations must be finite and inside the field."
				return failed
		points[int(key)] = Vector3(value[0], value[1], value[2])
	var checked := _checked_points(points)
	if not checked.error.is_empty():
		failed.error = checked.error
		return failed
	var source := _canonical_path(zip_path)
	var saved_source := _canonical_path(session.source)
	if not source.error.is_empty() or not saved_source.error.is_empty() or _path_key(source.path) != _path_key(saved_source.path):
		failed.error = "This probe session belongs to a different source ZIP."
		return failed
	var error := _matches(meta, index, session.identity)
	if error.is_empty():
		error = _verify_source(source.path, index, session.identity)
	if not error.is_empty():
		failed.error = error
		return failed
	var session_path := _canonical_path(path)
	if not session_path.error.is_empty():
		failed.error = session_path.error
		return failed
	return {error = "", field_index = index, points = checked.points, source_session = session_path.path}


func _finish_output(output: FileAccess, temporary: String, target: String, error: String,
		source: String, field_index: int, identity: Dictionary, canceled: Callable) -> String:
	if error.is_empty() and _flush(output) != OK:
		error = "Couldn't finish writing the probe output."
	output.close()
	if error.is_empty() and _is_canceled(canceled):
		error = "Probe output canceled. The previous file was kept."
	if error.is_empty():
		error = _verify_source(source, field_index, identity)
	if error.is_empty() and _is_canceled(canceled):
		error = "Probe output canceled. The previous file was kept."
	if error.is_empty() and _replace_file(temporary, target) != OK:
		error = "Couldn't replace %s. The previous file was kept." % target
	if not error.is_empty():
		DirAccess.remove_absolute(temporary)
	return error


func _write_session(file: FileAccess, text: String) -> Error:
	file.store_string(text)
	return file.get_error()


static func _probe_destination(target: String, protected: PackedStringArray) -> Dictionary:
	var result := _destination(target, protected)
	result.error = result.error.replace("Choose a statistics output file.", "Choose an output file.").replace("Choose a CSV file, not a directory.", "Choose an output file, not a directory.").replace("Statistics cannot replace", "Probe output cannot replace")
	return result


static func _temporary_path(target: String) -> String:
	var temporary := target + ".%d.%s.tmp" % [OS.get_process_id(), Crypto.new().generate_random_bytes(12).hex_encode()]
	return "" if FileAccess.file_exists(temporary) or DirAccess.dir_exists_absolute(temporary) else temporary


static func _matches(meta: RefCounted, field_index: int, identity: Dictionary) -> String:
	var current := snapshot(meta, field_index)
	if not current.error.is_empty():
		return current.error
	if not _valid_identity(identity):
		return "The source identity is invalid."
	var same: bool = current.identity.algorithm == identity.algorithm and current.identity.digest == identity.digest and int(current.identity.field_index) == int(identity.field_index)
	return "" if same else "The source ZIP has changed. Reopen it and place or restore probes again."


static func _verify_source(path: String, field_index: int, identity: Dictionary) -> String:
	var meta := Meta.new()
	var error := meta.open(path)
	if error.is_empty():
		error = _matches(meta, field_index, identity)
	meta.close()
	return error


static func _is_canceled(canceled: Callable) -> bool:
	return canceled.is_valid() and bool(canceled.call())


static func _failure(message: String, canceled: bool = false) -> Dictionary:
	return {error = message, canceled = canceled, rows = [], points = {}, cells = {}}


static func _integer(value: Variant) -> bool:
	return ScalarData.is_finite_number(value) and float(value) == floor(float(value))


static func _valid_identity(identity: Dictionary) -> bool:
	return identity.size() == 3 and identity.get("algorithm") == IDENTITY_ALGORITHM \
		and identity.get("digest") is String and identity.digest.length() == 64 \
		and _integer(identity.get("field_index")) and identity.field_index >= 0


static func _checked_points(points: Dictionary) -> Dictionary:
	if points.is_empty():
		return {error = "Pin at least one probe before continuing.", points = {}}
	var copy := {}
	for slot in points:
		var point: Variant = points[slot]
		if not slot is int or slot not in [0, 1] or not point is Vector3 or not point.is_finite() \
				or point.x < 0.0 or point.y < 0.0 or point.z < 0.0 or point.x >= 1.0 or point.y >= 1.0 or point.z >= 1.0:
			return {error = "Probe locations must be A/B points inside the field.", points = {}}
		copy[slot] = point
	return {error = "", points = copy}


static func _cell(point: Vector3, grid: Vector3i) -> Vector3i:
	var cell := Vector3i((point * Vector3(grid)).floor())
	return cell if cell.x >= 0 and cell.y >= 0 and cell.z >= 0 and cell.x < grid.x and cell.y < grid.y and cell.z < grid.z else Vector3i(-1, -1, -1)


static func _result_error(result: Dictionary) -> String:
	if result.get("error", "invalid") != "" or result.get("canceled", true) or not result.get("rows") is Array or result.rows.is_empty():
		return "Analyze committed probes successfully before exporting history."
	for key in ["source", "field", "quantity", "unit"]:
		if not result.get(key) is String:
			return "The probe history has invalid source metadata."
	if not result.get("identity") is Dictionary or not _valid_identity(result.identity) or not _integer(result.get("field_index")) or result.field_index != result.identity.field_index:
		return "The probe history has an invalid source identity."
	if not result.get("points") is Dictionary or not result.get("cells") is Dictionary:
		return "The probe history has invalid locations."
	if not _checked_points(result.points).error.is_empty() or result.points.size() != result.cells.size():
		return "The probe history has invalid locations."
	for slot in result.points:
		if not result.cells.get(slot) is Vector3i:
			return "The probe history has invalid cells."
	for index in result.rows.size():
		var row: Variant = result.rows[index]
		if not row is Dictionary or row.get("frame") != index + 1 or not ScalarData.is_finite_number(row.get("solver_time")) or not row.get("source_file") is String:
			return "The probe history has an invalid frame."
		for slot in [0, 1]:
			var name := "a" if slot == 0 else "b"
			if not row.has(name) or not row.has(name + "_byte"):
				return "The probe history is missing a reading."
			var byte: Variant = row[name + "_byte"]
			if result.points.has(slot):
				if not _integer(byte) or byte < 0 or byte > 255 or (byte == 0 and row[name] != null) or (byte > 0 and not ScalarData.is_finite_number(row[name])):
					return "The probe history has an invalid reading."
			elif byte != null or row[name] != null:
				return "An unplaced probe cannot contain readings."
		if not row.has("delta") or (row.a == null or row.b == null) and row.delta != null:
			return "The probe history has an invalid difference."
		if row.a != null and row.b != null and (not ScalarData.is_finite_number(row.delta) or row.delta != float(row.b) - float(row.a)):
			return "The probe history has an invalid difference."
	return ""
