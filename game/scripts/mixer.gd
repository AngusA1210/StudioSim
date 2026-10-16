extends CanvasLayer
## The mix window (Tab), laid out like a mixing desk: a channel strip for every instrument side by side, the master
## strip on the right. A strip has its inserts at the top, then the instrument's input (which hardware input, for a
## Speaker or an amp), buttons for input, mute and solo, a fader with its meter beside it, the fader's level and the
## highest peak beneath them, and the instrument's name in its colour at the foot.
## The inserts work as Pro Tools' do: click an empty one to choose a plug-in (its window opens), click a full one to
## open or close its window, Cmd-click (Ctrl-click) to bypass it, and right-click for the rest. A bypassed insert is
## blue. They play on the instrument's sound in order, before its fader.
## Click a strip's name to open the instrument's own window (an amp's panel and pedals, a pattern, a Speaker's panel),
## right-click it to remove the instrument from the room. You can walk about while the window is open. As in Pro Tools, the peak readout holds the highest peak
## until it is clicked (Alt-click clears them all), and clicking a meter does the same.
## It docks along the bottom of the screen so the room stays in view, and the music keeps playing.

const Fader := preload("res://scripts/fader.gd")
const LevelMeter := preload("res://scripts/level_meter.gd")

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
var _strips: Array = []  # {inst, fader, meter, value, peak, input, mute, solo, source, inserts: [{button, style}], plate}
var _insert_menu: PopupMenu  # what a right-click on a full insert offers
var _menu_for := []  # [instrument, slot] that menu is open for
var _name_menu: PopupMenu  # what a right-click on a strip's name offers
var _name_menu_for = null
var _confirm: ConfirmationDialog  # removing an instrument
var _pre_fader: CheckButton
var _signature := ""
var _input_channels := -1
var _master := {}
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
	app.plugin_browser.hide()
	for inst in app.instruments:
		app.hide_insert_editors(inst)
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _input(event: InputEvent) -> void:
	if app.plugin_browser.visible:  # the keys are for its search box
		return
	if is_open() and event is InputEventKey and event.pressed and not event.echo and event.physical_keycode in [KEY_TAB, KEY_ESCAPE]:
		close()
		get_viewport().set_input_as_handled()


func _process(_delta: float) -> void:
	if not is_open():
		return
	var vp := get_viewport().get_visible_rect().size
	var height := minf(520.0, vp.y - 60.0)
	_panel.position = Vector2(12, vp.y - height - 12)
	_panel.size = Vector2(vp.x - 24, height)
	_refresh()


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
	_pre_fader = CheckButton.new()
	_pre_fader.text = "Pre-fader meters"
	_pre_fader.focus_mode = Control.FOCUS_NONE
	_pre_fader.tooltip_text = "The channel meters show the signal before the fader (after the inserts), as Pro Tools' pre-fader metering does."
	_pre_fader.toggled.connect(func(on: bool) -> void: app.set_pre_fader_meters(on))
	header.add_child(_pre_fader)
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
	desk.add_child(_build_master())

	_insert_menu = PopupMenu.new()
	_insert_menu.id_pressed.connect(_on_insert_menu_chosen)
	_root.add_child(_insert_menu)
	_name_menu = PopupMenu.new()
	_name_menu.id_pressed.connect(_on_name_menu_chosen)
	_root.add_child(_name_menu)
	_confirm = ConfirmationDialog.new()
	_confirm.ok_button_text = "Remove"
	_confirm.confirmed.connect(_on_remove_confirmed)
	_root.add_child(_confirm)

	var hint := Label.new()
	hint.text = "Inserts: click an empty one for a plug-in, a full one for its window, Cmd-click to bypass it (blue), right-click for more.   Drag a fader (Shift for fine moves), or double-click or Alt-click it for 0 dB. Under each fader: its level, and the highest peak since you last clicked it (Alt-click clears them all).   I  input on: the keyboard plays it, or a Speaker or amp plays its input.   M  mute.   S  solo."
	hint.add_theme_font_size_override("font_size", 12)
	hint.add_theme_color_override("font_color", DIM)
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(hint)


func _build_master() -> PanelContainer:
	var strip := _strip_panel(STRIP_WIDTH + 14)
	var box: VBoxContainer = strip.get_child(0)
	var level_with_inserts := Control.new()  # so the faders line up with the instruments'
	level_with_inserts.custom_minimum_size.y = _inserts_height()
	box.add_child(level_with_inserts)
	_small(box, "OUTPUT")
	var limiter := _toggle("LIMIT", Color(0.55, 0.78, 1.0))
	limiter.tooltip_text = "On: the mix can't go over full scale on its way into the master fader. Off: the plain sum of the mix. Either way, what leaves the master fader over full scale is cut off."
	limiter.toggled.connect(_on_limiter_toggled)
	limiter.custom_minimum_size = Vector2(76, 24)
	limiter.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	box.add_child(limiter)
	var gap := Control.new()
	gap.custom_minimum_size.y = 24
	box.add_child(gap)
	var pair := _fader_and_meter(box, 2, null)
	pair.fader.value_changed.connect(_on_master_changed)
	var readouts := _readouts(box, null)
	box.add_child(_name_plate("Master", Color(0.75, 0.77, 0.82), null))
	_master = {"fader": pair.fader, "meter": pair.meter, "value": readouts.value, "peak": readouts.peak, "limiter": limiter}
	return strip


## A strip for one instrument.
func _build_strip(inst) -> Dictionary:
	var strip := _strip_panel(STRIP_WIDTH)
	var box: VBoxContainer = strip.get_child(0)
	var inserts := _build_inserts(box, inst)
	_small(box, "INPUT")
	var source: Control
	if inst.playable:
		var midi := Label.new()
		midi.text = "MIDI"
		midi.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		midi.custom_minimum_size.y = 24
		midi.add_theme_font_size_override("font_size", 13)
		source = midi
	else:
		var choice := OptionButton.new()
		choice.add_theme_font_size_override("font_size", 12)
		choice.fit_to_longest_item = false
		choice.custom_minimum_size = Vector2(STRIP_WIDTH - 16, 24)
		choice.item_selected.connect(_on_source_selected.bind(inst))
		source = choice
	box.add_child(source)
	var buttons := HBoxContainer.new()
	buttons.add_theme_constant_override("separation", 3)
	buttons.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_child(buttons)
	var input := _toggle("I", INPUT_GREEN)
	input.tooltip_text = "Input: the MIDI keyboard plays it" if inst.playable else "Input: it plays the hardware input chosen above"
	input.toggled.connect(_on_input_toggled.bind(inst))
	buttons.add_child(input)
	var mute := _toggle("M", MUTE_ORANGE)
	mute.tooltip_text = "Mute"
	mute.toggled.connect(_on_mute_toggled.bind(inst))
	buttons.add_child(mute)
	var solo := _toggle("S", SOLO_YELLOW)
	solo.tooltip_text = "Solo: while anything is soloed, everything else is silent"
	solo.toggled.connect(_on_solo_toggled.bind(inst))
	buttons.add_child(solo)
	var pair := _fader_and_meter(box, 1, inst)
	pair.fader.value_changed.connect(_on_fader_changed.bind(inst))
	var readouts := _readouts(box, inst)
	var plate := _name_plate(inst.display_name, inst.color, inst)
	box.add_child(plate)
	_strip_row.add_child(strip)
	return {"inst": inst, "fader": pair.fader, "meter": pair.meter, "value": readouts.value, "peak": readouts.peak, "input": input,
		"mute": mute, "solo": solo, "source": source, "inserts": inserts, "plate": plate}


const INSERT_HEIGHT := 19.0


func _inserts_height() -> float:
	return 14.0 + 6.0 + audio.get_max_inserts() * (INSERT_HEIGHT + 2.0)


## A strip's insert slots, A to E as in Pro Tools.
func _build_inserts(box: VBoxContainer, inst) -> Array:
	_small(box, "INSERTS")
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 2)
	box.add_child(column)
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
		button.gui_input.connect(_on_insert_input.bind(inst, slot))
		column.add_child(button)
		slots.append({"button": button, "style": style})
	return slots


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
	row.add_child(fader)
	var meter := LevelMeter.new()
	meter.vertical = true
	meter.clickable = true
	meter.tooltip_text = "Click to clear the peak (Alt-click: every peak)"
	meter.pressed.connect(_on_peak_pressed.bind(inst))
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
	value.tooltip_text = "The fader's level"
	row.add_child(value)
	var peak := Button.new()
	peak.focus_mode = Control.FOCUS_NONE
	peak.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	peak.custom_minimum_size = Vector2(0, 20)
	peak.add_theme_font_size_override("font_size", 12)
	peak.tooltip_text = "The highest peak since this was last clicked. Click to clear it (Alt-click: every peak)."
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
	else:
		plate.tooltip_text = "Click to open the %s; right-click to remove it" % _editor_name(inst)
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
	for inst in app.instruments:
		signature += "%d|" % inst.get_instance_id()
	if signature != _signature:  # instruments came or went: one strip each again
		_signature = signature
		for child in _strip_row.get_children():
			child.queue_free()
		_strips.clear()
		for inst in app.instruments:
			_strips.append(_build_strip(inst))
		_input_channels = -1
	var channels: int = app.input_channel_count()
	var relist := channels != _input_channels
	_input_channels = channels
	for strip in _strips:
		var inst = strip.inst
		if not strip.fader._dragging:
			strip.fader.set_value_no_signal(inst.level_db)
		strip.value.text = _db_text(inst.level_db)
		strip.input.set_pressed_no_signal(inst.input_on)
		strip.mute.set_pressed_no_signal(inst.muted)
		strip.solo.set_pressed_no_signal(inst.soloed)
		if strip.source is OptionButton:
			if relist:
				strip.source.clear()
				strip.source.add_item("All in")
				for i in channels:
					strip.source.add_item("In %d" % (i + 1))
			strip.source.select(clampi(inst.input_channel + 1, 0, strip.source.item_count - 1))
		strip.meter.feed([inst.meter_peak], [inst.meter_rms])
		_show_peak(strip.peak, inst.peak_hold)
		_show_inserts(strip.inserts, inst.inserts)

	var m: Dictionary = app.meter
	_master.meter.feed([m.get("peak_l", 0.0), m.get("peak_r", 0.0)], [m.get("rms_l", 0.0), m.get("rms_r", 0.0)])
	if not _master.fader._dragging:
		_master.fader.set_value_no_signal(settings.master_volume_db)
	_master.value.text = _db_text(settings.master_volume_db)
	_show_peak(_master.peak, app.master_peak_hold)
	_master.limiter.set_pressed_no_signal(settings.limiter)
	_pre_fader.set_pressed_no_signal(settings.pre_fader_meters)
	if Time.get_ticks_msec() < _problem_until:
		pass
	elif app.meter_clipped:
		_status.text = "Clipping: the output is going over full scale. Bring the master or an instrument down."
		_status.add_theme_color_override("font_color", LevelMeter.RED)
	elif app.meter_reduction_db > 0.1:
		_status.text = "Limiting by %.1f dB. Bring an instrument down to stop it (the limiter comes before the master fader)." % app.meter_reduction_db
		_status.add_theme_color_override("font_color", WARN)
	else:
		_status.text = "Limiter idle" if settings.limiter else "Limiter off  ·  no clipping"
		_status.add_theme_color_override("font_color", DIM)


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
		button.tooltip_text = ("Insert %s: %s (%s). Click for its window, Cmd-click to bypass, right-click for more." % [
			char(65 + slot), name, insert.get("plugin_maker", "")]) if name != "" else "Insert %s: click to choose a plug-in" % char(65 + slot)
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


func _on_input_toggled(on: bool, inst) -> void:
	app.set_input(inst, on)


func _on_mute_toggled(on: bool, inst) -> void:
	app.set_muted(inst, on)


func _on_solo_toggled(on: bool, inst) -> void:
	app.set_soloed(inst, on)


func _on_source_selected(index: int, inst) -> void:
	app.set_input_channel(inst, index - 1)


func _on_limiter_toggled(on: bool) -> void:
	app.set_limiter(on)


func _on_insert_input(event: InputEvent, inst, slot: int) -> void:
	if not (event is InputEventMouseButton) or not event.pressed:
		return
	var insert: Dictionary = inst.inserts[slot] if slot < inst.inserts.size() else {}
	var full: bool = insert.get("plugin_name", "") != ""
	var button: Button = _strip_for(inst).inserts[slot].button
	if event.button_index == MOUSE_BUTTON_LEFT:
		if not full:
			_choose_insert(inst, slot, button)
		elif event.meta_pressed or event.ctrl_pressed:  # Cmd-click bypasses, as in Pro Tools
			app.set_insert_on(inst, slot, not insert.get("on", true))
		else:
			app.show_insert_editor(inst, slot, not insert.get("editor_open", false))
	elif event.button_index == MOUSE_BUTTON_RIGHT and full:
		_menu_for = [inst, slot]
		_insert_menu.clear()
		_insert_menu.add_item("Close its window" if insert.get("editor_open", false) else "Open its window", 0)
		_insert_menu.add_item("Bypass off" if not insert.get("on", true) else "Bypass", 1)
		_insert_menu.add_item("Replace with…", 2)
		_insert_menu.add_separator()
		_insert_menu.add_item("Remove", 3)
		_insert_menu.position = Vector2i(button.get_screen_position() + Vector2(0, button.size.y))
		_insert_menu.popup()
	button.accept_event()


func _on_insert_menu_chosen(id: int) -> void:
	if _menu_for.is_empty() or not app.instruments.has(_menu_for[0]):
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
			if not app.instruments.has(inst):
				return
			var problem: String = app.set_insert(inst, slot, plugin.id)
			if problem != "":
				_status.text = "%s couldn't be loaded: %s." % [plugin.name, problem]
				_status.add_theme_color_override("font_color", WARN)
				_problem_until = Time.get_ticks_msec() + 5000
			else:
				app.show_insert_editor(inst, slot, true))


func _on_name_input(event: InputEvent, inst, plate: Button) -> void:
	if not (event is InputEventMouseButton) or not event.pressed:
		return
	if event.button_index == MOUSE_BUTTON_LEFT:
		open_editor(inst)
	elif event.button_index == MOUSE_BUTTON_RIGHT:
		_name_menu_for = inst
		_name_menu.clear()
		_name_menu.add_item("Open the %s" % _editor_name(inst), 0)
		_name_menu.add_separator()
		_name_menu.add_item("Remove the %s from the room…" % inst.display_name, 1)
		_name_menu.position = Vector2i(plate.get_screen_position() - Vector2(0, 70))
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
	if inst == null or not app.instruments.has(inst):
		return
	if id == 0:
		open_editor(inst)
	else:
		_confirm.dialog_text = "Remove the %s from the room? Its pattern, pedals and plug-ins go with it." % inst.display_name
		_confirm.popup_centered()


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
		for strip in _strips:
			strip.meter.clear_hold()
		return
	app.clear_peak(inst)
	if inst == null:
		_master.meter.clear_hold()
	for strip in _strips:
		if strip.inst == inst:
			strip.meter.clear_hold()
