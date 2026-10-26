extends SceneTree
## Metadata-only ZIP checks, including entries too large to inflate safely.
const ZipFiles := preload("res://app/zip_files.gd")
var _checks := 0
var _failures := 0
var _directory := "/private/tmp/wisualizer-zip-index-%d" % Time.get_ticks_usec()


func _initialize() -> void:
	DirAccess.make_dir_recursive_absolute(_directory)
	_run()
	for name in DirAccess.get_files_at(_directory):
		DirAccess.remove_absolute(_directory.path_join(name))
	DirAccess.remove_absolute(_directory)
	print("ZIP index checks: %d passed, %d failed" % [_checks - _failures, _failures])
	quit(0 if _failures == 0 else 1)


func _check(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(message)


func _run() -> void:
	var empty := _fixture("empty.zip", [])
	_check(_inspect(empty).error.is_empty(), "An empty ZIP has a valid empty index")
	var ordinary := _fixture("ordinary.zip", [
		{name = "模型.glb", data = PackedByteArray([1, 2, 3])},
		{name = "empty.txt", data = PackedByteArray()},
		{name = "folder", attributes = 0x41ed0010},
		{name = "folder/data.vec", data = PackedByteArray([7, 8])},
	])
	var index := _inspect(ordinary)
	_check(index.error.is_empty(), "UTF-8 names, empty files and no-slash directories index successfully")
	if index.error.is_empty():
		_check(index.entries["模型.glb"].size == 3, "The decoded UTF-8 name has its original size")
		_check(index.entries["empty.txt"].size == 0 and not index.entries["empty.txt"].directory, "An empty regular file remains a file")
		_check(index.entries["folder"].directory, "ZIPPacker-style Unix/DOS directory flags are recognized")
	var flags := _fixture("directory-flags.zip", [{name = "dos", attributes = 0x10}, {name = "unix", attributes = 0x40000000}, {name = "slash/"}])
	index = _inspect(flags)
	_check(index.error.is_empty() and index.entries.dos.directory and index.entries.unix.directory and index.entries["slash/"].directory, "Each directory representation is recognized")
	var parent := _fixture("parent.zip", [{name = "raw", data = PackedByteArray([1])}, {name = "raw/data", data = PackedByteArray([2])}])
	index = _inspect(parent)
	_check(index.error.is_empty() and not index.entries.raw.directory, "A nonempty parent-named file is not silently discarded as a directory")
	var commented := _fixture("comment.zip", [{name = "data", data = PackedByteArray([4])}], {comment = "A comment containing PK end-marker text".to_utf8_buffer()})
	_check(_inspect(commented).error.is_empty(), "An EOCD comment is accepted")
	var zip64 := _fixture("zip64.zip", [{name = "data", data = PackedByteArray([5, 6]), zip64 = true}], {zip64 = true})
	index = _inspect(zip64)
	_check(index.error.is_empty() and index.entries.data.size == 2, "ZIP64 end records and per-entry size fields are decoded")
	var large := _fixture("large.zip", [{name = "large.vec", data = PackedByteArray([0]), declared_size = 0x80000000}])
	var before := FileAccess.get_sha256(large)
	index = _inspect(large)
	_check(index.error.is_empty() and index.entries["large.vec"].size == 0x80000000, "A declared size over ZIPReader's 2 GB limit is indexed without inflating")
	_check(FileAccess.get_sha256(large) == before, "Indexing an oversized entry leaves its ZIP untouched")
	var huge := _fixture("huge.zip", [{name = "huge.vec", data = PackedByteArray([0]), declared_size = 0x100000005, zip64 = true}], {zip64 = true})
	index = _inspect(huge)
	_check(index.error.is_empty() and index.entries["huge.vec"].size == 0x100000005, "A ZIP64 size above 4 GB is retained exactly without allocation")
	_reject("encrypted.zip", [{name = "data", flags = 0x801}], {}, "Encrypted entries are rejected")
	_reject("multidisk.zip", [{name = "data"}], {disk = 1}, "Multi-disk end records are rejected")
	_reject("bad-empty.zip", [{name = "empty", crc = 123}], {}, "An empty entry with a nonzero CRC is rejected")
	_reject("bad-directory.zip", [{name = "directory", attributes = 0x10, data = PackedByteArray([1])}], {}, "Directory attributes cannot discard nonempty data")
	_reject("duplicates.zip", [{name = "same"}, {name = "same"}], {}, "Duplicate names are rejected")
	_reject("case-duplicates.zip", [{name = "Same"}, {name = "same"}], {}, "Portable case-insensitive name collisions are rejected")
	_reject("extra.zip", [{name = "data", extra = PackedByteArray([2, 0, 9, 0])}], {}, "Truncated extra fields are rejected")
	_reject("missing-zip64.zip", [{name = "data", sentinel = true}], {}, "A ZIP64 sentinel requires an entry extra field")
	var truncated := FileAccess.get_file_as_bytes(ordinary)
	truncated.resize(truncated.size() - 1)
	var broken := _write("truncated.zip", truncated)
	_check(not ZipFiles.inspect(broken, PackedStringArray(["模型.glb", "empty.txt", "folder", "folder/data.vec"])).error.is_empty(), "A truncated end record is rejected")
	_check(not ZipFiles.inspect(ordinary, PackedStringArray()).error.is_empty(), "Index names must match the central-directory count")
	var malformed := _archive([{name = "data", data = PackedByteArray([1])}])
	var central := _signature(malformed, 0x02014b50)
	malformed.encode_u32(central + 20, 1000)
	broken = _write("payload-span.zip", malformed)
	_check(not ZipFiles.inspect(broken, PackedStringArray(["data"])).error.is_empty(), "Compressed data cannot extend into the central directory")
	_check(not ZipFiles.inspect(_directory.path_join("missing.zip"), PackedStringArray()).error.is_empty(), "A missing archive is reported")
	var packed := _directory.path_join("engine-packer.zip")
	var packer := ZIPPacker.new()
	packer.open(packed)
	packer.start_file("folder/empty.txt")
	packer.close_file()
	packer.close()
	index = _inspect(packed)
	_check(index.error.is_empty() and index.entries.folder.directory and not index.entries["folder/empty.txt"].directory, "Real ZIPPacker entries distinguish a no-slash directory from an empty file")


func _reject(name: String, entries: Array, options: Dictionary, message: String) -> void:
	var path := _fixture(name, entries, options)
	var names := PackedStringArray()
	for entry in entries:
		names.append(entry.name)
	var before := FileAccess.get_sha256(path)
	_check(not ZipFiles.inspect(path, names).error.is_empty() and FileAccess.get_sha256(path) == before, message)


func _inspect(path: String) -> Dictionary:
	var zip := ZIPReader.new()
	if zip.open(path) != OK:
		return {entries = {}, error = "Fixture could not be opened by ZIPReader"}
	var names := zip.get_files()
	zip.close()
	return ZipFiles.inspect(path, names)


func _fixture(name: String, entries: Array, options: Dictionary = {}) -> String:
	return _write(name, _archive(entries, options))


func _write(name: String, bytes: PackedByteArray) -> String:
	var path := _directory.path_join(name)
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_buffer(bytes)
	file.close()
	return path


func _archive(entries: Array, options: Dictionary = {}) -> PackedByteArray:
	var bytes := PackedByteArray()
	var directory := PackedByteArray()
	for entry: Dictionary in entries:
		var name: PackedByteArray = entry.name.to_utf8_buffer()
		var data: PackedByteArray = entry.get("data", PackedByteArray())
		var size: int = entry.get("declared_size", data.size())
		var crc: int = entry.get("crc", _crc32(data))
		var flags: int = entry.get("flags", 0x800)
		var local_at := bytes.size()
		var local := PackedByteArray()
		local.resize(30)
		local.encode_u32(0, 0x04034b50)
		local.encode_u16(4, 20)
		local.encode_u16(6, flags)
		local.encode_u16(8, 8 if size != data.size() else 0)
		local.encode_u32(14, crc)
		local.encode_u32(18, data.size())
		local.encode_u32(22, mini(size, 0xffffffff))
		local.encode_u16(26, name.size())
		bytes.append_array(local)
		bytes.append_array(name)
		bytes.append_array(data)
		var extra: PackedByteArray = entry.get("extra", PackedByteArray())
		if entry.get("zip64", false):
			extra.resize(12)
			extra.encode_u16(0, 1)
			extra.encode_u16(2, 8)
			extra.encode_u64(4, size)
		var header := PackedByteArray()
		header.resize(46)
		header.encode_u32(0, 0x02014b50)
		header.encode_u16(4, 0x0314)
		header.encode_u16(6, 45 if entry.get("zip64", false) else 20)
		header.encode_u16(8, flags)
		header.encode_u16(10, 8 if size != data.size() else 0)
		header.encode_u32(16, crc)
		header.encode_u32(20, data.size())
		header.encode_u32(24, 0xffffffff if entry.get("zip64", false) or entry.get("sentinel", false) else size)
		header.encode_u16(28, name.size())
		header.encode_u16(30, extra.size())
		header.encode_u32(38, entry.get("attributes", 0x81a40000))
		header.encode_u32(42, local_at)
		directory.append_array(header)
		directory.append_array(name)
		directory.append_array(extra)
	var central_at := bytes.size()
	bytes.append_array(directory)
	if options.get("zip64", false):
		var zip64_at := bytes.size()
		var zip64 := PackedByteArray()
		zip64.resize(76)
		zip64.encode_u32(0, 0x06064b50)
		zip64.encode_u64(4, 44)
		zip64.encode_u16(12, 45)
		zip64.encode_u16(14, 45)
		zip64.encode_u64(24, entries.size())
		zip64.encode_u64(32, entries.size())
		zip64.encode_u64(40, directory.size())
		zip64.encode_u64(48, central_at)
		zip64.encode_u32(56, 0x07064b50)
		zip64.encode_u64(64, zip64_at)
		zip64.encode_u32(72, 1)
		bytes.append_array(zip64)
	var comment: PackedByteArray = options.get("comment", PackedByteArray())
	var end := PackedByteArray()
	end.resize(22)
	end.encode_u32(0, 0x06054b50)
	end.encode_u16(4, options.get("disk", 0))
	end.encode_u16(8, 0xffff if options.get("zip64", false) else entries.size())
	end.encode_u16(10, 0xffff if options.get("zip64", false) else entries.size())
	end.encode_u32(12, 0xffffffff if options.get("zip64", false) else directory.size())
	end.encode_u32(16, 0xffffffff if options.get("zip64", false) else central_at)
	end.encode_u16(20, comment.size())
	bytes.append_array(end)
	bytes.append_array(comment)
	return bytes


func _crc32(bytes: PackedByteArray) -> int:
	var crc := 0xffffffff
	for byte in bytes:
		crc ^= byte
		for bit in 8:
			crc = (crc >> 1) ^ (0xedb88320 if crc & 1 else 0)
	return crc ^ 0xffffffff


func _signature(bytes: PackedByteArray, signature: int) -> int:
	for index in range(bytes.size() - 3):
		if bytes.decode_u32(index) == signature:
			return index
	return -1
