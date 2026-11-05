extends CanvasLayer
## The tutorial (the title screen's Tutorial): a card at the top of the screen that takes a newcomer through StudioSim a
## step at a time, in a room of their own made on the New room page as any room is (a Record room, from the empty
## template, filled in for them): looking and walking, adding an instrument and putting it down, playing it, its
## pattern, carrying it elsewhere, the mix window and mixing, the edit window, arming a track and recording, playing
## it back, and saving. Each step says what to do, with the keys as they are bound now, and goes on by itself once it
## is done. Back, Skip and End are on the card, for whenever the mouse is free (Esc frees it, with the menu). In the
## room the card is at the left, clear of what the screen shows at its corners; over a window or the menu it is
## smaller, at the very top, where their headings leave room (on the New room page, over the foot of its template list).
## Over the title screen, at its right.

const Hints := preload("res://scripts/hints.gd")
const ACCENT := Color(0.49, 0.89, 0.82)
const DIM := Color(0.62, 0.65, 0.74)
const INK := Color(0.92, 0.93, 0.96)
const DONE_FOR := 0.9  # seconds a step shows it is done before the next comes
const WIDTH := 500.0   # the card's, in the room
const SMALL_WIDTH := 640.0  # and over a window (between the mix window's heading and its buttons)
const MOUSE_NOTE := "Esc frees the mouse (with the menu) for Back, Skip and End."

var app
var step := -1  # the step shown; -1 while the tutorial isn't running
var _steps: Array = []  # {"title", "text": Callable → String, "done": Callable → bool, "begin": Callable, "action": [words, Callable], "skip_if": Callable → bool}
var _seen := {}  # what the step has watched for since it began
var _done_in := 0.0  # counting down the step's moment of being done (0: not done)
var _small := false

var _card: PanelContainer
var _count: Label
var _small_title: Label  # (the step's name, beside the count, on the smaller card)
var _title: Label
var _text: Label
var _mouse_note: Label
var _action: Button
var _back: Button
var _skip: Button
var _end: Button


func setup(the_app) -> void:
	app = the_app
	layer = 15  # over the windows and the menu, under the questions they ask
	_build()
	_steps = _make_steps()
	_card.visible = false


func is_running() -> bool:
	return step >= 0


## From the first step: making the room.
func start() -> void:
	_go(0)


func end() -> void:
	step = -1
	_card.visible = false


func step_count() -> int:
	return _steps.size()


## The step's name ("" while not running), for the checks.
func step_title() -> String:
	return str(_steps[step].title) if is_running() else ""


func _go(index: int) -> void:
	if index >= _steps.size():
		end()
		return
	step = clampi(index, 0, _steps.size() - 1)
	var s: Dictionary = _steps[step]
	if s.has("skip_if") and s.skip_if.call():  # (a step this room hasn't the means for: on to the next)
		_go(step + 1)
		return
	_seen = {}
	_done_in = 0.0
	if s.has("begin"):
		s.begin.call()
	_card.visible = true
	_show()


func _show() -> void:
	var s: Dictionary = _steps[step]
	var done := _done_in > 0.0
	_count.text = "TUTORIAL  ·  %d of %d" % [step + 1, _steps.size()]
	_title.text = ("✓  " if done else "") + str(s.title)
	_small_title.text = _title.text
	for label in [_title, _small_title]:
		label.add_theme_color_override("font_color", ACCENT if done else INK)
	_text.text = s.text.call()
	_action.visible = s.has("action") and (not s.has("action_if") or s.action_if.call())
	if s.has("action"):
		_action.text = str(s.action[0])
	_back.disabled = step == 0
	_skip.visible = step < _steps.size() - 1


func _process(delta: float) -> void:
	if not is_running():
		return
	if _done_in > 0.0:
		_done_in -= delta
		if _done_in <= 0.0:
			_go(step + 1)
		else:
			_place()
		return
	var s: Dictionary = _steps[step]
	if s.done.call():
		_done_in = DONE_FOR
	_show()
	_place()


## In the room, at the left; smaller over a window or the menu, at the top (on the New room page, under its templates);
## over the title screen, on its right, clear of its words.
func _place() -> void:
	var vp := get_viewport().get_visible_rect().size
	var covered: bool = app.menu.is_open() or app.mixer.is_open() or app.edit_window.is_open() or app.sequencer.is_open() or \
		app.instrument_menu.is_open() or app.rooms_page.is_open() or app.amp_panel.is_open() or app.speaker_panel.is_open() or \
		app.mic_panel.is_open() or app.together_page.is_open() or app.avatar_page.is_open()
	if covered != _small:
		_small = covered
		_title.visible = not _small
		_small_title.visible = _small
		_text.add_theme_font_size_override("font_size", 13 if _small else 15)
	var hint := Hints.under_mouse(_card)  # (what a button does, under the mouse; or, the mouse caught, how to free it)
	_mouse_note.text = hint if hint != "" else (MOUSE_NOTE if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED else "")
	_mouse_note.visible = _mouse_note.text != ""
	var spare: Rect2 = app.rooms_page.spare_rect() if app.rooms_page.is_open() else Rect2()
	var width := minf(spare.size.x - 24.0 if spare.has_area() else (SMALL_WIDTH if _small else WIDTH), vp.x - 24.0)
	_card.custom_minimum_size.x = width
	_card.size = Vector2(width, 0.0)  # (as tall as its words)
	if spare.has_area():
		_card.position = Vector2(spare.position.x + 12.0, spare.end.y - _card.size.y - 12.0)
	elif _small:
		_card.position = Vector2((vp.x - width) / 2.0, 4.0)
	elif app.title.is_open():
		_card.position = Vector2(maxf(vp.x * 0.75 - width / 2.0, vp.x - width - 24.0), (vp.y - _card.size.y) / 2.0)
	else:  # (the left, a little above the middle: the screen's corners have its readouts, notices and keys)
		_card.position = Vector2(16.0, maxf(14.0, vp.y * 0.42 - _card.size.y / 2.0))


# ── The steps ────────────────────────────────────────────────────────────────────────────────────────────────

## A key as it is bound now ("T", "⌘S").
func _k(action: String) -> String:
	return app.bindings.label(action)


func _make_steps() -> Array:
	var player = app.player
	return [
		{"title": "Make a room",
			"text": func() -> String: return ("A room is what a session is in a DAW: everything in it, in a folder of its own. This one is filled in " +
				"for you: a Record room (with a timeline to record on) from the empty template. Change anything you like, then Create room."),
			"begin": func() -> void:
				_seen.path = app.session.path
				if not app.rooms_page.is_open():
					app.rooms_page.open_new("Tutorial room", "record", app.library.EMPTY_TEMPLATE),
			"action": ["New room page", func() -> void: app.rooms_page.open_new("Tutorial room", "record", app.library.EMPTY_TEMPLATE)],
			"action_if": func() -> bool: return not app.rooms_page.is_open(),
			"done": func() -> bool: return app.session.has_room() and app.session.path != _seen.path and not app.rooms_page.is_open()},
		{"title": "Look and walk",
			"text": func() -> String: return ("Move the mouse to look around (click first, if it doesn't), and walk with %s %s %s %s (%s to run). " +
				"You hear the room from where you stand, so its sound turns as you do.") % [_k("forward"), _k("left"), _k("back"), _k("right"), _k("run")],
			"begin": func() -> void: _seen.at = player.global_position,
			"done": func() -> bool: return not app.title.is_open() and player.global_position.distance_to(_seen.at) > 1.5},
		{"title": "Add an instrument",
			"text": func() -> String: return "Press %s for the instrument menu, and pick the Drums (or anything else you like)." % _k("add"),
			"begin": func() -> void: _seen.count = app.instruments.size(),
			"done": func() -> bool: return player.carried != null or app.instruments.size() > int(_seen.count)},
		{"title": "Put it down",
			"text": func() -> String: return ("It's in your hands: walk it to where it should stand and click (or press %s) to put it down. " +
				"It turns to face you.") % _k("carry"),
			"done": func() -> bool: return _carried_and_put_down()},
		{"title": "Play it",
			"text": func() -> String: return ("Face it and press %s to play it. The letter keys are its notes, each named on the keyboard at the " +
				"foot of the screen: on the drums, A is the kick, S the snare and T the hi-hat (at a kit, you sit on its stool). Play a little, " +
				"then %s gets up.") % [_k("play"), _k("stop")],
			"done": func() -> bool:
				if player.playing != null:
					_seen.played = true
				return _seen.get("played", false) and player.playing == null},
		{"title": "Give it a pattern",
			"text": func() -> String: return ("Standing at it, press %s for its pattern editor. Click squares to add notes (right-click one for how " +
				"hard it's hit); %s starts and stops the music. %s closes it.") % [_k("edit"), _k("transport"), _k("edit")],
			"done": func() -> bool:
				if app.sequencer.is_open():
					_seen.opened = true
				return _seen.get("opened", false) and not app.sequencer.is_open()},
		{"title": "Move it",
			"text": func() -> String: return ("Face it and press %s to pick it up, then click to put it down somewhere else. Its sound comes from " +
				"where it stands: walk round it and listen.") % _k("carry"),
			"done": func() -> bool: return _carried_and_put_down()},
		{"title": "The mix window",
			"text": func() -> String: return ("Press %s for the mix window: a channel strip for each instrument, as in a DAW. You can still walk " +
				"about while it's open.") % _k("mixer"),
			"done": func() -> bool: return app.mixer.is_open()},
		{"title": "Mix",
			"text": func() -> String: return ("Drag a fader to set a track's level, or turn its pan knob to place it. M mutes it and S solos it; " +
				"right-click its name for more.") + ("" if app.mixer.is_open() else "  (%s opens the mix window again.)" % _k("mixer")),
			"begin": func() -> void: _seen.mix = _mix_now(),
			"done": func() -> bool: return _mix_now() != _seen.mix},
		{"title": "Back to the room",
			"text": func() -> String: return ("%s closes the mix window. %s switches what you hear between the room, as you stand in it, and " +
				"the headphone mix of the faders: the top right of the screen says which.") % [_k("mixer"), _k("monitor")],
			"done": func() -> bool: return not app.mixer.is_open()},
		{"title": "The edit window",
			"text": func() -> String: return ("A Record room has a timeline: press %s for the edit window, each track's clips along the bars, " +
				"as in a DAW.") % _k("edit_window"),
			"skip_if": func() -> bool: return not app.timeline.is_record(),
			"done": func() -> bool: return app.edit_window.is_open()},
		{"title": "Arm a track",
			"text": func() -> String: return "Click the R on your instrument's row, beside its name, to make it ready to record.",
			"skip_if": func() -> bool: return not app.timeline.is_record(),
			"done": func() -> bool: return app.instruments.any(func(inst): return inst.armed)},
		{"title": "Record",
			"text": func() -> String: return ("Close the edit window (%s) and sit at the instrument (%s). %s records from the playhead: " +
				"play a few bars, and %s stops.") % [_k("edit_window"), _k("play"), _k("record"), _k("transport")],
			"skip_if": func() -> bool: return not app.timeline.is_record(),
			"begin": func() -> void: _seen.clips = _clip_count(),
			"done": func() -> bool: return _clip_count() > int(_seen.clips) and not app.timeline.recording},
		{"title": "Play it back",
			"text": func() -> String: return ("%s puts the playhead back at the start, and %s plays what you recorded. In the edit window (%s), " +
				"clips can be moved, trimmed and split, as in a DAW.") % [_k("to_start"), _k("transport"), _k("edit_window")],
			"skip_if": func() -> bool: return not app.timeline.is_record(),
			"done": func() -> bool:
				if not app.timeline.playing:
					_seen.stopped = true
				return _seen.get("stopped", false) and app.timeline.playing and not app.timeline.recording},
		{"title": "Save it",
			"text": func() -> String: return ("%s saves the room, in a folder of its own in the StudioSim folder; Open room… on the title " +
				"screen brings it back. Auto-save and backups are in Settings.") % _k("save"),
			"begin": func() -> void: _seen.saved = app.session.saved_at,
			"done": func() -> bool: return app.session.saved_at != int(_seen.saved)},
		{"title": "That's the tour",
			"text": func() -> String: return ("Esc opens the menu: the room's size and walls, the audio setup, settings, and every key on the " +
				"Controls page, each one changeable. Hold the mouse over anything to see what it does. Have fun."),
			"action": ["Done", end],
			"done": func() -> bool: return false},
	]


## Whether, since the step began, an instrument has been carried and then put down.
func _carried_and_put_down() -> bool:
	if app.player.carried != null:
		_seen.carried = true
	return _seen.get("carried", false) and app.player.carried == null and not app.instrument_menu.is_open()


## The faders, pans, mutes and solos as they are, to tell when one is moved.
func _mix_now() -> Array:
	var out: Array = [app.master_volume_db, app.room_volume_db]
	for inst in app.instruments:
		out.append([inst.level_db, inst.pan, inst.muted, inst.soloed, inst.room_db])
	return out


func _clip_count() -> int:
	var count := 0
	for inst in app.instruments:
		count += inst.clips.size()
	return count


# ── Building ────────────────────────────────────────────────────────────────────────────────────────────────

func _build() -> void:
	_card = PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.055, 0.06, 0.075, 0.94)
	style.set_corner_radius_all(12)
	style.set_border_width_all(1)
	style.border_color = Color(ACCENT, 0.35)
	style.content_margin_left = 18
	style.content_margin_right = 14
	style.content_margin_top = 10
	style.content_margin_bottom = 12
	_card.add_theme_stylebox_override("panel", style)
	add_child(_card)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 4)
	_card.add_child(column)

	var top := HBoxContainer.new()
	column.add_child(top)
	_count = Label.new()
	_count.add_theme_font_size_override("font_size", 11)
	_count.add_theme_color_override("font_color", ACCENT)
	_count.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	top.add_child(_count)
	_small_title = Label.new()
	_small_title.add_theme_font_size_override("font_size", 13)
	_small_title.visible = false
	top.add_child(_small_title)
	var gap := Control.new()
	gap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top.add_child(gap)
	_action = Button.new()
	_action.flat = true
	_action.focus_mode = Control.FOCUS_NONE
	_action.add_theme_font_size_override("font_size", 13)
	_action.add_theme_color_override("font_color", ACCENT)
	_action.pressed.connect(func() -> void:
		if is_running() and _steps[step].has("action"):
			_steps[step].action[1].call())
	top.add_child(_action)
	_back = _small_button(top, "Back", "The step before", func() -> void: _go(step - 1))
	_skip = _small_button(top, "Skip", "On to the next step, this one left undone", func() -> void: _go(step + 1))
	_end = _small_button(top, "End", "Ends the tutorial (Tutorial on the title screen starts it again)", end)

	var heavy := FontVariation.new()
	heavy.base_font = ThemeDB.fallback_font
	heavy.variation_embolden = 0.6
	_title = Label.new()
	_title.add_theme_font_override("font", heavy)
	_title.add_theme_font_size_override("font_size", 20)
	_small_title.add_theme_font_override("font", heavy)
	column.add_child(_title)
	_text = Label.new()
	_text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_text.add_theme_font_size_override("font_size", 15)
	_text.add_theme_color_override("font_color", Color(0.84, 0.86, 0.9))
	column.add_child(_text)
	_mouse_note = Label.new()
	_mouse_note.add_theme_font_size_override("font_size", 11)
	_mouse_note.add_theme_color_override("font_color", DIM)
	column.add_child(_mouse_note)


func _small_button(parent: Control, words: String, hint: String, on_pressed: Callable) -> Button:
	var button := Button.new()
	button.text = words
	button.flat = true
	button.focus_mode = Control.FOCUS_NONE  # (the keyboard stays with the room)
	Hints.give(button, hint)
	button.add_theme_font_size_override("font_size", 12)
	button.add_theme_color_override("font_color", DIM)
	button.pressed.connect(on_pressed)
	parent.add_child(button)
	return button
