extends Node
## Lets the person feel the field with a tracked controller. The tip of each
## controller's aim ray samples the current frame's brick: entering the field
## clicks, and inside it the controller taps faster, harder and sharper where
## the value is higher. Works with whatever controllers the volume has.

## How far ahead of the controller's aim location the tip sits, in meters:
## at the end of the visionOS pointer ray, which starts at the controller's
## front rather than at the aim location near the heel of the hand.
const ScalarData := preload("res://app/scalar_data.gd")
const TIP := 0.18
const ENTRY_FREQUENCY := 300.0
const ENTRY_AMPLITUDE := 0.6
## Taps at the weakest and strongest values.
const TAP_INTERVAL := Vector2(0.35, 0.08)
const TAP_AMPLITUDE := Vector2(0.25, 1.0)
const TAP_FREQUENCY := Vector2(80.0, 250.0)
const TAP_DURATION := 0.04

var volume: SpatialVolume3D
## Its global transform maps a unit cube onto the current brick, whether or
## not the field box shows.
var field: Node3D

## The current frame's brick: one byte per cell, x fastest, 0 where the
## cell has no value.
var bytes := PackedByteArray()
var cells := Vector3i.ZERO
## The byte that stands for the field's largest value, so strength compares
## across frames.
var peak := 1
## Changes each time the brick does.
var revision := 0
## Each controller's seconds until its next tap, or -1 outside the field.
var _waits := {}


## Sets the brick to feel, or none when [param data] is empty.
func set_brick(data: PackedByteArray, size: Vector3i, largest: int) -> void:
	var count := ScalarData.cell_count(size)
	# A failed/corrupt read clears the previous frame instead of exposing stale
	# values or allowing an out-of-range sample.
	bytes = data if count > 0 and data.size() == count else PackedByteArray()
	cells = size if not bytes.is_empty() else Vector3i.ZERO
	peak = maxi(largest, 1)
	revision += 1


func _process(delta: float) -> void:
	if volume == null:
		return
	for controller in volume.get_controllers():
		var value := _sample(controller)
		var wait: float = _waits.get(controller, -1.0)
		if value <= 0.0:
			_waits[controller] = -1.0
			continue
		if wait < 0.0:
			controller.trigger_haptic_pulse(&"haptic", ENTRY_FREQUENCY, ENTRY_AMPLITUDE, 0.0, 0.0)
			wait = TAP_INTERVAL.x
		wait -= delta
		if wait <= 0.0:
			controller.trigger_haptic_pulse(&"haptic", lerpf(TAP_FREQUENCY.x, TAP_FREQUENCY.y, value),
					lerpf(TAP_AMPLITUDE.x, TAP_AMPLITUDE.y, value), TAP_DURATION, 0.0)
			wait = lerpf(TAP_INTERVAL.x, TAP_INTERVAL.y, value)
		_waits[controller] = wait


## The cell outside the brick, as [method cell_at] returns it.
const NO_CELL := Vector3i(-1, -1, -1)


## The field's value at the controller's tip, from 0 to 1, or 0 outside it.
func _sample(controller: XRController3D) -> float:
	if not controller.get_has_tracking_data():
		return 0.0
	return value_of(cell_at(tip_of(controller)))


## Where [param controller] feels the field, in global coordinates. The pose
## carries the volume's scale, so the tip is TIP meters ahead.
func tip_of(controller: XRController3D) -> Vector3:
	return controller.global_transform * Vector3(0, 0, -TIP)


## The brick cell holding [param point], given in global coordinates, or
## [constant NO_CELL] outside the brick or without one.
func cell_at(point: Vector3) -> Vector3i:
	if bytes.is_empty() or not is_instance_valid(field) or not field.is_inside_tree() or not point.is_finite():
		return NO_CELL
	var transform := field.global_transform
	if not ScalarData.validate_transform(transform).is_empty():
		return NO_CELL
	var unit := transform.affine_inverse() * point
	# Reject outside/nonfinite coordinates before converting to integer cells.
	if not unit.is_finite() or unit.x < 0.0 or unit.y < 0.0 or unit.z < 0.0 or unit.x >= 1.0 or unit.y >= 1.0 or unit.z >= 1.0:
		return NO_CELL
	var cell := Vector3i((unit * Vector3(cells)).floor())
	return cell if is_inside(cell) else NO_CELL


func is_inside(cell: Vector3i) -> bool:
	return cell.x >= 0 and cell.y >= 0 and cell.z >= 0 and cell.x < cells.x and cell.y < cells.y and cell.z < cells.z


## The field's value in [param cell], from 0 to 1 of the largest, or 0
## outside the brick or where the cell has no value.
func value_of(cell: Vector3i) -> float:
	return minf(float(byte_of(cell)) / peak, 1.0)


## The brick's byte for [param cell], or 0 outside it.
func byte_of(cell: Vector3i) -> int:
	if bytes.is_empty() or not is_inside(cell):
		return 0
	var index := cell.x + cells.x * (cell.y + cells.y * cell.z)
	return bytes[index] if index < bytes.size() else 0
