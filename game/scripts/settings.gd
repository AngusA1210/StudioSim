extends RefCounted
## Everything the player can change in the menu. Saved to user://settings.cfg and loaded at start.

const BUFFER_SIZES := [32, 64, 128, 256, 512, 1024]

# Playback engine and I/O
var output_device := ""   # "" = follow the system default
var buffer_size := 128    # samples
var output_left := 0      # which hardware outputs carry the mix (0-based)
var output_right := 1
var input_device := ""    # remembered, but live input itself always starts switched off (see main.gd)
var speaker_input := -1   # hardware input the Speaker plays; -1 = all of them
var midi_disabled: Array = []  # names of MIDI devices to ignore

# Sound
var binaural := true
var click := false        # the metronome click (the tempo itself belongs to the room, not to these settings)
var click_volume_db := 0.0
var distance_falloff_db := 6.0  # how much quieter an instrument gets for each doubling of distance beyond 1.5 m
var limiter := true             # hold the mix under full scale; off = hear and meter exactly what it adds up to
var room_limiter := true        # and the room
var limiter_ceiling_db := -1.0  # where both limiters (after the master faders) hold the peaks, dBFS
var delay_compensation := true  # the mix's tracks held back to meet the latest of them at the master (plug-ins' delays)
var monitor := "room"           # what the main outputs play (H): "room", what you hear standing there, or "mix"
var mix_output := -1            # the mix on a pair of outputs of its own too (its first, 0-based), or -1 for none
var room_output := -1           # and the room

# Display and controls
var text_scale := 1.0
var fov := 75.0
var mouse_sensitivity := 1.0
var show_stats := false
var show_meter := true    # the master level meter on screen
var pre_fader_meters := true  # the mix window's channel meters read before the fader (right-click a fader for after it)
var pedalboard_open := true    # an amp's panel shows its pedalboard, or folds it away
var bindings := {}  # the keys changed on the Controls page: action → physical keycode (see bindings.gd)
var fullscreen := false
var room_brightness := 1.0

# You
var height := 1.75  # how tall you are, metres: your eyes and ears, and your body
var free_camera_hears := "you"  # while the free camera flies, the room is heard from "you" (your ears) or "camera"

# Rooms
var rooms_location := ""   # the folder new rooms go in; "" for SoundRoom/Rooms (see library.gd's home())
var recent_rooms: Array = []  # the rooms opened or saved lately, the latest first (their files)
var room_mode := "jam"     # what a new room is made as, to begin with: "jam" or "record" (the last chosen)
var autosave := false      # save the open room every so often, while it has changes
var autosave_minutes := 5
var backups := true        # a copy of the room in its Room Backups folder every so often
var backup_minutes := 10
var backups_kept := 10     # the oldest copies go past this many
var insertion_follows := false  # a Record room: stopping leaves the playhead where the music stopped (N), as Pro Tools' option
var count_in_bars := 0          # a Record room: bars of the click before recording starts (0, 1 or 2), as Pro Tools' Count Off
var loop_record := false        # a Record room: recording goes round the loop, a take each time (Option-L), as Pro Tools' Loop Record
var preroll_bars := 0           # a Record room: bars of the music before where playing or recording starts (0, 1 or 2)
var postroll_bars := 0          # and after a punch out, before it stops
var punch := false              # recording punches in and out over the range on the ruler, as a timeline selection does

var path := "user://settings.cfg"
var persist := true  # automated runs switch this off so they neither read nor change the player's settings


func load_from_disk() -> void:
	if not persist:
		return
	var file := ConfigFile.new()
	if file.load(path) != OK:
		return
	output_device = file.get_value("engine", "output_device", output_device)
	buffer_size = file.get_value("engine", "buffer_size", buffer_size)
	if not BUFFER_SIZES.has(buffer_size):
		buffer_size = 128
	output_left = file.get_value("io", "output_left", output_left)
	output_right = file.get_value("io", "output_right", output_right)
	input_device = file.get_value("io", "input_device", input_device)
	speaker_input = file.get_value("io", "speaker_input", file.get_value("io", "amp_input", speaker_input))  # its old name
	midi_disabled = file.get_value("midi", "disabled", midi_disabled)
	binaural = file.get_value("sound", "binaural", binaural)
	click = file.get_value("sound", "click", click)
	click_volume_db = clampf(file.get_value("sound", "click_volume_db", click_volume_db), -24.0, 6.0)
	distance_falloff_db = clampf(file.get_value("sound", "falloff_db_per_doubling", distance_falloff_db), 0.0, 6.0)
	limiter_ceiling_db = clampf(file.get_value("sound", "limiter_ceiling_db", limiter_ceiling_db), -12.0, 0.0)
	delay_compensation = bool(file.get_value("sound", "delay_compensation", delay_compensation))
	limiter = file.get_value("sound", "limiter", limiter)
	room_limiter = file.get_value("sound", "room_limiter", room_limiter)
	monitor = file.get_value("sound", "monitor", monitor)
	mix_output = file.get_value("engine", "mix_output", mix_output)
	room_output = file.get_value("engine", "room_output", room_output)
	text_scale = clampf(file.get_value("display", "text_scale", text_scale), 0.75, 2.0)
	fov = clampf(file.get_value("display", "fov", fov), 50.0, 110.0)
	mouse_sensitivity = clampf(file.get_value("display", "mouse_sensitivity", mouse_sensitivity), 0.2, 3.0)
	show_stats = file.get_value("display", "show_stats", show_stats)
	show_meter = file.get_value("display", "show_meter", show_meter)
	pre_fader_meters = file.get_value("display", "metering", "pre") != "post"  # (the old "pre_fader_meters" key is left behind: before is the default now)
	pedalboard_open = file.get_value("display", "pedalboard_open", pedalboard_open)
	fullscreen = file.get_value("display", "fullscreen", fullscreen)
	room_brightness = clampf(file.get_value("display", "room_brightness", room_brightness), 0.5, 3.0)
	height = clampf(float(file.get_value("you", "height", height)), 1.4, 2.1)
	free_camera_hears = "camera" if file.get_value("you", "free_camera_hears", free_camera_hears) == "camera" else "you"
	bindings = file.get_value("controls", "keys", bindings)
	rooms_location = file.get_value("rooms", "location", rooms_location)
	recent_rooms = file.get_value("rooms", "recent", recent_rooms)
	room_mode = file.get_value("rooms", "mode", room_mode)
	autosave = file.get_value("rooms", "autosave", autosave)
	autosave_minutes = clampi(file.get_value("rooms", "autosave_minutes", autosave_minutes), 1, 60)
	backups = file.get_value("rooms", "backups", backups)
	backup_minutes = clampi(file.get_value("rooms", "backup_minutes", backup_minutes), 1, 120)
	backups_kept = clampi(file.get_value("rooms", "backups_kept", backups_kept), 1, 100)
	insertion_follows = file.get_value("rooms", "insertion_follows_playback", insertion_follows)
	count_in_bars = clampi(file.get_value("rooms", "count_in_bars", count_in_bars), 0, 2)
	loop_record = file.get_value("rooms", "loop_record", loop_record)
	preroll_bars = clampi(file.get_value("rooms", "preroll_bars", preroll_bars), 0, 2)
	postroll_bars = clampi(file.get_value("rooms", "postroll_bars", postroll_bars), 0, 2)
	punch = file.get_value("rooms", "punch", punch)


func save_to_disk() -> void:
	if not persist:
		return
	var file := ConfigFile.new()
	file.set_value("engine", "output_device", output_device)
	file.set_value("engine", "buffer_size", buffer_size)
	file.set_value("io", "output_left", output_left)
	file.set_value("io", "output_right", output_right)
	file.set_value("io", "input_device", input_device)
	file.set_value("io", "speaker_input", speaker_input)
	file.set_value("midi", "disabled", midi_disabled)
	file.set_value("sound", "binaural", binaural)
	file.set_value("sound", "click", click)
	file.set_value("sound", "click_volume_db", click_volume_db)
	file.set_value("sound", "falloff_db_per_doubling", distance_falloff_db)
	file.set_value("sound", "limiter_ceiling_db", limiter_ceiling_db)
	file.set_value("sound", "delay_compensation", delay_compensation)
	file.set_value("sound", "limiter", limiter)
	file.set_value("sound", "room_limiter", room_limiter)
	file.set_value("sound", "monitor", monitor)
	file.set_value("engine", "mix_output", mix_output)
	file.set_value("engine", "room_output", room_output)
	file.set_value("display", "text_scale", text_scale)
	file.set_value("display", "fov", fov)
	file.set_value("display", "mouse_sensitivity", mouse_sensitivity)
	file.set_value("display", "show_stats", show_stats)
	file.set_value("display", "show_meter", show_meter)
	file.set_value("display", "metering", "pre" if pre_fader_meters else "post")
	file.set_value("display", "pedalboard_open", pedalboard_open)
	file.set_value("display", "fullscreen", fullscreen)
	file.set_value("display", "room_brightness", room_brightness)
	file.set_value("you", "height", height)
	file.set_value("you", "free_camera_hears", free_camera_hears)
	file.set_value("controls", "keys", bindings)
	file.set_value("rooms", "location", rooms_location)
	file.set_value("rooms", "recent", recent_rooms)
	file.set_value("rooms", "mode", room_mode)
	file.set_value("rooms", "autosave", autosave)
	file.set_value("rooms", "autosave_minutes", autosave_minutes)
	file.set_value("rooms", "backups", backups)
	file.set_value("rooms", "backup_minutes", backup_minutes)
	file.set_value("rooms", "backups_kept", backups_kept)
	file.set_value("rooms", "insertion_follows_playback", insertion_follows)
	file.set_value("rooms", "count_in_bars", count_in_bars)
	file.set_value("rooms", "loop_record", loop_record)
	file.set_value("rooms", "preroll_bars", preroll_bars)
	file.set_value("rooms", "postroll_bars", postroll_bars)
	file.set_value("rooms", "punch", punch)
	file.save(path)
