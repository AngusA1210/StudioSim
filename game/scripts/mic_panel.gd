extends CanvasLayer
## A microphone's panel (' at it, or its name in the mix window): where it stands, to the centimetre (across the room
## and along it, from its middle, and its capsule's height), which way it points (its bearing, clockwise from north,
## the way you first face, and how far down), or straight at an instrument; its gain, before it records, as a
## preamp's; and its input monitoring, with a meter of what it hears. Beside them, how far each instrument is from it,
## how late its sound arrives, and how loud it is there, for placing it with care (two mics at different distances
## from one instrument hear it at different times, as real ones do).

const Hints := preload("res://scripts/hints.gd")
const LevelMeter := preload("res://scripts/level_meter.gd")
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
	_aim_at.add_item("Point it at…")
	_aim_choices = app.instruments.filter(func(other): return other != inst and not other.is_mic)
	for other in _aim_choices:
		_aim_at.add_item(other.display_name)
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
	_show(_x, inst.global_position.x)
	_show(_z, inst.global_position.z)
	_show(_height, inst.source_height)
	_show(_bearing, app.mic_bearing(inst))
	_show(_tilt, inst.mic_tilt)
	_show(_gain, inst.mic_gain_db)
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
	var model := Label.new()
	model.text = "Flat (measurement), omni"
	model.add_theme_color_override("font_color", DIM)
	Hints.give(model, "A measurement microphone: flat from the lowest lows to the highest highs, and hearing all round alike. Dynamic, condenser and ribbon microphones are on the way")
	header.add_child(model)
	var gap := Control.new()
	gap.custom_minimum_size.x = 14
	header.add_child(gap)
	_close_button = Button.new()
	_close_button.pressed.connect(close)
	header.add_child(_close_button)

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
		func(v: float) -> void: app.set_mic_spot(inst, v, inst.global_position.z))
	_z = _number(grid, "Along", -10.0, 10.0, 0.01, " m", "Where it stands along the room, from its middle: to the south (towards you as you first face) is more",
		func(v: float) -> void: app.set_mic_spot(inst, inst.global_position.x, v))
	_height = _number(grid, "Height", 0.05, 3.0, 0.01, " m", "How high its capsule is, where it hears from (over a kick drum's hole, low; over the kit, high)",
		func(v: float) -> void: app.set_mic_height(inst, v))
	_bearing = _number(grid, "Points to", 0.0, 359.0, 1.0, "°", "Which way it points, clockwise from north (the way you first face): 90 is east. An omni mic hears all round alike, so this is for its stand, for now",
		func(v: float) -> void: app.set_mic_bearing(inst, v))
	_tilt = _number(grid, "Down by", -90.0, 90.0, 1.0, "°", "How far it points down (90: straight down, as an overhead)",
		func(v: float) -> void: app.set_mic_tilt(inst, v))
	_gain = _number(grid, "Gain", -20.0, 40.0, 0.5, " dB", "Its gain, before it records, as a preamp's: up for a mic far off, down for one right up against something loud",
		func(v: float) -> void: app.set_mic_gain(inst, v))
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
