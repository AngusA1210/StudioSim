extends Node3D
## Builds the Sound Room (room, instruments, player, HUD) and starts the native audio core.
##
## Command-line options, passed after `--`:
##   --silent                 run the audio clock without opening a sound card
##   --pose=x,z,yaw_degrees   start the player somewhere else
##   --screenshot=path.png    save a screenshot after --frames frames (default 90), print stats, and quit
##   --quit-after=seconds     print stats and quit after this long

const Instrument := preload("res://scripts/instrument.gd")
const Player := preload("res://scripts/player.gd")
const Hud := preload("res://scripts/hud.gd")

const ROOM_SIZE := Vector3(14.0, 4.0, 10.0)
const WALL_THICKNESS := 0.5
const PARTITION_CENTER := Vector3(-2.5, 1.5, -1.9)
const PARTITION_SIZE := Vector3(0.3, 3.0, 3.0)
const OCCLUDER_LAYER := 2  # physics layer the occlusion rays test against
const OCCLUSION_RAY_OFFSETS := [-0.45, -0.225, 0.0, 0.225, 0.45]

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
var player
var hud
var instruments: Array = []
var options := {}
var _frames := 0
var _elapsed := 0.0


func _ready() -> void:
	_parse_options()
	audio = SoundRoomAudio.new()
	audio.name = "AudioCore"
	add_child(audio)
	if not audio.start(options.has("silent")):
		push_error("Audio core failed to start: %s" % audio.get_error())

	_build_environment()
	_build_room()
	for spec in INSTRUMENTS:
		var inst := Instrument.new()
		add_child(inst)
		inst.setup(spec, audio)
		instruments.append(inst)

	player = Player.new()
	player.name = "Player"
	add_child(player)
	player.setup(audio, instruments, ROOM_SIZE, PARTITION_CENTER, PARTITION_SIZE)
	if options.has("pose"):
		var p: PackedStringArray = options.pose.split(",")
		player.place(Vector3(float(p[0]), 0.0, float(p[1])), deg_to_rad(float(p[2])))

	hud = Hud.new()
	add_child(hud)
	hud.setup(audio, player)


func _process(delta: float) -> void:
	_frames += 1
	_elapsed += delta
	if options.has("screenshot") and _frames == int(options.get("frames", "90")):
		var image := get_viewport().get_texture().get_image()
		image.save_png(options.screenshot)
		_print_stats()
		get_tree().quit()
	elif options.has("quit-after") and _elapsed >= float(options["quit-after"]):
		_print_stats()
		get_tree().quit()


func _physics_process(_delta: float) -> void:
	_update_occlusion()


## Each instrument is heard through the partition in proportion to how many of five parallel rays it blocks,
## so walking past the wall's edge fades the muffling in and out instead of switching it.
func _update_occlusion() -> void:
	if player == null:
		return
	var space := get_world_3d().direct_space_state
	var ear: Vector3 = player.ear_position()
	for inst in instruments:
		var to: Vector3 = inst.global_position
		var flat := Vector3(to.x - ear.x, 0.0, to.z - ear.z)
		var side := Vector3(-flat.z, 0.0, flat.x).normalized() if flat.length() > 0.001 else Vector3.RIGHT
		var clear := 0
		for offset in OCCLUSION_RAY_OFFSETS:
			var query := PhysicsRayQueryParameters3D.create(ear + side * offset, to + side * offset, 1 << (OCCLUDER_LAYER - 1))
			if space.intersect_ray(query).is_empty():
				clear += 1
		inst.set_visibility(float(clear) / OCCLUSION_RAY_OFFSETS.size())


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
	print("SoundRoom stats: backend=%s rate=%s block=%s device_period=%s buffer=%.2fms device=%.2fms output=%.2fms cpu=%.1f%% blocks=%s" % [
		s.get("backend", "?"), s.get("sample_rate", 0), s.get("block_size", 0), s.get("device_period", 0),
		s.get("buffer_ms", 0.0), s.get("device_ms", 0.0), s.get("output_latency_ms", 0.0),
		100.0 * s.get("cpu_load", 0.0), s.get("blocks", 0)])
	var levels := []
	for inst in instruments:
		levels.append("%s=%.3f vis=%.2f" % [inst.kind, audio.get_source_level(inst.source_id), inst.visibility])
	print("SoundRoom sources: ", ", ".join(levels))


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
	_add_block(Vector3(0, -t / 2, 0), Vector3(w + 2 * t, t, d + 2 * t), Color(0.05, 0.055, 0.07), 1)  # floor
	_add_block(Vector3(0, h + t / 2, 0), Vector3(w + 2 * t, t, d + 2 * t), Color(0.035, 0.04, 0.05), 1)  # ceiling
	_add_block(Vector3(-w / 2 - t / 2, h / 2, 0), Vector3(t, h, d), Color(0.06, 0.065, 0.085), 1)
	_add_block(Vector3(w / 2 + t / 2, h / 2, 0), Vector3(t, h, d), Color(0.06, 0.065, 0.085), 1)
	_add_block(Vector3(0, h / 2, -d / 2 - t / 2), Vector3(w, h, t), Color(0.06, 0.065, 0.085), 1)
	_add_block(Vector3(0, h / 2, d / 2 + t / 2), Vector3(w, h, t), Color(0.06, 0.065, 0.085), 1)
	# The partition both blocks the player and occludes sound.
	_add_block(PARTITION_CENTER, PARTITION_SIZE, Color(0.12, 0.13, 0.17), 1 | (1 << (OCCLUDER_LAYER - 1)))


func _add_block(center: Vector3, size: Vector3, color: Color, layers: int) -> void:
	var body := StaticBody3D.new()
	body.position = center
	body.collision_layer = layers
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
