extends Node3D
## One of a ZIP's models: shows its GLB for the current frame, and keeps
## only the frames near it in memory. Upcoming frames load on worker threads
## and wait hidden, so a frame is ready, on visionOS in RealityKit too, by
## the time it shows. A model that doesn't change is one GLB, kept loaded.

const Meta := preload("res://app/meta.gd")
## How many frames after and before the current one are kept loaded.
const AHEAD := 3
const BEHIND := 1

var _zip_path := ""
var _model: Meta.Model
## Loaded GLBs by file, and the worker tasks loading the others.
var _scenes := {}
var _tasks := {}
## Scenes the tasks have finished, by file, until the main thread adds them.
var _finished := {}
var _mutex := Mutex.new()


func setup(zip_path: String, model: Meta.Model) -> void:
	_zip_path = zip_path
	_model = model
	name = model.name.validate_node_name()


## Shows frame [param frame], loading it now if it isn't yet, and starts
## loading the frames around it.
func show_frame(frame: int) -> void:
	var count := _model.files.size()
	var wanted := {}
	for offset in range(-BEHIND, AHEAD + 1):
		# Playback loops, so the frames after the last are the first ones.
		wanted[_model.files[posmod(frame + offset, count)]] = true
	var current := _model.files[frame]
	if not _scenes.has(current):
		if _tasks.has(current):
			WorkerThreadPool.wait_for_task_completion(_tasks[current])
			_tasks.erase(current)
		else:
			_load_into(current)
		_collect()
	for file in wanted:
		if not _scenes.has(file) and not _tasks.has(file):
			_tasks[file] = WorkerThreadPool.add_task(_load_into.bind(file))
	for file in _scenes.keys():
		if not wanted.has(file):
			_scenes[file].visible = false
			_scenes[file].queue_free()
			_scenes.erase(file)
	for file in _scenes:
		_scenes[file].visible = file == current


## The bounds of the frame showing, in this node's coordinates.
func get_bounds() -> AABB:
	var bounds := AABB()
	var first := true
	for scene: Node3D in _scenes.values():
		if not scene.visible:
			continue
		for mesh: MeshInstance3D in scene.find_children("*", "MeshInstance3D", true, false):
			var box := scene.transform * _local_transform(mesh, scene) * mesh.get_aabb()
			bounds = box if first else bounds.merge(box)
			first = false
	return bounds


func _process(_delta: float) -> void:
	_collect()


## Frames still loading finish first: their tasks report back to this node.
func _exit_tree() -> void:
	for file in _tasks:
		WorkerThreadPool.wait_for_task_completion(_tasks[file])
	_tasks.clear()
	for scene in _finished.values():
		if scene:
			scene.free()
	_finished.clear()


## Adds the scenes the workers have finished, hidden until they show.
func _collect() -> void:
	_mutex.lock()
	var finished := _finished
	_finished = {}
	_mutex.unlock()
	for file: String in finished:
		if _tasks.has(file):
			WorkerThreadPool.wait_for_task_completion(_tasks[file])
			_tasks.erase(file)
		var scene: Node3D = finished[file]
		if scene == null or _scenes.has(file):
			if scene:
				scene.free()
			continue
		scene.visible = false
		add_child(scene)
		_scenes[file] = scene


func _load_into(file: String) -> void:
	var scene := _load(_zip_path, file)
	_mutex.lock()
	_finished[file] = scene
	_mutex.unlock()


## Reads one GLB from the ZIP. Runs on any thread: it opens the ZIP itself.
static func _load(zip_path: String, file: String) -> Node3D:
	var zip := ZIPReader.new()
	if zip.open(zip_path) != OK:
		return null
	var bytes := zip.read_file(file)
	zip.close()
	var document := GLTFDocument.new()
	var state := GLTFState.new()
	if document.append_from_buffer(bytes, "", state) != OK:
		return null
	var scene := document.generate_scene(state) as Node3D
	for mesh: MeshInstance3D in scene.find_children("*", "MeshInstance3D", true, false):
		for surface in mesh.mesh.get_surface_count():
			var material = mesh.get_active_material(surface)
			# RealityKit needs ordinary blending for imported transparent materials.
			if material is BaseMaterial3D and material.transparency == BaseMaterial3D.TRANSPARENCY_ALPHA_DEPTH_PRE_PASS:
				material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	return scene


static func _local_transform(node: Node3D, root: Node3D) -> Transform3D:
	var transform := Transform3D()
	while node != root and node != null:
		transform = node.transform * transform
		node = node.get_parent() as Node3D
	return transform
