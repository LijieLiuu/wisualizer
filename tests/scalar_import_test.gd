extends SceneTree
## Isolated regressions for batch import semantics and safe scalar sampling.
const Draft := preload("res://app/draft.gd")
const Touch := preload("res://app/field_touch.gd")
var _root := ""
var _checks := 0
var _failures := 0

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	_root = OS.get_cache_dir().path_join("wisualizer-scalar-import-%d-%d" % [OS.get_process_id(), Time.get_ticks_usec()])
	DirAccess.make_dir_recursive_absolute(_root)
	_test_imports()
	_test_reads()
	_test_round_trip()
	_test_touch()
	print("Scalar import: %d checks, %d failures" % [_checks, _failures])
	_remove_tree(_root)
	quit(1 if _failures else 0)

func _check(ok: bool, label: String) -> void:
	_checks += 1
	if not ok:
		_failures += 1
		push_error("FAIL: " + label)

func _header(name: String, time: String, variable := "B", span := "-2 2", dimensions := "2 2 1", origin := "10 20 30") -> String:
	var data := _root.path_join(name + ".bin")
	var handle := FileAccess.open(data, FileAccess.WRITE)
	handle.store_buffer(PackedByteArray([0, 1, 128, 255]))
	handle.close()
	var path := _root.path_join(name + ".bov")
	handle = FileAccess.open(path, FileAccess.WRITE)
	var ranges := span.split(" ")
	handle.store_string("TIME: %s\nVARIABLE: %s\nDATA SIZE: %s\nDATA FORMAT: BYTES\nDATA FILE: %s\nBRICK ORIGIN: %s\nBRICK SIZE: 4 2 1\nVARIABLE PALETTE MIN: %s\nVARIABLE PALETTE MAX: %s\n" % [time, variable, dimensions, data.get_file(), origin, ranges[0], ranges[1]])
	handle.close()
	return path

func _snapshot(draft) -> Dictionary:
	var fields := []
	for field in draft.fields:
		fields.append([field.get_instance_id(), field.name, field.quantity, field.unit, field.range, field.cells, field.origin, field.size, field.axes, field.bricks.duplicate()])
	return {times = draft.times.duplicate(), auto_frame = draft.auto_frame, first_field = draft.first_field, fields = fields}

func _rejected(draft, paths: PackedStringArray, label: String) -> void:
	var before := _snapshot(draft)
	_check(not draft.add_bovs(paths).is_empty(), label + " reports an error")
	_check(_snapshot(draft) == before, label + " leaves every existing field and frame unchanged")

func _test_imports() -> void:
	var first := _header("first", "1.5")
	var second := _header("second", "7")
	var draft := Draft.new()
	_check(draft.add_bovs(PackedStringArray([second, first])).is_empty(), "Complete valid batch imports")
	_check(draft.times == PackedFloat64Array([1.5, 7]), "Initial solver timeline comes from input times")
	_check(draft.fields.size() == 1 and draft.fields[0].bricks.size() == 2, "Both distinct time steps retained")
	_check(draft.fields[0].origin == Vector3(10,20,30) and draft.fields[0].size == Vector3(4,2,1), "Source spatial box retained without automatic fitting")
	_check(draft.fields[0].bricks[0].ends_with("first.bin") and draft.fields[0].bricks[1].ends_with("second.bin"), "Data placed by matching time")
	_rejected(draft, PackedStringArray([first]), "Existing frame cannot be overwritten")
	_rejected(draft, PackedStringArray([_header("unmatched", "1.6")]), "Nearby time is not silently rounded onto a frame")
	_rejected(draft, PackedStringArray([_header("newfield", "1.5", "Other"), second]), "Late collision rolls back an earlier staged field")
	var reordered := Draft.new()
	reordered.times = PackedFloat64Array([7,1.5])
	_check(reordered.add_bovs(PackedStringArray([first,second])).is_empty(), "Unsorted existing timeline is supported")
	_check(reordered.times == PackedFloat64Array([7,1.5]) and reordered.fields[0].bricks[0].ends_with("second.bin"), "Existing frame order is preserved")
	var duplicate_times := Draft.new()
	duplicate_times.times = PackedFloat64Array([1.5,1.5])
	_rejected(duplicate_times, PackedStringArray([first]), "Duplicate matching frame times are ambiguous")
	var same_time := _header("same-time", "1.5")
	_rejected(Draft.new(), PackedStringArray([first,same_time]), "Duplicate field/time inside a new batch")
	var provisional := Draft.new()
	provisional.times = PackedFloat64Array([0])
	provisional.auto_frame = true
	_rejected(provisional, PackedStringArray([first,_header("range-change", "7", "B", "0 10")]), "Different range on a later frame")
	_rejected(provisional, PackedStringArray([first,_header("grid-change", "7", "B", "-2 2", "1 4 1")]), "Different grid on a later frame")
	_rejected(provisional, PackedStringArray([first,_header("origin-change", "7", "B", "-2 2", "2 2 1", "0 0 0")]), "Different spatial box on a later frame")
	_rejected(provisional, PackedStringArray([first,_root.path_join("missing.bov")]), "Missing last header")
	_check(provisional.add_bovs(PackedStringArray([first,second])).is_empty(), "Valid batch replaces a provisional static frame")
	_check(not provisional.auto_frame and provisional.times == PackedFloat64Array([1.5,7]), "Provisional flag changes only after success")
	var independent := Draft.new()
	_check(independent.add_bovs(PackedStringArray([first,_header("other", "1.5", "Other")])).is_empty(), "Distinct variables can share a solver time")
	_check(independent.fields.size() == 2, "Both variables retained")
	var invalid_existing := Draft.new()
	invalid_existing.times = PackedFloat64Array([INF])
	_rejected(invalid_existing, PackedStringArray([first]), "Nonfinite existing frame time")

func _test_reads() -> void:
	var draft := Draft.new()
	draft.times = PackedFloat64Array([0,10])
	var header := _header("read", "0")
	_check(draft.add_bovs(PackedStringArray([header])).is_empty(), "Import one of two scalar frames")
	var field = draft.fields[0]
	_check(draft.read_brick_checked(field,0).bytes == PackedByteArray([0,1,128,255]), "Verified read preserves actual sample bytes")
	var missing: Dictionary = draft.read_brick_checked(field,1)
	_check(missing.error.is_empty() and missing.bytes == PackedByteArray([0,0,0,0]), "Unassigned frame explicitly contains missing samples")
	_check(not draft.read_brick_checked(field,2).error.is_empty(), "Out-of-range frame rejected")
	var handle := FileAccess.open(field.bricks[0],FileAccess.WRITE)
	handle.store_buffer(PackedByteArray([1,2]))
	handle.close()
	_check(not draft.read_brick_checked(field,0).error.is_empty(), "Source truncated after import is rejected")
	handle = FileAccess.open(field.bricks[0],FileAccess.WRITE)
	handle.store_buffer(PackedByteArray([1,2,3,4,5]))
	handle.close()
	_check(not draft.read_brick_checked(field,0).error.is_empty(), "Trailing source bytes rejected")
	DirAccess.remove_absolute(field.bricks[0])
	_check(not draft.read_brick_checked(field,0).error.is_empty(), "Source removed after import is rejected")
	_check(draft.source_files().has(field.bricks[0]), "Exporter can identify local brick sources")
	field.range = Vector2(INF,2)
	_check(not draft.read_brick_checked(field,1).error.is_empty(), "Even missing frames require valid scalar metadata")

func _test_round_trip() -> void:
	var draft := Draft.new()
	draft.times = PackedFloat64Array([0.10000000000000002,1.2345678901234567])
	var times := draft.times.duplicate()
	var json := '{"asset":{"version":"2.0"},"scene":0,"scenes":[{}]}'.to_utf8_buffer()
	while json.size() % 4:
		json.append(32)
	var glb := PackedByteArray()
	glb.resize(20)
	glb.encode_u32(0,0x46546c67)
	glb.encode_u32(4,2)
	glb.encode_u32(8,20+json.size())
	glb.encode_u32(12,json.size())
	glb.encode_u32(16,0x4e4f534a)
	var model := _root.path_join("model.glb")
	var handle := FileAccess.open(model,FileAccess.WRITE)
	handle.store_buffer(glb+json)
	handle.close()
	_check(draft.add_glbs(PackedStringArray([model])).is_empty(), "Add model to round-trip scalar fixture")
	var header := _header("precise", "0.10000000000000002")
	_check(draft.add_bovs(PackedStringArray([header])).is_empty(), "Exact high-precision BOV solver time matches the frame")
	var axes := Basis(Vector3(-1,0,0),Vector3(0.25,1,0),Vector3(0,0.1,1))
	var size := Vector3(2,3,4)
	draft.fields[0].axes = axes
	draft.fields[0].size = size
	var target := _root.path_join("scalar.zip")
	_check(draft.save(target).is_empty(), "Save an oblique reflected field and missing frame")
	_check(draft.times == times, "Save and reopen preserve full double solver-time precision")
	_check(draft.fields[0].axes == axes and draft.fields[0].size == size and draft.fields[0].origin == Vector3(10,20,30), "Save and reopen preserve exact affine factors")
	_check(draft.read_brick_checked(draft.fields[0],0).bytes == PackedByteArray([0,1,128,255]), "Verified ZIP reads preserve scalar bytes")
	_check(draft.read_brick_checked(draft.fields[0],1).bytes == PackedByteArray([0,0,0,0]), "Saved missing frame remains explicitly missing")
	var previous := FileAccess.get_file_as_bytes(target)
	var broken := _root.path_join("changed.bin")
	handle = FileAccess.open(broken,FileAccess.WRITE)
	handle.store_buffer(PackedByteArray([1,2]))
	handle.close()
	draft.fields[0].bricks[0] = broken
	_check(not draft.save(target).is_empty(), "A short source introduced after import cannot be saved")
	_check(FileAccess.get_file_as_bytes(target) == previous, "Invalid changed source preserves the existing ZIP")
	_check(draft.fields[0].bricks[0] == broken, "Rejected save retains the editable draft")
	handle = FileAccess.open(broken,FileAccess.WRITE)
	handle.store_buffer(PackedByteArray([1,2,3,4]))
	handle.close()
	_check(draft.save(target).is_empty(), "Corrected source can be retried successfully")
	draft.close()

func _test_touch() -> void:
	var touch := Touch.new()
	touch.set_brick(PackedByteArray([0,1,128,255]),Vector3i(2,2,1),255)
	_check(touch.byte_of(Vector3i(1,1,0)) == 255, "Valid cell samples x-fastest grid")
	_check(touch.byte_of(Vector3i(-1,0,0)) == 0 and touch.byte_of(Vector3i(2,0,0)) == 0, "Outside cells return missing")
	_check(touch.cell_at(Vector3.ZERO) == touch.NO_CELL, "Unbound field cannot be sampled")
	var revision: int = touch.revision
	touch.set_brick(PackedByteArray([1]),Vector3i(2,2,1),255)
	_check(touch.bytes.is_empty() and touch.byte_of(Vector3i(1,1,0)) == 0, "Truncated brick clears stale sample data")
	_check(touch.revision == revision+1, "Cleared brick updates probe revision")
	touch.set_brick(PackedByteArray([1,2]),Vector3i(1,1,1),255)
	_check(touch.bytes.is_empty(), "Overlong brick cannot be sampled")
	touch.set_brick(PackedByteArray([1]),Vector3i(-1,1,1),255)
	_check(touch.bytes.is_empty(), "Invalid dimensions cannot be sampled")
	var box := Node3D.new()
	root.add_child(box)
	touch.field = box
	touch.set_brick(PackedByteArray([0,1,128,255]),Vector3i(2,2,1),255)
	_check(touch.cell_at(Vector3(0.75,0.75,0.5)) == Vector3i(1,1,0), "Live spatial box maps a point to the right cell")
	_check(touch.cell_at(Vector3(1,0.5,0.5)) == touch.NO_CELL, "Upper grid boundary is outside")
	_check(touch.cell_at(Vector3(1e30,0,0)) == touch.NO_CELL, "Distant points rejected before integer conversion")
	_check(touch.cell_at(Vector3(NAN,0,0)) == touch.NO_CELL, "Nonfinite sample points rejected")
	box.transform = Transform3D(Basis(Vector3.ZERO,Vector3.UP,Vector3.BACK),Vector3.ZERO)
	_check(touch.cell_at(Vector3.ZERO) == touch.NO_CELL, "Singular live transform cannot be inverted for sampling")
	box.free()
	touch.free()

func _remove_tree(path: String) -> void:
	for file in DirAccess.get_files_at(path):
		DirAccess.remove_absolute(path.path_join(file))
	for folder in DirAccess.get_directories_at(path):
		_remove_tree(path.path_join(folder))
	DirAccess.remove_absolute(path)
