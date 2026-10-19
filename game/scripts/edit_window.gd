extends CanvasLayer
## The edit window (R, in a Record room), as a DAW's: every track along the timeline (timeline_view.gd), and the
## transport above them: play and stop (Space), record (Cmd-Space; Option-L for Loop Record, a take each time round the
## loop), loop playback (L), whether insertion follows playback (N), a count-in, where the music is (bar | beat, and
## minutes and seconds: click the bar | beat and type one, or a time, to go there), the grid clips snap to, zoom, and
## undo and redo. Enter goes back to the start. Shift-click chooses more clips, Cmd-A all of them; Delete takes the chosen
## ones away, Cmd-D puts a second of them just after, Cmd-E splits them at the playhead, comma and full stop (or - and +
## on the number pad) nudge them, Ctrl-Shift-↑ ↓ turn their clip gain up or down a dB, and U loops round them. Cmd-Z
## undoes an edit and Cmd-X (or Cmd-Shift-Z) does it again (the Cmd shortcuts can be changed on the Controls page).
## Double-click a MIDI clip for its notes, in the MIDI editor (midi_editor.gd) in the tracks' place; Esc goes back. Tab
## (or Cmd-=) goes over to the mix window. It docks along the bottom of the screen, the room in view above it, and you
## can walk about while it is open.

const TimelineView := preload("res://scripts/timeline_view.gd")
const MidiEditor := preload("res://scripts/midi_editor.gd")
const Hints := preload("res://scripts/hints.gd")
const DIM := Color(0.62, 0.65, 0.74)
const RECORD_RED := Color(1.0, 0.3, 0.28)

var app
var timeline
var view: Control
var notes: Control  # a MIDI clip's notes (midi_editor.gd), in the tracks' place while they are edited
var _notes_bar: HBoxContainer
var _notes_title: Label

var _root: Control
var _panel: PanelContainer
var _play: Button
var _record: Button
var _loop: Button
var _follow: Button
var _count_in: OptionButton
var _undo: Button
var _redo: Button
var _counter: LineEdit  # bar | beat, which can be typed into
var _clock: Label       # minutes and seconds
var _close: Button
var _grid: OptionButton
var _status: Label
var _hint: Label
var _status_until := 0


func setup(the_app) -> void:
	app = the_app
	timeline = app.timeline
	layer = 9
	_build()
	_root.visible = false
	app.session.notice.connect(func(text: String) -> void:
		_status.text = text
		_status_until = Time.get_ticks_msec() + 4000)


func is_open() -> bool:
	return _root.visible


func open() -> void:
	if not timeline.is_record():
		return
	app.player.release_keys()
	_root.visible = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func close() -> void:
	_root.visible = false
	if app.title == null or not app.title.is_open():
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _input(event: InputEvent) -> void:
	if not is_open() or not (event is InputEventKey) or not event.pressed or event.echo or app.name_prompt.is_open():
		return
	if _counter.has_focus():  # being typed into: the keys are its own, but Esc lets it go
		if event.physical_keycode == KEY_ESCAPE:
			_counter.release_focus()
			get_viewport().set_input_as_handled()
		return
	if editing_notes() and notes.handle_key(event):  # the notes' own keys first
		get_viewport().set_input_as_handled()
		return
	var key: int = event.physical_keycode
	var command: bool = event.meta_pressed or event.ctrl_pressed
	var action: String = app.bindings.action_for(key)
	var items: Array = view.chosen_items() if not editing_notes() else []
	if key == KEY_ESCAPE and editing_notes():
		show_tracks()
	elif key == KEY_ESCAPE or action == "edit_window":
		close()
	elif action == "mixer" and not command:
		close()
		app.mixer.open()
	elif key in [KEY_UP, KEY_DOWN] and event.ctrl_pressed and event.shift_pressed and not items.is_empty():  # clip gain, a dB
		timeline.remember("Clip gain")
		for it in items:
			timeline.set_clip_gain([it], float(it.clip.get("gain_db", 0.0)) + (1.0 if key == KEY_UP else -1.0), false)
		timeline._sync_items(items)
	elif key in [KEY_BACKSPACE, KEY_DELETE] and not items.is_empty():
		timeline.remove_clips(items)
		view.chosen = []
	elif key == KEY_A and command and not editing_notes():
		view.choose_all()
	elif command and app.bindings.command_for(key) == "duplicate_clip" and not items.is_empty():
		duplicate_selected()
	elif action == "to_start" and not command:  # back to the start, as Return is in Pro Tools
		timeline.locate(0.0)
	elif action == "follow" and not command:
		app.toggle_follow()
	elif key == KEY_L and event.alt_pressed and not command:  # Loop Record, as Option-L is in Pro Tools
		app.toggle_loop_record()
	elif key == KEY_L and not command:  # loop playback on or off
		timeline.set_loop(not timeline.loop_on)
	elif key == KEY_U and not command and not items.is_empty():  # (Logic's key for the same)
		loop_selected()
	elif command and app.bindings.command_for(key) == "separate" and not editing_notes():
		separate_selected()
	elif key in [KEY_COMMA, KEY_PERIOD, KEY_KP_SUBTRACT, KEY_KP_ADD] and not command and not items.is_empty():
		var amount: float = float(timeline.grid) if timeline.grid > 0 else timeline.NUDGE_SECONDS / timeline.step_seconds()
		view.chosen = timeline.move_clips(items, amount if key in [KEY_PERIOD, KEY_KP_ADD] else -amount, 0, false, "Nudge")
	else:
		return
	get_viewport().set_input_as_handled()


## A MIDI clip's notes, in the MIDI editor (double-click the clip); Esc goes back to the tracks.
func edit_notes(inst, index: int) -> void:
	notes.edit(inst, index)
	view.visible = false
	notes.visible = true
	_notes_bar.visible = true


func show_tracks() -> void:
	notes.visible = false
	notes.inst = null
	view.visible = true
	_notes_bar.visible = false


func editing_notes() -> bool:
	return notes.visible


## U: loop playback round the chosen clips, from the first's start to the last's end exactly (and on).
func loop_selected() -> void:
	var span: Vector2 = timeline.span_of(view.chosen_items())
	timeline.set_loop(true, span.x, span.y)


## Where typing in the counter says to go: a bar ("5"), a bar and beat ("5 | 3", "5 3", "5.3"), a sixteenth too
## ("5 | 3 | 2"), or a time in minutes and seconds ("1:24.5"). Returns the step, or -1 if it can't be read.
func step_for(text: String) -> float:
	var t := text.strip_edges()
	if t.contains(":"):
		var parts := t.split(":")
		if parts.size() != 2 or not parts[0].strip_edges().is_valid_int() or not parts[1].strip_edges().is_valid_float():
			return -1.0
		var seconds: float = int(parts[0]) * 60.0 + float(parts[1])
		return seconds / timeline.step_seconds()
	var numbers := []
	for part in t.replace("|", " ").replace(".", " ").split(" ", false):
		if not part.is_valid_int():
			return -1.0
		numbers.append(maxi(int(part), 1))
	if numbers.is_empty() or numbers.size() > 3:
		return -1.0
	var bar: int = numbers[0]
	var beat: int = numbers[1] if numbers.size() > 1 else 1
	var sixteenth: int = numbers[2] if numbers.size() > 2 else 1
	return (bar - 1) * 16.0 + (mini(beat, 4) - 1) * 4.0 + (mini(sixteenth, 4) - 1)


func _on_counter_submitted(text: String) -> void:
	var step := step_for(text)
	_counter.release_focus()
	if step >= 0.0:
		timeline.locate(step)
	else:
		app.session.notice.emit("Type a bar, a bar and beat (5 | 3), or a time (1:24)")


## The position's minutes and seconds, as "0:05.21".
func clock_text(step: float) -> String:
	var seconds: float = maxf(step, 0.0) * timeline.step_seconds()
	return "%d:%05.2f" % [int(seconds / 60.0), fmod(seconds, 60.0)]


## Cmd-E: the chosen clips split in two at the playhead (their second halves chosen then); with none chosen, every clip
## the playhead is in.
func separate_selected() -> void:
	var at: float = timeline.position()
	var items: Array = view.chosen_items()
	if not items.is_empty():
		var halves := []
		for it in items:
			var second: int = timeline.separate(it.inst, timeline.index_of(it.inst, it.clip), at)
			if second >= 0:
				halves.append({"inst": it.inst, "clip": it.inst.clips[second]})
		if halves.is_empty():
			app.session.notice.emit("The playhead isn't in the chosen clip%s" % ("s" if items.size() > 1 else ""))
		else:
			view.chosen = halves
		return
	var split := 0
	for inst in app.instruments:
		for c in inst.clips.size():
			var span: Vector2 = timeline.clip_steps(inst.clips[c])
			if at > span.x and at < span.y and timeline.separate(inst, c, at) >= 0:
				split += 1
				break  # (clips on a track don't overlap)
	if split == 0:
		app.session.notice.emit("There's no clip under the playhead to split")


## Cmd-D: a second of the chosen clips, just after them.
func duplicate_selected() -> void:
	var items: Array = view.chosen_items()
	var span: Vector2 = timeline.span_of(items)
	view.chosen = timeline.move_clips(items, span.y - span.x, 0, true, "Duplicate")


func _process(_delta: float) -> void:
	if not is_open():
		return
	if not timeline.is_record():
		close()
		return
	var vp := get_viewport().get_visible_rect().size
	var height := minf(560.0, vp.y * 0.62)
	_panel.position = Vector2(12, vp.y - height - 12)
	_panel.size = Vector2(vp.x - 24, height)
	var at: float = timeline.position()
	if not _counter.has_focus():
		_counter.text = "%d | %d" % [int(at / 16.0) + 1, int(fmod(at, 16.0) / 4.0) + 1]
	_clock.text = clock_text(at)
	_close.text = "Close  (%s)" % app.bindings.label("edit_window")
	_play.text = "■  Stop" if timeline.playing else "▶  Play"
	_record.add_theme_color_override("font_color", RECORD_RED if timeline.recording else Color(0.9, 0.6, 0.58))
	var counting: int = timeline.counting_in()
	var loop_mark := "⟳" if app.settings.loop_record else ""
	_record.text = "●%s  Count  %d" % [loop_mark, counting] if counting > 0 else ("●%s  Recording" % loop_mark if timeline.recording else "●%s  Record" % loop_mark)
	if editing_notes() and notes.inst != null:
		_notes_title.text = "%s  ·  %s" % [notes.inst.display_name, str(notes.clip.get("name", ""))]
	_count_in.select(app.settings.count_in_bars)
	_undo.disabled = timeline.undo_what() == "" or timeline.recording
	_redo.disabled = timeline.redo_what() == "" or timeline.recording
	_loop.set_pressed_no_signal(timeline.loop_on)
	_follow.set_pressed_no_signal(app.settings.insertion_follows)
	if Time.get_ticks_msec() >= _status_until:
		var armed: Array = app.instruments.filter(func(i): return i.armed)
		_status.text = "Armed: " + ", ".join(armed.map(func(i): return i.display_name)) if not armed.is_empty() else ""
	_hint.text = Hints.under_mouse(_panel)


func _build() -> void:
	_root = Control.new()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_root)
	_panel = PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.09, 0.095, 0.11, 0.97)
	style.set_corner_radius_all(10)
	style.set_border_width_all(1)
	style.border_color = Color(1, 1, 1, 0.14)
	style.set_content_margin_all(12)
	_panel.add_theme_stylebox_override("panel", style)
	_root.add_child(_panel)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	_panel.add_child(box)

	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 8)
	box.add_child(header)
	var title := Label.new()
	title.text = "Edit"
	title.add_theme_font_size_override("font_size", 20)
	header.add_child(title)
	_play = _button(header, "▶  Play", func() -> void: app.toggle_transport(), "Play from the playhead, or stop and go back to where it started (Space)")
	_play.custom_minimum_size.x = 96
	_record = _button(header, "●  Record", func() -> void: app.toggle_record(), func() -> String:
		return ("Loop Record (Option-L to switch off): round the loop from its start, a take each time round, or stop (%s)" if app.settings.loop_record else
			"Record the armed tracks from the playhead, or stop (%s)  ·  Option-L for Loop Record") % app.bindings.label("record"))
	_record.custom_minimum_size.x = 120
	_loop = _button(header, "⟳  Loop", func() -> void: timeline.set_loop(not timeline.loop_on), "Loop playback round the range marked on the ruler (drag along the ruler to mark another, or press L to loop the chosen clip)")
	_loop.toggle_mode = true
	_follow = _button(header, "↦  Follow", func() -> void: app.toggle_follow(), func() -> String:
		return "Insertion follows playback (%s): stopping leaves the playhead where the music stopped, rather than going back to where it started" % \
			app.bindings.label("follow"))
	_follow.toggle_mode = true
	_count_in = OptionButton.new()
	for item in ["No count-in", "Count-in: 1", "Count-in: 2"]:
		_count_in.add_item(item)
	_count_in.focus_mode = Control.FOCUS_NONE
	_count_in.item_selected.connect(func(i: int) -> void:
		app.settings.count_in_bars = i
		app.settings.save_to_disk())
	Hints.give(_count_in, "Bars of the click before recording from a stop, the music waiting, as Pro Tools' Count Off")
	header.add_child(_count_in)
	_counter = LineEdit.new()
	_counter.add_theme_font_size_override("font_size", 20)
	_counter.custom_minimum_size.x = 104
	_counter.alignment = HORIZONTAL_ALIGNMENT_CENTER
	_counter.flat = true
	_counter.select_all_on_focus = true
	_counter.text_submitted.connect(_on_counter_submitted)
	Hints.give(_counter, "Where the music is, bar | beat. Click it and type a bar, a bar and beat (5 | 3) or a time (1:24) to go there; Enter goes back to the start")
	header.add_child(_counter)
	_clock = Label.new()
	_clock.add_theme_font_size_override("font_size", 15)
	_clock.add_theme_color_override("font_color", DIM)
	_clock.custom_minimum_size.x = 70
	Hints.give(_clock, "Where the music is, in minutes and seconds")
	header.add_child(_clock)
	var grid_label := Label.new()
	grid_label.text = "Grid"
	grid_label.add_theme_color_override("font_color", DIM)
	header.add_child(grid_label)
	_grid = OptionButton.new()
	for entry in timeline.GRIDS:
		_grid.add_item(entry[0])
	_grid.select(2)
	_grid.item_selected.connect(func(i: int) -> void: timeline.grid = timeline.GRIDS[i][1])
	Hints.give(_grid, "What clips and the playhead snap to")
	header.add_child(_grid)
	_button(header, "−", func() -> void: view.set_zoom(view.zoom / 1.5), "Zoom out (Cmd and the scroll wheel, or a pinch)")
	_button(header, "+", func() -> void: view.set_zoom(view.zoom * 1.5), "Zoom in")
	_undo = _button(header, "↶", func() -> void: app.undo_edit(), func() -> String:
		return "Undo %s (%s)" % [timeline.undo_what(), app.bindings.label("undo")] if timeline.undo_what() != "" else "Nothing to undo")
	_redo = _button(header, "↷", func() -> void: app.undo_edit(true), func() -> String:
		return "Redo %s (%s)" % [timeline.redo_what(), app.bindings.label("redo")] if timeline.redo_what() != "" else "Nothing to redo")
	_status = Label.new()
	_status.add_theme_color_override("font_color", DIM)
	_status.add_theme_font_size_override("font_size", 13)
	_status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_status.clip_text = true
	header.add_child(_status)
	_button(header, "Mix  (Tab)", func() -> void:
		close()
		app.mixer.open(), "")
	_close = _button(header, "Close", close, "")

	_notes_bar = HBoxContainer.new()
	_notes_bar.add_theme_constant_override("separation", 10)
	_notes_bar.visible = false
	box.add_child(_notes_bar)
	_button(_notes_bar, "←  Tracks  (Esc)", show_tracks, "Back to the tracks")
	_notes_title = Label.new()
	_notes_title.add_theme_color_override("font_color", DIM)
	_notes_bar.add_child(_notes_title)
	view = TimelineView.new()
	view.setup(app)
	view.size_flags_vertical = Control.SIZE_EXPAND_FILL
	view.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_child(view)
	notes = MidiEditor.new()
	notes.setup(app)
	notes.size_flags_vertical = Control.SIZE_EXPAND_FILL
	notes.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	notes.visible = false
	box.add_child(notes)
	_hint = Hints.line()
	box.add_child(_hint)


func _button(parent: Control, text: String, on_pressed: Callable, hint) -> Button:
	var button := Button.new()
	button.text = text
	button.focus_mode = Control.FOCUS_NONE
	button.pressed.connect(on_pressed)
	if not (hint is String and hint == ""):
		Hints.give(button, hint)
	parent.add_child(button)
	return button
