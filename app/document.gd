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
## Seconds a volume takes to open before the resize hint shows.
const HINT_DELAY := 0.6

@onready var model: Window = $Model
## The 3D nodes are found by unique name: platforms may move them within
## the Window.
@onready var content: Node3D = %Content
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
@onready var speed_group: ButtonGroup = $Model/Options/Bar/Speeds/Speed0.button_group

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


func _ready() -> void:
	for window: Window in [model, controls, options, notes]:
		window.window_input.connect(_on_window_input)
	# The bars are pointed at, not tabbed through, so the keyboard stays with
	# the shortcuts: a focused button would also take Space.
	for window: Window in [controls, options]:
		for control in window.find_children("*", "Control", true, false):
			if control is BaseButton or control is Range:
				control.focus_mode = Control.FOCUS_NONE


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
	var bar: HBoxContainer = %Separator.get_parent()
	for frames in models:
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
	if meta.fields.size() < 2:
		return
	var bar: HBoxContainer = %Separator.get_parent()
	var group := ButtonGroup.new()
	for index in meta.fields.size():
		var button := Button.new()
		button.text = meta.fields[index].name
		button.toggle_mode = true
		button.button_group = group
		button.button_pressed = index == field_index
		button.focus_mode = Control.FOCUS_NONE
		button.custom_minimum_size = Vector2(64, 44)
		button.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		button.pressed.connect(func() -> void:
			field_index = index
			update_field())
		bar.add_child(button)


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
	playing = value
	elapsed = 0.0
	play_button.icon = PAUSE_ICON if playing else PLAY_ICON


func seek(value: float) -> void:
	frame = int(value)
	for frames in models:
		frames.show_frame(frame)
	slider.set_value_no_signal(frame)
	counter.text = "%d / %d" % [frame + 1, frame_count]
	update_field()


## Shows the field box, and the field around each controller, if the debug
## switch is on. The field can be felt with a controller either way.
func update_field() -> void:
	if meta.fields.is_empty():
		field.visible = false
		probes.visible = false
		return
	var current: Meta.Field = meta.fields[field_index]
	field.visible = debug_button.button_pressed
	probes.visible = field.visible
	probes.shown_field = current
	field.transform = current.box
	touch.set_brick(meta.read(current.files[frame]), current.cells, 255)


## Frames the volume on the models and the fields, as they are at the
## current frame.
func fit() -> void:
	var bounds := AABB()
	var first := true
	for frames in models:
		var box := frames.get_bounds()
		if box.has_volume():
			bounds = box if first else bounds.merge(box)
			first = false
	for entry: Meta.Field in meta.fields:
		var box := entry.box * AABB(Vector3.ZERO, Vector3.ONE)
		bounds = box if first else bounds.merge(box)
		first = false
	var volume_size := volume.get_measured_size()
	# Before the native window reports its size, use the size it opens at.
	if volume_size == Vector3.ZERO:
		volume_size = volume.window_size
	volume.position = bounds.get_center()
	var required := bounds.size / volume_size
	volume.size = required[required.max_axis_index()] * volume_size[volume.keep_aspect] * 1.15


func _process(delta: float) -> void:
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
