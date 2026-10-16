extends CanvasLayer
## A Speaker's panel (Enter at a Speaker, or its name in the mix window): which hardware input it plays, its input
## switch, and its own volume, as on the back of a powered PA speaker. The volume goes up to +24 dB, so that a Speaker
## can fill a big room as a big PA would; it comes after the Speaker's inserts (an amp simulator on one keeps its
## sound whatever the volume) and before its fader.

const Knob := preload("res://scripts/knob.gd")
const DIM := Color(0.62, 0.65, 0.74)
const MAX_DB := 24.0

var app
var inst = null

var _root: Control
var _panel: PanelContainer
var _title: Label
var _volume: Knob
var _input_switch: CheckButton
var _source: OptionButton
var _inserts: Label
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
	inst = speaker
	_back_to_mixer = from_mixer
	app.player.release_keys()
	_root.visible = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_title.text = inst.display_name
	_title.add_theme_color_override("font_color", inst.color.lightened(0.3))
	_source.clear()
	_source.add_item("All inputs")
	for i in app.input_channel_count():
		_source.add_item("Input %d" % (i + 1))
	_refresh()


func close() -> void:
	_root.visible = false
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	if _back_to_mixer:
		_back_to_mixer = false
		app.mixer.open()


func _input(event: InputEvent) -> void:
	if is_open() and event is InputEventKey and event.pressed and not event.echo and \
			event.physical_keycode in [KEY_ESCAPE, KEY_ENTER, KEY_KP_ENTER, KEY_TAB]:
		var to_mixer: bool = event.physical_keycode == KEY_TAB
		close()
		if to_mixer and not app.mixer.is_open():
			app.mixer.open()
		get_viewport().set_input_as_handled()


func _process(_delta: float) -> void:
	if is_open():
		_refresh()


func _refresh() -> void:
	if not _volume._dragging:
		_volume.set_value_no_signal(knob_for(inst.volume_db))
	_volume.readout = "off" if inst.volume_db <= -79.0 else "%+.1f dB" % inst.volume_db
	_volume.queue_redraw()
	_input_switch.set_pressed_no_signal(inst.input_on)
	_input_switch.text = "Input on" if inst.input_on else "Input off"
	_source.select(clampi(inst.input_channel + 1, 0, _source.item_count - 1))
	var names := []
	for insert in inst.inserts:
		if insert.plugin_name != "":
			names.append(insert.plugin_name + ("" if insert.on else " (bypassed)"))
	_inserts.text = "Inserts: " + (", ".join(names) if not names.is_empty() else "none. An amp simulator goes on one (Tab, then the strip's first insert); the Speaker then sounds as that amp.")


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
	_panel.custom_minimum_size.x = 560
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

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 18)
	box.add_child(row)
	_volume = Knob.new()
	_volume.title = "VOLUME"
	_volume.value_changed.connect(func(value: float) -> void: app.set_speaker_volume(inst, db_for(value)))
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
	input_row.add_child(_input_switch)
	_source = OptionButton.new()
	_source.item_selected.connect(func(index: int) -> void: app.set_input_channel(inst, index - 1))
	input_row.add_child(_source)
	var note := Label.new()
	note.text = "Its own level in the room, as on a powered speaker: 5 plays the input as it comes in, 10 is +24 dB, enough to fill a big room. Close up, the limiter catches it."
	note.add_theme_color_override("font_color", DIM)
	note.add_theme_font_size_override("font_size", 13)
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(note)
	_inserts = Label.new()
	_inserts.add_theme_color_override("font_color", DIM)
	_inserts.add_theme_font_size_override("font_size", 13)
	_inserts.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(_inserts)
