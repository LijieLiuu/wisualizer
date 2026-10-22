extends RefCounted
## XR backend: the volume's Window shares the headset's world, and its 3D
## nodes move under one root that maps the volume's box onto a box of
## [member SpatialVolume3D.window_size] meters, wherever the layout places it.

signal resized(size: Vector3)

var _volume: SpatialVolume3D
var _window: Window
## Holds the Window's 3D nodes, mapping the volume's box into the world.
var _root := Node3D.new()


func _init(volume: SpatialVolume3D) -> void:
	_volume = volume
	_window = volume.get_window()
	_window.own_world_3d = false
	_root.name = "VolumeRoot"
	# The Window is still entering the tree; move its nodes once it's in.
	_adopt_nodes.call_deferred()
	SpatialXRLayout.of(volume).add_volume(_window, self)


func _adopt_nodes() -> void:
	_window.add_child(_root)
	for child in _window.get_children():
		if child is Node3D and child != _root:
			child.reparent(_root, false)


func update() -> void:
	pass


## A volume in XR keeps the size it opened at, for now.
func get_measured_size() -> Vector3:
	return _volume.window_size


## Places the volume's box, centered on [param frame].
func place(frame: Transform3D) -> void:
	var meters_per_unit := _volume.window_size[_volume.keep_aspect] / _volume.size
	_root.transform = frame * Transform3D(Basis.from_scale(Vector3.ONE * meters_per_unit), Vector3.ZERO) * _volume.transform.affine_inverse()
	_root.visible = _window.visible


## The layout's controllers; they share this volume's world.
func get_controllers() -> Array[XRController3D]:
	return SpatialXRLayout.of(_volume).controllers
