extends PopupMenu
## The Presets menu of a plug-in or of an instrument: the presets to load (a plug-in's own first, then those saved),
## saving its settings as a new one, copying its settings and pasting copied ones onto it, and the folder its presets
## are kept in. The mix window offers it on an insert and on an instrument's name, and the amp and Speaker panels and
## the Plug-in pedal have a button for it. What happens is reported, for the window it belongs to to show.

signal reported(text: String, problem: bool)

const NONE := 999
const SAVE := 1000
const COPY := 1001
const PASTE := 1002
const FOLDER := 1003
const FACTORY := 2000  # + which of the plug-in's own presets
const SAVED := 10000   # + which of the saved ones

var app
var inst = null
var place := ""  # "insert" or "pedal" for a plug-in there; "" for the instrument itself
var index := -1
var _saved: Array = []


func setup(the_app) -> void:
	app = the_app
	id_pressed.connect(_on_chosen)
	about_to_popup.connect(_fill)


## The menu for the plug-in on an insert (`where` "insert", `at` its slot) or a Plug-in pedal ("pedal").
func for_plugin(instrument, where: String, at: int) -> void:
	inst = instrument
	place = where
	index = at
	_fill()


func for_instrument(instrument) -> void:
	inst = instrument
	place = ""
	index = -1
	_fill()


## Opens it under a control.
func open_below(control: Control) -> void:
	position = Vector2i(control.get_screen_position() + Vector2(0, control.size.y))
	popup()


func _fill() -> void:
	clear()
	if inst == null or not app.instruments.has(inst):
		return
	var library = app.library
	if place != "":
		var factory: PackedStringArray = app.audio.get_factory_presets(inst.source_id, place, index)
		if not factory.is_empty():
			add_separator("Its own")
			for i in factory.size():
				add_item(factory[i], FACTORY + i)
		_saved = library.plugin_presets(inst, place, index)
	else:
		_saved = library.instrument_presets(library.family_of(inst))
	if not _saved.is_empty():
		add_separator("Saved")
		for i in _saved.size():
			add_item(_saved[i].name, SAVED + i)
	if item_count == 0:
		add_item("No presets yet", NONE)
		set_item_disabled(get_item_index(NONE), true)
	add_separator()
	add_item("Save preset…", SAVE)
	add_item("Copy settings", COPY)
	add_item("Paste settings", PASTE)
	var can_paste: bool = library.can_paste_plugin(inst, place, index) if place != "" else library.can_paste_instrument(inst)
	set_item_disabled(get_item_index(PASTE), not can_paste)
	add_item("Show presets in Finder", FOLDER)


## What it is the presets of: the plug-in's name, or the instrument's.
func subject() -> String:
	return app.library.plugin_at(inst, place, index).get("name", "plug-in") if place != "" else inst.display_name


func _on_chosen(id: int) -> void:
	if inst == null or not app.instruments.has(inst):
		return
	var library = app.library
	if id >= SAVED:
		var preset: Dictionary = _saved[id - SAVED]
		var problem: String = library.load_plugin_preset(inst, place, index, preset.path) if place != "" else \
			library.load_instrument_preset(inst, preset.path)
		_report("%s loaded" % preset.name, "%s: %s" % [preset.name, problem], problem)
	elif id >= FACTORY:
		var loaded: bool = app.audio.load_factory_preset(inst.source_id, place, index, id - FACTORY)
		_report("%s loaded" % get_item_text(get_item_index(id)), "That preset wouldn't load", "" if loaded else "-")
	elif id == SAVE:
		var what := subject()
		app.name_prompt.ask("Save a preset of the %s" % what if place == "" else "Save a preset of %s" % what, what, _save, _is_taken)
	elif id == COPY:
		if place != "":
			library.copy_plugin(inst, place, index)
		else:
			library.copy_instrument(inst)
		reported.emit("The %s's settings are copied" % subject() if place == "" else "%s's settings are copied" % subject(), false)
	elif id == PASTE:
		if place != "":
			var pasted: bool = library.paste_plugin(inst, place, index)
			_report("Settings pasted onto %s" % subject(), "They couldn't be pasted", "" if pasted else "-")
		else:
			var problem: String = library.paste_instrument(inst)
			_report("Settings pasted onto the %s" % subject(), "Pasted, but not all of it: %s" % problem, problem)
	elif id == FOLDER:
		var plugin: Dictionary = library.plugin_at(inst, place, index)
		if place == "":
			library.show_folder(library.presets_dir(library.family_of(inst)))
		elif not plugin.is_empty():
			library.show_folder(library.plugin_presets_dir(plugin))


func _save(preset_name: String) -> void:
	if inst == null or not app.instruments.has(inst):
		return
	var library = app.library
	var problem: String = library.save_plugin_preset(inst, place, index, preset_name) if place != "" else \
		library.save_instrument_preset(inst, preset_name)
	_report("Saved as %s" % preset_name, "It couldn't be saved: %s" % problem, problem)


func _is_taken(preset_name: String) -> bool:
	var library = app.library
	if place != "":
		return FileAccess.file_exists(library.plugin_presets_dir(library.plugin_at(inst, place, index)).path_join(library._safe(preset_name) + ".aupreset"))
	return FileAccess.file_exists(library.presets_dir(library.family_of(inst)).path_join(library._safe(preset_name) + "." + library.PRESET_EXT))


func _report(done: String, failed: String, problem: String) -> void:
	reported.emit(done if problem == "" else failed, problem != "")
