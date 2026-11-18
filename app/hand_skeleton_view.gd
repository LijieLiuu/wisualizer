extends Node3D
## Renders validated hand snapshots at world positions with meter-sized meshes. The caller
## decides which joint positions are tracked; absent joints are never inferred.

const JOINT_RADIUS := 0.003
const SELECTED_RADIUS := 0.005
const BONE_RADIUS := 0.0015
const HANDS := ["left", "right"]
## Palm is optional: fingers connect to the wrist, not the synthesized palm.
const PARENTS := {
	XRHandTracker.HAND_JOINT_PALM: XRHandTracker.HAND_JOINT_WRIST,
	XRHandTracker.HAND_JOINT_THUMB_METACARPAL: XRHandTracker.HAND_JOINT_WRIST,
	XRHandTracker.HAND_JOINT_THUMB_PHALANX_PROXIMAL: XRHandTracker.HAND_JOINT_THUMB_METACARPAL,
	XRHandTracker.HAND_JOINT_THUMB_PHALANX_DISTAL: XRHandTracker.HAND_JOINT_THUMB_PHALANX_PROXIMAL,
	XRHandTracker.HAND_JOINT_THUMB_TIP: XRHandTracker.HAND_JOINT_THUMB_PHALANX_DISTAL,
	XRHandTracker.HAND_JOINT_INDEX_FINGER_METACARPAL: XRHandTracker.HAND_JOINT_WRIST,
	XRHandTracker.HAND_JOINT_INDEX_FINGER_PHALANX_PROXIMAL: XRHandTracker.HAND_JOINT_INDEX_FINGER_METACARPAL,
	XRHandTracker.HAND_JOINT_INDEX_FINGER_PHALANX_INTERMEDIATE: XRHandTracker.HAND_JOINT_INDEX_FINGER_PHALANX_PROXIMAL,
	XRHandTracker.HAND_JOINT_INDEX_FINGER_PHALANX_DISTAL: XRHandTracker.HAND_JOINT_INDEX_FINGER_PHALANX_INTERMEDIATE,
	XRHandTracker.HAND_JOINT_INDEX_FINGER_TIP: XRHandTracker.HAND_JOINT_INDEX_FINGER_PHALANX_DISTAL,
	XRHandTracker.HAND_JOINT_MIDDLE_FINGER_METACARPAL: XRHandTracker.HAND_JOINT_WRIST,
	XRHandTracker.HAND_JOINT_MIDDLE_FINGER_PHALANX_PROXIMAL: XRHandTracker.HAND_JOINT_MIDDLE_FINGER_METACARPAL,
	XRHandTracker.HAND_JOINT_MIDDLE_FINGER_PHALANX_INTERMEDIATE: XRHandTracker.HAND_JOINT_MIDDLE_FINGER_PHALANX_PROXIMAL,
	XRHandTracker.HAND_JOINT_MIDDLE_FINGER_PHALANX_DISTAL: XRHandTracker.HAND_JOINT_MIDDLE_FINGER_PHALANX_INTERMEDIATE,
	XRHandTracker.HAND_JOINT_MIDDLE_FINGER_TIP: XRHandTracker.HAND_JOINT_MIDDLE_FINGER_PHALANX_DISTAL,
	XRHandTracker.HAND_JOINT_RING_FINGER_METACARPAL: XRHandTracker.HAND_JOINT_WRIST,
	XRHandTracker.HAND_JOINT_RING_FINGER_PHALANX_PROXIMAL: XRHandTracker.HAND_JOINT_RING_FINGER_METACARPAL,
	XRHandTracker.HAND_JOINT_RING_FINGER_PHALANX_INTERMEDIATE: XRHandTracker.HAND_JOINT_RING_FINGER_PHALANX_PROXIMAL,
	XRHandTracker.HAND_JOINT_RING_FINGER_PHALANX_DISTAL: XRHandTracker.HAND_JOINT_RING_FINGER_PHALANX_INTERMEDIATE,
	XRHandTracker.HAND_JOINT_RING_FINGER_TIP: XRHandTracker.HAND_JOINT_RING_FINGER_PHALANX_DISTAL,
	XRHandTracker.HAND_JOINT_PINKY_FINGER_METACARPAL: XRHandTracker.HAND_JOINT_WRIST,
	XRHandTracker.HAND_JOINT_PINKY_FINGER_PHALANX_PROXIMAL: XRHandTracker.HAND_JOINT_PINKY_FINGER_METACARPAL,
	XRHandTracker.HAND_JOINT_PINKY_FINGER_PHALANX_INTERMEDIATE: XRHandTracker.HAND_JOINT_PINKY_FINGER_PHALANX_PROXIMAL,
	XRHandTracker.HAND_JOINT_PINKY_FINGER_PHALANX_DISTAL: XRHandTracker.HAND_JOINT_PINKY_FINGER_PHALANX_INTERMEDIATE,
	XRHandTracker.HAND_JOINT_PINKY_FINGER_TIP: XRHandTracker.HAND_JOINT_PINKY_FINGER_PHALANX_DISTAL,
}

var _hands: Dictionary = {}
var _joints: Dictionary = {}
var _bones: Dictionary = {}
var _materials: Dictionary = {}
var _selected_material: StandardMaterial3D
var _selected_hand := ""
var _selected_joint := -1
var _world_units_per_meter := 1.0


func _ready() -> void:
	_ensure_nodes()
	set_notify_transform(true)
	_render()


## Each hand has tracked: bool and joints: Dictionary[int, Vector3 world point].
## Copy accepted points so a caller cannot mutate the displayed snapshot later.
func set_hands(hands: Dictionary, world_units_per_meter := 1.0) -> void:
	_world_units_per_meter = world_units_per_meter
	_hands.clear()
	for hand: String in HANDS:
		var snapshot: Variant = hands.get(hand)
		if not snapshot is Dictionary or snapshot.get("tracked", false) != true:
			continue
		var supplied: Variant = snapshot.get("joints", {})
		if not supplied is Dictionary:
			continue
		var points := {}
		for joint: int in XRHandTracker.HAND_JOINT_MAX:
			var point: Variant = supplied.get(joint)
			if point is Vector3 and (point as Vector3).is_finite():
				points[joint] = point
		_hands[hand] = points
	_ensure_nodes()
	_render()


func clear() -> void:
	_hands.clear()
	_hide_all()


func set_selected(hand: String, joint: int) -> void:
	_selected_hand = hand if hand in HANDS and joint >= 0 and joint < XRHandTracker.HAND_JOINT_MAX else ""
	_selected_joint = joint if not _selected_hand.is_empty() else -1
	_render()


func _notification(what: int) -> void:
	if what == NOTIFICATION_TRANSFORM_CHANGED and is_node_ready():
		_render()


func _ensure_nodes() -> void:
	if not _joints.is_empty():
		return
	var sphere := SphereMesh.new()
	sphere.radius = JOINT_RADIUS
	sphere.height = JOINT_RADIUS * 2.0
	sphere.radial_segments = 12
	sphere.rings = 6
	var cylinder := CylinderMesh.new()
	cylinder.top_radius = BONE_RADIUS
	cylinder.bottom_radius = BONE_RADIUS
	cylinder.height = 1.0
	cylinder.radial_segments = 8
	cylinder.rings = 1
	_selected_material = _material(Color(1.0, 0.84, 0.18))
	for hand: String in HANDS:
		_materials[hand] = _material(Color(0.12, 0.8, 1.0) if hand == "left" else Color(0.95, 0.4, 0.75))
		var joints: Array[MeshInstance3D] = []
		var bones := {}
		for joint: int in XRHandTracker.HAND_JOINT_MAX:
			var marker := _mesh("%sJoint%d" % [hand.capitalize(), joint], sphere, _materials[hand])
			joints.append(marker)
		for joint: int in PARENTS:
			bones[joint] = _mesh("%sBone%d" % [hand.capitalize(), joint], cylinder, _materials[hand])
		_joints[hand] = joints
		_bones[hand] = bones


func _material(color: Color) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = color
	return material


func _mesh(node_name: String, mesh: Mesh, material: Material) -> MeshInstance3D:
	var node := MeshInstance3D.new()
	node.name = node_name
	node.mesh = mesh
	node.material_override = material
	node.visible = false
	add_child(node)
	return node


func _hide_all() -> void:
	for hand: String in _joints:
		for node: MeshInstance3D in _joints[hand]:
			node.hide()
		for node: MeshInstance3D in _bones[hand].values():
			node.hide()


func _render() -> void:
	if not is_inside_tree() or _joints.is_empty():
		return
	var world := global_transform
	if not is_finite(_world_units_per_meter) or _world_units_per_meter <= 0.0 or not world.is_finite() or not is_finite(world.basis.determinant()) or absf(world.basis.determinant()) < 1e-12:
		_hide_all()
		return
	var inverse := world.affine_inverse()
	var selected_chain := {}
	var ancestor := _selected_joint
	while PARENTS.has(ancestor):
		selected_chain[ancestor] = true
		ancestor = PARENTS[ancestor]
	for hand: String in HANDS:
		var points: Dictionary = _hands.get(hand, {})
		for joint: int in XRHandTracker.HAND_JOINT_MAX:
			var marker: MeshInstance3D = _joints[hand][joint]
			marker.visible = points.has(joint)
			if not marker.visible:
				continue
			var selected := hand == _selected_hand and joint == _selected_joint
			var scale_factor := SELECTED_RADIUS / JOINT_RADIUS if selected else 1.0
			scale_factor *= _world_units_per_meter
			var pose := inverse * Transform3D(Basis.from_scale(Vector3.ONE * scale_factor), points[joint])
			if not pose.is_finite():
				marker.hide()
				continue
			marker.transform = pose
			marker.material_override = _selected_material if selected else _materials[hand]
		for joint: int in PARENTS:
			var bone: MeshInstance3D = _bones[hand][joint]
			var parent: int = PARENTS[joint]
			bone.visible = points.has(joint) and points.has(parent)
			if not bone.visible:
				continue
			var start: Vector3 = points[parent]
			var end: Vector3 = points[joint]
			var difference := end - start
			var length := difference.length()
			if not difference.is_finite() or not is_finite(length) or length < 0.000001:
				bone.hide()
				continue
			var axis := difference / length
			var side := axis.cross(Vector3.UP if absf(axis.y) < 0.99 else Vector3.RIGHT).normalized()
			var basis := Basis(side * _world_units_per_meter, axis * length, side.cross(axis) * _world_units_per_meter)
			var pose := inverse * Transform3D(basis, start + difference * 0.5)
			if not pose.is_finite():
				bone.hide()
				continue
			bone.transform = pose
			bone.material_override = _selected_material if hand == _selected_hand and selected_chain.has(joint) else _materials[hand]
