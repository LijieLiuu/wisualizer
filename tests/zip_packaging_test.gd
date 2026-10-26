extends SceneTree
## Run with the project's Godot build:
## godot --headless --path . --script res://tests/zip_packaging_test.gd
## Fixtures are generated in a unique temporary directory, never in the library.

const Draft := preload("res://app/draft.gd")
const Meta := preload("res://app/meta.gd")

class FailedReplacement:
	extends "res://app/draft.gd"
	var fail_replace := false

	func _replace_zip(temporary: String, target: String) -> Error:
		return ERR_CANT_CREATE if fail_replace else super._replace_zip(temporary, target)

class FailedWrite:
	extends "res://app/draft.gd"
	var fail_write := false
	var write_count := 0

	func _store(packer: ZIPPacker, file: String, bytes: PackedByteArray) -> Error:
		if fail_write:
			write_count += 1
			if write_count == 2:
				return ERR_FILE_CANT_WRITE
		return super._store(packer, file, bytes)

var _checks := 0
var _failures := 0
var _root := ""
var _glb := PackedByteArray()
var _svg := '<svg xmlns="http://www.w3.org/2000/svg" width="2" height="2"><rect width="2" height="2" fill="red"/></svg>'.to_utf8_buffer()


func _initialize() -> void:
	var temporary := OS.get_environment("TMPDIR")
	if temporary.is_empty():
		temporary = "/tmp"
	_root = temporary.path_join("wisualizer-zip-tests-%d-%d" % [OS.get_process_id(), Time.get_ticks_usec()])
	_check(DirAccess.make_dir_recursive_absolute(_root) == OK, "Create isolated fixture directory")
	_glb = _triangle_glb()
	_test_notes_import()
	_test_attachment_import()
	_test_static_then_sequence()
	_test_round_trip()
	_test_legacy_archives()
	_test_nested_notes()
	_test_invalid_archives()
	_test_corrupt_attachment()
	_test_missing_sources()
	_test_failed_replacement()
	_test_failed_write()
	_test_failed_destination()
	print("ZIP packaging: %d checks, %d failures" % [_checks, _failures])
	if _failures == 0:
		_remove_tree(_root)
	else:
		print("Failure fixtures retained at: " + _root)
	quit(1 if _failures else 0)


func _check(condition: bool, message: String) -> bool:
	_checks += 1
	if not condition:
		_failures += 1
		push_error("FAIL: " + message)
	return condition


func _write(relative: String, bytes: PackedByteArray) -> String:
	var path := _root.path_join(relative)
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var file := FileAccess.open(path, FileAccess.WRITE)
	if not _check(file != null, "Write fixture " + relative):
		return path
	file.store_buffer(bytes)
	file.close()
	return path


func _triangle_glb() -> PackedByteArray:
	var binary := PackedByteArray()
	binary.resize(44)
	var coordinates := [0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0, 0.0]
	for index in coordinates.size():
		binary.encode_float(index * 4, coordinates[index])
	for index in 3:
		binary.encode_u16(36 + index * 2, index)
	var json := JSON.stringify({
		"asset": {"version": "2.0"}, "scene": 0, "scenes": [{"nodes": [0]}],
		"nodes": [{"mesh": 0}], "meshes": [{"primitives": [{"attributes": {"POSITION": 0}, "indices": 1}]}],
		"buffers": [{"byteLength": 42}],
		"bufferViews": [{"buffer": 0, "byteOffset": 0, "byteLength": 36, "target": 34962}, {"buffer": 0, "byteOffset": 36, "byteLength": 6, "target": 34963}],
		"accessors": [{"bufferView": 0, "componentType": 5126, "count": 3, "type": "VEC3", "min": [0, 0, 0], "max": [1, 1, 0]}, {"bufferView": 1, "componentType": 5123, "count": 3, "type": "SCALAR"}],
	}).to_utf8_buffer()
	while json.size() % 4:
		json.append(32)
	var header := PackedByteArray()
	header.resize(20)
	header.encode_u32(0, 0x46546C67)
	header.encode_u32(4, 2)
	header.encode_u32(8, 20 + json.size() + 8 + binary.size())
	header.encode_u32(12, json.size())
	header.encode_u32(16, 0x4E4F534A)
	var binary_header := PackedByteArray()
	binary_header.resize(8)
	binary_header.encode_u32(0, binary.size())
	binary_header.encode_u32(4, 0x004E4942)
	return header + json + binary_header + binary


func _seed(draft, folder: String) -> void:
	var path := _write(folder.path_join("triangle.glb"), _glb)
	_check(draft.add_glbs(PackedStringArray([path])).is_empty(), "Import a static GLB")
	_check(draft.models.size() == 1 and draft.times == PackedFloat64Array([0.0]), "Static GLB initializes a playable frame")
	draft.title = "Packaging fixture"
	draft.notes = "[b]Original notes[/b]"


func _test_notes_import() -> void:
	var text := "Velocity: 速度\nμ = 0.001\n[math]v_x[/math]\n"
	var plain := _write("notes/plain.txt", text.to_utf8_buffer())
	var result: Dictionary = Draft.read_notes_file(plain)
	_check(result.error.is_empty() and result.text == text, "Import Unicode UTF-8 notes without changing BBCode")
	var bom := _write("notes/bom.txt", PackedByteArray([0xEF, 0xBB, 0xBF]) + text.to_utf8_buffer())
	result = Draft.read_notes_file(bom)
	_check(result.error.is_empty() and result.text == text, "Strip a UTF-8 BOM")
	var empty := _write("notes/empty.txt", PackedByteArray())
	result = Draft.read_notes_file(empty)
	_check(result.error.is_empty() and result.text.is_empty(), "Empty text is a valid import")
	for malformed in [PackedByteArray([0xC3, 0x28]), PackedByteArray([0xE2, 0x82]), PackedByteArray([0xC0, 0xAF]), PackedByteArray([0xED, 0xA0, 0x80]), PackedByteArray([0xF4, 0x90, 0x80, 0x80]), PackedByteArray([65, 0, 66])]:
		var invalid := _write("notes/invalid.txt", malformed)
		result = Draft.read_notes_file(invalid)
		_check(not result.error.is_empty(), "Reject invalid UTF-8 or embedded NUL: " + malformed.hex_encode())
	result = Draft.read_notes_file(_root.path_join("notes/missing.txt"))
	_check(not result.error.is_empty(), "Missing TXT reports an error")


func _test_attachment_import() -> void:
	var draft := Draft.new()
	var first := _write("imports/a/Velocity.CSV", "x,y,z,vx,vy,vz\n0,0,0,1,2,3\n".to_utf8_buffer())
	var duplicate := _write("imports/b/velocity.csv", "different".to_utf8_buffer())
	var other := _write("imports/b/other.vec", PackedByteArray([0, 128, 255]))
	_check(not draft.add_attachments(PackedStringArray([first, duplicate])).is_empty(), "Reject case-insensitive duplicate names in one batch")
	_check(draft.attachments.is_empty(), "Rejected duplicate batch adds nothing")
	_check(draft.add_attachments(PackedStringArray([first])).is_empty(), "Import a vector CSV as an opaque attachment")
	var before: Dictionary = draft.attachments.duplicate()
	_check(not draft.add_attachments(PackedStringArray([other, duplicate])).is_empty(), "Reject collision with an existing attachment")
	_check(draft.attachments == before, "Existing-name collision keeps the entire prior attachment set")
	_check(not draft.add_attachments(PackedStringArray([other, _root.path_join("imports/missing.vec")])).is_empty(), "Reject a batch containing a missing source")
	_check(draft.attachments == before, "Missing-source batch is atomic")
	_check(not draft.add_attachments(PackedStringArray([_root.path_join("imports")])).is_empty(), "A directory is not an attachment")
	var unicode := _write("imports/速度 data.txt", "0 0 0 1 2 3\n".to_utf8_buffer())
	_check(draft.add_attachments(PackedStringArray([unicode])).is_empty(), "Preserve spaces and Unicode in attachment names")
	_check(draft.attachments.has("attachments/速度 data.txt"), "Imported attachments have archive-relative paths")
	var oversized_path := _root.path_join("imports/too-large.vec")
	var oversized := FileAccess.open(oversized_path, FileAccess.WRITE)
	if _check(oversized != null, "Create a sparse oversized-file fixture"):
		oversized.seek(0x7fffffff)
		oversized.store_8(0)
		_check(oversized.get_length() == 0x80000000, "Sparse fixture declares 2 GiB without allocating a byte array")
		oversized.close()
		before = draft.attachments.duplicate()
		_check(not draft.add_attachments(PackedStringArray([oversized_path])).is_empty(), "Reject a file too large for the ZIP reader before import")
		_check(draft.attachments == before, "Oversized-file rejection leaves existing attachments intact")
		DirAccess.remove_absolute(oversized_path)
	draft.close()


func _test_static_then_sequence() -> void:
	var draft := Draft.new()
	_seed(draft, "sequence/source")
	var paths := PackedStringArray([
		_write("sequence/source/flow0001.glb", _glb),
		_write("sequence/source/flow0002.glb", _glb),
	])
	_check(draft.add_glbs(paths).is_empty(), "Import an animated sequence after a static model")
	_check(draft.times == PackedFloat64Array([0.0, 1.0]), "A sequence replaces the automatic single-frame timeline")
	_check(draft.models.size() == 2 and draft.models[0].files.size() == 1 and draft.models[1].files.size() == 2, "Static and animated models coexist")
	_check(draft.save(_root.path_join("sequence/package.zip")).is_empty(), "A mixed static/animated package saves successfully")
	draft.close()
	var scalar := Draft.new()
	_seed(scalar, "bov/source")
	var headers := PackedStringArray()
	for index in 2:
		var data_name := "brick%04d.bin" % index
		_write("bov/source/" + data_name, PackedByteArray([index + 1, 255]))
		var header := "TIME: %d\nBRICK ORIGIN: 0 0 0\nDATA SIZE: 2 1 1\nDATA FORMAT: BYTES\nVARIABLE: Magnitude\nDATA FILE: %s\n" % [index, data_name]
		headers.append(_write("bov/source/frame%04d.bov" % index, header.to_utf8_buffer()))
	_check(scalar.add_bovs(headers).is_empty(), "Import scalar BOV frames after a static model")
	_check(scalar.times == PackedFloat64Array([0.0, 1.0]) and scalar.fields.size() == 1 and scalar.fields[0].bricks.size() == 2, "BOV frames replace the automatic timeline without dropping either brick")
	_check(scalar.save(_root.path_join("bov/package.zip")).is_empty(), "Static geometry plus scalar BOV frames saves successfully")
	scalar.close()


func _zip_entries(path: String) -> Dictionary:
	var zip := ZIPReader.new()
	if not _check(zip.open(path) == OK, "Open generated ZIP: " + path.get_file()):
		return {}
	var result := {}
	for name in zip.get_files():
		result[name] = zip.read_file(name)
	zip.close()
	return result


func _test_round_trip() -> void:
	var draft := Draft.new()
	_seed(draft, "roundtrip/source")
	var expected := {
		"attachments/velocity.csv": "x,y,z,vx,vy,vz\n0,0,0,1,2,3\n".to_utf8_buffer(),
		"attachments/velocity.txt": "# opaque vector source\n0 0 0 1 2 3\n".to_utf8_buffer(),
		"attachments/raw.vec": PackedByteArray([0, 255, 128, 1, 13, 10]),
		"attachments/empty.dat": PackedByteArray(),
	}
	var large := PackedByteArray()
	large.resize(2 * 1024 * 1024 + 17)
	large.fill(0xA5)
	large[0] = 0
	large[1024 * 1024 - 1] = 0x11
	large[1024 * 1024] = 0x22
	large[-1] = 0xFF
	expected["attachments/multi-chunk.vec"] = large
	var inputs := PackedStringArray()
	for name: String in expected:
		inputs.append(_write("roundtrip/source/" + name.get_file(), expected[name]))
	_check(draft.add_attachments(inputs).is_empty(), "Import text, binary and empty attachments together")
	var image_path := _write("roundtrip/source/diagram.svg", _svg)
	draft.add_images(PackedStringArray([image_path]))
	draft.notes = "[b]速度[/b]\n[img]images/diagram.svg[/img]\n[url=frame:1]Inspect[/url]"
	var field := Draft.Field.new()
	field.name = "Magnitude"
	field.cells = Vector3i(2, 1, 1)
	field.range = Vector2(-2.0, 2.0)
	field.bricks[0] = _write("roundtrip/source/magnitude.bin", PackedByteArray([1, 255]))
	draft.fields.append(field)
	var target := _root.path_join("roundtrip/package.zip")
	if not _check(draft.save(target).is_empty(), "Save a complete viewer-compatible package"):
		draft.close()
		return
	var entries := _zip_entries(target)
	if not _check(entries.has("meta.json"), "Package has a manifest"):
		draft.close()
		return
	var manifest: Dictionary = JSON.parse_string(entries["meta.json"].get_string_from_utf8())
	_check(manifest.get("attachments", []).size() == expected.size(), "Manifest lists every attachment")
	_check(entries[manifest.models[0].path] == _glb, "GLB bytes are unchanged")
	_check(entries["images/diagram.svg"] == _svg, "Image bytes are unchanged")
	_check(entries[manifest.notes].get_string_from_utf8() == draft.notes, "Notes and image/frame tags survive packaging")
	for name: String in expected:
		_check(entries.has(name) and entries[name] == expected[name], "Exact attachment bytes: " + name)
		_check(name in manifest.attachments, "Attachment is discoverable in the manifest: " + name)
	var original_notes: String = draft.notes
	draft.close()
	var reopened := Draft.new()
	if not _check(reopened.open(target).is_empty(), "Reopen the saved package"):
		return
	_check(reopened.attachments.size() == expected.size(), "Recognized model, notes, field and image files are not duplicated as attachments")
	_check(reopened.fields.size() == 1 and reopened.read_source(reopened.fields[0].bricks[0]) == PackedByteArray([1, 255]), "Scalar field bytes remain available")
	_remove_tree(_root.path_join("roundtrip/source"))
	_check(reopened.save(target).is_empty(), "Resave after every original source file is removed")
	var copy_path := _root.path_join("roundtrip/copied.zip")
	_check(reopened.save(copy_path).is_empty(), "Save As remains independent of original files")
	var copied := _zip_entries(copy_path)
	for name: String in expected:
		_check(copied.has(name) and copied[name] == expected[name], "Save As preserves attachment bytes: " + name)
	_check(reopened.notes == original_notes, "Save and Save As preserve authored notes")
	reopened.close()
	_check(DirAccess.remove_absolute(target) == OK, "Remove the original ZIP after Save As")
	var independent := Draft.new()
	_check(independent.open(copy_path).is_empty(), "Copied ZIP is self-contained")
	for name: String in expected:
		_check(independent.attachments.has(name) and independent.read_source(independent.attachments[name]) == expected[name], "Copied ZIP supplies attachment without old ZIP: " + name)
	independent.close()


func _make_zip(path: String, manifest: Dictionary, extra: Dictionary = {}) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var packer := ZIPPacker.new()
	if not _check(packer.open(path) == OK, "Create archive fixture"):
		return
	var notes_path: String = manifest.get("notes", "notes.txt")
	var contents := {"meta.json": JSON.stringify(manifest).to_utf8_buffer(), "models/triangle.glb": _glb}
	contents[notes_path] = "Existing notes".to_utf8_buffer()
	contents[notes_path.get_base_dir().path_join("images/diagram.svg")] = _svg
	contents.merge(extra, true)
	for name: String in contents:
		_check(packer.start_file(name) == OK, "Start archive fixture entry " + name)
		_check(packer.write_file(contents[name]) == OK, "Write archive fixture entry " + name)
		_check(packer.close_file() == OK, "Close archive fixture entry " + name)
	_check(packer.close() == OK, "Close archive fixture")


func _manifest() -> Dictionary:
	return {"title": "Existing package", "frames": [{"time": 0}], "models": [{"name": "Triangle", "path": "models/triangle.glb"}], "notes": "notes.txt"}


func _test_legacy_archives() -> void:
	for listed in [false, true]:
		var manifest := _manifest()
		var extra := {"legacy/velocity.vec": PackedByteArray([0, 1, 254, 255]), "source/readme.txt": "Keep this raw source".to_utf8_buffer()}
		if listed:
			manifest.attachments = ["legacy/velocity.vec"]
		var path := _root.path_join("legacy/%s.zip" % str(listed))
		_make_zip(path, manifest, extra)
		var draft := Draft.new()
		if not _check(draft.open(path).is_empty(), "Open an older package with listed=%s" % str(listed)):
			continue
		_check(draft.attachments.size() == 2, "Both listed and unrecognized files remain attachments")
		_check(draft.save(path).is_empty(), "Resave an older package without dropping unknown files")
		var result := _zip_entries(path)
		for name: String in extra:
			_check(result.has(name) and result[name] == extra[name], "Preserve original archive-relative path and bytes: " + name)
		draft.close()


func _test_nested_notes() -> void:
	var manifest := _manifest()
	manifest.notes = "docs/lesson.txt"
	var notes := "[img]images/diagram.svg[/img]\n[img]plots/other.svg[/img]"
	var path := _root.path_join("nested/package.zip")
	_make_zip(path, manifest, {"docs/lesson.txt": notes.to_utf8_buffer(), "docs/plots/other.svg": _svg})
	var draft := Draft.new()
	if not _check(draft.open(path).is_empty(), "Open notes with images in nested ZIP folders"):
		return
	_check(draft.notes_path == "docs/lesson.txt" and draft.notes == notes, "Retain nested notes location and relative references")
	_check(draft.images.has("diagram.svg"), "Discover images relative to the notes folder")
	_check(draft.attachments.has("docs/plots/other.svg"), "Keep an image outside the standard images folder as an attachment")
	_check(draft.read_file("docs/images/diagram.svg") == _svg, "Standard image remains available to the editor preview")
	_check(draft.read_file("docs/plots/other.svg") == _svg, "Attachment image remains available to the editor preview")
	_check(draft.save(path).is_empty(), "Resave nested notes and both image locations")
	var result := _zip_entries(path)
	_check(result.has("docs/lesson.txt") and result["docs/lesson.txt"].get_string_from_utf8() == notes, "Saving preserves nested notes and their relative paths")
	_check(result.has("docs/images/diagram.svg") and result["docs/images/diagram.svg"] == _svg, "Saving preserves standard nested image bytes")
	_check(result.has("docs/plots/other.svg") and result["docs/plots/other.svg"] == _svg, "Saving preserves the custom image folder")
	draft.close()


func _test_invalid_archives() -> void:
	for unsafe in ["../outside.vec", "/absolute.vec", "attachments/../outside.vec"]:
		var manifest := _manifest()
		manifest.attachments = [unsafe]
		var path := _root.path_join("invalid/path-%d.zip" % _checks)
		_make_zip(path, manifest, {unsafe: PackedByteArray([1])})
		var draft := Draft.new()
		_check(not draft.open(path).is_empty(), "Reject unsafe attachment path: " + unsafe)
		draft.close()
	var missing := _manifest()
	missing.attachments = ["attachments/missing.vec"]
	var path := _root.path_join("invalid/missing.zip")
	_make_zip(path, missing)
	var draft := Draft.new()
	_check(not draft.open(path).is_empty(), "Reject a listed attachment missing from the archive")
	draft.close()


func _corrupt_crc(path: String, name: String) -> bool:
	var bytes := FileAccess.get_file_as_bytes(path)
	var end := bytes.size() - 22
	if not _check(end >= 0 and bytes.decode_u32(end) == 0x06054B50, "Corruption fixture has a standard ZIP end record"):
		return false
	var cursor := int(bytes.decode_u32(end + 16))
	while cursor + 46 <= end and bytes.decode_u32(cursor) == 0x02014B50:
		var length := bytes.decode_u16(cursor + 28)
		var found := bytes.slice(cursor + 46, cursor + 46 + length).get_string_from_utf8()
		if found == name:
			var invalid_crc := bytes.decode_u32(cursor + 16) ^ 1
			bytes.encode_u32(cursor + 16, invalid_crc)
			var local_offset := int(bytes.decode_u32(cursor + 42))
			bytes.encode_u32(local_offset + 14, invalid_crc)
			var file := FileAccess.open(path, FileAccess.WRITE)
			if not _check(file != null, "Open the CRC corruption fixture for modification"):
				return false
			file.store_buffer(bytes)
			file.close()
			return true
		cursor += 46 + length + bytes.decode_u16(cursor + 30) + bytes.decode_u16(cursor + 32)
	_check(false, "Find the attachment to corrupt")
	return false


func _test_corrupt_attachment() -> void:
	var manifest := _manifest()
	manifest.attachments = ["attachments/vector.vec"]
	var path := _root.path_join("corrupt/package.zip")
	_make_zip(path, manifest, {"attachments/vector.vec": PackedByteArray([1, 2, 3, 4, 5])})
	if not _corrupt_crc(path, "attachments/vector.vec"):
		return
	var original := FileAccess.get_file_as_bytes(path)
	var draft := Draft.new()
	var opened: String = draft.open(path)
	if opened.is_empty():
		_check(not draft.save(path).is_empty(), "Corrupt attachment refuses to overwrite the source ZIP")
		var copy := _root.path_join("corrupt/copied.zip")
		_check(not draft.save(copy).is_empty() and not FileAccess.file_exists(copy), "Corrupt attachment cannot become an empty file in a new package")
	else:
		_check(true, "Corrupt attachment is rejected while opening")
	_check(FileAccess.get_file_as_bytes(path) == original, "CRC failure leaves the original archive unchanged")
	draft.close()


func _test_missing_sources() -> void:
	var draft := Draft.new()
	_seed(draft, "missing/source")
	var target := _root.path_join("missing/package.zip")
	if not _check(draft.save(target).is_empty(), "Create package for source-failure check"):
		draft.close()
		return
	var original := FileAccess.get_file_as_bytes(target)
	var vanished := _write("missing/source/vanished.vec", PackedByteArray([7, 8, 9]))
	_check(draft.add_attachments(PackedStringArray([vanished])).is_empty(), "Add attachment before source disappears")
	DirAccess.remove_absolute(vanished)
	draft.notes = "Unfinished edits must survive"
	_check(not draft.save(target).is_empty(), "Saving reports a disappeared source")
	_check(FileAccess.get_file_as_bytes(target) == original, "Missing source cannot replace the prior ZIP")
	_check(draft.notes == "Unfinished edits must survive" and draft.attachments.size() == 1, "Failed save keeps current edits and attachment references")
	_check(draft.read_source(draft.models[0].files[0]) == _glb, "Prior ZIP remains readable after source failure")
	draft.close()


func _test_failed_replacement() -> void:
	var draft := FailedReplacement.new()
	_seed(draft, "replacement/source")
	var source := _write("replacement/source/vector.vec", PackedByteArray([3, 2, 1]))
	_check(draft.add_attachments(PackedStringArray([source])).is_empty(), "Seed attachment for replacement failure")
	var target := _root.path_join("replacement/package.zip")
	if not _check(draft.save(target).is_empty(), "Create package before injected replacement failure"):
		draft.close()
		return
	var original := FileAccess.get_file_as_bytes(target)
	draft.notes = "Edited notes"
	draft.fail_replace = true
	_check(not draft.save(target).is_empty(), "Injected final rename failure is reported")
	_check(FileAccess.get_file_as_bytes(target) == original, "Final rename failure preserves the exact previous ZIP")
	_check(draft.notes == "Edited notes" and draft.read_source(draft.models[0].files[0]) == _glb, "Rename failure retains draft edits and usable ZIP sources")
	draft.fail_replace = false
	_check(draft.save(target).is_empty(), "Retry succeeds without reopening or losing edits")
	draft.close()


func _test_failed_write() -> void:
	var draft := FailedWrite.new()
	_seed(draft, "write/source")
	var target := _root.path_join("write/package.zip")
	if not _check(draft.save(target).is_empty(), "Create package before injected write failure"):
		draft.close()
		return
	var original := FileAccess.get_file_as_bytes(target)
	draft.notes = "Keep me after write failure"
	draft.fail_write = true
	_check(not draft.save(target).is_empty(), "Injected ZIP entry write failure is reported")
	_check(FileAccess.get_file_as_bytes(target) == original, "ZIP entry write failure preserves the old archive")
	_check(draft.notes == "Keep me after write failure" and draft.read_source(draft.models[0].files[0]) == _glb, "Write failure keeps the editable draft and open sources")
	draft.fail_write = false
	_check(draft.save(target).is_empty(), "A failed entry write can be retried")
	draft.close()


func _test_failed_destination() -> void:
	var draft := Draft.new()
	_seed(draft, "destination/source")
	var target := _root.path_join("destination/package.zip")
	_check(draft.save(target).is_empty(), "Create package before invalid Save As")
	var original := FileAccess.get_file_as_bytes(target)
	var invalid := _root.path_join("destination/folder.zip")
	DirAccess.make_dir_recursive_absolute(invalid)
	_check(not draft.save(invalid).is_empty(), "Reject a destination that is a directory")
	_check(DirAccess.dir_exists_absolute(invalid), "Failed save does not remove the destination directory")
	_check(FileAccess.get_file_as_bytes(target) == original, "Failed Save As preserves the original package")
	_check(draft.read_source(draft.models[0].files[0]) == _glb, "Failed Save As preserves readable model sources")
	draft.close()


func _remove_tree(path: String) -> void:
	for child in DirAccess.get_directories_at(path):
		_remove_tree(path.path_join(child))
	for child in DirAccess.get_files_at(path):
		DirAccess.remove_absolute(path.path_join(child))
	DirAccess.remove_absolute(path)
