extends Node
## The room that is open, as a DAW has a session open: its name and its file, saving it (Cmd-S), making a new one and
## opening another, and keeping it safe. A room lives in a folder named after it, as a Pro Tools session does: its one
## .sroom file holds everything (library.gd's room_data), with a Room Backups folder beside it (and, once recording
## comes, its audio). If auto-save is on (Settings), the room is saved every so many minutes while it has changes;
## if backups are on, a copy of it as it is goes into Room Backups every so often, the oldest thrown away past the
## number kept. Starting another room, opening one, or quitting first asks whether to save changes.
##
## At start no room is open: the default room plays behind the title screen until one is made or opened.

signal changed  # a room was made, opened or saved: whatever shows its name shows it again
signal notice(text: String)  # something done along the way (saved, backed up), for the screen to mention

const TOGETHER := "Together"  # (where copies of other players' rooms go, in the rooms folder)
const BACKUP_DIR := "Room Backups"
const MAX_RECENT := 10

var app
var path := ""       # the room's file; "" while none is open
var room_name := ""
var copy := false    # a copy of another player's room (joined, or left), kept in Together in the rooms folder
var saved_at := 0    # when it was last saved (Unix time), 0 if never
var _saved := ""     # the room as it was when last saved or opened, to tell whether it has changed since
var _backed_up := ""  # likewise for the last backup
var _since_save := 0.0
var _since_backup := 0.0
var _confirm: ConfirmationDialog  # "Save the changes to … ?"
var _then := Callable()  # what to do once that is answered
var _mouse_was := Input.MOUSE_MODE_VISIBLE  # given back once it is


func setup(the_app) -> void:
	app = the_app
	_confirm = ConfirmationDialog.new()
	_confirm.ok_button_text = "Save"
	_confirm.add_button("Don't Save", false, "discard")
	_confirm.confirmed.connect(func() -> void:
		var problem := save()
		if problem == "":
			_carry_on())
	_confirm.custom_action.connect(func(action: StringName) -> void:
		if action == &"discard":
			_confirm.hide()
			_carry_on())
	_confirm.canceled.connect(func() -> void:
		_then = Callable()
		Input.mouse_mode = _mouse_was)
	add_child(_confirm)


func has_room() -> bool:
	return path != "" or copy


## Joined another player's room: its copy here, named for it, in a folder of its own in Together, in the rooms folder,
## where its recordings go, and the others' come (it is saved there only when saved).
func begin_copy(the_name: String) -> void:
	var folder := location().path_join(TOGETHER)
	var unique := the_name
	var number := 2
	while exists(folder, unique):
		unique = "%s %d" % [the_name, number]
		number += 1
	path = file_for(folder, unique)
	copy = true
	room_name = unique
	_mark_saved()
	changed.emit()


## Left it: the copy stays as it was, to go on with (or save).
func end_copy() -> void:
	changed.emit()


## Where new rooms go unless another folder is chosen: Rooms, in the Studiolator folder (library.gd's home()).
func default_location() -> String:
	return app.library.root.path_join("Rooms")


func location() -> String:
	var chosen: String = app.settings.rooms_location
	return chosen if chosen != "" and not app.library.automated else default_location()


## A room's folder and file, from where it goes and its name.
func file_for(folder: String, the_name: String) -> String:
	var safe: String = app.library._safe(the_name)
	return folder.path_join(safe).path_join(safe + "." + app.library.ROOM_EXT)


func exists(folder: String, the_name: String) -> bool:
	return DirAccess.dir_exists_absolute(file_for(folder, the_name).get_base_dir())


## The open room's own folder: the one its file is in, or for a backup opened from Room Backups, the room's.
func room_folder() -> String:
	var folder := path.get_base_dir()
	return folder.get_base_dir() if folder.get_file() == BACKUP_DIR else folder


## The folder the open room's folder stands in, where a room saved as another goes beside it.
func folder_around() -> String:
	return room_folder().get_base_dir() if has_room() else location()


# ── Making, opening, saving ──────────────────────────────────────────────────────────────────────────────────

## Makes a new room from a template, carrying over what `carry` doesn't leave out (library.gd's CARRY), at `size`, and
## saves it in a folder of its own. Returns what went wrong, or "".
func create(the_name: String, folder: String, template_path: String, carry := {}, size = null, mode := "jam") -> String:
	var data: Dictionary = app.library.template_data(template_path)
	if data.is_empty():
		return "the template couldn't be read"
	if exists(folder, the_name):
		return "there is a room called that in that folder already"
	path = file_for(folder, the_name)
	copy = false
	room_name = the_name
	var problem: String = app.library.apply_room_data(data, carry, size, mode)
	var unsaved := save()
	return unsaved if unsaved != "" else problem


## Opens a room's file, in place of the room there is. Returns what went wrong, or "".
func open(file: String) -> String:
	var data: Dictionary = app.library.read_room_file(file)
	if data.is_empty():
		return "it isn't a room Studiolator can read"
	path = file  # first, so that its recordings are found in its folder
	copy = false
	var problem: String = app.library.apply_room_data(data)
	room_name = str(data.get("name", file.get_file().get_basename()))
	saved_at = FileAccess.get_modified_time(file)
	_mark_saved()
	_remember(file)
	changed.emit()
	return problem


## Saves the room to its file. Returns why it couldn't, or "".
func save() -> String:
	if not has_room():
		return "no room is open"
	if path == "":
		return "it is a copy of another player's room, with no file of its own: Save As keeps one"
	var data: Dictionary = app.library.room_data()
	data.name = room_name
	data.saved = Time.get_datetime_string_from_system()
	var problem: String = app.library.write_file(path, data)
	if problem != "":
		return problem
	saved_at = int(Time.get_unix_time_from_system())
	_mark_saved()
	_remember(path)
	changed.emit()
	return ""


## Cmd-S: saves the room, or with none open asks for a name to save it under, as a new room.
func save_or_ask() -> void:
	if path != "":
		var problem := save()
		notice.emit("Saved %s" % room_name if problem == "" else "It couldn't be saved: %s" % problem)
	else:
		app.name_prompt.ask("Save this room as", "Untitled room", save_as, func(n: String) -> bool: return exists(location(), n))


## Saves the room under another name, in a folder of its own beside the first (or in the rooms folder), and carries on
## in that one, as a DAW's Save As does.
func save_as(the_name: String) -> void:
	path = file_for(folder_around() if not copy else location(), the_name)
	copy = false
	room_name = the_name
	var problem := save()
	notice.emit("Saved as %s" % the_name if problem == "" else "It couldn't be saved: %s" % problem)


## Whether the room has changed since it was last saved or opened.
func has_unsaved_changes() -> bool:
	return path != "" and _signature() != _saved


## The rooms there are to open: those in the rooms folder, and those opened lately from elsewhere, the latest first:
## [{name, path, modified}].
func rooms() -> Array:
	var found := {}
	var folder := location()
	if DirAccess.dir_exists_absolute(folder):
		for sub in DirAccess.get_directories_at(folder):
			for file in DirAccess.get_files_at(folder.path_join(sub)):
				if file.get_extension() == app.library.ROOM_EXT:
					found[folder.path_join(sub).path_join(file)] = true
	for recent in app.settings.recent_rooms:
		if FileAccess.file_exists(recent):
			found[recent] = true
	var out := []
	for file in found:
		out.append({"name": file.get_file().get_basename(), "path": file, "modified": FileAccess.get_modified_time(file)})
	out.sort_custom(func(a, b): return a.modified > b.modified)
	return out


## Shows the room's folder in the Finder.
func show_folder() -> void:
	app.library.show_folder(room_folder() if has_room() else location())


# ── Asking before the room goes ──────────────────────────────────────────────────────────────────────────────

## Does `then` once the room's changes are saved or let go: at once if there are none, otherwise after asking.
## `doing` says what is about to happen ("opening another room").
func then_if_saved(then: Callable, doing: String) -> void:
	if not has_unsaved_changes():
		then.call()
		return
	_then = then
	_confirm.dialog_text = "Save the changes to \"%s\" before %s?" % [room_name, doing]
	_mouse_was = Input.mouse_mode
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE  # to answer it with, from the room as anywhere
	app.player.release_keys()
	_confirm.popup_centered()


func is_asking() -> bool:
	return _confirm.visible


func request_quit() -> void:
	then_if_saved(func() -> void: get_tree().quit(), "quitting")


func _carry_on() -> void:
	var then := _then
	_then = Callable()
	if then.is_valid():
		then.call()


# ── Auto-save and backups ────────────────────────────────────────────────────────────────────────────────────

func _process(delta: float) -> void:
	if path == "":
		return
	var settings = app.settings
	_since_save += delta
	_since_backup += delta
	if settings.autosave and _since_save >= settings.autosave_minutes * 60.0:
		_since_save = 0.0
		if has_unsaved_changes() and save() == "":
			notice.emit("Auto-saved %s" % room_name)
	if settings.backups and _since_backup >= settings.backup_minutes * 60.0:
		_since_backup = 0.0
		backup()


## A copy of the room as it is now (saved or not) in its Room Backups folder, if it has changed since the last one, as
## "Name backup 001.sroom", "Name backup 002.sroom" and so on (as Pro Tools numbers its .bak files); past the number
## kept, the oldest go. Returns the copy's file, or "".
func backup() -> String:
	var signature := _signature()
	if not has_room() or signature == _backed_up:
		return ""
	var folder := room_folder().path_join(BACKUP_DIR)
	var copies := backups()
	var number: int = copies.back().number + 1 if not copies.is_empty() else 1
	var file := folder.path_join("%s backup %03d.%s" % [app.library._safe(room_name), number, app.library.ROOM_EXT])
	var data: Dictionary = app.library.room_data()
	data.name = room_name
	data.saved = Time.get_datetime_string_from_system()
	if app.library.write_file(file, data) != "":
		return ""
	_backed_up = signature
	copies = backups()
	while copies.size() > maxi(app.settings.backups_kept, 1):
		DirAccess.remove_absolute(copies.pop_front().path)
	notice.emit("Backed up %s" % room_name)
	return file


## The open room's backups, oldest first: [{path, number}].
func backups() -> Array:
	var folder := room_folder().path_join(BACKUP_DIR)
	var out := []
	if has_room() and DirAccess.dir_exists_absolute(folder):
		for file in DirAccess.get_files_at(folder):
			var words := file.get_basename().split(" ")
			if file.get_extension() == app.library.ROOM_EXT and words.size() >= 2 and words[-2] == "backup" and words[-1].is_valid_int():
				out.append({"path": folder.path_join(file), "number": words[-1].to_int()})
	out.sort_custom(func(a, b): return a.number < b.number)
	return out


## The room as a string to compare, leaving out where you stand.
func _signature() -> String:
	var data: Dictionary = app.library.room_data()
	data.erase("player")
	data.timeline.erase("playhead")  # neither where you stand nor where the music is counts as a change
	data.timeline.erase("playing")
	return JSON.stringify(data)


func _mark_saved() -> void:
	_saved = _signature()
	_backed_up = _saved
	_since_save = 0.0
	_since_backup = 0.0


func _remember(file: String) -> void:
	var recent: Array = app.settings.recent_rooms
	recent.erase(file)
	recent.push_front(file)
	app.settings.recent_rooms = recent.slice(0, MAX_RECENT)
	app.settings.save_to_disk()
	DisplayServer.window_set_title("%s · Studiolator" % room_name)
