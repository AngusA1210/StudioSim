extends Node
## Playing together. One player hosts the room they have open; the others join it by the host's address, over the
## local network or the internet (the host's router asked to open its ports, or them forwarded by hand), or by the
## session's code, meeting through a session server (meeting.gd), where neither can be. On joining, a player's
## room becomes a copy of the host's, and from then on it is kept the same (room_sync.gd). Each player's computer makes
## the room's sound itself, heard from where that player stands: what goes over the network is what happens in the
## room, not its sound. That is the room and everything in it, where each player is (their body, seen by the others),
## the notes each plays (by the computer keyboard or a MIDI controller), and the session's clock, which the patterns
## keep to, so that they play in step everywhere.
##
## The session's clock is the host's: each player reckons how far theirs is from it by asking the time, as NTP does
## (the reply that came back soonest is the truest). Starting the patterns sets the moment they start on it, a little
## ahead so that it reaches everyone first; each player starts theirs then, less their own output's latency, so the
## first beat is heard at the same moment everywhere, and every half second each nudges theirs (a few milliseconds
## at a time) to keep to where the session says the music is. Live notes are heard as soon as they arrive, as late as the
## network makes them (as a player standing further off would be).
##
## A live input (a Speaker, a guitar into an amp) is played through by the player who switches its input on, and by
## nobody else meanwhile: its sound, as it leaves it (after its pedals, amp and inserts), goes to the others over a
## port of its own beside the session's (net_audio.h), and their copies of it play that in place of their own input.
## And each player's voice, from the input they choose for it, while they hold the talk key: heard by the others from
## their body's head, in the room like any sound (so the microphones hear it too), and not by themselves.

signal changed  # a player came or went; hosting, joining or leaving
signal reported(from: int, data: Dictionary)  # (the automated checks: what the other copy of the game found)

const Avatar := preload("res://scripts/avatar.gd")
const Discovery := preload("res://scripts/discovery.gd")
const Meeting := preload("res://scripts/meeting.gd")
const RoomList := preload("res://scripts/room_list.gd")
const RoomSync := preload("res://scripts/room_sync.gd")
const PORT := 47130
const PROTOCOL := 1
const MAX_GUESTS := 15
## A session's rules, as the host sets them: its name (the room's, unless given), whether it is listed in room browsers,
## the most players in it at once, and what joining players may do besides playing and talking (MAY).
const RULES := {"name": "", "listed": true, "most": 8, "may": {"move": true, "sound": true, "room": false, "transport": true}}
## What joining players may be let do, as a player who may not is told it ("The host hasn't let players …").
const MAY := {"move": "move, add or take out instruments", "sound": "change the instruments' sound, patterns or names",
	"room": "change the room (its size, walls, surfaces or tempo)", "transport": "play, stop or record the session, or edit the timeline"}
const DENIED_EVERY := 3000  # ms: a player is told they may not do something once in this long, at most
const POSE_EVERY := 1.0 / 15.0
const PING_EVERY := 1.0
const KEEP_IN_STEP_EVERY := 0.5
const START_AHEAD := 0.35  # a start is set this far ahead, so that it reaches everyone first (seconds)
const NUDGE_MOST := 0.004  # the most the patterns are moved at once to keep in step (seconds)
const NUDGE_FAR := 0.010  # and while they are further out than that (just started, say)
const VOICE := 255  # (each player's voice is their sound numbered 255)
const STATE := 0  # channels: the room's changes, in order; where the players are (the latest only); notes; files
const POSES := 1
const NOTES := 2
const FILES := 3
const CHANNELS := 4  # (as many as there are of those, declared on both sides)
const CHUNK := 32768  # a recording's file goes in pieces this big (bytes),
const CHUNKS_A_FRAME := 4  # this many each frame (about 8 MB a second at 60 frames a second)
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
var _waiting_clock := {}  # (a joining player) the music as the session has it, waiting for the session's time to be known
var public_address := ""  # (the host's) where others join from the internet, the router having opened the ports
var router := ""  # (the host's) how asking the router went: "", "asking", "open", or what went wrong
var _upnp = null  # (the host's) the router that opened the ports, to close them again
var _router_thread: Thread
var _password := ""  # (the host's) what a joining player must give, if anything
var rules := RULES.duplicate(true)  # the session's (the host's, as it set them; a joining player's, as told)
var discovery  # discovery.gd: the room browser's finding rooms on this network, and the host's answering it
var room_list  # room_list.gd: rooms listed across the internet
var over_internet := false  # (the host's) hosted over the internet: listed on the room list too, if listed
var _hosted_port := PORT  # (the host's) the session's port
var _denied_at := {}  # (the host's) "player:what" → when they were last told they may not
var _host_ended := false  # (a joining player) the host ended the session, rather than the connection being lost
var _rejoin := {}  # (a joining player whose connection was lost) {given, password, tries, next}: trying to get back in
var meeting = null  # meeting.gd: (the host's) its code, from the session server; (joining by a code) finding it
var _given := ""  # (a joining player) the host's address, or the session's code, as given
var _sound_where := ""  # (a joining player) where the sound between players goes: the host's, or the server's relay
var _sound_port := 0
var _streams := 0  # this player's sounds, numbered so far
var _outgoing := []  # recordings' files going: [{name, to, at, size, file}]
var _incoming := {}  # name → {size, got}: coming
var _asked := {}  # names asked for (of the host), and not come yet
var _wanted_by := {}  # (the host's) name → the players waiting for it, until it has come here
var _voice_out := -1  # this player's voice: a source no one hears here, whose sound goes to the others
var _voices := {}  # another player's id → the source their voice comes from here
var talking := false


func setup(the_app) -> void:
	app = the_app
	audio = app.audio
	sync = RoomSync.new()
	sync.setup(app, self)
	discovery = Discovery.new(self)
	room_list = RoomList.new()
	room_list.name = "RoomList"
	add_child(room_list)
	room_list.setup(self)
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected)
	multiplayer.connection_failed.connect(_failed)
	multiplayer.server_disconnected.connect(_lost)
	multiplayer.peer_packet.connect(_on_packet)


func is_playing_together() -> bool:
	return role == "host" or role == "guest"


## The session's clock, in microseconds.
func session_us() -> int:
	return Time.get_ticks_usec() + _offset_us


## Hosts the room that is open, for others to join on `port` (on every network this computer is on, or only `bind`'s:
## "127.0.0.1" for this computer alone, as the checks do). Returns what went wrong, or "".
## With `open_router`, the router is asked (UPnP) to open the session's two ports to this computer, so that others can
## join over the internet at the address it gives (public_address) without anyone forwarding them by hand. With a
## `password`, only those who give it can join. `session_rules`: the session's name, whether it is listed, the most
## players, what they may do (RULES, for what isn't given).
func host(port := PORT, bind := "*", open_router := false, password := "", session_rules := {}) -> String:
	leave()
	_password = password
	rules = RULES.duplicate(true)
	rules.merge(session_rules.duplicate(true), true)
	if str(rules.name).strip_edges() == "":
		rules.name = app.session.room_name
	rules.most = clampi(int(rules.most), 2, MAX_GUESTS + 1)
	_hosted_port = port
	over_internet = open_router
	var peer := ENetMultiplayerPeer.new()
	peer.set_bind_ip(bind)
	var problem := peer.create_server(port, MAX_GUESTS, CHANNELS)
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
	var trouble: String = audio.start_net_audio(true, bind, port + 1, 1)
	if trouble != "":
		status += " (no sound between players: %s)" % trouble
	_tell_engine_who()
	follow_voices()
	discovery.answer(bind)
	if open_router and not app.options.has("silent"):  # (never in the automated runs: nobody's router is theirs to open)
		_ask_router(port)
	if open_router and app.settings.session_server.strip_edges() != "":  # (a code, for others to join with from anywhere)
		meeting = Meeting.new(self)
		meeting.host(app.settings.session_server, port, port + 1, _local_address(bind))
	changed.emit()
	return ""


## This computer's address on its own network (for a player joining a session hosted here from the same network,
## by its code): the one bound to, or the likeliest of its own.
static func _local_address(bind: String) -> String:
	if bind != "*":
		return bind
	var addresses := Array(IP.get_local_addresses()).filter(func(a): return a.count(".") == 3 and not a.begins_with("127.") and not a.begins_with("169.254."))
	for prefix in ["192.168.", "10.", "172."]:
		for a in addresses:
			if a.begins_with(prefix):
				return a
	return addresses[0] if not addresses.is_empty() else ""

## The router asked to open the session's ports (UDP: the session's, and the next for the sound between players), in a
## thread of its own, as finding it takes a moment.
func _ask_router(port: int) -> void:
	router = "asking"
	_router_thread = Thread.new()
	_router_thread.start(func() -> void:
		var upnp := UPNP.new()
		var answer := {"ok": false, "why": "no router answered (UPnP may be off in it)"}
		if upnp.discover(2000, 2, "InternetGatewayDevice") == UPNP.UPNP_RESULT_SUCCESS and upnp.get_gateway() != null and \
				upnp.get_gateway().is_valid_gateway():
			var first := upnp.add_port_mapping(port, port, "StudioSim", "UDP", 0)
			var second := upnp.add_port_mapping(port + 1, port + 1, "StudioSim (sound)", "UDP", 0)
			if first == UPNP.UPNP_RESULT_SUCCESS and second == UPNP.UPNP_RESULT_SUCCESS:
				answer = {"ok": true, "address": upnp.query_external_address(), "upnp": upnp, "port": port}
			else:
				answer.why = "the router wouldn't open them (UPnP answered %d)" % (first if first != UPNP.UPNP_RESULT_SUCCESS else second)
		_router_answered.call_deferred(answer))


func _router_answered(answer: Dictionary) -> void:
	if _router_thread != null:
		_router_thread.wait_to_finish()
		_router_thread = null
	if role != "host":  # (ended meanwhile: closed again)
		if bool(answer.ok):
			_close_router(answer.upnp, int(answer.port))
		return
	if bool(answer.ok):
		router = "open"
		_upnp = {"upnp": answer.upnp, "port": int(answer.port)}
		public_address = str(answer.address)
	else:
		router = str(answer.why)
	changed.emit()


func _close_router(upnp, port: int) -> void:
	upnp.delete_port_mapping(port, "UDP")
	upnp.delete_port_mapping(port + 1, "UDP")


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST or what == NOTIFICATION_PREDELETE:  # (quitting: the router's ports closed)
		if _upnp != null:
			_close_router(_upnp.upnp, int(_upnp.port))
			_upnp = null


## Joins the room hosted at `address` ("host" or "host:port"), or with the session's code ("K7Q-M2D"), found through
## the session server; with its `password` if it has one. How it goes is told by `changed` and `status`.
func join(address: String, password := "") -> String:
	var rejoining := _rejoin.duplicate()
	leave()
	_rejoin = rejoining
	_password = password
	_host_ended = false
	_given = address.strip_edges()
	if Meeting.is_code(_given):
		if app.settings.session_server.strip_edges() == "":
			return "a code is joined through a session server: its address is wanted"
		meeting = Meeting.new(self)
		meeting.relay_only = app.options.has("relay")
		meeting.find(app.settings.session_server, _given)
		role = "joining"
		status = "Finding the session %s…" % _given.to_upper()
		changed.emit()
		return ""
	var where := _given
	var port := PORT
	if where.count(":") == 1:
		port = int(where.get_slice(":", 1))
		where = where.get_slice(":", 0)
	if where == "":
		return "the host's address is wanted"
	_sound_where = where
	_sound_port = port + 1
	var problem := _connect(where, port)
	if problem != "":
		return "%s couldn't be reached (%s)" % [address, problem]
	status = "Joining %s…" % address
	changed.emit()
	return ""


## (Joining by a code) where the session server says to join: the host's computer, or the server's relay to it.
func meet(game_address: String, game_port: int, sound_address: String, sound_port: int) -> void:
	_sound_where = sound_address
	_sound_port = sound_port
	var problem := _connect(game_address, game_port)
	if problem != "":
		_end("the host couldn't be reached (%s)" % problem)
		return
	status = "Joining %s%s…" % [_given.to_upper(), " by way of the session server" if meeting.by_relay else ""]
	changed.emit()


## (Joining) the session's connection begun, to `where`:`port` (in place of one tried before).
func _connect(where: String, port: int) -> String:
	if multiplayer.multiplayer_peer != null:
		multiplayer.multiplayer_peer.close()
	var peer := ENetMultiplayerPeer.new()
	var problem := peer.create_client(where, port, CHANNELS)
	if problem != OK:
		multiplayer.multiplayer_peer = null
		return error_string(problem)
	peer.host.compress(ENetConnection.COMPRESS_ZSTD)
	multiplayer.multiplayer_peer = peer
	role = "joining"
	return ""


## The host not reached: by way of the session server instead, if joining by a code; or that's that.
func _failed() -> void:
	if meeting != null and meeting.go_by_relay():
		return
	_end("the host couldn't be reached")


## Meeting through the session server didn't work (meeting.problem says why).
func meeting_failed(why: String) -> void:
	if role == "joining":
		_end(why)
	else:
		changed.emit()  # (the host: no code, but hosting as before)


## (Joining by a code) in by way of the session server's relay, rather than directly.
func by_relay() -> bool:
	return meeting != null and meeting.by_relay


# ── The session's rules ─────────────────────────────────────────────────────────────────────────────────────

## (The host) the session as the room browser shows it (discovery.gd), `id` being this session's there.
func listing(id: String) -> Dictionary:
	return {"id": id, "name": str(rules.name), "host": host_name, "mode": app.timeline.mode, "players": players.size(),
		"most": int(rules.most), "locked": _password != "", "port": _hosted_port, "protocol": PROTOCOL}


## (The host) the session's rules changed while it goes on: everyone told.
func set_rules(new_rules: Dictionary) -> void:
	if role != "host":
		return
	rules.merge(new_rules.duplicate(true), true)
	if str(rules.name).strip_edges() == "":
		rules.name = app.session.room_name
	rules.most = clampi(int(rules.most), 2, MAX_GUESTS + 1)
	_send("rules", rules)
	changed.emit()


## Whether this player may do `what` (a key of MAY): always, unless they joined and the host hasn't let them.
func may(what: String) -> bool:
	return role != "guest" or bool(rules.get("may", {}).get(what, true))


## As may, the player told when they may not.
func check(what: String) -> bool:
	if may(what):
		return true
	app.session.notice.emit("The host hasn't let players %s" % MAY.get(what, "do that"))
	return false


## (The host) a player asked to leave: told so, and their connection closed (they close it themselves on hearing).
func remove_player(id: int) -> void:
	if role != "host" or not players.has(id):
		return
	_send("refused", {"why": "the host has asked you to leave"}, id)
	(multiplayer.multiplayer_peer as ENetMultiplayerPeer).host.flush()
	get_tree().create_timer(1.0).timeout.connect(func() -> void:
		if role == "host" and multiplayer.multiplayer_peer != null and players.has(id):
			(multiplayer.multiplayer_peer as ENetMultiplayerPeer).disconnect_peer(id))


## (Turned away, or asked to leave) the connection to the host closed.
func _drop_connection() -> void:
	if role == "" and multiplayer.multiplayer_peer != null:
		multiplayer.multiplayer_peer.close()
		multiplayer.multiplayer_peer = null


## (The host) a joining player's change, as far as they may make it: what they may not is put back as it is here, and
## they're told. False if none of it stands (they alone are sent the room as it is, theirs undone).
func _allowed(kind: String, data: Dictionary, id: int) -> bool:
	var may_do: Dictionary = rules.get("may", {})
	var needs: String = {"add": "move", "remove": "move", "place": "move", "states": "sound"}.get(kind, "")
	if needs != "":
		if bool(may_do.get(needs, true)):
			return true
		var inst = sync.find(str(data.get("id", "")))
		var undo := {"id": str(data.get("id", "")), "from": id, "refused": true}
		match kind:
			"add":
				_send("remove", undo, id)
			"remove", "place", "states":
				if inst != null:
					undo.place = sync.place_of(inst)
					if kind != "place":
						undo.state = sync.state_of(inst)
						undo.states = sync.states_of(inst)
					_send("add" if kind == "remove" else kind, undo, id)
		_deny(id, needs)
		return false
	if kind != "state" and kind != "room":
		return true
	var inst = sync.find(str(data.get("id", ""))) if kind == "state" else null
	if kind == "state" and inst == null:
		return true
	var here: Dictionary = sync.state_of(inst) if kind == "state" else sync.room_entry()
	var asked: Dictionary = data[kind]
	var needed: Dictionary = RoomSync.STATE_NEEDS if kind == "state" else RoomSync.ROOM_NEEDS
	var refused := ""
	for key in needed:
		var what: String = needed[key]
		if bool(may_do.get(what, true)) or hash(asked.get(key)) == hash(here.get(key)):
			continue
		if here.has(key):
			asked[key] = here[key]
		else:
			asked.erase(key)
		refused = what
	if refused != "":
		data.refused = true  # (everyone, they too, takes it as the host has it)
		_deny(id, refused)
	return true


func _deny(id: int, what: String) -> void:
	var key := "%d:%s" % [id, what]
	var now := Time.get_ticks_msec()
	if now - int(_denied_at.get(key, -DENIED_EVERY)) < DENIED_EVERY:
		return
	_denied_at[key] = now
	_send("denied", {"what": what}, id)


## Leaves the session (as the host, ends it). A player who joined keeps a copy of the room, as it was.
func leave() -> void:
	_rejoin = {}
	if role == "":
		return
	if role == "host" and multiplayer.multiplayer_peer != null:  # (the others told it is over, not lost)
		_send("ending", {})
		(multiplayer.multiplayer_peer as ENetMultiplayerPeer).host.flush()
	if _upnp != null:
		_close_router(_upnp.upnp, int(_upnp.port))
		_upnp = null
	public_address = ""
	router = ""
	if multiplayer.multiplayer_peer != null:
		multiplayer.multiplayer_peer.close()
	multiplayer.multiplayer_peer = null
	_end("")


func _end(why: String) -> void:
	var was := role
	role = ""
	over_internet = false
	me = 0
	players = {}
	for id in _bodies.keys():
		_forget(id)
	audio.share_played_notes(false)
	_silence_voices()
	audio.stop_net_audio()
	for each in _outgoing:
		if each.get("file") != null:
			each.file.close()
	_outgoing.clear()
	_incoming.clear()
	_waiting_clock = {}
	discovery.stop_answering()
	_denied_at.clear()
	if meeting != null:
		meeting.end()
		meeting = null
	_pings.clear()
	_asked.clear()
	_wanted_by.clear()
	for inst in app.instruments:  # (nobody's input plays through anything any more but this player's own)
		for key in ["fed_by", "stream", "feeding", "sending", "armed_by"]:
			inst.remove_meta(key)
		if inst.played_by != "":
			inst.played_by = ""
			inst._refresh_label()
	if was == "guest":
		app.session.end_copy()
	status = why
	if why != "" and was != "" and _rejoin.is_empty():
		app.session.notice.emit("Playing together ended: %s" % why)
	changed.emit()


func _me(id: int) -> Dictionary:
	return {"name": _my_name(), "height": app.settings.height, "color": _color_data(COLORS[(id - 1) % COLORS.size()]),
		"look": Avatar.look_of(app.settings.appearance)}


## This player's name, as the others see it.
func my_name() -> String:
	return _my_name()


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
		_send("me", {"name": _my_name(), "height": app.settings.height, "look": Avatar.look_of(app.settings.appearance)}, 1)


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
	if meeting != null:
		meeting.connected()
	me = multiplayer.get_unique_id()
	_send("hello", {"protocol": PROTOCOL, "name": _my_name(), "height": app.settings.height, "look": Avatar.look_of(app.settings.appearance),
		"password": _password}, 1)


## The host gone without saying so (the connection lost, as a network can drop out): tried again every few seconds for
## half a minute, the copy of the room kept as it is meanwhile. Ended by the host, or left: over.
func _lost() -> void:
	if role == "":  # (ended already: turned away, say)
		return
	if role != "guest" or _host_ended:
		_end("the host has ended the session" if _host_ended else "the host has left")
		return
	var again := {"given": _given, "password": _password, "tries": 0, "next": 1.0}
	_end("")
	_rejoin = again
	status = "The connection to the host was lost: trying to get back in…"
	app.session.notice.emit(status)
	changed.emit()


func _try_rejoining(delta: float) -> void:
	_rejoin.next = float(_rejoin.next) - delta
	if float(_rejoin.next) > 0.0 or role == "guest" or meeting != null:  # (a code being found meanwhile: let be)
		return
	_rejoin.tries = int(_rejoin.tries) + 1
	if int(_rejoin.tries) > 10:
		_rejoin = {}
		status = "the connection to the host was lost"
		app.session.notice.emit("Playing together ended: %s" % status)
		changed.emit()
		return
	_rejoin.next = 3.0
	join(str(_rejoin.given), str(_rejoin.password))
	status = "The connection to the host was lost: trying to get back in (%d)…" % int(_rejoin.tries)


func _on_peer_connected(_id: int) -> void:
	pass  # (a joining player says hello first)


func _on_peer_disconnected(id: int) -> void:
	if role != "host" or not players.has(id):
		return
	var gone: String = players[id].name
	players.erase(id)
	_let_go(id)
	_forget(id)
	_tell_engine_who()
	for inst in app.instruments:  # (what they played through, and had armed, is free again)
		if int(inst.get_meta("fed_by", 0)) == id:
			inst.set_meta("fed_by", 0)
			inst.set_meta("stream", 0)
			follow_feed(inst)
		if int(inst.get_meta("armed_by", 0)) == id:
			inst.set_meta("armed_by", 0)
	_outgoing = _outgoing.filter(func(each): return int(each.to) != id)
	for name in _wanted_by:
		_wanted_by[name].erase(id)
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
		"refused":  # (turned away, or asked to leave)
			_rejoin = {}
			_end(str(data.get("why", "the host said no")))
			_drop_connection.call_deferred()
		"denied":  # (something the host hasn't let players do, put back as it was)
			app.session.notice.emit("The host hasn't let players %s" % MAY.get(str(data.get("what", "")), "do that"))
		"rules":
			if role == "guest":
				rules = data
				changed.emit()
		"ending":  # (the host is ending the session: not a connection lost)
			_host_ended = true
		"players":
			players = data
			for each in _bodies.keys():  # (gone, or changed: their name, height or look; made again as they are now)
				if not players.has(each) or _bodies[each].made_of != _made_of(players[each]):
					_forget(each)
			follow_voices()
			changed.emit()
		"me":  # (a player's name, height or look, changed)
			if role == "host" and players.has(id):
				players[id].name = str(data.get("name", "Player"))
				players[id].height = float(data.get("height", 1.75))
				players[id].look = Avatar.look_of(data.get("look", {}))
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
		"transport":
			if role == "host":
				set_transport(data)
		"want":  # (a recording's file someone hasn't got)
			if role == "host":
				_serve(str(data.name), id)
		"file":
			_on_file(data)
		"clock":
			_follow(data)
		"report":
			reported.emit(id, data)
		"add", "remove", "place", "state", "states", "room":
			if role == "host":
				data.from = id
				if not _allowed(kind, data, id):
					return
				sync.receive(kind, data)
				_send(kind, data)  # (to everyone, the player it came from too: the host's order is everyone's)
			else:
				sync.receive(kind, data)


func _on_hello(id: int, data: Dictionary) -> void:
	if role != "host":
		return
	if int(data.get("protocol", 0)) != PROTOCOL:
		_send("refused", {"why": "it is another version of StudioSim"}, id)
		return
	if _password != "" and str(data.get("password", "")) != _password:
		_send("refused", {"why": "the password isn't right"}, id)
		return
	if players.size() >= int(rules.most):
		_send("refused", {"why": "the room is full (%d players)" % int(rules.most)}, id)
		return
	players[id] = {"name": str(data.get("name", "Player")), "height": float(data.get("height", 1.75)),
		"color": _color_data(COLORS[players.size() % COLORS.size()]), "look": Avatar.look_of(data.get("look", {}))}
	_tell_engine_who()
	_send("welcome", {"you": id, "host": host_name, "room_name": app.session.room_name, "room": app.library.room_data(), "ids": sync.ids(),
		"feeds": app.instruments.map(func(i): return [int(i.get_meta("fed_by", 0)), int(i.get_meta("stream", 0))]),
		"players": players, "clock": clock, "rules": rules}, id)
	_send("players", players, -id)
	app.session.notice.emit("%s has joined" % players[id].name)
	changed.emit()


## In: the room as the host has it, made here.
func _on_welcome(data: Dictionary) -> void:
	_rejoin = {}
	role = "guest"
	me = int(data.you)
	host_name = str(data.host)
	players = data.players
	app.player.stop_playing()
	app.player.put_down()
	sync.applying = true
	var problem: String = app.library.apply_room_data(data.room)
	var feeds: Array = data.get("feeds", [])
	for i in mini(feeds.size(), app.instruments.size()):  # (whose input plays through what)
		app.instruments[i].set_meta("fed_by", int(feeds[i][0]))
		app.instruments[i].set_meta("stream", int(feeds[i][1]))
	sync.adopt(data.ids)
	sync.applying = false
	var trouble: String = audio.start_net_audio(false, _sound_where, _sound_port, me)
	if trouble != "":
		app.session.notice.emit("No sound between players: %s" % trouble)
	elif meeting != null:
		meeting.in_session()
	for inst in app.instruments:
		follow_feed(inst)
		need_files(inst.clips)
	follow_voices()
	rules = data.get("rules", RULES.duplicate(true))
	app.session.begin_copy("%s (%s's)" % [str(rules.get("name", data.room_name)), host_name])
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
	if not _waiting_clock.is_empty():  # (the session's time known: the music as it has it)
		var waiting := _waiting_clock
		_waiting_clock = {}
		_follow(waiting)


## Space, while playing together: the patterns started or stopped for everyone at once.
func request_running(on: bool) -> void:
	if not check("transport"):
		return
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


## Where the music should be on the session's clock just now, in steps: going on from where it started, at the tempo,
## and in a Record room round its loop as the timeline goes (but not while recording, unless loop recording).
func expected_step() -> float:
	var step := float(clock.anchor_step) + float(session_us() - int(clock.anchor_us)) / 1e6 * float(clock.bpm) / 15.0
	var length := _loop_length()
	if length > 0.0 and step >= app.timeline.loop_end:
		step = app.timeline.loop_start + fmod(step - app.timeline.loop_start, length)
	return step


## How long the loop the music goes round is, in steps (0: it doesn't go round one).
func _loop_length() -> float:
	var timeline = app.timeline
	var round: bool = timeline.is_record() and timeline.loop_on and (not bool(clock.get("record", false)) or bool(clock.get("loop_record", false)))
	var length: float = timeline.loop_end - timeline.loop_start
	return length if round and length >= 0.25 and float(clock.anchor_step) < timeline.loop_end else 0.0


## The patterns as the session's clock has them: started then (from where the music is, for a player coming in while
## they play), or stopped.
func _follow(data: Dictionary) -> void:
	if role == "guest" and _pings.is_empty():  # (the session's time not known here yet: once it is)
		_waiting_clock = data
		return
	var was: bool = clock.running
	var anchor_moved: bool = int(data.anchor_us) != int(clock.anchor_us)
	var was_recording: bool = bool(clock.get("record", false))
	clock = data
	if app.timeline.is_record():  # (a Record room: its timeline)
		if not bool(clock.running):
			app.timeline.stop_together(float(clock.get("playhead", app.timeline.playhead)))
		elif was and not anchor_moved and bool(clock.get("record", false)) and not was_recording:  # (recording from where it plays)
			app.timeline.play_together(0.0, 0.0, 0.0, true, false)
		elif not was or anchor_moved:
			_play_in_step()
		return
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


## How far ahead of where the session's clock says the music is it is heard here (seconds; round a loop, the nearer
## way round).
func ahead_of_session() -> float:
	var apart := _heard_step() - expected_step()
	var length := _loop_length()
	if length > 0.0:
		apart = fposmod(apart + length / 2.0, length) - length / 2.0
	return apart / (float(clock.bpm) / 15.0)


## A Record room's timeline from where the session says (a moment ahead; or, coming in while it plays, from a little
## way on, without recording).
func _play_in_step() -> void:
	var timeline = app.timeline
	var rate: float = float(clock.bpm) / 15.0
	var now := session_us()
	var at := int(clock.anchor_us)
	var from := float(clock.anchor_step)
	var late := now > at - 50000
	if late:
		from = expected_step() + 0.15 * rate
		at = now + 150000
	if timeline.playing and not timeline.recording:  # (from somewhere else)
		audio.set_sequencer_running(false)
		timeline.playing = false
	var recording := bool(clock.get("record", false)) and not late
	timeline.play_together(from, float(clock.get("punch_in", from)), maxf(float(at - now) / 1e6 - _output_latency(), 0.0), recording,
		bool(clock.get("loop_record", false)), float(clock.get("count_in", 0.0)) if recording else 0.0, float(clock.get("counted_us", 0)) / 1e6,
		float(clock.get("punch_out", -1.0)))
	_started_us = Time.get_ticks_usec()


## Whether the session is recording (in a Record room): some player, or none, recording what they have armed.
func is_recording() -> bool:
	return bool(clock.running) and bool(clock.get("record", false))


## Space, Cmd-Space, or the playhead moved while playing, in a Record room: the timeline started (recording too, with
## `record`; from `from`, or the playhead), or stopped, for everyone at once. (A Jam room's: its patterns.)
func request_transport(on: bool, record := false, from := -1.0) -> void:
	if not check("transport"):
		return
	var timeline = app.timeline
	var ask := {"on": on, "record": record, "from": timeline.playhead if from < 0.0 else from,
		"preroll": float(app.settings.preroll_bars * timeline.STEPS_PER_BAR), "loop_record": record and app.settings.loop_record,
		"follow": app.settings.insertion_follows, "count_in": float(app.settings.count_in_bars * timeline.STEPS_PER_BAR) if record else 0.0,
		"punch": record and app.settings.punch, "postroll": float(app.settings.postroll_bars * timeline.STEPS_PER_BAR)}
	if role == "host":
		set_transport(ask)
	else:
		_send("transport", ask, 1)


## (The host) the transport as asked, set for everyone: started a moment ahead (from the pre-roll's start), recording
## from where it plays, or stopped (the playhead back where playing began, or, as the one who stopped it has it, where
## the music stopped).
func set_transport(ask: Dictionary) -> void:
	if not app.timeline.is_record():
		set_running(bool(ask.on))
		return
	var now := session_us()
	var wanted: Dictionary
	if not bool(ask.on):
		var at: float = expected_step() if bool(ask.get("follow", false)) and bool(clock.running) else float(clock.get("punch_in", app.timeline.playhead))
		wanted = {"running": false, "anchor_us": now, "anchor_step": 0.0, "bpm": app.tempo, "playhead": maxf(at, 0.0)}
	elif bool(clock.running) and bool(ask.record):
		wanted = clock.duplicate()
		wanted.record = true
	else:
		# (punching in and out over the range on the ruler, or round it, a take a pass: from its start)
		var timeline = app.timeline
		var looped: bool = bool(ask.get("loop_record", false))
		var punched: bool = bool(ask.get("punch", false)) and not looped and timeline.loop_end > timeline.loop_start
		var from: float = timeline.loop_start if looped or punched else float(ask.from)
		var preroll := float(ask.get("preroll", 0.0)) if not bool(clock.running) else 0.0
		# A count-in: the click counts whole beats (at least one) before the music, which starts once it has.
		var count_in := float(ask.get("count_in", 0.0)) if bool(ask.record) else 0.0
		var beats := maxi(1, roundi(count_in / 4.0)) if count_in > 0.0 else 0
		var counted := int(beats * 4 * 15.0 / app.tempo * 1e6)
		wanted = {"running": true, "anchor_us": now + int(START_AHEAD * 1e6) + counted, "anchor_step": maxf(from - preroll, 0.0), "bpm": app.tempo,
			"record": bool(ask.record), "loop_record": looped, "punch_in": from, "count_in": count_in, "counted_us": counted,
			"punch_out": timeline.loop_end if punched else -1.0, "postroll": float(ask.get("postroll", 0.0)) if punched else 0.0}
	_send("clock", wanted)
	_follow(wanted)


## The room made a Jam room or a Record room (the host's): stopped, for everyone.
func mode_changed() -> void:
	if role == "host":
		clock = {"running": false, "anchor_us": session_us(), "anchor_step": 0.0, "bpm": app.tempo}
		_send("clock", clock)


func _output_latency() -> float:
	return float(audio.get_stats().get("output_latency_ms", 0.0)) / 1000.0


## The step being heard just now (the patterns run ahead of what is heard by the output's latency).
func _heard_step() -> float:
	var step: float = audio.get_sequencer_step_now()
	return -1.0 if step < 0.0 else step - _output_latency() * app.tempo / 15.0


## Every half second: the patterns nudged towards where the session says the music is (a few milliseconds at a time,
## ten while they are further out than that), or started again in step if they are far off. The host's tempo changing moves where the music is reckoned from.
func _keep_in_step() -> void:
	if not bool(clock.running) or (role == "guest" and _pings.is_empty()):
		return
	if role == "host" and not is_equal_approx(app.tempo, float(clock.bpm)):
		var moved: Dictionary = clock.duplicate()
		moved.anchor_us = session_us()
		moved.anchor_step = expected_step()
		moved.bpm = app.tempo
		clock = moved
		_send("clock", clock)
	if not is_equal_approx(app.tempo, float(clock.bpm)) or Time.get_ticks_usec() - _started_us < 300000 or bool(clock.get("record", false)):
		return  # (the tempo on its way here; or just started; or recording, when the take is to stay as it is played)
	var heard := _heard_step()
	if expected_step() < 2.0 and not app.timeline.is_record():
		return
	var off := ahead_of_session()
	if heard < 0.0 or absf(off) > 0.25:
		if app.timeline.is_record():
			_play_in_step()
		else:
			_start_in_step()
	elif absf(off) > 0.001:
		var most := NUDGE_FAR if absf(off) > NUDGE_FAR else NUDGE_MOST
		audio.nudge_sequencer(clampf(off, -most, most))


# ── Inputs ───────────────────────────────────────────────────────────────────────────────────────────────────

func _tell_engine_who() -> void:
	if role == "host":
		audio.set_net_players(PackedInt32Array(players.keys().filter(func(id): return int(id) != 1)))
	follow_voices()


# ── Arming ───────────────────────────────────────────────────────────────────────────────────────────────────

## A track armed or disarmed here (timeline.set_armed): whether it may be. Armed, it is this player's to record (and a
## Speaker's or an amp's input this player's to play through, which it must be to record it); nobody else's meanwhile.
func arm_switched(inst, on: bool) -> bool:
	if not is_playing_together():
		return true
	var by := int(inst.get_meta("armed_by", 0))
	if on:
		if not check("transport"):
			return false
		if by != 0 and by != me:
			app.session.notice.emit("%s has %s armed" % [name_of(by), inst.display_name])
			return false
		if inst.is_live() and not input_switched(inst, true):
			return false
		inst.set_meta("armed_by", me)
	else:
		if by == me:
			inst.set_meta("armed_by", 0)
		if inst.is_live() and not inst.input_on:
			input_switched(inst, false)
	return true


## A track as the session has it: armed here only if it is this player's to record.
func follow_arm(inst) -> void:
	var by := int(inst.get_meta("armed_by", 0))
	if by != 0 and by != me and inst.armed:
		inst.armed = false
		audio.set_record_arm(inst.source_id, false)
		app.follow_live_inputs()
		app.timeline.changed.emit()


## Who has a track armed, other than this player ("" if nobody, or this player).
func armed_by_another(inst) -> String:
	var by := int(inst.get_meta("armed_by", 0))
	return name_of(by) if by != 0 and by != me else ""


# ── Recordings' files ───────────────────────────────────────────────────────────────────────────────────────

func _path_of(name: String) -> String:
	return app.session.room_folder().path_join(name)


## Whether a recording's file is here (in the room's folder).
func has_file(name: String) -> bool:
	return FileAccess.file_exists(_path_of(name))


## A track's clips, come from another player: any of their files that isn't here asked for, of the host (which has
## every one, or is getting it).
func need_files(clips: Array) -> void:
	if role != "guest":
		return
	var names := {}
	for clip in clips:
		if str(clip.get("kind", "")) == "audio":
			names[str(clip.get("file", ""))] = true
			names[str(clip.get("di", ""))] = true  # (an amp's DI: "" for none, passed over below)
		for take in clip.get("takes", []):
			if str(take.get("kind", "")) == "audio":
				names[str(take.get("file", ""))] = true
				names[str(take.get("di", ""))] = true
	for name in names:
		if name != "" and not has_file(name) and not _asked.has(name) and not _incoming.has(name):
			_asked[name] = true
			_send("want", {"name": name}, 1)


## What this player has just recorded (its files' names): to the host, which passes them on to whoever wants them; or,
## the host's, to whoever has asked already.
func recorded(names: Array) -> void:
	for name in names:
		if role == "guest":
			_queue(str(name), 1)
		elif role == "host":
			for id in _wanted_by.get(str(name), []):
				_queue(str(name), int(id))
			_wanted_by.erase(str(name))


## (The host) a file asked for by a player: sent, if it is here; or once it has come.
func _serve(name: String, to: int) -> void:
	if has_file(name):
		_queue(name, to)
	else:
		if not _wanted_by.has(name):
			_wanted_by[name] = []
		if not _wanted_by[name].has(to):
			_wanted_by[name].append(to)


func _queue(name: String, to: int) -> void:
	var file := FileAccess.open(_path_of(name), FileAccess.READ)
	if file == null:
		return
	_outgoing.append({"name": name, "to": to, "at": 0, "size": file.get_length(), "file": file})


## Each frame: a few pieces of the files going (to one player, then the next).
func _send_files() -> void:
	var budget := CHUNKS_A_FRAME
	while budget > 0 and not _outgoing.is_empty():
		var each: Dictionary = _outgoing[0]
		var file: FileAccess = each.file
		file.seek(int(each.at))
		var data := file.get_buffer(CHUNK)
		_send("file", {"name": each.name, "size": int(each.size), "at": int(each.at), "data": data}, int(each.to), FILES)
		each.at = int(each.at) + data.size()
		budget -= 1
		if data.is_empty() or int(each.at) >= int(each.size):
			file.close()
			_outgoing.pop_front()


## A piece of a file come: written in its place (as name.part until it is whole, then named), and once whole, the
## tracks that play it told; the host passes it on to those waiting for it.
func _on_file(data: Dictionary) -> void:
	var name := str(data.name)
	if name.contains("..") or name.is_absolute_path():  # (only into the room's own folder)
		return
	var path := _path_of(name)
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var partial := path + ".part"
	var at := int(data.at)
	var file := FileAccess.open(partial, FileAccess.WRITE if at == 0 else FileAccess.READ_WRITE)
	if file == null:
		return
	file.seek(at)
	var bytes: PackedByteArray = data.data
	file.store_buffer(bytes)
	file.close()
	if not _incoming.has(name):
		_incoming[name] = {"size": int(data.size), "got": 0}
	_incoming[name].got = at + bytes.size()
	if at + bytes.size() < int(data.size):
		return
	_incoming.erase(name)
	_asked.erase(name)
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)
	DirAccess.rename_absolute(partial, path)
	app.timeline.file_arrived(name)
	if role == "host":
		for id in _wanted_by.get(name, []):
			_queue(name, int(id))
		_wanted_by.erase(name)


## How much of the recordings' files is still to come here, and to go from here (bytes), for the page.
func files_pending() -> Vector2i:
	var coming := 0
	for name in _incoming:
		coming += int(_incoming[name].size) - int(_incoming[name].got)
	var going := 0
	for each in _outgoing:
		going += int(each.size) - int(each.at)
	return Vector2i(coming, going)


# ── Voices ───────────────────────────────────────────────────────────────────────────────────────────────────

## Whether this player's voice wants the audio input open (playing together, an input chosen for it).
func wants_voice() -> bool:
	return is_playing_together() and app.settings.voice_input >= 0


## The voices as the session has them: this player's own (from its input, to the others, heard by nobody here), and
## each other player's, from where their head is.
func follow_voices() -> void:
	if not is_playing_together():
		return
	if wants_voice() and _voice_out < 0:
		_voice_out = audio.add_source("live", app.player.ear_position(), 1.0, 0.0)
		if _voice_out >= 0:
			audio.set_source_input_channel(_voice_out, app.settings.voice_input)
			audio.set_source_room_muted(_voice_out, true)  # (your own voice isn't sent back to you)
			audio.set_source_muted(_voice_out, true)
			audio.send_source_to_net(_voice_out, VOICE)
	elif not wants_voice() and _voice_out >= 0:
		audio.remove_source(_voice_out)
		_voice_out = -1
		talking = false
	if _voice_out >= 0:
		audio.set_source_input_channel(_voice_out, app.settings.voice_input)
	app.follow_live_inputs()
	for id in players:
		if int(id) != me and not _voices.has(int(id)):
			var source: int = audio.add_source("live", Vector3.ZERO, 1.0, 0.35)
			if source >= 0:
				audio.feed_source_from_net(source, int(id), VOICE)
				_voices[int(id)] = source
	for id in _voices.keys():
		if not players.has(id):
			audio.remove_source(_voices[id])
			_voices.erase(id)


func _silence_voices() -> void:
	for id in _voices:
		audio.remove_source(_voices[id])
	_voices.clear()
	if _voice_out >= 0:
		audio.remove_source(_voice_out)
		_voice_out = -1
	talking = false
	app.follow_live_inputs.call_deferred()


## Your voice's input chosen (-1: none), from the page.
func set_voice_input(channel: int) -> void:
	app.settings.voice_input = channel
	app.settings.save_to_disk()
	follow_voices()


## Each frame: your voice on while the talk key is held (unless something is being typed into), and each other
## player's coming from their head, their name saying when they talk.
func _voices_each_frame() -> void:
	var wanted: bool = _voice_out >= 0 and app.bindings.is_down("talk") and not (app.get_viewport().gui_get_focus_owner() is LineEdit)
	if wanted != talking:
		talking = wanted
		audio.set_source_input(_voice_out, talking)
	for id in _voices:
		var source: int = _voices[id]
		var info: Dictionary = players.get(id, {})
		var body: Dictionary = _bodies.get(id, {})
		if body.is_empty():
			continue
		var node: Node3D = body.node
		var mouth: Vector3 = node.global_transform * (Avatar.ears_at(float(info.get("height", 1.75))) + Vector3(0.0, -0.03, -0.09))
		if mouth.distance_to(body.get("mouth", Vector3.INF)) > 0.01:  # (moved: where the room, and its microphones, hear it from)
			body.mouth = mouth
			audio.set_source_position(source, mouth)
		var heard: bool = audio.get_source_level(source) > 0.002
		var tag := "%s  (talking)" % str(info.get("name", "Player")) if heard else str(info.get("name", "Player"))
		if body.get("tag", "") != tag:
			body.tag = tag
			body.body.set_name_tag(tag)


func name_of(id: int) -> String:
	return str(players.get(id, {}).get("name", "Someone"))


## A live input's input switched on or off here (main.set_input): whether it may be. Switched on, this player plays
## through it (unless another already does), its sound going to the others; switched off, it is free again.
func input_switched(inst, on: bool) -> bool:
	if not is_playing_together():
		return true
	var by := int(inst.get_meta("fed_by", 0))
	if on:
		if by != 0 and by != me:
			app.session.notice.emit("%s is playing through %s" % [name_of(by), inst.display_name])
			return false
		if by != me:
			_streams = _streams % 255 + 1
			inst.set_meta("fed_by", me)
			inst.set_meta("stream", _streams)
			inst.set_meta("sending", _streams)
			audio.send_source_to_net(inst.source_id, _streams)
	elif by == me:
		inst.set_meta("fed_by", 0)
		inst.set_meta("stream", 0)
		inst.set_meta("sending", 0)
		audio.send_source_to_net(inst.source_id, 0)
	return true


## A live input as the session has it: played by another player's sound (their input's, as it left theirs), or by
## this player's own input, or by nobody.
func follow_feed(inst) -> void:
	if not inst.is_live():
		return
	var by := int(inst.get_meta("fed_by", 0))
	var stream := int(inst.get_meta("stream", 0))
	var someone_else := by != 0 and by != me
	var wanted := [by, stream] if someone_else else [0, 0]
	if wanted != inst.get_meta("feeding", [0, 0]):
		audio.feed_source_from_net(inst.source_id, wanted[0], wanted[1])
		inst.set_meta("feeding", wanted)
	if someone_else and int(inst.get_meta("sending", 0)) != 0:  # (both switched it on at once: the host's order said theirs)
		inst.set_meta("sending", 0)
		audio.send_source_to_net(inst.source_id, 0)
	if someone_else and inst.input_on:
		inst.set_input(false)
		app.follow_live_inputs()
	var shown := name_of(by) if someone_else else ""
	if inst.played_by != shown:
		inst.played_by = shown
		inst._refresh_label()


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
		body.build(float(info.get("height", 1.75)), info.get("look", {}), Color(float(colour[0]), float(colour[1]), float(colour[2])), 1)
		body.set_name_tag(str(info.get("name", "Player")))
		var at: Array = data.at
		node.global_position = Vector3(float(at[0]), 0.0, float(at[1]))
		node.rotation.y = float(data.yaw)
		_bodies[id] = {"node": node, "body": body, "last": node.global_position, "made_of": _made_of(info)}
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
## What a player's body is made from: if it changes, the body is made again.
static func _made_of(info: Dictionary) -> int:
	return hash([info.get("name", ""), info.get("height", 1.75), info.get("look", {})])


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
	discovery.tick(delta)
	if meeting != null:
		meeting.tick(delta)
	if not _rejoin.is_empty():
		_try_rejoining(delta)
	if not is_playing_together():
		return
	if role == "host" and is_recording() and float(clock.get("punch_out", -1.0)) >= 0.0 and \
			expected_step() >= float(clock.punch_out) + float(clock.get("postroll", 0.0)):  # (punched out, and the post-roll played)
		set_transport({"on": false, "follow": false})
	sync.tick(delta)
	_send_files()
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
	_voices_each_frame()
