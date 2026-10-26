extends SceneTree
## The other player, for the automated checks: ui_check.gd hosts a room and starts this, a second copy of the game,
## which joins it and then does what the checks ask, saying what it found (over the session itself).
## Run by ui_check.gd: godot --headless --path game --script tests/together_guest.gd -- --silent --join=127.0.0.1:<port>
## [--password=<the host's>] (turned away, it quits with 2)

const RoomSync := preload("res://scripts/room_sync.gd")

var main
var view: SubViewport
var address := ""
var password := ""


func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--join="):
			address = arg.trim_prefix("--join=")
		if arg.begins_with("--password="):
			password = arg.trim_prefix("--password=")
	view = SubViewport.new()
	view.size = Vector2i(1280, 760)
	root.add_child(view)
	main = load("res://main.tscn").instantiate()
	view.add_child(main)
	_run()


func _run() -> void:
	for i in 30:
		await process_frame
	main.settings.player_name = "Guest"
	main.settings.height = 1.62
	main.player.set_height(1.62)
	main.net.reported.connect(_on_asked)
	main.net.join(address, password)
	var until := Time.get_ticks_msec() + 20000
	while main.net.role != "guest" and Time.get_ticks_msec() < until:
		await process_frame
	if main.net.role != "guest":
		print("GUEST: couldn't join %s (%s)" % [address, main.net.status])
		quit(2 if main.net.status.contains("password") else 1)
		return
	main.title.enter()
	for i in 20:
		await process_frame
	main.net.report({"step": "joined", "ids": main.net.sync.ids(), "kinds": main.instruments.map(func(i): return i.kind),
		"places": main.instruments.map(func(i): return main.net.sync.place_of(i)), "players": main.net.players.size(), "me": main.net.me,
		"room": main.net.sync.room_entry(), "at": [main.player.global_position.x, main.player.global_position.z]})
	until = Time.get_ticks_msec() + 180000  # (the checks go on for at most three minutes)
	while (main.net.role == "guest" or not main.net._rejoin.is_empty()) and Time.get_ticks_msec() < until:
		await process_frame
	quit(0)


## How far ahead of where the session's clock says the music is the patterns are heard (ms): the middle of thirty
## readings over a second and a bit (each may be a block out, or more, the two copies sharing one computer).
static func ahead_of_session(game) -> float:
	var readings := []
	for i in 30:
		readings.append(game.net.ahead_of_session() * 1000.0)
		await game.get_tree().create_timer(0.04).timeout
	readings.sort()
	return readings[readings.size() / 2]


func _on_asked(_from: int, ask: Dictionary) -> void:
	var sync = main.net.sync
	match str(ask.get("ask", "")):
		"move":  # an instrument picked up and put down somewhere else, by this player
			var inst = sync.find(str(ask.id))
			main.player.carry(inst)
			for i in 3:
				await process_frame
			main.player.put_down()
			inst.global_position = Vector3(float(ask.x), inst.global_position.y, float(ask.z))
			inst.sync_position()
			for i in 15:
				await process_frame
			main.net.report({"step": "moved", "place": sync.place_of(inst)})
		"state":  # how an instrument is here, and the room
			var inst = sync.find(str(ask.id))
			main.net.report({"step": "state", "state": sync.state_of(inst) if inst != null else {}, "room": sync.room_entry(),
				"tempo": main.tempo})
		"play":  # a note on an instrument, as the computer keyboard plays it
			var inst = sync.find(str(ask.id))
			main.audio.note_on(inst.source_id, int(ask.note), 0.9)
			main.net.played(inst.source_id, "on", int(ask.note), 0.9)
			for i in 30:
				await process_frame
			main.audio.note_off(inst.source_id, int(ask.note))
			main.net.played(inst.source_id, "off", int(ask.note))
			main.net.report({"step": "played"})
		"step":  # how far ahead of the session's clock the patterns are heard here (ms), read over half a second
			main.net.report({"step": "step", "ahead": await ahead_of_session(main), "running": main.sequence_running, "latency_ms": main.net.latency_ms})
		"input":  # a live input's input switched on or off, by this player
			var inst = sync.find(str(ask.id))
			main.set_input(inst, bool(ask.on))
			for i in 5:
				await process_frame
			main.net.report({"step": "input", "on": inst.input_on, "fed_by": int(inst.get_meta("fed_by", 0))})
		"talk":  # this player's voice on its first input, and the talk key held (the null device's silence, in these runs)
			main.net.set_voice_input(0)
			var hold := InputEventKey.new()
			hold.physical_keycode = main.bindings.key("talk")
			hold.pressed = true
			Input.parse_input_event(hold)
			for i in 10:
				await process_frame
			main.net.report({"step": "talk", "talking": main.net.talking, "live_input": main.live_input})
			await main.get_tree().create_timer(1.0).timeout
			hold = hold.duplicate()
			hold.pressed = false
			Input.parse_input_event(hold)
		"arm":  # a track armed (or disarmed) by this player, to record
			var inst = sync.find(str(ask.id))
			main.timeline.set_armed(inst, bool(ask.on))
			for i in 5:
				await process_frame
			main.net.report({"step": "arm", "armed": inst.armed})
		"transport":  # what the timeline is doing here
			var speaker_clips: Array = main.speaker.clips.map(func(c): return str(c.get("file", ""))) if main.speaker != null else []
			main.net.report({"step": "transport", "mode": main.timeline.mode, "playing": main.timeline.playing, "recording": main.timeline.recording,
				"at": main.timeline.position(), "folder": main.session.room_folder(), "speaker_clips": speaker_clips, "armed": main.instruments.filter(
				func(i): return i.armed).map(func(i): return i.display_name)})
		"leave":
			main.net.leave()
