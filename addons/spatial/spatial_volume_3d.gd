class_name SpatialVolume3D
extends Node3D
## Marks the Window it belongs to as a volume: a box of this Window's world,
## [member size] units across, shown at a physical size of
## [member window_size] meters. The box is centered on this node.
##
## Each platform shows the volume its own way. On visionOS, GodotRealityKit
## opens the Window as a RealityKit volume. Elsewhere, the Window stays an
## ordinary window, viewed through an orbit camera.

## Emitted when the volume's physical size changes, such as after the person
## resizes it.
signal resized(size: Vector3)

## Which axis of [member window_size] [member size] spans.
enum KeepAspect {
	KEEP_WIDTH,
	KEEP_HEIGHT,
	KEEP_DEPTH,
}

const RealityKitVolume := preload("reality_kit/reality_kit_volume.gd")
const DesktopVolume := preload("desktop/desktop_volume.gd")

## The extent of the box along the [member keep_aspect] axis, in world units.
@export var size := 5.0:
	set(value):
		size = value
		_update()
@export var keep_aspect := KeepAspect.KEEP_DEPTH:
	set(value):
		keep_aspect = value
		_update()
## The physical size the volume opens at, in meters.
@export var window_size := Vector3.ONE:
	set(value):
		window_size = value
		_update()
## Zero components leave the minimum and maximum unbounded.
@export var window_min_size := Vector3.ZERO:
	set(value):
		window_min_size = value
		_update()
@export var window_max_size := Vector3.ZERO:
	set(value):
		window_max_size = value
		_update()

var _backend


func _enter_tree() -> void:
	# The backend must exist before the Window first shows, because that is
	# when visionOS decides whether the Window opens as a volume.
	if _backend == null:
		_backend = RealityKitVolume.new(self) if RealityKitVolume.is_available() else DesktopVolume.new(self)
		_backend.resized.connect(resized.emit)
	_update()


## The physical size the volume has while open, in meters, or zero before
## the platform reports it.
func get_measured_size() -> Vector3:
	return _backend.get_measured_size() if _backend != null else Vector3.ZERO


## The size of the visible box in world units, following the volume's
## current physical proportions.
func get_region_size() -> Vector3:
	var physical := get_measured_size()
	if physical == Vector3.ZERO:
		physical = window_size
	return physical * (size / physical[keep_aspect])


func _update() -> void:
	if _backend != null:
		_backend.update()
