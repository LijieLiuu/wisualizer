extends RefCounted
## Two scalar probe pins in the field's unit cube. A visionOS spatial gesture
## moves a pin by the reported input-device pose delta from the initial hit.
## This is gesture-scoped input, not continuous finger-joint tracking.

signal changed

const ScalarData := preload("res://app/scalar_data.gd")
## Only the initial collider hit may be nudged off a face. Drags are never
## clamped into the field, so an outside position cannot produce a reading.
const BOUNDARY_EPSILON := 0.000001

var selected_slot := 0:
	set(value):
		if value not in [0, 1] or value == selected_slot:
			return
		cancel()
		selected_slot = value
		changed.emit()

var _pins: Dictionary = {}
var _active := false
var _index := 0
var _slot := 0
var _start_hit := Vector3.ZERO
var _start_pose := Vector3.ZERO
var _candidate := Vector3.ZERO
var _candidate_valid := false


## Returns true for spatial events, including rejected ones, so a caller in
## probe mode does not accidentally send them to the model-rotation handler.
## An explicit touch press is required; an orphan drag never starts a probe.
func handle_event(event: InputEvent, hit_world: Vector3, field_transform: Transform3D) -> bool:
	var touch := event.is_class("InputEventSpatialTouch")
	if not touch and not event.is_class("InputEventSpatialDrag"):
		return false
	var index: int = event.get("index")
	if event.is_canceled():
		finish(index, true)
		return true
	var pose: Variant = event.get("input_device_pose_position")
	if event.get("has_input_device_pose") != true or not pose is Vector3 or not pose.is_finite():
		if _active and index == _index:
			cancel()
		return true
	if touch and event.get("pressed"):
		begin(index, hit_world, pose, field_transform)
	elif touch:
		# The final event must still carry a valid pose. Never commit the last
		# good drag after tracking is lost or the hand leaves the field.
		move(index, pose, field_transform)
		finish(index)
	else:
		move(index, pose, field_transform)
	return true


func begin(index: int, hit_world: Vector3, pose_world: Vector3, field_transform: Transform3D) -> bool:
	if _active or not hit_world.is_finite() or not pose_world.is_finite():
		return false
	if not ScalarData.validate_transform(field_transform).is_empty():
		return false
	var unit := field_transform.affine_inverse() * hit_world
	if not unit.is_finite():
		return false
	for component in [unit.x, unit.y, unit.z]:
		if component < -BOUNDARY_EPSILON or component > 1.0 + BOUNDARY_EPSILON:
			return false
	unit = unit.clamp(Vector3.ONE * BOUNDARY_EPSILON, Vector3.ONE * (1.0 - BOUNDARY_EPSILON))
	var nudged_hit := field_transform * unit
	if not nudged_hit.is_finite():
		return false
	_active = true
	_index = index
	_slot = selected_slot
	_start_hit = nudged_hit
	_start_pose = pose_world
	_candidate = unit
	_candidate_valid = true
	changed.emit()
	return true


func move(index: int, pose_world: Vector3, field_transform: Transform3D) -> bool:
	if not _active or index != _index:
		return false
	if not pose_world.is_finite() or not ScalarData.validate_transform(field_transform).is_empty():
		cancel()
		return false
	var world := _start_hit + (pose_world - _start_pose)
	var unit := field_transform.affine_inverse() * world
	if not world.is_finite() or not unit.is_finite():
		cancel()
		return false
	_candidate = unit
	_candidate_valid = unit.x >= 0.0 and unit.y >= 0.0 and unit.z >= 0.0 and unit.x < 1.0 and unit.y < 1.0 and unit.z < 1.0
	changed.emit()
	return _candidate_valid


## A normal release pins only an in-box candidate; cancellation preserves
## the previous committed pin. A foreign gesture cannot end the active one.
func finish(index: int, canceled: bool = false) -> bool:
	if not _active or index != _index:
		return false
	if not canceled and _candidate_valid:
		_pins[_slot] = _candidate
	_active = false
	_candidate_valid = false
	changed.emit()
	return true


## During an outside drag, omit that slot instead of showing its old pin as
## though it were a current hand sample. Ending/canceling restores the pin.
func get_points() -> Dictionary:
	var points := _pins.duplicate()
	if _active:
		points.erase(_slot)
		if _candidate_valid:
			points[_slot] = _candidate
	return points


func is_active() -> bool:
	return _active


## Call on focus loss, hidden windows, mode changes, and frame changes.
func cancel() -> void:
	if _active:
		finish(_index, true)


## Call when the selected field/document changes, since normalized points
## from one field must not silently become pins in an unrelated field.
func clear() -> void:
	_active = false
	_candidate_valid = false
	_pins.clear()
	changed.emit()
