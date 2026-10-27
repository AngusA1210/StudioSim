extends RefCounted
## What StudioSim keeps on disk, and copying and pasting settings.
##
## - Rooms and templates: what a room holds (room_data: its size and walls, every instrument where it stands with its
##   fader, mute, solo, pattern, pedals and plug-ins with their settings, the tempo and swing, and where you stand),
##   and putting it back (apply_room_data). session.gd keeps rooms, each a .sroom file in a folder of its own, in
##   StudioSim/Rooms; templates are .srtemplate files in StudioSim/Templates, two built in (the default room, an empty
##   one), and a new room starts from one, carrying over as much of it as is chosen. (StudioSim/ is the folder the
##   game runs from: see home().)
## - Instrument presets: an instrument's sound, without where it stands or what it plays: the plug-ins on its inserts,
##   an amp's head, cabinet, knobs and pedals, a Speaker's volume, a plug-in instrument's plug-in. A .srpreset file in
##   StudioSim/Instrument Presets, in a folder for each family (amps, Speakers, MIDI instruments, plug-in instruments). One loads onto any instrument of its
##   family, or comes into the room as a new instrument from the instrument menu.
## - Plug-in presets: a plug-in's settings as an .aupreset file (an Audio Unit's) or a .vstpreset (a VST3's) in
##   Maker/Plug-in, under ~/Library/Audio/Presets on macOS (where every host keeps them, so presets saved in Logic show
##   up here and the other way round) or Documents/VST3 Presets on Windows. The presets a plug-in comes with are listed
##   alongside.
## - Copy and paste: an instrument's settings (onto another of its family) or a plug-in's (onto the same plug-in),
##   held until something else is copied.
##
## Files are JSON, plug-in settings in them base64. Automated runs keep everything in a folder of their own, emptied
## at start, and never touch the real ones.

const EARLIER_NAMES := ["Studiolator", "SoundRoom"]  # what StudioSim was called before, the latest first
const ROOM_EXT := "sroom"
const TEMPLATE_EXT := "srtemplate"
const PRESET_EXT := "srpreset"
const VERSION := 1
const DEFAULT_TEMPLATE := "builtin:default"
const EMPTY_TEMPLATE := "builtin:empty"
const FAMILIES := {"amp": "Amps", "speaker": "Speakers", "midi": "MIDI instruments", "plugin": "Plug-in instruments", "mic": "Microphones"}

var app
var audio: StudioSimAudio
var automated := false
var root := ""         # StudioSim (see home())
var plugin_root := ""  # ~/Library/Audio/Presets, or Documents/VST3 Presets
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
		if OS.get_name() == "macOS":
			plugin_root = OS.get_environment("HOME").path_join("Library/Audio/Presets")
		else:
			plugin_root = OS.get_system_dir(OS.SYSTEM_DIR_DOCUMENTS).path_join("VST3 Presets")


## Where rooms, templates and instrument presets are kept: the StudioSim folder the game runs from (the one holding
## game/), or for a build made to be handed out, which has no such folder, Music/StudioSim (the folder from before
## StudioSim had its name, Music/Studiolator or Music/SoundRoom, is moved there).
static func home() -> String:
	if OS.has_feature("template"):
		var music := OS.get_system_dir(OS.SYSTEM_DIR_MUSIC)
		if not DirAccess.dir_exists_absolute(music.path_join("StudioSim")):
			for before in EARLIER_NAMES:
				if DirAccess.dir_exists_absolute(music.path_join(before)):
					if DirAccess.rename_absolute(music.path_join(before), music.path_join("StudioSim")) != OK:
						return music.path_join(before)
					break
		return music.path_join("StudioSim")
	return ProjectSettings.globalize_path("res://").get_base_dir().get_base_dir()


func templates_dir() -> String:
	return root.path_join("Templates")


func presets_dir(family := "") -> String:
	var dir := root.path_join("Instrument Presets")
	return dir if family == "" else dir.path_join(FAMILIES[family])


static func family_of(inst) -> String:
	if inst.plays_plugin:
		return "plugin"
	if inst.is_mic:
		return "mic"
	return "amp" if inst.is_amp else ("midi" if inst.playable else "speaker")


# ── An instrument's settings ─────────────────────────────────────────────────────────────────────────────────

## An instrument's sound, without where it stands or what it plays: its inserts (plug-ins and their settings), an amp's
## head, cabinet, knobs and pedals, a Speaker's volume, and a microphone's gain. Not `with_states`, the plug-ins' own
## settings (each read from the plug-in) are left out: what is shared a few times a second when playing together.
func instrument_settings(inst, with_states := true) -> Dictionary:
	var out := {"kind": inst.kind, "family": family_of(inst), "inserts": inserts_data(inst, with_states)}
	if family_of(inst) == "speaker":
		out.volume_db = inst.volume_db
	if inst.is_mic:  # its model and pattern, its gain (and polarity) and where its track sits in the stereo
		out.mic_gain_db = inst.mic_gain_db
		if inst.mic_inverted:
			out.mic_inverted = true
		out.mic_model = inst.mic_model
		out.mic_pattern = inst.mic_pattern
		out.pan = inst.pan
	var played: Dictionary = audio.get_instrument_plugin(inst.source_id) if inst.plays_plugin else {}
	if str(played.get("plugin_id", "")) != "":  # a plug-in instrument's plug-in, which is the instrument itself
		out.instrument_plugin = {"plugin_id": played.plugin_id, "plugin_name": played.plugin_name, "plugin_maker": played.plugin_maker}
		if with_states:
			out.instrument_plugin.state = Marshalls.raw_to_base64(audio.get_plugin_state(inst.source_id, "instrument", 0))
	if inst.is_amp:
		var pedals := []
		var board: Array = audio.get_pedals(inst.source_id)
		for i in board.size():
			var p: Dictionary = board[i]
			var pedal := {"kind": p.kind, "on": p.on, "controls": Array(p.controls), "in_loop": p.get("in_loop", false)}
			if p.kind == "plugin" and p.plugin_id != "":
				pedal.merge({"plugin_id": p.plugin_id, "plugin_name": p.plugin_name, "plugin_maker": p.plugin_maker})
				if with_states:
					pedal.state = Marshalls.raw_to_base64(audio.get_plugin_state(inst.source_id, "pedal", i))
			pedals.append(pedal)
		out.amp = {"head": inst.amp_head, "head_on": inst.head_on, "cabinet": inst.amp_cabinet, "cabinet_on": inst.cabinet_on, "speaker": inst.amp_speaker,
			"controls": inst.amp_controls.duplicate(), "pedals": pedals, "loop_mix": inst.loop_mix}
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
		var played_id := str(played.get("plugin_id", ""))
		var played_state := _bytes(played.get("state", ""))
		var other: String = app.plugin_elsewhere(played_id, str(played.get("plugin_name", "")), str(played.get("plugin_maker", "")), true)
		if other != "":  # (the same plug-in in another format, without its settings)
			played_id = other
			played_state = PackedByteArray()
		var problem: String = app.set_instrument_plugin(inst, played_id, played_state)
		if problem != "":
			problems.append("%s: %s" % [played.get("plugin_name", "its plug-in"), problem])
	if inst.is_amp and settings.get("amp") is Dictionary and include.get("instrument_settings", true):
		var amp: Dictionary = settings.amp
		app.set_amp_voice(inst, str(amp.get("head", inst.amp_head)), bool(amp.get("head_on", true)),
			str(amp.get("cabinet", inst.amp_cabinet)), bool(amp.get("cabinet_on", true)), str(amp.get("speaker", "")))
		var controls: Dictionary = amp.get("controls", {})
		for control in controls:
			if inst.amp_controls.has(control):
				app.set_amp_control(inst, control, float(controls[control]))
		app.set_amp_loop_mix(inst, float(amp.get("loop_mix", 0.5)))
		app.hide_plugin_editors(inst)
		for i in range(audio.get_pedals(inst.source_id).size() - 1, -1, -1):
			app.remove_pedal(inst, i)
		for pedal in amp.get("pedals", []):  # (in order: those in front of the amp, then those in its effects loop)
			var at: int = app.add_pedal(inst, str(pedal.get("kind", "")), -1, bool(pedal.get("in_loop", false)))
			if at < 0:
				problems.append("a %s pedal" % str(pedal.get("kind", "")))
				continue
			var values: Array = pedal.get("controls", [])
			for c in values.size():
				app.set_pedal_control(inst, at, c, float(values[c]))
			app.set_pedal_on(inst, at, bool(pedal.get("on", true)))
			if str(pedal.get("plugin_id", "")) != "" and with_plugins:
				var pedal_id := str(pedal.plugin_id)
				var pedal_state := _bytes(pedal.get("state", ""))
				var other: String = app.plugin_elsewhere(pedal_id, str(pedal.get("plugin_name", "")), str(pedal.get("plugin_maker", "")))
				if other != "":  # (the same plug-in in another format, without its settings)
					pedal_id = other
					pedal_state = PackedByteArray()
				var problem: String = app.load_pedal_plugin(inst, at, pedal_id, pedal_state)
				if problem != "":
					problems.append("%s on pedal %d: %s" % [pedal.get("plugin_name", "a plug-in"), at + 1, problem])
	if family_of(inst) == "speaker" and settings.has("volume_db") and include.get("instrument_settings", true):
		app.set_speaker_volume(inst, float(settings.volume_db))
	if inst.is_mic and include.get("instrument_settings", true):
		if settings.has("mic_model"):
			if inst.is_stereo_mic:  # (its setup's patterns, its model as it was)
				inst.set_mic_model(str(settings.mic_model), str(settings.get("mic_pattern", "")))
			else:
				app.set_mic_model(inst, str(settings.mic_model), str(settings.get("mic_pattern", "")))
		if settings.has("mic_gain_db"):
			inst.set_mic_gain(float(settings.mic_gain_db))
		inst.set_mic_polarity(bool(settings.get("mic_inverted", false)))
		if settings.has("pan"):
			inst.set_pan(float(settings.pan))
	var problem := apply_inserts(inst, settings.get("inserts", []) if with_plugins else [])
	if problem != "":
		problems.append(problem)
	return "; ".join(problems)



## A stereo folder's (or aux track's) two pans, as kept; a room kept before it had them gave it a balance, which the
## nearest pair stands for (turned right: its left side moved over towards the right).
func _set_pans(folder, entry: Dictionary) -> void:
	if entry.has("pan_left"):
		app.set_folder_pans(folder, float(entry.get("pan_left", -1.0)), float(entry.get("pan_right", 1.0)))
	elif not bool(entry.get("mono", false)):
		var balance := float(entry.get("pan", 0.0))
		app.set_folder_pans(folder, -1.0 + 2.0 * maxf(balance, 0.0), 1.0 - 2.0 * maxf(-balance, 0.0))


## A track's inserts (an instrument's or a folder's), as saved: each slot's plug-in with its settings (unless not
## `with_states`: what each plug-in keeps of itself, read from it), or null.
func inserts_data(track, with_states := true) -> Array:
	var out := []
	var inserts: Array = audio.get_inserts(track.source_id)
	for slot in inserts.size():
		var insert: Dictionary = inserts[slot]
		if insert.plugin_id == "":
			out.append(null)
		else:
			var entry := {"plugin_id": insert.plugin_id, "plugin_name": insert.plugin_name, "plugin_maker": insert.plugin_maker, "on": insert.on}
			if with_states:
				entry.state = Marshalls.raw_to_base64(audio.get_plugin_state(track.source_id, "insert", slot))
			out.append(entry)
	return out


## Puts a track's inserts back as saved. Returns what couldn't be loaded, or "".
func apply_inserts(track, inserts: Array) -> String:
	var problems := []
	for slot in audio.get_max_inserts():
		var insert = inserts[slot] if slot < inserts.size() else null
		if not (insert is Dictionary):
			app.clear_insert(track, slot)
			continue
		var plugin_id := str(insert.get("plugin_id", ""))
		var state := _bytes(insert.get("state", ""))
		var other: String = app.plugin_elsewhere(plugin_id, str(insert.get("plugin_name", "")), str(insert.get("plugin_maker", "")))
		if other != "":  # (the same plug-in in another format: its settings don't go across)
			problems.append("%s on insert %s: its %s instead, as it was made" % [insert.get("plugin_name", "a plug-in"), char(65 + slot),
				"VST3" if other.begins_with("VST3:") else "Audio Unit"])
			plugin_id = other
			state = PackedByteArray()
		var problem: String = app.set_insert(track, slot, plugin_id, state)
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
	return [] if plugin.is_empty() else _files(plugin_presets_dir(plugin), audio.preset_extension(plugin.id))


## Saves the plug-in's settings as a preset under `preset_name` (replacing one of that name). Returns why it couldn't, or "".
func save_plugin_preset(inst, place: String, index: int, preset_name: String) -> String:
	var plugin := plugin_at(inst, place, index)
	if plugin.is_empty():
		return "there is no plug-in there"
	var path := plugin_presets_dir(plugin).path_join(_safe(preset_name) + "." + audio.preset_extension(plugin.id))
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
	data.merge({"studiosim": "instrument preset", "version": VERSION, "name": preset_name})
	return write_file(presets_dir(family_of(inst)).path_join(_safe(preset_name) + "." + PRESET_EXT), data)


## An instrument preset file's settings, or {} if it can't be read.
func read_instrument_preset(path: String) -> Dictionary:
	var data := read_file(path)
	return data if kind_of(data) == "instrument preset" and FAMILIES.has(data.get("family", "")) else {}


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
			"room_db": inst.room_db, "room_muted": inst.room_muted, "pan": inst.pan,
			"settings": instrument_settings(inst), "clips": inst.clips.duplicate(true), "color": _color_data(inst.color),
			"automation": inst.automation.duplicate(true), "auto_mode": inst.auto_mode, "lanes": inst.lanes.duplicate(),
			"sends": _sends_data(inst)}
		if inst.named:
			entry.name = inst.display_name
		if inst.locked:
			entry.locked = true
		if inst.is_mic:  # (where it stands: its capsule's height, and how far it points down; a stereo pair's other mic)
			entry.height = inst.source_height
			entry.tilt = inst.mic_tilt
			if inst.is_stereo_mic:
				entry.stereo = {"technique": inst.pair_technique, "spacing": inst.pair_spacing, "side_model": inst.side_model, "width": inst.ms_width}
		if inst.playable:
			entry.loop_on = inst.loop_on
			entry.steps = audio.get_pattern_steps(inst.source_id)
			entry.pattern = audio.get_pattern(inst.source_id)
		instruments.append(entry)
	var walls := []
	for wall in app.room.walls:
		walls.append([wall.a.x, wall.a.y, wall.b.x, wall.b.y, wall.height, wall.get("material", app.room.DEFAULT_WALL_MATERIAL)])
	var size: Vector3 = app.room.size
	var spot: Dictionary = app.player.standing_spot()  # (at a kit, where you stood before you sat down)
	var stood: Vector3 = spot.position
	var folders := []
	for folder in app.folders:  # (its tracks: an instrument's by its place in the list, a folder's or an aux's as {"folder"} or {"aux"})
		folders.append({"name": folder.display_name, "color": _color_data(folder.color), "level_db": folder.level_db, "muted": folder.muted,
			"soloed": folder.soloed, "open": folder.open, "members": folder.members.map(_track_ref), "pan": folder.pan, "mono": folder.mono,
			"pan_left": folder.pan_left, "pan_right": folder.pan_right,
			"inserts": inserts_data(folder), "automation": folder.automation.duplicate(true), "auto_mode": folder.auto_mode, "lanes": folder.lanes.duplicate(),
			"sends": _sends_data(folder)})
	var auxes := []
	for aux in app.auxes:
		auxes.append({"name": aux.display_name, "color": _color_data(aux.color), "level_db": aux.level_db, "muted": aux.muted, "soloed": aux.soloed,
			"pan": aux.pan, "mono": aux.mono, "pan_left": aux.pan_left, "pan_right": aux.pan_right,
			"inserts": inserts_data(aux), "automation": aux.automation.duplicate(true), "auto_mode": aux.auto_mode, "lanes": aux.lanes.duplicate(),
			"sends": _sends_data(aux)})
	var masters := {}
	for master in app.master_tracks():  # (each master's name, colour, inserts and automation)
		masters[master.which] = {"name": master.display_name, "color": _color_data(master.color), "inserts": inserts_data(master),
			"automation": master.automation.duplicate(true), "auto_mode": master.auto_mode, "lanes": master.lanes.duplicate()}
	return {"studiosim": "room", "version": VERSION, "mode": app.timeline.mode, "timeline": app.timeline.to_data(),
		"tempo": app.tempo, "swing": app.swing, "master_db": app.master_volume_db, "room_master_db": app.room_volume_db, "reverb_db": app.reverb_db,
		"room": {"size": [size.x, size.y, size.z], "walls": walls, "surfaces": app.room.surfaces.duplicate()},
		"player": {"position": [stood.x, stood.z], "yaw": spot.yaw}, "instruments": instruments, "folders": folders, "auxes": auxes,
		"masters": masters}


func _track_ref(track):
	if app.folders.has(track):
		return {"folder": app.folders.find(track)}
	if app.auxes.has(track):
		return {"aux": app.auxes.find(track)}
	return app.instruments.find(track)


func _sends_data(track) -> Array:
	return track.sends.map(func(send): return null if send.is_empty() else {"aux": app.auxes.find(send.aux), "level_db": send.level_db,
		"pre": send.pre, "on": send.on})


## A track's sends put back as saved, to the aux tracks made (null where one couldn't be).
func _apply_sends(track, sends: Array, auxes: Array) -> void:
	for slot in mini(sends.size(), audio.get_max_sends()):
		var send = sends[slot]
		if send is Dictionary and int(send.get("aux", -1)) >= 0 and int(send.aux) < auxes.size() and auxes[int(send.aux)] != null:
			app.set_send(track, slot, auxes[int(send.aux)], float(send.get("level_db", 0.0)), bool(send.get("pre", false)), bool(send.get("on", true)))


static func _color_data(color: Color) -> Array:
	return [snappedf(color.r, 0.001), snappedf(color.g, 0.001), snappedf(color.b, 0.001)]


static func _color_from(data, otherwise: Color) -> Color:
	return Color(float(data[0]), float(data[1]), float(data[2])) if data is Array and data.size() >= 3 else otherwise


## The room StudioSim starts with, as data: its size and its one wall, the instruments playing the default groove, all
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
	return {"studiosim": "template", "version": VERSION, "tempo": 90.0 if empty else app.DEFAULT_TEMPO, "swing": app.DEFAULT_SWING,
		"room": {"size": [size.x, size.y, size.z], "walls": walls}, "player": {"position": [spawn.x, spawn.z], "yaw": 0.0},
		"instruments": instruments, "timeline": {"playing": not empty, "loop_on": not empty}}


## What a template holds (one of the built-in ones, or a file), or {} if it can't be read.
func template_data(path: String) -> Dictionary:
	if path == DEFAULT_TEMPLATE or path == EMPTY_TEMPLATE:
		return default_room_data(path == EMPTY_TEMPLATE)
	return read_room_file(path)


## What one of StudioSim's files is ("room", "template", "instrument preset"): as it says, or as one saved while
## StudioSim had an earlier name (Studiolator, SoundRoom) says.
static func kind_of(data: Dictionary) -> String:
	return str(data.get("studiosim", data.get("studiolator", data.get("soundroom", ""))))


## A room's file, or a template's: what it holds, or {} if it isn't one.
func read_room_file(path: String) -> Dictionary:
	var data := read_file(path)
	return data if kind_of(data) in ["room", "template"] else {}


## The size a room or template is, or the default room's.
static func size_of(data: Dictionary) -> Vector3:
	var size: Array = data.get("room", {}).get("size", [])
	return Vector3(float(size[0]), float(size[1]), float(size[2])) if size.size() == 3 else Vector3(14.0, 4.0, 10.0)


func save_template(template_name: String) -> String:
	var data := room_data()
	data.studiosim = "template"
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
	var surfaces: Dictionary = room_part.get("surfaces", {})
	if not surfaces.has("floor") and room_part.has("floor"):  # (a room from before materials: its floor as it was)
		surfaces.floor = {"hard": "wood_floor", "rug": "rug", "carpet": "carpet"}.get(str(room_part.floor), "wood_floor")
	for surface in room.SURFACES:
		room.set_surface(surface, str(surfaces.get(surface, room.DEFAULT_SURFACES[surface])))
	if keep.call("walls"):
		for wall in room_part.get("walls", []):
			if wall is Array and wall.size() >= 5:
				room.add_wall(Vector2(float(wall[0]), float(wall[1])), Vector2(float(wall[2]), float(wall[3])), float(wall[4]),
					str(wall[5]) if wall.size() >= 6 else room.DEFAULT_WALL_MATERIAL)
	var with_tempo: bool = keep.call("tempo")
	app.set_tempo(float(data.get("tempo", app.DEFAULT_TEMPO)) if with_tempo else app.DEFAULT_TEMPO)
	app.set_swing(float(data.get("swing", app.DEFAULT_SWING)) if with_tempo else app.DEFAULT_SWING)
	app.set_master_volume_db(float(data.get("master_db", 0.0)) if keep.call("mix") else 0.0)  # unity unless it says otherwise
	# The room's master (a room from before there was one: the master it had, which was all there was to hear).
	app.set_room_volume_db(float(data.get("room_master_db", data.get("master_db", 0.0))) if keep.call("mix") else 0.0)
	app.set_reverb_db(float(data.get("reverb_db", 0.0)) if keep.call("mix") else 0.0)
	var problems := []
	var include := {"instrument_settings": keep.call("instrument_settings"), "plugins": keep.call("plugins")}
	var made := []  # each instrument entry's instrument (null where it couldn't be made), for the folders
	for entry in data.get("instruments", []) if keep.call("instruments") else []:
		var kind := str(entry.get("kind", ""))
		if kind == "mic_pair" and entry.has("pair"):  # (a stereo pair as two mono mics, as rooms kept them for a while: two mics)
			kind = "mic"
		var at: Array = entry.get("position", [0.0, 0.0])
		var inst = app.add_instrument(kind, Vector3(float(at[0]), 0.0, float(at[1]))) if app.Catalog.KINDS.has(kind) else null
		made.append(inst)
		if inst == null:
			problems.append("a %s (%s)" % [kind, "the room is full" if app.Catalog.KINDS.has(kind) else "not a kind StudioSim knows"])
			continue
		inst.rotation.y = float(entry.get("yaw", 0.0))
		inst.set_locked(bool(entry.get("locked", false)))
		inst.set_color(_color_from(entry.get("color"), inst.color))
		if entry.has("name"):
			app.rename_track(inst, str(entry.name))
		if inst.is_live():
			inst.set_input_channel(int(entry.get("input_channel", -1)))
		if inst.is_mic:
			app.set_mic_height(inst, float(entry.get("height", inst.source_height)))
			app.set_mic_tilt(inst, float(entry.get("tilt", 0.0)))
			var stereo = entry.get("stereo")
			if inst.is_stereo_mic:
				var setup: Dictionary = stereo if stereo is Dictionary else {}
				inst.set_pair(str(setup.get("technique", "xy")), float(setup.get("spacing", 0.0)), str(setup.get("side_model", "condenser")),
					float(setup.get("width", 1.0)))
		if keep.call("mix"):  # its fader, and its level in the room (a room from before: the fader's, as it was all one)
			app.set_instrument_level(inst, float(entry.get("level_db", 0.0)))
			app.set_room_level(inst, float(entry.get("room_db", entry.get("level_db", 0.0))))
			inst.set_room_muted(bool(entry.get("room_muted", false)))
			inst.set_pan(float(entry.get("pan", 0.0)))
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
		inst.clips = app.timeline.with_all_takes(entry.get("clips", []).duplicate(true)) if keep.call("patterns") else []
		if keep.call("mix"):  # its automation, as the mix's
			inst.automation = entry.get("automation", {}).duplicate(true)
			inst.auto_mode = str(entry.get("auto_mode", "read"))
			inst.lanes = entry.get("lanes", ["volume"]).duplicate()
	var made_folders := []  # the routing folders (their tracks put in them once the aux tracks are made too)
	for entry in data.get("folders", []) if keep.call("instruments") else []:
		var folder = app.add_folder([], str(entry.get("name", "")))
		made_folders.append(folder)
		if folder == null:
			problems.append("a folder (the room is full)")
			continue
		folder.color = _color_from(entry.get("color"), folder.color)
		folder.open = bool(entry.get("open", true))
		if keep.call("mix"):
			app.set_folder_level(folder, float(entry.get("level_db", 0.0)))
			app.set_pan(folder, float(entry.get("pan", 0.0)))
			_set_pans(folder, entry)
			app.set_folder_mono(folder, bool(entry.get("mono", false)))
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
			app.set_pan(aux, float(entry.get("pan", 0.0)))
			_set_pans(aux, entry)
			app.set_folder_mono(aux, bool(entry.get("mono", false)))
			aux.muted = bool(entry.get("muted", false))
			aux.soloed = bool(entry.get("soloed", false))
		var problem := apply_inserts(aux, entry.get("inserts", []) if keep.call("plugins") else [])
		if problem != "":
			problems.append("%s: %s" % [aux.display_name, problem])
		if keep.call("mix"):
			aux.automation = entry.get("automation", {}).duplicate(true)
			aux.auto_mode = str(entry.get("auto_mode", "read"))
			aux.lanes = entry.get("lanes", ["volume"]).duplicate()
	var folder_entries: Array = data.get("folders", []) if keep.call("instruments") else []
	for i in mini(folder_entries.size(), made_folders.size()):  # each folder's tracks, in their order
		if made_folders[i] == null:
			continue
		for ref in folder_entries[i].get("members", []):
			var track = null
			if ref is Dictionary and ref.has("folder"):
				track = made_folders[int(ref.folder)] if int(ref.folder) >= 0 and int(ref.folder) < made_folders.size() else null
			elif ref is Dictionary and ref.has("aux"):
				track = auxes[int(ref.aux)] if int(ref.aux) >= 0 and int(ref.aux) < auxes.size() else null
			elif not (ref is Dictionary) and int(ref) >= 0 and int(ref) < made.size():
				track = made[int(ref)]
			if track != null:
				app.put_in_folder(track, made_folders[i])
	if keep.call("mix"):  # and the sends, every track's
		var entries: Array = data.get("instruments", []) if keep.call("instruments") else []
		for i in mini(entries.size(), made.size()):
			if made[i] != null:
				_apply_sends(made[i], entries[i].get("sends", []), auxes)
		for i in mini(folder_entries.size(), made_folders.size()):
			if made_folders[i] != null:
				_apply_sends(made_folders[i], folder_entries[i].get("sends", []), auxes)
		var aux_entries: Array = data.get("auxes", []) if keep.call("instruments") else []
		for i in mini(aux_entries.size(), auxes.size()):
			if auxes[i] != null:
				_apply_sends(auxes[i], aux_entries[i].get("sends", []), auxes)
	for master in app.master_tracks():  # (a room from before the room's master had any: the mix's as it was kept then)
		var kept: Dictionary = data.get("masters", {}).get(master.which, {})
		if kept.is_empty() and master.which == "mix":
			kept = data.get("master_automation", {}).duplicate()
			kept["inserts"] = data.get("master_inserts", [])
		var master_problem := apply_inserts(master, kept.get("inserts", []) if keep.call("plugins") else [])
		if master_problem != "":
			problems.append("the %s: %s" % [master.display_name, master_problem])
		var mixed: Dictionary = kept if keep.call("mix") else {}
		master.automation = mixed.get("automation", {}).duplicate(true)
		master.auto_mode = str(mixed.get("auto_mode", "read"))
		master.lanes = mixed.get("lanes", ["volume"]).duplicate()
		master.display_name = str(kept.get("name", master.display_name))
		if kept.has("color"):
			master.color = _color_from(kept.color, master.CRIMSON)
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
