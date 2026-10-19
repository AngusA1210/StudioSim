extends Control
## The edit window's tracks along the timeline. A row for each instrument: its header on the left (its name in its
## colour; R arms it for recording, M mutes it, S solos it), and its lane, with its clips (audio drawn as its waveform,
## MIDI as its notes), across the bars. Above them the ruler: click it to put the playhead there, drag along it to
## loop that range. Click a clip to choose it (stopped, the playhead goes where you clicked, to split it there) and
## drag it along its track, or to another track that takes its kind (hold Option as you drop it for a copy); clips snap
## to the grid unless it is off. Drag either end of a clip to trim it, as Pro Tools' trim tool does, and an audio
## clip's top corners to fade it in or out. Click an empty lane to put the playhead there. The scroll wheel and
## trackpad move about (Shift for along), Cmd and the wheel (or a pinch) zoom. The cursor and the hint line say what a
## press would do.

const Hints := preload("res://scripts/hints.gd")
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

var app
var timeline
var zoom := 6.0       # pixels to a step (a bar is 96)
var scroll_x := 0.0   # the step at the lanes' left edge
var scroll_y := 0.0   # pixels the rows are scrolled up
var selected := {}    # the clip chosen: {inst, index}
var _drag := {}       # what a press is doing: moving a clip, or along the ruler


func setup(the_app) -> void:
	app = the_app
	timeline = app.timeline
	clip_contents = true
	mouse_filter = Control.MOUSE_FILTER_STOP
	focus_mode = Control.FOCUS_NONE
	Hints.give(self, func() -> String: return hint_at(get_local_mouse_position()))


func _process(_delta: float) -> void:
	if not is_visible_in_tree():
		return
	if not selected.is_empty() and (not app.instruments.has(selected.inst) or selected.index >= selected.inst.clips.size()):
		selected = {}  # undone, or its track removed
	if _drag.is_empty():
		var zone: String = zone_at(get_local_mouse_position()).get("zone", "")
		mouse_default_cursor_shape = CURSOR_HSIZE if zone in ["trim_start", "trim_end", "fade_in", "fade_out"] else CURSOR_ARROW
	if timeline.playing:  # keep the playhead in view
		var at: float = timeline.position()
		var span := (size.x - HEADER) / zoom
		if at < scroll_x or at > scroll_x + span * 0.9:
			scroll_x = maxf(at - span * 0.1, 0.0)
	queue_redraw()


func x_of(step: float) -> float:
	return HEADER + (step - scroll_x) * zoom


func step_at(x: float) -> float:
	return scroll_x + (x - HEADER) / zoom


func row_top(i: int) -> float:
	return RULER + i * ROW - scroll_y


func row_at(y: float) -> int:
	return int(floor((y - RULER + scroll_y) / ROW)) if y >= RULER else -1


func tracks() -> Array:
	return app.instruments


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
		if top > size.y or top + ROW < RULER:
			continue
		draw_rect(Rect2(HEADER, top, size.x - HEADER, ROW - 1), Color(0.12, 0.125, 0.145) if i % 2 == 0 else Color(0.105, 0.11, 0.13))
		var step := float(first_bar * 4)
		while step <= last_step:
			var x := x_of(step)
			if x >= HEADER:
				draw_line(Vector2(x, top), Vector2(x, top + ROW - 1), Color(1, 1, 1, 0.12 if int(step) % 16 == 0 else 0.04))
			step += 4.0
		for c in inst.clips.size():
			_draw_clip(inst, c, top, font)
		if timeline.recording and inst.armed:  # the take so far
			var from := x_of(_record_from())
			var to := x_of(timeline.position())
			draw_rect(Rect2(maxf(from, HEADER), top + 2, maxf(to - maxf(from, HEADER), 0.0), ROW - 5), Color(RECORD_RED, 0.28))
		_draw_header(inst, top, font)
	# The ruler: the bars, and the loop range.
	draw_rect(Rect2(0, 0, size.x, RULER), Color(0.14, 0.145, 0.17))
	var band := Rect2(maxf(x_of(timeline.loop_start), HEADER), 2, 0, 9)
	band.size.x = maxf(x_of(timeline.loop_end) - band.position.x, 0.0)
	draw_rect(band, LOOP_ON if timeline.loop_on else Color(0.45, 0.47, 0.52))
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
	# A clip being moved: where it would land.
	if _drag.get("what", "") == "clip" and _drag.get("moved", false) and _drag.has("to_row"):
		var span: Vector2 = timeline.clip_steps(_drag.inst.clips[_drag.index])
		var top := row_top(_drag.to_row)
		draw_rect(Rect2(x_of(_drag.to_step), top + 2, (span.y - span.x) * zoom, ROW - 5), Color(1, 1, 1, 0.6), false, 2.0)


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
	var chosen: bool = selected.get("inst") == inst and selected.get("index") == index
	draw_rect(rect, inst.color.darkened(0.55 if not chosen else 0.25))
	var ink: Color = inst.color.lightened(0.4)
	var inner := Rect2(rect.position + Vector2(0, 15), Vector2(rect.size.x, rect.size.y - 17))
	if clip.kind == "audio":  # its waveform
		var peaks: PackedFloat32Array = timeline.peaks(clip)
		var seconds_per_px: float = timeline.step_seconds() / zoom
		var mid := inner.position.y + inner.size.y / 2
		var x := inner.position.x
		while x < inner.end.x and not peaks.is_empty():
			var t: float = float(clip.offset) + (step_at(x) - span.x) * timeline.step_seconds()
			var i := int(t * 100.0)
			if i >= 0 and i < peaks.size():
				var h := minf(peaks[i], 1.0) * inner.size.y / 2
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
	if clip.kind == "audio":
		_draw_fades(clip, x0, x1, inner, rect, ink)
	draw_rect(rect, Color.WHITE if chosen else Color(0, 0, 0, 0.6), false, 1.0)
	draw_string(font, rect.position + Vector2(5, 12), str(clip.get("name", "")), HORIZONTAL_ALIGNMENT_LEFT, maxf(rect.size.x - 8, 1.0), 11, ink)


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
	draw_rect(Rect2(0, top, HEADER, ROW - 1), Color(0.16, 0.17, 0.19))
	draw_rect(Rect2(0, top, 5, ROW - 1), inst.color)
	draw_string(font, Vector2(12, top + 20), inst.display_name, HORIZONTAL_ALIGNMENT_LEFT, HEADER - 20, 13, inst.color.lightened(0.45))
	draw_string(font, Vector2(12, top + 40), "audio" if not inst.playable else "MIDI", HORIZONTAL_ALIGNMENT_LEFT, 60, 11, DIM)
	for b in _buttons(inst, top):
		var lit: bool = b.on
		draw_rect(b.rect, b.color if lit else Color(0.3, 0.31, 0.34))
		draw_string(font, b.rect.position + Vector2(5, 14), b.text, HORIZONTAL_ALIGNMENT_LEFT, -1, 12,
			Color(0.08, 0.08, 0.09) if lit else Color(0.85, 0.86, 0.9))


## A track's header buttons: R (armed), I (input), M (muted), S (soloed).
func _buttons(inst, top: float) -> Array:
	var y := top + 28
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
		scroll_y = clampf(scroll_y + event.delta.y * 12.0, 0.0, maxf(tracks().size() * ROW - (size.y - RULER), 0.0))
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
			scroll_y = clampf(scroll_y + amount * ROW * 0.5, 0.0, maxf(tracks().size() * ROW - (size.y - RULER), 0.0))
		accept_event()
		return
	if e.button_index != MOUSE_BUTTON_LEFT:
		return
	accept_event()
	if e.pressed:
		press(e.position)
	else:
		release(e.position, e.alt_pressed)


## What is at a point: {zone, inst, index, row}, the zone one of "ruler", "header", "fade_in", "fade_out" (an audio
## clip's top corners), "trim_start", "trim_end" (a clip's ends), "clip", "lane", or nothing.
func zone_at(at: Vector2) -> Dictionary:
	if at.y < 0.0 or at.x < 0.0 or at.x > size.x or at.y > size.y:
		return {}
	if at.y < RULER:
		return {"zone": "ruler"} if at.x >= HEADER else {}
	var row := row_at(at.y)
	if row < 0 or row >= tracks().size():
		return {}
	var inst = tracks()[row]
	if at.x < HEADER:
		return {"zone": "header", "inst": inst, "row": row}
	var top := row_top(row)
	for c in range(inst.clips.size() - 1, -1, -1):  # the one on top
		var clip: Dictionary = inst.clips[c]
		var span: Vector2 = timeline.clip_steps(clip)
		var x0 := x_of(span.x)
		var x1 := x_of(span.y)
		if at.x < x0 - 2.0 or at.x > x1 + 2.0:
			continue
		var found := {"inst": inst, "index": c, "row": row, "zone": "clip"}
		var edge := minf(EDGE, (x1 - x0) / 4.0)  # a short clip keeps its middle for moving
		if clip.kind == "audio" and at.y < top + 2.0 + NAME_STRIP:
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
	return {"zone": "lane", "inst": inst, "row": row}


## What the hint line says, with the mouse at a point.
func hint_at(at: Vector2) -> String:
	var found := zone_at(at)
	match found.get("zone", ""):
		"ruler":
			return "Click to put the playhead here; drag along to loop the range (L loops the chosen clip)"
		"header":
			for b in _buttons(found.inst, row_top(found.row)):
				if b.rect.has_point(at):
					return {"arm": "Arm the track for recording (its input goes on, to be heard)", "input": "Its input on or off",
						"mute": "Mute", "solo": "Solo"}[b.what]
			return found.inst.display_name
		"fade_in":
			return "Drag along to fade the clip in"
		"fade_out":
			return "Drag along to fade the clip out"
		"trim_start", "trim_end":
			return "Drag to trim the clip%s" % ("'s start" if found.zone == "trim_start" else "'s end") + \
				(": an audio clip only ever shows more or less of its file" if found.inst.clips[found.index].kind == "audio" else "")
		"clip":
			return "Drag to move it (Option as you drop: a copy)  ·  Cmd-E splits it at the playhead  ·  , and . nudge it  ·  L loops it  ·  Delete"
		"lane":
			return "Click to put the playhead here"
	return ""


## A press at a point: on the ruler, a header's button, a clip (its body, an end, a fade handle), or an empty lane.
## (The automated checks call these.)
func press(at: Vector2) -> void:
	_drag = {}
	var found := zone_at(at)
	match found.get("zone", ""):
		"ruler":
			_drag = {"what": "ruler", "from_x": at.x, "from": step_at(at.x)}
		"header":
			for b in _buttons(found.inst, row_top(found.row)):
				if b.rect.has_point(at):
					match b.what:
						"arm":
							timeline.set_armed(found.inst, not found.inst.armed)
						"input":
							app.set_input(found.inst, not found.inst.input_on)
						"mute":
							app.set_muted(found.inst, not found.inst.muted)
						"solo":
							app.set_soloed(found.inst, not found.inst.soloed)
		"clip", "trim_start", "trim_end", "fade_in", "fade_out":
			var inst = found.inst
			var c: int = found.index
			var span: Vector2 = timeline.clip_steps(inst.clips[c])
			selected = {"inst": inst, "index": c}
			_drag = {"what": found.zone, "inst": inst, "index": c, "grab": step_at(at.x) - span.x, "row": found.row, "at": step_at(at.x)}
		"lane":
			selected = {}
			timeline.locate(timeline.snap(step_at(at.x)))


func _on_drag(at: Vector2) -> void:
	var what: String = _drag.get("what", "")
	match what:
		"ruler":
			if absf(at.x - _drag.from_x) > 4.0:
				var unit: int = timeline.grid  # with the grid off, anywhere
				var a: float = maxf(timeline.snap(minf(_drag.from, step_at(at.x)), unit), 0.0)
				var b: float = timeline.snap(maxf(_drag.from, step_at(at.x)), unit)
				_drag.loop = Vector2(a, maxf(b, a + maxf(unit, 0.25)))
		"clip":
			_drag.moved = true
			_drag.to_step = maxf(timeline.snap(step_at(at.x) - _drag.grab), 0.0)
			var row := clampi(row_at(at.y), 0, tracks().size() - 1)
			_drag.to_row = row if timeline.fits(_drag.inst.clips[_drag.index], tracks()[row]) else _drag.row
		"trim_start", "trim_end":
			if not _drag.get("moved", false):
				timeline.remember("Trim clip")
				_drag.moved = true
			timeline.trim_clip(_drag.inst, _drag.index, "start" if what == "trim_start" else "end", timeline.snap(step_at(at.x)), false)
		"fade_in", "fade_out":
			if not _drag.get("moved", false):
				timeline.remember("Fade")
				_drag.moved = true
			var span: Vector2 = timeline.clip_steps(_drag.inst.clips[_drag.index])
			var steps: float = step_at(at.x) - span.x if what == "fade_in" else span.y - step_at(at.x)
			timeline.set_fade(_drag.inst, _drag.index, what, steps * timeline.step_seconds(), false)


func release(at: Vector2, copy := false) -> void:
	var drag := _drag
	_drag = {}
	match drag.get("what", ""):
		"ruler":
			if drag.has("loop"):
				timeline.set_loop(true, drag.loop.x, drag.loop.y)
			else:
				timeline.locate(timeline.snap(step_at(at.x)))
		"clip", "trim_start", "trim_end", "fade_in", "fade_out":
			if not drag.get("moved", false):  # a click: chosen, and (stopped) the playhead where it was clicked
				if not timeline.playing:
					timeline.locate(timeline.snap(drag.at))
			elif drag.what == "clip":
				var to = tracks()[drag.to_row]
				timeline.place_clip(drag.inst, drag.index, to, drag.to_step, copy)
				selected = {"inst": to, "index": to.clips.size() - 1}
			else:  # trimmed or faded as it went: now it is heard so
				timeline.sync(drag.inst)
				timeline.changed.emit()


## Lets the automated checks drag: a press, moves, a release.
func drag_to(from: Vector2, to: Vector2, copy := false) -> void:
	press(from)
	_on_drag(from.lerp(to, 0.5))
	_on_drag(to)
	release(to, copy)
