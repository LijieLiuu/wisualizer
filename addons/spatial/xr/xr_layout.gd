class_name SpatialXRLayout
extends Node3D
## XR layout: every window becomes a panel in the headset's world, at the
## physical size visionOS would give it, and every volume a box. Placement
## follows [member Window.placement] and the ornament properties; controllers
## (or, in the simulator, the mouse) point at panels and click them.
##
## The app's windows are embedded in an offscreen viewport, so their content
## reaches the world only through the panels, and the main scene moves into
## a window of its own, shown like any other.

const XRVolume := preload("xr_volume.gd")
const Placement := preload("../placement.gd")
const POINTS_PER_METER := 1360.0
## How far in front of the head the main window opens, in meters.
const MAIN_DISTANCE := 1.0
## The simulator's eye height, in meters.
const EYE_HEIGHT := 1.6
## How far ornaments and popups sit in front of what they belong to.
const LIFT := 0.005
const LOOK_SPEED := 0.005
## Trigger values that start and end a press.
const PRESS := 0.6
const RELEASE := 0.4
## Seconds between scroll steps while a thumbstick is held.
const SCROLL_INTERVAL := 0.08


class Pointer:
	## Points along its -Z axis.
	var node: Node3D
	var pressed := false
	## The window under the pointer, or the one a press started in.
	var window: Window
	var position := Vector2.ZERO
	var scroll_wait := 0.0
	var dot := MeshInstance3D.new()


static var instance: SpatialXRLayout

var _embedder := SubViewport.new()
## The controllers that point at panels, using their "aim" pose; none in the
## simulator.
var controllers: Array[XRController3D] = []
var _origin := XROrigin3D.new()
var _camera := XRCamera3D.new()
var _windows: Array[Window] = []
## Window to its panel, a MeshInstance3D showing its content.
var _panels := {}
## Window to the XR volume backend showing it.
var _volumes := {}
## Window to the outline drawn around its volume.
var _outlines := {}
## Window to where it is placed: the center of its panel or box.
var _frames := {}
var _pointers: Array[Pointer] = []
var _simulated := SpatialPlatform.is_simulated_xr()


## The layout volumes are placed by.
static func of(_node: Node) -> SpatialXRLayout:
	return instance


func _init() -> void:
	instance = self


func _ready() -> void:
	var root := get_tree().root
	root.use_xr = not _simulated
	add_child(_origin)
	_origin.add_child(_camera)
	_camera.current = true
	_add_environment()
	if _simulated:
		root.size = Vector2i(1440, 900)
		_camera.position.y = EYE_HEIGHT
		var pointer := Pointer.new()
		pointer.node = Node3D.new()
		_camera.add_child(pointer.node)
		_add_pointer(pointer)
	else:
		for hand in [&"left_hand", &"right_hand"]:
			var controller := XRController3D.new()
			controller.tracker = hand
			controller.pose = &"aim"
			_origin.add_child(controller)
			controllers.append(controller)
			var pointer := Pointer.new()
			pointer.node = controller
			controller.add_child(_ray_mesh())
			_add_pointer(pointer)
		var openxr := XRServer.find_interface("OpenXR")
		if openxr != null:
			openxr.pose_recentered.connect(_frames.clear)

	_embedder.name = "Windows"
	_embedder.gui_embed_subwindows = true
	_embedder.size = Vector2i(16, 16)
	_embedder.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(_embedder)
	get_tree().node_added.connect(_on_node_added)


func add_window(window: Window) -> void:
	if window in _windows:
		return
	_windows.append(window)
	window.tree_exited.connect(_forget_if_gone.bind(window))


func add_volume(window: Window, volume: XRVolume) -> void:
	_volumes[window] = volume


## Windows also leave the tree while they move within it.
func _forget_if_gone(window) -> void:
	_remove_if_gone.call_deferred(window)


func _remove_if_gone(window) -> void:
	if is_instance_valid(window) and window.is_inside_tree():
		return
	_windows.erase(window)
	_volumes.erase(window)
	_frames.erase(window)
	for nodes in [_panels, _outlines]:
		if nodes.has(window):
			nodes[window].queue_free()
			nodes.erase(window)


## The main scene is added to the root after the autoloads.
func _on_node_added(node: Node) -> void:
	if node.get_parent() == get_tree().root and not ProjectSettings.has_setting("autoload/" + node.name):
		get_tree().node_added.disconnect(_on_node_added)
		_adopt_main_scene.call_deferred(node)


func _adopt_main_scene(scene: Node) -> void:
	var main := Window.new()
	main.name = "Main"
	main.title = ProjectSettings.get_setting("application/config/name")
	main.size = Vector2i(ProjectSettings.get_setting("display/window/size/viewport_width"), ProjectSettings.get_setting("display/window/size/viewport_height"))
	_embedder.add_child(main)
	scene.reparent(main, false)


func _process(delta: float) -> void:
	for window in _windows:
		_update_window(window)
	for pointer in _pointers:
		_update_pointer(pointer, delta)


func _update_window(window: Window) -> void:
	var follows := window.placement == Window.PLACEMENT_ORNAMENT or window is Popup
	if not window.visible:
		if follows:
			_frames.erase(window)
	elif follows or not _frames.has(window):
		var frame = _place(window)
		if frame != null:
			_frames[window] = frame
	var placed := window.visible and _frames.has(window)

	if _volumes.has(window):
		if placed:
			_volumes[window].place(_frames[window])
			_outline_of(window).transform = _frames[window]
		elif _outlines.has(window):
			_outlines[window].visible = false
		return
	if placed:
		var panel := _panel_of(window)
		panel.transform = _frames[window]
		(panel.mesh as QuadMesh).size = Vector2(_size_of(window).x, _size_of(window).y)
		panel.visible = true
	elif _panels.has(window):
		_panels[window].visible = false


## Where [param window] goes now, or null if what it is placed by isn't
## placed yet.
func _place(window: Window):
	var own := _size_of(window)
	var target := Placement.target_of(window)
	var placed_target := target != null and _frames.has(target) and target.visible
	if window is Popup:
		if not placed_target:
			return null
		# Popups open over a point of their window, in embedder pixels.
		var scale := target.content_scale_factor * POINTS_PER_METER
		var center := (Vector2(window.position - target.position) + Vector2(window.size) * 0.5) / scale
		var target_size := _size_of(target)
		return _frames[target].translated_local(Vector3(center.x - target_size.x * 0.5, target_size.y * 0.5 - center.y, target_size.z * 0.5 + LIFT * 2.0))
	if window.placement == Window.PLACEMENT_ORNAMENT:
		if not placed_target:
			return null
		var target_size := _size_of(target)
		var center := Placement.ornament_center(window, target_size, own)
		return _frames[target].translated_local(Vector3(center.x - target_size.x * 0.5, target_size.y * 0.5 - center.y, center.z - target_size.z * 0.5 + LIFT))
	if not placed_target:
		# Wait for a target that is about to be placed.
		if target != null and target in _windows and target.visible:
			return null
		return _in_front_of_head()
	var target_size := _size_of(target)
	var side := Placement.side(window.placement)
	if side == Vector2.ZERO:
		# Dialogs and other automatic windows open just in front of their window.
		return _frames[target].translated_local(Vector3(0.0, 0.0, target_size.z * 0.5 + 0.05))
	var offset := Vector3(
		side.x * ((target_size.x + own.x) * 0.5 + Placement.GAP),
		-side.y * ((target_size.y + own.y) * 0.5 + Placement.GAP),
		# Volumes beside a window line their front up with it.
		(target_size.z - own.z) * 0.5)
	return _frames[target].translated_local(offset)


func _in_front_of_head():
	# In a headset, wait until the head is tracked.
	if not _simulated and Engine.get_process_frames() < 30:
		return null
	var head := _camera.global_transform
	var forward := -head.basis.z
	forward.y = 0.0
	forward = forward.normalized() if forward.length() > 0.01 else Vector3.FORWARD
	var center := head.origin + forward * MAIN_DISTANCE + Vector3.DOWN * 0.1
	return Transform3D(Basis.looking_at(forward), center)


## A window's physical size in meters: a volume's box, or a panel at the
## size visionOS would show it.
func _size_of(window: Window) -> Vector3:
	if _volumes.has(window):
		return _volumes[window].get_measured_size()
	return Vector3(window.size.x, window.size.y, 0.0) / (window.content_scale_factor * POINTS_PER_METER)


func _panel_of(window: Window) -> MeshInstance3D:
	if not _panels.has(window):
		var material := StandardMaterial3D.new()
		material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		material.albedo_texture = window.get_texture()
		material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR
		var panel := MeshInstance3D.new()
		panel.name = "Panel"
		panel.mesh = QuadMesh.new()
		panel.material_override = material
		add_child(panel)
		_panels[window] = panel
	return _panels[window]


func _outline_of(window: Window) -> MeshInstance3D:
	if not _outlines.has(window):
		var half := _size_of(window) * 0.5
		var lines := ImmediateMesh.new()
		lines.surface_begin(Mesh.PRIMITIVE_LINES)
		for axis in 3:
			for corner in 4:
				var a := Vector3.ONE
				a[(axis + 1) % 3] = -1.0 if corner & 1 else 1.0
				a[(axis + 2) % 3] = -1.0 if corner & 2 else 1.0
				var b := a
				a[axis] = -1.0
				b[axis] = 1.0
				lines.surface_add_vertex(a * half)
				lines.surface_add_vertex(b * half)
		lines.surface_end()
		var material := StandardMaterial3D.new()
		material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		material.albedo_color = Color(1, 1, 1, 0.25)
		var outline := MeshInstance3D.new()
		outline.name = "Outline"
		outline.mesh = lines
		outline.material_override = material
		add_child(outline)
		_outlines[window] = outline
	_outlines[window].visible = true
	return _outlines[window]


func _add_environment() -> void:
	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color(0.12, 0.12, 0.13)
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color(0.5, 0.5, 0.5)
	var world := WorldEnvironment.new()
	world.environment = environment
	add_child(world)
	var light := DirectionalLight3D.new()
	light.rotation = Vector3(deg_to_rad(-50.0), deg_to_rad(-20.0), 0.0)
	add_child(light)
	# A floor, so the room has a sense of up and distance.
	var floor_mesh := PlaneMesh.new()
	floor_mesh.size = Vector2(8.0, 8.0)
	var floor_material := StandardMaterial3D.new()
	floor_material.albedo_color = Color(0.2, 0.2, 0.22)
	floor_mesh.material = floor_material
	var floor := MeshInstance3D.new()
	floor.name = "Floor"
	floor.mesh = floor_mesh
	add_child(floor)


func _add_pointer(pointer: Pointer) -> void:
	var dot := SphereMesh.new()
	dot.radius = 0.004
	dot.height = 0.008
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	dot.material = material
	pointer.dot.mesh = dot
	pointer.dot.visible = false
	add_child(pointer.dot)
	_pointers.append(pointer)


func _ray_mesh() -> MeshInstance3D:
	var ray := BoxMesh.new()
	ray.size = Vector3(0.002, 0.002, 0.3)
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.albedo_color = Color(1, 1, 1, 0.4)
	ray.material = material
	var mesh := MeshInstance3D.new()
	mesh.mesh = ray
	mesh.position.z = -0.15
	return mesh


func _update_pointer(pointer: Pointer, delta: float) -> void:
	if _simulated:
		var mouse := get_viewport().get_mouse_position()
		var direction := _camera.project_ray_normal(mouse)
		pointer.node.global_transform = Transform3D(Basis.looking_at(direction), _camera.project_ray_origin(mouse))
	var origin := pointer.node.global_position
	var direction := -pointer.node.global_basis.z

	var hit: Window = null
	var hit_position := Vector2.ZERO
	var hit_point := Vector3.ZERO
	var nearest := INF
	for window: Window in _panels:
		var panel: MeshInstance3D = _panels[window]
		# A press keeps going to its window, even off its edge, so sliders drag.
		if not panel.visible or (pointer.pressed and pointer.window != null and window != pointer.window):
			continue
		var local := panel.global_transform.affine_inverse()
		var from := local * origin
		var along := local.basis * direction
		if along.z >= 0.0:
			continue
		var distance := -from.z / along.z
		var point := from + along * distance
		var size := (panel.mesh as QuadMesh).size
		var uv := Vector2(point.x / size.x + 0.5, 0.5 - point.y / size.y)
		var inside := uv.x >= 0.0 and uv.x <= 1.0 and uv.y >= 0.0 and uv.y <= 1.0
		if distance < nearest and (inside or pointer.pressed):
			nearest = distance
			hit = window
			hit_position = uv * Vector2(window.size)
			hit_point = panel.global_transform * point

	if hit != pointer.window and pointer.window != null:
		# Moving far outside the window ends any hover in it.
		_send_motion(pointer.window, Vector2(-100000, -100000), false)
	pointer.window = hit
	pointer.dot.visible = hit != null
	if hit != null:
		pointer.dot.global_position = hit_point
		if hit_position != pointer.position:
			pointer.position = hit_position
			_send_motion(hit, hit_position, pointer.pressed)

	var controller := pointer.node as XRController3D
	if controller != null:
		var trigger := controller.get_float(&"trigger")
		if trigger > PRESS and not pointer.pressed:
			_press(pointer, true)
		elif trigger < RELEASE and pointer.pressed:
			_press(pointer, false)
		var stick := controller.get_vector2(&"primary").y
		pointer.scroll_wait -= delta
		if absf(stick) > 0.5 and pointer.scroll_wait <= 0.0:
			pointer.scroll_wait = SCROLL_INTERVAL
			_scroll(pointer, MOUSE_BUTTON_WHEEL_UP if stick > 0.0 else MOUSE_BUTTON_WHEEL_DOWN)


func _press(pointer: Pointer, pressed: bool) -> void:
	pointer.pressed = pressed
	if pointer.window == null:
		return
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = pressed
	event.button_mask = MOUSE_BUTTON_MASK_LEFT if pressed else 0
	event.position = pointer.position
	event.global_position = pointer.position
	pointer.window.push_input(event)


func _scroll(pointer: Pointer, button: MouseButton) -> void:
	if pointer.window == null:
		return
	for pressed in [true, false]:
		var event := InputEventMouseButton.new()
		event.button_index = button
		event.pressed = pressed
		event.position = pointer.position
		event.global_position = pointer.position
		pointer.window.push_input(event)


func _send_motion(window: Window, position: Vector2, pressed: bool) -> void:
	var event := InputEventMouseMotion.new()
	event.position = position
	event.global_position = position
	event.button_mask = MOUSE_BUTTON_MASK_LEFT if pressed else 0
	window.push_input(event)


## In the simulator, the mouse points and clicks; dragging with the right
## button looks around.
func _input(event: InputEvent) -> void:
	if not _simulated or _pointers.is_empty():
		return
	var pointer := _pointers[0]
	if event is InputEventMouseMotion and event.button_mask & MOUSE_BUTTON_MASK_RIGHT:
		_camera.rotation.y -= event.relative.x * LOOK_SPEED
		_camera.rotation.x = clampf(_camera.rotation.x - event.relative.y * LOOK_SPEED, -PI * 0.45, PI * 0.45)
	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		_press(pointer, event.pressed)
	elif event is InputEventMouseButton and event.pressed and event.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
		_scroll(pointer, event.button_index)
