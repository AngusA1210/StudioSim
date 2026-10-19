extends CanvasLayer
## The edit window (R, in a Record room), as a DAW's: every track along the timeline (timeline_view.gd), and the
## transport above them: play and stop (Space), record (Cmd-Space), loop playback, where the music is (bar | beat, and
## minutes and seconds: click the bar | beat and type one, or a time, to go there), the grid clips snap to, and zoom.
## Enter goes back to the start. Delete takes the chosen clip away, Cmd-D puts a second of it just after it, and L
## loops it. Tab (or Cmd-=) goes over to the mix window. It docks along the bottom of the screen, the room in view
## above it, and you can walk about while it is open.

const TimelineView := preload("res://scripts/timeline_view.gd")
const Hints := preload("res://scripts/hints.gd")
const DIM := Color(0.62, 0.65, 0.74)
const RECORD_RED := Color(1.0, 0.3, 0.28)

var app
var timeline
var view: Control

var _root: Control
var _panel: PanelContainer
var _play: Button
var _record: Button
var _loop: Button
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
	var key: int = event.physical_keycode
	var command: bool = event.meta_pressed or event.ctrl_pressed
	var action: String = app.bindings.action_for(key)
	if key == KEY_ESCAPE or action == "edit_window":
		close()
	elif action == "mixer" and not command:
		close()
		app.mixer.open()
	elif key in [KEY_BACKSPACE, KEY_DELETE] and not view.selected.is_empty():
		timeline.remove_clip(view.selected.inst, view.selected.index)
		view.selected = {}
	elif key == KEY_D and command and not view.selected.is_empty():
		duplicate_selected()
	elif key in [KEY_ENTER, KEY_KP_ENTER] and not command:  # back to the start, as Return is in Pro Tools
		timeline.locate(0.0)
	elif key == KEY_L and not command and not view.selected.is_empty():
		loop_selected()
	else:
		return
	get_viewport().set_input_as_handled()


## L: loop playback round the chosen clip, from its start to its end exactly.
func loop_selected() -> void:
	var span: Vector2 = timeline.clip_steps(view.selected.inst.clips[view.selected.index])
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


## Cmd-D: a second of the chosen clip, just after it.
func duplicate_selected() -> void:
	var inst = view.selected.inst
	var span: Vector2 = timeline.clip_steps(inst.clips[view.selected.index])
	timeline.place_clip(inst, view.selected.index, inst, span.y, true)
	view.selected = {"inst": inst, "index": inst.clips.size() - 1}


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
	_record.text = "●  Recording" if timeline.recording else "●  Record"
	_loop.set_pressed_no_signal(timeline.loop_on)
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
	_record = _button(header, "●  Record", func() -> void: app.toggle_record(), "Record the armed tracks from the playhead, or stop (Cmd-Space)")
	_record.custom_minimum_size.x = 120
	_loop = _button(header, "⟳  Loop", func() -> void: timeline.set_loop(not timeline.loop_on), "Loop playback round the range marked on the ruler (drag along the ruler to mark another, or press L to loop the chosen clip)")
	_loop.toggle_mode = true
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
	_status = Label.new()
	_status.add_theme_color_override("font_color", DIM)
	_status.add_theme_font_size_override("font_size", 13)
	_status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_status.clip_text = true
	header.add_child(_status)
	_button(header, "Mix window  (Tab)", func() -> void:
		close()
		app.mixer.open(), "")
	_close = _button(header, "Close", close, "")

	view = TimelineView.new()
	view.setup(app)
	view.size_flags_vertical = Control.SIZE_EXPAND_FILL
	view.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_child(view)
	_hint = Hints.line()
	box.add_child(_hint)


func _button(parent: Control, text: String, on_pressed: Callable, hint: String) -> Button:
	var button := Button.new()
	button.text = text
	button.focus_mode = Control.FOCUS_NONE
	button.pressed.connect(on_pressed)
	if hint != "":
		Hints.give(button, hint)
	parent.add_child(button)
	return button
