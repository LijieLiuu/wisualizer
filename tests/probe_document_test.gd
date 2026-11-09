extends SceneTree
## Real document scene integration, using in-memory scalar frames. These
## checks do not simulate native hand tracking or physical headset input.

const Document := preload("res://app/document.tscn")
const Meta := preload("res://app/meta.gd")
const LONG_FIELD_NAME := "A long descriptive scalar field name used to inspect pressure around a complex geometry"

class FixtureMeta extends "res://app/meta.gd":
	var payloads := {
		"pressure-0": PackedByteArray([0, 1, 128, 255]),
		"pressure-1": PackedByteArray([255, 128, 1, 0]),
		"temperature": PackedByteArray([1, 128, 255, 0]),
	}
	func open(_path: String) -> String:
		return ""
	func read(file: String) -> PackedByteArray:
		return payloads.get(file, PackedByteArray())

class FixtureFrames extends "res://app/model_frames.gd":
	var bounds := AABB(Vector3(-1, -1, -1), Vector3(2, 2, 2))
	func get_bounds() -> AABB:
		return bounds
	func get_radius(pivot: Vector3) -> float:
		var radius := 0.0
		for corner in 8:
			radius = maxf(radius, bounds.get_endpoint(corner).distance_to(pivot))
		return radius
	func show_frame(_frame: int) -> void:
		pass

var _checks := 0
var _failures := 0
var _gesture := 0


func _initialize() -> void:
	_run.call_deferred()


func _check(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error("FAIL: " + message)


func _settle() -> void:
	for index in 4:
		await process_frame


func _document() -> Node:
	var document := Document.instantiate()
	var fixture := FixtureMeta.new()
	fixture.title = "Probe integration fixture"
	fixture.times = PackedFloat64Array([0.125, 0.25, 0.5])
	var pressure := Meta.Field.new()
	pressure.name = LONG_FIELD_NAME
	pressure.quantity = "Pressure"
	pressure.unit = "Pa"
	pressure.range = Vector2(-2, 2)
	pressure.cells = Vector3i(4, 1, 1)
	pressure.files = PackedStringArray(["pressure-0", "pressure-1", "absent"])
	var temperature := Meta.Field.new()
	temperature.name = "Temperature"
	temperature.quantity = "Temperature"
	temperature.unit = "K"
	temperature.range = Vector2(10, 30)
	temperature.cells = Vector3i(4, 1, 1)
	temperature.files = PackedStringArray(["temperature", "temperature", "temperature"])
	fixture.fields.assign([pressure, temperature])
	document.meta = fixture
	root.add_child(document)
	document.set_process(false)
	_check(document.open("in-memory-fixture").is_empty(), "Real document scene opens in-memory frame metadata")
	document.touch.set_process(false)
	document.probes.set_process(false)
	# Desktop tests exercise the same public mode controls without claiming
	# the native event classes or permission state are present.
	document.probe_button.show()
	document.probe_button.disabled = false
	document.show_options(true)
	return document


func _begin(document: Node, at: Vector3) -> int:
	_gesture += 1
	_check(document.inspection.begin(_gesture, document.field.global_transform * at, Vector3.ZERO, document.field.global_transform), "Start controlled gesture at a field point")
	return _gesture


func _pin(document: Node, slot: int, at: Vector3) -> void:
	document.select_probe(slot)
	var index := _begin(document, at)
	_check(document.inspection.finish(index), "Release commits selected point")


func _assert_canceled(document: Node, previous: Dictionary, reason: String) -> void:
	_check(not document.inspection.is_active(), reason + " cancels live movement")
	_check(document.inspection.get_points() == previous, reason + " retains committed points")


func _run() -> void:
	# An optional test-only extension can register the real plugin event
	# classes; the application project never installs or depends on it.
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--probe-event-extension="):
			var path := argument.trim_prefix("--probe-event-extension=")
			_check(GDExtensionManager.load_extension(path) == GDExtensionManager.LOAD_STATUS_OK, "Load explicitly requested native event fixture")
	var document := _document()
	await _settle()
	_check(document.playing, "Document initially plays frames")
	_check(not document.probing and document.grab.input_ray_pickable and not document.probe_grab.input_ray_pickable, "Initial mode reserves model rotation collider")
	document.yaw = 0.4
	document.tilt = 0.2
	document._yaw_target = 2.0
	document._tilt_target = 0.8
	document._drag = 12
	document._yaw_speed = 1.0
	document.set_probe_mode(true)
	await _settle()
	_check(document.probing and document.probe_button.button_pressed and not document.playing, "Enabling probe mode pauses playback and updates its button")
	_check(document._drag == -1 and document._yaw_speed == 0.0 and document._yaw_target == document.yaw and document._tilt_target == document.tilt, "Probe mode ends rotation and freezes the shown orientation")
	_check(not document.grab.input_ray_pickable and document.probe_grab.input_ray_pickable, "Probe mode exclusively selects the field collider")
	_check(document.grab.get_node("Shape").disabled and not document.probe_grab.get_node("Shape").disabled, "Model collider is disabled while the field collider is active")
	_check(document.field.visible and document.probes.visible and document.probe_tools.visible, "Probe mode shows field, markers and controls")
	_check(not document.probes.show_controllers, "Controller markers remain governed by Debug")
	_test_native_route(document)
	_pin(document, 0, Vector3(0.625, 0.5, 0.5))
	_pin(document, 1, Vector3(0.875, 0.5, 0.5))
	_check(document.probe_readout.text.contains("A: 0.0 Pa") and document.probe_readout.text.contains("B: 2.0 Pa") and document.probe_readout.text.contains("B − A: 2.0 Pa"), "Physical zero and signed A/B comparison reach the real document readout: " + document.probe_readout.text)
	_check(document.probe_readout.text.contains("frame 1") and document.probe_readout.text.contains("0.125"), "Readout identifies frame and solver time")
	var pins: Dictionary = document.inspection.get_points()
	var original_transform: Transform3D = document.turntable.transform
	document.turntable.position = Vector3(1e12, -1e12, 1e12)
	document._refresh_inspection()
	_check(document.inspection.get_points() == pins and document.probe_readout.text.contains("A: 0.0 Pa") and document.probe_readout.text.contains("cell (2, 0, 0)"), "Large world translations cannot round a normalized pin into a different cell")
	document.turntable.transform = original_transform
	document.probes.update_probes()
	_check(document.probes._probes.size() == 2, "Scene presents both committed probes")
	_begin(document, Vector3.ONE * 0.2)
	document.seek(1)
	_assert_canceled(document, pins, "Frame seek")
	_check(document.probe_readout.text.contains("A: -2.0 Pa") and document.probe_readout.text.contains("B: No data"), "Stationary pins sample replacement frame bytes: " + document.probe_readout.text)
	_check(not document.probe_readout.text.contains("B − A: 2.0 Pa"), "Missing B clears its previous valid difference")
	document.seek(2)
	document.probes.update_probes()
	_check(document.probes._probes.is_empty() and document.probe_readout.text.contains("A: No data"), "Absent frame data clears previous markers and readings")
	document.seek(0)
	_check(document.inspection.get_points() == pins and document.probe_readout.text.contains("A: 0.0 Pa"), "Returning to a valid frame recovers the same pinned positions")
	await _test_cancellation(document, pins)
	await _test_layout(document)
	await _test_framing()
	var second := _document()
	second.set_probe_mode(true)
	await _settle()
	var first_a: Button = document.get_node("Model/Options/ProbeTools/Buttons/ProbeA")
	var first_b: Button = document.get_node("Model/Options/ProbeTools/Buttons/ProbeB")
	var second_a: Button = second.get_node("Model/Options/ProbeTools/Buttons/ProbeA")
	var second_b: Button = second.get_node("Model/Options/ProbeTools/Buttons/ProbeB")
	_check(first_a.button_group != second_a.button_group, "Each document owns its own A/B ButtonGroup")
	_check(first_a.button_group == first_b.button_group and second_a.button_group == second_b.button_group, "A and B share exactly their own document group")
	_check(first_a.button_group.get_buttons().size() == 2 and second_a.button_group.get_buttons().size() == 2 and first_a.button_group.get_buttons().has(first_b) and not first_a.button_group.get_buttons().has(second_a), "Each real group contains only its document's two buttons")
	_press_button(first_b)
	_press_button(second_a)
	_check(first_b.button_pressed and not first_a.button_pressed and second_a.button_pressed and not second_b.button_pressed, "Selecting A in another document preserves this document's selected B button: %s" % [Vector4(int(first_a.button_pressed), int(first_b.button_pressed), int(second_a.button_pressed), int(second_b.button_pressed))])
	_check(document.inspection.selected_slot == 1 and second.inspection.selected_slot == 0, "Real A/B button signals route to their own document state")
	_pin(second, 0, Vector3(0.375, 0.5, 0.5))
	_check(second.inspection.get_points().size() == 1 and document.inspection.get_points() == pins, "Two documents keep independent point state")
	_check(second.probe_readout.text.contains("A: -2.0 Pa") and document.probe_readout.text.contains("A: 0.0 Pa"), "Two documents keep independent readouts")
	document.field_index = 1
	document.update_field()
	_check(document.inspection.get_points().is_empty() and document.probes.inspection_points.is_empty(), "Field change clears normalized points from the previous scalar")
	_check(document.probe_readout.text.contains("Temperature") and second.inspection.get_points().size() == 1, "Field change updates metadata without altering another document")
	_pin(document, 0, Vector3(0.125, 0.5, 0.5))
	_check(document.probe_readout.text.contains("A: 10.0 K"), "New field uses its own numerical range and unit: " + document.probe_readout.text)
	document.clear_probes()
	_check(document.inspection.get_points().is_empty() and document.probe_readout.text.contains("A: not placed"), "Clear button removes points and readout together")
	document.set_probe_mode(false)
	await _settle()
	_check(not document.probing and document.grab.input_ray_pickable and not document.probe_grab.input_ray_pickable, "Turning probing off restores rotation collider")
	_check(not document.grab.get_node("Shape").disabled and document.probe_grab.get_node("Shape").disabled, "Turning probing off restores collision shapes")
	_check(not document.probe_tools.visible and document.probes.inspection_points.is_empty(), "Turning probing off hides its controls and points")
	document.debug_button.button_pressed = true
	document.update_field()
	_check(document.probes.visible and document.probes.show_controllers, "Existing Debug controller visualization remains available")
	document.meta.fields.clear()
	document.set_probe_mode(true)
	_check(not document.probing and document.touch.bytes.is_empty() and not document.probes.visible, "Documents with no scalar field cannot enter probing or retain old bytes")
	document.free()
	second.free()
	await process_frame
	print("Probe document: %d checks, %d failures" % [_checks, _failures])
	quit(1 if _failures else 0)


func _test_cancellation(document: Node, pins: Dictionary) -> void:
	_begin(document, Vector3.ONE * 0.2)
	document.model.focus_exited.emit()
	_assert_canceled(document, pins, "Window focus loss")
	_begin(document, Vector3.ONE * 0.2)
	document._notification(Node.NOTIFICATION_APPLICATION_FOCUS_OUT)
	_assert_canceled(document, pins, "Application focus loss")
	_begin(document, Vector3.ONE * 0.2)
	document._notification(Node.NOTIFICATION_APPLICATION_PAUSED)
	_assert_canceled(document, pins, "Application pause")
	_begin(document, Vector3.ONE * 0.2)
	paused = true
	_assert_canceled(document, pins, "SceneTree pause")
	paused = false
	_begin(document, Vector3.ONE * 0.2)
	document.set_playing(true)
	_assert_canceled(document, pins, "Playback start")
	document.set_playing(false)
	_begin(document, Vector3.ONE * 0.2)
	document.model.hide()
	_assert_canceled(document, pins, "Hidden model window")
	document.model.show()
	await _settle()
	_begin(document, Vector3.ONE * 0.2)
	document.volume.resized.emit(Vector3.ONE * 2.0)
	_assert_canceled(document, pins, "Volume resize")
	_begin(document, Vector3.ONE * 0.2)
	document.reset_turn()
	_assert_canceled(document, pins, "Reset orientation")
	_begin(document, Vector3.ONE * 0.2)
	document.set_probe_mode(false)
	_assert_canceled(document, pins, "Mode change")
	document.set_probe_mode(true)
	await _settle()


func _test_layout(document: Node) -> void:
	var options: Window = document.options
	var bar: Control = options.get_node("Bar")
	options.get_node("Bar/Reset").show()
	# Exercise long names and units, two field buttons, and both native and
	# desktop content scales. The same controls must stay inside the viewport.
	document.meta.fields[0].name = LONG_FIELD_NAME
	document.meta.fields[0].unit = "Pa (absolute)"
	document._refresh_inspection()
	var long_field_button: Button
	for control in bar.get_children():
		if control is Button and control.text == LONG_FIELD_NAME:
			long_field_button = control
	_check(long_field_button != null, "Long field name creates a real field-selection button")
	if long_field_button != null:
		_check(long_field_button.clip_text and long_field_button.tooltip_text == LONG_FIELD_NAME and long_field_button.text_overrun_behavior == TextServer.OVERRUN_TRIM_ELLIPSIS, "Long field buttons retain full tooltip while displaying an ellipsis")
	for scale_factor in [1.0, 2.0]:
		options.content_scale_factor = scale_factor
		document._resize_probe_options()
		await _settle()
		var viewport: Rect2 = options.get_visible_rect()
		if scale_factor == 1.0:
			var host: Rect2 = document.model.get_visible_rect()
			var ornament := Rect2(Vector2(options.position), Vector2(options.size))
			_check(host.encloses(ornament), "Default desktop probe ornament stays wholly inside its model viewport")
		_check(viewport.encloses(bar.get_rect()), "Toolbar fits logical viewport at content scale %s" % scale_factor)
		_check(viewport.encloses(document.probe_tools.get_rect()), "Probe panel fits logical viewport at content scale %s" % scale_factor)
		var readout: Rect2 = document.probe_readout.get_global_rect()
		_check(viewport.encloses(readout), "Wrapped readout fits logical viewport at content scale %s" % scale_factor)
		for control in bar.get_children():
			if control is Control and control.visible:
				_check(viewport.encloses(control.get_global_rect()), "%s control fits logical viewport at scale %s" % [control.name, scale_factor])
		document.set_probe_mode(false)
		await _settle()
		_check(options.get_visible_rect().encloses(bar.get_rect()), "Normal options row still fits after disabling probing at scale %s" % scale_factor)
		document.set_probe_mode(true)
		await _settle()
	options.content_scale_factor = 1.0
	document.meta.fields[0].name = "Pressure"
	document.meta.fields[0].unit = "Pa"
	document._refresh_inspection()
	await _settle()


func _native_event(kind: String, index: int, pose: Vector3, pressed: bool = true) -> InputEvent:
	var event: InputEvent = ClassDB.instantiate(kind)
	event.set("index", index)
	event.set("has_input_device_pose", true)
	event.set("input_device_pose_position", pose)
	if kind == "InputEventSpatialTouch":
		event.set("pressed", pressed)
	return event


func _test_native_route(document: Node) -> void:
	if not ClassDB.class_exists("InputEventSpatialTouch") or not ClassDB.class_exists("InputEventSpatialDrag"):
		print("SKIP: document native event routing; RealityKit event classes are not installed.")
		return
	document.set_playing(true)
	# A pinch beginning immediately after Reset must freeze the currently
	# shown orientation before it acquires a spatial movement baseline.
	document.reset_turn()
	var yaw_before: float = document.yaw
	var tilt_before: float = document.tilt
	var hit: Vector3 = document.field.global_transform * (Vector3.ONE * 0.5)
	var press := _native_event("InputEventSpatialTouch", 900, Vector3.ZERO)
	document.probe_grab.emit_signal("input_event", document.volume, press, hit, Vector3.UP, 0)
	_check(document.inspection.is_active() and not document.playing, "Native field collider signal begins probing and pauses playback")
	_check(document._yaw_target == yaw_before and document._tilt_target == tilt_before, "Native pinch after Reset freezes the shown model before sampling")
	document.grab.emit_signal("input_event", document.volume, press, hit, Vector3.UP, 0)
	_check(document._drag == -1, "Rotation handler ignores a native touch while probe mode owns input")
	var release := _native_event("InputEventSpatialTouch", 900, Vector3.ZERO, false)
	document.probe_grab.emit_signal("input_event", document.volume, release, hit, Vector3.UP, 0)
	_check(not document.inspection.is_active() and document.inspection.get_points().has(0), "Native release through the field signal commits selected point")
	var previous: Dictionary = document.inspection.get_points()
	document.probe_grab.emit_signal("input_event", document.volume, press, hit, Vector3.UP, 0)
	release.set("canceled", true)
	release.set("has_input_device_pose", false)
	document.probe_grab.emit_signal("input_event", document.volume, release, Vector3.ZERO, Vector3.ZERO, -1)
	_assert_canceled(document, previous, "Native cancellation without a pose")
	document.clear_probes()


func _test_framing() -> void:
	var document := _document()
	var other := _document()
	var frames := FixtureFrames.new()
	document.content.add_child(frames)
	document.models.append(frames)
	var other_frames := FixtureFrames.new()
	other_frames.bounds = AABB(Vector3.ZERO, Vector3(7, 9, 11))
	other.content.add_child(other_frames)
	other.models.append(other_frames)
	document.fit()
	var first_shape: BoxShape3D = document.grab.get_node("Shape").shape
	var second_shape: BoxShape3D = other.grab.get_node("Shape").shape
	_check(first_shape != second_shape, "Document instances own independent mutable GrabShape resources")
	other.fit()
	_check(first_shape.size == Vector3(2, 2, 2) and second_shape.size == Vector3(7, 9, 11), "Fitting another document cannot resize this document's rotation collider")
	var ordinary_size: float = document.volume.size
	document.meta.fields[0].box = Transform3D(Basis(Vector3.UP, 0.4) * Basis.from_scale(Vector3(4, 3, 2)), Vector3(8, -4, 3))
	document.meta.fields[1].box = Transform3D(Basis.from_scale(Vector3(2, 3, 4)), Vector3(-20, 8, -4))
	document.update_field()
	_check(not _field_fits(document), "Framing fixture's scalar field extends outside ordinary model framing")
	document.yaw = 0.6
	document.tilt = 0.3
	document.set_probe_mode(true)
	_check(document.volume.size > ordinary_size and _field_fits(document), "Probe mode fits every rotated nonuniform field corner even with a rotated model")
	_check(first_shape.size == Vector3(2, 2, 2), "Fitting the field preserves the model's own grab bounds")
	document.field_index = 1
	document.update_field()
	_check(_field_fits(document), "Changing the selected field reframes its farther sampling box")
	_check(second_shape.size == Vector3(7, 9, 11), "Probe refitting never changes another document's collider")
	document.set_probe_mode(false)
	_check(is_equal_approx(document.volume.size, ordinary_size), "Leaving probe mode restores ordinary model framing")
	var supported_box: Transform3D = document.meta.fields[0].box
	var sheared_box := Transform3D(Basis(Vector3(2, 0, 0), Vector3(0.5, 2, 0), Vector3(0, 0, 2)), Vector3.ZERO)
	document.field_index = 0
	document.meta.fields[0].box = sheared_box
	document.update_field()
	document.set_probe_mode(true)
	_check(not document.probing and document.probe_button.disabled and document.probe_button.tooltip_text.contains("sheared"), "Sheared field axes reject probe mode with an explicit explanation")
	document.meta.fields[0].box = supported_box
	document.update_field()
	document.set_probe_mode(true)
	_check(document.probing, "Rotation and nonuniform orthogonal scale remain supported")
	_pin(document, 0, Vector3.ONE * 0.5)
	_begin(document, Vector3.ONE * 0.6)
	document.meta.fields[1].box = sheared_box
	document.field_index = 1
	document.update_field()
	_check(not document.probing and not document.inspection.is_active() and document.inspection.get_points().is_empty(), "Changing to a sheared field cancels movement, removes pins and exits probe mode")
	_check(not document.probe_grab.input_ray_pickable and document.grab.input_ray_pickable, "Unsupported field restores model input instead of a misleading native probe collider")
	var zero_axis := Basis.from_scale(Vector3(0, 1, 1))
	_check(not document._probe_axes_supported(zero_axis), "Zero-sized field axes cannot enable native probe mode")
	_check(not document._probe_axes_supported(Basis.from_scale(Vector3(INF, 1, 1))), "Nonfinite field axes cannot enable native probe mode")
	document.free()
	other.free()
	await process_frame


func _field_fits(document: Node) -> bool:
	var half_size: Vector3 = document.volume.get_region_size() * 0.5
	var box: Transform3D = document.meta.fields[document.field_index].box
	# Use Godot's independently enumerated AABB corners, including nonuniform
	# scale, and check the actual rotated scene against the visible volume.
	var unit := AABB(Vector3.ZERO, Vector3.ONE)
	for corner in 8:
		var world: Vector3 = document.turntable.global_transform * (box * unit.get_endpoint(corner))
		var local: Vector3 = document.volume.to_local(world)
		if absf(local.x) > half_size.x or absf(local.y) > half_size.y or absf(local.z) > half_size.z:
			return false
	return true


## Exercise the actual scene ButtonGroup and pressed connection directly;
## headless tests do not establish native pointer hit testing.
func _press_button(button: Button) -> void:
	button.button_pressed = true
	button.pressed.emit()
