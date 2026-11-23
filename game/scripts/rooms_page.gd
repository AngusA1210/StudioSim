extends CanvasLayer
## Making a new room, or opening one, from the title screen (as a DAW's dashboard does).
##
## New room: its name, the folder it goes in (a folder of its own is made there, named after it), the template it
## starts from, its size (the template's to begin with), and what to bring over from the template, everything to
## begin with: its walls, its instruments where they stand (with their patterns, their faders, mute and solo, their
## own settings, and their plug-ins), and its tempo. Templates appear only here.
## Open a room: the rooms in the rooms folder and those opened lately, the latest first, or any room's file found with
## Browse. A room that has changes asks first whether to save them.

const UI := preload("res://scripts/ui.gd")
const Hints := preload("res://scripts/hints.gd")
const Room := preload("res://scripts/room.gd")
const DIM := Color(0.62, 0.65, 0.74)
const WARN := Color(1.0, 0.61, 0.48)
const ACCENT := Color(0.49, 0.89, 0.82)
# What can be brought over from a template, in order: [key, words, hint, belongs to the instruments].
const CARRY := [
	["walls", "Walls", "The walls standing in the room", false],
	["instruments", "Instruments, where they stand", "Every instrument, standing and facing as it does in the template", false],
	["patterns", "Their patterns", "Each MIDI instrument's pattern: its notes, its length, and whether its loop is on", true],
	["mix", "Fader levels, mute and solo", "Each instrument's fader, whether it is muted or soloed, and the master fader (at 0 dB otherwise)", true],
	["instrument_settings", "Amp and Speaker settings", "Amps' heads, cabinets, knobs and pedals, and Speakers' volume", true],
	["plugins", "Plug-ins and their settings", "The plug-ins on the inserts and the Plug-in pedals, each with its settings", true],
	["tempo", "Tempo and swing", "The tempo and swing, rather than the default ones", false],
]

var app
## Where to go once a room is made or opened, or the page is closed, in place of going into the room: the Play
## together page, hosting a new room or a saved one.
var back_to := Callable()
var _root: Control
var _panel: PanelContainer
var _new_tab: Button
var _open_tab: Button
var _new_page: Control
var _open_page: Control
var _hint: Label

# New room
var _name: LineEdit
var _folder := ""
var _folder_label: Label
var _templates: Array = []
var _template_list: ItemList
var _template_trash: Button
var _size := {}  # "x", "y", "z" → SpinBox
var _carry := {}  # key → CheckBox
var _jam: Button   # what the room is made as: a Jam room or a Record room
var _record: Button
var _new_status: Label
var _create: Button
var _folder_dialog: FileDialog

# Open a room
var _rooms: Array = []
var _room_list: Tree
var _open: Button
var _open_status: Label
var _file_dialog: FileDialog


func setup(the_app) -> void:
	app = the_app
	layer = 10
	_build()
	_root.visible = false


func is_open() -> bool:
	return _root.visible


## The New room page: named "Untitled room" (or the next free one), made as the last room was, from the template chosen
## last; or, as the tutorial has it, named after `base`, as a `mode` room, from `template`.
func open_new(base := "Untitled room", mode := "", template := "") -> void:
	_show(true)
	_folder = app.session.location()
	_folder_label.text = _folder.replace(OS.get_environment("HOME"), "~")
	_name.text = _unused_name(base)
	(_record if (mode if mode != "" else app.settings.room_mode) == "record" else _jam).button_pressed = true
	_fill_templates(template)
	for key in _carry:
		_carry[key].set_pressed_no_signal(true)
	_follow_carry()
	_check_name()
	_name.grab_focus()
	_name.select_all()


## Where little is shown on the New room page (its template list, below the few templates there are): for the
## tutorial's card. Nothing while the other page is shown.
func spare_rect() -> Rect2:
	if not is_open() or not _new_page.visible:
		return Rect2()
	var list := _template_list.get_global_rect()
	var below := 0.0  # (below the last template)
	if _template_list.item_count > 0:
		below = _template_list.get_item_rect(_template_list.item_count - 1).end.y + 8.0
	return Rect2(list.position.x, list.position.y + below, list.size.x, list.size.y - below)


func open_existing() -> void:
	_show(false)
	_fill_rooms()


func close() -> void:
	_root.visible = false
	_folder_dialog.hide()
	_file_dialog.hide()
	if back_to.is_valid():
		var going := back_to
		back_to = Callable()
		going.call()


## A room made or opened: into it (or back to where the page was opened from).
func _into_room() -> void:
	var returning := back_to.is_valid()
	close()
	if not returning:
		app.title.enter()


func _show(new_room: bool) -> void:
	_root.visible = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_new_page.visible = new_room
	_open_page.visible = not new_room
	_new_tab.set_pressed_no_signal(new_room)
	_open_tab.set_pressed_no_signal(not new_room)
	_new_status.text = ""
	_open_status.text = ""


func _input(event: InputEvent) -> void:
	if not is_open() or app.name_prompt.is_open() or app.session.is_asking():
		return
	if event is InputEventKey and event.pressed and not event.echo and event.physical_keycode == KEY_ESCAPE:
		close()
		get_viewport().set_input_as_handled()


func _process(_delta: float) -> void:
	if not is_open():
		return
	var vp := get_viewport().get_visible_rect().size
	_panel.custom_minimum_size = Vector2(minf(920.0, vp.x - 32.0), minf(600.0, vp.y - 32.0))
	_hint.text = Hints.under_mouse(_panel)


# ── New room ─────────────────────────────────────────────────────────────────────────────────────────────────

## "Untitled room", or "Untitled room 2" and so on if that is taken.
func _unused_name(base := "Untitled room") -> String:
	var candidate := base
	var number := 2
	while app.session.exists(_folder, candidate):
		candidate = "%s %d" % [base, number]
		number += 1
	return candidate


func _fill_templates(choose := "") -> void:
	var was: String = choose if choose != "" else _chosen_template().get("path", app.library.DEFAULT_TEMPLATE)
	_templates = app.library.templates()
	_template_list.clear()
	var index := 0
	for i in _templates.size():
		_template_list.add_item(_templates[i].name)
		if _templates[i].path == was:
			index = i
	_template_list.select(index)
	_on_template_chosen()


func _chosen_template() -> Dictionary:
	if _template_list == null:
		return {}
	var picked := _template_list.get_selected_items()
	return _templates[picked[0]] if not picked.is_empty() and picked[0] < _templates.size() else {}


## A template chosen: the room's size becomes the template's, to be changed if wanted.
func _on_template_chosen() -> void:
	var template := _chosen_template()
	_template_trash.disabled = template.is_empty() or str(template.path).begins_with("builtin:")
	var size: Vector3 = app.library.size_of(app.library.template_data(template.get("path", app.library.DEFAULT_TEMPLATE)))
	for axis in _size:
		_size[axis].set_value_no_signal(size[axis])


## The instruments' own boxes count only while the instruments come over.
func _follow_carry() -> void:
	var with_instruments: bool = _carry.instruments.button_pressed
	for entry in CARRY:
		if entry[3]:
			_carry[entry[0]].disabled = not with_instruments


func _check_name() -> void:
	var the_name := _name.text.strip_edges()
	var taken: bool = the_name != "" and app.session.exists(_folder, the_name)
	_create.disabled = the_name == "" or taken
	_new_status.text = "There is a room called that in this folder already." if taken else ""
	_new_status.add_theme_color_override("font_color", WARN)


## Makes the room, once any changes to the one open are saved or let go, and goes into it.
func create() -> void:
	var the_name := _name.text.strip_edges()
	if _create.disabled or the_name == "":
		return
	var carry := {}
	for key in _carry:
		carry[key] = _carry[key].button_pressed and not _carry[key].disabled
	var size := Vector3(_size.x.value, _size.y.value, _size.z.value)
	var template := _chosen_template()
	app.session.then_if_saved(func() -> void:
		var mode := "record" if _record.button_pressed else "jam"
		app.settings.room_mode = mode
		app.settings.save_to_disk()
		# (shown as it is put in place, its plug-ins loading; all at once while playing together, the room being shared)
		var problem: String = await app.session.create_shown(the_name, _folder, template.path, carry, size, mode) if app.net.role == "" \
			else app.session.create(the_name, _folder, template.path, carry, size, mode)
		if not app.session.has_room() or app.session.room_name != the_name:
			_new_status.text = "It couldn't be made: %s." % problem
			return
		_into_room()
		if problem != "":
			app.session.notice.emit("Not all of the template came over: %s" % problem), "making a new room")


func _on_folder_chosen(folder: String) -> void:
	_folder = folder
	_folder_label.text = folder.replace(OS.get_environment("HOME"), "~")
	if not app.library.automated:
		app.settings.rooms_location = folder
		app.settings.save_to_disk()
	_check_name()


func _on_template_trash_pressed() -> void:
	var template := _chosen_template()
	if template.is_empty() or str(template.path).begins_with("builtin:"):
		return
	app.library.delete_file(template.path)
	_template_list.deselect_all()
	_fill_templates()


# ── Open a room ──────────────────────────────────────────────────────────────────────────────────────────────

func _fill_rooms() -> void:
	_rooms = app.session.rooms()
	_room_list.clear()
	var root := _room_list.create_item()
	for i in _rooms.size():
		var room: Dictionary = _rooms[i]
		var item := _room_list.create_item(root)
		item.set_text(0, room.name + ("   (open)" if room.path == app.session.path else ""))
		var when: Dictionary = Time.get_datetime_dict_from_unix_time(int(room.modified) + int(Time.get_time_zone_from_system().get("bias", 0)) * 60)
		item.set_text(1, "%d-%02d-%02d  %02d:%02d" % [when.year, when.month, when.day, when.hour, when.minute])
		item.set_text(2, room.path.get_base_dir().get_base_dir().replace(OS.get_environment("HOME"), "~"))
		for column in [1, 2]:
			item.set_custom_color(column, DIM)
		item.set_metadata(0, i)
	if not _rooms.is_empty():
		root.get_first_child().select(0)
	_open.disabled = _rooms.is_empty()
	_open_status.text = "" if not _rooms.is_empty() else "No rooms yet. Make one with New room, or find one with Browse."
	_open_status.add_theme_color_override("font_color", DIM)


func _chosen_room() -> Dictionary:
	var item := _room_list.get_selected()
	return _rooms[int(item.get_metadata(0))] if item != null else {}


## Opens a room's file, once any changes to the one open are saved or let go, and goes into it.
func open_room(file: String) -> void:
	if file == app.session.path:  # the one that is open: just go back in
		_into_room()
		return
	app.session.then_if_saved(func() -> void:
		var problem: String = await app.session.open_shown(file) if app.net.role == "" else app.session.open(file)
		if app.session.path != file:
			_open_status.text = "It couldn't be opened: %s." % problem
			_open_status.add_theme_color_override("font_color", WARN)
			return
		_into_room()
		if problem != "":
			app.session.notice.emit("Not all of it could be set up: %s" % problem), "opening another room")


# ── Building ─────────────────────────────────────────────────────────────────────────────────────────────────

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
	header.add_theme_constant_override("separation", 6)
	box.add_child(header)
	var group := ButtonGroup.new()
	_new_tab = _tab(header, "New room", group, open_new)
	_open_tab = _tab(header, "Open a room", group, open_existing)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(spacer)
	var close_button := Button.new()
	UI.ghost_button(close_button)
	UI.keyed(close_button, "Close", "Esc")
	close_button.pressed.connect(close)
	header.add_child(close_button)

	_new_page = _build_new_page()
	box.add_child(_new_page)
	_open_page = _build_open_page()
	box.add_child(_open_page)
	_hint = Hints.line()
	box.add_child(_hint)

	_folder_dialog = FileDialog.new()
	_folder_dialog.file_mode = FileDialog.FILE_MODE_OPEN_DIR
	_folder_dialog.access = FileDialog.ACCESS_FILESYSTEM
	_folder_dialog.use_native_dialog = true
	_folder_dialog.title = "Where the room goes"
	_folder_dialog.dir_selected.connect(_on_folder_chosen)
	_root.add_child(_folder_dialog)
	_file_dialog = FileDialog.new()
	_file_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	_file_dialog.access = FileDialog.ACCESS_FILESYSTEM
	_file_dialog.use_native_dialog = true
	_file_dialog.title = "Open a room"
	_file_dialog.filters = PackedStringArray(["*.%s ; StudioSim rooms" % app.library.ROOM_EXT])
	_file_dialog.file_selected.connect(open_room)
	_root.add_child(_file_dialog)


func _build_new_page() -> Control:
	var page := HBoxContainer.new()
	page.add_theme_constant_override("separation", 24)
	page.size_flags_vertical = Control.SIZE_EXPAND_FILL

	var left := VBoxContainer.new()
	left.add_theme_constant_override("separation", 8)
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	page.add_child(left)
	_heading(left, "Name")
	_name = LineEdit.new()
	_name.add_theme_font_size_override("font_size", 18)
	_name.text_changed.connect(func(_text: String) -> void: _check_name())
	_name.text_submitted.connect(func(_text: String) -> void: create())
	left.add_child(_name)
	var where := HBoxContainer.new()
	where.add_theme_constant_override("separation", 8)
	left.add_child(where)
	_folder_label = Label.new()
	_folder_label.add_theme_color_override("font_color", DIM)
	_folder_label.add_theme_font_size_override("font_size", 13)
	_folder_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_folder_label.clip_text = true
	_folder_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	Hints.give(_folder_label, "Where the room goes: a folder named after it is made here, holding its file and its backups")
	where.add_child(_folder_label)
	var change := Button.new()
	change.text = "Change…"
	change.pressed.connect(func() -> void:
		_folder_dialog.current_dir = _folder
		_folder_dialog.popup_centered(Vector2i(700, 500)))
	where.add_child(change)

	var template_row := HBoxContainer.new()
	template_row.add_theme_constant_override("separation", 8)
	left.add_child(template_row)
	var template_heading := _heading(template_row, "Template")
	template_heading.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var finder := Button.new()
	finder.text = "Show in Finder"
	finder.flat = true
	finder.add_theme_font_size_override("font_size", 12)
	finder.pressed.connect(func() -> void: app.library.show_folder(app.library.templates_dir()))
	Hints.give(finder, "The templates folder. A room is saved as a template from the menu's Room button")
	template_row.add_child(finder)
	_template_trash = Button.new()
	_template_trash.text = "Move to Trash"
	_template_trash.flat = true
	_template_trash.add_theme_font_size_override("font_size", 12)
	_template_trash.pressed.connect(_on_template_trash_pressed)
	template_row.add_child(_template_trash)
	_template_list = ItemList.new()
	_template_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_template_list.custom_minimum_size.y = 200
	_template_list.item_selected.connect(func(_index: int) -> void: _on_template_chosen())
	_template_list.item_activated.connect(func(_index: int) -> void: create())
	left.add_child(_template_list)

	var right := VBoxContainer.new()
	right.add_theme_constant_override("separation", 8)
	right.custom_minimum_size.x = 330
	page.add_child(right)
	_heading(right, "Mode")
	var modes := HBoxContainer.new()
	modes.add_theme_constant_override("separation", 8)
	right.add_child(modes)
	var mode_group := ButtonGroup.new()
	_jam = _mode_button(modes, "Jam", mode_group,
		"The patterns loop round to the tempo, as a jam does: start and stop them with Space")
	_record = _mode_button(modes, "Record", mode_group,
		"A timeline to record on, with the edit window (%s): tracks recorded with %s to the room's Audio Files folder" % [app.bindings.label("edit_window"),
			app.bindings.label("record")])
	right.add_child(HSeparator.new())
	_heading(right, "Size")
	for axis in [["x", "Width", Room.MIN_SIZE.x, Room.MAX_SIZE.x, 0.5], ["z", "Length", Room.MIN_SIZE.z, Room.MAX_SIZE.z, 0.5],
			["y", "Height", Room.MIN_SIZE.y, Room.MAX_SIZE.y, 0.1]]:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 10)
		var label := Label.new()
		label.text = axis[1]
		label.custom_minimum_size.x = 70
		label.add_theme_color_override("font_color", DIM)
		row.add_child(label)
		var spin := SpinBox.new()
		spin.min_value = axis[2]
		spin.max_value = axis[3]
		spin.step = axis[4]
		spin.suffix = "m"
		spin.custom_minimum_size.x = 120
		row.add_child(spin)
		right.add_child(row)
		_size[axis[0]] = spin
	right.add_child(HSeparator.new())
	_heading(right, "From the template")
	for entry in CARRY:
		var check := CheckBox.new()
		check.text = entry[1]
		check.button_pressed = true
		Hints.give(check, entry[2])
		if entry[3]:  # one of the instruments' own: set in under them
			var indent := MarginContainer.new()
			indent.add_theme_constant_override("margin_left", 24)
			indent.add_child(check)
			right.add_child(indent)
		else:
			right.add_child(check)
		_carry[entry[0]] = check
	_carry.instruments.toggled.connect(func(_on: bool) -> void: _follow_carry())
	var gap := Control.new()
	gap.size_flags_vertical = Control.SIZE_EXPAND_FILL
	right.add_child(gap)
	var footer := HBoxContainer.new()
	footer.add_theme_constant_override("separation", 10)
	right.add_child(footer)
	_new_status = Label.new()
	_new_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_new_status.add_theme_font_size_override("font_size", 13)
	_new_status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	footer.add_child(_new_status)
	_create = Button.new()
	_create.text = "Create room"
	_create.custom_minimum_size = Vector2(150, 40)
	_create.add_theme_color_override("font_color", ACCENT)
	_create.pressed.connect(create)
	footer.add_child(_create)
	return page


func _build_open_page() -> Control:
	var page := VBoxContainer.new()
	page.add_theme_constant_override("separation", 10)
	page.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_room_list = Tree.new()
	_room_list.hide_root = true
	_room_list.columns = 3
	_room_list.set_column_expand_ratio(0, 3)
	_room_list.set_column_expand_ratio(1, 2)
	_room_list.set_column_expand_ratio(2, 3)
	_room_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_room_list.item_activated.connect(func() -> void: _on_open_pressed())
	page.add_child(_room_list)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	page.add_child(row)
	_open = Button.new()
	_open.text = "Open"
	_open.custom_minimum_size = Vector2(110, 40)
	_open.add_theme_color_override("font_color", ACCENT)
	_open.pressed.connect(_on_open_pressed)
	row.add_child(_open)
	var browse := Button.new()
	browse.text = "Browse…"
	Hints.give(browse, "Find a room's file anywhere, a backup from its Room Backups folder among them")
	browse.pressed.connect(func() -> void:
		_file_dialog.current_dir = app.session.location()
		_file_dialog.popup_centered(Vector2i(700, 500)))
	row.add_child(browse)
	var finder := Button.new()
	finder.text = "Show in Finder"
	finder.pressed.connect(func() -> void:
		var room := _chosen_room()
		app.library.show_folder(room.path.get_base_dir() if not room.is_empty() else app.session.location()))
	row.add_child(finder)
	_open_status = Label.new()
	_open_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_open_status.add_theme_font_size_override("font_size", 13)
	_open_status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(_open_status)
	return page


func _on_open_pressed() -> void:
	var room := _chosen_room()
	if not room.is_empty():
		open_room(room.path)


func _mode_button(parent: Control, text: String, group: ButtonGroup, hint: String) -> Button:
	var button := Button.new()
	button.text = text
	button.toggle_mode = true
	button.button_group = group
	button.focus_mode = Control.FOCUS_NONE
	button.custom_minimum_size = Vector2(110, 32)
	Hints.give(button, hint)
	parent.add_child(button)
	return button


func _tab(parent: Control, text: String, group: ButtonGroup, on_pressed: Callable) -> Button:
	var button := Button.new()
	button.text = text
	button.toggle_mode = true
	button.button_group = group
	button.focus_mode = Control.FOCUS_NONE
	button.add_theme_font_size_override("font_size", 18)
	button.pressed.connect(on_pressed)
	parent.add_child(button)
	return button


func _heading(parent: Control, text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", 16)
	parent.add_child(label)
	return label
