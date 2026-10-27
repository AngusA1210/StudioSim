extends RefCounted
## Finding rooms on this network, for the room browser, with no server: a player looking asks every computer on the
## network every couple of seconds (a UDP broadcast), and each one hosting a listed room answers with what it is (its
## name, its host, Jam or Record, how many are in it, whether it has a password). The host answers on a port of its
## own (47129, or one of the next three if another copy of Studiolator on that computer has it), from the same program
## its session's port belongs to, so a firewall that lets the one in lets the other.
##
## The automated runs ask this computer alone (127.0.0.1), never the network.

const PORT := 47129
const PORTS := 4  # (PORT and the next three)
const ASK := "SRFIND1"
const ANSWER := "SRROOM1"
const ASK_EVERY := 2.0
const FORGET_AFTER := 7.0  # seconds without an answer: no longer there

var net  # net.gd
var rooms := {}  # the room's own id → {name, host, mode, players, most, locked, address, port, protocol, seen}
var problem := ""  # what keeps this computer from asking the network, if anything
var looking := false
var _answering: PacketPeerUDP = null  # (hosting) the port asked on
var _asking: PacketPeerUDP = null
var _since := ASK_EVERY
var _id := ""  # (hosting) this session's, so that a room heard at two of its computer's addresses is one room


func _init(the_net) -> void:
	net = the_net


## (Hosting) answering those who ask, on `bind`'s address ("*": every network; "127.0.0.1": this computer alone).
func answer(bind: String) -> void:
	stop_answering()
	_id = "%x%x" % [randi(), Time.get_ticks_usec()]
	for k in PORTS:
		var socket := PacketPeerUDP.new()
		if socket.bind(PORT + k, bind) == OK:
			_answering = socket
			return


func stop_answering() -> void:
	if _answering != null:
		_answering.close()
		_answering = null


## Looking for rooms (while the room browser is open), or no longer.
func look(on: bool) -> void:
	if on == looking:
		return
	looking = on
	rooms.clear()
	problem = ""
	if on:
		_asking = PacketPeerUDP.new()
		_asking.set_broadcast_enabled(true)
		if _asking.bind(0) != OK:
			problem = "no network socket could be opened"
			_asking = null
		_since = ASK_EVERY
	elif _asking != null:
		_asking.close()
		_asking = null


## The rooms found, those heard from lately, by name.
func found() -> Array:
	var now := Time.get_ticks_msec()
	for id in rooms.keys():
		if now - int(rooms[id].seen) > int(FORGET_AFTER * 1000.0):
			rooms.erase(id)
	var out := rooms.values()
	out.sort_custom(func(a, b): return str(a.name).naturalnocasecmp_to(str(b.name)) < 0)
	return out


func tick(delta: float) -> void:
	if _answering != null:
		while _answering.get_available_packet_count() > 0:
			var asked := _answering.get_packet().get_string_from_utf8()
			if asked.begins_with(ASK) and net.role == "host" and bool(net.rules.get("listed", true)):
				_answering.set_dest_address(_answering.get_packet_ip(), _answering.get_packet_port())
				_answering.put_packet((ANSWER + " " + JSON.stringify(net.listing(_id))).to_utf8_buffer())
	if _asking == null:
		return
	while _asking.get_available_packet_count() > 0:
		var heard := _asking.get_packet().get_string_from_utf8()
		var address := _asking.get_packet_ip()
		if heard.begins_with(ANSWER + " "):
			var room = JSON.parse_string(heard.substr(ANSWER.length() + 1))
			if room is Dictionary and room.has("id"):
				var id := str(room.id)
				var was: Dictionary = rooms.get(id, {})
				room.address = address if was.is_empty() or str(was.address).begins_with("127.") else str(was.address)  # (this network's, rather than this computer's)
				room.seen = Time.get_ticks_msec()
				rooms[id] = room
	_since += delta
	if _since < ASK_EVERY:
		return
	_since = 0.0
	var ask := (ASK + " " + str(net.PROTOCOL)).to_utf8_buffer()
	var where := ["127.0.0.1"]  # (a room hosted on this computer, by another copy of Studiolator)
	if not net.app.options.has("silent"):
		where.append("255.255.255.255")
		for address in IP.get_local_addresses():  # (and each network's own broadcast address, as a /24 has it)
			if address.count(".") == 3 and not address.begins_with("127.") and not address.begins_with("169.254."):
				where.append(address.substr(0, address.rfind(".")) + ".255")
	var failed := false
	for address in where:
		for k in PORTS:
			_asking.set_dest_address(address, PORT + k)
			if _asking.put_packet(ask) != OK and address != "127.0.0.1":
				failed = true
	problem = ""
	if failed:
		problem = ("this Mac isn't letting Studiolator reach the local network: allow it in System Settings > Privacy & Security > Local Network " +
			"(for Godot, or for the app it was started from, such as Terminal)") if OS.get_name() == "macOS" else \
			"this computer couldn't ask the local network (is it connected to one?)"
