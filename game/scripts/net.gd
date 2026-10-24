extends Node
## Playing together. One player hosts the room they have open (a Jam room); the others join it by the host's address,
## over the local network or the internet (with the host's port forwarded to their computer). On joining, a player's
## room becomes a copy of the host's, and from then on it is kept the same (room_sync.gd). Each player's computer makes
## the room's sound itself, heard from where that player stands: what goes over the network is what happens in the
## room, not its sound. That is the room and everything in it, where each player is (their body, seen by the others),
## the notes each plays (by the computer keyboard or a MIDI controller), and the session's clock, which the patterns
## keep to, so that they play in step everywhere.
##
## The session's clock is the host's: each player reckons how far theirs is from it by asking the time, as NTP does
## (the reply that came back soonest is the truest). Starting the patterns sets the moment they start on it, a little
## ahead so that it reaches everyone first; each player starts theirs then, less their own output's latency, so the
## first beat is heard at the same moment everywhere, and every half second each nudges theirs (by a few milliseconds
## at most) to keep to where the session says the music is. Live notes are heard as soon as they arrive, as late as the
## network makes them (as a player standing further off would be).

signal changed  # a player came or went; hosting, joining or leaving
signal reported(from: int, data: Dictionary)  # (the automated checks: what the other copy of the game found)

const Avatar := preload("res://scripts/avatar.gd")
const RoomSync := preload("res://scripts/room_sync.gd")
const PORT := 47130
const PROTOCOL := 1
const MAX_GUESTS := 15
const POSE_EVERY := 1.0 / 15.0
const PING_EVERY := 1.0
const KEEP_IN_STEP_EVERY := 0.5
const START_AHEAD := 0.35  # a start is set this far ahead, so that it reaches everyone first (seconds)
const NUDGE_MOST := 0.004  # the most the patterns are moved at once to keep in step (seconds)
const STATE := 0  # channels: the room's changes, in order; where the players are (the latest only); notes
const POSES := 1
const NOTES := 2
# Each player's colour, by when they came.
const COLORS := [Color(0.4, 0.62, 0.9), Color(0.92, 0.55, 0.3), Color(0.5, 0.82, 0.45), Color(0.85, 0.42, 0.7), Color(0.95, 0.82, 0.35),
	Color(0.45, 0.85, 0.85), Color(0.75, 0.55, 0.95), Color(0.9, 0.4, 0.4)]

var app
var audio
var sync  # room_sync.gd
var role := ""  # "", "host", "joining" or "guest"
var me := 0  # this player's id (the host's is 1)
var host_name := ""
var players := {}  # id → {"name", "height", "color"}
var latency_ms := 0.0  # there and back, to the host
var status := ""  # how it went, for the page
var clock := {"running": false, "anchor_us": 0, "anchor_step": 0.0, "bpm": 120.0}  # the music on the session's clock

var _bodies := {}  # another player's id → {"node", "body", "target", "yaw", "pitch", "kit", "hold", "last"}
var _held := {}  # another player's id → {"net id:note": [net id, note]}: their notes still down, let go if they leave
var _offset_us := 0  # the session's clock less this computer's
var _pings := []  # [round trip, offset], the last few
var _since_ping := 0.0
var _since_pose := 0.0
var _since_step := 0.0
var _started_us := 0  # when the patterns were last started here (on this computer's clock)


func setup(the_app) -> void:
	app = the_app
	audio = app.audio
	sync = RoomSync.new()
	sync.setup(app, self)
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected)
	multiplayer.connection_failed.connect(func() -> void: _end("the host couldn't be reached"))
	multiplayer.server_disconnected.connect(func() -> void: _end("the host has left"))
	multiplayer.peer_packet.connect(_on_packet)


func is_playing_together() -> bool:
	return role == "host" or role == "guest"


## The session's clock, in microseconds.
func session_us() -> int:
	return Time.get_ticks_usec() + _offset_us


## Hosts the room that is open, for others to join on `port` (on every network this computer is on, or only `bind`'s:
## "127.0.0.1" for this computer alone, as the checks do). Returns what went wrong, or "".
func host(port := PORT, bind := "*") -> String:
	leave()
	if app.timeline.is_record():
		return "playing together is for Jam rooms, for now"
	var peer := ENetMultiplayerPeer.new()
	peer.set_bind_ip(bind)
	var problem := peer.create_server(port, MAX_GUESTS)
	if problem != OK:
		return "port %d couldn't be opened (%s)" % [port, error_string(problem)]
	peer.host.compress(ENetConnection.COMPRESS_ZSTD)
	multiplayer.multiplayer_peer = peer
	role = "host"
	me = 1
	_offset_us = 0
	host_name = _my_name()
	players = {1: _me(1)}
	sync.adopt()
	clock = {"running": app.sequence_running, "anchor_us": session_us(), "anchor_step": maxf(_heard_step(), 0.0), "bpm": app.tempo}
	audio.share_played_notes(true)
	status = "Hosting on port %d" % port
	changed.emit()
	return ""


## Joins the room hosted at `address` ("host" or "host:port"). How it goes is told by `changed` and `status`.
func join(address: String) -> String:
	leave()
	var where := address.strip_edges()
	var port := PORT
	if where.count(":") == 1:
		port = int(where.get_slice(":", 1))
		where = where.get_slice(":", 0)
	if where == "":
		return "the host's address is wanted"
	var peer := ENetMultiplayerPeer.new()
	var problem := peer.create_client(where, port)
	if problem != OK:
		return "%s couldn't be reached (%s)" % [address, error_string(problem)]
	peer.host.compress(ENetConnection.COMPRESS_ZSTD)
	multiplayer.multiplayer_peer = peer
	role = "joining"
	status = "Joining %s…" % address
	changed.emit()
	return ""


## Leaves the session (as the host, ends it). A player who joined keeps a copy of the room, as it was.
func leave() -> void:
	if role == "":
		return
	if multiplayer.multiplayer_peer != null:
		multiplayer.multiplayer_peer.close()
	multiplayer.multiplayer_peer = null
	_end("")


func _end(why: String) -> void:
	var was := role
	role = ""
	me = 0
	players = {}
	for id in _bodies.keys():
		_forget(id)
	audio.share_played_notes(false)
	if was == "guest":
		app.session.end_copy()
	status = why
	if why != "" and was != "":
		app.session.notice.emit("Playing together ended: %s" % why)
	changed.emit()


func _me(id: int) -> Dictionary:
	return {"name": _my_name(), "height": app.settings.height, "color": _color_data(COLORS[(id - 1) % COLORS.size()])}


func _my_name() -> String:
	return app.settings.player_name if app.settings.player_name != "" else "Player"


static func _color_data(c: Color) -> Array:
	return [c.r, c.g, c.b]


## Your name or height changed (on the title screen's You page): the others told.
func me_changed() -> void:
	if not is_playing_together():
		return
	if role == "host":
		players[1] = _me(1)
		_send("players", players)
		changed.emit()
	else:
		_send("me", {"name": _my_name(), "height": app.settings.height}, 1)


# ── Messages ────────────────────────────────────────────────────────────────────────────────────────────────

func _send(kind: String, data, to := 0, channel := STATE, mode := MultiplayerPeer.TRANSFER_MODE_RELIABLE) -> void:
	if multiplayer.multiplayer_peer == null:
		return
	multiplayer.send_bytes(var_to_bytes([kind, data]), to, mode, channel)


## A change made here, for everyone: to the host, which passes it on; or, from the host, to everyone.
func share(kind: String, data: Dictionary) -> void:
	if role == "host":
		data.from = 1
		_send(kind, data)
	elif role == "guest":
		_send(kind, data, 1)


## (The automated checks: what this copy of the game found, for the other.)
func report(data: Dictionary) -> void:
	_send("report", data, 1 if role == "guest" else 0)


func _on_connected() -> void:
	me = multiplayer.get_unique_id()
	_send("hello", {"protocol": PROTOCOL, "name": _my_name(), "height": app.settings.height}, 1)


func _on_peer_connected(_id: int) -> void:
	pass  # (a joining player says hello first)


func _on_peer_disconnected(id: int) -> void:
	if role != "host" or not players.has(id):
		return
	var gone: String = players[id].name
	players.erase(id)
	_let_go(id)
	_forget(id)
	_send("players", players)
	_send("gone", {"id": id})
	app.session.notice.emit("%s has left" % gone)
	changed.emit()


func _on_packet(id: int, bytes: PackedByteArray) -> void:
	var message = bytes_to_var(bytes)
	if not (message is Array) or message.size() != 2 or not (message[0] is String):
		return
	var kind: String = message[0]
	var data = message[1]
	match kind:
		"hello":
			_on_hello(id, data)
		"welcome":
			_on_welcome(data)
		"refused":
			_end(str(data.get("why", "the host said no")))
		"players":
			players = data
			for each in _bodies.keys():
				if not players.has(each):
					_forget(each)
			changed.emit()
		"me":  # (a player's name or height, changed)
			if role == "host" and players.has(id):
				players[id].name = str(data.get("name", "Player"))
				players[id].height = float(data.get("height", 1.75))
				_send("players", players)
				_forget(id)  # (made again, as they are now)
				changed.emit()
		"gone":
			_let_go(int(data.id))
			_forget(int(data.id))
		"ping":
			if role == "host":
				_send("pong", {"sent": data.sent, "at": session_us()}, id, POSES, MultiplayerPeer.TRANSFER_MODE_UNRELIABLE)
		"pong":
			_on_pong(data)
		"pose":
			if role == "host":
				data.id = id
				_send("pose", data, -id, POSES, MultiplayerPeer.TRANSFER_MODE_UNRELIABLE_ORDERED)
			_on_pose(data)
		"note":
			if role == "host":
				data.from = id
				_send("note", data, -id, NOTES)
			_on_note(data)
		"run":  # (a player's Space: the host sets the moment for everyone)
			if role == "host":
				set_running(bool(data.on))
		"clock":
			_follow(data)
		"report":
			reported.emit(id, data)
		"add", "remove", "place", "state", "states", "room":
			if role == "host":
				data.from = id
				sync.receive(kind, data)
				_send(kind, data)  # (to everyone, the player it came from too: the host's order is everyone's)
			else:
				sync.receive(kind, data)


func _on_hello(id: int, data: Dictionary) -> void:
	if role != "host":
		return
	if int(data.get("protocol", 0)) != PROTOCOL:
		_send("refused", {"why": "it is another version of SoundRoom"}, id)
		return
	players[id] = {"name": str(data.get("name", "Player")), "height": float(data.get("height", 1.75)),
		"color": _color_data(COLORS[players.size() % COLORS.size()])}
	_send("welcome", {"you": id, "host": host_name, "room_name": app.session.room_name, "room": app.library.room_data(), "ids": sync.ids(),
		"players": players, "clock": clock}, id)
	_send("players", players, -id)
	app.session.notice.emit("%s has joined" % players[id].name)
	changed.emit()


## In: the room as the host has it, made here.
func _on_welcome(data: Dictionary) -> void:
	role = "guest"
	me = int(data.you)
	host_name = str(data.host)
	players = data.players
	app.player.stop_playing()
	app.player.put_down()
	sync.applying = true
	var problem: String = app.library.apply_room_data(data.room)
	sync.adopt(data.ids)
	sync.applying = false
	app.session.begin_copy("%s (%s's)" % [str(data.room_name), host_name])
	_stand_beside_host()
	audio.share_played_notes(true)
	_pings.clear()
	for i in 4:  # (the clock first, quickly)
		_send("ping", {"sent": Time.get_ticks_usec()}, 1, POSES, MultiplayerPeer.TRANSFER_MODE_UNRELIABLE)
	_follow.call_deferred(data.clock)
	status = "In %s's room" % host_name
	if problem != "":
		app.session.notice.emit("Not all of the room came over: %s" % problem)
	changed.emit()


## A joining player stands a little to the side of where the host stood when the room was kept, inside the room.
func _stand_beside_host() -> void:
	var spot: Vector3 = app.player.global_position + Vector3(0.8 * float(players.size() - 1), 0.0, 0.0)
	app.player.place(app.room.settle(spot, 0.4, 0.4, spot), app.player.yaw)


# ── The session's clock, and the patterns in step ───────────────────────────────────────────────────────────

func _on_pong(data: Dictionary) -> void:
	var now := Time.get_ticks_usec()
	var trip := now - int(data.sent)
	var offset := int(data.at) - (int(data.sent) + now) / 2
	_pings.append([trip, offset])
	if _pings.size() > 8:
		_pings.pop_front()
	var best: Array = _pings[0]
	for p in _pings:
		if p[0] < best[0]:
			best = p
	_offset_us = best[1]
	latency_ms = float(best[0]) / 1000.0


## Space, while playing together: the patterns started or stopped for everyone at once.
func request_running(on: bool) -> void:
	if role == "host":
		set_running(on)
	else:
		_send("run", {"on": on}, 1)


## (The host) starts the patterns a moment ahead, from the top, or stops them, for everyone.
func set_running(on: bool) -> void:
	var now := session_us()
	var wanted := {"running": on, "anchor_us": now + (int(START_AHEAD * 1e6) if on else 0), "anchor_step": 0.0, "bpm": app.tempo}
	_send("clock", wanted)
	_follow(wanted)


## Where the music should be on the session's clock just now, in steps.
func expected_step() -> float:
	return float(clock.anchor_step) + float(session_us() - int(clock.anchor_us)) / 1e6 * float(clock.bpm) / 15.0


## The patterns as the session's clock has them: started then (from where the music is, for a player coming in while
## they play), or stopped.
func _follow(data: Dictionary) -> void:
	var was: bool = clock.running
	var anchor_moved: bool = int(data.anchor_us) != int(clock.anchor_us)
	clock = data
	if not bool(clock.running):
		app.sequence_running = false
		audio.set_sequencer_running(false)
		return
	if not was or anchor_moved and is_zero_approx(float(clock.anchor_step)):  # (started: from the top, or where the music is)
		_start_in_step()


func _start_in_step() -> void:
	var rate: float = float(clock.bpm) / 15.0
	var now := session_us()
	var step := 0
	var at := int(clock.anchor_us)
	if now > at - 50000:  # (already going, or about to: from the next step a little way off)
		step = int(ceil(expected_step() + 0.15 * rate))
		at = int(clock.anchor_us) + int((float(step) - float(clock.anchor_step)) / rate * 1e6)
	audio.start_sequencer_in(maxf(float(at - now) / 1e6 - _output_latency(), 0.0), step)
	app.sequence_running = true
	_started_us = Time.get_ticks_usec()


func _output_latency() -> float:
	return float(audio.get_stats().get("output_latency_ms", 0.0)) / 1000.0


## The step being heard just now (the patterns run ahead of what is heard by the output's latency).
func _heard_step() -> float:
	var step: float = audio.get_sequencer_step_now()
	return -1.0 if step < 0.0 else step - _output_latency() * app.tempo / 15.0


## Every half second: the patterns nudged towards where the session says the music is (a few milliseconds at a time),
## or started again in step if they are far off. The host's tempo changing moves where the music is reckoned from.
func _keep_in_step() -> void:
	if not bool(clock.running):
		return
	if role == "host" and not is_equal_approx(app.tempo, float(clock.bpm)):
		clock = {"running": true, "anchor_us": session_us(), "anchor_step": expected_step(), "bpm": app.tempo}
		_send("clock", clock)
	if not is_equal_approx(app.tempo, float(clock.bpm)) or Time.get_ticks_usec() - _started_us < 1500000:
		return  # (the tempo on its way here; or just started)
	var expected := expected_step()
	var heard := _heard_step()
	if expected < 1.0:
		return
	var rate: float = float(clock.bpm) / 15.0
	var off := (heard - expected) / rate  # seconds ahead
	if heard < 0.0 or absf(off) > 0.25:
		_start_in_step()
	elif absf(off) > 0.001:
		audio.nudge_sequencer(clampf(off, -NUDGE_MOST, NUDGE_MOST))


# ── Notes ────────────────────────────────────────────────────────────────────────────────────────────────────

## A note played here (by the computer keyboard; a MIDI controller's are picked up from the audio core): for the others.
## `kind`: "on", "off" or "sustain".
func played(source_id: int, kind: String, note: int, velocity := 0.0) -> void:
	if not is_playing_together():
		return
	for inst in app.instruments:
		if inst.source_id == source_id:
			var data := {"id": RoomSync.id_of(inst), "kind": kind, "note": note, "velocity": velocity, "from": me}
			_send("note", data, 0 if role == "host" else 1, NOTES)
			return


func _on_note(data: Dictionary) -> void:
	var inst = sync.find(str(data.id))
	if inst == null:
		return
	var who := int(data.get("from", 0))
	var key := "%s:%d" % [data.id, int(data.note)]
	match str(data.kind):
		"on":
			audio.note_on(inst.source_id, int(data.note), float(data.velocity))
			if not _held.has(who):
				_held[who] = {}
			_held[who][key] = [str(data.id), int(data.note)]
		"off":
			audio.note_off(inst.source_id, int(data.note))
			if _held.has(who):
				_held[who].erase(key)
		"sustain":
			audio.set_sustain(inst.source_id, int(data.note) != 0)


## A player who left with notes still down: let go.
func _let_go(who: int) -> void:
	for held in _held.get(who, {}).values():
		var inst = sync.find(held[0])
		if inst != null:
			audio.note_off(inst.source_id, held[1])
	_held.erase(who)


# ── The players' bodies ─────────────────────────────────────────────────────────────────────────────────────

func _my_pose() -> Dictionary:
	var player = app.player
	var spot: Dictionary = player.standing_spot() if player.seated_at == null else {"position": player.global_position, "yaw": player.yaw}
	var holding := "carry" if player.carried != null else ("play" if player.playing != null else "")
	return {"at": [snappedf(spot.position.x, 0.001), snappedf(spot.position.z, 0.001)], "yaw": snappedf(spot.yaw, 0.001),
		"pitch": snappedf(player.pitch, 0.001), "kit": RoomSync.id_of(player.seated_at) if player.seated_at != null else "", "hold": holding,
		"carrying": RoomSync.id_of(player.carried) if player.carried != null else ""}


func _on_pose(data: Dictionary) -> void:
	var id := int(data.get("id", 0))
	if id == me or not players.has(id):
		return
	if not _bodies.has(id):
		var node := Node3D.new()
		var body = Avatar.new()
		node.add_child(body)
		app.add_child(node)
		var info: Dictionary = players[id]
		var colour: Array = info.get("color", [0.6, 0.6, 0.6])
		body.build(float(info.get("height", 1.75)), Color(float(colour[0]), float(colour[1]), float(colour[2])), 1)
		body.set_name_tag(str(info.get("name", "Player")))
		var at: Array = data.at
		node.global_position = Vector3(float(at[0]), 0.0, float(at[1]))
		node.rotation.y = float(data.yaw)
		_bodies[id] = {"node": node, "body": body, "last": node.global_position}
	var each: Dictionary = _bodies[id]
	each.target = Vector3(float(data.at[0]), 0.0, float(data.at[1]))
	each.yaw = float(data.yaw)
	each.pitch = float(data.pitch)
	each.kit = str(data.get("kit", ""))
	each.hold = str(data.get("hold", ""))
	each.carrying = str(data.get("carrying", ""))


func _move_bodies(delta: float) -> void:
	for id in _bodies:
		var each: Dictionary = _bodies[id]
		if not each.has("target"):
			continue
		var node: Node3D = each.node
		var follow := 1.0 - exp(-delta * 14.0)  # (between the poses, which come fifteen times a second)
		node.global_position = node.global_position.lerp(each.target, follow)
		node.rotation.y = lerp_angle(node.rotation.y, each.yaw, follow)
		var moved: Vector3 = (node.global_position - each.last) / maxf(delta, 0.0001)
		each.last = node.global_position
		var going: Vector3 = node.global_transform.basis.inverse() * Vector3(moved.x, 0.0, moved.z)
		var kit = sync.find(each.kit) if each.kit != "" else null
		var info: Dictionary = players.get(id, {})
		each.body.pose(Avatar.state_for(node.global_transform, float(info.get("height", 1.75)), each.pitch, going.limit_length(6.0), kit, each.hold),
			delta)


func _forget(id: int) -> void:
	if _bodies.has(id):
		_bodies[id].node.queue_free()
		_bodies.erase(id)


## Another player's body (for the checks), or null.
func body_of(id: int):
	return _bodies[id].node if _bodies.has(id) else null


## Who is carrying an instrument, other than you ("" if nobody is).
func carried_by_another(inst) -> String:
	var id := RoomSync.id_of(inst)
	for each in _bodies:
		if id != "" and str(_bodies[each].get("carrying", "")) == id:
			return str(players.get(each, {}).get("name", "Someone"))
	return ""


# ── Each frame ──────────────────────────────────────────────────────────────────────────────────────────────

func _process(delta: float) -> void:
	if not is_playing_together():
		return
	sync.tick(delta)
	for note in audio.take_played_notes():  # (a MIDI controller's, here)
		played(int(note[0]), str(note[1]), int(note[2]), float(note[3]))
	_since_pose += delta
	if _since_pose >= POSE_EVERY:
		_since_pose = 0.0
		var pose := _my_pose()
		pose.id = me
		_send("pose", pose, 0 if role == "host" else 1, POSES, MultiplayerPeer.TRANSFER_MODE_UNRELIABLE_ORDERED)
	if role == "guest":
		_since_ping += delta
		if _since_ping >= PING_EVERY:
			_since_ping = 0.0
			_send("ping", {"sent": Time.get_ticks_usec()}, 1, POSES, MultiplayerPeer.TRANSFER_MODE_UNRELIABLE)
	_since_step += delta
	if _since_step >= KEEP_IN_STEP_EVERY:
		_since_step = 0.0
		_keep_in_step()
	_move_bodies(delta)
