extends CanvasLayer
## An amp's panel (Enter at an amp): its knobs, its input, and the loop pedal on the floor in front of it.
## The pedal works the way a loop pedal does: one footswitch records, closes the loop, and lays overdubs on top;
## there are Stop, Undo and Clear beside it, a level for the loop, and Sync, which starts and ends recordings on bar
## lines while the patterns are running so the loop keeps time with them. The keys L, K, U and J do the same as
## the pedal's buttons, here and in the room.

const Knob := preload("res://scripts/knob.gd")
const Catalog := preload("res://scripts/catalog.gd")
const DIM := Color(0.62, 0.65, 0.74)
const KNOB_NAMES := {"gain": "GAIN", "bass": "BASS", "mid": "MIDDLE", "treble": "TREBLE", "presence": "PRESENCE", "master": "MASTER"}
# What each state looks like on the pedal's display, and what the footswitch does next.
const STATES := {
	"empty": ["EMPTY", Color(0.6, 0.62, 0.68), "Record"],
	"waiting": ["WAITING FOR THE BAR", Color(1.0, 0.75, 0.3), "Cancel"],
	"recording": ["● RECORDING", Color(1.0, 0.35, 0.32), "Close the loop"],
	"playing": ["▶ PLAYING", Color(0.4, 0.9, 0.5), "Overdub"],
	"overdubbing": ["● OVERDUBBING", Color(1.0, 0.62, 0.25), "Stop overdubbing"],
	"stopped": ["■ STOPPED", Color(0.6, 0.62, 0.68), "Play"],
}

var app
var audio: SoundRoomAudio
var inst = null

var _root: Control
var _panel: PanelContainer
var _title: Label
var _faceplate: StyleBoxFlat
var _knobs := {}
var _input_switch: CheckButton
var _source: OptionButton
var _display: Label
var _time: Label
var _progress: ProgressBar
var _footswitch: Button
var _stop: Button
var _undo: Button
var _clear: Button
var _level: Knob
var _sync: CheckButton
var _after: OptionButton
var _clear_armed_until := 0


func setup(the_app) -> void:
	app = the_app
	audio = app.audio
	layer = 9
	_build()
	_root.visible = false


func is_open() -> bool:
	return _root.visible


func open(amp) -> void:
	inst = amp
	app.player.release_keys()
	_root.visible = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_title.text = inst.display_name
	_title.add_theme_color_override("font_color", inst.color.lightened(0.3))
	_faceplate.border_color = inst.color
	_source.clear()
	_source.add_item("All inputs")
	for i in app.input_channel_count():
		_source.add_item("Input %d" % (i + 1))
	_refresh()


func close() -> void:
	_root.visible = false
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _input(event: InputEvent) -> void:
	if not is_open() or not (event is InputEventKey) or not event.pressed or event.echo:
		return
	var handled := true
	match event.physical_keycode:
		KEY_ESCAPE, KEY_ENTER, KEY_KP_ENTER:
			close()
		KEY_TAB:
			close()
			app.mixer.open()
		KEY_L:
			_on_footswitch()
		KEY_K:
			_on_stop()
		KEY_U:
			_on_undo()
		KEY_J:
			_on_clear()
		_:
			handled = false
	if handled:
		get_viewport().set_input_as_handled()


func _process(_delta: float) -> void:
	if not is_open():
		return
	var vp := get_viewport().get_visible_rect().size
	_panel.custom_minimum_size = Vector2(minf(820.0, vp.x - 32.0), 0.0)
	_refresh()


func _refresh() -> void:
	for control in _knobs:
		if not _knobs[control]._dragging:
			_knobs[control].set_value_no_signal(inst.amp_controls[control])
	_input_switch.set_pressed_no_signal(inst.input_on)
	_input_switch.text = "Input on" if inst.input_on else "Input off"
	_source.select(clampi(inst.input_channel + 1, 0, _source.item_count - 1))
	var loop: Dictionary = inst.looper
	var state: String = loop.get("state", "empty")
	var look: Array = STATES.get(state, STATES.empty)
	_display.text = look[0]
	_display.add_theme_color_override("font_color", look[1])
	var length: float = loop.get("length", 0.0)
	var position: float = loop.get("position", 0.0)
	if state in ["playing", "overdubbing"]:
		_time.text = "%s / %s" % [_clock(position), _clock(length)]
		_progress.value = position / maxf(length, 0.001) * 100.0
	elif state == "recording":
		_time.text = "%s   (up to %s)" % [_clock(length), _clock(loop.get("capacity", 0.0))]
		_progress.value = length / maxf(loop.get("capacity", 1.0), 0.001) * 100.0
	else:
		_time.text = _clock(length) if length > 0.0 else "-"
		_progress.value = 0.0
	_footswitch.text = "%s   (L)" % look[2]
	_stop.text = "Play   (K)" if state == "stopped" else "Stop   (K)"
	_stop.disabled = state in ["empty", "waiting"]
	_undo.text = "Redo   (U)" if loop.get("can_redo", false) and not loop.get("can_undo", false) else "Undo   (U)"
	_undo.disabled = not (loop.get("can_undo", false) or loop.get("can_redo", false))
	var armed := Time.get_ticks_msec() < _clear_armed_until
	_clear.text = "Press again to clear" if armed else "Clear   (J)"
	_clear.disabled = state in ["empty", "waiting"]
	if not _level._dragging:
		_level.set_value_no_signal(inst.looper_level * 5.0)
	_sync.set_pressed_no_signal(inst.looper_sync)
	_after.select(1 if inst.looper_dub_after else 0)


func _clock(seconds: float) -> String:
	return "%d:%04.1f" % [int(seconds) / 60, fmod(seconds, 60.0)]


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
	box.add_theme_constant_override("separation", 12)
	_panel.add_child(box)

	var header := HBoxContainer.new()
	box.add_child(header)
	_title = Label.new()
	_title.add_theme_font_size_override("font_size", 22)
	_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(_title)
	var close_button := Button.new()
	close_button.text = "Close  (Enter)"
	close_button.pressed.connect(close)
	header.add_child(close_button)

	# The amp's own panel: black, edged in its colour, with a row of knobs.
	var plate := PanelContainer.new()
	_faceplate = StyleBoxFlat.new()
	_faceplate.bg_color = Color(0.05, 0.05, 0.06)
	_faceplate.set_corner_radius_all(6)
	_faceplate.set_border_width_all(2)
	_faceplate.set_content_margin_all(12)
	plate.add_theme_stylebox_override("panel", _faceplate)
	box.add_child(plate)
	var knobs := HBoxContainer.new()
	knobs.alignment = BoxContainer.ALIGNMENT_CENTER
	knobs.add_theme_constant_override("separation", 18)
	plate.add_child(knobs)
	for control in Catalog.AMP_CONTROLS:
		var knob := Knob.new()
		knob.title = KNOB_NAMES[control]
		knob.value_changed.connect(_on_knob_changed.bind(control))
		knobs.add_child(knob)
		_knobs[control] = knob

	var input_row := HBoxContainer.new()
	input_row.add_theme_constant_override("separation", 12)
	box.add_child(input_row)
	_input_switch = CheckButton.new()
	_input_switch.toggled.connect(_on_input_toggled)
	input_row.add_child(_input_switch)
	_source = OptionButton.new()
	_source.item_selected.connect(_on_source_selected)
	input_row.add_child(_source)
	var input_note := Label.new()
	input_note.text = "Plug a guitar or bass into your interface and pick its input. Wear headphones."
	input_note.add_theme_color_override("font_color", DIM)
	input_note.add_theme_font_size_override("font_size", 13)
	input_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	input_note.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	input_row.add_child(input_note)

	# The loop pedal.
	var heading := Label.new()
	heading.text = "Loop pedal"
	heading.add_theme_font_size_override("font_size", 18)
	box.add_child(heading)
	var pedal := PanelContainer.new()
	var pedal_style := StyleBoxFlat.new()
	pedal_style.bg_color = Color(0.17, 0.18, 0.21)
	pedal_style.set_corner_radius_all(10)
	pedal_style.set_border_width_all(1)
	pedal_style.border_color = Color(0, 0, 0, 0.6)
	pedal_style.set_content_margin_all(14)
	pedal.add_theme_stylebox_override("panel", pedal_style)
	box.add_child(pedal)
	var pedal_row := HBoxContainer.new()
	pedal_row.add_theme_constant_override("separation", 18)
	pedal.add_child(pedal_row)

	var left := VBoxContainer.new()
	left.add_theme_constant_override("separation", 8)
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	pedal_row.add_child(left)
	var screen := PanelContainer.new()  # the pedal's display
	var screen_style := StyleBoxFlat.new()
	screen_style.bg_color = Color(0.03, 0.035, 0.04)
	screen_style.set_corner_radius_all(4)
	screen_style.set_content_margin_all(10)
	screen.add_theme_stylebox_override("panel", screen_style)
	left.add_child(screen)
	var screen_box := VBoxContainer.new()
	screen.add_child(screen_box)
	_display = Label.new()
	_display.add_theme_font_size_override("font_size", 20)
	screen_box.add_child(_display)
	_time = Label.new()
	_time.add_theme_color_override("font_color", DIM)
	screen_box.add_child(_time)
	_progress = ProgressBar.new()
	_progress.show_percentage = false
	_progress.custom_minimum_size.y = 8
	screen_box.add_child(_progress)
	_footswitch = Button.new()
	_footswitch.custom_minimum_size.y = 48
	_footswitch.add_theme_font_size_override("font_size", 18)
	_footswitch.pressed.connect(_on_footswitch)
	left.add_child(_footswitch)
	var buttons := HBoxContainer.new()
	buttons.add_theme_constant_override("separation", 8)
	left.add_child(buttons)
	_stop = _button(buttons, _on_stop)
	_undo = _button(buttons, _on_undo)
	_clear = _button(buttons, _on_clear)

	var right := VBoxContainer.new()
	right.add_theme_constant_override("separation", 8)
	right.custom_minimum_size.x = 250
	pedal_row.add_child(right)
	var level_row := HBoxContainer.new()
	right.add_child(level_row)
	_level = Knob.new()
	_level.title = "LOOP LEVEL"
	_level.value_changed.connect(_on_level_changed)
	level_row.add_child(_level)
	var options := VBoxContainer.new()
	level_row.add_child(options)
	_sync = CheckButton.new()
	_sync.text = "Sync to the bars"
	_sync.tooltip_text = "While the patterns are running, recording starts on the next bar line and the loop is a whole number of bars."
	_sync.toggled.connect(_on_sync_toggled)
	options.add_child(_sync)
	var after_label := Label.new()
	after_label.text = "After recording"
	after_label.add_theme_color_override("font_color", DIM)
	after_label.add_theme_font_size_override("font_size", 13)
	options.add_child(after_label)
	_after = OptionButton.new()
	_after.add_item("play the loop")
	_after.add_item("overdub straight away")
	_after.item_selected.connect(_on_after_selected)
	options.add_child(_after)
	var note := Label.new()
	note.text = "The footswitch records, then closes the loop, then lays overdubs on top. The pedal sits before the amp, so the loop plays through its knobs. Loops are kept until the sample rate changes, and aren't saved yet."
	note.add_theme_color_override("font_color", DIM)
	note.add_theme_font_size_override("font_size", 12)
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	right.add_child(note)


func _button(parent: Control, on_pressed: Callable) -> Button:
	var button := Button.new()
	button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	button.pressed.connect(on_pressed)
	parent.add_child(button)
	return button


# ── Handlers ────────────────────────────────────────────────────────────────────────────────────────────────

func _on_knob_changed(value: float, control: String) -> void:
	app.set_amp_control(inst, control, value)


func _on_input_toggled(on: bool) -> void:
	app.set_input(inst, on)


func _on_source_selected(index: int) -> void:
	app.set_input_channel(inst, index - 1)


func _on_footswitch() -> void:
	app.looper_action(inst, "press")


func _on_stop() -> void:
	app.looper_action(inst, "play" if inst.looper.get("state", "") == "stopped" else "stop")


func _on_undo() -> void:
	var loop: Dictionary = inst.looper
	app.looper_action(inst, "undo" if loop.get("can_undo", false) else "redo")


## Clearing takes two presses, so a stray key doesn't lose a loop.
func _on_clear() -> void:
	if Time.get_ticks_msec() < _clear_armed_until:
		_clear_armed_until = 0
		app.looper_action(inst, "clear")
	else:
		_clear_armed_until = Time.get_ticks_msec() + 3000


func _on_level_changed(value: float) -> void:
	app.set_looper_options(inst, value / 5.0, inst.looper_sync, inst.looper_dub_after)


func _on_sync_toggled(on: bool) -> void:
	app.set_looper_options(inst, inst.looper_level, on, inst.looper_dub_after)


func _on_after_selected(index: int) -> void:
	app.set_looper_options(inst, inst.looper_level, inst.looper_sync, index == 1)
