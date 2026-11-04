extends Node
## Rooms listed across the internet. A room hosted over the internet, and listed, is put on the room list
## (services/room-list: a Cloudflare Worker, with a D1 database) and kept there every half minute while it is hosted;
## the room browser fetches the list every few seconds while it is open. The list only lists: a player joining
## connects straight to the host's computer, at the address the list saw it come from (so the host's router must have
## opened its ports, as Over the internet asks it to). That must be its IPv4 address, which the sound between players
## goes to, so the host reaches the list over IPv4 alone, though its computer may have IPv6 too.
##
## The automated runs use a list of their own, on this computer (--room-list=http://127.0.0.1:<port>), never this one.

## The room list's address.
const ADDRESS := "https://studiosim-rooms.aja662.workers.dev"
const ANNOUNCE_EVERY := 30.0
const FETCH_EVERY := 5.0
const JSON_HEADERS := ["Content-Type: application/json"]

var net  # net.gd
var address := ""  # the list in use ("" for none)
var looking := false
var problem := ""  # (looking) why the list couldn't be had, if it couldn't
var listed := false  # (hosting) on the list
var listed_problem := ""  # (hosting) why the room isn't on it, if it isn't
var _rooms := []  # as the list last gave them
var _ask: HTTPRequest  # (hosting) putting the room on the list, keeping it there, taking it off
var _fetch: HTTPRequest
var _id := ""  # (hosting) the room on the list: its id (discovery.gd's, so that it is one room both ways), and token
var _token := ""
var _players := 0  # how many were in it when last put on the list
var _since_announce := ANNOUNCE_EVERY
var _since_fetch := FETCH_EVERY
var _named := ""  # the list's name ("studiosim-rooms…workers.dev"), as last looked up for its IPv4 address
var _ipv4 := ""  # and that address ("" until known, or if it has none)
var _resolving := -1


func setup(the_net) -> void:
	net = the_net
	var options: Dictionary = net.app.options
	address = str(options.get("room-list", "" if options.has("silent") else ADDRESS)).strip_edges().trim_suffix("/")
	_ask = HTTPRequest.new()
	_ask.timeout = 10.0
	_ask.request_completed.connect(_on_answered)
	add_child(_ask)
	_fetch = HTTPRequest.new()
	_fetch.timeout = 10.0
	_fetch.request_completed.connect(_on_fetched)
	add_child(_fetch)


## Fetching the list (while the room browser is open), or no longer.
func look(on: bool) -> void:
	if on == looking:
		return
	looking = on
	_since_fetch = FETCH_EVERY
	if not on:
		_rooms.clear()
		problem = ""


## The rooms the list gave, as the room browser shows them.
func found() -> Array:
	return _rooms if looking else []


func _process(delta: float) -> void:
	if address == "":
		return
	_look_up_ipv4()
	var hosting: bool = net.role == "host" and net.over_internet and bool(net.rules.get("listed", true))
	if hosting:
		if _id != net.discovery.id:  # (a session of its own)
			_id = net.discovery.id
			_token = "%x%x%x" % [randi(), randi(), Time.get_ticks_usec()]
			listed = false
			listed_problem = ""
			_since_announce = ANNOUNCE_EVERY
		if net.players.size() != _players:
			_since_announce = ANNOUNCE_EVERY
		_since_announce += delta
		if _since_announce >= ANNOUNCE_EVERY and _resolving < 0 and _ask.get_http_client_status() == HTTPClient.STATUS_DISCONNECTED:
			_since_announce = 0.0
			_players = net.players.size()
			var room: Dictionary = net.listing(_id)
			room.token = _token
			room.open = net.router == "open"
			if net.public_address.is_valid_ip_address() and not net.public_address.contains(":"):
				room.address4 = net.public_address
			_ask.request(_by_ipv4("/rooms"), _headers(), HTTPClient.METHOD_POST, JSON.stringify(room))
	elif _id != "":  # (the session over, or no longer listed: taken off)
		_ask.cancel_request()
		_ask.request(_by_ipv4("/rooms/" + _id), _headers(), HTTPClient.METHOD_DELETE, JSON.stringify({"token": _token}))
		_id = ""
		listed = false
	if looking:
		_since_fetch += delta
		if _since_fetch >= FETCH_EVERY and _fetch.get_http_client_status() == HTTPClient.STATUS_DISCONNECTED:
			_since_fetch = 0.0
			_fetch.request(address + "/rooms")


## The list's name, looked up for its IPv4 address alone (in the background), once for each list.
func _look_up_ipv4() -> void:
	var host := address.get_slice("://", 1).get_slice("/", 0).get_slice(":", 0)
	if host.is_valid_ip_address():
		_named = host
		_ipv4 = ""
		return
	if host != _named and _resolving < 0:
		_named = host
		_ipv4 = ""
		_resolving = IP.resolve_hostname_queue_item(host, IP.TYPE_IPV4)
		_ask.set_tls_options(TLSOptions.client(null, host))  # (its certificate is the name's, reached at the address)
	if _resolving >= 0 and IP.get_resolve_item_status(_resolving) in [IP.RESOLVER_STATUS_DONE, IP.RESOLVER_STATUS_ERROR]:
		_ipv4 = IP.get_resolve_item_address(_resolving) if IP.get_resolve_item_status(_resolving) == IP.RESOLVER_STATUS_DONE else ""
		IP.erase_resolve_item(_resolving)
		_resolving = -1


## Where on the list a host's request goes: at its IPv4 address once known, the name kept for the certificate and the
## Host header (otherwise as the address has it).
func _by_ipv4(path: String) -> String:
	return address.replace("://" + _named, "://" + _ipv4) + path if _ipv4 != "" else address + path


func _headers() -> PackedStringArray:
	return PackedStringArray(JSON_HEADERS + (["Host: " + _named] if _ipv4 != "" else []))


func _on_answered(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	if _id == "":  # (taking it off: nothing more to know)
		return
	var answer = JSON.parse_string(body.get_string_from_utf8())
	listed = result == HTTPRequest.RESULT_SUCCESS and code == 200
	listed_problem = "" if listed else (str(answer.get("error", "")) if answer is Dictionary and answer.has("error") else
		"the room list couldn't be reached")
	net.changed.emit()


func _on_fetched(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	if not looking:
		return
	var answer = JSON.parse_string(body.get_string_from_utf8()) if result == HTTPRequest.RESULT_SUCCESS and code == 200 else null
	if not (answer is Dictionary and answer.get("rooms") is Array):
		problem = "the room list couldn't be reached"
		return
	problem = ""
	_rooms = answer.rooms.filter(func(r): return r is Dictionary and r.has("id") and r.has("address") and r.has("port"))
	for room in _rooms:
		room.where = "internet"
