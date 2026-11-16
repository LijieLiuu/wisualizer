extends Control
## Frame-order history of two pinned scalar probes and B - A. Solver times
## are metadata: they may repeat or run backward and are never treated as seconds.

signal frame_selected(index: int)

const SERIES_KEYS := ["a", "b", "delta"]
const SERIES_NAMES := ["A", "B", "B − A"]
const SERIES_COLORS := [Color("55b9f5"), Color("ffba62"), Color("c9a1ff")]
const TEXT_COLOR := Color("e9eaf0")
const MUTED_COLOR := Color("aeb5c4")
const GRID_COLOR := Color(0.65, 0.7, 0.8, 0.18)
const FONT_SIZE := 14

var _values: Array[PackedFloat64Array] = []
var _lines: Array[PackedVector2Array] = []
var _dots: Array[PackedVector2Array] = []
var _frame_count := 0
var _frame := 0
var _unit := ""
var _has_values := false
var _minimum := 0.0
var _maximum := 0.0
var _plot := Rect2()
var _dot_radius := 2.5
var _cache_revision := 0
var _mouse_dragging := false
var _touch := -1
var _touch_start_x := 0.0
var _touch_start_frame := 0


func _init() -> void:
	clip_contents = true
	mouse_filter = MOUSE_FILTER_STOP
	custom_minimum_size = Vector2(320, 220)
	size_flags_horizontal = SIZE_EXPAND_FILL
	size_flags_vertical = SIZE_EXPAND_FILL


## Result rows are in playback order and contain nullable a/b/delta values.
## Their CSV frame labels are one-based; interaction uses zero-based row indices.
## Copy only numerical columns so callers can release their analysis dictionaries.
func set_series(result: Dictionary) -> void:
	clear()
	var rows: Variant = result.get("rows", [])
	if not result.get("error", "").is_empty() or not rows is Array:
		return
	_unit = str(result.get("unit", ""))
	_frame_count = rows.size()
	for key in SERIES_KEYS:
		var values := PackedFloat64Array()
		values.resize(_frame_count)
		values.fill(NAN)
		for index in _frame_count:
			if not rows[index] is Dictionary:
				continue
			var value: Variant = rows[index].get(key)
			if (value is float or value is int) and is_finite(float(value)):
				values[index] = float(value)
				if not _has_values:
					_minimum = values[index]
					_maximum = values[index]
					_has_values = true
				else:
					_minimum = minf(_minimum, values[index])
					_maximum = maxf(_maximum, values[index])
		_values.append(values)
	tooltip_text = "Frame order; solver times are not assumed to be evenly spaced.\nUnit: %s\nClick or drag to select a frame. On touch, drag from the current frame.\nGaps are missing samples. Dense columns show extrema; columns containing missing samples stay blank." % (_unit if not _unit.is_empty() else "not supplied")
	_rebuild_geometry()


func clear() -> void:
	_values.clear()
	_lines.clear()
	_dots.clear()
	_frame_count = 0
	_frame = 0
	_unit = ""
	_has_values = false
	_minimum = 0.0
	_maximum = 0.0
	_cancel_pointer()
	tooltip_text = "Analyze pinned probes to show their history."
	queue_redraw()


## Playback changes only the cursor, without scanning samples or rebuilding lines.
func set_frame(index: int) -> void:
	var selected := clampi(index, 0, maxi(0, _frame_count - 1))
	if _frame != selected:
		_frame = selected
		queue_redraw()


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		_rebuild_geometry()
	elif what == NOTIFICATION_THEME_CHANGED:
		queue_redraw()
	elif what == NOTIFICATION_VISIBILITY_CHANGED and not is_visible_in_tree():
		_cancel_pointer()
	elif what == NOTIFICATION_APPLICATION_FOCUS_OUT:
		_cancel_pointer()


func _cancel_pointer() -> void:
	_mouse_dragging = false
	_touch = -1


func _rebuild_geometry() -> void:
	_plot = Rect2(70.0, 65.0, maxf(size.x - 84.0, 1.0), maxf(size.y - 116.0, 1.0))
	_lines.clear()
	_dots.clear()
	_cache_revision += 1
	var columns := maxi(1, int(_plot.size.x))
	_dot_radius = minf(2.5, maxf(0.45, _plot.size.x / maxi(_frame_count, 1) * 0.25))
	for values in _values:
		var geometry := _dense_geometry(values, columns) if _frame_count > columns else _sparse_geometry(values)
		_lines.append(geometry.lines)
		_dots.append(geometry.dots)
	queue_redraw()


func _sparse_geometry(values: PackedFloat64Array) -> Dictionary:
	var lines := PackedVector2Array()
	var dots := PackedVector2Array()
	var previous := Vector2.ZERO
	var connected := false
	for index in values.size():
		if not is_finite(values[index]):
			connected = false
			continue
		var point := Vector2(_x_for_frame(index), _y_for_value(values[index]))
		dots.append(point)
		if connected:
			lines.append(previous)
			lines.append(point)
		previous = point
		connected = true
	return {lines = lines, dots = dots}


## Bound draw work to the plot width. A bucket with any missing sample is a
## gap, never an interpolated bridge across an unknown value. Complete buckets
## retain their extrema and connect the last sample to the next first sample.
func _dense_geometry(values: PackedFloat64Array, columns: int) -> Dictionary:
	var first := PackedFloat64Array()
	var last := PackedFloat64Array()
	var low := PackedFloat64Array()
	var high := PackedFloat64Array()
	var missing := PackedByteArray()
	first.resize(columns)
	last.resize(columns)
	low.resize(columns)
	high.resize(columns)
	missing.resize(columns)
	low.fill(INF)
	high.fill(-INF)
	for index in values.size():
		var column := mini(int(float(index) * columns / values.size()), columns - 1)
		var value := values[index]
		if not is_finite(value):
			missing[column] = 1
			continue
		if low[column] == INF:
			first[column] = value
		last[column] = value
		low[column] = minf(low[column], value)
		high[column] = maxf(high[column], value)
	var lines := PackedVector2Array()
	var dots := PackedVector2Array()
	var previous := Vector2.ZERO
	var connected := false
	for column in columns:
		if missing[column] or low[column] == INF:
			connected = false
			continue
		var x := _plot.position.x + (column + 0.5) * _plot.size.x / columns
		if low[column] != high[column]:
			lines.append(Vector2(x, _y_for_value(low[column])))
			lines.append(Vector2(x, _y_for_value(high[column])))
		else:
			dots.append(Vector2(x, _y_for_value(low[column])))
		if connected:
			lines.append(previous)
			lines.append(Vector2(x, _y_for_value(first[column])))
		previous = Vector2(x, _y_for_value(last[column]))
		connected = true
	return {lines = lines, dots = dots}


func _x_for_frame(index: int) -> float:
	return _plot.get_center().x if _frame_count <= 1 else _plot.position.x + float(index) / (_frame_count - 1) * _plot.size.x


func _y_for_value(value: float) -> float:
	if _minimum == _maximum:
		return _plot.get_center().y
	# Scaling before subtracting avoids overflow for opposite extreme endpoints.
	var magnitude := maxf(absf(_minimum), absf(_maximum))
	var lower := _minimum / magnitude
	var span := _maximum / magnitude - lower
	var ratio := clampf((value / magnitude - lower) / span, 0.0, 1.0)
	return _plot.end.y - ratio * _plot.size.y


func _draw() -> void:
	var font := get_theme_font(&"font", &"Label")
	draw_rect(Rect2(Vector2.ZERO, size), Color("171c26"))
	var heading := "Value · " + (_unit if not _unit.is_empty() else "no unit supplied")
	draw_string(font, Vector2(12, 22), _elide(heading, font, FONT_SIZE, size.x - 24), HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE, TEXT_COLOR)
	for series in 3:
		var x := 16.0 + series * 86.0
		draw_line(Vector2(x, 43), Vector2(x + 18, 43), SERIES_COLORS[series], 2.0, true)
		draw_string(font, Vector2(x + 24, 48), SERIES_NAMES[series], HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE, SERIES_COLORS[series])
	if _frame_count == 0:
		_draw_centered(font, "Analyze pinned probes", _plot.get_center().y - 6.0)
		_draw_centered(font, "to show their history.", _plot.get_center().y + 14.0)
		return
	for ratio in [0.0, 0.5, 1.0]:
		var y: float = _plot.position.y + _plot.size.y * ratio
		draw_line(Vector2(_plot.position.x, y), Vector2(_plot.end.x, y), GRID_COLOR)
	if _has_values:
		if _minimum == _maximum:
			_draw_axis_value(font, _minimum, _plot.get_center().y)
		else:
			_draw_axis_value(font, _maximum, _plot.position.y)
			_draw_axis_value(font, _minimum * 0.5 + _maximum * 0.5, _plot.get_center().y)
			_draw_axis_value(font, _minimum, _plot.end.y)
		for series in _lines.size():
			if not _lines[series].is_empty():
				draw_multiline(_lines[series], SERIES_COLORS[series], 1.6, true)
			for point in _dots[series]:
				draw_circle(point, _dot_radius, SERIES_COLORS[series])
	else:
		_draw_centered(font, "No valid probe values", _plot.get_center().y - 6.0)
		_draw_centered(font, "Missing samples stay blank.", _plot.get_center().y + 14.0)
	var cursor := _x_for_frame(_frame)
	draw_line(Vector2(cursor, _plot.position.y), Vector2(cursor, _plot.end.y), Color(1, 1, 1, 0.65), 1.0)
	var first_x := _plot.position.x if _frame_count > 1 else _plot.get_center().x - font.get_string_size("1", HORIZONTAL_ALIGNMENT_LEFT, -1, 12).x * 0.5
	draw_string(font, Vector2(first_x, _plot.end.y + 19), "1", HORIZONTAL_ALIGNMENT_LEFT, -1, 12, MUTED_COLOR)
	if _frame_count > 1:
		var last := str(_frame_count)
		var width := font.get_string_size(last, HORIZONTAL_ALIGNMENT_LEFT, -1, 12).x
		draw_string(font, Vector2(_plot.end.x - width, _plot.end.y + 19), last, HORIZONTAL_ALIGNMENT_LEFT, -1, 12, MUTED_COLOR)
	var caption := "Frame %d / %d · frame order · gaps = missing" % [_frame + 1, _frame_count]
	draw_string(font, Vector2(12, size.y - 10), _elide(caption, font, 12, size.x - 24), HORIZONTAL_ALIGNMENT_LEFT, -1, 12, MUTED_COLOR)


func _draw_centered(font: Font, text: String, baseline: float) -> void:
	var fitted := _elide(text, font, FONT_SIZE, size.x - 24)
	var width := font.get_string_size(fitted, HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE).x
	draw_string(font, Vector2((size.x - width) * 0.5, baseline), fitted, HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE, MUTED_COLOR)


func _draw_axis_value(font: Font, value: float, y: float) -> void:
	var text := String.num_scientific(value) if value != 0.0 and (absf(value) >= 100000.0 or absf(value) < 0.001) else String.num(value, 3)
	text = _elide(text, font, 11, _plot.position.x - 12)
	var width := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, 11).x
	draw_string(font, Vector2(_plot.position.x - width - 8, y + 4), text, HORIZONTAL_ALIGNMENT_LEFT, -1, 11, MUTED_COLOR)


func _elide(text: String, font: Font, font_size: int, width: float) -> String:
	if font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x <= width:
		return text
	var low := 0
	var high := text.length()
	while low < high:
		var middle := (low + high + 1) / 2
		if font.get_string_size(text.left(middle) + "…", HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x <= width:
			low = middle
		else:
			high = middle - 1
	return text.left(low) + "…"


func _gui_input(event: InputEvent) -> void:
	if _frame_count == 0:
		return
	if event is InputEventMouse and event.device == InputEvent.DEVICE_ID_EMULATION:
		accept_event()
	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed and _plot.has_point(event.position):
			_mouse_dragging = true
			_select_at(event.position.x, true)
			accept_event()
		elif not event.pressed:
			_mouse_dragging = false
	elif event is InputEventMouseMotion and _mouse_dragging:
		if event.button_mask & MOUSE_BUTTON_MASK_LEFT:
			_select_at(event.position.x)
			accept_event()
		else:
			_mouse_dragging = false
	elif event is InputEventScreenTouch:
		if event.canceled:
			if event.index == _touch:
				_touch = -1
			accept_event()
			return
		if event.pressed and _touch < 0 and _plot.has_point(event.position):
			_touch = event.index
			_touch_start_x = event.position.x
			_touch_start_frame = _frame
			_select_frame(_frame, true)
			accept_event()
		elif not event.pressed and event.index == _touch:
			_touch = -1
			accept_event()
	elif event is InputEventScreenDrag and _touch >= 0 and event.index == _touch:
		var moved: float = (event.position.x - _touch_start_x) / _plot.size.x
		_select_frame(_touch_start_frame + roundi(moved * (_frame_count - 1)))
		accept_event()


func _select_at(x: float, notify_same: bool = false) -> void:
	var ratio := clampf((x - _plot.position.x) / _plot.size.x, 0.0, 1.0)
	_select_frame(roundi(ratio * (_frame_count - 1)), notify_same)


func _select_frame(index: int, notify_same: bool = false) -> void:
	var selected := clampi(index, 0, _frame_count - 1)
	if selected != _frame or notify_same:
		set_frame(selected)
		frame_selected.emit(selected)
