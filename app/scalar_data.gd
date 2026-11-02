extends RefCounted
## Shared checks for byte-encoded scalar grids. Zero marks a missing sample;
## bytes 1 through 255 span the inclusive scalar range.

const MAX_CELLS := 0x7fffffff


static func is_finite_number(value: Variant) -> bool:
	return (value is int or value is float) and is_finite(float(value))


## Returns zero for invalid dimensions or a grid too large for PackedByteArray.
static func cell_count(cells: Vector3i) -> int:
	var count := 1
	for dimension in [cells.x, cells.y, cells.z]:
		if dimension <= 0:
			return 0
		@warning_ignore("integer_division")
		if count > MAX_CELLS / dimension:
			return 0
		count *= dimension
	return count


static func validate_range(span: Vector2) -> String:
	if not span.is_finite() or span.x > span.y:
		return "The scalar range must contain finite minimum and maximum values in order."
	return ""


static func validate_transform(box: Transform3D) -> String:
	if not box.origin.is_finite() or not box.basis.is_finite():
		return "The field's spatial transform must contain only finite values."
	var determinant := box.basis.determinant()
	if not is_finite(determinant) or determinant == 0.0:
		return "The field's spatial transform must be invertible."
	if not box.affine_inverse().is_finite():
		return "The field's inverse spatial transform must contain only finite values."
	return ""


static func validate_metadata(span: Vector2, cells: Vector3i, box: Transform3D = Transform3D.IDENTITY) -> String:
	if cell_count(cells) == 0:
		return "The grid needs positive integer dimensions and fewer than 2 GiB of cells."
	var error := validate_range(span)
	return error if not error.is_empty() else validate_transform(box)


static func validate(data: PackedByteArray, span: Vector2, cells: Vector3i) -> String:
	var error := validate_metadata(span, cells)
	if not error.is_empty():
		return error
	var expected := cell_count(cells)
	if data.size() != expected:
		return "The brick has %d bytes; its grid requires exactly %d." % [data.size(), expected]
	return ""


static func parse_cells(value: Variant) -> Dictionary:
	if not value is Array or value.size() != 3:
		return {value = Vector3i.ZERO, error = "Cells must be an array of three positive integers."}
	for dimension in value:
		if not is_finite_number(dimension) or float(dimension) != floor(float(dimension)) or float(dimension) <= 0.0 or float(dimension) > MAX_CELLS:
			return {value = Vector3i.ZERO, error = "Cells must be three positive integers smaller than 2 GiB."}
	var cells := Vector3i(int(value[0]), int(value[1]), int(value[2]))
	if cell_count(cells) == 0:
		return {value = Vector3i.ZERO, error = "The grid must contain fewer than 2 GiB of cells."}
	return {value = cells, error = ""}


static func parse_range(value: Variant) -> Dictionary:
	if not value is Array or value.size() != 2:
		return {value = Vector2.ZERO, error = "Range must be an array of two finite numbers."}
	for number in value:
		if not is_finite_number(number):
			return {value = Vector2.ZERO, error = "Range must be an array of two finite numbers."}
	var span := Vector2(float(value[0]), float(value[1]))
	if (float(value[0]) != 0.0 and span.x == 0.0) or (float(value[1]) != 0.0 and span.y == 0.0):
		return {value = Vector2.ZERO, error = "The scalar range is too small for the supported numeric precision."}
	if float(value[0]) != float(value[1]) and span.x == span.y:
		return {value = Vector2.ZERO, error = "The scalar range endpoints collapse at the supported numeric precision."}
	return {value = span, error = validate_range(span)}


static func parse_vector(value: Variant, label: String) -> Dictionary:
	if not value is Array or value.size() != 3:
		return {value = Vector3.ZERO, error = "%s must be an array of three finite numbers." % label}
	for number in value:
		if not is_finite_number(number):
			return {value = Vector3.ZERO, error = "%s must be an array of three finite numbers." % label}
	var vector := Vector3(float(value[0]), float(value[1]), float(value[2]))
	return {value = vector, error = "" if vector.is_finite() else "%s is outside the supported finite range." % label}


static func parse_box(value: Variant) -> Dictionary:
	if not value is Dictionary:
		return {value = Transform3D.IDENTITY, error = "The field box must be an object."}
	var origin := parse_vector(value.get("origin", [0, 0, 0]), "Box origin")
	if not origin.error.is_empty():
		return {value = Transform3D.IDENTITY, error = origin.error}
	var size := parse_vector(value.get("size", [1, 1, 1]), "Box size")
	if not size.error.is_empty():
		return {value = Transform3D.IDENTITY, error = size.error}
	var axes: Variant = value.get("axes", [[1, 0, 0], [0, 1, 0], [0, 0, 1]])
	if not axes is Array or axes.size() != 3:
		return {value = Transform3D.IDENTITY, error = "Box axes must contain three finite vectors."}
	var vectors: Array[Vector3] = []
	for axis in axes:
		var parsed := parse_vector(axis, "Box axis")
		if not parsed.error.is_empty():
			return {value = Transform3D.IDENTITY, error = parsed.error}
		vectors.append(parsed.value)
	var basis_axes := Basis(vectors[0], vectors[1], vectors[2])
	var basis := basis_axes * Basis.from_scale(size.value)
	var box := Transform3D(basis, origin.value)
	return {value = box, size = size.value, axes = basis_axes, error = validate_transform(box)}
