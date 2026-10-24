extends RefCounted
## What a track's menu offers (a right-click on its name, in the mix window or the edit window), whatever else that
## window adds: renaming it, its colour (from Pro Tools' kind of palette), and its folder: the tracks chosen in a new
## one (Cmd-G), into another folder, out of its own (an instrument's track, an aux track, or a folder with all in it);
## a new aux track; and for a folder or an aux, stereo or mono, and taking it away. A new folder or aux track can be
## stereo or mono, as in Pro Tools' New Track dialog. A microphone's track, its polarity (Ø); an acoustic kit's, its
## microphones put up in one go. These are the ids it uses.

const RENAME := 500
const NEW_FOLDER := 501
const OUT := 502
const REMOVE_FOLDER := 503
const NEW_AUX := 504
const REMOVE_AUX := 505
const STEREO := 506
const MONO := 507
const NEW_MONO_FOLDER := 508
const NEW_MONO_AUX := 509
const POLARITY := 510
const MIC_KIT := 520  # and on, a setup each (kit_mics.gd's)
const INTO := 600  # and on, a folder each

const KitMics := preload("res://scripts/kit_mics.gd")


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
	if track.get("is_master"):
		return
	if track.is_folder:  # its format: two channels, its pan a balance; or one, its pan placing it
		var kind := "aux track" if track.is_aux else "folder"
		menu.add_radio_check_item("Stereo", STEREO)
		menu.set_item_checked(menu.get_item_index(STEREO), not track.mono)
		menu.set_item_tooltip(menu.get_item_index(STEREO), "A stereo %s: two channels, its inserts in stereo, its pan a balance" % kind)
		menu.add_radio_check_item("Mono", MONO)
		menu.set_item_checked(menu.get_item_index(MONO), track.mono)
		menu.set_item_tooltip(menu.get_item_index(MONO),
			"A mono %s: what reaches it summed to one channel (its inserts and meter that one), its pan placing it in the mix" % kind)
		menu.add_separator()
	elif track.get("is_mic"):
		menu.add_check_item("Polarity inverted (Ø)", POLARITY)
		menu.set_item_checked(menu.get_item_index(POLARITY), track.mic_inverted)
		menu.set_item_tooltip(menu.get_item_index(POLARITY),
			"Turns its signal over at its preamp, before it records: for a mic facing another the other way, as one under a snare against one over it")
		menu.add_separator()
	elif track.has_parts():
		for i in KitMics.ORDER.size():
			var setup: Dictionary = KitMics.SETUPS[KitMics.ORDER[i]]
			menu.add_item(setup.name, MIC_KIT + i)
			menu.set_item_tooltip(menu.get_item_index(MIC_KIT + i), setup.hint + ": each named, pointed and its gain set, in a folder of their own")
		menu.add_separator()
	menu.add_item("New stereo aux track", NEW_AUX)
	menu.add_item("New mono aux track", NEW_MONO_AUX)
	var chosen: int = app.chosen_tracks.size() if app.chosen_tracks.has(track) else 1
	var with := "the %d chosen tracks" % chosen if chosen > 1 else "it"
	menu.add_item("New stereo folder with %s  (%s)" % [with, app.bindings.label("group")], NEW_FOLDER)
	menu.add_item("New mono folder with %s" % with, NEW_MONO_FOLDER)
	var own = app.folder_of(track)
	for i in app.folders.size():  # (those it can go in: not itself, nor one its own sound reaches)
		if app.folders[i] != own and app.can_put_in(track, app.folders[i]):
			menu.add_item("Into %s" % app.folders[i].display_name, INTO + i)
	if own != null:
		menu.add_item("Out of %s" % own.display_name, OUT)
	if track.is_aux:
		menu.add_item("Remove the aux track (and the sends to it)", REMOVE_AUX)
	elif track.is_folder:
		menu.add_item("Remove the folder (its tracks go where it went)", REMOVE_FOLDER)


## Acts on one of the track's items. Returns whether `id` was one of them.
static func chosen(app, track, id: int) -> bool:
	if not app.has_track(track):  # (a master: renamed, nothing else)
		if id == RENAME and app.is_track(track):
			app.ask_track_name(track)
		return id >= RENAME
	# The tracks it acts on: every one chosen, if this is one of them (a folder's tracks going with it), or else just this one.
	var outermost_chosen := func(t): return app.chosen_tracks.has(t) and not app.folders_around(t).any(func(f): return app.chosen_tracks.has(f))
	var tracks: Array = app.track_order().filter(outermost_chosen) if app.chosen_tracks.has(track) else [track]
	match id:
		RENAME:
			app.ask_track_name(track)
		NEW_FOLDER, NEW_MONO_FOLDER:
			if not app.chosen_tracks.has(track):
				app.choose_track(track)
			app.group_chosen(id == NEW_MONO_FOLDER)
		OUT:  # (out of the folder it is in, into the one that one is in)
			for t in tracks:
				var own = app.folder_of(t)
				if own != null:
					app.put_in_folder(t, app.folder_of(own), own)
		REMOVE_FOLDER:
			app.remove_folder(track)
		NEW_AUX, NEW_MONO_AUX:
			app.add_aux("", id == NEW_MONO_AUX)
		REMOVE_AUX:
			app.remove_aux(track)
		STEREO, MONO:
			app.set_folder_mono(track, id == MONO)
		POLARITY:
			app.set_mic_polarity(track, not track.mic_inverted)
		MIC_KIT, MIC_KIT + 1, MIC_KIT + 2:
			app.mic_kit(track, KitMics.ORDER[id - MIC_KIT])
		_:
			if id < INTO or id - INTO >= app.folders.size():
				return false
			for t in tracks:
				app.put_in_folder(t, app.folders[id - INTO])
	return true
