extends SceneTree
## Independent scalar oracles and actual ZIP/CSV transaction tests.
const Analysis := preload("res://app/field_analysis.gd")
const Draft := preload("res://app/draft.gd")

class FailedWrite:
	extends "res://app/field_analysis.gd"
	var rows := 0
	func _write_row(file: FileAccess, values: PackedStringArray) -> Error:
		rows += 1
		var error: Error = super._write_row(file, values)
		return ERR_FILE_CANT_WRITE if rows == 2 else error

class FailedFlush:
	extends "res://app/field_analysis.gd"
	func _flush(_file: FileAccess) -> Error:
		return ERR_FILE_CANT_WRITE

class FailedReplace:
	extends "res://app/field_analysis.gd"
	func _replace_file(_temporary: String, _target: String) -> Error:
		return ERR_CANT_CREATE

var _root := ""
var _checks := 0
var _failures := 0
const TIMES := [0.10000000000000002, 1.2345678901234567, 8.75]
const NAME := "Pressure, \"A\"\nlayer"


func _initialize() -> void:
	var temporary := OS.get_environment("TMPDIR")
	_root = (temporary if not temporary.is_empty() else "/tmp").path_join("wisualizer-analysis-%d-%d" % [OS.get_process_id(), Time.get_ticks_usec()])
	DirAccess.make_dir_recursive_absolute(_root)
	_test_summary()
	_test_zip_export()
	_test_draft_export()
	_test_bad_packages()
	_test_transaction_failures()
	_test_source_protection()
	print("Field analysis: %d checks, %d failures" % [_checks, _failures])
	if _failures == 0:
		_remove_tree(_root)
	else:
		print("Analysis failure fixtures retained: " + _root)
	quit(1 if _failures else 0)


func _check(condition: bool, message: String) -> bool:
	_checks += 1
	if not condition:
		_failures += 1
		push_error("FAIL: " + message)
	return condition


func _test_summary() -> void:
	var result := Analysis.summarize(PackedByteArray([0, 1, 128, 255]), Vector2(-2, 2), Vector3i(4, 1, 1))
	_check(result.error.is_empty(), "Known scalar fixture validates")
	_check(result.valid_count == 3 and result.missing_count == 1, "Byte 0 is missing; physical zero is valid")
	_check(result.min == -2.0 and result.max == 2.0 and result.mean == 0.0, "Independent [-2,0,2] oracle")
	result = Analysis.summarize(PackedByteArray([0, 0]), Vector2(-2, 2), Vector3i(2, 1, 1))
	_check(result.error.is_empty() and result.valid_count == 0 and result.missing_count == 2, "All-missing counts are explicit")
	_check(result.min == null and result.max == null and result.mean == null, "All-missing extrema and mean are undefined")
	result = Analysis.summarize(PackedByteArray([1, 128, 255, 0]), Vector2(7, 7), Vector3i(4, 1, 1))
	_check(result.error.is_empty() and result.min == 7.0 and result.max == 7.0 and result.mean == 7.0, "A constant range is a valid constant field")
	var constant_bytes := PackedByteArray()
	for byte in range(1, 256):
		constant_bytes.append(byte)
	result = Analysis.summarize(constant_bytes, Vector2(7, 7), Vector3i(255, 1, 1))
	_check(result.min == 7.0 and result.max == 7.0 and result.mean == 7.0, "All positive byte codes preserve a constant field exactly")
	result = Analysis.summarize(PackedByteArray([2]), Vector2(7, 7), Vector3i.ONE)
	_check(result.min == 7.0 and result.max == 7.0 and result.mean == 7.0, "A constant range cannot gain interpolation roundoff")
	var bytes := PackedByteArray()
	for index in 521:
		bytes.append((index * 73) % 256)
	result = Analysis.summarize(bytes, Vector2(-13.5, 27.25), Vector3i(521, 1, 1))
	# Calculated separately with Python fractions.Fraction over each decoded sample.
	_check(result.valid_count == 518 and result.missing_count == 3, "Independent rational oracle counts")
	_check(result.min == -13.5 and result.max == 27.25 and absf(result.mean - 6.8960607120055935) < 1e-13, "Histogram statistics match an independent exact-rational sample oracle")
	result = Analysis.summarize(PackedByteArray([1, 255]), Vector2(-3e38, 3e38), Vector3i(2, 1, 1))
	_check(result.error.is_empty() and is_finite(result.mean) and result.mean == 0.0, "Large opposite endpoints do not overflow or corrupt the mean")
	for value_range in [Vector2(2, 1), Vector2(NAN, 1), Vector2(0, INF), Vector2(-INF, 1)]:
		_check(not Analysis.summarize(PackedByteArray([1]), value_range, Vector3i.ONE).error.is_empty(), "Reject invalid value range")
	for cells in [Vector3i.ZERO, Vector3i(-1, 1, 1), Vector3i(0x7fffffff, 0x7fffffff, 2)]:
		_check(not Analysis.summarize(PackedByteArray([1]), Vector2(0, 1), cells).error.is_empty(), "Reject invalid or overflowing cell counts")
	_check(not Analysis.summarize(PackedByteArray([1]), Vector2(0, 1), Vector3i(2, 1, 1)).error.is_empty(), "Reject a short brick")
	_check(not Analysis.summarize(PackedByteArray([1, 2, 3]), Vector2(0, 1), Vector3i(2, 1, 1)).error.is_empty(), "Reject trailing brick data")
	_check(not Analysis.summarize(PackedByteArray(), Vector2(0, 1), Vector3i.ONE).error.is_empty(), "Empty bytes cannot stand for a valid nonempty grid")


func _write(relative: String, bytes: PackedByteArray) -> String:
	var path := _root.path_join(relative)
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var file := FileAccess.open(path, FileAccess.WRITE)
	if not _check(file != null, "Write fixture " + relative):
		return path
	file.store_buffer(bytes)
	file.close()
	return path


func _manifest() -> Dictionary:
	var frames := []
	for time in TIMES:
		frames.append({time = time})
	return {title = "Analysis fixture", frames = frames, models = [{name = "Model", path = "model.glb"}], fields = [
		{name = NAME, quantity = "Pressure, absolute", unit = 'Pa "gauge"', range = [-2, 2], cells = [4, 1, 1], path = "fields/pressure"},
		{name = "Reference", quantity = "Reference value", unit = "K", range = [7, 7], cells = [4, 1, 1], path = "fields/reference"},
	]}


func _make_zip(relative: String, manifest: Dictionary = {}, changed: Dictionary = {}) -> String:
	var path := _root.path_join(relative)
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var contents := {
		"fields/pressure/0001.bin": PackedByteArray([0, 1, 128, 255]),
		"fields/pressure/0002.bin": PackedByteArray([128, 128, 0, 0]),
		"fields/pressure/0003.bin": PackedByteArray([0, 0, 0, 0]),
		"fields/reference/0001.bin": PackedByteArray([1, 128, 255, 0]),
		"fields/reference/0002.bin": PackedByteArray([1, 128, 255, 0]),
		"fields/reference/0003.bin": PackedByteArray([1, 128, 255, 0]),
		"model.glb": _empty_glb(),
	}
	contents["meta.json"] = JSON.stringify(_manifest() if manifest.is_empty() else manifest, "", true, true).to_utf8_buffer()
	contents.merge(changed, true)
	var zip := ZIPPacker.new()
	if not _check(zip.open(path) == OK, "Create ZIP fixture"):
		return path
	for name: String in contents:
		_check(zip.start_file(name) == OK and zip.write_file(contents[name]) == OK and zip.close_file() == OK, "Write ZIP fixture entry " + name)
	_check(zip.close() == OK, "Close ZIP fixture")
	return path


func _empty_glb() -> PackedByteArray:
	var json := '{"asset":{"version":"2.0"},"scene":0,"scenes":[{}]}'.to_utf8_buffer()
	while json.size() % 4:
		json.append(32)
	var bytes := PackedByteArray()
	bytes.resize(20)
	bytes.encode_u32(0, 0x46546c67)
	bytes.encode_u32(4, 2)
	bytes.encode_u32(8, 20 + json.size())
	bytes.encode_u32(12, json.size())
	bytes.encode_u32(16, 0x4e4f534a)
	return bytes + json


func _rows(path: String) -> Array:
	var file := FileAccess.open(path, FileAccess.READ)
	if not _check(file != null, "Read exported CSV"):
		return []
	var rows := []
	while file.get_position() < file.get_length():
		rows.append(file.get_csv_line())
	file.close()
	return rows


func _test_zip_export() -> void:
	var source := _make_zip("export/source.zip")
	var target := _root.path_join("export/statistics.csv")
	var before := FileAccess.get_file_as_bytes(source)
	var error: String = Analysis.new().export_zip(source, target)
	if not _check(error.is_empty(), "Export a real scalar ZIP: " + error):
		return
	_check(FileAccess.get_file_as_bytes(source) == before, "Statistics do not mutate the source ZIP")
	var rows := _rows(target)
	if not _check(rows.size() == 7, "One row per field per frame, with quoted multiline names"):
		return
	_check(rows[0] == PackedStringArray(["field", "quantity", "unit", "frame", "solver_time", "source_file", "valid_count", "missing_count", "min", "max", "mean"]), "CSV schema identifies solver time without inventing seconds")
	for index in 3:
		_check(rows[index + 1][0] == NAME and rows[index + 1][1] == "Pressure, absolute" and rows[index + 1][2] == 'Pa "gauge"', "CSV preserves commas, quotes, newlines and units")
		_check(rows[index + 1][3].to_int() == index + 1 and rows[index + 1][4].to_float() == TIMES[index], "Original frame order and full-precision irregular time are retained")
		_check(rows[index + 1][5] == "fields/pressure/%04d.bin" % (index + 1), "Each row identifies its archive source file")
	_check(rows[1][6].to_int() == 3 and rows[1][7].to_int() == 1 and rows[1][8].to_float() == -2.0 and rows[1][9].to_float() == 2.0 and rows[1][10].to_float() == 0.0, "Export matches the numeric oracle")
	_check(rows[2][6].to_int() == 2 and rows[2][8].to_float() == 0.0 and rows[2][10].to_float() == 0.0, "True physical zeros are included")
	_check(rows[3][6].to_int() == 0 and rows[3][7].to_int() == 4 and rows[3][8] == "" and rows[3][9] == "" and rows[3][10] == "", "All-missing CSV values stay blank")
	_check(rows[4][8].to_float() == 7.0 and rows[4][10].to_float() == 7.0, "Constant field exports actual physical values")
	_check(_temp_files(target.get_base_dir()).is_empty(), "Successful export leaves no temporary file")


func _test_draft_export() -> void:
	var draft := Draft.new()
	var field := Draft.Field.new()
	field.name = "Unsaved scalar field"
	field.quantity = "Custom quantity"
	field.unit = "m/s"
	field.range = Vector2(-2, 2)
	field.cells = Vector3i(4, 1, 1)
	field.bricks[0] = _write("draft/source.bin", PackedByteArray([0, 1, 128, 255]))
	draft.fields.append(field)
	draft.times = PackedFloat64Array([7.5, 9.0])
	draft.notes = "Keep this draft unchanged"
	var source_map := field.bricks.duplicate()
	var target := _root.path_join("draft/statistics.csv")
	var error: String = Analysis.new().export_draft(draft, target)
	if _check(error.is_empty(), "Export unsaved fields without requiring a model or ZIP: " + error):
		var rows := _rows(target)
		if _check(rows.size() == 3, "Draft export includes its missing-data frame"):
			_check(rows[1][0] == field.name and rows[1][4].to_float() == 7.5 and rows[1][10].to_float() == 0.0, "Unsaved metadata and values are exported directly")
			_check(rows[2][5] == "" and rows[2][6].to_int() == 0 and rows[2][7].to_int() == 4 and rows[2][10] == "", "Missing draft bricks are explicit no-data frames")
	_check(field.bricks == source_map and draft.notes == "Keep this draft unchanged" and draft.source_zip_path().is_empty(), "Export does not save or mutate the draft")
	var bytes := FileAccess.get_file_as_bytes(field.bricks[0])
	_check(not Analysis.new().export_draft(draft, field.bricks[0]).is_empty(), "Cannot replace a draft's raw field source")
	_check(FileAccess.get_file_as_bytes(field.bricks[0]) == bytes, "Field source bytes remain intact")
	var supporting := _write("draft/extra.txt", "Source attachment".to_utf8_buffer())
	draft.add_attachments(PackedStringArray([supporting]))
	_check(not Analysis.new().export_draft(draft, supporting).is_empty(), "Cannot replace an unrelated supporting source file")
	_check(FileAccess.get_file_as_string(supporting) == "Source attachment", "Supporting source stays intact")
	draft.close()


func _test_bad_packages() -> void:
	var target := _write("invalid/statistics.csv", "Keep previous report".to_utf8_buffer())
	for bytes in [PackedByteArray([1]), PackedByteArray([1, 2, 3, 4, 5])]:
		var source := _make_zip("invalid/length.zip", {}, {"fields/pressure/0002.bin": bytes})
		_check(not Analysis.new().export_zip(source, target).is_empty(), "Reject short or oversized bricks before replacing output")
		_check(FileAccess.get_file_as_string(target) == "Keep previous report", "A late-frame length failure preserves the old CSV")
	var malformed := []
	var manifest := _manifest()
	manifest.fields = [false]
	malformed.append(manifest)
	manifest = _manifest()
	manifest.fields[0].range = [1]
	malformed.append(manifest)
	manifest = _manifest()
	manifest.fields[0].cells = [1.5, 1, 1]
	malformed.append(manifest)
	manifest = _manifest()
	manifest.frames[0].time = "not a number"
	malformed.append(manifest)
	for value: Dictionary in malformed:
		var source := _make_zip("invalid/metadata.zip", value)
		_check(not Analysis.new().export_zip(source, target).is_empty(), "Malformed metadata is an explicit error")
		_check(FileAccess.get_file_as_string(target) == "Keep previous report", "Malformed metadata cannot replace existing output")
	var corrupt := _make_zip("invalid/corrupt.zip")
	_corrupt_crc(corrupt, "fields/pressure/0002.bin")
	_check(not Analysis.new().export_zip(corrupt, target).is_empty(), "Reject a corrupt scalar frame")
	_check(FileAccess.get_file_as_string(target) == "Keep previous report", "A corrupt late frame preserves the old CSV")
	_check(_temp_files(target.get_base_dir()).is_empty(), "Rejected input leaves no temporary CSV")


func _test_transaction_failures() -> void:
	var source := _make_zip("failure/source.zip")
	var target := _write("failure/statistics.csv", "Previous results".to_utf8_buffer())
	for exporter in [FailedWrite.new(), FailedFlush.new(), FailedReplace.new()]:
		_check(not exporter.export_zip(source, target).is_empty(), "Injected output write, flush or replacement failure is reported")
		_check(FileAccess.get_file_as_string(target) == "Previous results", "Output failure preserves previous results")
		_check(_temp_files(target.get_base_dir()).is_empty(), "Output failure removes its incomplete temporary file")
	var directory := _root.path_join("failure/folder.csv")
	DirAccess.make_dir_recursive_absolute(directory)
	_check(not Analysis.new().export_zip(source, directory).is_empty() and DirAccess.dir_exists_absolute(directory), "A directory is not replaced by CSV output")
	_check(not Analysis.new().export_zip(source, _root.path_join("missing-folder/out.csv")).is_empty(), "An unavailable output folder reports an error")
	_check(Analysis.new().export_zip(source, target).is_empty(), "A normal retry replaces existing CSV only after success")


func _test_source_protection() -> void:
	var source := _make_zip("protection/source.zip")
	var bytes := FileAccess.get_file_as_bytes(source)
	_check(not Analysis.new().export_zip(source, source).is_empty(), "Cannot export over the source ZIP")
	_check(not Analysis.new().export_zip(source, source.get_base_dir().path_join("./source.zip")).is_empty(), "Equivalent paths cannot replace the ZIP")
	var directory := DirAccess.open(_root)
	var alias := _root.path_join("zip-alias.csv")
	if _check(directory.create_link(source, alias) == OK, "Create a source-file symlink fixture"):
		_check(not Analysis.new().export_zip(source, alias).is_empty(), "A source ZIP symlink cannot be an export destination")
	var folder_alias := _root.path_join("folder-alias")
	if _check(directory.create_link(source.get_base_dir(), folder_alias) == OK, "Create a parent-directory symlink fixture"):
		_check(not Analysis.new().export_zip(source, folder_alias.path_join("source.zip")).is_empty(), "A symlinked parent cannot bypass source protection")
	_check(FileAccess.get_file_as_bytes(source) == bytes, "All destination aliases leave source bytes unchanged")


func _corrupt_crc(path: String, name: String) -> void:
	var bytes := FileAccess.get_file_as_bytes(path)
	var end := bytes.size() - 22
	var cursor := int(bytes.decode_u32(end + 16))
	while cursor + 46 <= end and bytes.decode_u32(cursor) == 0x02014b50:
		var length := bytes.decode_u16(cursor + 28)
		if bytes.slice(cursor + 46, cursor + 46 + length).get_string_from_utf8() == name:
			var wrong := bytes.decode_u32(cursor + 16) ^ 1
			bytes.encode_u32(cursor + 16, wrong)
			bytes.encode_u32(int(bytes.decode_u32(cursor + 42)) + 14, wrong)
			var file := FileAccess.open(path, FileAccess.WRITE)
			file.store_buffer(bytes)
			file.close()
			return
		cursor += 46 + length + bytes.decode_u16(cursor + 30) + bytes.decode_u16(cursor + 32)
	_check(false, "Locate the frame whose CRC should be damaged")


func _temp_files(path: String) -> PackedStringArray:
	var found := PackedStringArray()
	for file in DirAccess.get_files_at(path):
		if file.ends_with(".tmp"):
			found.append(file)
	return found


func _remove_tree(path: String) -> void:
	var directory := DirAccess.open(path)
	for name in DirAccess.get_directories_at(path):
		if directory.is_link(name):
			DirAccess.remove_absolute(path.path_join(name))
		else:
			_remove_tree(path.path_join(name))
	for name in DirAccess.get_files_at(path):
		DirAccess.remove_absolute(path.path_join(name))
	DirAccess.remove_absolute(path)
