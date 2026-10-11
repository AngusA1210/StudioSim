extends Node3D
## The room itself: a floor, ceiling and outer walls of whatever size it is set to, a light under the ceiling, and
## the walls standing inside it. Whatever depends on the room's shape asks here, and `changed` says when it moves.
##
## A wall is {a: Vector2, b: Vector2, height: float}: it runs between two points on the floor plan (x, z) and
## reaches half its thickness past each, so two walls drawn to the same point close the corner between them.

signal changed

const DEFAULT_SIZE := Vector3(14.0, 4.0, 10.0)  # width (x), height, length (z)
const MIN_SIZE := Vector3(4.0, 2.4, 4.0)
const MAX_SIZE := Vector3(40.0, 12.0, 40.0)
const SHELL_THICKNESS := 0.5
const WALL_THICKNESS := 0.3
const DEFAULT_WALL_HEIGHT := 3.0
const MIN_WALL_HEIGHT := 0.5
const MAX_WALLS := 16
const MIN_WALL_RUN := 0.5  # the least distance between a wall's two ends
const GRID := 0.25         # wall ends snap to this

const GRID_SHADER := """
shader_type spatial;
uniform vec3 base_color : source_color = vec3(0.1);
uniform float line_strength = 0.035;
varying vec3 world_pos;
varying vec3 world_normal;
void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	world_normal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}
void fragment() {
	vec3 n = abs(world_normal);
	vec2 p = n.y > 0.5 ? world_pos.xz : (n.x > 0.5 ? world_pos.zy : world_pos.xy);
	vec2 g = abs(fract(p - 0.5) - 0.5) / fwidth(p);
	float line = 1.0 - min(min(g.x, g.y), 1.0);
	ALBEDO = base_color + vec3(line * line_strength);
	ROUGHNESS = 0.92;
}
"""

var size := DEFAULT_SIZE
var walls: Array = []

var _shell: Node3D
var _wall_nodes: Node3D
var _shader: Shader


func setup() -> void:
	_shader = Shader.new()
	_shader.code = GRID_SHADER
	_shell = Node3D.new()
	add_child(_shell)
	_wall_nodes = Node3D.new()
	add_child(_wall_nodes)
	reset()


## Back to the room the game starts with.
func reset() -> void:
	size = DEFAULT_SIZE
	walls = [{"a": Vector2(-2.5, -3.25), "b": Vector2(-2.5, -0.55), "height": DEFAULT_WALL_HEIGHT}]
	_build_shell()
	_build_walls()
	changed.emit()


func set_size(new_size: Vector3) -> void:
	new_size = new_size.clamp(MIN_SIZE, MAX_SIZE)
	if new_size.is_equal_approx(size):
		return
	size = new_size
	# Walls that now poke through the sides are cut back; any left too short to be a wall go.
	var kept := []
	for wall in walls:
		wall.a = _on_floor(wall.a)
		wall.b = _on_floor(wall.b)
		if wall.a.distance_to(wall.b) >= MIN_WALL_RUN:
			kept.append(wall)
	walls = kept
	_build_shell()
	_build_walls()
	changed.emit()


## Adds a wall between two points on the floor plan. Returns its index, or -1 if it would be too short or there
## are already as many walls as the room takes.
func add_wall(a: Vector2, b: Vector2, height := DEFAULT_WALL_HEIGHT) -> int:
	a = _on_floor(a)
	b = _on_floor(b)
	if walls.size() >= MAX_WALLS or a.distance_to(b) < MIN_WALL_RUN:
		return -1
	walls.append({"a": a, "b": b, "height": clampf(height, MIN_WALL_HEIGHT, MAX_SIZE.y)})
	_build_walls()
	changed.emit()
	return walls.size() - 1


## Moves a wall's ends. Refused (false) if that would leave it too short.
func set_wall(index: int, a: Vector2, b: Vector2) -> bool:
	a = _on_floor(a)
	b = _on_floor(b)
	if index < 0 or index >= walls.size() or a.distance_to(b) < MIN_WALL_RUN:
		return false
	if a.is_equal_approx(walls[index].a) and b.is_equal_approx(walls[index].b):
		return true
	walls[index].a = a
	walls[index].b = b
	_build_walls()
	changed.emit()
	return true


func set_wall_height(index: int, height: float) -> void:
	if index < 0 or index >= walls.size():
		return
	walls[index].height = clampf(height, MIN_WALL_HEIGHT, MAX_SIZE.y)
	_build_walls()
	changed.emit()


func remove_wall(index: int) -> void:
	if index < 0 or index >= walls.size():
		return
	walls.remove_at(index)
	_build_walls()
	changed.emit()


## How tall a wall stands: its own height, or the ceiling if that is lower.
func wall_top(wall: Dictionary) -> float:
	return minf(wall.height, size.y)


## How long a wall is from end to end, including the half thickness it reaches past each point.
func wall_length(wall: Dictionary) -> float:
	return wall.a.distance_to(wall.b) + WALL_THICKNESS


## The walls as the audio core wants them.
func audio_walls() -> Array:
	var out := []
	for wall in walls:
		out.append({"a": wall.a, "b": wall.b, "thickness": WALL_THICKNESS, "height": wall_top(wall)})
	return out


static func snap(point: Vector2) -> Vector2:
	return (point / GRID).round() * GRID


## The nearest place to `point` that is `margin` clear of the room's sides, and below the ceiling.
func keep_inside(point: Vector3, margin: float) -> Vector3:
	var reach := Vector2(maxf(size.x / 2 - margin, 0.0), maxf(size.z / 2 - margin, 0.0))
	return Vector3(clampf(point.x, -reach.x, reach.x), minf(point.y, size.y - 0.3), clampf(point.z, -reach.y, reach.y))


## A place for something at `point`: inside the room by `side_margin`, and out of the walls by `wall_margin` on the
## side nearer to `toward`. In a corner too tight for both, being inside the room wins.
func settle(point: Vector3, side_margin: float, wall_margin: float, toward: Vector3) -> Vector3:
	return keep_inside(push_out_of_walls(keep_inside(point, side_margin), wall_margin, toward), side_margin)


## If `point` is inside a wall, or within `margin` of one, moves it out through the face nearer to `toward`
## (so something being carried stays on the carrier's side of the wall).
func push_out_of_walls(point: Vector3, margin: float, toward: Vector3) -> Vector3:
	for pass_number in 2:  # a second pass in case leaving one wall pushed it into another
		for wall in walls:
			if point.y > wall_top(wall) + margin:
				continue  # above it
			var centre: Vector2 = (wall.a + wall.b) / 2
			var along: Vector2 = (wall.b - wall.a).normalized()
			var across := Vector2(-along.y, along.x)
			var flat := Vector2(point.x, point.z) - centre
			var half_length: float = wall.a.distance_to(wall.b) / 2 + WALL_THICKNESS / 2 + margin
			var half_thickness := WALL_THICKNESS / 2 + margin
			if absf(flat.dot(along)) >= half_length or absf(flat.dot(across)) >= half_thickness:
				continue
			var side := (Vector2(toward.x, toward.z) - centre).dot(across)
			if absf(side) < 0.01:
				side = flat.dot(across)
			var moved: Vector2 = centre + along * flat.dot(along) + across * half_thickness * (1.0 if side >= 0.0 else -1.0)
			point = Vector3(moved.x, point.y, moved.y)
	return point


# ── Building ────────────────────────────────────────────────────────────────────────────────────────────────

func _on_floor(point: Vector2) -> Vector2:
	return Vector2(clampf(point.x, -size.x / 2, size.x / 2), clampf(point.y, -size.z / 2, size.z / 2))


func _build_shell() -> void:
	for child in _shell.get_children():
		child.queue_free()
	var w := size.x
	var h := size.y
	var d := size.z
	var t := SHELL_THICKNESS
	_block(_shell, Vector3(0, -t / 2, 0), Vector3(w + 2 * t, t, d + 2 * t), Color(0.05, 0.055, 0.07))  # floor
	_block(_shell, Vector3(0, h + t / 2, 0), Vector3(w + 2 * t, t, d + 2 * t), Color(0.035, 0.04, 0.05))  # ceiling
	_block(_shell, Vector3(-w / 2 - t / 2, h / 2, 0), Vector3(t, h, d), Color(0.06, 0.065, 0.085))
	_block(_shell, Vector3(w / 2 + t / 2, h / 2, 0), Vector3(t, h, d), Color(0.06, 0.065, 0.085))
	_block(_shell, Vector3(0, h / 2, -d / 2 - t / 2), Vector3(w, h, t), Color(0.06, 0.065, 0.085))
	_block(_shell, Vector3(0, h / 2, d / 2 + t / 2), Vector3(w, h, t), Color(0.06, 0.065, 0.085))
	var light := OmniLight3D.new()
	light.position = Vector3(0.0, h - 0.3, 0.0)
	light.light_color = Color(0.75, 0.8, 1.0)
	light.light_energy = 0.35
	light.omni_range = maxf(14.0, 0.81 * Vector2(w, d).length())
	_shell.add_child(light)


func _build_walls() -> void:
	for child in _wall_nodes.get_children():
		child.queue_free()
	for wall in walls:
		var top := wall_top(wall)
		var centre: Vector2 = (wall.a + wall.b) / 2
		var along: Vector2 = wall.b - wall.a
		# Sound has to bend round these, and the player has to walk round them.
		_block(_wall_nodes, Vector3(centre.x, top / 2, centre.y), Vector3(wall_length(wall), top, WALL_THICKNESS), Color(0.12, 0.13, 0.17),
			atan2(-along.y, along.x))


func _block(parent: Node3D, centre: Vector3, block_size: Vector3, color: Color, turn := 0.0) -> void:
	var body := StaticBody3D.new()
	body.position = centre
	body.rotation.y = turn
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = block_size
	shape.shape = box
	body.add_child(shape)
	var mesh := MeshInstance3D.new()
	var box_mesh := BoxMesh.new()
	box_mesh.size = block_size
	mesh.mesh = box_mesh
	var material := ShaderMaterial.new()
	material.shader = _shader
	material.set_shader_parameter("base_color", color)
	mesh.material_override = material
	body.add_child(mesh)
	parent.add_child(body)
