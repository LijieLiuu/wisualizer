extends VBoxContainer
## Optional A/B tools inside the model's existing Options panel. The team's
## volume owns immersion, hand rendering, placement, controls, and sound.

signal failed(message: String)

const PRESENTATION_TIMEOUT := 15.0
const Sample := preload("res://app/hand_tracking_sample.gd")
const FINGERS := [XRHandTracker.HAND_JOINT_INDEX_FINGER_TIP, XRHandTracker.HAND_JOINT_THUMB_TIP,
	XRHandTracker.HAND_JOINT_MIDDLE_FINGER_TIP, XRHandTracker.HAND_JOINT_RING_FINGER_TIP, XRHandTracker.HAND_JOINT_PINKY_FINGER_TIP]
const TRACKERS := {"left": &"/user/hand_tracker/left", "right": &"/user/hand_tracker/right"}

@onready var readout: Label = %Reading
@onready var pinned_readout: Label = %PinnedReading

var document: Node
var selected_hand := "left"
var selected_joint := XRHandTracker.HAND_JOINT_INDEX_FINGER_TIP
var live_sample: Dictionary = {valid = false, unit = Vector3.ZERO, reason = "Waiting for hand tracking."}
var _closed := false
var _suspended := false
var _presented := false
var _opening_elapsed := 0.0
var _pinned_revision := -1
var _points: Dictionary = {}


static func availability() -> String:
	if not OS.has_feature("visionos"):
		return "Continuous hand pinning requires Apple Vision Pro."
	if not str(Engine.get_version_info().get("hash", "")).begins_with("0a8f8c791"):
		return "Use the matching engine documented in docs/hand-tracking.md."
	if not ProjectSettings.get_setting("xr/visionos/enable_hand_tracking", false):
		return "Hand tracking is disabled in this build."
	if not ClassDB.class_exists(&"RealityKitHandTracking"):
		return "Pinning tracked fingers needs the API revision 2 addon patch. Ordinary immersion, Probe and Inspect remain available."
	var api: Object = ClassDB.instantiate(&"RealityKitHandTracking")
	if api == null or not api.has_method("get_api_revision") or api.call("get_api_revision") != 2 \
			or not api.has_method("is_immersive_presented") or not api.has_method("is_hand_sample_fresh"):
		return "Rebuild the addon with the API revision 2 patch in docs/hand-tracking.md."
	return ""


func _runtime_problem() -> String:
	return availability()


func start(owner_document: Node) -> String:
	if _closed or document != null:
		return "This hand-inspection session has already started or ended."
	var problem := _runtime_problem()
	if not problem.is_empty():
		return problem
	if owner_document.entry.fields.is_empty():
		return "This model has no scalar field to inspect."
	if not owner_document.volume.has_safe_hand_tracking():
		return "Current hand samples require the API revision 2 addon."
	# Acquire the shared host first. A rejected second model must not pause
	# its shared clock or cancel an unrelated in-progress placement.
	owner_document.volume.set_immersive(true)
	if not owner_document.volume.is_immersive():
		return "Return the other model to its volume before entering this model's immersive space."
	document = owner_document
	document.inspection.cancel()
	document.set_playing(false)
	document.set_probe_mode(false)
	document.probes.selected_hand = selected_hand
	document.probes.selected_joint = selected_joint
	document.update_field()
	document.fit()
	_update()
	return ""


func _process(delta: float) -> void:
	if _closed or document == null:
		return
	if not is_instance_valid(document) or document.is_queued_for_deletion() or not document.volume.is_immersive():
		stop()
		return
	_update()
	if not _suspended and not _presented:
		_opening_elapsed += maxf(delta, 0.0)
		if _opening_elapsed >= PRESENTATION_TIMEOUT:
			document.volume.set_immersive(false)
			stop()
			failed.emit("visionOS did not finish opening the model's immersive space. Wait for the previous space to close, then retry.")


func _update() -> void:
	var points: Dictionary = document.inspection.get_committed_points()
	if document.touch.revision != _pinned_revision or points != _points:
		pinned_readout.text = document.format_probe_readings(points)
		_pinned_revision = document.touch.revision
		_points = points
	live_sample = {valid = false, unit = Vector3.ZERO, reason = "Waiting for the model's immersive space."}
	var presented: bool = document.model.visible and document.volume.is_hand_tracking_presented()
	# The Options panel may be hidden while the native space finishes opening.
	# Presentation belongs to the shared host, independently of this panel.
	if not _suspended and presented:
		_presented = true
		_opening_elapsed = 0.0
	if not _suspended and presented and document.options.visible:
		var hand := XRServer.get_tracker(TRACKERS[selected_hand]) as XRHandTracker
		var pose: Transform3D = document.volume.get_hand_joint(hand, selected_joint)
		var snapshot := {tracked = pose.is_finite(), joints = {selected_joint: pose.origin}}
		if document._probe_axes_supported(document.field.global_basis):
			live_sample = Sample.normalize_tip(snapshot, selected_joint, document.field.global_transform)
		else:
			live_sample.reason = "This field's axes cannot be sampled faithfully by the native renderer."
	elif _suspended:
		live_sample.reason = "Hand inspection paused."
	elif _presented and not presented:
		stop()
		return
	var text := str(live_sample.reason)
	if live_sample.valid:
		var cell: Vector3i = document.touch.cell_at_unit(live_sample.unit)
		if cell == document.touch.NO_CELL:
			live_sample = {valid = false, unit = Vector3.ZERO, reason = "Current scalar frame unavailable."}
			text = live_sample.reason
		else:
			var field = document.entry.fields[document.field_index]
			var byte: int = document.touch.byte_of(cell)
			text = "%s · cell (%d, %d, %d)" % ["No data" if byte == 0 else field.format(field.value_of(byte)), cell.x, cell.y, cell.z]
	readout.text = "Live fingertip: " + text
	%PinA.disabled = not live_sample.valid
	%PinB.disabled = not live_sample.valid


func select_hand(index: int) -> void:
	if index not in [0, 1]:
		return
	selected_hand = "left" if index == 0 else "right"
	document.probes.selected_hand = selected_hand
	_update()


func select_finger(index: int) -> void:
	if index < 0 or index >= FINGERS.size():
		return
	selected_joint = FINGERS[index]
	document.probes.selected_joint = selected_joint
	_update()


func pin(slot: int) -> void:
	if _closed or not is_instance_valid(document) or slot not in [0, 1]:
		return
	# A click must pass the same current native owner/freshness check again.
	_update()
	if not live_sample.valid:
		return
	var points: Dictionary = document.inspection.get_committed_points()
	points[slot] = live_sample.unit
	document.inspection.set_points(points)
	_update()


func _notification(what: int) -> void:
	if what in [NOTIFICATION_APPLICATION_FOCUS_OUT, NOTIFICATION_APPLICATION_PAUSED, NOTIFICATION_PAUSED]:
		_suspended = true
		if is_instance_valid(document):
			_update()
	elif what in [NOTIFICATION_APPLICATION_FOCUS_IN, NOTIFICATION_APPLICATION_RESUMED, NOTIFICATION_UNPAUSED]:
		_suspended = false


func stop() -> void:
	if _closed:
		return
	_closed = true
	live_sample = {valid = false, unit = Vector3.ZERO, reason = "Hand inspection ended."}
	hide()
	if is_instance_valid(document):
		document.probes.selected_hand = ""
		document.hand_workbench = null
		document.update_field()
		document.fit()
		document._resize_probe_options.call_deferred()
	queue_free()
