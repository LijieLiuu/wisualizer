extends SceneTree
## Synthetic data through the real team host, controls, handle, and sound.
## Headless fixtures cannot establish headset presentation or ARKit behavior.
const Host := preload("res://addons/spatial/reality_kit/reality_kit_volume.gd")
const INDEX := XRHandTracker.HAND_JOINT_INDEX_FINGER_TIP
const THUMB := XRHandTracker.HAND_JOINT_THUMB_TIP
const FLAGS := XRHandTracker.HAND_JOINT_FLAG_POSITION_VALID | XRHandTracker.HAND_JOINT_FLAG_POSITION_TRACKED

class Api extends RefCounted:
	var revision := 2
	var presented := true
	var fresh := [true, true]
	var last_window := -1
	func get_api_revision() -> int:
		return revision
	func is_immersive_presented(window: int) -> bool:
		last_window = window
		return presented
	func is_hand_sample_fresh(window: int, hand: int) -> bool:
		last_window = window
		return fresh[hand]

class ToolsFixture extends "res://app/hand_workbench.gd":
	func _runtime_problem() -> String:
		return ""

var _checks := 0
var _failures := 0
var _directory := ""
var _trackers := {}
var _previous := {}
var _world_scale := 1.0
var _document_scene: PackedScene
var _tools_scene: PackedScene

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
	var document := _document_scene.instantiate()
	root.add_child(document)
	_check(document.open(path).is_empty(), "Open legacy scalar model in the merged document")
	document.set_process(false)
	document.clock.set_process(false)
	document.touch.set_process(false)
	document.probes.set_process(false)
	document.sound.set_process(false)
	# Replace only the desktop presentation backend. All tested immersive,
	# coordinate, lifecycle, and handle methods are the actual team backend.
	var desktop = document.volume._backend
	desktop._camera.free()
	var host = Host.new(document.volume)
	document.volume._backend = host
	host.resized.connect(document.volume.resized.emit)
	host.immersive_changed.connect(document.volume.immersive_changed.emit)
	host._hand_api = Api.new()
	document.show_options(true)
	return document


func _tools(document: Node) -> Node:
	var tools := _tools_scene.instantiate()
	tools.set_script(ToolsFixture)
	document.options.add_child(tools)
	document.hand_workbench = tools
	tools.set_process(false)
	return tools


func _install_trackers() -> void:
	_world_scale = XRServer.world_scale
	for side in ["left", "right"]:
		var name := StringName("/user/hand_tracker/" + side)
		_previous[side] = XRServer.get_tracker(name)
		if _previous[side] != null:
			XRServer.remove_tracker(_previous[side])
		var hand := XRHandTracker.new()
		hand.name = name
		hand.hand = XRPositionalTracker.TRACKER_HAND_LEFT if side == "left" else XRPositionalTracker.TRACKER_HAND_RIGHT
		hand.has_tracking_data = true
		for joint in XRHandTracker.HAND_JOINT_MAX:
			hand.set_hand_joint_flags(joint, 0)
		XRServer.add_tracker(hand)
		_trackers[side] = hand


func _put(document: Node, side: String, joint: int, unit: Vector3, basis := Basis.IDENTITY) -> void:
	var world: Vector3 = document.field.global_transform * unit
	var origin: Transform3D = document.volume._backend._origin.global_transform.orthonormalized()
	var raw := origin.affine_inverse() * Transform3D(basis, world)
	raw.origin /= XRServer.world_scale
	_trackers[side].set_hand_joint_transform(joint, raw)
	_trackers[side].set_hand_joint_flags(joint, FLAGS)


func _event(kind: String, pressed := true) -> InputEvent:
	var event: InputEvent = ClassDB.instantiate(StringName(kind))
	event.set("index", 4)
	event.set("kind", 1)
	event.set("has_chirality", true)
	event.set("chirality", 0)
	if kind == "InputEventSpatialTouch":
		event.set("pressed", pressed)
	return event


func _pick_field(document: Node, index: int) -> void:
	for button in document.get_node("Model/Options/Bar").get_children():
		if button.has_meta("field_index") and button.get_meta("field_index") == index:
			button.pressed.emit()
			return
	_check(false, "The team's normal field picker contains the requested field")


func _lifecycle(document: Node, api: Api) -> void:
	api.presented = true
	var tools := _tools(document)
	_check(tools.start(document).is_empty(), "A/B tools reopen in the existing presented host after native presentation recovers")
	var pins: Dictionary = document.inspection.get_committed_points()
	tools._notification(Node.NOTIFICATION_APPLICATION_PAUSED)
	tools.pin(0)
	tools._process(100.0)
	_check(not tools.live_sample.valid and document.inspection.get_committed_points() == pins and not tools._closed, "Backgrounding suppresses pinning without consuming the opening timeout or losing committed pins")
	tools._notification(Node.NOTIFICATION_APPLICATION_RESUMED)
	_put(document, "left", INDEX, Vector3(0.625, 0.5, 0.5))
	tools._process(0.0)
	_check(tools.live_sample.valid, "Foregrounding reacquires a freshly validated fingertip")
	var near_size: float = document.volume.size
	_pick_field(document, 1)
	_check(document.field_index == 1 and document.inspection.get_committed_points().is_empty(), "The team's field picker switches fields and clears prior-field pins while only hand tools are open")
	_check(document.volume.size > near_size * 10.0, "Selecting a distant field fits it into the existing host while A/B tools are open")
	_put(document, "left", INDEX, Vector3(0.625, 0.5, 0.5))
	tools.get_node("%PinA").pressed.emit()
	_check(tools.pinned_readout.text.contains("Temperature") and document.inspection.get_committed_points().has(0), "The selected distant field can be pinned through the real Pin A action")
	_pick_field(document, 0)
	_check(is_equal_approx(document.volume.size, near_size) and document.inspection.get_committed_points().is_empty(), "The same picker returns to the original field fit without retaining unrelated pins")
	_pick_field(document, 1)
	# Keep this setup explicit so the shutdown assertion independently tests
	# restoration even if the field-change fit assertion fails.
	document.fit()
	var far_size: float = document.volume.size
	document.get_node("%Hands").pressed.emit()
	_check(document.hand_workbench == null and document.volume.is_immersive() and document.volume.size < far_size * 0.1, "Toggling A/B tools off restores the team model fit while leaving its immersive host open")
	await _settle()
	_pick_field(document, 0)
	document.volume.set_immersive(false)
	api.presented = false
	tools = _tools(document)
	_check(tools.start(document).is_empty(), "A/B tools can reenter after returning to the regular volume")
	var failures: Array[String] = []
	tools.failed.connect(func(message: String): failures.append(message))
	tools._notification(Node.NOTIFICATION_APPLICATION_PAUSED)
	tools._process(100.0)
	_check(document.volume.is_immersive() and not tools._closed, "Opening remains pending throughout an application pause")
	tools._notification(Node.NOTIFICATION_APPLICATION_RESUMED)
	tools._process(16.0)
	_check(tools._closed and not document.volume.is_immersive() and failures.size() == 1 and document.hand_workbench == null, "A real presentation timeout releases the owner and reports exactly one failure")
	await _settle()
	tools = _tools(document)
	_check(tools.start(document).is_empty(), "Retry after presentation timeout reacquires the same model host")
	document.show_options(false)
	api.presented = true
	tools._process(16.0)
	_check(document.volume.is_immersive() and not tools._closed, "A presented space is acknowledged even when Options was hidden during opening")
	# Continue cleanup on both sides of the regression until it is fixed.
	if not tools._closed:
		document.show_options(true)
		_put(document, "left", INDEX, Vector3(0.625, 0.5, 0.5))
		tools._process(0.0)
		_check(tools.live_sample.valid, "Reopening Options resumes current sampling in the same space")
		document.immersive_button.set_pressed(false)
		await _settle()
		_check(document.hand_workbench == null and not document.volume.is_immersive(), "The team's immersive button closes hand tools when returning to the regular volume")
	await _settle()


func _run() -> void:
	_document_scene = load("res://app/document.tscn")
	_tools_scene = load("res://app/hand_workbench.tscn")
	_directory = OS.get_temp_dir().path_join("wisualizer-shared-hands-%d" % Time.get_ticks_usec())
	DirAccess.make_dir_recursive_absolute(_directory)
	var source := _directory.path_join("source.zip")
	_fixture(source)
	_install_trackers()
	var document := _document(source)
	var host = document.volume._backend
	var api: Api = host._hand_api
	var before_windows := document.find_children("*", "Window", true, false).filter(func(window: Node): return not window is PopupMenu).size()
	var before_parts: Array = document.parts.duplicate()
	var before_model: Window = document.model
	var tools := _tools(document)
	_check(tools.start(document).is_empty(), "A/B tools enter the team's existing immersive host")
	_check(document.model == before_model and document.find_children("*", "Window", true, false).filter(func(window: Node): return not window is PopupMenu).size() == before_windows, "A/B tools create no additional window or world")
	_check(document.parts == before_parts and tools.find_children("*", "Camera3D", true, false).is_empty() and tools.find_children("*", "Node3D", true, false).is_empty(), "A/B tools create no camera, model readers, or duplicate skeleton")
	_check(document.volume.is_immersive() and host._handle != null and host._head is XRCamera3D, "The team's immersive camera and drag handle remain active")
	_check(not document.playing and not document.probing, "Opening A/B tools pauses the shared clock and ends gesture placement")
	var joint_basis := Basis(Vector3.UP, 0.45)
	_put(document, "left", INDEX, Vector3(0.625, 0.5, 0.5), joint_basis)
	_put(document, "left", THUMB, Vector3(0.5, 0.5, 0.5))
	_put(document, "right", INDEX, Vector3(0.875, 0.5, 0.5))
	tools._process(0.0)
	_check(tools.live_sample.valid and tools.live_sample.unit.is_equal_approx(Vector3(0.625, 0.5, 0.5)), "Real host origin and world scale undo native tracker conversion exactly once")
	_check(document.volume.get_hand_joint(_trackers.left, INDEX).basis.is_equal_approx(joint_basis), "Spatial joint API preserves the valid joint orientation")
	_check(api.last_window == document.model.get_window_id(), "Freshness queries belong to the presented model window")
	tools.get_node("%PinA").pressed.emit()
	_check(document.inspection.get_committed_points()[0].is_equal_approx(Vector3(0.625, 0.5, 0.5)), "Real Pin A action stores the selected normalized field point")
	tools.select_hand(1)
	tools.get_node("%PinB").pressed.emit()
	_check(tools.pinned_readout.text.contains("A: 0.0 Pa") and tools.pinned_readout.text.contains("B: 2.0 Pa") and tools.pinned_readout.text.contains("B − A: 2.0 Pa"), "One shared current-frame readout confirms both pins and difference")
	var pins: Dictionary = document.inspection.get_committed_points()
	document.probes.update_probes()
	_check(document.probes._joints.multimesh.instance_count == 3, "Existing team joint MultiMesh shows only the three valid positions")
	_check(document.probes._probes.has("inspection_0") and document.probes._probes.has(_trackers.right.get_instance_id()), "Pinned and existing live field-cell indicators coexist")
	var settings: Node = root.get_node("Settings")
	var old_sound: bool = settings.sound
	settings.sound = true
	document.sound._process(0.0)
	_check(document.sound._voices.size() == 2 and document.sound._voices[_trackers.left].target_loudness > 0.0 and document.sound._voices[_trackers.right].target_loudness > 0.0, "Team stereo finger sound stays active for both hands while A/B tools are open")
	_check(document.sound._voices[_trackers.left].gains.x > document.sound._voices[_trackers.left].gains.y and document.sound._voices[_trackers.right].gains.y > document.sound._voices[_trackers.right].gains.x, "Team voices retain opposite stereo panning")
	_check(is_equal_approx(document.sound._voices[_trackers.right].target_pitch, settings.high_pitch), "Maximum right-hand field value retains the team's configured pitch mapping")
	var old_center: Vector3 = host._space_center
	host._handle.input_event.emit(host._head, _event("InputEventSpatialTouch"), Vector3.ZERO, Vector3.ZERO, 0)
	_check(host._handle_touch == 4, "Normal team handle press acquires the tracked pinching hand")
	var delta := Vector3(0.05, 0.03, -0.02)
	for joint in [INDEX, THUMB]:
		var pose: Transform3D = _trackers.left.get_hand_joint_transform(joint)
		pose.origin += delta
		_trackers.left.set_hand_joint_transform(joint, pose)
	host._handle.input_event.emit(host._head, _event("InputEventSpatialDrag"), Vector3.ZERO, Vector3.ZERO, 0)
	_check(host._space_center.is_equal_approx(old_center + delta), "Normal handle drag moves team placement using raw tracking meters")
	_check(document.inspection.get_committed_points() == pins, "Moving the team model cannot change committed normalized A/B locations")
	host._handle.input_event.emit(host._head, _event("InputEventSpatialTouch", false), Vector3.ZERO, Vector3.ZERO, 0)
	_check(host._handle_touch == -1, "Team handle release ends its gesture normally")
	_put(document, "left", INDEX, Vector3(0.625, 0.5, 0.5))
	_put(document, "right", INDEX, Vector3(0.875, 0.5, 0.5))
	tools.select_hand(0)
	api.fresh[0] = false
	tools.pin(0)
	_check(not tools.live_sample.valid and document.inspection.get_committed_points() == pins and _trackers.left.has_tracking_data, "Click-time freshness rejects an expired hand even while its tracker flags remain set")
	document.probes.update_probes()
	document.sound._process(0.0)
	_check(document.probes._joints.multimesh.instance_count == 1 and document.sound._voices[_trackers.left].target_loudness == 0.0 and document.sound._voices[_trackers.right].target_loudness > 0.0, "The same stale-hand guard removes only that hand's dots and sound")
	tools.select_hand(1)
	_check(tools.live_sample.valid, "The independently fresh other hand still samples")
	api.fresh[0] = true
	tools.select_hand(0)
	_check(tools.live_sample.valid, "Fresh reacquisition recovers sampling without reopening")
	_trackers.left.set_hand_joint_flags(INDEX, XRHandTracker.HAND_JOINT_FLAG_POSITION_VALID)
	tools.pin(0)
	_check(not tools.live_sample.valid and not document.volume.get_hand_joint(_trackers.left, INDEX).origin.is_finite(), "An untracked individual joint is unavailable for pinning and ordinary consumers")
	_trackers.left.set_hand_joint_flags(INDEX, FLAGS)
	var second := _document(source)
	second.set_playing(true)
	_check(second.inspection.begin(42, second.field.global_transform * Vector3(0.25, 0.5, 0.5), Vector3.ZERO, second.field.global_transform), "Begin an unrelated transient placement in the second model")
	var second_points: Dictionary = second.inspection.get_points()
	var transitions := [0]
	second.volume.immersive_changed.connect(func(_immersive: bool): transitions[0] += 1)
	second.immersive_button.set_pressed(true)
	await _settle()
	_check(not second.immersive_button.button_pressed and transitions[0] == 0 and second.inspection.is_active(), "Rejected normal immersive toggle resets its button without a false transition or canceled placement")
	var rejected := _tools(second)
	_check(not rejected.start(second).is_empty(), "A second model's A/B request is rejected before entering the owned immersive space")
	_check(not second.volume.is_immersive() and document.volume.is_immersive() and second.playing, "Rejected second-model tools preserve its playing clock and the first immersive owner")
	_check(second.inspection.is_active() and second.inspection.get_points() == second_points and transitions[0] == 0, "Rejected A/B start preserves the contender's transient placement and emits no false transition")
	second.volume._backend._camera.preview_camera_enabled = true
	second.close()
	await _settle()
	# Losing native presentation clears tools, while main keeps control of its host.
	api.presented = false
	tools._process(0.0)
	_check(tools._closed and document.hand_workbench == null and document.inspection.get_committed_points() == pins, "Lost native presentation closes only A/B controls and retains committed pins")
	await _settle()
	await _lifecycle(document, api)
	document.volume.set_immersive(false)
	api.revision = 1
	document.volume.set_immersive(true)
	_check(document.volume.is_immersive() and not document.volume.has_safe_hand_tracking(), "Ordinary team immersion remains available with a stock/older addon")
	_put(document, "left", INDEX, Vector3(0.625, 0.5, 0.5))
	_put(document, "left", THUMB, Vector3(0.5, 0.5, 0.5))
	_put(document, "right", INDEX, Vector3(0.875, 0.5, 0.5))
	document.sound._process(0.0)
	_check(document.sound._voices[_trackers.left].target_loudness > 0.0 and document.sound._voices[_trackers.right].target_loudness > 0.0, "The older-addon fallback preserves both team finger-sound voices")
	var fallback_center: Vector3 = host._space_center
	host._handle.input_event.emit(host._head, _event("InputEventSpatialTouch"), Vector3.ZERO, Vector3.ZERO, 0)
	for joint in [INDEX, THUMB]:
		var pose: Transform3D = _trackers.left.get_hand_joint_transform(joint)
		pose.origin += Vector3(0.01, 0.02, 0.03)
		_trackers.left.set_hand_joint_transform(joint, pose)
	host._handle.input_event.emit(host._head, _event("InputEventSpatialDrag"), Vector3.ZERO, Vector3.ZERO, 0)
	_check(host._space_center.is_equal_approx(fallback_center + Vector3(0.01, 0.02, 0.03)), "The older-addon fallback preserves the normal team drag handle")
	host._handle.input_event.emit(host._head, _event("InputEventSpatialTouch", false), Vector3.ZERO, Vector3.ZERO, 0)
	var unsupported := _tools(document)
	_check(not unsupported.start(document).is_empty(), "Continuous A/B pinning explains its stricter capability requirement")
	unsupported.stop()
	await _settle()
	document.show_probe_history()
	_check(document.history.visible, "Manual history remains available with an older addon")
	document.volume.set_immersive(false)
	# Native macOS preview cameras are detached when disabled; reattach the
	# fixture-only preview before node cleanup (not a headset behavior).
	host._camera.preview_camera_enabled = true
	document.close()
	await _settle()
	# Let the audio thread release stopped generator playbacks before this
	# fast headless fixture exits; this is not a presentation delay in the app.
	await create_timer(0.2).timeout
	settings.sound = old_sound
	for side in _trackers:
		XRServer.remove_tracker(_trackers[side])
		if _previous[side] != null:
			XRServer.add_tracker(_previous[side])
	_trackers.clear()
	_previous.clear()
	XRServer.world_scale = _world_scale
	DirAccess.remove_absolute(source)
	DirAccess.remove_absolute(_directory)
	print("hand_workbench_test: %d checks, %d failures" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)
