extends CanvasLayer
## The menu (Esc). A Metronome page for the tempo and click, a Mixer page with a fader for every instrument and the
## master meter, a Room page for its size and walls, then the audio setup laid out the way a DAW does it:
## a Playback Engine page for the device and buffer size, an I/O page that maps hardware channels to what they
## carry, a MIDI page for enabling controllers, and general settings. The music keeps playing while it's open, so
## changes can be heard straight away.

const ACCENT := Color(0.49, 0.89, 0.82)
const DIM := Color(0.62, 0.65, 0.74)
const WARN := Color(1.0, 0.61, 0.48)
const MAX_GRID_CHANNELS := 16
const FloorPlan := preload("res://scripts/floor_plan.gd")
const LevelMeter := preload("res://scripts/level_meter.gd")
const Room := preload("res://scripts/room.gd")
# The pages, in order.
const METRONOME_TAB := 0
const MIXER_TAB := 1
const ROOM_TAB := 2
const ENGINE_TAB := 3
const IO_TAB := 4
const MIDI_TAB := 5
const SETTINGS_TAB := 6
const CONTROLS_TAB := 7
const OUTPUT_TRIM := 0.88  # roughly what the engine multiplies an instrument by on its way out, for the strip meters
const CONTROLS := """Move                    W A S D   (Shift to run)
Look                    mouse   (click to capture it)
Carry an instrument     G or click, again to put it down
Add an instrument       N
Remove an instrument    Backspace twice, facing or carrying it
Levels and the meter    Esc, then the Mixer page
Room size and walls     Esc, then the Room page
Play an instrument      E when next to it, Q to stop
                        A S D F G H J K L ;  white keys
                        W E T Y U O P  black keys,  Z X  octave
MIDI keyboard           plays the instrument you are playing
Edit its pattern        Tab when next to it or playing it
Its loop on / off       M   (for a Speaker: mute)
A Speaker's input       Tab when facing it
Start / stop patterns   Space
Metronome click         C
Binaural on / off       B
Reverb on / off         R
Live input on / off     I
Menu                    Esc"""

var app
var audio: SoundRoomAudio

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

# Mixer
var _master_meter
var _master_readout: Label
var _master_state: Label
var _limiter_toggle: CheckButton
var _falloff_slider: HSlider
var _falloff_value: Label
var _falloff_note: Label
var _strips: VBoxContainer
var _strip_rows: Array = []  # {inst, slider, value, meter}
var _strip_signature := ""

# Room
var _size_sliders := {}  # "x", "y", "z" → HSlider
var _size_values := {}
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
var _volume_slider: HSlider
var _volume_value: Label
var _binaural_toggle: CheckButton
var _reverb_toggle: CheckButton
var _text_slider: HSlider
var _text_value: Label
var _text_dragging := false
var _fov_slider: HSlider
var _fov_value: Label
var _mouse_slider: HSlider
var _mouse_value: Label
var _stats_toggle: CheckButton
var _meter_toggle: CheckButton
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
	if is_open() and event is InputEventKey and event.pressed and not event.echo and event.physical_keycode == KEY_ESCAPE:
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
	if _tabs.current_tab == MIXER_TAB:
		_refresh_meters()


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
	var title := Label.new()
	title.text = "SoundRoom"
	title.add_theme_font_size_override("font_size", 22)
	header.add_child(title)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(spacer)
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
	quit.pressed.connect(func(): get_tree().quit())
	header.add_child(quit)

	_tabs = TabContainer.new()
	_tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	box.add_child(_tabs)
	_build_metronome_page(_page("Metronome"))
	_build_mixer_page(_page("Mixer"))
	_build_room_page(_page("Room"))
	_build_engine_page(_page("Playback Engine"))
	_build_io_page(_page("I-O"))
	_tabs.set_tab_title(IO_TAB, "I/O")
	_build_midi_page(_page("MIDI"))
	_build_settings_page(_page("Settings"))
	var controls := Label.new()
	controls.text = CONTROLS
	controls.add_theme_font_override("font", _mono())
	controls.add_theme_font_size_override("font_size", 14)
	_page("Controls").add_child(controls)


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


func _build_mixer_page(page: VBoxContainer) -> void:
	page.get_parent().size_flags_vertical = Control.SIZE_EXPAND_FILL  # so the list of instruments can take the height
	var columns := HBoxContainer.new()
	columns.add_theme_constant_override("separation", 20)
	columns.size_flags_vertical = Control.SIZE_EXPAND_FILL
	page.add_child(columns)

	# The master section: what leaves for your ears.
	var master := VBoxContainer.new()
	master.custom_minimum_size.x = 290
	master.add_theme_constant_override("separation", 7)
	columns.add_child(master)
	_heading(master, "Master")
	_master_meter = LevelMeter.new()
	_master_meter.custom_minimum_size = Vector2(280, 26)
	master.add_child(_master_meter)
	_master_readout = Label.new()
	_master_readout.add_theme_font_size_override("font_size", 13)
	_master_readout.add_theme_color_override("font_color", DIM)
	master.add_child(_master_readout)
	_master_state = Label.new()
	_master_state.add_theme_font_size_override("font_size", 13)
	_master_state.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	master.add_child(_master_state)
	_volume_value = Label.new()
	_volume_slider = _narrow_slider(master, "Volume", -40.0, 12.0, 0.5, _volume_value)
	_volume_slider.value_changed.connect(_on_volume_changed)
	_limiter_toggle = CheckButton.new()
	_limiter_toggle.toggled.connect(_on_limiter_toggled)
	master.add_child(_limiter_toggle)
	master.add_child(HSeparator.new())
	_heading(master, "Distance")
	_falloff_value = Label.new()
	_falloff_slider = _narrow_slider(master, "Falloff", 0.0, 6.0, 0.5, _falloff_value)
	_falloff_slider.value_changed.connect(_on_falloff_changed)
	_falloff_note = Label.new()
	_falloff_note.add_theme_font_size_override("font_size", 13)
	_falloff_note.add_theme_color_override("font_color", DIM)
	_falloff_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	master.add_child(_falloff_note)

	# A fader for everything in the room.
	var right := VBoxContainer.new()
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right.add_theme_constant_override("separation", 7)
	columns.add_child(right)
	var top := HBoxContainer.new()
	right.add_child(top)
	var title := Label.new()
	title.text = "Instruments"
	title.add_theme_font_size_override("font_size", 17)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top.add_child(title)
	var reset := Button.new()
	reset.text = "All to 0 dB"
	reset.pressed.connect(_on_levels_reset_pressed)
	top.add_child(reset)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	right.add_child(scroll)
	_strips = VBoxContainer.new()
	_strips.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_strips.add_theme_constant_override("separation", 6)
	scroll.add_child(_strips)
	var hint := Label.new()
	hint.text = "0 dB is the level an instrument was made at. The small meter shows it as heard from right beside it."
	hint.add_theme_font_size_override("font_size", 12)
	hint.add_theme_color_override("font_color", DIM)
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	right.add_child(hint)


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
	var unsaved := Label.new()
	unsaved.text = "Resets when SoundRoom restarts."
	unsaved.add_theme_color_override("font_color", DIM)
	unsaved.add_theme_font_size_override("font_size", 12)
	unsaved.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	side.add_child(unsaved)


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
	_engine_note = _note(page, "")
	_note(page, "A smaller buffer responds faster but needs more CPU. If you hear crackles, pick a larger one. The sample rate follows the device.")


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
	_field(page, "Live input").add_child(_input_toggle)
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
	_reverb_toggle = CheckButton.new()
	_reverb_toggle.toggled.connect(_on_reverb_toggled)
	_field(page, "Room reverb").add_child(_reverb_toggle)

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
	_meter_toggle = CheckButton.new()
	_meter_toggle.toggled.connect(_on_meter_toggled)
	_field(page, "Master meter on screen").add_child(_meter_toggle)
	_stats_toggle = CheckButton.new()
	_stats_toggle.toggled.connect(_on_stats_toggled)
	_field(page, "Audio readout on screen").add_child(_stats_toggle)


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

	# Mixer
	_volume_slider.set_value_no_signal(settings.master_volume_db)
	_volume_value.text = "%+.1f dB" % settings.master_volume_db
	_limiter_toggle.set_pressed_no_signal(settings.limiter)
	_limiter_toggle.text = "Limiter on: the output can't clip" if settings.limiter else "Limiter off: the mix as it is"
	_falloff_slider.set_value_no_signal(settings.distance_falloff_db)
	_falloff_value.text = "%.1f dB" % settings.distance_falloff_db
	if settings.distance_falloff_db <= 0.0:
		_falloff_note.text = "Instruments are as loud from across the room as from beside them."
	else:
		_falloff_note.text = "An instrument is at its own level within 1.5 m, and %.1f dB quieter for each doubling of distance beyond. (6 dB is a single source in the open air.)" % settings.distance_falloff_db
	var strip_signature := ""
	for inst in app.instruments:
		strip_signature += "%d|" % inst.get_instance_id()
	if strip_signature != _strip_signature:
		_strip_signature = strip_signature
		_fill_strips()
	for row in _strip_rows:
		row.slider.set_value_no_signal(row.inst.level_db)
		row.value.text = "%+.1f dB" % row.inst.level_db

	# Room
	var room = app.room
	for axis in _size_sliders:
		_size_sliders[axis].set_value_no_signal(room.size[axis])
		_size_values[axis].text = "%.1f m" % room.size[axis]
	_decay_label.text = "Rings for about %.1f s. Bigger rooms ring longer but more quietly." % audio.get_room_decay()
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
		if float(s.binaural_ms) > 0.0:  # binaural rendering holds the sound back by a quarter of a buffer
			parts += " + %.1f ms binaural" % s.binaural_ms
		_latency_label.text = "%.1f ms   (%s)" % [s.output_latency_ms, parts]
		_cpu_label.text = "%.0f %%" % (100.0 * float(s.cpu_load))
	else:
		_latency_label.text = "-"
		_cpu_label.text = "-"
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
	_input_toggle.text = "On" if app.live_input else "Off"
	var live_instruments: Array = app.instruments.filter(func(inst): return not inst.playable)
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
		_input_note.text = "Switch live input on to hear a microphone or instrument through a Speaker in the room. It always starts switched off. Wear headphones, or it will feed back."
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
	_reverb_toggle.set_pressed_no_signal(settings.reverb)
	_reverb_toggle.text = "On" if settings.reverb else "Off"
	if not _text_dragging:
		_text_slider.set_value_no_signal(settings.text_scale * 100.0)
		_text_value.text = "%d %%" % roundi(settings.text_scale * 100.0)
	_fov_slider.set_value_no_signal(settings.fov)
	_fov_value.text = "%d°" % roundi(settings.fov)
	_mouse_slider.set_value_no_signal(settings.mouse_sensitivity)
	_mouse_value.text = "%.2f ×" % settings.mouse_sensitivity
	_stats_toggle.set_pressed_no_signal(settings.show_stats)
	_stats_toggle.text = "On" if settings.show_stats else "Off"
	_meter_toggle.set_pressed_no_signal(settings.show_meter)
	_meter_toggle.text = "On" if settings.show_meter else "Off"
	_light_slider.set_value_no_signal(settings.room_brightness * 100.0)
	_light_value.text = "%d %%" % roundi(settings.room_brightness * 100.0)


## The Mixer's meters, every frame while that page is showing.
func _refresh_meters() -> void:
	var m: Dictionary = app.meter
	_master_meter.feed([m.get("peak_l", 0.0), m.get("peak_r", 0.0)], [m.get("rms_l", 0.0), m.get("rms_r", 0.0)])
	var average := linear_to_db(maxf(maxf(m.get("rms_l", 0.0), m.get("rms_r", 0.0)), 0.00001))
	_master_readout.text = "Peak %.1f dBFS   ·   average %.0f dBFS" % [_master_meter.held_db(), average]
	if app.meter_clipped:
		_master_state.text = "Clipping: the mix is going over full scale. Turn the volume or an instrument down."
		_master_state.add_theme_color_override("font_color", LevelMeter.RED)
	elif app.meter_reduction_db > 0.1:
		_master_state.text = "Limiting by %.1f dB. Turn the volume or an instrument down to stop it." % app.meter_reduction_db
		_master_state.add_theme_color_override("font_color", WARN)
	else:
		_master_state.text = "Limiter idle." if app.settings.limiter else "No clipping."
		_master_state.add_theme_color_override("font_color", DIM)
	var out := OUTPUT_TRIM * db_to_linear(app.settings.master_volume_db)
	for row in _strip_rows:
		row.meter.feed([audio.get_source_level(row.inst.source_id) * out])


## A row for each instrument: its name, its fader, the fader's value and a small meter.
func _fill_strips() -> void:
	for child in _strips.get_children():
		child.queue_free()
	_strip_rows.clear()
	for inst in app.instruments:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		var swatch := ColorRect.new()
		swatch.color = inst.color
		swatch.custom_minimum_size = Vector2(6, 22)
		row.add_child(swatch)
		var name_label := Label.new()
		name_label.text = inst.display_name
		name_label.custom_minimum_size.x = 96
		name_label.clip_text = true
		row.add_child(name_label)
		var slider := HSlider.new()
		slider.min_value = -40.0
		slider.max_value = 12.0
		slider.step = 0.5
		slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		slider.value_changed.connect(_on_level_changed.bind(inst))
		row.add_child(slider)
		var value := Label.new()
		value.custom_minimum_size.x = 66
		value.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		row.add_child(value)
		var strip_meter := LevelMeter.new()
		strip_meter.custom_minimum_size = Vector2(64, 8)
		strip_meter.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		row.add_child(strip_meter)
		_strips.add_child(row)
		_strip_rows.append({"inst": inst, "slider": slider, "value": value, "meter": strip_meter})


# ── Handlers ────────────────────────────────────────────────────────────────────────────────────────────────

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


func _on_level_changed(db: float, inst) -> void:
	app.set_instrument_level(inst, db)
	_refresh_live()


func _on_levels_reset_pressed() -> void:
	for inst in app.instruments:
		app.set_instrument_level(inst, 0.0)
	_refresh_live()


func _on_limiter_toggled(on: bool) -> void:
	app.set_limiter(on)
	_refresh_live()


func _on_falloff_changed(db: float) -> void:
	app.set_distance_falloff(db)
	_refresh_live()


func _on_light_changed(percent: float) -> void:
	app.set_room_brightness(percent / 100.0)
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
		_note(_live_rows, "There is no Speaker in the room to play an input. Add one from the instrument menu (N).")


func _live_label(channel: int, inst) -> String:
	return "●" if channel == inst.input_channel else ""


func _on_live_clicked(channel: int, inst) -> void:
	app.set_instrument_input(inst, channel)
	_refresh_live()


func _on_midi_toggled(on: bool, device_name: String) -> void:
	app.set_midi_device_enabled(device_name, on)
	_refresh_live()


func _on_volume_changed(db: float) -> void:
	app.set_master_volume_db(db)
	_refresh_live()


func _on_binaural_toggled(on: bool) -> void:
	app.set_binaural(on)
	_refresh_live()


func _on_reverb_toggled(on: bool) -> void:
	app.set_reverb(on)
	_refresh_live()


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
	label.text = title
	label.add_theme_font_size_override("font_size", 17)
	page.add_child(label)


func _note(page: Control, text: String) -> Label:
	var label := Label.new()
	label.text = text
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
