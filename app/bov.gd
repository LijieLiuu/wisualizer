extends RefCounted
## A brick of values, as EnSight exports a field: a small header file of
## "KEY: value" lines beside a data file with one byte per cell, x fastest.
## The header says which variable and solver time the brick is, how many
## cells it has, and where it sits.

const ScalarData := preload("res://app/scalar_data.gd")

var variable := ""
var time := 0.0
var cells := Vector3i.ZERO
## The values bytes 1 and 255 stand for.
var range := Vector2(0.0, 1.0)
var origin := Vector3.ZERO
var size := Vector3.ONE
var axes := Basis()
## The data file, next to the header.
var data := ""


## Legacy convenience API; use read_checked when displaying import errors.
static func read(path: String):
	return read_checked(path).value


## Validates a header and its data file without loading the entire brick.
static func read_checked(path: String) -> Dictionary:
	var header := FileAccess.open(path, FileAccess.READ)
	if header == null:
		return _failure(path, "Couldn't open the BOV header.")
	var text := header.get_as_text()
	header.close()
	var lines := {}
	for raw_line in text.split("\n"):
		var line := raw_line.strip_edges()
		if line.is_empty() or line.begins_with("#"):
			continue
		var parts := line.split(":", true, 1)
		if parts.size() != 2 or parts[0].strip_edges().is_empty():
			return _failure(path, "Expected KEY: value in the BOV header.")
		var key := parts[0].strip_edges()
		if lines.has(key):
			return _failure(path, "The header repeats %s." % key)
		lines[key] = parts[1].strip_edges()
	for key in ["TIME", "BRICK ORIGIN", "DATA SIZE", "DATA FILE"]:
		if not lines.has(key):
			return _failure(path, "The header is missing %s." % key)
	if lines.get("DATA FORMAT") != "BYTES":
		return _failure(path, "DATA FORMAT must be BYTES (one byte per cell).")
	var time_value := _numbers(lines["TIME"], 1, "TIME")
	if not time_value.error.is_empty():
		return _failure(path, time_value.error)
	var dimensions := _numbers(lines["DATA SIZE"], 3, "DATA SIZE")
	if not dimensions.error.is_empty():
		return _failure(path, dimensions.error)
	var parsed_cells := ScalarData.parse_cells(dimensions.value)
	if not parsed_cells.error.is_empty():
		return _failure(path, parsed_cells.error)
	var minimum := _numbers(lines.get("VARIABLE PALETTE MIN", "0"), 1, "VARIABLE PALETTE MIN")
	var maximum := _numbers(lines.get("VARIABLE PALETTE MAX", "1"), 1, "VARIABLE PALETTE MAX")
	if not minimum.error.is_empty() or not maximum.error.is_empty():
		return _failure(path, minimum.error if not minimum.error.is_empty() else maximum.error)
	var parsed_range := ScalarData.parse_range([minimum.value[0], maximum.value[0]])
	if not parsed_range.error.is_empty():
		return _failure(path, parsed_range.error)
	var vectors := {}
	var defaults := {"BRICK ORIGIN": "", "BRICK SIZE": "1 1 1", "BRICK X_AXIS": "1 0 0", "BRICK Y_AXIS": "0 1 0", "BRICK Z_AXIS": "0 0 1"}
	for key in defaults:
		var numbers := _numbers(lines.get(key, defaults[key]), 3, key)
		if not numbers.error.is_empty():
			return _failure(path, numbers.error)
		vectors[key] = numbers.value
	var parsed_box := ScalarData.parse_box({
		origin = vectors["BRICK ORIGIN"], size = vectors["BRICK SIZE"],
		axes = [vectors["BRICK X_AXIS"], vectors["BRICK Y_AXIS"], vectors["BRICK Z_AXIS"]],
	})
	if not parsed_box.error.is_empty():
		return _failure(path, parsed_box.error)
	var bov = new()
	bov.variable = lines.get("VARIABLE", path.get_file())
	if bov.variable.is_empty():
		return _failure(path, "VARIABLE must not be empty.")
	bov.time = time_value.value[0]
	bov.cells = parsed_cells.value
	bov.range = parsed_range.value
	bov.origin = parsed_box.value.origin
	bov.size = parsed_box.size
	bov.axes = parsed_box.axes
	# Exporting-machine paths are resolved beside the selected header.
	var filename: String = lines["DATA FILE"].replace("\\", "/").get_file()
	if filename.is_empty() or filename in [".", ".."]:
		return _failure(path, "DATA FILE must name a data file beside the header.")
	bov.data = path.get_base_dir().path_join(filename)
	var payload := FileAccess.open(bov.data, FileAccess.READ)
	if payload == null:
		return _failure(path, "Couldn't open the data file %s beside the header." % filename)
	var length := payload.get_length()
	payload.close()
	var expected := ScalarData.cell_count(bov.cells)
	if length != expected:
		return _failure(path, "%s has %d bytes; its grid requires exactly %d." % [filename, length, expected])
	return {value = bov, error = ""}


static func _numbers(text: String, count: int, label: String) -> Dictionary:
	var tokens := text.replace("\t", " ").replace("\r", " ").split(" ", false)
	if tokens.size() != count:
		return {value = [], error = "%s must contain exactly %d finite number(s)." % [label, count]}
	var numbers: Array = []
	for token in tokens:
		if not token.is_valid_float():
			return {value = [], error = "%s must contain only finite numbers." % label}
		var number := float(token)
		if not is_finite(number):
			return {value = [], error = "%s must contain only finite numbers." % label}
		if number == 0.0:
			for digit in token.to_lower().get_slice("e", 0):
				if digit in "123456789":
					return {value = [], error = "%s is too small for the supported numeric precision." % label}
		numbers.append(number)
	return {value = numbers, error = ""}


static func _failure(path: String, message: String) -> Dictionary:
	return {value = null, error = "%s: %s" % [path.get_file(), message]}
