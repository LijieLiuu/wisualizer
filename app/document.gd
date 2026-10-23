extends Node
## One opened ZIP, shown as a volume the person can place anywhere. Its
## notes, if it has any, open in a window of their own beside the volume,
## which the person can move and resize, and its controls sit along the
## volume's bottom front edge.

const FPS := 4.0
const PLAY_ICON := preload("res://app/icons/play.svg")
const PAUSE_ICON := preload("res://app/icons/pause.svg")
const SPEEDS := [0.5, 1.0, 2.0, 4.0]
const NOTES_FILE := "notes.txt"
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

var frames: Array[Array] = []
## The brick that maps a unit cube onto each frame's field.
var boxes: Array = []
## Each frame's brick values and cell counts, or null without a field.
var bricks: Array = []
## The largest value in any brick.
var brick_peak := 0
var frame := 0
var playing := false
var elapsed := 0.0
var bounds := AABB(Vector3(-0.5, -0.5, -0.5), Vector3.ONE)
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
	if frames.is_empty():
		return
	if event.is_action_pressed(&"play_pause"):
		toggle_play()
	elif event.is_action_pressed(&"previous_frame", true):
		step(-1)
	elif event.is_action_pressed(&"next_frame", true):
		step(1)


func open(path: String) -> void:
	var title := path.get_file().get_basename()
	var zip := ZIPReader.new()
	zip.open(path)
	var data := PackedByteArray()
	var text := ""
	var notes_path := ""
	var metas := {}
	var blobs := {}
	for file in zip.get_files():
		if file.get_extension().to_lower() == "glb":
			data = zip.read_file(file)
			continue
		if file.get_file() == NOTES_FILE:
			text = zip.read_file(file).get_string_from_utf8()
			notes_path = file
			continue
		# The notes read their own images below.
		if NotesImages.is_image(file):
			continue
		var bytes := zip.read_file(file)
		# Field metadata is a few lines of text; the bricks it describes are megabytes.
		if bytes.size() < 4096:
			var meta := read_meta(bytes)
			if meta.has("TIME") and meta.has("BRICK ORIGIN"):
				var axes := Basis(vector(meta["BRICK X_AXIS"]), vector(meta["BRICK Y_AXIS"]), vector(meta["BRICK Z_AXIS"]))
				meta["box"] = Transform3D(axes * Basis.from_scale(vector(meta["BRICK SIZE"])), vector(meta["BRICK ORIGIN"]))
				metas[meta["TIME"].to_float()] = meta
		else:
			blobs[file.get_file()] = bytes
	if not text.is_empty():
		var notes_text: RichTextLabel = %Text
		text = notes_images.embed(text, zip, notes_path, str(get_instance_id()), notes_text.get_theme_color(&"default_color"), notes_text.get_theme_font_size(&"normal_font_size"))
	zip.close()

	var document := GLTFDocument.new()
	var state := GLTFState.new()
	document.append_from_buffer(data, "", state)
	var roots := PackedInt32Array()
	var counts: Array[int] = []
	for scene in state.get_json()["scenes"]:
		var nodes := PackedInt32Array(scene["nodes"])
		roots.append_array(nodes)
		counts.append(nodes.size())
		var time: float = scene.get("extensions", {}).get("ANSYS_scene_timevalue", {}).get("timevalue", NAN)
		# A field belongs to the scene with the same time.
		var box = null
		var brick = null
		for brick_time in metas:
			if is_equal_approx(brick_time, time):
				var meta: Dictionary = metas[brick_time]
				box = meta["box"]
				# The data file is named by the exporting machine's path.
				var blob: PackedByteArray = blobs.get(meta.get("DATA FILE", "").replace("\\", "/").get_file(), PackedByteArray())
				var cells := Vector3i(vector(meta.get("DATA SIZE", "0 0 0")))
				if meta.get("DATA FORMAT") == "BYTES" and blob.size() == cells.x * cells.y * cells.z:
					brick = [blob, cells]
					var sorted := blob.duplicate()
					sorted.sort()
					brick_peak = maxi(brick_peak, sorted[-1])
		boxes.append(box)
		bricks.append(brick)
	state.root_nodes = roots
	var scene_root := document.generate_scene(state)
	var meshes := scene_root.find_children("*", "MeshInstance3D", true, false)
	for mesh in meshes:
		for surface in mesh.mesh.get_surface_count():
			var material = mesh.get_active_material(surface)
			# RealityKit needs ordinary blending for imported transparent materials.
			if material is BaseMaterial3D and material.transparency == BaseMaterial3D.TRANSPARENCY_ALPHA_DEPTH_PRE_PASS:
				material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	content.add_child(scene_root)

	# The generated children follow the combined scene-root order above.
	var children := scene_root.get_children()
	var offset := 0
	for count in counts:
		frames.append(children.slice(offset, offset + count))
		offset += count

	var first := meshes[0] as MeshInstance3D
	bounds = first.global_transform * first.get_aabb()
	for mesh in meshes:
		bounds = bounds.merge(mesh.global_transform * mesh.get_aabb())
	fit_boxes(bounds)
	for box in boxes:
		if box != null:
			bounds = bounds.merge(box * AABB(Vector3.ZERO, Vector3.ONE))
	debug_button.disabled = boxes.count(null) == boxes.size()
	touch.volume = volume
	touch.field = field
	probes.touch = touch
	probes.volume = volume
	probes.field = field
	slider.max_value = frames.size() - 1
	seek(0)

	model.title = title
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
	queue_free()


func toggle_play() -> void:
	# Playing again after stopping at the end, without Loop, starts over.
	if not playing and not loop_button.button_pressed and frame == frames.size() - 1:
		seek(0)
	set_playing(not playing)


## Pauses and moves [param frames_by] frames, staying within the frames.
func step(frames_by: int) -> void:
	set_playing(false)
	seek(clampi(frame + frames_by, 0, frames.size() - 1))


## Follows a link in the notes. [code][url=frame:9]frame 9[/url][/code]
## pauses on the ninth frame; other links open as usual.
func open_link(meta: Variant) -> void:
	var link := str(meta)
	if link.begins_with("frame:"):
		set_playing(false)
		seek(clampi(link.trim_prefix("frame:").to_int() - 1, 0, frames.size() - 1))
	else:
		OS.shell_open(link)


func set_playing(value: bool) -> void:
	playing = value
	elapsed = 0.0
	play_button.icon = PAUSE_ICON if playing else PLAY_ICON


func seek(value: float) -> void:
	frame = int(value)
	for index in frames.size():
		for node in frames[index]:
			node.visible = index == frame
	slider.set_value_no_signal(frame)
	counter.text = "%d / %d" % [frame + 1, frames.size()]
	update_field()


## Shows the current frame's field box, and the field around each
## controller, if the debug switch is on. The field can be felt with a
## controller either way.
func update_field() -> void:
	var box = boxes[frame]
	field.visible = debug_button.button_pressed and box != null
	probes.visible = field.visible
	if box != null:
		field.transform = box
	if box != null and bricks[frame] != null:
		touch.set_brick(bricks[frame][0], bricks[frame][1], brick_peak)
	else:
		touch.set_brick(PackedByteArray(), Vector3i.ZERO, brick_peak)


func fit() -> void:
	var center := bounds.get_center()
	var volume_size := volume.get_measured_size()
	# Before the native window reports its size, use the size it opens at.
	if volume_size == Vector3.ZERO:
		volume_size = volume.window_size
	volume.position = center
	var required := bounds.size / volume_size
	volume.size = required[required.max_axis_index()] * volume_size[volume.keep_aspect] * 1.15


## Scales each frame's field brick about its center until it spans
## [param model] along the model's longest side. EnSight doesn't say what
## scale it writes bricks at, and it isn't the geometry's: the Hall sensor's
## brick says it is 40 across, around a model 80 across. So the scale comes
## from the model itself rather than from a fixed factor.
func fit_boxes(model: AABB) -> void:
	var first := boxes.find_custom(func(box) -> bool: return box != null)
	if first < 0:
		return
	var axis := model.size.max_axis_index()
	var scale: float = model.size[axis] / (boxes[first] as Transform3D).basis.get_scale()[axis]
	if is_equal_approx(scale, 1.0):
		return
	for index in boxes.size():
		var box = boxes[index]
		if box == null:
			continue
		var center: Vector3 = box * (Vector3.ONE * 0.5)
		boxes[index] = Transform3D(Basis.from_scale(Vector3.ONE * scale), center - center * scale) * box


## Reads "KEY: value" lines, such as "BRICK ORIGIN: -20 -20 -20".
func read_meta(bytes: PackedByteArray) -> Dictionary:
	var meta := {}
	for line in bytes.get_string_from_utf8().split("\n"):
		var parts := line.split(":", true, 1)
		if parts.size() == 2:
			meta[parts[0].strip_edges()] = parts[1].strip_edges()
	return meta


func vector(text: String) -> Vector3:
	var numbers := text.split_floats(" ", false)
	return Vector3(numbers[0], numbers[1], numbers[2])


func _process(delta: float) -> void:
	if not playing or frames.is_empty():
		return
	elapsed += delta * FPS * SPEEDS[speed_group.get_pressed_button().get_index()]
	while elapsed >= 1.0:
		elapsed -= 1.0
		if frame + 1 < frames.size():
			seek(frame + 1)
		elif loop_button.button_pressed:
			seek(0)
		else:
			set_playing(false)
			return
