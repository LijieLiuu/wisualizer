extends SceneTree
## Real ZIP/session/CSV fixtures, independent numerical oracles, and output
## failure injection. No headset or native hand events are required.

const History := preload("res://app/probe_history.gd")
const Meta := preload("res://app/meta.gd")
const POINTS := {0: Vector3(0.125, 0.5, 0.5), 1: Vector3(0.875, 0.5, 0.5)}
const TIMES := [2.25, 2.25, -1.0, 7.125000000000003]

class FailedWrite:
	extends "res://app/probe_history.gd"
	var count := 0
	func _write_row(file: FileAccess, values: PackedStringArray) -> Error:
		count += 1
		var error: Error = super._write_row(file, values)
		return ERR_FILE_CANT_WRITE if count == 2 else error

class FailedFlush:
	extends "res://app/probe_history.gd"
	func _flush(_file: FileAccess) -> Error:
		return ERR_FILE_CANT_WRITE

class FailedReplace:
	extends "res://app/probe_history.gd"
	func _replace_file(_temporary: String, _target: String) -> Error:
		return ERR_CANT_CREATE

class FailedSession:
	extends "res://app/probe_history.gd"
	func _write_session(_file: FileAccess, _text: String) -> Error:
		return ERR_FILE_CANT_WRITE

class ChangeAtFlush:
	extends "res://app/probe_history.gd"
	var mutate: Callable
	func _flush(file: FileAccess) -> Error:
		var error: Error = super._flush(file)
		mutate.call()
		return error

class CancelAtFlush:
	extends "res://app/probe_history.gd"
	var stopped := false
	func _flush(file: FileAccess) -> Error:
		stopped = true
		return super._flush(file)
	func canceled() -> bool:
		return stopped

var _root := ""
var _checks := 0
var _failures := 0


func _initialize() -> void:
	_root = OS.get_environment("TMPDIR").path_join("wisualizer-history-%d-%d" % [OS.get_process_id(), Time.get_ticks_usec()])
	if not _root.is_absolute_path():
		_root = "/tmp/" + _root
	DirAccess.make_dir_recursive_absolute(_root)
	_test_models()
	_test_analysis()
	_test_three_dimensional_grid()
	_test_sessions()
	_test_csv()
	_test_failures()
	_test_changes_and_cancellation()
	_test_crc()
	print("Probe history: %d checks, %d failures" % [_checks, _failures])
	if _failures == 0:
		_remove_tree(_root)
	else:
		print("Failure fixtures retained: " + _root)
	quit(1 if _failures else 0)


func _check(condition: bool, message: String) -> bool:
	_checks += 1
	if not condition:
		_failures += 1
		push_error("FAIL: " + message)
	return condition


func _write(path: String, bytes: PackedByteArray) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var file := FileAccess.open(path, FileAccess.WRITE)
	if _check(file != null, "Open fixture output"):
		file.store_buffer(bytes)
		file.close()


func _fixture(relative: String, changed: Dictionary = {}) -> String:
	var path := _root.path_join(relative)
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var manifest := {title = "Probe history", frames = [], models = [{name = "Shape", path = "shape.glb"}], fields = [
		{name = "Pressure, \"A\"\nfield", quantity = "Pressure", unit = "Pa", range = [-2, 2], cells = [4, 1, 1], path = "pressure"},
		{name = "Temperature", quantity = "Temperature", unit = "K", range = [10, 20], cells = [2, 1, 1], path = "temperature.bin"}]}
	for time in TIMES:
		manifest.frames.append({time = time})
	var files := {"meta.json": JSON.stringify(manifest, "", true, true).to_utf8_buffer(),
		"shape.glb": PackedByteArray([1]), "notes.txt": "Notes".to_utf8_buffer(),
		"pressure/0001.bin": PackedByteArray([1, 128, 0, 255]),
		"pressure/0002.bin": PackedByteArray([255, 0, 128, 1]),
		"pressure/0003.bin": PackedByteArray([0, 128, 255, 1]),
		"pressure/0004.bin": PackedByteArray([128, 255, 1, 0]),
		"temperature.bin": PackedByteArray([1, 255])}
	files.merge(changed, true)
	var zip := ZIPPacker.new()
	if not _check(zip.open(path) == OK, "Create real history fixture ZIP"):
		return path
	for name in files:
		_check(zip.start_file(name) == OK and zip.write_file(files[name]) == OK and zip.close_file() == OK, "Write ZIP fixture " + name)
	_check(zip.close() == OK, "Close ZIP fixture")
	return path


func _open(path: String) -> RefCounted:
	var meta := Meta.new()
	_check(meta.open(path).is_empty(), "Open source metadata")
	return meta


func _analyze(path: String, field_index: int = 0, points: Dictionary = POINTS) -> Dictionary:
	var meta := _open(path)
	var captured := History.snapshot(meta, field_index)
	meta.close()
	_check(captured.error.is_empty(), "Capture cached source identity")
	return History.new().analyze(path, field_index, points, captured.identity)


func _test_analysis() -> void:
	var path := _fixture("analysis/source.zip")
	var result := _analyze(path)
	if not _check(result.error.is_empty(), "Analyze selected field: " + result.error):
		return
	_check(result.rows.size() == 4, "Keep exactly one row per recorded frame")
	_check(result.cells == {0: Vector3i(0, 0, 0), 1: Vector3i(3, 0, 0)}, "Normalized pins use x-fastest cell mapping")
	_check(result.field_index == 0 and result.unit == "Pa" and result.quantity == "Pressure", "Retain selected-field metadata")
	var expected := [[1, 255, -2.0, 2.0, 4.0], [255, 1, 2.0, -2.0, -4.0], [0, 1, null, -2.0, null], [128, 0, 0.0, null, null]]
	for index in 4:
		var row: Dictionary = result.rows[index]
		_check(row.frame == index + 1 and row.solver_time == TIMES[index], "Repeated/nonmonotonic solver times retain exact frame order")
		_check([row.a_byte, row.b_byte, row.a, row.b, row.delta] == expected[index], "Independent scalar/difference oracle at frame %d" % (index + 1))
		_check(row.source_file == "pressure/%04d.bin" % (index + 1), "Each row identifies its brick")
	var single := _analyze(path, 0, {1: POINTS[1]})
	_check(single.error.is_empty() and single.rows[0].a == null and single.rows[0].a_byte == null and single.rows[0].b == 2.0 and single.rows[0].delta == null, "Unplaced A is distinct from missing byte zero")
	var second := _analyze(path, 1)
	_check(second.error.is_empty() and second.rows.size() == 4 and second.unit == "K", "Analyze the selected second field independently")
	for row in second.rows:
		_check(row.a == 10.0 and row.b == 20.0 and row.delta == 10.0 and row.source_file == "temperature.bin", "A constant brick is sampled at every recorded frame")
	var meta := _open(path)
	var display_field: Meta.Field = meta.fields[0]
	_check(display_field.format(0.0000001).begins_with("1.00e-07"), "Small nonzero scalar formatting uses supported scientific notation")
	var identity: Dictionary = History.snapshot(meta, 0).identity
	meta.close()
	for points in [{}, {2: Vector3.ZERO}, {"0": Vector3.ZERO}, {0: Vector3(1, 0, 0)}, {0: Vector3(-0.1, 0, 0)}, {0: Vector3(NAN, 0, 0)}, {0: [0, 0, 0]}]:
		var invalid := History.new().analyze(path, 0, points, identity)
		_check(not invalid.error.is_empty() and invalid.rows.is_empty(), "Reject invalid pins without partial results")
	_check(not History.new().analyze(path, 1, POINTS, identity).error.is_empty(), "Wrong selected-field snapshot is rejected")
	_check(not History.new().analyze(path, 0, POINTS, {}).error.is_empty(), "Missing source snapshot is rejected")


func _test_three_dimensional_grid() -> void:
	var manifest := {frames = [{time = 4.0}], models = [{path = "shape.glb"}], fields = [
		{name = "Volume", cells = [2, 2, 2], range = [0, 254], path = "volume.bin"},
		{name = "Constant zero", cells = [2, 2, 2], range = [0, 0], path = "volume.bin"}]}
	var path := _fixture("volume/source.zip", {"meta.json": JSON.stringify(manifest).to_utf8_buffer(), "volume.bin": PackedByteArray([1, 2, 3, 4, 5, 6, 7, 255])})
	var points := {0: Vector3(0.25, 0.75, 0.25), 1: Vector3(0.75, 0.25, 0.75)}
	var result := _analyze(path, 0, points)
	if not _check(result.error.is_empty(), "Analyze 3D grid"):
		return
	_check(result.cells == {0: Vector3i(0, 1, 0), 1: Vector3i(1, 0, 1)}, "Normalized locations map independently across all grid axes")
	_check(result.rows[0].a_byte == 3 and result.rows[0].b_byte == 6 and result.rows[0].a == 2.0 and result.rows[0].b == 5.0 and result.rows[0].delta == 3.0, "Independent 3D x-fastest offset oracle")
	result = _analyze(path, 1, points)
	_check(result.error.is_empty() and result.rows[0].a == 0.0 and result.rows[0].b == 0.0 and result.rows[0].delta == 0.0, "A constant-zero range stays valid for every nonzero byte")


func _test_sessions() -> void:
	var path := _fixture("sessions/source.zip")
	var meta := _open(path)
	var target := _root.path_join("sessions/inspection.json")
	var history := History.new()
	_check(history.save_session(meta, 1, POINTS, path, target).is_empty(), "Save both normalized pins atomically")
	var restored := history.restore_session(target, meta, path)
	_check(restored.error.is_empty() and restored.field_index == 1 and restored.points == POINTS, "Restore source-bound second-field pins: " + restored.error)
	_check(restored.source_session == History._canonical_path(target).path, "Restore supplies a protected session path")
	var original: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(target))
	_check(original.size() == 5 and not original.has("rows") and not original.has("values"), "Sessions contain no stored readings")
	var bad_values := [
		["version", 2], ["version", true], ["version", "1"], ["field_index", -1], ["field_index", true],
		["field_index", 0.5], ["field_index", 999], ["source", 3], ["source", _root.path_join("sessions/another.zip")],
		["points", {}], ["points", {"2": [0.1, 0.2, 0.3]}], ["points", {"0": [1, 0, 0]}],
		["points", {"0": [-0.1, 0, 0]}], ["points", {"0": [0, 0]}], ["points", {"0": ["0", 0, 0]}],
		["points", {"0": [null, 0, 0]}], ["points", {"0": [true, 0, 0]}], ["points", {"0": [0.9999999999999999, 0, 0]}],
		["identity", {}], ["identity", {algorithm = "other", digest = "0".repeat(64), field_index = 1}]]
	for change in bad_values:
		var modified := original.duplicate(true)
		modified[change[0]] = change[1]
		_write(target, JSON.stringify(modified, "", true, true).to_utf8_buffer())
		var invalid := history.restore_session(target, meta, path)
		_check(not invalid.error.is_empty() and invalid.points.is_empty(), "Reject malformed session " + str(change[0]))
	var forged := original.duplicate(true)
	forged["values"] = {"0": 999999}
	_write(target, JSON.stringify(forged).to_utf8_buffer())
	_check(not history.restore_session(target, meta, path).error.is_empty(), "Forged readings are not accepted from a session")
	_write(target, "not json".to_utf8_buffer())
	_check(not history.restore_session(target, meta, path).error.is_empty(), "Reject invalid JSON")
	_write(target, (" ".repeat(History.MAX_SESSION_BYTES + 1)).to_utf8_buffer())
	_check(not history.restore_session(target, meta, path).error.is_empty(), "Bound session read size")
	_check(history.save_session(meta, 0, {0: POINTS[0]}, path, target).is_empty(), "Replace bad session only after a successful save")
	_check(history.restore_session(target, meta, path).points == {0: POINTS[0]}, "Single-pin sessions restore exactly")
	_check(not history.save_session(meta, 0, {}, path, target).is_empty(), "Cannot save an empty session")
	var bytes := FileAccess.get_file_as_bytes(path)
	_check(not history.save_session(meta, 0, POINTS, path, path).is_empty(), "Cannot replace the source ZIP with a session")
	_check(FileAccess.get_file_as_bytes(path) == bytes, "Session source protection preserves source bytes")
	meta.close()


func _rows(path: String) -> Array:
	var file := FileAccess.open(path, FileAccess.READ)
	var rows := []
	while file.get_position() < file.get_length():
		rows.append(file.get_csv_line())
	file.close()
	return rows


func _test_csv() -> void:
	var path := _fixture("csv/source.zip")
	var result := _analyze(path)
	var target := _root.path_join("csv/history.csv")
	_check(History.new().export_csv(result, target).is_empty(), "Export real probe CSV")
	var rows := _rows(target)
	if not _check(rows.size() == 5 and rows[0] == PackedStringArray(History.HISTORY_COLUMNS), "CSV has one header and one row per frame"):
		return
	var columns: PackedStringArray = rows[0]
	for index in 4:
		_check(rows[index + 1][columns.find("solver_time")].to_float() == TIMES[index], "CSV retains full-precision recorded solver times")
		_check(rows[index + 1][columns.find("field")] == result.field, "CSV escaping retains quoted multiline field names")
	_check(rows[1][columns.find("a_value")] == "-2.0" and rows[1][columns.find("b_minus_a")] == "4.0", "CSV contains decoded values and signed B-A")
	_check(rows[3][columns.find("a_byte")] == "0" and rows[3][columns.find("a_valid")] == "false" and rows[3][columns.find("a_value")] == "", "Missing sample preserves raw zero and explicit false validity")
	_check(rows[4][columns.find("a_byte")] == "128" and rows[4][columns.find("a_valid")] == "true" and rows[4][columns.find("a_value")].to_float() == 0.0, "Physical zero remains a valid numeric CSV value")
	_check(rows[4][columns.find("b_minus_a")] == "", "Undefined difference stays blank")
	var source_bytes := FileAccess.get_file_as_bytes(path)
	_check(not History.new().export_csv(result, path).is_empty(), "Cannot overwrite source ZIP with CSV")
	var alias := _root.path_join("csv/source-alias.csv")
	var directory := DirAccess.open(_root)
	if _check(directory.create_link(path, alias) == OK, "Create source symlink fixture"):
		_check(not History.new().export_csv(result, alias).is_empty(), "Source symlink cannot bypass protection")
	var folder_alias := _root.path_join("source-folder")
	if _check(directory.create_link(path.get_base_dir(), folder_alias) == OK, "Create parent symlink fixture"):
		_check(not History.new().export_csv(result, folder_alias.path_join("source.zip")).is_empty(), "Parent symlink cannot bypass source protection")
	_check(FileAccess.get_file_as_bytes(path) == source_bytes, "CSV protection preserves source bytes")
	var session := _root.path_join("csv/session.json")
	_write(session, "Previous session".to_utf8_buffer())
	_check(not History.new().export_csv(result, session, Callable(), PackedStringArray([session])).is_empty(), "Explicit protected session path cannot be overwritten by CSV")
	_check(FileAccess.get_file_as_string(session) == "Previous session", "Protected session remains unchanged")
	var single := _analyze(path, 0, {1: POINTS[1]})
	History.new().export_csv(single, target)
	rows = _rows(target)
	_check(rows[1][columns.find("a_byte")] == "" and rows[1][columns.find("a_valid")] == "" and rows[1][columns.find("a_value")] == "", "Unplaced probe CSV validity is blank, distinct from missing")


func _test_failures() -> void:
	var path := _fixture("failures/source.zip")
	var result := _analyze(path)
	var target := _root.path_join("failures/history.csv")
	_write(target, "Prior output".to_utf8_buffer())
	for exporter in [FailedWrite.new(), FailedFlush.new(), FailedReplace.new()]:
		_check(not exporter.export_csv(result, target).is_empty(), "Injected CSV write/flush/replace error is reported")
		_check(FileAccess.get_file_as_string(target) == "Prior output", "Failed CSV leaves prior output intact")
		_check(_temporary_files(target.get_base_dir()).is_empty(), "Failed CSV removes temporary files")
	var stop := CancelAtFlush.new()
	_check(not stop.export_csv(result, target, stop.canceled).is_empty(), "Cancellation after flush blocks replacement")
	_check(FileAccess.get_file_as_string(target) == "Prior output" and _temporary_files(target.get_base_dir()).is_empty(), "Canceled CSV retains prior output and cleans temporary")
	var meta := _open(path)
	for saver in [FailedSession.new(), FailedFlush.new(), FailedReplace.new()]:
		_check(not saver.save_session(meta, 0, POINTS, path, target).is_empty(), "Injected session write/flush/replace error is reported")
		_check(FileAccess.get_file_as_string(target) == "Prior output", "Failed session leaves prior output intact")
		_check(_temporary_files(target.get_base_dir()).is_empty(), "Failed session removes temporary files")
	stop = CancelAtFlush.new()
	_check(not stop.save_session(meta, 0, POINTS, path, target, stop.canceled).is_empty(), "Canceled session cannot replace prior output")
	_check(FileAccess.get_file_as_string(target) == "Prior output", "Session cancellation preserves output")
	meta.close()
	for damaged in [{error = "failure", canceled = false, rows = []}, result.duplicate(true)]:
		if damaged.has("points"):
			damaged.rows[0].delta = 1234.0
		_check(not History.new().export_csv(damaged, target).is_empty(), "Failed or malformed results cannot export")
		_check(FileAccess.get_file_as_string(target) == "Prior output", "Malformed export cannot touch prior output")
	_check(not History.new().export_csv(result, target.get_base_dir()).is_empty(), "Output directory is not replaced")
	_check(not History.new().export_csv(result, _root.path_join("unavailable/history.csv")).is_empty(), "Unavailable parent directory fails safely")
	var replacement := _fixture("failures/replacement.zip", {"notes.txt": "Changed while exporting".to_utf8_buffer()})
	var change := ChangeAtFlush.new()
	change.mutate = func() -> void: DirAccess.rename_absolute(replacement, path)
	_check(not change.export_csv(result, target).is_empty(), "Source change during output writing blocks atomic replacement")
	_check(FileAccess.get_file_as_string(target) == "Prior output" and _temporary_files(target.get_base_dir()).is_empty(), "Changed source preserves previous output and cleans temporary")


func _test_changes_and_cancellation() -> void:
	var path := _fixture("changes/source.zip")
	var meta := _open(path)
	var identity: Dictionary = History.snapshot(meta, 0).identity
	var history := History.new()
	var canceled := history.analyze(path, 0, POINTS, identity, func() -> bool: return true)
	_check(canceled.canceled and not canceled.error.is_empty() and canceled.rows.is_empty(), "Cancellation before work returns no partial rows")
	var state := {stop = false, calls = []}
	canceled = history.analyze(path, 0, POINTS, identity, func() -> bool: return state.stop,
		func(done: int, total: int) -> void:
			state.calls.append([done, total])
			state.stop = done == 1)
	_check(canceled.canceled and canceled.rows.is_empty() and state.calls == [[1, 4]], "Cancellation between frames returns no partial rows and accurate progress")
	var result := history.analyze(path, 0, POINTS, identity)
	var session := _root.path_join("changes/session.json")
	_check(history.save_session(meta, 0, POINTS, path, session).is_empty(), "Save source-bound session before replacement")
	var replacement := _fixture("changes/replacement.zip", {"pressure/0001.bin": PackedByteArray([255, 128, 0, 255])})
	_check(DirAccess.rename_absolute(replacement, path) == OK, "Replace source with same-size changed scalar bytes")
	var changed := history.analyze(path, 0, POINTS, identity)
	_check(not changed.error.is_empty() and changed.rows.is_empty(), "Cached CRC identity detects same-size source changes before work")
	_check(not history.restore_session(session, meta, path).error.is_empty(), "Restore checks current ZIP even when caller still has old open metadata")
	_check(not history.save_session(meta, 0, POINTS, path, session).is_empty(), "Saving with stale metadata is rejected")
	var output := _root.path_join("changes/output.csv")
	_write(output, "Prior CSV".to_utf8_buffer())
	_check(not history.export_csv(result, output).is_empty() and FileAccess.get_file_as_string(output) == "Prior CSV", "Export refuses analyzed values after source changes")
	meta.close()
	path = _fixture("midrun/source.zip")
	meta = _open(path)
	identity = History.snapshot(meta, 0).identity
	replacement = _fixture("midrun/replacement.zip", {"notes.txt": "Different notes".to_utf8_buffer()})
	changed = history.analyze(path, 0, POINTS, identity, Callable(), func(done: int, _total: int) -> void:
		if done == 1:
			DirAccess.rename_absolute(replacement, path))
	_check(not changed.error.is_empty() and changed.rows.is_empty(), "Fresh final index rejects a source replaced during analysis")
	meta.close()
	var broken := _fixture("broken/source.zip", {"pressure/0003.bin": PackedByteArray([1])})
	changed = history.analyze(broken, 0, POINTS, identity)
	_check(not changed.error.is_empty() and changed.rows.is_empty(), "Malformed brick source fails without partial results")
	_check(history.analyze(_root.path_join("missing.zip"), 0, POINTS, identity).rows.is_empty(), "Unavailable source returns no rows")


func _test_crc() -> void:
	var path := _fixture("crc/source.zip")
	_corrupt_crc(path, "pressure/0002.bin")
	var result := _analyze(path)
	_check(not result.error.is_empty() and result.rows.is_empty(), "Actual inflated-byte checksum failure rejects all partial history")


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
			_write(path, bytes)
			return
		cursor += 46 + length + bytes.decode_u16(cursor + 30) + bytes.decode_u16(cursor + 32)
	_check(false, "Locate CRC corruption fixture entry")


func _temporary_files(path: String) -> PackedStringArray:
	var files := PackedStringArray()
	for name in DirAccess.get_files_at(path):
		if name.ends_with(".tmp"):
			files.append(name)
	return files


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


func _test_models() -> void:
	var times := [-1, 0, 1, 2, 3]
	var manifest := {title = "Multiple models", models = [
		{name = "Same model", parts = [{name = "Part", path = "team/shape", times = times}], fields = [
			{name = "Same field", quantity = "Pressure", unit = "Pa", range = [-2, 2], cells = [2, 1, 1], path = "team/pressure", times = [0, 2]},
			{name = "Same field", range = [10, 20], cells = [2, 1, 1], path = "temperature.bin"}],
			labels = [{text = "Point", position = [0, 0, 0], frames = [2, 4]}]},
		{name = "Same model", parts = [{path = "shape.glb"}], fields = [
			{name = "Same field", quantity = "Pressure", unit = "Pa", range = [-2, 2], cells = [2, 1, 1], path = "team/pressure", times = [100, 101]}]},
		{name = "Static model", parts = [{path = "shape.glb"}], fields = [
			{name = "Constant", range = [10, 20], cells = [2, 1, 1], path = "temperature.bin"}]}]}
	var changed := {"meta.json": JSON.stringify(manifest, "", true, true).to_utf8_buffer(),
		"team/pressure/01.bin": PackedByteArray([1, 255]), "team/pressure/02.bin": PackedByteArray([255, 1])}
	for frame in times.size():
		changed["team/shape/%02d.glb" % frame] = PackedByteArray([1])
	var path := _fixture("models/source.zip", changed)
	var meta := _open(path)
	_check(not meta.legacy and meta.models.size() == 3, "Team archive retains separate models")
	_check(meta.models[0].times == PackedFloat64Array(times) and meta.models[1].times == PackedFloat64Array([100, 101]), "Each model keeps its own team union timeline")
	_check(meta.models[0].fields[0].frame_steps == PackedInt32Array([0, 0, 0, 1, 1]), "Team sample-and-hold includes before-first and after-last frames")
	_check(meta.models[0].labels[0].frames == Vector2i(1, 3), "Team point labels retain their model frame range")
	var first := History.snapshot(meta, 0, 0)
	var other := History.snapshot(meta, 0, 1)
	var duplicate := History.snapshot(meta, 1, 0)
	_check(first.identity.digest != other.identity.digest and first.identity.digest != duplicate.identity.digest, "Duplicate model/field labels cannot share identities")
	var history := History.new()
	var result := history.analyze(path, 0, POINTS, first.identity, Callable(), Callable(), 0)
	if _check(result.error.is_empty() and result.rows.size() == 5, "Analyze selected model with held field steps"):
		_check(result.rows[2].solver_time == 1 and result.rows[2].source_time == 0 and result.rows[2].source_step == 1 and result.rows[2].a == -2.0, "Displayed model time is distinct from held source time/value")
		_check(result.rows[0].solver_time == -1 and result.rows[0].source_time == 0, "Before-first display names the actual first source time")
		_check(result.rows[4].solver_time == 3 and result.rows[4].source_time == 2 and result.rows[4].a == 2.0, "After-last display retains the actual last source step")
	var second := history.analyze(path, 0, POINTS, other.identity, Callable(), Callable(), 1)
	_check(second.error.is_empty() and second.model_index == 1 and second.rows.size() == 2 and second.rows[0].solver_time == 100, "Second model analysis never uses the first model's timeline")
	_check(not history.analyze(path, 0, POINTS, first.identity, Callable(), Callable(), 1).error.is_empty(), "Cross-model identity is rejected despite matching names")
	var captured := History.snapshot(meta, 0, 2)
	var static_result := history.analyze(path, 0, POINTS, captured.identity, Callable(), Callable(), 2)
	_check(static_result.error.is_empty() and static_result.rows.size() == 1 and static_result.rows[0].source_static and static_result.rows[0].source_time == null, "Static source has no invented solver timestamp")
	var session := _root.path_join("models/points.json")
	_check(history.save_session(meta, 0, POINTS, path, session, Callable(), 1).is_empty(), "Save model-scoped positions")
	var restored := history.restore_session(session, meta, path)
	_check(restored.error.is_empty() and restored.model_index == 1 and restored.field_index == 0, "Session restores exact model and field indices")
	var stored: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(session))
	_check(stored.version == 2 and stored.identity.model_index == 1, "Team positions use model-bound session version 2")
	stored.model_index = 0
	_write(session, JSON.stringify(stored).to_utf8_buffer())
	_check(not history.restore_session(session, meta, path).error.is_empty(), "Changing only session model index invalidates its identity")
	var target := _root.path_join("models/history.csv")
	_check(history.export_csv(result, target).is_empty(), "Export model-scoped probe history")
	var rows := _rows(target)
	var columns: PackedStringArray = rows[0]
	_check(rows[3][columns.find("model_index")] == "0" and rows[3][columns.find("field_index")] == "0" and rows[3][columns.find("source_time")].to_float() == 0.0 and rows[3][columns.find("solver_time")].to_float() == 1.0, "Probe CSV identifies model/field and held source time separately")
	_check(history.export_zip(path, target).is_empty(), "Statistics export every model")
	rows = _rows(target)
	columns = rows[0]
	_check(rows.size() == 14, "Statistics counts each model's own frames and fields")
	_check(rows[11][columns.find("model_index")] == "1" and rows[11][columns.find("solver_time")].to_float() == 100.0, "Statistics never leak first-model times into a duplicate model label")
	_check(rows[-1][columns.find("source_static")] == "true" and rows[-1][columns.find("source_time")] == "", "Static statistics source timestamp stays blank")
	meta.close()
