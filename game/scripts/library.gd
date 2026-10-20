extends RefCounted
## What SoundRoom keeps on disk, and copying and pasting settings.
##
## - Rooms and templates: what a room holds (room_data: its size and walls, every instrument where it stands with its
##   fader, mute, solo, pattern, pedals and plug-ins with their settings, the tempo and swing, and where you stand),
##   and putting it back (apply_room_data). session.gd keeps rooms, each a .sroom file in a folder of its own, in
##   SoundRoom/Rooms; templates are .srtemplate files in SoundRoom/Templates, two built in (the default room, an empty
##   one), and a new room starts from one, carrying over as much of it as is chosen. (SoundRoom/ is the folder the
##   game runs from: see home().)
## - Instrument presets: an instrument's sound, without where it stands or what it plays: the plug-ins on its inserts,
##   an amp's head, cabinet, knobs and pedals, a Speaker's volume, a plug-in instrument's plug-in. A .srpreset file in
##   SoundRoom/Instrument Presets, in a folder for each family (amps, Speakers, MIDI instruments, plug-in instruments). One loads onto any instrument of its
##   family, or comes into the room as a new instrument from the instrument menu.
## - Plug-in presets: a plug-in's settings as an .aupreset file in ~/Library/Audio/Presets/Maker/Plug-in, where every
##   Audio Unit host keeps them, so presets saved in Logic show up here and the other way round. The presets a plug-in
##   comes with are listed alongside.
## - Copy and paste: an instrument's settings (onto another of its family) or a plug-in's (onto the same plug-in),
##   held until something else is copied.
##
## Files are JSON, plug-in settings in them base64. Automated runs keep everything in a folder of their own, emptied
## at start, and never touch the real ones.

const ROOM_EXT := "sroom"
const TEMPLATE_EXT := "srtemplate"
const PRESET_EXT := "srpreset"
const VERSION := 1
const DEFAULT_TEMPLATE := "builtin:default"
const EMPTY_TEMPLATE := "builtin:empty"
const FAMILIES := {"amp": "Amps", "speaker": "Speakers", "midi": "MIDI instruments", "plugin": "Plug-in instruments"}

var app
var audio: SoundRoomAudio
var automated := false
var root := ""         # SoundRoom (see home())
var plugin_root := ""  # ~/Library/Audio/Presets
var copied_instrument := {}  # instrument_settings() of what was copied
var copied_plugin := {}      # {plugin_id, plugin_name, state}


func _init(the_app, automated_run: bool) -> void:
	app = the_app
	audio = app.audio
	automated = automated_run
	if automated:
		root = OS.get_user_data_dir().path_join("automated-run-library")
		_remove_tree(root)
		plugin_root = root.path_join("Audio Presets")
	else:
		root = home()
		plugin_root = OS.get_environment("HOME").path_join("Library/Audio/Presets")


## Where rooms, templates and instrument presets are kept: the SoundRoom folder the game runs from (the one holding
## game/), or for a build made to be handed out, which has no such folder, Music/SoundRoom.
static func home() -> String:
	if OS.has_feature("template"):
		return OS.get_system_dir(OS.SYSTEM_DIR_MUSIC).path_join("SoundRoom")
	return ProjectSettings.globalize_path("res://").get_base_dir().get_base_dir()


func templates_dir() -> String:
	return root.path_join("Templates")


func presets_dir(family := "") -> String:
	var dir := root.path_join("Instrument Presets")
	return dir if family == "" else dir.path_join(FAMILIES[family])


static func family_of(inst) -> String:
	if inst.plays_plugin:
		return "plugin"
	return "amp" if inst.is_amp else ("midi" if inst.playable else "speaker")


# ── An instrument's settings ─────────────────────────────────────────────────────────────────────────────────

## An instrument's sound, without where it stands or what it plays: its inserts (plug-ins and their settings), an amp's
## head, cabinet, knobs and pedals, and a Speaker's volume.
func instrument_settings(inst) -> Dictionary:
	var out := {"kind": inst.kind, "family": family_of(inst), "inserts": inserts_data(inst)}
	if family_of(inst) == "speaker":
		out.volume_db = inst.volume_db
	var played: Dictionary = audio.get_instrument_plugin(inst.source_id) if inst.plays_plugin else {}
	if str(played.get("plugin_id", "")) != "":  # a plug-in instrument's plug-in, which is the instrument itself
		out.instrument_plugin = {"plugin_id": played.plugin_id, "plugin_name": played.plugin_name, "plugin_maker": played.plugin_maker,
			"state": Marshalls.raw_to_base64(audio.get_plugin_state(inst.source_id, "instrument", 0))}
	if inst.is_amp:
		var pedals := []
		var board: Array = audio.get_pedals(inst.source_id)
		for i in board.size():
			var p: Dictionary = board[i]
			var pedal := {"kind": p.kind, "on": p.on, "controls": Array(p.controls)}
			if p.kind == "plugin" and p.plugin_id != "":
				pedal.merge({"plugin_id": p.plugin_id, "plugin_name": p.plugin_name, "plugin_maker": p.plugin_maker,
					"state": Marshalls.raw_to_base64(audio.get_plugin_state(inst.source_id, "pedal", i))})
			pedals.append(pedal)
		out.amp = {"head": inst.amp_head, "head_on": inst.head_on, "cabinet": inst.amp_cabinet, "cabinet_on": inst.cabinet_on,
			"controls": inst.amp_controls.duplicate(), "pedals": pedals}
	return out


## Gives an instrument these settings (from instrument_settings, a preset or a template), replacing its own. What
## applies to it does: an amp's parts only to an amp, a Speaker's volume only to a Speaker, inserts to anything.
## A plug-in that isn't installed leaves its insert empty. `include` can leave out the instrument's own settings
## ("instrument_settings": false) or the plug-ins ("plugins": false), which then aren't put back. Returns what
## couldn't be done, or "".
func apply_instrument_settings(inst, settings: Dictionary, include := {}) -> String:
	var problems := []
	var with_plugins: bool = include.get("plugins", true)
	var played = settings.get("instrument_plugin")
	if inst.plays_plugin and played is Dictionary:  # always: without it, a plug-in instrument would have no sound at all
		var problem: String = app.set_instrument_plugin(inst, str(played.get("plugin_id", "")), _bytes(played.get("state", "")))
		if problem != "":
			problems.append("%s: %s" % [played.get("plugin_name", "its plug-in"), problem])
	if inst.is_amp and settings.get("amp") is Dictionary and include.get("instrument_settings", true):
		var amp: Dictionary = settings.amp
		app.set_amp_voice(inst, str(amp.get("head", inst.amp_head)), bool(amp.get("head_on", true)),
			str(amp.get("cabinet", inst.amp_cabinet)), bool(amp.get("cabinet_on", true)))
		var controls: Dictionary = amp.get("controls", {})
		for control in controls:
			if inst.amp_controls.has(control):
				app.set_amp_control(inst, control, float(controls[control]))
		app.hide_plugin_editors(inst)
		for i in range(audio.get_pedals(inst.source_id).size() - 1, -1, -1):
			app.remove_pedal(inst, i)
		for pedal in amp.get("pedals", []):
			var at: int = app.add_pedal(inst, str(pedal.get("kind", "")))
			if at < 0:
				problems.append("a %s pedal" % str(pedal.get("kind", "")))
				continue
			var values: Array = pedal.get("controls", [])
			for c in values.size():
				app.set_pedal_control(inst, at, c, float(values[c]))
			app.set_pedal_on(inst, at, bool(pedal.get("on", true)))
			if str(pedal.get("plugin_id", "")) != "" and with_plugins:
				var problem: String = app.load_pedal_plugin(inst, at, pedal.plugin_id, _bytes(pedal.get("state", "")))
				if problem != "":
					problems.append("%s on pedal %d: %s" % [pedal.get("plugin_name", "a plug-in"), at + 1, problem])
	if family_of(inst) == "speaker" and settings.has("volume_db") and include.get("instrument_settings", true):
		app.set_speaker_volume(inst, float(settings.volume_db))
	var problem := apply_inserts(inst, settings.get("inserts", []) if with_plugins else [])
	if problem != "":
		problems.append(problem)
	return "; ".join(problems)


## A track's inserts (an instrument's or a folder's), as saved: each slot's plug-in with its settings, or null.
func inserts_data(track) -> Array:
	var out := []
	var inserts: Array = audio.get_inserts(track.source_id)
	for slot in inserts.size():
		var insert: Dictionary = inserts[slot]
		if insert.plugin_id == "":
			out.append(null)
		else:
			out.append({"plugin_id": insert.plugin_id, "plugin_name": insert.plugin_name, "plugin_maker": insert.plugin_maker,
				"on": insert.on, "state": Marshalls.raw_to_base64(audio.get_plugin_state(track.source_id, "insert", slot))})
	return out


## Puts a track's inserts back as saved. Returns what couldn't be loaded, or "".
func apply_inserts(track, inserts: Array) -> String:
	var problems := []
	for slot in audio.get_max_inserts():
		var insert = inserts[slot] if slot < inserts.size() else null
		if not (insert is Dictionary):
			app.clear_insert(track, slot)
			continue
		var problem: String = app.set_insert(track, slot, str(insert.get("plugin_id", "")), _bytes(insert.get("state", "")))
		if problem != "":
			app.clear_insert(track, slot)
			problems.append("%s on insert %s: %s" % [insert.get("plugin_name", "a plug-in"), char(65 + slot), problem])
		else:
			app.set_insert_on(track, slot, bool(insert.get("on", true)))
	return "; ".join(problems)


func copy_instrument(inst) -> void:
	copied_instrument = instrument_settings(inst)


## Whether what was copied can be pasted onto this instrument: one of the same family.
func can_paste_instrument(inst) -> bool:
	return copied_instrument.get("family", "") == family_of(inst)


func paste_instrument(inst) -> String:
	return apply_instrument_settings(inst, copied_instrument) if can_paste_instrument(inst) else "nothing of its kind was copied"


# ── A plug-in's settings ─────────────────────────────────────────────────────────────────────────────────────

## The plug-in on an insert (`place` "insert", `index` its slot) or a Plug-in pedal ("pedal", its place on the
## board): {id, name, maker}, or {} if there is none.
func plugin_at(inst, place: String, index: int) -> Dictionary:
	if place == "instrument":
		var played: Dictionary = audio.get_instrument_plugin(inst.source_id)
		return {} if played.plugin_id == "" else {"id": played.plugin_id, "name": played.plugin_name, "maker": played.plugin_maker}
	var list: Array = audio.get_inserts(inst.source_id) if place == "insert" else audio.get_pedals(inst.source_id)
	if index < 0 or index >= list.size() or str(list[index].get("plugin_id", "")) == "":
		return {}
	return {"id": list[index].plugin_id, "name": list[index].plugin_name, "maker": list[index].plugin_maker}


func copy_plugin(inst, place: String, index: int) -> void:
	var plugin := plugin_at(inst, place, index)
	if not plugin.is_empty():
		copied_plugin = {"plugin_id": plugin.id, "plugin_name": plugin.name, "state": audio.get_plugin_state(inst.source_id, place, index)}


## Whether what was copied can be pasted here: settings of the same plug-in.
func can_paste_plugin(inst, place: String, index: int) -> bool:
	return not copied_plugin.is_empty() and copied_plugin.plugin_id == plugin_at(inst, place, index).get("id", "")


func paste_plugin(inst, place: String, index: int) -> bool:
	return can_paste_plugin(inst, place, index) and audio.set_plugin_state(inst.source_id, place, index, copied_plugin.state)


## Where a plug-in's presets are kept, as Logic and other Audio Unit hosts keep them.
func plugin_presets_dir(plugin: Dictionary) -> String:
	return plugin_root.path_join(_safe(plugin.get("maker", "")) if plugin.get("maker", "") != "" else "Unknown").path_join(_safe(plugin.name))


## The presets saved for the plug-in at that place: [{name, path}], by name.
func plugin_presets(inst, place: String, index: int) -> Array:
	var plugin := plugin_at(inst, place, index)
	return [] if plugin.is_empty() else _files(plugin_presets_dir(plugin), "aupreset")


## Saves the plug-in's settings as a preset under `preset_name` (replacing one of that name). Returns why it couldn't, or "".
func save_plugin_preset(inst, place: String, index: int, preset_name: String) -> String:
	var plugin := plugin_at(inst, place, index)
	if plugin.is_empty():
		return "there is no plug-in there"
	var path := plugin_presets_dir(plugin).path_join(_safe(preset_name) + ".aupreset")
	if not audio.write_plugin_preset(path, preset_name, audio.get_plugin_state(inst.source_id, place, index)):
		return audio.get_error()
	return ""


## Loads a preset file into the plug-in at that place, while it plays. Returns why it couldn't, or "".
func load_plugin_preset(inst, place: String, index: int, path: String) -> String:
	var preset: Dictionary = audio.read_plugin_preset(path)
	if preset.is_empty():
		return audio.get_error()
	if preset.plugin_id != plugin_at(inst, place, index).get("id", ""):
		return "it is a preset for another plug-in"
	return "" if audio.set_plugin_state(inst.source_id, place, index, preset.state) else "the plug-in wouldn't take it"


# ── Instrument presets ───────────────────────────────────────────────────────────────────────────────────────

## The instrument presets saved, for one family or ("") every one: [{name, path, family}], by name.
func instrument_presets(family := "") -> Array:
	var out := []
	for each in FAMILIES:
		if family == "" or family == each:
			for file in _files(presets_dir(each), PRESET_EXT):
				file.family = each
				out.append(file)
	return out


func save_instrument_preset(inst, preset_name: String) -> String:
	var data := instrument_settings(inst)
	data.merge({"soundroom": "instrument preset", "version": VERSION, "name": preset_name})
	return write_file(presets_dir(family_of(inst)).path_join(_safe(preset_name) + "." + PRESET_EXT), data)


## An instrument preset file's settings, or {} if it can't be read.
func read_instrument_preset(path: String) -> Dictionary:
	var data := read_file(path)
	return data if data.get("soundroom", "") == "instrument preset" and FAMILIES.has(data.get("family", "")) else {}


func load_instrument_preset(inst, path: String) -> String:
	var data := read_instrument_preset(path)
	if data.is_empty():
		return "it couldn't be read"
	if data.family != family_of(inst):
		return "it is a preset for %s" % FAMILIES[data.family].to_lower()
	return apply_instrument_settings(inst, data)


# ── Rooms and templates ──────────────────────────────────────────────────────────────────────────────────────

## The templates there are, the two built-in ones first: [{name, path}].
func templates() -> Array:
	var saved := _files(templates_dir(), TEMPLATE_EXT) + _files(templates_dir(), ROOM_EXT)  # (early templates were .sroom)
	saved.sort_custom(func(a, b): return a.name.naturalnocasecmp_to(b.name) < 0)
	return [{"name": "Default room", "path": DEFAULT_TEMPLATE}, {"name": "Empty room", "path": EMPTY_TEMPLATE}] + saved


func template_exists(template_name: String) -> bool:
	return FileAccess.file_exists(templates_dir().path_join(_safe(template_name) + "." + TEMPLATE_EXT))


## The room as it is now: its size and walls, every instrument where it stands with its fader, mute, solo, pattern
## (MIDI notes, length, loop on or off), inserts, an amp's head, cabinet, knobs and pedals and a Speaker's volume and
## input, plug-ins with their settings, the tempo and swing, and where you stand. What a room's file and a template
## hold alike.
func room_data() -> Dictionary:
	var instruments := []
	for inst in app.instruments:
		var entry := {"kind": inst.kind, "position": [inst.global_position.x, inst.global_position.z], "yaw": inst.rotation.y,
			"level_db": inst.level_db, "muted": inst.muted, "soloed": inst.soloed, "input_channel": inst.input_channel,
			"settings": instrument_settings(inst), "clips": inst.clips.duplicate(true), "color": _color_data(inst.color),
			"automation": inst.automation.duplicate(true), "auto_mode": inst.auto_mode, "lanes": inst.lanes.duplicate(),
			"sends": inst.sends.map(func(send): return null if send.is_empty() else {"aux": app.auxes.find(send.aux), "level_db": send.level_db,
				"pre": send.pre, "on": send.on})}
		if inst.named:
			entry.name = inst.display_name
		if inst.playable:
			entry.loop_on = inst.loop_on
			entry.steps = audio.get_pattern_steps(inst.source_id)
			entry.pattern = audio.get_pattern(inst.source_id)
		instruments.append(entry)
	var walls := []
	for wall in app.room.walls:
		walls.append([wall.a.x, wall.a.y, wall.b.x, wall.b.y, wall.height])
	var size: Vector3 = app.room.size
	var stood: Vector3 = app.player.global_position
	var folders := []
	for folder in app.folders:
		folders.append({"name": folder.display_name, "color": _color_data(folder.color), "level_db": folder.level_db, "muted": folder.muted,
			"soloed": folder.soloed, "open": folder.open, "members": folder.members.map(func(inst): return app.instruments.find(inst)),
			"inserts": inserts_data(folder), "automation": folder.automation.duplicate(true), "auto_mode": folder.auto_mode, "lanes": folder.lanes.duplicate()})
	var auxes := []
	for aux in app.auxes:
		auxes.append({"name": aux.display_name, "color": _color_data(aux.color), "level_db": aux.level_db, "muted": aux.muted, "soloed": aux.soloed,
			"inserts": inserts_data(aux), "automation": aux.automation.duplicate(true), "auto_mode": aux.auto_mode, "lanes": aux.lanes.duplicate()})
	var master = app.master_track
	return {"soundroom": "room", "version": VERSION, "mode": app.timeline.mode, "timeline": app.timeline.to_data(),
		"tempo": app.tempo, "swing": app.swing, "master_db": app.master_volume_db, "reverb_db": app.reverb_db,
		"room": {"size": [size.x, size.y, size.z], "walls": walls},
		"player": {"position": [stood.x, stood.z], "yaw": app.player.yaw}, "instruments": instruments, "folders": folders, "auxes": auxes,
		"master_automation": {"automation": master.automation.duplicate(true), "auto_mode": master.auto_mode, "lanes": master.lanes.duplicate()}}


static func _color_data(color: Color) -> Array:
	return [snappedf(color.r, 0.001), snappedf(color.g, 0.001), snappedf(color.b, 0.001)]


static func _color_from(data, otherwise: Color) -> Color:
	return Color(float(data[0]), float(data[1]), float(data[2])) if data is Array and data.size() >= 3 else otherwise


## The room SoundRoom starts with, as data: its size and its one wall, the instruments playing the default groove, all
## turned to face where you come in. `empty`: the same room bare, with no instruments and no wall.
func default_room_data(empty := false) -> Dictionary:
	var instruments := []
	var spawn: Vector3 = app.SPAWN
	if not empty:
		for entry in app.DEFAULT_ROOM:
			var at: Vector3 = entry.position
			instruments.append({"kind": entry.kind, "position": [at.x, at.z], "yaw": atan2(spawn.x - at.x, spawn.z - at.z),
				"default_pattern": true, "input_channel": app.settings.speaker_input if entry.kind == "live" else -1})
	var walls := []
	if not empty:
		for wall in app.Room.default_walls():
			walls.append([wall.a.x, wall.a.y, wall.b.x, wall.b.y, wall.height])
	var size: Vector3 = app.Room.DEFAULT_SIZE
	# The empty room starts at a plain 90 BPM, and in a Record room stopped, with nothing looping: there is nothing to
	# hear yet. The default room plays its groove round its four bars.
	return {"soundroom": "template", "version": VERSION, "tempo": 90.0 if empty else app.DEFAULT_TEMPO, "swing": app.DEFAULT_SWING,
		"room": {"size": [size.x, size.y, size.z], "walls": walls}, "player": {"position": [spawn.x, spawn.z], "yaw": 0.0},
		"instruments": instruments, "timeline": {"playing": not empty, "loop_on": not empty}}


## What a template holds (one of the built-in ones, or a file), or {} if it can't be read.
func template_data(path: String) -> Dictionary:
	if path == DEFAULT_TEMPLATE or path == EMPTY_TEMPLATE:
		return default_room_data(path == EMPTY_TEMPLATE)
	return read_room_file(path)


## A room's file, or a template's: what it holds, or {} if it isn't one.
func read_room_file(path: String) -> Dictionary:
	var data := read_file(path)
	return data if data.get("soundroom", "") in ["room", "template"] else {}


## The size a room or template is, or the default room's.
static func size_of(data: Dictionary) -> Vector3:
	var size: Array = data.get("room", {}).get("size", [])
	return Vector3(float(size[0]), float(size[1]), float(size[2])) if size.size() == 3 else Vector3(14.0, 4.0, 10.0)


func save_template(template_name: String) -> String:
	var data := room_data()
	data.soundroom = "template"
	data.erase("mode")  # chosen when a room is made from it
	data.erase("timeline")
	for entry in data.instruments:
		entry.erase("clips")  # recordings belong to their room (and its folder)
	data.name = template_name
	return write_file(templates_dir().path_join(_safe(template_name) + "." + TEMPLATE_EXT), data)


## What can be carried over from a template into a new room, each true unless said otherwise.
const CARRY := ["walls", "instruments", "patterns", "mix", "instrument_settings", "plugins", "tempo"]


## Replaces the room with what a room's file or a template holds. `carry` leaves out what it sets false (see CARRY):
## the walls; the instruments altogether; their patterns; their faders, mute and solo; their own settings (an amp's
## head, cabinet, knobs and pedals, a Speaker's volume); the plug-ins on their inserts and pedals; the tempo and swing.
## `size`, if given, is the room's size instead of the one in `data`. Returns what couldn't be done, or "".
func apply_room_data(data: Dictionary, carry := {}, size = null, mode := "") -> String:
	var keep := func(what: String) -> bool: return bool(carry.get(what, true))
	app.clear_room()
	var room = app.room
	var room_part: Dictionary = data.get("room", {})
	room.reset()
	while not room.walls.is_empty():
		room.remove_wall(0)
	room.set_size(size if size is Vector3 else size_of(data))
	if keep.call("walls"):
		for wall in room_part.get("walls", []):
			if wall is Array and wall.size() >= 5:
				room.add_wall(Vector2(float(wall[0]), float(wall[1])), Vector2(float(wall[2]), float(wall[3])), float(wall[4]))
	var with_tempo: bool = keep.call("tempo")
	app.set_tempo(float(data.get("tempo", app.DEFAULT_TEMPO)) if with_tempo else app.DEFAULT_TEMPO)
	app.set_swing(float(data.get("swing", app.DEFAULT_SWING)) if with_tempo else app.DEFAULT_SWING)
	app.set_master_volume_db(float(data.get("master_db", 0.0)) if keep.call("mix") else 0.0)  # unity unless it says otherwise
	app.set_reverb_db(float(data.get("reverb_db", 0.0)) if keep.call("mix") else 0.0)
	var problems := []
	var include := {"instrument_settings": keep.call("instrument_settings"), "plugins": keep.call("plugins")}
	var made := []  # each instrument entry's instrument (null where it couldn't be made), for the folders
	for entry in data.get("instruments", []) if keep.call("instruments") else []:
		var kind := str(entry.get("kind", ""))
		var at: Array = entry.get("position", [0.0, 0.0])
		var inst = app.add_instrument(kind, Vector3(float(at[0]), 0.0, float(at[1]))) if app.Catalog.KINDS.has(kind) else null
		made.append(inst)
		if inst == null:
			problems.append("a %s (%s)" % [kind, "the room is full" if app.Catalog.KINDS.has(kind) else "not a kind SoundRoom knows"])
			continue
		inst.rotation.y = float(entry.get("yaw", 0.0))
		inst.set_color(_color_from(entry.get("color"), inst.color))
		if entry.has("name"):
			app.rename_track(inst, str(entry.name))
		if not inst.playable:
			inst.set_input_channel(int(entry.get("input_channel", -1)))
		if keep.call("mix"):
			app.set_instrument_level(inst, float(entry.get("level_db", 0.0)))
			inst.muted = bool(entry.get("muted", false))
			inst.soloed = bool(entry.get("soloed", false))
		if inst.playable and keep.call("patterns"):
			if entry.get("default_pattern", false):
				audio.load_default_pattern(inst.source_id)
			else:
				audio.set_pattern_steps(inst.source_id, int(entry.get("steps", 16)))
				audio.set_pattern(inst.source_id, entry.get("pattern", []))
			inst.set_loop(bool(entry.get("loop_on", true)))
		var problem := apply_instrument_settings(inst, entry.get("settings", {}), include)
		if problem != "":
			problems.append(problem)
		inst.clips = entry.get("clips", []).duplicate(true) if keep.call("patterns") else []
		if keep.call("mix"):  # its automation, as the mix's
			inst.automation = entry.get("automation", {}).duplicate(true)
			inst.auto_mode = str(entry.get("auto_mode", "read"))
			inst.lanes = entry.get("lanes", ["volume"]).duplicate()
	for entry in data.get("folders", []) if keep.call("instruments") else []:  # the routing folders, their tracks in them
		var members := []
		for index in entry.get("members", []):
			if int(index) >= 0 and int(index) < made.size() and made[int(index)] != null:
				members.append(made[int(index)])
		var folder = app.add_folder(members, str(entry.get("name", "")))
		if folder == null:
			problems.append("a folder (the room is full)")
			continue
		folder.color = _color_from(entry.get("color"), folder.color)
		folder.open = bool(entry.get("open", true))
		if keep.call("mix"):
			app.set_folder_level(folder, float(entry.get("level_db", 0.0)))
			folder.muted = bool(entry.get("muted", false))
			folder.soloed = bool(entry.get("soloed", false))
		var problem := apply_inserts(folder, entry.get("inserts", []) if keep.call("plugins") else [])
		if problem != "":
			problems.append("%s: %s" % [folder.display_name, problem])
		if keep.call("mix"):  # (after its plug-ins: one that isn't installed here keeps its automation, for where it is)
			folder.automation = entry.get("automation", {}).duplicate(true)
			folder.auto_mode = str(entry.get("auto_mode", "read"))
			folder.lanes = entry.get("lanes", ["volume"]).duplicate()
	var auxes := []  # the aux tracks, and then the tracks' sends to them
	for entry in data.get("auxes", []) if keep.call("instruments") else []:
		var aux = app.add_aux(str(entry.get("name", "")))
		auxes.append(aux)
		if aux == null:
			problems.append("an aux track (the room is full)")
			continue
		aux.color = _color_from(entry.get("color"), aux.color)
		if keep.call("mix"):
			app.set_folder_level(aux, float(entry.get("level_db", 0.0)))
			aux.muted = bool(entry.get("muted", false))
			aux.soloed = bool(entry.get("soloed", false))
		var problem := apply_inserts(aux, entry.get("inserts", []) if keep.call("plugins") else [])
		if problem != "":
			problems.append("%s: %s" % [aux.display_name, problem])
		if keep.call("mix"):
			aux.automation = entry.get("automation", {}).duplicate(true)
			aux.auto_mode = str(entry.get("auto_mode", "read"))
			aux.lanes = entry.get("lanes", ["volume"]).duplicate()
	var entries: Array = data.get("instruments", []) if keep.call("instruments") else []
	for i in mini(entries.size(), made.size()):
		var sends: Array = entries[i].get("sends", []) if made[i] != null and keep.call("mix") else []
		for slot in mini(sends.size(), audio.get_max_sends()):
			var send = sends[slot]
			if send is Dictionary and int(send.get("aux", -1)) >= 0 and int(send.aux) < auxes.size() and auxes[int(send.aux)] != null:
				app.set_send(made[i], slot, auxes[int(send.aux)], float(send.get("level_db", 0.0)), bool(send.get("pre", false)), bool(send.get("on", true)))
	var master_part: Dictionary = data.get("master_automation", {}) if keep.call("mix") else {}
	app.master_track.automation = master_part.get("automation", {}).duplicate(true)
	app.master_track.auto_mode = str(master_part.get("auto_mode", "read"))
	app.master_track.lanes = master_part.get("lanes", ["volume"]).duplicate()
	app.settle_new_room()
	var player: Dictionary = data.get("player", {})
	var stood: Array = player.get("position", [])
	if stood.size() == 2:
		app.player.place(Vector3(float(stood[0]), 0.0, float(stood[1])), float(player.get("yaw", 0.0)))
	app.settle_new_room()  # where you stand too, should the room be smaller than the one you stood in
	app.timeline.load_from(data, mode)  # a Jam room's patterns, or a Record room's timeline, going
	return "; ".join(problems)


## Removes a saved template or instrument preset (to the Trash).
func delete_file(path: String) -> void:
	if automated:
		DirAccess.remove_absolute(path)
	else:
		OS.move_to_trash(path)


## Opens a folder in the Finder, making it first if need be.
func show_folder(path: String) -> void:
	DirAccess.make_dir_recursive_absolute(path)
	if not automated:
		OS.shell_open(path)


# ── Files ────────────────────────────────────────────────────────────────────────────────────────────────────

## The files with this extension in a folder: [{name (the file's name without it), path}], by name.
func _files(dir: String, extension: String) -> Array:
	var out := []
	if not DirAccess.dir_exists_absolute(dir):
		return out
	for file in DirAccess.get_files_at(dir):
		if file.get_extension().to_lower() == extension:
			out.append({"name": file.get_basename(), "path": dir.path_join(file)})
	out.sort_custom(func(a, b): return a.name.naturalnocasecmp_to(b.name) < 0)
	return out


## Writes data as a JSON file, by way of a file beside it that then takes its place, so that a room's file is never
## left half written. Returns why it couldn't, or "".
func write_file(path: String, data: Dictionary) -> String:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var partial := path + ".saving"
	var file := FileAccess.open(partial, FileAccess.WRITE)
	if file == null:
		return "it couldn't be written (%s)" % error_string(FileAccess.get_open_error())
	file.store_string(JSON.stringify(data, "\t"))
	file.close()
	var moved := DirAccess.rename_absolute(partial, path)
	return "" if moved == OK else "it couldn't be written (%s)" % error_string(moved)


func read_file(path: String) -> Dictionary:
	var text := FileAccess.get_file_as_string(path)
	var data = JSON.parse_string(text) if text != "" else null
	return data if data is Dictionary else {}


static func _bytes(base64) -> PackedByteArray:
	return Marshalls.base64_to_raw(base64) if base64 is String and base64 != "" else PackedByteArray()


## A name made safe to be a file's: no slashes or other characters a file name can't hold.
static func _safe(text: String) -> String:
	var out := text.strip_edges()
	for bad in ["/", "\\", ":", "*", "?", "\"", "<", ">", "|"]:
		out = out.replace(bad, "-")
	out = out.lstrip(".")
	return out.left(80) if out != "" else "Untitled"


static func _remove_tree(dir: String) -> void:
	if not DirAccess.dir_exists_absolute(dir):
		return
	for sub in DirAccess.get_directories_at(dir):
		_remove_tree(dir.path_join(sub))
	for file in DirAccess.get_files_at(dir):
		DirAccess.remove_absolute(dir.path_join(file))
	DirAccess.remove_absolute(dir)
