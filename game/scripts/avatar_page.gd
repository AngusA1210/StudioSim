extends CanvasLayer
## Avatar customization, from the title screen: your name, your height and how your body looks (a male or female build,
## skin, hair, and a shirt, trousers and shoes, each a style and a colour: avatar.gd's LOOK), your body turning beside
## them as it will stand in the room, the others seeing it so. Set here, before you go into a room, rather than in the
## room's menu, as a player joining others would be: nobody grows taller in the middle of a session.

const UI := preload("res://scripts/ui.gd")
const Hints := preload("res://scripts/hints.gd")
const Avatar := preload("res://scripts/avatar.gd")
const Player := preload("res://scripts/player.gd")
const DIM := Color(0.62, 0.65, 0.74)
const ACCENT := Color(0.49, 0.89, 0.82)
const NAME_LENGTH := 24
const TURN_SECONDS := 12.0  # (your body, once round)
const SWATCH := Vector2(22, 22)
# The choices, in order: [what it is, its label, its styles (Avatar's), its colours' key, its colours, its hint].
const ROWS := [
	["body", "Body", Avatar.BODIES, "", [], "A man's build or a woman's: the shoulders, the hips and the chest"],
	["skin", "Skin", {}, "skin", Avatar.SKINS, "Your skin's colour"],
	["hair", "Hair", Avatar.HAIRS, "hair_color", Avatar.HAIR_COLORS, "How your hair is cut, and its colour"],
	["shirt", "Shirt", Avatar.SHIRTS, "shirt_color", Avatar.CLOTHES, "What you wear on top, and its colour"],
	["pants", "Pants", Avatar.PANTS, "pants_color", Avatar.CLOTHES, "Trousers, shorts or a skirt, and its colour"],
	["shoes", "Shoes", Avatar.SHOES, "shoes_color", Avatar.CLOTHES, "What is on your feet, and its colour"],
]

var app
var _root: Control
var _panel: PanelContainer
var _name: LineEdit
var _height: HSlider
var _height_value: Label
var _styles := {}  # a row's key → its OptionButton (the build: its two buttons)
var _swatches := {}  # a colour's key → its swatches (Buttons)
var _builds := {}  # "male", "female" → Button
var _hint: Label
var _body  # an Avatar, in the picture
var _picture_camera: Camera3D
var _turn := 0.0


func setup(the_app) -> void:
	app = the_app
	layer = 10
	_build()
	_root.visible = false


func is_open() -> bool:
	return _root.visible


func open() -> void:
	_root.visible = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_name.text = app.settings.player_name
	_height.set_value_no_signal(roundf(app.settings.height * 100.0))
	_show_choices()
	_show_body()
	_name.grab_focus()


func close() -> void:
	_name.release_focus()
	_root.visible = false


func _input(event: InputEvent) -> void:
	if not is_open():
		return
	if event is InputEventKey and event.pressed and not event.echo and event.physical_keycode == KEY_ESCAPE:
		close()
		get_viewport().set_input_as_handled()


func _process(delta: float) -> void:
	if not is_open():
		return
	_turn = fposmod(_turn + TAU * delta / TURN_SECONDS, TAU)
	_body.rotation.y = _turn
	_body.pose({}, delta)
	_hint.text = Hints.under_mouse(_panel)


## One choice made: your body looks so from now on, here and in the room, and to the others.
func choose(key: String, value) -> void:
	var look: Dictionary = Avatar.look_of(app.settings.appearance)
	look[key] = value
	app.set_appearance(look)
	_show_choices()
	_show_body()


## Your body in the picture, as tall as you are, looking as you have chosen, and named, the camera standing back to take
## all of it in.
func _show_body() -> void:
	var tall: float = app.settings.height
	_height_value.text = app.menu.height_text(tall)
	_body.build(tall, app.settings.appearance, Player.COLOR)
	_body.set_name_tag(app.settings.player_name)
	var back := (tall + 0.45) / (2.0 * tan(deg_to_rad(_picture_camera.fov / 2.0)))  # (far enough to take in all of it)
	_picture_camera.look_at_from_position(Vector3(0.0, 0.55 * tall + 0.1, back), Vector3(0.0, 0.5 * tall + 0.08, 0.0), Vector3.UP)


## What is chosen, shown: each style, and each colour's swatch ringed.
func _show_choices() -> void:
	var look: Dictionary = Avatar.look_of(app.settings.appearance)
	for build in _builds:
		_builds[build].set_pressed_no_signal(look.body == build)
	for key in _styles:
		_styles[key].select(Avatar.CHOICES[key].keys().find(look[key]))
	for key in _swatches:
		for i in _swatches[key].size():
			_ring(_swatches[key][i], Avatar.PALETTES[key][i], i == int(look[key]))


func _on_height_changed(cm: float) -> void:
	app.set_height(cm / 100.0)
	_show_body()


func _on_name_changed(text: String) -> void:
	app.set_player_name(text)
	_body.set_name_tag(app.settings.player_name)


func _build() -> void:
	_root = Control.new()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_root)
	var shade := ColorRect.new()
	shade.color = Color(0, 0, 0, 0.55)
	shade.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.add_child(shade)
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.add_child(center)
	_panel = PanelContainer.new()
	var style := UI.window_style(18)
	_panel.add_theme_stylebox_override("panel", style)
	center.add_child(_panel)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 12)
	_panel.add_child(box)

	var header := HBoxContainer.new()
	box.add_child(header)
	var title := Label.new()
	title.text = "Avatar customization"
	UI.title_label(title, 22)
	header.add_child(title)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(spacer)
	var close_button := Button.new()
	close_button.text = "Done  (Esc)"
	close_button.pressed.connect(close)
	header.add_child(close_button)

	var page := HBoxContainer.new()
	page.add_theme_constant_override("separation", 24)
	box.add_child(page)
	_build_picture(page)

	var form := GridContainer.new()
	form.columns = 2
	form.add_theme_constant_override("h_separation", 14)
	form.add_theme_constant_override("v_separation", 10)
	form.custom_minimum_size.x = 500
	page.add_child(form)
	_label(form, "Name")
	_name = LineEdit.new()
	_name.max_length = NAME_LENGTH
	_name.placeholder_text = "Your name"
	_name.add_theme_font_size_override("font_size", 18)
	_name.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_name.text_changed.connect(_on_name_changed)
	Hints.give(_name, "Your name, over your body where others see it (the other players, a microphone's view, the free camera)")
	form.add_child(_name)
	_label(form, "Height")
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	form.add_child(row)
	_height = HSlider.new()
	_height.min_value = Player.MIN_HEIGHT * 100.0
	_height.max_value = Player.MAX_HEIGHT * 100.0
	_height.step = 1.0
	_height.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_height.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_height.value_changed.connect(_on_height_changed)
	Hints.give(_height, "How tall you are: you see from your eyes and hear from between your ears, as high as they are on you (and sitting at a kit, as a seated drummer's are), and your body is drawn that tall")
	row.add_child(_height)
	_height_value = Label.new()
	_height_value.custom_minimum_size.x = 140
	row.add_child(_height_value)
	for each in ROWS:
		_build_row(form, each)
	_hint = Hints.line()
	box.add_child(_hint)


## Your body, turning, in a little world of its own.
func _build_picture(page: Control) -> void:
	var frame := SubViewportContainer.new()
	frame.stretch = true
	frame.custom_minimum_size = Vector2(260, 420)
	page.add_child(frame)
	var view := SubViewport.new()
	view.own_world_3d = true
	view.transparent_bg = true
	view.msaa_3d = Viewport.MSAA_4X
	frame.add_child(view)
	var world := Node3D.new()
	view.add_child(world)
	var environment := Environment.new()
	environment.background_mode = Environment.BG_CLEAR_COLOR
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color(0.55, 0.58, 0.66)
	environment.ambient_light_energy = 0.7
	var surroundings := WorldEnvironment.new()
	surroundings.environment = environment
	world.add_child(surroundings)
	var key := DirectionalLight3D.new()
	key.rotation = Vector3(-0.6, 0.5, 0.0)
	key.light_energy = 1.2
	world.add_child(key)
	var floor_disc := MeshInstance3D.new()
	var disc := CylinderMesh.new()
	disc.top_radius = 0.55
	disc.bottom_radius = 0.55
	disc.height = 0.01
	floor_disc.mesh = disc
	var floor_finish := StandardMaterial3D.new()
	floor_finish.albedo_color = Color(0.16, 0.17, 0.21)
	floor_disc.material_override = floor_finish
	floor_disc.position.y = -0.005
	world.add_child(floor_disc)
	_body = Avatar.new()
	world.add_child(_body)
	_picture_camera = Camera3D.new()
	_picture_camera.fov = 40.0
	world.add_child(_picture_camera)


## A row of choices: its styles (a menu, or the build's two buttons), and its colours (swatches).
func _build_row(form: Control, row: Array) -> void:
	var key: String = row[0]
	var label := _label(form, row[1])
	Hints.give(label, row[5])
	var line := HBoxContainer.new()
	line.add_theme_constant_override("separation", 10)
	form.add_child(line)
	if key == "body":
		var group := ButtonGroup.new()
		for build in Avatar.BODIES:
			var button := Button.new()
			button.text = Avatar.BODIES[build]
			button.toggle_mode = true
			button.button_group = group
			button.custom_minimum_size.x = 90
			button.pressed.connect(choose.bind("body", build))
			Hints.give(button, row[5])
			line.add_child(button)
			_builds[build] = button
	elif not row[2].is_empty():
		var styles := OptionButton.new()
		for each in row[2]:
			styles.add_item(row[2][each])
		styles.custom_minimum_size.x = 130
		styles.item_selected.connect(func(index: int) -> void: choose(key, row[2].keys()[index]))
		Hints.give(styles, row[5])
		line.add_child(styles)
		_styles[key] = styles
	if row[3] == "":
		return
	var colours := HFlowContainer.new()
	colours.add_theme_constant_override("h_separation", 4)
	colours.add_theme_constant_override("v_separation", 4)
	colours.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	line.add_child(colours)
	var swatches := []
	for i in row[4].size():
		var swatch := Button.new()
		swatch.custom_minimum_size = SWATCH
		swatch.focus_mode = Control.FOCUS_NONE
		swatch.pressed.connect(choose.bind(row[3], i))
		Hints.give(swatch, row[5])
		colours.add_child(swatch)
		swatches.append(swatch)
	_swatches[row[3]] = swatches


## A swatch in its colour, ringed when it is the one chosen.
func _ring(swatch: Button, colour: Color, chosen: bool) -> void:
	for state in ["normal", "hover", "pressed", "focus"]:
		var look := StyleBoxFlat.new()
		look.bg_color = colour.lightened(0.15) if state == "hover" else colour
		look.set_corner_radius_all(4)
		look.set_border_width_all(2 if chosen else 1)
		look.border_color = ACCENT if chosen else Color(1, 1, 1, 0.25)
		swatch.add_theme_stylebox_override(state, look)


func _label(parent: Control, text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_color_override("font_color", DIM)
	parent.add_child(label)
	return label
