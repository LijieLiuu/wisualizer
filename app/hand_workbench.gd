extends Node
## A single, opt-in mixed immersive space. Its meter-space tracking origin is
## independent of each shared volume; only committed normalized pins are shared.

signal failed(message: String)

const PRESENTATION_TIMEOUT := 15.0
const Sample := preload("res://app/hand_tracking_sample.gd")
const ModelFrames := preload("res://app/model_frames.gd")
const ScalarData := preload("res://app/scalar_data.gd")
const TRACKERS := {"left": &"/user/hand_tracker/left", "right": &"/user/hand_tracker/right"}
const FINGERS := [XRHandTracker.HAND_JOINT_INDEX_FINGER_TIP, XRHandTracker.HAND_JOINT_THUMB_TIP,
	XRHandTracker.HAND_JOINT_MIDDLE_FINGER_TIP, XRHandTracker.HAND_JOINT_RING_FINGER_TIP, XRHandTracker.HAND_JOINT_PINKY_FINGER_TIP]
const DEFAULT_PLACEMENT := Vector3(0, 1.1, -0.55)
static var _active: WeakRef

@onready var immersive: Window = $Immersive
@onready var panel: Window = $Panel
@onready var origin: XROrigin3D = $Immersive/Origin
@onready var content: Node3D = $Immersive/Content
@onready var field: Node3D = $Immersive/Content/Field
@onready var skeleton: Node3D = $Immersive/Skeleton
@onready var readout: Label = %Reading
@onready var pinned_readout: Label = %PinnedReading
@onready var status: Label = %Status

var document: Node
var selected_hand := "left"
var selected_joint := XRHandTracker.HAND_JOINT_INDEX_FINGER_TIP
var live_sample: Dictionary = {valid = false, unit = Vector3.ZERO, reason = "Waiting for hand tracking."}
var hands: Dictionary = {}
var _models: Array[Node3D] = []
var _pins: Array[MeshInstance3D] = []
var _frame := -1
var _field := -1
var _pinned_brick_revision := -1
var _displayed_points: Dictionary = {}
var _placement := DEFAULT_PLACEMENT
var _rotation := 0.0
var _presented := false
var _opening_elapsed := 0.0
var _native_api: RefCounted
var _closed := false
var _suspended := false
var _field_supported := false
var _fit_problem := ""
var _tracking_origin := Transform3D.IDENTITY
var _world_scale := 1.0


static func availability() -> String:
	if not OS.has_feature("visionos"):
		return "Continuous hand tracking requires Apple Vision Pro."
	# This engine revision provides the native per-window mixed immersive host.
	if not str(Engine.get_version_info().get("hash", "")).begins_with("0a8f8c791"):
		return "This engine build does not support hand inspection. Use the build documented in the README."
	if not ProjectSettings.get_setting("xr/visionos/enable_hand_tracking", false):
		return "Hand tracking is disabled in this build."
	if not ClassDB.class_exists(&"RealityKitHandTracking"):
		return "The hand-tracking addon needs the compatibility patch documented in the README."
	var api: Object = ClassDB.instantiate(&"RealityKitHandTracking")
	if api == null or not api.has_method("get_api_revision") or api.call("get_api_revision") != 2 \
			or not api.has_method("is_immersive_presented") or not api.has_method("is_hand_sample_fresh"):
		return "The hand-tracking addon needs API revision 2. Rebuild it with the patch documented in docs/hand-tracking.md."
	return ""


func _ready() -> void:
	immersive.visibility_changed.connect(func() -> void:
		if document != null and not immersive.visible and not _closed:
			stop())
	_build_field_edges()
	for color in [Color("55b9f5"), Color("ffba62")]:
		var pin := MeshInstance3D.new()
		var mesh := SphereMesh.new()
		mesh.radius = 0.007
		mesh.height = 0.014
		pin.mesh = mesh
		pin.material_override = _material(color)
		pin.visible = false
		immersive.add_child(pin)
		_pins.append(pin)


func _runtime_problem() -> String:
	return availability()


func _presentation_ready() -> bool:
	if _native_api == null:
		if not ClassDB.class_exists(&"RealityKitHandTracking"):
			return false
		_native_api = ClassDB.instantiate(&"RealityKitHandTracking") as RefCounted
	return _native_api != null and _native_api.has_method("is_immersive_presented") and bool(_native_api.call("is_immersive_presented", immersive.get_window_id()))


func start(owner_document: Node) -> String:
	if _closed or document != null:
		return "This hand-inspection session has already started or ended."
	var error := _runtime_problem()
	if not error.is_empty():
		return error
	if _active != null and is_instance_valid(_active.get_ref()) and _active.get_ref() != self:
		return "Close the current hand-inspection space before opening another document."
	if owner_document.meta.fields.is_empty():
		return "This document has no scalar field to inspect."
	document = owner_document
	_active = weakref(self)
	document.inspection.cancel()
	document.set_playing(false)
	document.set_probe_mode(false)
	panel.title = document.meta.title + " – Hand inspection"
	%Fields.clear()
	for entry in document.meta.fields:
		%Fields.add_item(entry.name)
	for entry in document.meta.models:
		var model := ModelFrames.new()
		model.setup(document.source_path, entry)
		content.add_child(model)
		_models.append(model)
	_sync_document()
	skeleton.set_selected(selected_hand, selected_joint)
	# Both camera and origin already exist when native hosting selects this Window.
	immersive.show()
	panel.show()
	status.text = "Opening hand inspection… You can return to windows while it opens."
	return ""


func _process(delta: float) -> void:
	if _closed or document == null:
		return
	if not is_instance_valid(document) or document.is_queued_for_deletion():
		stop()
		return
	_sync_document()
	_update_tracking()
	if not _closed and not _presented and not _suspended:
		_opening_elapsed += maxf(delta, 0.0)
		if _opening_elapsed >= PRESENTATION_TIMEOUT:
			stop()
			failed.emit("visionOS did not finish opening hand inspection. Wait for the previous immersive space to close, then choose Track fingers again.")


func _sync_document() -> void:
	if document == null or document.meta.fields.is_empty():
		pinned_readout.text = "This document has no scalar field."
		_clear_live("No scalar field is available.")
		return
	var changed: bool = _field != document.field_index
	if changed:
		_field = document.field_index
		%Fields.select(_field)
		field.transform = document.meta.fields[_field].box
	if changed or not origin.global_transform.is_equal_approx(_tracking_origin) or XRServer.world_scale != _world_scale:
		_fit()
		_clear_live("Field placement changed; waiting for a current sample.")
	if _frame != document.frame:
		_frame = document.frame
		for model in _models:
			model.show_frame(_frame)
	for index in _models.size():
		_models[index].visible = document.models[index].visible
	%Playback.text = "Pause" if document.playing else "Play"
	var points: Dictionary = document.inspection.get_committed_points()
	# This stays visible through live tracking loss and follows changes made in
	# the history inspector as well as hand pinning. It never uses a live tip.
	if document.touch.revision != _pinned_brick_revision or points != _displayed_points:
		pinned_readout.text = document.format_probe_readings(points)
		_pinned_brick_revision = document.touch.revision
		_displayed_points = points
	for slot in 2:
		_pins[slot].visible = _field_supported and points.has(slot) and immersive.visible and _presented and not _suspended
		if _pins[slot].visible:
			_pins[slot].global_transform = Transform3D(Basis.from_scale(Vector3.ONE * _world_scale), field.global_transform * points[slot])


func _snapshot(hand: String) -> Dictionary:
	# XRHandTracker flags can outlive their source sample between watchdog ticks.
	var side := 0 if hand == "left" else 1
	if not _native_api.call("is_hand_sample_fresh", immersive.get_window_id(), side):
		return {tracked = false, joints = {}, reason = "Waiting for a fresh hand sample."}
	return Sample.sample(XRServer.get_tracker(TRACKERS[hand]) as XRHandTracker, origin.global_transform, XRServer.world_scale)


func _update_tracking() -> void:
	if not is_instance_valid(document) or _field < 0 or _field >= document.meta.fields.size():
		_clear_live("No scalar field is available.")
		return
	if _suspended or not immersive.visible or not panel.visible:
		_clear_live("Hand inspection is inactive.")
		return
	# A visible Godot Window does not prove that visionOS presented its space.
	# Check here too: Pin and Move near fingertip call this outside _process.
	if not _presentation_ready():
		_clear_live("Waiting for visionOS to open the immersive space.")
		status.text = "Opening hand inspection… You can return to windows while it opens."
		if _presented:
			stop()
		return
	_presented = true
	_opening_elapsed = 0.0
	hands = {"left": _snapshot("left"), "right": _snapshot("right")}
	skeleton.set_hands(hands, XRServer.world_scale)
	var counts := "Left: %d tracked joints · Right: %d tracked joints" % [hands.left.joints.size(), hands.right.joints.size()]
	if not _field_supported:
		live_sample = {valid = false, reason = _fit_problem}
	else:
		live_sample = Sample.normalize_tip(hands[selected_hand], selected_joint, field.global_transform)
	var entry = document.meta.fields[_field]
	var line := str(live_sample.reason)
	if live_sample.valid:
		var cell: Vector3i = document.touch.cell_at_unit(live_sample.unit)
		if cell == document.touch.NO_CELL:
			live_sample = {valid = false, reason = "The current scalar frame is unavailable."}
			line = live_sample.reason
		else:
			var byte: int = document.touch.byte_of(cell)
			line = "%s · cell (%d, %d, %d)" % ["No data in this cell" if byte == 0 else entry.format(entry.value_of(byte)), cell.x, cell.y, cell.z]
	readout.text = "%s\n%s" % [counts, line]
	%PinA.disabled = not live_sample.valid
	%PinB.disabled = not live_sample.valid
	%NearHand.disabled = not _field_supported or not hands[selected_hand].joints.has(selected_joint)
	if not hands.left.tracked and not hands.right.tracked:
		status.text = "No tracked hands. Keep hands in view and allow Hand Tracking in Settings. Return to windows if tracking is unavailable."
	else:
		status.text = "Live readings do not change saved probes. Use the other hand to select Pin A or Pin B."


func _clear_live(reason: String) -> void:
	hands = {}
	live_sample = {valid = false, unit = Vector3.ZERO, reason = reason}
	if not is_node_ready():
		return
	skeleton.clear()
	%PinA.disabled = true
	%PinB.disabled = true
	%NearHand.disabled = true
	for pin in _pins:
		pin.hide()
	readout.text = reason


func select_hand(index: int) -> void:
	if index not in [0, 1]:
		return
	selected_hand = "left" if index == 0 else "right"
	skeleton.set_selected(selected_hand, selected_joint)
	_clear_live("Waiting for the selected hand.")


func select_finger(index: int) -> void:
	if index < 0 or index >= FINGERS.size():
		return
	selected_joint = FINGERS[index]
	skeleton.set_selected(selected_hand, selected_joint)
	_clear_live("Waiting for the selected fingertip.")


func select_field(index: int) -> void:
	if is_instance_valid(document):
		document.select_field(index)
		_sync_document()


func pin(slot: int) -> void:
	if not is_instance_valid(document) or slot not in [0, 1] or _closed:
		return
	# A button click samples again, never committing a cached pose from a prior frame.
	_sync_document()
	_update_tracking()
	if not live_sample.valid:
		return
	var points: Dictionary = document.inspection.get_committed_points()
	points[slot] = live_sample.unit
	document.inspection.set_points(points)
	_sync_document()


func step(by: int) -> void:
	if is_instance_valid(document):
		document.step(by)


func toggle_play() -> void:
	if is_instance_valid(document):
		document.toggle_play()


func open_history() -> void:
	if is_instance_valid(document):
		document.show_probe_history()


func place_near_hand() -> void:
	if _closed or not is_instance_valid(document):
		return
	_sync_document()
	_update_tracking()
	if _field_supported and hands.has(selected_hand) and hands[selected_hand].joints.has(selected_joint):
		# Placement and the 12 cm offset are in tracking-space meters.
		var tracking_point: Vector3 = _tracking_origin.orthonormalized().affine_inverse() * hands[selected_hand].joints[selected_joint]
		_placement = tracking_point / _world_scale + Vector3(0, 0, -0.12)
		_fit()
		_clear_live("Placement changed; waiting for a current sample.")


func resize_field(_value: float) -> void:
	_fit()
	_clear_live("Size changed; waiting for a current sample.")


func rotate_field(by: float) -> void:
	_rotation += by
	_fit()
	_clear_live("Orientation changed; waiting for a current sample.")


func reset_placement() -> void:
	_placement = DEFAULT_PLACEMENT
	_rotation = 0.0
	_fit()
	_clear_live("Placement reset; waiting for a current sample.")


func _fit() -> void:
	if document == null or _field < 0:
		return
	_tracking_origin = origin.global_transform
	_world_scale = XRServer.world_scale
	_field_supported = false
	content.hide()
	if not is_finite(_world_scale) or _world_scale <= 0.0:
		_fit_problem = "The XR world scale is invalid."
		return
	if not ScalarData.validate_transform(_tracking_origin).is_empty():
		_fit_problem = "The hand tracking origin is invalid."
		return
	if not document._probe_axes_supported(field.basis):
		_fit_problem = "This field has sheared axes that the native renderer cannot preserve."
		return
	var box: Transform3D = document.meta.fields[_field].box
	var bounds := box * AABB(Vector3.ZERO, Vector3.ONE)
	var extent := bounds.size[bounds.size.max_axis_index()]
	var scale := float(%Size.value) / extent if extent > 0.0 else 0.0
	var basis := Basis(Vector3.UP, _rotation).scaled(Vector3.ONE * scale)
	# Native hosting removes this origin and divides world units by world_scale.
	var transform := _tracking_origin.orthonormalized() * Transform3D(basis.scaled(Vector3.ONE * _world_scale), (_placement - basis * bounds.get_center()) * _world_scale)
	if not ScalarData.validate_transform(transform).is_empty():
		_fit_problem = "The field placement is invalid."
		return
	content.global_transform = transform
	_fit_problem = ""
	_field_supported = true
	content.show()


func _build_field_edges() -> void:
	var material := _material(Color(0.35, 0.85, 1, 0.7))
	for axis in 3:
		for first in 2:
			for second in 2:
				var edge := MeshInstance3D.new()
				var mesh := BoxMesh.new()
				mesh.size = Vector3.ONE * 0.003
				mesh.size[axis] = 1.003
				edge.mesh = mesh
				edge.material_override = material
				var at := Vector3.ZERO
				at[axis] = 0.5
				at[(axis + 1) % 3] = first
				at[(axis + 2) % 3] = second
				edge.position = at
				field.add_child(edge)


func _material(color: Color) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA if color.a < 1.0 else BaseMaterial3D.TRANSPARENCY_DISABLED
	material.albedo_color = color
	return material


func _notification(what: int) -> void:
	if what in [NOTIFICATION_APPLICATION_FOCUS_OUT, NOTIFICATION_APPLICATION_PAUSED, NOTIFICATION_PAUSED]:
		_suspended = true
		_clear_live("Hand inspection paused.")
	elif what in [NOTIFICATION_APPLICATION_FOCUS_IN, NOTIFICATION_APPLICATION_RESUMED, NOTIFICATION_UNPAUSED]:
		_suspended = false


func stop() -> void:
	if _closed:
		return
	_closed = true
	_clear_live("Hand inspection ended.")
	immersive.hide()
	panel.hide()
	queue_free()


func _exit_tree() -> void:
	_closed = true
	if _active != null and _active.get_ref() == self:
		_active = null
	if is_instance_valid(skeleton):
		skeleton.clear()
