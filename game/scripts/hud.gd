extends CanvasLayer
## On-screen status, crosshair, context hints, controls, and the piano shown while playing the Keys.

const PANEL_BG := Color(0.05, 0.06, 0.09, 0.82)
const DIM := Color(0.62, 0.65, 0.74)
const WARN := Color(1.0, 0.61, 0.48)
const WHITE_KEYS := [[KEY_A, "A"], [KEY_S, "S"], [KEY_D, "D"], [KEY_F, "F"], [KEY_G, "G"], [KEY_H, "H"], [KEY_J, "J"],
	[KEY_K, "K"], [KEY_L, "L"], [KEY_SEMICOLON, ";"]]
const BLACK_KEYS := [[KEY_W, "W", 0], [KEY_E, "E", 1], [KEY_T, "T", 3], [KEY_Y, "Y", 4], [KEY_U, "U", 5],
	[KEY_O, "O", 7], [KEY_P, "P", 8]]

var audio: SoundRoomAudio
var player

var _binaural_value: Label
var _reverb_value: Label
var _latency_value: Label
var _cpu_value: Label
var _midi_value: Label
var _input_value: Label
var _midi_events := 0
var _midi_flash := 0.0
var _hint: Label
var _hint_panel: PanelContainer
var _capture: PanelContainer
var _help: PanelContainer
var _piano: PanelContainer
var _piano_title: Label
var _piano_keys := {}  # physical key → [ColorRect, idle colour]
var _frame := 0


func setup(audio_core: SoundRoomAudio, the_player) -> void:
	audio = audio_core
	player = the_player
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)

	# Status, top left
	var status := _panel(root)
	status.position = Vector2(14, 14)
	var grid := GridContainer.new()
	grid.columns = 3
	grid.add_theme_constant_override("h_separation", 14)
	status.add_child(grid)
	_binaural_value = _row(grid, "Binaural (HRTF)", "B")
	_reverb_value = _row(grid, "Room reverb", "R")
	_midi_value = _row(grid, "MIDI", "")
	_input_value = _row(grid, "Live input", "I")
	_latency_value = _row(grid, "Output latency", "")
	_cpu_value = _row(grid, "Audio CPU", "")

	# Crosshair and hint, centre
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
	root.add_child(cross)

	_hint_panel = _panel(root)
	_hint_panel.set_anchors_preset(Control.PRESET_CENTER_TOP)
	_hint = Label.new()
	_hint_panel.add_child(_hint)

	_capture = _panel(root)
	var capture_text := Label.new()
	capture_text.text = "Click to capture the mouse"
	capture_text.add_theme_color_override("font_color", DIM)
	_capture.add_child(capture_text)

	# Controls, bottom left
	_help = _panel(root)
	var help := Label.new()
	help.text = "W A S D  move    Shift  run    mouse  look\nG or click  carry an instrument, put it down\nF  mute the one you're facing    E  play the Keys up close\nA MIDI keyboard plays the Keys from anywhere\nI  microphone / audio input into the Amp\nB  binaural on/off    R  reverb on/off    Esc  release mouse"
	help.add_theme_color_override("font_color", DIM)
	help.add_theme_font_size_override("font_size", 13)
	_help.add_child(help)

	_build_piano(root)


func _process(delta: float) -> void:
	_frame += 1
	var events := audio.get_midi_event_count()
	if events != _midi_events:
		_midi_events = events
		_midi_flash = 0.15
	_midi_flash = maxf(_midi_flash - delta, 0.0)
	_midi_value.add_theme_color_override("font_color", Color(1.0, 0.48, 0.82) if _midi_flash > 0.0 else Color.WHITE)
	var vp := get_viewport().get_visible_rect().size
	_binaural_value.text = "on" if player.binaural else "off (plain stereo)"
	_binaural_value.add_theme_color_override("font_color", Color.WHITE if player.binaural else WARN)
	_reverb_value.text = "on" if player.reverb else "off"
	_reverb_value.add_theme_color_override("font_color", Color.WHITE if player.reverb else WARN)
	if _frame % 20 == 1:
		var s := audio.get_stats()
		if s.is_empty():
			_latency_value.text = "audio not running"
			_cpu_value.text = "-"
		else:
			var ms: float = s.output_latency_ms
			_latency_value.text = "%.1f ms" % ms
			_latency_value.add_theme_color_override("font_color", WARN if ms > 40.0 else Color.WHITE)
			_cpu_value.text = "%.0f %%" % (100.0 * float(s.cpu_load))
		var devices := audio.get_midi_devices()
		if devices.is_empty():
			_midi_value.text = "no controller"
		else:
			_midi_value.text = devices[0] + ("" if devices.size() == 1 else "  +%d" % (devices.size() - 1))
		if player.live_input:
			_input_value.text = "on  (%s)" % s.get("input_device", "input")
			_input_value.add_theme_color_override("font_color", Color.WHITE)
		else:
			_input_value.text = "off" if player.live_input_error == "" else "unavailable"
			_input_value.add_theme_color_override("font_color", DIM if player.live_input_error == "" else WARN)

	var hint := ""
	if player.carried != null:
		hint = "Carrying %s  ·  G or click to put it down" % player.carried.display_name
	elif player.target != null and player.playing == null:
		var t = player.target
		var play := ""
		if t.playable:
			play = "E play  ·  " if player.can_play_target() else "step closer to play  ·  "
		hint = "%s  ·  %sG carry  ·  F %s" % [t.display_name, play, "unmute" if t.muted else "mute"]
	_hint.text = hint
	_hint_panel.visible = hint != ""
	_hint_panel.position = Vector2((vp.x - _hint_panel.size.x) / 2, vp.y / 2 + 24)
	_hint_panel.reset_size()

	_capture.visible = Input.mouse_mode != Input.MOUSE_MODE_CAPTURED
	_capture.position = Vector2((vp.x - _capture.size.x) / 2, 14)

	var playing: bool = player.playing != null
	_piano.visible = playing
	_help.visible = not playing
	_help.position = Vector2(14, vp.y - _help.size.y - 14)
	if playing:
		_piano.position = Vector2((vp.x - _piano.size.x) / 2, vp.y - _piano.size.y - 18)
		_piano_title.text = "Q  stop playing    Z X  octave (lowest key C%d)" % (4 + player.octave)
		for key in _piano_keys:
			var entry: Array = _piano_keys[key]
			entry[0].color = Color(1.0, 0.48, 0.82) if player.held.has(key) else entry[1]


func _build_piano(root: Control) -> void:
	_piano = _panel(root)
	var box := VBoxContainer.new()
	_piano.add_child(box)
	_piano_title = Label.new()
	_piano_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_piano_title.add_theme_color_override("font_color", DIM)
	box.add_child(_piano_title)
	var keyboard := Control.new()
	keyboard.custom_minimum_size = Vector2(438, 104)
	box.add_child(keyboard)
	for i in WHITE_KEYS.size():
		_piano_key(keyboard, WHITE_KEYS[i][0], WHITE_KEYS[i][1], Vector2(i * 44, 0), Vector2(42, 104),
			Color(0.91, 0.92, 0.96), Color(0.33, 0.35, 0.44))
	for k in BLACK_KEYS:
		_piano_key(keyboard, k[0], k[1], Vector2((k[2] + 1) * 44 - 15, 0), Vector2(28, 64),
			Color(0.09, 0.1, 0.15), DIM)
	_piano.visible = false


func _piano_key(parent: Control, key: int, letter: String, pos: Vector2, size: Vector2, idle: Color, ink: Color) -> void:
	var rect := ColorRect.new()
	rect.position = pos
	rect.size = size
	rect.color = idle
	parent.add_child(rect)
	var label := Label.new()
	label.text = letter
	label.add_theme_color_override("font_color", ink)
	label.add_theme_font_size_override("font_size", 12)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.size = Vector2(size.x, 18)
	label.position = Vector2(0, size.y - 22)
	rect.add_child(label)
	_piano_keys[key] = [rect, idle]


func _row(grid: GridContainer, name: String, key: String) -> Label:
	var label := Label.new()
	label.text = name
	label.add_theme_color_override("font_color", DIM)
	grid.add_child(label)
	var value := Label.new()
	value.text = "-"
	grid.add_child(value)
	var key_label := Label.new()
	key_label.text = key
	key_label.add_theme_color_override("font_color", DIM)
	grid.add_child(key_label)
	return value


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
