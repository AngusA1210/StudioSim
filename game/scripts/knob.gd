extends Control
## A rotary knob, as on an amp's panel: 0 to 10 round three quarters of a turn, an arc round it lit as far as it is
## turned (in `arc`, teal unless a pedal's own colour), its name underneath and its setting under that (`readout`, if set, says it in real units instead). Drag up or down to turn it (Shift for fine moves),
## use the scroll wheel, or double-click or Alt-click it to put it back where it started.

signal value_changed(value: float)

const UI := preload("res://scripts/ui.gd")

const ARC_START := PI * 0.75  # where 0 sits: down and to the left
const ARC_SWEEP := PI * 1.5
const RADIUS := 21.0

var title := ""
var value := 5.0
var resting := 5.0  # where a double-click puts it
var readout := ""
var ink := UI.INK      # its pointer
var arc := UI.ACCENT   # how far it is turned
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
	var turn := ARC_START + ARC_SWEEP * value / 10.0
	draw_arc(centre, RADIUS + 1, ARC_START, ARC_START + ARC_SWEEP, 48, Color(1, 1, 1, 0.1), 3.0, true)  # the way round it
	if value > 0.01:
		draw_arc(centre, RADIUS + 1, ARC_START, turn, 48, arc if not _dragging else arc.lightened(0.25), 3.0, true)
	draw_circle(centre, RADIUS - 5, UI.ROOM)
	draw_arc(centre, RADIUS - 5, 0, TAU, 40, UI.LINE_STRONG if not _dragging else Color(1, 1, 1, 0.4), 1.0, true)
	draw_line(centre, centre + Vector2(cos(turn), sin(turn)) * (RADIUS - 9), ink, 2.5, true)
	draw_string(font, Vector2(0, RADIUS * 2 + 26), title.to_upper(), HORIZONTAL_ALIGNMENT_CENTER, size.x, UI.LABEL_SIZE, UI.DIM)
	draw_string(font, Vector2(0, RADIUS * 2 + 41), readout if readout != "" else "%.1f" % value, HORIZONTAL_ALIGNMENT_CENTER, size.x, 12, UI.INK)


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed and (event.double_click or event.alt_pressed):
				_turn_to(resting)
			_dragging = event.pressed and not event.alt_pressed
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
