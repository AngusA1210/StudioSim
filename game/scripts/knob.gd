extends Control
## A rotary knob, as on an amp's panel: 0 to 10 round three quarters of a turn, its name underneath. Drag up or down
## to turn it (Shift for fine moves), use the scroll wheel, or double-click it to put it back where it started.

signal value_changed(value: float)

const ARC_START := PI * 0.75  # where 0 sits: down and to the left
const ARC_SWEEP := PI * 1.5
const RADIUS := 21.0

var title := ""
var value := 5.0
var resting := 5.0  # where a double-click puts it
var ink := Color(0.9, 0.9, 0.92)
var _dragging := false


func _ready() -> void:
	custom_minimum_size = Vector2(70, 82)
	focus_mode = Control.FOCUS_NONE


func set_value_no_signal(v: float) -> void:
	value = clampf(v, 0.0, 10.0)
	queue_redraw()


func _draw() -> void:
	var font := get_theme_default_font()
	var centre := Vector2(size.x / 2, RADIUS + 6)
	for i in 11:  # the scale round it
		var a := ARC_START + ARC_SWEEP * i / 10.0
		var dir := Vector2(cos(a), sin(a))
		draw_line(centre + dir * (RADIUS + 3), centre + dir * (RADIUS + (7 if i % 5 == 0 else 5)), Color(1, 1, 1, 0.5), 1.0)
	draw_circle(centre, RADIUS, Color(0.08, 0.08, 0.09))
	draw_arc(centre, RADIUS, 0, TAU, 32, Color(1, 1, 1, 0.25) if not _dragging else Color(1, 1, 1, 0.6), 1.5)
	var turn := ARC_START + ARC_SWEEP * value / 10.0
	draw_line(centre, centre + Vector2(cos(turn), sin(turn)) * (RADIUS - 3), ink, 3.0)
	draw_string(font, Vector2(0, RADIUS * 2 + 26), title, HORIZONTAL_ALIGNMENT_CENTER, size.x, 11, Color(1, 1, 1, 0.8))
	draw_string(font, Vector2(0, RADIUS * 2 + 41), "%.1f" % value, HORIZONTAL_ALIGNMENT_CENTER, size.x, 11, Color(1, 1, 1, 0.5))


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed and event.double_click:
				_turn_to(resting)
			_dragging = event.pressed
			queue_redraw()
			accept_event()
		elif event.pressed and event.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
			_turn_to(value + (0.25 if event.button_index == MOUSE_BUTTON_WHEEL_UP else -0.25))
			accept_event()
	elif event is InputEventMouseMotion and _dragging:
		var change: float = -event.relative.y / 150.0 * 10.0 * (0.2 if event.shift_pressed else 1.0)
		_turn_to(value + change)
		accept_event()


func _turn_to(v: float) -> void:
	v = clampf(snappedf(v, 0.05), 0.0, 10.0)
	if is_equal_approx(v, value):
		return
	value = v
	queue_redraw()
	value_changed.emit(v)
