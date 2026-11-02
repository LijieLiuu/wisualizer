extends SceneTree
## Run with: godot --headless --path . --script tests/scalar_validation_test.gd
const ScalarData := preload("res://app/scalar_data.gd")
const BOV := preload("res://app/bov.gd")
const Meta := preload("res://app/meta.gd")

var _checks := 0
var _failures := 0
var _serial := 0
var _directory := "/private/tmp/wisualizer-scalar-validation-%d" % Time.get_ticks_usec()


func _initialize() -> void:
	DirAccess.make_dir_recursive_absolute(_directory)
	_scalars()
	_bovs()
	_manifests()
	for name in DirAccess.get_files_at(_directory):
		DirAccess.remove_absolute(_directory.path_join(name))
	DirAccess.remove_absolute(_directory)
	print("Scalar validation checks: %d passed, %d failed" % [_checks - _failures, _failures])
	quit(0 if _failures == 0 else 1)


func _check(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(message)


func _scalars() -> void:
	_check(ScalarData.cell_count(Vector3i(3, 2, 4)) == 24, "Cell count uses every dimension")
	_check(ScalarData.cell_count(Vector3i(0x7fffffff, 1, 1)) == 0x7fffffff, "Maximum reader-sized grid is counted without allocating")
	for cells in [Vector3i.ZERO, Vector3i(-1, 2, 3), Vector3i(65536, 65536, 1), Vector3i(0x7fffffff, 0x7fffffff, 0x7fffffff)]:
		_check(ScalarData.cell_count(cells) == 0, "Invalid or overflowing cell counts are rejected: %s" % cells)
	for cells in [null, "3 1 1", [3, 1], [3, 1, 1, 1], [1.5, 1, 1], [true, 1, 1], ["3", 1, 1], [INF, 1, 1], [0x80000000, 1, 1]]:
		_check(not ScalarData.parse_cells(cells).error.is_empty(), "Cell shape and exact integer type are checked: %s" % str(cells))
	_check(ScalarData.parse_cells([3.0, 1.0, 1.0]).error.is_empty(), "JSON numeric integer dimensions are accepted")
	_check(ScalarData.validate(PackedByteArray([0, 1, 255]), Vector2(-2, 2), Vector3i(3, 1, 1)).is_empty(), "An exact scalar payload with missing samples is valid")
	_check(ScalarData.validate(PackedByteArray([0]), Vector2(4, 4), Vector3i.ONE).is_empty(), "A constant scalar range is valid")
	for bytes in [PackedByteArray([1, 2]), PackedByteArray([1, 2, 3, 4])]:
		_check(not ScalarData.validate(bytes, Vector2(0, 1), Vector3i(3, 1, 1)).is_empty(), "Short and long payloads are both rejected")
	for span in [Vector2(2, 1), Vector2(NAN, 1), Vector2(0, INF)]:
		_check(not ScalarData.validate_range(span).is_empty(), "Invalid scalar range is rejected")
	_check(not ScalarData.parse_range([true, 1]).error.is_empty(), "Booleans are not numeric scalar limits")
	_check(not ScalarData.parse_range([0, 1e100]).error.is_empty(), "Ranges outside Vector2's finite representation are rejected")
	if Vector2(1e10, 1e10 + 1).x == Vector2(1e10, 1e10 + 1).y:
		_check(not ScalarData.parse_range([1e10, 1e10 + 1]).error.is_empty(), "Distinct endpoints must not silently collapse to a constant range")
	if Vector2(1e-100, 0).x == 0.0:
		_check(not ScalarData.parse_range([1e-100, 1e-100]).error.is_empty(), "Nonzero endpoints must not silently underflow to zero")
	for box in [null, [], {origin = [1, 2]}, {size = [1, 0, 1]}, {axes = [[1, 0, 0], [1, 0, 0], [0, 0, 1]]}, {axes = [1, 2, 3]}, {origin = [0, INF, 0]}]:
		_check(not ScalarData.parse_box(box).error.is_empty(), "Malformed or non-invertible spatial metadata is rejected: %s" % str(box))
	_check(ScalarData.parse_box({origin = [-4, 2, 3], size = [2, 3, 4]}).error.is_empty(), "Finite translated and scaled boxes are accepted")
	var affine := ScalarData.parse_box({size = [-2, 3, 4], axes = [[1, 0.25, 0], [0, 2, 0], [0, 0, 1]]})
	_check(affine.error.is_empty() and affine.size == Vector3(-2, 3, 4) and affine.axes.x == Vector3(1, 0.25, 0), "Invertible reflection and shear retain their original box factors")
	var field := Meta.Field.new()
	field.range = Vector2(-3e38, 3e38)
	_check(is_finite(field.value_of(128)) and field.value_of(128) == 0.0, "Scalar decoding remains finite across extreme opposite endpoints")
	_check(is_nan(field.value_of(0)), "Zero remains a missing scalar sample")
	field.range = Vector2(0.1, 0.1)
	var exact_constant := true
	for byte in range(1, 256):
		exact_constant = exact_constant and field.value_of(byte) == field.range.x
	_check(exact_constant, "Every valid byte decodes exactly to a constant range endpoint")


func _bovs() -> void:
	var path := _bov()
	var result := BOV.read_checked(path)
	_check(result.error.is_empty() and result.value != null, "Valid BOV header and exact brick are accepted")
	if result.value != null:
		_check(result.value.cells == Vector3i(3, 1, 1) and result.value.range == Vector2(-2, 2) and result.value.time == -0.25, "BOV retains dimensions, signed range and solver time")
	_check(BOV.read(path) != null, "Legacy BOV.read still returns valid data")
	_check(BOV.read(_directory.path_join("missing.bov")) == null, "Legacy BOV.read returns null on failure")
	_check(BOV.read_checked(_bov({"VARIABLE PALETTE MIN": "5", "VARIABLE PALETTE MAX": "5"})).error.is_empty(), "BOV accepts constant ranges")
	_check(BOV.read_checked(_bov({"BRICK ORIGIN": "-1\t2\t3"})).error.is_empty(), "BOV accepts tab-separated finite vectors")
	for keys in [["TIME"], ["BRICK ORIGIN"], ["DATA SIZE"], ["DATA FILE"], ["DATA FORMAT"]]:
		_reject_bov(_bov({}, PackedByteArray([0, 1, 255]), keys), "Required BOV key is missing: %s" % keys[0])
	for change in [
		{"TIME": "abc"}, {"TIME": "1 2"}, {"TIME": "NaN"}, {"TIME": "1e999"}, {"TIME": "1e-999"},
		{"DATA SIZE": "3.5 1 1"}, {"DATA SIZE": "3 1"}, {"DATA SIZE": "3 1 1 1"},
		{"DATA SIZE": "3 -1 1"}, {"DATA SIZE": "65536 65536 1"},
		{"DATA FORMAT": "FLOAT"}, {"VARIABLE PALETTE MIN": "3", "VARIABLE PALETTE MAX": "2"},
		{"VARIABLE PALETTE MIN": "text"}, {"VARIABLE PALETTE MAX": "1e100"},
		{"BRICK ORIGIN": "0 0"}, {"BRICK SIZE": "0 1 1"}, {"BRICK SIZE": "1 1 inf"},
		{"BRICK Y_AXIS": "1 0 0"}, {"BRICK Z_AXIS": "0 0 0"},
		{"DATA FILE": "missing.bin"}, {"DATA FILE": ""},
		{"VARIABLE": " "},
		{"VARIABLE PALETTE MIN": "1e-999", "VARIABLE PALETTE MAX": "1e-999"},
	]:
		_reject_bov(_bov(change), "Invalid BOV metadata: %s" % str(change))
	_reject_bov(_bov({}, PackedByteArray([1, 2])), "BOV rejects a truncated brick")
	_reject_bov(_bov({}, PackedByteArray([1, 2, 3, 4])), "BOV rejects trailing brick bytes")
	path = _bov()
	_write(path, (FileAccess.get_file_as_string(path) + "TIME: 2\n").to_utf8_buffer())
	_reject_bov(path, "Duplicate BOV keys are rejected")
	path = _bov()
	_write(path, (FileAccess.get_file_as_string(path) + "malformed line\n").to_utf8_buffer())
	_reject_bov(path, "Malformed BOV lines are rejected")


func _manifests() -> void:
	var manifest := _manifest()
	manifest.frames = [{time = 5}, {time = -3}]
	var path := _archive(manifest)
	var meta := Meta.new()
	_check(meta.open(path).is_empty(), "A valid manifest with unsorted solver times opens")
	_check(meta.times == PackedFloat64Array([5, -3]), "Manifest frame order is preserved")
	_check(meta.read_checked("field.bin").bytes == PackedByteArray([0, 1, 255]), "Exact scalar payload is read unchanged")
	meta.close()
	manifest = _manifest()
	manifest.fields[0].box = {size = [-2, 3, 4], axes = [[1, 0.25, 0], [0, 2, 0], [0, 0, 1]]}
	_check(meta.open(_archive(manifest)).is_empty(), "A finite invertible affine field box opens")
	_check(meta.fields.size() == 1 and meta.fields[0].size == Vector3(-2, 3, 4) and meta.fields[0].axes.x == Vector3(1, 0.25, 0), "Meta preserves source size and axes without orthonormalizing")
	meta.close()
	for change in [
		{frames = null}, {frames = {}}, {frames = [null]}, {frames = [[]]},
		{frames = [{}]}, {frames = [{time = "1"}]}, {frames = [{time = true}]},
		{frames = [{time = INF}]}, {models = {}}, {models = [null]},
		{models = [{name = 7, path = "model.glb"}]}, {models = [{path = ["model.glb"]}]},
		{fields = {}}, {fields = [null]}, {attachments = {}}, {title = false}, {notes = []}, {field = 1},
	]:
		manifest = _manifest()
		manifest.merge(change, true)
		_reject_manifest(manifest, "Invalid manifest type: %s" % str(change))
	for change in [
		{range = []}, {range = [0]}, {range = "0 1"}, {range = ["0", 1]}, {range = [2, 1]},
		{range = [0, INF]}, {range = [0, 1e100]}, {cells = []}, {cells = [3, 1]},
		{cells = [3.5, 1, 1]}, {cells = [-3, 1, 1]}, {cells = [65536, 65536, 1]},
		{box = []}, {box = {origin = [0, 0]}}, {box = {size = [0, 1, 1]}},
		{box = {axes = []}}, {box = {axes = [[1, 0, 0], [1, 0, 0], [0, 0, 1]]}},
		{name = []}, {quantity = 1}, {unit = false}, {path = null},
	]:
		manifest = _manifest()
		manifest.fields[0].merge(change, true)
		_reject_manifest(manifest, "Invalid manifest field metadata: %s" % str(change))
	for bytes in [PackedByteArray([1, 2]), PackedByteArray([1, 2, 3, 4])]:
		path = _archive(_manifest(), bytes)
		_check(not meta.open(path).is_empty(), "Manifest rejects short and long declared brick sizes without reading the payload")
	manifest = _manifest()
	manifest.fields[0].range = [2, 2]
	_check(meta.open(_archive(manifest, PackedByteArray([0, 0, 0]))).is_empty(), "All-missing brick and constant range remain valid")
	meta.close()
	path = _archive(_manifest())
	var damaged := FileAccess.get_file_as_bytes(path)
	# Corrupt only the field's CRC, keeping its declared and actual sizes equal.
	for offset in range(damaged.size() - 46):
		if damaged.decode_u32(offset) == 0x02014b50:
			var length := damaged.decode_u16(offset + 28)
			if damaged.slice(offset + 46, offset + 46 + length).get_string_from_utf8() == "field.bin":
				var crc := damaged.decode_u32(offset + 16) ^ 1
				damaged.encode_u32(offset + 16, crc)
				damaged.encode_u32(damaged.decode_u32(offset + 42) + 14, crc)
				break
	_write(path, damaged)
	_check(meta.open(path).is_empty(), "Opening validates declared grid sizes without inflating every field")
	var result := meta.read_checked("field.bin")
	_check(not result.error.is_empty() and result.bytes.is_empty(), "A same-size corrupt brick fails checked reading")
	meta.close()


func _reject_bov(path: String, message: String) -> void:
	var result := BOV.read_checked(path)
	_check(result.value == null and not result.error.is_empty() and path.get_file() in result.error, message)


func _reject_manifest(manifest: Variant, message: String) -> void:
	var meta := Meta.new()
	var path := _archive(manifest)
	var before := FileAccess.get_sha256(path)
	_check(not meta.open(path).is_empty(), message)
	_check(not meta.read_checked("model.glb").error.is_empty() and FileAccess.get_sha256(path) == before, "Failed manifest opening closes the archive and leaves it unchanged")
	meta.close()


func _manifest() -> Dictionary:
	return {title = "Validation fixture", frames = [{time = 0}], models = [{name = "Model", path = "model.glb"}], fields = [{name = "B", range = [-2, 2], cells = [3, 1, 1], box = {origin = [0, 0, 0], size = [1, 1, 1]}, path = "field.bin"}]}


func _archive(manifest: Variant, bytes: PackedByteArray = PackedByteArray([0, 1, 255])) -> String:
	_serial += 1
	var path := _directory.path_join("fixture-%d.zip" % _serial)
	var zip := ZIPPacker.new()
	zip.open(path)
	var entries := {"meta.json": JSON.stringify(manifest).to_utf8_buffer(), "model.glb": PackedByteArray([1]), "field.bin": bytes}
	for name in entries:
		zip.start_file(name)
		zip.write_file(entries[name])
		zip.close_file()
	zip.close()
	return path


func _bov(changes: Dictionary = {}, bytes: PackedByteArray = PackedByteArray([0, 1, 255]), omitted: Array = []) -> String:
	_serial += 1
	var path := _directory.path_join("fixture-%d.bov" % _serial)
	var payload := "fixture-%d.bin" % _serial
	_write(_directory.path_join(payload), bytes)
	var lines := {"TIME": "-0.25", "VARIABLE": "B", "DATA SIZE": "3 1 1", "DATA FORMAT": "BYTES", "DATA FILE": payload, "BRICK ORIGIN": "0 0 0", "VARIABLE PALETTE MIN": "-2", "VARIABLE PALETTE MAX": "2"}
	lines.merge(changes, true)
	for key in omitted:
		lines.erase(key)
	var text := "# Scalar validation fixture\n"
	for key in lines:
		text += "%s: %s\n" % [key, lines[key]]
	_write(path, text.to_utf8_buffer())
	return path


func _write(path: String, bytes: PackedByteArray) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_buffer(bytes)
	file.close()
