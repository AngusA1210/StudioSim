extends Control
## A level meter: a bar for each channel, from -60 dB at the left (or the bottom, if `vertical`) to full scale, with
## the highest recent peak held as a tick. Green up to -12 dB, amber up to -3, red above. Feed it every frame.
## A vertical meter can carry its decibel scale down its left side (`show_scale`), and can be clicked (`clickable`),
## as a DAW's meters are to clear their peaks: it says so with `pressed`.

signal pressed(alt: bool)

const FLOOR_DB := -60.0
const AMBER_DB := -12.0
const RED_DB := -3.0
const HOLD_SECONDS := 1.5
const FALL_DB_PER_SECOND := 40.0
const GREEN := Color(0.36, 0.83, 0.55)
const AMBER := Color(0.95, 0.77, 0.3)
const RED := Color(1.0, 0.4, 0.36)
const SCALE_WIDTH := 20.0
const SCALE_MARKS := [0.0, -6.0, -12.0, -24.0, -40.0, -60.0]

var vertical := false
var show_scale := false
var clickable := false
var _bars: Array = []      # what each bar shows now, in dB: jumps up with the signal, falls back steadily
var _averages: Array = []  # the average level of each channel in dB, drawn brighter inside the bar
var _held: Array = []      # the tick: the highest peak lately
var _held_for: Array = []


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP if clickable else Control.MOUSE_FILTER_IGNORE


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		pressed.emit(event.alt_pressed)
		accept_event()


## Lets go of the held peak ticks at once.
func clear_hold() -> void:
	for i in _held.size():
		_held[i] = _bars[i]
		_held_for[i] = 0.0
	queue_redraw()


## `peaks` (and optionally `averages`) are linear levels, one per channel, where 1 is full scale.
func feed(peaks: Array, averages: Array = []) -> void:
	if _bars.size() != peaks.size():
		_bars.resize(peaks.size())
		_bars.fill(FLOOR_DB)
		_held = _bars.duplicate()
		_held_for.resize(peaks.size())
		_held_for.fill(0.0)
	_averages.clear()
	for value in averages:
		_averages.append(_db(value))
	for i in peaks.size():
		var level := _db(peaks[i])
		_bars[i] = maxf(_bars[i], level)
		if level >= _held[i]:
			_held[i] = level
			_held_for[i] = 0.0


## The highest peak being held, over all channels, in dB.
func held_db() -> float:
	var highest := FLOOR_DB
	for value in _held:
		highest = maxf(highest, value)
	return highest


func _process(delta: float) -> void:
	if not is_visible_in_tree():
		return
	for i in _bars.size():
		_bars[i] = maxf(_bars[i] - FALL_DB_PER_SECOND * delta, FLOOR_DB)
		_held_for[i] += delta
		if _held_for[i] > HOLD_SECONDS:
			_held[i] = maxf(_held[i] - FALL_DB_PER_SECOND * delta, FLOOR_DB)
	queue_redraw()


func _draw() -> void:
	var count := maxi(_bars.size(), 1)
	var gap := 2.0 if count > 1 else 0.0
	var start := SCALE_WIDTH if show_scale and vertical else 0.0
	var across := ((size.x if vertical else size.y) - start - gap * (count - 1)) / count
	if start > 0.0:
		var font := get_theme_default_font()
		for mark in SCALE_MARKS:
			var y := size.y * (1.0 - _along(mark))
			draw_line(Vector2(start - 4, y), Vector2(start - 1, y), Color(1, 1, 1, 0.45), 1.0)
			draw_string(font, Vector2(0, clampf(y + 4, 9, size.y)), str(int(-mark)), HORIZONTAL_ALIGNMENT_RIGHT, start - 5, 9,
				Color(1, 1, 1, 0.5))
	for i in count:
		var at := start + i * (across + gap)
		_rect(at, across, 0.0, 1.0, Color(1, 1, 1, 0.08))
		if i >= _bars.size():
			continue
		_stretch(at, across, _bars[i], 0.45)
		if i < _averages.size():
			_stretch(at, across, _averages[i], 1.0)
		if _held[i] > FLOOR_DB + 0.5:
			var length := size.y if vertical else size.x
			var spot := clampf(_along(_held[i]), 1.0 / length, 1.0 - 1.0 / length)
			_rect(at, across, spot - 1.0 / length, spot + 1.0 / length, _ink(_held[i]))
	for mark in [AMBER_DB, RED_DB]:  # where the colours change
		var length := size.y if vertical else size.x
		_rect(start, (size.x if vertical else size.y) - start, _along(mark), _along(mark) + 1.0 / length, Color(0, 0, 0, 0.5))


## A bar from the floor up to `level`, in the colour of each zone it passes through.
func _stretch(at: float, across: float, level: float, alpha: float) -> void:
	var from := FLOOR_DB
	for zone in [[AMBER_DB, GREEN], [RED_DB, AMBER], [6.0, RED]]:
		var to := minf(level, zone[0])
		if to > from:
			_rect(at, across, _along(from), _along(to), Color(zone[1], alpha))
		from = zone[0]


## A rectangle `across` wide starting `at` across the meter, from `low` to `high` of the way along it (0 = -60 dB).
func _rect(at: float, across: float, low: float, high: float, color: Color) -> void:
	if vertical:
		draw_rect(Rect2(at, size.y * (1.0 - high), across, size.y * (high - low)), color)
	else:
		draw_rect(Rect2(size.x * low, at, size.x * (high - low), across), color)


func _ink(level: float) -> Color:
	return RED if level > RED_DB else (AMBER if level > AMBER_DB else GREEN)


func _along(level: float) -> float:
	return clampf((level - FLOOR_DB) / -FLOOR_DB, 0.0, 1.0)


func _db(linear: float) -> float:
	return maxf(linear_to_db(maxf(linear, 0.000001)), FLOOR_DB)
