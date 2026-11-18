extends SceneTree
## Validate real mesh nodes and world-space geometry without a hand provider.

const View := preload("res://app/hand_skeleton_view.gd")
const WRIST := XRHandTracker.HAND_JOINT_WRIST
const PALM := XRHandTracker.HAND_JOINT_PALM
const INDEX_MIDDLE := XRHandTracker.HAND_JOINT_INDEX_FINGER_PHALANX_INTERMEDIATE
const INDEX_DISTAL := XRHandTracker.HAND_JOINT_INDEX_FINGER_PHALANX_DISTAL
const INDEX_TIP := XRHandTracker.HAND_JOINT_INDEX_FINGER_TIP

var _checks := 0
var _failures := 0


func _initialize() -> void:
	_run.call_deferred()


func _check(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error("FAIL: " + message)


func _points(offset: Vector3) -> Dictionary:
	var points := {WRIST: offset, PALM: offset + Vector3(0, 0.025, 0)}
	for joint: int in XRHandTracker.HAND_JOINT_MAX:
		if joint not in points:
			points[joint] = offset + Vector3(0.005 * joint, 0.01 + 0.004 * joint, 0.002 * joint)
	return points


func _snapshot(points: Dictionary, tracked := true) -> Dictionary:
	return {tracked = tracked, joints = points, reason = ""}


func _visible_joints(view: Node3D, hand: String) -> int:
	var count := 0
	for node: MeshInstance3D in view._joints[hand]:
		count += int(node.visible)
	return count


func _visible_bones(view: Node3D, hand: String) -> int:
	var count := 0
	for node: MeshInstance3D in view._bones[hand].values():
		count += int(node.visible)
	return count


func _ids(view: Node3D) -> Array[int]:
	var result: Array[int] = []
	for node in view.get_children():
		result.append(node.get_instance_id())
	return result


func _geometry(view: Node3D, hand: String, points: Dictionary) -> void:
	for joint: int in points:
		var marker: MeshInstance3D = view._joints[hand][joint]
		_check(marker.global_position.is_equal_approx(points[joint]), "%s joint %d retains world position" % [hand, joint])
	for joint: int in View.PARENTS:
		var bone: MeshInstance3D = view._bones[hand][joint]
		var start: Vector3 = bone.global_transform * Vector3(0, -0.5, 0)
		var end: Vector3 = bone.global_transform * Vector3(0, 0.5, 0)
		_check(start.is_equal_approx(points[View.PARENTS[joint]]) and end.is_equal_approx(points[joint]), "%s bone %d spans its anatomical endpoints" % [hand, joint])


func _run() -> void:
	var parent := Node3D.new()
	root.add_child(parent)
	var view := View.new()
	var left := _points(Vector3(-0.15, 1.1, -0.4))
	var right := _points(Vector3(0.15, 1.1, -0.4))
	view.set_hands({left = _snapshot(left), right = _snapshot(right)})
	view.set_selected("left", INDEX_TIP)
	parent.add_child(view)
	_check(view.get_child_count() == 102, "Exactly 52 joint meshes and 50 bone meshes are cached")
	_check(_visible_joints(view, "left") == 26 and _visible_joints(view, "right") == 26, "Both complete hand snapshots render all 26 joints")
	_check(_visible_bones(view, "left") == 25 and _visible_bones(view, "right") == 25, "Each hand renders the 25 anatomical connections")
	_check(view.find_children("*", "CollisionObject3D").is_empty() and view.find_children("*", "Camera3D").is_empty(), "Renderer adds no colliders or cameras")
	var joint: MeshInstance3D = view._joints.left[INDEX_TIP]
	_check(is_equal_approx((joint.mesh as SphereMesh).radius * joint.global_basis.x.length(), 0.005), "Selected joint has a five millimeter world radius")
	_check(joint.material_override == view._selected_material and view._bones.left[INDEX_MIDDLE].material_override == view._selected_material, "Selection highlights the joint and its finger chain")
	_check(view._bones.left[XRHandTracker.HAND_JOINT_THUMB_TIP].material_override == view._materials.left, "Selection leaves other fingers in the hand color")
	_check(view._joints.right[INDEX_TIP].material_override == view._materials.right, "Selection does not leak to the other hand")
	_check(is_equal_approx((view._bones.left[INDEX_TIP].mesh as CylinderMesh).top_radius, 0.0015), "Bone radius is one and a half millimeters")
	_geometry(view, "left", left)

	parent.transform = Transform3D(Basis(Vector3.UP, 0.45).scaled(Vector3.ONE * 2.0), Vector3(3, -2, 1))
	view.transform = Transform3D(Basis(Vector3.RIGHT, -0.3), Vector3(0.1, 0.2, -0.1))
	view.force_update_transform()
	_geometry(view, "left", left)
	_check(is_equal_approx(joint.global_basis.x.length() * View.JOINT_RADIUS, 0.005), "Moving and scaling the renderer preserves physical joint radius")
	_check(is_equal_approx(view._bones.left[INDEX_TIP].global_basis.x.length(), 1.0), "Renderer scaling preserves physical bone thickness")
	view.set_selected("right", INDEX_TIP)
	_check(is_equal_approx(joint.global_basis.x.length() * View.JOINT_RADIUS, 0.003), "Changing selection restores the old joint radius")
	_check(view._joints.right[INDEX_TIP].material_override == view._selected_material and joint.material_override == view._materials.left, "Changing selected hand updates both materials immediately")
	view.set_selected("unknown", 1000)
	_check(view._joints.right[INDEX_TIP].material_override == view._materials.right, "Invalid selection clears highlighting")
	view.set_selected("left", INDEX_TIP)
	for world_scale in [0.5, 2.5]:
		view.set_hands({left = _snapshot(left), right = _snapshot(right)}, world_scale)
		_check(is_equal_approx(joint.global_basis.x.length() * View.JOINT_RADIUS / world_scale, 0.005), "Selected marker retains physical radius at world scale %s" % world_scale)
		_check(is_equal_approx(view._joints.right[INDEX_TIP].global_basis.x.length() * View.JOINT_RADIUS / world_scale, 0.003), "Unselected marker retains physical radius at world scale %s" % world_scale)
		var bone: MeshInstance3D = view._bones.left[INDEX_TIP]
		_check(is_equal_approx(bone.global_basis.x.length() * View.BONE_RADIUS / world_scale, 0.0015) and is_equal_approx(bone.global_basis.z.length() * View.BONE_RADIUS / world_scale, 0.0015), "Both bone thickness axes retain their physical radius at world scale %s" % world_scale)
		_check((bone.global_transform * Vector3(0, -0.5, 0)).is_equal_approx(left[INDEX_DISTAL]) and (bone.global_transform * Vector3(0, 0.5, 0)).is_equal_approx(left[INDEX_TIP]), "Changing world scale does not multiply already-world-space bone endpoints")
	for invalid_scale in [0.0, -1.0, NAN, INF]:
		view.set_hands({left = _snapshot(left), right = _snapshot(right)}, invalid_scale)
		_check(_visible_joints(view, "left") == 0 and _visible_bones(view, "right") == 0, "Invalid physical scale hides all stale skeleton geometry")
	view.set_hands({left = _snapshot(left), right = _snapshot(right)})
	_check(_visible_joints(view, "left") == 26 and is_equal_approx(joint.global_basis.x.length() * View.JOINT_RADIUS, 0.005), "Default scale restores current geometry after an invalid scale")

	var partial := left.duplicate()
	partial.erase(PALM)
	view.set_hands({left = _snapshot(partial), right = _snapshot(right)})
	_check(not view._joints.left[PALM].visible and not view._bones.left[PALM].visible, "Missing palm hides its marker and incident bone")
	_check(_visible_bones(view, "left") == 24, "Missing optional palm retains every finger bone")
	partial.erase(INDEX_MIDDLE)
	view.set_hands({left = _snapshot(partial), right = _snapshot(right)})
	_check(not view._joints.left[INDEX_MIDDLE].visible and not view._bones.left[INDEX_MIDDLE].visible and not view._bones.left[INDEX_DISTAL].visible, "A missing finger joint hides both incident segments immediately")
	_check(view._bones.left[INDEX_TIP].visible and _visible_bones(view, "right") == 25, "A missing joint preserves unrelated segments and the other hand")
	partial[INDEX_MIDDLE] = Vector3(NAN, 1, 2)
	partial[INDEX_TIP] = "invalid"
	partial[-1] = Vector3.ZERO
	partial[999] = Vector3.ZERO
	view.set_hands({left = _snapshot(partial), right = _snapshot(right)})
	_check(not view._joints.left[INDEX_MIDDLE].visible and not view._joints.left[INDEX_TIP].visible, "Nonfinite and wrong-type joints are never rendered")
	_check(view.get_child_count() == 102, "Unexpected joint IDs cannot allocate extra geometry")
	var degenerate := left.duplicate()
	degenerate[INDEX_TIP] = degenerate[INDEX_DISTAL]
	view.set_hands({left = _snapshot(degenerate), right = _snapshot(right)})
	_check(view._joints.left[INDEX_TIP].visible and not view._bones.left[INDEX_TIP].visible, "Coincident endpoints keep the joint but hide the zero-length bone")
	var vertical := left.duplicate()
	vertical[INDEX_TIP] = vertical[INDEX_DISTAL] + Vector3.UP * 0.03
	view.set_hands({left = _snapshot(vertical)})
	_check(view._bones.left[INDEX_TIP].visible and view._bones.left[INDEX_TIP].global_transform.is_finite(), "Vertical segments have a finite orientation")
	_check(_visible_joints(view, "right") == 0 and _visible_bones(view, "right") == 0, "An absent hand removes all its previous geometry")
	view.set_hands({left = _snapshot(left, false), right = _snapshot(right)})
	_check(_visible_joints(view, "left") == 0 and _visible_bones(view, "left") == 0 and _visible_joints(view, "right") == 26, "Whole-hand tracking loss clears only that hand")
	view.set_hands({left = {tracked = true, joints = "invalid"}, right = null})
	_check(_visible_joints(view, "left") == 0 and _visible_joints(view, "right") == 0, "Malformed snapshots clear stale geometry")

	var stable := _ids(view)
	for tick in 100:
		view.set_hands({left = _snapshot(left), right = _snapshot(right)})
		view.set_selected("left" if tick % 2 == 0 else "right", INDEX_TIP)
	_check(_ids(view) == stable, "Continuous updates and selection changes reuse all mesh instances")
	_check(view._joints.left[0].mesh == view._joints.right[25].mesh and view._bones.left[0].mesh == view._bones.right[25].mesh, "Joint and bone geometry resources are shared")
	var copied := left.duplicate()
	view.set_hands({left = _snapshot(copied)})
	copied.clear()
	view.set_selected("left", INDEX_TIP)
	_check(_visible_joints(view, "left") == 26, "Caller mutation cannot change the accepted snapshot")
	view.transform = Transform3D(Basis.from_scale(Vector3.ZERO), Vector3.ZERO)
	view.force_update_transform()
	_check(_visible_joints(view, "left") == 0 and _visible_bones(view, "left") == 0, "Singular renderer transforms hide geometry safely")
	view.transform = Transform3D.IDENTITY
	view.force_update_transform()
	_check(_visible_joints(view, "left") == 26, "A valid renderer transform restores current tracked geometry")
	view.clear()
	_check(_visible_joints(view, "left") == 0 and _visible_joints(view, "right") == 0 and _visible_bones(view, "left") == 0 and _visible_bones(view, "right") == 0, "Clear hides both complete skeletons immediately")
	view.position.x += 1.0
	view.force_update_transform()
	view.set_selected("left", INDEX_TIP)
	_check(_visible_joints(view, "left") == 0 and _ids(view) == stable, "Clear discards stale positions while retaining the node cache")
	parent.free()
	print("hand_skeleton_view_test: %d checks, %d failures" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)
