extends CanvasLayer
## What stays on screen while playing: the crosshair, a hint about what you're facing, the piano while you play
## the Keys, and (if switched on in the menu) a small audio readout. Everything else lives in the menu.

const PANEL_BG := Color(0.05, 0.06, 0.09, 0.82)
const DIM := Color(0.62, 0.65, 0.74)
const WARN := Color(1.0, 0.61, 0.48)
const WHITE_KEYS := [[KEY_A, "A"], [KEY_S, "S"], [KEY_D, "D"], [KEY_F, "F"], [KEY_G, "G"], [KEY_H, "H"], [KEY_J, "J"],
	[KEY_K, "K"], [KEY_L, "L"], [KEY_SEMICOLON, ";"]]
const BLACK_KEYS := [[KEY_W, "W", 0], [KEY_E, "E", 1], [KEY_T, "T", 3], [KEY_Y, "Y", 4], [KEY_U, "U", 5],
	[KEY_O, "O", 7], [KEY_P, "P", 8]]

var app
var audio: SoundRoomAudio
var player

var _root: Control
var _stats_panel: PanelContainer
var _stats: Label
var _hint: Label
var _hint_panel: PanelContainer
var _prompt_panel: PanelContainer
var _prompt: Label
var _piano: PanelContainer
var _piano_title: Label
var _piano_keys := {}  # physical key → [ColorRect, idle colour]
var _frame := 0


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

	_hint_panel = _panel(_root)
	_hint = Label.new()
	_hint_panel.add_child(_hint)

	_prompt_panel = _panel(_root)
	_prompt = Label.new()
	_prompt.add_theme_color_override("font_color", DIM)
	_prompt_panel.add_child(_prompt)

	_build_piano(_root)


func _process(_delta: float) -> void:
	_frame += 1
	var menu_open: bool = app.menu != null and app.menu.is_open()
	_root.visible = not menu_open
	if menu_open:
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
	_hint_panel.reset_size()
	_hint_panel.position = Vector2((vp.x - _hint_panel.size.x) / 2, vp.y / 2 + 24)

	# One line of guidance: how to start, or where the menu is.
	var playing: bool = player.playing != null
	_prompt.text = "Click to look around  ·  Esc  menu and settings" if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED else "Esc  menu"
	_prompt_panel.visible = not playing
	_prompt_panel.reset_size()
	if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		_prompt_panel.position = Vector2((vp.x - _prompt_panel.size.x) / 2, 14)
	else:
		_prompt_panel.position = Vector2(14, vp.y - _prompt_panel.size.y - 14)

	_piano.visible = playing
	if playing:
		_piano.reset_size()
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
