extends CanvasLayer
## The title screen. The room is already alive behind it: a camera circles under the ceiling, and since the
## camera is also the listener, the music turns around you while you wait. Entering hands both over to the player.

const ACCENT := Color(0.49, 0.89, 0.82)
const DIM := Color(0.62, 0.65, 0.74)
const WARN := Color(1.0, 0.61, 0.48)
const ORBIT_SECONDS := 90.0  # once round the room
const LOOK_AT := Vector3(0.0, 0.8, -0.3)
const TITLE_GAIN := 0.6      # the music plays a little quieter behind the title
const TAGLINE := "A room of instruments, heard from where you stand."

var app
var audio: SoundRoomAudio
var camera: Camera3D
var buttons := {}  # "enter", "audio", "settings", "controls", "quit" → Button

var _open := false
var _leaving := false
var _angle := 0.6
var _status_in := 0.0
var _scale := 0.0  # the size the text was last laid out for

var _ui: Control
var _title: Label
var _tagline: Label
var _status: Label
var _fade: ColorRect


func setup(the_app) -> void:
	app = the_app
	audio = app.audio
	layer = 8
	camera = Camera3D.new()
	camera.fov = 62.0
	camera.near = 0.05
	app.add_child(camera)
	_build()
	visible = false


func is_open() -> bool:
	return _open


func open() -> void:
	_open = true
	_leaving = false
	_fade.color.a = 0.0
	visible = true
	_place_camera()
	camera.make_current()
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	app.set_stage_gain(TITLE_GAIN)
	for inst in app.instruments:
		inst.set_label_visible(false)
	_status_in = 0.0
	_show_ui(true)


func _process(delta: float) -> void:
	if not visible:
		return
	if _open:
		_angle = fposmod(_angle + TAU * delta / ORBIT_SECONDS, TAU)
		_place_camera()
		audio.set_listener(camera.global_transform)
		# The menu covers the title while it is open; hiding the buttons also keeps Enter from reaching them.
		var covered: bool = app.menu != null and app.menu.is_open()
		if _ui.visible == covered and not _leaving:
			_show_ui(not covered)
	_layout()
	_status_in -= delta
	if _status_in <= 0.0:
		_status_in = 0.5
		_refresh_status()


## An oval a little in from the room's sides and just under its ceiling (above the default room's wall).
func _place_camera() -> void:
	var room: Vector3 = app.room.size
	var at := Vector3(sin(_angle) * (room.x / 2 - 1.6), room.y - 0.65, cos(_angle) * (room.z / 2 - 1.3))
	camera.look_at_from_position(at, LOOK_AT, Vector3.UP)


func _show_ui(on: bool) -> void:
	_ui.visible = on
	if on:
		buttons.enter.grab_focus()


# ── Building ────────────────────────────────────────────────────────────────────────────────────────────────

func _build() -> void:
	_ui = Control.new()
	_ui.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_ui)

	# Darker on the left, where the words are, clear on the right, where the room shows.
	var gradient := Gradient.new()
	gradient.set_color(0, Color(0.01, 0.012, 0.02, 0.88))
	gradient.set_color(1, Color(0.01, 0.012, 0.02, 0.0))
	var texture := GradientTexture2D.new()
	texture.gradient = gradient
	texture.width = 64
	texture.height = 4
	texture.fill_to = Vector2(0.72, 0.0)
	var shade := TextureRect.new()
	shade.texture = texture
	shade.stretch_mode = TextureRect.STRETCH_SCALE
	shade.set_anchors_preset(Control.PRESET_FULL_RECT)
	shade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_ui.add_child(shade)

	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	margin.add_theme_constant_override("margin_left", 84)
	margin.add_theme_constant_override("margin_right", 40)
	margin.add_theme_constant_override("margin_top", 28)
	margin.add_theme_constant_override("margin_bottom", 26)
	_ui.add_child(margin)
	var column := VBoxContainer.new()
	column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	margin.add_child(column)

	var top := Control.new()
	top.size_flags_vertical = Control.SIZE_EXPAND_FILL
	top.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_child(top)

	var heavy := FontVariation.new()
	heavy.base_font = ThemeDB.fallback_font
	heavy.variation_embolden = 0.7
	heavy.spacing_glyph = 1
	_title = Label.new()
	_title.text = "SoundRoom"
	_title.add_theme_font_override("font", heavy)
	column.add_child(_title)
	_tagline = Label.new()
	_tagline.text = TAGLINE
	_tagline.add_theme_color_override("font_color", DIM)
	column.add_child(_tagline)
	var gap := Control.new()
	gap.custom_minimum_size.y = 18
	column.add_child(gap)

	_button(column, "enter", "Enter the room", _on_enter_pressed)
	_button(column, "audio", "Audio setup", _on_menu_pressed.bind("ENGINE_TAB"))
	_button(column, "settings", "Settings", _on_menu_pressed.bind("SETTINGS_TAB"))
	_button(column, "controls", "Controls", _on_menu_pressed.bind("CONTROLS_TAB"))
	_button(column, "quit", "Quit", _on_quit_pressed)

	var bottom := Control.new()
	bottom.size_flags_vertical = Control.SIZE_EXPAND_FILL
	bottom.size_flags_stretch_ratio = 0.8
	bottom.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_child(bottom)
	_status = Label.new()
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.add_theme_font_size_override("font_size", 13)
	column.add_child(_status)

	_fade = ColorRect.new()  # for the cut between the title's camera and the player's
	_fade.color = Color(0, 0, 0, 0)
	_fade.set_anchors_preset(Control.PRESET_FULL_RECT)
	_fade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_fade)


func _button(parent: Control, key: String, text: String, on_pressed: Callable) -> void:
	var button := Button.new()
	button.text = text
	button.alignment = HORIZONTAL_ALIGNMENT_LEFT
	button.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	for state in ["normal", "hover", "pressed", "focus"]:
		var style := StyleBoxFlat.new()
		style.bg_color = Color(1, 1, 1, {"normal": 0.0, "hover": 0.09, "pressed": 0.16, "focus": 0.0}[state])
		style.set_corner_radius_all(8)
		style.content_margin_left = 16
		style.content_margin_right = 22
		style.content_margin_top = 7
		style.content_margin_bottom = 7
		if state == "focus":  # a bar at the left marks the one the keyboard is on
			style.border_width_left = 3
			style.border_color = ACCENT
		button.add_theme_stylebox_override(state, style)
	var ink := ACCENT if key == "enter" else Color(0.9, 0.91, 0.95)
	for colour in ["font_color", "font_focus_color", "font_hover_color", "font_pressed_color"]:
		button.add_theme_color_override(colour, ink.lightened(0.25) if colour == "font_hover_color" else ink)
	button.pressed.connect(on_pressed)
	parent.add_child(button)
	buttons[key] = button


## Sizes the words for the window: smaller when it is short, or when the text size setting is large.
func _layout() -> void:
	var vp := get_viewport().get_visible_rect().size
	var k := clampf(minf(vp.y / 760.0, vp.x / 1100.0), 0.5, 1.0)
	if is_equal_approx(k, _scale):
		return
	_scale = k
	_title.add_theme_font_size_override("font_size", roundi(84 * k))
	_tagline.add_theme_font_size_override("font_size", roundi(19 * k))
	for key in buttons:
		buttons[key].add_theme_font_size_override("font_size", roundi((26 if key == "enter" else 22) * k))


func _refresh_status() -> void:
	var s: Dictionary = audio.get_stats()
	if not s.get("device_running", false):
		_status.text = "Audio is not running%s. Choose a device in Audio setup." % (": " + app.audio_error if app.audio_error != "" else "")
		_status.add_theme_color_override("font_color", WARN)
	elif float(s.device_ms) > 40.0:
		_status.text = "Playing through %s, which adds %.0f ms by itself, typical of Bluetooth. Wired headphones avoid the delay." % [
			s.output_device, float(s.device_ms)]
		_status.add_theme_color_override("font_color", WARN)
	else:
		_status.text = "Playing through %s  ·  %.1f kHz  ·  %d samples  ·  %.1f ms\nBest on wired headphones: every sound is placed around you." % [
			s.output_device, float(s.sample_rate) / 1000.0, s.block_size, s.output_latency_ms]
		_status.add_theme_color_override("font_color", DIM)


# ── Handlers ────────────────────────────────────────────────────────────────────────────────────────────────

## Fade out, cut to the player's view, fade in, with the music rising to its full level across the two.
func _on_enter_pressed() -> void:
	if _leaving or not _open:
		return
	_leaving = true
	var tween := create_tween()
	tween.tween_property(_fade, "color:a", 1.0, 0.3)
	tween.tween_callback(_cut_to_room)
	tween.tween_property(_fade, "color:a", 0.0, 0.45)
	tween.tween_callback(_finish)
	create_tween().tween_method(app.set_stage_gain, TITLE_GAIN, 1.0, 0.75)  # alongside, not in step with the fade


func _cut_to_room() -> void:
	_ui.visible = false
	_open = false  # from here the player listens, moves and looks
	app.player.camera.make_current()
	for inst in app.instruments:
		inst.set_label_visible(true)
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _finish() -> void:
	_leaving = false
	if not _open:
		visible = false


func _on_menu_pressed(page: String) -> void:
	app.menu.open(app.menu.get(page))


func _on_quit_pressed() -> void:
	get_tree().quit()
