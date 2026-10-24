extends RefCounted
## Microphones for an acoustic kit, put up in one go as an engineer would set them: each a model suited to what it is
## on, named for it, where it goes on its drum (or over the kit, or out in the room), pointed at it, its gain set for
## how close it is, panned where its piece sits between the overheads (the drummer's view: the hi-hat on the left), and
## the snare's bottom mic in reverse polarity to its top one. All of them in a folder of their own, their inputs off.

const Models := preload("res://scripts/instrument_models.gd")

const SETUPS := {
	"full": {"name": "Mic the kit: close mics, overheads and room",
		"hint": "Kick in and out, snare top and bottom, both toms and the hi-hat, a spaced pair of overheads, and a pair of room mics out in front"},
	"close": {"name": "Mic the kit: close mics and overheads",
		"hint": "Kick in and out, snare top and bottom, both toms and the hi-hat, and a spaced pair of overheads"},
	"four": {"name": "Mic the kit: four mics (Glyn Johns)",
		"hint": "Kick and snare, an overhead over the snare and one beside the floor tom, the two as far from the snare as each other"},
}
const ORDER := ["full", "close", "four"]
const OVERHEAD_SPREAD := 1.1  # (metres between a spaced pair of overheads)
const ROOM_OUT := 2.5  # (how far out in front of the kick the room mics stand, if the room is deep enough)
const ROOM_MARGIN := 0.3  # (and how near a wall they may be)


## A head's middle and the way it faces, on the kit as it is modelled (from the floor up, the stool towards +z).
static func _head(drum: Dictionary, top := true) -> Dictionary:
	var up: Vector3 = Basis.from_euler(drum.turn) * Vector3.UP
	return {"at": drum.at + up * drum.depth / 2.0 * (1.0 if top else -1.0), "up": up if top else -up, "radius": drum.radius}


## A point over a head: `out` of the way to its rim (of its radius) towards `toward`, and `above` it.
static func _over(head: Dictionary, toward: Vector3, out: float, above: float) -> Vector3:
	var across: Vector3 = (toward - head.up * toward.dot(head.up)).normalized()
	return head.at + across * out * head.radius + head.up * above


## Each mic of a setup, on the kit as it is modelled: [{name, kind, at, aim (the point it is pointed at), pan, inverted}].
static func plan(setup: String) -> Array:
	var snare := _head(Models.KIT_SNARE)
	var under := _head(Models.KIT_SNARE, false)
	var batter := _head(Models.KIT_KICK)
	var front := _head(Models.KIT_KICK, false)
	var port: Vector3 = front.at + Vector3(Models.KIT_PORT.across.x, Models.KIT_PORT.across.y, 0.0)
	var rack := _head(Models.KIT_RACK)
	var floor_tom := _head(Models.KIT_FLOOR)
	var hats: Vector3 = Models.KIT_HATS.at
	# (the overheads centred between the snare and the kick: each piece panned where it sits between them)
	var middle: float = (snare.at.x + batter.at.x) / 2.0
	var pan := func(x: float) -> float: return clampf((x - middle) / (OVERHEAD_SPREAD / 2.0), -0.8, 0.8)
	var out := []
	if setup == "four":
		var side := Vector3(floor_tom.at.x + floor_tom.radius + 0.15, floor_tom.at.y + 0.15, floor_tom.at.z + 0.05)
		var reach: float = side.distance_to(snare.at)  # (the overhead as far from the snare's middle as the side one)
		out.append({"name": "Kick", "kind": "mic_kick", "at": port + Vector3(-0.04, 0.02, -0.08), "aim": port, "pan": 0.0})
		out.append({"name": "Snare", "kind": "mic_dynamic", "at": _over(snare, Vector3(-0.5, 0, -1), 0.8, 0.06), "aim": snare.at, "pan": 0.0})
		out.append({"name": "Overhead", "kind": "mic_condenser", "at": snare.at + Vector3(0.06, reach, -0.06), "aim": snare.at, "pan": -0.6})
		out.append({"name": "Side", "kind": "mic_condenser", "at": side, "aim": snare.at, "pan": 0.6})
		return out
	out.append({"name": "Kick In", "kind": "mic_kick", "at": batter.at - batter.up * 0.12 + Vector3(0.05, -0.04, 0.0),
		"aim": batter.at + Vector3(0.0, -0.02, 0.0), "pan": 0.0})
	out.append({"name": "Kick Out", "kind": "mic_kick", "at": port + Vector3(-0.04, 0.02, -0.08), "aim": port, "pan": 0.0})
	out.append({"name": "Snare Top", "kind": "mic_dynamic", "at": _over(snare, Vector3(-0.5, 0, -1), 0.8, 0.06), "aim": snare.at, "pan": 0.0})
	out.append({"name": "Snare Bottom", "kind": "mic_dynamic", "at": _over(under, Vector3(-1, 0, -0.3), 0.6, 0.06),
		"aim": under.at, "pan": 0.0, "inverted": true})
	out.append({"name": "Rack Tom", "kind": "mic_dynamic", "at": _over(rack, Vector3(0, 0, -1), 0.8, 0.06),
		"aim": _over(rack, Vector3(0, 0, -1), 0.1, 0.0), "pan": pan.call(rack.at.x)})
	out.append({"name": "Floor Tom", "kind": "mic_dynamic", "at": _over(floor_tom, Vector3(1, 0, -0.6), 0.8, 0.06),
		"aim": _over(floor_tom, Vector3(1, 0, -0.6), 0.1, 0.0), "pan": pan.call(floor_tom.at.x)})
	var away := Vector3(-0.6, 0.0, -1.0).normalized()  # (over its bow, pointed out at its edge, away from the snare)
	out.append({"name": "Hi-Hat", "kind": "mic_pencil", "at": hats + away * 0.6 * Models.KIT_HATS.radius + Vector3(0, 0.12, 0),
		"aim": hats + away * 0.9 * Models.KIT_HATS.radius, "pan": pan.call(hats.x)})
	for s in [-1.0, 1.0]:  # a spaced pair, 1.85 m up, as far from the snare as each other, pointed at it
		out.append({"name": "OH L" if s < 0 else "OH R", "kind": "mic_pencil", "at": Vector3(middle + s * OVERHEAD_SPREAD / 2.0, 1.85, snare.at.z - 0.15),
			"aim": snare.at, "pan": s})
	if setup == "full":  # out in front, 1.4 m up, a pair of large condensers pointed at the kit
		for s in [-1.0, 1.0]:
			out.append({"name": "Room L" if s < 0 else "Room R", "kind": "mic_condenser", "room": true,
				"at": Vector3(middle + s * 0.8, 1.4, front.at.z - ROOM_OUT), "aim": Vector3(middle, 0.8, batter.at.z), "pan": s})
	return out


## Puts a setup's mics up round `kit` (in a folder of their own, beside it in the mix) and returns them, or [] if there
## isn't room for them. The room mics come in as far as the room needs (or are left out, in a room too small for them).
## One a frame (each tells the audio core how it hears every part of the kit, and its reflections: a lot to say at once).
static func place(app, kit, setup: String) -> Array:
	var mics := plan(setup)
	var half: Vector3 = app.room.size / 2.0
	var room_mics := mics.filter(func(m): return m.get("room", false))
	if not room_mics.is_empty():  # (brought in towards the kit until both are well inside the walls)
		var fits := false
		var brought := 0.0
		while not fits and brought <= ROOM_OUT - 1.0:
			fits = room_mics.all(func(m):
				var at: Vector3 = kit.to_room(m.at + Vector3(0, 0, brought))
				return absf(at.x) <= half.x - ROOM_MARGIN and absf(at.z) <= half.z - ROOM_MARGIN)
			if not fits:
				brought += 0.25
		for m in room_mics:
			if fits:
				m.at += Vector3(0, 0, brought)
			else:
				mics.erase(m)
	if app.instruments.size() + mics.size() + 1 > app.instrument_capacity():  # (and their folder)
		return []
	var names: Array = app.instruments.map(func(i): return i.display_name)
	var placed := []
	for m in mics:
		if not placed.is_empty():
			await app.get_tree().process_frame
		if not app.instruments.has(kit):  # (taken out of the room meanwhile)
			break
		var at: Vector3 = kit.to_room(m.at)
		var mic = app.add_instrument(m.kind, at)
		if mic == null:
			break
		var named: String = m.name
		var number := 2
		while names.has(named):  # (a second kit's: Kick In 2...)
			named = "%s %d" % [m.name, number]
			number += 1
		names.append(named)
		app.rename_track(mic, named)
		app.set_mic_spot(mic, at.x, at.z)
		app.set_mic_height(mic, at.y)
		app.aim_mic_at(mic, kit.to_room(m.aim))
		var sensitivity: float = float(app.mic_model_info(mic.mic_model).get("sensitivity_db", 0.0))
		var nearest: float = mic.global_position.distance_to(kit.sound_point(mic.global_position))
		app.set_mic_gain(mic, clampf(20.0 * log(maxf(nearest, 0.05) / 1.5) / log(10.0) - sensitivity, -20.0, 40.0))
		app.set_mic_polarity(mic, m.get("inverted", false))
		app.set_pan(mic, m.pan)
		placed.append(mic)
	if not placed.is_empty():
		app.add_folder(placed, "%s Mics" % kit.display_name, app.folder_of(kit))
	return placed
