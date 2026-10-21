extends Control
## The edit window's tracks along the timeline. A row for each instrument: its header on the left (its name in its
## colour; R arms it for recording, M mutes it, S solos it), and its lane, with its clips (audio drawn as its waveform,
## MIDI as its notes), across the bars. Above them the ruler: click it to put the playhead there, drag along it to
## loop that range. Click a clip to choose it (stopped, the playhead goes where you clicked, to split it there) and
## drag it along its track, or to another track that takes its kind (hold Option as you drop it for a copy); clips snap
## to the grid unless it is off. Drag either end of a clip to trim it, as Pro Tools' trim tool does, and an audio
## clip's top corners to fade it in or out (where two clips meet, the top of the seam crossfades them). Click an empty lane to put the playhead there. The scroll wheel and
## trackpad move about (Shift for along), Cmd and the wheel (or a pinch) zoom. The cursor and the hint line say what a
## press would do. Shift-click chooses more clips, to move (and edit) together. An audio clip's little fader at its foot
## is its clip gain: drag it up or down. A clip with takes (from loop recording) says how many; right-click it to choose
## one, or to show the takes under the track (as Pro Tools' playlists and Logic's take folders) and comp from them: drag
## along a take for that part of it in the track, or click a take to put it in place of the part of the track it is
## under; the parts of each take in the track are lit. Double-click a MIDI clip for its notes. With the automation lanes showing (A), each track has one under it: its
## buttons choose what it shows (volume, mute, an instrument's sustain pedal) and the track's automation mode; click
## in it to add a point, drag points to move them, Shift-click for more, Option-click to take one away.

const Hints := preload("res://scripts/hints.gd")
const TrackMenu := preload("res://scripts/track_menu.gd")
const Fader := preload("res://scripts/fader.gd")
const HEADER := 190.0
const RULER := 30.0
const ROW := 54.0
const DIM := Color(0.62, 0.65, 0.74)
const LOOP_ON := Color(0.35, 0.6, 1.0)
const RECORD_RED := Color(1.0, 0.3, 0.28)
const INPUT_GREEN := Color(0.36, 0.9, 0.5)
const MUTE_ORANGE := Color(1.0, 0.62, 0.25)
const SOLO_YELLOW := Color(0.98, 0.86, 0.3)
const NAME_STRIP := 15.0  # a clip's top strip, with its name: its corners hold the fade handles
const EDGE := 7.0         # how near an end of a clip a press trims it
const LANE := 46.0        # an automation lane, under its track (A shows them)
const TAKE := 38.0        # a take's lane, under its track while its takes show
const SHOW_TAKES := 1000  # the takes menu's item for showing them under the track (the others are the takes' numbers)
const POINT_GREEN := Color(0.45, 0.9, 0.55)

var app
var timeline
var zoom := 6.0       # pixels to a step (a bar is 96)
var scroll_x := 0.0   # the step at the lanes' left edge
var scroll_y := 0.0   # pixels the rows are scrolled up
var chosen: Array = []  # the clips chosen, [{inst, clip}] (the clip its Dictionary itself): Shift-click adds or takes one away
## The first clip chosen as {inst, index} ({} for none); setting it chooses just that one.
var selected: Dictionary:
	get:
		for it in chosen:
			var at: int = timeline.index_of(it.inst, it.clip) if app.instruments.has(it.inst) else -1
			if at >= 0:
				return {"inst": it.inst, "index": at}
		return {}
	set(value):
		chosen = [] if value.is_empty() else [{"inst": value.inst, "clip": value.inst.clips[value.index]}]
var show_automation := false  # A, as in Logic: a lane under each track for its automation
var chosen_points: Array = []  # the automation points chosen: [{track, param, point}] (the point its Array itself)
var _lane_menu: PopupMenu      # what a lane shows, or its track's automation mode
var _lane_menu_for := {}
var _lane_choices := []  # the params its menu offers, by id
var _takes_menu: PopupMenu  # a clip's takes, on a right-click
var _track_menu: PopupMenu  # a track's, on a right-click on its name
var _track_menu_for = null
var _colors: PopupMenu
var _modes: PopupMenu
var _takes_for := {}        # the clip it is for: {inst, clip}
var _drag := {}       # what a press is doing: moving a clip, or along the ruler


func setup(the_app) -> void:
	app = the_app
	timeline = app.timeline
	clip_contents = true
	mouse_filter = Control.MOUSE_FILTER_STOP
	focus_mode = Control.FOCUS_NONE
	Hints.give(self, func() -> String: return hint_at(get_local_mouse_position()))
	_make_fade_cursors()
	_takes_menu = PopupMenu.new()
	_takes_menu.id_pressed.connect(func(id: int) -> void:
		var at: int = timeline.index_of(_takes_for.inst, _takes_for.clip)
		if id == SHOW_TAKES:
			_takes_for.inst.takes_open = not _takes_for.inst.takes_open
		elif at >= 0 and id != int(_takes_for.clip.get("take", 0)):
			timeline.choose_take(_takes_for.inst, at, id)
			chosen = [{"inst": _takes_for.inst, "clip": _takes_for.inst.clips.back()}])
	add_child(_takes_menu)
	_lane_menu = PopupMenu.new()
	_lane_menu.id_pressed.connect(_on_lane_menu)
	add_child(_lane_menu)
	_track_menu = PopupMenu.new()
	_track_menu.id_pressed.connect(func(id: int) -> void: TrackMenu.chosen(app, _track_menu_for, id))
	add_child(_track_menu)
	_colors = TrackMenu.colors_menu(app, func(color: Color) -> void:
		if _track_menu_for != null and app.is_track(_track_menu_for):
			app.set_track_color(_track_menu_for, color))
	_track_menu.add_child(_colors)
	_modes = TrackMenu.modes_menu(app, func(mode: String) -> void:
		if _track_menu_for != null and app.is_track(_track_menu_for):
			app.automation.set_mode(_track_menu_for, mode))
	_track_menu.add_child(_modes)


func _process(_delta: float) -> void:
	if not is_visible_in_tree():
		return
	chosen = chosen_items()  # (less any undone, or whose track has gone)
	if _drag.is_empty():
		mouse_default_cursor_shape = cursor_at(get_local_mouse_position())
	if timeline.playing:  # keep the playhead in view
		var at: float = timeline.position()
		var span := (size.x - HEADER) / zoom
		if at < scroll_x or at > scroll_x + span * 0.9:
			scroll_x = maxf(at - span * 0.1, 0.0)
	queue_redraw()


## The fade cursors, as Pro Tools draws them: a small square with a fade's curve across it, rising for a fade in and
## falling for a fade out. They take the place of the diagonal resize cursors, which nothing else uses.
static func _make_fade_cursors() -> void:
	const SIZE := 22
	var ink := Color(0.06, 0.06, 0.07)
	for rising in [true, false]:
		var image := Image.create(SIZE, SIZE, false, Image.FORMAT_RGBA8)
		image.fill(Color(0, 0, 0, 0))
		for x in range(2, SIZE - 2):
			for y in range(2, SIZE - 2):
				var edge := x == 2 or y == 2 or x == SIZE - 3 or y == SIZE - 3
				image.set_pixel(x, y, ink if edge else Color(1, 1, 1, 0.95))
		var inner := SIZE - 6  # the square's inside, 3 to SIZE - 4
		var last_top := -1
		for i in inner:
			var t := float(i) / float(inner - 1)
			var top := SIZE - 4 - int(round(sin(0.5 * PI * (t if rising else 1.0 - t)) * (inner - 1)))
			for y in range(top, SIZE - 3):  # under the curve shaded, the curve itself dark
				image.set_pixel(3 + i, y, Color(0.56, 0.64, 0.86))
			for y in range(mini(top, last_top if last_top >= 0 else top), maxi(top, last_top if last_top >= 0 else top) + 1):
				image.set_pixel(3 + i, y, ink)
			last_top = top
		Input.set_custom_mouse_cursor(image, Input.CURSOR_BDIAGSIZE if rising else Input.CURSOR_FDIAGSIZE, Vector2(SIZE / 2, SIZE / 2))


## The clips chosen that are still on their tracks.
func chosen_items() -> Array:
	return chosen.filter(func(it): return app.instruments.has(it.inst) and timeline.index_of(it.inst, it.clip) >= 0)


func is_chosen(inst, clip: Dictionary) -> bool:
	return chosen.any(func(it): return it.inst == inst and is_same(it.clip, clip))


## Chooses every clip on every track (Cmd-A).
func choose_all() -> void:
	chosen = []
	for inst in app.instruments:
		for clip in inst.clips:
			chosen.append({"inst": inst, "clip": clip})


func x_of(step: float) -> float:
	return HEADER + (step - scroll_x) * zoom


func step_at(x: float) -> float:
	return scroll_x + (x - HEADER) / zoom


## How tall a track with one automation lane is: its row, and the lane while they show.
func row_height() -> float:
	return ROW + (LANE if show_automation else 0.0)


## How tall a track's place is: its row, its takes under it while they show, and its automation lanes while they do.
func height_of(track) -> float:
	return ROW + take_lanes(track) * TAKE + (LANE * track.lanes.size() if show_automation else 0.0)


## How many take lanes a track shows: as many as its loop recording with the most takes has, while its takes show.
func take_lanes(track) -> int:
	if not track.get("takes_open"):
		return 0
	var most := 0
	for clip in track.clips:
		most = maxi(most, clip.get("takes", []).size())
	return most


func take_top(i: int, n: int) -> float:
	return row_top(i) + ROW + n * TAKE


## The track whose take lane is at a height, and which: [row, take lane], or [] for none.
func take_at(y: float) -> Array:
	var i := _row_of(y)
	if i < 0:
		return []
	var below := y - row_top(i) - ROW
	var lanes := take_lanes(tracks()[i])
	return [i, int(floor(below / TAKE))] if below >= 0.0 and below < lanes * TAKE else []


func row_top(i: int) -> float:
	var y := RULER - scroll_y
	var rows := tracks()
	for k in mini(i, rows.size()):
		y += height_of(rows[k])
	return y


## The top of a track's automation lane `k` (its first, to begin with).
func lane_top(i: int, k := 0) -> float:
	return row_top(i) + ROW + take_lanes(tracks()[i]) * TAKE + k * LANE


## The track whose place (its row and its lanes) is at a height, or -1 below the last.
func _row_of(y: float) -> int:
	if y < RULER:
		return -1
	var top := RULER - scroll_y
	var rows := tracks()
	for i in rows.size():
		var height := height_of(rows[i])
		if y < top + height:
			return i
		top += height
	return -1


## The track whose row is at a height (not one of its lanes), or -1.
func row_at(y: float) -> int:
	var i := _row_of(y)
	return i if i >= 0 and y - row_top(i) < ROW else -1


## The track whose automation lane is at a height, or -1 (lane_number_at says which of its lanes).
func lane_at(y: float) -> int:
	var i := _row_of(y)
	return i if show_automation and i >= 0 and y >= lane_top(i) else -1


func lane_number_at(y: float, i: int) -> int:
	return clampi(int(floor((y - lane_top(i)) / LANE)), 0, tracks()[i].lanes.size() - 1)


## The track whose place (its row or its lanes) is at a height, for dragging clips over them.
func row_near(y: float) -> int:
	var i := _row_of(y)
	return clampi(i if i >= 0 else tracks().size() - 1, 0, maxi(tracks().size() - 1, 0))


func _most_scroll() -> float:
	var total := 0.0
	for track in tracks():
		total += height_of(track)
	return maxf(total - (size.y - RULER), 0.0)


## The rows: every track in order, each folder before its tracks (those of a folder that is closed left out, and of
## one inside it), the aux tracks not in a folder after them, and the master at the foot.
func tracks() -> Array:
	return app.track_order().filter(func(t): return app.folders_around(t).all(func(f): return f.open)) + app.master_tracks()


## How far a track's header is set in: by as many folders as it is in.
func _indent(track) -> float:
	return 10.0 * mini(app.folders_around(track).size(), 4)


# ── Drawing ──────────────────────────────────────────────────────────────────────────────────────────────────

func _draw() -> void:
	var font := get_theme_default_font()
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.08, 0.085, 0.1))
	var first_bar := int(floor(scroll_x / timeline.STEPS_PER_BAR))
	var last_step := step_at(size.x)
	# The lanes, with the bars and beats across them, and their clips.
	for i in tracks().size():
		var inst = tracks()[i]
		var top := row_top(i)
		if top > size.y or top + height_of(inst) < RULER:
			continue
		draw_rect(Rect2(HEADER, top, size.x - HEADER, ROW - 1), Color(0.07, 0.075, 0.09) if inst.is_folder else
			(Color(0.12, 0.125, 0.145) if i % 2 == 0 else Color(0.105, 0.11, 0.13)))
		var step := float(first_bar * 4)
		while step <= last_step:
			var x := x_of(step)
			if x >= HEADER:
				draw_line(Vector2(x, top), Vector2(x, top + ROW - 1), Color(1, 1, 1, 0.12 if int(step) % 16 == 0 else 0.04))
			step += 4.0
		for n in take_lanes(inst):
			_draw_take_lane(inst, n, top + ROW + n * TAKE, font, first_bar, last_step)
		if show_automation:
			for k in inst.lanes.size():
				_draw_lane(inst, k, lane_top(i, k), font, first_bar, last_step)
		if inst.is_folder:  # a folder's lane: no clips of its own
			_draw_header(inst, top, font)
			continue
		for c in inst.clips.size():
			_draw_clip(inst, c, top, font)
		for c in inst.clips.size():
			_draw_crossfade(inst, c, top)
		if timeline.recording and inst.armed:  # the take so far
			var from := x_of(_record_from())
			var to := x_of(timeline.position())
			draw_rect(Rect2(maxf(from, HEADER), top + 2, maxf(to - maxf(from, HEADER), 0.0), ROW - 5), Color(RECORD_RED, 0.28))
		_draw_header(inst, top, font)
	# The ruler: the bars, and the loop range.
	draw_rect(Rect2(0, 0, size.x, RULER), Color(0.14, 0.145, 0.17))
	var band := Rect2(maxf(x_of(timeline.loop_start), HEADER), 2, 0, 9)
	band.size.x = maxf(x_of(timeline.loop_end) - band.position.x, 0.0)
	var punching: bool = app.settings.punch and not app.settings.loop_record  # (the range is where recording punches in and out: red)
	draw_rect(band, RECORD_RED if punching else (LOOP_ON if timeline.loop_on else Color(0.45, 0.47, 0.52)))
	if _drag.get("what", "") == "ruler" and _drag.has("loop"):
		var r := Rect2(x_of(_drag.loop.x), 2, (_drag.loop.y - _drag.loop.x) * zoom, 9)
		draw_rect(r, Color(LOOP_ON, 0.6))
	var bar := first_bar
	while x_of(bar * 16.0) < size.x:
		var x := x_of(bar * 16.0)
		if x >= HEADER:
			draw_line(Vector2(x, 12), Vector2(x, RULER), Color(1, 1, 1, 0.4))
			draw_string(font, Vector2(x + 4, RULER - 5), str(bar + 1), HORIZONTAL_ALIGNMENT_LEFT, -1, 12, DIM)
		bar += 1
	draw_rect(Rect2(0, 0, HEADER, RULER), Color(0.14, 0.145, 0.17))
	draw_string(font, Vector2(12, RULER - 9), "Tracks", HORIZONTAL_ALIGNMENT_LEFT, -1, 13, DIM)
	# The playhead.
	var head := x_of(timeline.position())
	if head >= HEADER:
		var ink := RECORD_RED if timeline.recording else Color(1, 1, 1, 0.9)
		draw_line(Vector2(head, 0), Vector2(head, size.y), ink, 1.5)
		draw_colored_polygon(PackedVector2Array([Vector2(head - 6, 12), Vector2(head + 6, 12), Vector2(head, 20)]), ink)
	# Clips being moved: where they would land.
	if _drag.get("what", "") == "clip" and _drag.get("moved", false):
		for it in _drag.items:
			var span: Vector2 = timeline.clip_steps(it.clip)
			var top := row_top(tracks().find(it.inst) + _drag.rows)
			draw_rect(Rect2(x_of(span.x + _drag.delta), top + 2, (span.y - span.x) * zoom, ROW - 5), Color(1, 1, 1, 0.6), false, 2.0)


func _record_from() -> float:
	return timeline._started_at if timeline.playing else timeline.playhead


func _draw_clip(inst, index: int, top: float, font: Font) -> void:
	var clip: Dictionary = inst.clips[index]
	var span: Vector2 = timeline.clip_steps(clip)
	var x0 := x_of(span.x)
	var x1 := x_of(span.y)
	if x1 < HEADER or x0 > size.x:
		return
	var rect := Rect2(maxf(x0, HEADER), top + 2, minf(x1, size.x) - maxf(x0, HEADER), ROW - 5)
	var picked := is_chosen(inst, clip)
	draw_rect(rect, inst.color.darkened(0.55 if not picked else 0.25))
	var ink: Color = inst.color.lightened(0.4)
	var inner := Rect2(rect.position + Vector2(0, 15), Vector2(rect.size.x, rect.size.y - 17))
	_draw_contents(clip, span, inner, ink)
	if clip.kind == "audio":
		_draw_fades(clip, x0, x1, inner, rect, ink)
	draw_rect(rect, Color.WHITE if picked else Color(0, 0, 0, 0.6), false, 1.0)
	var takes: int = clip.get("takes", []).size()
	var takes_text := "%d takes" % takes if takes > 0 else ""
	var takes_width := font.get_string_size(takes_text, HORIZONTAL_ALIGNMENT_LEFT, -1, 10).x + 8 if takes > 0 else 0.0
	draw_string(font, rect.position + Vector2(5, 12), str(clip.get("name", "")), HORIZONTAL_ALIGNMENT_LEFT, maxf(rect.size.x - 8 - takes_width, 1.0), 11, ink)
	if takes > 0 and rect.size.x > takes_width + 30:  # it has takes to choose from (a right-click)
		draw_string(font, Vector2(rect.end.x - takes_width + 2, rect.position.y + 12), takes_text, HORIZONTAL_ALIGNMENT_LEFT, -1, 10, Color(ink, 0.75))
	if clip.kind == "audio" and x0 >= HEADER and x1 - x0 >= 44.0:  # its clip gain: a little fader, and the gain if it has one
		var knob := _gain_rect(x0, top)
		draw_line(Vector2(knob.position.x + 5, knob.position.y + 1), Vector2(knob.position.x + 5, knob.end.y - 1), Color(ink, 0.7), 1.0)
		var db := float(clip.get("gain_db", 0.0))
		var y := knob.end.y - 3 - (clampf(db, -24.0, 24.0) + 24.0) / 48.0 * (knob.size.y - 6)
		draw_rect(Rect2(knob.position.x + 2, y - 1.5, 7, 3), ink)
		if absf(db) >= 0.05:
			draw_string(font, Vector2(knob.end.x + 1, knob.end.y - 2), "-inf dB" if db <= timeline.MIN_CLIP_GAIN_DB else "%+.1f dB" % db,
				HORIZONTAL_ALIGNMENT_LEFT, -1, 10, Color(ink, 0.9))


## A track's take lane `n`: each of its loop recordings' take n+1 (they are numbered from 1), the parts of it in the
## track lit, and what a drag along it would put in.
func _draw_take_lane(inst, n: int, top: float, font: Font, first_bar: int, last_step: float) -> void:
	draw_rect(Rect2(HEADER, top, size.x - HEADER, TAKE - 1), Color(0.075, 0.08, 0.095))
	var step := float(first_bar * 4)
	while step <= last_step:
		if x_of(step) >= HEADER:
			draw_line(Vector2(x_of(step), top), Vector2(x_of(step), top + TAKE - 1), Color(1, 1, 1, 0.08 if int(step) % 16 == 0 else 0.03))
		step += 4.0
	var ink: Color = inst.color.lightened(0.3)
	for group in timeline.take_groups(inst):
		if n >= group.takes.size():
			continue
		var take: Dictionary = group.takes[n]
		var span: Vector2 = timeline.clip_steps(take)
		var x0 := x_of(span.x)
		var x1 := x_of(span.y)
		if x1 < HEADER or x0 > size.x:
			continue
		var rect := Rect2(maxf(x0, HEADER), top + 2, minf(x1, size.x) - maxf(x0, HEADER), TAKE - 5)
		draw_rect(rect, inst.color.darkened(0.7))
		for clip in inst.clips:  # the parts of it in the track
			if timeline.group_of(clip) == group.group and int(clip.get("take", 0)) == int(take.get("take", 0)):
				var used: Vector2 = timeline.clip_steps(clip)
				var lit := Rect2(maxf(x_of(used.x), rect.position.x), rect.position.y, 0, rect.size.y)
				lit.size.x = minf(x_of(used.y), rect.end.x) - lit.position.x
				if lit.size.x > 0.0:
					draw_rect(lit, inst.color.darkened(0.35))
		_draw_contents(take, span, Rect2(rect.position + Vector2(0, 12), Vector2(rect.size.x, rect.size.y - 13)), Color(ink, 0.85))
		draw_rect(rect, Color(0, 0, 0, 0.6), false, 1.0)
		draw_string(font, rect.position + Vector2(5, 10), "Take %d" % int(take.get("take", n + 1)), HORIZONTAL_ALIGNMENT_LEFT,
			maxf(rect.size.x - 8, 1.0), 10, ink)
	if _drag.get("what", "") == "comp" and _drag.inst == inst and _drag.lane == n and _drag.get("moved", false):
		var a := x_of(minf(_drag.from, _drag.to))
		var b := x_of(maxf(_drag.from, _drag.to))
		draw_rect(Rect2(maxf(a, HEADER), top + 1, maxf(b - maxf(a, HEADER), 0.0), TAKE - 3), Color(1, 1, 1, 0.75), false, 2.0)
	draw_rect(Rect2(0, top, HEADER, TAKE - 1), Color(0.11, 0.115, 0.13))
	draw_rect(Rect2(_indent(inst), top, 5, TAKE - 1), Color(inst.color, 0.6))
	draw_string(font, Vector2(14 + _indent(inst), top + 23), "Take %d" % (n + 1), HORIZONTAL_ALIGNMENT_LEFT, HEADER - 20, 12, DIM)


## What a clip holds, drawn in a rectangle: an audio clip's waveform (as its clip gain makes it), a MIDI clip's notes.
func _draw_contents(clip: Dictionary, span: Vector2, inner: Rect2, ink: Color) -> void:
	if clip.kind == "audio":  # its waveform, as its clip gain makes it
		var peaks: PackedFloat32Array = timeline.peaks(clip)
		var gain: float = timeline.gain_of(clip)
		var seconds_per_px: float = timeline.step_seconds() / zoom
		var mid := inner.position.y + inner.size.y / 2
		var x := inner.position.x
		while x < inner.end.x and not peaks.is_empty():
			var t: float = float(clip.offset) + (step_at(x) - span.x) * timeline.step_seconds()
			var i := int(t * 100.0)
			if i >= 0 and i < peaks.size():
				var h := minf(peaks[i] * gain, 1.0) * inner.size.y / 2
				draw_line(Vector2(x, mid - h), Vector2(x, mid + h), Color(ink, 0.8))
			x += 1.0
	elif clip.kind == "midi" and not clip.notes.is_empty():  # its notes, highest at the top
		var low := 127
		var high := 0
		for n in clip.notes:
			low = mini(low, int(n.note))
			high = maxi(high, int(n.note))
		var spread := maxf(high - low, 12)
		for n in clip.notes:
			if float(n.step) < 0.0 or float(n.step) >= float(clip.length):  # trimmed off
				continue
			var nx := x_of(span.x + float(n.step))
			var ny := inner.end.y - 3 - (int(n.note) - low) / spread * (inner.size.y - 6)
			var w := maxf(float(n.length) * zoom, 2.0)
			if nx + w > inner.position.x and nx < inner.end.x:
				draw_rect(Rect2(maxf(nx, inner.position.x), ny - 1.5, minf(w, inner.end.x - maxf(nx, inner.position.x)), 3), ink)


## Where an audio clip's clip-gain fader is, at its foot by its start.
func _gain_rect(x0: float, top: float) -> Rect2:
	return Rect2(x0 + EDGE + 4.0, top + ROW - 19, 11, 15)


## A track's automation lane `k`: on its left what it shows (its menu), the track's automation mode (its menu), and
## buttons for another lane (+) and none of this one (×); along it the points and the line between them, as the audio
## core plays it.
func _draw_lane(track, k: int, top: float, font: Font, first_bar: int, last_step: float) -> void:
	var auto = app.automation
	var param: String = track.lanes[k]
	var lane: Array = auto.points(track, param)
	var off: bool = track.auto_mode == "off"
	draw_rect(Rect2(HEADER, top, size.x - HEADER, LANE - 1), Color(0.085, 0.09, 0.105))
	var step := float(first_bar * 4)
	while step <= last_step:
		if x_of(step) >= HEADER:
			draw_line(Vector2(x_of(step), top), Vector2(x_of(step), top + LANE - 1), Color(1, 1, 1, 0.08 if int(step) % 16 == 0 else 0.03))
		step += 4.0
	var ink: Color = track.color.lightened(0.35)
	ink.a = 0.4 if off else 1.0
	var writing: Array = auto._writing.get(track, {}).get(param, [])
	if lane.is_empty():  # where it is without any: the control as it is
		var y := _lane_y(auto.now(track, param), param, top)
		draw_dashed_line(Vector2(HEADER, y), Vector2(size.x, y), Color(ink, 0.45 * ink.a), 1.0, 4.0)
	else:
		var last := Vector2(HEADER, _lane_y(float(lane[0][1]), param, top))
		for p in lane:
			var at := Vector2(x_of(float(p[0])), _lane_y(float(p[1]), param, top))
			if auto.is_switch(param):  # on or off from each point: a step
				draw_line(last, Vector2(at.x, last.y), ink, 1.5)
				draw_line(Vector2(at.x, last.y), at, ink, 1.5)
			else:
				draw_line(last, at, ink, 1.5)
			last = at
		draw_line(last, Vector2(size.x, last.y), ink, 1.5)
		for p in lane:
			var at := Vector2(x_of(float(p[0])), _lane_y(float(p[1]), param, top))
			if at.x >= HEADER - 3 and at.x <= size.x + 3:
				var picked := chosen_points.any(func(c): return is_same(c.point, p))
				draw_rect(Rect2(at - Vector2(3, 3), Vector2(6, 6)), Color.WHITE if picked else ink)
	if writing.size() > 1:  # what is being written, as it is
		for i in range(1, writing.size()):
			draw_line(Vector2(x_of(float(writing[i - 1][0])), _lane_y(float(writing[i - 1][1]), param, top)),
				Vector2(x_of(float(writing[i][0])), _lane_y(float(writing[i][1]), param, top)), RECORD_RED, 2.0)
	# Its header: what it shows, the mode, another lane and none of this one; and the value where the music is.
	draw_rect(Rect2(0, top, HEADER, LANE - 1), Color(0.12, 0.125, 0.14))
	draw_rect(Rect2(0, top, 5, LANE - 1), Color(track.color, 0.5))
	for b in _lane_buttons(track, top, k):
		draw_rect(b.rect, b.color)
		draw_string(font, b.rect.position + Vector2(4, 13), b.text, HORIZONTAL_ALIGNMENT_LEFT, b.rect.size.x - 6, 11, Color(0.9, 0.91, 0.94))
	var now: float = auto.value_at(lane, param, timeline.position()) if not lane.is_empty() else auto.now(track, param)
	draw_string(font, Vector2(14, top + 38), auto.value_text(track, param, now), HORIZONTAL_ALIGNMENT_LEFT, HEADER - 20, 11, DIM)


## A lane's buttons: what it shows, the track's automation mode, another lane (+) and none of this one (×).
func _lane_buttons(track, top: float, k := 0) -> Array:
	var param: String = track.lanes[k]
	var mode_color: Color = {"off": Color(0.3, 0.31, 0.34), "read": Color(0.24, 0.45, 0.32), "touch": Color(0.62, 0.45, 0.18),
		"latch": Color(0.6, 0.38, 0.2), "write": Color(0.7, 0.24, 0.22)}[track.auto_mode]
	var out := [
		{"what": "param", "text": "%s ▾" % app.automation.name_of(track, param), "rect": Rect2(10, top + 6, 88, 18), "color": Color(0.22, 0.23, 0.27)},
		{"what": "mode", "text": "%s ▾" % app.automation.MODE_NAMES[track.auto_mode], "rect": Rect2(101, top + 6, 50, 18), "color": mode_color},
	]
	if not track.get("is_master"):
		out.append({"what": "add", "text": "+", "rect": Rect2(154, top + 6, 16, 18), "color": Color(0.22, 0.23, 0.27)})
	if track.lanes.size() > 1:
		out.append({"what": "remove", "text": "×", "rect": Rect2(172, top + 6, 16, 18), "color": Color(0.22, 0.23, 0.27)})
	return out


## Where a value is drawn in a lane: on the fader's own scale (volume, sends), across a knob's or a control's range,
## or a switch at its top (on) or foot (off).
func _lane_y(value: float, param: String, top: float) -> float:
	if app.automation.is_switch(param):
		return top + 8 if value > 0.5 else top + LANE - 9
	return top + 4 + (1.0 - app.automation.height_of(param, value)) * (LANE - 9)


## The value a height in a lane stands for.
func _lane_value(y: float, param: String, top: float) -> float:
	if app.automation.is_switch(param):
		return 1.0 if y < top + LANE / 2 else 0.0
	return app.automation.value_from(param, 1.0 - (y - top - 4) / (LANE - 9))


## The lane menus: what a lane shows (the track's own controls, then each plug-in's in a submenu of its own), or the
## track's automation mode.
func _show_lane_menu(track, k: int, what: String, at: Vector2) -> void:
	_lane_menu_for = {"track": track, "lane": k, "what": what}
	_lane_menu.clear()
	for child in _lane_menu.get_children():
		child.queue_free()
	_lane_choices = []
	if what == "param":
		var params: Array = app.automation.params_for(track)
		for param in params:
			_lane_menu.add_radio_check_item(app.automation.name_of(track, param), _lane_choices.size())
			_lane_menu.set_item_checked(_lane_menu.item_count - 1, param == track.lanes[k])
			_lane_choices.append(param)
		for plugin in app.automation.plugin_params(track):
			var sub := PopupMenu.new()
			for control in plugin.params:
				sub.add_radio_check_item(control.name, _lane_choices.size())
				sub.set_item_checked(sub.item_count - 1, control.param == track.lanes[k])
				_lane_choices.append(control.param)
			sub.id_pressed.connect(_on_lane_menu)
			_lane_menu.add_child(sub)
			_lane_menu.add_submenu_node_item(plugin.name, sub)
	else:
		for i in app.automation.MODES.size():
			_lane_menu.add_radio_check_item(app.automation.MODE_NAMES[app.automation.MODES[i]], i)
			_lane_menu.set_item_checked(i, app.automation.MODES[i] == track.auto_mode)
	_lane_menu.position = Vector2i(get_screen_position() + at)
	_lane_menu.popup()


func _on_lane_menu(id: int) -> void:
	var track = _lane_menu_for.get("track")
	if track == null or not (app.has_track(track) or app.master_tracks().has(track)):
		return
	if _lane_menu_for.what == "param":
		if id >= 0 and id < _lane_choices.size():
			show_param(track, _lane_menu_for.lane, _lane_choices[id])
	else:
		app.automation.set_mode(track, app.automation.MODES[id])


## A lane shows a param (one shown in another of the track's lanes trades places with it).
func show_param(track, k: int, param: String) -> void:
	var already: int = track.lanes.find(param)
	if already >= 0:
		track.lanes[already] = track.lanes[k]
	track.lanes[k] = param
	chosen_points = []
	if app.automation.is_plugin(param) or app.automation.is_knob(param) or param.begins_with("send:"):
		timeline.sync(track)  # (the audio core plays every control with points: nothing new, but its lanes are read anew)


## Another lane under a track: the first of its controls it doesn't show yet.
func add_lane(track) -> void:
	var choices: Array = app.automation.params_for(track)
	for plugin in app.automation.plugin_params(track):
		for control in plugin.params:
			choices.append(control.param)
	for param in choices:
		if not track.lanes.has(param):
			track.lanes.append(param)
			return


## A crossfade where clip `c` meets the next: the two curves crossing over the seam, in a box.
func _draw_crossfade(inst, c: int, top: float) -> void:
	var span: Vector2 = timeline.crossfade_span(inst, c)
	if span.x + span.y <= 0.0:
		return
	var px_per_second: float = zoom / timeline.step_seconds()
	var seam := x_of(timeline.clip_steps(inst.clips[c]).y)
	var x0 := seam - span.x * px_per_second
	var x1 := seam + span.y * px_per_second
	if x1 < HEADER or x0 > size.x:
		return
	var box := Rect2(maxf(x0, HEADER), top + 2 + NAME_STRIP, minf(x1, size.x) - maxf(x0, HEADER), ROW - 7 - NAME_STRIP)
	draw_rect(box, Color(0, 0, 0, 0.25))
	var ink: Color = inst.color.lightened(0.5)
	var width := x1 - x0
	var last_out := Vector2.INF
	var last_in := Vector2.INF
	var d := 0.0
	while d <= width:
		var x := x0 + d
		var t := d / maxf(width, 1.0)
		var y_out: float = box.end.y - cos(0.5 * PI * t) * box.size.y
		var y_in: float = box.end.y - sin(0.5 * PI * t) * box.size.y
		if x >= box.position.x and x <= box.end.x:
			if last_out != Vector2.INF:
				draw_line(last_out, Vector2(x, y_out), ink, 1.2)
				draw_line(last_in, Vector2(x, y_in), ink, 1.2)
			last_out = Vector2(x, y_out)
			last_in = Vector2(x, y_in)
		d += 1.0
	draw_rect(box, Color(ink, 0.7), false, 1.0)


## An audio clip's fades: the part they take down shaded, the curve drawn over the waveform, and a handle at each top
## corner (at the fade's end) to drag.
func _draw_fades(clip: Dictionary, x0: float, x1: float, inner: Rect2, rect: Rect2, ink: Color) -> void:
	var px_per_second: float = zoom / timeline.step_seconds()
	var fade_in: float = float(clip.get("fade_in", 0.0)) * px_per_second
	var fade_out: float = float(clip.get("fade_out", 0.0)) * px_per_second
	for side in [[x0, fade_in, 1.0], [x1, fade_out, -1.0]]:
		var from: float = side[0]
		var width: float = side[1]
		var way: float = side[2]
		if width >= 1.0:
			var last := Vector2.INF
			var d := 0.0
			while d <= width:
				var x: float = from + d * way
				var y: float = inner.end.y - sin(0.5 * PI * d / width) * inner.size.y
				if x >= rect.position.x and x <= rect.end.x:
					draw_line(Vector2(x, inner.position.y), Vector2(x, y), Color(0, 0, 0, 0.32))
					if last != Vector2.INF:
						draw_line(last, Vector2(x, y), Color(ink, 0.95), 1.2)
					last = Vector2(x, y)
				d += 1.0
		var handle: float = from + width * way
		if handle >= rect.position.x and handle <= rect.end.x:
			draw_rect(Rect2(handle - 3.0, rect.position.y + 1.0, 6.0, 6.0), Color(ink, 0.9))


func _draw_header(inst, top: float, font: Font) -> void:
	var chosen_track: bool = app.chosen_tracks.has(inst)
	var indent := _indent(inst)  # a folder's tracks, under it
	draw_rect(Rect2(0, top, HEADER, ROW - 1), Color(0.24, 0.26, 0.31) if chosen_track else Color(0.16, 0.17, 0.19))
	draw_rect(Rect2(indent, top, 5, ROW - 1), inst.color)
	var name_x := 12.0 + indent
	if _folds(inst):  # its arrow, to show or hide its tracks
		draw_string(font, Vector2(10 + indent, top + 20), "▾" if inst.open else "▸", HORIZONTAL_ALIGNMENT_LEFT, -1, 13, inst.color.lightened(0.45))
		name_x = 26.0 + indent
	draw_string(font, Vector2(name_x, top + 20), inst.display_name, HORIZONTAL_ALIGNMENT_LEFT, HEADER - name_x - 8, 13, inst.color.lightened(0.45))
	var what: String
	if inst.get("is_master"):
		what = "master"
	elif inst.is_aux:
		what = "aux"
	elif inst.is_folder:
		what = "folder · %d" % inst.members.size()
	else:
		what = ("stereo mic" if inst.is_stereo_mic else "mic") if inst.is_mic else ("audio" if not inst.playable else "MIDI")
	draw_string(font, Vector2(name_x, top + 40), what, HORIZONTAL_ALIGNMENT_LEFT, 60, 11, DIM)
	for b in _buttons(inst, top):
		var lit: bool = b.on
		draw_rect(b.rect, b.color if lit else Color(0.3, 0.31, 0.34))
		draw_string(font, b.rect.position + Vector2(5, 14), b.text, HORIZONTAL_ALIGNMENT_LEFT, -1, 12,
			Color(0.08, 0.08, 0.09) if lit else Color(0.85, 0.86, 0.9))


## A track's header buttons: R (armed), I (input), M (muted), S (soloed).
## Whether a row folds its tracks away (a folder's does; an aux's and the master's don't).
static func _folds(track) -> bool:
	return track.is_folder and not track.is_aux and not track.get("is_master")


func _buttons(inst, top: float) -> Array:
	var y := top + 28
	if inst.get("is_master"):
		return []
	if inst.is_folder:  # (a folder records nothing, and takes no input)
		return [
			{"what": "mute", "text": "M", "on": inst.muted, "color": MUTE_ORANGE, "rect": Rect2(126, y, 20, 19)},
			{"what": "solo", "text": "S", "on": inst.soloed, "color": SOLO_YELLOW, "rect": Rect2(150, y, 20, 19)},
		]
	return [
		{"what": "arm", "text": "R", "on": inst.armed, "color": RECORD_RED, "rect": Rect2(78, y, 20, 19)},
		{"what": "input", "text": "I", "on": inst.input_on, "color": INPUT_GREEN, "rect": Rect2(102, y, 20, 19)},
		{"what": "mute", "text": "M", "on": inst.muted, "color": MUTE_ORANGE, "rect": Rect2(126, y, 20, 19)},
		{"what": "solo", "text": "S", "on": inst.soloed, "color": SOLO_YELLOW, "rect": Rect2(150, y, 20, 19)},
	]


# ── The mouse ────────────────────────────────────────────────────────────────────────────────────────────────

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		_on_button(event)
	elif event is InputEventMouseMotion and not _drag.is_empty():
		_on_drag(event.position)
	elif event is InputEventPanGesture:
		scroll_x = maxf(scroll_x + event.delta.x * 6.0 / zoom, 0.0)
		scroll_y = clampf(scroll_y + event.delta.y * 12.0, 0.0, _most_scroll())
	elif event is InputEventMagnifyGesture:
		set_zoom(zoom * event.factor, event.position.x)


func set_zoom(new_zoom: float, around_x := -1.0) -> void:
	var x := around_x if around_x >= HEADER else HEADER + (size.x - HEADER) / 2
	var anchor := step_at(x)
	zoom = clampf(new_zoom, 0.75, 48.0)
	scroll_x = maxf(anchor - (x - HEADER) / zoom, 0.0)


func _on_button(e: InputEventMouseButton) -> void:
	if e.pressed and e.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN, MOUSE_BUTTON_WHEEL_LEFT, MOUSE_BUTTON_WHEEL_RIGHT]:
		var amount := -1.0 if e.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_LEFT] else 1.0
		if e.meta_pressed or e.ctrl_pressed:
			set_zoom(zoom * (1.15 if amount < 0 else 1.0 / 1.15), e.position.x)
		elif e.shift_pressed or e.button_index in [MOUSE_BUTTON_WHEEL_LEFT, MOUSE_BUTTON_WHEEL_RIGHT]:
			scroll_x = maxf(scroll_x + amount * 40.0 / zoom, 0.0)
		else:
			scroll_y = clampf(scroll_y + amount * ROW * 0.5, 0.0, _most_scroll())
		accept_event()
		return
	if e.button_index == MOUSE_BUTTON_RIGHT and e.pressed:
		var found := zone_at(e.position)
		if found.get("zone", "") == "clip":
			show_takes(found.inst, found.index, e.position)
		elif found.get("zone", "") == "header":
			show_track_menu(found.inst, e.position)
		accept_event()
		return
	if e.button_index != MOUSE_BUTTON_LEFT:
		return
	accept_event()
	if e.pressed and e.double_click:  # a MIDI clip's notes, in the MIDI editor; a track's name, renamed
		var found := zone_at(e.position)
		if found.get("zone", "") == "clip" and found.inst.clips[found.index].kind == "midi":
			_drag = {}
			app.edit_window.edit_notes(found.inst, found.index)
			return
		if found.get("zone", "") == "header" and not _buttons(found.inst, row_top(found.row)).any(func(b): return b.rect.has_point(e.position)) and \
				not (_folds(found.inst) and e.position.x < 24.0 + _indent(found.inst)) and not found.inst.get("is_master"):
			app.ask_track_name(found.inst)
			return
	if e.pressed:
		press(e.position, e.alt_pressed, e.shift_pressed, e.meta_pressed or e.ctrl_pressed)
	else:
		release(e.position, e.alt_pressed)


## What is at a point: {zone, inst, index, row}, the zone one of "ruler", "header", "xfade" (the top of a seam where two
## audio clips meet: `index` is the first), "fade_in", "fade_out" (an audio clip's top corners), "trim_start", "trim_end"
## (a clip's ends), "clip", "track" (an empty part of its row), or nothing.
func zone_at(at: Vector2) -> Dictionary:
	if at.y < 0.0 or at.x < 0.0 or at.x > size.x or at.y > size.y:
		return {}
	if at.y < RULER:
		return {"zone": "ruler"} if at.x >= HEADER else {}
	var take := take_at(at.y)
	if not take.is_empty():
		return _take_zone(tracks()[take[0]], take[0], take[1], at)
	var lane_row := lane_at(at.y)
	if lane_row >= 0 and lane_row < tracks().size():
		return _lane_zone(tracks()[lane_row], lane_row, at)
	var row := row_at(at.y)
	if row < 0 or row >= tracks().size():
		return {}
	var inst = tracks()[row]
	if at.x < HEADER:
		return {"zone": "header", "inst": inst, "row": row}
	if inst.is_folder:
		return {"zone": "track", "inst": inst, "row": row}
	var top := row_top(row)
	if at.y < top + 2.0 + NAME_STRIP:  # the top of a seam: a crossfade
		for c in inst.clips.size():
			if timeline._meets(inst, c) < 0:
				continue
			var span: Vector2 = timeline.crossfade_span(inst, c)
			var px_per_second: float = zoom / timeline.step_seconds()
			var seam := x_of(timeline.clip_steps(inst.clips[c]).y)
			if at.x >= seam - span.x * px_per_second - EDGE and at.x <= seam + span.y * px_per_second + EDGE:
				return {"zone": "xfade", "inst": inst, "index": c, "row": row}
	for c in range(inst.clips.size() - 1, -1, -1):  # the one on top
		var clip: Dictionary = inst.clips[c]
		var span: Vector2 = timeline.clip_steps(clip)
		var x0 := x_of(span.x)
		var x1 := x_of(span.y)
		if at.x < x0 - 2.0 or at.x > x1 + 2.0:
			continue
		var found := {"inst": inst, "index": c, "row": row, "zone": "clip"}
		var edge := minf(EDGE, (x1 - x0) / 4.0)  # a short clip keeps its middle for moving
		if clip.kind == "audio" and x1 - x0 >= 44.0 and at.x - x0 > edge and _gain_rect(x0, top).grow(2.0).has_point(at):
			found.zone = "gain"
		elif clip.kind == "audio" and at.y < top + 2.0 + NAME_STRIP:
			var px_per_second: float = zoom / timeline.step_seconds()
			var in_handle := x0 + float(clip.get("fade_in", 0.0)) * px_per_second
			var out_handle := x1 - float(clip.get("fade_out", 0.0)) * px_per_second
			if absf(at.x - in_handle) <= maxf(edge, 4.0) and at.x - x0 < (x1 - x0) / 2.0:
				found.zone = "fade_in"
			elif absf(at.x - out_handle) <= maxf(edge, 4.0):
				found.zone = "fade_out"
		elif at.x - x0 <= edge:
			found.zone = "trim_start"
		elif x1 - at.x <= edge:
			found.zone = "trim_end"
		return found
	return {"zone": "track", "inst": inst, "row": row}


## The cursor at a point: the trim cursor at a clip's ends, the fade cursor (made above) at an audio clip's top corners.
func cursor_at(at: Vector2) -> CursorShape:
	return {"trim_start": CURSOR_HSIZE, "trim_end": CURSOR_HSIZE, "fade_in": CURSOR_BDIAGSIZE, "fade_out": CURSOR_FDIAGSIZE, "xfade": CURSOR_BDIAGSIZE,
		"gain": CURSOR_VSIZE}.get(
		zone_at(at).get("zone", ""), CURSOR_ARROW)


## What is at a point in a track's take lane: one of its loop recordings' takes ("take"), its header, or neither.
func _take_zone(inst, row: int, n: int, at: Vector2) -> Dictionary:
	if at.x < HEADER:
		return {"zone": "take_header", "inst": inst, "row": row, "lane": n}
	var step := step_at(at.x)
	for group in timeline.take_groups(inst):
		if n < group.takes.size():
			var span: Vector2 = timeline.clip_steps(group.takes[n])
			if step >= span.x and step < span.y:
				return {"zone": "take", "inst": inst, "row": row, "lane": n, "group": group.group, "take": int(group.takes[n].get("take", n + 1))}
	return {"zone": "take_lane", "inst": inst, "row": row, "lane": n}


## What is at a point in a track's automation lane: its buttons ("lane_button"), one of its points ("point"), or a
## place to add one ("lane").
func _lane_zone(track, row: int, at: Vector2) -> Dictionary:
	var k := lane_number_at(at.y, row)
	var top := lane_top(row, k)
	var param: String = track.lanes[k]
	var found := {"zone": "lane", "inst": track, "row": row, "lane": k, "param": param, "top": top}
	if at.x < HEADER:
		for b in _lane_buttons(track, top, k):
			if b.rect.has_point(at):
				found.zone = "lane_button"
				found.button = b.what
				return found
		return {"zone": "lane_header", "inst": track, "row": row}
	var lane: Array = app.automation.points(track, param)
	for i in range(lane.size() - 1, -1, -1):
		var p: Array = lane[i]
		if Vector2(x_of(float(p[0])), _lane_y(float(p[1]), param, top)).distance_to(at) <= 6.0:
			found.zone = "point"
			found.point = p
			return found
	return found


## What the hint line says, with the mouse at a point.
func hint_at(at: Vector2) -> String:
	var found := zone_at(at)
	match found.get("zone", ""):
		"ruler":
			return "Click to put the playhead here; drag along to loop the range  ·  L loop playback on or off, U loops the chosen clip"
		"take":
			return "Take %d: drag along it to put that part of it in the track (comping); click it to put it in place of the part of the track over it" % found.take
		"take_header":
			return "Take %d of each loop recording on the track: the parts of it in the track are lit (right-click a clip with takes to hide them)" % (found.lane + 1)
		"lane_button":
			return {"param": "What this lane shows: volume, mute, an instrument's sustain pedal, an amp's knobs and its pedals', sends, or a plug-in's controls",
				"mode": "The track's automation mode: Off, Read, Touch (written while a control is held), Latch (from then until it stops) or Write (as it plays)",
				"add": "Another lane under the track, for another of its controls", "remove": "No lane for this one (its points are kept)"}[found.button]
		"lane_header":
			return "%s's automation (A shows or hides the lanes)" % found.inst.display_name
		"point":
			return "%s %s at %s: drag to move it (the chosen points with it), Shift-click to choose more, Option-click to take it away, Delete" % [
				app.automation.name_of(found.inst, found.param), app.automation.value_text(found.inst, found.param, float(found.point[1])),
				_bar_beat(float(found.point[0]))]
		"lane":
			return "Click to add a point (%s here), dragging to place it" % app.automation.value_text(found.inst, found.param,
				_lane_value(at.y, found.param, found.top))
		"header":
			var track = found.inst
			if _folds(track) and at.x < 24.0 + _indent(track):
				return "Show or hide its tracks"
			for b in _buttons(track, row_top(found.row)):
				if b.rect.has_point(at):
					match b.what:
						"arm":
							return "Record-ready: it records when recording starts, and its input is heard while stopped or recording  ·  Option-click: every track"
						"input":
							return ("Input: the MIDI keyboard plays it" if track.playable else ("Input monitoring: what it hears is heard, rather than what it recorded"
								if track.is_mic else "Input monitoring: its input is heard, rather than what it recorded")) + \
								"  ·  Option-click: every track"
						"mute":
							return ("Mute: its tracks are silent" if track.is_folder else "Mute") + "  ·  Option-click: every track"
					return ("Solo: its tracks are soloed" if track.is_folder else "Solo") + "  ·  Option-click: every track"
			return "%s: click to choose it (Shift or Cmd-click for more; %s: the chosen in a new folder), double-click to rename it, right-click for more" % [
				track.display_name, app.bindings.label("group")]
		"xfade":
			return "Drag along to crossfade the two clips, each reaching into the other with the audio its file has beyond the cut"
		"fade_in":
			return "Drag along to fade the clip in"
		"fade_out":
			return "Drag along to fade the clip out"
		"trim_start", "trim_end":
			return "Drag to trim the clip%s" % ("'s start" if found.zone == "trim_start" else "'s end") + \
				(": an audio clip only ever shows more or less of its file" if found.inst.clips[found.index].kind == "audio" else "")
		"gain":
			return "Clip gain %+.1f dB: drag up or down (Shift for fine moves), Option-click for 0 dB  ·  Ctrl-Shift-↑ ↓ nudge it a dB" % \
				float(found.inst.clips[found.index].get("gain_db", 0.0))
		"clip":
			var clip: Dictionary = found.inst.clips[found.index]
			return "Drag to move it (Option as you drop: a copy), Shift-click to choose more  ·  %s splits it at the playhead  ·  , and . nudge it  ·  U loops it%s" % [
				app.bindings.label("separate"), "  ·  double-click for its notes" if clip.kind == "midi" else
				("  ·  right-click for its takes (and to comp from them)" if not clip.get("takes", []).is_empty() else "")]
		"track":
			return "Click to put the playhead here"
	return ""


static func _bar_beat(step: float) -> String:
	return "%d | %d" % [int(step / 16.0) + 1, int(fmod(step, 16.0) / 4.0) + 1]


## A press at a point: on the ruler, a header's button, a clip (its body, an end, a fade handle, its gain), or an empty
## lane. With `all` (Option held), a header's button sets every track as it sets this one, as Pro Tools' all-tracks
## modifier, and a clip's gain goes back to 0 dB; with `add` (Shift), a clip is added to the clips chosen, or taken
## away. (The automated checks call these.)
func press(at: Vector2, all := false, add := false, command := false) -> void:
	_drag = {}
	var found := zone_at(at)
	if found.get("zone", "") in ["lane", "point", "lane_button"]:
		_press_lane(found, at, all, add)
		return
	match found.get("zone", ""):
		"ruler":
			_drag = {"what": "ruler", "from_x": at.x, "from": step_at(at.x)}
		"take":  # comping: a drag along it puts that part in, a click the part the track has over it
			chosen = []
			_drag = {"what": "comp", "inst": found.inst, "lane": found.lane, "group": found.group, "take": found.take, "from": step_at(at.x),
				"to": step_at(at.x), "from_x": at.x, "moved": false}
		"header":
			if _folds(found.inst) and at.x < 24.0 + _indent(found.inst):  # its arrow
				found.inst.open = not found.inst.open
				return
			if not _buttons(found.inst, row_top(found.row)).any(func(b): return b.rect.has_point(at)):  # its name: choosing tracks
				app.choose_track(found.inst, "range" if add else ("toggle" if command else "only"))
				return
			for b in _buttons(found.inst, row_top(found.row)):
				if b.rect.has_point(at):
					if all:
						app.set_on_all(b.what, not b.on)
						return
					match b.what:
						"arm":
							timeline.set_armed(found.inst, not found.inst.armed)
						"input":
							app.set_input(found.inst, not found.inst.input_on)
						"mute":
							app.set_muted(found.inst, not found.inst.muted)
						"solo":
							app.set_soloed(found.inst, not found.inst.soloed)
		"clip", "trim_start", "trim_end", "fade_in", "fade_out", "xfade", "gain":
			var inst = found.inst
			var c: int = found.index
			var clip: Dictionary = inst.clips[c]
			if add:  # Shift: one more chosen, or one fewer
				if is_chosen(inst, clip):
					chosen = chosen.filter(func(it): return not (it.inst == inst and is_same(it.clip, clip)))
				else:
					chosen.append({"inst": inst, "clip": clip})
				return
			if not is_chosen(inst, clip) or found.zone in ["trim_start", "trim_end", "fade_in", "fade_out", "xfade"]:
				chosen = [{"inst": inst, "clip": clip}]
			var span: Vector2 = timeline.clip_steps(clip)
			_drag = {"what": found.zone, "inst": inst, "index": c, "grab": step_at(at.x) - span.x, "row": found.row, "at": step_at(at.x),
				"items": chosen_items(), "delta": 0.0, "rows": 0}
			if found.zone == "gain":
				var items: Array = _drag.items.filter(func(it): return it.clip.kind == "audio")
				_drag.items = items
				_drag.from_y = at.y
				_drag.dbs = items.map(func(it): return float(it.clip.get("gain_db", 0.0)))
				if all:  # back to 0 dB
					timeline.remember("Clip gain")
					timeline.set_clip_gain(items, 0.0)
					_drag = {}
		"track":
			chosen = []
			timeline.locate(timeline.snap(step_at(at.x)))


## A press in an automation lane: its buttons' menus; a point chosen (Shift: one more, or one fewer) and dragged with
## the others chosen, or (Option) taken away; or a new point, dragged to place it.
func _press_lane(found: Dictionary, at: Vector2, all: bool, add: bool) -> void:
	var track = found.inst
	if found.zone == "lane_button":
		match found.button:
			"add":
				add_lane(track)
			"remove":
				track.lanes.remove_at(found.lane)
				chosen_points = []
			_:
				_show_lane_menu(track, found.lane, found.button, at)
		return
	var param: String = found.param
	var point: Array
	if found.zone == "point":
		point = found.point
		if all:  # Option-click: taken away
			timeline.remember("Delete point")
			track.automation[param].erase(point)
			chosen_points = chosen_points.filter(func(c): return not is_same(c.point, point))
			_lane_changed(track)
			return
		var picked := chosen_points.any(func(c): return is_same(c.point, point))
		if add:
			if picked:
				chosen_points = chosen_points.filter(func(c): return not is_same(c.point, point))
			else:
				chosen_points.append({"track": track, "param": param, "point": point})
			return
		if not picked or chosen_points.any(func(c): return c.track != track or c.param != param):
			chosen_points = [{"track": track, "param": param, "point": point}]
	else:  # a new point, there
		timeline.remember("Add point")
		var step: float = maxf(timeline.snap(step_at(at.x)), 0.0)
		var index: int = app.automation.add_point(track, param, step, _lane_value(at.y, param, found.top))
		point = track.automation[param][index]
		chosen_points = [{"track": track, "param": param, "point": point}]
		_lane_changed(track)
	chosen = []
	var moving: Array = chosen_points.map(func(c): return c.point)
	_drag = {"what": "point", "track": track, "param": param, "anchor": point, "points": moving, "top": found.top,
		"steps": moving.map(func(p): return float(p[0])), "values": moving.map(func(p): return float(p[1])),
		"grab_step": step_at(at.x), "grab_y": at.y, "moved": found.zone == "lane"}


func _lane_changed(track) -> void:
	if track.get("is_master"):
		timeline.sync(track)
		timeline.changed.emit()
		return
	timeline.sync(track)
	timeline.changed.emit()


## Every chosen point taken away (Delete). Returns whether there were any.
func delete_chosen_points() -> bool:
	if chosen_points.is_empty():
		return false
	timeline.remember("Delete points")
	var touched := []
	for c in chosen_points:
		if app.has_track(c.track) or app.master_tracks().has(c.track):
			c.track.automation.get(c.param, []).erase(c.point)
			if not touched.has(c.track):
				touched.append(c.track)
	chosen_points = []
	for track in touched:
		_lane_changed(track)
	return true


func _on_drag(at: Vector2) -> void:
	var what: String = _drag.get("what", "")
	match what:
		"comp":
			_drag.to = step_at(at.x)
			_drag.moved = _drag.moved or absf(at.x - _drag.from_x) > 4.0
		"point":  # the chosen points along (the one held to the grid) and up or down, in order still
			if not _drag.get("moved", false):
				timeline.remember("Move points")
				_drag.moved = true
			var i: int = _drag.points.find(_drag.anchor)
			var along: float = maxf(timeline.snap(_drag.steps[i] + step_at(at.x) - _drag.grab_step), 0.0) - _drag.steps[i]
			var param: String = _drag.param
			var auto = app.automation
			for k in _drag.points.size():
				var p: Array = _drag.points[k]
				p[0] = maxf(_drag.steps[k] + along, 0.0)
				if auto.is_switch(param):
					p[1] = _lane_value(at.y, param, _drag.top)
				else:  # up or down its own scale (a fader's, for volume and sends)
					p[1] = auto.value_from(param, auto.height_of(param, _drag.values[k]) + (_drag.grab_y - at.y) / (LANE - 9))
			_drag.track.automation[param].sort_custom(func(a, b): return float(a[0]) < float(b[0]))
		"ruler":
			if absf(at.x - _drag.from_x) > 4.0:
				var unit: int = timeline.grid  # with the grid off, anywhere
				var a: float = maxf(timeline.snap(minf(_drag.from, step_at(at.x)), unit), 0.0)
				var b: float = timeline.snap(maxf(_drag.from, step_at(at.x)), unit)
				_drag.loop = Vector2(a, maxf(b, a + maxf(unit, 0.25)))
		"clip":  # every clip chosen goes with the one held, by as much (and to other tracks, if all of them fit there)
			_drag.moved = true
			var anchor: Vector2 = timeline.clip_steps(_drag.inst.clips[_drag.index])
			var earliest: float = timeline.span_of(_drag.items).x
			_drag.delta = maxf(maxf(timeline.snap(step_at(at.x) - _drag.grab), 0.0) - anchor.x, -earliest)
			var rows: int = row_near(at.y) - _drag.row
			for it in _drag.items:
				var row: int = tracks().find(it.inst) + rows
				if row < 0 or row >= tracks().size() or not timeline.fits(it.clip, tracks()[row]):
					rows = 0
			_drag.rows = rows
		"trim_start", "trim_end":
			if not _drag.get("moved", false):
				timeline.remember("Trim clip")
				_drag.moved = true
			timeline.trim_clip(_drag.inst, _drag.index, "start" if what == "trim_start" else "end", timeline.snap(step_at(at.x)), false)
		"xfade":
			if not _drag.get("moved", false):
				timeline.remember("Crossfade")
				_drag.moved = true
			var seam: float = timeline.clip_steps(_drag.inst.clips[_drag.index]).y
			timeline.set_crossfade(_drag.inst, _drag.index, 2.0 * absf(step_at(at.x) - seam) * timeline.step_seconds(), false)
		"fade_in", "fade_out":
			if not _drag.get("moved", false):
				timeline.remember("Fade")
				_drag.moved = true
			var span: Vector2 = timeline.clip_steps(_drag.inst.clips[_drag.index])
			var steps: float = step_at(at.x) - span.x if what == "fade_in" else span.y - step_at(at.x)
			timeline.set_fade(_drag.inst, _drag.index, what, steps * timeline.step_seconds(), false)
		"gain":  # up or down, each clip chosen by as much
			if not _drag.get("moved", false):
				timeline.remember("Clip gain")
				_drag.moved = true
			var change: float = (_drag.from_y - at.y) * (0.05 if Input.is_key_pressed(KEY_SHIFT) else 0.25)
			for i in _drag.items.size():
				timeline.set_clip_gain([_drag.items[i]], _drag.dbs[i] + change, false)


func release(at: Vector2, copy := false) -> void:
	var drag := _drag
	_drag = {}
	match drag.get("what", ""):
		"comp":
			_comp(drag)
		"point":
			_lane_changed(drag.track)
		"ruler":
			if drag.has("loop"):
				timeline.set_loop(true, drag.loop.x, drag.loop.y)
			else:
				timeline.locate(timeline.snap(step_at(at.x)))
		"clip", "trim_start", "trim_end", "fade_in", "fade_out", "xfade", "gain":
			if not drag.get("moved", false):  # a click: chosen, and (stopped) the playhead where it was clicked
				if not timeline.playing and drag.what != "gain":
					timeline.locate(timeline.snap(drag.at))
			elif drag.what == "clip":
				chosen = timeline.move_clips(drag.items, drag.delta, drag.rows, copy, "", tracks())
			else:  # trimmed, faded or turned up or down as it went: now it is heard so
				timeline._sync_items(drag.items if drag.what == "gain" else [{"inst": drag.inst}])


## A take dragged along (that part of it, to the grid, in the track) or clicked: put in place of the part of the track
## over it, or where the track has none of its recording there, over the gap.
func _comp(drag: Dictionary) -> void:
	var inst = drag.inst
	if drag.moved:
		var from: float = timeline.snap(minf(drag.from, drag.to))
		var to: float = timeline.snap(maxf(drag.from, drag.to))
		if to - from < 0.01:
			to = from + maxf(float(timeline.grid), 1.0)
		timeline.comp(inst, drag.group, drag.take, from, to)
		return
	var step: float = drag.from
	var gap := Vector2(-INF, INF)
	for c in inst.clips.size():
		var clip: Dictionary = inst.clips[c]
		if timeline.group_of(clip) != drag.group:
			continue
		var span: Vector2 = timeline.clip_steps(clip)
		if step >= span.x and step < span.y:
			if int(clip.get("take", 0)) != int(drag.take):
				timeline.choose_take(inst, c, drag.take)
			return
		if span.y <= step:
			gap.x = maxf(gap.x, span.y)
		else:
			gap.y = minf(gap.y, span.x)
	timeline.comp(inst, drag.group, drag.take, gap.x, gap.y)


## A track's menu (a right-click on its name): rename it, colour it, and its folder.
func show_track_menu(track, at: Vector2) -> void:
	_track_menu_for = track
	_track_menu.clear()
	TrackMenu.add_items(_track_menu, app, track, _colors, _modes)
	_track_menu.position = Vector2i(get_screen_position() + at)
	_track_menu.popup()


## A clip's takes, to choose one from (a right-click on it): the one shown ticked; and the takes shown under the track,
## to comp from, or not.
func show_takes(inst, index: int, at: Vector2) -> void:
	var clip: Dictionary = inst.clips[index]
	var takes: Array = timeline.takes_of(clip)
	if takes.is_empty():
		return
	_takes_for = {"inst": inst, "clip": clip}
	_takes_menu.clear()
	for take in takes:
		_takes_menu.add_radio_check_item("Take %d" % int(take.get("take", 0)), int(take.get("take", 0)))
		_takes_menu.set_item_checked(_takes_menu.item_count - 1, int(take.get("take", 0)) == int(clip.get("take", 0)))
	_takes_menu.add_separator()
	_takes_menu.add_check_item("Show the takes under the track, to comp from them", SHOW_TAKES)
	_takes_menu.set_item_checked(_takes_menu.item_count - 1, inst.takes_open)
	_takes_menu.position = Vector2i(get_screen_position() + at)
	_takes_menu.popup()


## Lets the automated checks drag: a press, moves, a release.
func drag_to(from: Vector2, to: Vector2, copy := false) -> void:
	press(from)
	_on_drag(from.lerp(to, 0.5))
	_on_drag(to)
	release(to, copy)
