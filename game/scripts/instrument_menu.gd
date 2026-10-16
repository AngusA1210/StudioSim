extends CanvasLayer
## The instrument menu (N): pick a kind of instrument and it appears in your hands, to be walked to where it
## should stand and put down. Two families: MIDI instruments, which are played and sequenced, and live inputs,
## which bring a microphone or a plugged-in instrument into the room.

const Catalog := preload("res://scripts/catalog.gd")
const DIM := Color(0.62, 0.65, 0.74)
const WARN := Color(1.0, 0.61, 0.48)

var app
var audio: SoundRoomAudio

var _root: Control
var _panel: PanelContainer
var _cards: Array = []
var _input_option: OptionButton
var _input_choice := -1  # the hardware input a new live instrument plays; -1 = all of them
var _footer: Label


func setup(the_app) -> void:
	app = the_app
	audio = app.audio
	layer = 9
	_build()
	_root.visible = false


func is_open() -> bool:
	return _root.visible


func open() -> void:
	app.player.release_keys()
	_root.visible = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_refresh()


func close() -> void:
	_root.visible = false
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


## Makes an instrument of this kind and puts it in the player's hands. Returns it, or null if the room is full.
func create(kind: String):
	var player = app.player
	var inst = app.add_instrument(kind, player.global_position + Vector3(0.0, Catalog.KINDS[kind].height, 0.0))
	if inst == null:
		return null
	if not inst.playable:
		app.set_input_channel(inst, _input_choice)
	player.carry(inst)
	inst.face(player.global_position)
	return inst


func _input(event: InputEvent) -> void:
	if is_open() and event is InputEventKey and event.pressed and not event.echo and \
			(event.physical_keycode == KEY_ESCAPE or app.bindings.action_for(event.physical_keycode) == "add"):
		close()
		get_viewport().set_input_as_handled()


func _process(_delta: float) -> void:
	if is_open():
		var vp := get_viewport().get_visible_rect().size
		_panel.custom_minimum_size = Vector2(minf(900.0, vp.x - 32.0), minf(700.0, vp.y - 32.0))


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
	close_button.text = "Close  (N)"
	close_button.pressed.connect(close)
	header.add_child(close_button)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	outer.add_child(scroll)
	var box := VBoxContainer.new()
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_theme_constant_override("separation", 10)
	scroll.add_child(box)

	_note(box, "Pick one and it appears in your hands. Walk it to where you want it, then click to put it down.")
	for group in Catalog.GROUPS:
		box.add_child(HSeparator.new())
		var heading := Label.new()
		heading.text = group.title
		heading.add_theme_font_size_override("font_size", 18)
		box.add_child(heading)
		_note(box, group.about)
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

	_footer = Label.new()
	_footer.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_footer.add_theme_font_size_override("font_size", 13)
	outer.add_child(_footer)


## A button for one kind of instrument: a stripe of its colour, its name, and a line about it.
func _card(kind: String) -> Button:
	var spec: Dictionary = Catalog.KINDS[kind]
	var card := Button.new()
	card.custom_minimum_size = Vector2(272, 76)
	card.focus_mode = Control.FOCUS_NONE
	for state in ["normal", "hover", "pressed", "disabled"]:
		var style := StyleBoxFlat.new()
		style.bg_color = Color(1, 1, 1, {"normal": 0.05, "hover": 0.11, "pressed": 0.16, "disabled": 0.02}[state])
		style.set_corner_radius_all(8)
		style.border_width_left = 6
		style.border_color = spec.color if state != "disabled" else spec.color.darkened(0.6)
		card.add_theme_stylebox_override(state, style)
	card.pressed.connect(_on_picked.bind(kind))

	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	margin.add_theme_constant_override("margin_left", 18)
	margin.add_theme_constant_override("margin_right", 10)
	margin.add_theme_constant_override("margin_top", 8)
	margin.add_theme_constant_override("margin_bottom", 8)
	card.add_child(margin)
	var text := VBoxContainer.new()
	text.mouse_filter = Control.MOUSE_FILTER_IGNORE
	text.add_theme_constant_override("separation", 2)
	margin.add_child(text)
	var name_label := Label.new()
	name_label.text = spec.name
	name_label.add_theme_font_size_override("font_size", 17)
	name_label.add_theme_color_override("font_color", spec.color.lightened(0.35))
	name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	text.add_child(name_label)
	var about := Label.new()
	about.text = spec.about
	about.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	about.add_theme_font_size_override("font_size", 13)
	about.add_theme_color_override("font_color", DIM)
	about.mouse_filter = Control.MOUSE_FILTER_IGNORE
	text.add_child(about)
	_cards.append(card)
	return card


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
	var limit := audio.get_max_sources()
	var full := count >= limit
	for card in _cards:
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


func _on_input_selected(index: int) -> void:
	_input_choice = index - 1


func _on_picked(kind: String) -> void:
	if create(kind) != null:
		close()
	else:
		_refresh()
