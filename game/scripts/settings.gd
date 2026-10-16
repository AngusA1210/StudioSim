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
var master_volume_db := 0.0
var binaural := true
var reverb := true
var click := false        # the metronome click (the tempo itself belongs to the room, not to these settings)
var click_volume_db := 0.0
var distance_falloff_db := 6.0  # how much quieter an instrument gets for each doubling of distance beyond 1.5 m
var limiter := true             # hold the output under full scale; off = hear and meter exactly what the mix adds up to

# Display and controls
var text_scale := 1.0
var fov := 75.0
var mouse_sensitivity := 1.0
var show_stats := false
var show_meter := true    # the master level meter on screen
var pre_fader_meters := false  # the mix window's channel meters read before the fader, as Pro Tools' option does
var bindings := {}  # the keys changed on the Controls page: action → physical keycode (see bindings.gd)
var fullscreen := false
var room_brightness := 1.0

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
	master_volume_db = file.get_value("sound", "master_volume_db", master_volume_db)
	binaural = file.get_value("sound", "binaural", binaural)
	reverb = file.get_value("sound", "reverb", reverb)
	click = file.get_value("sound", "click", click)
	click_volume_db = clampf(file.get_value("sound", "click_volume_db", click_volume_db), -24.0, 6.0)
	distance_falloff_db = clampf(file.get_value("sound", "falloff_db_per_doubling", distance_falloff_db), 0.0, 6.0)
	limiter = file.get_value("sound", "limiter", limiter)
	text_scale = clampf(file.get_value("display", "text_scale", text_scale), 0.75, 2.0)
	fov = clampf(file.get_value("display", "fov", fov), 50.0, 110.0)
	mouse_sensitivity = clampf(file.get_value("display", "mouse_sensitivity", mouse_sensitivity), 0.2, 3.0)
	show_stats = file.get_value("display", "show_stats", show_stats)
	show_meter = file.get_value("display", "show_meter", show_meter)
	pre_fader_meters = file.get_value("display", "pre_fader_meters", pre_fader_meters)
	fullscreen = file.get_value("display", "fullscreen", fullscreen)
	room_brightness = clampf(file.get_value("display", "room_brightness", room_brightness), 0.5, 3.0)
	bindings = file.get_value("controls", "keys", bindings)


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
	file.set_value("sound", "master_volume_db", master_volume_db)
	file.set_value("sound", "binaural", binaural)
	file.set_value("sound", "reverb", reverb)
	file.set_value("sound", "click", click)
	file.set_value("sound", "click_volume_db", click_volume_db)
	file.set_value("sound", "falloff_db_per_doubling", distance_falloff_db)
	file.set_value("sound", "limiter", limiter)
	file.set_value("display", "text_scale", text_scale)
	file.set_value("display", "fov", fov)
	file.set_value("display", "mouse_sensitivity", mouse_sensitivity)
	file.set_value("display", "show_stats", show_stats)
	file.set_value("display", "show_meter", show_meter)
	file.set_value("display", "pre_fader_meters", pre_fader_meters)
	file.set_value("display", "fullscreen", fullscreen)
	file.set_value("display", "room_brightness", room_brightness)
	file.set_value("controls", "keys", bindings)
	file.save(path)
