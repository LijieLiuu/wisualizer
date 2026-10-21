extends RefCounted
## visionOS backend: GodotRealityKit opens a Window as a volume when the
## Window holds a RealityVolumeCamera3D, so the volume adds one and keeps it
## in step.

signal resized(size: Vector3)

const CAMERA_CLASS := &"RealityVolumeCamera3D"

var _volume: SpatialVolume3D
## The plugin's camera. Untyped, because its class exists only where the
## plugin is built.
var _camera


static func is_available() -> bool:
	return OS.has_feature("visionos") and ClassDB.class_exists(CAMERA_CLASS)


func _init(volume: SpatialVolume3D) -> void:
	_volume = volume
	_camera = ClassDB.instantiate(CAMERA_CLASS)
	_camera.name = "RealityVolumeCamera3D"
	_camera.preview_camera_enabled = false
	_camera.window_resized.connect(resized.emit)
	# The plugin looks for an ordinary child, not an internal one.
	volume.add_child(_camera)


func update() -> void:
	_camera.size = _volume.size
	_camera.keep_aspect = _volume.keep_aspect
	_camera.window_size = _volume.window_size
	_camera.window_min_size = _volume.window_min_size
	_camera.window_max_size = _volume.window_max_size


func get_measured_size() -> Vector3:
	return _camera.get_window_measured_size()
