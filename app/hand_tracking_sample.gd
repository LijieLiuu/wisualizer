extends RefCounted
## Pure snapshots of the RealityKit provider's XRHandTracker coordinates.
## The provider removes the window's orthonormal XROrigin and world scale.
## Reverse those steps once; its joints already include the hand-anchor pose.

const ScalarData := preload("res://app/scalar_data.gd")
const POSITION_FLAGS := XRHandTracker.HAND_JOINT_FLAG_POSITION_VALID | XRHandTracker.HAND_JOINT_FLAG_POSITION_TRACKED


static func sample(tracker: XRHandTracker, origin: Transform3D, world_scale: float) -> Dictionary:
	var result := {tracked = false, joints = {}, reason = "Hand tracking is unavailable."}
	if tracker == null or not tracker.has_tracking_data:
		return result
	if not is_finite(world_scale) or world_scale <= 0.0:
		result.reason = "The tracking world scale is invalid."
		return result
	if not ScalarData.validate_transform(origin).is_empty():
		result.reason = "The tracking origin is invalid."
		return result
	var frame := origin.orthonormalized()
	if not frame.is_finite():
		result.reason = "The tracking origin is invalid."
		return result
	for joint in XRHandTracker.HAND_JOINT_MAX:
		if (tracker.get_hand_joint_flags(joint) & POSITION_FLAGS) != POSITION_FLAGS:
			continue
		var pose := tracker.get_hand_joint_transform(joint)
		if not pose.is_finite():
			continue
		var world_point: Vector3 = frame * (pose.origin * world_scale)
		if world_point.is_finite():
			result.joints[joint] = world_point
	result.tracked = not result.joints.is_empty()
	result.reason = "" if result.tracked else "No joint positions are currently tracked."
	return result


static func normalize_tip(snapshot: Dictionary, joint: int, field_transform: Transform3D) -> Dictionary:
	var result := {valid = false, unit = Vector3.ZERO, reason = "The selected joint is not tracked."}
	if snapshot.get("tracked") != true or joint < 0 or joint >= XRHandTracker.HAND_JOINT_MAX:
		return result
	var joints: Variant = snapshot.get("joints")
	if not joints is Dictionary:
		return result
	var point: Variant = joints.get(joint)
	if not point is Vector3 or not point.is_finite():
		return result
	if not ScalarData.validate_transform(field_transform).is_empty():
		result.reason = "The scalar field's spatial transform is invalid."
		return result
	var unit: Vector3 = field_transform.affine_inverse() * point
	if not unit.is_finite() or unit.x < 0.0 or unit.y < 0.0 or unit.z < 0.0 or unit.x >= 1.0 or unit.y >= 1.0 or unit.z >= 1.0:
		result.reason = "The selected joint is outside the scalar field."
		return result
	return {valid = true, unit = unit, reason = ""}
