extends Node
## Desktop layout: windows stay ordinary OS windows. A window placed beside
## another opens next to it, and ornaments become borderless windows that
## follow the window they belong to.

const Placement := preload("../placement.gd")
## visionOS points per meter, as used for the gap between windows.
const POINTS_PER_METER := 1360.0

var _ornaments: Array[Window] = []
## Screen pixels per window pixel: windows are sized for the main window's
## content scale, which may differ from this screen's.
var _scale := 1.0


func _ready() -> void:
	var root := get_tree().root
	_scale = DisplayServer.screen_get_scale(root.current_screen) / root.content_scale_factor
	if not is_equal_approx(_scale, 1.0):
		# The main window's content stretches with it.
		root.size = Vector2i(Vector2(root.size) * _scale)


## Called for each new window, after it takes the main window's content scale.
func add_window(window: Window) -> void:
	# The OS places popups.
	if window is Popup:
		return
	if not is_equal_approx(_scale, 1.0):
		window.size = Vector2i(Vector2(window.size) * _scale)
		window.content_scale_factor *= _scale
	if window.placement == Window.PLACEMENT_ORNAMENT:
		window.transient = true
		window.borderless = true
		window.unresizable = true
		_ornaments.append(window)
		window.tree_exiting.connect(_ornaments.erase.bind(window))
	elif Placement.side(window.placement) != Vector2.ZERO:
		window.visibility_changed.connect(_place_beside.bind(window), CONNECT_ONE_SHOT)


func _process(_delta: float) -> void:
	for ornament in _ornaments:
		if ornament.visible:
			_place_ornament(ornament)


func _place_beside(window: Window) -> void:
	var target := Placement.target_of(window)
	if target == null:
		return
	var gap := _gap(target)
	var side := Placement.side(window.placement)
	var center := Vector2(target.position) + Vector2(target.size) * 0.5
	center += side * ((Vector2(target.size) + Vector2(window.size)) * 0.5 + Vector2(gap, gap))
	var rect := Rect2(center - Vector2(window.size) * 0.5, window.size)
	# Stay on the target's screen, overlapping it if there's no room beside it.
	var screen := Rect2(DisplayServer.screen_get_usable_rect(target.current_screen))
	rect.position = rect.position.clamp(screen.position, screen.end - rect.size)
	window.position = Vector2i(rect.position)


func _place_ornament(ornament: Window) -> void:
	var target := Placement.target_of(ornament)
	if target == null:
		return
	var target_size := Vector3(target.size.x, target.size.y, 0.0)
	var own_size := Vector3(ornament.size.x, ornament.size.y, 0.0)
	var center := Placement.ornament_center(ornament, target_size, own_size)
	# Ornaments outside the window keep a gap from it, as on visionOS.
	if ornament.ornament_alignment == Window.ORNAMENT_ALIGNMENT_AUTOMATIC:
		var outward := Vector2(ornament.ornament_anchor.x, ornament.ornament_anchor.y) * 2.0 - Vector2.ONE
		outward = outward.snapped(Vector2.ONE) * _gap(target)
		center += Vector3(outward.x, outward.y, 0.0)
	var position := Vector2i(Vector2(target.position) + Vector2(center.x, center.y) - Vector2(ornament.size) * 0.5)
	if ornament.position != position:
		ornament.position = position


func _gap(window: Window) -> float:
	return Placement.GAP * POINTS_PER_METER * DisplayServer.screen_get_scale(window.current_screen)
