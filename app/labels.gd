extends Node3D
## The ZIP's labels: a dot at each label's point, and the label's text over
## it while a controller's tip is near the point or, on a desktop, while the
## pointer is over the dot. On visionOS, tapping a dot selects its text;
## tapping it again hides it. Only the current frame's labels show, and
## nothing does while hidden.
##
## Lives beside the Window's content, with no transform of its own, so its
## local coordinates are the model's.

const Meta := preload("res://app/meta.gd")
## The dot's diameter, the text's size and its gap above the dot: in
## meters in a volume as it opens, growing and shrinking with the model as
## the volume is resized, and in pixels on a desktop.
const DOT_SIZE := 0.012
const TEXT_HEIGHT := 0.05
const TEXT_GAP := 0.008
const DOT_PIXELS := 14.0
const TEXT_PIXELS := 17.0
const GAP_PIXELS := 6.0
const FONT_SIZE := 48
## The dot's texture: white, with a dark rim that shows on white models.
const DOT_TEXTURE_SIZE := 64
const DOT_RIM := 0.2
## Text wider than this wraps, in the label's pixels.
const TEXT_WIDTH := 640.0
## How near a controller's tip comes to a label without a radius for its
## text to show, in meters.
const DEFAULT_REACH := 0.03
## Text that shows stays until the tip is this many times as far, so it
## doesn't flicker at the edge.
const LEAVE := 1.25
## How near the desktop pointer comes to a dot, in pixels.
const HOVER_DISTANCE := 24.0
## A 4 cm diameter target is easier to click than the 12 mm dot.
const TAP_RADIUS := 0.02

## Finds each controller's tip, as for haptics.
var touch: Node
var volume: SpatialVolume3D
var frame := 0

var _labels: Array[Meta.PointLabel] = []
## Per label: its dot and its text.
var _dots: Array[Sprite3D] = []
var _texts: Array[Label3D] = []
## How tall each label's text is, in the label's pixels.
var _text_heights := PackedFloat32Array()
## Per controller: the label whose text it shows, or -1.
var _held := {}
var _pointer_inside := false
var _selected := -1
var _targets: Array[Area3D] = []
## Every target has the same physical radius; share its collision resource.
var _target_shape := SphereShape3D.new()


func _ready() -> void:
	var window := get_window()
	window.mouse_entered.connect(func() -> void: _pointer_inside = true)
	window.mouse_exited.connect(func() -> void: _pointer_inside = false)
	visibility_changed.connect(_on_visibility_changed)


func _on_visibility_changed() -> void:
	if is_visible_in_tree():
		return
	_selected = -1
	_held.clear()
	for text in _texts:
		text.hide()
	for target in _targets:
		target.input_ray_pickable = false


func set_labels(labels: Array[Meta.PointLabel]) -> void:
	_selected = -1
	_held.clear()
	for child in get_children():
		remove_child(child)
		child.queue_free()
	_dots.clear()
	_texts.clear()
	_targets.clear()
	_text_heights.clear()
	_labels = labels
	var dot_texture := _dot_texture()
	var spatial_input := SpatialPlatform.current() == SpatialPlatform.Kind.VISIONOS
	if spatial_input and volume != null:
		_update_target_size(_meters_per_unit())
	for label in labels:
		var dot := Sprite3D.new()
		dot.texture = dot_texture
		dot.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		# A point inside the model still shows, over it, with its text above.
		dot.no_depth_test = true
		dot.render_priority = RenderingServer.MATERIAL_RENDER_PRIORITY_MAX - 2
		dot.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR
		dot.position = label.position
		add_child(dot)
		_dots.append(dot)
		# RealityKit sends spatial clicks to collision objects, not sprites.
		if spatial_input:
			var target := Area3D.new()
			target.position = label.position
			target.collision_mask = 0
			target.monitoring = false
			target.monitorable = false
			target.visible = label.shows_at(frame)
			target.input_ray_pickable = target.visible and is_visible_in_tree()
			target.input_event.connect(_on_label_input.bind(_dots.size() - 1))
			var shape := CollisionShape3D.new()
			shape.shape = _target_shape
			target.add_child(shape)
			add_child(target)
			_targets.append(target)
		var text := Label3D.new()
		text.text = label.text
		text.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		text.no_depth_test = true
		# Over the model's transparent parts, which draw at the default priority.
		text.render_priority = RenderingServer.MATERIAL_RENDER_PRIORITY_MAX
		text.outline_render_priority = RenderingServer.MATERIAL_RENDER_PRIORITY_MAX - 1
		text.font_size = FONT_SIZE
		text.outline_size = 12
		text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		text.width = TEXT_WIDTH
		text.visible = false
		add_child(text)
		_texts.append(text)
		_text_heights.append(ThemeDB.fallback_font.get_multiline_string_size(label.text, HORIZONTAL_ALIGNMENT_CENTER, TEXT_WIDTH, FONT_SIZE).y)


func _process(_delta: float) -> void:
	if not is_visible_in_tree() or volume == null or _labels.is_empty():
		return
	var meters_per_unit := _meters_per_unit()
	if not _targets.is_empty():
		_update_target_size(meters_per_unit)
	var camera := get_viewport().get_camera_3d() if SpatialPlatform.current() == SpatialPlatform.Kind.DESKTOP else null
	var shown := {}
	for controller in volume.get_controllers():
		var index := -1
		if controller.get_has_tracking_data():
			index = nearest(to_local(touch.tip_of(controller)), _held.get(controller, -1), meters_per_unit)
		_held[controller] = index
		shown[index] = true
	shown[_hovered()] = true
	if _selected >= 0:
		if _labels[_selected].shows_at(frame):
			shown[_selected] = true
		else:
			_selected = -1
	# Dots and text scale with the model, from their size as the volume
	# opens; reach and taps keep their physical size, for the hand.
	var drawn_per_unit := _opening_meters_per_unit()
	for index in _labels.size():
		var label := _labels[index]
		var dot := _dots[index]
		dot.visible = label.shows_at(frame)
		var dot_size := _units(label.position, DOT_SIZE, DOT_PIXELS, drawn_per_unit, camera)
		dot.pixel_size = dot_size / DOT_TEXTURE_SIZE
		if index < _targets.size():
			var target := _targets[index]
			target.visible = dot.visible
			target.input_ray_pickable = dot.visible
		var text := _texts[index]
		text.visible = dot.visible and shown.has(index)
		if text.visible:
			text.pixel_size = _units(label.position, TEXT_HEIGHT, TEXT_PIXELS, drawn_per_unit, camera) / FONT_SIZE
			var offset := Vector3.UP * (dot_size * 0.5 + _units(label.position, TEXT_GAP, GAP_PIXELS, drawn_per_unit, camera))
			# Above the dot, or below it where the top of the volume, which
			# hides what's outside it, leaves no room.
			# The model's turntable rotates Labels, but "above" and clipping
			# are relative to the volume that contains it.
			var point := volume.to_local(to_global(label.position))
			var top := volume.get_region_size().y * 0.5
			var fits := point.y + offset.y + _text_heights[index] * text.pixel_size <= top
			text.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM if fits else VERTICAL_ALIGNMENT_TOP
			text.position = to_local(volume.to_global(point + (offset if fits else -offset)))


func _update_target_size(meters_per_unit: float) -> void:
	var radius := TAP_RADIUS / meters_per_unit
	# Setting an unchanged radius still rebuilds the physics shape and emits
	# Resource.changed, which makes RealityKit recreate its collision shape.
	if not is_equal_approx(_target_shape.radius, radius):
		_target_shape.radius = radius


func _on_label_input(_camera: Node, event: InputEvent, _position: Vector3, _normal: Vector3, _shape: int, index: int) -> void:
	if not is_visible_in_tree() or not _labels[index].shows_at(frame):
		return
	if event is InputEventScreenTouch:
		if not event.pressed or event.canceled:
			return
	elif event is InputEventMouseButton:
		if not event.pressed or event.canceled or event.button_index != MOUSE_BUTTON_LEFT:
			return
	else:
		return
	_selected = -1 if _selected == index else index


## The model's grab bounds can receive a tap in front of a visible label.
## Resolve that tap against the labels before starting a model drag.
func select_from_spatial_touch(camera: Node, event: InputEvent) -> bool:
	if not is_visible_in_tree() or volume == null or not event.is_class("InputEventSpatialTouch"):
		return false
	if not event.get("pressed") or event.get("canceled"):
		return false
	var origin: Vector3
	var direction: Vector3
	# Use the same camera projection the bridge uses for event.position.
	# This also works for simulator mouse events without a selection ray.
	if camera != null and camera.has_method("project_ray_origin") and camera.has_method("project_ray_normal"):
		origin = camera.project_ray_origin(event.get("position"))
		direction = camera.project_ray_normal(event.get("position"))
	elif event.get("has_selection_ray"):
		origin = event.get("selection_ray_origin")
		direction = event.get("selection_ray_direction")
	else:
		return false
	var index := _label_along_ray(origin, direction)
	if index < 0:
		return false
	_selected = -1 if _selected == index else index
	return true


## Nearest current-frame target intersected by a world-space ray. Work in
## label coordinates so the targets follow the model's turntable.
func _label_along_ray(origin: Vector3, direction: Vector3) -> int:
	var local_direction := (global_basis.inverse() * direction).normalized()
	if local_direction.is_zero_approx():
		return -1
	var local_origin := to_local(origin)
	var radius := TAP_RADIUS / _meters_per_unit()
	var found := -1
	var nearest_distance := INF
	for index in _labels.size():
		if not _labels[index].shows_at(frame):
			continue
		var offset := _labels[index].position - local_origin
		var along := offset.dot(local_direction)
		var perpendicular := offset.length_squared() - along * along
		var remainder := radius * radius - perpendicular
		if remainder < 0.0:
			continue
		var half_chord := sqrt(remainder)
		if along + half_chord < 0.0:
			continue
		var distance := maxf(along - half_chord, 0.0)
		if distance < nearest_distance:
			found = index
			nearest_distance = distance
	return found


## The label at the current frame nearest [param point], in model units,
## among those whose reach it is within, or -1. [param current], the label
## already shown, reaches [constant LEAVE] times as far.
func nearest(point: Vector3, current: int, meters_per_unit: float) -> int:
	var found := -1
	var found_distance := INF
	for index in _labels.size():
		var label := _labels[index]
		if not label.shows_at(frame):
			continue
		var reach := label.radius if label.radius > 0.0 else DEFAULT_REACH / meters_per_unit
		if index == current:
			reach *= LEAVE
		var distance := point.distance_to(label.position)
		if distance <= reach and distance < found_distance:
			found = index
			found_distance = distance
	return found


## On a desktop, the label whose dot the pointer is over, or -1.
func _hovered() -> int:
	if not _pointer_inside or SpatialPlatform.current() != SpatialPlatform.Kind.DESKTOP:
		return -1
	var camera := get_viewport().get_camera_3d()
	if camera == null:
		return -1
	var pointer := get_viewport().get_mouse_position()
	var found := -1
	var found_distance := HOVER_DISTANCE
	for index in _labels.size():
		var point := _dots[index].global_position
		if not _labels[index].shows_at(frame) or camera.is_position_behind(point):
			continue
		var distance := pointer.distance_to(camera.unproject_position(point))
		if distance <= found_distance:
			found = index
			found_distance = distance
	return found


## How many model units at [param point] are [param meters] in a volume,
## or [param pixels] on the screen of a desktop, which views it through
## [param camera].
func _units(point: Vector3, meters: float, pixels: float, meters_per_unit: float, camera: Camera3D) -> float:
	if camera == null:
		return meters / meters_per_unit
	var depth := -(camera.global_transform.affine_inverse() * to_global(point)).z
	return pixels * 2.0 * depth * tan(deg_to_rad(camera.fov) * 0.5) / get_viewport().get_visible_rect().size.y


func _meters_per_unit() -> float:
	var physical := volume.get_measured_size()
	# Before the platform reports the size, use the size the volume opens at.
	if physical == Vector3.ZERO:
		physical = volume.window_size
	return physical[volume.keep_aspect] / volume.size


## Meters per model unit at the size the volume opens at.
func _opening_meters_per_unit() -> float:
	return volume.window_size[volume.keep_aspect] / volume.size


static func _dot_texture() -> ImageTexture:
	var image := Image.create_empty(DOT_TEXTURE_SIZE, DOT_TEXTURE_SIZE, false, Image.FORMAT_RGBA8)
	var radius := DOT_TEXTURE_SIZE * 0.5
	for y in DOT_TEXTURE_SIZE:
		for x in DOT_TEXTURE_SIZE:
			var distance := Vector2(x + 0.5, y + 0.5).distance_to(Vector2(radius, radius))
			# Edges a pixel wide, so the dot stays round when small.
			var fill := clampf(radius * (1.0 - DOT_RIM) - distance, 0.0, 1.0)
			var color := Color(0.1, 0.1, 0.1).lerp(Color.WHITE, fill)
			color.a = clampf(radius - distance, 0.0, 1.0)
			image.set_pixel(x, y, color)
	return ImageTexture.create_from_image(image)
