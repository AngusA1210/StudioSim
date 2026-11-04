extends Node3D
## The room itself: a floor, ceiling and outer walls of whatever size it is set to, a light under the ceiling, and
## the walls standing inside it. Whatever depends on the room's shape asks here, and `changed` says when it moves.
##
## A wall is {a: Vector2, b: Vector2, height: float, material: String}: it runs between two points on the floor plan
## (x, z) and reaches half its thickness past each, so two walls drawn to the same point close the corner between them.
## Each of the room's own surfaces (its floor, its ceiling, its four walls) is made of a material, and so is each wall
## standing in it: what it absorbs sets how long and how brightly the room rings, what it sends back is what the
## microphones hear off it, and what passes through a wall standing in the room is what is heard behind it.

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
const LIGHT_SPACING := 7.0
const LIGHT_RANGE := 12.0
const LIGHT_ENERGY := 0.3
## The 3D layer the walls standing in the room are drawn on as well as the first: the instruments' lights take their
## shadows from it alone, so that a wall stops an instrument's light (as it does its sound), and nothing else need be
## drawn into their shadows. Glass isn't on it: light goes through glass.
const SHADOW_LAYER := 18

const Surfaces := preload("res://scripts/room_surfaces.gd")

var size := DEFAULT_SIZE
var walls: Array = []
var brightness := 1.0  # of the room's own lights
## The materials, as the audio core has them (materials.h): [name, what it does to sound, its colour, where it can go:
## "walls" (the room's own and those standing in it), "floor", "ceiling"].
const MATERIALS := {
	"drywall": ["Drywall", "Gypsum board on studs: it gives a little in the lows and sends the rest back. Standing in the room, it lets some sound through, the lows most.",
		Color(0.07, 0.075, 0.095), ["walls", "ceiling"]],
	"plaster": ["Plaster", "Plaster on masonry: hard and heavy, it sends nearly everything back, and next to nothing gets through it.",
		Color(0.16, 0.15, 0.14), ["walls", "ceiling"]],
	"brick": ["Brick", "Bare brick: hard, its texture taking a little of the highs. Next to nothing gets through it.", Color(0.2, 0.08, 0.05), ["walls"]],
	"concrete": ["Concrete", "Sealed concrete: as hard as a surface gets, so a room of it rings on and on. Nothing gets through it to speak of.",
		Color(0.13, 0.13, 0.14), ["walls", "ceiling", "floor"]],
	"wood": ["Wood panelling", "Wood on studs: it takes some of the lows and sends the rest back warm. Standing in the room, it lets more through than drywall.",
		Color(0.16, 0.09, 0.05), ["walls", "ceiling"]],
	"glass": ["Glass", "Glass: it sends nearly everything back. As a booth's window, it lets a little through, the highs a little more than drywall does.",
		Color(0.2, 0.32, 0.38), ["walls"]],
	"curtain": ["Heavy curtain", "Draped velour: it takes most of the mids and highs and few of the lows. Hung across the room, it hides more than it stops.",
		Color(0.2, 0.03, 0.05), ["walls"]],
	"foam": ["Acoustic foam", "Foam: it takes the mids and highs and leaves the lows. Standing in the room, sound passes through it.",
		Color(0.035, 0.035, 0.04), ["walls", "ceiling"]],
	"acoustic_panel": ["Acoustic panels", "Thick mineral-wool panels: they take nearly everything, the lows too. Standing in the room, a gobo: it shields what is behind it, the highs most.",
		Color(0.1, 0.12, 0.17), ["walls", "ceiling"]],
	"ceiling_tile": ["Acoustic tiles", "A suspended ceiling of acoustic tiles: it takes much of everything.", Color(0.12, 0.12, 0.13), ["ceiling"]],
	"diffuser": ["Diffuser panels", "Wooden panels of wells of different depths: they send back nearly all of the mids and highs, but scattered, spread out in time and from all over them rather than as a mirror's echo. The room keeps its life without the flutter between bare walls.",
		Color(0.19, 0.12, 0.07), ["walls", "ceiling"]],
	"bookshelf": ["Bookshelves", "Full shelves of books: they take some of everything and scatter much of what they send back.", Color(0.16, 0.1, 0.12), ["walls"]],
	"wood_floor": ["Wooden floor", "Wood: it sends most back. A mic a little way off a floor-standing amp hears a strong bounce off it (notches, where it arrives half a wave late).",
		Color(0.11, 0.065, 0.04), ["floor"]],
	"tile": ["Tiles", "Tiles: as hard as a floor gets, a strong, bright bounce.", Color(0.17, 0.17, 0.19), ["floor"]],
	"rug": ["A rug", "A rug under the band: a softer bounce, without its highs.", Color(0.17, 0.08, 0.05), ["floor"]],
	"carpet": ["Carpet", "Thick carpet: hardly any bounce, and little of the highs comes back off it.", Color(0.09, 0.07, 0.1), ["floor"]],
}
const MATERIAL_ORDER := ["drywall", "plaster", "brick", "concrete", "wood", "glass", "curtain", "foam", "acoustic_panel", "diffuser",
	"bookshelf", "ceiling_tile", "wood_floor", "tile", "rug", "carpet"]
## The room's own surfaces, and what each is made of as a room starts (north is the way you first face).
const SURFACES := ["floor", "ceiling", "north", "south", "east", "west"]
const SURFACE_NAMES := {"floor": "Floor", "ceiling": "Ceiling", "north": "North wall", "south": "South wall", "east": "East wall", "west": "West wall"}
const DEFAULT_SURFACES := {"floor": "wood_floor", "ceiling": "ceiling_tile", "north": "drywall", "south": "drywall", "east": "drywall",
	"west": "drywall"}
const DEFAULT_WALL_MATERIAL := "drywall"
var surfaces := DEFAULT_SURFACES.duplicate()

var _shell: Node3D
var _wall_nodes: Node3D
var _lights: Array = []  # [light, its energy at normal brightness]


func setup() -> void:
	_shell = Node3D.new()
	add_child(_shell)
	_wall_nodes = Node3D.new()
	add_child(_wall_nodes)
	reset()


## The wall the default room has: a short one standing between the drums and the bass.
static func default_walls() -> Array:
	return [{"a": Vector2(-2.5, -3.25), "b": Vector2(-2.5, -0.55), "height": DEFAULT_WALL_HEIGHT, "material": DEFAULT_WALL_MATERIAL}]


## Back to the room the game starts with.
func reset() -> void:
	size = DEFAULT_SIZE
	walls = default_walls()
	surfaces = DEFAULT_SURFACES.duplicate()
	_build_shell()
	_build_walls()
	changed.emit()


## The materials a surface can be made of: the floor's, the ceiling's, or a wall's (the room's own or one standing in it).
static func materials_for(surface: String) -> Array:
	var place := surface if surface in ["floor", "ceiling"] else "walls"
	return MATERIAL_ORDER.filter(func(m): return place in MATERIALS[m][3])


## What one of the room's own surfaces is made of ("floor", "ceiling", "north", "south", "east", "west").
func set_surface(surface: String, material: String) -> void:
	if not surfaces.has(surface) or not materials_for(surface).has(material) or surfaces[surface] == material:
		return
	surfaces[surface] = material
	_build_shell()
	changed.emit()


## What a wall standing in the room is made of.
func set_wall_material(index: int, material: String) -> void:
	if index < 0 or index >= walls.size() or not materials_for("walls").has(material) or walls[index].get("material", "") == material:
		return
	walls[index].material = material
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
func add_wall(a: Vector2, b: Vector2, height := DEFAULT_WALL_HEIGHT, material := DEFAULT_WALL_MATERIAL) -> int:
	a = _on_floor(a)
	b = _on_floor(b)
	if walls.size() >= MAX_WALLS or a.distance_to(b) < MIN_WALL_RUN:
		return -1
	if not materials_for("walls").has(material):
		material = DEFAULT_WALL_MATERIAL
	walls.append({"a": a, "b": b, "height": clampf(height, MIN_WALL_HEIGHT, MAX_SIZE.y), "material": material})
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
		out.append({"a": wall.a, "b": wall.b, "thickness": WALL_THICKNESS, "height": wall_top(wall),
			"material": wall.get("material", DEFAULT_WALL_MATERIAL)})
	return out


## A material's colour, as the room is drawn.
static func material_color(material: String) -> Color:
	return MATERIALS.get(material, MATERIALS[DEFAULT_WALL_MATERIAL])[2]


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
	# Each drawn as its material (room_surfaces.gd), the ceiling a little darker, as it is lit from below.
	_block(_shell, Vector3(0, -t / 2, 0), Vector3(w + 2 * t, t, d + 2 * t), surfaces.floor)
	_block(_shell, Vector3(0, h + t / 2, 0), Vector3(w + 2 * t, t, d + 2 * t), surfaces.ceiling, func(c: Color) -> Color: return c.darkened(0.3))
	_block(_shell, Vector3(-w / 2 - t / 2, h / 2, 0), Vector3(t, h, d), surfaces.west)
	_block(_shell, Vector3(w / 2 + t / 2, h / 2, 0), Vector3(t, h, d), surfaces.east)
	_block(_shell, Vector3(0, h / 2, -d / 2 - t / 2), Vector3(w, h, t), surfaces.north)
	_block(_shell, Vector3(0, h / 2, d / 2 + t / 2), Vector3(w, h, t), surfaces.south)
	# Lights in a grid about seven metres apart, so a big room is lit as evenly as a small one. They hang at the
	# default room's ceiling height, where they light the floor and what stands on it; a tall room gets a second
	# set under its own ceiling for the upper walls.
	_lights.clear()
	var across := clampi(roundi(w / LIGHT_SPACING), 1, 6)
	var along := clampi(roundi(d / LIGHT_SPACING), 1, 6)
	var layers := [[minf(h - 0.3, 3.7), 1.0]]  # height, share of the full energy
	if h > 6.0:
		layers.append([h - 0.3, 0.6])
	for layer in layers:
		for i in across:
			for j in along:
				var light := OmniLight3D.new()
				light.position = Vector3((i + 0.5) * w / across - w / 2, layer[0], (j + 0.5) * d / along - d / 2)
				light.light_color = Color(0.75, 0.8, 1.0)
				light.omni_range = LIGHT_RANGE
				_shell.add_child(light)
				_lights.append([light, LIGHT_ENERGY * layer[1]])
	set_brightness(brightness)


func set_brightness(value: float) -> void:
	brightness = value
	for entry in _lights:
		entry[0].light_energy = entry[1] * value


func _build_walls() -> void:
	for child in _wall_nodes.get_children():
		child.queue_free()
	for wall in walls:
		var top := wall_top(wall)
		var centre: Vector2 = (wall.a + wall.b) / 2
		var along: Vector2 = wall.b - wall.a
		# Sound has to bend round these, and the player has to walk round them.
		var material: String = wall.get("material", DEFAULT_WALL_MATERIAL)
		var block := _block(_wall_nodes, Vector3(centre.x, top / 2, centre.y), Vector3(wall_length(wall), top, WALL_THICKNESS), material,
			func(c: Color) -> Color: return c.lightened(0.15), atan2(-along.y, along.x))
		if material != "glass":
			block.layers |= 1 << (SHADOW_LAYER - 1)


func _block(parent: Node3D, centre: Vector3, block_size: Vector3, material: String, tint: Callable = Callable(), turn := 0.0) -> MeshInstance3D:
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
	mesh.material_override = Surfaces.made_of(material, material_color(material), tint)
	body.add_child(mesh)
	parent.add_child(body)
	return mesh
