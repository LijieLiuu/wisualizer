extends MarginContainer
## Open one teaching ZIP, display its scenes as frames, and control playback.
## Each frame's field brick, when the ZIP has one, is outlined in the volume.

const FPS := 4.0
const SPEEDS := [0.5, 1.0, 2.0, 4.0]

@onready var play_button: Button = %Play
@onready var slider: HSlider = %Frame
@onready var counter: Label = %Count
@onready var speed: OptionButton = %Speed
@onready var time_label: Label = %Time
@onready var field_button: CheckButton = %FieldBox
@onready var volume: Window = $Model
@onready var camera: SpatialVolume3D = $Model/Camera
@onready var field: Node3D = $Model/Field

var frames: Array[Array] = []
## Each frame's solver time, and the brick that maps a unit cube onto its field.
var times: Array[float] = []
var boxes: Array = []
var frame := 0
var playing := false
var elapsed := 0.0
var bounds := AABB(Vector3(-0.5, -0.5, -0.5), Vector3.ONE)


func open_zip(path: String) -> void:
	volume.show()
	playing = false
	frames.clear()
	var content := volume.get_node("Content")
	for child in content.get_children():
		content.remove_child(child)
		child.queue_free()

	var zip := ZIPReader.new()
	zip.open(path)
	var data := PackedByteArray()
	var bricks := {}
	for file in zip.get_files():
		if file.get_extension().to_lower() == "glb":
			data = zip.read_file(file)
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
	times.clear()
	boxes.clear()
	for scene in state.get_json()["scenes"]:
		var nodes := PackedInt32Array(scene["nodes"])
		roots.append_array(nodes)
		counts.append(nodes.size())
		var time: float = scene.get("extensions", {}).get("ANSYS_scene_timevalue", {}).get("timevalue", NAN)
		times.append(time)
		# A field belongs to the scene with the same time.
		var box = null
		for brick_time in bricks:
			if is_equal_approx(brick_time, time):
				box = bricks[brick_time]
		boxes.append(box)
	state.root_nodes = roots
	var model := document.generate_scene(state)
	var meshes := model.find_children("*", "MeshInstance3D", true, false)
	for mesh in meshes:
		for surface in mesh.mesh.get_surface_count():
			var material = mesh.get_active_material(surface)
			# RealityKit needs ordinary blending for imported transparent materials.
			if material is BaseMaterial3D and material.transparency == BaseMaterial3D.TRANSPARENCY_ALPHA_DEPTH_PRE_PASS:
				material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	content.add_child(model)

	# The generated children follow the combined scene-root order above.
	var children := model.get_children()
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
	fit()
	seek(0)
	elapsed = 0.0
	playing = true
	slider.max_value = frames.size() - 1
	slider.editable = true
	play_button.disabled = false
	play_button.text = "Pause"


func toggle_play() -> void:
	playing = not playing
	elapsed = 0.0
	play_button.text = "Pause" if playing else "Play"


func seek(value: float) -> void:
	frame = int(value)
	for index in frames.size():
		for node in frames[index]:
			node.visible = index == frame
	slider.set_value_no_signal(frame)
	counter.text = "%d / %d" % [frame + 1, frames.size()]
	time_label.text = "t = –" if is_nan(times[frame]) else "t = %s" % times[frame]
	update_field()


func update_field() -> void:
	field.visible = field_button.button_pressed and boxes[frame] != null
	if field.visible:
		field.transform = boxes[frame]


func fit() -> void:
	var volume_size := camera.get_measured_size()
	# Before the native window reports its size, use the size it opens at.
	if volume_size == Vector3.ZERO:
		volume_size = camera.window_size
	camera.global_position = bounds.get_center()
	var required := bounds.size / volume_size
	camera.size = required[required.max_axis_index()] * volume_size[camera.keep_aspect] * 1.15


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
	if not playing:
		return
	elapsed += delta * FPS * SPEEDS[speed.selected]
	while elapsed >= 1.0:
		elapsed -= 1.0
		seek((frame + 1) % frames.size())
