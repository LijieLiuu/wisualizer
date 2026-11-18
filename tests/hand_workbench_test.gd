extends SceneTree
## Desktop integration uses real trackers and scenes with a local capability
## override. It does not claim ARKit permission, native hosting, or headset proof.

const Document := preload("res://app/document.tscn")
const Workbench := preload("res://app/hand_workbench.tscn")
const INDEX := XRHandTracker.HAND_JOINT_INDEX_FINGER_TIP
const THUMB := XRHandTracker.HAND_JOINT_THUMB_TIP
const FLAGS := XRHandTracker.HAND_JOINT_FLAG_POSITION_VALID | XRHandTracker.HAND_JOINT_FLAG_POSITION_TRACKED

class PublishedHands extends RefCounted:
	var fresh := [true, true]
	var queried_window := -1

	func is_hand_sample_fresh(window_id: int, hand: int) -> bool:
		queried_window = window_id
		return fresh[hand]

class Fixture extends "res://app/hand_workbench.gd":
	var presentation_ready := true
	func _runtime_problem() -> String:
		return ""
	func _presentation_ready() -> bool:
		return presentation_ready

class ReferenceFixture extends XRInterfaceExtension:
	func _get_name() -> StringName:
		return &"HandWorkbenchTest"
	func _is_initialized() -> bool:
		return true
	func _get_camera_transform() -> Transform3D:
		return Transform3D(Basis(Vector3.UP, 0.7), Vector3(4, 1, -2))

var _checks := 0
var _failures := 0
var _directory := ""
var _trackers: Dictionary = {}
var _prior_trackers: Dictionary = {}
var _world_scale := 1.0


func _initialize() -> void:
	_run.call_deferred()


func _check(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error("FAIL: " + message)


func _settle() -> void:
	for tick in 4:
		await process_frame


func _glb() -> PackedByteArray:
	var binary := PackedByteArray()
	binary.resize(44)
	var coordinates := [0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0, 1.0]
	for index in coordinates.size():
		binary.encode_float(index * 4, coordinates[index])
	for index in 3:
		binary.encode_u16(36 + index * 2, index)
	var body := JSON.stringify({
		"asset": {"version": "2.0"}, "scene": 0, "scenes": [{"nodes": [0]}],
		"nodes": [{"mesh": 0}], "meshes": [{"primitives": [{"attributes": {"POSITION": 0}, "indices": 1}]}],
		"buffers": [{"byteLength": 42}],
		"bufferViews": [{"buffer": 0, "byteOffset": 0, "byteLength": 36, "target": 34962}, {"buffer": 0, "byteOffset": 36, "byteLength": 6, "target": 34963}],
		"accessors": [{"bufferView": 0, "componentType": 5126, "count": 3, "type": "VEC3", "min": [0, 0, 0], "max": [1, 1, 1]}, {"bufferView": 1, "componentType": 5123, "count": 3, "type": "SCALAR"}],
	}).to_utf8_buffer()
	while body.size() % 4:
		body.append(32)
	var header := PackedByteArray()
	header.resize(20)
	header.encode_u32(0, 0x46546c67)
	header.encode_u32(4, 2)
	header.encode_u32(8, 28 + body.size() + binary.size())
	header.encode_u32(12, body.size())
	header.encode_u32(16, 0x4e4f534a)
	var binary_header := PackedByteArray()
	binary_header.resize(8)
	binary_header.encode_u32(0, binary.size())
	binary_header.encode_u32(4, 0x004e4942)
	return header + body + binary_header + binary


func _fixture(path: String) -> void:
	var manifest := {
		"title": "Probe history integration", "frames": [{"time": 2}, {"time": 0}, {"time": 2}, {"time": 3}],
		"models": [{"name": "Model", "path": "model.glb"}],
		"fields": [
			{"name": "Pressure", "quantity": "Pressure", "unit": "Pa", "range": [-2, 2], "cells": [4, 1, 1], "box": {"origin": [0, 0, 0], "size": [1, 1, 1]}, "path": "pressure"},
			{"name": "Temperature", "quantity": "Temperature", "unit": "K", "range": [10, 30], "cells": [4, 1, 1], "box": {"origin": [100, 0, 0], "size": [8, 2, 3]}, "path": "temperature.bin"},
		],
	}
	var files := {
		"meta.json": JSON.stringify(manifest).to_utf8_buffer(), "model.glb": _glb(),
		"pressure/0001.bin": PackedByteArray([0, 1, 128, 255]),
		"pressure/0002.bin": PackedByteArray([255, 128, 0, 1]),
		"pressure/0003.bin": PackedByteArray([1, 255, 128, 0]),
		"pressure/0004.bin": PackedByteArray([0, 1, 255, 128]),
		"temperature.bin": PackedByteArray([1, 128, 255, 0]),
	}
	var zip := ZIPPacker.new()
	_check(zip.open(path) == OK, "Create disposable real ZIP fixture")
	for name in files:
		_check(zip.start_file(name) == OK and zip.write_file(files[name]) == OK and zip.close_file() == OK, "Write fixture entry " + name)
	_check(zip.close() == OK, "Finish ZIP central directory")


func _document(path: String) -> Node:
	var document := Document.instantiate()
	root.add_child(document)
	document.set_process(false)
	_check(document.open(path).is_empty(), "Open a real ZIP with valid GLB and scalar frames")
	document.touch.set_process(false)
	document.probes.set_process(false)
	return document


func _bench(document: Node) -> Node:
	var bench := Workbench.instantiate()
	bench.set_script(Fixture)
	bench._native_api = PublishedHands.new()
	document.add_child(bench)
	bench.set_process(false)
	return bench


func _install_trackers() -> void:
	_world_scale = XRServer.world_scale
	XRServer.world_scale = 1.0
	for hand in ["left", "right"]:
		var name := StringName("/user/hand_tracker/" + hand)
		_prior_trackers[hand] = XRServer.get_tracker(name)
		if _prior_trackers[hand] != null:
			XRServer.remove_tracker(_prior_trackers[hand])
		var tracker := XRHandTracker.new()
		tracker.name = name
		tracker.hand = XRPositionalTracker.TRACKER_HAND_LEFT if hand == "left" else XRPositionalTracker.TRACKER_HAND_RIGHT
		tracker.has_tracking_data = true
		# The engine's native joint buffers must be initialized, even for absent joints.
		for joint in XRHandTracker.HAND_JOINT_MAX:
			tracker.set_hand_joint_flags(joint, 0)
			tracker.set_hand_joint_transform(joint, Transform3D.IDENTITY)
		tracker.set_pose(&"default", Transform3D(Basis.IDENTITY, Vector3(50, 60, 70)), Vector3.ZERO, Vector3.ZERO, XRPose.XR_TRACKING_CONFIDENCE_HIGH)
		XRServer.add_tracker(tracker)
		_trackers[hand] = tracker


func _put_world(bench: Node, hand: String, joint: int, point: Vector3) -> void:
	var local: Vector3 = bench.origin.global_transform.orthonormalized().affine_inverse() * point
	var tracker: XRHandTracker = _trackers[hand]
	tracker.has_tracking_data = true
	tracker.set_hand_joint_transform(joint, Transform3D(Basis.IDENTITY, local / XRServer.world_scale))
	tracker.set_hand_joint_flags(joint, FLAGS)


func _put(bench: Node, hand: String, joint: int, point: Vector3) -> void:
	_put_world(bench, hand, joint, bench.field.global_transform * point)


func _tick(bench: Node) -> void:
	bench._process(0.0)


func _wait_history(history: Node) -> void:
	var deadline := Time.get_ticks_msec() + 10000
	while history.is_busy() and Time.get_ticks_msec() < deadline:
		await create_timer(0.01).timeout
	_check(not history.is_busy(), "Real history analysis joins its worker")


func _layout(bench: Node) -> void:
	var panel: Window = bench.panel
	var scroll: ScrollContainer = panel.get_node("Margin/Scroll")
	var column: Control = scroll.get_node("Column")
	var help: Control = column.get_node("Instructions")
	var last: Control = column.get_node("Return")
	var previous := panel.size
	var previous_minimum := panel.min_size
	var previous_scale := panel.content_scale_factor
	var previous_status: String = bench.status.text
	bench.status.text = "Tracking unavailable. " + "Move both hands into view and allow Hand Tracking in Settings. ".repeat(8)
	for scale in [1.0, 2.0]:
		panel.content_scale_factor = scale
		panel.min_size = Vector2i(Vector2(480, 500) * scale)
		panel.size = panel.min_size
		scroll.scroll_vertical = 0
		await _settle()
		_check(column.size.x <= scroll.size.x + 0.1, "Controls stay within minimum panel width at scale %s" % scale)
		_check(help.get_global_rect().position.y >= scroll.get_global_rect().position.y - 0.1, "Top instructions are reachable at scale %s" % scale)
		for control: Control in column.find_children("*", "Control"):
			if control is Label or control is Button or control is SpinBox:
				_check(control.get_global_rect().end.x <= scroll.get_global_rect().end.x + 0.1, "Control %s has no horizontal clipping at scale %s" % [control.name, scale])
		scroll.scroll_vertical = int(scroll.get_v_scroll_bar().max_value)
		await _settle()
		_check(last.get_global_rect().end.y <= scroll.get_global_rect().end.y + 0.1 and last.get_global_rect().position.y >= scroll.get_global_rect().position.y - 0.1, "Return action is fully reachable by scrolling at scale %s" % scale)
		_check(bench.status.get_global_rect().end.y <= scroll.get_global_rect().end.y + 0.1, "Long status is reachable by scrolling at scale %s" % scale)
	panel.content_scale_factor = previous_scale
	panel.min_size = previous_minimum
	panel.size = previous
	bench.status.text = previous_status
	scroll.scroll_vertical = 0


func _run() -> void:
	_directory = OS.get_temp_dir().path_join("wisualizer-hand-workbench-%d" % Time.get_ticks_usec())
	_check(DirAccess.make_dir_recursive_absolute(_directory) == OK, "Create isolated fixture directory")
	var source := _directory.path_join("source.zip")
	_fixture(source)
	_install_trackers()
	var document := _document(source)
	var second := _document(source)
	var bench := _bench(document)
	document.hand_workbench = bench
	_check(bench.start(document).is_empty(), "Opt-in scene starts with test-only capability override")
	await _settle()
	_check(bench.document == document and not document.playing and not document.probing, "Workbench binds one document and pauses placement playback")
	_check(bench.immersive.own_world_3d and bench.origin.get_parent() == bench.immersive, "Immersive window owns its world and tracking origin")
	var cameras: Array[Node] = bench.immersive.find_children("*", "Camera3D", true, false)
	_check(cameras.size() == 1 and cameras[0] is XRCamera3D, "First and only camera routes the window to immersive hosting")
	_check(bench.immersive.find_children("*", "SpatialVolume3D", true, false).is_empty(), "Immersive subtree has no volume backend or volume camera")
	_check(bench._models.size() == document.models.size() and bench._models[0] != document.models[0] and document.models[0].get_parent() == document.content, "Workbench owns fresh frame loaders without moving document models")
	_check(not bench._models[0].get_bounds().size.is_zero_approx(), "Valid GLB geometry reaches the independent workbench loader")
	var contender := _bench(second)
	_check(not contender.start(second).is_empty() and not contender.immersive.visible and contender.document == null, "A second document cannot replace the active immersive owner")
	contender.free()

	_put(bench, "left", INDEX, Vector3(0.625, 0.5, 0.5))
	_put(bench, "right", INDEX, Vector3(0.875, 0.5, 0.5))
	_tick(bench)
	_check(bench.live_sample.valid and bench.live_sample.unit.is_equal_approx(Vector3(0.625, 0.5, 0.5)), "Fresh fingertip maps through the workbench field inverse exactly once")
	_check(bench.readout.text.contains("0.0 Pa") and bench.readout.text.contains("cell (2, 0, 0)"), "Live scalar readout preserves physical zero and its cell")
	_check(document.inspection.get_committed_points().is_empty() and second.inspection.get_committed_points().is_empty(), "Continuous readings do not mutate either document's committed pins")
	_check(bench.pinned_readout.text.contains("A: not placed") and bench.pinned_readout.text.contains("B: not placed"), "Live tip cannot appear in the separate committed readout before pinning")
	bench.get_node("%PinA").pressed.emit()
	_check(document.inspection.get_committed_points()[0].is_equal_approx(Vector3(0.625, 0.5, 0.5)), "Explicit Pin A stores normalized field coordinates")
	_check(bench.pinned_readout.text.contains("A: 0.0 Pa · cell (2, 0, 0)") and bench.pinned_readout.text.contains("B: not placed"), "Pinning immediately shows committed physical zero and its cell")
	var pinned_a_text: String = bench.pinned_readout.text
	document.history.analyze()
	await _wait_history(document.history)
	_check(not document.history.result.is_empty(), "Committed fingertip drives the real history analyzer")
	var analyzed: Dictionary = document.history.result.duplicate(true)
	_test_stale_publication(bench, document)
	_put(bench, "left", INDEX, Vector3(0.875, 0.5, 0.5))
	_tick(bench)
	_check(document.history.result == analyzed and document.inspection.get_committed_points().size() == 1, "Moving live fingertip preserves analyzed history and committed A")
	for tick in 4:
		_tick(bench)
	_check(bench.pinned_readout.text == pinned_a_text and bench.readout.text.contains("2.0 Pa"), "Committed A remains readable across frames while the live fingertip reports a different value")
	_put(bench, "left", INDEX, Vector3(0.375, 0.5, 0.5))
	bench.get_node("%PinB").pressed.emit()
	_check(document.inspection.get_committed_points()[1].is_equal_approx(Vector3(0.375, 0.5, 0.5)) and document.history.result.is_empty(), "Pin B resamples current tracker rather than stale live pose, then invalidates old history")
	_check(second.inspection.get_committed_points().is_empty(), "Pinning in the first document leaves the second untouched")
	_check(bench.pinned_readout.text.contains("B: -2.0 Pa · cell (1, 0, 0)") and bench.pinned_readout.text.contains("B − A: -2.0 Pa"), "Committed B and signed B minus A appear immediately")
	_check(bench.pinned_readout.text == document.history.readout.text and document.probe_readout.text.begins_with(bench.pinned_readout.text), "Workbench, inspector, and volume share the same current-frame reading format")
	var placed_points: Dictionary = document.inspection.get_committed_points()
	document.inspection.set_points({0: placed_points[0], 1: placed_points[0]})
	_tick(bench)
	_check(bench.pinned_readout.text.contains("A: 0.0 Pa") and bench.pinned_readout.text.contains("B: 0.0 Pa") and bench.pinned_readout.text.contains("B − A: 0.0 Pa"), "Externally replaced coincident pins remain individually identified with a real zero difference")
	document.clear_probes()
	_tick(bench)
	_check(bench.pinned_readout.text.contains("A: not placed") and bench.pinned_readout.text.contains("B: not placed") and not bench.pinned_readout.text.contains("B − A: 0.0 Pa"), "External clear removes committed readings and the previous numeric difference")
	document.inspection.set_points(placed_points)
	_tick(bench)

	bench.select_hand(1)
	_check(not bench.live_sample.valid and bench.get_node("%PinA").disabled, "Hand selection clears the previous live candidate immediately")
	_tick(bench)
	_check(bench.live_sample.unit.is_equal_approx(Vector3(0.875, 0.5, 0.5)), "Right hand selects its independent tracked position")
	_put(bench, "right", THUMB, Vector3(0.125, 0.5, 0.5))
	bench.select_finger(1)
	_tick(bench)
	_check(bench.selected_joint == THUMB and bench.live_sample.unit.is_equal_approx(Vector3(0.125, 0.5, 0.5)) and bench.readout.text.contains("No data in this cell"), "Thumb selection displays a valid spatial sample with explicit missing scalar data")
	_trackers.right.set_hand_joint_flags(THUMB, XRHandTracker.HAND_JOINT_FLAG_POSITION_VALID)
	_tick(bench)
	_check(not bench.live_sample.valid and bench.get_node("%PinA").disabled and not bench.skeleton._joints.right[THUMB].visible, "An untracked selected joint clears its sample and skeleton marker")
	_check(bench.pinned_readout.text.contains("A: 0.0 Pa") and bench.pinned_readout.text.contains("B − A: -2.0 Pa"), "Tracking loss clears the live sample while retaining current readings at committed locations")
	var preserved: Dictionary = document.inspection.get_committed_points()
	bench.pin(0)
	_check(document.inspection.get_committed_points() == preserved, "A pin attempt after tracking loss cannot commit a stale point")
	_trackers.right.has_tracking_data = false
	_tick(bench)
	_check(not bench.hands.right.tracked and bench.hands.left.tracked, "Whole right-hand loss preserves the independently tracked left hand")
	bench.select_hand(0)
	bench.select_finger(0)

	XRServer.world_scale = 2.0
	bench.origin.transform = Transform3D(Basis(Vector3.UP, 0.6).scaled(Vector3.ONE * 1.5), Vector3(0.3, -0.2, 0.1))
	_tick(bench)
	var tracking_origin: Transform3D = bench.origin.global_transform.orthonormalized()
	var center: Vector3 = bench.field.global_transform * (Vector3.ONE * 0.5)
	_check(center.is_equal_approx(tracking_origin * (Fixture.DEFAULT_PLACEMENT * 2.0)), "Default placement retains its meter height and distance under scaled, rotated tracking origin")
	_check(is_equal_approx(bench.field.global_basis.x.length() / XRServer.world_scale, bench.get_node("%Size").value), "Meter-labeled field size survives runtime world-scale changes")
	_check(is_equal_approx(bench._pins[0].global_basis.x.length() * bench._pins[0].mesh.radius / XRServer.world_scale, 0.007), "Committed pin markers keep their seven millimeter physical radius")
	_check(bench._pins[0].global_position.is_equal_approx(bench.field.global_transform * preserved[0]), "Scale and origin refits move committed markers with their normalized field points")
	_put(bench, "left", INDEX, Vector3(0.625, 0.5, 0.5))
	_tick(bench)
	_check(bench.live_sample.valid and bench.live_sample.unit.is_equal_approx(Vector3(0.625, 0.5, 0.5)), "Origin rotation/translation and world scale are reversed once; origin scale is orthonormalized")
	_check(is_equal_approx(bench.skeleton._joints.left[INDEX].global_basis.x.length() * bench.skeleton.JOINT_RADIUS / XRServer.world_scale, 0.005), "Workbench supplies world units per meter to its selected skeleton marker")
	var scaled_tip: Vector3 = bench.hands.left.joints[INDEX]
	bench.place_near_hand()
	center = bench.field.global_transform * (Vector3.ONE * 0.5)
	_check(center.is_equal_approx(scaled_tip + tracking_origin.basis * Vector3(0, 0, -0.24)), "Near-fingertip offset is twelve physical centimeters along tracking-space forward")
	_check(not bench.live_sample.valid, "A scale-aware placement change clears the old live reading")
	bench.reset_placement()
	_put(bench, "left", INDEX, Vector3(0.625, 0.5, 0.5))
	_tick(bench)
	var previous_interface: XRInterface = XRServer.primary_interface
	var reference := ReferenceFixture.new()
	XRServer.add_interface(reference)
	XRServer.primary_interface = reference
	XRServer.center_on_hmd(XRServer.RESET_FULL_ROTATION, false)
	_check(not XRServer.get_reference_frame().is_equal_approx(Transform3D.IDENTITY), "Test establishes a nonidentity XR reference frame")
	_tick(bench)
	_check(bench.live_sample.valid and bench.live_sample.unit.is_equal_approx(Vector3(0.625, 0.5, 0.5)), "Provider joints ignore extra global reference frame and unrelated default palm pose")
	XRServer.clear_reference_frame()
	XRServer.primary_interface = previous_interface
	XRServer.remove_interface(reference)
	XRServer.world_scale = NAN
	_tick(bench)
	_check(not bench.content.visible and not bench.live_sample.valid and bench.get_node("%PinA").disabled and bench.readout.text.contains("world scale"), "Invalid XR scale hides the field and explains why sampling is unavailable")
	_check(not bench._pins[0].visible and not bench.skeleton._joints.left[INDEX].visible, "Invalid scale cannot retain old pin or skeleton geometry")
	XRServer.world_scale = 0.5
	_tick(bench)
	_put(bench, "left", INDEX, Vector3(0.625, 0.5, 0.5))
	_tick(bench)
	_check(bench.content.visible and bench.live_sample.valid and is_equal_approx(bench.field.global_basis.x.length() / XRServer.world_scale, bench.get_node("%Size").value), "Restoring a valid smaller world scale recovers physical size and live sampling")
	bench.origin.transform = Transform3D(Basis.from_scale(Vector3.ZERO), Vector3.ZERO)
	_tick(bench)
	_check(not bench.content.visible and not bench.live_sample.valid and bench.readout.text.contains("origin"), "Invalid tracking origin hides geometry and reports the origin error")
	bench.origin.transform = Transform3D.IDENTITY
	XRServer.world_scale = 1.0
	bench.get_node("%Size").value = 0.3
	bench.rotate_field(0.5235988)
	_put(bench, "left", INDEX, Vector3(0.625, 0.5, 0.5))
	_tick(bench)
	_check(bench.live_sample.valid and bench.live_sample.unit.is_equal_approx(Vector3(0.625, 0.5, 0.5)), "Resized and rotated field keeps scalar sampling aligned to rendering")
	var world_point: Vector3 = bench.hands.left.joints[INDEX]
	bench.place_near_hand()
	_check(bench._placement.is_equal_approx(world_point + Vector3(0, 0, -0.12)) and not bench.live_sample.valid, "Move-near-fingertip recenters from a fresh pose and clears the old candidate")
	bench.reset_placement()
	_put(bench, "left", INDEX, Vector3(0.625, 0.5, 0.5))
	bench.step(1)
	_tick(bench)
	_check(document.frame == 1 and bench._frame == 1 and bench.readout.text.contains("No data in this cell"), "Frame changes refresh the selected cell and preserve explicit missing bytes")
	_check(document.inspection.get_committed_points() == preserved, "Frame playback leaves committed field locations unchanged")
	_check(bench.pinned_readout.text.contains("frame 2 / 4") and bench.pinned_readout.text.contains("A: No data · cell (2, 0, 0)") and bench.pinned_readout.text.contains("B: 0.0 Pa") and bench.pinned_readout.text.contains("B − A: place both probes on valid data"), "New frame updates committed cells and clears the numeric difference when a cell is missing")
	document.touch.set_brick(PackedByteArray(), Vector3i.ZERO, 255)
	_tick(bench)
	_check(not bench.live_sample.valid and bench.get_node("%PinA").disabled and bench.readout.text.contains("unavailable"), "Unavailable scalar payload disables pinning instead of retaining a stale value")
	_check(bench.pinned_readout.text.contains("A: No data (current scalar frame unavailable)") and bench.pinned_readout.text.contains("B: No data (current scalar frame unavailable)") and not bench.pinned_readout.text.contains("B: 0.0 Pa"), "Unavailable payload clears both committed values instead of retaining the preceding frame")
	document.update_field()
	bench.select_field(1)
	_put(bench, "left", INDEX, Vector3(0.625, 0.5, 0.5))
	_tick(bench)
	_check(bench.live_sample.valid and bench.readout.text.contains("30.0 K") and bench._field == 1, "Distant anisotropic second field refits and uses its own scalar metadata")
	_check(document.inspection.get_committed_points().is_empty() and second.field_index == 0, "Field switching clears only the owning document's old-field pins")
	_check(bench.pinned_readout.text.contains("Temperature") and bench.pinned_readout.text.contains("A: not placed") and bench.pinned_readout.text.contains("B: not placed") and not bench.pinned_readout.text.contains("Pa"), "Field switch replaces metadata and clears readings from the old field")
	bench.pin(0)
	_check(bench.pinned_readout.text.contains("A: 30.0 K · cell (2, 0, 0)"), "Pinning the new field uses its own units and numerical range")
	var final_pins: Dictionary = document.inspection.get_committed_points()
	bench._notification(Node.NOTIFICATION_APPLICATION_FOCUS_OUT)
	_check(not bench.live_sample.valid and bench.get_node("%PinA").disabled, "Application suspension immediately clears live input")
	_check(bench.pinned_readout.text.contains("A: 30.0 K"), "Suspension retains committed field readings separately from unavailable live hands")
	bench.pin(1)
	_check(document.inspection.get_committed_points() == final_pins, "Suspended workbench cannot commit new pins")
	bench._notification(Node.NOTIFICATION_APPLICATION_FOCUS_IN)
	_tick(bench)
	await _layout(bench)
	var old_window: Window = bench.immersive
	bench.stop()
	_check(document.inspection.get_committed_points() == final_pins and not old_window.visible and not bench.panel.visible, "Stop closes windows immediately and preserves explicitly committed pins")
	await _settle()
	_check(not is_instance_valid(bench) and not is_instance_valid(old_window), "Stop frees immersive scene and its Window")
	await _test_presentation(document, second)
	var next := _bench(second)
	second.hand_workbench = next
	_check(next.start(second).is_empty(), "Stopping releases the singleton so another document can start")
	second.close()
	await _settle()
	_check(not is_instance_valid(next) and not is_instance_valid(second), "Document close also frees its active workbench")
	document.close()
	await _settle()
	_cleanup()
	print("hand_workbench_test: %d checks, %d failures" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


func _test_stale_publication(bench: Node, document: Node) -> void:
	var published: PublishedHands = bench._native_api
	var pins: Dictionary = document.inspection.get_committed_points()
	var placement: Vector3 = bench._placement
	# Simulate crossing the age limit between a valid UI frame and the click.
	published.fresh[0] = false
	bench.get_node("%PinB").pressed.emit()
	_check(published.queried_window == bench.immersive.get_window_id(), "Freshness is requested for the workbench's own window")
	_check(_trackers.left.has_tracking_data and _trackers.left.get_hand_joint_flags(INDEX) == FLAGS, "Expired left pose still has readable XR tracker flags in this fixture")
	_check(document.inspection.get_committed_points() == pins and not document.history.result.is_empty(), "A click between expiry and native cleanup preserves existing pins and history")
	_check(not bench.live_sample.valid and not bench.skeleton._joints.left[INDEX].visible and bench.skeleton._joints.right[INDEX].visible, "Only the expired hand disappears")
	bench.place_near_hand()
	_check(bench._placement == placement and bench.get_node("%NearHand").disabled, "An expired fingertip cannot move the field")
	bench.select_hand(1)
	_tick(bench)
	_check(bench.live_sample.valid and bench.live_sample.unit.is_equal_approx(Vector3(0.875, 0.5, 0.5)), "The other hand can still sample the field")
	published.fresh = [true, false]
	bench.select_hand(0)
	_tick(bench)
	_check(bench.live_sample.valid and not bench.hands.right.tracked, "Newly published left data recovers while expired right data stays hidden")
	published.fresh[1] = true


func _test_presentation(document: Node, second: Node) -> void:
	var pins: Dictionary = document.inspection.get_committed_points()
	document.history.analyze()
	await _wait_history(document.history)
	var history: Dictionary = document.history.result.duplicate(true)
	_check(not history.is_empty(), "Presentation tests begin with actual saved pins and analyzed history")
	var waiting := _bench(document)
	document.hand_workbench = waiting
	waiting.presentation_ready = false
	var failures: Array[String] = []
	waiting.failed.connect(func(message: String) -> void: failures.append(message))
	_check(waiting.start(document).is_empty(), "Opening starts while native presentation is still pending")
	_put(waiting, "left", INDEX, Vector3(0.375, 0.5, 0.5))
	_tick(waiting)
	_check(not waiting._presented and not waiting.live_sample.valid and waiting.hands.is_empty(), "Pending presentation cannot consume stale global hand trackers")
	_check(waiting.get_node("%PinA").disabled and waiting.get_node("%PinB").disabled and waiting.get_node("%NearHand").disabled, "Pending presentation disables both pins and near-fingertip placement")
	_check(not waiting.skeleton._joints.left[INDEX].visible and not waiting._pins[0].visible, "Pending presentation hides skeleton and committed marker geometry")
	var placement: Vector3 = waiting._placement
	waiting.pin(0)
	waiting.pin(1)
	waiting.place_near_hand()
	_check(document.inspection.get_committed_points() == pins and waiting._placement == placement and document.history.result == history, "Synchronous Pin and Move actions cannot bypass the presentation gate or invalidate history")
	_check(not waiting.start(second).is_empty() and waiting.document == document, "A pending workbench cannot be restarted with a different document")
	var contender := _bench(second)
	_check(not contender.start(second).is_empty() and contender.document == null, "Pending presentation retains exclusive immersive ownership")
	contender.free()
	waiting._notification(Node.NOTIFICATION_APPLICATION_FOCUS_OUT)
	waiting._process(Fixture.PRESENTATION_TIMEOUT + 1.0)
	_check(not waiting._closed and is_zero_approx(waiting._opening_elapsed) and failures.is_empty(), "Background time does not count toward native presentation timeout")
	waiting._notification(Node.NOTIFICATION_APPLICATION_FOCUS_IN)
	waiting._process(0.25)
	waiting._process(-1.0)
	_check(is_equal_approx(waiting._opening_elapsed, 0.25), "Presentation timeout accumulates active time and ignores negative deltas")
	waiting.presentation_ready = true
	_tick(waiting)
	_check(waiting._presented and waiting.live_sample.valid and is_zero_approx(waiting._opening_elapsed), "Confirmed presentation begins fresh sampling and clears the opening timer")
	_trackers.left.has_tracking_data = false
	_trackers.right.has_tracking_data = false
	waiting._process(Fixture.PRESENTATION_TIMEOUT + 1.0)
	_check(not waiting._closed and failures.is_empty() and not waiting.live_sample.valid, "Presented space with unavailable or denied tracking does not trigger an opening timeout")
	waiting.presentation_ready = false
	_tick(waiting)
	_check(waiting._closed and not waiting.immersive.visible and not waiting.panel.visible and failures.is_empty(), "Losing an already presented space stops cleanly without an opening-timeout error")
	_check(document.inspection.get_committed_points() == pins and document.history.result == history, "Presentation loss preserves saved probes and analyzed history")
	await _settle()
	_check(not is_instance_valid(waiting), "Presentation loss frees the old singleton instance")

	var timed_out := _bench(document)
	document.hand_workbench = timed_out
	timed_out.presentation_ready = false
	var outcomes: Array[Dictionary] = []
	timed_out.failed.connect(func(message: String) -> void:
		outcomes.append({message = message, closed = timed_out._closed, windows_hidden = not timed_out.immersive.visible and not timed_out.panel.visible}))
	_check(timed_out.start(document).is_empty(), "A fresh instance retries after native presentation loss")
	_put(timed_out, "left", INDEX, Vector3(0.375, 0.5, 0.5))
	timed_out._process(Fixture.PRESENTATION_TIMEOUT)
	_check(outcomes.size() == 1 and not outcomes[0].message.is_empty() and outcomes[0].closed and outcomes[0].windows_hidden, "Opening timeout closes windows before reporting one actionable failure")
	timed_out.presentation_ready = true
	timed_out._process(Fixture.PRESENTATION_TIMEOUT)
	timed_out.pin(1)
	_check(outcomes.size() == 1 and not timed_out.live_sample.valid and document.inspection.get_committed_points() == pins and document.history.result == history, "Late readiness cannot revive a timed-out session, commit a point, or repeat its error")
	_check(not timed_out.start(document).is_empty(), "A timed-out instance cannot be reused")
	await _settle()
	_check(not is_instance_valid(timed_out), "Opening timeout releases the singleton after deferred deletion")

	var retry := _bench(document)
	document.hand_workbench = retry
	_check(retry.start(document).is_empty(), "Retry uses a fresh workbench after timeout cleanup")
	_put(retry, "left", INDEX, Vector3(0.375, 0.5, 0.5))
	_tick(retry)
	_check(retry.live_sample.valid and retry._presented, "Fresh retry samples the current hand when native presentation is confirmed")
	retry.immersive.hide()
	_check(retry._closed and not retry.panel.visible, "Native immersive visibility loss closes its accompanying panel")
	await _settle()
	var canceled := _bench(document)
	document.hand_workbench = canceled
	canceled.presentation_ready = false
	var canceled_errors: Array[String] = []
	canceled.failed.connect(func(message: String) -> void: canceled_errors.append(message))
	_check(canceled.start(document).is_empty(), "Another pending presentation can be canceled explicitly")
	canceled.stop()
	canceled._process(Fixture.PRESENTATION_TIMEOUT + 1.0)
	_check(canceled_errors.is_empty() and document.inspection.get_committed_points() == pins, "Explicit Return while opening does not produce a later timeout or erase pins")
	await _settle()


func _cleanup() -> void:
	for hand in _trackers:
		XRServer.remove_tracker(_trackers[hand])
		if _prior_trackers[hand] != null:
			XRServer.add_tracker(_prior_trackers[hand])
	_trackers.clear()
	XRServer.world_scale = _world_scale
	for file in DirAccess.get_files_at(_directory):
		DirAccess.remove_absolute(_directory.path_join(file))
	DirAccess.remove_absolute(_directory)
