extends Control
## What a [Scrubber] shows: a filled capsule with the knob inside its leading
## end, the way visionOS draws its sliders. It only draws; the scrubber,
## an invisible HSlider, takes the input.
##
## Uses the "Scrubber" theme type: "track", "fill", "fill_hover",
## "fill_pressed" and "fill_disabled" styles, "knob" and "knob_disabled"
## icons, and "knob_inset", the space around the knob.

var _slider: Scrubber


func _init(slider: Scrubber) -> void:
	_slider = slider
	mouse_filter = MOUSE_FILTER_IGNORE
	set_anchors_preset(PRESET_FULL_RECT)


func _draw() -> void:
	var state := &"fill"
	if not _slider.editable:
		state = &"fill_disabled"
	elif _slider.is_dragging():
		state = &"fill_pressed"
	elif _slider.is_hovered():
		state = &"fill_hover"
	var track := get_theme_stylebox(&"track", &"Scrubber")
	var fill := get_theme_stylebox(state, &"Scrubber")
	var knob := get_theme_icon(&"knob" if _slider.editable else &"knob_disabled", &"Scrubber")
	var inset := float(get_theme_constant(&"knob_inset", &"Scrubber"))
	var height := maxf(track.get_minimum_size().y, knob.get_height() + inset * 2.0)
	var top := (size.y - height) * 0.5
	track.draw(get_canvas_item(), Rect2(0.0, top, size.x, height))

	# The knob's center follows the slider's own mapping of the pointer, kept
	# inside the track at the ends.
	var range := _slider.max_value - _slider.min_value
	var ratio := 0.0 if is_zero_approx(range) else (_slider.value - _slider.min_value) / range
	if is_layout_rtl():
		ratio = 1.0 - ratio
	var radius := knob.get_width() * 0.5
	var center := clampf(ratio * size.x, inset + radius, size.x - inset - radius)
	if is_layout_rtl():
		fill.draw(get_canvas_item(), Rect2(center - radius - inset, top, size.x - center + radius + inset, height))
	else:
		fill.draw(get_canvas_item(), Rect2(0.0, top, center + radius + inset, height))
	draw_texture(knob, Vector2(center - radius, top + (height - knob.get_height()) * 0.5))
