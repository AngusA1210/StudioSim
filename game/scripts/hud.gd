extends CanvasLayer
## What stays on screen while playing: the crosshair, a hint about what you're facing, the beat, whether binaural
## and the room reverb are on, the master meter, the keyboard while you are at an instrument, and (if switched on in
## the menu) a small audio readout. Everything else lives in the menu, the mix window and the pattern editor.

const Hints := preload("res://scripts/hints.gd")
const LevelMeter := preload("res://scripts/level_meter.gd")
const PANEL_BG := Color(0.05, 0.06, 0.09, 0.82)
const DIM := Color(0.62, 0.65, 0.74)
const WARN := Color(1.0, 0.61, 0.48)
const BINAURAL_BLUE := Color(0.55, 0.78, 1.0)
const MONITOR_GREEN := Color(0.45, 0.9, 0.62)
const FOLLOW_AMBER := Color(0.98, 0.76, 0.36)
const WHITE_KEYS := [[KEY_A, "A"], [KEY_S, "S"], [KEY_D, "D"], [KEY_F, "F"], [KEY_G, "G"], [KEY_H, "H"], [KEY_J, "J"],
	[KEY_K, "K"], [KEY_L, "L"], [KEY_SEMICOLON, ";"]]
const BLACK_KEYS := [[KEY_W, "W", 0], [KEY_E, "E", 1], [KEY_T, "T", 3], [KEY_Y, "Y", 4], [KEY_U, "U", 5],
	[KEY_O, "O", 7], [KEY_P, "P", 8]]
# What each drum piece is called on a key: spelled out on the wide white keys, two letters on the black ones.
const DRUM_LABELS := {"Kick": ["Kick", "BD"], "Snare": ["Snare", "SD"], "Closed hat": ["Hat", "CH"], "Open hat": ["Open", "OH"],
	"Low tom": ["Lo tom", "LT"], "High tom": ["Hi tom", "HT"], "Clap": ["Clap", "CP"], "Ride": ["Ride", "RD"], "Crash": ["Crash", "CR"]}

var app
var audio: SoundRoomAudio
var player

var _root: Control
var _stats_panel: PanelContainer
var _stats: Label
var _hint_panel: PanelContainer
var _hint_title: Label
var _hint_rows: VBoxContainer
var _hint_signature := ""
var _prompt_panel: PanelContainer
var _prompt: Label
var _beat_panel: PanelContainer
var _beat: Label
var _modes_panel: PanelContainer
var _binaural_chip: Label
var _monitor_chip: Label  # what you hear (H switches): the room, or the mix (as headphones would have it)
var _follow_chip: Label  # a Record room's insertion following playback, shown while it does
var _meter_panel: PanelContainer
var _meter
var _meter_text: Label
var _piano: PanelContainer
var _piano_title: Label
var _piano_help: Label
var _piano_keys := {}  # physical key → {rect, idle colour, piece label, semitone, white}
var _piano_for := ""  # what the keyboard is labelled for: an instrument (its id), or "keyboard"
var _frame := 0
var _notice_panel: PanelContainer  # something done in the background (the room saved or backed up), for a moment
var _notice: Label
var _notice_until := 0


func setup(the_app) -> void:
	app = the_app
	audio = app.audio
	player = app.player
	_root = Control.new()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_root)

	_stats_panel = _panel(_root)
	_stats_panel.position = Vector2(14, 14)
	_stats = Label.new()
	_stats.add_theme_color_override("font_color", DIM)
	_stats.add_theme_font_size_override("font_size", 13)
	_stats_panel.add_child(_stats)

	var cross := Panel.new()
	var ring := StyleBoxFlat.new()
	ring.bg_color = Color(0, 0, 0, 0)
	ring.set_border_width_all(2)
	ring.border_color = Color(1, 1, 1, 0.8)
	ring.set_corner_radius_all(5)
	cross.add_theme_stylebox_override("panel", ring)
	cross.size = Vector2(9, 9)
	cross.set_anchors_preset(Control.PRESET_CENTER)
	cross.position -= cross.size / 2
	cross.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(cross)

	# What you can do with the instrument you're facing: its name, then a key and an action on each line.
	_hint_panel = _panel(_root)
	var hint_box := VBoxContainer.new()
	hint_box.add_theme_constant_override("separation", 3)
	hint_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hint_panel.add_child(hint_box)
	_hint_title = Label.new()
	_hint_title.add_theme_font_size_override("font_size", 17)
	hint_box.add_child(_hint_title)
	_hint_rows = VBoxContainer.new()
	_hint_rows.add_theme_constant_override("separation", 2)
	_hint_rows.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hint_box.add_child(_hint_rows)

	_prompt_panel = _panel(_root)
	_prompt = Label.new()
	_prompt.add_theme_color_override("font_color", DIM)
	_prompt_panel.add_child(_prompt)

	_beat_panel = _panel(_root)
	_beat = Label.new()
	_beat.add_theme_color_override("font_color", DIM)
	_beat.add_theme_font_size_override("font_size", 14)
	_beat_panel.add_child(_beat)

	# Whether binaural rendering (B) is on, lit when it is; and in a Record room, whether insertion follows playback (N).
	_modes_panel = _panel(_root)
	var modes := HBoxContainer.new()
	modes.add_theme_constant_override("separation", 6)
	modes.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_modes_panel.add_child(modes)
	_monitor_chip = _chip(modes)
	_binaural_chip = _chip(modes)
	_follow_chip = _chip(modes)

	# The master meter, standing upright as on a mixing desk: the output level, and under it the recent peak, or a
	# word when the limiter is working or the output is clipping.
	_meter_panel = _panel(_root)
	var meter_box := VBoxContainer.new()
	meter_box.add_theme_constant_override("separation", 4)
	meter_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_meter_panel.add_child(meter_box)
	var meter_title := Label.new()
	meter_title.text = "MASTER"
	meter_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	meter_title.add_theme_font_size_override("font_size", 10)
	meter_title.add_theme_color_override("font_color", DIM)
	meter_box.add_child(meter_title)
	_meter = LevelMeter.new()
	_meter.vertical = true
	_meter.show_scale = true
	_meter.custom_minimum_size = Vector2(LevelMeter.SCALE_WIDTH + 24, 150)
	_meter.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	meter_box.add_child(_meter)
	_meter_text = Label.new()
	_meter_text.add_theme_font_size_override("font_size", 12)
	_meter_text.custom_minimum_size.x = 56
	_meter_text.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	meter_box.add_child(_meter_text)

	_build_piano(_root)

	# Outside the rest, so it shows over the mix window too.
	var notice_root := Control.new()
	notice_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	notice_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(notice_root)
	_notice_panel = _panel(notice_root)
	_notice = Label.new()
	_notice.add_theme_font_size_override("font_size", 14)
	_notice_panel.add_child(_notice)
	_notice_panel.visible = false
	app.session.notice.connect(func(text: String) -> void:
		_notice.text = Hints.keys(text)
		_notice_until = Time.get_ticks_msec() + 2500)


func _process(_delta: float) -> void:
	_frame += 1
	_notice_panel.visible = Time.get_ticks_msec() < _notice_until and not app.title.is_open()
	if _notice_panel.visible:
		_notice_panel.reset_size()
		_notice_panel.position = Vector2(14, 14 + (_stats_panel.size.y + 8 if _stats_panel.visible and _root.visible else 0.0))
	var covered := false
	for panel in [app.title, app.menu, app.sequencer, app.mixer, app.amp_panel, app.speaker_panel, app.mic_panel, app.instrument_menu, app.edit_window]:
		covered = covered or (panel != null and panel.is_open())
	_root.visible = not covered
	if covered:
		return
	var vp := get_viewport().get_visible_rect().size

	_stats_panel.visible = app.settings.show_stats
	if app.settings.show_stats and _frame % 20 == 1:
		var s := audio.get_stats()
		if s.is_empty() or not s.get("device_running", false):
			_stats.text = "Audio is not running"
		else:
			_stats.text = "%s\n%d Hz  ·  %d samples  ·  %.1f ms out  ·  CPU %.0f %%" % [
				s.output_device, s.sample_rate, s.block_size, s.output_latency_ms, 100.0 * float(s.cpu_load)]

	# The beat: a dot for each beat of the bar, the tempo, and whether the click is on.
	var step := int(audio.get_transport().get("step", -1))
	var beat := (step / 4) % 4 if step >= 0 else -1
	var dots := ""
	for i in 4:
		dots += "● " if i == beat else "○ "
	_beat.text = "%s  %d BPM%s" % [dots if app.sequence_running else "■  stopped  · ", roundi(app.tempo), "  ·  click" if app.settings.click else ""]
	var timeline = app.timeline
	if timeline.is_record():  # a Record room: where the music is on the timeline, and whether it is recording
		var at: float = timeline.position()
		var counting: int = timeline.counting_in()
		var state: String = {"count-in": "●  COUNT-IN %d" % counting, "pre-roll": "●  PRE-ROLL", "post-roll": "●  POST-ROLL",
			"recording": "●  LOOP REC" if timeline._looping else "●  REC"}.get(timeline.phase(), "▶" if timeline.playing else "■")
		var seconds: float = maxf(at, 0.0) * timeline.step_seconds()
		_beat.text = "%s   %d | %d   %d:%04.1f   ·   %s%d BPM%s" % [state, int(at / 16.0) + 1, int(fmod(at, 16.0) / 4.0) + 1,
			int(seconds / 60.0), fmod(seconds, 60.0),
			"⟳ %s   ·   " % loop_text(timeline.loop_start, timeline.loop_end) if timeline.loop_on else "",
			roundi(app.tempo), "  ·  click" if app.settings.click else ""]
		_beat.add_theme_color_override("font_color", Color(1.0, 0.4, 0.38) if timeline.recording else DIM)
	else:
		_beat.add_theme_color_override("font_color", DIM)
	_beat_panel.reset_size()
	_beat_panel.position = Vector2(vp.x - _beat_panel.size.x - 14, 14)

	_light_chip(_binaural_chip, "BINAURAL", app.settings.binaural, BINAURAL_BLUE)
	var hearing_mix: bool = app.settings.monitor == "mix"
	_light_chip(_monitor_chip, "HEADPHONE MIX" if hearing_mix else "ROOM", true, MONITOR_GREEN if hearing_mix else Color(0.78, 0.8, 0.86))
	_follow_chip.visible = timeline.is_record() and app.settings.insertion_follows
	_light_chip(_follow_chip, "FOLLOWS PLAYBACK", true, FOLLOW_AMBER)
	_modes_panel.reset_size()
	_modes_panel.position = Vector2(_beat_panel.position.x - _modes_panel.size.x - 8, 14)

	_meter_panel.visible = app.settings.show_meter
	if app.settings.show_meter:
		var m: Dictionary = app.meter
		_meter.feed([m.get("peak_l", 0.0), m.get("peak_r", 0.0)], [m.get("rms_l", 0.0), m.get("rms_r", 0.0)])
		if app.meter_clipped:
			_meter_text.text = "CLIP"
			_meter_text.add_theme_color_override("font_color", LevelMeter.RED)
		elif app.meter_reduction_db > 0.1:
			_meter_text.text = "limit\n%.0f dB" % app.meter_reduction_db
			_meter_text.add_theme_color_override("font_color", WARN)
		else:
			_meter_text.text = "%.0f dB" % _meter.held_db()
			_meter_text.add_theme_color_override("font_color", DIM)
		_meter_panel.reset_size()
		_meter_panel.position = Vector2(vp.x - _meter_panel.size.x - 14, _beat_panel.position.y + _beat_panel.size.y + 8)

	_show_hint(vp)

	# One line of guidance: how to start, or where the menu is.
	var keys = app.bindings
	var playing: bool = player.playing != null or player.typing or player.plugin_open != null
	_prompt.text = "Click to look around  ·  Esc  menu and settings" if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED else keys_prompt()
	_prompt_panel.visible = not playing
	_prompt_panel.reset_size()
	if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		_prompt_panel.position = Vector2((vp.x - _prompt_panel.size.x) / 2, 14)
	else:
		_prompt_panel.position = Vector2(14, vp.y - _prompt_panel.size.y - 14)

	_piano.visible = playing
	var octaves := "%s %s  octave" % [keys.label("octave_down"), keys.label("octave_up")]
	if player.playing != null:
		var inst = player.playing
		if _piano_for != str(inst.get_instance_id()):
			_label_piano(inst)
		_piano_title.text = "Playing the %s" % inst.display_name
		var octave := "" if inst.drum_kit else "%s (lowest key C%d)  ·  " % [octaves, 4 + player.octave]
		# Its pattern's key, unless that key is a note just now (then the pattern waits until you get up).
		var pattern := "" if keys.NOTES.has(keys.key("edit")) else "%s  pattern  ·  " % keys.label("edit")
		_piano_help.text = "%s  stop  ·  %s%s%s  input %s  ·  %s  loop %s" % [keys.label("stop"), octave, pattern,
			keys.label("input"), "off" if inst.input_on else "on", keys.label("loop"), "on" if not inst.loop_on else "off"]
		_light_piano(inst.color)
	elif player.plugin_open != null:
		# A plug-in instrument's window is open above: the keys play it.
		var inst = player.plugin_open
		if _piano_for != str(inst.get_instance_id()):
			_label_piano(inst)
		_piano_title.text = "Playing the %s  ·  its window is open above" % inst.display_name
		_piano_help.text = "Esc, %s or a click in the room  close it  ·  %s (lowest key C%d)" % [keys.label("stop"), octaves, 4 + player.keyboard_octave]
		_light_piano(inst.color)
	elif player.typing:
		# The keyboard: every instrument whose input is on, wherever they stand.
		var armed: Array = app.armed_instruments()
		var drums_only := not armed.is_empty()
		var names := []
		for inst in armed:
			names.append(inst.display_name)
			drums_only = drums_only and inst.drum_kit
		var lead = armed[0] if not armed.is_empty() else null
		if _piano_for != (str(lead.get_instance_id()) if drums_only else "keyboard"):
			_label_piano(lead if drums_only else null)
		_piano_title.text = ("Keyboard  →  " + ", ".join(names)) if not armed.is_empty() else \
			"Keyboard: no instrument's input is on. Face one and press %s." % keys.label("input")
		_piano_title.add_theme_color_override("font_color", lead.color.lightened(0.3) if lead != null else WARN)
		_piano_help.text = "%s or Esc  close  ·  %s (lowest key C%d)  ·  arrows  walk and turn  ·  %s  input of what you face" % [
			keys.label("stop"), octaves, 4 + player.keyboard_octave, keys.label("input")]
		_light_piano(lead.color if lead != null else Color(0.6, 0.62, 0.68))


## How far up the screen the on-screen keyboard reaches (0 to 1), for a plug-in's window to stand just above it.
func piano_top_fraction() -> float:
	var vp := get_viewport().get_visible_rect().size
	return clampf((_piano.get_combined_minimum_size().y + 18.0 + 10.0) / maxf(vp.y, 1.0), 0.0, 0.9)


func _light_piano(lit: Color) -> void:
	var vp := get_viewport().get_visible_rect().size
	_piano.reset_size()
	_piano.position = Vector2((vp.x - _piano.size.x) / 2, vp.y - _piano.size.y - 18)
	for key in _piano_keys:
		var entry: Dictionary = _piano_keys[key]
		entry.rect.color = lit.lightened(0.15) if player.held.has(key) else entry.idle


## The instruction card beside the crosshair: for what you're facing, what you're carrying, or a removal to confirm.
func _show_hint(vp: Vector2) -> void:
	var title := ""
	var tint := Color.WHITE
	var rows := []  # [key, action]; an empty key draws a line, for the removal at the bottom
	var keys = app.bindings
	if player.remove_pending != null:
		title = "Remove %s?" % player.remove_pending.display_name
		tint = WARN
		rows = [[keys.label("remove"), "yes, remove it"], ["look away", "keep it"]]
	elif player.carried != null:
		title = "Carrying %s" % player.carried.display_name
		tint = player.carried.color.lightened(0.3)
		rows = [["%s or click" % keys.label("carry"), "put it down"], [keys.label("duplicate"), "duplicate it"], ["", ""],
			[keys.label("remove"), "remove"]]
	elif player.clear_pending != null:
		title = "Clear %s's loop?" % player.clear_pending.display_name
		tint = WARN
		rows = [[keys.label("loop_clear"), "yes, clear it"], ["look away", "keep it"]]
	elif player.target != null and player.playing == null:
		var t = player.target
		title = t.display_name
		tint = t.color.lightened(0.3)
		if t.is_amp:  # an amp, its pedals, and its loop pedal if it has one
			var loop: Dictionary = t.looper
			var state: String = loop.get("state", "none")
			rows.append([keys.label("input"), "input off" if t.input_on else "input on"])
			rows.append([keys.label("edit"), "amp and pedals"])
			var count: int = t.pedals.size()
			if count > 0:
				rows.append(["1" if count == 1 else "1-%d" % count, "stamp on a pedal" if count == 1 else "stamp on the pedals"])
			if state != "none":
				rows.append([keys.label("loop_switch"), {"empty": "record a loop", "waiting": "cancel (waiting for the bar)", "recording": "close the loop",
					"playing": "overdub", "overdubbing": "stop overdubbing", "stopped": "play the loop"}[state]])
			if state in ["playing", "overdubbing", "recording"]:
				rows.append([keys.label("loop_stop"), "stop the loop"])
			if loop.get("can_undo", false):
				rows.append([keys.label("loop_undo"), "undo the last overdub"])
			elif loop.get("can_redo", false):
				rows.append([keys.label("loop_undo"), "redo the overdub"])
			if state not in ["empty", "waiting", "none"]:
				rows.append([keys.label("loop_clear"), "clear the loop (press twice)"])
			rows.append([keys.label("loop"), "unmute" if t.muted else "mute"])
		elif t.playable:
			rows.append([keys.label("play"), "play" if player.can_play_target() else "play (step closer)"])
			rows.append([keys.label("edit"), "edit its pattern"])
			if t.plays_plugin:
				rows.append([keys.label("plugin_window"), "its plug-in's window"])
			rows.append([keys.label("input"), "input off" if t.input_on else "input on"])
			rows.append([keys.label("loop"), "loop on" if not t.loop_on else "loop off"])
		elif t.is_mic:  # a microphone: where it stands and points, its gain; hearing what it hears
			rows.append([keys.label("edit"), "where it stands and points"])
			rows.append([keys.label("input"), "stop hearing it" if t.input_on else "hear what it hears"])
			rows.append([keys.label("loop"), "unmute" if t.muted else "mute"])
		elif not t.is_amp:
			rows.append([keys.label("input"), "input off" if t.input_on else "input on"])
			rows.append([keys.label("edit"), "volume and input"])
			rows.append([keys.label("loop"), "unmute" if t.muted else "mute"])
		rows.append([keys.label("carry"), "carry"])
		rows.append([keys.label("duplicate"), "duplicate"])
		rows.append(["", ""])
		rows.append([keys.label("remove"), "remove (press twice)"])
	_hint_panel.visible = title != ""
	if title == "":
		return
	var signature := title + str(rows)
	if signature != _hint_signature:
		_hint_signature = signature
		_hint_title.text = title
		_hint_title.add_theme_color_override("font_color", tint)
		for child in _hint_rows.get_children():
			_hint_rows.remove_child(child)  # now, so the card is measured without them
			child.queue_free()
		for row in rows:
			if row[0] == "":
				var line := HSeparator.new()
				line.mouse_filter = Control.MOUSE_FILTER_IGNORE
				_hint_rows.add_child(line)
				continue
			var line := HBoxContainer.new()
			line.add_theme_constant_override("separation", 10)
			line.mouse_filter = Control.MOUSE_FILTER_IGNORE
			var key := Label.new()
			key.text = row[0]
			key.custom_minimum_size.x = 92
			key.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
			key.add_theme_color_override("font_color", tint if player.remove_pending == null else WARN)
			key.add_theme_font_size_override("font_size", 14)
			line.add_child(key)
			var action := Label.new()
			action.text = row[1]
			action.add_theme_font_size_override("font_size", 14)
			action.add_theme_color_override("font_color", Color(0.86, 0.88, 0.93))
			line.add_child(action)
			_hint_rows.add_child(line)
	_hint_panel.reset_size()
	# At the right-hand side, clear of what you're looking at, and left of the master meter if they would meet.
	var at := Vector2(vp.x - _hint_panel.size.x - 24, vp.y / 2 - _hint_panel.size.y / 2)
	if _meter_panel.visible and at.y < _meter_panel.position.y + _meter_panel.size.y + 8:
		at.x = minf(at.x, _meter_panel.position.x - _hint_panel.size.x - 12)
	_hint_panel.position = at


func hint_lines() -> Array:  # what the card says, line by line (for the automated checks)
	var lines := [_hint_title.text]
	for row in _hint_rows.get_children():
		if row is HBoxContainer:
			lines.append("%s %s" % [row.get_child(0).text, row.get_child(1).text])
	return lines


func _build_piano(root: Control) -> void:
	_piano = _panel(root)
	var box := VBoxContainer.new()
	_piano.add_child(box)
	_piano_title = Label.new()
	_piano_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(_piano_title)
	_piano_help = Label.new()
	_piano_help.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_piano_help.add_theme_color_override("font_color", DIM)
	_piano_help.add_theme_font_size_override("font_size", 14)
	box.add_child(_piano_help)
	var keyboard := Control.new()
	keyboard.custom_minimum_size = Vector2(438, 104)
	keyboard.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	box.add_child(keyboard)
	var white_semitones := [0, 2, 4, 5, 7, 9, 11, 12, 14, 16]
	var black_semitones := [1, 3, 6, 8, 10, 13, 15]
	for i in WHITE_KEYS.size():
		_piano_key(keyboard, WHITE_KEYS[i][0], WHITE_KEYS[i][1], Vector2(i * 44, 0), Vector2(42, 104),
			Color(0.91, 0.92, 0.96), Color(0.33, 0.35, 0.44), white_semitones[i], true)
	for i in BLACK_KEYS.size():
		var k: Array = BLACK_KEYS[i]
		_piano_key(keyboard, k[0], k[1], Vector2((k[2] + 1) * 44 - 15, 0), Vector2(28, 64),
			Color(0.09, 0.1, 0.15), DIM, black_semitones[i], false)
	_piano.visible = false


func _piano_key(parent: Control, key: int, letter: String, pos: Vector2, size: Vector2, idle: Color, ink: Color,
		semitone: int, white: bool) -> void:
	var rect := ColorRect.new()
	rect.position = pos
	rect.size = size
	rect.color = idle
	rect.mouse_filter = Control.MOUSE_FILTER_STOP  # it can be clicked to play, and a click on it isn't one in the room
	rect.gui_input.connect(func(event: InputEvent) -> void:
		if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed:
				player.piano_down(key)
			else:
				player.piano_up(key)
			rect.accept_event())
	parent.add_child(rect)
	var label := Label.new()
	label.text = letter
	label.add_theme_color_override("font_color", ink)
	label.add_theme_font_size_override("font_size", 12)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.size = Vector2(size.x, 18)
	label.position = Vector2(0, size.y - 22)
	rect.add_child(label)
	var piece := Label.new()  # which drum this key hits, shown at the drums only
	piece.add_theme_color_override("font_color", ink)
	piece.add_theme_font_size_override("font_size", 11)
	piece.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	piece.size = Vector2(size.x, 16)
	piece.position = Vector2(0, 65 if white else 6)  # on a white key, just below where the black keys end
	piece.visible = false
	rect.add_child(piece)
	_piano_keys[key] = {"rect": rect, "idle": idle, "piece": piece, "semitone": semitone, "white": white}


## Names the keys for an instrument: a drum kit's pieces, or nothing beyond the notes (null: the keyboard).
func _label_piano(inst) -> void:
	_piano_for = str(inst.get_instance_id()) if inst != null else "keyboard"
	var drums: bool = inst != null and inst.drum_kit
	if inst != null:
		_piano_title.add_theme_color_override("font_color", inst.color.lightened(0.3))
	for key in _piano_keys:
		var entry: Dictionary = _piano_keys[key]
		entry.piece.visible = drums
		if drums:
			var names: Array = DRUM_LABELS.get(audio.get_drum_piece_name(60 + int(entry.semitone), inst.kind), ["", ""])
			entry.piece.text = names[0] if entry.white else names[1]


## A small label that lights up in its colour while what it names is on.
## A loop range for the screen: whole bars as "1–4", anything else bar | beat, as "2 | 1–2 | 3".
static func loop_text(start: float, end: float) -> String:
	if is_zero_approx(fmod(start, 16.0)) and is_zero_approx(fmod(end, 16.0)):
		return "%d–%d" % [int(start / 16.0) + 1, int(end / 16.0)]
	return "%d | %d–%d | %d" % [int(start / 16.0) + 1, int(fmod(start, 16.0) / 4.0) + 1, int(end / 16.0) + 1, int(fmod(end, 16.0) / 4.0) + 1]


## The line of keys at the foot of the screen in the room: the menu, the mix window (and in a Record room the edit
## window), the instrument menu and the keyboard.
func keys_prompt() -> String:
	var keys = app.bindings
	return "Esc  menu  ·  %s  mix window%s  ·  %s  add an instrument  ·  %s  keyboard" % [keys.label("mixer"),
		"  ·  %s  edit window" % keys.label("edit_window") if app.timeline.is_record() else "", keys.label("add"), keys.label("keyboard")]


func _chip(parent: Control) -> Label:
	var chip := Label.new()
	chip.add_theme_font_size_override("font_size", 12)
	var style := StyleBoxFlat.new()
	style.set_corner_radius_all(4)
	style.set_border_width_all(1)
	style.content_margin_left = 7
	style.content_margin_right = 7
	style.content_margin_top = 2
	style.content_margin_bottom = 2
	chip.add_theme_stylebox_override("normal", style)
	parent.add_child(chip)
	return chip


func _light_chip(chip: Label, name: String, on: bool, lit: Color) -> void:
	chip.text = name if on else name + " OFF"
	var style: StyleBoxFlat = chip.get_theme_stylebox("normal")
	style.bg_color = lit if on else Color(0, 0, 0, 0)
	style.border_color = lit if on else Color(1, 1, 1, 0.25)
	chip.add_theme_color_override("font_color", Color(0.06, 0.07, 0.09) if on else Color(0.62, 0.65, 0.74, 0.8))


func _panel(parent: Control) -> PanelContainer:
	var panel := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = PANEL_BG
	style.set_corner_radius_all(10)
	style.set_border_width_all(1)
	style.border_color = Color(1, 1, 1, 0.12)
	style.content_margin_left = 12
	style.content_margin_right = 12
	style.content_margin_top = 8
	style.content_margin_bottom = 8
	panel.add_theme_stylebox_override("panel", style)
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(panel)
	return panel
