extends CanvasLayer
## An amp's panel (Enter at an amp): its head and cabinet, its knobs and input, and the board of pedals on the floor
## in front of it. Any head goes with any cabinet, and either can be bypassed: without its head, the amp plays what
## reaches it straight through the cabinet (a plug-in amp on a Plug-in pedal can be the head); without its cabinet it
## is a flat full-range speaker.
##
## The board runs the way the signal does: from the input through the pedals in order, then the amp. Click a pedal to
## set it up underneath; drag it along the line to move it (hold Option as you drop it for a second of it instead);
## "+ Pedal" adds one at the end. The board folds away under its heading. 1 to 8 stamp on the pedals, here and facing
## the amp in the room: a pedal switches on or off, and the loop pedal (an amp can have one) presses its footswitch.
## The loop pedal works as a loop pedal does: one footswitch records, closes the loop, and lays overdubs on top; there
## are Stop, Undo and Clear beside it, a level for the loop, and Sync, which starts and ends recordings on bar lines
## while the patterns are running. L, O, U and J (as bound) do the same as its buttons, here and in the room.
## What each part does is said in the line at the foot of the panel, while the mouse is over it.

const Knob := preload("res://scripts/knob.gd")
const Catalog := preload("res://scripts/catalog.gd")
const Hints := preload("res://scripts/hints.gd")
const DIM := Color(0.62, 0.65, 0.74)
const WARN := Color(1.0, 0.61, 0.48)
const LED_ON := Color(1.0, 0.27, 0.22)
const LED_OFF := Color(0.18, 0.08, 0.08)
const IN_TUNE := Color(0.4, 0.9, 0.5)
const OUT_OF_TUNE := Color(1.0, 0.75, 0.3)
const DROP_MARK := Color(0.55, 0.78, 1.0)
const KNOB_NAMES := {"gain": "GAIN", "bass": "BASS", "mid": "MIDDLE", "treble": "TREBLE", "presence": "PRESENCE", "master": "MASTER"}
# What each state looks like on the loop pedal's display, and what the footswitch does next.
const STATES := {
	"empty": ["EMPTY", Color(0.6, 0.62, 0.68), "Record"],
	"waiting": ["WAITING FOR THE BAR", Color(1.0, 0.75, 0.3), "Cancel"],
	"recording": ["● RECORDING", Color(1.0, 0.35, 0.32), "Close the loop"],
	"playing": ["▶ PLAYING", Color(0.4, 0.9, 0.5), "Overdub"],
	"overdubbing": ["● OVERDUBBING", Color(1.0, 0.62, 0.25), "Stop overdubbing"],
	"stopped": ["■ STOPPED", Color(0.6, 0.62, 0.68), "Play"],
}
const NUMBER_KEYS := [KEY_1, KEY_2, KEY_3, KEY_4, KEY_5, KEY_6, KEY_7, KEY_8]

var app
var audio: SoundRoomAudio
var inst = null
var selected := -1  # the pedal being set up under the board; -1 for none
var _back_to_mixer := false  # opened from the mix window, which comes back when this closes

var _root: Control
var _panel: PanelContainer
var _title: Label
var _faceplate: StyleBoxFlat
var _knobs := {}
var _head_choice: OptionButton
var _head_on: CheckButton
var _cabinet_choice: OptionButton
var _cabinet_on: CheckButton
var _input_switch: CheckButton
var _source: OptionButton
var _hint: Label  # the line at the foot: what the mouse is over, or a problem for a few seconds
var _problem := ""
var _problem_until := 0

# The board
var _board_toggle: Button  # its heading, which folds it away and brings it back
var _board_summary: Label  # how many pedals, while it is folded
var _board_body: VBoxContainer
var _board: HBoxContainer
var _tiles: Array = []  # a pedal's tile: {panel, style, led}
var _add_button: Button
var _add_arrow: Label
var _add_menu: PopupMenu
var _board_signature := "-"  # what the board was built for ("-": nothing yet)
var _drop_mark: ColorRect  # while a pedal is dragged: the gap it would go in

# Under the board: nothing chosen, the loop pedal, or another pedal; and what can be done to whichever it is
var _empty_page: Label
var _loop_page: Control
var _pedal_page: VBoxContainer
var _pedal_title: Label
var _pedal_controls: HBoxContainer
var _controls: Array = []  # one per control: {node (a Knob or a CheckButton), readout}
var _shown := ""  # the pedal the controls were made for: its place and kind
var _footer: HBoxContainer
var _pedal_switch: Button
var _remove: Button
var _remove_armed_until := 0
var _tuner_box: VBoxContainer
var _tuner_note: Label
var _tuner_cents: Label
var _tuner_needle: ColorRect
var _tuner_scale: Control
var _plugin_box: VBoxContainer
var _plugin_status: Label
var _plugin_window: Button
var _plugin_choose: Button
var _plugin_error: Label

# The loop pedal
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


func open(amp, from_mixer := false) -> void:
	_back_to_mixer = from_mixer
	if inst != amp:
		selected = 0 if not amp.pedals.is_empty() else -1
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
	_board_signature = "-"
	_shown = ""
	_refresh()


## Closing the panel puts away any plug-in windows it opened: in the room the mouse looks around rather than pointing.
func close() -> void:
	_root.visible = false
	_add_menu.hide()
	app.plugin_browser.hide()
	if inst != null:
		app.hide_plugin_editors(inst)
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	if _back_to_mixer:
		_back_to_mixer = false
		app.mixer.open()


func has_looper() -> bool:
	return inst != null and inst.looper.get("state", "none") != "none"


func _input(event: InputEvent) -> void:
	if not is_open() or not (event is InputEventKey) or not event.pressed or event.echo:
		return
	if app.plugin_browser.visible:  # the keys are for its search box
		return
	var handled := true
	var key: int = event.physical_keycode
	var action: String = "edit" if key == KEY_ESCAPE else app.bindings.action_for(key)
	match action:
		"edit":
			close()
		"mixer":
			close()
			if not app.mixer.is_open():
				app.mixer.open()
		_:
			var loop_keys := {"loop_switch": _on_footswitch, "loop_stop": _on_stop, "loop_undo": _on_undo, "loop_clear": _on_clear}
			if loop_keys.has(action):
				handled = has_looper()
				if handled:
					loop_keys[action].call()
			else:
				handled = NUMBER_KEYS.has(key) and NUMBER_KEYS.find(key) < inst.pedals.size()
				if handled:
					app.stomp(inst, NUMBER_KEYS.find(key))
	if handled:
		get_viewport().set_input_as_handled()


func _process(_delta: float) -> void:
	if not is_open():
		return
	var vp := get_viewport().get_visible_rect().size
	_panel.custom_minimum_size = Vector2(minf(1080.0, vp.x - 32.0), 0.0)
	_refresh()
	var problem := Time.get_ticks_msec() < _problem_until
	_hint.text = _problem if problem else Hints.under_mouse(_panel)
	_hint.add_theme_color_override("font_color", WARN if problem else DIM)


func _refresh() -> void:
	for control in _knobs:
		if not _knobs[control]._dragging:
			_knobs[control].set_value_no_signal(inst.amp_controls[control])
		_knobs[control].modulate.a = 1.0 if inst.head_on or control == "master" else 0.35  # the head's knobs, bypassed with it
	_head_choice.select(_index_of(Catalog.AMP_HEADS, inst.amp_head))
	_cabinet_choice.select(_index_of(Catalog.AMP_CABINETS, inst.amp_cabinet))
	_head_on.set_pressed_no_signal(inst.head_on)
	_head_on.text = "In use" if inst.head_on else "Bypassed"
	_cabinet_on.set_pressed_no_signal(inst.cabinet_on)
	_cabinet_on.text = "In use" if inst.cabinet_on else "Bypassed"
	_input_switch.set_pressed_no_signal(inst.input_on)
	_input_switch.text = "Input on" if inst.input_on else "Input off"
	_source.select(clampi(inst.input_channel + 1, 0, _source.item_count - 1))
	selected = mini(selected, inst.pedals.size() - 1)
	var unfolded: bool = app.settings.pedalboard_open
	_board_toggle.text = ("▾  " if unfolded else "▸  ") + "Pedalboard"
	_board_body.visible = unfolded
	_board_summary.visible = not unfolded
	var lit: int = inst.pedals.filter(func(p: Dictionary) -> bool: return p.on and p.kind != "looper").size()
	_board_summary.text = "no pedals" if inst.pedals.is_empty() else "%d pedal%s, %d on" % [inst.pedals.size(),
		"" if inst.pedals.size() == 1 else "s", lit]
	_refresh_board()
	var kind: String = inst.pedals[selected].kind if selected >= 0 else ""
	_empty_page.visible = selected < 0
	_loop_page.visible = kind == "looper"
	_pedal_page.visible = kind != "" and kind != "looper"
	_footer.visible = selected >= 0
	if kind == "looper":
		_refresh_loop()
	elif kind != "":
		_refresh_pedal()
	if selected >= 0:
		_refresh_footer()


# ── The board ───────────────────────────────────────────────────────────────────────────────────────────────

func _refresh_board() -> void:
	var signature := ""
	for p in inst.pedals:
		signature += "%s:%s|" % [p.kind, p.plugin_name]
	if signature != _board_signature:
		_board_signature = signature
		_build_board()
	for i in _tiles.size():
		var tile: Dictionary = _tiles[i]
		var pedal: Dictionary = inst.pedals[i]
		if pedal.kind == "looper":  # its light shows what the loop is doing
			var state: String = inst.looper.get("state", "empty")
			tile.led.color = STATES.get(state, STATES.empty)[1] if state != "empty" else LED_OFF
		else:
			tile.led.color = LED_ON if pedal.on else LED_OFF
		tile.style.border_color = Color.WHITE if i == selected else Color(0, 0, 0, 0.6)
	if not get_viewport().gui_is_dragging() or not _board.get_global_rect().grow(8.0).has_point(_board.get_global_mouse_position()):
		_drop_mark.visible = false
	_add_button.visible = inst.pedals.size() < audio.get_max_pedals()
	_add_arrow.visible = _add_button.visible
	_add_menu.set_item_disabled(Catalog.PEDAL_ORDER.find("looper"), has_looper())


func _build_board() -> void:
	for child in _board.get_children():
		_board.remove_child(child)
		child.queue_free()
	_tiles.clear()
	_board.add_child(_end_label("INPUT"))
	for i in inst.pedals.size():
		var pedal: Dictionary = inst.pedals[i]
		var spec: Dictionary = Catalog.PEDALS[pedal.kind]
		var name: String = spec.name if pedal.kind != "plugin" or pedal.plugin_name == "" else pedal.plugin_name
		_board.add_child(_arrow())
		var tile := _tile(str(i + 1), name, spec.color, i)
		_board.add_child(tile.panel)
		_tiles.append(tile)
	_board.add_child(_arrow())
	_add_button = Button.new()
	_add_button.text = "+ Pedal"
	_add_button.custom_minimum_size = Vector2(80, 86)
	Hints.give(_add_button, "Add a pedal at the end of the line, just before the amp: a tuner, drives, modulation, delay and reverb, a loop pedal, or one of your plug-ins")
	_add_button.pressed.connect(_on_add_pressed)
	_add_button.set_drag_forwarding(Callable(), _pedal_can_drop, _pedal_drop)
	_board.add_child(_add_button)
	_add_arrow = _arrow()
	_board.add_child(_add_arrow)
	_board.add_child(_end_label("AMP"))


## A pedal on the board: its number (its key), its light, and its name, painted in its colour. `index` is where it
## stands, or -1 for the picture of one being dragged.
func _tile(number: String, name: String, color: Color, index: int) -> Dictionary:
	var panel := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = color.darkened(0.1)
	style.set_corner_radius_all(6)
	style.set_border_width_all(2)
	style.set_content_margin_all(6)
	panel.add_theme_stylebox_override("panel", style)
	panel.custom_minimum_size = Vector2(82, 86)
	panel.mouse_filter = Control.MOUSE_FILTER_STOP
	if index >= 0:  # not the picture of one being dragged
		panel.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		panel.gui_input.connect(_on_tile_input.bind(index))
		panel.set_drag_forwarding(_pedal_drag.bind(index), _pedal_can_drop, _pedal_drop)
		Hints.give(panel, _tile_hint.bind(index))
	var ink := Color(0.08, 0.08, 0.1) if color.get_luminance() > 0.45 else Color(0.95, 0.95, 0.97)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 4)
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(box)
	var top := HBoxContainer.new()
	top.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(top)
	var key := Label.new()
	key.text = number
	key.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	key.add_theme_font_size_override("font_size", 11)
	key.add_theme_color_override("font_color", Color(ink, 0.7))
	top.add_child(key)
	var led := ColorRect.new()
	led.custom_minimum_size = Vector2(10, 10)
	led.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	led.mouse_filter = Control.MOUSE_FILTER_IGNORE
	top.add_child(led)
	var label := Label.new()
	label.text = name
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.size_flags_vertical = Control.SIZE_EXPAND_FILL
	label.custom_minimum_size.x = 70
	label.add_theme_font_size_override("font_size", 11)
	label.add_theme_color_override("font_color", ink)
	box.add_child(label)
	return {"panel": panel, "style": style, "led": led, "label": label}


func _arrow() -> Label:
	var arrow := Label.new()
	arrow.text = "›"
	arrow.add_theme_color_override("font_color", DIM)
	arrow.add_theme_font_size_override("font_size", 20)
	arrow.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	return arrow


func _end_label(text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_color_override("font_color", DIM)
	label.add_theme_font_size_override("font_size", 11)
	label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	return label


func _tile_hint(index: int) -> String:
	if inst == null or index >= inst.pedals.size():
		return ""
	var pedal: Dictionary = inst.pedals[index]
	var spec: Dictionary = Catalog.PEDALS[pedal.kind]
	var name: String = pedal.plugin_name if pedal.kind == "plugin" and pedal.plugin_name != "" else spec.name
	return "%s: %s  Click to set it up, %d to stamp on it, drag to move it (Option: a copy)." % [name, spec.about, index + 1]


# Dragging pedals along the board: picked up from a tile, dropped in the gap nearest the mouse, anywhere on the board.

func _pedal_drag(_at: Vector2, index: int):
	if inst == null or index >= inst.pedals.size():
		return null
	var pedal: Dictionary = inst.pedals[index]
	var spec: Dictionary = Catalog.PEDALS[pedal.kind]
	if get_viewport().gui_is_dragging():
		var tag := _tile("", spec.name if pedal.kind != "plugin" or pedal.plugin_name == "" else pedal.plugin_name, spec.color, -1)
		tag.panel.modulate.a = 0.8
		_tiles[index].panel.set_drag_preview(tag.panel)
	return {"pedal": true, "inst": inst, "index": index}


func _pedal_can_drop(_at: Vector2, data) -> bool:
	if not (data is Dictionary and data.get("pedal", false) and data.inst == inst):
		return false
	var slot := gap_at(_board.get_global_mouse_position().x)
	var x: float
	if slot < _tiles.size():
		x = _tiles[slot].panel.get_global_rect().position.x - 6.0
	elif _add_button.visible:
		x = _add_button.get_global_rect().position.x - 6.0
	else:
		x = _tiles[-1].panel.get_global_rect().end.x + 2.0
	var top: Rect2 = _tiles[0].panel.get_global_rect() if not _tiles.is_empty() else _add_button.get_global_rect()
	_drop_mark.global_position = Vector2(x, top.position.y)
	_drop_mark.size = Vector2(4, top.size.y)
	_drop_mark.visible = true
	return true


func _pedal_drop(_at: Vector2, data) -> void:
	_drop_mark.visible = false
	drop_pedal(data, gap_at(_board.get_global_mouse_position().x), Input.is_key_pressed(KEY_ALT))


## The gap along the board nearest `x` (on screen): 0 before the first pedal, up to the number of pedals after the last.
func gap_at(x: float) -> int:
	for i in _tiles.size():
		if x < _tiles[i].panel.get_global_rect().get_center().x:
			return i
	return _tiles.size()


## Dropping a pedal in a gap on the board: it moves there, or with `copy` (Option held as it is dropped) a second of it
## goes there, its knobs, switch and plug-in settings and all.
func drop_pedal(data: Dictionary, gap: int, copy: bool) -> void:
	if inst == null or data.get("inst") != inst or data.index >= inst.pedals.size():
		return
	if copy:
		var at: int = app.copy_pedal(inst, data.index, inst, gap)
		if at < 0:
			_show_problem("It couldn't be copied: %s." % audio.get_error())
		else:
			selected = at
	else:
		var to: int = gap - 1 if gap > data.index else gap
		if to != data.index and app.move_pedal(inst, data.index, to):
			selected = to
	_shown = ""
	_refresh()


func _show_problem(text: String) -> void:
	_problem = text
	_problem_until = Time.get_ticks_msec() + 4000


# ── A pedal ─────────────────────────────────────────────────────────────────────────────────────────────────

func _refresh_pedal() -> void:
	var pedal: Dictionary = inst.pedals[selected]
	var spec: Dictionary = Catalog.PEDALS[pedal.kind]
	var shown := "%d:%s" % [selected, pedal.kind]
	if shown != _shown:
		_shown = shown
		_build_controls(pedal.kind)
		_pedal_title.text = spec.name
		_pedal_title.add_theme_color_override("font_color", spec.color.lightened(0.25))
		Hints.give(_pedal_title, spec.about)
		_plugin_error.text = ""
	for i in _controls.size():
		var control: Dictionary = _controls[i]
		var value: float = pedal.controls[i]
		if control.node is CheckButton:
			control.node.set_pressed_no_signal(value > 0.5)
		else:
			if not control.node._dragging:
				control.node.set_value_no_signal(value)
			control.node.readout = Catalog.pedal_readout(control.readout, control.node.value, pedal.controls)
			control.node.queue_redraw()
	_tuner_box.visible = pedal.kind == "tuner"
	if pedal.kind == "tuner":
		_show_tuner(pedal.on)
	_plugin_box.visible = pedal.kind == "plugin"
	if pedal.kind == "plugin":
		var has_plugin: bool = pedal.plugin_name != ""
		_plugin_status.text = ("%s   ·   %s" % [pedal.plugin_name, pedal.plugin_maker]) if has_plugin else "No plug-in yet."
		_plugin_window.visible = has_plugin
		_plugin_window.text = "Close its window" if pedal.editor_open else "Open its window"
		_plugin_choose.text = "Choose another…" if has_plugin else "Choose a plug-in…"


## The footswitch (not for the loop pedal, whose footswitch is its own), and taking it off the board.
func _refresh_footer() -> void:
	var pedal: Dictionary = inst.pedals[selected]
	_pedal_switch.visible = pedal.kind != "looper"
	_pedal_switch.text = ("On   (%d)" if pedal.on else "Bypassed   (%d)") % (selected + 1)
	_pedal_switch.set_pressed_no_signal(pedal.on)
	var armed := Time.get_ticks_msec() < _remove_armed_until
	_remove.text = "Press again: the loop goes too" if armed else "Take off the board"


## The controls for a kind of pedal: a knob for each of its knobs, a switch for each switch.
func _build_controls(kind: String) -> void:
	for child in _pedal_controls.get_children():
		_pedal_controls.remove_child(child)
		child.queue_free()
	_controls.clear()
	var switches := VBoxContainer.new()
	switches.alignment = BoxContainer.ALIGNMENT_CENTER
	for i in Catalog.PEDALS[kind].controls.size():
		var spec: Array = Catalog.PEDALS[kind].controls[i]
		if spec[1] == "switch":
			var toggle := CheckButton.new()
			toggle.text = spec[0].capitalize()
			toggle.toggled.connect(_on_pedal_switch_toggled.bind(i))
			switches.add_child(toggle)
			_controls.append({"node": toggle, "readout": "switch"})
		else:
			var knob := Knob.new()
			knob.title = spec[0]
			knob.resting = spec[2]  # where a double-click puts it back
			knob.custom_minimum_size = Vector2(80, 82)
			knob.value_changed.connect(_on_pedal_knob_changed.bind(i))
			_pedal_controls.add_child(knob)
			_controls.append({"node": knob, "readout": spec[1]})
	if switches.get_child_count() > 0:
		_pedal_controls.add_child(switches)
	else:
		switches.free()


func _show_tuner(listening: bool) -> void:
	var reading: Dictionary = inst.tuner
	if not listening or not reading.get("pitched", false):
		_tuner_note.text = "-"
		_tuner_cents.text = "Play a string" if listening else "Switch it on (%d) to tune" % (selected + 1)
		_tuner_note.add_theme_color_override("font_color", DIM)
		_tuner_needle.visible = false
		return
	var cents: float = reading.cents
	var ink := IN_TUNE if absf(cents) < 3.0 else OUT_OF_TUNE
	_tuner_note.text = Catalog.note_name(reading.note)
	_tuner_note.add_theme_color_override("font_color", ink)
	_tuner_cents.text = "%+.0f cents   ·   %.1f Hz" % [cents, reading.frequency]
	_tuner_needle.visible = true
	_tuner_needle.color = ink
	_tuner_needle.position.x = (_tuner_scale.size.x - _tuner_needle.size.x) * (0.5 + clampf(cents, -50.0, 50.0) / 100.0)


# ── The loop pedal ──────────────────────────────────────────────────────────────────────────────────────────

func _refresh_loop() -> void:
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
	var keys = app.bindings
	_footswitch.text = "%s   (%s or %d)" % [look[2], keys.label("loop_switch"), selected + 1]
	_stop.text = ("Play   (%s)" if state == "stopped" else "Stop   (%s)") % keys.label("loop_stop")
	_stop.disabled = state in ["empty", "waiting"]
	_undo.text = ("Redo   (%s)" if loop.get("can_redo", false) and not loop.get("can_undo", false) else "Undo   (%s)") % keys.label("loop_undo")
	_undo.disabled = not (loop.get("can_undo", false) or loop.get("can_redo", false))
	var armed := Time.get_ticks_msec() < _clear_armed_until
	_clear.text = "Press again to clear" if armed else "Clear   (%s)" % keys.label("loop_clear")
	_clear.disabled = state in ["empty", "waiting"]
	var controls: Array = inst.pedals[selected].controls
	if not _level._dragging:
		_level.set_value_no_signal(controls[0])
	_level.readout = Catalog.pedal_readout("level", _level.value)
	_level.queue_redraw()
	_sync.set_pressed_no_signal(controls[1] > 0.5)
	_after.select(1 if controls[2] > 0.5 else 0)


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
	style.set_content_margin_all(16)
	_panel.add_theme_stylebox_override("panel", style)
	center.add_child(_panel)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 10)
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

	# The head and the cabinet, each with its switch.
	var voice := HBoxContainer.new()
	voice.add_theme_constant_override("separation", 10)
	box.add_child(voice)
	_head_choice = _voice_row(voice, "HEAD", Catalog.AMP_HEADS)
	Hints.give(_head_choice, func() -> String: return "Head: " + Catalog.AMP_HEADS[_head_choice.selected][2])
	_head_on = CheckButton.new()
	Hints.give(_head_on, "Bypassed, the head passes what reaches it straight to the cabinet, so a plug-in amp on a Plug-in pedal can be the head")
	voice.add_child(_head_on)
	var gap := Control.new()
	gap.custom_minimum_size.x = 18
	voice.add_child(gap)
	_cabinet_choice = _voice_row(voice, "CABINET", Catalog.AMP_CABINETS)
	Hints.give(_cabinet_choice, func() -> String: return "Cabinet: %s As it sounds in the room, without a microphone's colour." % (
		Catalog.AMP_CABINETS[_cabinet_choice.selected][2]))
	_cabinet_on = CheckButton.new()
	Hints.give(_cabinet_on, "Bypassed, the cabinet is a flat, full-range speaker: for a plug-in amp that brings its own cabinet")
	voice.add_child(_cabinet_on)
	_head_choice.item_selected.connect(func(_i: int) -> void: _set_voice())
	_cabinet_choice.item_selected.connect(func(_i: int) -> void: _set_voice())
	_head_on.toggled.connect(func(_on: bool) -> void: _set_voice())
	_cabinet_on.toggled.connect(func(_on: bool) -> void: _set_voice())

	# The amp's own panel: black, edged in its colour, with a row of knobs.
	var plate := PanelContainer.new()
	_faceplate = StyleBoxFlat.new()
	_faceplate.bg_color = Color(0.05, 0.05, 0.06)
	_faceplate.set_corner_radius_all(6)
	_faceplate.set_border_width_all(2)
	_faceplate.set_content_margin_all(8)
	plate.add_theme_stylebox_override("panel", _faceplate)
	box.add_child(plate)
	var knobs := HBoxContainer.new()
	knobs.alignment = BoxContainer.ALIGNMENT_CENTER
	knobs.add_theme_constant_override("separation", 18)
	plate.add_child(knobs)
	Hints.give(plate, "Drag a knob up or down (Shift for fine moves), or double-click it to put it back")
	for control in Catalog.AMP_CONTROLS:
		var knob := Knob.new()
		knob.title = KNOB_NAMES[control]
		knob.value_changed.connect(_on_knob_changed.bind(control))
		if control != "master":
			Hints.give(knob, func() -> String: return "" if inst == null or inst.head_on else "The head is bypassed: only Master is in use")
		knobs.add_child(knob)
		_knobs[control] = knob

	var input_row := HBoxContainer.new()
	input_row.add_theme_constant_override("separation", 12)
	box.add_child(input_row)
	_input_switch = CheckButton.new()
	_input_switch.toggled.connect(_on_input_toggled)
	Hints.give(_input_switch, "Input on: the amp plays what is plugged into your interface. Wear headphones")
	input_row.add_child(_input_switch)
	_source = OptionButton.new()
	_source.item_selected.connect(_on_source_selected)
	Hints.give(_source, "Which of your interface's inputs the guitar or bass is plugged into")
	input_row.add_child(_source)

	# The pedalboard, in the order the signal passes along it, under a heading that folds it away.
	var board_heading := HBoxContainer.new()
	board_heading.add_theme_constant_override("separation", 10)
	box.add_child(board_heading)
	_board_toggle = Button.new()
	_board_toggle.flat = true
	_board_toggle.focus_mode = Control.FOCUS_NONE
	_board_toggle.add_theme_font_size_override("font_size", 18)
	_board_toggle.pressed.connect(func() -> void: app.set_pedalboard_open(not app.settings.pedalboard_open))
	Hints.give(_board_toggle, "Fold the pedalboard away, or bring it back. 1-8 stamp on the pedals either way")
	board_heading.add_child(_board_toggle)
	_board_summary = Label.new()
	_board_summary.add_theme_color_override("font_color", DIM)
	_board_summary.add_theme_font_size_override("font_size", 13)
	_board_summary.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	board_heading.add_child(_board_summary)
	_board_body = VBoxContainer.new()
	_board_body.add_theme_constant_override("separation", 10)
	box.add_child(_board_body)
	var floor_panel := PanelContainer.new()
	var floor_style := StyleBoxFlat.new()
	floor_style.bg_color = Color(0.11, 0.115, 0.13)
	floor_style.set_corner_radius_all(8)
	floor_style.set_content_margin_all(8)
	floor_panel.add_theme_stylebox_override("panel", floor_style)
	_board_body.add_child(floor_panel)
	var scroll := ScrollContainer.new()
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.custom_minimum_size.y = 92
	floor_panel.add_child(scroll)
	_board = HBoxContainer.new()
	_board.add_theme_constant_override("separation", 4)
	_board.set_drag_forwarding(Callable(), _pedal_can_drop, _pedal_drop)  # a pedal dropped between the tiles
	scroll.add_child(_board)
	_add_menu = PopupMenu.new()
	for i in Catalog.PEDAL_ORDER.size():
		_add_menu.add_item(Catalog.PEDALS[Catalog.PEDAL_ORDER[i]].name, i)
	_add_menu.id_pressed.connect(_on_add_chosen)
	_root.add_child(_add_menu)

	# What is selected on the board.
	var page_panel := PanelContainer.new()
	var page_style := StyleBoxFlat.new()
	page_style.bg_color = Color(0.17, 0.18, 0.21)
	page_style.set_corner_radius_all(10)
	page_style.set_border_width_all(1)
	page_style.border_color = Color(0, 0, 0, 0.6)
	page_style.set_content_margin_all(14)
	page_panel.add_theme_stylebox_override("panel", page_style)
	page_panel.custom_minimum_size.y = 236
	_board_body.add_child(page_panel)
	var pages := VBoxContainer.new()
	pages.add_theme_constant_override("separation", 10)
	page_panel.add_child(pages)
	_empty_page = Label.new()
	_empty_page.text = "No pedals yet"
	_empty_page.add_theme_color_override("font_color", DIM)
	_empty_page.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_empty_page.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_empty_page.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_empty_page.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	pages.add_child(_empty_page)
	_loop_page = _build_loop_page()
	pages.add_child(_loop_page)
	_pedal_page = _build_pedal_page()
	pages.add_child(_pedal_page)
	_footer = _build_footer()
	pages.add_child(_footer)

	_hint = Hints.line()
	box.add_child(_hint)
	_drop_mark = ColorRect.new()
	_drop_mark.color = DROP_MARK
	_drop_mark.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_drop_mark.visible = false
	_root.add_child(_drop_mark)


func _build_pedal_page() -> VBoxContainer:
	var page := VBoxContainer.new()
	page.add_theme_constant_override("separation", 10)
	page.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 14)
	page.add_child(top)
	_pedal_title = Label.new()
	_pedal_title.add_theme_font_size_override("font_size", 20)
	top.add_child(_pedal_title)

	var middle := HBoxContainer.new()
	middle.add_theme_constant_override("separation", 20)
	middle.size_flags_vertical = Control.SIZE_EXPAND_FILL
	page.add_child(middle)
	_pedal_controls = HBoxContainer.new()
	_pedal_controls.add_theme_constant_override("separation", 10)
	middle.add_child(_pedal_controls)

	# The tuner's display: the note, a needle that sits in the middle when it is in tune, and how far off it is.
	_tuner_box = VBoxContainer.new()
	_tuner_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	middle.add_child(_tuner_box)
	_tuner_note = Label.new()
	_tuner_note.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_tuner_note.add_theme_font_size_override("font_size", 40)
	_tuner_box.add_child(_tuner_note)
	_tuner_scale = Control.new()
	_tuner_scale.custom_minimum_size = Vector2(300, 18)
	_tuner_scale.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_tuner_box.add_child(_tuner_scale)
	var track := ColorRect.new()
	track.color = Color(0.05, 0.05, 0.06)
	track.set_anchors_preset(Control.PRESET_FULL_RECT)
	_tuner_scale.add_child(track)
	var centre := ColorRect.new()
	centre.color = Color(1, 1, 1, 0.5)
	centre.custom_minimum_size = Vector2(2, 18)
	centre.anchor_left = 0.5
	centre.anchor_right = 0.5
	centre.offset_left = -1
	centre.offset_right = 1
	centre.offset_bottom = 18
	_tuner_scale.add_child(centre)
	_tuner_needle = ColorRect.new()
	_tuner_needle.size = Vector2(6, 18)
	_tuner_scale.add_child(_tuner_needle)
	_tuner_cents = Label.new()
	_tuner_cents.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_tuner_cents.add_theme_color_override("font_color", DIM)
	_tuner_box.add_child(_tuner_cents)

	# The Plug-in pedal: what it holds, its window, and the browser to choose one from.
	_plugin_box = VBoxContainer.new()
	_plugin_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_plugin_box.add_theme_constant_override("separation", 8)
	middle.add_child(_plugin_box)
	_plugin_status = Label.new()
	_plugin_status.add_theme_font_size_override("font_size", 17)
	_plugin_status.clip_text = true
	_plugin_box.add_child(_plugin_status)
	var plugin_row := HBoxContainer.new()
	plugin_row.add_theme_constant_override("separation", 10)
	_plugin_box.add_child(plugin_row)
	_plugin_choose = Button.new()
	_plugin_choose.pressed.connect(_on_plugin_choose_pressed)
	plugin_row.add_child(_plugin_choose)
	_plugin_window = Button.new()
	_plugin_window.pressed.connect(_on_plugin_window_pressed)
	plugin_row.add_child(_plugin_window)
	_plugin_error = Label.new()
	_plugin_error.add_theme_color_override("font_color", WARN)
	_plugin_error.add_theme_font_size_override("font_size", 12)
	_plugin_error.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_plugin_box.add_child(_plugin_error)
	return page


func _build_footer() -> HBoxContainer:
	var bottom := HBoxContainer.new()
	bottom.add_theme_constant_override("separation", 8)
	_pedal_switch = Button.new()
	_pedal_switch.toggle_mode = true
	_pedal_switch.custom_minimum_size = Vector2(180, 40)
	_pedal_switch.add_theme_font_size_override("font_size", 16)
	_pedal_switch.toggled.connect(_on_pedal_switch_pressed)
	bottom.add_child(_pedal_switch)
	var gap := Control.new()
	gap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bottom.add_child(gap)
	_remove = Button.new()
	_remove.pressed.connect(_on_remove_pressed)
	bottom.add_child(_remove)
	return bottom


func _build_loop_page() -> HBoxContainer:
	var pedal_row := HBoxContainer.new()
	pedal_row.add_theme_constant_override("separation", 18)
	pedal_row.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var left := VBoxContainer.new()
	left.add_theme_constant_override("separation", 8)
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	pedal_row.add_child(left)
	var title := Label.new()
	title.text = "Loop Pedal"
	title.add_theme_font_size_override("font_size", 20)
	Hints.give(title, "It records what reaches it: a loop keeps the pedals before it, and plays through those after it and the amp. Loops last until the sample rate changes, and aren't saved yet")
	left.add_child(title)
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
	_footswitch.custom_minimum_size.y = 44
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
	right.custom_minimum_size.x = 260
	pedal_row.add_child(right)
	var level_row := HBoxContainer.new()
	right.add_child(level_row)
	_level = Knob.new()
	_level.title = "LOOP LEVEL"
	_level.value_changed.connect(_on_pedal_knob_changed.bind(0))
	level_row.add_child(_level)
	var options := VBoxContainer.new()
	level_row.add_child(options)
	_sync = CheckButton.new()
	_sync.text = "Sync to the bars"
	Hints.give(_sync, "While the patterns are running, recording starts on the next bar line and the loop is a whole number of bars")
	_sync.toggled.connect(_on_pedal_switch_toggled.bind(1))
	options.add_child(_sync)
	var after_label := Label.new()
	after_label.text = "After recording"
	after_label.add_theme_color_override("font_color", DIM)
	after_label.add_theme_font_size_override("font_size", 13)
	options.add_child(after_label)
	_after = OptionButton.new()
	_after.add_item("play the loop")
	_after.add_item("overdub straight away")
	_after.item_selected.connect(func(index: int) -> void: _on_pedal_switch_toggled(index == 1, 2))
	options.add_child(_after)
	return pedal_row


func _voice_row(parent: Control, title: String, choices: Array) -> OptionButton:
	var label := Label.new()
	label.text = title
	label.add_theme_color_override("font_color", DIM)
	label.add_theme_font_size_override("font_size", 12)
	parent.add_child(label)
	var choice := OptionButton.new()
	for entry in choices:
		choice.add_item(entry[1])
	choice.custom_minimum_size.x = 150
	parent.add_child(choice)
	return choice


func _index_of(choices: Array, name: String) -> int:
	for i in choices.size():
		if choices[i][0] == name:
			return i
	return 0


func _set_voice() -> void:
	app.set_amp_voice(inst, Catalog.AMP_HEADS[_head_choice.selected][0], _head_on.button_pressed,
		Catalog.AMP_CABINETS[_cabinet_choice.selected][0], _cabinet_on.button_pressed)


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


func _on_tile_input(event: InputEvent, index: int) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		selected = index
		_remove_armed_until = 0
		_refresh()


func _on_add_pressed() -> void:
	_add_menu.position = Vector2i(_add_button.get_screen_position() + Vector2(0, _add_button.size.y))
	_add_menu.popup()


func _on_add_chosen(id: int) -> void:
	var at: int = app.add_pedal(inst, Catalog.PEDAL_ORDER[id])
	if at >= 0:
		selected = at
		_refresh()
		if Catalog.PEDAL_ORDER[id] == "plugin":  # straight to choosing what it holds
			_on_plugin_choose_pressed()


func _on_pedal_knob_changed(value: float, control: int) -> void:
	app.set_pedal_control(inst, selected, control, value)


func _on_pedal_switch_toggled(on: bool, control: int) -> void:
	app.set_pedal_control(inst, selected, control, 1.0 if on else 0.0)


func _on_pedal_switch_pressed(on: bool) -> void:
	app.set_pedal_on(inst, selected, on)


## Taking a loop pedal that holds a loop off the board loses the loop, so that takes a second press.
func _on_remove_pressed() -> void:
	var holding: bool = inst.pedals[selected].kind == "looper" and inst.looper.get("state", "empty") != "empty"
	if holding and Time.get_ticks_msec() >= _remove_armed_until:
		_remove_armed_until = Time.get_ticks_msec() + 3000
		return
	_remove_armed_until = 0
	app.remove_pedal(inst, selected)
	selected = mini(selected, inst.pedals.size() - 1)
	_refresh()


func _on_plugin_window_pressed() -> void:
	app.show_plugin_editor(inst, selected, not inst.pedals[selected].editor_open)


func _on_plugin_choose_pressed() -> void:
	_plugin_error.text = ""
	var index := selected
	app.plugin_browser.open_for("A plug-in for pedal %d" % (index + 1), app.available_plugins(),
		_plugin_choose.get_screen_position() + Vector2(0, 40), func(plugin: Dictionary) -> void: _load_plugin(index, plugin))


## Loads a plug-in into the Plug-in pedal at `index`, and opens its window.
func _load_plugin(index: int, plugin: Dictionary) -> void:
	if inst == null or index >= inst.pedals.size():
		return
	var problem: String = app.load_pedal_plugin(inst, index, plugin.id)
	if problem != "":
		_plugin_error.text = "%s couldn't be loaded: %s." % [plugin.name, problem]
		return
	_plugin_error.text = ""
	app.show_plugin_editor(inst, index, true)


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
