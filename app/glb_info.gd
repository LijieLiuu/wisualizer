extends RefCounted
## What the workspace needs to know about a GLB, read from its JSON chunk
## without decoding its meshes: how many scenes it has, the solver time
## EnSight writes on a scene, and the bounds of its meshes.

const TIME_EXTENSION := "ANSYS_scene_timevalue"


## A GLB's JSON chunk, or an empty dictionary if the bytes aren't a GLB.
static func json(bytes: PackedByteArray) -> Dictionary:
	if bytes.size() < 20 or bytes.decode_u32(0) != 0x46546C67:
		return {}
	var length := bytes.decode_u32(12)
	var parsed = JSON.parse_string(bytes.slice(20, 20 + length).get_string_from_utf8())
	return parsed if parsed is Dictionary else {}


static func scene_count(json: Dictionary) -> int:
	return json.get("scenes", []).size()


## The solver time of a GLB's first scene, or NAN without one.
static func time(json: Dictionary) -> float:
	var scenes: Array = json.get("scenes", [])
	if scenes.is_empty():
		return NAN
	return float(scenes[0].get("extensions", {}).get(TIME_EXTENSION, {}).get("timevalue", NAN))


## The bounds of a GLB's meshes, from the extents glTF records for each
## mesh's positions, through the node transforms. Empty without meshes.
static func bounds(json: Dictionary) -> AABB:
	var nodes: Array = json.get("nodes", [])
	var box := AABB()
	for scene: Dictionary in json.get("scenes", []):
		for root in scene.get("nodes", []):
			box = merge(box, _node_bounds(json, nodes, int(root), Transform3D()))
	return box


## [param a] and [param b] together, where an empty box is none.
static func merge(a: AABB, b: AABB) -> AABB:
	if a.size == Vector3.ZERO:
		return b
	if b.size == Vector3.ZERO:
		return a
	return a.merge(b)


static func _node_bounds(json: Dictionary, nodes: Array, index: int, parent: Transform3D) -> AABB:
	var node: Dictionary = nodes[index]
	var transform := parent * _node_transform(node)
	var box := AABB()
	if node.has("mesh"):
		for primitive: Dictionary in json.get("meshes", [])[int(node["mesh"])].get("primitives", []):
			var accessor: Dictionary = json.get("accessors", [])[int(primitive.get("attributes", {}).get("POSITION", 0))]
			if accessor.has("min") and accessor.has("max"):
				var low := Vector3(accessor["min"][0], accessor["min"][1], accessor["min"][2])
				var high := Vector3(accessor["max"][0], accessor["max"][1], accessor["max"][2])
				box = merge(box, transform * AABB(low, high - low))
	for child in node.get("children", []):
		box = merge(box, _node_bounds(json, nodes, int(child), transform))
	return box


static func _node_transform(node: Dictionary) -> Transform3D:
	if node.has("matrix"):
		var m: Array = node["matrix"]
		return Transform3D(Vector3(m[0], m[1], m[2]), Vector3(m[4], m[5], m[6]), Vector3(m[8], m[9], m[10]), Vector3(m[12], m[13], m[14]))
	var t: Array = node.get("translation", [0, 0, 0])
	var r: Array = node.get("rotation", [0, 0, 0, 1])
	var s: Array = node.get("scale", [1, 1, 1])
	return Transform3D(Basis(Quaternion(r[0], r[1], r[2], r[3])).scaled(Vector3(s[0], s[1], s[2])), Vector3(t[0], t[1], t[2]))
