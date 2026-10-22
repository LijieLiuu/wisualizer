extends RefCounted
## Desktop backend: the volume's Window stays an ordinary OS window, sized
## from the volume's physical size, and an orbit camera frames the box.

signal resized(size: Vector3)

const OrbitCamera3D := preload("orbit_camera_3d.gd")

## The same scale visionOS uses for windows: points per meter.
const POINTS_PER_METER := 1360.0

var _volume: SpatialVolume3D
var _camera: OrbitCamera3D


func _init(volume: SpatialVolume3D) -> void:
	_volume = volume
	_camera = OrbitCamera3D.new()
	_camera.name = "OrbitCamera3D"
	volume.add_child(_camera)
	var window := volume.get_window()
	if window != volume.get_tree().root:
		var screen := DisplayServer.get_primary_screen()
		var pixels := POINTS_PER_METER * DisplayServer.screen_get_scale(screen)
		var usable := Vector2(DisplayServer.screen_get_usable_rect(screen).size) * 0.6
		var wanted := Vector2(volume.window_size.x, volume.window_size.y) * pixels
		if usable.x > 0.0 and usable.y > 0.0:
			wanted *= minf(1.0, minf(usable.x / wanted.x, usable.y / wanted.y))
		window.size = Vector2i(wanted)
		var minimum := Vector2(volume.window_min_size.x, volume.window_min_size.y) * pixels
		window.min_size = Vector2i(minimum.min(Vector2(window.size)))


func update() -> void:
	_camera.region = _volume.get_region_size()


## A desktop window has no physical size; it keeps the size it opened at.
func get_measured_size() -> Vector3:
	return _volume.window_size


## A desktop has no tracked controllers.
func get_controllers() -> Array[XRController3D]:
	return []
