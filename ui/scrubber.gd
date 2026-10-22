class_name Scrubber
extends HSlider
## A slider that looks like visionOS's own. The scrubber itself is an
## invisible HSlider: it takes the input, holds the value, and gives
## accessibility and the system's hover highlight its shape. A
## ScrubberTrack inside it draws what the person sees.
##
## A mouse click seeks to where it lands, as on a desktop. A touch, such as a
## pinch on visionOS, drags relative to where it started instead: visionOS
## gaze is not a pointer, and the person can't see exactly where they are
## looking, so a pinch alone must not move the value. The mouse events Godot
## emulates from touches are ignored, or HSlider would jump to them.

const ScrubberTrack := preload("scrubber_track.gd")

var _track := ScrubberTrack.new(self)
var _hovered := false
var _dragging := false
## The touch dragging the value, and where it and the value started.
var _touch := -1
var _touch_start := 0.0
var _value_start := 0.0


func _init() -> void:
	add_child(_track, false, INTERNAL_MODE_FRONT)
	theme_type_variation = &"Scrubber"


func _ready() -> void:
	mouse_entered.connect(_set_hovered.bind(true))
	mouse_exited.connect(_set_hovered.bind(false))
	drag_started.connect(_set_dragging.bind(true))
	drag_ended.connect(func(_changed: bool) -> void: _set_dragging(false))
	value_changed.connect(func(_value: float) -> void: _track.queue_redraw())
	changed.connect(_track.queue_redraw)


func is_hovered() -> bool:
	return _hovered


func is_dragging() -> bool:
	return _dragging


func _set_hovered(hovered: bool) -> void:
	_hovered = hovered
	_track.queue_redraw()


func _set_dragging(dragging: bool) -> void:
	_dragging = dragging
	_track.queue_redraw()


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouse and event.device == InputEvent.DEVICE_ID_EMULATION:
		accept_event()
	elif event is InputEventScreenTouch and event.pressed and _touch < 0 and editable:
		_touch = event.index
		_touch_start = event.position.x
		_value_start = value
		drag_started.emit()
		accept_event()
	elif event is InputEventScreenTouch and not event.pressed and event.index == _touch:
		_touch = -1
		drag_ended.emit(not is_equal_approx(value, _value_start))
		accept_event()
	elif event is InputEventScreenDrag and event.index == _touch:
		var moved: float = (event.position.x - _touch_start) / maxf(size.x, 1.0)
		if is_layout_rtl():
			moved = -moved
		value = _value_start + moved * (max_value - min_value)
		accept_event()


func _notification(what: int) -> void:
	if what == NOTIFICATION_THEME_CHANGED or what == NOTIFICATION_DRAW:
		_track.queue_redraw()
