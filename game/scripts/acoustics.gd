extends RefCounted
## Works out how an instrument's sound reaches the listener when box-shaped walls are in the way:
## which edge it bends around, how much longer that route is, and how narrowly a clear line of sight misses an edge.
## The audio core turns those lengths into how dull the sound gets (see acoustics.h).

const SHRINK := 0.01  # ignore grazing contact with a wall's surface


## Returns {via: Vector3, extra: float, deltas: PackedFloat32Array, blocked: bool}, the arguments for
## SoundRoomAudio.set_source_direct_path.
static func direct_path(ear: Vector3, source: Vector3, walls: Array, ceiling: float) -> Dictionary:
	var direct := ear.distance_to(source)
	for wall: AABB in walls:
		if wall.intersects_segment(ear, source) != null:
			return _around(ear, source, wall, ceiling, direct)
	var nearest := 100.0
	for wall: AABB in walls:
		nearest = minf(nearest, _clearance(ear, source, wall, direct))
	return {"via": source, "extra": 0.0, "deltas": PackedFloat32Array([-nearest]), "blocked": false}


## The line of sight is blocked: find the routes around either side of the wall and over its top.
static func _around(ear: Vector3, source: Vector3, wall: AABB, ceiling: float, direct: float) -> Dictionary:
	var lo := Vector2(wall.position.x, wall.position.z)
	var hi := Vector2(wall.end.x, wall.end.z)
	var top := wall.end.y
	var corners := [Vector2(lo.x, lo.y), Vector2(hi.x, lo.y), Vector2(hi.x, hi.y), Vector2(lo.x, hi.y)]
	var a := Vector2(ear.x, ear.z)
	var b := Vector2(source.x, source.z)
	var rise := source.y - ear.y
	var centre := (lo + hi) / 2

	# A route passes one corner, or two neighbouring ones (around the end of a thin wall).
	var routes := []
	for i in 4:
		var next: Vector2 = corners[(i + 1) % 4]
		routes.append([corners[i]])
		routes.append([corners[i], next])
		routes.append([next, corners[i]])
	var best := {}  # which side of the wall → shortest route that way
	for route: Array in routes:
		var first: Vector2 = route[0]
		var last: Vector2 = route[-1]
		if _crosses(a, first, lo, hi) or _crosses(last, b, lo, hi):
			continue
		var flat := a.distance_to(first) + first.distance_to(last) + last.distance_to(b)
		var length := sqrt(flat * flat + rise * rise)
		# Which way round the wall this route goes (the angle it sweeps about the wall's centre), so that two
		# routes hugging the same end count as one.
		var side := signf((a - centre).angle_to(first - centre) + (first - centre).angle_to(last - centre) \
				+ (last - centre).angle_to(b - centre))
		if not best.has(side) or length < best[side].length:
			var height := ear.y + rise * a.distance_to(first) / maxf(flat, 0.001)
			best[side] = {"length": length, "via": Vector3(first.x, height, first.y)}
	var paths: Array = best.values()

	if top < ceiling - 0.05:
		var span := _span(a, b, lo, hi)
		if span.size() == 2:
			var enter := a.lerp(b, span[0])
			var leave := a.lerp(b, span[1])
			var length := Vector2(a.distance_to(enter), top - ear.y).length() + enter.distance_to(leave) \
					+ Vector2(leave.distance_to(b), top - source.y).length()
			paths.append({"length": length, "via": Vector3(enter.x, top, enter.y)})

	if paths.is_empty():  # sealed in: only what leaks through the wall
		return {"via": source, "extra": 0.0, "deltas": PackedFloat32Array([10.0]), "blocked": true}
	paths.sort_custom(func(x, y): return x.length < y.length)
	var deltas := PackedFloat32Array()
	for path in paths.slice(0, 3):
		deltas.append(path.length - direct)
	var shortest: Dictionary = paths[0]
	var via: Vector3 = shortest.via
	return {"via": via, "extra": maxf(shortest.length - ear.distance_to(via), 0.0), "deltas": deltas, "blocked": true}


## The line of sight is clear: how much longer would the route via this wall's nearest edge be?
## Small values mean the sound only just clears the edge, where it already starts to dim.
static func _clearance(ear: Vector3, source: Vector3, wall: AABB, direct: float) -> float:
	var lo := Vector2(wall.position.x, wall.position.z)
	var hi := Vector2(wall.end.x, wall.end.z)
	var a := Vector2(ear.x, ear.z)
	var b := Vector2(source.x, source.z)
	var rise := source.y - ear.y
	var nearest := 100.0
	for corner: Vector2 in [Vector2(lo.x, lo.y), Vector2(hi.x, lo.y), Vector2(hi.x, hi.y), Vector2(lo.x, hi.y)]:
		var flat := a.distance_to(corner) + corner.distance_to(b)
		nearest = minf(nearest, sqrt(flat * flat + rise * rise) - direct)
	var span := _span(a, b, lo, hi)
	if span.size() == 2:  # the line of sight passes over the top of the wall
		var top := wall.end.y
		var enter := a.lerp(b, span[0])
		var leave := a.lerp(b, span[1])
		var over := Vector2(a.distance_to(enter), top - ear.y).length() + enter.distance_to(leave) \
				+ Vector2(leave.distance_to(b), top - source.y).length()
		nearest = minf(nearest, over - direct)
	return maxf(nearest, 0.0)


## Where the flat segment p→q is inside the rectangle, as [enter, leave] fractions along it; empty if it misses.
static func _span(p: Vector2, q: Vector2, lo: Vector2, hi: Vector2) -> Array:
	var t0 := 0.0
	var t1 := 1.0
	var d := q - p
	for axis in 2:
		if absf(d[axis]) < 1e-9:
			if p[axis] <= lo[axis] or p[axis] >= hi[axis]:
				return []
		else:
			var ta: float = (lo[axis] - p[axis]) / d[axis]
			var tb: float = (hi[axis] - p[axis]) / d[axis]
			t0 = maxf(t0, minf(ta, tb))
			t1 = minf(t1, maxf(ta, tb))
			if t0 >= t1:
				return []
	return [t0, t1]


static func _crosses(p: Vector2, q: Vector2, lo: Vector2, hi: Vector2) -> bool:
	return _span(p, q, lo + Vector2(SHRINK, SHRINK), hi - Vector2(SHRINK, SHRINK)).size() == 2
