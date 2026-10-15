extends CanvasLayer
## The mix window (Tab), laid out like a mixing desk: a channel strip for every instrument side by side, the master
## strip on the right. A strip has the instrument's input at the top (which hardware input, for a Speaker), buttons
## for input, mute and solo, a fader with its meter beside it, and the instrument's name in its colour at the foot.
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
const OUTPUT_TRIM := 0.88  # roughly what the engine multiplies an instrument by on its way out, for the strip meters

var app
var audio: SoundRoomAudio

var _root: Control
var _panel: PanelContainer
var _strip_row: HBoxContainer
var _strips: Array = []  # {inst, fader, meter, value, input, mute, solo, source}
var _signature := ""
var _input_channels := -1
var _master := {}
var _falloff: HSlider
var _falloff_value: Label
var _status: Label


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


func close() -> void:
	_root.visible = false
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _input(event: InputEvent) -> void:
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
	var falloff_label := Label.new()
	falloff_label.text = "Distance falloff"
	falloff_label.add_theme_color_override("font_color", DIM)
	header.add_child(falloff_label)
	_falloff = HSlider.new()
	_falloff.min_value = 0.0
	_falloff.max_value = 6.0
	_falloff.step = 0.5
	_falloff.custom_minimum_size.x = 120
	_falloff.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_falloff.tooltip_text = "How much quieter an instrument gets for each doubling of distance beyond 1.5 m. 6 dB is the inverse square law."
	_falloff.value_changed.connect(_on_falloff_changed)
	header.add_child(_falloff)
	_falloff_value = Label.new()
	_falloff_value.custom_minimum_size.x = 150
	header.add_child(_falloff_value)
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

	var hint := Label.new()
	hint.text = "Drag a fader (Shift for fine moves), or double-click it for 0 dB.   I  input on: the keyboard plays it, or a Speaker plays its input.   M  mute.   S  solo."
	hint.add_theme_font_size_override("font_size", 12)
	hint.add_theme_color_override("font_color", DIM)
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(hint)


func _build_master() -> PanelContainer:
	var strip := _strip_panel(STRIP_WIDTH + 14)
	var box: VBoxContainer = strip.get_child(0)
	_small(box, "OUTPUT")
	var limiter := _toggle("LIMIT", Color(0.55, 0.78, 1.0))
	limiter.tooltip_text = "On: the output can't go over full scale. Off: the plain sum of the mix, cut off at full scale."
	limiter.toggled.connect(_on_limiter_toggled)
	limiter.custom_minimum_size = Vector2(76, 24)
	limiter.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	box.add_child(limiter)
	var gap := Control.new()
	gap.custom_minimum_size.y = 24
	box.add_child(gap)
	var pair := _fader_and_meter(box, 2)
	pair.fader.value_changed.connect(_on_master_changed)
	var value := _value_label(box)
	box.add_child(_name_plate("Master", Color(0.75, 0.77, 0.82)))
	_master = {"fader": pair.fader, "meter": pair.meter, "value": value, "limiter": limiter}
	return strip


## A strip for one instrument.
func _build_strip(inst) -> Dictionary:
	var strip := _strip_panel(STRIP_WIDTH)
	var box: VBoxContainer = strip.get_child(0)
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
	var pair := _fader_and_meter(box, 1)
	pair.fader.value_changed.connect(_on_fader_changed.bind(inst))
	var value := _value_label(box)
	box.add_child(_name_plate(inst.display_name, inst.color))
	_strip_row.add_child(strip)
	return {"inst": inst, "fader": pair.fader, "meter": pair.meter, "value": value, "input": input, "mute": mute, "solo": solo,
		"source": source}


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


## The fader with its meter just to the right, filling the strip's height.
func _fader_and_meter(box: VBoxContainer, channels: int) -> Dictionary:
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
	meter.custom_minimum_size = Vector2(8 * channels + 2 * (channels - 1), 60)
	meter.size_flags_vertical = Control.SIZE_EXPAND_FILL
	row.add_child(meter)
	return {"fader": fader, "meter": meter}


func _value_label(box: VBoxContainer) -> Label:
	var value := Label.new()
	value.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	value.add_theme_font_size_override("font_size", 13)
	box.add_child(value)
	return value


func _name_plate(text: String, color: Color) -> PanelContainer:
	var plate := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = color.darkened(0.45)
	style.set_corner_radius_all(3)
	style.set_content_margin_all(3)
	plate.add_theme_stylebox_override("panel", style)
	var label := Label.new()
	label.text = text
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.clip_text = true
	label.add_theme_font_size_override("font_size", 13)
	label.add_theme_color_override("font_color", color.lightened(0.6))
	plate.add_child(label)
	return plate


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
	var out := OUTPUT_TRIM * db_to_linear(settings.master_volume_db)
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
		strip.meter.feed([audio.get_source_level(inst.source_id) * out])

	var m: Dictionary = app.meter
	_master.meter.feed([m.get("peak_l", 0.0), m.get("peak_r", 0.0)], [m.get("rms_l", 0.0), m.get("rms_r", 0.0)])
	if not _master.fader._dragging:
		_master.fader.set_value_no_signal(settings.master_volume_db)
	_master.value.text = _db_text(settings.master_volume_db)
	_master.limiter.set_pressed_no_signal(settings.limiter)
	_falloff.set_value_no_signal(settings.distance_falloff_db)
	_falloff_value.text = "%.1f dB per doubling" % settings.distance_falloff_db
	var peak := "Peak %.1f dBFS" % _master.meter.held_db()
	if app.meter_clipped:
		_status.text = "%s   ·   Clipping: the mix is going over full scale. Bring the master or an instrument down." % peak
		_status.add_theme_color_override("font_color", LevelMeter.RED)
	elif app.meter_reduction_db > 0.1:
		_status.text = "%s   ·   Limiting by %.1f dB. Bring the master or an instrument down to stop it." % [peak, app.meter_reduction_db]
		_status.add_theme_color_override("font_color", WARN)
	else:
		_status.text = "%s   ·   %s" % [peak, "Limiter idle" if settings.limiter else "No clipping"]
		_status.add_theme_color_override("font_color", DIM)


func _db_text(db: float) -> String:
	return "-inf" if db <= Fader.SILENT + 0.05 else "%+.1f" % db


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


func _on_falloff_changed(db: float) -> void:
	app.set_distance_falloff(db)
