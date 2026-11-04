extends Node3D
## A body in the room: yours (seen from a microphone, the free camera or the title screen, never from your own eyes),
## and the other players'. Built in proportion to its height (Winter's anthropometric fractions of it), as its player
## has chosen it to look (LOOK: a male or female build, skin, hair, and a shirt, trousers and shoes), wearing
## headphones where its ears are, which is where it hears from. Each frame its legs and arms are placed from
## where its feet and hands should be (two-bone IK): walking, its feet step and its arms swing; carrying something,
## its hands hold it out; seated at a kit, its feet are on the pedals and its sticks over the hi-hat and the snare.
## It faces -z, as the player does; its left is -x.

const LAYER := 19  # the 3D layer your own body is drawn on, which your own eyes leave out (another player's: the first)
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
const STOOL_TOP := 0.56  # a kit's stool's top (instrument_models.gd)

## What a body can look like, as the title screen's Avatar customization page sets it: each choice a name (a build, a
## hair style, a piece of clothing) or a place in one of these lists of colours, so that it goes to the other players
## as it is. Shown in this order.
const BODIES := {"male": "Male", "female": "Female"}
const SKINS := [Color(0.97, 0.86, 0.78), Color(0.93, 0.77, 0.65), Color(0.86, 0.67, 0.53), Color(0.77, 0.57, 0.43),
	Color(0.65, 0.46, 0.33), Color(0.53, 0.36, 0.25), Color(0.41, 0.27, 0.19), Color(0.29, 0.19, 0.13)]
const HAIRS := {"short": "Short", "buzz": "Buzz cut", "long": "Long", "ponytail": "Ponytail", "bun": "Bun", "curly": "Curly",
	"bald": "Bald"}
const HAIR_COLORS := [Color(0.06, 0.05, 0.045), Color(0.18, 0.11, 0.06), Color(0.33, 0.2, 0.11), Color(0.5, 0.2, 0.08),
	Color(0.78, 0.62, 0.36), Color(0.88, 0.84, 0.74), Color(0.58, 0.58, 0.6), Color(0.2, 0.35, 0.75), Color(0.85, 0.36, 0.62)]
const SHIRTS := {"tshirt": "T-shirt", "long": "Long sleeves", "hoodie": "Hoodie", "tank": "Tank top"}
const PANTS := {"trousers": "Trousers", "shorts": "Shorts", "skirt": "Skirt"}
const SHOES := {"sneakers": "Sneakers", "boots": "Boots", "dress": "Dress shoes"}
const CLOTHES := [Color(0.08, 0.08, 0.09), Color(0.24, 0.25, 0.28), Color(0.55, 0.56, 0.58), Color(0.92, 0.92, 0.9),
	Color(0.12, 0.16, 0.32), Color(0.26, 0.45, 0.78), Color(0.22, 0.33, 0.5), Color(0.12, 0.5, 0.5), Color(0.22, 0.42, 0.24),
	Color(0.4, 0.4, 0.22), Color(0.7, 0.16, 0.14), Color(0.42, 0.1, 0.16), Color(0.85, 0.5, 0.15), Color(0.86, 0.75, 0.3),
	Color(0.42, 0.26, 0.6), Color(0.66, 0.55, 0.4)]
## How a body looks until its player chooses otherwise.
const LOOK := {"body": "male", "skin": 3, "hair": "short", "hair_color": 1, "shirt": "tshirt", "shirt_color": 5,
	"pants": "trousers", "pants_color": 1, "shoes": "sneakers", "shoes_color": 0}
const CHOICES := {"body": BODIES, "hair": HAIRS, "shirt": SHIRTS, "pants": PANTS, "shoes": SHOES}
const PALETTES := {"skin": SKINS, "hair_color": HAIR_COLORS, "shirt_color": CLOTHES, "pants_color": CLOTHES, "shoes_color": CLOTHES}

var height := 1.75
var layer := LAYER
var look := LOOK.duplicate()
var _shoulder_out := SHOULDER_OUT
var _hip_out := HIP_OUT
var _name_text := ""
var _tag: Label3D  # its name, over its head
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


## A look as it can be (from the settings, or another player): whatever isn't one of the choices is as LOOK has it.
static func look_of(given) -> Dictionary:
	var out := LOOK.duplicate()
	if not given is Dictionary:
		return out
	for key in CHOICES:
		if CHOICES[key].has(str(given.get(key, ""))):
			out[key] = str(given[key])
	for key in PALETTES:
		if given.has(key) and (given[key] is int or given[key] is float):
			out[key] = clampi(int(given[key]), 0, PALETTES[key].size() - 1)
	return out


## Its bones, in proportion to `tall` (metres), looking as `chosen` says (look_of), its headphones' rings in `accent`
## (its player's colour), drawn on `on_layer`.
func build(tall: float, chosen: Dictionary, accent: Color, on_layer := LAYER) -> void:
	height = tall
	layer = on_layer
	look = look_of(chosen)
	var female: bool = look.body == "female"
	_shoulder_out = 0.116 if female else SHOULDER_OUT  # (narrower shoulders, wider hips)
	_hip_out = 0.056 if female else HIP_OUT
	for part in get_children():  # (gone at once, so the new pieces have their names)
		remove_child(part)
		part.queue_free()
	_parts.clear()
	_stretch.clear()
	_tag = Label3D.new()
	_tag.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_tag.pixel_size = 0.0016
	_tag.font_size = 44
	_tag.outline_size = 12
	_tag.modulate = Color(0.95, 0.96, 1.0)
	_tag.outline_modulate = Color(0.02, 0.03, 0.05, 0.8)
	_tag.layers = 1 << (layer - 1)
	add_child(_tag)
	set_name_tag(_name_text)
	var shirt := _material(CLOTHES[look.shirt_color], 0.8)
	var trousers := _material(CLOTHES[look.pants_color], 0.85)
	var shoes := _material(CLOTHES[look.shoes_color], 0.2 if look.shoes == "dress" else 0.55)
	var skin := _material(SKINS[look.skin], 0.6)
	var hair := _material(HAIR_COLORS[look.hair_color], 0.75)
	hair.cull_mode = BaseMaterial3D.CULL_DISABLED  # (seen from below, inside it too)
	var dark := _material(Color(0.06, 0.06, 0.07), 0.45)
	var glossy := _material(Color(0.05, 0.06, 0.08), 0.15)  # (its eyes)
	var h := tall
	# (0.31 of its height, end to end)
	var torso := _capsule("torso", 0.075 * h, 0.16 * h, shirt, Vector3(1.25, 1.0, 0.85) if female else Vector3(1.4, 1.0, 0.85))
	if female:  # (a little fuller at the chest)
		var chest := CapsuleMesh.new()
		chest.radius = 0.027 * h
		chest.height = 0.105 * h
		var bust := _part("chest", chest, shirt, torso)
		bust.rotation = Vector3(0.0, 0.0, PI / 2.0)
		bust.position = Vector3(0.0, 0.035 * h, -0.056 * h)
	if look.shirt == "hoodie":  # (its hood rolled round the neck, and its pocket in front)
		var rolled := TorusMesh.new()
		rolled.inner_radius = 0.022 * h
		rolled.outer_radius = 0.05 * h
		rolled.rings = 16
		rolled.ring_segments = 10
		_part("hood", rolled, shirt, torso).position = Vector3(0.0, 0.15 * h, 0.012 * h)
		var flat := BoxMesh.new()
		flat.size = Vector3(0.1 * h, 0.045 * h, 0.012 * h)
		_part("pocket", flat, _material(CLOTHES[look.shirt_color].darkened(0.18), 0.85), torso).position = Vector3(0.0, -0.075 * h, -0.072 * h)
	_capsule("pelvis", 0.065 * h, (0.085 if female else 0.07) * h, trousers, Vector3(1.0, 1.0, 0.8))
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
		var lit := _part("ring_%d" % side, ring, _material(accent.lightened(0.2), 0.4), head)
		lit.rotation = Vector3(0.0, 0.0, PI / 2.0)
		lit.position = Vector3(side * 1.15 * HEAD * h, -0.08 * HEAD * h, 0.0)
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
	_hair(hair, head, h)
	var sleeve := skin if look.shirt == "tank" else shirt
	var cuff := shirt if look.shirt in ["long", "hoodie"] else skin
	var upper_leg := skin if look.pants == "skirt" else trousers
	var lower_leg := trousers if look.pants == "trousers" else skin
	if look.pants == "skirt":  # (flaring from the waist to above the knee: placed each frame, as the legs are)
		var flare := CylinderMesh.new()
		flare.top_radius = 0.115 * h  # (its top is at the hem, as it is placed: from the waist down)
		flare.bottom_radius = 0.072 * h
		flare.height = 0.2 * h
		flare.radial_segments = 18
		_part("skirt", flare, trousers)
	for side in ["l", "r"]:
		_capsule("upper_arm_" + side, 0.026 * h, UPPER_ARM * h, sleeve)
		_capsule("forearm_" + side, 0.021 * h, FOREARM * h, cuff)
		_sphere("hand_" + side, 0.028 * h, skin, Vector3(0.7, 1.3, 1.0))
		_capsule("thigh_" + side, 0.042 * h, THIGH * h, upper_leg)
		_capsule("shank_" + side, 0.031 * h, SHANK * h, lower_leg)
		_shoe(side, shoes, h)
		var stick := CylinderMesh.new()
		stick.top_radius = 0.006
		stick.bottom_radius = 0.008
		stick.height = STICK
		stick.radial_segments = 6
		_part("stick_" + side, stick, _material(Color(0.83, 0.7, 0.5), 0.5)).visible = false
	pose({}, 0.0)


## Its name, shown over its head ("" for none).
func set_name_tag(text: String) -> void:
	_name_text = text
	if _tag != null:
		_tag.text = text
		_tag.visible = text != ""


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
	if _parts.has("skirt"):
		_place("skirt", _between(hips + spine * 0.03 * h, hips - spine * 0.17 * h))
	var look := clampf(float(state.get("pitch", 0.0)), -1.1, 0.9)
	_place("head", Transform3D(Basis(Vector3.RIGHT, look), ears + Vector3(0.0, 0.01 * h, 0.0)))
	_tag.position = ears + Vector3(0.0, 0.14 * h, 0.0)
	var feet: Array = state.get("feet", [])
	var hands: Array = state.get("hands", [])
	var sticks: Array = state.get("sticks", [])
	for i in 2:
		var side := -1.0 if i == 0 else 1.0
		var tag := "l" if i == 0 else "r"
		var phase := _phase + (0.0 if i == 0 else PI)
		# A leg: from its hip to where its foot goes, the knee bending forward.
		var hip := hips + Vector3(side * _hip_out * h, 0.0, 0.0)
		var ankle: Vector3
		if feet.size() == 2:
			ankle = feet[i]
		else:
			var lift := maxf(cos(phase), 0.0) * 0.25 * _stride
			ankle = Vector3(side * _hip_out * h * 1.2, ANKLE * h + lift, 0.0) + _travel * _stride * sin(phase)
		var leg := _bend(hip, ankle, THIGH * h, SHANK * h, Vector3(0.0, 0.1, -1.0))
		_place("thigh_" + tag, _between(hip, leg[0]))
		_place("shank_" + tag, _between(leg[0], leg[1]))
		var toe_down := 0.12 if feet.size() == 2 else 0.0  # (on a pedal)
		_place("foot_" + tag, Transform3D(Basis(Vector3.RIGHT, -toe_down),
			leg[1] + Vector3(0.0, -0.4 * ANKLE * h, -0.3 * FOOT * h)))
		# An arm: from its shoulder to where its hand goes, the elbow bending back and out.
		var shoulder := shoulders + Vector3(side * _shoulder_out * h, -0.02 * h, 0.0)
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


## What a body is doing, as pose() takes it: standing at `at` (on the floor, facing its -z), `tall`, looking up or down
## by `pitch`, going `going` (in its own frame, m/s), seated at `kit` (on its stool: its feet on its pedals, its
## sticks over its hi-hat and snare) or not (null), and `holding` "carry" (its hands holding something out), "play"
## (its hands on keys) or "".
static func state_for(at: Transform3D, tall: float, pitch: float, going: Vector3, kit, holding: String) -> Dictionary:
	var state := {"pitch": pitch, "move": going}
	var k := tall / 1.75
	if kit != null:
		var mine := at.affine_inverse()
		state.seat_top = STOOL_TOP
		state.feet = [mine * kit.to_room(Vector3(-0.56, 0.09, 0.42)), mine * kit.to_room(Vector3(0.04, 0.09, 0.36))]
		state.hands = [mine * kit.to_room(Vector3(-0.15, 0.85, 0.5)), mine * kit.to_room(Vector3(-0.22, 1.0, 0.38))]
		state.sticks = [mine * kit.to_room(Vector3(-0.28, 0.69, 0.23)), mine * kit.to_room(Vector3(-0.47, 0.94, 0.15))]
	elif holding == "carry":
		state.hands = [Vector3(-0.17, 1.12, -0.42) * k, Vector3(0.17, 1.12, -0.42) * k]
	elif holding == "play":
		state.hands = [Vector3(-0.15, 0.98, -0.38) * k, Vector3(0.15, 0.98, -0.38) * k]
	return state


## Its hair, on its head (turning with it), as its look has it: a cap from high over the brow to low at the nape, so
## its face shows and its headphones' cups stand out of it, and what a style adds to that.
func _hair(finish: Material, head: Node3D, h: float) -> void:
	if look.hair == "bald":
		return
	var r := HEAD * h
	var size: float = {"buzz": 1.03, "short": 1.09, "long": 1.08, "ponytail": 1.06, "bun": 1.06, "curly": 1.2}[look.hair]
	var dome := SphereMesh.new()
	dome.radius = size * r
	dome.height = size * r
	dome.is_hemisphere = true
	dome.radial_segments = 20
	dome.rings = 8
	var cap := _part("hair_cap", dome, finish, head)
	cap.rotation.x = 0.42  # (its edge tilted: high at the front, low at the back)
	cap.position = Vector3(0.0, 0.06 * r, 0.02 * r)
	if look.hair == "curly":  # (curls all over it)
		cap.scale = Vector3(0.93, 1.1, 1.0)
		var curl := SphereMesh.new()
		curl.radius = 0.3 * r
		curl.height = 0.6 * r
		curl.radial_segments = 10
		curl.rings = 5
		var n := 0
		for ring in [[0.25, 9], [0.7, 8], [1.1, 5], [1.57, 1]]:  # (how far up from its edge, and how many round it)
			for k in ring[1]:
				var round_it: float = TAU * (float(k) + 0.5 * float(n % 2)) / float(ring[1])
				var up: float = ring[0]
				_part("hair_curl_%d" % n, curl, finish, cap).position = size * r * Vector3(cos(up) * sin(round_it), sin(up), cos(up) * cos(round_it))
				n += 1
	match look.hair:
		"long":  # falling behind, over the shoulders
			var fall := CapsuleMesh.new()
			fall.radius = 0.75 * r
			fall.height = 2.5 * r
			var back := _part("hair_long", fall, finish, head)
			back.position = Vector3(0.0, -1.0 * r, 0.75 * r)
			back.scale = Vector3(1.15, 1.0, 0.55)
		"ponytail":
			var knot := SphereMesh.new()
			knot.radius = 0.3 * r
			knot.height = 0.6 * r
			_part("hair_tie", knot, finish, head).position = Vector3(0.0, 0.25 * r, 1.0 * r)
			var tail := CapsuleMesh.new()
			tail.radius = 0.24 * r
			tail.height = 1.7 * r
			var hanging := _part("hair_ponytail", tail, finish, head)
			hanging.position = Vector3(0.0, -0.5 * r, 1.2 * r)
			hanging.rotation.x = -0.25
		"bun":
			var knot := SphereMesh.new()
			knot.radius = 0.42 * r
			knot.height = 0.84 * r
			_part("hair_bun", knot, finish, head).position = Vector3(0.0, 0.75 * r, 0.75 * r)


## A shoe on the `side` foot, as its look has it: sneakers (a white sole under them), boots (up over the ankle), or
## dress shoes (low and glossy).
func _shoe(side: String, finish: Material, h: float) -> void:
	var box := BoxMesh.new()
	box.size = Vector3((0.05 if look.shoes == "dress" else 0.056) * h, (0.034 if look.shoes == "dress" else 0.042) * h,
		(1.05 if look.shoes == "dress" else 1.0) * FOOT * h)
	var foot := _part("foot_" + side, box, finish)
	if look.shoes == "sneakers":
		var sole := BoxMesh.new()
		sole.size = Vector3(0.058 * h, 0.012 * h, 1.02 * FOOT * h)
		_part("sole_" + side, sole, _material(Color(0.9, 0.9, 0.88), 0.7), foot).position.y = -0.018 * h
	elif look.shoes == "boots":
		var shaft := CylinderMesh.new()
		shaft.top_radius = 0.034 * h
		shaft.bottom_radius = 0.034 * h
		shaft.height = 0.1 * h
		shaft.radial_segments = 12
		# (the ankle is up from the foot's middle and back: where it is placed from)
		_part("boot_" + side, shaft, finish, foot).position = Vector3(0.0, 0.4 * ANKLE * h + 0.05 * h, 0.3 * FOOT * h)


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
	part.layers = 1 << (layer - 1)
	(parent if parent != null else self).add_child(part)
	_parts[name] = part
	return part


static func _material(color: Color, roughness: float) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = roughness
	return material
