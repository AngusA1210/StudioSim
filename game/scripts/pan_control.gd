extends Control
## A track's pan, as a pot on a DAW's mix window strip (Pro Tools' kind): a knob turned from hard left round to hard
## right, its arc lit from the top (the middle) to where it is, and its setting under it as Pro Tools reads it ("<50"
## to the left, "50>" to the right, "C" in the middle). Drag up or right to turn it right, down or left to turn it left
## (Shift for fine moves), turn the scroll wheel to nudge it, double-click or Alt-click it for the middle.

signal value_changed(value: float)  # -1 left to 1 right

const SWEEP := PI * 0.75  # how far round it turns either way from the top

var value := 0.0
var ink := Color(0.55, 0.78, 1.0)
var _dragging := false
var _from := Vector2.ZERO
var _from_value := 0.0


func _init() -> void:
	custom_minimum_size = Vector2(70, 40)
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
	var radius := minf(size.y - 16.0, size.x) / 2.0 - 1.0
	var centre := Vector2(size.x / 2.0, radius + 1.0)
	var top := -PI / 2.0
	draw_arc(centre, radius, top - SWEEP, top + SWEEP, 32, Color(1, 1, 1, 0.14), 2.0, true)  # its range
	var at := top + value * SWEEP
	if absf(value) > 0.005:  # lit from the middle to where it is
		draw_arc(centre, radius, minf(top, at), maxf(top, at), 24, Color(ink, 0.95 if _dragging else 0.8), 2.5, true)
	draw_circle(centre, radius - 3.5, Color(0.08, 0.085, 0.1))
	draw_arc(centre, radius - 3.5, 0, TAU, 24, Color(1, 1, 1, 0.22), 1.0, true)
	draw_line(centre, centre + Vector2(cos(at), sin(at)) * (radius - 4.5), Color(0.93, 0.94, 0.97), 2.0, true)
	draw_line(centre + Vector2(0, -radius - 1.0), centre + Vector2(0, -radius + 2.0), Color(1, 1, 1, 0.45), 1.0)  # the middle
	draw_string(font, Vector2(0, size.y - 2.0), readout(value), HORIZONTAL_ALIGNMENT_CENTER, size.x, 11, Color(0.93, 0.94, 0.97))


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var e: InputEventMouseButton = event
		if e.button_index == MOUSE_BUTTON_LEFT:
			if e.pressed and (e.double_click or e.alt_pressed):
				_turn_to(0.0)
			_dragging = e.pressed and not e.alt_pressed and not e.double_click
			_from = e.position
			_from_value = value
			queue_redraw()
			accept_event()
		elif e.pressed and e.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
			_turn_to(value + (0.05 if e.button_index == MOUSE_BUTTON_WHEEL_UP else -0.05))
			accept_event()
	elif event is InputEventMouseMotion and _dragging:
		var e: InputEventMouseMotion = event
		var moved: Vector2 = e.position - _from
		_turn_to(_from_value + (moved.x - moved.y) / 120.0 * (0.2 if e.shift_pressed else 1.0))
		accept_event()


func _turn_to(v: float) -> void:
	v = clampf(snappedf(v, 0.01), -1.0, 1.0)
	if is_equal_approx(v, value):
		return
	value = v
	queue_redraw()
	value_changed.emit(v)
