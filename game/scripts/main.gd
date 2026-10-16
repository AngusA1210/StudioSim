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
##   --menu=N                 open the menu on page N at start (0 Metronome, 1 Mixer, 2 Room, 3 Playback Engine...)
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
var amp_panel  # an amp's knobs and its pedals (Enter at an amp)
var plugin_browser  # the effect plug-ins on the computer, to choose one for an insert or a Plug-in pedal
var speaker_panel  # a Speaker's volume and input (Enter at a Speaker)
var bindings  # the keys, as set on the Controls page
var _plugins = null  # what get_plugins() said, the first time anything asked
var instrument_menu
var title  # the title screen
var room  # its size and the walls inside it
var instruments: Array = []
var speaker  # the Speaker the room starts with: the one whose input choice is remembered between runs
# The room's clock. These belong to the room rather than the player's settings, so they start from the defaults.
var tempo := DEFAULT_TEMPO
var swing := DEFAULT_SWING
var sequence_running := true  # whether the sequencer is playing the patterns
var options := {}
var live_input := false   # the audio input is open: some Speaker's input is on. Every Speaker starts with it off,
                          # since an open microphone next to speakers would feed back
var audio_error := ""     # the last problem opening a device, shown in the menu
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
	room = Room.new()
	add_child(room)
	room.changed.connect(_on_room_changed)
	room.setup()
	if options.has("room"):
		var dims: PackedStringArray = options.room.split(",")
		room.set_size(Vector3(float(dims[0]), float(dims[1]), float(dims[2])))
	if options.has("walls"):
		while not room.walls.is_empty():
			room.remove_wall(0)
		for text in options.walls.split(";", false):
			var n: PackedStringArray = text.split(",")
			room.add_wall(Vector2(float(n[0]), float(n[1])), Vector2(float(n[2]), float(n[3])), float(n[4]) if n.size() > 4 else Room.DEFAULT_WALL_HEIGHT)
	for entry in DEFAULT_ROOM:
		var inst = add_instrument(entry.kind, entry.position, true)  # with its part of the default groove
		inst.face(SPAWN)
		if entry.kind == "live":
			speaker = inst
			inst.set_input_channel(settings.speaker_input)
	# The clock has been running since the audio opened: begin again, so the music starts on the first beat with
	# every pattern in place.
	audio.set_sequencer_running(false)
	audio.set_sequencer_running(true)
	audio.set_binaural(settings.binaural)
	audio.set_reverb(settings.reverb)
	_apply_master_volume()
	audio.set_distance_falloff(settings.distance_falloff_db)
	audio.set_limiter(settings.limiter)
	audio.set_click(settings.click)
	audio.set_click_volume(db_to_linear(settings.click_volume_db))
	if options.has("tempo"):
		set_tempo(float(options.tempo))

	player = Player.new()
	player.name = "Player"
	add_child(player)
	player.setup(self, instruments)
	_on_room_changed()  # now that there are instruments and a player to keep inside it
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
	# Each channel as it reaches the master: after its fader, before distance and the master's. Or before its fader,
	# scaled so that the two agree with the fader at 0 dB.
	var pre: bool = settings.pre_fader_meters
	for inst in instruments:
		var scale: float = CHANNEL_TRIM * (inst.normal_gain() if pre else 1.0)
		inst.meter_peak = audio.get_source_peak(inst.source_id, pre) * scale
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
func clear_peak(inst) -> void:
	if inst == null:
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


func clear_all_peaks() -> void:
	master_peak_hold = 0.0
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


func set_pedal_on(inst, index: int, on: bool) -> void:
	audio.set_pedal_on(inst.source_id, index, on)
	inst.pedals = audio.get_pedals(inst.source_id)


func set_pedal_control(inst, index: int, control: int, value: float) -> void:
	audio.set_pedal_control(inst.source_id, index, control, value)
	inst.pedals = audio.get_pedals(inst.source_id)


## Loads one of the computer's effect plug-ins into a Plug-in pedal. Returns why it couldn't, or "".
func load_pedal_plugin(inst, index: int, plugin_id: String) -> String:
	var loaded := audio.load_pedal_plugin(inst.source_id, index, plugin_id)
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


## A channel's inserts, as in a DAW's mix window: a plug-in in each of a few slots, before the fader. Loading one
## returns why it couldn't be loaded, or "".
func set_insert(inst, slot: int, plugin_id: String) -> String:
	var loaded := audio.set_insert(inst.source_id, slot, plugin_id)
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
	sequence_running = on
	audio.set_sequencer_running(on)


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
	for panel in [menu, sequencer, mixer, amp_panel, speaker_panel, instrument_menu]:
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


func set_reverb(on: bool) -> void:
	settings.reverb = on
	audio.set_reverb(on)
	settings.save_to_disk()


func set_master_volume_db(db: float) -> void:
	settings.master_volume_db = db
	_apply_master_volume()
	settings.save_to_disk()


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
	audio.set_master_volume(db_to_linear(settings.master_volume_db) * _stage_gain)


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
