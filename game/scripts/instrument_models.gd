extends RefCounted
## What each kind of instrument looks like, built from simple shapes: a drum kit, a monophonic bass synth, a
## modular synth for the pad, tubular bells, an electric piano, a PA speaker on a tripod, and guitar and bass amps
## (combos, and heads on cabinets), and a microphone on a boom stand. An amp's effect pedals stand on the floor in
## front of it as they are put on its board (stomp_box, and loop_pedal for the loop pedal).
##
## Each model stands on the floor (y = 0) and faces +z. The parts drawn in the instrument's own colour use the
## `accent` material, which the instrument lights up as it plays. An amp's pedal has an `led` material too, which
## shows what the pedal is doing.

const KEY_WHITE := 0.0235  # width of a white key, in metres

static var _shared := {}  # finishes every model uses, made once
# The cabinets an amp can have, as they look: the box, and whether it stands on casters.
const CABINETS := {
	"1x12": {"size": Vector3(0.62, 0.48, 0.25), "casters": false},
	"2x12": {"size": Vector3(0.74, 0.5, 0.27), "casters": false},
	"4x12": {"size": Vector3(0.76, 0.76, 0.36), "casters": false},
	"1x15": {"size": Vector3(0.56, 0.7, 0.42), "casters": true},
	"4x10": {"size": Vector3(0.6, 0.62, 0.42), "casters": true},
	"8x10": {"size": Vector3(0.6, 1.3, 0.45), "casters": false},
}


## Returns {node: Node3D, accent: StandardMaterial3D} and, for an amp, how tall it stands and the floor it covers
## {top: float, footprint: Vector2} and where its pedals stand {pedal_spot: Vector3}. An amp is drawn with `cabinet`:
## a combo has its controls across the top of it, a stack its head standing on it. A microphone is drawn with
## `mic` {height (its capsule's, in metres), tilt (degrees it points down), model (microphones.h's), stand (whether
## it has one: a stereo pair's right mic is on its left one's), pair (the left mic of a pair: where the stand under the
## two is and where the other is, see instrument.pair_stand)}, and says how tall it stands.
static func build(kind: String, color: Color, cabinet := "", mic := {}) -> Dictionary:
	var node := Node3D.new()
	var accent := StandardMaterial3D.new()
	accent.albedo_color = color.darkened(0.35)
	accent.roughness = 0.35
	accent.emission_enabled = true
	accent.emission = color
	var built := {"node": node, "accent": accent}
	match kind:
		"guitar_combo", "guitar_stack", "bass_combo", "bass_stack":
			var defaults := {"guitar_combo": "1x12", "guitar_stack": "4x12", "bass_combo": "1x15", "bass_stack": "8x10"}
			var look: Dictionary = CABINETS.get(cabinet, CABINETS[defaults[kind]])
			var size: Vector3 = look.size
			var combo := kind.ends_with("_combo")
			_amp_box(node, accent, size, look.casters, combo)
			var lift := 0.05 if look.casters else 0.015
			built.top = lift + size.y
			if not combo:  # a head standing on its cabinet
				var head := Vector3(size.x - 0.02, 0.25, minf(size.z - 0.06, 0.32))
				_amp_head(node, accent, head, lift + size.y - 0.015)
				built.top += head.y + 0.06
			built.footprint = Vector2(size.x, size.z)
			built.pedal_spot = Vector3(0, 0, size.z / 2 + 0.3)
		"drums":
			_drum_kit(node, accent)
		"garage_drums":
			_drum_kit(node, accent, "garage")
		"studio_drums":
			_drum_kit(node, accent, "studio")
		"plugin_synth":
			_controller(node, accent)
		"bass":
			_bass_synth(node, accent)
		"pad":
			_modular(node, accent)
		"bells":
			_tubular_bells(node, accent)
		"keys":
			_electric_piano(node, accent)
		"live":
			_speaker(node, accent)
		"mic":
			built.top = _microphone(node, accent, float(mic.get("height", 1.2)), float(mic.get("tilt", 0.0)), str(mic.get("model", "flat")),
				bool(mic.get("stand", true)), mic.get("pair", {}))
	return built


## An effect pedal for an amp's board: a small box painted in its colour, with a footswitch at the front, a row of
## `knobs` at the back, and a light that is lit while it is on. It stands on the floor at the origin, facing +z.
## Returns {node: Node3D, led: StandardMaterial3D}.
static func stomp_box(color: Color, knobs: int) -> Dictionary:
	var node := Node3D.new()
	var paint := _plain(color)
	paint.metallic = 0.4
	paint.roughness = 0.35
	_box(node, Vector3(0.068, 0.042, 0.112), paint, Vector3(0, 0.021, 0))
	_cylinder(node, 0.011, 0.02, _finish("chrome"), Vector3(0, 0.05, 0.024))  # the footswitch
	for k in knobs:
		_cylinder(node, 0.0065, 0.012, _finish("knob"), Vector3((k - (knobs - 1) / 2.0) * 0.019, 0.047, -0.03))
	var led := StandardMaterial3D.new()
	led.albedo_color = Color(0.12, 0.04, 0.04)
	led.emission_enabled = true
	led.emission = Color(1.0, 0.18, 0.12)
	led.emission_energy_multiplier = 0.0
	_sphere(node, 0.0045, led, Vector3(0, 0.043, -0.006))
	return {"node": node, "led": led}


# ── The instruments ─────────────────────────────────────────────────────────────────────────────────────────

## A drum kit, set up as a right-handed drummer plays it, the stool on the side you stand (the instrument's front, +z):
## the kick in the middle with its pedal under your right foot, the hi-hat on your left with its pedal under your left
## foot, the snare between your knees, the toms over the kick and the floor tom on your right, the crash on your left
## and the ride on your right. `style`: "machine" (the drum machine's kit: two toms up), "garage" (one up, one down, on
## an old rug) or "studio" (one up, one down, on a dark rug).
static func _drum_kit(node: Node3D, accent: Material, style := "machine") -> void:
	var chrome := _finish("chrome")
	var head := _finish("head")
	var black := _finish("black")
	var bronze := _finish("bronze")
	if style != "machine":
		var rug := Color(0.36, 0.12, 0.1) if style == "garage" else Color(0.1, 0.1, 0.12)
		_box(node, Vector3(2.0, 0.008, 1.8), _plain(rug), Vector3(0, 0.004, 0.1))
	# The kick, on its side: its batter head towards you, its front head (and its spurs) away.
	_cylinder(node, 0.27, 0.42, accent, Vector3(0, 0.29, -0.15), Vector3(PI / 2, 0, 0))
	_cylinder(node, 0.262, 0.006, head, Vector3(0, 0.29, -0.364), Vector3(PI / 2, 0, 0))
	_cylinder(node, 0.262, 0.006, head, Vector3(0, 0.29, 0.064), Vector3(PI / 2, 0, 0))
	for z in [-0.36, 0.06]:
		_ring(node, 0.262, 0.285, black, Vector3(0, 0.29, z), Vector3(PI / 2, 0, 0))
	for side in [-1.0, 1.0]:
		_rod(node, Vector3(side * 0.24, 0.2, -0.3), Vector3(side * 0.36, 0.0, -0.44), 0.008, chrome)
	# Its pedal: the footboard under your right foot, the beater up against the head.
	_box(node, Vector3(0.09, 0.02, 0.26), black, Vector3(0.04, 0.035, 0.24), Vector3(0.12, 0, 0))
	_rod(node, Vector3(0.04, 0.05, 0.12), Vector3(0.04, 0.3, 0.1), 0.006, chrome)
	_sphere(node, 0.025, _finish("head"), Vector3(0.04, 0.3, 0.095))
	# The toms over the kick, tilted towards you.
	_rod(node, Vector3(0, 0.55, -0.12), Vector3(0, 0.74, -0.1), 0.012, chrome)
	for x in ([-0.17, 0.17] if style == "machine" else [-0.04]):
		_drum(node, 0.14 if style == "machine" else 0.15, 0.17 if style == "machine" else 0.18, Vector3(x, 0.8, -0.08),
			Vector3(0.3, 0, -x * 0.6), accent, head)
	# The snare between your knees, a little to the left.
	_drum(node, 0.18, 0.13, Vector3(-0.28, 0.62, 0.22), Vector3(0.12, 0, 0), accent, head)
	_tripod(node, Vector3(-0.28, 0.55, 0.22), 0.22, chrome)
	# The floor tom on three legs, to your right.
	_drum(node, 0.2, 0.34, Vector3(0.5, 0.45, 0.16), Vector3.ZERO, accent, head)
	for i in 3:
		var a := TAU * i / 3.0 + 0.4
		_rod(node, Vector3(0.5 + cos(a) * 0.2, 0.5, 0.16 + sin(a) * 0.2), Vector3(0.5 + cos(a) * 0.26, 0.0, 0.16 + sin(a) * 0.26), 0.008, chrome)
	# The hi-hat on your left, its pedal under your left foot.
	_tripod(node, Vector3(-0.6, 0.9, 0.1), 0.24, chrome)
	for y in [0.9, 0.925]:
		_cylinder(node, 0.18, 0.006, bronze, Vector3(-0.6, y, 0.1))
	_box(node, Vector3(0.09, 0.02, 0.25), black, Vector3(-0.56, 0.03, 0.32), Vector3(0.12, 0, 0))
	# The crash behind on your left and the ride on your right, on boom stands, tilted towards you.
	_tripod(node, Vector3(-0.62, 1.18, -0.42), 0.26, chrome)
	_rod(node, Vector3(-0.62, 1.18, -0.42), Vector3(-0.48, 1.32, -0.3), 0.01, chrome)
	_cylinder(node, 0.23, 0.006, bronze, Vector3(-0.47, 1.33, -0.29), Vector3(0.35, 0, 0.2))
	_tripod(node, Vector3(0.82, 1.0, -0.22), 0.24, chrome)
	_rod(node, Vector3(0.82, 1.0, -0.22), Vector3(0.72, 1.08, -0.12), 0.01, chrome)
	_cylinder(node, 0.26, 0.007, bronze, Vector3(0.71, 1.09, -0.1), Vector3(0.22, 0, -0.25))
	# The stool, on your side.
	_cylinder(node, 0.17, 0.08, black, Vector3(0, 0.52, 0.66))
	_tripod(node, Vector3(0, 0.48, 0.66), 0.22, chrome)


## A monophonic synthesizer: a short keyboard with a tilted panel of knobs, wooden ends, on an X stand.
static func _bass_synth(node: Node3D, accent: Material) -> void:
	var black := _finish("black")
	var wood := _finish("wood")
	var panel := _finish("panel")
	var knob := _finish("knob")
	for side in [-1.0, 1.0]:  # the stand: two crossed legs each side, and a bar across the top
		_rod(node, Vector3(side * 0.28, 0.0, -0.2), Vector3(side * 0.28, 0.84, 0.18), 0.014, black)
		_rod(node, Vector3(side * 0.28, 0.0, 0.18), Vector3(side * 0.28, 0.84, -0.2), 0.014, black)
		_box(node, Vector3(0.03, 0.03, 0.46), black, Vector3(side * 0.28, 0.85, 0))
	_box(node, Vector3(0.74, 0.08, 0.36), black, Vector3(0, 0.91, 0.02))  # the body
	for side in [-1.0, 1.0]:
		_box(node, Vector3(0.025, 0.13, 0.38), wood, Vector3(side * 0.383, 0.93, 0.02))
	_keyboard(node, 22, Vector3(-0.2, 0.955, 0.2))
	for x in [-0.33, -0.29]:  # pitch and modulation wheels
		_cylinder(node, 0.03, 0.014, black, Vector3(x, 0.965, 0.1), Vector3(0, 0, PI / 2))
	# The control panel, rising behind the keys.
	var face := _box(node, Vector3(0.74, 0.22, 0.02), panel, Vector3(0, 1.06, -0.13), Vector3(-1.0, 0, 0))
	_box(node, Vector3(0.74, 0.012, 0.022), accent, Vector3(0, 1.165, -0.19), Vector3(-1.0, 0, 0))  # trim along the top
	for row in 3:
		for col in 8:
			var knob_part := _cylinder(face, 0.013, 0.02, knob, Vector3(-0.3 + col * 0.085, -0.06 + row * 0.06, 0.018), Vector3(PI / 2, 0, 0))
			knob_part.name = "Knob"


## A modular synthesizer: a case of module panels with knobs, jacks and patch cables, on a small table.
static func _modular(node: Node3D, accent: Material) -> void:
	var black := _finish("black")
	var wood := _finish("wood")
	var panel := _finish("panel")
	var knob := _finish("knob")
	_box(node, Vector3(0.9, 0.04, 0.5), black, Vector3(0, 0.95, 0))  # the table
	for x in [-0.4, 0.4]:
		for z in [-0.2, 0.2]:
			_rod(node, Vector3(x, 0.0, z), Vector3(x, 0.93, z), 0.016, black)
	var case := Node3D.new()  # tilted back a little, standing on the table
	case.position = Vector3(0, 0.97, 0.02)
	case.rotation.x = -0.25
	node.add_child(case)
	for side in [-1.0, 1.0]:
		_box(case, Vector3(0.03, 0.72, 0.16), wood, Vector3(side * 0.43, 0.36, 0))
	_box(case, Vector3(0.86, 0.72, 0.02), black, Vector3(0, 0.36, -0.07))
	_box(case, Vector3(0.86, 0.015, 0.16), accent, Vector3(0, 0.725, 0))  # a lit strip along the top
	var cable_colors := [Color(0.95, 0.75, 0.2), Color(0.9, 0.3, 0.3), Color(0.35, 0.6, 0.95), Color(0.95, 0.95, 0.95)]
	for row in 2:
		var y := 0.18 + row * 0.35
		for module in 7:  # module faces of different widths, knobs above, jacks below
			var x := -0.39 + module * 0.112
			_box(case, Vector3(0.105, 0.32, 0.01), panel, Vector3(x + 0.052, y, 0.075))
			for k in 2:
				_cylinder(case, 0.014, 0.022, knob, Vector3(x + 0.03 + k * 0.045, y + 0.08, 0.09), Vector3(PI / 2, 0, 0))
			_cylinder(case, 0.008, 0.012, black, Vector3(x + 0.052, y - 0.08, 0.085), Vector3(PI / 2, 0, 0))
		for cable in 3:  # patch cables, sagging between jacks
			var from := Vector3(-0.33 + cable * 0.23, y - 0.08, 0.09)
			var to := from + Vector3(0.22 + cable * 0.03, 0.02, 0.0)
			var sag := (from + to) / 2 + Vector3(0, -0.07, 0.04)
			var ink := _plain(cable_colors[(row * 3 + cable) % cable_colors.size()])
			_rod(case, from, sag, 0.0045, ink)
			_rod(case, sag, to, 0.0045, ink)


static func _tubular_bells(node: Node3D, accent: Material) -> void:
	var black := _finish("black")
	var brass := _finish("brass")
	for side in [-1.0, 1.0]:  # the frame
		_box(node, Vector3(0.04, 1.95, 0.04), black, Vector3(side * 0.43, 0.975, 0))
		_box(node, Vector3(0.05, 0.04, 0.5), black, Vector3(side * 0.43, 0.04, 0))
		for z in [-0.22, 0.22]:
			_sphere(node, 0.025, black, Vector3(side * 0.43, 0.025, z))
	_box(node, Vector3(0.9, 0.05, 0.07), black, Vector3(0, 1.93, 0))
	_box(node, Vector3(0.86, 0.03, 0.03), black, Vector3(0, 1.72, 0.05))  # the damper bar
	for i in 8:  # longest on the left, as the notes go up to the right
		var x := -0.33 + i * (0.66 / 7.0)
		var length := 1.4 - i * 0.075
		_rod(node, Vector3(x, 1.92, 0), Vector3(x, 1.85, 0), 0.002, black)  # the cord it hangs from
		_cylinder(node, 0.019, length, brass, Vector3(x, 1.84 - length / 2, 0))
		_cylinder(node, 0.023, 0.035, accent, Vector3(x, 1.84, 0))  # the cap that is struck


## An electric piano: a 73-key case on chrome legs, with its lid and name plate, and a sustain pedal.
static func _electric_piano(node: Node3D, accent: Material) -> void:
	var black := _finish("black")
	var chrome := _finish("chrome")
	_box(node, Vector3(1.2, 0.16, 0.52), black, Vector3(0, 0.825, 0))
	_keyboard(node, 43, Vector3(-43 * KEY_WHITE / 2, 0.915, 0.24))
	for side in [-1.0, 1.0]:  # end blocks either side of the keys
		_box(node, Vector3(0.085, 0.05, 0.2), black, Vector3(side * 0.557, 0.93, 0.15))
	_box(node, Vector3(1.2, 0.06, 0.25), black, Vector3(0, 0.95, -0.135))  # the lid behind the keys
	_box(node, Vector3(0.26, 0.03, 0.006), accent, Vector3(0, 0.95, -0.007))  # the name plate
	_box(node, Vector3(1.03, 0.008, 0.006), accent, Vector3(0, 0.898, 0.262))  # a lit strip under the keys
	for x in [-0.54, 0.54]:
		for z in [-0.2, 0.2]:
			_rod(node, Vector3(x, 0.0, z), Vector3(x, 0.75, z), 0.016, chrome)
	_box(node, Vector3(0.09, 0.03, 0.24), chrome, Vector3(0.12, 0.015, 0.45))  # the sustain pedal


## A plug-in instrument: a controller keyboard on a stand, and above it on a shelf the laptop running the plug-in, its
## screen lit in the instrument's colour.
static func _controller(node: Node3D, accent: Material) -> void:
	var black := _finish("black")
	var chrome := _finish("chrome")
	var panel := _finish("panel")
	_box(node, Vector3(0.82, 0.08, 0.3), black, Vector3(0, 0.8, 0))
	_keyboard(node, 29, Vector3(-29 * KEY_WHITE / 2, 0.85, 0.13))
	_box(node, Vector3(0.8, 0.006, 0.006), accent, Vector3(0, 0.8, 0.152))  # a lit strip under the keys
	for x in [-0.36, 0.36]:
		for z in [-0.11, 0.11]:
			_rod(node, Vector3(x, 0.0, z), Vector3(x, 0.76, z), 0.014, chrome)
	_rod(node, Vector3(0, 0.84, -0.13), Vector3(0, 1.04, -0.13), 0.012, chrome)
	_box(node, Vector3(0.38, 0.015, 0.26), panel, Vector3(0, 1.05, -0.12))  # the laptop
	_box(node, Vector3(0.38, 0.25, 0.012), black, Vector3(0, 1.17, -0.255), Vector3(-0.25, 0, 0))
	_box(node, Vector3(0.34, 0.21, 0.004), accent, Vector3(0, 1.172, -0.247), Vector3(-0.25, 0, 0))


## A PA speaker on a tripod: a woofer and a horn behind a lit ring each.
static func _speaker(node: Node3D, accent: Material) -> void:
	var black := _finish("black")
	var chrome := _finish("chrome")
	var cone := _finish("cone")
	_box(node, Vector3(0.36, 0.54, 0.3), black, Vector3(0, 1.45, 0))
	_cylinder(node, 0.125, 0.02, cone, Vector3(0, 1.38, 0.15), Vector3(PI / 2, 0, 0))
	_sphere(node, 0.04, cone, Vector3(0, 1.38, 0.155), Vector3(1, 1, 0.4))
	_ring(node, 0.125, 0.14, accent, Vector3(0, 1.38, 0.152), Vector3(PI / 2, 0, 0))
	_box(node, Vector3(0.16, 0.08, 0.02), cone, Vector3(0, 1.62, 0.151))  # the horn
	_ring(node, 0.03, 0.04, accent, Vector3(0, 1.62, 0.163), Vector3(PI / 2, 0, 0))
	_rod(node, Vector3(0, 0.55, 0), Vector3(0, 1.18, 0), 0.018, chrome)  # the pole
	_tripod(node, Vector3(0, 0.62, 0), 0.42, chrome)


## A microphone on a boom stand: its capsule (where it hears from, lit in its colour as it hears) at `height` over the
## floor, pointing along +z and down by `tilt` degrees; its body as its model has it (end-address, the body behind the
## capsule: the measurement mic, the dynamics, the pencil; side-address, the body below it: the large condenser, the
## ribbon); and the boom back to the stand's pole, and a tripod. A stereo pair's left mic draws the stand under the
## two and the bar they are on instead; its right mic, no stand. Returns how tall it stands.
static func _microphone(node: Node3D, accent: Material, height: float, tilt: float, model := "flat", stand := true, pair := {}) -> float:
	var t := deg_to_rad(tilt)
	var aim := Vector3(0.0, -sin(t), cos(t))  # the way it points
	var up := Vector3(0.0, cos(t), sin(t))    # and up, as it is tilted
	var capsule := Vector3(0.0, height, 0.0)
	var tail := _mic_body(node, accent, model, capsule, aim, up)
	var top := maxf(capsule.y, tail.y) + 0.08
	if not pair.is_empty():  # a stereo pair: a bar from this one's clip to the other's, on a stand between them
		var other: Vector3 = pair.partner + Basis(Vector3.UP, float(pair.partner_turn)) * (tail - capsule)
		_rod(node, tail, other, 0.006, _finish("panel"))
		var middle := (tail + other) / 2.0
		_sphere(node, 0.014, _finish("black"), middle)
		_tripod(node, middle, 0.3, _finish("panel"))
		return maxf(top, middle.y + 0.05)
	if not stand:
		return top
	var pole_top := Vector3(0.0, maxf(tail.y + 0.03, 0.25), tail.z - 0.42)
	_rod(node, tail, pole_top, 0.007, _finish("panel"))  # the boom
	_sphere(node, 0.016, _finish("black"), pole_top)  # where the boom meets the pole
	_tripod(node, pole_top, 0.3, _finish("panel"))
	return maxf(top, pole_top.y + 0.05)


## A microphone's body, as its model has it, round its capsule. Returns where its clip is, which holds it.
static func _mic_body(node: Node3D, accent: Material, model: String, capsule: Vector3, aim: Vector3, up: Vector3) -> Vector3:
	var chrome := _finish("chrome")
	var black := _finish("black")
	var grille := _finish("grille")
	var tail: Vector3
	match model:
		"dynamic":  # a short dark body behind a round-ended grille
			_rod(node, capsule + aim * 0.012, capsule - aim * 0.05, 0.0165, chrome)
			_sphere(node, 0.0165, chrome, capsule + aim * 0.012)
			_rod(node, capsule - aim * 0.05, capsule - aim * 0.16, 0.015, black)
			tail = capsule - aim * 0.16
		"kick":  # a big egg: a wide grille in front, a fat body behind
			_rod(node, capsule + aim * 0.01, capsule - aim * 0.06, 0.042, grille)
			_sphere(node, 0.042, grille, capsule + aim * 0.01, Vector3(1.0, 1.0, 1.0))
			_rod(node, capsule - aim * 0.06, capsule - aim * 0.16, 0.038, accent)
			_rod(node, capsule - aim * 0.16, capsule - aim * 0.2, 0.02, black)
			tail = capsule - aim * 0.2
		"condenser":  # side-address: the head grille round the capsule, the body below it, held from underneath
			_rod(node, capsule - up * 0.035, capsule + up * 0.035, 0.03, grille)
			_sphere(node, 0.03, grille, capsule + up * 0.035)
			_rod(node, capsule - up * 0.035, capsule - up * 0.18, 0.027, _finish("brass"))
			_ring(node, 0.03, 0.036, black, capsule - up * 0.11, Vector3(atan2(-aim.y, aim.z), 0.0, 0.0))
			tail = capsule - up * 0.2 - aim * 0.02
		"pencil":  # a slim dark pencil, the capsule in its silver tip
			_rod(node, capsule, capsule - aim * 0.025, 0.0115, chrome)
			_rod(node, capsule - aim * 0.025, capsule - aim * 0.2, 0.0105, black)
			tail = capsule - aim * 0.2
		"ribbon":  # side-address: a flat grille box round the ribbon, in a yoke
			var t := atan2(-aim.y, aim.z)
			_box(node, Vector3(0.06, 0.12, 0.035), grille, capsule, Vector3(t, 0.0, 0.0))
			_box(node, Vector3(0.066, 0.02, 0.04), accent, capsule - up * 0.065, Vector3(t, 0.0, 0.0))
			_rod(node, capsule - up * 0.075, capsule - up * 0.14, 0.008, black)
			tail = capsule - up * 0.14
		_:  # the measurement mic: a long slim silver body, its capsule in its narrower tip
			_rod(node, capsule - aim * 0.035, capsule - aim * 0.24, 0.0095, chrome)
			_rod(node, capsule, capsule - aim * 0.035, 0.0055, chrome)
			tail = capsule - aim * 0.24
	_sphere(node, 0.0065, accent, capsule + aim * 0.002)  # its capsule, lit as it hears
	_rod(node, tail + (capsule - tail).normalized() * 0.025, tail - (capsule - tail).normalized() * 0.008, 0.0125, black)  # the clip
	return tail


## A guitar or bass amp's box: tolex all round, grille cloth on the front, metal corners, and for a combo the control
## panel along the top.
static func _amp_box(node: Node3D, accent: Material, size: Vector3, casters: bool, combo: bool) -> void:
	var black := _finish("black")
	var grille := _finish("grille")
	var chrome := _finish("chrome")
	var lift := 0.05 if casters else 0.015
	_box(node, size, black, Vector3(0, lift + size.y / 2, 0))
	var face_height := size.y - (0.11 if combo else 0.06)
	_box(node, Vector3(size.x - 0.06, face_height - 0.04, 0.01), grille,
		Vector3(0, lift + 0.03 + (face_height - 0.04) / 2, size.z / 2 + 0.002))
	_box(node, Vector3(size.x - 0.04, 0.012, 0.012), accent, Vector3(0, lift + 0.03 + face_height - 0.03, size.z / 2 + 0.006))  # piping
	if combo:  # the panel across the top front, with its knobs
		_box(node, Vector3(size.x - 0.04, 0.07, 0.012), _finish("panel"), Vector3(0, lift + size.y - 0.045, size.z / 2 + 0.002))
		for k in 6:
			_cylinder(node, 0.014, 0.02, _finish("knob_white"), Vector3(-0.2 + k * 0.07, lift + size.y - 0.045, size.z / 2 + 0.014), Vector3(PI / 2, 0, 0))
		_sphere(node, 0.01, accent, Vector3(size.x / 2 - 0.05, lift + size.y - 0.045, size.z / 2 + 0.01))  # the pilot light
		_box(node, Vector3(0.18, 0.03, 0.04), black, Vector3(0, lift + size.y + 0.015, 0))  # the handle
	for x in [-1.0, 1.0]:  # corners
		for y in [lift + 0.015, lift + size.y - 0.015]:
			for z in [-1.0, 1.0]:
				_box(node, Vector3(0.04, 0.04, 0.04), chrome, Vector3(x * (size.x / 2 - 0.01), y, z * (size.z / 2 - 0.01)))
	if casters:
		for x in [-1.0, 1.0]:
			for z in [-1.0, 1.0]:
				_sphere(node, 0.022, black, Vector3(x * (size.x / 2 - 0.06), 0.022, z * (size.z / 2 - 0.06)))


## A head sitting on top of a cabinet `on_top` metres high: a box with its faceplate in the accent colour and a row of
## knobs, a power switch, and a handle.
static func _amp_head(node: Node3D, accent: Material, size: Vector3, on_top: float) -> void:
	var black := _finish("black")
	var y := on_top + 0.015 + size.y / 2
	_box(node, size, black, Vector3(0, y, 0))
	_box(node, Vector3(size.x - 0.05, size.y * 0.55, 0.01), accent, Vector3(0, y - 0.01, size.z / 2 + 0.002))
	for k in 6:
		_cylinder(node, 0.016, 0.022, _finish("knob"), Vector3(-0.22 + k * 0.075, y - 0.01, size.z / 2 + 0.016), Vector3(PI / 2, 0, 0))
	_box(node, Vector3(0.02, 0.035, 0.02), _finish("chrome"), Vector3(size.x / 2 - 0.06, y - 0.01, size.z / 2 + 0.012))
	_box(node, Vector3(0.2, 0.03, 0.04), black, Vector3(0, on_top + size.y + 0.03, 0))


## The loop pedal: a little larger than the others, with a ring of light round its level knob that shows what it is
## doing. It stands on the floor at the origin, facing +z. Returns {node: Node3D, led: StandardMaterial3D}.
static func loop_pedal() -> Dictionary:
	var node := Node3D.new()
	var body := _plain(Color(0.2, 0.22, 0.26))
	body.metallic = 0.5
	_box(node, Vector3(0.075, 0.045, 0.125), body, Vector3(0, 0.0225, 0))
	_cylinder(node, 0.013, 0.02, _finish("chrome"), Vector3(0, 0.055, 0.025))  # the footswitch
	var led := StandardMaterial3D.new()
	led.albedo_color = Color(0.1, 0.1, 0.1)
	led.emission_enabled = true
	led.emission = Color(0, 0, 0)
	_ring(node, 0.018, 0.026, led, Vector3(0, 0.046, -0.025))  # its light, round a small level knob
	_cylinder(node, 0.012, 0.015, _finish("knob"), Vector3(0, 0.052, -0.025))
	return {"node": node, "led": led}


# ── Shared parts ────────────────────────────────────────────────────────────────────────────────────────────

## A drum: a shell in the accent colour with a head on top.
static func _drum(parent: Node3D, radius: float, depth: float, at: Vector3, turn: Vector3, shell: Material, head: Material) -> void:
	var drum := Node3D.new()
	drum.position = at
	drum.rotation = turn
	parent.add_child(drum)
	_cylinder(drum, radius, depth, shell, Vector3.ZERO)
	_cylinder(drum, radius * 0.97, 0.005, head, Vector3(0, depth / 2 + 0.002, 0))
	_ring(drum, radius * 0.97, radius * 1.05, _finish("chrome"), Vector3(0, depth / 2, 0))


## A stand's three legs, from a point on its pole down to the floor.
static func _tripod(parent: Node3D, top: Vector3, spread: float, material: Material) -> void:
	_rod(parent, Vector3(top.x, 0.0, top.z), top, 0.011, material)
	for i in 3:
		var a := TAU * i / 3.0 + PI / 2
		_rod(parent, Vector3(top.x, minf(0.35, top.y), top.z), Vector3(top.x + cos(a) * spread, 0.0, top.z + sin(a) * spread), 0.008, material)


## Piano keys: `whites` white keys starting from C, the front left corner of the first at `front_left` (key tops).
static func _keyboard(parent: Node3D, whites: int, front_left: Vector3) -> void:
	var white_mesh := BoxMesh.new()
	white_mesh.size = Vector3(KEY_WHITE - 0.0015, 0.02, 0.15)
	white_mesh.material = _finish("ivory")
	var black_mesh := BoxMesh.new()
	black_mesh.size = Vector3(KEY_WHITE * 0.55, 0.022, 0.095)
	black_mesh.material = _finish("ebony")
	var white_keys: Array = []
	var black_keys: Array = []
	for i in whites:
		var x := front_left.x + (i + 0.5) * KEY_WHITE
		white_keys.append(Vector3(x, front_left.y - 0.01, front_left.z - 0.075))
		if i % 7 in [0, 1, 3, 4, 5] and i < whites - 1:  # black keys sit after C, D, F, G and A
			black_keys.append(Vector3(x + KEY_WHITE / 2, front_left.y + 0.008, front_left.z - 0.1025))
	for group in [[white_mesh, white_keys], [black_mesh, black_keys]]:
		var multi := MultiMesh.new()
		multi.transform_format = MultiMesh.TRANSFORM_3D
		multi.mesh = group[0]
		multi.instance_count = group[1].size()
		for i in group[1].size():
			multi.set_instance_transform(i, Transform3D(Basis(), group[1][i]))
		var instance := MultiMeshInstance3D.new()
		instance.multimesh = multi
		parent.add_child(instance)


static func _box(parent: Node3D, size: Vector3, material: Material, at: Vector3, turn := Vector3.ZERO) -> MeshInstance3D:
	var mesh := BoxMesh.new()
	mesh.size = size
	return _place(parent, mesh, material, at, turn)


static func _cylinder(parent: Node3D, radius: float, height: float, material: Material, at: Vector3, turn := Vector3.ZERO) -> MeshInstance3D:
	var mesh := CylinderMesh.new()
	mesh.top_radius = radius
	mesh.bottom_radius = radius
	mesh.height = height
	mesh.radial_segments = 28 if radius > 0.05 else 12
	mesh.rings = 1
	return _place(parent, mesh, material, at, turn)


static func _ring(parent: Node3D, inner: float, outer: float, material: Material, at: Vector3, turn := Vector3.ZERO) -> MeshInstance3D:
	var mesh := TorusMesh.new()
	mesh.inner_radius = inner
	mesh.outer_radius = outer
	mesh.rings = 32
	mesh.ring_segments = 6
	return _place(parent, mesh, material, at, turn)


static func _sphere(parent: Node3D, radius: float, material: Material, at: Vector3, stretch := Vector3.ONE) -> MeshInstance3D:
	var mesh := SphereMesh.new()
	mesh.radius = radius
	mesh.height = radius * 2
	mesh.radial_segments = 12
	mesh.rings = 6
	var part := _place(parent, mesh, material, at, Vector3.ZERO)
	part.scale = stretch
	return part


## A thin round bar from one point to another.
static func _rod(parent: Node3D, from: Vector3, to: Vector3, radius: float, material: Material) -> MeshInstance3D:
	var mesh := CylinderMesh.new()
	mesh.top_radius = radius
	mesh.bottom_radius = radius
	mesh.height = from.distance_to(to)
	mesh.radial_segments = 8
	mesh.rings = 1
	var part := MeshInstance3D.new()
	part.mesh = mesh
	part.material_override = material
	parent.add_child(part)
	var along := (to - from).normalized()
	var side := along.cross(Vector3.FORWARD if absf(along.dot(Vector3.FORWARD)) < 0.9 else Vector3.RIGHT).normalized()
	part.transform = Transform3D(Basis(side, along, side.cross(along)).orthonormalized(), (from + to) / 2)
	return part


static func _place(parent: Node3D, mesh: Mesh, material: Material, at: Vector3, turn: Vector3) -> MeshInstance3D:
	var part := MeshInstance3D.new()
	part.mesh = mesh
	part.material_override = material
	part.position = at
	part.rotation = turn
	parent.add_child(part)
	return part


## The finishes models share: chrome, black hardware, cymbal bronze, drum heads, wood, piano keys and so on.
static func _finish(which: String) -> StandardMaterial3D:
	if _shared.has(which):
		return _shared[which]
	var specs := {  # albedo, metallic, roughness
		"chrome": [Color(0.78, 0.8, 0.86), 0.7, 0.2], "black": [Color(0.05, 0.052, 0.06), 0.0, 0.65],
		"bronze": [Color(0.86, 0.66, 0.32), 0.65, 0.3], "brass": [Color(0.9, 0.76, 0.42), 0.65, 0.25],
		"head": [Color(0.88, 0.87, 0.82), 0.0, 0.6], "wood": [Color(0.46, 0.28, 0.15), 0.0, 0.55],
		"panel": [Color(0.2, 0.21, 0.24), 0.4, 0.4], "knob": [Color(0.09, 0.09, 0.1), 0.0, 0.4],
		"ivory": [Color(0.93, 0.92, 0.88), 0.0, 0.35], "ebony": [Color(0.04, 0.04, 0.05), 0.0, 0.3],
		"cone": [Color(0.11, 0.11, 0.12), 0.0, 0.85], "grille": [Color(0.24, 0.24, 0.23), 0.0, 0.95],
		"knob_white": [Color(0.86, 0.85, 0.8), 0.0, 0.4],
	}
	var spec: Array = specs[which]
	var material := StandardMaterial3D.new()
	material.albedo_color = spec[0]
	material.metallic = spec[1]
	material.roughness = spec[2]
	_shared[which] = material
	return material


static func _plain(color: Color) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = 0.5
	return material
