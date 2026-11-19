extends Node3D
## Shows field cells sampled by controllers or the A/B inspection points.
## Inspection points are stored in the field's unit cube, so pinned samples
## follow the model and keep their locations when the frame changes.

const Meta := preload("res://app/meta.gd")
const ScalarData := preload("res://app/scalar_data.gd")
const OPACITY := 0.55
const FONT_SIZE := 48
## The label's height and its gap above the cube, in meters.
const LABEL_HEIGHT := 0.02
const LABEL_GAP := 0.01
const JOINT_SIZE := 0.008

var touch: Node
var volume: SpatialVolume3D
## Its global transform maps a unit cube onto the current brick.
var field: Node3D
var shown_field: Meta.Field
## Slot 0 (A) and slot 1 (B), each in the field's unit coordinates.
var inspection_points: Dictionary = {}
var show_controllers := true
var show_hands := true
var selected_hand := ""
var selected_joint := XRHandTracker.HAND_JOINT_INDEX_FINGER_TIP
var _joints := MultiMeshInstance3D.new()

var _colors := Gradient.new()
## Stable source key to its cube and label. Removed sources are discarded,
## rather than leaving the last tracked cell visible.
var _probes := {}


func _init() -> void:
	_colors.offsets = PackedFloat32Array([0.0, 0.25, 0.5, 0.75, 1.0])
	_colors.colors = PackedColorArray([Color(0, 0, 1), Color(0, 1, 1), Color(0, 1, 0), Color(1, 1, 0), Color(1, 0, 0)])
	var dot := SphereMesh.new()
	dot.radius = 0.5
	dot.height = 1.0
	dot.radial_segments = 8
	dot.rings = 4
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = Color.WHITE
	dot.material = material
	_joints.multimesh = MultiMesh.new()
	_joints.multimesh.transform_format = MultiMesh.TRANSFORM_3D
	_joints.multimesh.mesh = dot
	add_child(_joints)


func _process(_delta: float) -> void:
	update_probes()


## Rebuilds the visible source set from current input and current brick data.
func update_probes() -> void:
	if not is_inside_tree() or not is_visible_in_tree() or not get_window().visible \
			or not is_instance_valid(touch) or not touch.is_inside_tree() \
			or not is_instance_valid(volume) or not volume.is_inside_tree() \
			or not is_instance_valid(field) or not field.is_inside_tree() \
			or touch.bytes.is_empty() \
			or not ScalarData.validate_transform(field.global_transform).is_empty() \
			or not ScalarData.validate_transform(global_transform).is_empty():
		_clear_visuals()
		return
	var meters_per_unit := _meters_per_unit()
	if meters_per_unit <= 0.0:
		_clear_visuals()
		return
	var sources := {}
	if show_controllers:
		for controller in volume.get_controllers():
			if not is_instance_valid(controller) or not controller.is_inside_tree() or not controller.get_has_tracking_data():
				continue
			var cell: Vector3i = touch.cell_at(touch.tip_of(controller))
			# Controllers keep their existing behavior: missing cells are silent.
			if touch.byte_of(cell) != 0:
				sources[controller.get_instance_id()] = {cell = cell, title = ""}
	var snapshots := {}
	if show_hands:
		for hand in volume.get_hands():
			var snapshot := volume.get_hand_snapshot(hand)
			snapshots[hand] = snapshot
			var side := "left" if hand.hand == XRPositionalTracker.TRACKER_HAND_LEFT else "right"
			var joint := selected_joint if side == selected_hand else XRHandTracker.HAND_JOINT_INDEX_FINGER_TIP
			if snapshot.joints.has(joint):
				var cell: Vector3i = touch.cell_at(snapshot.joints[joint])
				if touch.byte_of(cell) != 0:
					sources[hand.get_instance_id()] = {cell = cell, title = ""}
	_show_joints(snapshots, meters_per_unit)
	for slot in [0, 1]:
		var point: Variant = inspection_points.get(slot)
		if not point is Vector3 or not (point as Vector3).is_finite():
			continue
		var cell: Vector3i = touch.cell_at_unit(point)
		if cell != touch.NO_CELL:
			sources["inspection_%d" % slot] = {cell = cell, title = "A" if slot == 0 else "B"}
	# A and B can deliberately compare the same cell. Share one cube and
	# label in that case, rather than drawing two labels at the same point.
	if sources.has("inspection_0") and sources.has("inspection_1") \
			and sources.inspection_0.cell == sources.inspection_1.cell:
		sources.inspection_0.title = "A / B"
		sources.erase("inspection_1")
	for key in _probes.keys():
		if not sources.has(key):
			_remove_probe(key)
	for key in sources:
		if not _probes.has(key):
			_probes[key] = _add_probe()
		var source: Dictionary = sources[key]
		_show(_probes[key], source.cell, source.title, meters_per_unit)


func _meters_per_unit() -> float:
	if not is_finite(volume.size) or volume.size <= 0.0:
		return 0.0
	var physical := volume.get_measured_size()
	if not physical.is_finite() or physical[volume.keep_aspect] <= 0.0:
		physical = volume.window_size
	if not physical.is_finite() or physical[volume.keep_aspect] <= 0.0:
		return 0.0
	var scale := physical[volume.keep_aspect] / volume.size
	return scale if is_finite(scale) and scale > 0.0 else 0.0


func _clear_visuals() -> void:
	_joints.multimesh.instance_count = 0
	for key in _probes.keys():
		_remove_probe(key)


func _remove_probe(key: Variant) -> void:
	var probe: Dictionary = _probes[key]
	# Hide immediately; queue_free() runs at the end of the frame.
	probe.cube.hide()
	probe.label.hide()
	probe.cube.queue_free()
	probe.label.queue_free()
	_probes.erase(key)


func _add_probe() -> Dictionary:
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	var cube := MeshInstance3D.new()
	cube.mesh = BoxMesh.new()
	cube.material_override = material
	add_child(cube)
	var label := Label3D.new()
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.no_depth_test = true
	label.render_priority = RenderingServer.MATERIAL_RENDER_PRIORITY_MAX
	label.outline_render_priority = RenderingServer.MATERIAL_RENDER_PRIORITY_MAX - 1
	label.font_size = FONT_SIZE
	label.outline_size = 12
	label.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	add_child(label)
	return {cube = cube, label = label}


## Updates placement even when the sampled cell is unchanged: a resize or
## field transform can change the cube and the label's physical scale.
func _show(probe: Dictionary, cell: Vector3i, title: String, meters_per_unit: float) -> void:
	var unit := global_transform.affine_inverse() * field.global_transform
	var cells := Vector3(touch.cells)
	var center := unit * ((Vector3(cell) + Vector3.ONE * 0.5) / cells)
	var cube: MeshInstance3D = probe.cube
	cube.transform = Transform3D(unit.basis * Basis.from_scale(Vector3.ONE / cells), center)
	var byte: int = touch.byte_of(cell)
	var value: float = touch.value_of(cell)
	var color := _colors.sample(value) if byte != 0 else Color(0.6, 0.6, 0.6)
	(cube.material_override as StandardMaterial3D).albedo_color = Color(color, OPACITY)

	var label: Label3D = probe.label
	label.pixel_size = LABEL_HEIGHT / meters_per_unit / FONT_SIZE
	# Include all three cell axes when finding its vertical half-extent.
	var half_height := (absf(cube.basis.x.y) + absf(cube.basis.y.y) + absf(cube.basis.z.y)) * 0.5
	label.position = center + Vector3.UP * (half_height + LABEL_GAP / meters_per_unit)
	var reading := "No data"
	if byte != 0:
		reading = shown_field.format(shown_field.value_of(byte)) if shown_field else "%.2f" % value
	var heading := "" if title.is_empty() else title + " · "
	if shown_field and not shown_field.quantity.is_empty():
		heading += shown_field.quantity + "\n"
	label.text = heading + "(%.1f, %.1f, %.1f)\n%s" % [center.x, center.y, center.z, reading]


## Reuse the team's single joint MultiMesh, omitting every invalid joint.
func _show_joints(snapshots: Dictionary, meters_per_unit: float) -> void:
	var points: Array[Vector3] = []
	for snapshot: Dictionary in snapshots.values():
		for point: Vector3 in snapshot.joints.values():
			points.append(point)
	_joints.multimesh.instance_count = points.size()
	var dot := Basis.from_scale(Vector3.ONE * JOINT_SIZE / meters_per_unit)
	var inverse := global_transform.affine_inverse()
	for index in points.size():
		_joints.multimesh.set_instance_transform(index, Transform3D(inverse.basis * dot, inverse * points[index]))
