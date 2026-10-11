extends Control
## A level meter: a bar for each channel, from -60 dB at the left to full scale at the right, with the highest
## recent peak held as a tick. Green up to -12 dB, amber up to -3, red above. Feed it every frame.

const FLOOR_DB := -60.0
const AMBER_DB := -12.0
const RED_DB := -3.0
const HOLD_SECONDS := 1.5
const FALL_DB_PER_SECOND := 40.0
const GREEN := Color(0.36, 0.83, 0.55)
const AMBER := Color(0.95, 0.77, 0.3)
const RED := Color(1.0, 0.4, 0.36)

var _bars: Array = []      # what each bar shows now, in dB: jumps up with the signal, falls back steadily
var _averages: Array = []  # the average level of each channel in dB, drawn brighter inside the bar
var _held: Array = []      # the tick: the highest peak lately
var _held_for: Array = []


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE


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
	var height := (size.y - gap * (count - 1)) / count
	for i in count:
		var y := i * (height + gap)
		draw_rect(Rect2(0, y, size.x, height), Color(1, 1, 1, 0.08))
		if i >= _bars.size():
			continue
		_stretch(y, height, _bars[i], 0.45)
		if i < _averages.size():
			_stretch(y, height, _averages[i], 1.0)
		if _held[i] > FLOOR_DB + 0.5:
			var x := clampf(_along(_held[i]) * size.x, 1.0, size.x - 1.0)
			draw_rect(Rect2(x - 1.0, y, 2.0, height), _ink(_held[i]))
	for mark in [AMBER_DB, RED_DB]:  # where the colours change
		draw_rect(Rect2(_along(mark) * size.x, 0, 1.0, size.y), Color(0, 0, 0, 0.5))


## A bar from the left up to `level`, in the colour of each zone it passes through.
func _stretch(y: float, height: float, level: float, alpha: float) -> void:
	var from := FLOOR_DB
	for zone in [[AMBER_DB, GREEN], [RED_DB, AMBER], [6.0, RED]]:
		var to := minf(level, zone[0])
		if to > from:
			draw_rect(Rect2(_along(from) * size.x, y, (_along(to) - _along(from)) * size.x, height), Color(zone[1], alpha))
		from = zone[0]


func _ink(level: float) -> Color:
	return RED if level > RED_DB else (AMBER if level > AMBER_DB else GREEN)


func _along(level: float) -> float:
	return clampf((level - FLOOR_DB) / -FLOOR_DB, 0.0, 1.0)


func _db(linear: float) -> float:
	return maxf(linear_to_db(maxf(linear, 0.000001)), FLOOR_DB)
