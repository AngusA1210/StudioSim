extends CanvasLayer
## Playing together, from the title screen: hosting the room that is open, for others to join, or joining another
## player's by their address; and, while together, who is there and how far off the host is.

const Hints := preload("res://scripts/hints.gd")
const Net := preload("res://scripts/net.gd")
const DIM := Color(0.62, 0.65, 0.74)
const WARN := Color(1.0, 0.61, 0.48)
const ACCENT := Color(0.49, 0.89, 0.82)

var app
var _root: Control
var _panel: PanelContainer
var _port: SpinBox
var _host_button: Button
var _where: Label  # where the others join this computer
var _address: LineEdit
var _join_button: Button
var _status: Label
var _players: VBoxContainer
var _leave_button: Button
var _hint: Label
var _was := ""  # what playing together was, when last shown


func setup(the_app) -> void:
	app = the_app
	layer = 10
	_build()
	_root.visible = false
	app.net.changed.connect(_refresh)


func is_open() -> bool:
	return _root.visible


func open() -> void:
	_root.visible = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_refresh()


func close() -> void:
	_address.release_focus()
	_root.visible = false


func _input(event: InputEvent) -> void:
	if not is_open():
		return
	if event is InputEventKey and event.pressed and not event.echo and event.physical_keycode == KEY_ESCAPE:
		close()
		get_viewport().set_input_as_handled()


func _process(_delta: float) -> void:
	if is_open():
		_hint.text = Hints.under_mouse(_panel)
		if app.net.role == "guest":
			_status.text = "In %s's room  ·  %.0f ms to the host and back" % [app.net.host_name, app.net.latency_ms]


## Something to say on the page, in place of how it is going.
func tell(text: String) -> void:
	_status.text = text
	_status.add_theme_color_override("font_color", WARN)


## Hosts the room that is open. (The checks call it, with a port of their own, on this computer alone.)
func host(port := -1, bind := "*") -> String:
	if port >= 0:
		_port.set_value_no_signal(port)
	var problem: String = app.net.host(int(_port.value), bind)
	if problem != "":
		_status.text = "It couldn't be hosted: %s." % problem
		_status.add_theme_color_override("font_color", WARN)
	return problem


func join(address := "") -> String:
	var problem: String = app.net.join(_address.text if address == "" else address)
	if problem != "":
		_status.text = "It couldn't be joined: %s." % problem
		_status.add_theme_color_override("font_color", WARN)
	return problem


func _refresh() -> void:
	var net = app.net
	if net.role == "guest" and _was == "joining" and is_open():  # (in: into the room)
		close()
		app.title.enter()
	_was = net.role
	var together: bool = net.is_playing_together() or net.role == "joining"
	_host_button.disabled = together or not app.session.has_room() or app.timeline.is_record()
	_join_button.disabled = together
	_leave_button.visible = together
	_leave_button.text = "End the session" if net.role == "host" else "Leave"
	_where.text = ""
	if net.role == "host":
		var addresses := Array(IP.get_local_addresses()).filter(func(a): return a.count(".") == 3 and not a.begins_with("127.") and not a.begins_with("169.254."))
		_where.text = "Others join at %s  (port %d)" % [", ".join(addresses) if not addresses.is_empty() else "this computer's address", int(_port.value)]
	if net.status != "" or not together:
		_status.text = net.status if net.status != "" else ("Host the room that is open, or join another player's." if app.session.has_room() else
			"Open a room to host it, or join another player's.")
		_status.add_theme_color_override("font_color", WARN if net.status.begins_with("the ") else DIM)
	for child in _players.get_children():
		child.queue_free()
	for id in net.players:
		var info: Dictionary = net.players[id]
		var line := Label.new()
		var colour: Array = info.get("color", [0.8, 0.8, 0.8])
		line.text = "%s%s  ·  %d cm" % [str(info.get("name", "Player")), "  (you)" if int(id) == net.me else ("  (host)" if int(id) == 1 else ""),
			roundi(float(info.get("height", 1.75)) * 100.0)]
		line.add_theme_color_override("font_color", Color(float(colour[0]), float(colour[1]), float(colour[2])))
		_players.add_child(line)


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
	_panel.custom_minimum_size.x = 640
	center.add_child(_panel)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 12)
	_panel.add_child(box)

	var header := HBoxContainer.new()
	box.add_child(header)
	var title := Label.new()
	title.text = "Play together"
	title.add_theme_font_size_override("font_size", 22)
	header.add_child(title)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(spacer)
	var close_button := Button.new()
	close_button.text = "Close  (Esc)"
	close_button.pressed.connect(close)
	header.add_child(close_button)

	_label(box, "Host this room")
	var host_row := HBoxContainer.new()
	host_row.add_theme_constant_override("separation", 10)
	box.add_child(host_row)
	var port_label := Label.new()
	port_label.text = "Port"
	port_label.add_theme_color_override("font_color", DIM)
	host_row.add_child(port_label)
	_port = SpinBox.new()
	_port.min_value = 1024
	_port.max_value = 65535
	_port.value = Net.PORT
	_port.select_all_on_focus = true
	Hints.give(_port, "The port the others join on. Over the internet, forward it (UDP) to this computer in your router")
	host_row.add_child(_port)
	_host_button = Button.new()
	_host_button.text = "Host"
	_host_button.pressed.connect(func() -> void: host())
	Hints.give(_host_button, "Others can then join the room you have open (a Jam room): their copies kept the same as yours, each hearing it from where they stand")
	host_row.add_child(_host_button)
	_where = Label.new()
	_where.add_theme_color_override("font_color", ACCENT)
	box.add_child(_where)

	_label(box, "Join a room")
	var join_row := HBoxContainer.new()
	join_row.add_theme_constant_override("separation", 10)
	box.add_child(join_row)
	_address = LineEdit.new()
	_address.placeholder_text = "The host's address (and :port, if not %d)" % Net.PORT
	_address.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_address.text_submitted.connect(func(_text: String) -> void: join())
	Hints.give(_address, "The address the host's page shows: on the same network, theirs there (192.168…); over the internet, their public one")
	join_row.add_child(_address)
	_join_button = Button.new()
	_join_button.text = "Join"
	_join_button.pressed.connect(func() -> void: join())
	Hints.give(_join_button, "Your room becomes a copy of theirs (yours as it was is left as it was saved)")
	join_row.add_child(_join_button)

	_status = Label.new()
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(_status)
	_players = VBoxContainer.new()
	box.add_child(_players)
	_leave_button = Button.new()
	_leave_button.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	_leave_button.pressed.connect(func() -> void: app.net.leave())
	box.add_child(_leave_button)
	_hint = Hints.line()
	box.add_child(_hint)


func _label(parent: Control, text: String) -> void:
	var label := Label.new()
	label.text = text
	label.add_theme_color_override("font_color", DIM)
	parent.add_child(label)
