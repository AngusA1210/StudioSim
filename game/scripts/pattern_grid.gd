extends Control
## One bar of a pattern drawn as a grid: a row for each note (or drum piece), a column for each sixteenth.
## It only draws and reports what the mouse does; the pattern editor decides what a click means.

signal cell_pressed(column: int, note: int, button: int)
signal cell_hovered(column: int, note: int)  # note is -1 when the mouse isn't over a cell
signal label_pressed(note: int)

const LABEL_WIDTH := 96.0
const COLUMNS := 16
const TEXT := Color(0.72, 0.75, 0.83)

var rows: Array = []   # top to bottom: {note: int, label: String, dark: bool}
var notes: Array = []  # the whole pattern: {step, note, length, velocity, chance}
var bar := 0
var steps := 64        # the pattern's length; columns past it are dimmed
var playhead := -1     # the column the clock is on, or -1
var color := Color.WHITE
var row_height := 22.0

var _row_of := {}  # note → row
var _hover := Vector2i(-1, -1)  # column, row


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_PASS  # so the wheel still scrolls the list this sits in
	mouse_exited.connect(_on_mouse_exited)


func show_rows(new_rows: Array, height: float) -> void:
	rows = new_rows
	row_height = height
	_row_of.clear()
	for i in rows.size():
		_row_of[int(rows[i].note)] = i
	custom_minimum_size = Vector2(LABEL_WIDTH + COLUMNS * 22.0, rows.size() * row_height)
	queue_redraw()


func set_playhead(column: int) -> void:
	if column != playhead:
		playhead = column
		queue_redraw()


## Where a note's row starts, for scrolling to it.
func row_top(note: int) -> float:
	return float(_row_of.get(note, 0)) * row_height


func _column_width() -> float:
	return (size.x - LABEL_WIDTH) / COLUMNS


func _draw() -> void:
	var cw := _column_width()
	var font := get_theme_default_font()
	var font_size := 13 if row_height >= 28.0 else 12
	var first := bar * COLUMNS
	for r in rows.size():
		var row: Dictionary = rows[r]
		var y := r * row_height
		var shade := 0.55 if row.get("dark", false) else 1.0
		draw_rect(Rect2(0, y + 1, LABEL_WIDTH - 4, row_height - 2), Color(1, 1, 1, 0.05 * shade))
		draw_string(font, Vector2(8, y + row_height * 0.5 + font_size * 0.36), row.label, HORIZONTAL_ALIGNMENT_LEFT,
			LABEL_WIDTH - 14, font_size, TEXT if not row.get("dark", false) else TEXT.darkened(0.3))
		for c in COLUMNS:
			var alpha := (0.085 if (c / 4) % 2 == 0 else 0.05) * shade  # beats one and three a little lighter
			if first + c >= steps:
				alpha = 0.018  # past the end of the pattern
			elif _hover == Vector2i(c, r):
				alpha += 0.09
			draw_rect(Rect2(LABEL_WIDTH + c * cw + 1, y + 1, cw - 2, row_height - 2), Color(1, 1, 1, alpha))

	for n in notes:
		if not _row_of.has(int(n.note)):
			continue
		var from := maxf(float(n.step), float(first))
		var to := minf(float(n.step) + maxf(float(n.length), 1.0), float(first + COLUMNS))
		if to <= from:
			continue
		var y: float = _row_of[int(n.note)] * row_height
		var rect := Rect2(LABEL_WIDTH + (from - first) * cw + 2, y + 3, (to - from) * cw - 4, row_height - 6)
		var ink := color
		ink.a = 0.3 + 0.7 * float(n.velocity)
		if float(n.chance) < 1.0:
			draw_rect(rect.grow(-1), ink.lightened(0.2), false, 2.0)  # hollow: it only plays some of the time
		else:
			draw_rect(rect, ink)
			if float(n.step) >= first:  # a brighter edge where the note starts
				draw_rect(Rect2(rect.position, Vector2(3, rect.size.y)), color.lightened(0.45))

	for beat in range(1, 4):
		var x := LABEL_WIDTH + beat * 4 * cw
		draw_line(Vector2(x, 0), Vector2(x, rows.size() * row_height), Color(1, 1, 1, 0.16), 1.0)
	if playhead >= 0:
		draw_rect(Rect2(LABEL_WIDTH + playhead * cw, 0, cw, rows.size() * row_height), Color(1, 1, 1, 0.11))


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		var cell := _cell_at(event.position)
		if cell != _hover:
			_hover = cell
			queue_redraw()
			cell_hovered.emit(cell.x, int(rows[cell.y].note) if cell.x >= 0 and cell.y >= 0 else -1)
	elif event is InputEventMouseButton and event.pressed and event.button_index in [MOUSE_BUTTON_LEFT, MOUSE_BUTTON_RIGHT]:
		var row := int(event.position.y / row_height)
		if row < 0 or row >= rows.size():
			return
		accept_event()
		var cell := _cell_at(event.position)
		if cell.x >= 0:
			cell_pressed.emit(cell.x, int(rows[row].note), event.button_index)
		elif event.button_index == MOUSE_BUTTON_LEFT:
			label_pressed.emit(int(rows[row].note))


## The column and row under a point; the column is -1 over the labels, both are -1 outside the rows.
func _cell_at(point: Vector2) -> Vector2i:
	var row := int(floor(point.y / row_height))
	if row < 0 or row >= rows.size() or point.x < 0.0:
		return Vector2i(-1, -1)
	if point.x < LABEL_WIDTH:
		return Vector2i(-1, row)
	return Vector2i(clampi(int((point.x - LABEL_WIDTH) / _column_width()), 0, COLUMNS - 1), row)


func _on_mouse_exited() -> void:
	_hover = Vector2i(-1, -1)
	queue_redraw()
	cell_hovered.emit(-1, -1)
