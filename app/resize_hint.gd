extends Node3D
## Corner marks on the bottom of the volume, where visionOS puts its resize
## handles: shown for a while when the volume opens, then bouncing outward a
## few times, to show the person the volume can be resized. Each mark has a
## rounded corner, like visionOS windows.
## Lives under the volume, so it sits on the box the volume shows.

## Seconds the marks stay still before they bounce.
const HOLD_TIME := 3.0
const BOUNCES := 3
const BOUNCE_TIME := 0.7
## How far the marks bounce out, as a fraction of the box. They rest this
## far inside the box and bounce out to its edge: a volume clips anything
## beyond its bounds.
const SPREAD := 0.05
## Arm length and thickness, as fractions of the box's smallest and largest
## side; the corner's radius, as a fraction of the arm.
const ARM := 0.12
const THICKNESS := 0.006
const RADIUS := 0.45
const ARC_STEPS := 8
## The four corners of the bottom face, as (x, z) signs.
const CORNERS: Array[Vector2] = [Vector2(-1, -1), Vector2(1, -1), Vector2(-1, 1), Vector2(1, 1)]

var _marks: Array[MeshInstance3D] = []
var _region := Vector3.ONE
var _thickness := 0.0
var _tween: Tween
var _spread := 0.0:
	set(value):
		_spread = value
		_place()


func _ready() -> void:
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = Color(1, 1, 1)
	# Mirrored marks turn their faces inside out.
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	for corner in CORNERS:
		var mark := MeshInstance3D.new()
		mark.material_override = material
		# The mesh is built for the (-x, -z) corner, with arms along +x and +z.
		mark.scale = Vector3(-corner.x, 1, -corner.y)
		add_child(mark)
		_marks.append(mark)
	visible = false


## Shows the marks on a box of [param region] world units, centered here.
func play(region: Vector3) -> void:
	_region = region
	_thickness = region[region.max_axis_index()] * THICKNESS
	var mesh := _corner_mesh(region[region.min_axis_index()] * ARM, _thickness)
	for mark in _marks:
		mark.mesh = mesh
	_spread = 0.0
	visible = true
	if _tween:
		_tween.kill()
	_tween = create_tween()
	_tween.tween_interval(HOLD_TIME)
	for i in BOUNCES:
		_tween.tween_property(self, "_spread", SPREAD, BOUNCE_TIME).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
		_tween.tween_property(self, "_spread", 0.0, BOUNCE_TIME).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN)
	_tween.tween_callback(hide)


func _place() -> void:
	# Keep the whole mark, including its thickness, inside the box.
	var half := _region * (0.5 - SPREAD + _spread) - Vector3.ONE * _thickness * 0.5
	for i in _marks.size():
		var corner := CORNERS[i]
		_marks[i].position = Vector3(corner.x * half.x, (_thickness - _region.y) * 0.5, corner.y * half.z)


## A square tube along two arms of length [param arm] joined by a rounded
## corner, lying flat with the corner at the origin.
static func _corner_mesh(arm: float, thickness: float) -> ArrayMesh:
	var radius := arm * RADIUS
	var path := PackedVector2Array([Vector2(arm, 0)])
	for step in ARC_STEPS + 1:
		var angle := PI * 1.5 - step * PI * 0.5 / ARC_STEPS
		path.append(Vector2(radius, radius) + Vector2(cos(angle), sin(angle)) * radius)
	path.append(Vector2(0, arm))

	var tool := SurfaceTool.new()
	tool.begin(Mesh.PRIMITIVE_TRIANGLES)
	var h := thickness * 0.5
	for i in path.size() - 1:
		var a := path[i]
		var b := path[i + 1]
		var side := (b - a).orthogonal().normalized() * h
		var a_out := Vector3(a.x + side.x, 0, a.y + side.y)
		var b_out := Vector3(b.x + side.x, 0, b.y + side.y)
		var a_in := Vector3(a.x - side.x, 0, a.y - side.y)
		var b_in := Vector3(b.x - side.x, 0, b.y - side.y)
		var up := Vector3(0, h, 0)
		_quad(tool, a_out + up, b_out + up, b_in + up, a_in + up)
		_quad(tool, a_out - up, b_out - up, b_in - up, a_in - up)
		_quad(tool, a_out + up, b_out + up, b_out - up, a_out - up)
		_quad(tool, a_in + up, b_in + up, b_in - up, a_in - up)
	return tool.commit()


static func _quad(tool: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3) -> void:
	for vertex in [a, b, c, a, c, d]:
		tool.add_vertex(vertex)
