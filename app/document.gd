extends Node
## One opened ZIP, shown as a volume the person can place anywhere. Its
## notes, if it has any, hang on the volume's left, and its controls below it.

const FPS := 4.0
const PLAY_ICON := preload("res://app/icons/play.svg")
const PAUSE_ICON := preload("res://app/icons/pause.svg")
const SPEEDS := [0.5, 1.0, 2.0, 4.0]
const NOTES_FILE := "notes.txt"
## Seconds a volume takes to open before the resize hint shows.
const HINT_DELAY := 0.6

@onready var model: Window = $Model
@onready var volume: SpatialVolume3D = $Model/Volume
@onready var field: Node3D = $Model/Field
@onready var controls: Window = $Model/Controls
@onready var options: Window = $Model/Options
@onready var notes: Window = $Model/Notes
@onready var play_button: Button = %Play
@onready var slider: HSlider = %Frame
@onready var counter: Label = %Count
@onready var field_button: CheckButton = %FieldBox
@onready var notes_button: Button = %NotesButton
@onready var options_button: Button = %OptionsButton
@onready var speed_group: ButtonGroup = $Model/Options/Margin/Column/Speeds/Speed0.button_group

var frames: Array[Array] = []
## The brick that maps a unit cube onto each frame's field.
var boxes: Array = []
var frame := 0
var playing := false
var elapsed := 0.0
var bounds := AABB(Vector3(-0.5, -0.5, -0.5), Vector3.ONE)


func _ready() -> void:
	# Window sizes are in pixels; show their content at the app's scale, as
	# the main window does (twice the pixels on visionOS).
	var scale := get_window().content_scale_factor
	for window: Window in [model, controls, options, notes]:
		window.content_scale_factor = scale


func open(path: String) -> void:
	var title := path.get_file().get_basename()
	var zip := ZIPReader.new()
	zip.open(path)
	var data := PackedByteArray()
	var text := ""
	var bricks := {}
	for file in zip.get_files():
		if file.get_extension().to_lower() == "glb":
			data = zip.read_file(file)
			continue
		if file.get_file() == NOTES_FILE:
			text = zip.read_file(file).get_string_from_utf8()
			continue
		var bytes := zip.read_file(file)
		# Field metadata is a few lines of text; the bricks it describes are megabytes.
		if bytes.size() < 4096:
			var meta := read_meta(bytes)
			if meta.has("TIME") and meta.has("BRICK ORIGIN"):
				var axes := Basis(vector(meta["BRICK X_AXIS"]), vector(meta["BRICK Y_AXIS"]), vector(meta["BRICK Z_AXIS"]))
				var brick := Transform3D(axes * Basis.from_scale(vector(meta["BRICK SIZE"])), vector(meta["BRICK ORIGIN"]))
				bricks[meta["TIME"].to_float()] = brick
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
		for brick_time in bricks:
			if is_equal_approx(brick_time, time):
				box = bricks[brick_time]
		boxes.append(box)
	state.root_nodes = roots
	var scene_root := document.generate_scene(state)
	var meshes := scene_root.find_children("*", "MeshInstance3D", true, false)
	for mesh in meshes:
		for surface in mesh.mesh.get_surface_count():
			var material = mesh.get_active_material(surface)
			# RealityKit needs ordinary blending for imported transparent materials.
			if material is BaseMaterial3D and material.transparency == BaseMaterial3D.TRANSPARENCY_ALPHA_DEPTH_PRE_PASS:
				material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	$Model/Content.add_child(scene_root)

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
	for box in boxes:
		if box != null:
			bounds = bounds.merge(box * AABB(Vector3.ZERO, Vector3.ONE))
	field_button.disabled = boxes.count(null) == boxes.size()
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


func show_options(shown: bool) -> void:
	options.visible = shown


func show_resize_hint() -> void:
	$Model/Volume/ResizeHint.play(volume.get_region_size())


func close() -> void:
	queue_free()


func toggle_play() -> void:
	set_playing(not playing)


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


func update_field() -> void:
	field.visible = field_button.button_pressed and boxes[frame] != null
	if field.visible:
		field.transform = boxes[frame]


func fit() -> void:
	var center := bounds.get_center()
	var volume_size := volume.get_measured_size()
	# Before the native window reports its size, use the size it opens at.
	if volume_size == Vector3.ZERO:
		volume_size = volume.window_size
	volume.position = center
	var required := bounds.size / volume_size
	volume.size = required[required.max_axis_index()] * volume_size[volume.keep_aspect] * 1.15


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
		seek((frame + 1) % frames.size())
