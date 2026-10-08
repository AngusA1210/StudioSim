extends Node3D
## Builds the Sound Room (room, instruments, player, HUD, menu), starts the native audio core, and is the one
## place that changes settings: the menu and the keyboard shortcuts both go through the functions below.
##
## Command-line options, passed after `--`:
##   --silent                 run the audio clock without opening a sound card (also leaves saved settings alone)
##   --pose=x,z,yaw_degrees   start the player somewhere else
##   --live-input             switch the audio input on at start
##   --menu=N                 open the menu on tab N at start
##   --text-scale=F           override the text size
##   --screenshot=path.png    save a screenshot after --frames frames (default 90), print stats, and quit
##   --quit-after=seconds     print stats and quit after this long

const Instrument := preload("res://scripts/instrument.gd")
const Player := preload("res://scripts/player.gd")
const Hud := preload("res://scripts/hud.gd")
const Menu := preload("res://scripts/menu.gd")
const Settings := preload("res://scripts/settings.gd")
const Acoustics := preload("res://scripts/acoustics.gd")

const ROOM_SIZE := Vector3(14.0, 4.0, 10.0)
const WALL_THICKNESS := 0.5
const PARTITION_CENTER := Vector3(-2.5, 1.5, -1.9)
const PARTITION_SIZE := Vector3(0.3, 3.0, 3.0)

const INSTRUMENTS := [
	{"kind": "drums", "name": "Drums", "color": Color(1.0, 0.42, 0.26), "position": Vector3(0.5, 0.9, -3.6),
		"size": Vector3(0.9, 0.6, 0.9), "gain": 0.50, "send": 0.6},
	{"kind": "bass", "name": "Bass", "color": Color(0.58, 0.44, 1.0), "position": Vector3(-5.0, 1.0, -2.0),
		"size": Vector3(0.7, 1.2, 0.5), "gain": 0.38, "send": 0.4},
	{"kind": "pad", "name": "Pad", "color": Color(0.25, 0.84, 0.75), "position": Vector3(4.8, 1.6, -1.6),
		"size": Vector3(0.6, 0.6, 0.6), "gain": 1.0, "send": 1.0, "spin": 0.25},
	{"kind": "bells", "name": "Bells", "color": Color(1.0, 0.82, 0.29), "position": Vector3(-4.6, 1.6, 2.4),
		"size": Vector3(0.42, 0.42, 0.42), "gain": 0.42, "send": 1.0, "spin": -0.6},
	{"kind": "keys", "name": "Keys", "color": Color(1.0, 0.48, 0.82), "position": Vector3(3.0, 0.95, 1.8),
		"size": Vector3(1.3, 0.12, 0.42), "gain": 0.20, "send": 0.9, "playable": true},
	# Whatever is plugged into the audio input comes out of this amp once live input is switched on.
	{"kind": "live", "name": "Amp", "color": Color(0.55, 0.78, 1.0), "position": Vector3(-2.0, 0.6, 1.6),
		"size": Vector3(0.6, 0.7, 0.4), "gain": 1.5, "send": 0.7},
]

const GRID_SHADER := """
shader_type spatial;
uniform vec3 base_color : source_color = vec3(0.1);
uniform float line_strength = 0.035;
varying vec3 world_pos;
varying vec3 world_normal;
void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	world_normal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}
void fragment() {
	vec3 n = abs(world_normal);
	vec2 p = n.y > 0.5 ? world_pos.xz : (n.x > 0.5 ? world_pos.zy : world_pos.xy);
	vec2 g = abs(fract(p - 0.5) - 0.5) / fwidth(p);
	float line = 1.0 - min(min(g.x, g.y), 1.0);
	ALBEDO = base_color + vec3(line * line_strength);
	ROUGHNESS = 0.92;
}
"""

var audio: SoundRoomAudio
var settings := Settings.new()
var player
var hud
var menu
var instruments: Array = []
var amp  # the live-input instrument
var walls: Array = []  # AABBs that sound has to bend around
var options := {}
var live_input := false   # never restored from settings: an open microphone next to speakers would feed back
var audio_error := ""     # the last problem opening a device, shown in the menu
var _frames := 0
var _elapsed := 0.0
var _midi_poll := 0.0


func _ready() -> void:
	_parse_options()
	settings.persist = not options.has("silent")
	settings.load_from_disk()
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
	_build_room()
	for spec in INSTRUMENTS:
		var inst := Instrument.new()
		add_child(inst)
		inst.setup(spec, audio)
		instruments.append(inst)
		if spec.kind == "live":
			amp = inst
	audio.set_source_input_channel(amp.source_id, settings.amp_input)
	audio.set_binaural(settings.binaural)
	audio.set_reverb(settings.reverb)
	audio.set_master_volume(db_to_linear(settings.master_volume_db))

	player = Player.new()
	player.name = "Player"
	add_child(player)
	player.setup(self, instruments, ROOM_SIZE, PARTITION_CENTER, PARTITION_SIZE)
	if options.has("pose"):
		var p: PackedStringArray = options.pose.split(",")
		player.place(Vector3(float(p[0]), 0.0, float(p[1])), deg_to_rad(float(p[2])))

	hud = Hud.new()
	add_child(hud)
	hud.setup(self)
	menu = Menu.new()
	add_child(menu)
	menu.setup(self)
	_apply_display()

	if options.has("live-input"):
		set_live_input(true)
	if options.has("menu"):
		menu.open(int(options.menu))


func _process(delta: float) -> void:
	_frames += 1
	_elapsed += delta
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


## Tell the audio core how each instrument's sound reaches the listener: straight, or bent around a wall edge.
func _physics_process(_delta: float) -> void:
	if player == null:
		return
	var ear: Vector3 = player.ear_position()
	for inst in instruments:
		inst.set_direct_path(Acoustics.direct_path(ear, inst.global_position, walls, ROOM_SIZE.y))


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


func set_live_input(on: bool) -> void:
	live_input = on
	open_audio()


func set_amp_input(channel: int) -> void:
	settings.amp_input = channel
	audio.set_source_input_channel(amp.source_id, channel)
	settings.save_to_disk()


func set_midi_device_enabled(device_name: String, on: bool) -> void:
	audio.set_midi_device_enabled(device_name, on)
	settings.midi_disabled.erase(device_name)
	if not on:
		settings.midi_disabled.append(device_name)
	settings.save_to_disk()


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
	audio.set_master_volume(db_to_linear(db))
	settings.save_to_disk()


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


func set_show_stats(on: bool) -> void:
	settings.show_stats = on
	settings.save_to_disk()


func _apply_display() -> void:
	get_window().content_scale_factor = settings.text_scale
	if player:
		player.camera.fov = settings.fov


# ── Setup ───────────────────────────────────────────────────────────────────────────────────────────────────

func _parse_options() -> void:
	for arg in OS.get_cmdline_user_args():
		var a: String = arg.trim_prefix("--")
		var eq := a.find("=")
		if eq >= 0:
			options[a.substr(0, eq)] = a.substr(eq + 1)
		else:
			options[a] = ""


func _print_stats() -> void:
	var s := audio.get_stats()
	print("SoundRoom stats: device=%s backend=%s rate=%s block=%s device_period=%s buffer=%.2fms device=%.2fms output=%.2fms cpu=%.1f%% blocks=%s" % [
		s.get("output_device", "?"), s.get("backend", "?"), s.get("sample_rate", 0), s.get("block_size", 0),
		s.get("device_period", 0), s.get("buffer_ms", 0.0), s.get("device_ms", 0.0), s.get("output_latency_ms", 0.0),
		100.0 * s.get("cpu_load", 0.0), s.get("blocks", 0)])
	var levels := []
	for inst in instruments:
		levels.append("%s=%.3f%s" % [inst.kind, audio.get_source_level(inst.source_id), " (behind wall)" if inst.shadowed else ""])
	print("SoundRoom sources: ", ", ".join(levels))
	print("SoundRoom midi: ", audio.get_midi_devices(), " live_input=", s.get("live_input", false))


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

	var house_light := OmniLight3D.new()
	house_light.position = Vector3(0.0, ROOM_SIZE.y - 0.3, 0.0)
	house_light.light_color = Color(0.75, 0.8, 1.0)
	house_light.light_energy = 0.35
	house_light.omni_range = 14.0
	add_child(house_light)


func _build_room() -> void:
	var w := ROOM_SIZE.x
	var h := ROOM_SIZE.y
	var d := ROOM_SIZE.z
	var t := WALL_THICKNESS
	_add_block(Vector3(0, -t / 2, 0), Vector3(w + 2 * t, t, d + 2 * t), Color(0.05, 0.055, 0.07))  # floor
	_add_block(Vector3(0, h + t / 2, 0), Vector3(w + 2 * t, t, d + 2 * t), Color(0.035, 0.04, 0.05))  # ceiling
	_add_block(Vector3(-w / 2 - t / 2, h / 2, 0), Vector3(t, h, d), Color(0.06, 0.065, 0.085))
	_add_block(Vector3(w / 2 + t / 2, h / 2, 0), Vector3(t, h, d), Color(0.06, 0.065, 0.085))
	_add_block(Vector3(0, h / 2, -d / 2 - t / 2), Vector3(w, h, t), Color(0.06, 0.065, 0.085))
	_add_block(Vector3(0, h / 2, d / 2 + t / 2), Vector3(w, h, t), Color(0.06, 0.065, 0.085))
	# The partition blocks the player, and sound has to bend around it.
	_add_block(PARTITION_CENTER, PARTITION_SIZE, Color(0.12, 0.13, 0.17))
	walls.append(AABB(PARTITION_CENTER - PARTITION_SIZE / 2, PARTITION_SIZE))


func _add_block(center: Vector3, size: Vector3, color: Color) -> void:
	var body := StaticBody3D.new()
	body.position = center
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	shape.shape = box
	body.add_child(shape)
	var mesh := MeshInstance3D.new()
	var box_mesh := BoxMesh.new()
	box_mesh.size = size
	mesh.mesh = box_mesh
	var material := ShaderMaterial.new()
	material.shader = _grid_shader()
	material.set_shader_parameter("base_color", color)
	mesh.material_override = material
	body.add_child(mesh)
	add_child(body)


var _shader: Shader
func _grid_shader() -> Shader:
	if _shader == null:
		_shader = Shader.new()
		_shader.code = GRID_SHADER
	return _shader
