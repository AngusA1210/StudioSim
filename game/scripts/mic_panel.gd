extends CanvasLayer
## A microphone's panel (' at it, or its name in the mix window): which model it is and which of its pickup patterns,
## with its frequency response and its pattern drawn; where it stands, to the centimetre (across the room and along
## it, from its middle, and its capsule's height), which way it points (its bearing, clockwise from north, the way you
## first face, and how far down), or straight at an instrument; its gain, before it records, as a preamp's; where its
## track sits in the stereo; and its input monitoring, with a meter of what it hears. Beside them, how far each
## instrument is from it, how late its sound arrives, and how loud it is there, for placing it with care (two mics at
## different distances from one instrument hear it at different times, as real ones do). A stereo pair's panel sets
## up the pair (XY, ORTF, a spaced pair, Blumlein) and places and points the two as one.

const Hints := preload("res://scripts/hints.gd")
const LevelMeter := preload("res://scripts/level_meter.gd")
const PanControl := preload("res://scripts/pan_control.gd")
const MicGraph := preload("res://scripts/mic_graph.gd")
const Catalog := preload("res://scripts/catalog.gd")
const DIM := Color(0.62, 0.65, 0.74)
const SPEED_OF_SOUND := 343.0  # metres a second, as the audio core has it
const REF_DISTANCE := 1.5      # where an instrument is heard at the level it was made at
const NEAREST := 0.1           # and no louder for coming closer than this

var app
var inst = null
var _close_button: Button
var _root: Control
var _panel: PanelContainer
var _title: Label
var _x: SpinBox
var _z: SpinBox
var _height: SpinBox
var _bearing: SpinBox
var _tilt: SpinBox
var _aim_at: OptionButton
var _aim_choices := []  # the instruments the Point at menu offers, in its order (after its first item)
var _gain: SpinBox
var _model: OptionButton
var _pattern: OptionButton
var _patterns_shown := []  # the pattern names its menu offers, in its order
var _about: Label
var _graph
var _pan
var _pair_row: HBoxContainer
var _technique: OptionButton
var _spacing: SpinBox
var _spacing_label: Label
var _input_switch: CheckButton
var _meter
var _distances: GridContainer
var _hint: Label
var _back_to_mixer := false


func setup(the_app) -> void:
	app = the_app
	layer = 9
	_build()
	_root.visible = false


func is_open() -> bool:
	return _root.visible


func open(mic, from_mixer := false) -> void:
	_close_button.text = "Close  (%s)" % app.bindings.label("edit")
	inst = mic
	_back_to_mixer = from_mixer
	app.player.release_keys()
	_root.visible = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_title.text = inst.display_name
	_title.add_theme_color_override("font_color", inst.color.lightened(0.3))
	var half: Vector3 = app.room.size / 2.0
	_x.min_value = -half.x
	_x.max_value = half.x
	_z.min_value = -half.z
	_z.max_value = half.z
	_height.max_value = app.room.size.y - 0.05
	_aim_at.clear()
	_aim_at.add_item("Point it at…" if inst.pair_partner == null else "Point the pair at…")
	_aim_choices = app.instruments.filter(func(other): return other != inst and not other.is_mic)
	for other in _aim_choices:
		_aim_at.add_item(other.display_name)
	_model.clear()
	for info in app.mic_models():
		_model.add_item(str(info.name))
	_graph.app = app
	_patterns_shown = []
	_refresh()


func close() -> void:
	_root.visible = false
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	if _back_to_mixer:
		_back_to_mixer = false
		app.mixer.open()


func _input(event: InputEvent) -> void:
	if not is_open() or not (event is InputEventKey) or not event.pressed or event.echo or app.name_prompt.is_open():
		return
	if get_viewport().gui_get_focus_owner() is LineEdit and event.physical_keycode != KEY_ESCAPE:
		return  # (typing a number)
	var action: String = "edit" if event.physical_keycode == KEY_ESCAPE else app.bindings.action_for(event.physical_keycode)
	if action in ["edit", "mixer"]:
		var to_mixer: bool = action == "mixer"
		close()
		if to_mixer and not app.mixer.is_open():
			app.mixer.open()
		get_viewport().set_input_as_handled()


func _process(_delta: float) -> void:
	if not is_open():
		return
	if not app.instruments.has(inst):
		close()
		return
	_refresh()
	_hint.text = Hints.under_mouse(_panel)


func _refresh() -> void:
	var centre: Vector3 = app.rig_centre(inst)
	_show(_x, centre.x)
	_show(_z, centre.z)
	_show(_height, inst.source_height)
	_show(_bearing, app.mic_bearing(inst))
	_show(_tilt, inst.mic_tilt)
	_show(_gain, inst.mic_gain_db)
	var models: Array = app.mic_models()
	var which: int = models.map(func(m): return m.id).find(inst.mic_model)
	_model.select(which)
	var info: Dictionary = models[which] if which >= 0 else {}
	var names: Array = info.get("patterns", []).map(func(p): return p.name)
	if names != _patterns_shown:  # its model's patterns
		_patterns_shown = names
		_pattern.clear()
		for name in names:
			_pattern.add_item(Catalog.MIC_PATTERNS.get(name, name))
	var pattern: String = app.mic_pattern_of(inst)
	_pattern.select(names.find(pattern))
	_pattern.disabled = names.size() < 2
	_about.text = "%s  Sensitivity %+.0f dB against the measurement mic." % [info.get("about", ""), float(info.get("sensitivity_db", 0.0))]
	var patterns: Array = info.get("patterns", [])
	_graph.ink = inst.color.lightened(0.2)
	_graph.show_mic(inst.mic_model, patterns[maxi(names.find(pattern), 0)] if not patterns.is_empty() else {})
	if not _pan._dragging:
		_pan.set_value_no_signal(inst.mic_pan)
	_pair_row.visible = inst.pair_partner != null
	if inst.pair_partner != null:
		_technique.select(Catalog.MIC_PAIR_ORDER.find(inst.pair_technique))
		var spaced: bool = inst.pair_technique == "ab"
		_spacing.visible = spaced
		_spacing_label.visible = spaced
		_show(_spacing, inst.pair_spacing)
	_input_switch.set_pressed_no_signal(inst.input_on)
	_input_switch.text = "Hearing it" if inst.input_on else "Hear it"
	var level: float = app.audio.get_source_level(inst.source_id, true)
	_meter.feed([level * sqrt(2.0)], [level])
	_show_distances(distances(inst, app.instruments))


## Each instrument's distance from a microphone in a straight line (round a wall it is further), how late its sound
## arrives, and how loud it is there against its level at 1.5 m: [{name, metres, ms, db}], the nearest first.
static func distances(mic, instruments: Array) -> Array:
	var out := []
	for other in instruments:
		if other == mic or other.is_mic:
			continue
		var metres: float = other.global_position.distance_to(mic.global_position)
		out.append({"name": other.display_name, "metres": metres, "ms": 1000.0 * metres / SPEED_OF_SOUND,
			"db": 20.0 * log(REF_DISTANCE / maxf(metres, NEAREST)) / log(10.0)})
	out.sort_custom(func(a, b): return a.metres < b.metres)
	return out


## The table of distances: a row for each instrument, its name, then its numbers lined up on the right.
func _show_distances(rows: Array) -> void:
	var cells: Array = []
	for row in rows:
		cells.append_array([row.name, "%.2f m" % row.metres, "%.1f ms" % row.ms, "%+.1f dB" % row.db])
	while _distances.get_child_count() > cells.size():
		var last := _distances.get_child(_distances.get_child_count() - 1)
		_distances.remove_child(last)
		last.queue_free()
	while _distances.get_child_count() < cells.size():
		var cell := Label.new()
		cell.add_theme_font_size_override("font_size", 13)
		cell.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT if _distances.get_child_count() % 4 == 0 else HORIZONTAL_ALIGNMENT_RIGHT
		cell.mouse_filter = Control.MOUSE_FILTER_PASS
		_distances.add_child(cell)
	for i in cells.size():
		_distances.get_child(i).text = cells[i]


## What the table says, as lines (for the checks).
func distances_text() -> String:
	var lines := []
	for i in range(0, _distances.get_child_count(), 4):
		lines.append("   ".join(range(4).map(func(k): return _distances.get_child(i + k).text)))
	return "\n".join(lines)


func _show(box: SpinBox, value: float) -> void:
	if not box.get_line_edit().has_focus():
		box.set_value_no_signal(value)


func _number(grid: GridContainer, title: String, low: float, high: float, step: float, suffix: String, hint: String, changed: Callable) -> SpinBox:
	var label := Label.new()
	label.text = title
	label.add_theme_color_override("font_color", DIM)
	grid.add_child(label)
	var box := SpinBox.new()
	box.min_value = low
	box.max_value = high
	box.step = step
	box.suffix = suffix
	box.custom_minimum_size.x = 130
	box.select_all_on_focus = true
	box.value_changed.connect(func(value: float) -> void:
		if inst != null and app.instruments.has(inst):
			changed.call(value))
	Hints.give(box, hint)
	grid.add_child(box)
	return box


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
	_panel.custom_minimum_size.x = 640
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
	_model = OptionButton.new()
	_model.item_selected.connect(func(index: int) -> void:
		var models: Array = app.mic_models()
		if index >= 0 and index < models.size():
			app.set_mic_model(inst, str(models[index].id), app.mic_pattern_of(inst)))
	Hints.give(_model, "Which microphone it is: each has its own pickup pattern, frequency response and sensitivity")
	header.add_child(_model)
	_pattern = OptionButton.new()
	_pattern.item_selected.connect(func(index: int) -> void:
		if index >= 0 and index < _patterns_shown.size():
			app.set_mic_model(inst, inst.mic_model, _patterns_shown[index]))
	Hints.give(_pattern, "Its pickup pattern, if it can be switched: omni hears all round alike, cardioid little from behind, figure-8 front and back (the back in reverse polarity) and nothing from the sides")
	header.add_child(_pattern)
	var gap := Control.new()
	gap.custom_minimum_size.x = 14
	header.add_child(gap)
	_close_button = Button.new()
	_close_button.pressed.connect(close)
	header.add_child(_close_button)

	_about = Label.new()
	_about.add_theme_color_override("font_color", DIM)
	_about.add_theme_font_size_override("font_size", 13)
	_about.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(_about)
	_graph = MicGraph.new()
	Hints.give(_graph, "Its frequency response on axis, 20 Hz to 20 kHz (±15 dB), and its pickup pattern from above, its front up: the middle band bright, the lows and highs fainter; dashed, a lobe in reverse polarity. Close up, a directional mic gains bass too (the proximity effect)")
	box.add_child(_graph)
	_pair_row = HBoxContainer.new()
	_pair_row.add_theme_constant_override("separation", 10)
	box.add_child(_pair_row)
	var pair_label := Label.new()
	pair_label.text = "Stereo pair"
	pair_label.add_theme_color_override("font_color", DIM)
	_pair_row.add_child(pair_label)
	_technique = OptionButton.new()
	for technique in Catalog.MIC_PAIR_ORDER:
		_technique.add_item(Catalog.MIC_PAIRS[technique].name)
	_technique.item_selected.connect(func(index: int) -> void: app.set_pair_technique(inst, Catalog.MIC_PAIR_ORDER[index]))
	Hints.give(_technique, func() -> String: return "How the pair is set up: %s" % (
		Catalog.MIC_PAIRS.get(inst.pair_technique, {}).get("about", "") if inst != null else ""))
	_pair_row.add_child(_technique)
	_spacing_label = Label.new()
	_spacing_label.text = "apart by"
	_spacing_label.add_theme_color_override("font_color", DIM)
	_pair_row.add_child(_spacing_label)
	_spacing = SpinBox.new()
	_spacing.min_value = 0.1
	_spacing.max_value = 3.0
	_spacing.step = 0.01
	_spacing.suffix = " m"
	_spacing.select_all_on_focus = true
	_spacing.value_changed.connect(func(v: float) -> void:
		if inst != null and app.instruments.has(inst):
			app.set_pair_spacing(inst, v))
	Hints.give(_spacing, "How far apart a spaced pair's mics are: further, a wider image (and a hole in the middle, past a metre or so)")
	_pair_row.add_child(_spacing)

	var columns := HBoxContainer.new()
	columns.add_theme_constant_override("separation", 26)
	box.add_child(columns)
	var left := VBoxContainer.new()
	left.add_theme_constant_override("separation", 10)
	columns.add_child(left)
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 12)
	grid.add_theme_constant_override("v_separation", 6)
	left.add_child(grid)
	_x = _number(grid, "Across", -10.0, 10.0, 0.01, " m", "Where it stands across the room, from its middle: to the east (right on the floor plan) is more",
		func(v: float) -> void: app.set_mic_spot(inst, v, app.rig_centre(inst).z))
	_z = _number(grid, "Along", -10.0, 10.0, 0.01, " m", "Where it stands along the room, from its middle: to the south (towards you as you first face) is more",
		func(v: float) -> void: app.set_mic_spot(inst, app.rig_centre(inst).x, v))
	_height = _number(grid, "Height", 0.05, 3.0, 0.01, " m", "How high its capsule is, where it hears from (over a kick drum's hole, low; over the kit, high)",
		func(v: float) -> void: app.set_mic_height(inst, v))
	_bearing = _number(grid, "Points to", 0.0, 359.0, 1.0, "°", "Which way it points, clockwise from north (the way you first face): 90 is east. An omni mic hears all round alike, so this is for its stand, for now",
		func(v: float) -> void: app.set_mic_bearing(inst, v))
	_tilt = _number(grid, "Down by", -90.0, 90.0, 1.0, "°", "How far it points down (90: straight down, as an overhead)",
		func(v: float) -> void: app.set_mic_tilt(inst, v))
	_gain = _number(grid, "Gain", -20.0, 40.0, 0.5, " dB", "Its gain, before it records, as a preamp's: up for a mic far off, down for one right up against something loud",
		func(v: float) -> void: app.set_mic_gain(inst, v))
	var pan_label := Label.new()
	pan_label.text = "Pan"
	pan_label.add_theme_color_override("font_color", DIM)
	grid.add_child(pan_label)
	_pan = PanControl.new()
	_pan.custom_minimum_size = Vector2(130, 22)
	_pan.value_changed.connect(func(v: float) -> void:
		if inst != null and app.instruments.has(inst):
			app.set_mic_pan(inst, v))
	Hints.give(_pan, "Where its track sits in the stereo: drag (Shift: fine), double-click for the middle. A stereo pair's are hard left and right")
	grid.add_child(_pan)
	_aim_at = OptionButton.new()
	_aim_at.item_selected.connect(func(index: int) -> void:
		if index > 0 and index - 1 < _aim_choices.size() and app.instruments.has(_aim_choices[index - 1]):
			app.aim_mic(inst, _aim_choices[index - 1])
		_aim_at.select(0))
	Hints.give(_aim_at, "Turns it and tilts it to point straight at an instrument (at where its sound comes from)")
	left.add_child(_aim_at)
	var input_row := HBoxContainer.new()
	input_row.add_theme_constant_override("separation", 10)
	left.add_child(input_row)
	_input_switch = CheckButton.new()
	_input_switch.toggled.connect(func(on: bool) -> void: app.set_input(inst, on))
	Hints.give(_input_switch, "Its input monitoring: hear what it hears (through its track, in the middle of the stereo), rather than what it recorded")
	input_row.add_child(_input_switch)
	_meter = LevelMeter.new()
	_meter.custom_minimum_size = Vector2(150, 12)
	_meter.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	Hints.give(_meter, "What it hears, after its gain: what it records")
	input_row.add_child(_meter)

	var right := VBoxContainer.new()
	right.add_theme_constant_override("separation", 6)
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	columns.add_child(right)
	var heading := Label.new()
	heading.text = "FROM IT"
	heading.add_theme_font_size_override("font_size", 12)
	heading.add_theme_color_override("font_color", DIM)
	right.add_child(heading)
	_distances = GridContainer.new()
	_distances.columns = 4
	_distances.add_theme_constant_override("h_separation", 16)
	_distances.add_theme_constant_override("v_separation", 2)
	Hints.give(_distances, "How far each instrument is, in a straight line (round a wall it is further), how late its sound arrives, and how loud it is here against 1.5 m away")
	right.add_child(_distances)
	_hint = Hints.line()
	box.add_child(_hint)
