extends CanvasLayer
## Playing together, from the title screen, in three tabs. Rooms: the rooms hosted on this network, found by
## themselves (discovery.gd), joined with a double-click (and the password, if one has it). Host: the room to host
## (the one open, a new one or a saved one), its name, password, whether it is listed, how many may be in it and what
## joining players may do. Direct connect: a room joined by its host's address (or its code, through a session server).
## While together, the page shows the session in their place: who is in it, where others join (the host's), its rules
## (the host's to change, and to ask a player to leave), and Leave.

const Hints := preload("res://scripts/hints.gd")
const Net := preload("res://scripts/net.gd")
const DIM := Color(0.62, 0.65, 0.74)
const WARN := Color(1.0, 0.61, 0.48)
const ACCENT := Color(0.49, 0.89, 0.82)
const MAY_LABELS := {"move": "Move, add and take out instruments", "sound": "Change instruments' sound, patterns and names",
	"room": "Change the room: its size, walls, surfaces and tempo", "transport": "Play, stop and record, and edit the timeline"}

var app
var _root: Control
var _panel: PanelContainer
var _header: HBoxContainer
var _tabs := {}  # "rooms", "host", "direct" → its tab
var _pages := {}  # and its page
var _tab := "rooms"
var _status: Label
var _voice: OptionButton
var _hint: Label
var _was := ""  # what playing together was, when last shown

# Rooms
var _list: Tree
var _found := []  # the rooms listed, as shown
var _listed_hash := 0
var _since_list := 0.0
var _list_password: LineEdit
var _list_join: Button

# Host
var _room_label: Label
var _rules_slot: VBoxContainer  # where the rules are, on the Host page (they go to the session's while hosting)
var _rules_box: VBoxContainer
var _session_name: LineEdit
var _named := false  # (a name typed, rather than the room's)
var _listed: CheckBox
var _most: SpinBox
var _may := {}  # Net.MAY's keys → CheckBox
var _host_password: LineEdit
var _internet: CheckBox  # (hosting) the router asked to open the ports, and a code from the session server
var _port: SpinBox
var _server: LineEdit  # the session server players meet through
var _host_button: Button

# Direct connect
var _address: LineEdit
var _password: LineEdit
var _join_button: Button

# The session, while together
var _session: VBoxContainer
var _session_title: Label
var _where: Label  # (the host's) where the others join
var _players: VBoxContainer
var _session_rules: VBoxContainer
var _rules_text: Label  # (a joining player's) what the host lets players do
var _enter_button: Button
var _leave_button: Button


func setup(the_app) -> void:
	app = the_app
	layer = 10
	_build()
	_load_rules()
	_root.visible = false
	app.net.changed.connect(_refresh)
	app.session.changed.connect(_refresh)


func is_open() -> bool:
	return _root.visible


func open() -> void:
	_root.visible = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_load_rules()
	_listed_hash = 0  # (the list, and what it says, shown again)
	_refresh()


func close() -> void:
	for field in [_address, _password, _list_password, _session_name, _host_password, _server]:
		field.release_focus()
	_root.visible = false
	app.net.discovery.look(false)


## One of the tabs: "rooms", "host" or "direct".
func show_tab(tab: String) -> void:
	_tab = tab
	_status.text = ""
	_listed_hash = 0
	_refresh()


func _input(event: InputEvent) -> void:
	if not is_open():
		return
	if event is InputEventKey and event.pressed and not event.echo and event.physical_keycode == KEY_ESCAPE:
		close()
		get_viewport().set_input_as_handled()


func _process(delta: float) -> void:
	if not is_open():
		return
	_hint.text = Hints.under_mouse(_panel)
	var net = app.net
	var pending: Vector2i = net.files_pending()
	var files := ("  ·  recordings: %.1f MB to come" % (pending.x / 1048576.0) if pending.x > 0 else "") + (
		"  ·  %.1f MB to send" % (pending.y / 1048576.0) if pending.y > 0 else "")
	if net.role == "guest":
		_status.text = "%.0f ms to the host and back%s%s" % [net.latency_ms, "  ·  by way of the session server" if net.by_relay() else "", files]
		_status.add_theme_color_override("font_color", DIM)
	elif net.role == "host" and files != "":
		_status.text = net.status + files
	if _pages.rooms.visible:
		_since_list += delta
		if _since_list >= 0.5:
			_since_list = 0.0
			_fill_list()


## Something to say on the page, in place of how it is going.
func tell(text: String) -> void:
	_status.text = text
	_status.add_theme_color_override("font_color", WARN)


# ── Hosting and joining ─────────────────────────────────────────────────────────────────────────────────────

## Hosts the room that is open, as the Host tab has it set up. (The checks call it, with a port of their own, on this
## computer alone.)
func host(port := -1, bind := "*") -> String:
	if port >= 0:
		_port.set_value_no_signal(port)
	if not app.session.has_room():
		tell("Open a room to host, or make a new one.")
		return "no room is open"
	_save_rules()
	var problem: String = app.net.host(int(_port.value), bind, _internet.button_pressed, _host_password.text.strip_edges(), chosen_rules())
	if problem != "":
		tell("It couldn't be hosted: %s." % problem)
	return problem


## Joins the room at `address` (or with a session's code), with `password`.
func join(address: String, password: String) -> String:
	var problem: String = app.net.join(address, password.strip_edges())
	if problem != "":
		tell("It couldn't be joined: %s." % problem)
	return problem


## The session's rules as the Host tab has them.
func chosen_rules() -> Dictionary:
	var may := {}
	for key in _may:
		may[key] = _may[key].button_pressed
	return {"name": _session_name.text.strip_edges(), "listed": _listed.button_pressed, "most": int(_most.value), "may": may}


func _load_rules() -> void:
	var saved: Dictionary = app.settings.session_rules
	_listed.set_pressed_no_signal(bool(saved.get("listed", Net.RULES.listed)))
	_most.set_value_no_signal(int(saved.get("most", Net.RULES.most)))
	for key in _may:
		_may[key].set_pressed_no_signal(bool(saved.get("may", {}).get(key, Net.RULES.may[key])))


func _save_rules() -> void:
	var rules := chosen_rules()
	rules.erase("name")  # (each room's own)
	app.settings.session_rules = rules
	app.settings.save_to_disk()


## A rule changed on the page: kept for next time, and, while hosting, the session's from now on.
func _on_rule_changed() -> void:
	_save_rules()
	if app.net.role == "host":
		app.net.set_rules(chosen_rules())


## Hosting a new room, or a saved one: made or opened on the rooms page, then back here to host it.
func _choose_room(new_room: bool) -> void:
	_named = false
	close()
	app.rooms_page.back_to = func() -> void:
		open()
		show_tab("host")
	if new_room:
		app.rooms_page.open_new()
	else:
		app.rooms_page.open_existing()


func _join_listed() -> void:
	var room := _chosen_listed()
	if room.is_empty():
		return
	if int(room.get("protocol", 0)) != Net.PROTOCOL:
		tell("%s is hosted by another version of SoundRoom." % str(room.name))
		return
	if bool(room.get("locked", false)) and _list_password.text.strip_edges() == "":
		tell("%s has a password: type it beside Join." % str(room.name))
		_list_password.grab_focus()
		return
	join("%s:%d" % [str(room.address), int(room.port)], _list_password.text)


func _chosen_listed() -> Dictionary:
	var item := _list.get_selected()
	if item == null:
		return {}
	var index := int(item.get_metadata(0))
	return _found[index] if index < _found.size() else {}


# ── Showing how it is ───────────────────────────────────────────────────────────────────────────────────────

func _refresh() -> void:
	var net = app.net
	_fill_voice()
	if net.role == "guest" and _was == "joining" and is_open():  # (in: into the room)
		close()
		app.title.enter()
	_was = net.role
	var together: bool = net.is_playing_together() or net.role == "joining"
	_header.visible = not together
	for key in _pages:
		_pages[key].visible = not together and key == _tab
		_tabs[key].set_pressed_no_signal(key == _tab)
	_session.visible = together
	net.discovery.look(is_open() and not together and _tab == "rooms")
	if _pages.rooms.visible:
		_fill_list()

	# Host
	var has_room: bool = app.session.has_room()
	_room_label.text = app.session.room_name if has_room else "No room is open"
	_room_label.add_theme_color_override("font_color", Color(0.9, 0.91, 0.95) if has_room else WARN)
	if not _named:
		_session_name.text = app.session.room_name if has_room else ""
	_host_button.disabled = not has_room
	var rules_here: Control = _session_rules if net.role == "host" else _rules_slot
	if _rules_box.get_parent() != rules_here:
		_rules_box.reparent(rules_here)
	if net.role == "host":
		if not _session_name.has_focus():
			_session_name.text = str(net.rules.name)
		_listed.set_pressed_no_signal(bool(net.rules.listed))
		_most.set_value_no_signal(int(net.rules.most))
		for key in _may:
			_may[key].set_pressed_no_signal(bool(net.rules.may.get(key, true)))

	# The session
	_rules_text.visible = net.role == "guest"
	if net.role == "guest":
		var let: Array = Net.MAY.keys().filter(func(k): return bool(net.rules.get("may", {}).get(k, true))).map(func(k): return Net.MAY[k])
		_rules_text.text = ("Besides playing and talking, the host lets players %s." % "; ".join(let)) if not let.is_empty() else \
			"Besides playing and talking, the host hasn't let players do anything else here."
	_session_title.text = {"host": "Hosting %s" % str(net.rules.name), "guest": "In %s  ·  %s's room" % [str(net.rules.get("name", "")), net.host_name],
		"joining": "Joining…"}.get(net.role, "")
	_where.visible = net.role == "host"
	if net.role == "host":
		_where.text = _where_others_join()
	_leave_button.text = {"host": "End the session", "guest": "Leave", "joining": "Stop"}.get(net.role, "Leave")
	_enter_button.visible = net.is_playing_together()
	_fill_players()
	if net.status != "" or not together:
		var said: String = net.status
		if said == "the host couldn't be reached":
			said += _why_unreached()
		if said != "" or not _pages.rooms.visible:
			_status.text = said
		var trouble := said != "" and said[0] == said[0].to_lower()  # (what went wrong starts small: "the password isn't right")
		_status.add_theme_color_override("font_color", WARN if trouble else DIM)


## (The host's) where others join: on this network, over the internet, by a code.
func _where_others_join() -> String:
	var net = app.net
	var addresses := Array(IP.get_local_addresses()).filter(func(a): return a.count(".") == 3 and not a.begins_with("127.") and not a.begins_with("169.254."))
	var text := "On this network it is listed under Rooms%s, or joined at %s  (port %d)" % ["" if bool(net.rules.listed) else " (not now: unlisted)",
		", ".join(addresses) if not addresses.is_empty() else "this computer's address", int(_port.value)]
	match net.router:  # (over the internet)
		"asking":
			text += "\nAsking your router to open the ports…"
		"open":
			text += "\nOver the internet: %s  (the router has opened ports %d and %d)" % [net.public_address, int(_port.value), int(_port.value) + 1]
		"":
			pass
		_:
			text += "\nThe router didn't open them: %s. Forward ports %d and %d (UDP) to this computer in your router%s." % [
				net.router, int(_port.value), int(_port.value) + 1, ", or join with the code" if net.meeting != null else ""]
	if net.meeting != null:  # (a session server: a code)
		match net.meeting.state:
			"hosted":
				text += "\nOr from anywhere, with the code %s" % net.meeting.code
			"":
				text += "\nNo code: %s" % net.meeting.problem
			_:
				text += "\nAsking the session server for a code…"
	if OS.get_name() == "Windows":
		text += "\nIf nobody can join: Windows Defender Firewall must let Godot in, for this network (set the network to Private)."
	return text


## What usually keeps a joining player from reaching a host.
func _why_unreached() -> String:
	return (". On the host's computer, its firewall must let Godot in: Windows asks the first time a room is hosted (allow it for " +
		"private networks, and set the network to Private); a Mac with its firewall on asks too. Both computers must be on the same " +
		"network (a guest Wi-Fi often keeps its computers apart), or the host's ports open to the internet.")


func _fill_players() -> void:
	var net = app.net
	for child in _players.get_children():
		child.queue_free()
	for id in net.players:
		var info: Dictionary = net.players[id]
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 10)
		_players.add_child(row)
		var line := Label.new()
		var colour: Array = info.get("color", [0.8, 0.8, 0.8])
		line.text = "%s%s  ·  %d cm" % [str(info.get("name", "Player")), "  (you)" if int(id) == net.me else ("  (host)" if int(id) == 1 else ""),
			roundi(float(info.get("height", 1.75)) * 100.0)]
		line.add_theme_color_override("font_color", Color(float(colour[0]), float(colour[1]), float(colour[2])))
		row.add_child(line)
		if net.role == "host" and int(id) != net.me:
			var remove := Button.new()
			remove.text = "Ask to leave"
			remove.flat = true
			remove.add_theme_font_size_override("font_size", 12)
			remove.pressed.connect(func() -> void: net.remove_player(int(id)))
			Hints.give(remove, "Takes them out of the session (they can join again, with the password if it has one)")
			row.add_child(remove)


## The rooms found on this network, kept as they were chosen.
func _fill_list() -> void:
	var discovery = app.net.discovery
	var rooms: Array = discovery.found()
	var shown := rooms.map(func(r): return [r.id, r.name, r.host, r.mode, r.players, r.most, r.locked, r.address])
	var listed_hash := hash([shown, discovery.problem])
	if listed_hash == _listed_hash:
		return
	_listed_hash = listed_hash
	var was := str(_chosen_listed().get("id", ""))
	_found = rooms
	_list.clear()
	var root := _list.create_item()
	for i in rooms.size():
		var room: Dictionary = rooms[i]
		var item := _list.create_item(root)
		item.set_text(0, str(room.name))
		item.set_text(1, str(room.host))
		item.set_text(2, "%s room" % ("Record" if str(room.mode) == "record" else "Jam"))
		item.set_text(3, "%d / %d" % [int(room.players), int(room.most)])
		item.set_text(4, "Password" if bool(room.locked) else "")
		for column in [1, 2, 3, 4]:
			item.set_custom_color(column, DIM)
		if int(room.get("protocol", 0)) != Net.PROTOCOL:
			item.set_text(4, "Another version")
			item.set_custom_color(4, WARN)
		item.set_metadata(0, i)
		if str(room.id) == was:
			item.select(0)
	_follow_choice()
	if discovery.problem != "":
		tell("Rooms on this network can't be found: %s." % discovery.problem)
	elif rooms.is_empty():
		_status.text = "Looking for rooms on this network…  None yet. A room hosted on another network is joined under Direct connect."
		_status.add_theme_color_override("font_color", DIM)
	else:
		_status.text = "%d room%s on this network" % [rooms.size(), "" if rooms.size() == 1 else "s"]
		_status.add_theme_color_override("font_color", DIM)


func _follow_choice() -> void:
	var room := _chosen_listed()
	_list_join.disabled = room.is_empty()
	_list_password.editable = bool(room.get("locked", false))
	if not _list_password.editable:
		_list_password.text = ""


# ── Building ────────────────────────────────────────────────────────────────────────────────────────────────

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
	_panel.custom_minimum_size.x = 760
	center.add_child(_panel)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 12)
	_panel.add_child(box)

	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 6)
	box.add_child(top)
	var title := Label.new()
	title.text = "Play together"
	title.add_theme_font_size_override("font_size", 22)
	top.add_child(title)
	var gap := Control.new()
	gap.custom_minimum_size.x = 18
	top.add_child(gap)
	_header = HBoxContainer.new()
	_header.add_theme_constant_override("separation", 6)
	top.add_child(_header)
	var group := ButtonGroup.new()
	_tab_button("rooms", "Rooms", group, "The rooms hosted on this network, found by themselves")
	_tab_button("host", "Host", group, "Host a room for others to join: the one open, a new one or a saved one")
	_tab_button("direct", "Direct connect", group, "Join a room by its host's address (or its code), from anywhere")
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top.add_child(spacer)
	var close_button := Button.new()
	close_button.text = "Close  (Esc)"
	close_button.pressed.connect(close)
	top.add_child(close_button)

	_build_rooms(box)
	_build_host(box)
	_build_direct(box)
	_build_session(box)

	_status = Label.new()
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(_status)
	var voice_row := _row(box)
	_label(voice_row, "Your voice")
	_voice = OptionButton.new()
	_voice.item_selected.connect(func(index: int) -> void: app.net.set_voice_input(index - 1))
	Hints.give(_voice, func() -> String:
		return "Which of your interface's inputs your voice comes in on: playing together, hold %s to talk, and the others hear you from where you stand (your own voice isn't sent back to you)" % app.bindings.label("talk"))
	voice_row.add_child(_voice)
	_hint = Hints.line()
	box.add_child(_hint)


func _tab_button(key: String, text: String, group: ButtonGroup, hint: String) -> void:
	var tab := Button.new()
	tab.text = text
	tab.toggle_mode = true
	tab.button_group = group
	tab.pressed.connect(show_tab.bind(key))
	Hints.give(tab, hint)
	_header.add_child(tab)
	_tabs[key] = tab


func _page(parent: Control, key: String) -> VBoxContainer:
	var page := VBoxContainer.new()
	page.add_theme_constant_override("separation", 10)
	parent.add_child(page)
	_pages[key] = page
	return page


func _build_rooms(box: Control) -> void:
	var page := _page(box, "rooms")
	_list = Tree.new()
	_list.columns = 5
	_list.column_titles_visible = true
	for column in 5:
		_list.set_column_title(column, ["Room", "Host", "Kind", "Players", ""][column])
		_list.set_column_expand(column, column < 2)
		_list.set_column_title_alignment(column, HORIZONTAL_ALIGNMENT_LEFT)
	_list.set_column_custom_minimum_width(2, 110)
	_list.set_column_custom_minimum_width(3, 80)
	_list.set_column_custom_minimum_width(4, 120)
	_list.hide_root = true
	_list.select_mode = Tree.SELECT_ROW
	_list.custom_minimum_size.y = 220
	_list.item_selected.connect(_follow_choice)
	_list.item_activated.connect(_join_listed)
	Hints.give(_list, "The rooms hosted on this network that are listed, found by themselves. Double-click one to join it")
	page.add_child(_list)
	var row := _row(page)
	_label(row, "Password")
	_list_password = LineEdit.new()
	_list_password.secret = true
	_list_password.placeholder_text = "If the room has one"
	_list_password.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list_password.text_submitted.connect(func(_text: String) -> void: _join_listed())
	Hints.give(_list_password, "The room's password, from its host")
	row.add_child(_list_password)
	_list_join = Button.new()
	_list_join.text = "Join"
	_list_join.pressed.connect(_join_listed)
	Hints.give(_list_join, "Your room becomes a copy of theirs (yours as it was is left as it was saved)")
	row.add_child(_list_join)


func _build_host(box: Control) -> void:
	var page := _page(box, "host")
	var room_row := _row(page)
	_label(room_row, "Room")
	_room_label = Label.new()
	_room_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_room_label.clip_text = true
	Hints.give(_room_label, "The room that is open: the one hosted")
	room_row.add_child(_room_label)
	_button(room_row, "New room…", func() -> void: _choose_room(true), "Make a new room to host, then come back here")
	_button(room_row, "Open a room…", func() -> void: _choose_room(false), "Open a saved room to host, then come back here")

	_rules_slot = VBoxContainer.new()
	page.add_child(_rules_slot)
	_rules_box = VBoxContainer.new()
	_rules_box.add_theme_constant_override("separation", 10)
	_rules_slot.add_child(_rules_box)
	var name_row := _row(_rules_box)
	_label(name_row, "Name")
	_session_name = LineEdit.new()
	_session_name.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_session_name.max_length = 40
	_session_name.text_changed.connect(func(_text: String) -> void:
		_named = true
		if app.net.role == "host":
			_on_rule_changed())
	Hints.give(_session_name, "What the room is called in others' room browsers (the room's own name, unless you give another)")
	name_row.add_child(_session_name)
	var options_row := _row(_rules_box)
	_listed = CheckBox.new()
	_listed.text = "Listed under Rooms"
	_listed.toggled.connect(func(_on: bool) -> void: _on_rule_changed())
	Hints.give(_listed, "Shown in the room browser of everyone on this network. Unlisted, it is joined only by its address")
	options_row.add_child(_listed)
	var gap := Control.new()
	gap.custom_minimum_size.x = 18
	options_row.add_child(gap)
	_label(options_row, "Players, at most")
	_most = SpinBox.new()
	_most.min_value = 2
	_most.max_value = Net.MAX_GUESTS + 1
	_most.value_changed.connect(func(_value: float) -> void: _on_rule_changed())
	Hints.give(_most, "How many can be in the room at once, you included")
	options_row.add_child(_most)
	var may_label := _label(_rules_box, "Joining players may, besides playing and talking:")
	may_label.add_theme_font_size_override("font_size", 13)
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 18)
	_rules_box.add_child(grid)
	for key in Net.MAY:
		var choice := CheckBox.new()
		choice.text = MAY_LABELS[key]
		choice.toggled.connect(func(_on: bool) -> void: _on_rule_changed())
		Hints.give(choice, "Unticked, a joining player who tries to %s is told the host hasn't let them, and it stays as it is" % Net.MAY[key])
		grid.add_child(choice)
		_may[key] = choice

	var password_row := _row(page)
	_label(password_row, "Password")
	_host_password = LineEdit.new()
	_host_password.secret = true
	_host_password.placeholder_text = "None"
	_host_password.custom_minimum_size.x = 220
	Hints.give(_host_password, "Only those who give it can join (it keeps out anyone who comes across the room; it isn't encryption)")
	password_row.add_child(_host_password)

	var internet_row := _row(page)
	_internet = CheckBox.new()
	_internet.text = "Over the internet"
	Hints.give(_internet, "Asks your router (by UPnP, which most home routers allow) to open the session's two ports to this computer while you host, and shows the address others join at from anywhere (closed again when the session ends). With a session server, the room also gets a code that others join with, which works where the router won't open them")
	internet_row.add_child(_internet)
	_label(internet_row, "Port")
	_port = SpinBox.new()
	_port.min_value = 1024
	_port.max_value = 65535
	_port.value = Net.PORT
	_port.select_all_on_focus = true
	Hints.give(_port, "The port the others join on (and the next, for the sound between players). Over the internet, these are the ones the router opens")
	internet_row.add_child(_port)
	_label(internet_row, "Session server")
	_server = LineEdit.new()
	_server.placeholder_text = "None"
	_server.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_server.text = app.settings.session_server
	_server.text_changed.connect(func(text: String) -> void:
		app.settings.session_server = text.strip_edges()
		app.settings.save_to_disk())
	Hints.give(_server, "Not needed on one network, nor where the router opens its ports. A machine on the internet that players meet through (its address, and :port if not 47100), for when a router won't: hosting over the internet, the room gets a code that others join with, from anywhere. Everyone uses the same one. Running one: docs/session-server.md")
	internet_row.add_child(_server)

	var host_row := _row(page)
	_host_button = _button(host_row, "Host", func() -> void: host(), "Others can then join the room that is open: their copies kept the same as yours, each hearing it from where they stand")
	_host_button.custom_minimum_size.x = 120


func _build_direct(box: Control) -> void:
	var page := _page(box, "direct")
	var note := _label(page, "A room on this network is listed under Rooms. One elsewhere is joined at its host's address, which their Play together page shows.")
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	var address_row := _row(page)
	_label(address_row, "Address")
	_address = LineEdit.new()
	_address.placeholder_text = "The host's address (and :port, if not %d), or the session's code" % Net.PORT
	_address.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_address.text_submitted.connect(func(_text: String) -> void: join(_address.text, _password.text))
	Hints.give(_address, "What the host's page shows: on the same network, their address there (192.168…); over the internet, their public one, or the session's code (K7Q-M2D), found through the session server")
	address_row.add_child(_address)
	var password_row := _row(page)
	_label(password_row, "Password")
	_password = LineEdit.new()
	_password.secret = true
	_password.placeholder_text = "If the room has one"
	_password.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_password.text_submitted.connect(func(_text: String) -> void: join(_address.text, _password.text))
	Hints.give(_password, "The room's password, from its host")
	password_row.add_child(_password)
	var join_row := _row(page)
	_join_button = _button(join_row, "Join", func() -> void: join(_address.text, _password.text), "Your room becomes a copy of theirs (yours as it was is left as it was saved)")
	_join_button.custom_minimum_size.x = 120


func _build_session(box: Control) -> void:
	_session = VBoxContainer.new()
	_session.add_theme_constant_override("separation", 10)
	box.add_child(_session)
	_session_title = Label.new()
	_session_title.add_theme_font_size_override("font_size", 18)
	_session.add_child(_session_title)
	_where = Label.new()
	_where.add_theme_color_override("font_color", ACCENT)
	_where.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_session.add_child(_where)
	_label(_session, "In the room")
	_players = VBoxContainer.new()
	_session.add_child(_players)
	_session_rules = VBoxContainer.new()
	_session.add_child(_session_rules)
	_rules_text = Label.new()
	_rules_text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_rules_text.add_theme_color_override("font_color", DIM)
	_session.add_child(_rules_text)
	var buttons := _row(_session)
	_enter_button = _button(buttons, "Into the room", func() -> void:
		close()
		app.title.enter(), "Back into the room, the session going on")
	_leave_button = _button(buttons, "Leave", func() -> void: app.net.leave(), "")
	Hints.give(_leave_button, func() -> String:
		return "Ends the session for everyone (their copies of the room are theirs to keep)" if app.net.role == "host" else \
			"Leaves the session: your copy of the room is yours to keep")


## Your voice's choices: none, or each input of the input device (as many as it says it has, eight if it isn't known).
func _fill_voice() -> void:
	var inputs := 8
	for device in app.audio.get_input_devices():
		if str(device.get("name", "")) == app.settings.input_device or (app.settings.input_device == "" and bool(device.get("is_default", false))):
			inputs = maxi(int(device.get("channels", 8)), 1)
	_voice.clear()
	_voice.add_item("None")
	for i in inputs:
		_voice.add_item("Input %d" % (i + 1))
	_voice.select(clampi(app.settings.voice_input + 1, 0, inputs))


func _row(parent: Control) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	parent.add_child(row)
	return row


func _label(parent: Control, text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_color_override("font_color", DIM)
	parent.add_child(label)
	return label


func _button(parent: Control, text: String, on_pressed: Callable, hint: String) -> Button:
	var button := Button.new()
	button.text = text
	button.pressed.connect(on_pressed)
	if hint != "":
		Hints.give(button, hint)
	parent.add_child(button)
	return button
