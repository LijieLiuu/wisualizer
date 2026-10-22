extends RefCounted
## Where a window goes relative to the window it is placed by, following
## [member Window.placement] and the ornament properties. Shared by the
## desktop and XR layouts, so both read the same properties the same way
## visionOS does.
##
## Boxes are in a target's own unit frame: x from leading to trailing, y from
## top to bottom, z from back to front, as SwiftUI's UnitPoint3D.

## Space between a placed window and its target, in meters.
const GAP := 0.02


## The window [param window]'s placement refers to.
static func target_of(window: Window) -> Window:
	var path := window.placement_target
	if not path.is_empty():
		var target := window.get_node_or_null(path) as Window
		if target != null:
			return target
	var parent := window.get_parent()
	return parent.get_window() if parent != null else null


## The ornament's center, relative to its target's top leading back corner,
## for a target of [param target_size] and an ornament of [param own_size].
static func ornament_center(window: Window, target_size: Vector3, own_size: Vector3) -> Vector3:
	var anchor := window.ornament_anchor
	var align := _alignment_point(window.ornament_alignment, anchor)
	var center := anchor * target_size
	center.x -= (align.x - 0.5) * own_size.x
	center.y -= (align.y - 0.5) * own_size.y
	return center


## Which point of the ornament lies on the anchor, in the ornament's unit
## frame. Automatic keeps the ornament outside the edge its anchor is on.
static func _alignment_point(alignment: Window.OrnamentAlignment, anchor: Vector3) -> Vector2:
	if alignment == Window.ORNAMENT_ALIGNMENT_AUTOMATIC:
		return Vector2(_outside(anchor.x), _outside(anchor.y))
	var index := int(alignment) - 1
	return Vector2(index % 3, floori(index / 3.0)) * 0.5


static func _outside(edge: float) -> float:
	if is_zero_approx(edge):
		return 1.0
	if is_equal_approx(edge, 1.0):
		return 0.0
	return 0.5


## For placements beside a target: the direction to move in, in the target's
## unit frame (y down), or zero for placements that don't go beside it.
static func side(placement: Window.Placement) -> Vector2:
	match placement:
		Window.PLACEMENT_LEADING:
			return Vector2.LEFT
		Window.PLACEMENT_TRAILING:
			return Vector2.RIGHT
		Window.PLACEMENT_ABOVE:
			return Vector2.UP
		Window.PLACEMENT_BELOW, Window.PLACEMENT_UTILITY_PANEL:
			return Vector2.DOWN
	return Vector2.ZERO
