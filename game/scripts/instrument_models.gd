extends RefCounted
## What each kind of instrument looks like, built from simple shapes: a drum kit, a monophonic bass synth, a
## modular synth for the pad, tubular bells, an electric piano, a PA speaker on a tripod, and guitar and bass amps
## (combos, and heads on cabinets), each with its loop pedal on the floor in front. An amp's effect pedals are added
## beside the loop pedal as they are put on its board (stomp_box).
##
## Each model stands on the floor (y = 0) and faces +z. The parts drawn in the instrument's own colour use the
## `accent` material, which the instrument lights up as it plays. An amp's pedal has an `led` material too, which
## shows what the pedal is doing.

const KEY_WHITE := 0.0235  # width of a white key, in metres

static var _shared := {}  # finishes every model uses, made once


## Returns {node: Node3D, accent: StandardMaterial3D} and, for an amp, {led: StandardMaterial3D} and where its loop
## pedal stands, {pedal_spot: Vector3}.
static func build(kind: String, color: Color) -> Dictionary:
	var node := Node3D.new()
	var accent := StandardMaterial3D.new()
	accent.albedo_color = color.darkened(0.35)
	accent.roughness = 0.35
	accent.emission_enabled = true
	accent.emission = color
	var built := {"node": node, "accent": accent}
	match kind:
		"guitar_combo":
			_amp_box(node, accent, Vector3(0.62, 0.48, 0.25), false, 1)
			built.pedal_spot = Vector3(0, 0, 0.42)
		"guitar_stack":
			_amp_box(node, accent, Vector3(0.76, 0.76, 0.36), false, 4)  # the 4x12 cabinet
			_amp_head(node, accent, Vector3(0.74, 0.25, 0.27), 0.76)
			built.pedal_spot = Vector3(0, 0, 0.5)
		"bass_combo":
			_amp_box(node, accent, Vector3(0.56, 0.7, 0.42), true, 1)
			built.pedal_spot = Vector3(0, 0, 0.52)
		"bass_stack":
			_amp_box(node, accent, Vector3(0.6, 1.3, 0.45), false, 8)  # the 8x10 cabinet
			_amp_head(node, accent, Vector3(0.62, 0.24, 0.32), 1.3)
			built.pedal_spot = Vector3(0, 0, 0.55)
		"drums":
			_drum_kit(node, accent)
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
	if built.has("pedal_spot"):
		built.led = _loop_pedal(node, built.pedal_spot.z)
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

static func _drum_kit(node: Node3D, accent: Material) -> void:
	var chrome := _finish("chrome")
	var head := _finish("head")
	var black := _finish("black")
	var bronze := _finish("bronze")
	# Bass drum, on its side, with a hoop at each end.
	_cylinder(node, 0.27, 0.42, accent, Vector3(0, 0.29, 0.02), Vector3(PI / 2, 0, 0))
	_cylinder(node, 0.262, 0.006, head, Vector3(0, 0.29, 0.234), Vector3(PI / 2, 0, 0))
	for z in [-0.19, 0.23]:
		_ring(node, 0.262, 0.285, black, Vector3(0, 0.29, z), Vector3(PI / 2, 0, 0))
	for side in [-1.0, 1.0]:  # spurs
		_rod(node, Vector3(side * 0.24, 0.2, 0.15), Vector3(side * 0.36, 0.0, 0.28), 0.008, chrome)
	# Two toms on the bass drum, tilted towards the player.
	_rod(node, Vector3(0, 0.55, -0.02), Vector3(0, 0.74, -0.04), 0.012, chrome)
	for x in [-0.17, 0.17]:
		_drum(node, 0.14, 0.17, Vector3(x, 0.8, -0.04), Vector3(0.3, 0, -x * 0.6), accent, head)
	# Snare on its stand, to the left.
	_drum(node, 0.18, 0.13, Vector3(-0.45, 0.62, 0.2), Vector3(0.12, 0, 0), accent, head)
	_tripod(node, Vector3(-0.45, 0.55, 0.2), 0.22, chrome)
	# Floor tom on three legs, to the right.
	_drum(node, 0.2, 0.34, Vector3(0.5, 0.45, 0.18), Vector3.ZERO, accent, head)
	for i in 3:
		var a := TAU * i / 3.0 + 0.4
		_rod(node, Vector3(0.5 + cos(a) * 0.2, 0.5, 0.18 + sin(a) * 0.2), Vector3(0.5 + cos(a) * 0.26, 0.0, 0.18 + sin(a) * 0.26), 0.008, chrome)
	# Hi-hat: a pair of cymbals on a stand with a pedal.
	_tripod(node, Vector3(-0.75, 0.9, 0.05), 0.24, chrome)
	for y in [0.9, 0.925]:
		_cylinder(node, 0.18, 0.006, bronze, Vector3(-0.75, y, 0.05))
	_box(node, Vector3(0.09, 0.02, 0.25), black, Vector3(-0.75, 0.01, 0.22))
	# Crash and ride on boom stands behind.
	_tripod(node, Vector3(0.55, 1.18, -0.38), 0.26, chrome)
	_rod(node, Vector3(0.55, 1.18, -0.38), Vector3(0.45, 1.32, -0.25), 0.01, chrome)
	_cylinder(node, 0.23, 0.006, bronze, Vector3(0.45, 1.33, -0.24), Vector3(0.35, 0, 0.2))
	_tripod(node, Vector3(0.85, 1.0, -0.12), 0.24, chrome)
	_cylinder(node, 0.26, 0.007, bronze, Vector3(0.82, 1.02, -0.06), Vector3(0.22, 0, -0.25))
	# The drummer's stool, behind.
	_cylinder(node, 0.17, 0.08, black, Vector3(0, 0.52, -0.62))
	_tripod(node, Vector3(0, 0.48, -0.62), 0.22, chrome)


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


## A guitar or bass amp's box: tolex all round, grille cloth on the front, metal corners, and (for a combo) the
## control panel along the top. `speakers` only sets how the grille is divided: one big panel, or a cabinet's look.
static func _amp_box(node: Node3D, accent: Material, size: Vector3, casters: bool, speakers: int) -> void:
	var black := _finish("black")
	var grille := _finish("grille")
	var chrome := _finish("chrome")
	var lift := 0.05 if casters else 0.015
	_box(node, size, black, Vector3(0, lift + size.y / 2, 0))
	var face_height := size.y - (0.11 if speakers == 1 else 0.06)
	_box(node, Vector3(size.x - 0.06, face_height - 0.04, 0.01), grille,
		Vector3(0, lift + 0.03 + (face_height - 0.04) / 2, size.z / 2 + 0.002))
	_box(node, Vector3(size.x - 0.04, 0.012, 0.012), accent, Vector3(0, lift + 0.03 + face_height - 0.03, size.z / 2 + 0.006))  # piping
	if speakers == 1:  # a combo: the panel across the top front, with its knobs
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


## The loop pedal on the floor in front of an amp, `ahead` metres out. Returns its light's material.
static func _loop_pedal(node: Node3D, ahead: float) -> StandardMaterial3D:
	var body := _plain(Color(0.2, 0.22, 0.26))
	body.metallic = 0.5
	_box(node, Vector3(0.075, 0.045, 0.125), body, Vector3(0, 0.0225, ahead))
	_cylinder(node, 0.013, 0.02, _finish("chrome"), Vector3(0, 0.055, ahead + 0.025))  # the footswitch
	var led := StandardMaterial3D.new()
	led.albedo_color = Color(0.1, 0.1, 0.1)
	led.emission_enabled = true
	led.emission = Color(0, 0, 0)
	_ring(node, 0.018, 0.026, led, Vector3(0, 0.046, ahead - 0.025))  # its light, round a small level knob
	_cylinder(node, 0.012, 0.015, _finish("knob"), Vector3(0, 0.052, ahead - 0.025))
	return led


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
