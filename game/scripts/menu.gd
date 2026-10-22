extends CanvasLayer
## The menu (Esc). Its header names the room that is open, with Save (Cmd-S) and a Room menu (Save As, Save as
## Template, Show in Finder). A Metronome page for the tempo and click, a Room page for its size and walls, then the
## audio setup laid out the way a DAW does it:
## a Playback Engine page for the device and buffer size, an I/O page that maps hardware channels to what they
## carry, a MIDI page for enabling controllers, and general settings. The music keeps playing while it's open, so
## changes can be heard straight away.

const ACCENT := Color(0.49, 0.89, 0.82)
const DIM := Color(0.62, 0.65, 0.74)
const WARN := Color(1.0, 0.61, 0.48)
const MAX_GRID_CHANNELS := 16
const FloorPlan := preload("res://scripts/floor_plan.gd")
const Room := preload("res://scripts/room.gd")
const Hints := preload("res://scripts/hints.gd")
# The pages, in order.
const METRONOME_TAB := 0
const ROOM_TAB := 1
const ENGINE_TAB := 2
const IO_TAB := 3
const MIDI_TAB := 4
const SETTINGS_TAB := 5
const CONTROLS_TAB := 6
const Bindings := preload("res://scripts/bindings.gd")
const FIXED_KEYS := """Look about              the mouse (click to capture it)
Back out of anything    Esc
Walk and turn           the arrow keys, always (even while the letter keys are notes)
An amp's pedals         1 to 8, facing the amp
Notes                   A S D F G H J K L ;  white keys,  W E T Y U O P  black keys,
                        at an instrument (E) or with the keyboard open (K). Those keys
                        are notes then, and do nothing else until you get up or close it
                        (but for the panel's key, which opens it then too)."""

var app
var audio: SoundRoomAudio
# The room that is open
var _room_title: Label
var _room_status: Label
var _save: Button
var _room_menu: MenuButton
var _status_until := 0  # something just done is shown in place of when it was saved, for a few seconds

# Saving (Settings)
var _autosave_toggle: CheckButton
var _autosave_slider: HSlider
var _autosave_value: Label
var _backup_toggle: CheckButton
var _backup_slider: HSlider
var _backup_value: Label
var _kept_slider: HSlider
var _kept_value: Label

var _key_buttons := {}  # action → its button on the Controls page
var _waiting_for := ""  # the action whose new key is awaited
var _keys_note: Label

var _root: Control
var _panel: PanelContainer
var _tabs: TabContainer
var _resume: Button
var _to_title: Button
var _fast := 0.0
var _slow := 0.0

# Metronome
var _playing_toggle: CheckButton
var _tempo_slider: HSlider
var _tempo_value: Label
var _swing_slider: HSlider
var _swing_value: Label
var _click_toggle: CheckButton
var _click_slider: HSlider
var _click_value: Label

# Room
var _size_sliders := {}  # "x", "y", "z" → HSlider
var _size_values := {}
var _floor_choice: OptionButton  # what the floor is (as the microphones hear its bounce)
var _floor_note: Label
var _decay_label: Label
var _plan
var _wall_title: Label
var _wall_height: HSlider
var _wall_height_value: Label
var _wall_note: Label
var _wall_remove: Button
var _wall_add: Button
var _wall_count: Label

# Playback Engine
var _engine_option: OptionButton
var _engine_names: Array = []
var _engine_signature := ""
var _buffer_option: OptionButton
var _rate_label: Label
var _latency_label: Label
var _cpu_label: Label
var _disk_label: Label
var _engine_note: Label

# I/O
var _output_title: Label
var _output_grid: HBoxContainer
var _output_signature := ""
var _output_channels := 0
var _input_toggle: CheckButton
var _input_option: OptionButton
var _input_names: Array = []
var _input_signature := ""
var _input_channels := 0
var _live_rows: VBoxContainer  # a row of input buttons for each live-input instrument in the room
var _live_signature := ""
var _input_note: Label

# MIDI
var _midi_list: VBoxContainer
var _midi_empty: Label
var _midi_rows := {}  # device name → {dot: Label, events: int, flash: float}
var _midi_signature := ""

# Settings
var _binaural_toggle: CheckButton
var _falloff_slider: HSlider
var _falloff_value: Label
var _ceiling_slider: HSlider
var _ceiling_value: Label
var _text_slider: HSlider
var _text_value: Label
var _text_dragging := false
var _fov_slider: HSlider
var _fov_value: Label
var _mouse_slider: HSlider
var _mouse_value: Label
var _stats_toggle: CheckButton
var _meter_toggle: CheckButton
var _fullscreen_toggle: CheckButton
var _light_slider: HSlider
var _light_value: Label


func setup(the_app) -> void:
	app = the_app
	audio = app.audio
	layer = 10
	_build()
	_root.visible = false


func is_open() -> bool:
	return _root.visible


func open(tab := -1) -> void:
	if tab >= 0:
		_tabs.current_tab = clampi(tab, 0, _tabs.get_tab_count() - 1)
	_root.visible = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	app.player.release_keys()
	var on_title: bool = app.title != null and app.title.is_open()
	_resume.text = "Back  (Esc)" if on_title else "Resume  (Esc)"
	_to_title.visible = not on_title
	_engine_signature = ""  # force the device lists to rebuild
	_input_signature = ""
	_refresh_devices()
	_refresh_live()


func close() -> void:
	_root.visible = false
	if app.title == null or not app.title.is_open():  # the title screen keeps the mouse
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _input(event: InputEvent) -> void:
	if not is_open() or not (event is InputEventKey) or not event.pressed or event.echo or app.name_prompt.is_open():
		return
	if _waiting_for != "":  # the Controls page is waiting for a key
		if not (Bindings.is_command(_waiting_for) and Bindings.MODIFIERS.has(event.physical_keycode)):  # (Cmd on its way to the key)
			_take_key(event.physical_keycode)
		get_viewport().set_input_as_handled()
	elif event.physical_keycode == KEY_ESCAPE:
		close()
		get_viewport().set_input_as_handled()


func _process(delta: float) -> void:
	if not is_open():
		return
	var vp := get_viewport().get_visible_rect().size
	_panel.custom_minimum_size = Vector2(minf(800.0, vp.x - 32.0), minf(580.0, vp.y - 32.0))
	_fast += delta
	_slow += delta
	if _fast > 0.2:
		_fast = 0.0
		_refresh_live()
	if _slow > 1.0:  # listing devices asks the system, so do it less often
		_slow = 0.0
		_refresh_devices()
	for device_name in _midi_rows:
		var row: Dictionary = _midi_rows[device_name]
		row.flash = maxf(row.flash - delta, 0.0)
		row.dot.add_theme_color_override("font_color", ACCENT if row.flash > 0.0 else Color(1, 1, 1, 0.18))


# ── Building ────────────────────────────────────────────────────────────────────────────────────────────────

func _build() -> void:
	_root = Control.new()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_root)
	var shade := ColorRect.new()
	shade.color = Color(0, 0, 0, 0.55)
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
	box.add_theme_constant_override("separation", 12)
	_panel.add_child(box)

	var header := HBoxContainer.new()
	box.add_child(header)
	header.add_theme_constant_override("separation", 6)
	_room_title = Label.new()
	_room_title.add_theme_font_size_override("font_size", 22)
	header.add_child(_room_title)
	_room_status = Label.new()
	_room_status.add_theme_color_override("font_color", DIM)
	_room_status.add_theme_font_size_override("font_size", 13)
	_room_status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_room_status.clip_text = true
	header.add_child(_room_status)
	_save = Button.new()
	_save.text = "Save  (%s)" % app.bindings.label("save")
	_save.pressed.connect(func() -> void:
		app.session.save_or_ask()
		_show_status("Saved" if not app.session.has_unsaved_changes() else ""))
	header.add_child(_save)
	_room_menu = MenuButton.new()
	_room_menu.text = "Room ▾"
	_room_menu.flat = false
	_room_menu.get_popup().add_item("Save as…", 0)
	_room_menu.get_popup().add_item("Save as template…", 1)
	_room_menu.get_popup().add_separator()
	_room_menu.get_popup().add_item("Show in Finder", 2)
	_room_menu.get_popup().add_separator()
	_room_menu.get_popup().add_item("Make it a Record room", 3)
	_room_menu.get_popup().id_pressed.connect(_on_room_menu_chosen)
	header.add_child(_room_menu)
	_resume = Button.new()
	_resume.text = "Resume  (Esc)"
	_resume.pressed.connect(close)
	header.add_child(_resume)
	_to_title = Button.new()
	_to_title.text = "Title screen"
	_to_title.pressed.connect(_on_title_pressed)
	header.add_child(_to_title)
	var quit := Button.new()
	quit.text = "Quit"
	quit.pressed.connect(func() -> void: app.session.request_quit())
	header.add_child(quit)

	_tabs = TabContainer.new()
	_tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	box.add_child(_tabs)
	_build_metronome_page(_page("Metronome"))
	_build_room_page(_page("Room"))
	_build_engine_page(_page("Playback Engine"))
	_build_io_page(_page("I-O"))
	_tabs.set_tab_title(IO_TAB, "I/O")
	_build_midi_page(_page("MIDI"))
	_build_settings_page(_page("Settings"))
	_build_controls_page(_page("Controls"))


## The keys: each action with its key, which a click lets you change.
func _build_controls_page(page: VBoxContainer) -> void:
	_heading(page, "Keys")
	_note(page, "Click a key, then press the one you want instead. If another action had that key, the two swap. Esc cancels.")
	for entry in Bindings.ACTIONS:
		var button := Button.new()
		button.custom_minimum_size.x = 150
		button.focus_mode = Control.FOCUS_NONE
		button.pressed.connect(_on_key_button_pressed.bind(entry[0]))
		var row := _field(page, entry[1])
		row.get_child(0).custom_minimum_size.x = 400  # the keys in one column
		row.add_child(button)
		_key_buttons[entry[0]] = button
	_heading(page, "Shortcuts with ⌘")
	_note(page, "Held with Cmd. Click one, then press its new key (Cmd or not). If another shortcut had that key, the two swap.")
	for entry in Bindings.COMMANDS:
		var button := Button.new()
		button.custom_minimum_size.x = 150
		button.focus_mode = Control.FOCUS_NONE
		button.pressed.connect(_on_key_button_pressed.bind(entry[0]))
		var row := _field(page, entry[1])
		row.get_child(0).custom_minimum_size.x = 400
		row.add_child(button)
		_key_buttons[entry[0]] = button
	var reset := Button.new()
	reset.text = "Put every key back as it was"
	reset.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	reset.pressed.connect(func() -> void:
		app.reset_bindings()
		_keys_note.text = "Every key is back as it began."
		_show_keys())
	page.add_child(reset)
	_keys_note = _note(page, "")
	page.add_child(HSeparator.new())
	_heading(page, "Keys that don't change")
	var fixed := Label.new()
	fixed.text = FIXED_KEYS
	fixed.add_theme_font_override("font", _mono())
	fixed.add_theme_font_size_override("font_size", 13)
	page.add_child(fixed)
	_show_keys()


func _show_keys() -> void:
	_save.text = "Save  (%s)" % app.bindings.label("save")
	for action in _key_buttons:
		_key_buttons[action].text = "press a key…" if action == _waiting_for else app.bindings.label(action)


func _on_key_button_pressed(action: String) -> void:
	_waiting_for = action
	_keys_note.text = "Press the key for \"%s\", or Esc to leave it as %s." % [_action_name(action), app.bindings.label(action)]
	_show_keys()


func _take_key(keycode: int) -> void:
	var action := _waiting_for
	_waiting_for = ""
	if keycode == KEY_ESCAPE:
		_keys_note.text = ""
	elif Bindings.FIXED.has(keycode) and not Bindings.is_command(action):
		_keys_note.text = "%s is kept for %s." % [Bindings.name_of(keycode), Bindings.FIXED[keycode]]
	else:
		var swapped: String = app.set_binding(action, keycode)
		_keys_note.text = "\"%s\" is now %s." % [_action_name(action), app.bindings.label(action)]
		if swapped != "":
			_keys_note.text += " \"%s\", which had it, is now %s." % [_action_name(swapped), app.bindings.label(swapped)]
		if Bindings.NOTES.has(keycode) and not Bindings.is_command(action):
			_keys_note.text += " It is a note key too: while you play, it plays a note instead."
	_show_keys()


func _action_name(action: String) -> String:
	for entry in Bindings.ACTIONS + Bindings.COMMANDS:
		if entry[0] == action:
			return entry[1]
	return action


func _build_metronome_page(page: VBoxContainer) -> void:
	_heading(page, "Tempo")
	_playing_toggle = CheckButton.new()
	_playing_toggle.toggled.connect(_on_playing_toggled)
	_field(page, "Patterns").add_child(_playing_toggle)
	_tempo_value = Label.new()
	_tempo_slider = _slider(page, "Tempo", 40.0, 240.0, 1.0, _tempo_value)
	_tempo_slider.value_changed.connect(_on_tempo_changed)
	_swing_value = Label.new()
	_swing_slider = _slider(page, "Swing", 0.0, 60.0, 1.0, _swing_value)
	_swing_slider.value_changed.connect(_on_swing_changed)
	_note(page, "Every instrument's pattern follows this tempo. Swing makes the off-beat sixteenths late: 0 % is straight, the room starts at 14 %.")

	page.add_child(HSeparator.new())
	_heading(page, "Click")
	_click_toggle = CheckButton.new()
	_click_toggle.toggled.connect(_on_click_toggled)
	_field(page, "Metronome click").add_child(_click_toggle)
	_click_value = Label.new()
	_click_slider = _slider(page, "Click volume", -24.0, 6.0, 0.5, _click_value)
	_click_slider.value_changed.connect(_on_click_volume_changed)
	_note(page, "The click is on every beat, higher on the first beat of the bar. It plays straight into your ears rather than from somewhere in the room.")
	_note(page, "Space starts and stops the patterns and C switches the click, without opening this menu. To change what an instrument plays, walk up to it and press Tab. The tempo and the patterns go back to the defaults each time SoundRoom starts, until rooms can be saved.")


func _build_room_page(page: VBoxContainer) -> void:
	page.get_parent().size_flags_vertical = Control.SIZE_EXPAND_FILL  # so the floor plan can take the page's height
	_note(page, "The room from above, north (the way you first face) at the top. Drag on the floor to draw a wall. Drag a wall to move it, or the dot at either end to turn and stretch it.")
	var columns := HBoxContainer.new()
	columns.add_theme_constant_override("separation", 18)
	columns.size_flags_vertical = Control.SIZE_EXPAND_FILL
	page.add_child(columns)
	_plan = FloorPlan.new()
	_plan.setup(app)
	_plan.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_plan.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_plan.selection_changed.connect(_refresh_live)
	columns.add_child(_plan)
	var side := VBoxContainer.new()
	side.custom_minimum_size.x = 270
	side.add_theme_constant_override("separation", 7)
	columns.add_child(side)

	_heading(side, "Size")
	for axis in [["x", "Width", Room.MIN_SIZE.x, Room.MAX_SIZE.x, 0.5], ["z", "Length", Room.MIN_SIZE.z, Room.MAX_SIZE.z, 0.5],
			["y", "Height", Room.MIN_SIZE.y, Room.MAX_SIZE.y, 0.1]]:
		_size_values[axis[0]] = Label.new()
		_size_sliders[axis[0]] = _narrow_slider(side, axis[1], axis[2], axis[3], axis[4], _size_values[axis[0]])
		_size_sliders[axis[0]].value_changed.connect(_on_size_changed)
	_decay_label = Label.new()
	_decay_label.add_theme_color_override("font_color", DIM)
	_decay_label.add_theme_font_size_override("font_size", 13)
	_decay_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	side.add_child(_decay_label)
	_heading(side, "Floor")
	_floor_choice = OptionButton.new()
	for kind in Room.FLOOR_ORDER:
		_floor_choice.add_item(Room.FLOORS[kind][0])
	_floor_choice.item_selected.connect(func(i: int) -> void:
		app.room.set_floor(Room.FLOOR_ORDER[i])
		_refresh_live())
	side.add_child(_floor_choice)
	_floor_note = Label.new()
	_floor_note.add_theme_color_override("font_color", DIM)
	_floor_note.add_theme_font_size_override("font_size", 13)
	_floor_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	side.add_child(_floor_note)

	side.add_child(HSeparator.new())
	_heading(side, "Walls")
	_wall_title = Label.new()
	side.add_child(_wall_title)
	_wall_height_value = Label.new()
	_wall_height = _narrow_slider(side, "Height", Room.MIN_WALL_HEIGHT, Room.MAX_SIZE.y, 0.1, _wall_height_value)
	_wall_height.value_changed.connect(_on_wall_height_changed)
	_wall_note = Label.new()
	_wall_note.add_theme_color_override("font_color", DIM)
	_wall_note.add_theme_font_size_override("font_size", 13)
	_wall_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	side.add_child(_wall_note)
	var buttons := HBoxContainer.new()
	buttons.add_theme_constant_override("separation", 8)
	side.add_child(buttons)
	_wall_add = Button.new()
	_wall_add.text = "Add a wall"
	_wall_add.pressed.connect(_on_wall_add_pressed)
	buttons.add_child(_wall_add)
	_wall_remove = Button.new()
	_wall_remove.text = "Remove"
	_wall_remove.pressed.connect(_on_wall_remove_pressed)
	buttons.add_child(_wall_remove)
	_wall_count = Label.new()
	_wall_count.add_theme_color_override("font_color", DIM)
	_wall_count.add_theme_font_size_override("font_size", 13)
	buttons.add_child(_wall_count)
	var gap := Control.new()
	gap.size_flags_vertical = Control.SIZE_EXPAND_FILL
	side.add_child(gap)
	var reset := Button.new()
	reset.text = "Back to the default room"
	reset.pressed.connect(_on_room_reset_pressed)
	side.add_child(reset)


func _build_engine_page(page: VBoxContainer) -> void:
	_engine_option = OptionButton.new()
	_engine_option.custom_minimum_size.x = 380
	_engine_option.item_selected.connect(_on_engine_selected)
	_field(page, "Playback Engine").add_child(_engine_option)

	_buffer_option = OptionButton.new()
	for samples in app.settings.BUFFER_SIZES:
		_buffer_option.add_item("%d Samples" % samples)
	_buffer_option.item_selected.connect(_on_buffer_selected)
	_field(page, "H/W Buffer Size").add_child(_buffer_option)

	_rate_label = Label.new()
	_field(page, "Sample Rate").add_child(_rate_label)
	page.add_child(HSeparator.new())
	_latency_label = Label.new()
	_field(page, "Output latency").add_child(_latency_label)
	_cpu_label = Label.new()
	_field(page, "Audio CPU").add_child(_cpu_label)
	_disk_label = Label.new()
	_field(page, "Disk").add_child(_disk_label)
	_engine_note = _note(page, "")
	_note(page, "A smaller buffer responds faster but needs more CPU. If you hear crackles, pick a larger one. The sample rate follows the device.")
	_note(page, "Recorded audio is read from disk a few seconds ahead of the music and let go once it has played, so long rooms need little memory. Disk says how much is read ahead, and how many buffers the disk was too slow for, if any (heard as a gap).")


func _build_io_page(page: VBoxContainer) -> void:
	_heading(page, "Output")
	_output_title = Label.new()
	_field(page, "Device").add_child(_output_title)
	_output_grid = HBoxContainer.new()
	_output_grid.add_theme_constant_override("separation", 4)
	_field(page, "Main mix").add_child(_output_grid)
	_note(page, "Click an output to put the left side of the mix there. The right side goes to the next one.")

	page.add_child(HSeparator.new())
	_heading(page, "Input")
	_input_toggle = CheckButton.new()
	_input_toggle.text = "Off"
	_input_toggle.toggled.connect(_on_input_toggled)
	_field(page, "Speaker inputs").add_child(_input_toggle)
	_input_option = OptionButton.new()
	_input_option.custom_minimum_size.x = 380
	_input_option.item_selected.connect(_on_input_selected)
	_field(page, "Device").add_child(_input_option)
	_live_rows = VBoxContainer.new()
	_live_rows.add_theme_constant_override("separation", 12)
	page.add_child(_live_rows)
	_input_note = _note(page, "")


func _build_midi_page(page: VBoxContainer) -> void:
	_heading(page, "MIDI Input Devices")
	_note(page, "Ticked devices play whichever instrument you are playing: walk up to one and press E. At the drums each key is a drum, laid out like a General MIDI kit. A USB keyboard plugged straight into the computer shows up here under its own name. The light flashes when a device sends notes.")
	_midi_list = VBoxContainer.new()
	_midi_list.add_theme_constant_override("separation", 6)
	page.add_child(_midi_list)
	_midi_empty = _note(page, "No MIDI devices found. Plug one in and it appears here within a couple of seconds.")


func _build_settings_page(page: VBoxContainer) -> void:
	_heading(page, "Sound")
	_binaural_toggle = CheckButton.new()
	_binaural_toggle.toggled.connect(_on_binaural_toggled)
	_field(page, "Binaural (HRTF)").add_child(_binaural_toggle)
	_falloff_value = Label.new()
	_falloff_slider = _slider(page, "Distance falloff", 0.0, 6.0, 0.5, _falloff_value)
	_falloff_slider.value_changed.connect(_on_falloff_changed)
	_falloff_value.custom_minimum_size.x = 150
	_note(page, "How much quieter an instrument gets for each doubling of distance beyond 1.5 m. 6 dB is the inverse square law, as in a real room; less keeps the levels more even as you move about.")
	_ceiling_value = Label.new()
	_ceiling_slider = _slider(page, "Limiter ceiling", -12.0, 0.0, 0.1, _ceiling_value)
	_ceiling_slider.value_changed.connect(func(db: float) -> void: app.set_limiter_ceiling(db))
	_ceiling_value.custom_minimum_size.x = 150
	_note(page, "Where the limiters on both masters (LIMIT, after the master fader) hold the peaks.")

	page.add_child(HSeparator.new())
	_heading(page, "Display and controls")
	_text_value = Label.new()
	_text_slider = _slider(page, "Text size", 75.0, 200.0, 5.0, _text_value)
	# Resizing the text moves the slider under the mouse, so apply it when the drag ends.
	_text_slider.drag_started.connect(_on_text_drag_started)
	_text_slider.drag_ended.connect(_on_text_drag_ended)
	_text_slider.value_changed.connect(_on_text_changed)
	_fov_value = Label.new()
	_fov_slider = _slider(page, "Field of view", 50.0, 110.0, 1.0, _fov_value)
	_fov_slider.value_changed.connect(_on_fov_changed)
	_mouse_value = Label.new()
	_mouse_slider = _slider(page, "Mouse sensitivity", 0.2, 3.0, 0.05, _mouse_value)
	_mouse_slider.value_changed.connect(_on_mouse_changed)
	_light_value = Label.new()
	_light_slider = _slider(page, "Room lighting", 50.0, 300.0, 10.0, _light_value)
	_light_slider.value_changed.connect(_on_light_changed)
	_fullscreen_toggle = CheckButton.new()
	_fullscreen_toggle.toggled.connect(_on_fullscreen_toggled)
	_field(page, "Full screen").add_child(_fullscreen_toggle)
	_meter_toggle = CheckButton.new()
	_meter_toggle.toggled.connect(_on_meter_toggled)
	_field(page, "Master meter on screen").add_child(_meter_toggle)
	_stats_toggle = CheckButton.new()
	_stats_toggle.toggled.connect(_on_stats_toggled)
	_field(page, "Audio readout on screen").add_child(_stats_toggle)

	page.add_child(HSeparator.new())
	_heading(page, "Saving the room")
	_autosave_toggle = CheckButton.new()
	_autosave_toggle.toggled.connect(func(on: bool) -> void: _set_saving("autosave", on))
	_field(page, "Auto-save").add_child(_autosave_toggle)
	_autosave_value = Label.new()
	_autosave_slider = _slider(page, "Auto-save every", 1.0, 60.0, 1.0, _autosave_value)
	_autosave_slider.value_changed.connect(func(minutes: float) -> void: _set_saving("autosave_minutes", int(minutes)))
	_backup_toggle = CheckButton.new()
	_backup_toggle.toggled.connect(func(on: bool) -> void: _set_saving("backups", on))
	_field(page, "Backups in the room's folder").add_child(_backup_toggle)
	_backup_value = Label.new()
	_backup_slider = _slider(page, "A backup every", 1.0, 120.0, 1.0, _backup_value)
	_backup_slider.value_changed.connect(func(minutes: float) -> void: _set_saving("backup_minutes", int(minutes)))
	_kept_value = Label.new()
	_kept_slider = _slider(page, "Backups kept", 1.0, 100.0, 1.0, _kept_value)
	_kept_slider.value_changed.connect(func(count: float) -> void: _set_saving("backups_kept", int(count)))
	_note(page, "Backups go in the Room Backups folder beside the room's file, only when the room has changed, the oldest thrown away past the number kept. Each is a room you can open.")


# ── Refreshing ──────────────────────────────────────────────────────────────────────────────────────────────

## Device lists: rebuilt only when something was plugged in or removed, and never under an open dropdown.
func _refresh_devices() -> void:
	var s: Dictionary = audio.get_stats()
	var outputs: Array = audio.get_output_devices()
	var signature := _signature(outputs)
	if signature != _engine_signature and not _engine_option.get_popup().visible:
		_engine_signature = signature
		_engine_names = _fill_devices(_engine_option, outputs, "ch out")
	_select(_engine_option, _engine_names, app.settings.output_device)

	var inputs: Array = audio.get_input_devices()
	signature = _signature(inputs)
	if signature != _input_signature and not _input_option.get_popup().visible:
		_input_signature = signature
		_input_names = _fill_devices(_input_option, inputs, "ch in")
	_select(_input_option, _input_names, app.settings.input_device)

	# How many inputs the speaker can choose from: what is open, or what the chosen device says it has.
	_input_channels = int(s.get("input_channels", 0)) if app.live_input else 0
	if _input_channels == 0:
		for device in inputs:
			if device.name == app.settings.input_device or (app.settings.input_device == "" and device.is_default):
				_input_channels = device.channels


## Everything that can change from moment to moment while the menu is open.
func _refresh_live() -> void:
	var settings = app.settings
	var s: Dictionary = audio.get_stats()
	var running: bool = s.get("device_running", false)

	# Metronome
	_playing_toggle.set_pressed_no_signal(app.sequence_running)
	_playing_toggle.text = "Playing" if app.sequence_running else "Stopped"
	_tempo_slider.set_value_no_signal(app.tempo)
	_tempo_value.text = "%d BPM" % roundi(app.tempo)
	_swing_slider.set_value_no_signal(app.swing * 100.0)
	_swing_value.text = "%d %%" % roundi(app.swing * 100.0)
	_click_toggle.set_pressed_no_signal(settings.click)
	_click_toggle.text = "On" if settings.click else "Off"
	_click_slider.set_value_no_signal(settings.click_volume_db)
	_click_value.text = "%+.1f dB" % settings.click_volume_db

	# Room
	var room = app.room
	for axis in _size_sliders:
		_size_sliders[axis].set_value_no_signal(room.size[axis])
		_size_values[axis].text = "%.1f m" % room.size[axis]
	_decay_label.text = "Rings for about %.1f s. Bigger rooms ring longer but more quietly." % audio.get_room_decay()
	_floor_choice.select(Room.FLOOR_ORDER.find(room.floor_kind))
	_floor_note.text = Room.FLOORS[room.floor_kind][2]
	var chosen: int = _plan.selected
	var has_wall: bool = chosen >= 0 and chosen < room.walls.size()
	_wall_height.editable = has_wall
	_wall_remove.disabled = not has_wall
	if has_wall:
		var wall: Dictionary = room.walls[chosen]
		_wall_title.text = "Wall %d  ·  %.2f m long" % [chosen + 1, room.wall_length(wall)]
		_wall_height.max_value = room.size.y
		_wall_height.set_value_no_signal(room.wall_top(wall))
		_wall_height_value.text = "%.1f m" % room.wall_top(wall)
		_wall_note.text = "It reaches the ceiling: sound only gets round its ends." if room.wall_top(wall) >= room.size.y - 0.05 \
			else "Sound comes over the top as well as round the ends."
	else:
		_wall_title.text = "No wall selected"
		_wall_height_value.text = ""
		_wall_note.text = "Click a wall on the plan to select it."
	_wall_add.disabled = room.walls.size() >= Room.MAX_WALLS
	_wall_count.text = "%d of %d" % [room.walls.size(), Room.MAX_WALLS]

	# Playback Engine
	_buffer_option.select(settings.BUFFER_SIZES.find(settings.buffer_size))
	_rate_label.text = "%.1f kHz" % (float(s.get("sample_rate", 0)) / 1000.0) if running else "-"
	if running:
		var parts := "%.1f ms buffer + %.1f ms device" % [s.buffer_ms, s.device_ms]
		if float(s.binaural_ms) > 0.0:  # binaural rendering holds the sound back by about a quarter of a buffer
			parts += " + %.1f ms binaural" % s.binaural_ms
		_latency_label.text = "%.1f ms   (%s)" % [s.output_latency_ms, parts]
		_cpu_label.text = "%.0f %%" % (100.0 * float(s.cpu_load))
		var short := int(s.get("disk_misses", 0))
		_disk_label.text = "%.0f MB read ahead%s" % [float(s.get("disk_mb", 0.0)), "   ·   %d buffer%s short" % [short, "" if short == 1 else "s"] if short > 0 else ""]
	else:
		_latency_label.text = "-"
		_cpu_label.text = "-"
		_disk_label.text = "-"
	var note := ""
	if app.audio_error != "":
		note = "Problem: %s." % app.audio_error
	elif not running:
		note = "Audio is not running."
	elif settings.output_device != "" and s.output_device != settings.output_device:
		note = "%s is not connected, so the system default is playing until it is." % settings.output_device
	elif float(s.device_ms) > 40.0:
		note = "This device adds %.0f ms by itself, which is typical of Bluetooth. Wired headphones avoid it." % float(s.device_ms)
	_engine_note.text = note
	_engine_note.visible = note != ""
	_engine_note.add_theme_color_override("font_color", WARN)

	# I/O
	var outputs := int(s.get("output_channels", 0))
	_output_title.text = "%s   ·   %d output%s" % [s.get("output_device", "-"), outputs, "" if outputs == 1 else "s"] if running else "-"
	_output_channels = outputs
	var signature := "%d:%d:%d" % [outputs, settings.output_left, settings.output_right]
	if signature != _output_signature:
		_output_signature = signature
		_fill_grid(_output_grid, outputs, false, _output_label, _on_output_clicked)
	_input_toggle.set_pressed_no_signal(app.live_input)
	_input_toggle.text = "On (the audio input is open)" if app.live_input else "Off (the audio input is closed)"
	var live_instruments: Array = app.instruments.filter(func(inst): return inst.is_live())
	signature = str(_input_channels)
	for inst in live_instruments:
		signature += "|%s:%d" % [inst.display_name, inst.input_channel]
	if signature != _live_signature:
		_live_signature = signature
		_fill_live_rows(live_instruments)
	if app.live_input and running:
		_input_note.text = "%s is live: %.1f ms in, %.1f ms out. Wear headphones, or the microphone will pick up the speakers and feed back." % [
			s.input_device, s.input_latency_ms, s.output_latency_ms]
	else:
		_input_note.text = "Switch a Speaker's input on (I when facing it, or its I button in the mix window) to hear a microphone or instrument through it. This switch does it for every Speaker. Inputs always start switched off. Wear headphones, or it will feed back."
	_input_note.add_theme_color_override("font_color", DIM)

	# MIDI
	var devices: Array = audio.get_midi_devices()
	var midi_signature := ""
	for device in devices:
		midi_signature += "%s:%s|" % [device.name, device.enabled]
	if midi_signature != _midi_signature:
		_midi_signature = midi_signature
		_fill_midi(devices)
	for device in devices:
		var row: Dictionary = _midi_rows.get(device.name, {})
		if not row.is_empty() and int(device.events) != row.events:
			row.events = int(device.events)
			row.flash = 0.25
	_midi_empty.visible = devices.is_empty()

	# Settings
	_binaural_toggle.set_pressed_no_signal(settings.binaural)
	_binaural_toggle.text = "On" if settings.binaural else "Off (plain stereo)"
	_falloff_slider.set_value_no_signal(settings.distance_falloff_db)
	_falloff_value.text = "%.1f dB per doubling" % settings.distance_falloff_db
	_ceiling_slider.set_value_no_signal(settings.limiter_ceiling_db)
	_ceiling_value.text = "%.1f dBFS" % settings.limiter_ceiling_db
	if not _text_dragging:
		_text_slider.set_value_no_signal(settings.text_scale * 100.0)
		_text_value.text = "%d %%" % roundi(settings.text_scale * 100.0)
	_fov_slider.set_value_no_signal(settings.fov)
	_fov_value.text = "%d°" % roundi(settings.fov)
	_mouse_slider.set_value_no_signal(settings.mouse_sensitivity)
	_mouse_value.text = "%.2f ×" % settings.mouse_sensitivity
	_stats_toggle.set_pressed_no_signal(settings.show_stats)
	_stats_toggle.text = "On" if settings.show_stats else "Off"
	_autosave_toggle.set_pressed_no_signal(settings.autosave)
	_autosave_toggle.text = "On" if settings.autosave else "Off"
	_autosave_slider.set_value_no_signal(settings.autosave_minutes)
	_autosave_slider.editable = settings.autosave
	_autosave_value.text = "%d min" % settings.autosave_minutes
	_backup_toggle.set_pressed_no_signal(settings.backups)
	_backup_toggle.text = "On" if settings.backups else "Off"
	_backup_slider.set_value_no_signal(settings.backup_minutes)
	_backup_slider.editable = settings.backups
	_backup_value.text = "%d min" % settings.backup_minutes
	_kept_slider.set_value_no_signal(settings.backups_kept)
	_kept_slider.editable = settings.backups
	_kept_value.text = "the last %d" % settings.backups_kept
	_refresh_room()
	_fullscreen_toggle.set_pressed_no_signal(settings.fullscreen)
	_fullscreen_toggle.text = "On: SoundRoom opens full screen" if settings.fullscreen else "Off"
	_meter_toggle.set_pressed_no_signal(settings.show_meter)
	_meter_toggle.text = "On" if settings.show_meter else "Off"
	_light_slider.set_value_no_signal(settings.room_brightness * 100.0)
	_light_value.text = "%d %%" % roundi(settings.room_brightness * 100.0)


# ── Handlers ────────────────────────────────────────────────────────────────────────────────────────────────

## The header: the room's name, and when it was saved, or something just done.
func _refresh_room() -> void:
	var session = app.session
	_room_title.text = (session.room_name if session.room_name.length() <= 28 else session.room_name.left(27) + "…") if session.has_room() else "SoundRoom"
	_save.visible = session.has_room() or (app.title == null or not app.title.is_open())
	_room_menu.visible = _save.visible
	_room_menu.get_popup().set_item_disabled(_room_menu.get_popup().get_item_index(2), not session.has_room())
	_room_menu.get_popup().set_item_text(_room_menu.get_popup().get_item_index(3),
		"Make it a Jam room" if app.timeline.is_record() else "Make it a Record room")
	if Time.get_ticks_msec() < _status_until:
		return
	if not session.has_room():
		_room_status.text = "not saved as a room yet" if _save.visible else ""
	elif session.saved_at > 0:
		var when: Dictionary = Time.get_datetime_dict_from_unix_time(session.saved_at + _utc_offset())
		_room_status.text = "saved %02d:%02d" % [when.hour, when.minute]


func _utc_offset() -> int:
	return int(Time.get_time_zone_from_system().get("bias", 0)) * 60


func _show_status(text: String) -> void:
	if text == "":
		return
	_room_status.text = text
	_status_until = Time.get_ticks_msec() + 3000


func _on_room_menu_chosen(id: int) -> void:
	var session = app.session
	match id:
		3:  # a Jam room becomes a Record room, or the other way
			app.timeline.set_mode("jam" if app.timeline.is_record() else "record")
			_show_status("Now a %s room" % ("Record" if app.timeline.is_record() else "Jam"))
		0:
			app.name_prompt.ask("Save the room as", (session.room_name + " copy") if session.has_room() else "Untitled room",
				func(the_name: String) -> void:
					session.save_as(the_name)
					_show_status("Saved as %s" % the_name),
				func(the_name: String) -> bool: return session.exists(session.folder_around(), the_name))
		1:
			app.name_prompt.ask("Save the room as a template", session.room_name if session.has_room() else "My template",
				func(the_name: String) -> void:
					var problem: String = app.library.save_template(the_name)
					_show_status("Saved as the template %s" % the_name if problem == "" else "It couldn't be saved: %s" % problem),
				app.library.template_exists)
		2:
			session.show_folder()


func _set_saving(what: String, value) -> void:
	app.settings.set(what, value)
	app.settings.save_to_disk()
	_refresh_live()


func _on_title_pressed() -> void:
	app.show_title()


func _on_playing_toggled(on: bool) -> void:
	app.set_sequence_running(on)
	_refresh_live()


func _on_tempo_changed(bpm: float) -> void:
	app.set_tempo(bpm)
	_refresh_live()


func _on_swing_changed(percent: float) -> void:
	app.set_swing(percent / 100.0)
	_refresh_live()


func _on_click_toggled(on: bool) -> void:
	app.set_click(on)
	_refresh_live()


func _on_click_volume_changed(db: float) -> void:
	app.set_click_volume_db(db)
	_refresh_live()


func _on_light_changed(percent: float) -> void:
	app.set_room_brightness(percent / 100.0)
	_refresh_live()


func _on_fullscreen_toggled(on: bool) -> void:
	app.set_fullscreen(on)
	_refresh_live()


func _on_meter_toggled(on: bool) -> void:
	app.set_show_meter(on)
	_refresh_live()


func _on_size_changed(_value: float) -> void:
	app.room.set_size(Vector3(_size_sliders.x.value, _size_sliders.y.value, _size_sliders.z.value))
	_refresh_live()


func _on_wall_height_changed(metres: float) -> void:
	app.room.set_wall_height(_plan.selected, metres)
	_refresh_live()


func _on_wall_remove_pressed() -> void:
	app.room.remove_wall(_plan.selected)
	_plan.select(-1)
	_refresh_live()


## A wall three metres long across the middle of the room, ready to be dragged into place.
func _on_wall_add_pressed() -> void:
	var made: int = app.room.add_wall(Vector2(-1.5, 0.0), Vector2(1.5, 0.0))
	if made >= 0:
		_plan.select(made)
	_refresh_live()


func _on_room_reset_pressed() -> void:
	_plan.select(-1)
	app.room.reset()
	_refresh_live()


func _on_engine_selected(index: int) -> void:
	app.set_output_device(_engine_names[index])
	_refresh_devices()
	_refresh_live()


func _on_buffer_selected(index: int) -> void:
	app.set_buffer_size(app.settings.BUFFER_SIZES[index])
	_refresh_live()


func _on_input_toggled(on: bool) -> void:
	app.set_live_input(on)
	_refresh_devices()
	_refresh_live()


func _on_input_selected(index: int) -> void:
	app.set_input_device(_input_names[index])
	_refresh_devices()
	_refresh_live()


func _output_label(channel: int) -> String:
	var settings = app.settings
	if channel == settings.output_left and channel == settings.output_right:
		return "L+R"
	if channel == settings.output_left:
		return "L"
	if channel == settings.output_right:
		return "R"
	return ""


func _on_output_clicked(channel: int) -> void:
	app.set_output_channels(channel, mini(channel + 1, _output_channels - 1))
	_refresh_live()


## One row for each live-input instrument: which hardware input it plays.
func _fill_live_rows(live_instruments: Array) -> void:
	for child in _live_rows.get_children():
		child.queue_free()
	for inst in live_instruments:
		var grid := HBoxContainer.new()
		grid.add_theme_constant_override("separation", 4)
		_field(_live_rows, "%s plays input" % inst.display_name).add_child(grid)
		_fill_grid(grid, _input_channels, true, _live_label.bind(inst), _on_live_clicked.bind(inst))
	if live_instruments.is_empty():
		_note(_live_rows, "There is no Speaker in the room to play an input. Add one from the instrument menu (%s)." % app.bindings.label("add"))


func _live_label(channel: int, inst) -> String:
	return "●" if channel == inst.input_channel else ""


func _on_live_clicked(channel: int, inst) -> void:
	app.set_input_channel(inst, channel)
	_refresh_live()


func _on_midi_toggled(on: bool, device_name: String) -> void:
	app.set_midi_device_enabled(device_name, on)
	_refresh_live()


func _on_binaural_toggled(on: bool) -> void:
	app.set_binaural(on)
	_refresh_live()


func _on_falloff_changed(db: float) -> void:
	app.set_distance_falloff(db)


func _on_text_drag_started() -> void:
	_text_dragging = true


func _on_text_drag_ended(_changed: bool) -> void:
	_text_dragging = false
	app.set_text_scale(_text_slider.value / 100.0)


func _on_text_changed(percent: float) -> void:
	_text_value.text = "%d %%" % roundi(percent)
	if not _text_dragging:
		app.set_text_scale(percent / 100.0)


func _on_fov_changed(degrees: float) -> void:
	app.set_fov(degrees)
	_refresh_live()


func _on_mouse_changed(multiplier: float) -> void:
	app.set_mouse_sensitivity(multiplier)
	_refresh_live()


func _on_stats_toggled(on: bool) -> void:
	app.set_show_stats(on)
	_refresh_live()


func _signature(devices: Array) -> String:
	var out := ""
	for device in devices:
		out += "%s:%d:%s|" % [device.name, device.channels, device.is_default]
	return out


## Fills a device dropdown: "System default (name)" first, then every device. Returns the name behind each row
## ("" for the system default).
func _fill_devices(option: OptionButton, devices: Array, unit: String) -> Array:
	option.clear()
	var names := [""]
	var default_name := "none"
	for device in devices:
		if device.is_default:
			default_name = device.name
	option.add_item("System default  (%s)" % default_name)
	for device in devices:
		option.add_item("%s   ·   %d %s" % [device.name, device.channels, unit])
		names.append(device.name)
	return names


func _select(option: OptionButton, names: Array, wanted: String) -> void:
	var index := names.find(wanted)
	if index < 0:  # the saved device isn't connected: show it anyway so the choice isn't silently lost
		option.add_item("%s   ·   not connected" % wanted)
		names.append(wanted)
		index = names.size() - 1
	option.select(index)


## A row of channel buttons, as in a DAW's I/O grid. `label_for` returns what an assigned channel shows ("" if
## it isn't assigned); `on_click` receives the channel that was clicked. With `with_all`, a first button stands
## for every channel at once (channel -1).
func _fill_grid(grid: HBoxContainer, channels: int, with_all: bool, label_for: Callable, on_click: Callable) -> void:
	for child in grid.get_children():
		child.queue_free()
	var first := -1 if with_all else 0
	for ch in range(first, mini(channels, MAX_GRID_CHANNELS)):
		var button := Button.new()
		var assigned: String = label_for.call(ch)
		button.custom_minimum_size = Vector2(56 if ch < 0 else 44, 32)
		var number := "All" if ch < 0 else str(ch + 1)
		button.text = number if assigned == "" else "%s %s" % [number, assigned]
		for state in ["normal", "hover", "pressed", "focus"]:
			button.add_theme_stylebox_override(state, _cell_style(assigned != "", state == "hover"))
		for colour in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color"]:
			button.add_theme_color_override(colour, Color(0.03, 0.12, 0.1) if assigned != "" else DIM)
		button.pressed.connect(on_click.bind(ch))
		grid.add_child(button)
	if channels == 0:
		var none := Label.new()
		none.text = "no channels"
		none.add_theme_color_override("font_color", DIM)
		grid.add_child(none)


func _fill_midi(devices: Array) -> void:
	for child in _midi_list.get_children():
		child.queue_free()
	var previous := _midi_rows
	_midi_rows = {}
	for device in devices:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 10)
		var dot := Label.new()
		dot.text = "●"
		row.add_child(dot)
		var check := CheckBox.new()
		check.text = device.name
		check.button_pressed = device.enabled
		check.toggled.connect(_on_midi_toggled.bind(device.name))
		row.add_child(check)
		_midi_list.add_child(row)
		var before: Dictionary = previous.get(device.name, {})
		_midi_rows[device.name] = {"dot": dot, "events": before.get("events", int(device.events)), "flash": 0.0}


# ── Small layout helpers ────────────────────────────────────────────────────────────────────────────────────

func _page(title: String) -> VBoxContainer:
	var scroll := ScrollContainer.new()
	scroll.name = title
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	var margin := MarginContainer.new()
	margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 16)
	var page := VBoxContainer.new()
	page.add_theme_constant_override("separation", 12)
	scroll.add_child(margin)
	margin.add_child(page)
	_tabs.add_child(scroll)
	return page


func _field(page: Control, title: String) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 14)
	var label := Label.new()
	label.text = title
	label.custom_minimum_size.x = 190
	label.add_theme_color_override("font_color", DIM)
	row.add_child(label)
	page.add_child(row)
	return row


func _heading(page: Control, title: String) -> void:
	var label := Label.new()
	label.text = Hints.keys(title)
	label.add_theme_font_size_override("font_size", 17)
	page.add_child(label)


func _note(page: Control, text: String) -> Label:
	var label := Label.new()
	label.text = Hints.keys(text)
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.add_theme_color_override("font_color", DIM)
	label.add_theme_font_size_override("font_size", 13)
	page.add_child(label)
	return label


func _slider(page: VBoxContainer, title: String, low: float, high: float, step: float, value_label: Label) -> HSlider:
	var slider := HSlider.new()
	slider.min_value = low
	slider.max_value = high
	slider.step = step
	slider.custom_minimum_size.x = 300
	slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var row := _field(page, title)
	row.add_child(slider)
	value_label.custom_minimum_size.x = 80
	row.add_child(value_label)
	return slider


## A slider for a narrow column: a short label, the slider, and its value.
func _narrow_slider(parent: Control, title: String, low: float, high: float, step: float, value_label: Label) -> HSlider:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	var label := Label.new()
	label.text = title
	label.custom_minimum_size.x = 58
	label.add_theme_color_override("font_color", DIM)
	row.add_child(label)
	var slider := HSlider.new()
	slider.min_value = low
	slider.max_value = high
	slider.step = step
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(slider)
	value_label.custom_minimum_size.x = 56
	value_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	row.add_child(value_label)
	parent.add_child(row)
	return slider


func _cell_style(assigned: bool, hover: bool) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = ACCENT if assigned else Color(1, 1, 1, 0.1 if hover else 0.04)
	style.set_border_width_all(1)
	style.border_color = ACCENT if assigned else Color(1, 1, 1, 0.22)
	style.set_corner_radius_all(5)
	style.set_content_margin_all(4)
	return style


func _mono() -> Font:
	var font := SystemFont.new()
	font.font_names = PackedStringArray(["Menlo", "SF Mono", "Consolas", "monospace"])
	return font
