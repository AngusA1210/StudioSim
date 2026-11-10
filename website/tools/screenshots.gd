extends SceneTree
# Screenshots for the website, from the real app: each scene set up through the app's own functions, drawn off-screen
# at 1920x1080 with the interface at 125 %, into website/_shots/ (not kept in git). From them, cropped and made JPEGs,
# come the pictures in website/static/img. On a Mac (the plug-ins shown are Apple's own):
#   godot --path game --script ../website/tools/screenshots.gd -- --silent            (all of them)
#   godot --path game --script ../website/tools/screenshots.gd -- --silent mixer,edit  (some)

var OUT := ""  # website/_shots/, beside the game (set as it starts)
const SIZE := Vector2i(1920, 1080)
const SCALE := 1.25
const AU_DELAY := "AU:61756678:64656c79:6170706c"
const AU_REVERB := "AU:61756678:72766232:6170706c"
const AU_EQ := "AU:61756678:6e626571:6170706c"
const AU_DYNAMICS := "AU:61756678:64636d70:6170706c"

var main
var view: SubViewport
var only := ""
var cam: Camera3D


func _initialize() -> void:
	OUT = ProjectSettings.globalize_path("res://").path_join("../website/_shots/").simplify_path() + "/"
	DirAccess.make_dir_recursive_absolute(OUT)
	view = SubViewport.new()
	view.size = SIZE
	view.size_2d_override = Vector2i(Vector2(SIZE) / SCALE)
	view.size_2d_override_stretch = true
	view.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	view.msaa_3d = Viewport.MSAA_4X
	root.add_child(view)
	main = load("res://main.tscn").instantiate()
	view.add_child(main)
	view.notification(Node.NOTIFICATION_VP_MOUSE_ENTER)
	create_timer(170.0).timeout.connect(func() -> void:
		print("TIMED OUT")
		quit(1))
	var args := OS.get_cmdline_user_args()
	if args.size() > 1:
		only = args[-1]
	_run()


func frames(n: int) -> void:
	for i in n:
		await process_frame


func seconds(t: float) -> void:
	await create_timer(t).timeout


func shot(name: String) -> void:
	await frames(6)
	view.get_texture().get_image().save_png(OUT + name + ".png")
	print("SHOT ", name)


func want(name: String) -> bool:
	return only == "" or only.split(",").has(name)


## The room from a camera of its own, the screen's readouts put away.
func beauty(name: String, from: Vector3, at: Vector3, fov := 62.0) -> void:
	cam.fov = fov
	cam.look_at_from_position(from, at, Vector3.UP)
	cam.make_current()
	main.hud.visible = false
	await frames(12)
	await shot(name)
	main.hud.visible = true
	main.player.look_through()


func _run() -> void:
	await frames(40)
	var session = main.session
	var timeline = main.timeline
	var player = main.player
	var number := 1
	while session.exists(session.location(), "Night session %d" % number):
		number += 1
	session.create("Night session %d" % number, session.location(), main.library.DEFAULT_TEMPLATE, {}, null, "record")
	await seconds(1.0)
	main.settings.room_brightness = 2.2
	main._apply_lighting()
	main.room.set_surface("north", "brick")
	main.room.set_surface("west", "wood")
	main.room.set_surface("east", "curtain")

	# In place of the drum machine, a studio kit miked up; a guitar combo with pedals and a mic at its cone.
	var machine = main.find_instrument("drums")
	var groove = main.audio.get_pattern(machine.source_id)
	var groove_steps: int = main.audio.get_pattern_steps(machine.source_id)
	main.remove_instrument(machine)
	var kit = main.add_instrument("studio_drums", Vector3(0.5, 0.0, -3.4), true)
	kit.face(Vector3(0.0, 0.0, 3.6))
	main.audio.set_pattern_steps(kit.source_id, groove_steps)
	main.audio.set_pattern(kit.source_id, groove)
	print("GROOVE ", groove.size(), " notes over ", groove_steps, " steps")
	await frames(4)
	var kit_mics: Array = await main.mic_kit(kit, "close")
	main.set_room_level(kit, -14.0)  # (the kit played softer in the room: its close mics were set for that)
	var amp = main.add_instrument("guitar_combo", Vector3(5.6, 0.0, 3.3))
	amp.face(Vector3(1.0, 0.0, 0.8))
	for kind in ["tuner", "compressor", "overdrive"]:
		main.add_pedal(amp, kind)
	main.add_pedal(amp, "delay", -1, true)
	main.add_pedal(amp, "reverb", -1, true)
	main.set_amp_control(amp, "gain", 6.5)
	main.set_amp_control(amp, "treble", 6.0)
	var toward: Vector3 = (Vector3(1.0, 0.0, 0.8) - amp.global_position).normalized()
	var amp_mic = main.add_instrument("mic_dynamic", amp.global_position + toward * 0.45)
	main.aim_mic(amp_mic, amp)
	var keys = main.find_instrument("keys")
	var verb = main.add_aux("Reverb")
	print("INSERTS ", main.set_insert(verb, 0, AU_REVERB), main.set_insert(keys, 0, AU_EQ), main.set_insert(keys, 1, AU_DELAY),
		main.set_insert(main.find_instrument("bass"), 0, AU_DYNAMICS))
	main.set_send(keys, 0, verb, -12.0)
	main.set_send(main.find_instrument("pad"), 0, verb, -9.0)
	for mic in kit_mics:
		if mic.display_name.begins_with("Snare Top") or mic.display_name.begins_with("OH"):
			main.set_send(mic, 0, verb, -15.0)
	main.set_instrument_level(main.find_instrument("bass"), -3.0)
	main.set_instrument_level(main.find_instrument("pad"), -6.5)
	main.set_instrument_level(main.find_instrument("bells"), -9.0)
	await frames(10)
	main.title.enter()
	await seconds(1.4)
	cam = Camera3D.new()
	cam.near = 0.05
	main.add_child(cam)

	if want("hero"):
		await beauty("hero_a", Vector3(-1.2, 1.75, 4.6), Vector3(0.9, 0.9, -2.4), 66.0)
		await beauty("hero_b", Vector3(6.3, 3.3, 4.5), Vector3(-0.8, 0.4, -1.2), 60.0)
		await beauty("hero_c", Vector3(2.4, 1.6, 0.6), Vector3(0.4, 0.9, -3.4), 60.0)
		await beauty("hero_d", Vector3(-6.2, 2.6, 4.4), Vector3(1.5, 0.5, -1.5), 62.0)
		await beauty("amp_room", Vector3(3.2, 1.2, 1.6), Vector3(5.6, 0.45, 3.3), 55.0)
		await beauty("kit_mics", Vector3(1.9, 1.7, -1.3), Vector3(0.5, 0.75, -3.4), 55.0)

	if want("room"):
		player.place(Vector3(0.4, 0.0, 4.0), 0.0)
		await frames(30)
		await shot("room")
		main._sit_at("keys")
		await frames(30)
		await shot("room_keys")
		player.start_playing(keys)
		await frames(30)
		await shot("playing_keys")
		player.stop_playing()

	if want("pattern"):
		main.sequencer.open(kit)
		await frames(20)
		await shot("pattern")
		main.sequencer.close()
		player.stop_playing()

	if want("amp"):
		main.amp_panel.open(amp)
		main.amp_panel.selected = 2
		await frames(20)
		await shot("amp")
		main.amp_panel.close()

	if want("mic"):
		main.mic_panel.open(amp_mic)
		await frames(30)
		await shot("mic_amp")
		main.mic_panel.close()
		for mic in kit_mics:
			if mic.display_name.begins_with("OH L"):
				main.mic_panel.open(mic)
				await frames(30)
				await shot("mic_overhead")
				main.mic_panel.close()

	if want("edit") or want("mixer"):
		# A few seconds recorded on the kit's mics, and notes on the keys and bass, so the tracks have clips to show.
		for mic in kit_mics:
			timeline.set_armed(mic, true)
		timeline.locate(0.0)
		print("RECORD ", timeline.start_recording())
		await seconds(10.6)
		timeline.stop()
		for wait in 40:
			await frames(3)
			if not timeline._taking:
				break
		for mic in kit_mics:
			timeline.set_armed(mic, false)
		var notes := []
		for bar in 4:
			for hit in [[0.0, 60], [0.0, 64], [0.0, 67], [6.0, 62], [6.0, 65], [10.0, 69], [12.0, 64], [12.0, 67]]:
				notes.append({"step": bar * 16.0 + hit[0], "length": 3.5, "note": hit[1] + (bar % 2) * 2, "velocity": 0.8})
		keys.clips = [{"kind": "midi", "name": "Keys 1", "start": 0.0, "length": 64.0, "notes": notes}]
		keys.automation["volume"] = [[0.0, -8.0], [16.0, 0.0], [48.0, 0.0], [64.0, -12.0]]
		timeline.sync(keys)
		var bass = main.find_instrument("bass")
		var line := []
		for bar in 4:
			for hit in [[0.0, 36], [3.0, 36], [6.0, 43], [8.0, 41], [11.0, 36], [14.0, 38]]:
				line.append({"step": bar * 16.0 + hit[0], "length": 2.0, "note": hit[1], "velocity": 0.85})
		bass.clips = [{"kind": "midi", "name": "Bass 1", "start": 0.0, "length": 32.0, "notes": line.filter(func(n): return n.step < 32.0)},
			{"kind": "midi", "name": "Bass 2", "start": 32.0, "length": 32.0,
				"notes": line.filter(func(n): return n.step >= 32.0).map(func(n): return {"step": n.step - 32.0, "length": n.length, "note": n.note, "velocity": n.velocity})}]
		timeline.sync(bass)

	if want("mixer"):
		timeline.locate(0.0)
		timeline.start_playing()
		main.mixer.open()
		await seconds(2.5)
		await shot("mixer")
		main.mixer.close()
		timeline.stop()

	if want("edit"):
		timeline.locate(22.0)
		main.edit_window.open()
		await frames(10)
		var tv = main.edit_window.view
		tv.scroll_y = clampf(tv.row_top(tv.tracks().find(keys)) + tv.scroll_y - tv.RULER, 0.0, tv._most_scroll())
		await seconds(0.8)
		await shot("edit")
		main.edit_window.show_automation(true)
		await frames(10)
		tv.scroll_y = clampf(tv.row_top(tv.tracks().find(keys)) + tv.scroll_y - tv.RULER, 0.0, tv._most_scroll())
		await seconds(0.5)
		await shot("edit_auto")
		main.edit_window.show_automation(false)
		main.edit_window.close()

	if want("menu"):
		main.room.add_wall(Vector2(2.2, 0.4), Vector2(2.2, 3.4), 2.4, "glass")
		main.menu.open(main.menu.ROOM_TAB)
		await frames(20)
		await shot("menu_room")
		main.menu.close()

	if want("instruments"):
		main.instrument_menu.open()
		await frames(20)
		await shot("instruments")
		main.instrument_menu.close()

	if want("avatar"):
		main.show_title()
		await frames(10)
		main.avatar_page.open()
		main.avatar_page._turn = 5.6
		await frames(8)
		await shot("avatar")
		main.avatar_page.close()
		main.together_page.open()
		await frames(20)
		await shot("together")
		main.together_page.close()

	quit(0)
