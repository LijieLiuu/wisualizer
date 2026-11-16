extends SceneTree
const Timeline := preload("res://ui/probe_timeline.gd")
var _checks := 0
var _failures := 0
var _selections: Array[int] = []


func _initialize() -> void:
	_run.call_deferred()


func _check(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error("FAIL: " + message)


func _row(frame: int, a: Variant, b: Variant = null, delta: Variant = null, time: float = 0.0) -> Dictionary:
	return {frame = frame, solver_time = time, a = a, b = b, delta = delta}


func _run() -> void:
	var chart := Timeline.new()
	root.add_child(chart)
	chart.size = Vector2(320, 220)
	chart.frame_selected.connect(func(index: int) -> void: _selections.append(index))
	await process_frame
	_check(chart.custom_minimum_size == Vector2(320, 220), "Compact chart advertises a usable minimum size")
	_check(chart.clip_contents, "Plot and long headings stay inside the chart")
	_check(chart._frame_count == 0 and chart._lines.is_empty(), "New chart is explicitly empty")
	chart.set_series({rows = [], unit = "Pa"})
	_check(chart._frame_count == 0 and not chart._has_values, "An empty analysis remains empty")
	chart.set_series({rows = [_row(1, null), _row(2, null)]})
	_check(chart._frame_count == 2 and not chart._has_values, "All-missing data keeps a selectable frame timeline")
	_check(chart._lines[0].is_empty() and chart._dots[0].is_empty(), "Missing values never render as zeros")
	chart.set_frame(99)
	_check(chart._frame == 1, "Cursor clamps to the last all-missing frame")
	chart.set_frame(-9)
	_check(chart._frame == 0, "Cursor clamps to the first frame")
	chart.set_series({rows = [_row(1, 7.0, 7.0, 0.0)], unit = "K"})
	_check(chart._dots[0].size() == 1 and chart._lines[0].is_empty(), "Single frame is a point, not a fabricated segment")
	_check(is_equal_approx(chart._dots[0][0].x, chart._plot.get_center().x), "Single-frame point is centered")
	chart.set_series({rows = [_row(1, 7.0), _row(2, 7.0), _row(3, 7.0)]})
	_check(chart._minimum == 7.0 and chart._maximum == 7.0, "Constant series does not invent a scalar range")
	_check(is_equal_approx(chart._y_for_value(7.0), chart._plot.get_center().y), "Constant field draws at a finite middle position")
	chart.set_series({rows = [_row(1, 0.0, null, null, 9.0), _row(2, 1.0, null, null, 9.0), _row(3, null, null, null, -4.0), _row(4, 3.0, null, null, 100.0), _row(5, 4.0, null, null, 2.0)], unit = "Pascal with a deliberately long declared unit annotation"})
	_check(chart._lines[0].size() == 4 and chart._dots[0].size() == 4, "An internal missing frame splits the curve into two segments")
	var first: Vector2 = chart._lines[0][0]
	var second: Vector2 = chart._lines[0][1]
	var fourth: Vector2 = chart._lines[0][2]
	_check(first.x < second.x and second.x < fourth.x, "X positions follow frame order despite repeated and reversed solver times")
	_check(is_equal_approx(second.x - first.x, chart._plot.size.x / 4.0), "Frames are evenly spaced by index, not solver time")
	_check(chart.tooltip_text.contains("deliberately long") and chart.tooltip_text.contains("not assumed"), "Tooltip preserves the full declared unit and axis meaning")
	var font: Font = chart.get_theme_font(&"font", &"Label")
	var fitted: String = chart._elide(chart._unit, font, 14, 100.0)
	_check(fitted.ends_with("…") and font.get_string_size(fitted, HORIZONTAL_ALIGNMENT_LEFT, -1, 14).x <= 100.0, "Long unit ellipsis fits its available width")
	_test_pointer(chart)
	_test_extremes(chart)
	_test_dense(chart)
	var revision: int = chart._cache_revision
	for frame in 1000:
		chart.set_frame(frame)
	_check(chart._cache_revision == revision, "A thousand playback cursor updates never rebuild geometry")
	chart.size = Vector2(900, 360)
	await process_frame
	_check(chart._cache_revision > revision and chart._plot.end.x <= chart.size.x and chart._plot.end.y <= chart.size.y, "Resize rebuilds geometry within the new bounds")
	_check(chart._lines[0].size() <= int(chart._plot.size.x) * 4, "Resized dense geometry stays bounded by plot width")
	chart.clear()
	_check(chart._frame_count == 0 and chart._lines.is_empty() and chart._dots.is_empty() and chart._touch == -1, "Clear removes data, rendered geometry and pointer capture")
	chart.set_series({error = "Unable to read source", rows = [_row(1, 99.0)]})
	_check(chart._frame_count == 0, "Failed analysis cannot leave previous curves on screen")
	chart.free()
	await process_frame
	print("Probe timeline: %d checks, %d failures" % [_checks, _failures])
	quit(1 if _failures else 0)


func _test_pointer(chart) -> void:
	_selections.clear()
	var mouse := InputEventMouseButton.new()
	mouse.button_index = MOUSE_BUTTON_LEFT
	mouse.pressed = true
	mouse.position = Vector2(chart._plot.end.x - 0.01, chart._plot.get_center().y)
	chart._gui_input(mouse)
	_check(chart._frame == 4 and _selections == [4], "Click selects a zero-based frame index")
	chart._gui_input(mouse)
	_check(_selections == [4, 4], "Explicit click can pause on the current frame without moving it")
	var drag := InputEventMouseMotion.new()
	drag.button_mask = MOUSE_BUTTON_MASK_LEFT
	drag.position = Vector2(chart._plot.position.x - 200, chart._plot.position.y)
	chart._gui_input(drag)
	_check(chart._frame == 0 and _selections.back() == 0, "Captured mouse drag clamps outside the first frame")
	mouse.pressed = false
	chart._gui_input(mouse)
	_check(not chart._mouse_dragging, "Mouse release ends scrubbing")
	var count := _selections.size()
	drag.position.x = chart._plot.end.x
	chart._gui_input(drag)
	_check(_selections.size() == count, "Orphan mouse movement never scrubs")
	mouse.pressed = true
	mouse.device = InputEvent.DEVICE_ID_EMULATION
	chart._gui_input(mouse)
	_check(_selections.size() == count, "Touch-emulated mouse does not select a second time")
	chart.set_frame(2)
	var touch := InputEventScreenTouch.new()
	touch.index = 7
	touch.pressed = true
	touch.position = Vector2(chart._plot.position.x + 1, chart._plot.get_center().y)
	chart._gui_input(touch)
	_check(chart._frame == 2 and _selections.back() == 2, "Touch pinch starts from the current frame instead of jumping to gaze")
	var motion := InputEventScreenDrag.new()
	motion.index = 99
	motion.position = touch.position + Vector2(chart._plot.size.x / 4.0, 0)
	chart._gui_input(motion)
	_check(chart._frame == 2, "Another touch cannot move the active scrub")
	motion.index = 7
	chart._gui_input(motion)
	_check(chart._frame == 3 and _selections.back() == 3, "Touch drag moves relative to its initial frame")
	touch.pressed = false
	touch.canceled = true
	chart._gui_input(touch)
	_check(chart._touch == -1, "Canceled touch releases ownership")
	chart._gui_input(motion)
	_check(chart._frame == 3, "A drag after cancellation cannot resume itself")
	touch.pressed = true
	touch.canceled = false
	chart._gui_input(touch)
	chart.hide()
	_check(chart._touch == -1, "Hidden chart releases an active touch")
	chart.show()


func _test_extremes(chart) -> void:
	chart.set_series({rows = [_row(1, -1.0e308, 1.0e308, 0.0), _row(2, 1.0e308, -1.0e308, 0.0)]})
	_check(is_equal_approx(chart._y_for_value(-1.0e308), chart._plot.end.y), "Extreme negative endpoint stays finite at the bottom")
	_check(is_equal_approx(chart._y_for_value(1.0e308), chart._plot.position.y), "Extreme positive endpoint stays finite at the top")
	_check(is_equal_approx(chart._y_for_value(0.0), chart._plot.get_center().y), "Opposite extreme endpoints normalize zero without overflow")
	for curve in chart._lines:
		for point in curve:
			_check(point.is_finite(), "Extreme-range geometry contains only finite points")
	chart.set_series({rows = [_row(1, 1.0e-300), _row(2, 2.0e-300)]})
	_check(is_equal_approx(chart._y_for_value(1.0e-300), chart._plot.end.y) and is_equal_approx(chart._y_for_value(2.0e-300), chart._plot.position.y), "Tiny nonzero range remains distinguishable")
	chart.set_series({rows = [_row(1, INF), _row(2, NAN), _row(3, 0.0)]})
	_check(chart._dots[0].size() == 1 and chart._lines[0].is_empty(), "Nonfinite samples are missing, while physical zero remains a point")


func _test_dense(chart) -> void:
	var rows := []
	for index in 20000:
		var value: Variant = 1000.0 if index == 500 else float(index % 23)
		if index == 10000:
			value = null
		rows.append(_row(index + 1, value, null, 0.0, float(20000 - index)))
	chart.set_series({rows = rows, unit = "Pa"})
	var columns := int(chart._plot.size.x)
	_check(chart._lines[0].size() <= columns * 4 and chart._dots[0].size() <= columns, "Twenty thousand samples reduce to geometry bounded by pixel columns")
	var retained_peak := false
	for point in chart._lines[0]:
		retained_peak = retained_peak or is_equal_approx(point.y, chart._plot.position.y)
	_check(retained_peak, "Dense aggregation preserves a one-frame extreme")
	var gap_column := int(10000.0 * columns / rows.size())
	var gap_x: float = chart._plot.position.x + (gap_column + 0.5) * chart._plot.size.x / columns
	var crossed_gap := false
	for pair in range(0, chart._lines[0].size(), 2):
		var left: Vector2 = chart._lines[0][pair]
		var right: Vector2 = chart._lines[0][pair + 1]
		if minf(left.x, right.x) <= gap_x and maxf(left.x, right.x) >= gap_x:
			crossed_gap = true
	_check(not crossed_gap, "Dense geometry never bridges a column containing a missing sample")
	_check(chart._lines[1].is_empty() and chart._dots[1].is_empty(), "An entirely missing second probe has no dense geometry")
	_check(chart._dots[2].size() == columns, "Dense valid zero difference is retained across every column")
