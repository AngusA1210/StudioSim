extends RefCounted
## What SoundRoom keeps on disk, and copying and pasting settings.
##
## - Templates: a whole room (its size and walls, every instrument where it stands with its fader, mute, solo, pattern,
##   pedals and plug-ins with their settings, the tempo and swing, and where you stand), as a .sroom file in
##   Music/SoundRoom/Templates. Loading one replaces the room. Two are built in: the default room, and an empty one.
## - Instrument presets: an instrument's sound, without where it stands or what it plays: the plug-ins on its inserts,
##   an amp's head, cabinet, knobs and pedals, a Speaker's volume. A .srpreset file in Music/SoundRoom/Instrument
##   Presets, in a folder for each family (amps, Speakers, MIDI instruments). One loads onto any instrument of its
##   family, or comes into the room as a new instrument from the instrument menu.
## - Plug-in presets: a plug-in's settings as an .aupreset file in ~/Library/Audio/Presets/Maker/Plug-in, where every
##   Audio Unit host keeps them, so presets saved in Logic show up here and the other way round. The presets a plug-in
##   comes with are listed alongside.
## - Copy and paste: an instrument's settings (onto another of its family) or a plug-in's (onto the same plug-in),
##   held until something else is copied.
##
## Files are JSON, plug-in settings in them base64. Automated runs keep everything in a folder of their own, emptied
## at start, and never touch the real ones.

const TEMPLATE_EXT := "sroom"
const PRESET_EXT := "srpreset"
const VERSION := 1
const DEFAULT_TEMPLATE := "builtin:default"
const EMPTY_TEMPLATE := "builtin:empty"
const FAMILIES := {"amp": "Amps", "speaker": "Speakers", "midi": "MIDI instruments"}
const UNREADABLE := "it couldn't be read"

var app
var audio: SoundRoomAudio
var automated := false
var root := ""         # Music/SoundRoom
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
		root = OS.get_system_dir(OS.SYSTEM_DIR_MUSIC).path_join("SoundRoom")
		plugin_root = OS.get_environment("HOME").path_join("Library/Audio/Presets")


func templates_dir() -> String:
	return root.path_join("Templates")


func presets_dir(family := "") -> String:
	var dir := root.path_join("Instrument Presets")
	return dir if family == "" else dir.path_join(FAMILIES[family])


static func family_of(inst) -> String:
	return "amp" if inst.is_amp else ("midi" if inst.playable else "speaker")


# ── An instrument's settings ─────────────────────────────────────────────────────────────────────────────────

## An instrument's sound, without where it stands or what it plays: its inserts (plug-ins and their settings), an amp's
## head, cabinet, knobs and pedals, and a Speaker's volume.
func instrument_settings(inst) -> Dictionary:
	var out := {"kind": inst.kind, "family": family_of(inst), "inserts": []}
	var inserts: Array = audio.get_inserts(inst.source_id)
	for slot in inserts.size():
		var insert: Dictionary = inserts[slot]
		if insert.plugin_id == "":
			out.inserts.append(null)
		else:
			out.inserts.append({"plugin_id": insert.plugin_id, "plugin_name": insert.plugin_name, "plugin_maker": insert.plugin_maker,
				"on": insert.on, "state": Marshalls.raw_to_base64(audio.get_plugin_state(inst.source_id, "insert", slot))})
	if family_of(inst) == "speaker":
		out.volume_db = inst.volume_db
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
## A plug-in that isn't installed leaves its insert empty. Returns what couldn't be done, or "".
func apply_instrument_settings(inst, settings: Dictionary) -> String:
	var problems := []
	if inst.is_amp and settings.get("amp") is Dictionary:
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
			if str(pedal.get("plugin_id", "")) != "":
				var problem: String = app.load_pedal_plugin(inst, at, pedal.plugin_id, _bytes(pedal.get("state", "")))
				if problem != "":
					problems.append("%s on pedal %d: %s" % [pedal.get("plugin_name", "a plug-in"), at + 1, problem])
	if family_of(inst) == "speaker" and settings.has("volume_db"):
		app.set_speaker_volume(inst, float(settings.volume_db))
	var inserts: Array = settings.get("inserts", [])
	for slot in audio.get_max_inserts():
		var insert = inserts[slot] if slot < inserts.size() else null
		if not (insert is Dictionary):
			app.clear_insert(inst, slot)
			continue
		var problem: String = app.set_insert(inst, slot, str(insert.get("plugin_id", "")), _bytes(insert.get("state", "")))
		if problem != "":
			app.clear_insert(inst, slot)
			problems.append("%s on insert %s: %s" % [insert.get("plugin_name", "a plug-in"), char(65 + slot), problem])
		else:
			app.set_insert_on(inst, slot, bool(insert.get("on", true)))
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
	return _write(presets_dir(family_of(inst)).path_join(_safe(preset_name) + "." + PRESET_EXT), data)


## An instrument preset file's settings, or {} if it can't be read.
func read_instrument_preset(path: String) -> Dictionary:
	var data := _read(path)
	return data if data.get("soundroom", "") == "instrument preset" and FAMILIES.has(data.get("family", "")) else {}


func load_instrument_preset(inst, path: String) -> String:
	var data := read_instrument_preset(path)
	if data.is_empty():
		return UNREADABLE
	if data.family != family_of(inst):
		return "it is a preset for %s" % FAMILIES[data.family].to_lower()
	return apply_instrument_settings(inst, data)


# ── Templates ────────────────────────────────────────────────────────────────────────────────────────────────

## The templates there are, the two built-in ones first: [{name, path}].
func templates() -> Array:
	return [{"name": "Default room", "path": DEFAULT_TEMPLATE}, {"name": "Empty room", "path": EMPTY_TEMPLATE}] + \
		_files(templates_dir(), TEMPLATE_EXT)


func template_exists(template_name: String) -> bool:
	return FileAccess.file_exists(templates_dir().path_join(_safe(template_name) + "." + TEMPLATE_EXT))


## The room as it is now, as a template holds it.
func room_template() -> Dictionary:
	var instruments := []
	for inst in app.instruments:
		var entry := {"kind": inst.kind, "position": [inst.global_position.x, inst.global_position.z], "yaw": inst.rotation.y,
			"level_db": inst.level_db, "muted": inst.muted, "soloed": inst.soloed, "input_channel": inst.input_channel,
			"settings": instrument_settings(inst)}
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
	return {"soundroom": "template", "version": VERSION, "tempo": app.tempo, "swing": app.swing,
		"room": {"size": [size.x, size.y, size.z], "walls": walls},
		"player": {"position": [stood.x, stood.z], "yaw": app.player.yaw}, "instruments": instruments}


func save_template(template_name: String) -> String:
	var data := room_template()
	data.name = template_name
	return _write(templates_dir().path_join(_safe(template_name) + "." + TEMPLATE_EXT), data)


## Replaces the room with a template's (a file, or one of the built-in ones). Returns what couldn't be done, or "".
func load_template(path: String) -> String:
	if path == DEFAULT_TEMPLATE or path == EMPTY_TEMPLATE:
		app.load_default_room(path == EMPTY_TEMPLATE)
		return ""
	var data := _read(path)
	if data.get("soundroom", "") != "template":
		return UNREADABLE
	app.clear_room()
	var room = app.room
	var room_data: Dictionary = data.get("room", {})
	var size: Array = room_data.get("size", [])
	room.reset()
	while not room.walls.is_empty():
		room.remove_wall(0)
	if size.size() == 3:
		room.set_size(Vector3(float(size[0]), float(size[1]), float(size[2])))
	for wall in room_data.get("walls", []):
		if wall is Array and wall.size() >= 5:
			room.add_wall(Vector2(float(wall[0]), float(wall[1])), Vector2(float(wall[2]), float(wall[3])), float(wall[4]))
	app.set_tempo(float(data.get("tempo", app.DEFAULT_TEMPO)))
	app.set_swing(float(data.get("swing", app.DEFAULT_SWING)))
	var problems := []
	for entry in data.get("instruments", []):
		var kind := str(entry.get("kind", ""))
		var at: Array = entry.get("position", [0.0, 0.0])
		var inst = app.add_instrument(kind, Vector3(float(at[0]), 0.0, float(at[1]))) if app.Catalog.KINDS.has(kind) else null
		if inst == null:
			problems.append("a %s (%s)" % [kind, "the room is full" if app.Catalog.KINDS.has(kind) else "not a kind SoundRoom knows"])
			continue
		inst.rotation.y = float(entry.get("yaw", 0.0))
		app.set_instrument_level(inst, float(entry.get("level_db", 0.0)))
		if not inst.playable:
			inst.set_input_channel(int(entry.get("input_channel", -1)))
		if inst.playable:
			audio.set_pattern_steps(inst.source_id, int(entry.get("steps", 16)))
			audio.set_pattern(inst.source_id, entry.get("pattern", []))
			inst.set_loop(bool(entry.get("loop_on", true)))
		var problem := apply_instrument_settings(inst, entry.get("settings", {}))
		if problem != "":
			problems.append(problem)
		inst.muted = bool(entry.get("muted", false))
		inst.soloed = bool(entry.get("soloed", false))
	app.settle_new_room()
	var player: Dictionary = data.get("player", {})
	var stood: Array = player.get("position", [])
	if stood.size() == 2:
		app.player.place(Vector3(float(stood[0]), 0.0, float(stood[1])), float(player.get("yaw", 0.0)))
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


func _write(path: String, data: Dictionary) -> String:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return "it couldn't be written (%s)" % error_string(FileAccess.get_open_error())
	file.store_string(JSON.stringify(data, "\t"))
	return ""


func _read(path: String) -> Dictionary:
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
