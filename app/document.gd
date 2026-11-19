extends Node
## One of an opened ZIP's models, shown as a volume the person can place
## anywhere; see docs/zip-format.md. The ZIP's notes, if it has any, open
## beside its first model's volume in a window of their own, which the
## person can move and resize, and each volume's controls sit along its
## bottom front edge.

const PLAY_ICON := preload("res://app/icons/play.svg")
const PAUSE_ICON := preload("res://app/icons/pause.svg")
const SPEEDS := [0.5, 1.0, 2.0, 4.0]
const Meta := preload("res://app/meta.gd")
const ModelFrames := preload("res://app/model_frames.gd")
const Playback := preload("res://app/playback.gd")
const HandWorkbench := preload("res://app/hand_workbench.tscn")
const HandWorkbenchScript := preload("res://app/hand_workbench.gd")
const SpatialProbe := preload("res://app/spatial_probe.gd")
const NotesImages := preload("res://app/notes_images.gd")
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
## A spatial event's kind for a finger touching, not pinching:
## InputEventSpatialTouch.KIND_TOUCH, a class that exists only on visionOS.
const KIND_TOUCH := 0

@onready var model: Window = $Model
## The 3D nodes are found by unique name: platforms may move them within
## the Window.
@onready var content: Node3D = %Content
## Holds the model, the field box, the probes and the labels, and turns them together.
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
@onready var probes: Node3D = %FieldProbes
@onready var labels: Node3D = %Labels
@onready var labels_button: CheckButton = %ShowLabels
@onready var notes_button: Button = %NotesButton
@onready var options_button: Button = %OptionsButton
@onready var immersive_button: Button = %ImmersiveButton
@onready var touch: Node = $FieldTouch
@onready var sound: Node = $FieldSound
@onready var speed_group: ButtonGroup = $Model/Options/Bar/Speeds/Row/Speed0.button_group

@onready var probe_button: CheckButton = %ProbeEnabled
@onready var probe_grab: StaticBody3D = %ProbeGrab
@onready var probe_tools: VBoxContainer = %ProbeTools
@onready var probe_readout: Label = %ProbeReadout
@onready var history: Window = $Model/ProbeHistory

var inspection := SpatialProbe.new()
var probing := false
var _probe_field := -1
var hand_workbench: Node
var source_path := ""
var model_index := 0
var playing: bool:
	get:
		return clock != null and clock.playing
var meta := Meta.new()
## The model this volume shows.
var entry: Meta.Model
## One per part, showing it at the current frame.
var parts: Array[ModelFrames] = []
## The field the debug view shows, and controllers and hands feel.
var field_index := 0
var frame_count := 0
## The frame of the model's timeline showing.
var frame := -1
## The clock this volume plays by, shared with the ZIP's other volumes.
var clock: Playback
## The images the notes show, kept for as long as the document is open.
var notes_images := NotesImages.new()
## The bars' sizes as ornaments, kept while they are windows of their own:
## visionOS gives a window a larger size than an ornament's.
var _bar_sizes := {}
## Worker tasks measuring the fields' peaks.
var _peak_tasks: Array[int] = []
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
## The horizontal across the person's view, as the drag began: sideways
## movement along it turns the model.
var _drag_across := Vector3.RIGHT
## A gesture that selected a label must not also turn the model.
var _label_touch := -1
## Touches that have ended, until their index presses again: a drag event
## can arrive after its touch ends, and must not start a drag no release
## will end.
var _ended := {}
var _drag_start := Vector3.ZERO
var _drag_yaw := 0.0
var _drag_tilt := 0.0
var _yaw_speed := 0.0
## The model's center and the radius of a sphere around it, in its own
## coordinates, from the last fit.
var _center := Vector3.ZERO
var _radius := 1.0


func _ready() -> void:
	%Hands.visible = OS.has_feature("visionos")
	var hand_problem := HandWorkbenchScript.availability()
	%Hands.disabled = not hand_problem.is_empty()
	%Hands.tooltip_text = hand_problem if not hand_problem.is_empty() else "Enter a mixed immersive space to inspect the field with tracked fingertips."
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


## Space plays or pauses, and the arrow keys step a frame, in any of this
## document's windows, when there are frames to play.
func _on_window_input(event: InputEvent) -> void:
	if frame_count < 2:
		return
	if event.is_action_pressed(&"play_pause"):
		toggle_play()
	elif event.is_action_pressed(&"previous_frame", true):
		step(-1)
	elif event.is_action_pressed(&"next_frame", true):
		step(1)


## Opens model [param model_index] of the ZIP at [param path], with the ZIP's
## notes if [param with_notes], and beside the volume [param after] if
## there is one, so a ZIP's volumes open side by side. It plays by
## [param shared_clock], so they play together, or by a clock of its own.
## Returns an empty string, or what is wrong with the ZIP.
func open(path: String, chosen_model := 0, with_notes := true, after: Window = null, shared_clock: Playback = null) -> String:
	var error := meta.open(path)
	if not error.is_empty():
		return error
	if chosen_model < 0 or chosen_model >= meta.models.size():
		meta.close()
		return "The requested model is not present in this ZIP."
	model_index = chosen_model
	source_path = path
	entry = meta.models[model_index]
	history.setup(self)
	frame_count = entry.times.size()
	field_index = entry.first_field
	for index in entry.fields.size():
		_peak_tasks.append(WorkerThreadPool.add_task(_measure_peak.bind(path, index, entry.fields[index].files)))
	for part in entry.parts:
		var frames := ModelFrames.new()
		frames.setup(path, part)
		content.add_child(frames)
		parts.append(frames)
	_add_model_switches()
	_add_field_picker()
	Settings.changed.connect(update_field)
	touch.volume = volume
	touch.field = field
	probes.touch = touch
	sound.touch = touch
	sound.volume = volume
	probes.volume = volume
	probes.field = field
	labels.touch = touch
	labels.volume = volume
	labels.set_labels(entry.labels)
	labels_button.visible = not entry.labels.is_empty()
	# A model that doesn't change has nothing to play.
	for control: Control in [play_button, slider, counter, $Model/Options/Bar/SpeedLabel, $Model/Options/Bar/Speeds]:
		control.visible = frame_count > 1
	# The field picker follows the playback speed and the switches, if any.
	var switches := parts.size() > 1 or not entry.labels.is_empty()
	var picker := entry.fields.size() > 1
	%Separator.visible = picker and (frame_count > 1 or switches)
	options_button.visible = frame_count > 1 or switches or picker or not entry.fields.is_empty()
	_fit_options()
	slider.max_value = frame_count - 1
	clock = shared_clock
	if clock == null:
		clock = Playback.new()
		clock.times = entry.times
		add_child(clock)
	clock.hold()
	clock.changed.connect(_follow_clock)
	for button in speed_group.get_buttons():
		button.pressed.connect(func() -> void: clock.set_speed(SPEEDS[button.get_index()]))
	_follow_clock()

	var text := ""
	if with_notes and not meta.notes.is_empty():
		var notes_text: RichTextLabel = %Text
		text = notes_images.embed(meta.read(meta.notes).get_string_from_utf8(), meta.read, meta.notes, str(get_instance_id()), notes_text.get_theme_color(&"default_color"), notes_text.get_theme_font_size(&"normal_font_size"))
	model.title = meta.title if meta.models.size() < 2 else "%s – %s" % [meta.title, entry.name]
	%Text.text = text
	notes_button.visible = not text.is_empty()
	immersive_button.visible = volume.can_be_immersive()
	if frame_count < 2:
		# Only the notes, options and immersive buttons are left.
		_fit_width(controls, play_button.get_parent())
	fit()
	if after:
		model.placement = Window.PLACEMENT_TRAILING
		model.placement_target = model.get_path_to(after)
	model.show()
	controls.show()
	show_options(options_button.visible and options_button.button_pressed)
	show_notes(notes_button.visible)
	# Show that the volume can be resized, once it has finished opening.
	create_tween().tween_callback(show_resize_hint).set_delay(HINT_DELAY)
	return ""


## A switch for each part, in the options, when there's more than one.
func _add_model_switches() -> void:
	if parts.size() < 2:
		return
	var bar: Container = %Separator.get_parent()
	for frames in parts:
		var switch := CheckButton.new()
		switch.text = frames.name
		switch.button_pressed = true
		switch.focus_mode = Control.FOCUS_NONE
		switch.custom_minimum_size.y = 44
		switch.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		switch.toggled.connect(func(shown: bool) -> void: frames.visible = shown)
		bar.add_child(switch)
		bar.move_child(switch, %Separator.get_index())


## A button for each field, in the options, when there's more than one.
func _add_field_picker() -> void:
	if entry.fields.size() < 2:
		return
	var bar: Container = %Separator.get_parent()
	var group := ButtonGroup.new()
	for index in entry.fields.size():
		var button := Button.new()
		button.text = entry.fields[index].name
		button.tooltip_text = entry.fields[index].name
		button.clip_text = true
		button.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		button.toggle_mode = true
		button.button_group = group
		button.button_pressed = index == field_index
		button.set_meta("field_index", index)
		button.focus_mode = Control.FOCUS_NONE
		button.custom_minimum_size = Vector2(160, 44)
		button.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		button.pressed.connect(select_field.bind(index))
		bar.add_child(button)
		bar.move_child(button, %Separator.get_index())


func show_notes(shown: bool) -> void:
	notes.visible = shown


## The person closed the notes window; the notes button opens it again.
func close_notes() -> void:
	notes.hide()
	notes_button.set_pressed_no_signal(false)


## Sizes the options to what they hold, which depends on the ZIP: a switch
## per model, a button per field, the labels switch.
func _fit_options() -> void:
	_resize_probe_options()


## Narrows or widens [param window] to the bar filling it.
func _fit_width(window: Window, bar: Control) -> void:
	var margins := bar.offset_left - bar.offset_right
	window.size.x = ceili((bar.get_combined_minimum_size().x + margins) * window.content_scale_factor)


func show_options(shown: bool) -> void:
	options.visible = shown


func show_resize_hint() -> void:
	%ResizeHint.play(volume.get_region_size())


## The person closed the model. Leaving the immersive space also asks to
## close it; the volume opens again instead.
func close() -> void:
	if volume.is_immersive():
		return
	if is_instance_valid(hand_workbench):
		hand_workbench.stop()
	history.cancel_analysis()
	inspection.clear()
	meta.close()
	queue_free()


## A competing model can own the space. Reflect the actual state even when
## a request is declined without a transition or any other side effects.
func _request_immersive(immersive: bool) -> void:
	volume.set_immersive(immersive)
	immersive_button.set_pressed_no_signal(volume.is_immersive())


## The model's Window reopened around the person or as a volume. The bars
## hang from the volume as ornaments; the immersive space has no ornaments,
## so there they are windows of their own.
func _on_immersive_changed(immersive: bool) -> void:
	inspection.cancel()
	if not immersive and is_instance_valid(hand_workbench):
		hand_workbench.stop()
	immersive_button.set_pressed_no_signal(immersive)
	var placement := Window.PLACEMENT_AUTOMATIC if immersive else Window.PLACEMENT_ORNAMENT
	for window: Window in [controls, options]:
		var shown := window.visible
		window.hide()
		if immersive:
			_bar_sizes[window] = window.size
		elif _bar_sizes.has(window):
			window.size = _bar_sizes[window]
		window.placement = placement
		window.visible = shown


func toggle_play() -> void:
	clock.set_playing(not clock.playing)


## Pauses and moves [param frames_by] of the model's frames, staying within
## them.
func step(frames_by: int) -> void:
	clock.set_playing(false)
	seek(clampi(frame + frames_by, 0, frame_count - 1))


## Follows a link in the notes. [code][url=frame:9]frame 9[/url][/code]
## pauses on the ninth frame; other links open as usual.
func open_link(target: Variant) -> void:
	var link := str(target)
	if link.begins_with("frame:"):
		clock.set_playing(false)
		seek(clampi(link.trim_prefix("frame:").to_int() - 1, 0, frame_count - 1))
	else:
		OS.shell_open(link)


## Sends the clock, and with it every volume of the ZIP, to frame
## [param value] of this model's timeline.
func seek(value: float) -> void:
	if meta.legacy:
		clock.seek_frame(clampi(int(value), 0, frame_count - 1))
	else:
		clock.seek_time(entry.times[clampi(int(value), 0, frame_count - 1)])


## Shows what the clock says: the model's step at its time, whether it
## plays, and how fast.
func _follow_clock() -> void:
	if clock.playing:
		inspection.cancel()
	play_button.icon = PAUSE_ICON if clock.playing else PLAY_ICON
	# Without signals a group doesn't let go of the button pressed before.
	for button in speed_group.get_buttons():
		button.set_pressed_no_signal(SPEEDS[button.get_index()] == clock.speed)
	var at := clock.frame if meta.legacy else Meta.step_at(entry.times, clock.time())
	if at != frame:
		_show_frame(at)


func _show_frame(value: int) -> void:
	inspection.cancel()
	frame = value
	for frames in parts:
		frames.show_frame(frame)
	slider.set_value_no_signal(frame)
	counter.text = "%d / %d" % [frame + 1, frame_count]
	labels.frame = frame
	update_field()


## Shows the field box, and the field around each controller and hand, if
## the debug view is on in the settings. The field can be felt either way.
func update_field() -> void:
	if entry == null or entry.fields.is_empty():
		field.visible = false
		probes.visible = false
		touch.set_brick(PackedByteArray(), Vector3i.ZERO, 255)
		inspection.clear()
		return
	var field_changed := _probe_field != field_index
	if field_changed:
		_probe_field = field_index
		inspection.clear()
	var current: Meta.Field = entry.fields[field_index]
	field.visible = Settings.debug or probing or ((history.visible or is_instance_valid(hand_workbench)) and _probe_axes_supported(current.box.basis))
	probes.visible = field.visible
	probes.show_controllers = Settings.debug
	probes.shown_field = current
	field.transform = current.box
	var supported := _probe_axes_supported(current.box.basis)
	probe_button.disabled = not supported or not ClassDB.class_exists("InputEventSpatialTouch") or not ClassDB.class_exists("InputEventSpatialDrag")
	probe_button.tooltip_text = "Pause and place two scalar probes with a pinch. Turn off to rotate the model." if supported else "Hand probes are unavailable for this field: the current visionOS renderer cannot preserve sheared field axes."
	if probing and not supported:
		set_probe_mode(false)
		return
	touch.set_brick(meta.read(current.files[frame]), current.cells, current.peak if current.peak > 0 else 255)
	if field_changed and (probing or history.visible):
		fit()
	_refresh_inspection()


func _measure_peak(path: String, index: int, files: PackedStringArray) -> void:
	var zip := ZIPReader.new()
	if zip.open(path) != OK:
		return
	var peak := 0
	for file in files:
		var bytes := zip.read_file(file)
		if not bytes.is_empty():
			bytes.sort()
			peak = maxi(peak, bytes[-1])
	zip.close()
	_set_peak.call_deferred(index, peak)


func _set_peak(index: int, peak: int) -> void:
	if is_queued_for_deletion() or entry == null:
		return
	entry.fields[index].peak = peak
	if index == field_index:
		update_field()


func _exit_tree() -> void:
	if clock and clock.changed.is_connected(_follow_clock):
		clock.changed.disconnect(_follow_clock)
		clock.release()
	for task in _peak_tasks:
		WorkerThreadPool.wait_for_task_completion(task)
	_peak_tasks.clear()


## Turns the model as the person pinches and drags it, like Apple's globe:
## moving the hand sideways turns it about the vertical without limit, and
## moving it up or down tilts it toward or away from the person, up to
## [constant TILT_LIMIT]. Both follow how far the hand has moved since the
## pinch began, so small jitters don't add up, and the model eases after the
## hand. On release the tilt springs back and the turn carries on a little.
## Only a pinch turns it: a finger brushing the model leaves it be.
## Spatial events only come from visionOS; on desktop, the orbit camera
## turns the view instead.
func turn_by_drag(camera: Node, event: InputEvent, _position: Vector3, _normal: Vector3, _shape: int) -> void:
	if probing:
		return
	if event.is_class("InputEventSpatialTouch"):
		if event.get("pressed") and not event.get("canceled"):
			_ended.erase(event.get("index"))
		else:
			_ended[event.get("index")] = true
		if _label_touch != -1 and event.get("index") == _label_touch:
			if not event.get("pressed") or event.get("canceled"):
				_label_touch = -1
			return
		if event.get("canceled"):
			if event.get("index") == _drag:
				_drag = -1
				_tilt_target = 0.0
			return
		if event.get("pressed") and _drag < 0 and labels.select_from_spatial_touch(camera, event):
			_label_touch = event.get("index")
			return
		if event.get("pressed") and _drag < 0 and event.get("kind") != KIND_TOUCH:
			_begin_drag(event.get("index"), event.get("world_position"))
		elif not event.get("pressed") and event.get("index") == _drag:
			_drag = -1
			_tilt_target = 0.0
			_yaw_target += clampf(_yaw_speed * SPIN_TIME, -PI, PI)
		return
	if not event.is_class("InputEventSpatialDrag"):
		return
	if _label_touch != -1 and event.get("index") == _label_touch:
		return
	if _ended.has(event.get("index")):
		return
	var at: Vector3 = event.get("world_position")
	if _drag < 0 and event.get("kind") != KIND_TOUCH:
		_begin_drag(event.get("index"), at - (event.get("world_relative") as Vector3))
	if event.get("index") != _drag:
		return
	var moved := at - _drag_start
	var turned := _yaw_target
	_yaw_target = _drag_yaw + moved.dot(_drag_across) / _radius * TURN_GAIN
	var delta := maxf(get_process_delta_time(), 0.001)
	_yaw_speed = lerpf(_yaw_speed, (_yaw_target - turned) / delta, 0.5)
	_tilt_target = _ease_tilt(_drag_tilt - moved.y / _radius * TURN_GAIN)


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
	if not facing.is_zero_approx():
		_drag_across = facing.normalized().cross(Vector3.UP)
	if absf(tilt) < deg_to_rad(1.0):
		_tilt_axis = _drag_across


## Eases [param raw] toward [constant TILT_LIMIT] rather than stopping at it:
## one for one near upright, slower and slower toward the limit.
static func _ease_tilt(raw: float) -> float:
	return TILT_LIMIT * atan(raw / TILT_LIMIT * PI / 2.0) * 2.0 / PI


static func _unease_tilt(eased: float) -> float:
	return TILT_LIMIT * tan(clampf(eased / TILT_LIMIT, -0.99, 0.99) * PI / 2.0) * 2.0 / PI


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


## Frames the volume on the model and labels so they can turn without leaving
## the volume or changing size: on a sphere about its center that reaches
## its farthest vertex. The field box, shown only while debugging, may reach
## past it.
func fit() -> void:
	inspection.cancel()
	var bounds := AABB()
	for frames in parts:
		var box := frames.get_bounds()
		if box.has_volume():
			bounds = box if bounds.size == Vector3.ZERO else bounds.merge(box)
	var boxes: Array[AABB] = []
	for each: Meta.Field in entry.fields:
		boxes.append(each.box * AABB(Vector3.ZERO, Vector3.ONE))
	if bounds.size == Vector3.ZERO:
		for box in boxes:
			bounds = box if bounds.size == Vector3.ZERO else bounds.merge(box)
	# A document can contain just labels, with no model or field to frame.
	if bounds.size == Vector3.ZERO and not entry.labels.is_empty():
		bounds = AABB(entry.labels[0].position, Vector3.ZERO)
		for label: Meta.PointLabel in entry.labels:
			bounds = bounds.expand(label.position)
	_center = bounds.get_center()
	_radius = 0.0
	for frames in parts:
		_radius = maxf(_radius, frames.get_radius(_center))
	if is_zero_approx(_radius):
		_radius = maxf(bounds.size.length() * 0.5, 0.001)
	for label: Meta.PointLabel in entry.labels:
		_radius = maxf(_radius, label.position.distance_to(_center))
	if (probing or history.visible or is_instance_valid(hand_workbench)) and not entry.fields.is_empty():
		var box: Transform3D = entry.fields[field_index].box
		for corner in 8:
			var point := box * Vector3(corner & 1, (corner >> 1) & 1, (corner >> 2) & 1)
			_radius = maxf(_radius, point.distance_to(_center))
	# The model is grabbed by its bounds, which stay inside the volume and
	# leave the space around the model for moving the window.
	grab.position = _center
	(grab.get_node("Shape").shape as BoxShape3D).size = bounds.size.max(Vector3.ONE * maxf(bounds.size[bounds.size.max_axis_index()] * 0.02, 0.001))
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


func select_field(index: int) -> void:
	if index < 0 or index >= entry.fields.size():
		return
	field_index = index
	for button in $Model/Options/Bar.get_children():
		if button.has_meta("field_index"):
			button.set_pressed_no_signal(button.get_meta("field_index") == index)
	update_field()


func _show_hand_tracking_error(message: String) -> void:
	if is_queued_for_deletion():
		return
	var alert := AcceptDialog.new()
	alert.title = "Hand inspection unavailable"
	alert.dialog_text = message
	alert.dialog_autowrap = true
	alert.size = Vector2i(880, 240)
	model.add_child(alert)
	alert.confirmed.connect(alert.queue_free)
	alert.canceled.connect(alert.queue_free)
	alert.popup_centered()


func show_probe_history() -> void:
	history.show()
	history.refresh()
	update_field()
	fit()


func hide_probe_history() -> void:
	history.hide()
	update_field()
	fit()


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
	if enabled and is_instance_valid(hand_workbench):
		hand_workbench.stop()
	probing = enabled and entry != null and not entry.fields.is_empty() and _probe_axes_supported(entry.fields[field_index].box.basis)
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
	inspection.handle_event(event, hit, field.global_transform)


## Samples pins again from the current brick. Pins are normalized field
## coordinates, so rotating/resizing a volume never moves a pin to another cell.
func _refresh_inspection() -> void:
	if not is_node_ready() or touch == null:
		return
	var points: Dictionary = inspection.get_points()
	probes.inspection_points = points if probing or ((history.visible or is_instance_valid(hand_workbench)) and entry != null and not entry.fields.is_empty() and _probe_axes_supported(entry.fields[field_index].box.basis)) else {}
	history.refresh()
	probe_readout.text = format_probe_readings(points)
	if entry == null or entry.fields.is_empty():
		return
	var state := "Moving %s · release inside the field to pin" % ("A" if inspection.selected_slot == 0 else "B") if inspection.is_active() else "Select A or B, pinch the field box, then move your hand in 3D. Release to pin."
	probe_readout.text += "\n" + state
	_resize_probe_options.call_deferred()


## One current-frame summary for the volume, history, and hand workbench.
## Callers choose released pins or a live gesture; formatting never changes them.
func format_probe_readings(points: Dictionary) -> String:
	if entry == null or entry.fields.is_empty():
		return "This document has no scalar field."
	var current: Meta.Field = entry.fields[field_index]
	var rows := PackedStringArray()
	var values := {}
	for slot in [0, 1]:
		var name := "A" if slot == 0 else "B"
		if not points.has(slot):
			rows.append("%s: not placed" % name)
			continue
		var cell: Vector3i = touch.cell_at_unit(points[slot])
		if cell == touch.NO_CELL:
			rows.append("%s: No data (current scalar frame unavailable)" % name)
			continue
		var byte: int = touch.byte_of(cell)
		if byte > 0:
			values[slot] = current.value_of(byte)
		rows.append("%s: %s · cell (%d, %d, %d)" % [name, "No data" if byte == 0 else current.format(values[slot]), cell.x, cell.y, cell.z])
	var difference := "B − A: place both probes on valid data"
	if values.has(0) and values.has(1):
		difference = "B − A: " + current.format(values[1] - values[0])
	return "%s · frame %d / %d · solver time %s\n%s\n%s" % [current.name, frame + 1, frame_count, String.num(entry.times[frame], 14), "\n".join(rows), difference]


## Adds only A/B tools to the existing Options panel and immersive host.
func start_hand_tracking() -> void:
	if is_instance_valid(hand_workbench):
		hand_workbench.stop()
		return
	hand_workbench = HandWorkbench.instantiate()
	hand_workbench.failed.connect(_show_hand_tracking_error)
	options.add_child(hand_workbench)
	hand_workbench.minimum_size_changed.connect(_resize_probe_options)
	var error: String = hand_workbench.start(self)
	if not error.is_empty():
		hand_workbench.queue_free()
		hand_workbench = null
		_show_hand_tracking_error(error)
	else:
		probe_tools.hide()
		show_options(true)
	_resize_probe_options.call_deferred()


func set_playing(value: bool) -> void:
	if clock != null:
		clock.set_playing(value)


## Window sizes are physical pixels; controls use logical points. The native
## window inherits a scale of two, while desktop ornaments reset it to one.
func _resize_probe_options() -> void:
	if not is_node_ready():
		return
	var bar: HFlowContainer = $Model/Options/Bar
	# Keep the normal toolbar on one row when there is room. Additional
	# fields wrap at the model window's width (or its original ornament width).
	var width := bar.offset_left - bar.offset_right
	var gap: int = bar.get_theme_constant("h_separation")
	for child: Control in bar.get_children():
		if child.visible:
			width += child.get_combined_minimum_size().x + gap
	width = clampf(width - gap, 480.0, 740.0)
	if SpatialPlatform.current() == SpatialPlatform.Kind.DESKTOP:
		width = minf(width, maxf(480.0, model.get_visible_rect().size.x - 24.0))
	var height := maxf(56.0, bar.get_combined_minimum_size().y + 12.0)
	bar.offset_bottom = height
	probe_tools.offset_top = height
	if probing:
		height += probe_tools.get_combined_minimum_size().y + 12.0
	if is_instance_valid(hand_workbench) and not hand_workbench.is_queued_for_deletion():
		hand_workbench.offset_left = 20.0
		hand_workbench.offset_right = -20.0
		hand_workbench.anchor_right = 1.0
		hand_workbench.offset_top = height
		height += hand_workbench.get_combined_minimum_size().y + 12.0
	options.size = Vector2i(Vector2(width, height) * options.content_scale_factor)
