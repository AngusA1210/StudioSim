extends CanvasLayer
## You, from the title screen: your name and your height, with your body turning beside them as it will stand in the
## room (its colours, hair and clothes to come). Set here, before you go into a room, rather than in the room's menu,
## as a player joining others would be: nobody grows taller in the middle of a session.

const Hints := preload("res://scripts/hints.gd")
const Avatar := preload("res://scripts/avatar.gd")
const Player := preload("res://scripts/player.gd")
const DIM := Color(0.62, 0.65, 0.74)
const ACCENT := Color(0.49, 0.89, 0.82)
const NAME_LENGTH := 24
const TURN_SECONDS := 12.0  # (your body, once round)

var app
var _root: Control
var _panel: PanelContainer
var _name: LineEdit
var _height: HSlider
var _height_value: Label
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


## Your body in the picture, as tall as you are and named, the camera standing back to take all of it in.
func _show_body() -> void:
	var tall: float = app.settings.height
	_height_value.text = app.menu.height_text(tall)
	_body.build(tall, Player.COLOR)
	_body.set_name_tag(app.settings.player_name)
	var back := (tall + 0.45) / (2.0 * tan(deg_to_rad(_picture_camera.fov / 2.0)))  # (far enough to take in all of it)
	_picture_camera.look_at_from_position(Vector3(0.0, 0.55 * tall + 0.1, back), Vector3(0.0, 0.5 * tall + 0.08, 0.0), Vector3.UP)


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
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.07, 0.08, 0.11, 0.98)
	style.set_corner_radius_all(14)
	style.set_border_width_all(1)
	style.border_color = Color(1, 1, 1, 0.14)
	style.set_content_margin_all(18)
	_panel.add_theme_stylebox_override("panel", style)
	center.add_child(_panel)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 12)
	_panel.add_child(box)

	var header := HBoxContainer.new()
	box.add_child(header)
	var title := Label.new()
	title.text = "You"
	title.add_theme_font_size_override("font_size", 22)
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
	# Your body, turning.
	var frame := SubViewportContainer.new()
	frame.stretch = true
	frame.custom_minimum_size = Vector2(260, 380)
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

	var form := VBoxContainer.new()
	form.add_theme_constant_override("separation", 10)
	form.custom_minimum_size.x = 380
	page.add_child(form)
	_label(form, "Name")
	_name = LineEdit.new()
	_name.max_length = NAME_LENGTH
	_name.placeholder_text = "Your name"
	_name.add_theme_font_size_override("font_size", 18)
	_name.text_changed.connect(_on_name_changed)
	Hints.give(_name, "Your name, over your body where others see it (a microphone's view and the free camera now; the other players, when they come)")
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
	_hint = Hints.line()
	box.add_child(_hint)


func _label(parent: Control, text: String) -> void:
	var label := Label.new()
	label.text = text
	label.add_theme_color_override("font_color", DIM)
	parent.add_child(label)
