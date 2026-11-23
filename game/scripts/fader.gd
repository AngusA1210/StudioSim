extends Control
## A mixing-desk fader: a cap that slides up and down a slot, with a decibel scale beside it. +12 dB at the top,
## 0 dB three quarters of the way up, silence at the bottom, spaced the way a console's faders are. A master's stops at
## 0 dB (`top_db`), its travel spaced the same below that.
## Drag to move it (hold Shift for fine moves), turn the wheel to nudge it, double-click or Alt-click for 0 dB.

signal value_changed(db: float)

const SILENT := -80.0  # what the bottom of the travel means: nothing at all
# Points along the travel (0 = bottom, 1 = top) and the level each stands for; levels between are in proportion.
const TAPER := [[0.0, -80.0], [0.08, -60.0], [0.2, -40.0], [0.38, -20.0], [0.5, -10.0], [0.6, -5.0], [0.72, 0.0], [0.86, 6.0], [1.0, 12.0]]
const MARKS := [[12.0, "12"], [6.0, "6"], [0.0, "0"], [-5.0, "5"], [-10.0, "10"], [-20.0, "20"], [-40.0, "40"], [-60.0, "60"], [-80.0, "∞"]]
const CAP := Vector2(30, 16)
const SCALE_WIDTH := 18.0

var value := 0.0
var top_db := 12.0  # the top of its travel
var _dragging := false


func _ready() -> void:
	custom_minimum_size = Vector2(SCALE_WIDTH + CAP.x + 4, 120)
	focus_mode = Control.FOCUS_NONE


func set_value_no_signal(db: float) -> void:
	value = clampf(db, SILENT, top_db)
	queue_redraw()


## How far up its own travel a level is (0 to 1), and the level that far up.
func _up(db: float) -> float:
	return position_of(db) / position_of(top_db)


func _level(travel: float) -> float:
	return level_at(travel * position_of(top_db))


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
	draw_rect(Rect2(slot_x - 2, top, 4, travel), Color("090a0f"))
	draw_rect(Rect2(slot_x - 2, top, 4, travel), Color(1, 1, 1, 0.09), false, 1.0)
	for mark in MARKS:
		if mark[0] > top_db:
			continue
		var y: float = top + (1.0 - _up(mark[0])) * travel
		var ink := Color("eceef4") if mark[0] == 0.0 else Color("9aa1b8")
		draw_line(Vector2(SCALE_WIDTH - 2, y), Vector2(SCALE_WIDTH + 4, y), ink, 1.0)
		draw_string(font, Vector2(0, y + 4), mark[1], HORIZONTAL_ALIGNMENT_RIGHT, SCALE_WIDTH - 4, 10, ink)
	var cap_y := (1.0 - _up(value)) * travel
	var cap := Rect2(Vector2(slot_x - CAP.x / 2, cap_y), CAP)
	var face := StyleBoxFlat.new()  # (a light cap, rounded, with a line across its middle)
	face.bg_color = Color("d9dce6") if not _dragging else Color("ffffff")
	face.set_corner_radius_all(4)
	face.shadow_color = Color(0, 0, 0, 0.5)
	face.shadow_size = 4
	face.shadow_offset = Vector2(0, 2)
	draw_style_box(face, cap)
	draw_rect(Rect2(cap.position + Vector2(4, CAP.y / 2 - 1), Vector2(CAP.x - 8, 2)), Color("13161f"))


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
		var travel: float = _up(value) - event.relative.y / _travel_pixels() * (0.25 if event.shift_pressed else 1.0)
		_change(_level(travel))
		accept_event()


func _change(db: float) -> void:
	db = clampf(snappedf(db, 0.1), SILENT, top_db)
	if is_equal_approx(db, value):
		return
	value = db
	queue_redraw()
	value_changed.emit(db)
