extends CanvasLayer
## A Speaker's panel (P at a Speaker, or its name in the mix window): which hardware input it plays, its input
## switch, and its own volume, as on the back of a powered PA speaker. The volume goes up to +24 dB, so that a Speaker
## can fill a big room as a big PA would; it comes after the Speaker's inserts (an amp simulator on one keeps its
## sound whatever the volume) and before its fader.

const UI := preload("res://scripts/ui.gd")
const Knob := preload("res://scripts/knob.gd")
const Hints := preload("res://scripts/hints.gd")
const PresetMenu := preload("res://scripts/preset_menu.gd")
const DIM := Color(0.62, 0.65, 0.74)
const WARN := Color(1.0, 0.61, 0.48)
const MAX_DB := 24.0

var app
var _close_button: Button  # its label says which key closes it too
var inst = null

var _root: Control
var _panel: PanelContainer
var _title: Label
var _volume: Knob
var _input_switch: CheckButton
var _source: OptionButton
var _inserts: Label
var _hint: Label  # the line at the foot: what the mouse is over, or for a few seconds what just happened
var _notice := ""
var _notice_is_problem := false
var _notice_until := 0
var _presets: Button
var _speaker_presets: PopupMenu
var _back_to_mixer := false


## The volume knob's setting for a level: 5 is 0 dB, 10 is +24 dB, 0 is off, evenly in decibels between.
static func knob_for(db: float) -> float:
	return 0.0 if db <= -79.0 else clampf(5.0 + db / (MAX_DB / 5.0), 0.05, 10.0)


static func db_for(knob: float) -> float:
	return -80.0 if knob <= 0.0 else (knob - 5.0) * (MAX_DB / 5.0)


func setup(the_app) -> void:
	app = the_app
	layer = 9
	_build()
	_root.visible = false


func is_open() -> bool:
	return _root.visible


func open(speaker, from_mixer := false) -> void:
	UI.keyed(_close_button, "Close", app.bindings.label("edit"))
	inst = speaker
	_back_to_mixer = from_mixer
	app.player.release_keys()
	_root.visible = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_title.text = inst.display_name
	_title.add_theme_color_override("font_color", inst.color.lightened(0.3))
	app.show_input_choice(_source, inst.input_channel)
	_refresh()


func close() -> void:
	_root.visible = false
	_speaker_presets.hide()
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	if _back_to_mixer:
		_back_to_mixer = false
		app.mixer.open()


func _input(event: InputEvent) -> void:
	if not is_open() or not (event is InputEventKey) or not event.pressed or event.echo or app.name_prompt.is_open():
		return
	var action: String = "edit" if event.physical_keycode == KEY_ESCAPE else app.bindings.action_for(event.physical_keycode)
	if action in ["edit", "mixer"]:
		var to_mixer: bool = action == "mixer"
		close()
		if to_mixer and not app.mixer.is_open():
			app.mixer.open()
		get_viewport().set_input_as_handled()


func _process(_delta: float) -> void:
	if is_open():
		_refresh()
		var noticed := Time.get_ticks_msec() < _notice_until
		_hint.text = _notice if noticed else Hints.under_mouse(_panel)
		_hint.add_theme_color_override("font_color", (WARN if _notice_is_problem else Color(0.85, 0.87, 0.92)) if noticed else DIM)


func _refresh() -> void:
	if not _volume._dragging:
		_volume.set_value_no_signal(knob_for(inst.volume_db))
	_volume.readout = "off" if inst.volume_db <= -79.0 else "%+.1f dB" % inst.volume_db
	_volume.queue_redraw()
	_input_switch.set_pressed_no_signal(inst.input_on)
	_input_switch.text = app.input_text(inst)
	app.show_input_choice(_source, inst.input_channel)
	var names := []
	for insert in inst.inserts:
		if insert.plugin_name != "":
			names.append(insert.plugin_name + ("" if insert.on else " (bypassed)"))
	_inserts.text = "Inserts: " + (", ".join(names) if not names.is_empty() else "none")


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
	var style := UI.window_style(18)
	_panel.add_theme_stylebox_override("panel", style)
	_panel.custom_minimum_size.x = 560
	center.add_child(_panel)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 12)
	_panel.add_child(box)
	var header := HBoxContainer.new()
	box.add_child(header)
	_title = Label.new()
	UI.title_label(_title, 22)
	_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(_title)
	_presets = Button.new()
	_presets.text = "Presets ▾"
	Hints.give(_presets, "Load a preset of the Speaker (its volume and plug-ins), save one, or copy and paste its settings")
	_presets.pressed.connect(func() -> void:
		_speaker_presets.for_instrument(inst)
		_speaker_presets.open_below(_presets))
	header.add_child(_presets)
	var gap_before_close := Control.new()
	gap_before_close.custom_minimum_size.x = 8
	header.add_child(gap_before_close)
	var close_button := Button.new()
	UI.ghost_button(close_button)
	_close_button = close_button
	close_button.pressed.connect(close)
	header.add_child(close_button)
	_speaker_presets = PresetMenu.new()
	_speaker_presets.setup(app)
	_speaker_presets.reported.connect(func(text: String, problem: bool) -> void:
		_notice = text
		_notice_is_problem = problem
		_notice_until = Time.get_ticks_msec() + 4000)
	_root.add_child(_speaker_presets)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 18)
	box.add_child(row)
	_volume = Knob.new()
	_volume.title = "VOLUME"
	_volume.value_changed.connect(func(value: float) -> void: app.set_speaker_volume(inst, db_for(value)))
	Hints.give(_volume, "Its own level in the room, as on a powered speaker: 5 plays the input as it comes in, 10 is +24 dB, enough to fill a big room")
	row.add_child(_volume)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 8)
	column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(column)
	var input_row := HBoxContainer.new()
	input_row.add_theme_constant_override("separation", 12)
	column.add_child(input_row)
	_input_switch = CheckButton.new()
	_input_switch.toggled.connect(func(on: bool) -> void: app.set_input(inst, on))
	Hints.give(_input_switch, "Input on: it plays what comes into your interface. Wear headphones. Armed to record, it plays it while stopped or recording too, whatever this says")
	input_row.add_child(_input_switch)
	_source = OptionButton.new()
	_source.item_selected.connect(func(index: int) -> void: app.set_input_channel(inst, app.input_at(_source, index)))
	Hints.give(_source, "Which of your interface's inputs it plays (or desktop audio, the computer's other apps, while the I/O page's audio bridge is on)")
	input_row.add_child(_source)
	_inserts = Label.new()
	_inserts.add_theme_color_override("font_color", DIM)
	_inserts.add_theme_font_size_override("font_size", 13)
	_inserts.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	Hints.give(_inserts, func() -> String: return "The plug-ins on its channel, set in the mix window (%s). An amp simulator on the first makes the Speaker sound as that amp" % (
		app.bindings.label("mixer")))
	column.add_child(_inserts)
	_hint = Hints.line()
	box.add_child(_hint)
