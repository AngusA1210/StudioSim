extends Control
## A mixing-desk fader: a cap that slides up and down a slot, with a decibel scale beside it. +12 dB at the top,
## 0 dB three quarters of the way up, silence at the bottom, spaced the way a console's faders are.
## Drag to move it (hold Shift for fine moves), turn the wheel to nudge it, double-click or Alt-click for 0 dB.

signal value_changed(db: float)

const SILENT := -80.0  # what the bottom of the travel means: nothing at all
# Points along the travel (0 = bottom, 1 = top) and the level each stands for; levels between are in proportion.
const TAPER := [[0.0, -80.0], [0.08, -60.0], [0.2, -40.0], [0.38, -20.0], [0.5, -10.0], [0.6, -5.0], [0.72, 0.0], [0.86, 6.0], [1.0, 12.0]]
const MARKS := [[12.0, "12"], [6.0, "6"], [0.0, "0"], [-5.0, "5"], [-10.0, "10"], [-20.0, "20"], [-40.0, "40"], [-60.0, "60"], [-80.0, "∞"]]
const CAP := Vector2(30, 16)
const SCALE_WIDTH := 18.0

var value := 0.0
var _dragging := false


func _ready() -> void:
	custom_minimum_size = Vector2(SCALE_WIDTH + CAP.x + 4, 120)
	focus_mode = Control.FOCUS_NONE


func set_value_no_signal(db: float) -> void:
	value = clampf(db, SILENT, 12.0)
	queue_redraw()


static func position_of(db: float) -> float:
	if db <= SILENT:
		return 0.0
	for i in range(1, TAPER.size()):
		if db <= TAPER[i][1]:
			var low: Array = TAPER[i - 1]
			var high: Array = TAPER[i]
			return lerpf(low[0], high[0], (db - low[1]) / (high[1] - low[1]))
	return 1.0


static func level_at(travel: float) -> float:
	travel = clampf(travel, 0.0, 1.0)
	for i in range(1, TAPER.size()):
		if travel <= TAPER[i][0]:
			var low: Array = TAPER[i - 1]
			var high: Array = TAPER[i]
			return lerpf(low[1], high[1], (travel - low[0]) / (high[0] - low[0]))
	return 12.0


func _travel_pixels() -> float:
	return maxf(size.y - CAP.y, 1.0)


func _draw() -> void:
	var font := get_theme_default_font()
	var slot_x := SCALE_WIDTH + CAP.x / 2 + 2
	var top := CAP.y / 2
	var travel := _travel_pixels()
	draw_rect(Rect2(slot_x - 2, top, 4, travel), Color(0, 0, 0, 0.75))
	for mark in MARKS:
		var y: float = top + (1.0 - position_of(mark[0])) * travel
		var ink := Color(1, 1, 1, 0.75 if mark[0] == 0.0 else 0.45)
		draw_line(Vector2(SCALE_WIDTH - 2, y), Vector2(SCALE_WIDTH + 4, y), ink, 1.0)
		draw_string(font, Vector2(0, y + 4), mark[1], HORIZONTAL_ALIGNMENT_RIGHT, SCALE_WIDTH - 4, 10, ink)
	var cap_y := (1.0 - position_of(value)) * travel
	var cap := Rect2(Vector2(slot_x - CAP.x / 2, cap_y), CAP)
	draw_rect(cap, Color(0.78, 0.8, 0.84) if not _dragging else Color(0.92, 0.94, 0.97))
	draw_rect(Rect2(cap.position + Vector2(0, CAP.y / 2 - 1), Vector2(CAP.x, 2)), Color(0.1, 0.1, 0.12))
	draw_rect(cap, Color(0, 0, 0, 0.6), false, 1.0)


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
			if event.double_click or event.alt_pressed:
				_change(0.0)
			else:
				_dragging = true
			accept_event()
		elif event.button_index == MOUSE_BUTTON_LEFT:
			_dragging = false
			queue_redraw()
			accept_event()
		elif event.pressed and event.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
			_change(value + (0.5 if event.button_index == MOUSE_BUTTON_WHEEL_UP else -0.5))
			accept_event()
	elif event is InputEventMouseMotion and _dragging:
		var travel: float = position_of(value) - event.relative.y / _travel_pixels() * (0.25 if event.shift_pressed else 1.0)
		_change(level_at(travel))
		accept_event()


func _change(db: float) -> void:
	db = clampf(snappedf(db, 0.1), SILENT, 12.0)
	if is_equal_approx(db, value):
		return
	value = db
	queue_redraw()
	value_changed.emit(db)
