extends SceneTree
## Exercise real scalar sampling and probe nodes with controlled spatial input.

const Probes := preload("res://app/field_probes.gd")
const Touch := preload("res://app/field_touch.gd")
const Meta := preload("res://app/meta.gd")

class TestVolume extends SpatialVolume3D:
	var measured := Vector3.ZERO
	var controllers: Array[XRController3D] = []
	func _enter_tree() -> void:
		pass
	func get_measured_size() -> Vector3:
		return measured
	func get_controllers() -> Array[XRController3D]:
		return controllers

var _checks := 0
var _failures := 0


func _initialize() -> void:
	_run.call_deferred()


func _check(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error("FAIL: " + message)


func _run() -> void:
	var parent := Node3D.new()
	root.add_child(parent)
	var field := Node3D.new()
	parent.add_child(field)
	field.transform = Transform3D(Basis(Vector3(4, 0, 0), Vector3(1, 2, 0), Vector3(0, 0, 3)), Vector3(10, 20, 30))
	var volume := TestVolume.new()
	volume.size = 5.0
	volume.window_size = Vector3.ONE
	parent.add_child(volume)
	var touch := Touch.new()
	parent.add_child(touch)
	touch.set_process(false)
	touch.field = field
	touch.volume = volume
	touch.set_brick(PackedByteArray([0, 1, 128, 255]), Vector3i(4, 1, 1), 255)
	var probes := Probes.new()
	parent.add_child(probes)
	probes.set_process(false)
	probes.touch = touch
	probes.field = field
	probes.volume = volume
	probes.shown_field = Meta.Field.new()
	probes.shown_field.range = Vector2(-2, 2)
	probes.shown_field.quantity = "Pressure"
	probes.shown_field.unit = "Pa"
	probes.inspection_points = {0: Vector3(0.625, 0.5, 0.5), 1: Vector3(0.875, 0.5, 0.5)}
	probes.update_probes()
	_check(probes._probes.size() == 2, "Two hand inspection points show without controllers")
	if probes._probes.size() != 2:
		parent.free()
		_finish()
		return
	var a: Dictionary = probes._probes.inspection_0
	var b: Dictionary = probes._probes.inspection_1
	_check(a.cube.position.is_equal_approx(Vector3(13, 21, 31.5)), "Cell center respects source translation, shear and anisotropic scale")
	_check(a.cube.basis.x.is_equal_approx(Vector3(1, 0, 0)) and a.cube.basis.y.is_equal_approx(Vector3(1, 2, 0)), "Cell cube retains affine axes")
	_check(a.label.text.begins_with("A · Pressure") and a.label.text.get_slice("\n", 2) == "0.0 Pa", "Physical zero is a valid labeled A sample")
	_check(b.label.text.begins_with("B · Pressure") and b.label.text.get_slice("\n", 2) == "2.0 Pa", "B keeps its own value and units")
	probes.inspection_points[1] = Vector3(0.65, 0.6, 0.6)
	probes.update_probes()
	_check(probes._probes.size() == 1 and a.label.text.begins_with("A / B · Pressure"), "Two pins in the same cell share one identified label and cube")
	_check(not b.cube.visible and not b.label.visible, "Merged B removes the overlapping visuals immediately")
	_check(probes.inspection_points.size() == 2, "Visual merging preserves both inspection positions")
	probes.inspection_points[1] = Vector3(0.875, 0.5, 0.5)
	probes.update_probes()
	b = probes._probes.inspection_1
	_check(probes._probes.size() == 2 and a.label.text.begins_with("A · Pressure") and b.label.text.begins_with("B · Pressure"), "Moving B to another cell restores separate labels")
	var initial_pixel_size: float = a.label.pixel_size
	_check(is_finite(initial_pixel_size) and is_equal_approx(initial_pixel_size, 0.02 / 0.2 / 48.0), "Declared size keeps labels finite before the native measurement arrives")
	volume.measured = Vector3.ONE * 2.0
	probes.update_probes()
	_check(is_equal_approx(a.label.pixel_size, initial_pixel_size * 0.5), "Unchanged cell updates label scale after volume resize")
	parent.transform = Transform3D(Basis(Vector3.UP, 0.7), Vector3(-7, 4, 2))
	probes.update_probes()
	_check(a.cube.position.is_equal_approx(Vector3(13, 21, 31.5)), "Model rotation and translation do not move a pinned cell in model space")
	field.position.x += 6.0
	probes.update_probes()
	_check(a.cube.position.is_equal_approx(Vector3(19, 21, 31.5)), "Unchanged cell refreshes after a field transform change")
	touch.set_brick(PackedByteArray([0, 1, 255, 128]), Vector3i(4, 1, 1), 255)
	probes.update_probes()
	_check(a.label.text.get_slice("\n", 2) == "2.0 Pa" and b.label.text.get_slice("\n", 2) == "0.0 Pa", "Pinned positions read the new frame rather than stale values")
	probes.shown_field.unit = "K"
	probes.shown_field.quantity = "Temperature"
	probes.update_probes()
	_check(a.label.text.begins_with("A · Temperature") and a.label.text.get_slice("\n", 2) == "2.0 K", "Changing field metadata refreshes a stationary label")
	probes.inspection_points[0] = Vector3(0.125, 0.5, 0.5)
	probes.update_probes()
	_check(a.label.text.ends_with("No data") and not a.label.text.contains("nan"), "Missing byte has an explicit label, not a numerical zero or NAN")
	_check((a.cube.material_override as StandardMaterial3D).albedo_color.is_equal_approx(Color(0.6, 0.6, 0.6, 0.55)), "Missing sample uses a neutral cube")
	probes.inspection_points.erase(1)
	probes.update_probes()
	_check(probes._probes.size() == 1 and not b.cube.visible and not b.label.visible, "Removed B is hidden immediately and removed from the cache")
	probes.inspection_points = {0: Vector3(NAN, 0, 0), 1: Vector3(1.1, 0.5, 0.5)}
	probes.update_probes()
	_check(probes._probes.is_empty(), "Nonfinite and outside points never leave stale visuals")
	probes.inspection_points = {0: Vector3(0.625, 0.5, 0.5)}
	probes.update_probes()
	probes.hide()
	probes.update_probes()
	_check(probes._probes.is_empty(), "Disabling probe visibility clears all sources")
	probes.show()
	probes.update_probes()
	parent.hide()
	probes.update_probes()
	_check(probes._probes.is_empty(), "Hidden ancestor clears all sources")
	parent.show()
	probes.update_probes()
	touch.set_brick(PackedByteArray([1]), Vector3i(4, 1, 1), 255)
	probes.update_probes()
	_check(probes._probes.is_empty(), "Corrupt replacement brick clears the old frame's probe")
	touch.set_brick(PackedByteArray([0, 1, 128, 255]), Vector3i(4, 1, 1), 255)
	probes.update_probes()
	volume.measured = Vector3.ZERO
	volume.window_size = Vector3.ZERO
	probes.update_probes()
	_check(probes._probes.is_empty(), "Invalid measured and declared dimensions cannot create infinite labels")
	volume.window_size = Vector3.ONE
	await _test_controller_lifecycle(probes, touch, field, volume, parent)
	var hidden_window := Window.new()
	hidden_window.visible = false
	root.add_child(hidden_window)
	probes.reparent(hidden_window)
	probes.inspection_points = {0: Vector3(0.625, 0.5, 0.5)}
	probes.update_probes()
	_check(probes._probes.is_empty(), "Closed or hidden document window removes probes")
	hidden_window.free()
	parent.free()
	await process_frame
	_finish()


func _test_controller_lifecycle(probes, touch, field: Node3D, volume: TestVolume, parent: Node3D) -> void:
	var tracker := XRPositionalTracker.new()
	tracker.type = XRServer.TRACKER_CONTROLLER
	tracker.name = &"probe_test_controller"
	XRServer.add_tracker(tracker)
	var controller := XRController3D.new()
	controller.tracker = tracker.name
	controller.pose = &"aim"
	parent.add_child(controller)
	var controller_tip: Vector3 = field.global_transform * Vector3(0.875, 0.5, 0.5)
	tracker.set_pose(&"aim", Transform3D(Basis.IDENTITY, controller_tip + Vector3(0, 0, touch.TIP)), Vector3.ZERO, Vector3.ZERO, XRPose.XR_TRACKING_CONFIDENCE_HIGH)
	await process_frame
	# XRController3D's pose is relative to its parent, which is transformed.
	controller.global_transform = Transform3D(Basis.IDENTITY, controller_tip + Vector3(0, 0, touch.TIP))
	volume.controllers = [controller]
	probes.inspection_points = {0: Vector3(0.625, 0.5, 0.5)}
	probes.show_controllers = true
	probes.update_probes()
	_check(controller.get_has_tracking_data(), "Synthetic real XR tracker supplies a live controller pose")
	_check(probes._probes.size() == 2, "Hand pin and tracked controller coexist")
	var key := controller.get_instance_id()
	if probes._probes.has(key):
		var old: Dictionary = probes._probes[key]
		volume.controllers.clear()
		probes.update_probes()
		_check(not probes._probes.has(key) and not old.cube.visible, "Removed controller leaves no stale cell")
	volume.controllers = [controller]
	probes.update_probes()
	probes.show_controllers = false
	probes.update_probes()
	_check(probes._probes.size() == 1 and probes._probes.has("inspection_0"), "Debug toggle removes controller probes while preserving A")
	probes.show_controllers = true
	tracker.invalidate_pose(&"aim")
	await process_frame
	probes.update_probes()
	_check(not probes._probes.has(key), "Tracking loss removes controller visualization")
	volume.controllers.clear()
	XRServer.remove_tracker(tracker)
	controller.free()


func _finish() -> void:
	print("Field probes: %d checks, %d failures" % [_checks, _failures])
	quit(1 if _failures else 0)
