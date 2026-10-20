extends Control
## A track's pan, as a DAW's mix window has one: a bar from hard left to hard right, the middle marked, filled from
## the middle to where it is, and reading as Pro Tools reads it ("<50" to the left, "50>" to the right, "C" in the
## middle). Drag it along (Shift for fine moves), turn the scroll wheel to nudge it, double-click or Alt-click it for
## the middle.

signal value_changed(value: float)  # -1 left to 1 right

var value := 0.0
var ink := Color(0.55, 0.78, 1.0)
var _dragging := false
var _from_x := 0.0
var _from_value := 0.0


func _init() -> void:
	custom_minimum_size = Vector2(70, 20)
	focus_mode = Control.FOCUS_NONE
	mouse_filter = Control.MOUSE_FILTER_STOP


## How a pan reads: "C", "<50", "50>".
static func readout(pan: float) -> String:
	var amount := roundi(absf(pan) * 100.0)
	if amount == 0:
		return "C"
	return "<%d" % amount if pan < 0.0 else "%d>" % amount


func set_value_no_signal(v: float) -> void:
	value = clampf(v, -1.0, 1.0)
	queue_redraw()


func _draw() -> void:
	var font := get_theme_default_font()
	var bar := Rect2(Vector2(1, 3), Vector2(size.x - 2, size.y - 6))
	draw_rect(bar, Color(0.06, 0.065, 0.08))
	var middle := bar.position.x + bar.size.x / 2.0
	var at := middle + value * bar.size.x / 2.0
	draw_rect(Rect2(minf(middle, at), bar.position.y, absf(at - middle), bar.size.y), Color(ink, 0.55 if not _dragging else 0.8))
	draw_line(Vector2(middle, bar.position.y), Vector2(middle, bar.end.y), Color(1, 1, 1, 0.35), 1.0)
	draw_line(Vector2(at, bar.position.y - 2), Vector2(at, bar.end.y + 2), Color(0.93, 0.94, 0.97), 2.0)
	draw_rect(bar, Color(0, 0, 0, 0.6), false, 1.0)
	draw_string(font, Vector2(0, size.y / 2.0 + 4), readout(value), HORIZONTAL_ALIGNMENT_CENTER, size.x, 11, Color(0.93, 0.94, 0.97))


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var e: InputEventMouseButton = event
		if e.button_index == MOUSE_BUTTON_LEFT:
			if e.pressed and (e.double_click or e.alt_pressed):
				_turn_to(0.0)
			_dragging = e.pressed and not e.alt_pressed and not e.double_click
			_from_x = e.position.x
			_from_value = value
			queue_redraw()
			accept_event()
		elif e.pressed and e.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
			_turn_to(value + (0.05 if e.button_index == MOUSE_BUTTON_WHEEL_UP else -0.05))
			accept_event()
	elif event is InputEventMouseMotion and _dragging:
		var e: InputEventMouseMotion = event
		var across := (e.position.x - _from_x) / maxf(size.x, 1.0) * 2.0 * (0.2 if e.shift_pressed else 1.0)
		_turn_to(_from_value + across)
		accept_event()


func _turn_to(v: float) -> void:
	v = clampf(snappedf(v, 0.01), -1.0, 1.0)
	if is_equal_approx(v, value):
		return
	value = v
	queue_redraw()
	value_changed.emit(v)
