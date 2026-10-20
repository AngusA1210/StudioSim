extends Node3D
## Builds the Sound Room (room, instruments, player, HUD, title screen, menus, pattern editor), starts the native
## audio core, and is the one place that changes settings and the tempo: the menus and the keyboard shortcuts all
## go through the functions below.
##
## Command-line options, passed after `--`:
##   --silent                 run the audio clock without opening a sound card (also leaves saved settings alone)
##   --skip-title             start in the room rather than on the title screen
##   --pose=x,z,yaw_degrees   start the player somewhere else
##   --live-input             switch the Speaker's input on at start
##   --menu=N                 open the menu on page N at start (0 Metronome, 1 Room, 2 Playback Engine...)
##   --play=kind              sit down at an instrument at start (drums, bass, pad, bells, keys)
##   --sequencer=kind[,bar]   open that instrument's pattern editor at start
##   --add=kind               make a new instrument at start, in the player's hands
##   --instruments            open the instrument menu at start
##   --mixer                  open the mix window at start
##   --room=W,H,L             start with a room this wide, high and long (metres)
##   --walls=ax,az,bx,bz[,h];...   replace the room's walls: each runs from (ax, az) to (bx, bz), h high
##   --tempo=BPM              start at another tempo
##   --text-scale=F           override the text size
##   --screenshot=path.png    save a screenshot after --frames frames (default 90), print stats, and quit
##   --quit-after=seconds     print stats and quit after this long

const Instrument := preload("res://scripts/instrument.gd")
const Folder := preload("res://scripts/folder.gd")
const Player := preload("res://scripts/player.gd")
const Hud := preload("res://scripts/hud.gd")
const Menu := preload("res://scripts/menu.gd")
const Sequencer := preload("res://scripts/sequencer.gd")
const InstrumentMenu := preload("res://scripts/instrument_menu.gd")
const Mixer := preload("res://scripts/mixer.gd")
const AmpPanel := preload("res://scripts/amp_panel.gd")
const PluginBrowser := preload("res://scripts/plugin_browser.gd")
const SpeakerPanel := preload("res://scripts/speaker_panel.gd")
const MicPanel := preload("res://scripts/mic_panel.gd")
const Bindings := preload("res://scripts/bindings.gd")
const Title := preload("res://scripts/title.gd")
const Catalog := preload("res://scripts/catalog.gd")
const Settings := preload("res://scripts/settings.gd")
const Room := preload("res://scripts/room.gd")
const Library := preload("res://scripts/library.gd")
const Session := preload("res://scripts/session.gd")
const RoomsPage := preload("res://scripts/rooms_page.gd")
const Timeline := preload("res://scripts/timeline.gd")
const EditWindow := preload("res://scripts/edit_window.gd")
const NamePrompt := preload("res://scripts/name_prompt.gd")

# The instruments the room starts with, each playing its part of the default groove and turned to face where the
# player comes in. More can be added from the instrument menu; scripts/catalog.gd describes each kind.
const DEFAULT_ROOM := [
	{"kind": "drums", "position": Vector3(0.5, 0.0, -3.6)},
	{"kind": "bass", "position": Vector3(-5.0, 0.0, -2.0)},
	{"kind": "pad", "position": Vector3(4.8, 0.0, -1.6)},
	{"kind": "bells", "position": Vector3(-4.6, 0.0, 2.4)},
	{"kind": "keys", "position": Vector3(3.0, 0.0, 1.8)},
	# Whatever is plugged into the audio input comes out of this speaker once its input is switched on.
	{"kind": "live", "position": Vector3(-2.0, 0.0, 1.6)},
]
const SPAWN := Vector3(0.0, 0.0, 3.6)
# What the audio core multiplies an instrument by on its way to the master, heard within 1.5 m: its channel meter
# reads the instrument at that level, as a DAW's track meter reads the signal the track sends to the master.
const CHANNEL_TRIM := 0.88
const DEFAULT_TEMPO := 92.0
const DEFAULT_SWING := 0.14

var audio: SoundRoomAudio
var settings := Settings.new()
var player
var hud
var menu
var sequencer  # the pattern editor
var mixer  # the mix window (Tab)
var amp_panel  # an amp's knobs and its pedals (' at an amp)
var plugin_browser  # the effect plug-ins on the computer, to choose one for an insert or a Plug-in pedal
var speaker_panel  # a Speaker's volume and input (' at a Speaker)
var mic_panel      # a microphone's place, aim and gain (' at a microphone)
var _mic_models = null  # the microphone models, as the audio core has them (asked for once)
var bindings  # the keys, as set on the Controls page
var library  # rooms' and templates' contents, presets, and settings copied to be pasted
var session  # the room that is open: its file, saving, backups
var rooms_page  # making a new room, or opening one
var timeline  # the room's mode, and a Record room's transport, recording and clips
var automation  # the tracks' automation, as the music plays (automation.gd)
var edit_window  # a Record room's tracks and clips along the timeline
var name_prompt  # asks for a name, to save a template or a preset under
var _plugins = null  # what get_plugins() said, the first time anything asked
var _instrument_plugins = null  # and get_instrument_plugins()
var instrument_menu
var title  # the title screen
var room  # its size and the walls inside it
var instruments: Array = []
var folders: Array = []        # the routing folders (folder.gd)
var auxes: Array = []          # the aux tracks (folder.gd, is_aux): buses the tracks' sends play into
var master_track               # the master, as a track for automation (master_track.gd)
var silenced := {}             # the tracks a mute or a solo elsewhere keeps from being heard (track → true), as last set
var chosen_tracks: Array = []  # the tracks chosen by their names in the edit and mix windows: instruments and folders
var speaker  # the Speaker the room starts with: the one whose input choice is remembered between runs
# The room's clock. These belong to the room rather than the player's settings, so they start from the defaults.
var tempo := DEFAULT_TEMPO
var master_volume_db := 0.0  # the master fader
var reverb_db := 0.0  # the room reverb's fader
var reverb_meter := {}  # its return's level, read with the output meter
var reverb_peak_hold := 0.0
var swing := DEFAULT_SWING
var sequence_running := true  # whether the sequencer is playing the patterns
var options := {}
var live_input := false   # the audio input is open: some Speaker's input is on. Every Speaker starts with it off,
                          # since an open microphone next to speakers would feed back
var audio_error := ""     # the last problem opening a device, shown in the menu
var copy_problem := ""    # what the last duplicate_instrument couldn't copy, if anything
var _stage_gain := 1.0    # the title screen turns the music down a little; 1 in the room
var _environment: Environment
# The output meter, read once a frame for whoever shows it: the latest reading, how hard the limiter has pulled
# down lately (in dB, held for a moment), and whether samples have been cut off at full scale lately. Like the
# instruments' channel meters, it also keeps the highest peak since it was last cleared, as a DAW's peak readout does.
var meter := {}
var master_peak_hold := 0.0
var meter_reduction_db := 0.0
var meter_clipped := false
var _reduction_age := 0.0
var _clip_age := 10.0
var _frames := 0
var _elapsed := 0.0
var _midi_poll := 0.0


func _ready() -> void:
	_parse_options()
	settings.persist = not options.has("silent")
	settings.load_from_disk()
	bindings = Bindings.new(settings.bindings)
	if options.has("text-scale"):
		settings.text_scale = float(options["text-scale"])

	audio = SoundRoomAudio.new()
	audio.name = "AudioCore"
	add_child(audio)
	open_audio()
	for device_name in settings.midi_disabled:
		audio.set_midi_device_enabled(device_name, false)
	audio.start_midi()

	_build_environment()
	library = Library.new(self, options.has("silent"))
	room = Room.new()
	add_child(room)
	room.changed.connect(_on_room_changed)
	room.setup()
	player = Player.new()
	player.name = "Player"
	add_child(player)
	player.setup(self, instruments)
	session = Session.new()
	session.name = "Session"
	add_child(session)
	session.setup(self)
	timeline = Timeline.new()
	timeline.name = "Timeline"
	add_child(timeline)
	timeline.setup(self)
	automation = preload("res://scripts/automation.gd").new()
	automation.name = "Automation"
	add_child(automation)
	automation.setup(self)
	master_track = preload("res://scripts/master_track.gd").new()
	master_track.app = self
	load_default_room()  # behind the title screen, until a room is made or opened
	if options.has("room"):
		var dims: PackedStringArray = options.room.split(",")
		room.set_size(Vector3(float(dims[0]), float(dims[1]), float(dims[2])))
	if options.has("walls"):
		while not room.walls.is_empty():
			room.remove_wall(0)
		for text in options.walls.split(";", false):
			var n: PackedStringArray = text.split(",")
			room.add_wall(Vector2(float(n[0]), float(n[1])), Vector2(float(n[2]), float(n[3])), float(n[4]) if n.size() > 4 else Room.DEFAULT_WALL_HEIGHT)
	audio.set_binaural(settings.binaural)
	_apply_master_volume()
	audio.set_distance_falloff(settings.distance_falloff_db)
	audio.set_limiter(settings.limiter)
	audio.set_click(settings.click)
	audio.set_click_volume(db_to_linear(settings.click_volume_db))
	if options.has("tempo"):
		set_tempo(float(options.tempo))
	if options.has("pose"):
		var p: PackedStringArray = options.pose.split(",")
		player.place(Vector3(float(p[0]), 0.0, float(p[1])), deg_to_rad(float(p[2])))

	hud = Hud.new()
	add_child(hud)
	hud.setup(self)
	menu = Menu.new()
	add_child(menu)
	menu.setup(self)
	sequencer = Sequencer.new()
	add_child(sequencer)
	sequencer.setup(self)
	mixer = Mixer.new()
	add_child(mixer)
	mixer.setup(self)
	amp_panel = AmpPanel.new()
	add_child(amp_panel)
	amp_panel.setup(self)
	speaker_panel = SpeakerPanel.new()
	add_child(speaker_panel)
	speaker_panel.setup(self)
	mic_panel = MicPanel.new()
	add_child(mic_panel)
	mic_panel.setup(self)
	plugin_browser = PluginBrowser.new()
	add_child(plugin_browser)
	instrument_menu = InstrumentMenu.new()
	add_child(instrument_menu)
	instrument_menu.setup(self)
	title = Title.new()
	add_child(title)
	title.setup(self)
	rooms_page = RoomsPage.new()
	add_child(rooms_page)
	rooms_page.setup(self)
	edit_window = EditWindow.new()
	add_child(edit_window)
	edit_window.setup(self)
	name_prompt = NamePrompt.new()
	add_child(name_prompt)
	get_tree().auto_accept_quit = false  # quitting asks first whether to save the room
	# Should the game lose the keyboard (to a plug-in's window, say), let go of every note held: the keys' letting go
	# would never arrive, and the notes would hang.
	get_window().focus_exited.connect(func() -> void: player.release_keys())
	_apply_display()
	if not options.has("skip-title"):
		title.open()

	if options.has("live-input") and speaker != null:
		set_input(speaker, true)
	if options.has("menu"):
		menu.open(int(options.menu))
	if options.has("play"):
		_sit_at(options.play)
		player.start_playing(find_instrument(options.play))
	if options.has("sequencer"):
		var parts: PackedStringArray = options.sequencer.split(",")
		_sit_at(parts[0])
		sequencer.open(find_instrument(parts[0]), int(parts[1]) - 1 if parts.size() > 1 else -1)
	if options.has("add"):
		instrument_menu.create(options.add)
	if options.has("instruments"):
		instrument_menu.open()
	if options.has("mixer"):
		mixer.open()


## Closing the window, or Cmd-Q: as Quit, which offers to save the room first.
func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST and session != null:
		session.request_quit()


## The Cmd shortcuts (Ctrl off a Mac; bindings.gd lists them): saving the room, from anywhere but a box being typed
## in; and in the room or its windows, recording, undo and redo, and the mix and edit windows in turn. Space starts and
## stops the music in the mix and edit windows too.
func _input(event: InputEvent) -> void:
	if not (event is InputEventKey and event.pressed and not event.echo) or name_prompt.is_open() or rooms_page.is_open():
		return
	if get_viewport().gui_get_focus_owner() is LineEdit:  # being typed in (the edit window's counter, say)
		return
	var command: bool = event.meta_pressed or event.ctrl_pressed
	var shortcut: String = bindings.command_for(event.physical_keycode) if command else ""
	if shortcut == "save" and not session.is_asking():
		session.save_or_ask()
		get_viewport().set_input_as_handled()
		return
	if (title != null and title.is_open()) or menu.is_open() or session.is_asking():
		return
	if shortcut == "undo" and event.shift_pressed:  # Cmd-Shift-Z redoes too, as most programs have it
		shortcut = "redo"
	match shortcut:
		"record":
			toggle_record()
		"swap_windows":  # the mix window and the edit window, in turn
			if not timeline.is_record():
				return
			if edit_window.is_open():
				edit_window.close()
				mixer.open()
			else:
				if mixer.is_open():
					mixer.close()
				edit_window.open()
		"undo", "redo":
			if not timeline.is_record() or timeline.recording:
				return
			undo_edit(shortcut == "redo")
		"group":  # the tracks chosen, in a new folder
			if not (mixer.is_open() or edit_window.is_open()):
				return
			group_chosen()
		_:
			if (mixer.is_open() or edit_window.is_open()) and bindings.action_for(event.physical_keycode) == "transport" and not command:
				toggle_transport()  # Space works in the mix and edit windows too
			else:
				return
	get_viewport().set_input_as_handled()


## Cmd-Z, or the edit window's Undo button: the clips as they were before the last edit (with `redo`, the last edit undone,
## done again).
func undo_edit(redo := false) -> void:
	var what: String = timeline.redo() if redo else timeline.undo()
	edit_window.view.chosen = []
	session.notice.emit(("Redo " if redo else "Undo ") + what if what != "" else ("Nothing to redo" if redo else "Nothing to undo"))


func _process(delta: float) -> void:
	_frames += 1
	_elapsed += delta
	_read_meter(delta)
	_midi_poll += delta
	if _midi_poll > 2.0:  # the system tells us about new controllers too; this is the fallback
		_midi_poll = 0.0
		audio.poll_midi()
	if options.has("screenshot") and _frames == int(options.get("frames", "90")):
		var image := get_viewport().get_texture().get_image()
		image.save_png(options.screenshot)
		_print_stats()
		get_tree().quit()
	elif options.has("quit-after") and _elapsed >= float(options["quit-after"]):
		_print_stats()
		get_tree().quit()


func _read_meter(delta: float) -> void:
	meter = audio.read_meter()
	master_peak_hold = maxf(master_peak_hold, maxf(meter.get("peak_l", 0.0), meter.get("peak_r", 0.0)))
	reverb_peak_hold = maxf(reverb_peak_hold, maxf(meter.get("reverb_peak_l", 0.0), meter.get("reverb_peak_r", 0.0)))
	# Each channel as it reaches the master: after its fader, before distance and the master's. Or before its fader,
	# scaled so that the two agree with the fader at 0 dB.
	var pre: bool = settings.pre_fader_meters
	for inst in instruments:
		var scale: float = CHANNEL_TRIM * (inst.normal_gain() if pre else 1.0)
		var peaks := [audio.get_source_peak(inst.source_id, false), audio.get_source_peak(inst.source_id, true)]  # both,
		inst.meter_peak = peaks[int(pre)] * scale  # so the other doesn't hold an old peak for when it is chosen
		inst.meter_rms = audio.get_source_level(inst.source_id, pre) * scale
		inst.peak_hold = maxf(inst.peak_hold, inst.meter_peak)
	for folder in folders + auxes:  # (its bus's meters read dBFS as it reaches the master already)
		var peaks := [audio.get_source_peak(folder.source_id, false), audio.get_source_peak(folder.source_id, true)]
		folder.meter_peak = peaks[int(pre)]
		folder.meter_rms = audio.get_source_level(folder.source_id, pre)
		folder.peak_hold = maxf(folder.peak_hold, folder.meter_peak)
	var reduction := -linear_to_db(maxf(meter.get("limiter_gain", 1.0), 0.001))
	_reduction_age += delta
	if reduction >= meter_reduction_db or _reduction_age > 1.5:
		meter_reduction_db = reduction
		_reduction_age = 0.0
	_clip_age = 0.0 if int(meter.get("clipped", 0)) > 0 else _clip_age + delta
	meter_clipped = _clip_age < 2.0


## Clears a channel's peak readout (null: the master's), or every one of them.
func clear_peak(inst) -> void:  # (null: the master's; "reverb": the reverb's)
	if inst is String:
		reverb_peak_hold = 0.0
	elif inst == null:
		master_peak_hold = 0.0
	else:
		inst.peak_hold = 0.0


## Gives an action a new key (the Controls page). Whatever had that key takes the action's old one; returns it, or "".
func set_binding(action: String, keycode: int) -> String:
	var swapped: String = bindings.bind(action, keycode)
	settings.bindings = bindings.changed()
	settings.save_to_disk()
	return swapped


func reset_bindings() -> void:
	bindings.reset()
	settings.bindings = {}
	settings.save_to_disk()


## The mix window's channel meters before the fader or after it. The peaks held so far were measured the other way.
func set_pre_fader_meters(on: bool) -> void:
	settings.pre_fader_meters = on
	settings.save_to_disk()
	for inst in instruments + folders + auxes:
		inst.peak_hold = 0.0


## An amp's panel with its pedalboard showing, or folded away (for every amp, and remembered).
func set_pedalboard_open(on: bool) -> void:
	settings.pedalboard_open = on
	settings.save_to_disk()


func clear_all_peaks() -> void:
	master_peak_hold = 0.0
	reverb_peak_hold = 0.0
	for inst in instruments + folders + auxes:
		inst.peak_hold = 0.0


## Tell the audio core where each instrument is. It works out how the sound gets from there to the listener.
func _physics_process(_delta: float) -> void:
	for inst in instruments:
		inst.sync_position()


# ── The room ────────────────────────────────────────────────────────────────────────────────────────────────

## The room's size or walls changed: tell the audio core, and bring in anything left outside or inside a wall.
func _on_room_changed() -> void:
	audio.set_room(room.size, room.audio_walls())
	for inst in instruments:
		var at: Vector3 = inst.global_position
		at.y = inst.source_height
		inst.global_position = room.settle(at, 0.6, 0.5, at)
	if player != null:
		var stood: Vector3 = player.global_position
		stood.y = 0.0
		player.global_position = room.settle(stood, 0.5, 0.45, stood)
	_apply_lighting()


# ── Playback engine and I/O ─────────────────────────────────────────────────────────────────────────────────

## Opens the audio devices the settings ask for. If the chosen output isn't connected, falls back to the system
## default (keeping the choice, so it comes back when the device does). Returns whether sound is running.
func open_audio() -> bool:
	audio_error = ""
	var config := {
		"silent": options.has("silent"),
		"output_device": settings.output_device,
		"buffer_size": settings.buffer_size,
		"output_left": settings.output_left,
		"output_right": settings.output_right,
		"input_enabled": live_input,
		"input_device": settings.input_device,
	}
	if audio.open_device(config):
		return true
	audio_error = audio.get_error()
	if live_input:  # most likely the input: carry on without it
		live_input = false
		config.input_enabled = false
		if audio.open_device(config):
			return true
	config.output_device = ""
	if audio.open_device(config):
		return true
	audio_error = audio.get_error()
	push_error("Audio could not start: %s" % audio_error)
	return false


func set_output_device(device_name: String) -> void:
	settings.output_device = device_name
	settings.output_left = 0
	settings.output_right = 1
	open_audio()
	settings.save_to_disk()


func set_buffer_size(samples: int) -> void:
	settings.buffer_size = samples
	open_audio()
	settings.save_to_disk()


func set_output_channels(left: int, right: int) -> void:
	settings.output_left = left
	settings.output_right = right
	audio.set_output_channels(left, right)
	settings.save_to_disk()


func set_input_device(device_name: String) -> void:
	settings.input_device = device_name
	if live_input:
		open_audio()
	settings.save_to_disk()


## Every Speaker's input on or off at once (the I/O page's switch).
func set_live_input(on: bool) -> void:
	for inst in instruments:
		if inst.is_live():
			inst.set_input(on)
	follow_live_inputs()


## Switches an instrument's input on or off, as a track's input in a DAW. With it on, a MIDI instrument plays what
## the MIDI keyboard sends, and a Speaker plays its hardware input (the audio input opens when the first one does).
func set_input(inst, on: bool) -> void:
	inst.set_input(on)
	if player != null:
		player.notice_input(inst)
	if inst.is_live():
		follow_live_inputs()


## The MIDI instruments whose input is on, or that are armed to record: what the keyboards play.
func armed_instruments() -> Array:
	return instruments.filter(func(inst): return inst.playable and (inst.input_on or inst.armed))


## Opens the audio input while any Speaker or amp wants it (its input on, or armed to record), and closes it when none does.
func follow_live_inputs() -> void:
	var wanted := instruments.any(func(inst): return inst.is_live() and (inst.input_on or inst.armed))
	if wanted == live_input:
		return
	live_input = wanted
	open_audio()
	if wanted and not live_input:  # the input wouldn't open: say so through the Speakers too
		for inst in instruments:
			if inst.is_live():
				inst.set_input(false)


# ── Amps ────────────────────────────────────────────────────────────────────────────────────────────────────

## An amp's head and cabinet (catalog.gd lists them), and whether each is in use: bypassed, a head passes the signal
## straight to the cabinet, so that a plug-in amp on a pedal can be the head, and a cabinet is a flat full-range speaker.
func set_amp_voice(inst, head: String, use_head: bool, cabinet: String, use_cabinet: bool) -> void:
	inst.set_voice(head, use_head, cabinet, use_cabinet)


## One of an amp's knobs ("gain", "bass", "mid", "treble", "presence", "master"), 0 to 10.
func set_amp_control(inst, control: String, value: float) -> void:
	inst.amp_controls[control] = clampf(value, 0.0, 10.0)
	audio.set_amp_control(inst.source_id, control, inst.amp_controls[control])


## An amp's loop pedal's buttons, if it has one: "press" (the footswitch), "stop", "play", "undo", "redo", "clear".
## Starting a recording switches the amp's input on, since there would be nothing to record otherwise.
func looper_action(inst, action: String) -> void:
	if not inst.is_amp or inst.looper.get("state", "none") == "none":
		return
	if action == "press" and inst.looper.get("state", "empty") == "empty" and not inst.input_on:
		set_input(inst, true)
	audio.looper(inst.source_id, action)
	inst.looper = audio.get_looper(inst.source_id)


## Stamping on an amp's pedal, as a foot would: it switches on or off, or for the loop pedal presses its footswitch.
func stomp(inst, index: int) -> void:
	if index < 0 or index >= inst.pedals.size():
		return
	if inst.pedals[index].kind == "looper":
		looper_action(inst, "press")
	else:
		set_pedal_on(inst, index, not inst.pedals[index].on)


## Mute and solo, as on a mixing desk: while anything is soloed, everything else is silent.
## An amp's effect pedals (the amp panel sets them up; 1-8 in the room switch them). The instrument's `pedals` is
## brought up to date at once, rather than waiting for its next frame.
## The pedals' automation follows them about the board (see automation.pedals_moved).
func add_pedal(inst, kind: String, at := -1) -> int:
	var count: int = inst.pedals.size()
	var index := audio.add_pedal(inst.source_id, kind, at)
	inst.pedals = audio.get_pedals(inst.source_id)
	inst.looper = audio.get_looper(inst.source_id)
	if index >= 0 and index < count:
		automation.pedals_moved(inst, range(count).map(func(i): return i + 1 if i >= index else i))
	return index


func remove_pedal(inst, index: int) -> void:
	var count: int = inst.pedals.size()
	if audio.remove_pedal(inst.source_id, index):
		automation.pedals_moved(inst, range(count).map(func(i): return -1 if i == index else (i - 1 if i > index else i)))
	inst.pedals = audio.get_pedals(inst.source_id)
	inst.looper = audio.get_looper(inst.source_id)


func move_pedal(inst, from: int, to: int) -> bool:
	var count: int = inst.pedals.size()
	var moved := audio.move_pedal(inst.source_id, from, to)
	inst.pedals = audio.get_pedals(inst.source_id)
	if moved and from != to:
		automation.pedals_moved(inst, range(count).map(func(i):
			if i == from:
				return to
			if from < to and i > from and i <= to:
				return i - 1
			if to < from and i >= to and i < from:
				return i + 1
			return i))
	return moved


## A second of a pedal (Option-drag on the board, or duplicating the amp), switch, knobs and plug-in settings and all,
## on `to_inst`'s board at `at` (-1: the end). Where it went, or -1, with the reason in `audio.get_error()`.
func copy_pedal(inst, index: int, to_inst, at := -1) -> int:
	var count: int = to_inst.pedals.size()
	var placed := audio.copy_pedal(inst.source_id, index, to_inst.source_id, at)
	to_inst.pedals = audio.get_pedals(to_inst.source_id)
	to_inst.looper = audio.get_looper(to_inst.source_id)
	if placed >= 0:  # its automation copied with it (the others on that board moved along first)
		if placed < count:
			automation.pedals_moved(to_inst, range(count).map(func(i): return i + 1 if i >= placed else i))
		automation.copied(inst, "pedal", index + 1 if inst == to_inst and index >= placed else index, to_inst, placed)
	return placed


func set_pedal_on(inst, index: int, on: bool) -> void:
	audio.set_pedal_on(inst.source_id, index, on)
	inst.pedals = audio.get_pedals(inst.source_id)


func set_pedal_control(inst, index: int, control: int, value: float) -> void:
	audio.set_pedal_control(inst.source_id, index, control, value)
	inst.pedals = audio.get_pedals(inst.source_id)


## Loads one of the computer's effect plug-ins into a Plug-in pedal. Returns why it couldn't, or "".
func load_pedal_plugin(inst, index: int, plugin_id: String, state := PackedByteArray()) -> String:
	var before: String = str(inst.pedals[index].get("plugin_id", "")) if index < inst.pedals.size() else ""
	var loaded := audio.load_pedal_plugin(inst.source_id, index, plugin_id, state)
	inst.pedals = audio.get_pedals(inst.source_id)
	if loaded and before != "" and before != plugin_id:  # another plug-in: the old one's automation goes with it
		automation.dropped(inst, "pedal", index)
	return "" if loaded else audio.get_error()


## A plug-in's own window, floating over the room. Not in automated runs, which have no windows to show it in.
func show_plugin_editor(inst, index: int, show: bool) -> bool:
	if show and DisplayServer.get_name() == "headless":
		return false
	var pedal: Dictionary = inst.pedals[index] if index < inst.pedals.size() else {}
	var shown := audio.show_plugin_editor(inst.source_id, index, show, "%s  ·  %s pedal %d" % [pedal.get("plugin_name", ""),
		inst.display_name, index + 1])
	inst.pedals = audio.get_pedals(inst.source_id)
	return shown


## The effect plug-ins installed, as the audio core lists them: looked up once, the first time they are wanted.
func available_plugins() -> Array:
	if _plugins == null:
		_plugins = audio.get_plugins()
	return _plugins


## The instrument plug-ins installed (synthesizers, samplers, pianos), looked up once, the first time they are wanted.
func available_instrument_plugins() -> Array:
	if _instrument_plugins == null:
		_instrument_plugins = audio.get_instrument_plugins()
	return _instrument_plugins


## Loads an instrument plug-in into a plug-in instrument (with these settings, if given), which then goes by its name.
## Returns why it couldn't, or "".
func set_instrument_plugin(inst, plugin_id: String, state := PackedByteArray()) -> String:
	var before: String = str(inst.instrument_plugin.get("plugin_id", ""))
	if not audio.set_instrument_plugin(inst.source_id, plugin_id, state):
		return audio.get_error()
	inst.instrument_plugin = audio.get_instrument_plugin(inst.source_id)
	if before != "" and before != plugin_id:
		automation.dropped(inst, "instrument")
	if not inst.named:  # (a track given a name keeps it)
		inst.set_display_name(unique_name(inst.instrument_plugin.plugin_name, inst))
	return ""


## A plug-in instrument's plug-in's own window, floating over the room. Not in automated runs, which have no windows.
func show_instrument_editor(inst, show: bool) -> bool:
	if show and DisplayServer.get_name() == "headless":
		return false
	var shown := audio.show_instrument_editor(inst.source_id, show, inst.display_name)
	inst.instrument_plugin = audio.get_instrument_plugin(inst.source_id)
	return shown


## Moves a plug-in instrument's window to the middle of the game's, its bottom `above_bottom` of the way up (0 to 1).
func place_instrument_editor(inst, above_bottom: float) -> void:
	audio.place_instrument_editor(inst.source_id, above_bottom)


## A name no other instrument in the room has: `base`, or "base 2", "base 3"... (`except` is the one being named).
func unique_name(base: String, except = null) -> String:
	var taken := instruments.filter(func(other): return other != except).map(func(other): return other.display_name)
	var candidate := base
	var number := 2
	while taken.has(candidate):
		candidate = "%s %d" % [base, number]
		number += 1
	return candidate


## A channel's inserts, as in a DAW's mix window: a plug-in in each of a few slots, before the fader. Loading one
## returns why it couldn't be loaded, or "". A plug-in's automation goes where it goes: moved, copied, or (taken away,
## or another put in its place) gone with it.
func set_insert(inst, slot: int, plugin_id: String, state := PackedByteArray()) -> String:
	var before: String = str(inst.inserts[slot].get("plugin_id", "")) if slot < inst.inserts.size() else ""
	var loaded := audio.set_insert(inst.source_id, slot, plugin_id, state)
	inst.inserts = audio.get_inserts(inst.source_id)
	if loaded and before != "" and before != plugin_id:
		automation.dropped(inst, "insert", slot)
	return "" if loaded else audio.get_error()


## Dragging an insert to another slot, on this channel or another: it moves there and whatever was there takes its
## place. Copying instead puts a second of the same plug-in there, with its settings; it returns why it couldn't, or "".
func move_insert(from_inst, from_slot: int, to_inst, to_slot: int) -> void:
	var moved := audio.move_insert(from_inst.source_id, from_slot, to_inst.source_id, to_slot)
	from_inst.inserts = audio.get_inserts(from_inst.source_id)
	to_inst.inserts = audio.get_inserts(to_inst.source_id)
	if moved and not (from_inst == to_inst and from_slot == to_slot):
		automation.insert_moved(from_inst, from_slot, to_inst, to_slot)


func copy_insert(from_inst, from_slot: int, to_inst, to_slot: int) -> String:
	var copied := audio.copy_insert(from_inst.source_id, from_slot, to_inst.source_id, to_slot)
	to_inst.inserts = audio.get_inserts(to_inst.source_id)
	if copied and not (from_inst == to_inst and from_slot == to_slot):
		automation.copied(from_inst, "insert", from_slot, to_inst, to_slot)
	return "" if copied else audio.get_error()


func clear_insert(inst, slot: int) -> void:
	audio.clear_insert(inst.source_id, slot)
	inst.inserts = audio.get_inserts(inst.source_id)
	automation.dropped(inst, "insert", slot)


func set_insert_on(inst, slot: int, on: bool) -> void:
	audio.set_insert_on(inst.source_id, slot, on)
	inst.inserts = audio.get_inserts(inst.source_id)


## An insert's plug-in window, floating over the room. Not in automated runs, which have no windows to show it in.
func show_insert_editor(inst, slot: int, show: bool) -> bool:
	if show and DisplayServer.get_name() == "headless":
		return false
	var insert: Dictionary = inst.inserts[slot] if slot < inst.inserts.size() else {}
	var shown := audio.show_insert_editor(inst.source_id, slot, show, "%s  ·  %s insert %s" % [insert.get("plugin_name", ""),
		inst.display_name, char(65 + slot)])
	inst.inserts = audio.get_inserts(inst.source_id)
	return shown


func hide_insert_editors(inst) -> void:
	for i in inst.inserts.size():
		if inst.inserts[i].editor_open:
			show_insert_editor(inst, i, false)


func hide_plugin_editors(inst) -> void:
	for i in inst.pedals.size():
		if inst.pedals[i].kind == "plugin" and inst.pedals[i].editor_open:
			show_plugin_editor(inst, i, false)


## Option-clicked, as Pro Tools' all-tracks modifier: every track's input ("input"), mute, solo or record arm ("arm")
## set as the one clicked now is.
func set_on_all(what: String, on: bool) -> void:
	if what in ["mute", "solo"]:
		for folder in folders + auxes:
			if what == "mute":
				folder.muted = on
			else:
				folder.soloed = on
	for inst in instruments:
		match what:
			"input":
				if inst.input_on != on:
					set_input(inst, on)
			"mute":
				inst.muted = on
			"solo":
				inst.soloed = on
			"arm":
				timeline.set_armed(inst, on)
	_apply_channels()


func set_muted(inst, on: bool) -> void:
	var changed: bool = inst.muted != on
	inst.muted = on
	_apply_channels()
	if changed and automation != null:
		automation.mute_pressed(inst)  # (written, in Touch, Latch or Write while it plays)


func set_soloed(inst, on: bool) -> void:
	inst.soloed = on
	_apply_channels()


## Mute and solo, as Pro Tools has them, folders too: a folder muted silences what is in it (folders in it too), a
## folder soloed solos them; and whatever is soloed is heard all the way to the master: through the folders it is in,
## and the aux tracks it sends to (and the folders they are in).
func _apply_channels() -> void:
	var every := instruments + folders + auxes
	var any_solo: bool = every.any(func(t): return t.soloed)
	var heard := {}
	if any_solo:
		for track in every:
			if track.soloed or folders_around(track).any(func(f): return f.soloed):
				_heard_from(track, heard)
	silenced = {}
	for track in every:  # (a solo elsewhere takes an instrument out of the mix, not out of the room: its mics still hear it)
		var muted_here: bool = track.muted or folders_around(track).any(func(f): return f.muted)
		var solo_muted: bool = any_solo and not heard.has(track)
		if muted_here or solo_muted:
			silenced[track] = true
		if track.is_folder:
			audio.set_source_muted(track.source_id, muted_here or solo_muted)
		else:
			track.set_channel(track.muted, track.soloed, muted_here, solo_muted)


## A track heard, and everything its sound goes through on the way to the master.
func _heard_from(track, heard: Dictionary) -> void:
	if heard.has(track):
		return
	heard[track] = true
	var folder = folder_of(track)
	if folder != null:
		_heard_from(folder, heard)
	for send in track.sends:
		if not send.is_empty():
			_heard_from(send.aux, heard)


# ── Tracks and folders ──────────────────────────────────────────────────────────────────────────────────────

## Colours a track can be given, as Pro Tools' palette: [name, colour].
const TRACK_COLORS := [["Red", Color(0.92, 0.26, 0.24)], ["Orange", Color(1.0, 0.52, 0.22)], ["Amber", Color(1.0, 0.7, 0.24)],
	["Yellow", Color(0.98, 0.88, 0.3)], ["Lime", Color(0.66, 0.88, 0.3)], ["Green", Color(0.32, 0.8, 0.42)], ["Teal", Color(0.25, 0.8, 0.72)],
	["Cyan", Color(0.3, 0.78, 0.95)], ["Blue", Color(0.38, 0.55, 1.0)], ["Indigo", Color(0.5, 0.45, 0.95)], ["Violet", Color(0.66, 0.4, 0.95)],
	["Magenta", Color(0.9, 0.38, 0.85)], ["Pink", Color(1.0, 0.5, 0.7)], ["Brown", Color(0.66, 0.46, 0.32)], ["Grey", Color(0.66, 0.68, 0.74)],
	["White", Color(0.92, 0.93, 0.96)]]


func has_track(track) -> bool:
	return instruments.has(track) or folders.has(track) or auxes.has(track)


## Every track in order, as the edit and mix windows show them: each folder just before what is in it (in its order,
## folders in it with theirs), the aux tracks not in a folder at the end.
func track_order() -> Array:
	var top := []
	for track in instruments + folders + auxes:
		var outermost = track
		while folder_of(outermost) != null:
			outermost = folder_of(outermost)
		if not top.has(outermost):
			top.append(outermost)
	var out := []
	for track in top:
		_with_members(track, out)
	return out


func _with_members(track, out: Array) -> void:
	out.append(track)
	if track.is_folder and not track.is_aux:
		for member in track.members:
			_with_members(member, out)


## The folder a track is in (an instrument's, a folder's, an aux's), or null.
func folder_of(track):
	for folder in folders:
		if folder.members.has(track):
			return folder
	return null


## The folders a track is in, the nearest first.
func folders_around(track) -> Array:
	var out := []
	var folder = folder_of(track)
	while folder != null and not out.has(folder):
		out.append(folder)
		folder = folder_of(folder)
	return out


## Whether a track's sound reaches another's on its way to the master: through the folder it is in (and theirs), or
## its sends (and where those auxes go).
func routes_to(from, to) -> bool:
	var seen := {}
	var waiting := [from]
	while not waiting.is_empty():
		var track = waiting.pop_back()
		if track == to:
			return true
		if track == null or seen.has(track):
			continue
		seen[track] = true
		waiting.append(folder_of(track))
		for send in track.sends:
			if not send.is_empty():
				waiting.append(send.aux)
	return false


## Whether a track can go in a folder (null: straight to the master): not into itself, nor into a folder its own sound
## reaches it through (that would go round in a circle).
func can_put_in(track, folder) -> bool:
	return folder == null or (folder.is_folder and not folder.is_aux and folder != track and not routes_to(folder, track))


## Whether a track can send to an aux: not to one its sound already comes back to it from.
func can_send(track, aux) -> bool:
	return aux != null and aux != track and not routes_to(aux, track)


## A new routing folder (Cmd-G), with these tracks in it (instruments, folders, auxes): its bus in the audio core, its
## tracks playing into it rather than the master; in `parent`, if given. Null if the room's channels are all in use.
func add_folder(members: Array, the_name := "", parent = null):
	var id: int = audio.add_source("bus", Vector3.ZERO, 1.0, 0.0)
	if id < 0:
		return null
	var folder := Folder.new()
	folder.source_id = id
	folder.display_name = the_name if the_name != "" else _folder_name()
	folder.inserts = audio.get_inserts(id)
	folders.append(folder)
	if parent != null:
		put_in_folder(folder, parent, members.front() if not members.is_empty() and parent.members.has(members.front()) else null, true)
	for track in members:
		put_in_folder(track, folder)
	_apply_channels()
	return folder


## "Folder 1", "Folder 2"...: the first not taken.
func _folder_name() -> String:
	var number := 1
	while folders.any(func(folder): return folder.display_name == "Folder %d" % number):
		number += 1
	return "Folder %d" % number


## Puts a track in a folder (null: out of any, to the master), as assigning its output to the folder's bus does in Pro
## Tools: an instrument's track, an aux track, or another folder with all that is in it. It goes after the folder's
## last track (or after `after`, one of them; with `before`, just before it). Returns false (and nothing changes) where
## it can't go: into itself, or into a folder that its own sound reaches (a folder in it, an aux it sends to...).
func put_in_folder(track, folder, after = null, before := false) -> bool:
	if not can_put_in(track, folder):
		return false
	var was = folder_of(track)
	if was != null:
		was.members.erase(track)
	if folder != null:
		var at: int = folder.members.size()
		if after != null and folder.members.has(after):
			at = folder.members.find(after) + (0 if before else 1)
		folder.members.insert(at, track)
		if track is Node and not was == folder:  # an instrument: next to the folder's others in the room's list too
			var next_to = null
			for member in folder.members:
				if member != track and instruments.has(member):
					next_to = member
			if next_to != null:
				instruments.erase(track)
				instruments.insert(instruments.find(next_to) + 1, track)
	audio.set_source_output(track.source_id, folder.source_id if folder != null else -1)
	_apply_channels()
	return true


## Takes a folder away: what is in it goes to the folder it was in (or straight to the master).
func remove_folder(folder) -> void:
	if not folders.has(folder):
		return
	var parent = folder_of(folder)
	for track in folder.members.duplicate():
		folder.members.erase(track)
		put_in_folder(track, parent, folder, true)
	if parent != null:
		parent.members.erase(folder)
	hide_insert_editors(folder)
	folders.erase(folder)
	chosen_tracks.erase(folder)
	audio.remove_source(folder.source_id)
	_apply_channels()


func set_folder_level(folder, db: float) -> void:
	folder.level_db = clampf(db, -80.0, 12.0)
	audio.set_source_gain(folder.source_id, 0.0 if folder.level_db <= -79.0 else db_to_linear(folder.level_db))


## A new aux track, as Pro Tools' aux input: a bus that the tracks' sends play into (a reverb or a delay on its
## inserts, say), and from there through its fader to the master. Null if the room's channels are all in use.
func add_aux(the_name := ""):
	var id: int = audio.add_source("bus", Vector3.ZERO, 1.0, 0.0)
	if id < 0:
		return null
	var aux := Folder.new()
	aux.is_aux = true
	aux.source_id = id
	aux.color = TRACK_COLORS[7][1]
	aux.inserts = audio.get_inserts(id)
	var number := 1
	while auxes.any(func(other): return other.display_name == "Aux %d" % number):
		number += 1
	aux.display_name = the_name if the_name != "" else "Aux %d" % number
	auxes.append(aux)
	_apply_channels()
	return aux


## Takes an aux track away, and the sends to it.
func remove_aux(aux) -> void:
	if not auxes.has(aux):
		return
	for track in instruments + folders + auxes:
		for slot in track.sends.size():
			if track.sends[slot].get("aux") == aux:
				set_send(track, slot, null)
	if folder_of(aux) != null:
		folder_of(aux).members.erase(aux)
	hide_insert_editors(aux)
	auxes.erase(aux)
	chosen_tracks.erase(aux)
	audio.remove_source(aux.source_id)
	_apply_channels()


## A track's send (A to E), as Pro Tools': to an aux track (null takes it away), at a level in dB, after its fader
## (the track as heard in the room; a folder's or an aux's, what leaves its fader) or `pre` before it (its own sound,
## straight), on or off. A folder and an aux have sends too. Returns false (nothing changes) for an aux whose sound
## comes back to the track (one in it, if it is a folder; one sending to it...).
func set_send(inst, slot: int, aux, level_db := 0.0, pre := false, on := true) -> bool:
	if aux != null and not can_send(inst, aux):
		return false
	inst.sends[slot] = {} if aux == null else {"aux": aux, "level_db": clampf(level_db, -80.0, 12.0), "pre": pre, "on": on}
	_send_send(inst, slot)
	_apply_channels()
	return true


func set_send_level(inst, slot: int, db: float) -> void:
	if not inst.sends[slot].is_empty():
		inst.sends[slot].level_db = clampf(db, -80.0, 12.0)
		_send_send(inst, slot)


func _send_send(inst, slot: int) -> void:
	var send: Dictionary = inst.sends[slot]
	if send.is_empty():
		audio.set_send(inst.source_id, slot, -1, 0.0, false, false)
		return
	var db := float(send.level_db)
	var gain: float = 0.0 if db <= -79.0 else db_to_linear(db) * (inst.normal_gain() if send.pre else 1.0)  # (before the fader: as at 0 dB)
	audio.set_send(inst.source_id, slot, send.aux.source_id, gain, send.pre, send.on)


## The master fader at a gain, as its automation has it (stopped, at the playhead), without moving the fader.
func apply_master_gain(gain: float) -> void:
	audio.set_master_volume(gain * _stage_gain)


## Cmd-G: the tracks chosen, in a new folder: instruments' tracks, aux tracks and folders (with all that is in them),
## in their order. The new folder goes where the first of them was (in the folder it was in, if any).
func group_chosen() -> void:
	var tracks: Array = track_order().filter(func(t): return chosen_tracks.has(t) and not folders_around(t).any(func(f): return chosen_tracks.has(f)))
	if tracks.is_empty():
		session.notice.emit("Choose the tracks for a folder first: click their names (Shift or Cmd-click for more), then %s" % bindings.label("group"))
		return
	var parent = folder_of(tracks.front())
	while parent != null and tracks.has(parent):
		parent = folder_of(parent)
	var folder = add_folder(tracks, "", parent)
	if folder == null:
		session.notice.emit("There's no room for another folder")
		return
	chosen_tracks = [folder]
	session.notice.emit("%s, with %d track%s" % [folder.display_name, tracks.size(), "" if tracks.size() == 1 else "s"])


## Choosing tracks by their names, as Pro Tools does: "only" this one, "toggle" (Cmd-click) one more or one fewer,
## "range" (Shift-click) every one from the last chosen to this.
func choose_track(track, how := "only") -> void:
	match how:
		"toggle":
			if chosen_tracks.has(track):
				chosen_tracks.erase(track)
			else:
				chosen_tracks.append(track)
		"range":
			var order := track_order()
			var from: int = order.find(chosen_tracks.back()) if not chosen_tracks.is_empty() else order.find(track)
			var to: int = order.find(track)
			for i in range(mini(from, to), maxi(from, to) + 1):
				if not chosen_tracks.has(order[i]):
					chosen_tracks.append(order[i])
		_:
			chosen_tracks = [track]


## A track's name (an instrument's in the room too), given it: kept from then on.
func rename_track(track, new_name: String) -> void:
	new_name = new_name.strip_edges()
	if new_name == "":
		return
	if track.is_folder:
		track.display_name = new_name
	else:
		track.named = true
		track.set_display_name(new_name)


func set_track_color(track, color: Color) -> void:
	if track.is_folder:
		track.color = color
	else:
		track.set_color(color)


## Renaming a track, in the name prompt.
func ask_track_name(track) -> void:
	name_prompt.ask("Rename the %s" % ("folder" if track.is_folder else "track"), track.display_name,
		func(new_name: String) -> void: rename_track(track, new_name))


## Which hardware input a live-input instrument plays (-1 = all of them).
func set_input_channel(inst, channel: int) -> void:
	inst.set_input_channel(channel)
	if inst == speaker:
		settings.speaker_input = channel
		settings.save_to_disk()


## How many inputs there are to choose from: what is open, or what the chosen input device says it has.
func input_channel_count() -> int:
	if live_input:
		var open_inputs := int(audio.get_stats().get("input_channels", 0))
		if open_inputs > 0:
			return open_inputs
	for device in audio.get_input_devices():
		if device.name == settings.input_device or (settings.input_device == "" and device.is_default):
			return device.channels
	return 0


func set_midi_device_enabled(device_name: String, on: bool) -> void:
	audio.set_midi_device_enabled(device_name, on)
	settings.midi_disabled.erase(device_name)
	if not on:
		settings.midi_disabled.append(device_name)
	settings.save_to_disk()


# ── Tempo and the metronome ─────────────────────────────────────────────────────────────────────────────────

func set_tempo(bpm: float) -> void:
	tempo = clampf(bpm, 40.0, 240.0)
	audio.set_tempo(tempo)


func set_swing(amount: float) -> void:
	swing = clampf(amount, 0.0, 0.6)
	audio.set_swing(swing)


## Starts or stops every instrument's pattern. Starting begins again from the first beat.
func set_sequence_running(on: bool) -> void:
	if timeline.is_record():  # the timeline's transport
		if on != timeline.playing:
			timeline.toggle_play()
		return
	sequence_running = on
	audio.set_sequencer_running(on)


## Space: in a Jam room, the patterns stopped or started again from the top; in a Record room, the timeline played from
## the playhead or stopped.
func toggle_transport() -> void:
	if timeline.is_record():
		timeline.toggle_play()
	else:
		set_sequence_running(not sequence_running)


## Option-L, in a Record room: Loop Record, as Pro Tools has it: recording from a stop goes round the loop from its
## start, a take each time round.
func toggle_loop_record() -> void:
	settings.loop_record = not settings.loop_record
	settings.save_to_disk()
	session.notice.emit("Loop Record: recording goes round the loop, a take each time" if settings.loop_record else "Loop Record off")


## N, in a Record room: whether stopping leaves the playhead where the music stopped, or takes it back to where it
## started (Pro Tools' Insertion Follows Playback).
func toggle_follow() -> void:
	settings.insertion_follows = not settings.insertion_follows
	settings.save_to_disk()
	session.notice.emit("Insertion follows playback" if settings.insertion_follows else "Insertion doesn't follow playback: stopping goes back to where it started")


## Cmd-Space: recording, in a Record room.
func toggle_record() -> void:
	var problem: String = timeline.toggle_record()
	if problem != "":
		session.notice.emit("Can't record: %s" % problem)


func set_click(on: bool) -> void:
	settings.click = on
	audio.set_click(on)
	settings.save_to_disk()


func set_click_volume_db(db: float) -> void:
	settings.click_volume_db = db
	audio.set_click_volume(db_to_linear(db))
	settings.save_to_disk()


# ── The title screen ────────────────────────────────────────────────────────────────────────────────────────

## Where the room is being heard from: the player's ears, or the title screen's camera.
func listener_position() -> Vector3:
	return title.camera.global_position if title != null and title.is_open() else player.ear_position()


## Back to the title screen. The room carries on as it is.
func show_title() -> void:
	for panel in [menu, sequencer, mixer, amp_panel, speaker_panel, mic_panel, instrument_menu, edit_window]:
		if panel.is_open():
			panel.close()
	player.stop_playing()
	player.put_down()
	title.open()


# ── Instruments ─────────────────────────────────────────────────────────────────────────────────────────────

## Puts a new instrument of this kind in the room and returns it, or null if the room is full. Unless
## `with_default_pattern`, a MIDI instrument starts with nothing to loop.
func add_instrument(kind: String, at: Vector3, with_default_pattern := false):
	var spec: Dictionary = Catalog.KINDS[kind].duplicate()
	var same_kind := 0
	var names := []
	for other in instruments:
		names.append(other.display_name)
		if other.kind == kind:
			same_kind += 1
	var base_name: String = spec.name
	var number := 2
	while names.has(spec.name):  # Drums, Drums 2, Drums 3...
		spec.name = "%s %d" % [base_name, number]
		number += 1
	spec.color = spec.color.lightened(minf(0.2 * same_kind, 0.5))  # each further one a paler tint, to tell them apart
	spec.kind = kind
	spec.position = at
	var inst := Instrument.new()
	add_child(inst)
	inst.setup(spec, audio)
	if inst.source_id < 0:
		inst.queue_free()
		return null
	instruments.append(inst)
	if with_default_pattern and inst.playable:
		audio.load_default_pattern(inst.source_id)
	return inst


## The room the game starts with (the "Default room" template): its size and wall, the instruments playing the
## default groove, all facing where you come in, and the tempo. `empty`: the same room bare ("Empty room").
func load_default_room(empty := false) -> void:
	library.apply_room_data(library.default_room_data(empty))


## Takes everything out of the room, ready for another: its instruments go, with their windows.
func clear_room() -> void:
	player.stop_playing()
	player.put_down()
	for inst in instruments.duplicate():
		remove_instrument(inst)
	for folder in folders.duplicate():
		remove_folder(folder)
	for aux in auxes.duplicate():
		remove_aux(aux)
	master_track.automation = {}
	master_track.auto_mode = "read"
	master_track.lanes = ["volume"]


## A room has just been filled (the default one, or a template's): mute and solo take effect, the Speaker whose input
## is remembered is the first one, everything is settled inside the room, and the patterns start together from the top.
func settle_new_room() -> void:
	_apply_channels()
	speaker = null
	for inst in instruments:
		if inst.kind == "live":
			speaker = inst
			break
	_on_room_changed()
	if title != null and title.is_open():  # its names would drift behind the title's words
		for inst in instruments:
			inst.set_label_visible(false)


## A second of an instrument, as Pro Tools duplicates a track: the same kind, with its fader, mute and pattern, a
## Speaker's volume, an amp's head, cabinet, knobs and pedals, and the plug-ins on its inserts and pedals with their
## settings. Its input starts off, as every input does, and a loop pedal comes without its loop. It stands at `at`, or
## beside the original, and its strip follows the original's. Null if the room is full; anything that couldn't be
## copied is in `copy_problem`.
func duplicate_instrument(inst, at = null):
	copy_problem = ""
	var copy = add_instrument(inst.kind, at if at != null else _spot_beside(inst))
	if copy == null:
		return null
	instruments.erase(copy)
	instruments.insert(instruments.find(inst) + 1, copy)
	copy.set_color(inst.color)
	if folder_of(inst) != null:  # in the same folder, just after it
		put_in_folder(copy, folder_of(inst), inst)
	for slot in inst.sends.size():  # its sends, to the same auxes
		if not inst.sends[slot].is_empty():
			set_send(copy, slot, inst.sends[slot].aux, inst.sends[slot].level_db, inst.sends[slot].pre, inst.sends[slot].on)
	var problems := []
	if inst.plays_plugin and str(inst.instrument_plugin.get("plugin_id", "")) != "":
		var problem := set_instrument_plugin(copy, inst.instrument_plugin.plugin_id, audio.get_plugin_state(inst.source_id, "instrument", 0))
		if problem != "":
			problems.append("its plug-in: %s" % problem)
	copy.rotation.y = inst.rotation.y
	set_instrument_level(copy, inst.level_db)
	set_muted(copy, inst.muted)
	copy.clips = inst.clips.duplicate(true)
	timeline.sync(copy)
	if inst.playable:
		audio.set_pattern_steps(copy.source_id, audio.get_pattern_steps(inst.source_id))
		audio.set_pattern(copy.source_id, audio.get_pattern(inst.source_id))
		copy.set_loop(inst.loop_on)
	elif inst.is_mic:  # as high, as tilted, as loud, the same model (a stereo mic set up the same way), as panned
		set_mic_height(copy, inst.source_height)
		set_mic_tilt(copy, inst.mic_tilt)
		set_mic_gain(copy, inst.mic_gain_db)
		if inst.is_stereo_mic:
			copy.mic_model = inst.mic_model
			copy.mic_pattern = inst.mic_pattern
			copy.set_pair(inst.pair_technique, inst.pair_spacing, inst.side_model, inst.ms_width)
		else:
			copy.set_mic_model(inst.mic_model, inst.mic_pattern)
		set_mic_pan(copy, inst.mic_pan)
	else:
		set_input_channel(copy, inst.input_channel)
		set_speaker_volume(copy, inst.volume_db)
	if inst.is_amp:
		set_amp_voice(copy, inst.amp_head, inst.head_on, inst.amp_cabinet, inst.cabinet_on)
		for control in inst.amp_controls:
			set_amp_control(copy, control, inst.amp_controls[control])
		for i in audio.get_pedals(inst.source_id).size():
			if copy_pedal(inst, i, copy) < 0:
				problems.append("pedal %d: %s" % [i + 1, audio.get_error()])
	var inserts: Array = audio.get_inserts(inst.source_id)
	for slot in inserts.size():
		if inserts[slot].plugin_name != "":
			var problem := copy_insert(inst, slot, copy, slot)
			if problem != "":
				problems.append("insert %s: %s" % [char(65 + slot), problem])
	copy.automation = inst.automation.duplicate(true)  # its automation, all of it
	copy.lanes = inst.lanes.duplicate()
	copy.auto_mode = inst.auto_mode
	timeline.sync(copy)
	copy_problem = "; ".join(problems)
	return copy


## Somewhere on the floor beside an instrument, clear of the others if there is room: for a copy of it.
func _spot_beside(inst) -> Vector3:
	var side: Vector3 = inst.global_transform.basis.x.normalized()
	var step: float = maxf(inst.footprint.x, 0.6) + 0.5
	for offset in [step, -step, 2.0 * step, -2.0 * step]:
		var at: Vector3 = room.settle(inst.global_position + side * offset, 0.6, 0.5, inst.global_position)
		var clear := instruments.all(func(other) -> bool:
			return Vector2(other.global_position.x - at.x, other.global_position.z - at.z).length() > 0.9)
		if clear:
			return at
	return room.settle(inst.global_position + side * step, 0.6, 0.5, inst.global_position)


func remove_instrument(inst) -> void:
	if not instruments.has(inst):
		return
	if sequencer.is_open() and sequencer.inst == inst:
		sequencer.close()
	if amp_panel.is_open() and amp_panel.inst == inst:
		amp_panel.close()
	if speaker_panel.is_open() and speaker_panel.inst == inst:
		speaker_panel.close()
	if mic_panel.is_open() and mic_panel.inst == inst:
		mic_panel.close()
	player.forget(inst)
	var folder = folder_of(inst)
	if folder != null:
		folder.members.erase(inst)
	chosen_tracks.erase(inst)
	instruments.erase(inst)
	if inst == speaker:
		speaker = null
	hide_plugin_editors(inst)
	hide_insert_editors(inst)
	if inst.plays_plugin:
		show_instrument_editor(inst, false)
	audio.remove_source(inst.source_id)  # fades out over a few milliseconds
	inst.queue_free()
	_apply_channels()  # it may have been the one soloed
	if not inst.playable:
		follow_live_inputs()


func find_instrument(kind: String):
	for inst in instruments:
		if inst.kind == kind:
			return inst
	return null


# ── Sound, display, controls ────────────────────────────────────────────────────────────────────────────────

func set_binaural(on: bool) -> void:
	settings.binaural = on
	audio.set_binaural(on)
	settings.save_to_disk()


## The room reverb's fader (in the mix window, beside the master), in decibels: 0 is as the room has it, -80 none.
## It belongs to the room, as an effects return does to a session.
func set_reverb_db(db: float) -> void:
	reverb_db = clampf(db, -80.0, 12.0)
	audio.set_reverb_level(0.0 if reverb_db <= -79.0 else db_to_linear(reverb_db))


## The master fader, in decibels. It belongs to the room (saved with it), as a session's master fader does.
func set_master_volume_db(db: float) -> void:
	master_volume_db = clampf(db, -80.0, 12.0)
	_apply_master_volume()


## A Speaker's own volume (its panel), in decibels: after its inserts, before its fader. -80 is off.
# ── Microphones ─────────────────────────────────────────────────────────────────────────────────────────────

## A microphone's place: where it stands on the floor (x and z, metres from the middle of the room, kept inside it),
## its capsule's height, which way it points (its bearing, degrees clockwise from north, the way you first face, and
## how far down), and its gain (dB, before it records). A stereo mic's are its stand's (between its two) and the way
## the two point between them.
func set_mic_spot(mic, x: float, z: float) -> void:
	var half: Vector3 = room.size / 2.0
	mic.global_position = Vector3(clampf(x, -half.x + 0.05, half.x - 0.05), mic.source_height, clampf(z, -half.z + 0.05, half.z - 0.05))
	mic.sync_position()


func set_mic_height(mic, height: float) -> void:
	mic.set_mic_height(clampf(height, 0.05, room.size.y - 0.05))


func set_mic_bearing(mic, degrees: float) -> void:
	mic.rotation.y = PI - deg_to_rad(fposmod(degrees, 360.0))


func mic_bearing(mic) -> float:
	return fposmod(rad_to_deg(PI - mic.rotation.y), 360.0)


func set_mic_tilt(mic, degrees: float) -> void:
	mic.set_mic_tilt(degrees)


func set_mic_gain(mic, db: float) -> void:
	mic.set_mic_gain(db)


## Points a microphone (a stereo mic, between its two) at an instrument: at where its sound comes from.
func aim_mic(mic, at) -> void:
	var to: Vector3 = at.global_position - mic.global_position
	if Vector2(to.x, to.z).length() > 0.001:
		mic.rotation.y = atan2(to.x, to.z)
	mic.set_mic_tilt(rad_to_deg(atan2(-to.y, Vector2(to.x, to.z).length())))


## The instrument nearest a microphone (another microphone never), or null.
func nearest_instrument(mic):
	var best = null
	for inst in instruments:
		if inst != mic and not inst.is_mic and (best == null or inst.global_position.distance_to(mic.global_position) < best.global_position.distance_to(mic.global_position)):
			best = inst
	return best


## A microphone's model (microphones.h's: get_mic_models lists them) and its pattern ("" for the model's own); one not
## given a name takes its model's. A stereo mic's two take it alike (a mid-side pair's mid only: its side stays a
## figure-8); the patterns of a pair set up some other way are its setup's.
func set_mic_model(mic, model: String, pattern := "") -> void:
	var info := mic_model_info(model)
	if info.is_empty():
		return
	if mic.is_stereo_mic and not Catalog.MIC_PAIRS.get(mic.pair_technique, {}).get("mid_side", false):
		pattern = Catalog.MIC_PAIRS.get(mic.pair_technique, Catalog.MIC_PAIRS.xy).patterns[0]
	if pattern != "" and not info.patterns.any(func(p): return p.name == pattern):
		if mic.is_stereo_mic:
			return  # (it hasn't the pattern its setup wants)
		pattern = ""
	mic.set_mic_model(model, pattern)
	if not mic.named and not mic.is_stereo_mic:
		for kind in Catalog.KINDS:
			if Catalog.KINDS[kind].get("model", "") == model and not Catalog.KINDS[kind].get("stereo", false):
				mic.set_display_name(unique_name(Catalog.KINDS[kind].name, mic))


## Where a microphone's track sits in the stereo (-1 left, 1 right); a stereo mic's, its balance.
func set_mic_pan(mic, pan: float) -> void:
	mic.set_mic_pan(pan)


## The models there are, as the audio core has them (asked for once): [{id, name, about, sensitivity_db, noise_db, patterns}].
func mic_models() -> Array:
	if _mic_models == null:
		_mic_models = audio.get_mic_models()
	return _mic_models


func mic_model_info(model: String) -> Dictionary:
	for info in mic_models():
		if info.id == model:
			return info
	return {}


## The pattern a microphone has now: its own choice, or its model's own.
func mic_pattern_of(mic) -> String:
	var info := mic_model_info(mic.mic_model)
	if info.is_empty():
		return "omni"
	return mic.mic_pattern if mic.mic_pattern != "" else str(info.patterns[0].name)


# ── Stereo mics ─────────────────────────────────────────────────────────────────────────────────────────────

## How a stereo mic is set up: its technique (catalog.gd's MIC_PAIRS), and (a spaced pair) how far apart its two are.
## The two take the patterns it wants (a model that has them, if theirs hasn't: pencils for the cardioids and omnis,
## ribbons for figure-8s; a mid-side pair's side, the large condenser's figure-8). Its track is in the middle.
func set_pair_technique(mic, technique: String, spacing := -1.0) -> void:
	if not mic.is_stereo_mic or not Catalog.MIC_PAIRS.has(technique):
		return
	var spec: Dictionary = Catalog.MIC_PAIRS[technique]
	var pattern: String = spec.patterns[0]
	var model: String = mic.mic_model
	if not mic_model_info(model).get("patterns", []).any(func(p): return p.name == pattern):
		model = "ribbon" if pattern == "figure8" else "pencil"
	mic.mic_model = model
	mic.mic_pattern = pattern
	mic.set_pair(technique, clampf(spacing, 0.0, 3.0) if spacing >= 0.0 else float(spec.spacing), "condenser", mic.ms_width)


func set_pair_spacing(mic, metres: float) -> void:
	set_pair_technique(mic, mic.pair_technique, metres)


## A mid-side pair's width: how much of its side is decoded into the left and right (0 mono, 1 as it hears it, 2 wider).
func set_mic_width(mic, width: float) -> void:
	mic.set_ms_width(width)


func set_speaker_volume(inst, db: float) -> void:
	inst.volume_db = clampf(db, -80.0, SpeakerPanel.MAX_DB)
	audio.set_source_volume(inst.source_id, 0.0 if inst.volume_db <= -79.0 else db_to_linear(inst.volume_db))


## An instrument's fader, in decibels above or below its normal level.
func set_instrument_level(inst, db: float) -> void:
	inst.set_level_db(clampf(db, -80.0, 12.0))  # -80: the bottom of the fader, silence


## How much quieter an instrument gets for each doubling of distance beyond a metre and a half, in decibels.
func set_distance_falloff(db: float) -> void:
	settings.distance_falloff_db = clampf(db, 0.0, 6.0)
	audio.set_distance_falloff(settings.distance_falloff_db)
	settings.save_to_disk()


func set_limiter(on: bool) -> void:
	settings.limiter = on
	audio.set_limiter(on)
	settings.save_to_disk()


## A level on top of the master volume, for the title screen to hold the music back and bring it up on entering.
func set_stage_gain(gain: float) -> void:
	_stage_gain = gain
	_apply_master_volume()


func _apply_master_volume() -> void:
	audio.set_master_volume((0.0 if master_volume_db <= -79.0 else db_to_linear(master_volume_db)) * _stage_gain)


func set_text_scale(scale_factor: float) -> void:
	settings.text_scale = scale_factor
	_apply_display()
	settings.save_to_disk()


func set_fov(degrees: float) -> void:
	settings.fov = degrees
	_apply_display()
	settings.save_to_disk()


func set_mouse_sensitivity(multiplier: float) -> void:
	settings.mouse_sensitivity = multiplier
	settings.save_to_disk()


func set_show_meter(on: bool) -> void:
	settings.show_meter = on
	settings.save_to_disk()


func set_room_brightness(value: float) -> void:
	settings.room_brightness = clampf(value, 0.5, 3.0)
	_apply_lighting()
	settings.save_to_disk()


## The light that doesn't come from the instruments: the room's own lamps, the glow in the air, and how soon the
## far walls fade into the dark (not at all sooner in a big room than in the default one).
func _apply_lighting() -> void:
	if room == null or _environment == null:
		return
	room.set_brightness(settings.room_brightness)
	_environment.ambient_light_energy = 0.35 * settings.room_brightness
	var default_span := Vector2(Room.DEFAULT_SIZE.x, Room.DEFAULT_SIZE.z).length()
	_environment.fog_density = 0.02 * minf(1.0, default_span / Vector2(room.size.x, room.size.z).length())


func set_show_stats(on: bool) -> void:
	settings.show_stats = on
	settings.save_to_disk()


func set_fullscreen(on: bool) -> void:
	settings.fullscreen = on
	_apply_display()
	settings.save_to_disk()


func _apply_display() -> void:
	get_window().content_scale_factor = settings.text_scale
	if player:
		player.camera.fov = settings.fov
	if not options.has("silent"):  # automated runs keep their window as it is
		var mode := Window.MODE_FULLSCREEN if settings.fullscreen else Window.MODE_WINDOWED
		if get_window().mode != mode and not (mode == Window.MODE_WINDOWED and get_window().mode == Window.MODE_MAXIMIZED):
			get_window().mode = mode


# ── Setup ───────────────────────────────────────────────────────────────────────────────────────────────────

func _parse_options() -> void:
	for arg in OS.get_cmdline_user_args():
		var a: String = arg.trim_prefix("--")
		var eq := a.find("=")
		if eq >= 0:
			options[a.substr(0, eq)] = a.substr(eq + 1)
		else:
			options[a] = ""


## Stands the player in front of an instrument, facing it (for the --play and --sequencer options).
func _sit_at(kind: String) -> void:
	var inst = find_instrument(kind)
	var from: Vector3 = inst.position + Vector3(0.0, 0.0, 1.8)
	player.place(Vector3(from.x, 0.0, from.z), 0.0)


func _print_stats() -> void:
	var s := audio.get_stats()
	print("SoundRoom stats: device=%s backend=%s rate=%s block=%s device_period=%s buffer=%.2fms device=%.2fms binaural=%.2fms output=%.2fms cpu=%.1f%% blocks=%s" % [
		s.get("output_device", "?"), s.get("backend", "?"), s.get("sample_rate", 0), s.get("block_size", 0),
		s.get("device_period", 0), s.get("buffer_ms", 0.0), s.get("device_ms", 0.0), s.get("binaural_ms", 0.0), s.get("output_latency_ms", 0.0),
		100.0 * s.get("cpu_load", 0.0), s.get("blocks", 0)])
	var levels := []
	for inst in instruments:
		levels.append("%s=%.3f%s" % [inst.kind, audio.get_source_level(inst.source_id),
			" (behind wall)" if audio.is_source_blocked(inst.source_id) else ""])
	print("SoundRoom sources: ", ", ".join(levels))
	print("SoundRoom midi: ", audio.get_midi_devices(), " live_input=", s.get("live_input", false))
	var patterns := []
	for inst in instruments:
		if inst.playable:
			patterns.append("%s=%d notes/%d steps%s" % [inst.kind, audio.get_pattern(inst.source_id).size(),
				audio.get_pattern_steps(inst.source_id), "" if inst.loop_on else " (loop off)"])
	print("SoundRoom room: ", room.size, " walls=", room.walls.size(), " reverb=%.2fs" % audio.get_room_decay())
	print("SoundRoom transport: ", audio.get_transport(), " playing=",
		player.playing.kind if player.playing != null else "nothing", " patterns: ", ", ".join(patterns))


func _build_environment() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.02, 0.022, 0.03)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.55, 0.58, 0.7)
	env.ambient_light_energy = 0.35
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.glow_enabled = true
	env.glow_intensity = 0.6
	env.glow_bloom = 0.05
	env.fog_enabled = true
	env.fog_light_color = Color(0.03, 0.035, 0.05)
	env.fog_density = 0.02
	var world_env := WorldEnvironment.new()
	world_env.environment = env
	add_child(world_env)
	_environment = env
