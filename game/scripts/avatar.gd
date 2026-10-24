extends Node3D
## A body in the room: yours (seen from a microphone, the free camera or the title screen, never from your own eyes),
## and in time the other players'. Built in proportion to its height (Winter's anthropometric fractions of it),
## wearing headphones where its ears are, which is where it hears from. Each frame its legs and arms are placed from
## where its feet and hands should be (two-bone IK): walking, its feet step and its arms swing; carrying something,
## its hands hold it out; seated at a kit, its feet are on the pedals and its sticks over the hi-hat and the snare.
## It faces -z, as the player does; its left is -x.

const LAYER := 19  # the 3D layer it is drawn on, which your own eyes leave out
# Fractions of its height (D. A. Winter, Biomechanics and Motor Control of Human Movement).
const EARS := 0.922  # the middle of the head, between the ears
const EYES_UP := 0.0145  # the eyes, over the ears (about 2.5 cm)
const EYES_AHEAD := 0.049  # and in front of them (about 8.5 cm)
const SHOULDER := 0.818
const HIP := 0.53
const ANKLE := 0.039
const SHOULDER_OUT := 0.129  # each shoulder from the middle
const HIP_OUT := 0.05  # each hip joint
const UPPER_ARM := 0.186
const FOREARM := 0.146
const THIGH := 0.245
const SHANK := 0.246
const FOOT := 0.152
const HEAD := 0.065  # its radius
const SEAT_LEAN := 0.21  # seated, leaning a little in towards the kit (12°)
const HIP_OVER_SEAT := 0.05  # (seated, the hip joints over the seat)
const STICK := 0.4  # a drumstick's length, metres

var height := 1.75
var _parts := {}  # name → MeshInstance3D
var _stretch := {}  # name → its scale, kept as it is placed
var _phase := 0.0  # the walk's cycle (radians)
var _stride := 0.0  # how far each foot swings ahead and behind the hips, metres
var _travel := Vector3.FORWARD  # the way it last walked (in its own frame)


## Where its ears are (the middle of its head), from the floor under it: standing, or seated on a seat whose top is
## `seat_top` high (its hips over where it stands, leaning in).
static func ears_at(tall: float, seat_top := -1.0) -> Vector3:
	if seat_top < 0.0:
		return Vector3(0.0, EARS * tall, 0.0)
	var up := (EARS - HIP) * tall
	return Vector3(0.0, seat_top + HIP_OVER_SEAT * tall + cos(SEAT_LEAN) * up, -sin(SEAT_LEAN) * up)


## Where its eyes are from its ears, its head turned straight ahead.
static func eyes_from_ears(tall: float) -> Vector3:
	return Vector3(0.0, EYES_UP * tall, -EYES_AHEAD * tall)


## Its bones, in proportion to `tall` (metres), in `color` (its shirt, and its headphones' rings).
func build(tall: float, color: Color) -> void:
	height = tall
	for part in get_children():  # (gone at once, so the new pieces have their names)
		remove_child(part)
		part.queue_free()
	_parts.clear()
	_stretch.clear()
	var shirt := _material(color.darkened(0.15), 0.8)
	var trousers := _material(Color(0.2, 0.22, 0.27), 0.85)
	var skin := _material(Color(0.74, 0.72, 0.7), 0.6)  # (a mannequin's)
	var dark := _material(Color(0.06, 0.06, 0.07), 0.45)
	var glossy := _material(Color(0.05, 0.06, 0.08), 0.15)  # (its eyes)
	var h := tall
	_capsule("torso", 0.075 * h, 0.16 * h, shirt, Vector3(1.4, 1.0, 0.85))  # (0.31 of its height, end to end)
	_capsule("pelvis", 0.065 * h, 0.07 * h, trousers, Vector3(1.0, 1.0, 0.8))
	_capsule("neck", 0.03 * h, 0.024 * h, skin)
	var head := _sphere("head", HEAD * h, skin)
	# Its eyes, so others can see where it looks.
	for side in [-1.0, 1.0]:
		var eye := SphereMesh.new()
		eye.radius = 0.16 * HEAD * h
		eye.height = 2.0 * eye.radius
		var across := 0.34 * HEAD * h
		var each := _part("eye_%d" % side, eye, glossy, head)
		each.scale = Vector3(0.8, 1.15, 0.5)
		each.position = Vector3(side * across, (EYES_UP - 0.01) * h, -sqrt(HEAD * HEAD * h * h - across * across) * 0.97)
	# Headphones, over its ears: two cups and a band over the top of its head.
	var cup := CylinderMesh.new()
	cup.top_radius = 0.45 * HEAD * h
	cup.bottom_radius = 0.5 * HEAD * h
	cup.height = 0.32 * HEAD * h
	cup.radial_segments = 16
	for side in [-1.0, 1.0]:
		var each := _part("cup_%d" % side, cup, dark, head)
		each.rotation = Vector3(0.0, 0.0, PI / 2.0)
		each.position = Vector3(side * 0.98 * HEAD * h, -0.08 * HEAD * h, 0.0)
		var ring := TorusMesh.new()
		ring.inner_radius = 0.3 * HEAD * h
		ring.outer_radius = 0.42 * HEAD * h
		var accent := _part("ring_%d" % side, ring, _material(color.lightened(0.2), 0.4), head)
		accent.rotation = Vector3(0.0, 0.0, PI / 2.0)
		accent.position = Vector3(side * 1.15 * HEAD * h, -0.08 * HEAD * h, 0.0)
	var arc := 9
	for i in arc:  # (the band: short rods round a half circle)
		var a0 := PI * float(i) / arc
		var a1 := PI * float(i + 1) / arc
		var r := 1.06 * HEAD * h
		var from := Vector3(-cos(a0) * r, sin(a0) * r * 1.05 - 0.05 * HEAD * h, 0.05 * HEAD * h)
		var to := Vector3(-cos(a1) * r, sin(a1) * r * 1.05 - 0.05 * HEAD * h, 0.05 * HEAD * h)
		var rod := CylinderMesh.new()
		rod.top_radius = 0.08 * HEAD * h
		rod.bottom_radius = rod.top_radius
		rod.height = from.distance_to(to) + 0.01
		rod.radial_segments = 6
		var piece := _part("band_%d" % i, rod, dark, head)
		piece.transform = _between(from, to)
	for side in ["l", "r"]:
		_capsule("upper_arm_" + side, 0.026 * h, UPPER_ARM * h, shirt)
		_capsule("forearm_" + side, 0.021 * h, FOREARM * h, skin)
		_sphere("hand_" + side, 0.028 * h, skin, Vector3(0.7, 1.3, 1.0))
		_capsule("thigh_" + side, 0.042 * h, THIGH * h, trousers)
		_capsule("shank_" + side, 0.031 * h, SHANK * h, trousers)
		var shoe := BoxMesh.new()
		shoe.size = Vector3(0.056 * h, 0.042 * h, FOOT * h)
		_part("foot_" + side, shoe, dark)
		var stick := CylinderMesh.new()
		stick.top_radius = 0.006
		stick.bottom_radius = 0.008
		stick.height = STICK
		stick.radial_segments = 6
		_part("stick_" + side, stick, _material(Color(0.83, 0.7, 0.5), 0.5)).visible = false
	pose({}, 0.0)


## Places it for this frame. `state`: "pitch" (where its head looks, up or down, radians), "move" (how fast it goes
## over the floor and which way, in its own frame, m/s), "seat_top" (seated, on a seat this high under its hips),
## "feet" and "hands" ([left, right], where they should be, in its own frame; otherwise as it stands or walks),
## "sticks" ([left, right], where a drumstick in each hand points to).
func pose(state: Dictionary, delta: float) -> void:
	if _parts.is_empty():
		return
	var h := height
	var seated: bool = state.has("seat_top")
	var move: Vector3 = state.get("move", Vector3.ZERO)
	var speed := Vector2(move.x, move.z).length()
	# The walk: its feet swing ahead and behind, as far as it is going fast, each step as long as its speed needs.
	var wanted := 0.0 if seated else clampf(speed * 0.13, 0.0, 0.34) * h / 1.75
	_stride += (wanted - _stride) * (1.0 - exp(-delta * 8.0))
	if speed > 0.05:
		_travel = Vector3(move.x, 0.0, move.z).normalized()
	if _stride > 0.005:
		_phase = fmod(_phase + TAU * speed / maxf(4.0 * _stride, 0.2) * delta, TAU)
	var hips := Vector3(0.0, HIP * h, 0.0)
	var lean := 0.0
	if seated:
		hips = Vector3(0.0, float(state.seat_top) + HIP_OVER_SEAT * h, 0.0)
		lean = SEAT_LEAN
	else:
		hips.y -= 0.12 * _stride * (1.0 - absf(cos(_phase)))  # (lower as its legs are apart)
	var spine := Vector3(0.0, cos(lean), -sin(lean))
	var shoulders := hips + spine * (SHOULDER - HIP) * h
	var ears := hips + spine * (EARS - HIP) * h
	_place("pelvis", Transform3D(Basis(Vector3.BACK, PI / 2.0), hips))
	_place("torso", _between(hips + spine * 0.095 * h, hips + spine * 0.255 * h))
	_place("neck", _between(shoulders, ears - spine * 0.02 * h))
	var look := clampf(float(state.get("pitch", 0.0)), -1.1, 0.9)
	_place("head", Transform3D(Basis(Vector3.RIGHT, look), ears + Vector3(0.0, 0.01 * h, 0.0)))
	var feet: Array = state.get("feet", [])
	var hands: Array = state.get("hands", [])
	var sticks: Array = state.get("sticks", [])
	for i in 2:
		var side := -1.0 if i == 0 else 1.0
		var tag := "l" if i == 0 else "r"
		var phase := _phase + (0.0 if i == 0 else PI)
		# A leg: from its hip to where its foot goes, the knee bending forward.
		var hip := hips + Vector3(side * HIP_OUT * h, 0.0, 0.0)
		var ankle: Vector3
		if feet.size() == 2:
			ankle = feet[i]
		else:
			var lift := maxf(cos(phase), 0.0) * 0.25 * _stride
			ankle = Vector3(side * HIP_OUT * h * 1.2, ANKLE * h + lift, 0.0) + _travel * _stride * sin(phase)
		var leg := _bend(hip, ankle, THIGH * h, SHANK * h, Vector3(0.0, 0.1, -1.0))
		_place("thigh_" + tag, _between(hip, leg[0]))
		_place("shank_" + tag, _between(leg[0], leg[1]))
		var toe_down := 0.12 if feet.size() == 2 else 0.0  # (on a pedal)
		_place("foot_" + tag, Transform3D(Basis(Vector3.RIGHT, -toe_down),
			leg[1] + Vector3(0.0, -0.4 * ANKLE * h, -0.3 * FOOT * h)))
		# An arm: from its shoulder to where its hand goes, the elbow bending back and out.
		var shoulder := shoulders + Vector3(side * SHOULDER_OUT * h, -0.02 * h, 0.0)
		var hand: Vector3
		if hands.size() == 2:
			hand = hands[i]
		else:  # hanging, swinging against the leg on its side
			var swing := 0.6 * _stride * sin(phase) * _travel.dot(Vector3.FORWARD)
			hand = shoulder + Vector3(side * 0.035 * h, -(UPPER_ARM + FOREARM) * h * 0.96, swing)
		var arm := _bend(shoulder, hand, UPPER_ARM * h, FOREARM * h, Vector3(side * 0.5, -0.3, 1.0))
		_place("upper_arm_" + tag, _between(shoulder, arm[0]))
		_place("forearm_" + tag, _between(arm[0], arm[1]))
		_place("hand_" + tag, _between(arm[0], arm[1]).translated_local(Vector3(0.0, (FOREARM * h) / 2.0 + 0.02 * h, 0.0)))
		var stick: MeshInstance3D = _parts["stick_" + tag]
		stick.visible = sticks.size() == 2
		if stick.visible:
			var tip: Vector3 = sticks[i]
			var held: Vector3 = arm[1] + (arm[1] - arm[0]).normalized() * 0.03 * h
			stick.transform = _between(held - (tip - held).normalized() * 0.06, held + (tip - held).normalized() * (STICK - 0.06))


## Where a two-bone limb's middle joint goes, from its root towards `end`, its bones `a` and `b` long, bending
## towards `bend`; and where its end gets to (as near `end` as it reaches): [joint, end].
static func _bend(root: Vector3, end: Vector3, a: float, b: float, bend: Vector3) -> Array:
	var to := end - root
	var dir := to.normalized() if to.length() > 0.001 else Vector3.DOWN
	var d := clampf(to.length(), absf(a - b) + 0.001, a + b - 0.001)
	var along := (a * a - b * b + d * d) / (2.0 * d)
	var out := sqrt(maxf(a * a - along * along, 0.0))
	var side := bend - dir * bend.dot(dir)
	if side.length() < 0.001:
		side = Vector3.BACK - dir * Vector3.BACK.dot(dir)
	return [root + dir * along + side.normalized() * out, root + dir * d]


## A transform that stands a mesh's length (its y) from one point to another, its middle between them.
static func _between(from: Vector3, to: Vector3) -> Transform3D:
	var along := to - from
	if along.length() < 0.0001:
		return Transform3D(Basis(), from)
	var y := along.normalized()
	var x := y.cross(Vector3.BACK if absf(y.dot(Vector3.BACK)) < 0.9 else Vector3.RIGHT).normalized()
	return Transform3D(Basis(x, y, x.cross(y)).orthonormalized(), (from + to) / 2.0)


func _place(name: String, where: Transform3D) -> void:
	_parts[name].transform = where.scaled_local(_stretch.get(name, Vector3.ONE))


func _capsule(name: String, radius: float, length: float, material: Material, stretch := Vector3.ONE) -> MeshInstance3D:
	var mesh := CapsuleMesh.new()
	mesh.radius = radius
	mesh.height = length + 2.0 * radius
	mesh.radial_segments = 14
	mesh.rings = 4
	var part := _part(name, mesh, material)
	_stretch[name] = stretch
	return part


func _sphere(name: String, radius: float, material: Material, stretch := Vector3.ONE) -> MeshInstance3D:
	var mesh := SphereMesh.new()
	mesh.radius = radius
	mesh.height = 2.0 * radius
	mesh.radial_segments = 18
	mesh.rings = 9
	var part := _part(name, mesh, material)
	_stretch[name] = stretch
	return part


## A piece of it, on its layer: under `parent` (the head's pieces move with it), or else placed each frame.
func _part(name: String, mesh: Mesh, material: Material, parent: Node3D = null) -> MeshInstance3D:
	var part := MeshInstance3D.new()
	part.name = name
	part.mesh = mesh
	part.material_override = material
	part.layers = 1 << (LAYER - 1)
	(parent if parent != null else self).add_child(part)
	_parts[name] = part
	return part


static func _material(color: Color, roughness: float) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = roughness
	return material
