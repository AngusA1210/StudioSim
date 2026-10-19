extends Control
## A MIDI clip's notes, as Pro Tools' MIDI editor shows them (double-click a MIDI clip in the edit window): a row for
## each pitch with the piano down the left (click a key to hear it), the clip's bars along the top, and each note's
## velocity as a stalk along the foot. Click an empty place to add a note, a grid line long (drag as you add it to make
## it longer); click a note to choose it (Shift-click for more) and drag it along or up and down to move it (Option as
## you drop: a copy), drag its right end to lengthen or shorten it, and drag a stalk up or down for its velocity.
## Delete takes the chosen notes away, Cmd-A chooses them all, Cmd-D puts a second of them just after, and comma and
## full stop nudge them a grid line. Every edit can be undone. The scroll wheel moves up and down (Shift for along), Cmd
## and the wheel (or a pinch) zoom. Notes are kept in steps from the clip's start; those it no longer reaches (trimmed
## off) aren't shown.

const Hints := preload("res://scripts/hints.gd")
const KEYS := 64.0       # the piano's width
const RULER := 24.0
const ROW := 11.0        # a semitone
const VELOCITY := 60.0   # the velocity lane, along the foot
const EDGE := 5.0        # how near a note's right end a press lengthens it
const NAMES := ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
const BLACK := [1, 3, 6, 8, 10]
const DIM := Color(0.62, 0.65, 0.74)

var app
var timeline
var inst            # whose clip it is
var index := -1     # the clip's place on its track
var clip: Dictionary
var zoom := 16.0    # pixels to a step
var scroll_x := 0.0  # the step (from the clip's start) at the left edge of the notes
var scroll_y := 0.0  # pixels the rows are scrolled down from the top note (127)
var chosen: Array = []  # the notes chosen (their Dictionaries)
var new_velocity := 0.8
var _drag := {}
var _fit := false   # fit the clip in view once it has a size


func setup(the_app) -> void:
	app = the_app
	timeline = app.timeline
	clip_contents = true
	mouse_filter = Control.MOUSE_FILTER_STOP
	focus_mode = Control.FOCUS_NONE
	Hints.give(self, func() -> String: return hint_at(get_local_mouse_position()))


## Opens a clip's notes.
func edit(the_inst, the_index: int) -> void:
	inst = the_inst
	index = the_index
	clip = inst.clips[index]
	chosen = []
	_drag = {}
	_fit = true


func is_editing() -> bool:
	return is_visible_in_tree() and inst != null


func notes() -> Array:
	return clip.notes


## The notes it shows: those its length still reaches.
func shown() -> Array:
	return clip.notes.filter(func(n): return float(n.step) >= 0.0 and float(n.step) < float(clip.length))


func _process(_delta: float) -> void:
	if not is_visible_in_tree() or inst == null:
		return
	# After an undo (or the clip changing under it) it finds the clip again at its place; if none, back to the tracks.
	if not app.instruments.has(inst) or index >= inst.clips.size() or inst.clips[index].kind != "midi":
		app.edit_window.show_tracks()
		return
	if not is_same(inst.clips[index], clip):
		clip = inst.clips[index]
	chosen = chosen.filter(func(n): return clip.notes.any(func(m): return is_same(m, n)))
	if _fit and size.x > KEYS + 40.0:
		_fit = false
		zoom = clampf((size.x - KEYS - 24.0) / maxf(float(clip.length), 4.0), 2.0, 96.0)
		scroll_x = 0.0
		var middle := 60.0
		if not shown().is_empty():
			var low := 127
			var high := 0
			for n in shown():
				low = mini(low, int(n.note))
				high = maxi(high, int(n.note))
			middle = (low + high) / 2.0
		scroll_y = clampf((127.0 - middle) * ROW - (size.y - RULER - VELOCITY) / 2.0, 0.0, _most_scroll())
	queue_redraw()


func _most_scroll() -> float:
	return maxf(128.0 * ROW - (size.y - RULER - VELOCITY), 0.0)


func x_of(step: float) -> float:
	return KEYS + (step - scroll_x) * zoom


func step_at(x: float) -> float:
	return scroll_x + (x - KEYS) / zoom


func y_of(note: int) -> float:
	return RULER + (127 - note) * ROW - scroll_y


func note_at(y: float) -> int:
	return clampi(127 - int(floor((y - RULER + scroll_y) / ROW)), 0, 127)


func lane_top() -> float:
	return size.y - VELOCITY


## How long a new note is, and what moves snap to: a grid line (a sixteenth with the grid off, and then no snapping).
func _unit() -> float:
	return float(timeline.grid) if timeline.grid > 0 else 1.0


func _snap(step: float) -> float:
	return timeline.snap(step)


static func note_name(note: int) -> String:
	return "%s%d" % [NAMES[note % 12], note / 12 - 1]


# ── Drawing ──────────────────────────────────────────────────────────────────────────────────────────────────

func _draw() -> void:
	if inst == null:
		return
	var font := get_theme_default_font()
	var bottom := lane_top()
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.08, 0.085, 0.1))
	draw_rect(Rect2(0, 0, size.x, RULER), Color(0.14, 0.145, 0.17))
	# The rows, the black keys' darker.
	for note in range(note_at(bottom), note_at(RULER) + 1):
		var y := y_of(note)
		draw_rect(Rect2(KEYS, y, size.x - KEYS, ROW), Color(0.105, 0.11, 0.13) if (note % 12) in BLACK else Color(0.13, 0.135, 0.155))
		if note % 12 == 0:
			draw_line(Vector2(KEYS, y + ROW), Vector2(size.x, y + ROW), Color(1, 1, 1, 0.1))
	# Beats and bars, on the timeline's own bar lines; past the clip's end, shaded.
	var start := float(clip.start)
	var step := floorf((scroll_x + start) / 4.0) * 4.0 - start
	while x_of(step) < size.x:
		var x := x_of(step)
		if x >= KEYS:
			var bar_line := is_zero_approx(fmod(step + start, 16.0))
			draw_line(Vector2(x, RULER), Vector2(x, bottom), Color(1, 1, 1, 0.16 if bar_line else 0.05))
			if bar_line:
				draw_string(font, Vector2(x + 3, RULER - 7), str(int((step + start) / 16.0) + 1), HORIZONTAL_ALIGNMENT_LEFT, -1, 12, DIM)
		step += 4.0
	var end_x := x_of(float(clip.length))
	if end_x < size.x:
		draw_rect(Rect2(maxf(end_x, KEYS), RULER, size.x - maxf(end_x, KEYS), bottom - RULER), Color(0, 0, 0, 0.45))
	# The notes.
	var ink: Color = inst.color
	for n in shown():
		var r := _note_rect(n)
		if r.end.x < KEYS or r.position.x > size.x or r.end.y < RULER or r.position.y > bottom:
			continue
		var picked := chosen.any(func(m): return is_same(m, n))
		draw_rect(r, Color(ink.lightened(0.25), 0.45 + 0.55 * float(n.velocity)))
		draw_rect(r, Color.WHITE if picked else Color(0, 0, 0, 0.5), false, 1.0)
	# The velocity lane.
	draw_rect(Rect2(KEYS, bottom, size.x - KEYS, VELOCITY), Color(0.11, 0.115, 0.135))
	draw_line(Vector2(KEYS, bottom), Vector2(size.x, bottom), Color(1, 1, 1, 0.2))
	for n in shown():
		var x := x_of(float(n.step))
		if x < KEYS or x > size.x:
			continue
		var picked := chosen.any(func(m): return is_same(m, n))
		var top := bottom + VELOCITY - 4 - float(n.velocity) * (VELOCITY - 10)
		var stalk: Color = Color.WHITE if picked else ink.lightened(0.3)
		draw_line(Vector2(x, bottom + VELOCITY - 4), Vector2(x, top), stalk, 2.0)
		draw_rect(Rect2(x - 3, top - 3, 6, 6), stalk)
	# The playhead, where it is in the clip.
	var at: float = timeline.position() - start
	if at >= 0.0 and at <= float(clip.length) and x_of(at) >= KEYS:
		draw_line(Vector2(x_of(at), 0), Vector2(x_of(at), size.y), Color(1, 0.3, 0.28) if timeline.recording else Color(1, 1, 1, 0.85), 1.5)
	# The piano, and the ruler over everything.
	draw_rect(Rect2(0, RULER, KEYS, bottom - RULER), Color(0.85, 0.86, 0.88))
	for note in range(note_at(bottom), note_at(RULER) + 1):
		var y := y_of(note)
		if (note % 12) in BLACK:
			draw_rect(Rect2(0, y + 1, KEYS * 0.62, ROW - 2), Color(0.12, 0.12, 0.14))
		else:
			draw_line(Vector2(0, y + ROW), Vector2(KEYS, y + ROW), Color(0, 0, 0, 0.18))
		if note % 12 == 0:
			draw_string(font, Vector2(KEYS - 26, y + ROW - 1), note_name(note), HORIZONTAL_ALIGNMENT_LEFT, -1, 10, Color(0.2, 0.2, 0.24))
	draw_rect(Rect2(0, bottom, KEYS, VELOCITY), Color(0.14, 0.145, 0.17))
	draw_string(font, Vector2(8, bottom + 16), "Velocity", HORIZONTAL_ALIGNMENT_LEFT, -1, 11, DIM)
	draw_rect(Rect2(0, 0, KEYS, RULER), Color(0.14, 0.145, 0.17))
	draw_string(font, Vector2(8, RULER - 7), "Notes", HORIZONTAL_ALIGNMENT_LEFT, -1, 12, DIM)


func _note_rect(n: Dictionary) -> Rect2:
	var length := minf(float(n.length), float(clip.length) - float(n.step))
	return Rect2(x_of(float(n.step)), y_of(int(n.note)) + 1, maxf(length * zoom, 3.0), ROW - 2)


# ── What is where ────────────────────────────────────────────────────────────────────────────────────────────

## What is at a point: {zone, note}, the zone one of "ruler", "piano", "velocity" (a note's stalk), "lane" (the
## velocity lane, no stalk there), "length" (a note's right end), "note", "grid" (an empty place), or nothing.
func zone_at(at: Vector2) -> Dictionary:
	if at.x < 0.0 or at.y < 0.0 or at.x > size.x or at.y > size.y:
		return {}
	if at.y < RULER:
		return {"zone": "ruler"} if at.x >= KEYS else {}
	if at.x < KEYS:
		return {"zone": "piano", "pitch": note_at(at.y)} if at.y < lane_top() else {}
	if at.y >= lane_top():
		var nearest = null
		for n in shown():
			if absf(x_of(float(n.step)) - at.x) <= 4.0 and (nearest == null or absf(x_of(float(n.step)) - at.x) < absf(x_of(float(nearest.step)) - at.x)):
				nearest = n
		return {"zone": "velocity", "note": nearest} if nearest != null else {"zone": "lane"}
	var notes_here := shown()
	for i in range(notes_here.size() - 1, -1, -1):
		var n: Dictionary = notes_here[i]
		var r := _note_rect(n)
		if r.has_point(at):
			return {"zone": "length" if r.size.x > 10.0 and at.x >= r.end.x - EDGE else "note", "note": n}
	return {"zone": "grid"} if step_at(at.x) < float(clip.length) else {}


func hint_at(at: Vector2) -> String:
	var found := zone_at(at)
	match found.get("zone", ""):
		"ruler":
			return "Click to put the playhead here"
		"piano":
			return "%s: click to hear it" % note_name(found.pitch)
		"velocity":
			return "Velocity %d: drag up or down (the chosen notes together)" % roundi(float(found.note.velocity) * 127.0)
		"length":
			return "Drag to lengthen or shorten it"
		"note":
			return "%s, velocity %d: drag to move it (Option as you drop: a copy), Shift-click to choose more  ·  Delete, Cmd-D, comma and full stop" % [
				note_name(int(found.note.note)), roundi(float(found.note.velocity) * 127.0)]
		"grid":
			return "Click to add a note (%s, a grid line long; drag to make it longer)" % note_name(note_at(at.y))
	return ""


# ── The mouse ────────────────────────────────────────────────────────────────────────────────────────────────

func _gui_input(event: InputEvent) -> void:
	if inst == null:
		return
	if event is InputEventMouseButton:
		var e: InputEventMouseButton = event
		if e.pressed and e.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN, MOUSE_BUTTON_WHEEL_LEFT, MOUSE_BUTTON_WHEEL_RIGHT]:
			var amount := -1.0 if e.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_LEFT] else 1.0
			if e.meta_pressed or e.ctrl_pressed:
				set_zoom(zoom * (1.15 if amount < 0 else 1.0 / 1.15), e.position.x)
			elif e.shift_pressed or e.button_index in [MOUSE_BUTTON_WHEEL_LEFT, MOUSE_BUTTON_WHEEL_RIGHT]:
				scroll_x = maxf(scroll_x + amount * 40.0 / zoom, 0.0)
			else:
				scroll_y = clampf(scroll_y + amount * ROW * 3.0, 0.0, _most_scroll())
			accept_event()
		elif e.button_index == MOUSE_BUTTON_LEFT:
			accept_event()
			if e.pressed:
				press(e.position, e.shift_pressed)
			else:
				release(e.position, e.alt_pressed)
	elif event is InputEventMouseMotion and not _drag.is_empty():
		drag(event.position)
	elif event is InputEventPanGesture:
		scroll_x = maxf(scroll_x + event.delta.x * 6.0 / zoom, 0.0)
		scroll_y = clampf(scroll_y + event.delta.y * 12.0, 0.0, _most_scroll())
	elif event is InputEventMagnifyGesture:
		set_zoom(zoom * event.factor, event.position.x)


func set_zoom(new_zoom: float, around_x := -1.0) -> void:
	var x := around_x if around_x >= KEYS else KEYS + (size.x - KEYS) / 2
	var anchor := step_at(x)
	zoom = clampf(new_zoom, 2.0, 96.0)
	scroll_x = maxf(anchor - (x - KEYS) / zoom, 0.0)


## A press at a point (the automated checks call these): `add` (Shift) chooses one more note, or one fewer.
func press(at: Vector2, add := false) -> void:
	_drag = {}
	var found := zone_at(at)
	match found.get("zone", ""):
		"ruler":
			timeline.locate(float(clip.start) + maxf(_snap(step_at(at.x)), 0.0))
		"piano":
			preview(found.pitch, new_velocity)
		"velocity":
			var n: Dictionary = found.note
			if not chosen.any(func(m): return is_same(m, n)):
				chosen = [n]
			_drag = {"what": "velocity", "notes": chosen.duplicate(), "from_y": at.y, "from": chosen.map(func(m): return float(m.velocity))}
		"note", "length":
			var n: Dictionary = found.note
			if add:
				if chosen.any(func(m): return is_same(m, n)):
					chosen = chosen.filter(func(m): return not is_same(m, n))
				else:
					chosen.append(n)
				return
			if not chosen.any(func(m): return is_same(m, n)):
				chosen = [n]
			if found.zone == "note":
				preview(int(n.note), float(n.velocity))
			_drag = {"what": "move" if found.zone == "note" else "length", "anchor": n, "notes": chosen.duplicate(),
				"grab_step": step_at(at.x), "grab_note": note_at(at.y), "steps": chosen.map(func(m): return float(m.step)),
				"pitches": chosen.map(func(m): return int(m.note)), "lengths": chosen.map(func(m): return float(m.length))}
		"grid":  # a new note, a grid line long (dragged on from here, longer)
			timeline.remember("Add note")
			var n := {"step": maxf(floorf(step_at(at.x) / _unit()) * _unit() if timeline.grid > 0 else step_at(at.x), 0.0), "length": _unit(),
				"note": note_at(at.y), "velocity": new_velocity}
			clip.notes.append(n)
			chosen = [n]
			preview(int(n.note), float(n.velocity))
			_drag = {"what": "length", "anchor": n, "notes": [n], "grab_step": step_at(at.x), "grab_note": note_at(at.y), "steps": [float(n.step)],
				"pitches": [int(n.note)], "lengths": [float(n.length)], "moved": true, "added": true}
			_send()
		_:
			chosen = []


func drag(at: Vector2) -> void:
	match _drag.get("what", ""):
		"move":  # every chosen note with the one held: along (its start to the grid), and up or down
			_first_move("Move notes")
			var i: int = _drag.notes.find(_drag.anchor)
			var to := _snap(_drag.steps[i] + step_at(at.x) - _drag.grab_step)
			var along: float = to - _drag.steps[i]
			var up: int = note_at(at.y) - _drag.grab_note
			for k in _drag.notes.size():
				_drag.notes[k].step = clampf(_drag.steps[k] + along, 0.0, maxf(float(clip.length) - 0.01, 0.0))
				_drag.notes[k].note = clampi(_drag.pitches[k] + up, 0, 127)
		"length":
			_first_move("Note length")
			var i: int = _drag.notes.find(_drag.anchor)
			var end := maxf(_snap(step_at(at.x)), float(_drag.anchor.step) + 0.25)
			var change: float = end - float(_drag.anchor.step) - _drag.lengths[i]
			if _drag.get("added", false):
				change = maxf(change, 0.0)  # a new note is at least a grid line long
			for k in _drag.notes.size():
				_drag.notes[k].length = maxf(_drag.lengths[k] + change, 0.25)
		"velocity":
			_first_move("Velocity")
			var change: float = (_drag.from_y - at.y) / (VELOCITY - 10.0)
			for k in _drag.notes.size():
				_drag.notes[k].velocity = clampf(_drag.from[k] + change, 0.02, 1.0)
			new_velocity = float(_drag.notes[0].velocity)


func _first_move(what: String) -> void:
	if not _drag.get("moved", false):
		timeline.remember(what)
		_drag.moved = true


func release(_at: Vector2, copy := false) -> void:
	var done := _drag
	_drag = {}
	if not done.get("moved", false):
		return
	if done.what == "move" and copy:  # Option as you drop: the notes where they were, and copies where they went
		var copies := []
		for k in done.notes.size():
			var n: Dictionary = done.notes[k]
			copies.append(n.duplicate())
			n.step = done.steps[k]
			n.note = done.pitches[k]
		clip.notes.append_array(copies)
		chosen = copies
	_send()


## Hears a note, briefly (not while recording: it would be taken).
func preview(note: int, velocity: float) -> void:
	if timeline.recording or inst == null:
		return
	var id: int = inst.source_id
	app.audio.note_on(id, note, velocity)
	get_tree().create_timer(0.3).timeout.connect(func() -> void: app.audio.note_off(id, note))


func _send() -> void:
	timeline.sync(inst)
	timeline.changed.emit()


# ── Keys (the edit window hands them over while it shows the notes) ─────────────────────────────────────────

## Returns whether the key was its own.
func handle_key(event: InputEventKey) -> bool:
	var key := event.physical_keycode
	var command := event.meta_pressed or event.ctrl_pressed
	if key in [KEY_BACKSPACE, KEY_DELETE] and not chosen.is_empty():
		timeline.remember("Delete notes")
		clip.notes = clip.notes.filter(func(n): return not chosen.any(func(m): return is_same(m, n)))
		chosen = []
		_send()
	elif key == KEY_A and command:
		chosen = shown()
	elif command and app.bindings.command_for(key) == "duplicate_clip" and not chosen.is_empty():  # a second of them, just after
		var first := INF
		var last := -INF
		for n in chosen:
			first = minf(first, float(n.step))
			last = maxf(last, float(n.step) + float(n.length))
		var along := maxf(timeline.snap(last - first) if timeline.grid > 0 else last - first, _unit())
		timeline.remember("Duplicate notes")
		var copies := []
		for n in chosen:
			var copy: Dictionary = n.duplicate()
			copy.step = float(n.step) + along
			copies.append(copy)
		clip.notes.append_array(copies)
		chosen = copies
		_send()
	elif key in [KEY_COMMA, KEY_PERIOD, KEY_KP_SUBTRACT, KEY_KP_ADD] and not command and not chosen.is_empty():
		timeline.remember("Nudge notes")
		var along := (1.0 if key in [KEY_PERIOD, KEY_KP_ADD] else -1.0) * (float(timeline.grid) if timeline.grid > 0 else 0.25)
		for n in chosen:
			n.step = clampf(float(n.step) + along, 0.0, maxf(float(clip.length) - 0.01, 0.0))
		_send()
	else:
		return false
	return true
