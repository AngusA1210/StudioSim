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
const Player := preload("res://scripts/player.gd")
const Hud := preload("res://scripts/hud.gd")
const Menu := preload("res://scripts/menu.gd")
const Sequencer := preload("res://scripts/sequencer.gd")
const InstrumentMenu := preload("res://scripts/instrument_menu.gd")
const Mixer := preload("res://scripts/mixer.gd")
const AmpPanel := preload("res://scripts/amp_panel.gd")
const PluginBrowser := preload("res://scripts/plugin_browser.gd")
const SpeakerPanel := preload("res://scripts/speaker_panel.gd")
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
var bindings  # the keys, as set on the Controls page
var library  # rooms' and templates' contents, presets, and settings copied to be pasted
var session  # the room that is open: its file, saving, backups
var rooms_page  # making a new room, or opening one
var timeline  # the room's mode, and a Record room's transport, recording and clips
var edit_window  # a Record room's tracks and clips along the timeline
var name_prompt  # asks for a name, to save a template or a preset under
var _plugins = null  # what get_plugins() said, the first time anything asked
var _instrument_plugins = null  # and get_instrument_plugins()
var instrument_menu
var title  # the title screen
var room  # its size and the walls inside it
var instruments: Array = []
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


## Cmd-S (Ctrl-S) saves the room, from anywhere but a box being typed in.
func _input(event: InputEvent) -> void:
	if not (event is InputEventKey and event.pressed and not event.echo) or name_prompt.is_open() or rooms_page.is_open():
		return
	if get_viewport().gui_get_focus_owner() is LineEdit:  # being typed in (the edit window's counter, say)
		return
	var command: bool = event.meta_pressed or event.ctrl_pressed
	if event.physical_keycode == KEY_S and command and not session.is_asking():
		session.save_or_ask()
		get_viewport().set_input_as_handled()
		return
	if (title != null and title.is_open()) or menu.is_open() or session.is_asking():
		return
	if event.physical_keycode == KEY_SPACE and command:
		toggle_record()
	elif event.physical_keycode == KEY_Z and command and timeline.is_record() and not timeline.recording:  # the edits, undone or done again
		var what: String = timeline.redo() if event.shift_pressed else timeline.undo()
		edit_window.view.selected = {}
		session.notice.emit(("Redo " if event.shift_pressed else "Undo ") + what if what != "" else
			("Nothing to redo" if event.shift_pressed else "Nothing to undo"))
	elif event.physical_keycode == KEY_EQUAL and command and timeline.is_record():  # the mix window and the edit window, in turn
		if edit_window.is_open():
			edit_window.close()
			mixer.open()
		else:
			if mixer.is_open():
				mixer.close()
			edit_window.open()
	elif (mixer.is_open() or edit_window.is_open()) and bindings.action_for(event.physical_keycode) == "transport" and not command:
		toggle_transport()  # Space works in the mix and edit windows too
	else:
		return
	get_viewport().set_input_as_handled()


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
	for inst in instruments:
		inst.peak_hold = 0.0


## An amp's panel with its pedalboard showing, or folded away (for every amp, and remembered).
func set_pedalboard_open(on: bool) -> void:
	settings.pedalboard_open = on
	settings.save_to_disk()


func clear_all_peaks() -> void:
	master_peak_hold = 0.0
	reverb_peak_hold = 0.0
	for inst in instruments:
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
		if not inst.playable:
			inst.set_input(on)
	_follow_speaker_inputs()


## Switches an instrument's input on or off, as a track's input in a DAW. With it on, a MIDI instrument plays what
## the MIDI keyboard sends, and a Speaker plays its hardware input (the audio input opens when the first one does).
func set_input(inst, on: bool) -> void:
	inst.set_input(on)
	if player != null:
		player.notice_input(inst)
	if not inst.playable:
		_follow_speaker_inputs()


## The MIDI instruments whose input is on: what the keyboards play.
func armed_instruments() -> Array:
	return instruments.filter(func(inst): return inst.playable and inst.input_on)


## Opens the audio input while any Speaker wants it, and closes it when none does.
func _follow_speaker_inputs() -> void:
	var wanted := instruments.any(func(inst): return not inst.playable and inst.input_on)
	if wanted == live_input:
		return
	live_input = wanted
	open_audio()
	if wanted and not live_input:  # the input wouldn't open: say so through the Speakers too
		for inst in instruments:
			if not inst.playable:
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
func add_pedal(inst, kind: String, at := -1) -> int:
	var index := audio.add_pedal(inst.source_id, kind, at)
	inst.pedals = audio.get_pedals(inst.source_id)
	inst.looper = audio.get_looper(inst.source_id)
	return index


func remove_pedal(inst, index: int) -> void:
	audio.remove_pedal(inst.source_id, index)
	inst.pedals = audio.get_pedals(inst.source_id)
	inst.looper = audio.get_looper(inst.source_id)


func move_pedal(inst, from: int, to: int) -> bool:
	var moved := audio.move_pedal(inst.source_id, from, to)
	inst.pedals = audio.get_pedals(inst.source_id)
	return moved


## A second of a pedal (Option-drag on the board, or duplicating the amp), switch, knobs and plug-in settings and all,
## on `to_inst`'s board at `at` (-1: the end). Where it went, or -1, with the reason in `audio.get_error()`.
func copy_pedal(inst, index: int, to_inst, at := -1) -> int:
	var placed := audio.copy_pedal(inst.source_id, index, to_inst.source_id, at)
	to_inst.pedals = audio.get_pedals(to_inst.source_id)
	to_inst.looper = audio.get_looper(to_inst.source_id)
	return placed


func set_pedal_on(inst, index: int, on: bool) -> void:
	audio.set_pedal_on(inst.source_id, index, on)
	inst.pedals = audio.get_pedals(inst.source_id)


func set_pedal_control(inst, index: int, control: int, value: float) -> void:
	audio.set_pedal_control(inst.source_id, index, control, value)
	inst.pedals = audio.get_pedals(inst.source_id)


## Loads one of the computer's effect plug-ins into a Plug-in pedal. Returns why it couldn't, or "".
func load_pedal_plugin(inst, index: int, plugin_id: String, state := PackedByteArray()) -> String:
	var loaded := audio.load_pedal_plugin(inst.source_id, index, plugin_id, state)
	inst.pedals = audio.get_pedals(inst.source_id)
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
	if not audio.set_instrument_plugin(inst.source_id, plugin_id, state):
		return audio.get_error()
	inst.instrument_plugin = audio.get_instrument_plugin(inst.source_id)
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
## returns why it couldn't be loaded, or "".
func set_insert(inst, slot: int, plugin_id: String, state := PackedByteArray()) -> String:
	var loaded := audio.set_insert(inst.source_id, slot, plugin_id, state)
	inst.inserts = audio.get_inserts(inst.source_id)
	return "" if loaded else audio.get_error()


## Dragging an insert to another slot, on this channel or another: it moves there and whatever was there takes its
## place. Copying instead puts a second of the same plug-in there, with its settings; it returns why it couldn't, or "".
func move_insert(from_inst, from_slot: int, to_inst, to_slot: int) -> void:
	audio.move_insert(from_inst.source_id, from_slot, to_inst.source_id, to_slot)
	from_inst.inserts = audio.get_inserts(from_inst.source_id)
	to_inst.inserts = audio.get_inserts(to_inst.source_id)


func copy_insert(from_inst, from_slot: int, to_inst, to_slot: int) -> String:
	var copied := audio.copy_insert(from_inst.source_id, from_slot, to_inst.source_id, to_slot)
	to_inst.inserts = audio.get_inserts(to_inst.source_id)
	return "" if copied else audio.get_error()


func clear_insert(inst, slot: int) -> void:
	audio.clear_insert(inst.source_id, slot)
	inst.inserts = audio.get_inserts(inst.source_id)


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


func set_muted(inst, on: bool) -> void:
	inst.muted = on
	_apply_channels()


func set_soloed(inst, on: bool) -> void:
	inst.soloed = on
	_apply_channels()


func _apply_channels() -> void:
	var any_solo := instruments.any(func(inst): return inst.soloed)
	for inst in instruments:
		inst.set_channel(inst.muted, inst.soloed, inst.muted or (any_solo and not inst.soloed))


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
	for panel in [menu, sequencer, mixer, amp_panel, speaker_panel, instrument_menu, edit_window]:
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
	player.forget(inst)
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
		_follow_speaker_inputs()


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
