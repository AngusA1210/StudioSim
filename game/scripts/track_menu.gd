extends RefCounted
## What a track's menu offers (a right-click on its name, in the mix window or the edit window), whatever else that
## window adds: renaming it, its colour (from Pro Tools' kind of palette), and its folder: the tracks chosen in a new
## one (Cmd-G), into another folder, out of its own; and for a folder, taking it away. These are the ids it uses.

const RENAME := 500
const NEW_FOLDER := 501
const OUT := 502
const REMOVE_FOLDER := 503
const NEW_AUX := 504
const REMOVE_AUX := 505
const INTO := 600  # and on, a folder each


## The colours, as a submenu of swatches: choosing one calls `on_color` with it.
static func colors_menu(app, on_color: Callable) -> PopupMenu:
	var menu := PopupMenu.new()
	for i in app.TRACK_COLORS.size():
		var image := Image.create(14, 14, false, Image.FORMAT_RGBA8)
		image.fill(app.TRACK_COLORS[i][1])
		menu.add_icon_item(ImageTexture.create_from_image(image), app.TRACK_COLORS[i][0], i)
	menu.id_pressed.connect(func(id: int) -> void: on_color.call(app.TRACK_COLORS[id][1]))
	return menu


## The automation modes, as a submenu: choosing one calls `on_mode` with it. Ticked as the track has it when shown.
static func modes_menu(app, on_mode: Callable) -> PopupMenu:
	var menu := PopupMenu.new()
	for i in app.automation.MODES.size():
		menu.add_radio_check_item(app.automation.MODE_NAMES[app.automation.MODES[i]], i)
	menu.id_pressed.connect(func(id: int) -> void: on_mode.call(app.automation.MODES[id]))
	return menu


## Adds the track's items to `menu` (with `colors` as its Colour submenu, and `modes` its Automation one, children of it).
static func add_items(menu: PopupMenu, app, track, colors: PopupMenu, modes: PopupMenu = null) -> void:
	menu.add_item("Rename…", RENAME)
	menu.add_submenu_node_item("Colour", colors)
	if modes != null:
		for i in modes.item_count:
			modes.set_item_checked(i, app.automation.MODES[i] == track.auto_mode)
		menu.add_submenu_node_item("Automation: %s" % app.automation.MODE_NAMES[track.auto_mode], modes)
	menu.add_separator()
	if track.is_aux:
		menu.add_item("New aux track", NEW_AUX)
		menu.add_item("Remove the aux track (and the sends to it)", REMOVE_AUX)
		return
	if track.is_folder:
		menu.add_item("New aux track", NEW_AUX)
		menu.add_item("Remove the folder (its tracks go straight to the master)", REMOVE_FOLDER)
		return
	menu.add_item("New aux track", NEW_AUX)
	var chosen: int = app.chosen_tracks.filter(func(t): return not t.is_folder).size() if app.chosen_tracks.has(track) else 1
	menu.add_item("New folder with %s  (%s)" % ["the %d chosen tracks" % chosen if chosen > 1 else "it", app.bindings.label("group")], NEW_FOLDER)
	var own = app.folder_of(track)
	for i in app.folders.size():
		if app.folders[i] != own:
			menu.add_item("Into %s" % app.folders[i].display_name, INTO + i)
	if own != null:
		menu.add_item("Out of %s" % own.display_name, OUT)


## Acts on one of the track's items. Returns whether `id` was one of them.
static func chosen(app, track, id: int) -> bool:
	if not app.has_track(track):
		return id >= RENAME
	# The tracks it acts on: every one chosen, if this is one of them, or else just this one.
	var tracks: Array = app.instruments.filter(func(inst): return app.chosen_tracks.has(inst)) if app.chosen_tracks.has(track) else [track]
	match id:
		RENAME:
			app.ask_track_name(track)
		NEW_FOLDER:
			if not app.chosen_tracks.has(track):
				app.choose_track(track)
			app.group_chosen()
		OUT:
			for inst in tracks:
				app.put_in_folder(inst, null)
		REMOVE_FOLDER:
			app.remove_folder(track)
		NEW_AUX:
			app.add_aux()
		REMOVE_AUX:
			app.remove_aux(track)
		_:
			if id < INTO or id - INTO >= app.folders.size():
				return false
			for inst in tracks:
				if not inst.is_folder:
					app.put_in_folder(inst, app.folders[id - INTO])
	return true
