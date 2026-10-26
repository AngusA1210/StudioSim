extends RefCounted
## Meeting through a session server (audio_core/src/server/session_server.h), for players whose routers won't let
## others reach them. Hosting over the internet with a session server given, the host is given a code, which the
## others join with in place of an address. A player joining is told where the host's computer is, as the internet
## sees it, and the host where they are, and each sends to the other at once, which most routers take as leave to let
## the other's packets in: the two then talk directly. If they haven't reached each other after a few seconds, the
## server passes everything between them itself (a relay): the session's messages, and the sound between players.
##
## All of it is UDP: requests from a socket of its own here, and from the session's own sockets (ENet's, and the
## sound's: net_audio.h), so that the server sees where those are.

const VERSION := "SM1"
const PORT := 47100  # the server's, unless its address says otherwise
const LEAST := 128  # bytes: each request at least this long (the server's rule)
const ASK_EVERY := 1.0  # seconds: a request asked again until answered,
const GIVE_UP := 10.0  # for this long
const ALIVE_EVERY := 5.0  # (the host) the session kept alive, and its sockets seen
const DIRECT_FOR := 5.0  # (joining) a direct connection tried for this long, before going by way of the server
const KNOCK_FOR := 10.0  # (joining) the sound's socket shown to the server, for the host to send to, for this long
const KEEP_RELAY := 60.0  # (the host) a relay sent to from here for this long (then the session's own traffic keeps it open)
const CODE_LETTERS := "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"

var net  # net.gd
var server := ""  # as given ("meet.example.com", or with :port)
var server_ip := ""
var code := ""  # (the host's) the session's, as shown ("K7Q-M2D")
## How it is going. The host's: "finding" the server, "asking" it for a code, "hosted". A joining player's: "finding"
## the session, trying it "direct", asking for a relay ("relaying"), by way of the "relay", or "in" (directly). "" with
## a problem: it didn't work.
var state := ""
var problem := ""
var relay_only := false  # (joining, for the checks) by way of the server's relay from the first, never directly
var by_relay := false  # (joining) in by way of the server
var _socket := PacketPeerUDP.new()
var _server_port := PORT
var _resolving := -1  # (the server's name being looked up)
var _hosting := false
var _local := []  # (the host's) [game port, sound port, address on its own network]
var _token := ""  # (the host's) the session's, which only it knows
var _ticket := ""  # (joining) this player's, from the server
var _wanted := ""  # (joining) the code
var _nonce := ""  # this request's, to know its answer
var _since := 0.0  # since a request was last sent
var _waited := 0.0  # without an answer
var _answered := false  # (joining) the server has answered, if only to say wait
var _tried := 0.0  # (joining) the direct connection, so far
var _knocking := 0.0  # (joining, in directly) the sound's socket shown to the server for this long more
var _relays := []  # (the host's) [game port, sound port, until (ms)]: the server's relays to players joining


func _init(the_net) -> void:
	net = the_net


## Whether `text` is a session's code (three letters or digits, a dash, three more), rather than an address.
static func is_code(text: String) -> bool:
	var plain := text.strip_edges().to_upper()
	if plain.length() != 7 or plain[3] != "-":
		return false
	for c in plain.replace("-", ""):
		if not CODE_LETTERS.contains(c) and not c in "01OI":
			return false
	return true


## Hosting: a code asked for, for the session on `game_port` (and its sound on `sound_port`), at `local` on this
## computer's own network (for a player joining from that network).
func host(server_address: String, game_port: int, sound_port: int, local: String) -> void:
	_hosting = true
	_local = [game_port, sound_port, local]
	_begin(server_address)


## Joining: the session with `wanted` for its code found, and joined (by net.meet).
func find(server_address: String, wanted: String) -> void:
	_hosting = false
	_wanted = wanted.strip_edges().to_upper()
	_begin(server_address)


## (Joining) the session's connection made: no relay wanted.
func connected() -> void:
	if state == "direct":
		state = "in"


## (Joining) in the session, its sound begun: its socket shown to the server for a while (if not by way of the relay),
## for the host to send to.
func in_session() -> void:
	if not by_relay:
		_knocking = KNOCK_FOR
		_since = ASK_EVERY


## (Joining) the direct connection given up on: a relay asked for. False if it isn't to be (in already, or by way of
## one).
func go_by_relay() -> bool:
	if state != "direct":
		return false
	state = "relaying"
	_nonce = str(randi())
	_waited = 0.0
	_since = ASK_EVERY
	net.changed.emit()
	return true


func end() -> void:
	if _hosting and _token != "":
		for i in 2:
			_ask("end " + _token)
	if _resolving >= 0:
		IP.erase_resolve_item(_resolving)
		_resolving = -1
	_socket.close()
	state = ""


func tick(delta: float) -> void:
	if _resolving >= 0:
		match IP.get_resolve_item_status(_resolving):
			IP.RESOLVER_STATUS_DONE:
				var ip := IP.get_resolve_item_address(_resolving)
				IP.erase_resolve_item(_resolving)
				_resolving = -1
				if ip == "":
					_fail("the session server %s couldn't be found" % server)
				else:
					_reached(ip)
			IP.RESOLVER_STATUS_ERROR, IP.RESOLVER_STATUS_NONE:
				IP.erase_resolve_item(_resolving)
				_resolving = -1
				_fail("the session server %s couldn't be found" % server)
		return
	if server_ip == "" or state == "":
		return
	while _socket.get_available_packet_count() > 0:
		_heard(_socket.get_packet().get_string_from_utf8().split(" ", false))
		if state == "":
			return
	_since += delta
	if _hosting:
		_tick_hosting(delta)
	else:
		_tick_joining(delta)


func _tick_hosting(delta: float) -> void:
	match state:
		"asking":
			_waited += delta
			if _waited >= GIVE_UP:
				_fail("the session server %s didn't answer" % server)
			elif _since >= ASK_EVERY:
				_since = 0.0
				_ask("host %s %d %d %s" % [_nonce, int(_local[0]), int(_local[1]), str(_local[2])])
		"hosted":
			if _since >= ALIVE_EVERY:
				_since = 0.0
				_ask("alive " + _token)
				_from_session("game", server_ip, _server_port, "at %s game" % _token)
				_from_session("sound", server_ip, _server_port, "at %s sound" % _token)
				var now := Time.get_ticks_msec()
				_relays = _relays.filter(func(r): return int(r[2]) > now)
				for relay in _relays:
					_to_relay(relay)


func _tick_joining(delta: float) -> void:
	match state:
		"finding", "relaying":
			_waited += delta
			if _waited >= GIVE_UP:
				_fail("the session %s isn't ready (its host may still be starting it)" % _wanted if _answered else
					"the session server %s didn't answer" % server)
			elif _since >= ASK_EVERY:
				_since = 0.0
				_ask("find %s %s" % [_wanted, _nonce] if state == "finding" else "relay %s %s" % [_ticket, _nonce])
		"direct":
			_tried += delta
			if _tried >= DIRECT_FOR:
				go_by_relay()
			elif _since >= ASK_EVERY:
				_since = 0.0
				_from_session("game", server_ip, _server_port, "at %s game" % _ticket)
		"in", "relay":
			if _knocking > 0.0:
				_knocking -= delta
				if _since >= ASK_EVERY:
					_since = 0.0
					_from_session("sound", server_ip, _server_port, "at %s sound" % _ticket)


func _begin(server_address: String) -> void:
	server = server_address.strip_edges()
	var name := server
	_server_port = PORT
	if name.count(":") == 1:
		_server_port = int(name.get_slice(":", 1))
		name = name.get_slice(":", 0)
	_nonce = str(randi())
	state = "finding"
	if name.is_valid_ip_address():
		_reached(name)
	else:
		_resolving = IP.resolve_hostname_queue_item(name, IP.TYPE_IPV4)
		if _resolving < 0:
			_fail("the session server %s couldn't be looked up" % server)


func _reached(ip: String) -> void:
	server_ip = ip
	_socket.connect_to_host(ip, _server_port)
	state = "asking" if _hosting else "finding"
	_since = ASK_EVERY  # (at once)
	_waited = 0.0
	net.changed.emit()


func _heard(words: PackedStringArray) -> void:
	if words.size() < 2 or words[0] != VERSION:
		return
	_answered = true
	match words[1]:
		"hosted":  # hosted <nonce> <code> <token>
			if _hosting and state == "asking" and words.size() >= 5 and words[2] == _nonce:
				_waited = 0.0
				code = words[3].substr(0, 3) + "-" + words[3].substr(3)
				_token = words[4]
				state = "hosted"
				_since = ALIVE_EVERY  # (the session's sockets seen at once)
				net.changed.emit()
		"gone":  # (the server has forgotten the session, restarted, say: a code asked for again)
			if _hosting and state == "hosted":
				state = "asking"
				code = ""
				_nonce = str(randi())
				_since = ASK_EVERY
				net.changed.emit()
		"knock":  # knock <ticket> game|sound <address> <port>: a player joining, sent to so that their packets are let in here
			if _hosting and words.size() >= 6:
				_from_session(words[3], words[4], int(words[5]), "punch")
		"relay":  # relay <ticket> <game port> <sound port>: a player joining by way of the server
			if _hosting and words.size() >= 5:
				var relay := [int(words[3]), int(words[4]), Time.get_ticks_msec() + int(KEEP_RELAY * 1000.0)]
				_relays = _relays.filter(func(r): return int(r[0]) != relay[0])
				_relays.append(relay)
				_to_relay(relay)
		"busy":
			_fail("the session server is full just now")
		"unknown":  # unknown <nonce>
			if not _hosting and words.size() >= 3 and words[2] == _nonce:
				_fail("no session has the code %s" % _wanted)
		"found":  # found <nonce> <ticket> <address> <game port> <sound port> [<its own network's address> <game port> <sound port>]
			if not _hosting and state == "finding" and words.size() >= 7 and words[2] == _nonce:
				_waited = 0.0
				_ticket = words[3]
				var where := [words[4], int(words[5]), int(words[6])]
				if words.size() >= 10:  # (on the host's own network: its address there)
					where = [words[7], int(words[8]), int(words[9])]
				state = "direct"
				_tried = 0.0
				_since = ASK_EVERY
				if relay_only:
					go_by_relay()
				else:
					net.meet(where[0], where[1], where[0], where[2])
		"relayed":  # relayed <nonce> <game port> <sound port>
			if not _hosting and state == "relaying" and words.size() >= 5 and words[2] == _nonce:
				_waited = 0.0
				state = "relay"
				by_relay = true
				net.meet(server_ip, int(words[3]), server_ip, int(words[4]))


func _fail(why: String) -> void:
	problem = why
	state = ""
	net.meeting_failed(why)


## A request to the server, from this socket.
func _ask(text: String) -> void:
	_socket.put_packet(_padded(text))


## A packet from the session's own socket: the game's (ENet's) or the sound's.
func _from_session(which: String, ip: String, port: int, text: String) -> void:
	if not ip.is_valid_ip_address():
		return
	if which == "game":
		var peer := net.multiplayer.multiplayer_peer as ENetMultiplayerPeer
		if peer != null and peer.host != null:
			peer.host.socket_send(ip, port, _padded(text))
	elif which == "sound":
		net.audio.send_net_datagram(ip, port, _padded(text))


## (The host) a relay told where this end of it is: from the session's sockets, each to its port.
func _to_relay(relay: Array) -> void:
	_from_session("game", server_ip, int(relay[0]), "at %s relay" % _token)
	_from_session("sound", server_ip, int(relay[1]), "at %s relay" % _token)


static func _padded(text: String) -> PackedByteArray:
	var bytes := ("%s %s" % [VERSION, text]).to_utf8_buffer()
	if bytes.size() < LEAST:
		bytes.resize(LEAST)  # (with zeros, which the server reads as spaces)
	return bytes
