extends Control
## A small fader lying across, for a level with little room to show it (an instrument's level in the room, at the foot
## of its strip): its handle on the same scale as the mix window's faders (fader.gd: +12 dB at the right, silence at the
## left), a meter along its foot, and its level in dB in it. Drag it along (Shift for fine moves), turn the scroll wheel
## to nudge it, double-click or Alt-click it for 0 dB.

signal value_changed(db: float)

const Fader := preload("res://scripts/fader.gd")
const LevelMeter := preload("res://scripts/level_meter.gd")

var value := 0.0
var ink := Color(0.62, 0.65, 0.74)
var level := 0.0  # what its meter shows (linear): the peaks fed it each frame, falling back between them
var dim := false:  # drawn dimmer (muted)
	set(on):
		if on != dim:
			dim = on
			queue_redraw()
var _dragging := false
var _from_x := 0.0
var _from_place := 0.0


func _init() -> void:
	custom_minimum_size = Vector2(60, 20)
	focus_mode = Control.FOCUS_NONE
	mouse_filter = Control.MOUSE_FILTER_STOP


## A frame's peak (linear), for its meter.
func feed(peak: float) -> void:
	var shown := maxf(peak, level * 0.88)
	if absf(shown - level) > 1e-5:
		level = shown
		queue_redraw()


func set_value_no_signal(db: float) -> void:
	db = clampf(db, -80.0, 12.0)
	if db != value:
		value = db
		queue_redraw()


func _draw() -> void:
	var font := get_theme_default_font()
	var track := Rect2(Vector2(2, 4), Vector2(size.x - 4, size.y - 9))
	draw_rect(track, Color(0.06, 0.065, 0.08))
	var place: float = Fader.position_of(value)
	var x := track.position.x + place * track.size.x
	draw_rect(Rect2(track.position, Vector2(x - track.position.x, track.size.y)), Color(ink, 0.25 if dim else 0.45))
	var zero := track.position.x + Fader.position_of(0.0) * track.size.x  # 0 dB marked
	draw_line(Vector2(zero, track.position.y), Vector2(zero, track.end.y), Color(1, 1, 1, 0.25), 1.0)
	draw_rect(Rect2(Vector2(x - 2.5, 1), Vector2(5, size.y - 4)), Color(0.93, 0.94, 0.97) if not dim else Color(0.55, 0.57, 0.62))
	# Its meter, along the foot: -60 dB at the left to full scale at the right.
	var lit: float = clampf((linear_to_db(maxf(level, 1e-6)) + 60.0) / 60.0, 0.0, 1.0)
	draw_rect(Rect2(Vector2(2, size.y - 3), Vector2((size.x - 4) * lit, 2)), LevelMeter.GREEN if lit < 0.8 else LevelMeter.AMBER)
	var text := "-inf" if value <= -79.0 else "%+.1f" % value
	draw_string(font, Vector2(4, track.position.y + track.size.y - 2), text, HORIZONTAL_ALIGNMENT_LEFT, -1, 10, Color(0.93, 0.94, 0.97, 0.85))


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var e: InputEventMouseButton = event
		if e.button_index == MOUSE_BUTTON_LEFT:
			if e.pressed and (e.double_click or e.alt_pressed):
				_move_to(0.0)
			_dragging = e.pressed and not e.alt_pressed and not e.double_click
			_from_x = e.position.x
			_from_place = Fader.position_of(value)
			accept_event()
		elif e.pressed and e.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
			_move_to(value + (0.5 if e.button_index == MOUSE_BUTTON_WHEEL_UP else -0.5))
			accept_event()
	elif event is InputEventMouseMotion and _dragging:
		var e: InputEventMouseMotion = event
		var along := (e.position.x - _from_x) / maxf(size.x - 4.0, 1.0) * (0.2 if e.shift_pressed else 1.0)
		_move_to(snappedf(Fader.level_at(clampf(_from_place + along, 0.0, 1.0)), 0.1))
		accept_event()


func _move_to(db: float) -> void:
	db = clampf(db, -80.0, 12.0)
	if is_equal_approx(db, value):
		return
	value = db
	queue_redraw()
	value_changed.emit(db)
