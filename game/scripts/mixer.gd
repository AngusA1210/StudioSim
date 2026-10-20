extends CanvasLayer
## The mix window (Tab), laid out like a mixing desk: a channel strip for every instrument side by side, the master
## strip on the right. A strip has its inserts at the top, then the instrument's input (which hardware input, for a
## Speaker or an amp), buttons for input, mute and solo, a fader with its meter beside it, the fader's level and the
## highest peak beneath them, and the instrument's name in its colour at the foot.
## The inserts work as Pro Tools' do: click an empty one to choose a plug-in (its window opens), click a full one to
## open or close its window, Cmd-click (Ctrl-click) to bypass it, and right-click for the rest. A bypassed insert is
## blue. Drag one to another slot, on its own strip or another, to move it there (it swaps with what was there);
## hold Option while dropping to copy it instead, settings and all. They play on the instrument's sound in order,
## before its fader.
## Click a strip's name to open the instrument's own window (an amp's panel and pedals, a pattern, a Speaker's panel);
## Shift-click or Cmd-click it to choose tracks (Cmd-G puts those chosen in a new folder); right-click it to rename it,
## colour it, put it in a folder or take it out, duplicate it or remove it from the room. Under its input, each strip's
## output: the master, or a routing folder. A folder's strip (before its tracks') has its inserts, its mute and solo,
## and its fader, through which its tracks reach the master. An aux track's strip (after the tracks') has its inserts
## (a reverb, a delay), mute and solo and its fader: the tracks' sends play into it. Under the inserts, as in Pro Tools,
## each strip's sends, A to E: click an empty send to send to an aux (or a new one); drag a send up or down for its
## level (Shift for fine moves), double-click it for 0 dB, Cmd-click to switch it off and on, right-click it for before
## the fader or after, another aux, or none. As in Pro Tools, the peak readout holds the
## highest peak until it is clicked (Alt-click clears them all), and clicking a meter does the same. The channel meters
## read before the fader; right-click any fader to have them read after it instead.
## Rather than instructions written across it, the line at the foot of the window describes whatever the mouse is over.
## It docks along the bottom of the screen so the room stays in view, you can walk about while it is open, and the
## music keeps playing.

const Fader := preload("res://scripts/fader.gd")
const LevelMeter := preload("res://scripts/level_meter.gd")
const Hints := preload("res://scripts/hints.gd")
const PresetMenu := preload("res://scripts/preset_menu.gd")
const TrackMenu := preload("res://scripts/track_menu.gd")

const STRIP_WIDTH := 96.0
const STRIP_BG := Color(0.16, 0.17, 0.19, 0.98)
const DIM := Color(0.62, 0.65, 0.74)
const WARN := Color(1.0, 0.61, 0.48)
const INPUT_GREEN := Color(0.36, 0.9, 0.5)
const MUTE_ORANGE := Color(1.0, 0.62, 0.25)
const SOLO_YELLOW := Color(0.98, 0.86, 0.3)

var app
var audio: SoundRoomAudio

var _root: Control
var _panel: PanelContainer
var _strip_row: HBoxContainer
var _strips: Array = []  # {inst (an instrument or a folder), fader, meter, value, peak, input, mute, solo, source, output, inserts: [{button, style}], plate, frame}
var _colors: PopupMenu   # the Colour submenu of a track's menu
var _send_menu: PopupMenu  # an empty send's auxes to choose from, or a full one's options
var _send_menu_for := []   # [instrument, slot]
var _send_drag := {}       # a send's level being dragged: {inst, slot, from_y, from_db}
var _modes: PopupMenu    # and its Automation submenu
var _insert_menu: PopupMenu  # what a right-click on a full insert offers
var _menu_for := []  # [instrument, slot] that menu is open for
var _insert_presets: PopupMenu  # its Presets submenu: the plug-in's presets, and copying and pasting its settings
var _name_presets: PopupMenu  # the same for an instrument, from its name
var _plugin_menu: PopupMenu  # what a right-click on a plug-in instrument's plug-in offers
var _plugin_presets: PopupMenu
var _plugin_menu_for = null
var _name_menu: PopupMenu  # what a right-click on a strip's name offers
var _name_menu_for = null
var _confirm: ConfirmationDialog  # removing an instrument
var _meter_menu: PopupMenu  # what a right-click on a fader or meter offers: the meters before the fader or after it
var _hint: Label  # the line at the foot: what the mouse is over
var _to_edit: Button  # over to the edit window, in a Record room
var _signature := ""
var _input_channels := -1
var _master := {}
var _reverb := {}  # the room reverb's strip
const REVERB := "reverb"  # what its fader and meter are for (null is the master)
var _status: Label
var _problem_until := 0  # a plug-in that wouldn't load is reported in the status line for a few seconds


func setup(the_app) -> void:
	app = the_app
	audio = app.audio
	layer = 9
	_build()
	_root.visible = false


func is_open() -> bool:
	return _root.visible


func open() -> void:
	app.player.release_keys()
	_root.visible = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_input_channels = -1  # the hardware may have changed: list its inputs again
	_refresh()


## Closing puts away the inserts' windows: in the room the mouse looks around rather than pointing.
func close() -> void:
	_root.visible = false
	_insert_menu.hide()
	_meter_menu.hide()
	_plugin_menu.hide()
	app.plugin_browser.hide()
	for folder in app.folders + app.auxes:
		app.hide_insert_editors(folder)
	for inst in app.instruments:
		app.hide_insert_editors(inst)
		if inst.plays_plugin and inst.instrument_plugin.get("editor_open", false):
			app.show_instrument_editor(inst, false)
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _input(event: InputEvent) -> void:
	if app.plugin_browser.visible or app.name_prompt.is_open():  # the keys are for typing
		return
	if not (is_open() and event is InputEventKey and event.pressed and not event.echo) or event.meta_pressed or event.ctrl_pressed:
		return
	if get_viewport().gui_get_focus_owner() is LineEdit:
		return
	var action: String = app.bindings.action_for(event.physical_keycode)
	if event.physical_keycode == KEY_ESCAPE or action == "mixer":
		close()
	elif action == "edit_window" and app.timeline.is_record():  # over to the edit window
		close()
		app.edit_window.open()
	elif action == "to_start" and app.timeline.is_record():  # back to the start
		app.timeline.locate(0.0)
	elif action == "follow" and app.timeline.is_record():
		app.toggle_follow()
	elif event.physical_keycode == KEY_L and event.alt_pressed and app.timeline.is_record():  # Loop Record
		app.toggle_loop_record()
	elif event.physical_keycode == KEY_L and app.timeline.is_record():  # loop playback on or off
		app.timeline.set_loop(not app.timeline.loop_on)
	else:
		return
	get_viewport().set_input_as_handled()


func _process(_delta: float) -> void:
	if not is_open():
		return
	var vp := get_viewport().get_visible_rect().size
	var height := minf(620.0, vp.y - 60.0)
	_panel.position = Vector2(12, vp.y - height - 12)
	_panel.size = Vector2(vp.x - 24, height)
	_refresh()
	_line_up()
	_to_edit.visible = app.timeline.is_record()
	_to_edit.text = "Edit window  (%s)" % app.bindings.label("edit_window")
	_hint.text = Hints.under_mouse(_panel)


## The reverb's and the master's faders level with the tracks': the space above them grown or shrunk to match.
func _line_up() -> void:
	if _strips.is_empty():
		return
	var top: float = _strips[0].fader.global_position.y
	for strip in [_reverb, _master]:
		var off: float = top - strip.fader.global_position.y
		if absf(off) > 0.5:
			strip.gap.custom_minimum_size.y = maxf(strip.gap.custom_minimum_size.y + off, 0.0)


# ── Building ────────────────────────────────────────────────────────────────────────────────────────────────

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
	header.add_theme_constant_override("separation", 14)
	box.add_child(header)
	var title := Label.new()
	title.text = "Mix"
	title.add_theme_font_size_override("font_size", 20)
	header.add_child(title)
	_status = Label.new()
	_status.add_theme_font_size_override("font_size", 13)
	_status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_status.clip_text = true
	header.add_child(_status)
	_to_edit = Button.new()
	_to_edit.text = "Edit window  (R)"
	_to_edit.focus_mode = Control.FOCUS_NONE
	_to_edit.pressed.connect(func() -> void:
		close()
		app.edit_window.open())
	header.add_child(_to_edit)
	var close_button := Button.new()
	close_button.text = "Close  (Tab)"
	close_button.pressed.connect(close)
	header.add_child(close_button)

	var desk := HBoxContainer.new()
	desk.add_theme_constant_override("separation", 10)
	desk.size_flags_vertical = Control.SIZE_EXPAND_FILL
	box.add_child(desk)
	var scroll := ScrollContainer.new()
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	desk.add_child(scroll)
	_strip_row = HBoxContainer.new()
	_strip_row.add_theme_constant_override("separation", 4)
	_strip_row.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.add_child(_strip_row)
	desk.add_child(VSeparator.new())
	desk.add_child(_build_reverb())
	desk.add_child(_build_master())

	_insert_menu = PopupMenu.new()
	_insert_menu.id_pressed.connect(_on_insert_menu_chosen)
	_root.add_child(_insert_menu)
	_insert_presets = PresetMenu.new()
	_insert_presets.setup(app)
	_insert_presets.reported.connect(_report)
	_insert_menu.add_child(_insert_presets)
	_name_menu = PopupMenu.new()
	_name_menu.id_pressed.connect(_on_name_menu_chosen)
	_root.add_child(_name_menu)
	_name_presets = PresetMenu.new()
	_name_presets.setup(app)
	_name_presets.reported.connect(_report)
	_name_menu.add_child(_name_presets)
	_colors = TrackMenu.colors_menu(app, func(color: Color) -> void:
		if _name_menu_for != null and app.has_track(_name_menu_for):
			app.set_track_color(_name_menu_for, color))
	_name_menu.add_child(_colors)
	_send_menu = PopupMenu.new()
	_send_menu.id_pressed.connect(_on_send_menu_chosen)
	_root.add_child(_send_menu)
	_modes = TrackMenu.modes_menu(app, func(mode: String) -> void:
		if _name_menu_for != null and app.has_track(_name_menu_for):
			app.automation.set_mode(_name_menu_for, mode))
	_name_menu.add_child(_modes)
	_plugin_menu = PopupMenu.new()
	_plugin_menu.id_pressed.connect(_on_plugin_menu_chosen)
	_root.add_child(_plugin_menu)
	_plugin_presets = PresetMenu.new()
	_plugin_presets.setup(app)
	_plugin_presets.reported.connect(_report)
	_plugin_menu.add_child(_plugin_presets)
	_confirm = ConfirmationDialog.new()
	_confirm.ok_button_text = "Remove"
	_confirm.confirmed.connect(_on_remove_confirmed)
	_root.add_child(_confirm)
	_meter_menu = PopupMenu.new()
	_meter_menu.add_radio_check_item("Pre-fader metering", 0)
	_meter_menu.add_radio_check_item("Post-fader metering", 1)
	_meter_menu.id_pressed.connect(func(id: int) -> void: app.set_pre_fader_meters(id == 0))
	_root.add_child(_meter_menu)

	_hint = Hints.line()
	box.add_child(_hint)


## The room reverb's return, as a DAW's effects return: its fader (0 dB is the reverb the room's size calls for, the
## bottom none at all) with its meter, beside the master's.
func _build_reverb() -> PanelContainer:
	var strip := _strip_panel(STRIP_WIDTH + 14)
	var box: VBoxContainer = strip.get_child(0)
	var level_with_inserts := Control.new()  # so its fader lines up with the others
	level_with_inserts.custom_minimum_size.y = _slots_height()
	box.add_child(level_with_inserts)
	_small(box, "RETURN")
	var gap := Control.new()
	gap.custom_minimum_size.y = 84
	box.add_child(gap)
	var pair := _fader_and_meter(box, 2, REVERB)
	pair.fader.value_changed.connect(func(db: float) -> void: app.set_reverb_db(db))
	var readouts := _readouts(box, REVERB)
	box.add_child(_name_plate("Reverb", Color(0.4, 0.86, 0.78), null))
	_reverb = {"fader": pair.fader, "meter": pair.meter, "value": readouts.value, "peak": readouts.peak, "gap": gap}
	return strip


func _build_master() -> PanelContainer:
	var strip := _strip_panel(STRIP_WIDTH + 14)
	var box: VBoxContainer = strip.get_child(0)
	var level_with_inserts := Control.new()  # so the faders line up with the instruments'
	level_with_inserts.custom_minimum_size.y = _slots_height()
	box.add_child(level_with_inserts)
	_small(box, "OUTPUT")
	var limiter := _toggle("LIMIT", Color(0.55, 0.78, 1.0))
	Hints.give(limiter, "Limiter, before the master fader: on, the mix can't go over full scale; off, the plain sum. What leaves the fader over full scale is cut off either way.")
	limiter.toggled.connect(_on_limiter_toggled)
	limiter.custom_minimum_size = Vector2(76, 24)
	limiter.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	box.add_child(limiter)
	var gap := Control.new()
	gap.custom_minimum_size.y = 54
	box.add_child(gap)
	var pair := _fader_and_meter(box, 2, null)
	pair.fader.value_changed.connect(_on_master_changed)
	var readouts := _readouts(box, null)
	box.add_child(_name_plate("Master", Color(0.75, 0.77, 0.82), null))
	_master = {"fader": pair.fader, "meter": pair.meter, "value": readouts.value, "peak": readouts.peak, "limiter": limiter, "gap": gap}
	return strip


## A strip for one instrument.
func _build_strip(inst) -> Dictionary:
	var strip := _strip_panel(STRIP_WIDTH)
	var box: VBoxContainer = strip.get_child(0)
	var inserts := _build_inserts(box, inst)
	var sends := _build_sends(box, inst)
	_small(box, "INSTRUMENT" if inst.plays_plugin else "INPUT")
	var source: Control
	if inst.plays_plugin:  # the plug-in it plays, in place of where its input comes from
		var plug := Button.new()
		plug.focus_mode = Control.FOCUS_NONE
		plug.clip_text = true
		plug.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		plug.add_theme_font_size_override("font_size", 12)
		plug.custom_minimum_size = Vector2(STRIP_WIDTH - 12, 24)
		plug.pressed.connect(func() -> void: app.show_instrument_editor(inst, not inst.instrument_plugin.get("editor_open", false)))
		plug.gui_input.connect(_on_plugin_input.bind(inst, plug))
		Hints.give(plug, func() -> String: return "Its plug-in, %s: click for its window, right-click to replace it or for its presets" % (
			inst.instrument_plugin.get("plugin_name", "")))
		source = plug
	elif inst.playable:
		var midi := Label.new()
		midi.text = "MIDI"
		midi.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		midi.custom_minimum_size.y = 24
		midi.add_theme_font_size_override("font_size", 13)
		Hints.give(midi, func() -> String: return "Played over MIDI: your MIDI keyboard, or the computer's (%s), while its input is on" % (
			app.bindings.label("keyboard")))
		source = midi
	else:
		var choice := OptionButton.new()
		choice.add_theme_font_size_override("font_size", 12)
		choice.fit_to_longest_item = false
		choice.custom_minimum_size = Vector2(STRIP_WIDTH - 16, 24)
		choice.item_selected.connect(_on_source_selected.bind(inst))
		Hints.give(choice, "Which of your interface's inputs it plays")
		source = choice
	box.add_child(source)
	var output := _output_button(inst)
	box.add_child(output)
	var buttons := HBoxContainer.new()
	buttons.add_theme_constant_override("separation", 3)
	buttons.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_child(buttons)
	var input := _toggle("I", INPUT_GREEN)
	Hints.give(input, ("Input: the MIDI keyboard plays it" if inst.playable else "Input monitoring: it plays the hardware input chosen above") +
		"  ·  Option-click: every track")
	input.toggled.connect(_on_input_toggled.bind(inst))
	buttons.add_child(input)
	var mute := _toggle("M", MUTE_ORANGE)
	Hints.give(mute, "Mute  ·  Option-click: every track")
	mute.toggled.connect(_on_mute_toggled.bind(inst))
	buttons.add_child(mute)
	var solo := _toggle("S", SOLO_YELLOW)
	Hints.give(solo, "Solo: while anything is soloed, everything else is silent  ·  Option-click: every track")
	solo.toggled.connect(_on_solo_toggled.bind(inst))
	buttons.add_child(solo)
	var pair := _fader_and_meter(box, 1, inst)
	pair.fader.value_changed.connect(_on_fader_changed.bind(inst))
	var readouts := _readouts(box, inst)
	var plate := _name_plate(inst.display_name, inst.color, inst)
	box.add_child(plate)
	_strip_row.add_child(strip)
	return {"inst": inst, "fader": pair.fader, "meter": pair.meter, "value": readouts.value, "peak": readouts.peak, "input": input,
		"mute": mute, "solo": solo, "source": source, "output": output, "inserts": inserts, "sends": sends, "plate": plate,
		"frame": strip.get_theme_stylebox("panel"), "panel": strip}


## Where a track plays, as a Pro Tools track's output: the master, or a folder's bus (an aux input). Only the folders
## it can go in are offered (not itself, nor one its own sound reaches: a folder in it, an aux it sends to...).
func _output_button(track) -> OptionButton:
	var output := OptionButton.new()
	output.add_theme_font_size_override("font_size", 12)
	output.fit_to_longest_item = false
	output.focus_mode = Control.FOCUS_NONE
	output.custom_minimum_size = Vector2(STRIP_WIDTH - 16, 24)
	var choices: Array = [null] + app.folders.filter(func(folder): return app.can_put_in(track, folder))
	for folder in choices:
		output.add_item("→ %s" % (folder.display_name if folder != null else "Master"))
	output.set_meta("choices", choices)
	output.item_selected.connect(func(i: int) -> void:
		if not app.put_in_folder(track, choices[i]):
			_report("It can't go there: its own sound would come round to it again."))
	Hints.give(output, "Its output: straight to the master, or into a folder, through the folder's inserts and fader")
	return output


## A routing folder's strip (an aux track's too): its inserts (in stereo) and sends, how many tracks it has (or sends
## come in), its output, mute and solo, and its fader, through which they reach the master or the folder it is in.
func _build_folder_strip(folder) -> Dictionary:
	var strip := _strip_panel(STRIP_WIDTH)
	var box: VBoxContainer = strip.get_child(0)
	var inserts := _build_inserts(box, folder)
	var sends := _build_sends(box, folder)
	_small(box, "AUX" if folder.is_aux else "FOLDER")
	var count := Label.new()
	count.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	count.custom_minimum_size.y = 24
	count.add_theme_font_size_override("font_size", 12)
	Hints.give(count, "The tracks' sends to it play into it, and through its inserts and fader to its output" if folder.is_aux else
		"The tracks in it play into it, and through its inserts and fader to its output")
	box.add_child(count)
	var output := _output_button(folder)
	box.add_child(output)
	var buttons := HBoxContainer.new()
	buttons.add_theme_constant_override("separation", 3)
	buttons.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_child(buttons)
	var mute := _toggle("M", MUTE_ORANGE)
	Hints.give(mute, "Mute: its tracks are silent  ·  Option-click: every track")
	mute.toggled.connect(_on_mute_toggled.bind(folder))
	buttons.add_child(mute)
	var solo := _toggle("S", SOLO_YELLOW)
	Hints.give(solo, "Solo: its tracks are soloed  ·  Option-click: every track")
	solo.toggled.connect(_on_solo_toggled.bind(folder))
	buttons.add_child(solo)
	var pair := _fader_and_meter(box, 1, folder)
	pair.fader.value_changed.connect(func(db: float) -> void: app.set_folder_level(folder, db))
	var readouts := _readouts(box, folder)
	var plate := _name_plate(folder.display_name, folder.color, folder)
	box.add_child(plate)
	_strip_row.add_child(strip)
	return {"inst": folder, "fader": pair.fader, "meter": pair.meter, "value": readouts.value, "peak": readouts.peak, "input": null,
		"mute": mute, "solo": solo, "source": count, "output": output, "inserts": inserts, "sends": sends, "plate": plate,
		"frame": strip.get_theme_stylebox("panel"), "panel": strip}


const INSERT_HEIGHT := 17.0


## How tall a strip's inserts and sends are together (the reverb's and the master's strips leave the room empty).
func _slots_height() -> float:
	var section := func(count: int) -> float: return 14.0 + 3.0 + count * INSERT_HEIGHT + (count - 1) * 1.0
	return section.call(audio.get_max_inserts()) + 8.0 + section.call(audio.get_max_sends())


## A strip's insert slots, A to E as in Pro Tools.
func _build_inserts(box: VBoxContainer, inst) -> Array:
	var section := VBoxContainer.new()
	section.add_theme_constant_override("separation", 3)
	box.add_child(section)
	_small(section, "INSERTS")
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 1)
	section.add_child(column)
	var slots := []
	for slot in audio.get_max_inserts():
		var button := Button.new()
		button.focus_mode = Control.FOCUS_NONE
		button.custom_minimum_size = Vector2(STRIP_WIDTH - 12, INSERT_HEIGHT)
		button.clip_text = true
		button.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		button.add_theme_font_size_override("font_size", 11)
		var style := StyleBoxFlat.new()
		style.set_corner_radius_all(3)
		style.set_border_width_all(1)
		style.content_margin_left = 4
		style.content_margin_right = 4
		for state in ["normal", "hover", "pressed", "hover_pressed"]:
			button.add_theme_stylebox_override(state, style)
		button.pressed.connect(func() -> void:
			_on_insert_clicked(inst, slot, Input.is_key_pressed(KEY_META) or Input.is_key_pressed(KEY_CTRL)))
		button.gui_input.connect(_on_insert_input.bind(inst, slot))
		button.set_drag_forwarding(_insert_drag.bind(inst, slot), _insert_can_drop.bind(inst, slot), _insert_drop.bind(inst, slot))
		Hints.give(button, _insert_hint.bind(inst, slot))
		column.add_child(button)
		slots.append({"button": button, "style": style})
	return slots


## A strip's sends, A to E as Pro Tools has them, under its inserts.
func _build_sends(box: VBoxContainer, inst) -> Array:
	var section := VBoxContainer.new()
	section.add_theme_constant_override("separation", 3)
	box.add_child(section)
	_small(section, "SENDS")
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 1)
	section.add_child(column)
	var slots := []
	for slot in audio.get_max_sends():
		var button := Button.new()
		button.focus_mode = Control.FOCUS_NONE
		button.custom_minimum_size = Vector2(STRIP_WIDTH - 12, INSERT_HEIGHT)
		button.clip_text = true
		button.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		button.add_theme_font_size_override("font_size", 11)
		var style := StyleBoxFlat.new()
		style.set_corner_radius_all(3)
		style.set_border_width_all(1)
		style.content_margin_left = 4
		style.content_margin_right = 4
		for state in ["normal", "hover", "pressed", "hover_pressed"]:
			button.add_theme_stylebox_override(state, style)
		button.gui_input.connect(_on_send_input.bind(inst, slot, button))
		Hints.give(button, _send_hint.bind(inst, slot))
		column.add_child(button)
		slots.append({"button": button, "style": style})
	return slots


## What each send shows: the aux it goes to and its level (as its automation has it, playing), pre-fader marked,
## dim while it is off.
func _show_sends(strip: Dictionary) -> void:
	var inst = strip.inst
	for slot in strip.sends.size():
		var button: Button = strip.sends[slot].button
		var style: StyleBoxFlat = strip.sends[slot].style
		var send: Dictionary = inst.sends[slot]
		if send.is_empty():
			button.text = ""
			style.bg_color = Color(0.1, 0.105, 0.12)
			style.border_color = Color(0, 0, 0, 0.5)
			continue
		var db: float = app.automation.shown(inst, "send:%d" % slot)
		button.text = "%s  %s%s" % [send.aux.display_name, _db_text(db), "  pre" if send.pre else ""]
		style.bg_color = send.aux.color.darkened(0.55) if send.on else Color(0.18, 0.18, 0.2)
		style.border_color = send.aux.color.darkened(0.2) if send.on else Color(0, 0, 0, 0.5)
		var ink := Color(0.93, 0.94, 0.97) if send.on else Color(0.55, 0.57, 0.62)
		for state in ["font_color", "font_hover_color", "font_pressed_color"]:
			button.add_theme_color_override(state, ink)


func _send_hint(inst, slot: int) -> String:
	var send: Dictionary = inst.sends[slot]
	if send.is_empty():
		return "Send %s: click to send a copy of the track to an aux track (or a new one)" % char(65 + slot)
	return "Send %s to %s, %s the fader%s: drag up or down for its level (Shift: fine), double-click for 0 dB, Cmd-click: %s, right-click for more" % [
		char(65 + slot), send.aux.display_name, "before" if send.pre else "after", "" if send.on else ", off", "on" if not send.on else "off"]


## A send pressed: empty, the auxes to send to; full, its level dragged (or with Cmd, switched; double-click, 0 dB);
## right-clicked, its options.
func _on_send_input(event: InputEvent, inst, slot: int, button: Button) -> void:
	if event is InputEventMouseButton:
		var e: InputEventMouseButton = event
		var send: Dictionary = inst.sends[slot]
		if e.pressed and e.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN] and not send.is_empty():
			app.set_send_level(inst, slot, float(send.level_db) + (0.5 if e.button_index == MOUSE_BUTTON_WHEEL_UP else -0.5))
		elif e.button_index == MOUSE_BUTTON_LEFT and e.pressed:
			if send.is_empty():
				show_send_menu(inst, slot, button)
			elif e.meta_pressed or e.ctrl_pressed:
				app.set_send(inst, slot, send.aux, send.level_db, send.pre, not send.on)
			elif e.double_click:
				app.set_send_level(inst, slot, 0.0)
			else:
				_send_drag = {"inst": inst, "slot": slot, "from_y": e.global_position.y, "from_db": float(send.level_db)}
				app.automation.touch(inst, true, "send:%d" % slot)
		elif e.button_index == MOUSE_BUTTON_LEFT and not e.pressed and not _send_drag.is_empty():
			app.automation.touch(_send_drag.inst, false, "send:%d" % _send_drag.slot)
			_send_drag = {}
		elif e.button_index == MOUSE_BUTTON_RIGHT and e.pressed and not send.is_empty():
			show_send_menu(inst, slot, button)
		button.accept_event()
	elif event is InputEventMouseMotion and not _send_drag.is_empty():
		var fine: bool = event.shift_pressed
		var travel: float = Fader.position_of(_send_drag.from_db) + (_send_drag.from_y - event.global_position.y) / (80.0 if not fine else 400.0)
		app.set_send_level(_send_drag.inst, _send_drag.slot, snappedf(Fader.level_at(travel), 0.1))
		button.accept_event()


## The send menu: for an empty send, the aux tracks (and a new one); for a full one, before or after the fader, on or
## off, another aux, or none.
func show_send_menu(inst, slot: int, near: Control) -> void:
	_send_menu_for = [inst, slot]
	_send_menu.clear()
	var send: Dictionary = inst.sends[slot]
	if not send.is_empty():
		_send_menu.add_check_item("Before the fader (pre)", 1)
		_send_menu.set_item_checked(_send_menu.item_count - 1, send.pre)
		_send_menu.add_check_item("On", 2)
		_send_menu.set_item_checked(_send_menu.item_count - 1, send.on)
		_send_menu.add_separator()
	for i in app.auxes.size():  # (those whose sound doesn't come back to it)
		if (send.is_empty() or app.auxes[i] != send.aux) and app.can_send(inst, app.auxes[i]):
			_send_menu.add_item(("To %s" if not send.is_empty() else "%s") % app.auxes[i].display_name, 100 + i)
	_send_menu.add_item("To a new aux track" if not send.is_empty() else "A new aux track", 3)
	if not send.is_empty():
		_send_menu.add_separator()
		_send_menu.add_item("Remove", 4)
	_send_menu.position = Vector2i(near.get_screen_position() + Vector2(0, near.size.y))
	_send_menu.popup()


func _on_send_menu_chosen(id: int) -> void:
	if _send_menu_for.is_empty() or not app.has_track(_send_menu_for[0]):
		return
	var inst = _send_menu_for[0]
	var slot: int = _send_menu_for[1]
	var send: Dictionary = inst.sends[slot]
	match id:
		1:
			app.set_send(inst, slot, send.aux, send.level_db, not send.pre, send.on)
		2:
			app.set_send(inst, slot, send.aux, send.level_db, send.pre, not send.on)
		3:
			var aux = app.add_aux()
			if aux == null:
				_report("There's no room for another aux track.")
			else:
				app.set_send(inst, slot, aux, send.get("level_db", 0.0), send.get("pre", false), send.get("on", true))
		4:
			app.set_send(inst, slot, null)
		_:
			if id >= 100 and id - 100 < app.auxes.size():
				app.set_send(inst, slot, app.auxes[id - 100], send.get("level_db", 0.0), send.get("pre", false), send.get("on", true))


func _strip_panel(width: float) -> PanelContainer:
	var strip := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = STRIP_BG
	style.set_corner_radius_all(4)
	style.set_border_width_all(1)
	style.border_color = Color(0, 0, 0, 0.6)
	style.content_margin_left = 6
	style.content_margin_right = 6
	style.content_margin_top = 6
	style.content_margin_bottom = 6
	strip.add_theme_stylebox_override("panel", style)
	strip.custom_minimum_size.x = width
	strip.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	strip.add_child(box)
	return strip


## The fader with its meter just to the right, filling the strip's height. `inst` is whose peak a click on the
## meter clears (null: the master's).
func _fader_and_meter(box: VBoxContainer, channels: int, inst) -> Dictionary:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 3)
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.size_flags_vertical = Control.SIZE_EXPAND_FILL
	box.add_child(row)
	var fader := Fader.new()
	fader.size_flags_vertical = Control.SIZE_EXPAND_FILL
	fader.gui_input.connect(_on_fader_area_input.bind(fader))
	var fader_name := "Master fader, after the limiter" if inst == null else ("Room reverb: how much of the room's reverb is heard" \
		if inst is String else "Fader")
	Hints.give(fader, "%s: drag (Shift for fine moves), double-click or Alt-click for 0 dB.  Right-click: pre- or post-fader meters" % fader_name)
	row.add_child(fader)
	var meter := LevelMeter.new()
	meter.vertical = true
	meter.clickable = true
	meter.pressed.connect(_on_peak_pressed.bind(inst))
	meter.gui_input.connect(_on_fader_area_input.bind(meter))
	if inst == null:
		Hints.give(meter, "Output meter: what goes to your speakers.  Click to clear its peak (Alt-click: every peak)")
	elif inst is String:
		Hints.give(meter, "The room reverb's return, after its fader.  Click to clear its peak (Alt-click: every peak)")
	else:
		Hints.give(meter, func() -> String: return "Meter, %s the fader.  Click to clear its peak (Alt-click: every peak).  Right-click: pre or post" % (
			"before" if app.settings.pre_fader_meters else "after"))
	meter.custom_minimum_size = Vector2(8 * channels + 2 * (channels - 1), 60)
	meter.size_flags_vertical = Control.SIZE_EXPAND_FILL
	row.add_child(meter)
	return {"fader": fader, "meter": meter}


## Under the fader, side by side as in Pro Tools: the fader's level, and the peak readout, which holds the highest
## peak until it is clicked.
func _readouts(box: VBoxContainer, inst) -> Dictionary:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 3)
	box.add_child(row)
	var value := Label.new()
	value.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	value.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	value.add_theme_font_size_override("font_size", 12)
	Hints.give(value, "The fader's level")
	row.add_child(value)
	var peak := Button.new()
	peak.focus_mode = Control.FOCUS_NONE
	peak.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	peak.custom_minimum_size = Vector2(0, 20)
	peak.add_theme_font_size_override("font_size", 12)
	Hints.give(peak, func() -> String: return "The highest peak%s since this was clicked.  Click to clear it (Alt-click: every peak)" % (
		"" if inst == null or inst is String else (" before the fader" if app.settings.pre_fader_meters else " after the fader")))
	for state in ["normal", "hover", "pressed", "hover_pressed"]:
		var style := StyleBoxFlat.new()
		style.bg_color = Color(0.03, 0.035, 0.04) if not state.begins_with("hover") else Color(0.08, 0.085, 0.1)
		style.set_corner_radius_all(3)
		style.set_content_margin_all(1)
		peak.add_theme_stylebox_override(state, style)
	peak.gui_input.connect(_on_peak_input.bind(inst))
	row.add_child(peak)
	return {"value": value, "peak": peak}


## The name at the foot of a strip, in the instrument's colour. For an instrument it is a button: click it to open the
## instrument's own window, right-click it to remove the instrument.
func _name_plate(text: String, color: Color, inst) -> Button:
	var plate := Button.new()
	plate.text = text
	plate.focus_mode = Control.FOCUS_NONE
	plate.clip_text = true
	plate.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	plate.add_theme_font_size_override("font_size", 13)
	for state in ["normal", "hover", "pressed", "hover_pressed", "disabled"]:
		var style := StyleBoxFlat.new()
		style.bg_color = color.darkened(0.45 if not state.begins_with("hover") else 0.3)
		style.set_corner_radius_all(3)
		style.set_content_margin_all(3)
		plate.add_theme_stylebox_override(state, style)
	for state in ["font_color", "font_hover_color", "font_pressed_color", "font_disabled_color"]:
		plate.add_theme_color_override(state, color.lightened(0.6))
	if inst == null:
		plate.disabled = true
		plate.mouse_filter = Control.MOUSE_FILTER_IGNORE
	elif inst.is_folder:
		Hints.give(plate, "Click to choose it (Shift or Cmd-click for more).  Right-click to rename it, colour it, its automation, or take it away")
		plate.gui_input.connect(_on_name_input.bind(inst, plate))
	else:
		Hints.give(plate, "Click to open the %s, Shift or Cmd-click to choose it (%s: the chosen in a folder).  Right-click: rename, colour, folder, duplicate, remove" % [
			_editor_name(inst), app.bindings.label("group")])
		plate.gui_input.connect(_on_name_input.bind(inst, plate))
	return plate


## What clicking an instrument's name opens.
func _editor_name(inst) -> String:
	if inst.is_amp:
		return "amp and its pedals"
	return "pattern editor" if inst.playable else "Speaker's panel"


func _small(box: VBoxContainer, text: String) -> void:
	var label := Label.new()
	label.text = text
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", 10)
	label.add_theme_color_override("font_color", DIM)
	box.add_child(label)


## A small square button that lights up in `lit` when on.
func _toggle(text: String, lit: Color) -> Button:
	var button := Button.new()
	button.text = text
	button.toggle_mode = true
	button.focus_mode = Control.FOCUS_NONE
	button.custom_minimum_size = Vector2(26, 24)
	button.add_theme_font_size_override("font_size", 13)
	for state in ["normal", "hover", "pressed", "hover_pressed"]:
		var style := StyleBoxFlat.new()
		var on: bool = state.contains("pressed")
		style.bg_color = lit if on else Color(0.3, 0.31, 0.34)
		if state.begins_with("hover"):
			style.bg_color = style.bg_color.lightened(0.12)
		style.set_corner_radius_all(3)
		style.set_content_margin_all(2)
		button.add_theme_stylebox_override(state, style)
		var ink := Color(0.08, 0.08, 0.09) if on else Color(0.85, 0.86, 0.9)
		button.add_theme_color_override("font_color" if state == "normal" else "font_%s_color" % state, ink)
	return button


# ── Refreshing ──────────────────────────────────────────────────────────────────────────────────────────────

func _refresh() -> void:
	var settings = app.settings
	var signature := ""
	for track in app.track_order():  # (the folders' names, the routing and every track's colour are drawn into strips: change them, build them again)
		var folder = app.folder_of(track)
		signature += "%d:%s:%s:%s|" % [track.get_instance_id(), track.color.to_html(), track.display_name if track.is_folder else "",
			"%d" % folder.get_instance_id() if folder != null else ""]
		for send in track.sends:
			signature += "%d," % send.aux.get_instance_id() if not send.is_empty() else ","
	if signature != _signature:  # tracks came or went, or moved: one strip each again
		_signature = signature
		for child in _strip_row.get_children():
			child.queue_free()
		_strips.clear()
		for track in app.track_order():
			_strips.append(_build_folder_strip(track) if track.is_folder else _build_strip(track))  # (an aux's as a folder's)
		_input_channels = -1
	var channels: int = app.input_channel_count()
	var relist := channels != _input_channels
	_input_channels = channels
	for strip in _strips:
		var inst = strip.inst
		var held: bool = strip.fader._dragging
		if held != strip.get("held", false):  # its fader taken hold of, or let go: Touch and Latch write while it is held
			strip.held = held
			app.automation.touch(inst, held)
		var level: float = inst.level_db if held else app.automation.shown_level(inst)  # (as its automation has it, while that is read)
		if not held:
			strip.fader.set_value_no_signal(level)
		strip.value.text = _db_text(level)
		strip.mute.set_pressed_no_signal(app.automation.shown_mute(inst))
		strip.solo.set_pressed_no_signal(inst.soloed)
		strip.plate.text = inst.display_name  # a plug-in instrument takes its plug-in's name
		strip.frame.border_color = Color(1, 1, 1, 0.85) if app.chosen_tracks.has(inst) else Color(0, 0, 0, 0.6)  # chosen
		strip.meter.feed([inst.meter_peak], [inst.meter_rms])
		_show_peak(strip.peak, inst.peak_hold)
		_show_inserts(strip.inserts, inst.inserts)
		_show_sends(strip)
		if inst.is_folder:
			strip.output.select(strip.output.get_meta("choices").find(app.folder_of(inst)))
		if inst.is_aux:
			var sending: int = (app.instruments + app.folders + app.auxes).filter(func(t): return t.sends.any(func(send): return send.get("aux") == inst)).size()
			strip.source.text = "%d send%s in" % [sending, "" if sending == 1 else "s"]
			continue
		if inst.is_folder:
			strip.source.text = "%d track%s" % [inst.members.size(), "" if inst.members.size() == 1 else "s"]
			continue
		strip.input.set_pressed_no_signal(inst.input_on)
		if inst.plays_plugin:
			strip.source.text = inst.instrument_plugin.get("plugin_name", "")
		if strip.source is OptionButton:
			if relist:
				strip.source.clear()
				strip.source.add_item("All in")
				for i in channels:
					strip.source.add_item("In %d" % (i + 1))
			strip.source.select(clampi(inst.input_channel + 1, 0, strip.source.item_count - 1))
		strip.output.select(strip.output.get_meta("choices").find(app.folder_of(inst)))

	var m: Dictionary = app.meter
	_master.meter.feed([m.get("peak_l", 0.0), m.get("peak_r", 0.0)], [m.get("rms_l", 0.0), m.get("rms_r", 0.0)])
	var master_held: bool = _master.fader._dragging
	if master_held != _master.get("held", false):  # (Touch and Latch write while it is held, as a track's)
		_master.held = master_held
		app.automation.touch(app.master_track, master_held)
	var master_level: float = app.master_volume_db if master_held else app.automation.shown_level(app.master_track)
	if not master_held:
		_master.fader.set_value_no_signal(master_level)
	_master.value.text = _db_text(master_level)
	_show_peak(_master.peak, app.master_peak_hold)
	_reverb.meter.feed([m.get("reverb_peak_l", 0.0), m.get("reverb_peak_r", 0.0)], [m.get("reverb_rms_l", 0.0), m.get("reverb_rms_r", 0.0)])
	if not _reverb.fader._dragging:
		_reverb.fader.set_value_no_signal(app.reverb_db)
	_reverb.value.text = _db_text(app.reverb_db)
	_show_peak(_reverb.peak, app.reverb_peak_hold)
	_master.limiter.set_pressed_no_signal(settings.limiter)
	if Time.get_ticks_msec() < _problem_until:
		pass
	elif app.meter_clipped:
		_status.text = "Clipping"
		_status.add_theme_color_override("font_color", LevelMeter.RED)
		Hints.give(_status, "The output is going over full scale and being cut off: bring the master or an instrument down")
	elif app.meter_reduction_db > 0.1:
		_status.text = "Limiting %.1f dB" % app.meter_reduction_db
		_status.add_theme_color_override("font_color", WARN)
		Hints.give(_status, "The limiter is holding the mix under full scale. It comes before the master fader: bring an instrument down to stop it")
	else:
		_status.text = "Limiter idle" if settings.limiter else "Limiter off"
		_status.add_theme_color_override("font_color", DIM)
		Hints.give(_status, "")


func _db_text(db: float) -> String:
	return "-inf" if db <= Fader.SILENT + 0.05 else "%+.1f" % db


## What each insert holds: empty, a plug-in (blue while bypassed), its border lit while its window is open.
func _show_inserts(slots: Array, inserts: Array) -> void:
	for slot in slots.size():
		var insert: Dictionary = inserts[slot] if slot < inserts.size() else {}
		var name: String = insert.get("plugin_name", "")
		var button: Button = slots[slot].button
		var style: StyleBoxFlat = slots[slot].style
		button.text = name
		if name == "":
			style.bg_color = Color(0.1, 0.105, 0.12)
		elif insert.get("on", true):
			style.bg_color = Color(0.3, 0.32, 0.38)
		else:
			style.bg_color = Color(0.22, 0.36, 0.72)  # bypassed, in Pro Tools' blue
		style.border_color = Color(1, 1, 1, 0.85) if insert.get("editor_open", false) else Color(0, 0, 0, 0.5)
		var ink := Color(0.93, 0.94, 0.97) if name != "" else Color(0.5, 0.52, 0.58)
		for state in ["font_color", "font_hover_color", "font_pressed_color"]:
			button.add_theme_color_override(state, ink)


## A peak readout: the level in dBFS, red once anything has reached full scale.
func _show_peak(button: Button, linear: float) -> void:
	var db := linear_to_db(maxf(linear, 0.0000001))
	button.text = "-inf" if db < -99.0 else "%.1f" % db
	var ink := LevelMeter.RED if db >= -0.05 else (Color(0.85, 0.86, 0.9) if db > -99.0 else Color(0.5, 0.52, 0.58))
	for state in ["font_color", "font_hover_color", "font_pressed_color"]:
		button.add_theme_color_override(state, ink)


# ── Handlers ────────────────────────────────────────────────────────────────────────────────────────────────

func _on_fader_changed(db: float, inst) -> void:
	app.set_instrument_level(inst, db)


func _on_master_changed(db: float) -> void:
	app.set_master_volume_db(db)


## (Option held: every track, as Pro Tools' all-tracks modifier.)
func _on_input_toggled(on: bool, inst) -> void:
	if Input.is_key_pressed(KEY_ALT):
		app.set_on_all("input", on)
	else:
		app.set_input(inst, on)


func _on_mute_toggled(on: bool, inst) -> void:
	if Input.is_key_pressed(KEY_ALT):
		app.set_on_all("mute", on)
	else:
		app.set_muted(inst, on)


func _on_solo_toggled(on: bool, inst) -> void:
	if Input.is_key_pressed(KEY_ALT):
		app.set_on_all("solo", on)
	else:
		app.set_soloed(inst, on)


func _on_source_selected(index: int, inst) -> void:
	app.set_input_channel(inst, index - 1)


func _on_limiter_toggled(on: bool) -> void:
	app.set_limiter(on)


## A click on an insert (on letting go, so that a drag doesn't count): an empty one offers the plug-ins, a full one opens
## or closes its window, or with Cmd (`command`) is bypassed, as in Pro Tools.
func _on_insert_clicked(inst, slot: int, command: bool) -> void:
	var insert: Dictionary = inst.inserts[slot] if slot < inst.inserts.size() else {}
	if insert.get("plugin_name", "") == "":
		_choose_insert(inst, slot, _strip_for(inst).inserts[slot].button)
	elif command:
		app.set_insert_on(inst, slot, not insert.get("on", true))
	else:
		app.show_insert_editor(inst, slot, not insert.get("editor_open", false))


func _insert_hint(inst, slot: int) -> String:
	var insert: Dictionary = inst.inserts[slot] if slot < inst.inserts.size() else {}
	if insert.get("plugin_name", "") == "":
		return "Insert %s: click to choose a plug-in" % char(65 + slot)
	return "Insert %s: %s (%s%s).  Click for its window, Cmd-click to bypass, drag to move (Option: copy), right-click for more" % [
		char(65 + slot), insert.plugin_name, insert.get("plugin_maker", ""), "" if insert.get("on", true) else ", bypassed"]


## Picking an insert up: what it holds, to drop on another slot.
func _insert_drag(_at: Vector2, inst, slot: int):
	var insert: Dictionary = inst.inserts[slot] if slot < inst.inserts.size() else {}
	if insert.get("plugin_name", "") == "":
		return null
	var tag := Label.new()
	tag.text = "  %s  " % insert.plugin_name
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.3, 0.32, 0.38, 0.9)
	style.set_corner_radius_all(3)
	tag.add_theme_stylebox_override("normal", style)
	tag.add_theme_font_size_override("font_size", 11)
	if get_viewport().gui_is_dragging():
		_strip_for(inst).inserts[slot].button.set_drag_preview(tag)
	else:  # asked for outside a drag (the automated checks)
		tag.free()
	return {"insert": true, "inst": inst, "slot": slot}


func _insert_can_drop(_at: Vector2, data, inst, slot: int) -> bool:
	return data is Dictionary and data.get("insert", false) and app.has_track(data.inst) and \
		not (data.inst == inst and data.slot == slot)


func _insert_drop(_at: Vector2, data, inst, slot: int) -> void:
	drop_insert(data, inst, slot, Input.is_key_pressed(KEY_ALT))


## Dropping an insert on a slot: it moves there, swapping with what was there, or with `copy` (Option held) a second of
## it goes there instead, with the same settings.
func drop_insert(data: Dictionary, inst, slot: int, copy: bool) -> void:
	if not app.has_track(data.inst) or not app.has_track(inst):
		return
	if copy:
		var problem: String = app.copy_insert(data.inst, data.slot, inst, slot)
		if problem != "":
			_report("It couldn't be copied: %s." % problem)
	else:
		app.move_insert(data.inst, data.slot, inst, slot)


func _on_insert_input(event: InputEvent, inst, slot: int) -> void:
	if not (event is InputEventMouseButton) or not event.pressed:
		return
	var insert: Dictionary = inst.inserts[slot] if slot < inst.inserts.size() else {}
	var full: bool = insert.get("plugin_name", "") != ""
	var button: Button = _strip_for(inst).inserts[slot].button
	if event.button_index == MOUSE_BUTTON_RIGHT and full:
		_menu_for = [inst, slot]
		_insert_menu.clear()
		_insert_menu.add_item("Close its window" if insert.get("editor_open", false) else "Open its window", 0)
		_insert_menu.add_item("Bypass off" if not insert.get("on", true) else "Bypass", 1)
		_insert_menu.add_item("Replace with…", 2)
		_insert_menu.add_separator()
		_insert_presets.for_plugin(inst, "insert", slot)
		_insert_menu.add_submenu_node_item("Presets", _insert_presets, 4)
		_insert_menu.add_separator()
		_insert_menu.add_item("Remove", 3)
		_insert_menu.position = Vector2i(button.get_screen_position() + Vector2(0, button.size.y))
		_insert_menu.popup()
		button.accept_event()  # only the right-click: a left one is left to the button, which acts when it is let go


func _on_insert_menu_chosen(id: int) -> void:
	if _menu_for.is_empty() or not app.has_track(_menu_for[0]):
		return
	var inst = _menu_for[0]
	var slot: int = _menu_for[1]
	var insert: Dictionary = inst.inserts[slot]
	match id:
		0:
			app.show_insert_editor(inst, slot, not insert.editor_open)
		1:
			app.set_insert_on(inst, slot, not insert.on)
		2:
			_choose_insert(inst, slot, _strip_for(inst).inserts[slot].button)
		3:
			app.clear_insert(inst, slot)


## The plug-in browser, for one insert; what is chosen goes in it, and its window opens.
func _choose_insert(inst, slot: int, near: Control) -> void:
	app.plugin_browser.open_for("Insert %s on the %s" % [char(65 + slot), inst.display_name], app.available_plugins(),
		near.get_screen_position() + Vector2(near.size.x + 6, 0), func(plugin: Dictionary) -> void:
			if not app.has_track(inst):
				return
			var problem: String = app.set_insert(inst, slot, plugin.id)
			if problem != "":
				_report("%s couldn't be loaded: %s." % [plugin.name, problem])
			else:
				app.show_insert_editor(inst, slot, true))


func _on_plugin_input(event: InputEvent, inst, plug: Button) -> void:
	if not (event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_RIGHT):
		return
	_plugin_menu_for = inst
	_plugin_menu.clear()
	_plugin_menu.add_item("Close its window" if inst.instrument_plugin.get("editor_open", false) else "Open its window", 0)
	_plugin_menu.add_item("Replace with…", 1)
	_plugin_presets.for_plugin(inst, "instrument", 0)
	_plugin_menu.add_submenu_node_item("Presets", _plugin_presets, 2)
	_plugin_menu.position = Vector2i(plug.get_screen_position() + Vector2(0, plug.size.y))
	_plugin_menu.popup()
	plug.accept_event()


func _on_plugin_menu_chosen(id: int) -> void:
	var inst = _plugin_menu_for
	if inst == null or not app.instruments.has(inst):
		return
	if id == 0:
		app.show_instrument_editor(inst, not inst.instrument_plugin.get("editor_open", false))
	elif id == 1:
		var near: Control = _strip_for(inst).source
		app.plugin_browser.open_for("Another plug-in for the %s" % inst.display_name, app.available_instrument_plugins(),
			near.get_screen_position() + Vector2(near.size.x + 6, 0), func(plugin: Dictionary) -> void:
				if not app.instruments.has(inst):
					return
				var problem: String = app.set_instrument_plugin(inst, plugin.id)
				if problem != "":
					_report("%s couldn't be loaded: %s." % [plugin.name, problem])
				else:
					app.show_instrument_editor(inst, true))


func _on_name_input(event: InputEvent, inst, plate: Button) -> void:
	if not (event is InputEventMouseButton) or not event.pressed:
		return
	if event.button_index == MOUSE_BUTTON_LEFT:
		if event.shift_pressed:  # choosing tracks, as Pro Tools does by their names
			app.choose_track(inst, "range")
		elif event.meta_pressed or event.ctrl_pressed:
			app.choose_track(inst, "toggle")
		elif inst.is_folder:
			app.choose_track(inst)
		else:
			app.choose_track(inst)
			open_editor(inst)
	elif event.button_index == MOUSE_BUTTON_RIGHT:
		_name_menu_for = inst
		_name_menu.clear()
		if not inst.is_folder:
			_name_menu.add_item("Open the %s" % _editor_name(inst), 0)
			_name_menu.add_item("Duplicate", 2)
			_name_presets.for_instrument(inst)
			_name_menu.add_submenu_node_item("Presets", _name_presets, 3)
			_name_menu.add_separator()
		TrackMenu.add_items(_name_menu, app, inst, _colors, _modes)
		if not inst.is_folder:
			_name_menu.add_separator()
			_name_menu.add_item("Remove the %s from the room…" % inst.display_name, 1)
		_name_menu.reset_size()
		_name_menu.position = Vector2i(plate.get_screen_position() - Vector2(0, _name_menu.get_contents_minimum_size().y))
		_name_menu.popup()
	plate.accept_event()


## An instrument's own window, from its strip: the mix window gives way to it, and comes back when it closes.
func open_editor(inst) -> void:
	if not app.instruments.has(inst):
		return
	close()
	if inst.is_amp:
		app.amp_panel.open(inst, true)
	elif inst.playable:
		app.sequencer.open(inst, -1, true)
	else:
		app.speaker_panel.open(inst, true)


func _on_name_menu_chosen(id: int) -> void:
	var inst = _name_menu_for
	if inst == null or TrackMenu.chosen(app, inst, id) or not app.instruments.has(inst):
		return
	if id == 0:
		open_editor(inst)
	elif id == 2:
		duplicate_instrument(inst)
	elif id == 1:
		_confirm.dialog_text = "Remove the %s from the room? Its pattern, pedals and plug-ins go with it." % inst.display_name
		_confirm.popup_centered()


## A second of an instrument, settings, pedals and plug-ins and all, beside it in the room, its strip next to this one.
func duplicate_instrument(inst) -> void:
	if app.duplicate_instrument(inst) == null:
		_report("The room is full: there's no space for another instrument.")
	elif app.copy_problem != "":
		_report("Not all of it could be copied: %s." % app.copy_problem)


## A problem, or something done, in the status line for a few seconds.
func _report(text: String, problem := true) -> void:
	_status.text = text
	_status.add_theme_color_override("font_color", WARN if problem else Color(0.85, 0.87, 0.92))
	_problem_until = Time.get_ticks_msec() + 5000


## A right-click on a fader or a meter: whether the channel meters read before the fader or after it.
func _on_fader_area_input(event: InputEvent, control: Control) -> void:
	if not (event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_RIGHT):
		return
	_meter_menu.set_item_checked(0, app.settings.pre_fader_meters)
	_meter_menu.set_item_checked(1, not app.settings.pre_fader_meters)
	_meter_menu.position = Vector2i(control.get_screen_position() + event.position)
	_meter_menu.popup()
	control.accept_event()


func _on_remove_confirmed() -> void:
	if _name_menu_for != null and app.instruments.has(_name_menu_for):
		app.remove_instrument(_name_menu_for)
	_name_menu_for = null


func _strip_for(inst) -> Dictionary:
	for strip in _strips:
		if strip.inst == inst:
			return strip
	return {}


func _on_peak_input(event: InputEvent, inst) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		_on_peak_pressed(event.alt_pressed, inst)


## Clears a peak readout (and the held tick on its meter), or with Alt every one of them.
func _on_peak_pressed(alt: bool, inst) -> void:
	if alt:
		app.clear_all_peaks()
		_master.meter.clear_hold()
		_reverb.meter.clear_hold()
		for strip in _strips:
			strip.meter.clear_hold()
		return
	app.clear_peak(inst)
	if inst is String:
		_reverb.meter.clear_hold()
		return
	if inst == null:
		_master.meter.clear_hold()
	for strip in _strips:
		if strip.inst == inst:
			strip.meter.clear_hold()
