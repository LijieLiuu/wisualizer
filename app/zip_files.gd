extends RefCounted
## Reads ZIP entry sizes and directory flags without inflating file contents.
## Names come from ZIPReader.get_files(), in central-directory order, so this
## index uses the engine's filename decoding. CRC/data failures remain the
## reader's responsibility; callers must compare returned bytes with size.

const EOCD := 0x06054b50
const ZIP64_EOCD := 0x06064b50
const ZIP64_LOCATOR := 0x07064b50
const CENTRAL := 0x02014b50
const LOCAL := 0x04034b50
const MAX_U32 := 0xffffffff
const MAX_U16 := 0xffff


static func inspect(path: String, names: PackedStringArray) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {entries = {}, error = "Couldn't read the ZIP index: %s." % path}
	var length := file.get_length()
	if length < 22:
		return _failed(file, "The ZIP end record is missing.")
	var tail_start := maxi(0, length - 22 - MAX_U16)
	file.seek(tail_start)
	var tail := file.get_buffer(length - tail_start)
	if tail.size() != length - tail_start:
		return _failed(file, "Couldn't read the ZIP end record.")
	var end := -1
	for offset in range(tail.size() - 22, -1, -1):
		if tail.decode_u32(offset) == EOCD and offset + 22 + tail.decode_u16(offset + 20) == tail.size():
			end = offset
			break
	if end < 0:
		return _failed(file, "The ZIP end record or comment is incomplete.")
	var end_at := tail_start + end
	var disk := tail.decode_u16(end + 4)
	var central_disk := tail.decode_u16(end + 6)
	var disk_count: int = tail.decode_u16(end + 8)
	var count: int = tail.decode_u16(end + 10)
	var central_size: int = tail.decode_u32(end + 12)
	var central_at: int = tail.decode_u32(end + 16)
	if disk != 0 or central_disk != 0:
		return _failed(file, "Multi-disk ZIPs are not supported.")
	var central_limit := end_at
	var locator := PackedByteArray()
	if end_at >= 20:
		file.seek(end_at - 20)
		locator = file.get_buffer(20)
	var has_zip64 := locator.size() == 20 and locator.decode_u32(0) == ZIP64_LOCATOR
	if has_zip64:
		if locator.decode_u32(4) != 0 or locator.decode_u32(16) != 1:
			return _failed(file, "Multi-disk ZIP64 archives are not supported.")
		var zip64_at := _u64(locator, 8)
		if not _within(zip64_at, 56, end_at - 20):
			return _failed(file, "The ZIP64 end record has an invalid offset.")
		file.seek(zip64_at)
		var record := file.get_buffer(56)
		if record.size() != 56 or record.decode_u32(0) != ZIP64_EOCD:
			return _failed(file, "The ZIP64 end record is missing.")
		var record_size := _u64(record, 4)
		if record_size < 44 or not _within(zip64_at + 12, record_size, end_at - 20) or zip64_at + 12 + record_size != end_at - 20:
			return _failed(file, "The ZIP64 end record is incomplete.")
		if record.decode_u32(16) != 0 or record.decode_u32(20) != 0:
			return _failed(file, "Multi-disk ZIP64 archives are not supported.")
		disk_count = _u64(record, 24)
		count = _u64(record, 32)
		central_size = _u64(record, 40)
		central_at = _u64(record, 48)
		central_limit = zip64_at
	elif central_size == MAX_U32 or central_at == MAX_U32 or ((count == MAX_U16 or disk_count == MAX_U16) and names.size() != MAX_U16):
		# Legacy ZIPs can contain exactly 65535 entries without ZIP64 records.
		return _failed(file, "The ZIP64 locator is missing.")
	if disk_count != count or count < 0 or count != names.size():
		return _failed(file, "The ZIP entry count is inconsistent.")
	if not _within(central_at, central_size, central_limit) or central_size < count * 46:
		return _failed(file, "The ZIP central directory is incomplete.")
	var central_end := central_at + central_size
	var cursor := central_at
	var entries := {}
	var seen := {}
	for index in names.size():
		if not _within(cursor, 46, central_end):
			return _failed(file, "A ZIP directory entry is incomplete.")
		file.seek(cursor)
		var header := file.get_buffer(46)
		if header.size() != 46 or header.decode_u32(0) != CENTRAL:
			return _failed(file, "A ZIP directory entry is invalid.")
		if header.decode_u16(8) & 0x41:
			return _failed(file, "Encrypted ZIP entries are not supported.")
		var name_size := header.decode_u16(28)
		var extra_size := header.decode_u16(30)
		var comment_size := header.decode_u16(32)
		var end_entry := cursor + 46 + name_size + extra_size + comment_size
		if name_size == 0 or not _within(cursor, end_entry - cursor, central_end):
			return _failed(file, "A ZIP directory entry is truncated.")
		var entry_size: int = header.decode_u32(24)
		var compressed_size: int = header.decode_u32(20)
		var local_at: int = header.decode_u32(42)
		var entry_disk: int = header.decode_u16(34)
		file.seek(cursor + 46 + name_size)
		var extra := file.get_buffer(extra_size)
		if extra.size() != extra_size:
			return _failed(file, "Couldn't read a ZIP entry's extra fields.")
		var zip64 := PackedByteArray()
		var extra_at := 0
		var found_zip64 := false
		while extra_at < extra.size():
			if extra.size() - extra_at < 4:
				return _failed(file, "A ZIP entry's extra field is truncated.")
			var tag := extra.decode_u16(extra_at)
			var size := extra.decode_u16(extra_at + 2)
			if size > extra.size() - extra_at - 4:
				return _failed(file, "A ZIP entry's extra field is truncated.")
			if tag == 1:
				if found_zip64:
					return _failed(file, "A ZIP entry has duplicate ZIP64 fields.")
				found_zip64 = true
				zip64 = extra.slice(extra_at + 4, extra_at + 4 + size)
			extra_at += 4 + size
		var values := [entry_size, compressed_size, local_at, entry_disk]
		var zip64_at := 0
		for part in values.size():
			if values[part] == (MAX_U16 if part == 3 else MAX_U32):
				var width := 4 if part == 3 else 8
				if zip64.size() - zip64_at < width:
					return _failed(file, "A ZIP64 entry is missing its size or offset.")
				values[part] = zip64.decode_u32(zip64_at) if part == 3 else _u64(zip64, zip64_at)
				zip64_at += width
		entry_size = values[0]
		compressed_size = values[1]
		local_at = values[2]
		entry_disk = values[3]
		if entry_disk != 0:
			return _failed(file, "Multi-disk ZIP entries are not supported.")
		if entry_size < 0 or compressed_size < 0 or not _within(local_at, 30, central_at):
			return _failed(file, "A ZIP entry has an invalid size or offset.")
		file.seek(local_at)
		var local := file.get_buffer(30)
		if local.size() != 30 or local.decode_u32(0) != LOCAL:
			return _failed(file, "A ZIP entry's local header is missing.")
		if local.decode_u16(6) & 0x41:
			return _failed(file, "Encrypted ZIP entries are not supported.")
		var data_at := local_at + 30 + local.decode_u16(26) + local.decode_u16(28)
		if not _within(data_at, compressed_size, central_at):
			return _failed(file, "A ZIP entry's compressed data is truncated.")
		var name := names[index]
		if name.is_empty() or seen.has(name.to_lower()):
			return _failed(file, "The ZIP contains empty or duplicate entry names.")
		seen[name.to_lower()] = true
		var attributes := header.decode_u32(38)
		var directory := name.ends_with("/") or (attributes & 0x10) != 0 or ((attributes >> 16) & 0xf000) == 0x4000
		if entry_size == 0 and header.decode_u32(16) != 0:
			return _failed(file, "The empty ZIP entry %s has an invalid checksum." % name)
		if directory and entry_size != 0:
			return _failed(file, "The ZIP directory %s unexpectedly contains file data." % name)
		entries[name] = {size = entry_size, directory = directory}
		cursor = end_entry
	# The optional central-directory digital signature is metadata, not a file.
	if cursor < central_end:
		if not _within(cursor, 6, central_end):
			return _failed(file, "The ZIP central directory has trailing invalid data.")
		file.seek(cursor)
		var signature := file.get_buffer(6)
		if signature.size() != 6 or signature.decode_u32(0) != 0x05054b50 or cursor + 6 + signature.decode_u16(4) != central_end:
			return _failed(file, "The ZIP central directory has trailing invalid data.")
	file.close()
	return {entries = entries, error = ""}


static func _within(offset: int, size: int, limit: int) -> bool:
	return offset >= 0 and size >= 0 and offset <= limit and size <= limit - offset


static func _u64(bytes: PackedByteArray, offset: int) -> int:
	# GDScript integers are signed; refuse values outside their range.
	return -1 if bytes[offset + 7] & 0x80 else bytes.decode_u64(offset)


static func _failed(file: FileAccess, message: String) -> Dictionary:
	file.close()
	return {entries = {}, error = message}
