extends Node
## One opened ZIP, shown as a volume the person can place anywhere; see
## docs/zip-format.md. Its notes, if it has any, open in a window of their
## own beside the volume, which the person can move and resize, and its
## controls sit along the volume's bottom front edge.

const FPS := 4.0
const PLAY_ICON := preload("res://app/icons/play.svg")
const PAUSE_ICON := preload("res://app/icons/pause.svg")
const SPEEDS := [0.5, 1.0, 2.0, 4.0]
const Meta := preload("res://app/meta.gd")
const ModelFrames := preload("res://app/model_frames.gd")
const NotesImages := preload("res://app/notes_images.gd")
const SpatialProbe := preload("res://app/spatial_probe.gd")
## Seconds a volume takes to open before the resize hint shows.
const HINT_DELAY := 0.6
## Radians the model turns as the hand moves by its radius. More than one,
## so a small movement of the hand turns it well round.
const TURN_GAIN := 3.0
## How far the model tilts toward or away from the person at most; it eases
## toward this, and springs back upright when let go.
const TILT_LIMIT := deg_to_rad(75.0)
## How quickly the model follows the hand, and settles once let go: the
## inverse of the time it takes to cover most of the way.
const FOLLOW_RATE := 14.0
const SETTLE_RATE := 6.0
## Seconds of the hand's last speed that carry on turning the model after
## it is let go, like a globe given a spin.
const SPIN_TIME := 0.3

@onready var model: Window = $Model
## The 3D nodes are found by unique name: platforms may move them within
## the Window.
@onready var content: Node3D = %Content
## Holds the model, the field box and the probes, and turns them together.
@onready var turntable: Node3D = %Turntable
## Where pinching and dragging the model turns it.
@onready var grab: StaticBody3D = %Grab
@onready var volume: SpatialVolume3D = %Volume
@onready var field: Node3D = %Field
@onready var controls: Window = $Model/Controls
@onready var options: Window = $Model/Options
@onready var notes: Window = $Model/Notes
@onready var play_button: Button = %Play
@onready var slider: HSlider = %Frame
@onready var counter: Label = %Count
@onready var debug_button: CheckButton = %Debug
@onready var loop_button: CheckButton = %Loop
@onready var probes: Node3D = %FieldProbes
@onready var notes_button: Button = %NotesButton
@onready var options_button: Button = %OptionsButton
@onready var touch: Node = $FieldTouch
@onready var probe_button: CheckButton = %ProbeEnabled
@onready var probe_grab: StaticBody3D = %ProbeGrab
@onready var probe_tools: VBoxContainer = %ProbeTools
@onready var probe_readout: Label = %ProbeReadout
@onready var speed_group: ButtonGroup = $Model/Options/Bar/Speeds/Speed0.button_group

var inspection := SpatialProbe.new()
var probing := false
var _probe_field := -1
var _options_base_width := 0.0

var meta := Meta.new()
## One per model, showing it at the current frame.
var models: Array[ModelFrames] = []
## The field the debug view shows and controllers feel.
var field_index := 0
var frame_count := 0
var frame := 0
var playing := false
var elapsed := 0.0
## The images the notes show, kept for as long as the document is open.
var notes_images := NotesImages.new()
## How far the model is turned about the vertical, and tilted toward the
## person about [member _tilt_axis], now and where it is heading.
var yaw := 0.0
var tilt := 0.0
var _yaw_target := 0.0
var _tilt_target := 0.0
var _tilt_axis := Vector3.RIGHT
## The drag turning the model: its touch index, or -1; where the hand was
## when it began, the turn and the tilt then, and how fast the yaw was
## changing. The tilt is kept before its easing toward the limit.
var _drag := -1
var _drag_start := Vector3.ZERO
var _drag_yaw := 0.0
var _drag_tilt := 0.0
var _yaw_speed := 0.0
## The model's center and the radius of a sphere around it, in its own
## coordinates, from the last fit.
var _center := Vector3.ZERO
var _radius := 1.0


func _ready() -> void:
	_options_base_width = options.size.x / options.content_scale_factor
	inspection.changed.connect(_refresh_inspection)
	probe_tools.minimum_size_changed.connect(_resize_probe_options)
	$Model/Options/Bar.minimum_size_changed.connect(_resize_probe_options)
	model.size_changed.connect(_resize_probe_options)
	model.visibility_changed.connect(_cancel_probe_gesture)
	model.focus_exited.connect(_cancel_probe_gesture)
	# The shared-volume event classes come from the matching native addon.
	probe_button.visible = OS.has_feature("visionos")
	probe_button.disabled = not ClassDB.class_exists("InputEventSpatialTouch") or not ClassDB.class_exists("InputEventSpatialDrag")
	for window: Window in [model, controls, options, notes]:
		window.window_input.connect(_on_window_input)
	# The bars are pointed at, not tabbed through, so the keyboard stays with
	# the shortcuts: a focused button would also take Space.
	for window: Window in [controls, options]:
		for control in window.find_children("*", "Control", true, false):
			if control is BaseButton or control is Range:
				control.focus_mode = Control.FOCUS_NONE
	_resize_probe_options.call_deferred()


## Space plays or pauses, and the arrow keys step a frame, in any of this
## document's windows.
func _on_window_input(event: InputEvent) -> void:
	if frame_count == 0:
		return
	if event.is_action_pressed(&"play_pause"):
		toggle_play()
	elif event.is_action_pressed(&"previous_frame", true):
		step(-1)
	elif event.is_action_pressed(&"next_frame", true):
		step(1)


## Opens the ZIP at [param path]. Returns an empty string, or what is
## wrong with it.
func open(path: String) -> String:
	var error := meta.open(path)
	if not error.is_empty():
		return error
	frame_count = meta.times.size()
	field_index = meta.first_field
	for entry in meta.models:
		var frames := ModelFrames.new()
		frames.setup(path, entry)
		content.add_child(frames)
		models.append(frames)
	_add_model_switches()
	_add_field_picker()
	debug_button.disabled = meta.fields.is_empty()
	probe_button.disabled = probe_button.disabled or meta.fields.is_empty()
	touch.volume = volume
	touch.field = field
	probes.touch = touch
	probes.volume = volume
	probes.field = field
	slider.max_value = frame_count - 1
	seek(0)

	var text := ""
	if not meta.notes.is_empty():
		var notes_text: RichTextLabel = %Text
		text = notes_images.embed(meta.read(meta.notes).get_string_from_utf8(), meta.read, meta.notes, str(get_instance_id()), notes_text.get_theme_color(&"default_color"), notes_text.get_theme_font_size(&"normal_font_size"))
	model.title = meta.title
	%Text.text = text
	notes_button.visible = not text.is_empty()
	fit()
	model.show()
	controls.show()
	show_options(options_button.button_pressed)
	show_notes(notes_button.visible)
	# Show that the volume can be resized, once it has finished opening.
	create_tween().tween_callback(show_resize_hint).set_delay(HINT_DELAY)
	set_playing(true)
	return ""


## A switch for each model, in the options, when there's more than one.
func _add_model_switches() -> void:
	if models.size() < 2:
		return
	var bar: Container = %Separator.get_parent()
	for frames in models:
		var switch := CheckButton.new()
		switch.text = frames.name
		switch.tooltip_text = frames.name
		switch.clip_text = true
		switch.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		switch.custom_minimum_size.x = 160
		switch.button_pressed = true
		switch.focus_mode = Control.FOCUS_NONE
		switch.custom_minimum_size.y = 44
		switch.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		switch.toggled.connect(func(shown: bool) -> void: frames.visible = shown)
		bar.add_child(switch)
		bar.move_child(switch, %Separator.get_index())


## A button for each field, in the options, when there's more than one.
func _add_field_picker() -> void:
	if meta.fields.size() < 2:
		return
	var bar: Container = %Separator.get_parent()
	var group := ButtonGroup.new()
	for index in meta.fields.size():
		var button := Button.new()
		button.text = meta.fields[index].name
		button.tooltip_text = meta.fields[index].name
		button.clip_text = true
		button.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		button.toggle_mode = true
		button.button_group = group
		button.button_pressed = index == field_index
		button.focus_mode = Control.FOCUS_NONE
		button.custom_minimum_size = Vector2(160, 44)
		button.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		button.pressed.connect(func() -> void:
			field_index = index
			update_field())
		bar.add_child(button)
		bar.move_child(button, %Reset.get_index())


func show_notes(shown: bool) -> void:
	notes.visible = shown


## The person closed the notes window; the notes button opens it again.
func close_notes() -> void:
	notes.hide()
	notes_button.set_pressed_no_signal(false)


func show_options(shown: bool) -> void:
	options.visible = shown


func show_resize_hint() -> void:
	%ResizeHint.play(volume.get_region_size())


func close() -> void:
	inspection.clear()
	meta.close()
	queue_free()


func toggle_play() -> void:
	# Playing again after stopping at the end, without Loop, starts over.
	if not playing and not loop_button.button_pressed and frame == frame_count - 1:
		seek(0)
	set_playing(not playing)


## Pauses and moves [param frames_by] frames, staying within the frames.
func step(frames_by: int) -> void:
	set_playing(false)
	seek(clampi(frame + frames_by, 0, frame_count - 1))


## Follows a link in the notes. [code][url=frame:9]frame 9[/url][/code]
## pauses on the ninth frame; other links open as usual.
func open_link(target: Variant) -> void:
	var link := str(target)
	if link.begins_with("frame:"):
		set_playing(false)
		seek(clampi(link.trim_prefix("frame:").to_int() - 1, 0, frame_count - 1))
	else:
		OS.shell_open(link)


func set_playing(value: bool) -> void:
	if value:
		inspection.cancel()
	playing = value
	elapsed = 0.0
	play_button.icon = PAUSE_ICON if playing else PLAY_ICON


func seek(value: float) -> void:
	inspection.cancel()
	frame = int(value)
	for frames in models:
		frames.show_frame(frame)
	slider.set_value_no_signal(frame)
	counter.text = "%d / %d" % [frame + 1, frame_count]
	update_field()


## Debug shows controller samples; Probe shows A/B samples and the field
## target. Controllers can provide haptics in either mode.
func update_field() -> void:
	if meta.fields.is_empty():
		field.visible = false
		probes.visible = false
		touch.set_brick(PackedByteArray(), Vector3i.ZERO, 255)
		inspection.clear()
		return
	var field_changed := _probe_field != field_index
	if field_changed:
		_probe_field = field_index
		inspection.clear()
	var current: Meta.Field = meta.fields[field_index]
	field.visible = debug_button.button_pressed or probing
	probes.visible = field.visible
	probes.show_controllers = debug_button.button_pressed
	probes.shown_field = current
	field.transform = current.box
	var supported := _probe_axes_supported(current.box.basis)
	probe_button.disabled = not supported or not ClassDB.class_exists("InputEventSpatialTouch") or not ClassDB.class_exists("InputEventSpatialDrag")
	probe_button.tooltip_text = "Pause and place two scalar probes with a pinch. Turn off to rotate the model." if supported else "Hand probes are unavailable for this field: the current visionOS renderer cannot preserve sheared field axes."
	if probing and not supported:
		set_probe_mode(false)
		return
	touch.set_brick(meta.read(current.files[frame]), current.cells, 255)
	if field_changed and probing:
		fit()
	_refresh_inspection()


## RealityKit entity transforms contain translation, rotation, and scale.
## The plugin discards shear, so its native hit box would disagree with the
## affine coordinates used by the sampler. Do not offer misleading probes.
static func _probe_axes_supported(basis: Basis) -> bool:
	var axes: Array[Vector3] = []
	for axis in [basis.x, basis.y, basis.z]:
		var length: float = axis.length()
		if not is_finite(length) or length <= 0.0:
			return false
		axes.append(axis / length)
	return absf(axes[0].dot(axes[1])) < 0.00001 and absf(axes[0].dot(axes[2])) < 0.00001 and absf(axes[1].dot(axes[2])) < 0.00001


## Explicit probe mode reserves the field's collider for pinch gestures.
## It pauses playback; pressing Play later revisits the pinned points over time.
func set_probe_mode(enabled: bool) -> void:
	probing = enabled and not meta.fields.is_empty() and _probe_axes_supported(meta.fields[field_index].box.basis)
	probe_button.set_pressed_no_signal(probing)
	inspection.cancel()
	_drag = -1
	_yaw_speed = 0.0
	# Freeze the displayed orientation so easing cannot move the field under a pinch.
	_yaw_target = yaw
	_tilt_target = tilt
	if probing:
		set_playing(false)
	grab.input_ray_pickable = not probing
	probe_grab.input_ray_pickable = probing
	grab.get_node("Shape").set_deferred("disabled", probing)
	probe_grab.get_node("Shape").set_deferred("disabled", not probing)
	probe_tools.visible = probing
	_resize_probe_options.call_deferred()
	update_field()
	fit()


## Window sizes are physical pixels; controls use logical points. The native
## window inherits a scale of two, while desktop ornaments reset it to one.
func _resize_probe_options() -> void:
	if not is_node_ready():
		return
	var bar: HFlowContainer = $Model/Options/Bar
	var row_height := maxf(56.0, bar.get_combined_minimum_size().y + 12.0)
	bar.offset_bottom = row_height
	probe_tools.offset_top = row_height
	var width := _options_base_width
	if SpatialPlatform.current() == SpatialPlatform.Kind.DESKTOP:
		width = minf(width, maxf(320.0, model.get_visible_rect().size.x - 24.0))
	width = maxf(width, bar.get_combined_minimum_size().x + 32.0)
	var height := row_height
	if probing:
		height += probe_tools.get_combined_minimum_size().y + 12.0
	options.size = Vector2i(Vector2(width, height) * options.content_scale_factor)


func select_probe(slot: int) -> void:
	inspection.selected_slot = slot
	_refresh_inspection()


func clear_probes() -> void:
	inspection.clear()


func _cancel_probe_gesture() -> void:
	inspection.cancel()


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT or what == NOTIFICATION_APPLICATION_PAUSED or what == NOTIFICATION_PAUSED:
		inspection.cancel()


func probe_by_drag(_camera: Node, event: InputEvent, hit: Vector3, _normal: Vector3, _shape: int) -> void:
	if not probing or not model.visible or touch.bytes.is_empty():
		inspection.cancel()
		return
	if event.is_class("InputEventSpatialTouch") and event.get("pressed"):
		set_playing(false)
		_yaw_target = yaw
		_tilt_target = tilt
		%Reset.visible = not is_zero_approx(yaw) or not is_zero_approx(tilt)
	inspection.handle_event(event, hit, field.global_transform)


## Samples pins again from the current brick. Pins are normalized field
## coordinates, so rotating/resizing a volume never moves a pin to another cell.
func _refresh_inspection() -> void:
	if not is_node_ready() or touch == null:
		return
	var points: Dictionary = inspection.get_points()
	probes.inspection_points = points if probing else {}
	if meta.fields.is_empty():
		probe_readout.text = "This document has no scalar field."
		return
	var current: Meta.Field = meta.fields[field_index]
	var rows := PackedStringArray()
	var values := {}
	for slot in [0, 1]:
		var name := "A" if slot == 0 else "B"
		if not points.has(slot):
			rows.append("%s: not placed" % name)
			continue
		var cell: Vector3i = touch.cell_at_unit(points[slot])
		var byte: int = touch.byte_of(cell)
		if byte == 0:
			rows.append("%s: No data" % name)
			continue
		var value := current.value_of(byte)
		values[slot] = value
		rows.append("%s: %s  ·  cell (%d, %d, %d)" % [name, current.format(value), cell.x, cell.y, cell.z])
	var difference := "B − A: place both probes on valid data"
	if values.has(0) and values.has(1):
		difference = "B − A: " + current.format(values[1] - values[0])
	var state := "Moving %s · release inside the field to pin" % ("A" if inspection.selected_slot == 0 else "B") if inspection.is_active() else "Select A or B, pinch the field box, then move your hand in 3D. Release to pin."
	probe_readout.text = "%s · frame %d · solver time %s\n%s\n%s\n%s" % [current.name, frame + 1, String.num(meta.times[frame], 14), "\n".join(rows), difference, state]
	_resize_probe_options.call_deferred()


## Turns the model as the person pinches and drags it, like Apple's globe:
## moving the hand sideways turns it about the vertical without limit, and
## moving it up or down tilts it toward or away from the person, up to
## [constant TILT_LIMIT]. Both follow how far the hand has moved since the
## pinch began, so small jitters don't add up, and the model eases after the
## hand. On release the tilt springs back and the turn carries on a little.
## Spatial events only come from visionOS; on desktop, the orbit camera
## turns the view instead.
func turn_by_drag(_camera: Node, event: InputEvent, _position: Vector3, _normal: Vector3, _shape: int) -> void:
	if probing:
		return
	if event.is_class("InputEventSpatialTouch"):
		if event.get("pressed") and _drag < 0:
			_begin_drag(event.get("index"), event.get("world_position"))
		elif not event.get("pressed") and event.get("index") == _drag:
			_drag = -1
			_tilt_target = 0.0
			_yaw_target += clampf(_yaw_speed * SPIN_TIME, -PI, PI)
		return
	if not event.is_class("InputEventSpatialDrag"):
		return
	var at: Vector3 = event.get("world_position")
	if _drag < 0:
		_begin_drag(event.get("index"), at - (event.get("world_relative") as Vector3))
	if event.get("index") != _drag:
		return
	var moved := at - _drag_start
	var turned := _yaw_target
	_yaw_target = _drag_yaw + moved.dot(_tilt_axis) / _radius * TURN_GAIN
	var delta := maxf(get_process_delta_time(), 0.001)
	_yaw_speed = lerpf(_yaw_speed, (_yaw_target - turned) / delta, 0.5)
	_tilt_target = _ease_tilt(_drag_tilt - moved.y / _radius * TURN_GAIN)
	%Reset.visible = true


## Starts a drag at [param at]: tilting turns about the horizontal axis
## across the person's view, taken as facing the side of the model held.
func _begin_drag(index: int, at: Vector3) -> void:
	_drag = index
	_drag_start = at
	_drag_yaw = _yaw_target
	_yaw_speed = 0.0
	# A drag soon after another picks up the tilt where it is, as it springs
	# back, about the same axis.
	_drag_tilt = _unease_tilt(tilt)
	var facing := Vector3(_center.x - at.x, 0.0, _center.z - at.z)
	if absf(tilt) < deg_to_rad(1.0) and not facing.is_zero_approx():
		_tilt_axis = facing.normalized().cross(Vector3.UP)


## Eases [param raw] toward [constant TILT_LIMIT] rather than stopping at it:
## one for one near upright, slower and slower toward the limit.
static func _ease_tilt(raw: float) -> float:
	return TILT_LIMIT * atan(raw / TILT_LIMIT * PI / 2.0) * 2.0 / PI


static func _unease_tilt(eased: float) -> float:
	return TILT_LIMIT * tan(clampf(eased / TILT_LIMIT, -0.99, 0.99) * PI / 2.0) * 2.0 / PI


func reset_turn() -> void:
	inspection.cancel()
	_yaw_target = 0.0
	_tilt_target = 0.0
	%Reset.visible = false


## Eases the turn toward where it is heading.
func _ease_turn(delta: float) -> void:
	var rate := FOLLOW_RATE if _drag >= 0 else SETTLE_RATE
	var weight := 1.0 - exp(-rate * delta)
	yaw = lerpf(yaw, _yaw_target, weight)
	tilt = lerpf(tilt, _tilt_target, weight)
	_place_turntable()


## Turns the turntable by [member yaw] and [member tilt] about the model's
## center.
func _place_turntable() -> void:
	var turn := Basis(_tilt_axis, tilt) * Basis(Vector3.UP, yaw)
	turntable.transform = Transform3D(turn, _center - turn * _center)


## Frames the volume on the model so it can turn any way without leaving
## the volume or changing size: on a sphere about its center that reaches
## its farthest vertex. Probe mode also fits the current field so every
## face of its sampling box can be targeted inside the volume.
func fit() -> void:
	inspection.cancel()
	var bounds := AABB()
	for frames in models:
		var box := frames.get_bounds()
		if box.has_volume():
			bounds = box if bounds.size == Vector3.ZERO else bounds.merge(box)
	var boxes: Array[AABB] = []
	for entry: Meta.Field in meta.fields:
		boxes.append(entry.box * AABB(Vector3.ZERO, Vector3.ONE))
	if bounds.size == Vector3.ZERO:
		for box in boxes:
			bounds = box if bounds.size == Vector3.ZERO else bounds.merge(box)
	_center = bounds.get_center()
	_radius = 0.0
	for frames in models:
		_radius = maxf(_radius, frames.get_radius(_center))
	if is_zero_approx(_radius):
		_radius = maxf(bounds.size.length() * 0.5, 0.001)
	if probing and not meta.fields.is_empty():
		var box: Transform3D = meta.fields[field_index].box
		for corner in 8:
			var point := box * Vector3(corner & 1, (corner >> 1) & 1, (corner >> 2) & 1)
			_radius = maxf(_radius, point.distance_to(_center))
	# The model is grabbed by its bounds, which stay inside the volume and
	# leave the space around the model for moving the window.
	grab.position = _center
	(grab.get_node("Shape").shape as BoxShape3D).size = bounds.size.max(Vector3.ONE * bounds.size[bounds.size.max_axis_index()] * 0.02)
	_place_turntable()
	var volume_size := volume.get_measured_size()
	# Before the native window reports its size, use the size it opens at.
	if volume_size == Vector3.ZERO:
		volume_size = volume.window_size
	volume.position = _center
	var smallest := volume_size[volume_size.min_axis_index()]
	volume.size = _radius * 2.0 / smallest * volume_size[volume.keep_aspect] * 1.1


func _process(delta: float) -> void:
	_ease_turn(delta)
	if not playing or frame_count == 0:
		return
	elapsed += delta * FPS * SPEEDS[speed_group.get_pressed_button().get_index()]
	while elapsed >= 1.0:
		elapsed -= 1.0
		if frame + 1 < frame_count:
			seek(frame + 1)
		elif loop_button.button_pressed:
			seek(0)
		else:
			set_playing(false)
			return
