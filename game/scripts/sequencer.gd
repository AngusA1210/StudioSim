extends CanvasLayer
## The pattern editor (Enter at an instrument): a step grid for the loop that instrument plays, one bar at a time,
## with the tempo and the metronome click along the top. The music keeps playing while it's open, so every change
## is heard on the next time round. While it's open, a MIDI controller plays the instrument being edited.

const PatternGrid := preload("res://scripts/pattern_grid.gd")

const DIM := Color(0.62, 0.65, 0.74)
const NOTE_NAMES := ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
const NOTE_LENGTHS := [[1.0, "1/16"], [2.0, "1/8"], [4.0, "1/4"], [8.0, "1/2"], [16.0, "1 bar"]]
const BAR_CHOICES := [1, 2, 4]
# How hard a note is hit. Right-click steps through these, then "now and then", then back to loud.
const LOUDNESS := [[1.0, "loud"], [0.8, "medium"], [0.5, "soft"]]
const SOMETIMES_VELOCITY := 0.3
const SOMETIMES_CHANCE := 0.25
# The lowest and highest row shown for each kind of instrument. Notes outside it widen the range.
const RANGES := {"bass": [28, 64], "pad": [43, 79], "bells": [60, 96], "keys": [36, 84]}
const DEFAULT_LENGTH := {"drums": 1.0, "garage_drums": 1.0, "studio_drums": 1.0, "bass": 2.0, "pad": 16.0, "bells": 1.0, "keys": 2.0, "plugin_synth": 2.0}
# A drum kit's rows, top to bottom, by its pieces' places in the audio core's list (Kick, Snare, Closed hat, Open hat,
# Low tom, High tom, Clap or Ride, Crash): the cymbals on top, the kick at the foot.
const DRUM_ORDER := [7, 3, 2, 6, 5, 4, 1, 0]
const DRUM_ROW := 44.0
const NOTE_ROW := 20.0
const HELP := "Click a square to add a note, click a note to remove it. Right-click a note to change how hard it is hit. Click a name on the left to hear it."

var app
var audio: SoundRoomAudio
var inst = null  # the instrument whose pattern is open
var bar := 0

var _notes: Array = []
var _steps := 64
var _note_length := 1.0
var _sat_down := false  # opening the editor sat the player down at the instrument, so closing stands them up
var _back_to_mixer := false  # opened from the mix window, which comes back when this closes
var _center_in := 0     # frames until the grid scrolls to the notes (it has to be laid out first)

var _root: Control
var _panel: PanelContainer
var _title: Label
var _play: Button
var _tempo: SpinBox
var _click: CheckButton
var _beat: Label
var _loop: CheckButton
var _length: OptionButton
var _bars: Array = []
var _note_length_box: HBoxContainer
var _note_length_option: OptionButton
var _scroll: ScrollContainer
var _grid
var _status: Label


func setup(the_app) -> void:
	app = the_app
	audio = app.audio
	layer = 9
	_build()
	_root.visible = false


func is_open() -> bool:
	return _root.visible


## Opens the editor on an instrument's pattern, at the bar that is playing (or `at_bar`, counted from 0).
func open(instrument, at_bar := -1, from_mixer := false) -> void:
	if instrument == null or not instrument.playable:
		return
	_back_to_mixer = from_mixer
	inst = instrument
	app.player.release_keys()
	_sat_down = app.player.playing != inst
	app.player.start_playing(inst)
	_note_length = DEFAULT_LENGTH.get(inst.kind, 1.0)
	_reload()
	_grid.show_rows(_rows(), DRUM_ROW if inst.drum_kit else NOTE_ROW)
	var step := int(audio.get_transport().get("step", -1))
	bar = at_bar if at_bar >= 0 else (maxi(step, 0) % _steps) / PatternGrid.COLUMNS
	_root.visible = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_status.text = HELP
	_refresh()
	_center_in = 2


func close() -> void:
	_root.visible = false
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	if _sat_down:
		app.player.stop_playing()
	if _back_to_mixer:
		_back_to_mixer = false
		app.mixer.open()


func _input(event: InputEvent) -> void:
	if not is_open() or not (event is InputEventKey) or not event.pressed or event.echo:
		return
	var action: String = "escape" if event.physical_keycode == KEY_ESCAPE else app.bindings.action_for(event.physical_keycode)
	match action:
		"escape":
			close()
			get_viewport().set_input_as_handled()
		"edit":
			if not (get_viewport().gui_get_focus_owner() is LineEdit):  # Enter in the tempo box sets the tempo
				close()
				get_viewport().set_input_as_handled()
		"mixer":  # straight over to the mix window
			close()
			app.mixer.open()
			get_viewport().set_input_as_handled()
		"transport":
			if not (get_viewport().gui_get_focus_owner() is LineEdit):
				app.set_sequence_running(not app.sequence_running)
				get_viewport().set_input_as_handled()


func _process(_delta: float) -> void:
	if not is_open():
		return
	var vp := get_viewport().get_visible_rect().size
	_panel.custom_minimum_size = Vector2(minf(920.0, vp.x - 32.0), minf(680.0, vp.y - 32.0))
	if _center_in > 0:
		_center_in -= 1
		if _center_in == 0:
			_center_on_notes()

	var step := int(audio.get_transport().get("step", -1))
	var local := step % _steps if step >= 0 else -1
	var playing_bar := local / PatternGrid.COLUMNS if local >= 0 else -1
	_grid.set_playhead(local % PatternGrid.COLUMNS if playing_bar == bar else -1)
	for i in _bars.size():
		_bars[i].text = "%d ◂" % (i + 1) if i == playing_bar else str(i + 1)
	var beat := (step / 4) % 4 if step >= 0 else -1
	var dots := ""
	for i in 4:
		dots += "● " if i == beat else "○ "
	_beat.text = dots
	_play.text = "■  Stop" if app.sequence_running else "▶  Play"
	if not _tempo.get_line_edit().has_focus():
		_tempo.set_value_no_signal(app.tempo)
	_click.set_pressed_no_signal(app.settings.click)
	_loop.set_pressed_no_signal(inst.loop_on)
	_loop.text = "Loop on" if inst.loop_on else "Loop off"


# ── Building ────────────────────────────────────────────────────────────────────────────────────────────────

func _build() -> void:
	_root = Control.new()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_root)
	var shade := ColorRect.new()
	shade.color = Color(0, 0, 0, 0.45)
	shade.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.add_child(shade)
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.add_child(center)

	_panel = PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.07, 0.08, 0.11, 0.97)
	style.set_corner_radius_all(14)
	style.set_border_width_all(1)
	style.border_color = Color(1, 1, 1, 0.14)
	style.set_content_margin_all(18)
	_panel.add_theme_stylebox_override("panel", style)
	center.add_child(_panel)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 10)
	_panel.add_child(box)

	var header := HBoxContainer.new()
	box.add_child(header)
	_title = Label.new()
	_title.add_theme_font_size_override("font_size", 22)
	header.add_child(_title)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(spacer)
	var close_button := Button.new()
	close_button.text = "Close  (Enter)"
	close_button.pressed.connect(close)
	header.add_child(close_button)

	# The clock everything follows.
	var transport := _row(box)
	_play = Button.new()
	_play.custom_minimum_size.x = 92
	_play.tooltip_text = "Start or stop every instrument's pattern (Space)"
	_play.pressed.connect(_on_play_pressed)
	transport.add_child(_play)
	_tempo = SpinBox.new()
	_tempo.min_value = 40
	_tempo.max_value = 240
	_tempo.step = 1
	_tempo.suffix = "BPM"
	_tempo.custom_minimum_size.x = 120
	_tempo.value_changed.connect(_on_tempo_changed)
	_tempo.get_line_edit().text_submitted.connect(_on_tempo_typed)
	_labelled(transport, "Tempo", _tempo)
	_click = CheckButton.new()
	_click.text = "Metronome click"
	_click.toggled.connect(_on_click_toggled)
	transport.add_child(_click)
	_beat = Label.new()
	_beat.add_theme_color_override("font_color", DIM)
	transport.add_child(_beat)

	# This instrument's pattern.
	var pattern := _row(box)
	_loop = CheckButton.new()
	_loop.tooltip_text = "Whether this instrument plays its pattern. With the loop off you can still play it by hand (M)."
	_loop.toggled.connect(_on_loop_toggled)
	pattern.add_child(_loop)
	_length = OptionButton.new()
	for bars in BAR_CHOICES:
		_length.add_item("1 bar" if bars == 1 else "%d bars" % bars)
	_length.item_selected.connect(_on_length_selected)
	_labelled(pattern, "Repeats every", _length)
	var bar_box := HBoxContainer.new()
	bar_box.add_theme_constant_override("separation", 4)
	for i in 4:
		var button := Button.new()
		button.toggle_mode = true
		button.custom_minimum_size.x = 44
		button.pressed.connect(_on_bar_pressed.bind(i))
		bar_box.add_child(button)
		_bars.append(button)
	_labelled(pattern, "Bar", bar_box)
	_note_length_option = OptionButton.new()
	for choice in NOTE_LENGTHS:
		_note_length_option.add_item(choice[1])
	_note_length_option.item_selected.connect(_on_note_length_selected)
	_note_length_box = _labelled(pattern, "New notes last", _note_length_option)

	_scroll = ScrollContainer.new()
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	box.add_child(_scroll)
	_grid = PatternGrid.new()
	_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_grid.cell_pressed.connect(_on_cell_pressed)
	_grid.cell_hovered.connect(_on_cell_hovered)
	_grid.label_pressed.connect(_on_label_pressed)
	_scroll.add_child(_grid)

	_status = Label.new()
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.add_theme_color_override("font_color", DIM)
	_status.add_theme_font_size_override("font_size", 13)
	_status.custom_minimum_size.y = 36
	box.add_child(_status)

	var footer := _row(box)
	_button(footer, "Clear this bar", _on_clear_bar)
	_button(footer, "Clear the whole pattern", _on_clear_all)
	_button(footer, "Back to the default pattern", _on_reset)


func _row(parent: Control) -> HFlowContainer:
	var row := HFlowContainer.new()
	row.add_theme_constant_override("h_separation", 18)
	row.add_theme_constant_override("v_separation", 8)
	parent.add_child(row)
	return row


func _labelled(parent: Control, title: String, control: Control) -> HBoxContainer:
	var pair := HBoxContainer.new()
	pair.add_theme_constant_override("separation", 8)
	var label := Label.new()
	label.text = title
	label.add_theme_color_override("font_color", DIM)
	pair.add_child(label)
	pair.add_child(control)
	parent.add_child(pair)
	return pair


func _button(parent: Control, title: String, on_pressed: Callable) -> void:
	var button := Button.new()
	button.text = title
	button.pressed.connect(on_pressed)
	parent.add_child(button)


# ── The pattern ─────────────────────────────────────────────────────────────────────────────────────────────

func _reload() -> void:
	_notes = audio.get_pattern(inst.source_id)
	_steps = maxi(audio.get_pattern_steps(inst.source_id), PatternGrid.COLUMNS)


## Everything on screen that follows the pattern and the bar being shown.
func _refresh() -> void:
	var bars := _steps / PatternGrid.COLUMNS
	bar = clampi(bar, 0, bars - 1)
	_title.text = "%s pattern" % inst.display_name
	_title.add_theme_color_override("font_color", inst.color.lightened(0.3))
	_length.select(maxi(BAR_CHOICES.find(bars), 0))
	for i in _bars.size():
		_bars[i].disabled = i >= bars
		_bars[i].set_pressed_no_signal(i == bar)
	# The drums and bells ring for as long as they ring, whatever a note's length says.
	_note_length_box.visible = not inst.drum_kit and inst.kind != "bells"
	for i in NOTE_LENGTHS.size():
		if is_equal_approx(NOTE_LENGTHS[i][0], _note_length):
			_note_length_option.select(i)
	_grid.notes = _notes
	_grid.steps = _steps
	_grid.bar = bar
	_grid.color = inst.color
	_grid.queue_redraw()


func _rows() -> Array:
	var rows := []
	if inst.drum_kit:
		var pieces: Array = audio.get_drum_pieces(inst.kind)
		for index in DRUM_ORDER:
			rows.append({"note": pieces[index].note, "label": pieces[index].name, "dark": false})
		return rows
	var span: Array = RANGES.get(inst.kind, [36, 84])
	var low: int = span[0]
	var high: int = span[1]
	for n in _notes:
		low = mini(low, int(n.note))
		high = maxi(high, int(n.note))
	for note in range(high, low - 1, -1):
		rows.append({"note": note, "label": _note_name(note), "dark": NOTE_NAMES[note % 12].ends_with("#")})
	return rows


func _center_on_notes() -> void:
	if _notes.is_empty() or inst.drum_kit:
		_scroll.scroll_vertical = int(maxf(_grid.size.y - _scroll.size.y, 0.0) / 2.0)
		return
	var highest := 0
	var lowest := 127
	for n in _notes:
		highest = maxi(highest, int(n.note))
		lowest = mini(lowest, int(n.note))
	var middle: float = (_grid.row_top(highest) + _grid.row_top(lowest) + _grid.row_height) / 2.0
	_scroll.scroll_vertical = int(maxf(middle - _scroll.size.y / 2.0, 0.0))


## The note in this row that is sounding at `step`, or an empty dictionary.
func _note_at(step: int, note: int) -> Dictionary:
	for n in _notes:
		if int(n.note) == note and step >= int(n.step) and float(step) < float(n.step) + maxf(float(n.length), 1.0):
			return n
	return {}


func _note_name(note: int) -> String:
	return "%s%d" % [NOTE_NAMES[note % 12], note / 12 - 1]


func _row_name(note: int) -> String:
	return audio.get_drum_piece_name(note, inst.kind) if inst.drum_kit else _note_name(note)


func _loudness_index(velocity: float) -> int:
	var best := 0
	for i in LOUDNESS.size():
		if absf(LOUDNESS[i][0] - velocity) < absf(LOUDNESS[best][0] - velocity):
			best = i
	return best


func _describe(n: Dictionary) -> String:
	var text := "%s  ·  bar %d, step %d  ·  " % [_row_name(int(n.note)), int(n.step) / PatternGrid.COLUMNS + 1, int(n.step) % PatternGrid.COLUMNS + 1]
	if float(n.chance) < 1.0:
		text += "soft, and only now and then (one time in four)"
	else:
		text += LOUDNESS[_loudness_index(float(n.velocity))][1]
	if _note_length_box.visible:
		var length := "%s sixteenths" % String.num(float(n.length), 1).trim_suffix(".0")
		for choice in NOTE_LENGTHS:
			if is_equal_approx(choice[0], float(n.length)):
				length = choice[1]
		text += "  ·  lasts %s" % length
	return text


func _audition(note: int, velocity: float) -> void:
	audio.note_on(inst.source_id, note, velocity)
	get_tree().create_timer(0.35).timeout.connect(audio.note_off.bind(inst.source_id, note))


# ── Handlers ────────────────────────────────────────────────────────────────────────────────────────────────

func _on_cell_pressed(column: int, note: int, button: int) -> void:
	var step := bar * PatternGrid.COLUMNS + column
	if step >= _steps:
		return
	var existing := _note_at(step, note)
	if button == MOUSE_BUTTON_LEFT and existing.is_empty():
		if not audio.set_pattern_note(inst.source_id, step, note, _note_length, LOUDNESS[1][0], 1.0):
			_status.text = "This pattern is full."
			return
		_audition(note, LOUDNESS[1][0])
		_reload()
		_status.text = "Added  " + _describe(_note_at(step, note))
	elif button == MOUSE_BUTTON_LEFT:
		audio.remove_pattern_note(inst.source_id, int(existing.step), note)
		_status.text = "Removed  %s  ·  bar %d, step %d" % [_row_name(note), int(existing.step) / PatternGrid.COLUMNS + 1,
			int(existing.step) % PatternGrid.COLUMNS + 1]
		_reload()
	elif not existing.is_empty():  # right-click: the next loudness
		var velocity: float = LOUDNESS[0][0]
		var chance := 1.0
		if float(existing.chance) >= 1.0:
			var index := _loudness_index(float(existing.velocity))
			if index + 1 < LOUDNESS.size():
				velocity = LOUDNESS[index + 1][0]
			else:
				velocity = SOMETIMES_VELOCITY
				chance = SOMETIMES_CHANCE
		audio.set_pattern_note(inst.source_id, int(existing.step), note, float(existing.length), velocity, chance)
		_audition(note, velocity)
		_reload()
		_status.text = _describe(_note_at(step, note))
	_refresh()


func _on_cell_hovered(column: int, note: int) -> void:
	if note < 0 or column < 0:
		return
	var existing := _note_at(bar * PatternGrid.COLUMNS + column, note)
	if not existing.is_empty():
		_status.text = _describe(existing)
	else:
		_status.text = "%s  ·  bar %d, step %d" % [_row_name(note), bar + 1, column + 1]


func _on_label_pressed(note: int) -> void:
	_audition(note, LOUDNESS[1][0])
	_status.text = _row_name(note)


func _on_play_pressed() -> void:
	app.set_sequence_running(not app.sequence_running)


func _on_tempo_changed(bpm: float) -> void:
	app.set_tempo(bpm)


## Enter in the tempo box: hand the keyboard back, so Space starts and stops the patterns again.
func _on_tempo_typed(_text: String) -> void:
	_tempo.get_line_edit().release_focus()


func _on_click_toggled(on: bool) -> void:
	app.set_click(on)


func _on_loop_toggled(on: bool) -> void:
	inst.set_loop(on)


func _on_length_selected(index: int) -> void:
	audio.set_pattern_steps(inst.source_id, BAR_CHOICES[index] * PatternGrid.COLUMNS)
	_reload()
	_refresh()


func _on_bar_pressed(index: int) -> void:
	bar = index
	_refresh()


func _on_note_length_selected(index: int) -> void:
	_note_length = NOTE_LENGTHS[index][0]


func _on_clear_bar() -> void:
	var first := bar * PatternGrid.COLUMNS
	for n in _notes:
		if int(n.step) >= first and int(n.step) < first + PatternGrid.COLUMNS:
			audio.remove_pattern_note(inst.source_id, int(n.step), int(n.note))
	_reload()
	_status.text = "Cleared bar %d." % (bar + 1)
	_refresh()


func _on_clear_all() -> void:
	audio.set_pattern(inst.source_id, [])
	_reload()
	_status.text = "Cleared the whole pattern."
	_refresh()


func _on_reset() -> void:
	audio.load_default_pattern(inst.source_id)
	_reload()
	_grid.show_rows(_rows(), DRUM_ROW if inst.drum_kit else NOTE_ROW)
	_status.text = "Back to the default pattern." if not _notes.is_empty() else "The %s have no default pattern, so it is empty." % inst.display_name
	_refresh()
	_center_in = 2
