extends SceneTree
## Synthetic fixtures use the engine's real XRHandTracker class. They prove
## consumer math and invalidation, not ARKit or physical headset tracking.

const Sample := preload("res://app/hand_tracking_sample.gd")
const TIP := XRHandTracker.HAND_JOINT_INDEX_FINGER_TIP
const FLAGS := XRHandTracker.HAND_JOINT_FLAG_POSITION_VALID | XRHandTracker.HAND_JOINT_FLAG_POSITION_TRACKED

class ReferenceInterface extends XRInterfaceExtension:
	func _get_name() -> StringName:
		return &"Hand sample reference fixture"
	func _is_initialized() -> bool:
		return true
	func _get_camera_transform() -> Transform3D:
		return Transform3D(Basis(Vector3.UP, 0.4), Vector3(10, 20, 30))

var _checks := 0
var _failures := 0


func _initialize() -> void:
	_run.call_deferred()


func _check(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error("FAIL: " + message)


func _tracker(at: Vector3, hand: int = XRPositionalTracker.TRACKER_HAND_LEFT) -> XRHandTracker:
	var tracker := XRHandTracker.new()
	tracker.hand = hand
	# Providers must initialize every native joint flag before publication.
	for joint in XRHandTracker.HAND_JOINT_MAX:
		tracker.set_hand_joint_flags(joint, 0)
	tracker.has_tracking_data = true
	tracker.set_hand_joint_flags(TIP, FLAGS)
	tracker.set_hand_joint_transform(TIP, Transform3D(Basis.IDENTITY, at))
	return tracker


func _empty(value: Dictionary, message: String) -> void:
	_check(not value.tracked and value.joints.is_empty() and not value.reason.is_empty(), message)


func _run() -> void:
	_test_provider_coordinates()
	_test_validity()
	_test_field_coordinates()
	print("Hand tracking sample: %d checks, %d failures" % [_checks, _failures])
	quit(1 if _failures else 0)


func _test_provider_coordinates() -> void:
	var left := _tracker(Vector3(0.2, 0.3, -0.4))
	# Independent oracle: a 90-degree Z turn maps (x,y,z) to (-y,x,z).
	# Origin axis lengths must be removed, and world scale applied once.
	var origin := Transform3D(Basis(Vector3(0, 2, 0), Vector3(-3, 0, 0), Vector3(0, 0, 4)), Vector3(5, -2, 7))
	var value := Sample.sample(left, origin, 2.5)
	_check(value.tracked and value.joints.size() == 1 and value.joints[TIP].is_equal_approx(Vector3(4.25, -1.5, 6)), "Rotated nonuniform origin and nonunit world scale match the provider's coordinate reversal: " + str(value))
	_check(not value.joints.has(XRHandTracker.HAND_JOINT_PALM), "A tracked fingertip is usable without a palm")
	left.set_pose("default", Transform3D(Basis.IDENTITY, Vector3(100, 200, 300)), Vector3.ZERO, Vector3.ZERO, XRPose.XR_TRACKING_CONFIDENCE_HIGH)
	_check(Sample.sample(left, origin, 2.5) == value, "Joint transforms are not multiplied by the palm/default pose again")
	var previous_interface := XRServer.primary_interface
	var previous_scale := XRServer.world_scale
	var previous_origin := XRServer.world_origin
	var reference := ReferenceInterface.new()
	XRServer.add_interface(reference)
	XRServer.primary_interface = reference
	XRServer.center_on_hmd(XRServer.RESET_FULL_ROTATION, false)
	XRServer.world_scale = 4.0
	XRServer.world_origin = Transform3D(Basis.IDENTITY, Vector3(8, 9, 10))
	_check(not XRServer.get_reference_frame().is_equal_approx(Transform3D.IDENTITY), "Reference-frame fixture actually creates a nonidentity recentering transform")
	_check(Sample.sample(left, origin, 2.5) == value, "Pure sampling ignores XRServer recentering, global origin, and global scale beyond explicit arguments")
	XRServer.clear_reference_frame()
	XRServer.primary_interface = previous_interface
	XRServer.remove_interface(reference)
	XRServer.world_scale = previous_scale
	XRServer.world_origin = previous_origin
	var right := _tracker(Vector3(-0.7, 0.5, 1.3), XRPositionalTracker.TRACKER_HAND_RIGHT)
	var right_value := Sample.sample(right, origin, 2.5)
	_check(right_value.joints[TIP].is_equal_approx(Vector3(3.75, -3.75, 10.25)), "Right-hand coordinates remain independent and are not mirrored implicitly")
	value.joints.clear()
	_check(Sample.sample(left, origin, 2.5).joints.has(TIP) and right_value.joints.has(TIP), "Mutating a returned snapshot cannot alter a tracker or another hand")
	left.has_tracking_data = false
	_empty(Sample.sample(left, origin, 2.5), "Tracking loss removes positions despite retained native joint data")
	_check(Sample.sample(right, origin, 2.5) == right_value, "Losing one hand never clears the other hand")
	left.has_tracking_data = true
	left.set_hand_joint_transform(TIP, Transform3D(Basis.IDENTITY, Vector3(1, 2, 3)))
	_check(Sample.sample(left, Transform3D.IDENTITY, 1.0).joints[TIP] == Vector3(1, 2, 3), "Tracking recovery samples fresh coordinates rather than cached positions")


func _test_validity() -> void:
	_empty(Sample.sample(null, Transform3D.IDENTITY, 1.0), "Missing tracker is explicitly unavailable")
	var tracker := _tracker(Vector3.ZERO)
	for flags in [0, XRHandTracker.HAND_JOINT_FLAG_POSITION_VALID, XRHandTracker.HAND_JOINT_FLAG_POSITION_TRACKED, XRHandTracker.HAND_JOINT_FLAG_ORIENTATION_VALID | XRHandTracker.HAND_JOINT_FLAG_ORIENTATION_TRACKED]:
		tracker.set_hand_joint_flags(TIP, flags)
		_empty(Sample.sample(tracker, Transform3D.IDENTITY, 1.0), "Incomplete position flags cannot authorize a sample")
	tracker.set_hand_joint_flags(TIP, FLAGS)
	_check(Sample.sample(tracker, Transform3D.IDENTITY, 1.0).joints[TIP] == Vector3.ZERO, "A real zero position is valid without orientation flags")
	for scale in [0.0, -1.0, NAN, INF]:
		_empty(Sample.sample(tracker, Transform3D.IDENTITY, scale), "Invalid world scale removes all positions")
	for origin in [Transform3D(Basis.IDENTITY, Vector3(INF, 0, 0)), Transform3D(Basis.from_scale(Vector3(1, 0, 1)), Vector3.ZERO), Transform3D(Basis(Vector3(NAN, 0, 0), Vector3.UP, Vector3.BACK), Vector3.ZERO)]:
		_empty(Sample.sample(tracker, origin, 1.0), "Invalid tracking origin cannot produce scene coordinates")
	for pose in [Transform3D(Basis.IDENTITY, Vector3(NAN, 0, 0)), Transform3D(Basis(Vector3(INF, 0, 0), Vector3.UP, Vector3.BACK), Vector3.ZERO)]:
		tracker.set_hand_joint_transform(TIP, pose)
		_empty(Sample.sample(tracker, Transform3D.IDENTITY, 1.0), "Nonfinite joint transform is rejected even when position flags claim validity")
	var thumb := XRHandTracker.HAND_JOINT_THUMB_TIP
	tracker.set_hand_joint_flags(thumb, FLAGS)
	tracker.set_hand_joint_transform(thumb, Transform3D(Basis.IDENTITY, Vector3.ONE))
	var partial := Sample.sample(tracker, Transform3D.IDENTITY, 1.0)
	_check(partial.tracked and partial.joints.size() == 1 and partial.joints.has(thumb), "An invalid joint does not suppress another valid joint")
	tracker.set_hand_joint_flags(thumb, 0)
	_empty(Sample.sample(tracker, Transform3D.IDENTITY, 1.0), "Losing the last valid joint cannot retain the previous snapshot")
	tracker.set_hand_joint_transform(TIP, Transform3D(Basis.IDENTITY, Vector3(1e30, 0, 0)))
	_empty(Sample.sample(tracker, Transform3D.IDENTITY, 1e30), "World-coordinate overflow is rejected after conversion")


func _test_field_coordinates() -> void:
	# x=5-3v+0.5w, y=-2+2u+0.25w, z=3+4w.
	var field := Transform3D(Basis(Vector3(0, 2, 0), Vector3(-3, 0, 0), Vector3(0.5, 0.25, 4)), Vector3(5, -2, 3))
	var snapshot := Sample.sample(_tracker(Vector3(3.85, -1.475, 3.4)), Transform3D.IDENTITY, 1.0)
	var normalized := Sample.normalize_tip(snapshot, TIP, field)
	_check(normalized.valid and normalized.unit.is_equal_approx(Vector3(0.25, 0.4, 0.1)) and normalized.reason.is_empty(), "Physical field rotation, nonuniform scale, translation, and affine factors map to normalized coordinates")
	for axis in 3:
		for edge in [0.0, 1.0, -0.0001, 1.0001]:
			var point := Vector3.ONE * 0.5
			point[axis] = edge
			var value := Sample.normalize_tip(Sample.sample(_tracker(point), Transform3D.IDENTITY, 1.0), TIP, Transform3D.IDENTITY)
			_check(value.valid == (edge == 0.0), "Each field axis accepts its lower face and excludes its upper/outside face")
	var inner := Vector3(0.9999, 0.0001, 0.5)
	_check(Sample.normalize_tip(Sample.sample(_tracker(inner), Transform3D.IDENTITY, 1.0), TIP, Transform3D.IDENTITY).valid, "Points just inside the half-open field remain valid")
	for invalid in [{}, {tracked = false, joints = {TIP: Vector3.ZERO}}, {tracked = true, joints = {}}, {tracked = true, joints = []}, {tracked = true, joints = {TIP: Vector3(INF, 0, 0)}}, {tracked = true, joints = {TIP: "invalid"}}]:
		var value := Sample.normalize_tip(invalid, TIP, Transform3D.IDENTITY)
		_check(not value.valid and value.unit == Vector3.ZERO and not value.reason.is_empty(), "Malformed or unavailable snapshots cannot produce a normalized reading")
	for joint in [-1, XRHandTracker.HAND_JOINT_MAX, XRHandTracker.HAND_JOINT_THUMB_TIP]:
		_check(not Sample.normalize_tip(snapshot, joint, field).valid, "Missing or out-of-range selected joints cannot borrow another joint")
	for invalid_field in [Transform3D(Basis.from_scale(Vector3.ZERO), Vector3.ZERO), Transform3D(Basis.IDENTITY, Vector3(NAN, 0, 0))]:
		_check(not Sample.normalize_tip(snapshot, TIP, invalid_field).valid, "Invalid field transforms clear the normalized reading")
	var overflow := {tracked = true, joints = {TIP: Vector3(1e30, 0, 0)}}
	_check(not Sample.normalize_tip(overflow, TIP, Transform3D(Basis.from_scale(Vector3(1e-10, 1, 1)), Vector3.ZERO)).valid, "Inverse field overflow cannot become a reading")
