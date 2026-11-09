extends SceneTree
## Runs without a headset. Native event-adapter checks run only when the
## RealityKit event classes are installed; their absence is reported.

const Probe := preload("res://app/spatial_probe.gd")
const IDENTITY := Transform3D.IDENTITY
var _checks := 0
var _failures := 0


func _initialize() -> void:
	_test_lifecycle()
	_test_affine_coordinates()
	_test_boundaries()
	_test_invalid_data()
	_test_event_adapter()
	print("Spatial probe: %d checks, %d failures" % [_checks, _failures])
	quit(1 if _failures else 0)


func _check(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error("FAIL: " + message)


func _point(probe: RefCounted, slot: int, expected: Vector3, message: String) -> void:
	var points: Dictionary = probe.get_points()
	_check(points.has(slot) and (points[slot] as Vector3).is_equal_approx(expected), message)


func _pin(probe: RefCounted, index: int, at: Vector3) -> void:
	_check(probe.begin(index, at, Vector3(2, 3, 4), IDENTITY), "Begin a pin")
	_check(probe.finish(index), "Release the pin")


func _test_lifecycle() -> void:
	var probe := Probe.new()
	_check(not probe.is_active() and probe.get_points().is_empty(), "New probe has no active or committed points")
	_check(not probe.move(1, Vector3.ONE, IDENTITY), "Orphan drag cannot synthesize a beginning")
	_check(not probe.finish(1), "Orphan release cannot pin anything")
	_pin(probe, 10, Vector3(0.2, 0.3, 0.4))
	_point(probe, 0, Vector3(0.2, 0.3, 0.4), "First release commits A")
	probe.selected_slot = 1
	_pin(probe, 20, Vector3(0.7, 0.6, 0.5))
	_check(probe.get_points().size() == 2, "A and B coexist independently")
	_point(probe, 0, Vector3(0.2, 0.3, 0.4), "Pinning B preserves A")
	probe.selected_slot = 0
	_check(probe.begin(30, Vector3(0.5, 0.5, 0.5), Vector3.ONE, IDENTITY), "Start replacing A")
	_check(not probe.begin(30, Vector3(0.9, 0.9, 0.9), Vector3.ZERO, IDENTITY), "Duplicate begin cannot replace the baseline")
	_check(not probe.begin(31, Vector3.ZERO, Vector3.ZERO, IDENTITY), "Second gesture cannot replace active ownership")
	_check(not probe.move(31, Vector3.ZERO, IDENTITY) and not probe.finish(31, true), "Foreign move/cancel cannot affect active gesture")
	_check(probe.move(30, Vector3(1.1, 0.8, 1.0), IDENTITY), "Owner moves relative to original pose")
	_point(probe, 0, Vector3(0.6, 0.3, 0.5), "Live point uses hand displacement, not absolute pose")
	probe.cancel()
	_check(not probe.is_active(), "Cancellation ends gesture")
	_point(probe, 0, Vector3(0.2, 0.3, 0.4), "Cancellation restores committed A")
	_point(probe, 1, Vector3(0.7, 0.6, 0.5), "Cancellation preserves B")
	_check(not probe.move(30, Vector3.ZERO, IDENTITY), "Drag after cancellation does not resume")
	probe.begin(40, Vector3(0.4, 0.4, 0.4), Vector3.ZERO, IDENTITY)
	probe.selected_slot = 1
	_check(not probe.is_active(), "Changing selected slot cancels active baseline")
	_point(probe, 0, Vector3(0.2, 0.3, 0.4), "Changing slots cannot pin or move A")
	probe.selected_slot = 8
	_check(probe.selected_slot == 1, "Invalid slot cannot create a third pin")
	var returned: Dictionary = probe.get_points()
	returned[0] = Vector3.ZERO
	returned.clear()
	_check(probe.get_points().size() == 2, "Returned points cannot mutate committed state")
	probe.begin(-7, Vector3(0.3, 0.3, 0.3), Vector3.ZERO, IDENTITY)
	_check(probe.is_active(), "Signed native event identifiers are supported")
	probe.clear()
	_check(not probe.is_active() and probe.get_points().is_empty(), "Field change clears active and committed points")
	_check(not probe.finish(-7), "Late release cannot resurrect cleared pins")


func _test_affine_coordinates() -> void:
	var probe := Probe.new()
	# Independent coordinate oracle: x = 5 - 3v + 0.5w,
	# y = -2 + 2u + 0.25w, z = 3 + 4w. Includes rotation,
	# nonuniform scale, shear, and translation.
	var field := Transform3D(Basis(Vector3(0, 2, 0), Vector3(-3, 0, 0), Vector3(0.5, 0.25, 4)), Vector3(5, -2, 3))
	_check(probe.begin(1, Vector3(3.85, -1.475, 3.4), Vector3(10, 8, -4), field), "Begin inside affine field")
	_point(probe, 0, Vector3(0.25, 0.4, 0.1), "World hit maps through full affine inverse")
	_check(probe.move(1, Vector3(10.45, 8.475, -2.8), field), "Affine pose delta stays in field")
	_point(probe, 0, Vector3(0.45, 0.3, 0.4), "Pose delta preserves shear and nonuniform scale")
	probe.finish(1)
	_point(probe, 0, Vector3(0.45, 0.3, 0.4), "Committed location remains normalized")
	# The same world displacement under a changed current transform must be
	# evaluated in that current field, not in a cached inverse.
	probe.clear()
	probe.begin(2, Vector3(0.4, 0.5, 0.6), Vector3.ZERO, IDENTITY)
	_check(probe.move(2, Vector3.ZERO, Transform3D(Basis.IDENTITY, Vector3(0.1, 0, 0))), "Current field transform is used")
	_point(probe, 0, Vector3(0.3, 0.5, 0.6), "Field transform change is not mistaken for hand movement")


func _test_boundaries() -> void:
	for axis in 3:
		for face in [0.0, 1.0]:
			var probe := Probe.new()
			var hit := Vector3.ONE * 0.5
			hit[axis] = face
			_check(probe.begin(1, hit, Vector3.ZERO, IDENTITY), "Each exact face hit can begin")
			var point: Vector3 = probe.get_points()[0]
			_check(point[axis] > 0.0 and point[axis] < 1.0 and absf(point[axis] - face) <= Probe.BOUNDARY_EPSILON * 1.1, "Face is nudged only a tiny distance inside")
			_check(probe.move(1, Vector3.ZERO, IDENTITY), "Stationary release retains initial boundary nudge")
			probe.finish(1)
			_check(probe.get_points().has(0), "Stationary boundary gesture pins a sample")
	for x in [-Probe.BOUNDARY_EPSILON * 0.5, 1.0 + Probe.BOUNDARY_EPSILON * 0.5]:
		var probe := Probe.new()
		_check(probe.begin(1, Vector3(x, 0.5, 0.5), Vector3.ZERO, IDENTITY), "Tiny collider roundoff at a face is tolerated")
	for x in [-Probe.BOUNDARY_EPSILON * 10.0, 1.0 + Probe.BOUNDARY_EPSILON * 10.0]:
		var probe := Probe.new()
		_check(not probe.begin(1, Vector3(x, 0.5, 0.5), Vector3.ZERO, IDENTITY), "An actual outside collider hit is rejected")
	for offset in [Vector3(-0.6, 0, 0), Vector3(0.5, 0, 0), Vector3(0, -0.6, 0), Vector3(0, 0.5, 0), Vector3(0, 0, -0.6), Vector3(0, 0, 0.5)]:
		var probe := Probe.new()
		_pin(probe, 1, Vector3(0.2, 0.3, 0.4))
		probe.begin(2, Vector3.ONE * 0.5, Vector3.ZERO, IDENTITY)
		_check(not probe.move(2, offset, IDENTITY), "Outside movement cannot yield a sample")
		_check(probe.is_active() and not probe.get_points().has(0), "Outside live sample is hidden without losing gesture ownership")
		probe.finish(2)
		_point(probe, 0, Vector3(0.2, 0.3, 0.4), "Release outside preserves prior pin")
	var probe := Probe.new()
	probe.begin(1, Vector3.ONE * 0.5, Vector3.ZERO, IDENTITY)
	probe.move(1, Vector3.ONE, IDENTITY)
	_check(probe.move(1, Vector3(0.1, 0.2, 0.3), IDENTITY), "Same gesture can re-enter field")
	probe.finish(1)
	_point(probe, 0, Vector3(0.6, 0.7, 0.8), "Re-entry uses original baseline")


func _test_invalid_data() -> void:
	var probe := Probe.new()
	_pin(probe, 1, Vector3.ONE * 0.25)
	for bad in [Vector3(NAN, 0, 0), Vector3(0, INF, 0), Vector3(0, 0, -INF)]:
		_check(not probe.begin(2, bad, Vector3.ZERO, IDENTITY), "Reject nonfinite initial hit")
		_check(not probe.begin(2, Vector3.ONE * 0.5, bad, IDENTITY), "Reject nonfinite initial pose")
		probe.begin(2, Vector3.ONE * 0.5, Vector3.ZERO, IDENTITY)
		_check(not probe.move(2, bad, IDENTITY) and not probe.is_active(), "Nonfinite live pose cancels tracking")
		_point(probe, 0, Vector3.ONE * 0.25, "Bad tracking cannot overwrite committed pin")
	for field in [Transform3D(Basis.from_scale(Vector3(0, 1, 1)), Vector3.ZERO), Transform3D(Basis.IDENTITY, Vector3(NAN, 0, 0)), Transform3D(Basis.from_scale(Vector3(INF, 1, 1)), Vector3.ZERO)]:
		_check(not probe.begin(2, Vector3.ONE * 0.5, Vector3.ZERO, field), "Reject singular/nonfinite initial field transform")
		probe.begin(2, Vector3.ONE * 0.5, Vector3.ZERO, IDENTITY)
		_check(not probe.move(2, Vector3.ZERO, field) and not probe.is_active(), "Invalid live transform cancels tracking")
		_point(probe, 0, Vector3.ONE * 0.25, "Invalid transform cannot overwrite committed pin")
	probe.begin(3, Vector3.ONE * 0.5, Vector3(-3e38, 0, 0), IDENTITY)
	_check(not probe.move(3, Vector3(3e38, 0, 0), IDENTITY) and not probe.is_active(), "Finite inputs whose subtraction overflows are rejected")


func _native_event(kind: String, index: int, pose: Vector3, pressed: bool = true) -> InputEvent:
	var event: InputEvent = ClassDB.instantiate(kind)
	event.set("index", index)
	event.set("has_input_device_pose", true)
	event.set("input_device_pose_position", pose)
	if kind == "InputEventSpatialTouch":
		event.set("pressed", pressed)
	return event


func _test_event_adapter() -> void:
	var probe := Probe.new()
	_check(not probe.handle_event(InputEventMouseButton.new(), Vector3.ZERO, IDENTITY), "Ordinary mouse event is not a tracked spatial gesture")
	if not ClassDB.class_exists("InputEventSpatialTouch") or not ClassDB.class_exists("InputEventSpatialDrag"):
		print("SKIP: native SpatialTouch/SpatialDrag adapter checks; RealityKit event classes are not installed. Core gesture state tests still ran.")
		return
	var drag := _native_event("InputEventSpatialDrag", 1, Vector3.ZERO)
	_check(probe.handle_event(drag, Vector3.ONE * 0.5, IDENTITY) and not probe.is_active(), "Native orphan drag is consumed without beginning")
	var press := _native_event("InputEventSpatialTouch", 1, Vector3.ZERO)
	_check(probe.handle_event(press, Vector3.ONE * 0.5, IDENTITY) and probe.is_active(), "Native touch starts at collision hit")
	var release := _native_event("InputEventSpatialTouch", 1, Vector3(0.1, 0.2, 0.3), false)
	probe.handle_event(release, Vector3.ZERO, IDENTITY)
	_point(probe, 0, Vector3(0.6, 0.7, 0.8), "Native release uses final pose, not event hit")
	probe.handle_event(press, Vector3.ONE * 0.5, IDENTITY)
	release.set("has_input_device_pose", false)
	probe.handle_event(release, Vector3.ZERO, IDENTITY)
	_check(not probe.is_active(), "Missing pose on native release cancels")
	_point(probe, 0, Vector3(0.6, 0.7, 0.8), "Missing release pose rolls back previous pin")
	probe.handle_event(press, Vector3.ONE * 0.5, IDENTITY)
	release.set("has_input_device_pose", true)
	release.set("canceled", true)
	probe.handle_event(release, Vector3.ZERO, IDENTITY)
	_point(probe, 0, Vector3(0.6, 0.7, 0.8), "Native cancellation cannot commit final pose")
	probe.handle_event(press, Vector3.ONE * 0.5, IDENTITY)
	release.set("canceled", false)
	release.set("input_device_pose_position", Vector3.ONE * 2.0)
	probe.handle_event(release, Vector3.ZERO, IDENTITY)
	_point(probe, 0, Vector3(0.6, 0.7, 0.8), "Native outside release cannot commit stale in-box sample")

	probe.handle_event(press, Vector3.ONE * 0.5, IDENTITY)
	var foreign := _native_event("InputEventSpatialDrag", 99, Vector3(NAN, 0, 0))
	foreign.set("has_input_device_pose", false)
	probe.handle_event(foreign, Vector3.ZERO, IDENTITY)
	_check(probe.is_active(), "A foreign event losing its pose cannot cancel the owner")
	drag.set("input_device_pose_position", Vector3(0.1, 0, 0))
	probe.handle_event(drag, Vector3(0.9, 0.9, 0.9), IDENTITY)
	_point(probe, 0, Vector3(0.6, 0.5, 0.5), "Native drag ignores changing ray-hit positions")
	drag.set("has_input_device_pose", false)
	drag.set("world_relative", Vector3(0.01, 0, 0))
	probe.handle_event(drag, Vector3.ONE * 0.5, IDENTITY)
	_check(not probe.is_active(), "Missing native pose cancels instead of inferring movement from world_relative")
	_point(probe, 0, Vector3(0.6, 0.7, 0.8), "Native lost-pose drag rolls back the live position")
	drag.set("has_input_device_pose", true)
	probe.handle_event(drag, Vector3.ONE * 0.5, IDENTITY)
	_check(not probe.is_active(), "Regaining a pose on a drag cannot resume a canceled gesture")
	press.set("has_input_device_pose", false)
	probe.handle_event(press, Vector3.ONE * 0.5, IDENTITY)
	_check(not probe.is_active(), "A native press without a pose cannot begin")
	press.set("has_input_device_pose", true)
	press.set("input_device_pose_position", Vector3(INF, 0, 0))
	probe.handle_event(press, Vector3.ONE * 0.5, IDENTITY)
	_check(not probe.is_active(), "A native press with nonfinite pose cannot begin")
	press.set("input_device_pose_position", Vector3.ZERO)
	probe.handle_event(press, Vector3.ONE * 0.5, IDENTITY)
	release.set("input_device_pose_position", Vector3(0.1, 0, 0))
	probe.handle_event(release, Vector3.ZERO, Transform3D(Basis.from_scale(Vector3.ZERO), Vector3.ZERO))
	_check(not probe.is_active(), "Invalid transform at native release cancels")
	_point(probe, 0, Vector3(0.6, 0.7, 0.8), "Invalid release transform cannot pin an earlier valid position")
	probe.handle_event(press, Vector3.ONE * 0.5, IDENTITY)
	release.set("canceled", true)
	release.set("has_input_device_pose", false)
	probe.handle_event(release, Vector3(NAN, 0, 0), IDENTITY)
	_check(not probe.is_active(), "Native canceled touch works without hit or pose payload")
	_point(probe, 0, Vector3(0.6, 0.7, 0.8), "Payload-free cancellation preserves the prior pin")
