extends CanvasLayer
## A microphone's panel (P at it, or its name in the mix window), docked down the right of the screen so the room stays
## in view, and the view from its capsule: looking the way it points (its own model out of the way), a cross at the
## middle, and what is on its axis under it, for placing it by eye as you would with your head beside the stand. In the
## view, W A S D (or the arrows) move it, R and F raise and lower it, dragging aims it, and the scroll wheel moves it
## along its aim, closer or further; Shift for fine moves. Its keys are drawn in the corner of the view, lit while held.
## The panel has which model it is and which of its pickup patterns, with its frequency response and its pattern
## drawn; where it stands, to the centimetre (across the room and along it, from its middle, and its capsule's height),
## which way it points (its bearing, clockwise from north, the way you first face, and how far down), or straight at an
## instrument; its gain, before it records, as a preamp's; and its input monitoring, with a meter of what it hears.
## Under them, how far each instrument is from it, how late its sound arrives, how loud it is there, and how far off
## its axis (two mics at different distances from one instrument hear it at different times, as real ones do). A
## stereo mic's sets up its pair (XY, ORTF, a spaced pair, Blumlein, mid-side: a spaced pair's spacing, a mid-side
## pair's width), placed and pointed as one. Its pan is the mix window's, with the rest of the mix.

const Hints := preload("res://scripts/hints.gd")
const LevelMeter := preload("res://scripts/level_meter.gd")
const MicGraph := preload("res://scripts/mic_graph.gd")
const Catalog := preload("res://scripts/catalog.gd")
const DIM := Color(0.62, 0.65, 0.74)
const SPEED_OF_SOUND := 343.0  # metres a second, as the audio core has it
const REF_DISTANCE := 1.5      # where an instrument is heard at the level it was made at
const NEAREST := 0.1           # and no louder for coming closer than this
const WIDTH := 400.0           # the panel, down the right of the screen
const HIDDEN_LAYER := 20       # the 3D layer its own model is put on while you look out from it, which the view leaves out
const MOVE_SPEED := 0.5        # metres a second, a key held (Shift: a fifth of it)
const TURN := 0.2              # degrees a pixel, dragging to aim it
const WHEEL_STEP := 0.02       # metres along its aim, a turn of the scroll wheel
const ON_AXIS := 25.0          # how far off its axis something can be and still be what it points at (degrees)
const VIEW_HINT := "From its capsule, the way it points: W A S D or the arrows move it, R and F raise and lower it, drag to aim it, the scroll wheel moves it closer or further along its aim (Shift: fine)"
const RAISE := KEY_R  # its height, up and down
const LOWER := KEY_F
const KEYCAP := 30.0  # a key drawn in the guide, square

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
var _pair_row: HFlowContainer
var _technique: OptionButton
var _spacing: SpinBox
var _spacing_label: Label
var _width: SpinBox
var _width_label: Label
var _input_switch: CheckButton
var _polarity: Button
var _meter
var _distances: GridContainer
var _hint: Label
var _back_to_mixer := false
var _eye: Camera3D  # the view from its capsule
var _view: Control  # the room's part of the screen: dragged on, it aims the mic
var _cross: Control  # the cross at the middle, and what is on its axis
var _guide: Control  # its keys, in the corner of the view
var _aiming := false


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
	_aim_at.add_item("Point the pair at…" if inst.is_stereo_mic else "Point it at…")
	_aim_choices = app.instruments.filter(func(other): return other != inst and not other.is_mic)
	for other in _aim_choices:
		_aim_at.add_item(other.display_name)
	_model.clear()
	for info in app.mic_models():
		_model.add_item(str(info.name))
	_graph.app = app
	_patterns_shown = []
	_eye.fov = app.player.camera.fov
	_eye.make_current()
	_refresh()
	_look_out()


func close() -> void:
	_root.visible = false
	_aiming = false
	if inst != null and is_instance_valid(inst):
		inst.set_hidden_layer(0)
	app.player.look_through()
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


func _process(delta: float) -> void:
	if not is_open():
		return
	if not app.instruments.has(inst):
		close()
		return
	_nudge(delta)
	_refresh()
	_look_out()
	_hint.text = Hints.under_mouse(_root)


## The view from its capsule (a stereo mic's, from between its two), the way it points; its own model out of sight.
## Its axis is at the middle of the room's part of the screen, under the cross, not the middle of the whole screen (the
## frustum shifted sideways, as a shift lens does), so the panel beside it covers none of what it points at.
func _look_out() -> void:
	var aim: Vector3 = inst.mic_aim()
	var facing: Vector3 = inst.global_transform.basis.z
	var up := Vector3.UP if absf(aim.y) < 0.98 else (facing * -signf(aim.y)).normalized()  # (straight down: ahead is up)
	_eye.global_transform = Transform3D(Basis.looking_at(aim, up), inst.global_position)
	var screen := get_viewport().get_visible_rect().size
	var tall := 2.0 * _eye.near * tan(deg_to_rad(_eye.fov) / 2.0)  # the near plane's height, as the fov has it
	var wide := tall * screen.x / maxf(screen.y, 1.0)
	_eye.size = tall
	_eye.frustum_offset = Vector2((screen.x / 2.0 - _view.size.x / 2.0) / maxf(screen.x, 1.0) * wide, 0.0)
	inst.set_hidden_layer(HIDDEN_LAYER)  # (again each frame: its model is made afresh as it is raised or changed)
	_cross.queue_redraw()
	_guide.queue_redraw()


## The keys held, in the view: it moves along the floor the way it faces and across it, and up and down.
func _nudge(delta: float) -> void:
	if get_viewport().gui_get_focus_owner() is LineEdit or app.name_prompt.is_open():
		return
	var keys = app.bindings
	var across := _held(keys.key("right"), KEY_RIGHT) - _held(keys.key("left"), KEY_LEFT)
	var ahead := _held(keys.key("forward"), KEY_UP) - _held(keys.key("back"), KEY_DOWN)
	var rise := _held(RAISE) - _held(LOWER)
	if across == 0.0 and ahead == 0.0 and rise == 0.0 or inst.locked:
		return
	app.note_move(inst)
	var step := MOVE_SPEED * delta * (0.2 if Input.is_key_pressed(KEY_SHIFT) else 1.0)
	var facing: Vector3 = inst.global_transform.basis.z
	facing = Vector3(facing.x, 0.0, facing.z).normalized()
	if across != 0.0 or ahead != 0.0:
		var to: Vector3 = inst.global_position + (facing * ahead + facing.cross(Vector3.UP) * across) * step
		app.set_mic_spot(inst, to.x, to.z)
	if rise != 0.0:
		app.set_mic_height(inst, inst.source_height + rise * step)


func _held(key: int, other := KEY_NONE) -> float:
	if Input.is_key_pressed(KEY_META) or Input.is_key_pressed(KEY_CTRL):
		return 0.0
	return 1.0 if Input.is_physical_key_pressed(key) or (other != KEY_NONE and Input.is_physical_key_pressed(other)) else 0.0


## The room's part of the screen: drag to aim it (as you'd turn your head), scroll to move it along its aim.
func _on_view_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var e: InputEventMouseButton = event
		if e.button_index == MOUSE_BUTTON_LEFT:
			_aiming = e.pressed
			if e.pressed:
				_view.grab_focus()  # (off any number being typed)
				_view.release_focus()
		elif e.pressed and e.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN] and not inst.locked:
			app.note_move(inst)
			var along: Vector3 = inst.mic_aim() * WHEEL_STEP * (0.25 if e.shift_pressed else 1.0) * (1.0 if e.button_index == MOUSE_BUTTON_WHEEL_UP else -1.0)
			var to: Vector3 = inst.global_position + along
			app.set_mic_spot(inst, to.x, to.z)
			app.set_mic_height(inst, to.y)
		_view.accept_event()
	elif event is InputEventMouseMotion and _aiming and not inst.locked:
		app.note_move(inst)
		var e: InputEventMouseMotion = event
		var fine := 0.25 if e.shift_pressed else 1.0
		app.set_mic_bearing(inst, app.mic_bearing(inst) + e.relative.x * TURN * fine)
		app.set_mic_tilt(inst, clampf(inst.mic_tilt + e.relative.y * TURN * fine, -90.0, 90.0))
		_view.accept_event()


## Its keys, in the corner of the view, laid out as they are on the keyboard: W A S D (as bound) to move it along the
## floor, R and F to raise and lower it, each lit while it is held; and the mouse's part under them.
func _draw_guide() -> void:
	var font := _guide.get_theme_default_font()
	var back := StyleBoxFlat.new()
	back.bg_color = Color(0.05, 0.06, 0.08, 0.72)
	back.set_corner_radius_all(8)
	_guide.draw_style_box(back, Rect2(Vector2.ZERO, _guide.size))
	var keys = app.bindings
	if inst != null and inst.locked:  # nothing moves it: say so, and how to unlock it
		_guide.draw_texture_rect(inst._lock_texture, Rect2(Vector2(16, _guide.size.y / 2 - 20), Vector2(40, 40)), false)
		_guide.draw_string(font, Vector2(68, _guide.size.y / 2 - 4), "Locked in place", HORIZONTAL_ALIGNMENT_LEFT, -1, 15, Color(1.0, 0.85, 0.4))
		_guide.draw_string(font, Vector2(68, _guide.size.y / 2 + 16), "%s unlocks it" % keys.label("lock"), HORIZONTAL_ALIGNMENT_LEFT, -1, 12,
			Color(1, 1, 1, 0.6))
		return
	var gap := KEYCAP + 4.0
	var move := Vector2(14, 12)  # the W A S D block's top left: W above S, A and D either side
	_keycap(font, move + Vector2(gap, 0), keys.key("forward"), KEY_UP)
	_keycap(font, move + Vector2(0, gap), keys.key("left"), KEY_LEFT)
	_keycap(font, move + Vector2(gap, gap), keys.key("back"), KEY_DOWN)
	_keycap(font, move + Vector2(2 * gap, gap), keys.key("right"), KEY_RIGHT)
	_caption(font, move + Vector2(0, 2 * gap + 14), 3 * gap, "Move")
	var lift := Vector2(move.x + 3 * gap + 18, move.y)
	_keycap(font, lift, RAISE)
	_keycap(font, lift + Vector2(0, gap), LOWER)
	_caption(font, lift + Vector2(gap, KEYCAP / 2 + 5), 52, "Up", HORIZONTAL_ALIGNMENT_LEFT)
	_caption(font, lift + Vector2(gap, gap + KEYCAP / 2 + 5), 52, "Down", HORIZONTAL_ALIGNMENT_LEFT)
	_caption(font, lift + Vector2(-16, 2 * gap + 14), KEYCAP + 32, "Height")
	var mouse := Vector2(lift.x + gap + 58, move.y + 4)
	var shift := Input.is_key_pressed(KEY_SHIFT)
	for i in 4:
		var row: Array = [["Drag", "Aim"], ["Wheel", "Closer / further"], ["Shift", "Fine"], [keys.label("edit"), "Close"]][i]
		var at := mouse + Vector2(0, i * 21.0)
		var lit: bool = (i == 0 and _aiming) or (i == 2 and shift)
		_guide.draw_string(font, at + Vector2(0, 12), row[0], HORIZONTAL_ALIGNMENT_LEFT, 44, 12, Color(1.0, 0.85, 0.4) if lit else Color(1, 1, 1, 0.9))
		_guide.draw_string(font, at + Vector2(46, 12), row[1], HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color(1, 1, 1, 0.6))


## A key in the guide: its letter on a cap, lit while it (or `also`, an arrow key) is held.
func _keycap(font: Font, at: Vector2, code: int, also := KEY_NONE) -> void:
	var held: bool = not (Input.is_key_pressed(KEY_META) or Input.is_key_pressed(KEY_CTRL)) and (Input.is_physical_key_pressed(code) or
		(also != KEY_NONE and Input.is_physical_key_pressed(also)))
	var cap := StyleBoxFlat.new()
	cap.bg_color = Color(1.0, 0.82, 0.35) if held else Color(0.2, 0.22, 0.27)
	cap.set_corner_radius_all(5)
	cap.border_width_bottom = 3
	cap.border_color = Color(0.7, 0.55, 0.2) if held else Color(0.09, 0.1, 0.12)
	_guide.draw_style_box(cap, Rect2(at, Vector2(KEYCAP, KEYCAP)))
	var text: String = app.bindings.name_of(code)
	_guide.draw_string(font, at + Vector2(0, KEYCAP / 2 + 4), text, HORIZONTAL_ALIGNMENT_CENTER, KEYCAP, 13,
		Color(0.1, 0.1, 0.12) if held else Color(1, 1, 1, 0.92))


func _caption(font: Font, at: Vector2, width: float, text: String, align := HORIZONTAL_ALIGNMENT_CENTER) -> void:
	_guide.draw_string(font, at, text, align, width, 11, Color(1, 1, 1, 0.55))


## What the guide shows, as text (for the checks).
func guide_text() -> String:
	var keys = app.bindings
	if inst != null and inst.locked:
		return "Locked in place, %s unlocks it" % keys.label("lock")
	return "%s %s %s %s move, %s %s height, drag aim, wheel closer or further, Shift fine, %s close" % [keys.name_of(keys.key("forward")),
		keys.name_of(keys.key("left")), keys.name_of(keys.key("back")), keys.name_of(keys.key("right")), keys.name_of(RAISE),
		keys.name_of(LOWER), keys.label("edit")]


## The cross at the middle of the view, and under it what the mic points at: how far, and how far off its axis.
func _draw_cross() -> void:
	var middle := _cross.size / 2.0
	var ink := Color(1, 1, 1, 0.85)
	for arm in [Vector2(1, 0), Vector2(-1, 0), Vector2(0, 1), Vector2(0, -1)]:
		_cross.draw_line(middle + arm * 6.0, middle + arm * 18.0, Color(0, 0, 0, 0.5), 3.0)
		_cross.draw_line(middle + arm * 6.0, middle + arm * 18.0, ink, 1.0)
	_cross.draw_circle(middle, 1.5, ink)
	if inst == null or not app.instruments.has(inst):
		return
	var font := _cross.get_theme_default_font()
	var target := on_axis(inst, app.instruments)
	var named: String = "%s, %s" % [target.of, target.name.to_lower()] if target.has("of") else str(target.get("name", ""))
	var text := "%s  ·  %.2f m  ·  %.0f° off axis" % [named, target.metres, target.off] if not target.is_empty() else "Nothing on its axis"
	var at := middle + Vector2(-200, 40)
	_cross.draw_string_outline(font, at, text, HORIZONTAL_ALIGNMENT_CENTER, 400, 14, 4, Color(0, 0, 0, 0.6))
	_cross.draw_string(font, at, text, HORIZONTAL_ALIGNMENT_CENTER, 400, 14, ink)
	var place := "%.2f m high  ·  points %.0f°, %.0f° down" % [inst.source_height, app.mic_bearing(inst), inst.mic_tilt]
	_cross.draw_string_outline(font, at + Vector2(0, 18), place, HORIZONTAL_ALIGNMENT_CENTER, 400, 12, 4, Color(0, 0, 0, 0.6))
	_cross.draw_string(font, at + Vector2(0, 18), place, HORIZONTAL_ALIGNMENT_CENTER, 400, 12, Color(ink, 0.7))


func _refresh() -> void:
	for box in [_x, _z, _height, _bearing, _tilt]:  # (locked, where it stands can't be changed)
		box.editable = not inst.locked
	_aim_at.disabled = inst.locked
	_show(_x, inst.global_position.x)
	_show(_z, inst.global_position.z)
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
	var mid_side: bool = inst.is_stereo_mic and Catalog.MIC_PAIRS.get(inst.pair_technique, {}).get("mid_side", false)
	_pattern.disabled = names.size() < 2 or (inst.is_stereo_mic and not mid_side)  # (a pair's patterns are its setup's)
	_about.text = "%s  Sensitivity %+.0f dB against the measurement mic; self-noise %.0f dB(A), %.0f dB SPL with the preamp's." % [info.get("about", ""),
		float(info.get("sensitivity_db", 0.0)), float(info.get("self_noise_db", 0.0)), float(info.get("noise_db", 0.0))]
	var patterns: Array = info.get("patterns", [])
	_graph.ink = inst.color.lightened(0.2)
	_graph.show_mic(inst.mic_model, patterns[maxi(names.find(pattern), 0)] if not patterns.is_empty() else {})
	_pair_row.visible = inst.is_stereo_mic
	if inst.is_stereo_mic:
		_technique.select(Catalog.MIC_PAIR_ORDER.find(inst.pair_technique))
		var spaced: bool = inst.pair_technique == "ab"
		_spacing.visible = spaced
		_spacing_label.visible = spaced
		_show(_spacing, inst.pair_spacing)
		_width.visible = mid_side
		_width_label.visible = mid_side
		_show(_width, inst.ms_width * 100.0)
	_input_switch.set_pressed_no_signal(inst.input_on)
	_polarity.set_pressed_no_signal(inst.mic_inverted)
	_input_switch.text = app.input_text(inst)
	var level: float = app.audio.get_source_level(inst.source_id, true)
	_meter.feed([level * sqrt(2.0)], [level])
	_show_distances(distances(inst, app.instruments))


## Each instrument's distance from a microphone in a straight line (round a wall it is further), how late its sound
## arrives, how loud it is there against its level at 1.5 m, and how far off the mic's axis it is (degrees): [{name,
## metres, ms, db, off}], the nearest first. A kit's row ("pieces": true) is followed by one for each of its pieces
## ({..., of: the kit}), the nearest first, so what bleeds into a close mic can be read off drum by drum.
static func distances(mic, instruments: Array) -> Array:
	var groups := []
	for other in instruments:  # (an amp from its nearest cone)
		if other == mic or other.is_mic:
			continue
		var group := [_row(mic, other.display_name, other.sound_point(mic.global_position))]
		if other.has_parts():  # a kit: then each of its pieces, from its nearest head (or its port, or inside it)
			var nearest := {}
			for part: Dictionary in other.parts_in_room():
				var was: Vector3 = nearest.get(part.piece, Vector3.INF)
				if was == Vector3.INF or part.at.distance_to(mic.global_position) < was.distance_to(mic.global_position):
					nearest[part.piece] = part.at
			var pieces := []
			for piece: String in nearest:
				var row := _row(mic, piece, nearest[piece])
				row["of"] = other.display_name
				pieces.append(row)
			pieces.sort_custom(func(a, b): return a.metres < b.metres)
			group[0]["pieces"] = true
			group.append_array(pieces)
		groups.append(group)
	groups.sort_custom(func(a, b): return a[0].metres < b[0].metres)
	var out := []
	for group in groups:
		out.append_array(group)
	return out


static func _row(mic, name: String, point: Vector3) -> Dictionary:
	var to: Vector3 = point - mic.global_position
	var metres: float = to.length()
	return {"name": name, "metres": metres, "ms": 1000.0 * metres / SPEED_OF_SOUND, "db": 20.0 * log(REF_DISTANCE / maxf(metres, NEAREST)) / log(10.0),
		"off": rad_to_deg(mic.mic_aim().angle_to(to)) if metres > 0.001 else 0.0}


## What a microphone points at: the instrument nearest its axis (a kit's piece), if one is within 25° of it ({} if none).
static func on_axis(mic, instruments: Array) -> Dictionary:
	var best := {}
	for row in distances(mic, instruments):
		if row.get("pieces", false):
			continue
		if row.off <= ON_AXIS and (best.is_empty() or row.off < best.off):
			best = row
	return best


const COLUMNS := 5


## The table of distances: a row for each instrument, its name, then its numbers lined up on the right (a kit's
## pieces under it, set in).
func _show_distances(rows: Array) -> void:
	var cells: Array = []
	for row in rows:
		cells.append_array([("    " if row.has("of") else "") + row.name, "%.2f m" % row.metres, "%.1f ms" % row.ms, "%+.1f dB" % row.db,
			"%.0f°" % row.off])
	while _distances.get_child_count() > cells.size():
		var last := _distances.get_child(_distances.get_child_count() - 1)
		_distances.remove_child(last)
		last.queue_free()
	while _distances.get_child_count() < cells.size():
		var cell := Label.new()
		cell.add_theme_font_size_override("font_size", 13)
		cell.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT if _distances.get_child_count() % COLUMNS == 0 else HORIZONTAL_ALIGNMENT_RIGHT
		if _distances.get_child_count() % COLUMNS == 0:  # (a long name cut short, so the numbers fit)
			cell.custom_minimum_size.x = 96
			cell.clip_text = true
			cell.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		cell.mouse_filter = Control.MOUSE_FILTER_PASS
		_distances.add_child(cell)
	for i in cells.size():
		_distances.get_child(i).text = cells[i]


## What the table says, as lines (for the checks).
func distances_text() -> String:
	var lines := []
	for i in range(0, _distances.get_child_count(), COLUMNS):
		lines.append("   ".join(range(COLUMNS).map(func(k): return _distances.get_child(i + k).text)))
	return "\n".join(lines)


## A change to where it stands or points, typed in: remembered for Cmd-Z, and not made while it is locked.
func _move(change: Callable) -> void:
	if inst.locked:
		return
	app.note_move(inst)
	change.call()


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
	box.custom_minimum_size.x = 150
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
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_root)
	_eye = Camera3D.new()
	_eye.near = 0.02
	_eye.projection = Camera3D.PROJECTION_FRUSTUM
	_eye.cull_mask = 0xFFFFF & ~(1 << (HIDDEN_LAYER - 1))
	add_child(_eye)
	_view = Control.new()  # the room, as the mic sees it, left of the panel
	_view.set_anchors_preset(Control.PRESET_FULL_RECT)
	_view.offset_right = -WIDTH - 12
	_view.focus_mode = Control.FOCUS_CLICK
	_view.gui_input.connect(_on_view_input)
	Hints.give(_view, VIEW_HINT)
	_root.add_child(_view)
	_cross = Control.new()
	_cross.set_anchors_preset(Control.PRESET_FULL_RECT)
	_cross.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_cross.draw.connect(_draw_cross)
	_view.add_child(_cross)
	_guide = Control.new()
	_guide.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	_guide.offset_left = 16
	_guide.offset_right = 16 + 392
	_guide.offset_top = -16 - 120
	_guide.offset_bottom = -16
	_guide.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_guide.draw.connect(_draw_guide)
	_view.add_child(_guide)
	_panel = PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.07, 0.08, 0.11, 0.96)
	style.set_corner_radius_all(10)
	style.set_border_width_all(1)
	style.border_color = Color(1, 1, 1, 0.14)
	style.set_content_margin_all(14)
	_panel.add_theme_stylebox_override("panel", style)
	_panel.set_anchors_preset(Control.PRESET_RIGHT_WIDE)
	_panel.offset_left = -WIDTH - 12
	_panel.offset_right = -12
	_panel.offset_top = 12
	_panel.offset_bottom = -12
	_root.add_child(_panel)
	var outer := VBoxContainer.new()
	outer.add_theme_constant_override("separation", 8)
	_panel.add_child(outer)
	var header := HBoxContainer.new()
	outer.add_child(header)
	_title = Label.new()
	_title.add_theme_font_size_override("font_size", 20)
	_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_title.clip_text = true
	_title.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	header.add_child(_title)
	_close_button = Button.new()
	_close_button.pressed.connect(close)
	header.add_child(_close_button)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	outer.add_child(scroll)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 10)
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(box)
	var kind := HBoxContainer.new()
	kind.add_theme_constant_override("separation", 8)
	box.add_child(kind)
	_model = OptionButton.new()
	_model.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_model.fit_to_longest_item = false
	_model.item_selected.connect(func(index: int) -> void:
		var models: Array = app.mic_models()
		if index >= 0 and index < models.size():
			app.set_mic_model(inst, str(models[index].id), app.mic_pattern_of(inst)))
	Hints.give(_model, "Which microphone it is: each has its own pickup pattern, frequency response and sensitivity")
	kind.add_child(_model)
	_pattern = OptionButton.new()
	_pattern.item_selected.connect(func(index: int) -> void:
		if index >= 0 and index < _patterns_shown.size():
			app.set_mic_model(inst, inst.mic_model, _patterns_shown[index]))
	Hints.give(_pattern, "Its pickup pattern, if it can be switched: omni hears all round alike, cardioid little from behind, figure-8 front and back (the back in reverse polarity) and nothing from the sides")
	kind.add_child(_pattern)

	_about = Label.new()
	_about.add_theme_color_override("font_color", DIM)
	_about.add_theme_font_size_override("font_size", 13)
	_about.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(_about)
	_graph = MicGraph.new()
	Hints.give(_graph, "Its frequency response on axis, 20 Hz to 20 kHz (±15 dB), and its pickup pattern from above, its front up: the middle band bright, the lows and highs fainter; dashed, a lobe in reverse polarity. Close up, a directional mic gains bass too (the proximity effect)")
	box.add_child(_graph)
	_pair_row = HFlowContainer.new()
	_pair_row.add_theme_constant_override("h_separation", 10)
	_pair_row.add_theme_constant_override("v_separation", 6)
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
	_width_label = Label.new()
	_width_label.text = "width"
	_width_label.add_theme_color_override("font_color", DIM)
	_pair_row.add_child(_width_label)
	_width = SpinBox.new()
	_width.min_value = 0.0
	_width.max_value = 200.0
	_width.step = 1.0
	_width.suffix = " %"
	_width.select_all_on_focus = true
	_width.value_changed.connect(func(v: float) -> void:
		if inst != null and app.instruments.has(inst):
			app.set_mic_width(inst, v / 100.0))
	Hints.give(_width, "How much of the side mic is decoded into the left and right: 0 is mono (the mid alone), 100 as the two hear it, more wider still. It can be changed after recording, as the two are recorded as they are")
	_pair_row.add_child(_width)

	var left := VBoxContainer.new()
	left.add_theme_constant_override("separation", 10)
	box.add_child(left)
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 12)
	grid.add_theme_constant_override("v_separation", 6)
	left.add_child(grid)
	_x = _number(grid, "Across", -10.0, 10.0, 0.01, " m", "Where it stands across the room, from its middle: to the east (right on the floor plan) is more",
		func(v: float) -> void: _move(func() -> void: app.set_mic_spot(inst, v, inst.global_position.z)))
	_z = _number(grid, "Along", -10.0, 10.0, 0.01, " m", "Where it stands along the room, from its middle: to the south (towards you as you first face) is more",
		func(v: float) -> void: _move(func() -> void: app.set_mic_spot(inst, inst.global_position.x, v)))
	_height = _number(grid, "Height", 0.05, 3.0, 0.01, " m", "How high its capsule is, where it hears from (over a kick drum's hole, low; over the kit, high)",
		func(v: float) -> void: _move(func() -> void: app.set_mic_height(inst, v)))
	_bearing = _number(grid, "Points to", 0.0, 359.0, 1.0, "°", "Which way it points, clockwise from north (the way you first face): 90 is east. An omni mic hears all round alike, so this is for its stand, for now",
		func(v: float) -> void: _move(func() -> void: app.set_mic_bearing(inst, v)))
	_tilt = _number(grid, "Down by", -90.0, 90.0, 1.0, "°", "How far it points down (90: straight down, as an overhead)",
		func(v: float) -> void: _move(func() -> void: app.set_mic_tilt(inst, v)))
	_gain = _number(grid, "Gain", -20.0, 40.0, 0.5, " dB", "Its gain, before it records, as a preamp's: up for a mic far off, down for one right up against something loud",
		func(v: float) -> void: app.set_mic_gain(inst, v))
	_aim_at = OptionButton.new()
	_aim_at.item_selected.connect(func(index: int) -> void:
		if index > 0 and index - 1 < _aim_choices.size() and app.instruments.has(_aim_choices[index - 1]):
			app.note_move(inst)
			app.aim_mic(inst, _aim_choices[index - 1])
		_aim_at.select(0))
	Hints.give(_aim_at, "Turns it and tilts it to point straight at an instrument (at where its sound comes from)")
	left.add_child(_aim_at)
	var input_row := HBoxContainer.new()
	input_row.add_theme_constant_override("separation", 10)
	left.add_child(input_row)
	_input_switch = CheckButton.new()
	_input_switch.toggled.connect(func(on: bool) -> void: app.set_input(inst, on))
	Hints.give(_input_switch, "Its input: on, you hear what it hears (through its track, where its pan puts it), rather than what it recorded. Armed to record, it is heard while stopped or recording too, whatever this says")
	input_row.add_child(_input_switch)
	_polarity = Button.new()
	_polarity.text = "Ø"
	_polarity.toggle_mode = true
	_polarity.custom_minimum_size.x = 34
	_polarity.toggled.connect(func(on: bool) -> void: app.set_mic_polarity(inst, on))
	Hints.give(_polarity, "Its polarity, inverted at its preamp before it records: for a mic facing another the other way (under a snare, against one over it), so the two add rather than cancel")
	input_row.add_child(_polarity)
	_meter = LevelMeter.new()
	_meter.custom_minimum_size = Vector2(150, 12)
	_meter.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	Hints.give(_meter, "What it hears, after its gain: what it records")
	input_row.add_child(_meter)

	var right := VBoxContainer.new()
	right.add_theme_constant_override("separation", 6)
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_child(right)
	var heading := Label.new()
	heading.text = "FROM IT"
	heading.add_theme_font_size_override("font_size", 12)
	heading.add_theme_color_override("font_color", DIM)
	right.add_child(heading)
	_distances = GridContainer.new()
	_distances.columns = COLUMNS
	_distances.add_theme_constant_override("h_separation", 10)
	_distances.add_theme_constant_override("v_separation", 2)
	Hints.give(_distances, "How far each instrument is, in a straight line (round a wall it is further), how late its sound arrives, how loud it is here against 1.5 m away, and how far off its axis")
	right.add_child(_distances)
	_hint = Hints.line(34)
	outer.add_child(_hint)
