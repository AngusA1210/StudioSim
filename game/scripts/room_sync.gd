extends RefCounted
## The room kept the same for everyone playing together (net.gd). A few times a second, what is shared of the room is
## compared with what was last sent or heard, and only what changed goes: an instrument put in or taken out, where
## each stands (ten times a second, so one being carried follows), each one's settings, pattern and level in the room
## (three times), its plug-ins' own settings (every three seconds: each is read from the plug-in), and the room itself
## (its size, walls and surfaces, the tempo and swing, the reverb). What one player changes goes to the host, which
## passes it on to everyone in the order it came, the player who changed it too: the host's order is everyone's, so two
## changes to the same thing at once end the same way everywhere (each player's own change, coming back, is let be
## unless someone else's came in between).
##
## Shared: the room, and each instrument's place, name, colour, lock, settings (an amp's, its pedals', a microphone's,
## its inserts, a plug-in instrument's plug-in), pattern and level in the room. Each player's own: the mix window (the
## faders, mute and solo, pans, folders, aux tracks, sends and masters), which inputs are on, and what they hear.

const Library := preload("res://scripts/library.gd")
const PLACE_EVERY := 0.1
const STATE_EVERY := 0.3
const STATES_EVERY := 3.0

var app
var net
var applying := false  # what came from elsewhere is being applied: not to be sent back
var _known := {}  # net id → {"place", "state", "states"}: hashes of what was last sent or heard
var _room_known := 0
var _wanted := {}  # net id → what was shared of its plug-ins that isn't installed here: {"insert:0": entry, ...}
var _in_flight := {}  # "id:aspect" → this player's changes on their way to the host and back
var _overridden := {}  # "id:aspect" → someone else's change applied while this player's were on their way
var _count := 0
var _since_place := 0.0
var _since_state := 0.0
var _since_states := 0.0


func setup(the_app, the_net) -> void:
	app = the_app
	net = the_net


static func id_of(inst) -> String:
	return str(inst.get_meta("net_id", ""))


func find(id: String):
	for inst in app.instruments:
		if id_of(inst) == id:
			return inst
	return null


## Every instrument named for the network (the host's own, as it begins to host; or a joining player's, in the order
## the host's room listed them), and what is shared of the room as it is now, so that only changes go from here on.
func adopt(ids := []) -> void:
	_known.clear()
	_wanted.clear()
	_in_flight.clear()
	_overridden.clear()
	for i in app.instruments.size():
		var inst = app.instruments[i]
		inst.set_meta("net_id", str(ids[i]) if i < ids.size() else _new_id())
		_baseline(inst)
	_room_known = hash(room_entry())


func ids() -> Array:
	return app.instruments.map(id_of)


func _new_id() -> String:
	_count += 1
	return "%d-%d" % [net.me, _count]


func _baseline(inst) -> void:
	_known[id_of(inst)] = {"place": hash(place_of(inst)), "state": hash(state_of(inst)), "states": hash(states_of(inst))}


# ── What is shared ───────────────────────────────────────────────────────────────────────────────────────────

## Where an instrument stands: across and along the room, which way it faces, and a microphone's height and tilt.
func place_of(inst) -> Array:
	return [snappedf(inst.global_position.x, 0.001), snappedf(inst.global_position.z, 0.001), snappedf(inst.rotation.y, 0.001),
		snappedf(inst.source_height, 0.001), snappedf(inst.mic_tilt, 0.01)]


## What is shared of an instrument but its place and its plug-ins' own settings.
func state_of(inst) -> Dictionary:
	var settings: Dictionary = app.library.instrument_settings(inst, false)
	settings.erase("pan")  # (a microphone's track's: the mix's, each player's own)
	var wanted: Dictionary = _wanted.get(id_of(inst), {})
	if not wanted.is_empty():  # (a plug-in shared that isn't installed here is still the room's, though empty here)
		var inserts: Array = settings.get("inserts", [])
		for slot in inserts.size():
			if inserts[slot] == null and wanted.has("insert:%d" % slot):
				inserts[slot] = wanted["insert:%d" % slot]
		if wanted.has("instrument") and not settings.has("instrument_plugin"):
			settings.instrument_plugin = wanted.instrument
	var out := {"kind": inst.kind, "color": Library._color_data(inst.color), "room_db": snappedf(inst.room_db, 0.01),
		"room_muted": inst.room_muted, "locked": inst.locked, "settings": settings}
	if inst.named:
		out.name = inst.display_name
	if inst.is_stereo_mic:
		out.stereo = {"technique": inst.pair_technique, "spacing": inst.pair_spacing, "side_model": inst.side_model, "width": inst.ms_width}
	if inst.playable:
		out.loop_on = inst.loop_on
		out.steps = app.audio.get_pattern_steps(inst.source_id)
		out.pattern = app.audio.get_pattern(inst.source_id)
	return out


## Its plug-ins' own settings, each as the plug-in keeps it: {"insert:0": base64, "pedal:2": ..., "instrument:0": ...}.
func states_of(inst) -> Dictionary:
	var audio = app.audio
	var out := {}
	var inserts: Array = audio.get_inserts(inst.source_id)
	for slot in inserts.size():
		if inserts[slot].plugin_id != "":
			out["insert:%d" % slot] = Marshalls.raw_to_base64(audio.get_plugin_state(inst.source_id, "insert", slot))
	if inst.is_amp:
		var board: Array = audio.get_pedals(inst.source_id)
		for i in board.size():
			if board[i].kind == "plugin" and board[i].plugin_id != "":
				out["pedal:%d" % i] = Marshalls.raw_to_base64(audio.get_plugin_state(inst.source_id, "pedal", i))
	if inst.plays_plugin and str(audio.get_instrument_plugin(inst.source_id).get("plugin_id", "")) != "":
		out["instrument:0"] = Marshalls.raw_to_base64(audio.get_plugin_state(inst.source_id, "instrument", 0))
	return out


## The room's own: its size, walls and surfaces, the tempo and swing, and its reverb.
func room_entry() -> Dictionary:
	var room = app.room
	var walls := []
	for wall in room.walls:
		walls.append([snappedf(wall.a.x, 0.001), snappedf(wall.a.y, 0.001), snappedf(wall.b.x, 0.001), snappedf(wall.b.y, 0.001),
			snappedf(wall.height, 0.001), wall.get("material", room.DEFAULT_WALL_MATERIAL)])
	return {"size": [snappedf(room.size.x, 0.001), snappedf(room.size.y, 0.001), snappedf(room.size.z, 0.001)], "walls": walls,
		"surfaces": room.surfaces.duplicate(), "tempo": snappedf(app.tempo, 0.01), "swing": snappedf(app.swing, 0.001),
		"reverb_db": snappedf(app.reverb_db, 0.01)}


# ── Sending what changed here ────────────────────────────────────────────────────────────────────────────────

func tick(delta: float) -> void:
	if applying:
		return
	_since_place += delta
	_since_state += delta
	_since_states += delta
	var present := {}
	for inst in app.instruments:  # put in here (by this player, or by opening a room as the host)
		var id := id_of(inst)
		if id == "" or not _known.has(id):
			if id == "":
				id = _new_id()
				inst.set_meta("net_id", id)
			_baseline(inst)
			net.share("add", {"id": id, "place": place_of(inst), "state": state_of(inst), "states": states_of(inst)})
		present[id] = true
	for id in _known.keys():  # taken out
		if not present.has(id):
			_known.erase(id)
			_wanted.erase(id)
			net.share("remove", {"id": id})
	if _since_place >= PLACE_EVERY:
		_since_place = 0.0
		for inst in app.instruments:
			_send_if_changed(inst, "place", place_of(inst))
	if _since_state >= STATE_EVERY:
		_since_state = 0.0
		for inst in app.instruments:
			_send_if_changed(inst, "state", state_of(inst))
		var room := room_entry()
		var room_hash := hash(room)
		if room_hash != _room_known:
			_room_known = room_hash
			_mine("room")
			net.share("room", {"id": "room", "room": room})
	if _since_states >= STATES_EVERY:
		_since_states = 0.0
		for inst in app.instruments:
			_send_if_changed(inst, "states", states_of(inst))


func _send_if_changed(inst, aspect: String, value) -> void:
	var id := id_of(inst)
	var h := hash(value)
	if not _known.has(id) or _known[id][aspect] == h:
		return
	_known[id][aspect] = h
	_mine("%s:%s" % [id, aspect])
	net.share(aspect, {"id": id, aspect: value})


## A change of this player's on its way to the host and back (the host's own needs no answer: it is the order).
func _mine(key: String) -> void:
	if net.role != "host":
		_in_flight[key] = int(_in_flight.get(key, 0)) + 1


# ── Applying what came from elsewhere ────────────────────────────────────────────────────────────────────────

## A change from the network: `from` is the player it came from (this one's own, coming back from the host, is let be
## unless someone else's came in between, when it is applied again, the host's order being everyone's).
func receive(kind: String, data: Dictionary) -> void:
	var id := str(data.get("id", ""))
	var key := "room" if kind == "room" else "%s:%s" % [id, kind]
	if int(data.get("from", 0)) == net.me:
		if kind in ["add", "remove"]:
			return
		_in_flight[key] = maxi(int(_in_flight.get(key, 0)) - 1, 0)
		var again: bool = _overridden.get(key, false)
		if _in_flight[key] == 0:
			_overridden.erase(key)
		if not again:
			return
	elif int(_in_flight.get(key, 0)) > 0:
		_overridden[key] = true
	applying = true
	match kind:
		"add":
			_add(data)
		"remove":
			var gone = find(id)
			if gone != null:
				app.remove_instrument(gone)
			_known.erase(id)
			_wanted.erase(id)
		"place":
			var inst = find(id)
			if inst != null and app.player.carried != inst:
				_apply_place(inst, data.place)
				_known[id].place = hash(place_of(inst))
		"state":
			var inst = find(id)
			if inst != null:
				_apply_state(inst, data.state)
				_known[id].state = hash(state_of(inst))
		"states":
			var inst = find(id)
			if inst != null:
				_apply_states(inst, data.states)
				_known[id].states = hash(states_of(inst))
		"room":
			_apply_room(data.room)
			_room_known = hash(room_entry())
			for inst in app.instruments:  # (the room's own settling of what is in it isn't anyone's move)
				if _known.has(id_of(inst)):
					_known[id_of(inst)].place = hash(place_of(inst))
	applying = false


func _add(data: Dictionary) -> void:
	var id := str(data.id)
	if find(id) != null:
		return
	var state: Dictionary = data.state
	var place: Array = data.place
	var inst = app.add_instrument(str(state.get("kind", "")), Vector3(float(place[0]), 0.0, float(place[1])))
	if inst == null:
		app.session.notice.emit("A %s couldn't be put in here: the room is full" % str(state.get("kind", "instrument")))
		return
	inst.set_meta("net_id", id)
	_apply_place(inst, place)
	_apply_state(inst, state)
	_apply_states(inst, data.get("states", {}))
	_baseline(inst)


func _apply_place(inst, place: Array) -> void:
	app._place(inst, {"position": Vector3(float(place[0]), inst.global_position.y, float(place[1])), "yaw": float(place[2]),
		"height": float(place[3]), "tilt": float(place[4])})


func _apply_state(inst, state: Dictionary) -> void:
	if state.has("name") and str(state.name) != inst.display_name:
		app.rename_track(inst, str(state.name))
	var color := Library._color_from(state.get("color"), inst.color)
	if not color.is_equal_approx(inst.color):
		inst.set_color(color)
	if bool(state.get("locked", false)) != inst.locked:
		inst.set_locked(bool(state.get("locked", false)))
	if not is_equal_approx(float(state.get("room_db", inst.room_db)), inst.room_db):
		app.set_room_level(inst, float(state.room_db))
	if bool(state.get("room_muted", false)) != inst.room_muted:
		app.set_room_muted(inst, bool(state.get("room_muted", false)))
	if inst.is_stereo_mic and state.get("stereo") is Dictionary:
		var pair: Dictionary = state.stereo
		if str(pair.technique) != inst.pair_technique or not is_equal_approx(float(pair.spacing), inst.pair_spacing) or \
				str(pair.side_model) != inst.side_model or not is_equal_approx(float(pair.width), inst.ms_width):
			inst.set_pair(str(pair.technique), float(pair.spacing), str(pair.side_model), float(pair.width))
	if inst.playable:
		var audio = app.audio
		if int(state.get("steps", 16)) != audio.get_pattern_steps(inst.source_id):
			audio.set_pattern_steps(inst.source_id, int(state.steps))
		if state.has("pattern") and hash(state.pattern) != hash(audio.get_pattern(inst.source_id)):
			audio.set_pattern(inst.source_id, state.pattern)
		if bool(state.get("loop_on", true)) != inst.loop_on:
			inst.set_loop(bool(state.get("loop_on", true)))
	_apply_settings(inst, state.get("settings", {}))


## An instrument's settings changed elsewhere, made here: only what differs, so that nothing (a plug-in above all) is
## loaded again that needn't be.
func _apply_settings(inst, wanted: Dictionary) -> void:
	var have: Dictionary = app.library.instrument_settings(inst, false)
	var id := id_of(inst)
	var missing := {}  # (shared plug-ins that couldn't be loaded here)
	var played = wanted.get("instrument_plugin")
	if inst.plays_plugin and played is Dictionary:
		var had = have.get("instrument_plugin")
		if not (had is Dictionary) or str(had.plugin_id) != str(played.plugin_id):
			if app.set_instrument_plugin(inst, _local_id(played, true)) != "":
				missing.instrument = played
	if inst.is_amp and wanted.get("amp") is Dictionary:
		var amp: Dictionary = wanted.amp
		var was: Dictionary = have.get("amp", {})
		if str(amp.head) != str(was.head) or bool(amp.head_on) != bool(was.head_on) or str(amp.cabinet) != str(was.cabinet) or \
				bool(amp.cabinet_on) != bool(was.cabinet_on) or str(amp.speaker) != str(was.speaker):
			app.set_amp_voice(inst, str(amp.head), bool(amp.head_on), str(amp.cabinet), bool(amp.cabinet_on), str(amp.speaker))
		var controls: Dictionary = amp.get("controls", {})
		for control in controls:
			if inst.amp_controls.has(control) and not is_equal_approx(float(controls[control]), float(inst.amp_controls[control])):
				app.set_amp_control(inst, control, float(controls[control]))
		if not is_equal_approx(float(amp.get("loop_mix", 0.5)), inst.loop_mix):
			app.set_amp_loop_mix(inst, float(amp.get("loop_mix", 0.5)))
		_apply_pedals(inst, amp.get("pedals", []), was.get("pedals", []))
	if wanted.has("volume_db") and not is_equal_approx(float(wanted.volume_db), inst.volume_db):
		app.set_speaker_volume(inst, float(wanted.volume_db))
	if inst.is_mic:
		if wanted.has("mic_model") and (str(wanted.mic_model) != inst.mic_model or str(wanted.get("mic_pattern", "")) != inst.mic_pattern):
			if inst.is_stereo_mic:
				inst.set_mic_model(str(wanted.mic_model), str(wanted.get("mic_pattern", "")))
			else:
				app.set_mic_model(inst, str(wanted.mic_model), str(wanted.get("mic_pattern", "")))
		if wanted.has("mic_gain_db") and not is_equal_approx(float(wanted.mic_gain_db), inst.mic_gain_db):
			app.set_mic_gain(inst, float(wanted.mic_gain_db))
		if bool(wanted.get("mic_inverted", false)) != inst.mic_inverted:
			app.set_mic_polarity(inst, bool(wanted.get("mic_inverted", false)))
	var inserts: Array = wanted.get("inserts", [])
	var had_inserts: Array = have.get("inserts", [])
	for slot in app.audio.get_max_inserts():
		var insert = inserts[slot] if slot < inserts.size() else null
		var had = had_inserts[slot] if slot < had_inserts.size() else null
		if not (insert is Dictionary):
			if had is Dictionary:
				app.clear_insert(inst, slot)
			continue
		if not (had is Dictionary) or str(had.plugin_id) != str(insert.plugin_id):
			if app.set_insert(inst, slot, _local_id(insert)) != "":
				app.clear_insert(inst, slot)
				missing["insert:%d" % slot] = insert
				continue
		if bool(insert.get("on", true)) != bool(app.audio.get_inserts(inst.source_id)[slot].on):
			app.set_insert_on(inst, slot, bool(insert.get("on", true)))
	if missing.is_empty():
		_wanted.erase(id)
	else:
		_wanted[id] = missing
		app.session.notice.emit("%s uses a plug-in that isn't installed here" % inst.display_name)


## An amp's pedals: switched and turned where its board is as it was (the same pedals in the same order), and put
## together again where it isn't.
func _apply_pedals(inst, pedals: Array, had: Array) -> void:
	var same := pedals.size() == had.size()
	for i in mini(pedals.size(), had.size()):
		same = same and str(pedals[i].kind) == str(had[i].kind) and bool(pedals[i].get("in_loop", false)) == bool(had[i].get("in_loop", false)) and \
			str(pedals[i].get("plugin_id", "")) == str(had[i].get("plugin_id", ""))
	if not same:
		for i in range(had.size() - 1, -1, -1):
			app.remove_pedal(inst, i)
		for pedal in pedals:
			var at: int = app.add_pedal(inst, str(pedal.kind), -1, bool(pedal.get("in_loop", false)))
			if at >= 0 and str(pedal.get("plugin_id", "")) != "":
				app.load_pedal_plugin(inst, at, _local_id(pedal))
		had = app.library.instrument_settings(inst, false).get("amp", {}).get("pedals", [])
	for i in mini(pedals.size(), had.size()):
		var values: Array = pedals[i].get("controls", [])
		var were: Array = had[i].get("controls", [])
		for c in values.size():
			if c >= were.size() or not is_equal_approx(float(values[c]), float(were[c])):
				app.set_pedal_control(inst, i, c, float(values[c]))
		if bool(pedals[i].get("on", true)) != bool(had[i].get("on", true)):
			app.set_pedal_on(inst, i, bool(pedals[i].get("on", true)))


## A plug-in's id here: the same one, or the same plug-in in the other format if only that is installed.
func _local_id(entry: Dictionary, instrument := false) -> String:
	var other: String = app.plugin_elsewhere(str(entry.get("plugin_id", "")), str(entry.get("plugin_name", "")), str(entry.get("plugin_maker", "")),
		instrument)
	return other if other != "" else str(entry.get("plugin_id", ""))


func _apply_states(inst, states: Dictionary) -> void:
	var mine := states_of(inst)
	for key in states:
		if str(states[key]) == str(mine.get(key, "")):
			continue
		var place: String = str(key).get_slice(":", 0)
		var index := int(str(key).get_slice(":", 1))
		if mine.has(key):  # (a plug-in that is here)
			app.audio.set_plugin_state(inst.source_id, place, index, Marshalls.base64_to_raw(str(states[key])))


func _apply_room(room_part: Dictionary) -> void:
	var room = app.room
	var size: Array = room_part.get("size", [])
	if size.size() == 3:
		var wanted := Vector3(float(size[0]), float(size[1]), float(size[2]))
		if not wanted.is_equal_approx(room.size):
			room.set_size(wanted)
	var walls: Array = room_part.get("walls", [])
	if hash(walls) != hash(room_entry().walls):
		while not room.walls.is_empty():
			room.remove_wall(0)
		for wall in walls:
			room.add_wall(Vector2(float(wall[0]), float(wall[1])), Vector2(float(wall[2]), float(wall[3])), float(wall[4]), str(wall[5]))
	var surfaces: Dictionary = room_part.get("surfaces", {})
	for surface in surfaces:
		if str(room.surfaces.get(surface, "")) != str(surfaces[surface]):
			room.set_surface(surface, str(surfaces[surface]))
	if not is_equal_approx(float(room_part.get("tempo", app.tempo)), app.tempo):
		app.set_tempo(float(room_part.tempo))
	if not is_equal_approx(float(room_part.get("swing", app.swing)), app.swing):
		app.set_swing(float(room_part.swing))
	if not is_equal_approx(float(room_part.get("reverb_db", app.reverb_db)), app.reverb_db):
		app.set_reverb_db(float(room_part.reverb_db))
