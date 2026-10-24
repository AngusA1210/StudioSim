extends Control
## The room seen from above: its outline, the walls in it, the instruments, and where you are standing.
## Drag on the floor to draw a wall; drag a wall to move it, or one of its ends to turn and stretch it. Drag one of the
## room's own walls to move it alone, in or out, the wall opposite staying put (never past a locked instrument).
## North (the way you face when you first walk in) is up. You are the white arrowhead; the free camera, while it flies, an
## outline.

signal selection_changed

const Room := preload("res://scripts/room.gd")
const ACCENT := Color(0.49, 0.89, 0.82)
const PAD := 16.0
const HANDLE := 7.0  # radius of the dots on a selected wall's ends, in pixels

var app
var selected := -1  # index into the room's walls, or -1

var _drag := {}  # what the mouse is doing: {mode: "a" | "b" | "move" | "new" | "side", ...}
var _hover := -1
var _hover_side := ""  # one of the room's own walls under the mouse ("north"...), or ""
# While one of the room's own walls is dragged, the plan holds still: its scale as it was, and shifted with what is in
# the room (which moves by half as much the other way, the room staying centred), so the wall follows the mouse.
var _held_scale := 0.0
var _view := Vector2.ZERO


func setup(the_app) -> void:
	app = the_app
	custom_minimum_size = Vector2(300, 250)
	mouse_filter = Control.MOUSE_FILTER_PASS  # so the wheel still scrolls the page this sits in


func select(index: int) -> void:
	if index != selected:
		selected = index
		selection_changed.emit()


func _process(_delta: float) -> void:
	if not is_visible_in_tree():
		return
	if selected >= app.room.walls.size():  # the room changed under us
		select(-1)
	queue_redraw()  # instruments and the player move


## Pixels to a metre: as large as fits (or as it was, while one of the room's walls is dragged).
func _scale() -> float:
	if _held_scale > 0.0:
		return _held_scale
	var room_size: Vector3 = app.room.size
	return maxf(minf((size.x - 2 * PAD) / room_size.x, (size.y - 2 * PAD) / room_size.z), 1.0)


func to_screen(point: Vector2) -> Vector2:
	return size / 2 + (point - _view) * _scale()


func to_plan(pixel: Vector2) -> Vector2:
	return (pixel - size / 2) / _scale() + _view


func _draw() -> void:
	var room = app.room
	var half := Vector2(room.size.x, room.size.z) / 2
	var k := _scale()
	var floor_rect := Rect2(to_screen(-half), half * 2 * k)
	draw_rect(floor_rect, Color(1, 1, 1, 0.045))
	var spacing := 1.0 if k >= 12.0 else 5.0  # a line every metre, or every five when the room is large
	var x := ceilf(-half.x / spacing) * spacing
	while x < half.x:
		draw_line(to_screen(Vector2(x, -half.y)), to_screen(Vector2(x, half.y)), Color(1, 1, 1, 0.09 if is_zero_approx(x) else 0.045))
		x += spacing
	var z := ceilf(-half.y / spacing) * spacing
	while z < half.y:
		draw_line(to_screen(Vector2(-half.x, z)), to_screen(Vector2(half.x, z)), Color(1, 1, 1, 0.09 if is_zero_approx(z) else 0.045))
		z += spacing
	# The room's own walls, each in its material's colour (north at the top).
	var corners := [to_screen(Vector2(-half.x, -half.y)), to_screen(Vector2(half.x, -half.y)), to_screen(Vector2(half.x, half.y)),
		to_screen(Vector2(-half.x, half.y))]
	for side in [["north", 0, 1], ["east", 1, 2], ["south", 2, 3], ["west", 3, 0]]:
		var dragged: bool = side[0] == _drag.get("side", "") or (_drag.is_empty() and side[0] == _hover_side)
		draw_line(corners[side[1]], corners[side[2]], ACCENT if dragged else Room.material_color(room.surfaces[side[0]]).lightened(0.55),
			5.0 if dragged else 3.0)

	for i in room.walls.size():
		var wall: Dictionary = room.walls[i]
		var made: Color = Room.material_color(wall.get("material", Room.DEFAULT_WALL_MATERIAL)).lightened(0.45)
		var ink := ACCENT if i == selected else (made.lightened(0.25) if i == _hover else made)
		if room.wall_top(wall) < room.size.y - 0.05:
			ink.a = 0.6  # paler: it stops short of the ceiling, so sound comes over it
		draw_colored_polygon(_outline(wall.a, wall.b), ink)
	if _drag.get("mode", "") == "new" and _drag.from.distance_to(_drag.to) >= Room.MIN_WALL_RUN:
		draw_colored_polygon(_outline(_drag.from, _drag.to), Color(ACCENT, 0.45))
	if selected >= 0 and selected < room.walls.size():
		for end: Vector2 in [room.walls[selected].a, room.walls[selected].b]:
			draw_circle(to_screen(end), HANDLE, Color(0.07, 0.08, 0.11))
			draw_arc(to_screen(end), HANDLE, 0.0, TAU, 24, ACCENT, 2.0)

	var font := get_theme_default_font()
	for inst in app.instruments:
		var at := to_screen(Vector2(inst.global_position.x, inst.global_position.z))
		draw_circle(at, 5.0, inst.color)
		draw_string(font, at + Vector2(8, 4), inst.display_name, HORIZONTAL_ALIGNMENT_LEFT, -1, 11, inst.color.lightened(0.4))
	var player = app.player
	if player != null:  # an arrowhead where you stand, pointing the way you face
		var here := to_screen(Vector2(player.global_position.x, player.global_position.z))
		var ahead := Vector2(-sin(player.yaw), -cos(player.yaw))
		var side := Vector2(-ahead.y, ahead.x)
		draw_colored_polygon(PackedVector2Array([here + ahead * 10.0, here - ahead * 6.0 + side * 6.0, here - ahead * 6.0 - side * 6.0]),
			Color(1, 1, 1, 0.95))
		if player.flying:  # and the free camera, an outline, the way it looks
			var at: Vector3 = player.fly_camera.global_position
			var there := to_screen(Vector2(at.x, at.z))
			var looks := Vector2(-sin(player.fly_yaw), -cos(player.fly_yaw))
			var across := Vector2(-looks.y, looks.x)
			draw_polyline(PackedVector2Array([there + looks * 10.0, there - looks * 6.0 + across * 6.0, there - looks * 6.0 - across * 6.0,
				there + looks * 10.0]), ACCENT, 2.0)


## A wall's four corners on screen.
func _outline(a: Vector2, b: Vector2) -> PackedVector2Array:
	var along := (b - a).normalized() * Room.WALL_THICKNESS / 2
	var across := Vector2(-along.y, along.x)
	return PackedVector2Array([to_screen(a - along - across), to_screen(b + along - across), to_screen(b + along + across),
		to_screen(a - along + across)])


## Which of the room's own walls is under the mouse ("north", "south", "east", "west"), or "".
func _side_at(pixel: Vector2) -> String:
	var half := Vector2(app.room.size.x, app.room.size.z) / 2
	var point := to_plan(pixel)
	var reach := 6.0 / _scale()
	if absf(point.x) <= half.x + reach:
		if absf(point.y + half.y) <= reach:
			return "north"
		if absf(point.y - half.y) <= reach:
			return "south"
	if absf(point.y) <= half.y + reach:
		if absf(point.x - half.x) <= reach:
			return "east"
		if absf(point.x + half.x) <= reach:
			return "west"
	return ""


func _wall_at(pixel: Vector2) -> int:
	var point := to_plan(pixel)
	var reach := Room.WALL_THICKNESS / 2 + 5.0 / _scale()
	for i in range(app.room.walls.size() - 1, -1, -1):
		var wall: Dictionary = app.room.walls[i]
		if Geometry2D.get_closest_point_to_segment(point, wall.a, wall.b).distance_to(point) <= reach:
			return i
	return -1


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_press(event.position)
		else:
			_release()
		accept_event()
	elif event is InputEventMouseMotion:
		if _drag.is_empty():
			_hover = _wall_at(event.position)
			_hover_side = _side_at(event.position) if _hover < 0 else ""
		else:
			_move(event.position)
			accept_event()


func _press(pixel: Vector2) -> void:
	var room = app.room
	if selected >= 0:  # the ends of the selected wall come first
		for end in ["a", "b"]:
			if to_screen(room.walls[selected][end]).distance_to(pixel) <= HANDLE + 4.0:
				_drag = {"mode": end}
				return
	var hit := _wall_at(pixel)
	if hit >= 0:
		select(hit)
		_drag = {"mode": "move", "grab": to_plan(pixel), "a": room.walls[hit].a, "b": room.walls[hit].b}
		return
	select(-1)
	var side := _side_at(pixel)
	if side != "":  # one of the room's own walls: moved alone
		_held_scale = _scale()
		_drag = {"mode": "side", "side": side}
		return
	var start := Room.snap(to_plan(pixel))
	if absf(start.x) <= room.size.x / 2 and absf(start.y) <= room.size.z / 2:
		_drag = {"mode": "new", "from": start, "to": start}


func _move(pixel: Vector2) -> void:
	var room = app.room
	var half := Vector2(room.size.x, room.size.z) / 2
	var point := to_plan(pixel).clamp(-half, half)
	match _drag.mode:
		"a":
			room.set_wall(selected, Room.snap(point), room.walls[selected].b)
		"b":
			room.set_wall(selected, room.walls[selected].a, Room.snap(point))
		"move":  # the whole wall, kept inside the room
			var a: Vector2 = _drag.a
			var b: Vector2 = _drag.b
			var shift := Room.snap(to_plan(pixel) - _drag.grab)
			shift.x = clampf(shift.x, -half.x - minf(a.x, b.x), half.x - maxf(a.x, b.x))
			shift.y = clampf(shift.y, -half.y - minf(a.y, b.y), half.y - maxf(a.y, b.y))
			room.set_wall(selected, a + shift, b + shift)
		"new":
			_drag.to = Room.snap(point)
		"side":  # the wall to where the mouse is (in the plan as it was), everything else holding still
			var at := Room.snap(to_plan(pixel))
			var wall: float = {"north": -half.y, "south": half.y, "east": half.x, "west": -half.x}[_drag.side]
			var wanted: float = at.y if _drag.side in ["north", "south"] else at.x
			var outward := -1.0 if _drag.side in ["north", "west"] else 1.0
			var moved: float = app.move_room_wall(_drag.side, outward * (wanted - wall))
			if _drag.side in ["north", "south"]:
				_view.y -= outward * moved / 2.0
			else:
				_view.x -= outward * moved / 2.0


func _release() -> void:
	if _drag.get("mode", "") == "new":
		var made: int = app.room.add_wall(_drag.from, _drag.to)
		if made >= 0:
			select(made)
	_drag = {}
	_held_scale = 0.0  # (fitted to the room again)
	_view = Vector2.ZERO
