extends Camera3D
## Orbits its parent's origin, keeping a box of size [member region] in view.
## Drag to rotate; scroll or pinch to zoom.

const ROTATE_SPEED := 0.008
const ZOOM_STEP := 1.1
const ZOOM_RANGE := Vector2(0.2, 5.0)

## The size of the box to frame, in world units.
var region := Vector3.ONE
var yaw := 0.0
var pitch := 0.0
var zoom := 1.0


func _ready() -> void:
	# A volume's world has no environment or lights of its own; RealityKit
	# lights it on visionOS.
	environment = Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color(0.12, 0.12, 0.13)
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color(0.5, 0.5, 0.5)
	var light := DirectionalLight3D.new()
	light.rotation = Vector3(deg_to_rad(-30.0), deg_to_rad(-20.0), 0.0)
	add_child(light)
	make_current()


func _process(_delta: float) -> void:
	# Fit the box's largest face within the narrower field of view, as a
	# volume shows it from the front; the box's corners may leave the view
	# as it turns.
	var viewport := Vector2(get_viewport().get_visible_rect().size)
	var half_fov := atan(tan(deg_to_rad(fov) * 0.5) * minf(1.0, viewport.x / viewport.y))
	var radius := region.length() * 0.5
	var half := region[region.max_axis_index()] * 0.5
	var distance := (half / tan(half_fov) + half) * zoom
	var orbit := Basis.from_euler(Vector3(pitch, yaw, 0.0))
	transform = Transform3D(orbit, orbit * Vector3(0.0, 0.0, distance))
	near = maxf(distance - radius, distance * 0.01) * 0.5
	far = (distance + radius) * 2.0


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and event.button_mask & (MOUSE_BUTTON_MASK_LEFT | MOUSE_BUTTON_MASK_RIGHT):
		yaw -= event.relative.x * ROTATE_SPEED
		pitch = clampf(pitch - event.relative.y * ROTATE_SPEED, -PI * 0.49, PI * 0.49)
	elif event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			_zoom_by(1.0 / ZOOM_STEP)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_zoom_by(ZOOM_STEP)
	elif event is InputEventMagnifyGesture:
		_zoom_by(1.0 / event.factor)
	elif event is InputEventPanGesture:
		_zoom_by(pow(ZOOM_STEP, event.delta.y))
	else:
		return
	get_viewport().set_input_as_handled()


func _zoom_by(factor: float) -> void:
	zoom = clampf(zoom * factor, ZOOM_RANGE.x, ZOOM_RANGE.y)
