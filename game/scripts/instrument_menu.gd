extends CanvasLayer
## The instrument menu (T): pick a kind of instrument and it appears in your hands, to be walked to where it
## should stand and put down. Each is a card with a picture of it (its model, as it stands in the room) and its name;
## what it is, and what a family is, is said in the line at the foot while the mouse is over it. The families: MIDI
## instruments, which are played and sequenced, live inputs, which bring a plugged-in instrument into the room, and
## microphones. Under them, any instrument presets saved (an amp with its pedals and plug-ins, say), each of which
## comes in as a new instrument set up that way.

const Catalog := preload("res://scripts/catalog.gd")
const Hints := preload("res://scripts/hints.gd")
const Models := preload("res://scripts/instrument_models.gd")
const CARD := Vector2(172, 136)
const PICTURE := Vector2(160, 98)
const PICK := "Pick one and it appears in your hands. Walk it to where you want it, then click to put it down."
const DIM := Color(0.62, 0.65, 0.74)
const WARN := Color(1.0, 0.61, 0.48)

var app
var _close_button: Button  # its label says which key closes it too
var audio: SoundRoomAudio

var _root: Control
var _panel: PanelContainer
var _cards: Array = []
var _card_for := {}  # kind → its card
var _input_option: OptionButton
var _input_choice := -1  # the hardware input a new live instrument plays; -1 = all of them
var _footer: Label
var _scroll: ScrollContainer
var _preset_box: VBoxContainer  # "Your presets", shown when there are any
var _preset_cards: HFlowContainer
var _preset_buttons: Array = []
var _hint: Label  # what the mouse is over
var _pictures := {}  # kind → its card's picture, drawn the first time the menu opens
var _drawn := false


func setup(the_app) -> void:
	app = the_app
	audio = app.audio
	layer = 9
	_build()
	_root.visible = false


func is_open() -> bool:
	return _root.visible


func open() -> void:
	_close_button.text = "Close  (%s)" % app.bindings.label("add")
	app.player.release_keys()
	_root.visible = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_draw_pictures()
	_fill_presets()
	_refresh()
	_scroll.scroll_vertical = 0  # from the top each time


func close() -> void:
	_root.visible = false
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


## Makes an instrument of this kind and puts it in the player's hands. Returns it, or null if the room is full.
func create(kind: String):
	var player = app.player
	var at: Vector3 = player.global_position + Vector3(0.0, Catalog.KINDS[kind].height, 0.0)
	var inst = app.add_instrument(kind, at)
	if inst == null:
		return null
	if inst.is_stereo_mic:  # (XY, to begin with)
		app.set_pair_technique(inst, "xy")
	if inst.is_live():
		app.set_input_channel(inst, _input_choice)
	player.carry(inst)
	inst.face(player.global_position)
	return inst


func _input(event: InputEvent) -> void:
	if is_open() and not app.name_prompt.is_open() and not app.plugin_browser.visible and event is InputEventKey and event.pressed and not event.echo and \
			(event.physical_keycode == KEY_ESCAPE or app.bindings.action_for(event.physical_keycode) == "add"):
		close()
		get_viewport().set_input_as_handled()


func _process(_delta: float) -> void:
	if is_open():
		var vp := get_viewport().get_visible_rect().size
		_panel.custom_minimum_size = Vector2(minf(980.0, vp.x - 32.0), minf(720.0, vp.y - 32.0))
		var hint := Hints.under_mouse(_panel)
		_hint.text = hint if hint != "" else PICK


# ── Building ────────────────────────────────────────────────────────────────────────────────────────────────

func _build() -> void:
	_root = Control.new()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_root)
	var shade := ColorRect.new()
	shade.color = Color(0, 0, 0, 0.5)
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
	center.add_child(_panel)
	var outer := VBoxContainer.new()
	outer.add_theme_constant_override("separation", 10)
	_panel.add_child(outer)

	var header := HBoxContainer.new()
	outer.add_child(header)
	var title := Label.new()
	title.text = "Add an instrument"
	title.add_theme_font_size_override("font_size", 22)
	header.add_child(title)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(spacer)
	var close_button := Button.new()
	_close_button = close_button
	close_button.pressed.connect(close)
	header.add_child(close_button)

	var scroll := ScrollContainer.new()
	_scroll = scroll
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	outer.add_child(scroll)
	var box := VBoxContainer.new()
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_theme_constant_override("separation", 10)
	scroll.add_child(box)

	for group in Catalog.GROUPS:
		box.add_child(HSeparator.new())
		var heading := Label.new()
		heading.text = group.title
		heading.add_theme_font_size_override("font_size", 18)
		heading.mouse_filter = Control.MOUSE_FILTER_PASS
		heading.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
		Hints.give(heading, group.about)
		box.add_child(heading)
		var cards := HFlowContainer.new()
		cards.add_theme_constant_override("h_separation", 10)
		cards.add_theme_constant_override("v_separation", 10)
		box.add_child(cards)
		var live := false
		for kind in group.kinds:
			cards.add_child(_card(kind))
			live = live or Catalog.KINDS[kind].get("live_input", false)
		if live:  # which hardware input the new one listens to; it can be changed later on the I/O page
			var row := HBoxContainer.new()
			row.add_theme_constant_override("separation", 10)
			var label := Label.new()
			label.text = "A new one plays"
			label.add_theme_color_override("font_color", DIM)
			row.add_child(label)
			_input_option = OptionButton.new()
			_input_option.item_selected.connect(_on_input_selected)
			row.add_child(_input_option)
			box.add_child(row)
		if group.coming != "":
			_note(box, group.coming)

	_preset_box = VBoxContainer.new()
	_preset_box.add_theme_constant_override("separation", 10)
	box.add_child(_preset_box)
	_preset_box.add_child(HSeparator.new())
	var preset_heading := Label.new()
	preset_heading.text = "Your presets"
	preset_heading.add_theme_font_size_override("font_size", 18)
	_preset_box.add_child(preset_heading)
	_preset_cards = HFlowContainer.new()
	_preset_cards.add_theme_constant_override("h_separation", 10)
	_preset_cards.add_theme_constant_override("v_separation", 10)
	_preset_box.add_child(_preset_cards)

	_hint = Hints.line()
	_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_hint.custom_minimum_size.y = 20
	_hint.add_theme_font_size_override("font_size", 14)
	_hint.add_theme_color_override("font_color", Color(0.85, 0.87, 0.92))
	outer.add_child(_hint)
	_footer = Label.new()
	_footer.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_footer.add_theme_font_size_override("font_size", 13)
	outer.add_child(_footer)


## A button for one kind of instrument: a picture of it, its name under it in its colour, a stripe of its colour at the
## foot; what it is, in the line at the foot of the menu while the mouse is over it.
func _card(kind: String) -> Button:
	var spec: Dictionary = Catalog.KINDS[kind]
	var card := Button.new()
	card.custom_minimum_size = CARD
	card.focus_mode = Control.FOCUS_NONE
	for state in ["normal", "hover", "pressed", "disabled"]:
		var style := StyleBoxFlat.new()
		style.bg_color = Color(1, 1, 1, {"normal": 0.05, "hover": 0.11, "pressed": 0.16, "disabled": 0.02}[state])
		style.set_corner_radius_all(8)
		style.border_width_bottom = 4
		style.border_color = spec.color if state != "disabled" else spec.color.darkened(0.6)
		card.add_theme_stylebox_override(state, style)
	card.pressed.connect(_on_picked.bind(kind))
	Hints.give(card, "%s: %s" % [spec.name, spec.about])
	_card_for[kind] = card

	var column := VBoxContainer.new()
	column.set_anchors_preset(Control.PRESET_FULL_RECT)
	column.offset_left = 6
	column.offset_right = -6
	column.offset_top = 6
	column.offset_bottom = -8
	column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_theme_constant_override("separation", 4)
	card.add_child(column)
	var picture := TextureRect.new()
	picture.custom_minimum_size = PICTURE
	picture.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	picture.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	picture.size_flags_vertical = Control.SIZE_EXPAND_FILL
	picture.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_child(picture)
	_pictures[kind] = picture
	var name_label := Label.new()
	name_label.text = spec.name
	name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_label.clip_text = true
	name_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	name_label.add_theme_font_size_override("font_size", 15)
	name_label.add_theme_color_override("font_color", spec.color.lightened(0.35))
	name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_child(name_label)
	_cards.append(card)
	return card


## Each card's picture: its model as it stands in the room, seen from in front and a little above and to the side, in a
## little world of its own, drawn once (at twice the card's size, for a sharp picture on a Retina screen).
func _draw_pictures() -> void:
	if _drawn:
		return
	_drawn = true
	for kind in _pictures:
		var spec: Dictionary = Catalog.KINDS[kind]
		var view := SubViewport.new()
		view.size = Vector2i(PICTURE * 2.0)
		view.own_world_3d = true
		view.transparent_bg = true
		view.msaa_3d = Viewport.MSAA_4X
		view.render_target_update_mode = SubViewport.UPDATE_ONCE
		_root.add_child(view)
		var mic := {}
		if spec.get("mic", false):  # (on a short stand, so the mic itself fills the picture)
			mic = {"height": minf(float(spec.height), 0.45), "tilt": 0.0, "model": spec.get("model", "flat"), "capsules": []}
			if spec.get("stereo", false):  # an XY pair, as a new one is
				var pair: Dictionary = Catalog.MIC_PAIRS.xy
				for k in 2:
					var turn := deg_to_rad(float(pair.turns[k]))
					mic.capsules.append({"at": Vector3.ZERO, "aim": Basis(Vector3.UP, turn) * Vector3(0, 0, 1), "turn": turn, "model": mic.model})
		var built: Dictionary = Models.build("mic" if spec.get("mic", false) else kind, spec.color, "", mic)
		var model: Node3D = built.node
		view.add_child(model)
		var bounds := _bounds(model)
		var centre := bounds.get_center()
		var radius := maxf(bounds.size.length() / 2.0, 0.05)
		var toward := Vector3(0.55, 0.38, 1.0)
		if not mic.is_empty():  # a mic: its body, from the side, the stand going off behind it
			centre = Vector3(0.0, mic.height, -0.03)
			radius = 0.2 if spec.get("stereo", false) else 0.15
			toward = Vector3(1.0, 0.35, 0.5)
		var camera := Camera3D.new()
		camera.fov = 30.0
		var from := toward.normalized() * radius / sin(deg_to_rad(camera.fov / 2.0)) * 0.8
		camera.environment = _picture_light()
		view.add_child(camera)
		camera.look_at_from_position(centre + from, centre)
		var sun := DirectionalLight3D.new()
		sun.light_energy = 1.3
		view.add_child(sun)
		sun.look_at_from_position(Vector3(1.0, 2.0, 1.5), Vector3.ZERO)
		_pictures[kind].texture = view.get_texture()


## How a model's parts are lit in its picture: a soft light all round, with the sun from over your shoulder.
func _picture_light() -> Environment:
	var environment := Environment.new()
	environment.background_mode = Environment.BG_CLEAR_COLOR
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color(0.75, 0.78, 0.85)
	environment.ambient_light_energy = 0.7
	return environment


## The box round a model's parts, from its own origin.
static func _bounds(root: Node3D) -> AABB:
	var box := AABB()
	var first := true
	for part in root.find_children("*", "GeometryInstance3D", true, false):
		var place := Transform3D.IDENTITY
		var node: Node = part
		while node != root and node is Node3D:
			place = (node as Node3D).transform * place
			node = node.get_parent()
		var aabb: AABB = place * (part as GeometryInstance3D).get_aabb()
		box = aabb if first else box.merge(aabb)
		first = false
	return box


func _note(parent: Control, text: String) -> void:
	var label := Label.new()
	label.text = text
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.add_theme_color_override("font_color", DIM)
	label.add_theme_font_size_override("font_size", 13)
	parent.add_child(label)


## How full the room is, and which hardware inputs there are to choose from.
func _refresh() -> void:
	var count: int = app.instruments.size()
	var limit: int = app.instrument_capacity()
	var full := count >= limit
	for card in _cards + _preset_buttons:
		card.disabled = full
	if full:
		_footer.text = "The room is full: it holds %d instruments. Remove one to make space: face it and press Backspace twice." % limit
	else:
		_footer.text = "%d in the room, space for %d more. To remove one, face it (or carry it) and press Backspace twice." % [count, limit - count]
	_footer.add_theme_color_override("font_color", WARN if full else DIM)

	var inputs: int = app.input_channel_count()
	_input_option.clear()
	_input_option.add_item("all inputs")
	for i in inputs:
		_input_option.add_item("input %d" % (i + 1))
	_input_choice = mini(_input_choice, inputs - 1)
	_input_option.select(_input_choice + 1)


## A plug-in instrument: which of the instrument plug-ins, from the browser; then it comes into your hands holding it,
## named after it.
func _choose_plugin_instrument() -> void:
	var card: Control = _card_for.plugin_synth
	app.plugin_browser.open_for("A plug-in instrument", app.available_instrument_plugins(), card.get_screen_position() + Vector2(card.size.x + 6, 0),
		func(plugin: Dictionary) -> void:
			var inst = create("plugin_synth")
			if inst == null:
				_refresh()
				return
			var problem: String = app.set_instrument_plugin(inst, plugin.id)
			if problem != "":
				app.remove_instrument(inst)
				_footer.text = "%s couldn't be loaded: %s." % [plugin.name, problem]
				_footer.add_theme_color_override("font_color", WARN)
				return
			close())


## A card for each instrument preset saved, in the colour of the kind of instrument it makes.
func _fill_presets() -> void:
	for child in _preset_cards.get_children():
		child.queue_free()
	_preset_buttons.clear()
	for preset in app.library.instrument_presets():
		var data: Dictionary = app.library.read_instrument_preset(preset.path)
		var kind: String = data.get("kind", "")
		if not Catalog.KINDS.has(kind):
			continue
		var spec: Dictionary = Catalog.KINDS[kind]
		var card := Button.new()
		card.text = "%s\n%s" % [preset.name, spec.name]
		card.alignment = HORIZONTAL_ALIGNMENT_LEFT
		card.custom_minimum_size = Vector2(200, 56)
		card.focus_mode = Control.FOCUS_NONE
		card.add_theme_font_size_override("font_size", 14)
		for state in ["normal", "hover", "pressed", "disabled"]:
			var style := StyleBoxFlat.new()
			style.bg_color = Color(1, 1, 1, {"normal": 0.05, "hover": 0.11, "pressed": 0.16, "disabled": 0.02}[state])
			style.set_corner_radius_all(8)
			style.border_width_left = 6
			style.border_color = spec.color if state != "disabled" else spec.color.darkened(0.6)
			style.content_margin_left = 16
			style.content_margin_right = 12
			card.add_theme_stylebox_override(state, style)
		card.pressed.connect(_on_preset_picked.bind(preset.path))
		_preset_cards.add_child(card)
		_preset_buttons.append(card)
	_preset_box.visible = not _preset_buttons.is_empty()


## A preset picked: a new instrument of its kind, set up as the preset says, in your hands.
func _on_preset_picked(path: String) -> void:
	var data: Dictionary = app.library.read_instrument_preset(path)
	var inst = create(data.get("kind", "")) if Catalog.KINDS.has(data.get("kind", "")) else null
	if inst == null:
		_refresh()
		return
	var problem: String = app.library.apply_instrument_settings(inst, data)
	if problem == "":
		close()
	else:
		_footer.text = "Not all of it could be set up: %s." % problem
		_footer.add_theme_color_override("font_color", WARN)


func _on_input_selected(index: int) -> void:
	_input_choice = index - 1


func _on_picked(kind: String) -> void:
	if kind == "plugin_synth":
		_choose_plugin_instrument()
		return
	if create(kind) != null:
		close()
	else:
		_refresh()
