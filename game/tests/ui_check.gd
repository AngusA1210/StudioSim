extends SceneTree
## Drives the real game with pretend key presses and mouse clicks and checks what happens: the title screen,
## walking up to an instrument, its instruction card and input, the amps and their loop pedals, playing it, editing its pattern, the tempo and click, adding and removing instruments, the
## Speaker, the menu, the mixer and meter, the room's size and walls.
## Run: godot --headless --path game --script tests/ui_check.gd -- --silent
## (--silent keeps it from making a sound or touching saved settings; the exit code is the number of failures)

var main
var view: SubViewport  # headless runs only get a 64-pixel window, so the game runs in a full-size off-screen one
var failures := 0
const TrackMenu := preload("res://scripts/track_menu.gd")


func _initialize() -> void:
	view = SubViewport.new()
	view.size = Vector2i(1280, 760)
	view.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(view)
	main = load("res://main.tscn").instantiate()
	view.add_child(main)
	view.notification(Node.NOTIFICATION_VP_MOUSE_ENTER)  # as a real window does when the mouse is over it
	create_timer(150.0).timeout.connect(_on_timeout)  # a script error would otherwise leave this running for ever
	_run()


func _on_timeout() -> void:
	print("TIMED OUT: the checks did not finish (look for a script error above)")
	quit(1)


func check(ok: bool, what: String, detail := "") -> void:
	print("  [%s] %s  (%s)" % ["pass" if ok else "FAIL", what, detail])
	if not ok:
		failures += 1


func key(code: int, pressed := true) -> void:
	var e := InputEventKey.new()
	e.physical_keycode = code
	e.keycode = code
	e.pressed = pressed
	view.push_input(e)


func tap(code: int) -> void:
	key(code, true)
	await frames(2)
	key(code, false)
	await frames(2)


## A key pressed and let go with Ctrl and Shift held.
func control_shift_tap(code: int) -> void:
	for pressed in [true, false]:
		var e := InputEventKey.new()
		e.physical_keycode = code
		e.keycode = code
		e.ctrl_pressed = true
		e.shift_pressed = true
		e.pressed = pressed
		view.push_input(e)
		await frames(2)


## A key pressed and let go with Cmd held (and Shift, with `shift`).
func command_tap(code: int, shift := false) -> void:
	for pressed in [true, false]:
		var e := InputEventKey.new()
		e.physical_keycode = code
		e.keycode = code
		e.meta_pressed = true
		e.shift_pressed = shift
		e.pressed = pressed
		view.push_input(e)
		await frames(2)


func click(pos: Vector2, button := MOUSE_BUTTON_LEFT) -> void:
	var move := InputEventMouseMotion.new()
	move.position = pos
	move.global_position = pos
	move.relative = Vector2(2, 1)
	view.push_input(move)
	await frames(1)
	for pressed in [true, false]:
		var e := InputEventMouseButton.new()
		e.position = pos
		e.global_position = pos
		e.button_index = button
		e.pressed = pressed
		view.push_input(e)
		await frames(1)
	await frames(2)


## Moves the mouse over a point, as hovering does.
func hover(pos: Vector2) -> void:
	var move := InputEventMouseMotion.new()
	move.position = pos
	move.global_position = pos
	move.relative = Vector2(2, 1)
	view.push_input(move)
	await frames(2)


## Drags with the mouse from one point to another and lets go there: Godot's own drag and drop.
func mouse_drag(from: Vector2, to: Vector2) -> void:
	await hover(from)
	var grab := InputEventMouseButton.new()
	grab.position = from
	grab.global_position = from
	grab.button_index = MOUSE_BUTTON_LEFT
	grab.pressed = true
	view.push_input(grab)
	await frames(1)
	for step in 8:
		var at: Vector2 = from.lerp(to, (step + 1) / 8.0)
		var move := InputEventMouseMotion.new()
		move.position = at
		move.global_position = at
		move.relative = (to - from) / 8.0
		move.button_mask = MOUSE_BUTTON_MASK_LEFT
		view.push_input(move)
		await frames(1)
	var let_go := InputEventMouseButton.new()
	let_go.position = to
	let_go.global_position = to
	let_go.button_index = MOUSE_BUTTON_LEFT
	view.push_input(let_go)
	await frames(3)


## Turns a knob by dragging it up (or down, for negative) by so many pixels.
func turn(knob: Control, pixels: float) -> void:
	var at: Vector2 = knob.get_global_rect().get_center() - Vector2(0, 20)
	var grab := InputEventMouseButton.new()
	grab.position = at
	grab.global_position = at
	grab.button_index = MOUSE_BUTTON_LEFT
	grab.pressed = true
	view.push_input(grab)
	await frames(1)
	var move := InputEventMouseMotion.new()
	move.position = at + Vector2(0, -pixels)
	move.global_position = move.position
	move.relative = Vector2(0, -pixels)
	move.button_mask = MOUSE_BUTTON_MASK_LEFT
	view.push_input(move)
	await frames(1)
	var let_go := grab.duplicate()
	let_go.pressed = false
	view.push_input(let_go)
	await frames(2)


## Presses the mouse at one point of the floor plan (in metres) and lets go at another.
func drag(plan, from: Vector2, to: Vector2) -> void:
	var origin: Vector2 = plan.get_global_rect().position
	for step in 6:
		var at: Vector2 = origin + plan.to_screen(from.lerp(to, maxf(step - 1, 0) / 4.0))
		var move := InputEventMouseMotion.new()
		move.position = at
		move.global_position = at
		move.relative = Vector2(2, 1)
		move.button_mask = MOUSE_BUTTON_MASK_LEFT if step > 0 else 0
		view.push_input(move)
		await frames(1)
		if step == 0 or step == 5:
			var button := InputEventMouseButton.new()
			button.position = at
			button.global_position = at
			button.button_index = MOUSE_BUTTON_LEFT
			button.pressed = step == 0
			view.push_input(button)
			await frames(1)
	await frames(2)


## An instrument's level averaged over a while (a held pad note swells and ebbs as its two halves beat).
func average_level(id: int, duration: float) -> float:
	var total := 0.0
	var count := 0
	var until := Time.get_ticks_msec() + int(duration * 1000.0)
	while Time.get_ticks_msec() < until:
		var level: float = main.audio.get_source_level(id)
		total += level * level
		count += 1
		await process_frame
	return sqrt(total / maxi(count, 1))


## What it puts into the room and into the mix, over the same frames: (room, mix).
func room_and_mix(id: int, duration: float) -> Vector2:
	var total := Vector2.ZERO
	var until := Time.get_ticks_msec() + int(duration * 1000.0)
	while Time.get_ticks_msec() < until:
		var room: float = main.audio.get_source_room_level(id)
		var level: float = main.audio.get_source_level(id)
		total += Vector2(room * room, level * level)
		await process_frame
	return Vector2(sqrt(total.x), sqrt(total.y))


## The same, of what it puts into the room.
func average_room_level(id: int, duration: float) -> float:
	var total := 0.0
	var count := 0
	var until := Time.get_ticks_msec() + int(duration * 1000.0)
	while Time.get_ticks_msec() < until:
		var level: float = main.audio.get_source_room_level(id)
		total += level * level
		count += 1
		await process_frame
	return sqrt(total / maxi(count, 1))


func frames(n: int) -> void:
	for i in n:
		await process_frame


func seconds(s: float) -> void:
	await create_timer(s).timeout


func cell(col: int, row: int) -> Vector2:
	var grid = main.sequencer._grid
	var rect: Rect2 = grid.get_global_rect()
	var cw: float = (rect.size.x - grid.LABEL_WIDTH) / 16.0
	return rect.position + Vector2(grid.LABEL_WIDTH + (col + 0.5) * cw, (row + 0.5) * grid.row_height)


func has_note(id: int, step: int, note: int) -> Dictionary:
	for n in main.audio.get_pattern(id):
		if int(n.step) == step and int(n.note) == note:
			return n
	return {}


func _run() -> void:
	await frames(10)
	var audio = main.audio
	var player = main.player
	var seq = main.sequencer
	var drums = main.find_instrument("drums")
	var bass = main.find_instrument("bass")
	var speaker = main.speaker
	var title = main.title

	print("The title screen")
	await seconds(0.6)
	var heard := 0.0
	for inst in main.instruments:
		heard = maxf(heard, audio.get_source_level(inst.source_id))
	check(title.is_open() and title.camera.current and not player.camera.current and not main.hud._root.visible,
		"the game starts on the title screen, looking at the room from its own camera")
	check(heard > 0.001 and audio.get_transport().running, "the room is already playing behind it", "loudest instrument %.3f" % heard)
	check(title.buttons.new.has_focus() and not title.buttons.back.visible and not main.session.has_room() and
		title._status.text.begins_with("Playing through"), "with no room open yet, New room is ready under the keyboard",
		title._status.text.replace("\n", " / "))
	var stood: Vector3 = player.global_position
	for code in [KEY_E, KEY_TAB, KEY_T, KEY_N, KEY_M, KEY_P, KEY_SPACE]:
		await tap(code)
	check(player.playing == null and not seq.is_open() and not main.instrument_menu.is_open() and not main.mixer.is_open() and
		main.sequence_running and player.global_position.is_equal_approx(stood), "the room's own keys do nothing here")
	if main.menu.is_open():  # Tab and Space are the buttons' own keys here: Tab moved to the next button, Space pressed it
		main.menu.close()
	if main.rooms_page.is_open():
		main.rooms_page.close()
	await frames(2)
	await click(title.buttons.audio.get_global_rect().get_center())
	check(main.menu.is_open() and main.menu._tabs.get_tab_title(main.menu._tabs.current_tab) == "Playback Engine"
		and main.menu._resume.text.begins_with("Back") and not main.menu._to_title.visible and not title._ui.visible,
		"Audio setup opens the menu on the Playback Engine page", main.menu._tabs.get_tab_title(main.menu._tabs.current_tab))
	var with_binaural: Dictionary = audio.get_stats()
	check(main.menu._latency_label.text.contains("binaural") and with_binaural.binaural_ms > 0.0
		and is_equal_approx(with_binaural.output_latency_ms, with_binaural.buffer_ms + with_binaural.device_ms + with_binaural.binaural_ms),
		"the output latency it shows counts what binaural rendering adds", main.menu._latency_label.text)
	main.menu._binaural_toggle.button_pressed = false
	await seconds(0.3)
	var plain: Dictionary = audio.get_stats()
	check(not main.menu._latency_label.text.contains("binaural") and is_zero_approx(plain.binaural_ms)
		and is_equal_approx(plain.output_latency_ms, with_binaural.output_latency_ms - with_binaural.binaural_ms),
		"and less with binaural switched off", main.menu._latency_label.text)
	main.menu._binaural_toggle.button_pressed = true
	await seconds(0.3)
	check(main.settings.binaural and main.menu._latency_label.text.contains("binaural"), "switching it back on brings the delay back", main.menu._latency_label.text)
	check(main.menu._disk_label.text.contains("MB read ahead"), "the page says how much recorded audio is read ahead from disk", main.menu._disk_label.text)
	await tap(KEY_ENTER)
	check(title.is_open() and not main.rooms_page.is_open(), "Enter doesn't slip through the menu to the title's buttons")
	await tap(KEY_ESCAPE)
	await frames(3)
	check(not main.menu.is_open() and title.is_open() and title._ui.visible and title.buttons.new.has_focus(), "Esc comes back to the title")
	await click(title.buttons.controls.get_global_rect().get_center())
	check(main.menu.is_open() and main.menu._tabs.get_tab_title(main.menu._tabs.current_tab) == "Controls", "Controls opens the key list")
	await tap(KEY_ESCAPE)
	await frames(3)
	check(main.menu._tabs.get_tab_count() == 7 and not range(7).any(func(i): return main.menu._tabs.get_tab_title(i) == "Templates") and
		not title.buttons.has("templates"), "templates are neither on the title screen nor in the menu")
	await tap(KEY_ENTER)
	await frames(3)
	var rooms = main.rooms_page
	check(rooms.is_open() and rooms._new_page.visible and rooms._name.text == "Untitled room" and rooms._templates[0].name == "Default room" and
		rooms._templates[1].name == "Empty room" and rooms._carry.values().all(func(box): return box.button_pressed) and
		is_equal_approx(rooms._size.x.value, 14.0) and is_equal_approx(rooms._size.z.value, 10.0) and is_equal_approx(rooms._size.y.value, 4.0),
		"New room asks for a name, a template (the default room to begin with), its size and what to bring over, everything ticked")
	rooms._name.text = "Test room"
	rooms._check_name()
	main.set_master_volume_db(-80.0)  # left at the bottom behind the title, say
	await click(rooms._create.get_global_rect().get_center())
	await seconds(1.0)
	check(is_equal_approx(main.master_volume_db, 0.0), "a room made from the default template starts with the master fader at 0 dB",
		"%.1f dB" % main.master_volume_db)
	drums = main.find_instrument("drums")
	bass = main.find_instrument("bass")
	speaker = main.speaker
	check(not rooms.is_open() and main.session.room_name == "Test room" and FileAccess.file_exists(main.session.path) and
		main.instruments.size() == 6 and audio.get_pattern(drums.source_id).size() > 10, "Create room makes it from the template, saves it, and goes in",
		main.session.path)
	check(main.hud._meter_panel.visible and main.hud._meter.vertical and main.hud._meter_text.text.ends_with(" dB") and main.hud._meter.held_db() > -40.0,
		"the master meter stands upright on screen, reading the music", main.hud._meter_text.text)
	check(main.hud._binaural_chip.text == "BINAURAL" and main.hud._modes_panel.visible and not main.hud._follow_chip.visible,
		"the screen shows that binaural is on (the reverb has a fader now, so no lamp)")
	await tap(KEY_B)
	await tap(KEY_R)  # the edit window's key: in a Jam room it does nothing
	await tap(KEY_N)  # and insertion following playback is for Record rooms too
	await frames(2)
	check(main.hud._binaural_chip.text == "BINAURAL OFF" and not main.settings.binaural and not main.edit_window.is_open() and
		not main.settings.insertion_follows, "B switches binaural off, which it shows; R and N do nothing in a Jam room", main.hud._binaural_chip.text)
	await tap(KEY_B)
	await frames(2)
	check(main.settings.binaural and main.hud._binaural_chip.text == "BINAURAL", "and on again")
	check(not title.is_open() and not title.visible and player.camera.current and main.hud._root.visible, "Enter goes into the room, in the player's view",
		"title open %s, title showing %s, player camera %s, hud %s" % [title.is_open(), title.visible, player.camera.current, main.hud._root.visible])

	print("Walking up to an instrument")
	check(speaker.display_name == "Speaker", "the live input is called the Speaker", speaker.display_name)
	await tap(KEY_P)
	check(not seq.is_open(), "P does nothing when you aren't at an instrument")
	await tap(KEY_TAB)
	check(main.mixer.is_open(), "Tab opens the mix window from anywhere")
	await tap(KEY_TAB)
	check(not main.mixer.is_open(), "and closes it again")
	main._sit_at("drums")
	await frames(5)
	check(player.target == drums and player.can_play_target(), "standing at the drums, they are what you're facing")
	var card: Array = main.hud.hint_lines()
	check(card == ["Drums", "E Play", "P Edit Pattern", "I Enable Input", "M Loop Off", "G Carry", "⌘L Lock in Place", "V Duplicate", "Backspace Remove (press twice)"],
		"a card lists what each key does, one per line, with removing at the bottom", " / ".join(card))
	var parts := 0
	for node in drums._model.find_children("*", "MeshInstance3D", true, false):
		parts += 1
	check(parts > 30 and drums.source_height == 0.9 and is_equal_approx(drums.global_position.y, 0.9), "the drums are a drum kit standing on the floor",
		"%d parts" % parts)

	print("Playing by hand")
	await tap(KEY_M)
	check(not drums.loop_on and drums._label.text.contains("loop off"), "M switches the drum loop off", drums._label.text)
	await seconds(0.8)
	var quiet: float = audio.get_source_level(drums.source_id)
	await tap(KEY_E)
	check(player.playing == drums and main.hud._piano.visible, "E sits down at the drums and shows the keyboard", main.hud._piano_help.text)
	check(drums.input_on and drums._input_badge.visible and main.armed_instruments() == [drums],
		"sitting down switches the drums' input on, and a green i shows under their name")
	check(main.hud._piano_keys[KEY_A].piece.text == "Kick" and main.hud._piano_keys[KEY_T].piece.text == "CH" and main.hud._piano_keys[KEY_S].piece.text == "Snare",
		"the keys are labelled with the drums they hit", "A %s, S %s, T %s" % [main.hud._piano_keys[KEY_A].piece.text, main.hud._piano_keys[KEY_S].piece.text, main.hud._piano_keys[KEY_T].piece.text])
	key(KEY_A)
	await frames(3)
	var hit: float = audio.get_source_level(drums.source_id)
	key(KEY_A, false)
	check(quiet < 0.0005 and hit > 0.01, "with the loop off the drums are silent until a key is pressed", "before %.4f, on the hit %.3f" % [quiet, hit])
	await tap(KEY_M)
	check(drums.loop_on, "M works while playing too, and brings the loop back")

	print("The pattern editor")
	await tap(KEY_P)
	check(seq.is_open() and seq.inst == drums and seq._title.text == "Drums pattern", "P opens the drums' pattern", seq._title.text)
	check(seq._grid.rows.size() == 8 and seq._grid.rows[7].label == "Kick" and seq._grid.rows[0].label == "Crash", "eight rows, kick at the bottom",
		"%d rows" % seq._grid.rows.size())
	check(not seq._note_length_box.visible, "no note-length choice for drums")
	seq._on_bar_pressed(0)
	await frames(2)
	var id: int = drums.source_id
	var before: int = audio.get_pattern(id).size()
	var clap := 39
	check(seq._grid.rows[3].note == clap, "row four is the clap", str(seq._grid.rows[3].note))
	await click(cell(4, 3))
	var added := has_note(id, 4, clap)
	check(not added.is_empty() and audio.get_pattern(id).size() == before + 1 and is_equal_approx(added.velocity, 0.8),
		"clicking an empty square adds a note", seq._status.text)
	await click(cell(4, 3), MOUSE_BUTTON_RIGHT)
	check(is_equal_approx(has_note(id, 4, clap).velocity, 0.5), "right-click makes it softer", seq._status.text)
	await click(cell(4, 3), MOUSE_BUTTON_RIGHT)
	var sometimes := has_note(id, 4, clap)
	check(sometimes.chance < 1.0, "again, and it plays only now and then", seq._status.text)
	await click(cell(4, 3), MOUSE_BUTTON_RIGHT)
	check(is_equal_approx(has_note(id, 4, clap).velocity, 1.0) and has_note(id, 4, clap).chance >= 1.0, "again, and it is back to loud", seq._status.text)
	await click(cell(4, 3))
	check(has_note(id, 4, clap).is_empty() and audio.get_pattern(id).size() == before, "clicking a note removes it", seq._status.text)
	await click(cell(0, 7))
	check(has_note(id, 0, 36).is_empty(), "clicking the kick on beat one removes it", seq._status.text)
	await click(cell(0, 7))
	check(not has_note(id, 0, 36).is_empty(), "and clicking again puts one back")
	var over := InputEventMouseMotion.new()
	over.position = cell(4, 6)
	over.global_position = over.position
	over.relative = Vector2(3, 2)
	view.push_input(over)
	await frames(2)
	check(seq._status.text.begins_with("Snare  ·  bar 1, step 5"), "pointing at a note says what it is", seq._status.text)

	seq._bars[2].pressed.emit()
	await frames(2)
	check(seq.bar == 2, "the bar buttons change the bar shown")
	await click(cell(1, 6))
	check(not has_note(id, 33, 38).is_empty(), "a click in bar three lands in bar three", seq._status.text)
	seq._on_clear_bar()
	var left_in_bar := 0
	for n in audio.get_pattern(id):
		if int(n.step) >= 32 and int(n.step) < 48:
			left_in_bar += 1
	check(left_in_bar == 0 and audio.get_pattern(id).size() > 40, "clearing a bar leaves the other bars alone", "%d notes left" % audio.get_pattern(id).size())
	seq._length.select(0)
	seq._on_length_selected(0)
	await frames(2)
	check(audio.get_pattern_steps(id) == 16 and seq._bars[1].disabled and seq.bar == 0, "a one-bar pattern only has bar one")
	seq._on_reset()
	await frames(2)
	check(audio.get_pattern(id).size() == 86 and audio.get_pattern_steps(id) == 64, "back to the default pattern")

	print("Tempo, click and transport")
	seq._tempo.value = 120
	await frames(2)
	check(is_equal_approx(main.tempo, 120.0) and is_equal_approx(audio.get_transport().bpm, 120.0), "the tempo box sets the tempo", str(audio.get_transport().bpm))
	await tap(KEY_SPACE)
	await frames(3)
	check(not main.sequence_running and int(audio.get_transport().step) == -1 and seq._play.text.contains("Play"), "Space stops the patterns", seq._play.text)
	seq._play.pressed.emit()
	await seconds(0.3)
	check(main.sequence_running and int(audio.get_transport().step) >= 0, "the Play button starts them again", str(audio.get_transport().step))
	seq._click.button_pressed = true
	await frames(2)
	check(main.settings.click and audio.get_transport().click, "the click switch turns the metronome on")
	await tap(KEY_P)
	check(not seq.is_open() and player.playing == drums, "P closes the editor; you are still at the drums")
	await tap(KEY_C)
	check(not main.settings.click, "C switches the click off")
	check(main.hud._beat.text.contains("120 BPM"), "the beat readout shows the tempo", main.hud._beat.text)
	await tap(KEY_Q)
	check(player.playing == null and not drums.input_on and not drums._input_badge.visible, "Q stands up, and the drums' input goes off again")
	await tap(KEY_I)
	check(drums.input_on and drums._input_badge.visible and main.armed_instruments() == [drums], "I switches it on for good")
	main._sit_at("keys")
	await frames(5)
	var keys = main.find_instrument("keys")
	await tap(KEY_E)
	await seconds(0.5)
	key(KEY_A)
	await frames(4)
	var keys_level: float = audio.get_source_level(keys.source_id)
	var drums_level: float = audio.get_source_level(drums.source_id)
	key(KEY_A, false)
	check(keys_level > 0.001 and drums_level > 0.01, "sitting at the Keys, a key plays them and the drums, whose input is still on",
		"keys %.3f, drums %.3f" % [keys_level, drums_level])
	await tap(KEY_Q)
	check(not keys.input_on and drums.input_on, "getting up switches only the Keys' input off")
	main._sit_at("drums")
	await frames(5)
	await tap(KEY_I)
	check(not drums.input_on, "and I switches the drums' off")

	print("A melodic instrument")
	main._sit_at("bass")
	await frames(5)
	await tap(KEY_P)
	check(seq.is_open() and seq.inst == bass and player.playing == bass, "P opens the bass pattern straight from facing it", seq._title.text)
	check(seq._note_length_box.visible and seq._grid.rows.size() >= 33, "a row for each note, and a note-length choice", "%d rows" % seq._grid.rows.size())
	await frames(4)
	seq._on_bar_pressed(0)
	await frames(2)
	# Click a row that is on screen: the one in the middle of the visible list.
	var scroll_rect: Rect2 = seq._scroll.get_global_rect()
	var grid_rect: Rect2 = seq._grid.get_global_rect()
	var row := int((scroll_rect.get_center().y - grid_rect.position.y) / seq._grid.row_height)
	var note: int = seq._grid.rows[row].note
	check(scroll_rect.size.y > 100 and grid_rect.size.y > scroll_rect.size.y, "the note list scrolls", "showing %d of %d px, scrolled to %d" % [scroll_rect.size.y, grid_rect.size.y, seq._scroll.scroll_vertical])
	var taken := not has_note(bass.source_id, 5, note).is_empty()
	seq._note_length_option.select(2)
	seq._on_note_length_selected(2)
	await click(cell(5, row))
	var made := has_note(bass.source_id, 5, note)
	check(not taken and not made.is_empty() and is_equal_approx(made.length, 4.0), "a click adds a quarter note on that pitch", seq._status.text)
	await click(cell(7, row))
	check(has_note(bass.source_id, 5, note).is_empty(), "clicking anywhere along a long note removes it", seq._status.text)
	await tap(KEY_ESCAPE)
	check(not seq.is_open() and player.playing == null and not main.menu.is_open(), "Esc closes the editor, and you are standing again")

	print("Adding and removing instruments")
	var im = main.instrument_menu
	player.place(Vector3(0.0, 0.0, 3.6), 0.0)  # the middle of the room, facing nothing in particular
	await frames(5)
	var count_before: int = main.instruments.size()
	var others: int = audio.get_source_count() - count_before  # (the sources that aren't instruments: the master's inserts')
	await tap(KEY_BACKSPACE)
	check(player.target == null and player.remove_pending == null, "Backspace does nothing when you aren't facing an instrument")
	await tap(KEY_T)
	check(im.is_open() and im._cards.size() == 20 and not im._cards[0].disabled, "N opens the instrument menu, with the amps among the live inputs, and the microphones",
		im._footer.text)
	await click(im._card_for.bass.get_global_rect().get_center())
	var bass2 = player.carried
	check(not im.is_open() and bass2 != null and bass2.display_name == "Bass 2" and bass2.kind == "bass" and main.instruments.size() == count_before + 1,
		"picking Bass puts a second bass in your hands", " / ".join(main.hud.hint_lines()))
	check(audio.get_pattern(bass2.source_id).is_empty() and bass2.loop_on and bass2.color != bass.color, "it has an empty pattern and a paler colour")
	await seconds(0.3)
	var ahead: Vector3 = bass2.global_position - player.global_position
	check(ahead.z < -1.0 and absf(ahead.x) < 0.2, "it floats in front of you", str(ahead))
	await tap(KEY_G)
	await frames(5)
	check(player.carried == null and player.target == bass2 and player.can_play_target(), "G puts it down, and it is what you're facing")
	await seconds(0.3)
	var silent_before: float = audio.get_source_level(bass2.source_id)
	await tap(KEY_E)
	key(KEY_A)
	await frames(4)
	var sounding: float = audio.get_source_level(bass2.source_id)
	key(KEY_A, false)
	check(player.playing == bass2 and silent_before < 0.0005 and sounding > 0.01, "it is silent until you play it", "before %.4f, playing %.3f" % [silent_before, sounding])
	await tap(KEY_P)
	check(seq.is_open() and seq._title.text == "Bass 2 pattern", "and it has its own pattern to edit", seq._title.text)
	await tap(KEY_BACKSPACE)
	check(main.instruments.has(bass2), "Backspace is ignored while the pattern editor is open")
	await tap(KEY_P)
	await tap(KEY_BACKSPACE)
	await frames(2)
	check(player.remove_pending == bass2 and main.instruments.has(bass2) and main.hud.hint_lines()[0] == "Remove Bass 2?",
		"one Backspace only asks", " / ".join(main.hud.hint_lines()))
	await tap(KEY_BACKSPACE)
	await frames(3)
	check(not main.instruments.has(bass2) and main.instruments.size() == count_before and audio.get_source_count() == count_before + others
		and player.playing == null and not is_instance_valid(bass2), "a second one removes it")

	await tap(KEY_T)
	im._input_option.select(im._input_option.item_count - 1)  # the last hardware input there is
	im._on_input_selected(im._input_option.selected)
	await click(im._card_for.live.get_global_rect().get_center())
	var speaker2 = player.carried
	check(speaker2 != null and speaker2.display_name == "Speaker 2" and not speaker2.playable
		and speaker2.input_channel == im._input_option.item_count - 2, "a second Speaker, set to the input chosen in the menu",
		"input %d of %d" % [speaker2.input_channel + 1, im._input_option.item_count - 1])
	await tap(KEY_G)
	await frames(5)
	check(not speaker2.input_on and not main.live_input, "a new Speaker's input starts off, and the audio input is closed")
	await tap(KEY_I)
	await frames(3)
	check(speaker2.input_on and speaker2._input_badge.visible and main.live_input and audio.get_stats().get("live_input", false),
		"I switches its input on: the audio input opens, and a green i shows under its name")
	await tap(KEY_TAB)
	await frames(5)
	var strip2: Dictionary = main.mixer._strips[main.instruments.find(speaker2)]
	check(main.mixer.is_open() and strip2.source is OptionButton and strip2.input.button_pressed, "its strip in the mix window has an input list, and its input lit",
		strip2.source.get_item_text(strip2.source.selected))
	strip2.source.select(0)
	main.mixer._on_source_selected(0, speaker2)
	check(speaker2.input_channel == -1, "choosing All in there sets which input it plays")
	await click(strip2.input.get_global_rect().get_center())
	check(not speaker2.input_on and not main.live_input, "its I button switches the input off, and the audio input closes")
	await tap(KEY_TAB)
	main.menu.open(main.menu.IO_TAB)
	await frames(15)
	check(main.menu._live_rows.get_child_count() == 2, "the I/O page has a row for each Speaker", "%d rows" % main.menu._live_rows.get_child_count())
	main.menu._on_live_clicked(1, speaker2)
	check(speaker2.input_channel == 1 and speaker.input_channel == main.settings.speaker_input, "each Speaker's input is set on its own row")
	await tap(KEY_ESCAPE)
	await tap(KEY_BACKSPACE)
	await tap(KEY_BACKSPACE)
	check(not main.instruments.has(speaker2) and not main.menu.is_open(), "the second Speaker can be removed too")

	var extras := []
	while true:
		var extra = main.add_instrument("bells", Vector3(0.0, 1.6, 0.0))
		if extra == null:
			break
		extras.append(extra)
	await tap(KEY_T)
	check(main.instruments.size() == main.instrument_capacity() and main.instrument_capacity() == audio.get_max_sources() - others and im._cards[0].disabled and im._footer.text.begins_with("The room is full"),
		"a full room says so and offers nothing more", "%d instruments, the last one is %s" % [main.instruments.size(), extras[-1].display_name])
	await tap(KEY_T)
	for extra in extras:
		main.remove_instrument(extra)
	await seconds(0.4)
	var returned = main.add_instrument("pad", Vector3(0.0, 1.6, 0.0))
	check(not im.is_open() and audio.get_source_count() == count_before + others + 1 and returned != null and returned.display_name == "Pad 2",
		"N closes the menu again, and removing instruments makes space")
	main.remove_instrument(returned)

	print("An amp and its loop pedal")
	main.set_tempo(240.0)  # bars of one second, so the pedal doesn't keep the test waiting
	player.place(Vector3(0.0, 0.0, 3.6), 0.0)
	await frames(3)
	await tap(KEY_T)
	await click(im._card_for.guitar_combo.get_global_rect().get_center())
	var amp = player.carried
	check(amp != null and amp.display_name == "Guitar Combo" and amp.is_amp and not amp.playable and amp.pedals.is_empty(),
		"the instrument menu offers a guitar combo, its pedalboard empty")
	await tap(KEY_G)
	await frames(5)
	var bare_card: Array = main.hud.hint_lines()
	await tap(KEY_L)
	await frames(2)
	check(player.target == amp and bare_card.has("P Amp and Pedals") and not bare_card.has("L Record a Loop") and not bare_card.has("E Play") and
		amp.looper.get("state", "") == "none" and amp._led == null, "without a loop pedal its card offers the amp and pedals, and L does nothing",
		" / ".join(bare_card))
	await tap(KEY_P)
	await frames(3)
	var panel = main.amp_panel
	check(panel.is_open() and panel._tiles.is_empty() and panel._empty_page.visible, "its panel says the board is empty")
	await click(panel._add_button.get_global_rect().get_center())
	panel._add_menu.id_pressed.emit(load("res://scripts/catalog.gd").PEDAL_ORDER.find("looper"))
	panel._add_menu.hide()
	await frames(3)
	check(amp.pedals.size() == 1 and amp.pedals[0].kind == "looper" and panel._loop_page.visible and panel._display.text == "EMPTY" and
		panel._add_menu.is_item_disabled(load("res://scripts/catalog.gd").PEDAL_ORDER.find("looper")),
		"+ Pedal puts a loop pedal on the board, and then offers no second one")
	await tap(KEY_P)
	await frames(5)
	var amp_card: Array = main.hud.hint_lines()
	check(not panel.is_open() and amp_card.has("L Record a Loop") and amp_card.has("1 Stamp on a Pedal") and amp._led != null and
		amp._pedal_row.get_child_count() == 1, "now its card offers the loop pedal, and it stands on the floor", " / ".join(amp_card))
	await tap(KEY_L)
	await frames(3)
	# With Sync it waits for the next bar line, unless one fell in the frames just gone.
	var armed: bool = amp.looper.get("state", "") == "waiting" or (amp.looper.get("state", "") == "recording" and amp.looper.get("length", 1.0) < 0.06)
	check(amp.input_on and armed, "L arms the pedal: its input goes on, and with Sync it waits for the bar line", amp.looper.get("state", ""))
	var waited := 0.0
	while amp.looper.get("state", "") == "waiting" and waited < 1.5:
		await seconds(0.02)
		waited += 0.02
	check(amp.looper.get("state", "") == "recording", "on the bar line it starts recording", "after %.2f s" % waited)
	await seconds(0.4)
	await tap(KEY_L)  # under a bar in: it carries on to the end of the bar
	await seconds(1.0)
	check(amp.looper.get("state", "") == "playing" and absf(float(amp.looper.get("length", 0.0)) - 1.0) < 0.02 and amp._loop_label.text.begins_with("▶ LOOP"),
		"L again closes the loop on the next bar line, a whole bar long, and it plays", "%.3f s; %s" % [amp.looper.get("length", 0.0), amp._loop_label.text])
	await tap(KEY_L)
	await frames(3)
	check(amp.looper.get("state", "") == "overdubbing", "L once more overdubs")
	await seconds(0.3)
	await tap(KEY_L)
	await seconds(0.3)
	check(amp.looper.get("state", "") == "playing" and amp.looper.get("can_undo", false) and main.hud.hint_lines().has("U Undo the Last Overdub"),
		"and again goes back to playing, with the overdub ready to undo")
	await tap(KEY_U)
	await frames(3)
	check(amp.looper.get("can_redo", false) and not amp.looper.get("can_undo", false), "U undoes it")
	await tap(KEY_O)
	await frames(3)
	check(amp.looper.get("state", "") == "stopped" and amp._loop_label.text.contains("stopped"), "O stops the loop", amp._loop_label.text)
	await tap(KEY_P)
	await frames(4)
	check(panel.is_open() and panel.inst == amp and panel._display.text == "■ STOPPED" and panel._footswitch.text.begins_with("Play"),
		"P opens the amp's panel: its knobs and the loop pedal", panel._display.text)
	var gain_knob = panel._knobs.gain
	var knob_at: Vector2 = gain_knob.get_global_rect().get_center() - Vector2(0, 20)
	var grab := InputEventMouseButton.new()
	grab.position = knob_at
	grab.global_position = knob_at
	grab.button_index = MOUSE_BUTTON_LEFT
	grab.pressed = true
	view.push_input(grab)
	await frames(1)
	var turn := InputEventMouseMotion.new()
	turn.position = knob_at + Vector2(0, -45)
	turn.global_position = turn.position
	turn.relative = Vector2(0, -45)
	turn.button_mask = MOUSE_BUTTON_MASK_LEFT
	view.push_input(turn)
	await frames(1)
	var let_go := grab.duplicate()
	let_go.pressed = false
	view.push_input(let_go)
	await frames(2)
	check(absf(amp.amp_controls.gain - 8.0) < 0.2, "dragging the Gain knob up turns it up", "%.2f" % amp.amp_controls.gain)
	var combo_top: float = amp.top
	check(panel._head_choice.get_item_text(panel._head_choice.selected) == "Crunch" and panel._cabinet_choice.get_item_text(panel._cabinet_choice.selected) == "1x12 open back",
		"the combo starts with a Crunch head in a 1x12 open-back cabinet")
	panel._cabinet_choice.select(2)
	panel._cabinet_choice.item_selected.emit(2)
	panel._head_choice.select(2)
	panel._head_choice.item_selected.emit(2)
	await frames(3)
	check(amp.amp_cabinet == "4x12" and amp.amp_head == "high_gain" and amp.top > combo_top + 0.2 and amp.footprint.x > 0.7,
		"a High Gain head and a 4x12 can be swapped in, and the amp is drawn with the bigger cabinet", "%.2f m tall" % amp.top)
	var speakers_listed: int = panel._speaker_choice.item_count
	var usual: String = panel._speaker_choice.get_item_text(panel._speaker_choice.selected)
	panel._speaker_choice.select(0)
	panel._speaker_choice.item_selected.emit(0)
	await frames(2)
	var chose: String = amp.amp_speaker
	var kept_settings: Dictionary = main.library.instrument_settings(amp)
	panel._cabinet_choice.select(3)  # a 1x15: its own speaker
	panel._cabinet_choice.item_selected.emit(3)
	await frames(3)
	check(speakers_listed == 4 and usual == "British 60 W" and chose == "british_25" and kept_settings.amp.get("speaker", "") == "british_25" and
		amp.amp_speaker == "bass_15" and panel._speaker_choice.item_count == 1,
		"the 4x12 comes with its usual speakers and offers the four 12s; another can be put in (and is kept with it); a 1x15 takes its 15",
		"%s, then %s" % [usual, amp.amp_speaker])
	panel._cabinet_choice.select(2)
	panel._cabinet_choice.item_selected.emit(2)
	await frames(2)
	panel._head_on.button_pressed = false
	panel._cabinet_on.button_pressed = false
	await frames(3)
	await hover(panel._head_on.get_global_rect().get_center())
	check(not amp.head_on and not amp.cabinet_on and panel._knobs.gain.modulate.a < 0.5 and panel._knobs.master.modulate.a == 1.0 and
		panel._hint.text.begins_with("Bypassed, the head passes"), "either can be bypassed: the head's knobs go dim, the master stays, and the line at the foot says what that means while the mouse is over its switch",
		panel._hint.text)
	await hover(panel._title.get_global_rect().get_center())
	check(panel._hint.text == "", "over the panel's name there is nothing to explain, and the line is empty", panel._hint.text)
	panel._head_on.button_pressed = true
	panel._cabinet_on.button_pressed = true
	panel._cabinet_choice.select(0)
	panel._cabinet_choice.item_selected.emit(0)
	panel._head_choice.select(1)
	panel._head_choice.item_selected.emit(1)
	await frames(2)
	await click(panel._footswitch.get_global_rect().get_center())
	for wait in 10:  # (the audio thread takes it up a block later)
		if amp.looper.get("state", "") == "playing":
			break
		await frames(3)
	check(amp.looper.get("state", "") == "playing", "the pedal's footswitch button plays it again", "%s, footswitch at %s, panel %s" % [amp.looper.get("state", ""), panel._footswitch.get_global_rect(), panel._panel.get_global_rect()])
	await tap(KEY_J)
	await tap(KEY_J)
	await frames(3)
	check(amp.looper.get("state", "") == "empty", "J twice clears the loop, from the panel too")
	await tap(KEY_P)
	check(not panel.is_open(), "P closes the panel")
	await tap(KEY_L)
	await frames(2)
	await tap(KEY_L)  # cancel the wait
	await frames(2)
	await tap(KEY_J)
	await frames(2)
	check(amp.looper.get("state", "") == "empty" and player.clear_pending == null, "a pedal waiting for the bar can be cancelled, and has nothing to clear")

	print("Effect pedals")
	var order: Array = load("res://scripts/catalog.gd").PEDAL_ORDER
	await tap(KEY_P)
	await frames(3)
	await click(panel._remove.get_global_rect().get_center())
	check(panel.is_open() and panel._tiles.is_empty() and panel._empty_page.visible and panel._add_button.visible and amp.looper.state == "none",
		"the loop pedal, empty, comes off the board at a press")
	await click(panel._add_button.get_global_rect().get_center())
	check(panel._add_menu.visible and panel._add_menu.item_count == order.size(), "+ Pedal offers every kind of pedal", "%d kinds" % panel._add_menu.item_count)
	panel._add_menu.id_pressed.emit(order.find("overdrive"))
	panel._add_menu.hide()
	await frames(3)
	check(amp.pedals.size() == 1 and amp.pedals[0].kind == "overdrive" and amp.pedals[0].on and panel.selected == 0 and panel._pedal_page.visible and
		not panel._loop_page.visible and panel._pedal_title.text == "Overdrive" and panel._controls.size() == 3,
		"choosing the overdrive puts one on the board, switched on, with its three knobs showing")
	check(panel._controls[1].node.readout == "2.2 kHz" and panel._controls[2].node.readout == "+0.0 dB",
		"its knobs read in real units: the tone in hertz, the level in decibels", "%s, %s" % [panel._controls[1].node.readout, panel._controls[2].node.readout])
	await turn(panel._controls[0].node, 45.0)
	check(absf(amp.pedals[0].controls[0] - 8.0) < 0.2, "turning Drive up turns it up in the audio core", "%.2f" % amp.pedals[0].controls[0])
	await tap(KEY_1)
	await frames(2)
	check(not amp.pedals[0].on and panel._pedal_switch.text.begins_with("Bypassed") and panel._tiles[0].led.color == panel.LED_OFF,
		"1 stamps on the first pedal: bypassed, its light off", panel._pedal_switch.text)
	await click(panel._pedal_switch.get_global_rect().get_center())
	check(amp.pedals[0].on, "and its footswitch switches it back on")
	await click(panel._add_button.get_global_rect().get_center())
	panel._add_menu.id_pressed.emit(order.find("tuner"))
	panel._add_menu.hide()
	await frames(3)
	check(panel._footer.get_children().all(func(b): return not (b is Button) or not (b.text.contains("Earlier") or b.text.contains("Later"))),
		"there are no buttons for moving pedals along the line")
	await mouse_drag(panel._tiles[1].panel.get_global_rect().get_center(), panel._tiles[0].panel.get_global_rect().position + Vector2(8, 40))
	check(amp.pedals.size() == 2 and amp.pedals[0].kind == "tuner" and amp.pedals[1].kind == "overdrive" and panel.selected == 0 and panel._tuner_box.visible and
		not panel._drop_mark.visible, "a tuner added at the end can be dragged with the mouse to the front of the line", "%s, %s" % [amp.pedals[0].kind, amp.pedals[1].kind])
	panel.drop_pedal({"pedal": true, "inst": amp, "index": 1}, 2, true)  # with Option held
	await frames(3)
	check(amp.pedals.size() == 3 and amp.pedals[2].kind == "overdrive" and absf(amp.pedals[2].controls[0] - amp.pedals[1].controls[0]) < 0.01 and
		amp.pedals[2].on == amp.pedals[1].on and panel.selected == 2, "dropped with Option held, a second overdrive goes in, its knobs set the same")
	# The amp's effects loop, after its PREAMP: a pedal dragged into it goes in it; one dragged back comes out in front.
	await mouse_drag(panel._tiles[2].panel.get_global_rect().get_center(), panel._loop_add.get_global_rect().get_center())
	await frames(3)
	var looped_in: bool = amp.pedals[2].get("in_loop", false) and audio.get_pedal_loop(amp.source_id) == 1 and panel.front_count() == 2 and \
		panel._loop_box.is_ancestor_of(panel._tiles[2].panel)
	panel.drop_pedal({"pedal": true, "inst": amp, "index": 2}, 0, false, false)
	await frames(3)
	var out_again: bool = amp.pedals[0].kind == "overdrive" and not amp.pedals[0].get("in_loop", false) and audio.get_pedal_loop(amp.source_id) == 0
	panel._on_add_pressed(true)
	panel._add_menu.id_pressed.emit(order.find("delay"))
	panel._add_menu.hide()
	await frames(3)
	check(looped_in and out_again and amp.pedals.size() == 4 and amp.pedals[3].kind == "delay" and amp.pedals[3].get("in_loop", false),
		"a pedal dragged past the PREAMP goes in the amp's effects loop, and dragged back comes out in front; the loop's + adds one in it")
	var mix_at_first: float = amp.loop_mix
	panel._loop_mix.value_changed.emit(8.0)
	await frames(2)
	check(is_equal_approx(mix_at_first, 0.5) and is_equal_approx(amp.loop_mix, 0.8) and panel._loop_box.is_ancestor_of(panel._loop_mix) and
		panel._loop_mix.readout == "80 %" and is_equal_approx(float(main.library.instrument_settings(amp).amp.loop_mix), 0.8),
		"the loop is a parallel one, its MIX knob in the loop: half and half to begin with, and kept with the amp's settings", panel._loop_mix.readout)
	main.set_amp_loop_mix(amp, 0.5)
	main.remove_pedal(amp, 3)
	panel.selected = 0
	await click(panel._remove.get_global_rect().get_center())
	panel.selected = 0
	await click(panel._board_toggle.get_global_rect().get_center())
	check(not main.settings.pedalboard_open and not panel._board_body.visible and panel._board_summary.text == "2 pedals, 2 on" and panel._knobs.gain.is_visible_in_tree(),
		"the pedalboard folds away under its heading, leaving the amp", panel._board_summary.text)
	await tap(KEY_2)
	check(not amp.pedals[1].on, "and 2 still stamps on the second pedal")
	await tap(KEY_2)
	await click(panel._board_toggle.get_global_rect().get_center())
	check(main.settings.pedalboard_open and panel._board_body.visible, "it unfolds again")
	check(amp.tuner.get("listening", false) and not amp.tuner.get("pitched", true) and panel._tuner_cents.text == "Play a string" and amp._loop_label.text.begins_with("TUNER"),
		"switched on, it listens for a note, on the panel and over the amp", amp._loop_label.text.replace("\n", " / "))
	await click(panel._add_button.get_global_rect().get_center())
	panel._add_menu.id_pressed.emit(order.find("plugin"))
	panel._add_menu.hide()
	await frames(3)
	var browser = main.plugin_browser
	var headings := []
	for heading in browser._tree.get_root().get_children():
		headings.append(heading.get_text(0).get_slice("   ", 0))
	check(amp.pedals.size() == 3 and panel._plugin_box.visible and browser.visible and browser.plugins.size() > 0 and headings.has("Delay") and
		headings.has("Reverb") and headings.find("Amps & cabinets") <= 0, "a Plug-in pedal opens the plug-in browser, grouped by kind of effect",
		"%d plug-ins: %s" % [browser.plugins.size(), ", ".join(headings)])
	browser._by_maker.button_pressed = true
	await frames(2)
	var makers := []
	for heading in browser._tree.get_root().get_children():
		makers.append(heading.get_text(0).get_slice("   ", 0))
	check(makers.has("Apple") and not makers.has("Delay"), "or by maker", ", ".join(makers))
	browser._search.text = "audelay"
	browser._search.text_changed.emit("audelay")
	await frames(2)
	var found: TreeItem = browser._tree.get_root().get_first_child()
	check(browser._tree.get_root().get_child_count() == 1 and found.get_child_count() == 1 and not found.collapsed and
		found.get_first_child().get_text(0) == "AUDelay", "searching narrows it to what matches")
	browser._search.text_submitted.emit("audelay")
	await frames(3)
	check(not browser.visible and amp.pedals[2].plugin_name == "AUDelay" and panel._plugin_status.text.begins_with("AUDelay") and
		panel._tiles[2].label.text == "AUDelay", "choosing it puts AUDelay on the board, before the amp", panel._plugin_status.text)
	browser._by_type.button_pressed = true
	await click(panel._remove.get_global_rect().get_center())
	check(amp.pedals.size() == 2 and panel.selected == 1, "a pedal can be taken off the board again")
	await tap(KEY_P)
	await frames(4)
	var with_pedals: Array = main.hud.hint_lines()
	check(not panel.is_open() and with_pedals.has("1-2 Stamp on the Pedals") and amp._pedal_row.get_child_count() == 2,
		"in the room the pedals stand in front of the amp, and the card offers 1 and 2 to stamp on them", " / ".join(with_pedals))
	await tap(KEY_2)
	await frames(2)
	check(not amp.pedals[1].on and amp._pedal_leds[1].emission_energy_multiplier == 0.0, "2 switches the overdrive off from the room, and its light goes out")
	main.set_insert(amp, 0, "AU:61756678:64656c79:6170706c")  # AUDelay
	main.set_amp_control(amp, "treble", 7.5)
	var amp_count: int = main.instruments.size()
	await tap(KEY_V)
	await frames(3)
	var amp_copy = player.carried
	check(amp_copy != null and amp_copy != amp and amp_copy.kind == amp.kind and main.instruments.size() == amp_count + 1 and
		main.instruments.find(amp_copy) == main.instruments.find(amp) + 1, "V duplicates the amp you face, into your hands", amp_copy.display_name if amp_copy else "nothing")
	var same_pedals: bool = amp_copy.pedals.size() == amp.pedals.size()
	for i in mini(amp_copy.pedals.size(), amp.pedals.size()):
		same_pedals = same_pedals and amp_copy.pedals[i].kind == amp.pedals[i].kind and amp_copy.pedals[i].on == amp.pedals[i].on and \
			amp_copy.pedals[i].controls == amp.pedals[i].controls
	check(same_pedals and amp_copy.amp_head == amp.amp_head and amp_copy.amp_cabinet == amp.amp_cabinet and amp_copy.amp_controls == amp.amp_controls and
		audio.get_inserts(amp_copy.source_id)[0].plugin_name == "AUDelay" and not amp_copy.input_on and amp_copy.input_channel == amp.input_channel,
		"the copy has the same head, cabinet, knobs and pedals, the same plug-in on its insert, and its input off")
	await tap(KEY_G)
	main.remove_instrument(amp_copy)
	main.set_input(amp, false)
	main.remove_instrument(amp)
	main.set_tempo(100.0)

	print("The Speaker and the menu")
	var from: Vector3 = speaker.position + Vector3(0.0, 0.0, 1.8)
	player.place(Vector3(from.x, 0.0, from.z), 0.0)
	await frames(5)
	var speaker_card: Array = main.hud.hint_lines()
	check(player.target == speaker and speaker_card == ["Speaker", "I Enable Input", "P Volume and Input", "M Mute", "G Carry",
		"⌘L Lock in Place", "V Duplicate", "Backspace Remove (press twice)"], "the Speaker's card offers input, its panel and mute, but not playing", " / ".join(speaker_card))
	await tap(KEY_M)
	check(speaker.room_muted and not speaker.muted, "M mutes it in the room (you're standing in it; its track plays on in the mix)")
	await tap(KEY_E)
	check(player.playing == null and not seq.is_open(), "E does nothing at the Speaker: it isn't played")
	await tap(KEY_M)
	await tap(KEY_P)
	await frames(3)
	var speaker_panel = main.speaker_panel
	check(speaker_panel.is_open() and speaker_panel.inst == speaker and speaker_panel._volume.readout == "+0.0 dB",
		"P opens the Speaker's panel, its volume at 0 dB", speaker_panel._volume.readout)
	await turn(speaker_panel._volume, 75.0)  # 5 knob steps: right to the top
	check(absf(speaker.volume_db - 24.0) < 0.6 and speaker_panel._volume.readout == "+24.0 dB",
		"its volume goes up to +24 dB, as a big PA speaker's would", speaker_panel._volume.readout)
	main.set_speaker_volume(speaker, 0.0)
	await tap(KEY_P)
	check(not speaker_panel.is_open(), "P closes it")
	await tap(KEY_ESCAPE)
	check(main.menu.is_open() and main.menu._tabs.get_tab_title(0) == "Metronome", "Esc opens the menu, Metronome page first", main.menu._tabs.get_tab_title(main.menu._tabs.current_tab))
	main.menu._tempo_slider.value = 100
	main.menu._swing_slider.value = 0
	main.menu._click_slider.value = -6
	await frames(2)
	check(is_equal_approx(audio.get_transport().bpm, 100.0) and is_equal_approx(audio.get_transport().swing, 0.0) and absf(audio.get_transport().click_volume - 0.501) < 0.01,
		"its sliders set tempo, swing and click volume", str(audio.get_transport()))

	print("The mix window")
	var menu = main.menu
	var pad = main.find_instrument("pad")
	await tap(KEY_ESCAPE)  # out of the menu, into the mix window
	await tap(KEY_TAB)
	await frames(4)
	var mix = main.mixer
	check(mix.is_open() and mix._strips.size() == main.instruments.size() and mix._strips[0].inst == drums and mix._strips[0].value.text == "+0.0",
		"Tab opens the mix window: a strip for each instrument, at 0 dB", "%d strips" % mix._strips.size())
	await seconds(0.5)
	check(mix._master.meter.held_db() > -40.0 and mix._master.peak.text.begins_with("-") and mix._status.text == "Limiter idle",
		"the master meter beside the master fader is reading the output, with its peak beneath", mix._master.peak.text)
	var drums_strip: Dictionary = mix._strips[0]
	check(drums.peak_hold > 0.01 and drums_strip.peak.text.begins_with("-") and drums_strip.peak.text != "-inf" and mix._strips[0].meter.held_db() > -40.0,
		"each strip has its own peak readout under the fader", drums_strip.peak.text)
	main.set_pre_fader_meters(false)  # muted, the meter after the fader stays down once its peak is cleared
	main.set_muted(drums, true)
	await seconds(0.3)
	await click(drums_strip.peak.get_global_rect().get_center())
	await frames(2)
	check(drums.peak_hold < 0.00001 and drums_strip.peak.text == "-inf", "clicking the peak readout clears it, as in Pro Tools", drums_strip.peak.text)
	main.set_muted(drums, false)
	main.set_pre_fader_meters(true)
	await hover(drums_strip.mute.get_global_rect().get_center())
	var over_mute: String = mix._hint.text
	await hover(drums_strip.inserts[0].button.get_global_rect().get_center())
	var over_insert: String = mix._hint.text
	await hover(mix._status.get_global_rect().end + Vector2(-4, 0))
	check(over_mute.begins_with("Mute") and over_insert.begins_with("Insert A: click to choose") and mix._hint.text == "",
		"the line at the foot of the window says what the mouse is over (M: Mute), and nothing otherwise", "%s / %s" % [over_mute, over_insert])
	check(drums_strip.inserts.size() == audio.get_max_inserts() and audio.get_max_inserts() == 5 and drums_strip.inserts[0].button.text == "" and
		mix._strips.back().inserts.size() == 5, "every strip has five inserts, empty to begin with")
	await click(drums_strip.inserts[0].button.get_global_rect().get_center())
	var picker = main.plugin_browser
	check(picker.visible and picker._title.text == "Insert A on the Drums", "clicking an empty insert opens the plug-in browser for it", picker._title.text)
	picker._search.text = "audelay"
	picker._search.text_changed.emit("audelay")
	picker._search.text_submitted.emit("audelay")
	await frames(3)
	check(not picker.visible and drums.inserts[0].plugin_name == "AUDelay" and drums_strip.inserts[0].button.text == "AUDelay" and
		audio.get_inserts(drums.source_id)[0].plugin_name == "AUDelay", "choosing a plug-in puts it on the drums' first insert")
	mix._on_insert_clicked(drums, 0, true)  # with Cmd held
	await frames(2)
	check(not drums.inserts[0].on and drums_strip.inserts[0].style.bg_color.b > 0.6, "Cmd-click bypasses it, and it turns blue")
	mix._on_insert_clicked(drums, 0, true)
	var held = mix._insert_drag(Vector2.ZERO, drums, 0)
	check(held != null and mix._insert_can_drop(Vector2.ZERO, held, drums, 2) and not mix._insert_can_drop(Vector2.ZERO, held, drums, 0) and
		mix._insert_drag(Vector2.ZERO, drums, 4) == null, "an insert can be picked up and dropped on another slot, but an empty one can't be picked up")
	await mouse_drag(drums_strip.inserts[0].button.get_global_rect().get_center(), drums_strip.inserts[2].button.get_global_rect().get_center())
	check(drums.inserts[0].plugin_name == "" and drums.inserts[2].plugin_name == "AUDelay" and not drums.inserts[2].editor_open and not picker.visible,
		"dragging it down the strip with the mouse moves it to that slot")
	mix.drop_insert(mix._insert_drag(Vector2.ZERO, drums, 2), bass, 0, false)
	await frames(2)
	check(drums.inserts[2].plugin_name == "" and bass.inserts[0].plugin_name == "AUDelay" and mix._strip_for(bass).inserts[0].button.text == "AUDelay",
		"dragging it to another strip moves it to that instrument")
	mix.drop_insert(mix._insert_drag(Vector2.ZERO, bass, 0), drums, 0, true)  # with Option held
	await frames(2)
	check(bass.inserts[0].plugin_name == "AUDelay" and drums.inserts[0].plugin_name == "AUDelay", "with Option held it is copied instead, as in Pro Tools")
	main.clear_insert(bass, 0)
	var right_click := InputEventMouseButton.new()
	right_click.button_index = MOUSE_BUTTON_RIGHT
	right_click.pressed = true
	mix._on_insert_input(right_click, drums, 0)
	await frames(2)
	check(drums.inserts[0].on and mix._insert_menu.visible and mix._insert_menu.get_item_text(mix._insert_menu.get_item_index(3)) == "Remove",
		"right-click offers its window, bypass, another plug-in, and taking it out")
	mix._insert_menu.id_pressed.emit(3)
	mix._insert_menu.hide()
	await frames(2)
	check(drums.inserts[0].plugin_name == "" and drums_strip.inserts[0].button.text == "", "and Remove takes it out")
	var test_gain: Dictionary = {}
	for p in main.available_plugins():
		if p.name == "SR Test Gain":
			test_gain = p
	var vst3_problem: String = main.set_insert(drums, 4, str(test_gain.get("id", "")))
	await frames(2)
	check(test_gain.get("format", "") == "VST3" and vst3_problem == "" and drums.inserts[4].plugin_name == "SR Test Gain" and
		main.automation.value_text(drums, "insert:4:0", 1.0) == "+6.0 dB",
		"a VST3 plug-in goes on an insert as well (the checks' own), its control's values as it writes them", vst3_problem)
	main.clear_insert(drums, 4)
	# Delay compensation: a plug-in that makes the drums 1000 samples late holds the others back as much.
	var lookahead_id := ""
	for p in main.available_plugins():
		if p.name == "SR Test Lookahead":
			lookahead_id = str(p.id)
	main.set_insert(drums, 4, lookahead_id)
	main.refresh_delays()
	await frames(2)
	var bass_strip: Dictionary = mix._strip_for(main.find_instrument("bass"))
	var held_cells := [drums_strip.delay.dly.text, drums_strip.delay.cmp.text, bass_strip.delay.dly.text, bass_strip.delay.cmp.text,
		mix._master.delay.cmp.text]
	main.set_delay_compensation(false)
	await frames(2)
	var off_cells := [bass_strip.delay.cmp.text, mix._master.delay.cmp.text]
	main.set_delay_compensation(true)
	check(held_cells == ["dly 1000", "cmp 0", "dly 0", "cmp 1000", "tot 1000"] and off_cells == ["cmp off", ""] and
		is_equal_approx(float(audio.get_stats().compensation_ms), 1000.0 / float(audio.get_stats().sample_rate) * 1000.0),
		"delay compensation, at the foot of each strip as Pro Tools shows it: the drums' plug-in delays them 1000 samples (dly), the bass is held back to meet them (cmp), the master says the total; off, nothing is held back",
		" / ".join(held_cells))
	main.clear_insert(drums, 4)
	main.refresh_delays()
	var pad_strip: Dictionary = mix._strips[main.instruments.find(pad)]
	pad.set_loop(false)
	await seconds(1.5)
	audio.note_on(pad.source_id, 57, 0.8)  # one held note to measure
	await seconds(1.5)
	var full: float = await average_level(pad.source_id, 1.5)
	# Drag the pad's fader cap down by as far as 12 dB is on its scale.
	var fader = pad_strip.fader
	var travel: float = fader._travel_pixels()
	var cap: Vector2 = fader.get_global_rect().position + Vector2(fader.SCALE_WIDTH + fader.CAP.x / 2 + 2, (1.0 - fader.position_of(0.0)) * travel + fader.CAP.y / 2)
	var drop: float = (fader.position_of(0.0) - fader.position_of(-12.0)) * travel
	var press := InputEventMouseButton.new()
	press.position = cap
	press.global_position = cap
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	view.push_input(press)
	await frames(1)
	for step in 4:
		var move := InputEventMouseMotion.new()
		move.position = cap + Vector2(0, drop * (step + 1) / 4.0)
		move.global_position = move.position
		move.relative = Vector2(0, drop / 4.0)
		move.button_mask = MOUSE_BUTTON_MASK_LEFT
		view.push_input(move)
		await frames(1)
	var lift := press.duplicate()
	lift.pressed = false
	view.push_input(lift)
	await seconds(0.4)
	var lowered: float = await average_level(pad.source_id, 1.5)
	check(absf(pad.level_db + 12.0) < 0.6 and absf(linear_to_db(lowered / full) + 12.0) < 1.0 and pad_strip.value.text.begins_with("-1"),
		"dragging the pad's fader down 12 dB makes it 12 dB quieter", "fader at %s, %.1f dB quieter" % [pad_strip.value.text, -linear_to_db(lowered / full)])
	var twice := press.duplicate()
	twice.double_click = true
	view.push_input(twice)
	await frames(2)
	view.push_input(lift)
	await seconds(0.4)
	var restored: float = await average_level(pad.source_id, 1.5)
	check(is_equal_approx(pad.level_db, 0.0) and absf(linear_to_db(restored / full)) < 1.0, "double-clicking the fader puts it back to 0 dB",
		"%+.1f dB" % linear_to_db(restored / full))
	await click(pad_strip.solo.get_global_rect().get_center())
	await seconds(0.5)
	var soloed_drums: float = await average_level(drums.source_id, 0.5)
	var soloed_pad: float = await average_level(pad.source_id, 0.5)
	check(pad.soloed and soloed_drums < 0.0005 and soloed_pad > 0.005, "soloing the pad silences everything else",
		"drums %.4f, pad %.4f" % [soloed_drums, soloed_pad])
	await click(pad_strip.solo.get_global_rect().get_center())
	await click(mix._strips[0].mute.get_global_rect().get_center())
	await seconds(0.5)
	check(not pad.soloed and drums.muted and not drums._label.text.contains("muted") and await average_level(drums.source_id, 0.5) < 0.0005,
		"M on the drums' strip mutes their track in the mix (in the room they play on: their label doesn't say muted)", drums._label.text)
	await click(mix._strips[0].mute.get_global_rect().get_center())
	audio.note_off(pad.source_id, 57)
	pad.set_loop(true)

	main.set_monitor("mix")  # (the main outputs play the mix, where the faders are)
	for inst in main.instruments:  # every instrument far too loud
		mix._on_fader_changed(12.0, inst)
	await seconds(1.5)
	check(main.meter_reduction_db > 1.0 and not main.meter_clipped and mix._status.text.begins_with("Limiting"),
		"turned up too far, the limiter holds the output and the window says by how much", mix._status.text)
	var limiting: float = main.meter_reduction_db
	mix._on_master_changed(-10.0)
	var still_limiting := 0.0
	for wait in 12:  # the most it holds back over a few bars, whatever the groove is doing just then
		await seconds(0.25)
		if wait >= 6:
			still_limiting = maxf(still_limiting, main.meter_reduction_db)
	check(limiting > 1.0 and still_limiting < limiting - 3.0,
		"the limiter comes after the master fader: bringing the master down 10 dB eases it", "%.1f dB, then %.1f dB" % [limiting, still_limiting])
	mix._on_master_changed(6.0)
	check(is_equal_approx(main.master_volume_db, 0.0) and mix._master.fader.top_db == 0.0, "the master fader goes no higher than 0 dB",
		"%.1f dB" % main.master_volume_db)
	mix._on_master_changed(0.0)
	await click(mix._master.limiter.get_global_rect().get_center())
	for wait in 16:  # however quiet the groove is just then, it clips within a bar or two
		await seconds(0.25)
		if main.meter_clipped and wait >= 5:
			break
	check(not main.settings.limiter and main.meter_clipped and mix._status.text.contains("Clipping"),
		"with the LIMIT button off, the same mix is reported as clipping", mix._status.text)
	for inst in main.instruments:
		mix._on_fader_changed(0.0, inst)
	await click(mix._master.limiter.get_global_rect().get_center())
	await seconds(2.5)
	check(main.settings.limiter and not main.meter_clipped and main.meter_reduction_db < 0.1 and mix._status.text.ends_with("Limiter idle"),
		"back at 0 dB with the limiter on, nothing is being held back", mix._status.text)
	var held_loud: float = main.master_peak_hold
	var press_alt := InputEventMouseButton.new()
	press_alt.button_index = MOUSE_BUTTON_LEFT
	press_alt.pressed = true
	press_alt.alt_pressed = true
	mix._on_peak_input(press_alt, pad)
	await frames(3)
	check(held_loud > 0.5 and main.master_peak_hold < 0.5 and drums.peak_hold < 0.5 and pad.peak_hold < held_loud,
		"Alt-clicking a peak readout clears them all, the master's too", "master held %.2f, now %.2f" % [held_loud, main.master_peak_hold])
	main.set_monitor("room")

	# The room and the mix apart: each instrument's level in the room at the foot of its strip, its pan in the mix,
	# and the two masters at the right, HEAR on the one the main outputs play.
	var foot: Dictionary = mix._strip_for(drums).room
	var room_before: Vector2 = await room_and_mix(drums.source_id, 0.8)  # (the room's level against the mix's, the groove's ups and downs alike in both)
	foot.level.value_changed.emit(-12.0)
	await seconds(0.3)
	var room_down: Vector2 = await room_and_mix(drums.source_id, 0.8)
	var room_change: float = linear_to_db((room_down.x / maxf(room_down.y, 1e-9)) / maxf(room_before.x / maxf(room_before.y, 1e-9), 1e-9))
	foot.level.value_changed.emit(0.0)
	await frames(2)
	check(foot.level.value == 0.0 and absf(room_change + 12.0) < 1.5 and room_down.y > 0.001 and is_equal_approx(drums.level_db, 0.0),
		"an instrument's level in the room, at the foot of its strip: 12 dB down there, its fader in the mix as it was", "%.1f dB in the room" % room_change)
	await click(foot.mute.get_global_rect().get_center())
	await seconds(0.4)
	var room_muted_level: float = await average_room_level(drums.source_id, 0.4)
	var mix_muted_level: float = await average_level(drums.source_id, 0.4)
	check(drums.room_muted and not drums.muted and room_muted_level < 0.0001 and mix_muted_level > 0.001 and drums._label.text.contains("muted"),
		"its M there mutes it in the room (its label says so), its direct output playing on in the mix", "%.5f, %.4f" % [room_muted_level, mix_muted_level])
	await click(foot.mute.get_global_rect().get_center())
	var drums_pan: Control = mix._strip_for(drums).pan
	drums_pan.value_changed.emit(-0.5)
	await frames(2)
	check(is_equal_approx(drums.pan, -0.5) and drums_pan.value == -0.5 and main.mixer.PanControl.readout(-0.5) == "<50" and
		main.automation.params_for(drums).has("pan"),
		"every instrument has a pan pot in the mix (as Pro Tools reads it, <50), and its pan can be automated", main.mixer.PanControl.readout(drums.pan))
	drums_pan.value_changed.emit(0.0)
	await click(mix._master.hear.get_global_rect().get_center())
	await frames(2)
	var heard_mix: bool = main.settings.monitor == "mix" and mix._master.hear.button_pressed and not mix._room.hear.button_pressed
	mix.close()  # (the screen's own label is under the window while it's open)
	await frames(2)
	var mix_chip: String = main.hud._monitor_chip.text
	mix.open()
	await tap(KEY_H)
	mix.close()
	await frames(2)
	var room_chip: String = main.hud._monitor_chip.text
	mix.open()
	await frames(2)
	check(heard_mix and main.settings.monitor == "room" and mix._room.hear.button_pressed and mix_chip == "HEADPHONE MIX" and room_chip == "ROOM",
		"HEAR on the mix's master has the main outputs play the mix (the screen says HEADPHONE MIX), and H goes back to the room (ROOM)",
		"%s, %s" % [mix_chip, room_chip])
	await click(mix._master.inserts[0].button.get_global_rect().get_center())
	check(picker.visible and picker._title.text == "Insert A on the Mix Master", "the mix's master has inserts too", picker._title.text)
	picker._search.text = "audelay"
	picker._search.text_changed.emit("audelay")
	picker._search.text_submitted.emit("audelay")
	await frames(3)
	check(main.master_track.inserts[0].plugin_name == "AUDelay" and mix._master.inserts[0].button.text == "AUDelay" and
		main.automation.plugin_params(main.master_track).size() == 1, "a plug-in on it plays on the whole mix, its controls automatable", mix._master.inserts[0].button.text)
	main.clear_insert(main.master_track, 0)
	# The room's master is a master as the mix's is: inserts, its own outputs, its own limiter; both crimson to begin with,
	# and renamed and coloured as a track is.
	await click(mix._room.inserts[0].button.get_global_rect().get_center())
	var room_insert_title: String = picker._title.text
	picker._search.text = "audelay"
	picker._search.text_changed.emit("audelay")
	picker._search.text_submitted.emit("audelay")
	await frames(3)
	var room_insert: String = main.room_master_track.inserts[0].plugin_name
	main.clear_insert(main.room_master_track, 0)
	main.set_master_output("room", 2)
	var room_out: int = main.master_output("room")
	main.set_master_output("room", -1)
	await click(mix._room.limiter.get_global_rect().get_center())
	var room_limit_off: bool = not main.settings.room_limiter and main.settings.limiter
	await click(mix._room.limiter.get_global_rect().get_center())
	check(room_insert_title == "Insert A on the Room Master" and room_insert == "AUDelay" and room_out == 2 and room_limit_off and main.settings.room_limiter,
		"the room's master has inserts, outputs of its own and a limiter of its own, as the mix's has", room_insert_title)
	var crimson: Color = main.master_track.CRIMSON
	var both_crimson: bool = main.master_track.color == crimson and main.room_master_track.color == crimson and mix._room.plate.get_meta("color") == crimson
	main.set_track_color(main.room_master_track, main.TRACK_COLORS[8][1])
	main.rename_track(main.room_master_track, "Live Room")
	await frames(2)
	check(both_crimson and mix._room.plate.text == "Live Room" and mix._room.plate.get_meta("color") == main.TRACK_COLORS[8][1] and
		main.edit_window.view.tracks().has(main.room_master_track) and main.edit_window.view.tracks().back() == main.master_track,
		"both masters are crimson to begin with, and can be renamed and coloured; both have rows at the foot of the edit window", mix._room.plate.text)
	main.set_track_color(main.room_master_track, crimson)
	main.rename_track(main.room_master_track, "Room Master")
	# The meters read before the fader unless a fader's right-click menu says after: the pad turned down 20 dB still reads
	# as loud before its fader.
	mix._on_fader_changed(-20.0, pad)
	await seconds(0.3)
	main.clear_peak(pad)
	await seconds(1.0)
	var before_fader: float = pad.peak_hold
	await click(mix._strip_for(pad).fader.get_global_rect().get_center(), MOUSE_BUTTON_RIGHT)
	check(mix._meter_menu.visible and mix._meter_menu.is_item_checked(0) and not mix._meter_menu.is_item_checked(1) and absf(pad.level_db + 20.0) < 0.01,
		"right-clicking a fader offers pre- or post-fader metering, pre-fader ticked, and leaves the fader where it is")
	mix._meter_menu.id_pressed.emit(1)
	mix._meter_menu.hide()
	await seconds(1.0)
	var after_fader: float = pad.peak_hold
	check(main.settings.pre_fader_meters == false and before_fader > after_fader * 5.0, "the meters read before the fader to begin with, and after it once that is chosen",
		"%.1f dB before the fader, %.1f dB after" % [linear_to_db(before_fader), linear_to_db(after_fader)])
	await click(mix._master.meter.get_global_rect().get_center(), MOUSE_BUTTON_RIGHT)
	check(mix._meter_menu.visible and mix._meter_menu.is_item_checked(1), "a meter's right-click offers the same, post-fader now ticked")
	mix._meter_menu.id_pressed.emit(0)
	mix._meter_menu.hide()
	check(main.settings.pre_fader_meters, "and pre-fader can be chosen again there")
	mix._on_fader_changed(0.0, pad)
	# Walking about with the mix window open.
	var standing: Vector3 = player.global_position
	var w := InputEventKey.new()  # movement reads the keyboard's state, so tell Input itself
	w.physical_keycode = KEY_W
	w.pressed = true
	Input.parse_input_event(w)
	await seconds(0.4)
	w = w.duplicate()
	w.pressed = false
	Input.parse_input_event(w)
	await frames(2)
	check(mix.is_open() and player.global_position.distance_to(standing) > 0.3, "you can walk about with the mix window open",
		"%.2f m" % player.global_position.distance_to(standing))
	player.place(standing, player.yaw)
	# A strip's name opens the instrument's own window, and the mix window comes back when it closes.
	await click(mix._strip_for(drums).plate.get_global_rect().get_center())
	check(seq.is_open() and seq.inst == drums and not mix.is_open(), "clicking a strip's name opens the instrument's window: the drums' pattern")
	await tap(KEY_ESCAPE)
	await frames(3)
	check(not seq.is_open() and mix.is_open(), "and closing it comes back to the mix window")
	await click(mix._strip_for(drums).plate.get_global_rect().get_center(), MOUSE_BUTTON_RIGHT)
	check(mix._name_menu.visible and mix._name_menu.get_item_index(2) >= 0, "a strip's name offers to duplicate the instrument")
	mix._name_menu.id_pressed.emit(2)
	mix._name_menu.hide()
	await frames(3)
	var drums_copy = main.instruments[main.instruments.find(drums) + 1]
	var plugin_names := func(of) -> Array: return audio.get_inserts(of.source_id).map(func(insert): return insert.plugin_name)
	check(drums_copy.kind == "drums" and drums_copy.display_name == "Drums 2" and mix._strips[main.instruments.find(drums) + 1].inst == drums_copy and
		audio.get_pattern(drums_copy.source_id) == audio.get_pattern(drums.source_id) and plugin_names.call(drums_copy) == plugin_names.call(drums) and
		drums_copy.global_position.distance_to(drums.global_position) > 0.9, "Duplicate puts a second drum kit beside the first, its strip next to theirs, with the same pattern and inserts",
		drums_copy.display_name)
	main.remove_instrument(drums_copy)
	var spare = main.add_instrument("bells", Vector3(2.0, 0.0, 2.0))
	await frames(3)
	await click(mix._strip_for(spare).plate.get_global_rect().get_center(), MOUSE_BUTTON_RIGHT)
	check(mix._name_menu.visible and mix._name_menu.get_item_text(mix._name_menu.get_item_index(1)).begins_with("Remove the Bells 2"),
		"right-clicking a strip's name offers to remove the instrument", mix._name_menu.get_item_text(mix._name_menu.get_item_index(1)))
	mix._name_menu.id_pressed.emit(1)
	mix._name_menu.hide()
	await frames(2)
	check(mix._confirm.visible and main.instruments.has(spare), "which asks first")
	mix._confirm.get_ok_button().pressed.emit()
	await frames(3)
	check(not main.instruments.has(spare) and mix._strip_for(spare).is_empty(), "and then takes it out of the room and the mix window")
	await tap(KEY_TAB)
	check(not mix.is_open(), "Tab closes the mix window")

	print("The keyboard, and changing keys")
	var bass_synth = main.find_instrument("bass")
	player.stop_playing()
	player.place(Vector3(0.0, 0.0, 3.6), PI)  # facing away from everything
	await frames(3)
	await tap(KEY_K)
	await frames(2)
	check(player.typing and main.hud._piano.visible and main.hud._piano_title.text.begins_with("Keyboard: no instrument's input is on"),
		"K opens the keyboard, which says when no instrument's input is on", main.hud._piano_title.text)
	main.set_input(bass_synth, true)
	await frames(2)
	key(KEY_A)
	await frames(2)
	check(main.hud._piano_title.text == "Keyboard  →  Bass" and player.held.has(KEY_A) and player.held[KEY_A][1] == [bass_synth.source_id],
		"with the bass's input on, the keyboard plays it from across the room", main.hud._piano_title.text)
	key(KEY_A, false)
	var here: Vector3 = player.global_position
	for keycode in [KEY_W, KEY_UP]:
		var walk_key := InputEventKey.new()
		walk_key.physical_keycode = keycode
		walk_key.pressed = true
		Input.parse_input_event(walk_key)
		await seconds(0.3)
		var walk_up := walk_key.duplicate()
		walk_up.pressed = false
		Input.parse_input_event(walk_up)
		await frames(2)
		if keycode == KEY_W:
			check(player.global_position.distance_to(here) < 0.05, "W is a note while the keyboard is open, so it doesn't walk")
	check(player.global_position.distance_to(here) > 0.3, "but the arrow keys still walk", "%.2f m" % player.global_position.distance_to(here))
	await tap(KEY_Q)
	check(not player.typing and not main.hud._piano.visible, "Q closes the keyboard")
	main.set_input(bass_synth, false)
	main.menu.open(main.menu.CONTROLS_TAB)
	await frames(3)
	main.menu._tabs.get_child(main.menu.CONTROLS_TAB).ensure_control_visible(main.menu._key_buttons.mixer)  # scrolled to it
	await frames(3)
	await click(main.menu._key_buttons.mixer.get_global_rect().get_center())
	check(main.menu._key_buttons.mixer.text == "press a key…", "on the Controls page, clicking a key waits for a new one")
	await tap(KEY_C)
	check(main.bindings.key("mixer") == KEY_C and main.bindings.key("click") == KEY_TAB and main.menu._key_buttons.mixer.text == "C" and
		main.menu._keys_note.text.contains("Metronome click"), "pressing C gives it to the mix window, and the click takes Tab", main.menu._keys_note.text)
	await tap(KEY_ESCAPE)
	await frames(2)
	await tap(KEY_C)
	await frames(2)
	check(mix.is_open() and main.bindings.label("mixer") == "C", "C now opens the mix window")
	await tap(KEY_C)
	main.reset_bindings()
	check(main.bindings.key("mixer") == KEY_TAB and main.bindings.key("click") == KEY_C, "and the keys can all be put back")
	main.menu.open(main.menu.CONTROLS_TAB)
	await frames(2)
	main.menu._tabs.get_child(main.menu.CONTROLS_TAB).ensure_control_visible(main.menu._key_buttons.redo)
	await frames(3)
	check(main.menu._key_buttons.redo.text == "⌘X" and main.menu._key_buttons.undo.text == "⌘Z", "the Controls page lists the Cmd shortcuts too: redo is Cmd-X",
		main.menu._key_buttons.redo.text)
	await click(main.menu._key_buttons.redo.get_global_rect().get_center())
	key(KEY_META)  # Cmd on its way to the key is passed over
	await frames(2)
	await tap(KEY_Y)
	key(KEY_META, false)
	check(main.bindings.command_for(KEY_Y) == "redo" and main.bindings.label("redo") == "⌘Y" and main.bindings.command_for(KEY_X) == "" and
		main.bindings.key("redo") == KEY_Y, "and a shortcut takes its new key there (Cmd held or not)", main.menu._keys_note.text)
	main.set_binding("undo", KEY_Y)
	check(main.bindings.label("undo") == "⌘Y" and main.bindings.label("redo") == "⌘Z" and main.bindings.action_for(KEY_Y) != "undo",
		"two shortcuts swap keys as the plain keys do, apart from them")
	main.reset_bindings()
	check(main.bindings.label("redo") == "⌘X" and main.bindings.label("undo") == "⌘Z", "and they are put back with the rest")
	await tap(KEY_ESCAPE)
	await frames(2)

	menu.open(menu.SETTINGS_TAB)
	await frames(3)
	check(is_equal_approx(main.settings.distance_falloff_db, 6.0) and menu._falloff_value.text == "6.0 dB per doubling",
		"sound falls 6 dB per doubling of distance: the inverse square law, set in Settings", menu._falloff_value.text)
	menu._falloff_slider.value = 3.0
	await frames(3)
	check(is_equal_approx(main.settings.distance_falloff_db, 3.0), "and it can be made gentler there", menu._falloff_value.text)
	menu._falloff_slider.value = 6.0
	menu._fullscreen_toggle.button_pressed = true
	await frames(2)
	check(main.settings.fullscreen and menu._fullscreen_toggle.text.begins_with("On"), "Settings has a full-screen switch that is remembered for next time")
	menu._fullscreen_toggle.button_pressed = false
	menu._tabs.current_tab = menu.SETTINGS_TAB
	await frames(3)
	menu._light_slider.value = 200.0
	menu._meter_toggle.button_pressed = false
	await frames(3)
	check(is_equal_approx(main.room.brightness, 2.0) and is_equal_approx(main._environment.ambient_light_energy, 0.7) and not main.settings.show_meter,
		"Settings has the room lighting and the on-screen meter switch")
	menu._light_slider.value = 100.0
	menu._meter_toggle.button_pressed = true

	print("The room")
	var room = main.room
	player.place(Vector3(0.5, 0.0, -2.0), 0.0)  # the bass is on the other side of the wall from here
	await frames(4)
	check(audio.is_source_blocked(bass.source_id) and not audio.is_source_blocked(drums.source_id), "from behind the wall, the bass is hidden and the drums are not")
	menu._tabs.current_tab = menu.ROOM_TAB
	await frames(4)
	var plan = menu._plan
	check(menu._tabs.get_tab_title(menu.ROOM_TAB) == "Room" and plan.is_visible_in_tree() and plan.size.x > 250 and plan.size.y > 200,
		"the Room page shows the floor plan", "%d x %d pixels" % [plan.size.x, plan.size.y])
	var rang: float = audio.get_room_decay()
	menu._size_sliders.x.value = 24.0
	menu._size_sliders.z.value = 16.0
	menu._size_sliders.y.value = 6.0
	await frames(3)
	check(room.size.is_equal_approx(Vector3(24, 6, 16)) and audio.get_room_decay() > rang + 0.4 and menu._decay_label.text.contains("%.1f" % audio.get_room_decay()),
		"the sliders resize the room, and a bigger room rings longer", "%.2f s, then %.2f s" % [rang, audio.get_room_decay()])
	await seconds(1.2)
	check(audio.is_room_settled(), "the reverb has changed over within about a second")
	menu._floor_choice.select(2)
	menu._floor_choice.item_selected.emit(2)
	await frames(2)
	check(room.floor_kind == "carpet" and menu._floor_note.text.begins_with("Thick carpet") and main.library.room_data().room.get("floor", "") == "carpet",
		"the floor can be carpeted (the mics hear hardly any bounce off it), and is kept with the room", menu._floor_note.text)
	room.set_floor("hard")

	var had: int = room.walls.size()
	await drag(plan, Vector2(2.1, 3.05), Vector2(6.05, 2.9))
	var drawn: Dictionary = room.walls[-1]
	check(room.walls.size() == had + 1 and drawn.a.is_equal_approx(Vector2(2, 3)) and drawn.b.is_equal_approx(Vector2(6, 3)) and plan.selected == had,
		"dragging on the floor draws a wall, snapped to the grid", "%s to %s" % [drawn.a, drawn.b])
	check(menu._wall_title.text == "Wall %d  ·  4.30 m long" % (had + 1), "the page says which wall is selected and how long it is", menu._wall_title.text)
	await drag(plan, Vector2(4, 3), Vector2(4, 5))
	check(room.walls[had].a.is_equal_approx(Vector2(2, 5)) and room.walls[had].b.is_equal_approx(Vector2(6, 5)), "dragging a wall moves it",
		"%s to %s" % [room.walls[had].a, room.walls[had].b])
	await drag(plan, Vector2(6, 5), Vector2(6, 1))
	check(room.walls[had].a.is_equal_approx(Vector2(2, 5)) and room.walls[had].b.is_equal_approx(Vector2(6, 1)), "dragging its end turns and stretches it",
		"%s to %s" % [room.walls[had].a, room.walls[had].b])
	await drag(plan, Vector2(2, 5), Vector2(5.9, 1.1))
	check(room.walls[had].a.distance_to(room.walls[had].b) >= 0.5, "an end can't be dragged onto the other", "%s to %s" % [room.walls[had].a, room.walls[had].b])
	await click(plan.get_global_rect().position + plan.to_screen(Vector2(-2.5, -1.9)))
	check(plan.selected == 0 and menu._wall_note.text.contains("over the top"), "clicking another wall selects it", menu._wall_note.text)
	menu._wall_height.value = 6.0
	await frames(2)
	check(is_equal_approx(room.walls[0].height, 6.0) and menu._wall_note.text.contains("reaches the ceiling"), "its height slider raises it to the ceiling", menu._wall_note.text)
	menu._wall_remove.pressed.emit()
	await frames(2)
	check(room.walls.size() == had and plan.selected == -1 and menu._wall_remove.disabled, "Remove takes the selected wall away")
	check(not audio.is_source_blocked(bass.source_id), "and the bass is no longer hidden")
	menu._wall_add.pressed.emit()
	await frames(2)
	check(room.walls.size() == had + 1 and plan.selected == had, "Add a wall puts one in the middle, selected")
	var inside: Vector3 = room.push_out_of_walls(Vector3(0.2, 1.0, 0.05), 0.5, Vector3(0.0, 0.0, 3.0))
	check(is_equal_approx(inside.z, 0.65) and is_equal_approx(inside.x, 0.2), "something carried into a wall stays on the carrier's side of it", str(inside))

	for axis in ["x", "z", "y"]:
		menu._size_sliders[axis].value = 0.0  # as small as it goes
	await frames(4)
	var outside := []
	if absf(player.global_position.x) > 1.8 or absf(player.global_position.z) > 1.8:  # jostled by six instruments, but in the room
		outside.append("you at %s" % player.global_position)
	for inst in main.instruments:
		if absf(inst.global_position.x) > 1.41 or absf(inst.global_position.z) > 1.41 or inst.top > 2.4:
			outside.append("%s at %s" % [inst.display_name, inst.global_position])
	for wall in room.walls:
		if absf(wall.a.x) > 2.0 or absf(wall.b.x) > 2.0 or absf(wall.a.y) > 2.0 or absf(wall.b.y) > 2.0:
			outside.append("a wall from %s to %s" % [wall.a, wall.b])
	check(room.size.is_equal_approx(Vector3(4.0, 2.4, 4.0)) and outside.is_empty(), "shrinking the room brings the instruments, the walls and you inside it",
		"%s, reverb %.2f s; left outside: %s" % [room.size, audio.get_room_decay(), ", ".join(outside) if not outside.is_empty() else "nothing"])
	menu._on_room_reset_pressed()
	await frames(3)
	check(room.size.is_equal_approx(Vector3(14, 4, 10)) and room.walls.size() == 1 and is_equal_approx(audio.get_room_decay(), 1.1),
		"Back to the default room restores its size and its one wall")

	print("Back to the title screen")
	await tap(KEY_ESCAPE)  # close the menu left open above
	main._sit_at("bass")
	await frames(5)
	await tap(KEY_E)
	var notes_before: int = audio.get_pattern(drums.source_id).size()
	await tap(KEY_Q)
	await tap(KEY_G)
	check(player.carried == bass, "carrying the bass")
	await tap(KEY_ESCAPE)
	check(main.menu.is_open() and main.menu._to_title.visible and main.menu._resume.text.begins_with("Resume"), "in the room the menu offers the title screen")
	await click(main.menu._to_title.get_global_rect().get_center())
	await frames(3)
	check(title.is_open() and not main.menu.is_open() and title.camera.current and player.carried == null and not bass.carried,
		"it goes back to the title, putting down what you were carrying")
	check(title.buttons.back.visible and title.buttons.back.text == "Back to Test room" and title.buttons.back.has_focus(),
		"the title screen offers to go back to the room that is open", title.buttons.back.text)
	await click(title.buttons.back.get_global_rect().get_center())
	await seconds(1.0)
	check(not title.is_open() and player.camera.current and audio.get_pattern(drums.source_id).size() == notes_before
		and is_equal_approx(audio.get_transport().bpm, 100.0), "and the room is as you left it when you come back in")

	print("Presets, copy and paste")
	var library = main.library
	var prompt = main.name_prompt
	var reverb_id := "AU:61756678:72766232:6170706c"  # Apple's AUReverb2
	var delay_id := "AU:61756678:64656c79:6170706c"  # and AUDelay
	var bells = main.find_instrument("bells")
	check(library.root.ends_with("automated-run-library") and not library.plugin_root.begins_with(OS.get_environment("HOME").path_join("Library/Audio")),
		"automated runs keep templates and presets in a folder of their own", library.root)
	main.set_insert(pad, 0, reverb_id)
	await tap(KEY_TAB)
	await frames(3)
	await click(mix._strip_for(pad).inserts[0].button.get_global_rect().get_center(), MOUSE_BUTTON_RIGHT)
	var presets = mix._insert_presets
	check(mix._insert_menu.visible and mix._insert_menu.get_item_index(4) >= 0 and presets.get_item_index(presets.FACTORY + 12) >= 0 and
		presets.is_item_disabled(presets.get_item_index(presets.PASTE)), "an insert's right-click menu has Presets: AUReverb2's own, and nothing to paste yet",
		"%d items" % presets.item_count)
	mix._insert_menu.hide()
	var as_loaded: PackedByteArray = audio.get_plugin_state(pad.source_id, "insert", 0)
	presets.id_pressed.emit(presets.FACTORY + 12)
	await frames(2)
	var hall: PackedByteArray = audio.get_plugin_state(pad.source_id, "insert", 0)
	check(hall != as_loaded and mix._status.text == "Large Hall 2 loaded", "choosing one of its own presets loads it", mix._status.text)
	presets.id_pressed.emit(presets.SAVE)
	await frames(2)
	check(prompt.is_open() and prompt._name.text == "AUReverb2", "Save preset asks for a name", prompt._title.text)
	await tap(KEY_TAB)
	check(mix.is_open() and prompt.is_open(), "while it asks, the keys are for typing: Tab doesn't close the mix window")
	prompt._name.text = "Big hall"
	prompt.confirm()
	await frames(2)
	var saved: Array = library.plugin_presets(pad, "insert", 0)
	check(not prompt.is_open() and saved.size() == 1 and saved[0].name == "Big hall" and saved[0].path == library.plugin_root.path_join("Apple/AUReverb2/Big hall.aupreset"),
		"it is saved as an .aupreset in the plug-in's folder, where Audio Unit hosts keep them", saved[0].path if not saved.is_empty() else "nothing")
	presets.for_plugin(pad, "insert", 0)
	presets.id_pressed.emit(presets.FACTORY)
	await frames(2)
	var small: PackedByteArray = audio.get_plugin_state(pad.source_id, "insert", 0)
	presets.for_plugin(pad, "insert", 0)
	check(presets.get_item_text(presets.get_item_index(presets.SAVED)) == "Big hall", "and listed under Saved")
	presets.id_pressed.emit(presets.SAVED)
	await frames(2)
	check(small != hall and audio.get_plugin_state(pad.source_id, "insert", 0) != small and mix._status.text == "Big hall loaded",
		"from where it loads again", mix._status.text)
	presets.id_pressed.emit(presets.COPY)
	main.set_insert(bells, 1, reverb_id)
	main.set_insert(drums, 1, delay_id)
	presets.for_plugin(drums, "insert", 1)
	var not_onto_delay: bool = presets.is_item_disabled(presets.get_item_index(presets.PASTE))
	presets.for_plugin(bells, "insert", 1)
	check(not_onto_delay and not presets.is_item_disabled(presets.get_item_index(presets.PASTE)),
		"a plug-in's copied settings can be pasted onto the same plug-in elsewhere, and not onto another")
	presets.id_pressed.emit(presets.PASTE)
	await frames(2)
	check(audio.get_plugin_state(bells.source_id, "insert", 1) == audio.get_plugin_state(pad.source_id, "insert", 0),
		"pasting them gives the bells' AUReverb2 the pad's settings")

	var lead = main.add_instrument("guitar_combo", Vector3(-1.0, 0.0, 0.5))
	main.set_amp_voice(lead, "high_gain", true, "4x12", true)
	main.set_amp_control(lead, "gain", 8.5)
	main.add_pedal(lead, "overdrive")
	main.add_pedal(lead, "delay")
	main.set_pedal_control(lead, 1, 0, 3.0)
	main.set_pedal_on(lead, 0, false)
	main.add_pedal(lead, "plugin")
	main.load_pedal_plugin(lead, 2, reverb_id)
	main.set_insert(lead, 2, delay_id)
	var names = mix._name_presets
	names.for_instrument(lead)
	names.id_pressed.emit(names.SAVE)
	await frames(2)
	prompt._name.text = "Lead rig"
	prompt.confirm()
	var amp_presets: Array = library.instrument_presets("amp")
	check(amp_presets.size() == 1 and amp_presets[0].name == "Lead rig" and amp_presets[0].path == library.presets_dir("amp").path_join("Lead rig.srpreset"),
		"an amp's settings are saved as an instrument preset", amp_presets[0].path if not amp_presets.is_empty() else "none")
	var stack = main.add_instrument("bass_stack", Vector3(1.0, 0.0, 0.5))
	names.for_instrument(stack)
	check(names.get_item_text(names.get_item_index(names.SAVED)) == "Lead rig", "it is offered to another amp, a bass stack even")
	names.id_pressed.emit(names.SAVED)
	await frames(3)
	var kinds_on_board: Array = stack.pedals.map(func(p): return p.kind)
	check(stack.amp_head == "high_gain" and stack.amp_cabinet == "4x12" and absf(stack.amp_controls.gain - 8.5) < 0.01 and
		kinds_on_board == ["overdrive", "delay", "plugin"] and not stack.pedals[0].on and absf(stack.pedals[1].controls[0] - 3.0) < 0.01 and
		stack.pedals[2].plugin_name == "AUReverb2" and audio.get_inserts(stack.source_id)[2].plugin_name == "AUDelay",
		"loading it gives the stack the same head, cabinet, knobs, pedals and plug-ins", str(kinds_on_board))
	names.for_instrument(speaker)
	check(names.get_item_index(names.SAVED) < 0, "a Speaker isn't offered an amp's presets")
	main.set_speaker_volume(speaker, 6.0)
	main.set_insert(speaker, 0, delay_id)
	names.id_pressed.emit(names.COPY)
	var speaker3 = main.add_instrument("live", Vector3(0.0, 0.0, -1.0))
	names.for_instrument(lead)
	var not_onto_amp: bool = names.is_item_disabled(names.get_item_index(names.PASTE))
	names.for_instrument(speaker3)
	names.id_pressed.emit(names.PASTE)
	await frames(2)
	check(not_onto_amp and absf(speaker3.volume_db - 6.0) < 0.01 and audio.get_inserts(speaker3.source_id)[0].plugin_name == "AUDelay",
		"a Speaker's copied settings paste onto another Speaker (volume and plug-ins), not onto an amp")
	main.set_speaker_volume(speaker, 0.0)
	await tap(KEY_TAB)
	await tap(KEY_T)
	check(im.is_open() and im._preset_box.visible and im._preset_buttons.size() == 1 and im._preset_buttons[0].text.begins_with("Lead rig"),
		"the instrument menu offers the presets saved")
	(im._preset_box.get_parent().get_parent() as ScrollContainer).ensure_control_visible(im._preset_buttons[0])
	await frames(3)
	await click(im._preset_buttons[0].get_global_rect().get_center())
	var from_preset = player.carried
	check(not im.is_open() and from_preset != null and from_preset.kind == "guitar_combo" and from_preset.amp_head == "high_gain" and
		from_preset.pedals.size() == 3, "picking one brings a new amp in, set up as the preset says", from_preset.display_name if from_preset else "nothing")
	await tap(KEY_G)

	print("More instruments")
	player.place(Vector3(0.0, 0.0, 3.6), 0.0)
	await frames(3)
	await tap(KEY_T)
	await click(im._card_for.garage_drums.get_global_rect().get_center())
	var garage = player.carried
	check(im._card_for.has("studio_drums") and main.Catalog.KINDS.studio_drums.drum_kit and
		main.Catalog.KINDS.studio_drums.color.b > main.Catalog.KINDS.studio_drums.color.g, "the instrument menu also has a studio kit, in purple")
	check(garage != null and garage.display_name == "Garage Kit" and garage.drum_kit and garage.playable and audio.get_pattern(garage.source_id).is_empty(),
		"the instrument menu has a garage kit", garage.display_name if garage else "nothing")
	await tap(KEY_G)
	await frames(3)
	seq.open(garage)
	await frames(3)
	var lanes: Array = seq._rows().map(func(row): return row.label)
	check(lanes == ["Crash", "Open hat", "Closed hat", "Ride", "High tom", "Low tom", "Snare", "Kick"],
		"its pattern has a row for each of its pieces, a ride where the drum machine has its clap", str(lanes))
	seq.close()
	await frames(2)
	audio.note_on(garage.source_id, 38, 0.9)
	var garage_level: float = await average_level(garage.source_id, 0.2)
	check(garage_level > 0.001, "and it plays", "%.4f" % garage_level)

	player.place(Vector3(3.0, 0.0, 3.6), 0.0)  # somewhere else to set the next one down
	await frames(3)
	await tap(KEY_T)
	await click(im._card_for.plugin_synth.get_global_rect().get_center())
	check(picker.visible and picker._title.text == "A plug-in instrument" and picker.plugins.any(func(p): return p.name == "DLSMusicDevice") and
		not picker.plugins.any(func(p): return p.name == "AUDelay"), "Plug-in Instrument offers the instrument plug-ins, not the effects",
		"%d of them" % picker.plugins.size())
	picker._search.text = "dlsmusic"
	picker._search.text_changed.emit("dlsmusic")
	picker._search.text_submitted.emit("dlsmusic")
	await frames(3)
	var synth = player.carried
	check(not im.is_open() and synth != null and synth.plays_plugin and synth.display_name == "DLSMusicDevice" and
		synth.instrument_plugin.get("plugin_name", "") == "DLSMusicDevice", "choosing one brings a plug-in instrument into your hands, named after it",
		synth.display_name if synth else "nothing")
	await tap(KEY_G)
	await frames(3)
	main._sit_at("plugin_synth")
	await frames(5)
	check(main.hud.hint_lines().has("' Plug-in Window"), "its card offers its plug-in's window", " / ".join(main.hud.hint_lines()))
	await tap(KEY_APOSTROPHE)
	check(player.plugin_open == synth and main.hud._piano.visible and main.hud._piano_title.text.begins_with("Playing the DLSMusicDevice") and
		main.hud.piano_top_fraction() > 0.1, "' opens its plug-in's window over the on-screen keyboard", main.hud._piano_title.text)
	key(KEY_D)
	var window_level: float = await average_level(synth.source_id, 0.3)
	key(KEY_D, false)
	await click(Vector2(640, 300))
	check(window_level > 0.0005 and player.plugin_open == null and not main.hud._piano.visible,
		"with it open the letter keys play it, and a click in the room puts it away", "%.4f" % window_level)
	await tap(KEY_APOSTROPHE)
	var piano_key: Control = main.hud._piano_keys[KEY_F].rect
	var at_key: Vector2 = piano_key.get_global_rect().get_center()
	var key_press := InputEventMouseButton.new()
	key_press.position = at_key
	key_press.global_position = at_key
	key_press.button_index = MOUSE_BUTTON_LEFT
	key_press.pressed = true
	view.push_input(key_press)
	var clicked_level: float = await average_level(synth.source_id, 0.3)
	var held_by_click: bool = player.held.has(KEY_F)
	var key_release: InputEventMouseButton = key_press.duplicate()
	key_release.pressed = false
	view.push_input(key_release)
	await frames(3)
	check(clicked_level > 0.0005 and held_by_click and not player.held.has(KEY_F) and player.plugin_open == synth,
		"clicking the on-screen keyboard plays it too, and leaves the window open", "%.4f" % clicked_level)
	key(KEY_D)
	await frames(2)
	main.get_window().focus_exited.emit()  # as when a plug-in's window takes the keyboard
	await frames(2)
	check(player.held.is_empty(), "should the game lose the keyboard, the notes held are let go rather than left hanging")
	key(KEY_D, false)
	await tap(KEY_ESCAPE)
	check(player.plugin_open == null and not main.menu.is_open(), "Esc puts it away too (rather than opening the menu)")
	await tap(KEY_E)
	key(KEY_A)
	var synth_level: float = await average_level(synth.source_id, 0.3)
	key(KEY_A, false)
	await tap(KEY_Q)
	check(synth_level > 0.0005, "sitting at it, the letter keys play it", "%.4f" % synth_level)
	await tap(KEY_TAB)
	await frames(3)
	var synth_strip: Dictionary = mix._strip_for(synth)
	(mix._strip_row.get_parent() as ScrollContainer).ensure_control_visible(synth_strip.source)
	await frames(3)
	check(synth_strip.source is Button and synth_strip.source.text == "DLSMusicDevice" and synth_strip.plate.text == "DLSMusicDevice",
		"its strip shows its plug-in where others show their input")
	await click(synth_strip.source.get_global_rect().get_center(), MOUSE_BUTTON_RIGHT)
	check(mix._plugin_menu.visible and mix._plugin_menu.get_item_index(2) >= 0 and mix._plugin_presets.get_item_index(mix._plugin_presets.SAVE) >= 0,
		"right-clicking it offers its window, another plug-in, and its presets")
	mix._plugin_menu.hide()
	mix._on_plugin_menu_chosen(1)
	picker._search.text = "ausampler"
	picker._search.text_changed.emit("ausampler")
	picker._search.text_submitted.emit("ausampler")
	await frames(3)
	check(synth.display_name == "AUSampler" and mix._strip_for(synth).plate.text == "AUSampler" and mix._strip_for(synth).source.text == "AUSampler",
		"Replace with another plug-in, and it takes that one's name", synth.display_name)
	mix.duplicate_instrument(synth)
	await frames(3)
	var synth_copy = main.instruments[main.instruments.find(synth) + 1]
	check(synth_copy.plays_plugin and synth_copy.display_name == "AUSampler 2" and synth_copy.instrument_plugin.get("plugin_name", "") == "AUSampler",
		"duplicated, it plays the same plug-in, with its settings", synth_copy.display_name)
	main.remove_instrument(synth_copy)
	await tap(KEY_TAB)
	await frames(2)

	print("Rooms")
	var session = main.session
	var room_file: String = session.path
	check(room_file == session.location().path_join("Test room").path_join("Test room.sroom") and session.has_unsaved_changes(),
		"the room has a folder of its own with its file inside, and what was done since it was made isn't saved yet", room_file)
	main.set_tempo(123.0)
	main.room.set_size(Vector3(18.0, 5.0, 12.0))
	var standing_at: Vector3 = player.global_position
	var command := InputEventKey.new()  # as a hand would: Cmd down, then S
	command.physical_keycode = KEY_META
	command.keycode = KEY_META
	command.pressed = true
	Input.parse_input_event(command)
	var save_key := InputEventKey.new()
	save_key.physical_keycode = KEY_S
	save_key.keycode = KEY_S
	save_key.meta_pressed = true
	save_key.pressed = true
	Input.parse_input_event(save_key)
	view.push_input(save_key)
	await frames(6)
	for each in [save_key, command]:
		var up: InputEventKey = each.duplicate()
		up.pressed = false
		Input.parse_input_event(up)
	await frames(2)
	var on_disk: Dictionary = library.read_room_file(room_file)
	check(not session.has_unsaved_changes() and is_equal_approx(float(on_disk.get("tempo", 0.0)), 123.0) and on_disk.get("name", "") == "Test room" and
		player.global_position.distance_to(standing_at) < 0.05, "Cmd-S saves it, the tempo and all, without walking you backwards",
		"unsaved %s, moved %.2f m" % [session.has_unsaved_changes(), player.global_position.distance_to(standing_at)])
	check(on_disk.instruments.size() == main.instruments.size() and on_disk.instruments[0].has("pattern") and on_disk.instruments[0].has("level_db") and
		on_disk.has("swing"), "its one file holds every instrument with its pattern and fader, and the tempo and swing")
	menu.open()
	await frames(2)
	check(menu._room_title.text == "Test room" and menu._room_status.text.begins_with("saved") and menu._save.visible, "the menu names the room, and when it was saved",
		menu._room_status.text)
	menu._on_room_menu_chosen(1)
	await frames(2)
	prompt._name.text = "Big room"
	prompt.confirm()
	await frames(2)
	check(FileAccess.file_exists(library.templates_dir().path_join("Big room.srtemplate")) and library.templates().any(func(t): return t.name == "Big room"),
		"its Room button saves the room as a template")
	menu.close()

	main.settings.backups = true
	main.settings.backups_kept = 2
	session._process(main.settings.backup_minutes * 60.0)
	var unchanged: bool = session.backups().is_empty()
	for bpm in [124.0, 125.0, 126.0]:
		main.set_tempo(bpm)
		session._process(main.settings.backup_minutes * 60.0)
	var copies: Array = session.backups()
	check(unchanged and copies.size() == 2 and copies[0].path.ends_with("Room Backups/Test room backup 002.sroom") and
		is_equal_approx(float(library.read_room_file(copies[1].path).tempo), 126.0) and session.has_unsaved_changes(),
		"every so often a backup goes in its Room Backups folder (only if it changed), keeping as many as set; the room itself stays unsaved",
		", ".join(copies.map(func(c): return c.path.get_file())))
	main.settings.autosave = true
	main.settings.autosave_minutes = 1
	main.set_tempo(127.0)
	session._process(61.0)
	check(not session.has_unsaved_changes() and is_equal_approx(float(library.read_room_file(room_file).tempo), 127.0) and main.hud._notice.text == "Auto-saved Test room",
		"with auto-save on, it is saved every so many minutes", main.hud._notice.text)
	main.settings.autosave = false

	main.set_tempo(128.0)  # a change left unsaved
	main.show_title()
	await frames(3)
	await click(title.buttons.new.get_global_rect().get_center())
	rooms._name.text = "Test room"
	rooms._check_name()
	check(rooms._create.disabled and rooms._new_status.text.begins_with("There is a room called that"), "a second room can't take the name of one beside it")
	rooms._name.text = "Second room"
	rooms._check_name()
	var big: int = rooms._templates.map(func(t): return t.name).find("Big room")
	rooms._template_list.select(big)
	rooms._on_template_chosen()
	check(is_equal_approx(rooms._size.x.value, 18.0) and is_equal_approx(rooms._size.y.value, 5.0), "choosing a template takes its size")
	rooms._size.x.value = 20.0
	rooms._carry.patterns.button_pressed = false
	rooms._carry.plugins.button_pressed = false
	await click(rooms._create.get_global_rect().get_center())
	check(session.is_asking() and session._confirm.dialog_text.contains("Test room"), "the room open has changes: making another asks first whether to save them")
	session._confirm.custom_action.emit(&"discard")
	await seconds(1.0)
	var second_drums = main.find_instrument("drums")
	var second_pad = main.find_instrument("pad")
	check(session.room_name == "Second room" and not title.is_open() and is_equal_approx(main.room.size.x, 20.0) and is_equal_approx(main.room.size.z, 12.0) and
		audio.get_pattern(second_drums.source_id).is_empty() and audio.get_inserts(second_pad.source_id)[0].plugin_name == "" and
		is_equal_approx(main.tempo, 123.0) and main.instruments.size() == on_disk.instruments.size(),
		"Don't Save lets it go, and the new room is the template at the size asked for, without the patterns and plug-ins left unticked")
	check(main.instruments.any(func(i): return i.plays_plugin and i.instrument_plugin.get("plugin_name", "") == "AUSampler"),
		"though a plug-in instrument keeps its plug-in: it is the instrument")
	check(is_equal_approx(float(library.read_room_file(room_file).tempo), 127.0), "the first room's file is as it was last saved")

	main.show_title()
	await frames(3)
	await click(title.buttons.open.get_global_rect().get_center())
	await frames(2)
	var listed: Array = rooms._rooms.map(func(r): return r.name)
	check(rooms.is_open() and rooms._open_page.visible and listed.has("Test room") and listed.has("Second room") and
		rooms._room_list.get_root().get_first_child().get_text(0).begins_with("Second room"), "Open room lists the rooms, the latest first", str(listed))
	var first_room: TreeItem = rooms._room_list.get_root().get_child(listed.find("Test room"))
	first_room.select(0)
	await click(rooms._open.get_global_rect().get_center())
	await seconds(1.0)
	check(session.room_name == "Test room" and is_equal_approx(main.tempo, 127.0) and main.room.size.is_equal_approx(Vector3(18.0, 5.0, 12.0)) and
		not session.has_unsaved_changes() and not title.is_open(), "opening one brings it back as it was saved, and goes in")
	check(main.instruments.any(func(i): return i.plays_plugin and i.display_name == "AUSampler" and i.instrument_plugin.get("plugin_name", "") == "AUSampler") and
		main.instruments.any(func(i): return i.kind == "garage_drums"), "the garage kit and the plug-in instrument come back with it")
	main.set_tempo(90.0)
	session.request_quit()
	var asked_from: Vector3 = player.global_position
	var asked_yaw: float = player.yaw
	key(KEY_LEFT)
	key(KEY_UP)
	var arrows := InputEventKey.new()
	arrows.physical_keycode = KEY_LEFT
	arrows.pressed = true
	Input.parse_input_event(arrows)
	await seconds(0.3)
	arrows = arrows.duplicate()
	arrows.pressed = false
	Input.parse_input_event(arrows)
	key(KEY_LEFT, false)
	key(KEY_UP, false)
	await frames(2)
	check(session.is_asking() and session._confirm.dialog_text.ends_with("before quitting?") and Input.mouse_mode == Input.MOUSE_MODE_VISIBLE and
		player.global_position.is_equal_approx(asked_from) and is_equal_approx(player.yaw, asked_yaw),
		"quitting with changes asks whether to save them, with the mouse free to answer and the arrows not turning you meanwhile")
	session._confirm.get_cancel_button().pressed.emit()
	await frames(2)
	check(not session.is_asking() and is_equal_approx(main.tempo, 90.0), "and Cancel carries on")

	print("Record rooms")
	var timeline = main.timeline
	main.show_title()
	await frames(3)
	await click(title.buttons.new.get_global_rect().get_center())
	await frames(2)
	check(rooms._jam.button_pressed and not rooms._record.button_pressed, "a new room is a Jam room unless Record is chosen")
	rooms._name.text = "Recording room"
	rooms._check_name()
	rooms._record.button_pressed = true
	rooms._template_list.select(0)
	rooms._on_template_chosen()
	await click(rooms._create.get_global_rect().get_center())
	if session.is_asking():
		session._confirm.custom_action.emit(&"discard")
	await seconds(1.0)
	check(session.room_name == "Recording room" and timeline.is_record() and timeline.playing and timeline.loop_on and timeline.loop_start == 0 and
		timeline.loop_end == 64 and main.instruments.size() == 6 and main.settings.room_mode == "record",
		"a Record room made from the default template starts as a Jam room does: playing, its first four bars going round")
	await seconds(0.5)
	check(timeline.position() > 0.5 and main.hud._beat.text.contains("⟳ 1–4"), "the screen shows where the music is, and the loop", main.hud._beat.text)
	var keys_inst = main.find_instrument("keys")
	var speaker_inst = main.speaker
	await tap(KEY_R)
	await frames(3)
	var edit = main.edit_window
	var view = edit.view
	check(main.hud.keys_prompt().contains("Tab  mix window  ·  R  edit window"), "the screen says R opens the edit window, beside Tab for the mix window",
		main.hud.keys_prompt())
	check(edit.is_open() and view.tracks().size() == 8 and view.tracks().back() == main.master_track and view.tracks()[-2] == main.room_master_track and
		not main.hud._root.visible, "R opens the edit window: a track for each instrument, and the masters at the foot (the room's, then the mix's)")
	check(edit._panel.get_combined_minimum_size().x <= main.get_viewport().get_visible_rect().size.x - 24.0,
		"its buttons all fit across the window", "%.0f px wide" % edit._panel.get_combined_minimum_size().x)
	await tap(KEY_SPACE)
	await frames(2)
	check(not timeline.playing and is_equal_approx(timeline.playhead, 0.0), "Space stops, and the playhead goes back to where it started")
	view.press(Vector2(view.x_of(32.0), 12))
	view.release(Vector2(view.x_of(32.0), 12))
	check(is_equal_approx(timeline.playhead, 32.0), "clicking the ruler puts the playhead there: bar 3", "%.1f" % timeline.playhead)
	view.drag_to(Vector2(view.x_of(16.0), 12), Vector2(view.x_of(48.0), 12))
	check(timeline.loop_on and timeline.loop_start == 16 and timeline.loop_end == 48, "dragging along the ruler loops that range: bars 2 and 3",
		"%d to %d" % [timeline.loop_start, timeline.loop_end])
	var keys_row: int = view.tracks().find(keys_inst)
	view.press(Vector2(84, view.row_top(keys_row) + 34))
	timeline.set_armed(speaker_inst, true)
	check(keys_inst.armed and not keys_inst.input_on and speaker_inst.armed and not speaker_inst.input_on and main.armed_instruments().has(keys_inst) and
		main.live_input, "R on a track's header arms it, its input button left as it was (as Pro Tools has it): the keys play an armed instrument, and the audio input opens for an armed Speaker")
	var speaker_header: int = view.tracks().find(speaker_inst)
	view.press(Vector2(108, view.row_top(speaker_header) + 34), true)  # its I, Option held
	var all_inputs: bool = main.instruments.all(func(i): return i.input_on)
	view.press(Vector2(108, view.row_top(speaker_header) + 34), true)
	view.press(Vector2(84, view.row_top(speaker_header) + 34), true)  # its R, Option held: it was armed, so all go off
	check(all_inputs and main.instruments.all(func(i): return not i.input_on) and main.instruments.all(func(i): return not i.armed),
		"Option-click, as Pro Tools' all-tracks modifier: every track's input on, then off, and every track disarmed")
	view.press(Vector2(84, view.row_top(keys_row) + 34))
	timeline.set_armed(speaker_inst, true)
	timeline.locate(0.0)
	var record_key := InputEventKey.new()
	record_key.physical_keycode = KEY_SPACE
	record_key.keycode = KEY_SPACE
	record_key.meta_pressed = true
	record_key.pressed = true
	view.get_viewport().push_input(record_key)
	await seconds(0.4)
	check(timeline.recording and timeline.playing and edit._record.text.contains("Recording"), "Cmd-Space records the armed tracks from the playhead")
	main.audio.note_on(keys_inst.source_id, 64, 0.8)
	await seconds(0.4)
	main.audio.note_off(keys_inst.source_id, 64)
	await seconds(0.3)
	await tap(KEY_SPACE)
	for wait in 20:
		await frames(3)
		if not keys_inst.clips.is_empty() and not speaker_inst.clips.is_empty():
			break
	var midi_clip: Dictionary = keys_inst.clips[0] if not keys_inst.clips.is_empty() else {}
	var audio_clip: Dictionary = speaker_inst.clips[0] if not speaker_inst.clips.is_empty() else {}
	var wav: String = session.room_folder().path_join("Audio Files/Speaker_01.wav")
	check(not timeline.recording and not timeline.playing and is_equal_approx(timeline.playhead, 0.0) and midi_clip.get("kind", "") == "midi" and
		midi_clip.notes.size() == 1 and int(midi_clip.notes[0].note) == 64 and audio_clip.get("file", "") == "Audio Files/Speaker_01.wav" and
		FileAccess.file_exists(wav) and float(audio_clip.length) > 0.8, "stopping makes clips: the notes played on the keys, and the Speaker's take as a WAV in the room's Audio Files folder",
		"%s, %s" % [str(midi_clip.get("notes", [])), wav])
	check(audio_clip.get("file", "") != "" and timeline.peaks(audio_clip).size() > 50, "a take's waveform can be drawn")
	var clip_start: float = float(midi_clip.start)
	var clip_y: float = view.row_top(keys_row) + 30
	view.drag_to(Vector2(view.x_of(clip_start + 3.0), clip_y), Vector2(view.x_of(clip_start + 19.2), clip_y))  # by its middle
	check(keys_inst.clips.size() == 1 and is_equal_approx(float(keys_inst.clips[0].start), timeline.snap(clip_start + 16.2)),
		"a clip dragged along its track moves, snapping to the grid", "%.2f" % float(keys_inst.clips[0].start))
	var moved_start: float = float(keys_inst.clips[0].start)
	view.drag_to(Vector2(view.x_of(moved_start + 3.0), clip_y), Vector2(view.x_of(moved_start + 35.0), clip_y), true)
	check(keys_inst.clips.size() == 2, "dropped with Option held, it is copied")
	view.selected = {"inst": keys_inst, "index": 1}
	edit.duplicate_selected()
	check(keys_inst.clips.size() == 3, "Cmd-D puts a second of the chosen clip just after it")
	await tap(KEY_BACKSPACE)
	check(keys_inst.clips.size() == 2 and view.selected.is_empty(), "Delete takes the chosen clip away")
	view.selected = {"inst": speaker_inst, "index": 0}
	timeline.set_loop(false)
	await tap(KEY_U)
	var take_span: Vector2 = timeline.clip_steps(speaker_inst.clips[0])
	check(timeline.loop_on and is_equal_approx(timeline.loop_start, take_span.x) and is_equal_approx(timeline.loop_end, take_span.y),
		"U loops the chosen clip, from its start to its end exactly", "%.3f to %.3f" % [timeline.loop_start, timeline.loop_end])
	await tap(KEY_L)
	var loop_off: bool = not timeline.loop_on
	await tap(KEY_L)
	check(loop_off and timeline.loop_on and is_equal_approx(timeline.loop_start, take_span.x), "L switches loop playback off and on again")
	view.selected = {}
	timeline.grid = 0
	view.drag_to(Vector2(view.x_of(5.3), 12), Vector2(view.x_of(9.7), 12))
	check(absf(timeline.loop_start - 5.3) < 0.2 and absf(timeline.loop_end - 9.7) < 0.2, "with the grid off, a loop dragged on the ruler isn't snapped to bars",
		"%.2f to %.2f" % [timeline.loop_start, timeline.loop_end])
	timeline.grid = 4
	timeline.locate(40.0)
	await tap(KEY_ENTER)
	check(is_equal_approx(timeline.playhead, 0.0), "Enter puts the playhead back at the start")
	edit._counter.grab_focus()
	edit._counter.text = "5 | 3"
	edit._counter.text_submitted.emit("5 | 3")
	await frames(2)
	var at_bar_five: float = timeline.playhead
	edit._counter.text_submitted.emit("0:02")
	await frames(2)
	check(is_equal_approx(at_bar_five, 72.0) and absf(timeline.playhead * timeline.step_seconds() - 2.0) < 0.01 and not edit._counter.has_focus() and
		edit._clock.text.begins_with("0:02"), "typing a bar | beat (or a time) in the counter puts the playhead there, and the time shows beside it",
		"%.1f, then %s" % [at_bar_five, edit._clock.text])
	timeline.locate(0.0)
	await tap(KEY_TAB)
	check(main.mixer.is_open() and not edit.is_open() and main.mixer._to_edit.text == "Edit window  (R)", "Tab goes over to the mix window")
	await tap(KEY_R)
	check(edit.is_open() and not main.mixer.is_open(), "and R from the mix window back to the edit window")
	var speaker_row: int = view.tracks().find(speaker_inst)
	view.drag_to(Vector2(view.x_of(timeline.clip_steps(audio_clip).x + 3.0), view.row_top(speaker_row) + 30),
		Vector2(view.x_of(timeline.clip_steps(audio_clip).x + 3.0), view.row_top(keys_row) + 30))
	check(speaker_inst.clips.size() == 1 and keys_inst.clips.size() == 2, "an audio clip can't be dropped on an instrument's track")

	print("Editing clips")
	view.zoom = 24.0  # a bar 384 pixels wide
	view.scroll_x = 0.0
	timeline.locate(0.0)
	var before_edits: Array = speaker_inst.clips.duplicate(true)
	var take: Dictionary = speaker_inst.clips[0].duplicate(true)
	var take_steps: Vector2 = timeline.clip_steps(take)
	var file_length: float = timeline.file_seconds(take)
	var lane_y: float = view.row_top(speaker_row) + 34  # below its name strip
	var strip_y: float = view.row_top(speaker_row) + 8   # in it
	check(view.cursor_at(Vector2(view.x_of(take_steps.y) - 2.0, lane_y)) == Control.CURSOR_HSIZE and
		view.cursor_at(Vector2(view.x_of(take_steps.x) + 1.0, strip_y)) == Control.CURSOR_BDIAGSIZE and
		view.cursor_at(Vector2(view.x_of(take_steps.y) - 1.0, strip_y)) == Control.CURSOR_FDIAGSIZE and
		view.cursor_at(Vector2(view.x_of((take_steps.x + take_steps.y) / 2.0), lane_y)) == Control.CURSOR_ARROW,
		"the cursor shows what a press would do: the trim cursor at a clip's ends, a fade cursor (a ramp in a box) at its top corners")
	check(view.hint_at(Vector2(view.x_of(take_steps.y) - 2.0, lane_y)).begins_with("Drag to trim the clip's end") and
		view.zone_at(Vector2(view.x_of(take_steps.x) + 1.0, strip_y)).get("zone", "") == "fade_in" and
		view.hint_at(Vector2(view.x_of((take_steps.x + take_steps.y) / 2.0), lane_y)).contains("⌘E splits"),
		"a clip's ends trim it and its top corners fade it, as the hint line says with the mouse over them",
		view.hint_at(Vector2(view.x_of(take_steps.y) - 2.0, lane_y)))
	var end_x: float = view.x_of(take_steps.y - 4.0)
	view.drag_to(Vector2(view.x_of(take_steps.y) - 2.0, lane_y), Vector2(end_x, lane_y))
	check(speaker_inst.clips.size() == 1 and absf(timeline.clip_steps(speaker_inst.clips[0]).y - timeline.snap(view.step_at(end_x))) < 0.01 and
		is_equal_approx(float(speaker_inst.clips[0].start), float(take.start)) and is_equal_approx(float(speaker_inst.clips[0].offset), float(take.offset)),
		"dragging a clip's end trims it, to the grid", "ends at step %.2f" % timeline.clip_steps(speaker_inst.clips[0]).y)
	view.drag_to(Vector2(view.x_of(timeline.clip_steps(speaker_inst.clips[0]).y) - 2.0, lane_y), Vector2(view.x_of(take_steps.y + 40.0), lane_y))
	check(absf(float(speaker_inst.clips[0].offset) + float(speaker_inst.clips[0].length) - file_length) < 0.001,
		"drawn out again, an audio clip reaches the end of its file and no further", "%.3f s of %.3f" % [float(speaker_inst.clips[0].length), file_length])
	var start_x: float = view.x_of(take_steps.x + 4.0)
	view.drag_to(Vector2(view.x_of(take_steps.x) + 2.0, lane_y), Vector2(start_x, lane_y))
	var new_start: float = timeline.snap(view.step_at(start_x)) * timeline.step_seconds()
	var trimmed: Dictionary = speaker_inst.clips[0]
	check(absf(float(trimmed.start) - new_start) < 0.001 and absf(float(trimmed.offset) - (float(take.offset) + new_start - float(take.start))) < 0.001 and
		absf(float(trimmed.start) + float(trimmed.length) - (float(take.start) + file_length - float(take.offset))) < 0.001,
		"its start trims the same way: the clip shows its file from later on, its end staying put", "starts %.3f s, %.3f s into its file" % [float(trimmed.start), float(trimmed.offset)])
	var span_now: Vector2 = timeline.clip_steps(trimmed)
	view.drag_to(Vector2(view.x_of(span_now.x) + 1.0, strip_y), Vector2(view.x_of(span_now.x + 1.0), strip_y))
	view.drag_to(Vector2(view.x_of(span_now.y) - 1.0, strip_y), Vector2(view.x_of(span_now.y - 1.0), strip_y))
	check(absf(float(speaker_inst.clips[0].fade_in) - timeline.step_seconds()) < 0.01 and absf(float(speaker_inst.clips[0].fade_out) - timeline.step_seconds()) < 0.01,
		"dragging a clip's top corners fades it in and out", "%.3f s in, %.3f s out" % [float(speaker_inst.clips[0].fade_in), float(speaker_inst.clips[0].fade_out)])
	var cut_at: float = (span_now.x + span_now.y) / 2.0
	view.release(Vector2(view.x_of(cut_at), lane_y))  # (nothing pressed: nothing happens)
	view.press(Vector2(view.x_of(cut_at), lane_y))
	view.release(Vector2(view.x_of(cut_at), lane_y))
	var clicked_to: float = timeline.playhead
	timeline.locate(cut_at)
	await command_tap(KEY_E)
	var first_half: Dictionary = speaker_inst.clips[0]
	var second_half: Dictionary = speaker_inst.clips[1] if speaker_inst.clips.size() > 1 else {}
	check(is_equal_approx(clicked_to, timeline.snap(cut_at)) and speaker_inst.clips.size() == 2 and
		absf(float(first_half.start) + float(first_half.length) - float(second_half.start)) < 1e-6 and
		absf(float(second_half.offset) - (float(first_half.offset) + float(first_half.length))) < 1e-6 and float(first_half.fade_in) > 0.0 and
		float(first_half.fade_out) == 0.0 and float(second_half.fade_in) == 0.0 and float(second_half.fade_out) > 0.0 and
		str(second_half.name) == str(take.name) + "-01" and view.selected.get("index", -1) == 1,
		"clicking a clip (stopped) puts the playhead there, and Cmd-E splits it there: the halves meet, each keeping its outer fade", str(second_half.get("name", "")))
	var second_start: float = float(second_half.start)
	await tap(KEY_PERIOD)
	var nudged: Dictionary = speaker_inst.clips[view.selected.index]
	check(absf(float(nudged.start) - (second_start + timeline.grid * timeline.step_seconds())) < 1e-6,
		"full stop nudges the chosen clip a grid line later (comma, earlier)", "%.3f s to %.3f s" % [second_start, float(nudged.start)])
	await command_tap(KEY_Z)
	check(speaker_inst.clips.size() == 2 and is_equal_approx(float(speaker_inst.clips[1].start), second_start), "Cmd-Z undoes the nudge")
	for undo in 6:
		await command_tap(KEY_Z)
	check(speaker_inst.clips == before_edits and view.selected.is_empty(), "and the split, the fades and the trims, one by one, back to the take as it was")
	await command_tap(KEY_X)
	var first_trim: float = timeline.snap(view.step_at(end_x))
	check(absf(timeline.clip_steps(speaker_inst.clips[0]).y - first_trim) < 0.01 and not edit._undo.disabled and not edit._redo.disabled,
		"Cmd-X does the first trim again (the rest still to redo)", "undo %s, redo %s" % [edit._undo.disabled, edit._redo.disabled])
	edit._undo.pressed.emit()
	await frames(2)
	var undone_by_button: bool = speaker_inst.clips == before_edits
	edit._redo.pressed.emit()
	await frames(2)
	check(undone_by_button and absf(timeline.clip_steps(speaker_inst.clips[0]).y - first_trim) < 0.01, "the edit window's undo and redo buttons do the same")
	await command_tap(KEY_Z)
	await command_tap(KEY_Z, true)
	var shift_redid: bool = absf(timeline.clip_steps(speaker_inst.clips[0]).y - first_trim) < 0.01
	await command_tap(KEY_Z)
	check(shift_redid and speaker_inst.clips == before_edits, "Cmd-Shift-Z redoes too (and Cmd-Z undoes it again)")
	timeline.separate(speaker_inst, 0, (take_steps.x + take_steps.y) / 2.0)
	var seam_x: float = view.x_of(timeline.clip_steps(speaker_inst.clips[0]).y)
	check(view.zone_at(Vector2(seam_x, strip_y)).get("zone", "") == "xfade" and view.hint_at(Vector2(seam_x, strip_y)).begins_with("Drag along to crossfade"),
		"where two clips meet, the top of the seam crossfades them")
	view.drag_to(Vector2(seam_x, strip_y), Vector2(seam_x + 0.5 * view.zoom, strip_y))  # half a step past the cut
	var xspan: Vector2 = timeline.crossfade_span(speaker_inst, 0)
	var sent: Array = timeline.engine_clips(speaker_inst)
	var xlength: float = timeline.step_seconds()
	check(absf(xspan.x + xspan.y - xlength) < 0.005 and absf(xspan.x - xspan.y) < 0.005 and sent.size() == 2 and
		absf(float(sent[0].start) + float(sent[0].length) - (float(sent[1].start) + xspan.x + xspan.y)) < 1e-4 and
		absf(float(sent[0].fade_out) - xlength) < 0.005 and absf(float(sent[1].fade_in) - xlength) < 0.005,
		"dragged along, it crossfades them, centred on the cut: each plays on into the other's time from its file, one fading out as the other fades in",
		"%.3f s before the cut, %.3f s after" % [xspan.x, xspan.y])
	timeline.undo()
	timeline.undo()
	check(speaker_inst.clips == before_edits, "(the crossfade and the split undone)")

	var gain_at: Vector2 = view._gain_rect(view.x_of(take_steps.x), view.row_top(speaker_row)).get_center()
	check(view.zone_at(gain_at).get("zone", "") == "gain" and view.cursor_at(gain_at) == Control.CURSOR_VSIZE and
		view.hint_at(gain_at).begins_with("Clip gain"), "an audio clip has a clip gain fader at its foot, as Pro Tools has", view.hint_at(gain_at))
	view.drag_to(gain_at, gain_at - Vector2(0, 24))  # a quarter of a dB a pixel
	var lifted := float(speaker_inst.clips[0].get("gain_db", 0.0))
	var sent_gain := float(timeline.engine_clips(speaker_inst)[0].gain)
	view.press(gain_at, true)  # Option-click
	view.release(gain_at)
	var reset_gain := float(speaker_inst.clips[0].get("gain_db", 0.0))
	view.selected = {"inst": speaker_inst, "index": 0}
	await control_shift_tap(KEY_UP)
	check(is_equal_approx(lifted, 6.0) and absf(sent_gain - db_to_linear(6.0)) < 0.001 and reset_gain == 0.0 and
		is_equal_approx(float(speaker_inst.clips[0].gain_db), 1.0), "dragged up it turns the clip up, Option-click puts it back to 0 dB, and Ctrl-Shift-↑ nudges it a dB",
		"%.1f dB, then %.1f, then %.1f" % [lifted, reset_gain, float(speaker_inst.clips[0].gain_db)])
	for undo in 3:
		timeline.undo()
	check(speaker_inst.clips == before_edits, "(undone)")

	timeline.separate(speaker_inst, 0, (take_steps.x + take_steps.y) / 2.0)
	var halves: Array = speaker_inst.clips.duplicate()
	var middle_y: float = view.row_top(speaker_row) + 26
	var a_mid := Vector2(view.x_of((timeline.clip_steps(halves[0]).x + timeline.clip_steps(halves[0]).y) / 2.0), middle_y)
	var b_mid := Vector2(view.x_of((timeline.clip_steps(halves[1]).x + timeline.clip_steps(halves[1]).y) / 2.0), middle_y)
	view.press(a_mid)
	view.release(a_mid)
	view.press(b_mid, false, true)  # Shift-click
	view.release(b_mid)
	var a_was := float(halves[0].start)
	var b_was := float(halves[1].start)
	var two_chosen: bool = view.chosen_items().size() == 2
	view.drag_to(a_mid, a_mid + Vector2(4.0 * view.zoom, 0))
	var together: Array = view.chosen_items()
	check(two_chosen and together.size() == 2 and absf(float(together[0].clip.start) - (a_was + 4.0 * timeline.step_seconds())) < 1e-6 and
		absf(float(together[1].clip.start) - (b_was + 4.0 * timeline.step_seconds())) < 1e-6,
		"Shift-click chooses a second clip, and dragging one moves both together")
	await tap(KEY_DELETE)
	check(speaker_inst.clips.is_empty() and view.chosen_items().is_empty(), "Delete takes away every clip chosen")
	for undo in 3:
		timeline.undo()
	await command_tap(KEY_A)
	var every_clip := 0
	for each in main.instruments:
		every_clip += each.clips.size()
	await tap(KEY_U)
	var everything: Vector2 = timeline.span_of(view.chosen_items())
	check(speaker_inst.clips == before_edits and view.chosen_items().size() == every_clip and is_equal_approx(timeline.loop_start, everything.x) and
		is_equal_approx(timeline.loop_end, everything.y), "Cmd-A chooses every clip, and U loops round them all", "%d clips" % every_clip)
	view.chosen = []
	var midi: Dictionary = keys_inst.clips[0]
	var midi_end: float = float(midi.start) + float(midi.length)
	var note_step: float = float(midi.notes[0].step)
	timeline.trim_clip(keys_inst, 0, "end", float(midi.start) + note_step - 0.1)
	var cut_off: bool = float(midi.notes[0].step) >= float(midi.length)
	timeline.trim_clip(keys_inst, 0, "end", midi_end)
	check(cut_off and midi.notes.size() == 1 and is_equal_approx(float(midi.notes[0].step), note_step) and is_equal_approx(float(midi.length), midi_end - float(midi.start)),
		"a MIDI clip trimmed short keeps the notes it no longer shows, and drawn out again they are back")
	view.zoom = 6.0
	await tap(KEY_R)
	check(not edit.is_open(), "R closes it again")

	print("Insertion follows playback")
	timeline.locate(8.0)
	await tap(KEY_ENTER)
	check(is_equal_approx(timeline.playhead, 0.0), "Enter in the room puts the playhead back at the start too")
	await tap(KEY_N)
	await frames(2)
	check(main.settings.insertion_follows and main.hud._follow_chip.visible and main.hud._follow_chip.text == "FOLLOWS PLAYBACK",
		"N: insertion follows playback, which the screen shows")
	timeline.set_loop(false)
	timeline.start_playing()
	await seconds(0.6)
	await tap(KEY_SPACE)
	check(not timeline.playing and timeline.playhead > 1.5, "stopping then leaves the playhead where the music stopped", "step %.2f" % timeline.playhead)
	await tap(KEY_R)
	await tap(KEY_N)
	await frames(2)
	check(edit.is_open() and not main.settings.insertion_follows and not edit._follow.button_pressed,
		"N in the edit window switches it off again, as its Follow button shows")
	var played_from: float = timeline.playhead
	timeline.start_playing()
	await seconds(0.4)
	await tap(KEY_SPACE)
	check(is_equal_approx(timeline.playhead, played_from), "and stopping goes back to where playing started")
	await tap(KEY_R)
	await frames(2)
	check(not main.hud._follow_chip.visible, "and the screen no longer says it follows")
	var loop_was: bool = timeline.loop_on
	await tap(KEY_L)
	var room_flipped: bool = timeline.loop_on != loop_was
	await tap(KEY_L)
	check(room_flipped and timeline.loop_on == loop_was, "L in the room (away from a loop pedal) switches loop playback too")

	print("Count-in")
	main.settings.count_in_bars = 1
	timeline.locate(16.0)
	check(timeline.start_recording() == "", "recording starts with a count-in")
	await seconds(0.4)
	main.edit_window.open()
	await frames(3)
	check(timeline.counting_in() > 0 and edit._record.text.begins_with("●  Count ") and is_equal_approx(timeline.position(), 16.0) and
		main.speaker.clips.size() == 1, "the click counts a bar first, the edit window saying so, the music waiting at the playhead", edit._record.text)
	timeline.stop()
	await frames(6)
	check(not timeline.recording and main.speaker.clips.size() == 1 and keys_inst.clips.size() == 2 and is_equal_approx(timeline.playhead, 16.0),
		"stopped during the count-in, nothing is recorded")
	main.edit_window.close()
	main.settings.count_in_bars = 0
	timeline.locate(0.0)

	print("Loop recording")
	var loop_before := Vector2(timeline.loop_start, timeline.loop_end)
	timeline.set_loop(true, 16.0, 24.0)  # half a bar
	main.settings.loop_record = true
	var pass_seconds: float = 8.0 * timeline.step_seconds()
	check(timeline.start_recording() == "" and is_equal_approx(timeline.playhead, 16.0), "Loop Record starts from the loop's start")
	await seconds(pass_seconds * 1.2)
	main.audio.note_on(keys_inst.source_id, 67, 0.8)  # in the second pass
	await seconds(0.15)
	main.audio.note_off(keys_inst.source_id, 67)
	await frames(2)
	var loop_rec_text: String = main.hud._beat.text
	var wrapped_back: bool = timeline.position() < 24.0
	await seconds(pass_seconds * 2.3 - pass_seconds * 1.2 - 0.15)
	timeline.stop()
	for wait in 20:
		await frames(3)
		if not timeline._taking:
			break
	var stacked: Dictionary = main.speaker.clips.back() if not main.speaker.clips.is_empty() else {}
	var keys_stack: Dictionary = keys_inst.clips.back()
	check(loop_rec_text.contains("LOOP REC") and wrapped_back and stacked.get("takes", []).size() == 2 and int(stacked.get("take", 0)) == 2 and
		is_equal_approx(float(stacked.start), 16.0 * timeline.step_seconds()) and absf(float(stacked.length) - pass_seconds) < 0.01,
		"it goes round the loop as it records, and each whole pass is a take, stacked: the last one shown", loop_rec_text)
	check(int(keys_stack.get("take", 0)) == 2 and keys_stack.get("takes", []).size() == 2 and keys_stack.notes.size() == 1 and
		keys_stack.takes[0].notes.is_empty(), "the keys' takes too, the note played in the second pass in the second take")
	var stacked_at: int = main.speaker.clips.size() - 1
	view.show_takes(main.speaker, stacked_at, Vector2(300, 100))
	var take_items: int = view._takes_menu.item_count
	var second_checked: bool = view._takes_menu.is_item_checked(1)
	view._takes_menu.id_pressed.emit(1)
	view._takes_menu.hide()
	check(take_items == 4 and second_checked and int(main.speaker.clips.back().take) == 1 and main.speaker.clips.back().takes.size() == 2 and
		absf(timeline.clip_steps(main.speaker.clips.back()).y - 24.0) < 0.01,
		"right-click a clip for its takes, and choosing another shows it in the clip's place")

	print("Comping")
	timeline.grid = 2
	main.edit_window.open()
	await frames(2)
	view.show_takes(main.speaker, main.speaker.clips.size() - 1, Vector2(300, 100))
	view._takes_menu.id_pressed.emit(view.SHOW_TAKES)
	view._takes_menu.hide()
	var takes_row: int = view.tracks().find(main.speaker)
	view.scroll_y = clampf(view.row_top(takes_row) + view.scroll_y - view.RULER, 0.0, view._most_scroll())
	var take_two_y: float = view.take_top(takes_row, 1) + view.TAKE / 2.0
	var take_hint: String = view.hint_at(Vector2(view.x_of(19.0), take_two_y))
	check(main.speaker.takes_open and view.take_lanes(main.speaker) == 2 and is_equal_approx(view.height_of(main.speaker), view.ROW + 2 * view.TAKE) and
		take_hint.begins_with("Take 2: drag along it"), "the takes menu shows the takes under the track, a lane each, to comp from", take_hint)
	view.press(Vector2(view.x_of(18.0), take_two_y))
	view._on_drag(Vector2(view.x_of(22.0), take_two_y))
	view.release(Vector2(view.x_of(22.0), take_two_y))
	var comped: Array = main.speaker.clips.filter(func(c): return timeline.group_of(c) == timeline.group_of(stacked))
	comped.sort_custom(func(a, b): return float(a.start) < float(b.start))
	var comp_parts: Array = comped.map(func(c): return [int(c.take), snappedf(timeline.clip_steps(c).x, 0.01), snappedf(timeline.clip_steps(c).y, 0.01)])
	check(comp_parts == [[1, 16.0, 18.0], [2, 18.0, 22.0], [1, 22.0, 24.0]] and comped.all(func(c): return c.takes.size() == 2) and
		is_equal_approx(float(comped[0].get("xfade", 0.0)), timeline.COMP_XFADE) and is_equal_approx(float(comped[1].get("xfade", 0.0)), timeline.COMP_XFADE),
		"dragging along a take puts that part of it in the track, in place of what was there (a moment's crossfade at each join)", str(comp_parts))
	var take_one_y: float = view.take_top(takes_row, 0) + view.TAKE / 2.0
	view.press(Vector2(view.x_of(20.0), take_one_y))
	view.release(Vector2(view.x_of(20.0), take_one_y))
	var part_at_20: Array = main.speaker.clips.filter(func(c): return timeline.clip_steps(c).x <= 20.0 and timeline.clip_steps(c).y > 20.0)
	check(part_at_20.size() == 1 and int(part_at_20[0].take) == 1 and is_equal_approx(timeline.clip_steps(part_at_20[0]).x, 18.0),
		"clicking a take puts it in place of the part of the track over it")
	view.show_takes(main.speaker, main.speaker.clips.size() - 1, Vector2(300, 100))
	view._takes_menu.id_pressed.emit(view.SHOW_TAKES)
	view._takes_menu.hide()
	view.scroll_y = 0.0
	main.edit_window.close()
	timeline.grid = 4
	for undo in 4:
		timeline.undo()
	main.settings.loop_record = false
	timeline.set_loop(true, loop_before.x, loop_before.y)
	check(main.speaker.clips.size() == 1 and keys_inst.clips.size() == 2, "(the loop recording undone)")

	print("Microphones")
	var drums_heard = main.find_instrument("drums")
	var mic = main.add_instrument("mic", Vector3(drums_heard.global_position.x + 2.0, 0.0, drums_heard.global_position.z + 1.0))
	main.mixer.open()
	await frames(3)
	var mic_strip: Dictionary = main.mixer._strip_for(mic)
	var mic_card: String = mic_strip.source.text if not mic_strip.is_empty() else ""
	main.mixer.close()
	check(mic != null and mic.is_mic and not mic.playable and not mic.is_live() and is_equal_approx(mic.global_position.y, 1.2) and mic_card == "FLAT · OMNI",
		"a microphone stands in the room on its stand, its capsule 1.2 m up: an audio track, its strip saying what it is", mic_card)
	var mp = main.mic_panel
	mp.open(mic)
	await frames(2)
	mp._x.value = drums_heard.global_position.x + 1.5
	mp._z.value = drums_heard.global_position.z
	mp._height.value = 0.6
	mp._aim_at.item_selected.emit(mp._aim_choices.find(drums_heard) + 1)
	await frames(2)
	var points: Vector3 = Vector3(sin(mic.rotation.y) * cos(deg_to_rad(mic.mic_tilt)), -sin(deg_to_rad(mic.mic_tilt)), cos(mic.rotation.y) * cos(deg_to_rad(mic.mic_tilt)))
	var toward: Vector3 = (drums_heard.global_position - mic.global_position).normalized()
	var from_it: Array = mp.distances(mic, main.instruments)
	check(is_equal_approx(mic.global_position.x, drums_heard.global_position.x + 1.5) and is_equal_approx(mic.source_height, 0.6) and
		is_equal_approx(mic.global_position.y, 0.6) and points.dot(toward) > 0.999 and from_it[0].name == drums_heard.display_name and
		absf(from_it[0].ms - 1000.0 * from_it[0].metres / 343.0) < 0.01 and mp.distances_text().begins_with(drums_heard.display_name),
		"its panel puts it to the centimetre, its capsule as high as wanted, pointing straight at the drums; and says how far each instrument is, and how late it is heard",
		mp.distances_text().get_slice("\n", 0))
	mp._gain.value = 6.0
	check(is_equal_approx(mic.mic_gain_db, 6.0), "and its gain, before it records")
	check(mp.guide_text() == "W A S D move, R F height, drag aim, wheel closer or further, Shift fine, P close" and mp._guide.is_visible_in_tree(),
		"the view shows its keys in the corner, as they lie on the keyboard: W A S D to move it, R and F for its height", mp.guide_text())
	await seconds(0.8)  # (a pause: what comes next is a move of its own)
	var mic_spot: Vector3 = mic.global_position
	var raise := InputEventKey.new()
	raise.physical_keycode = KEY_R
	raise.keycode = KEY_R
	raise.pressed = true
	Input.parse_input_event(raise)
	await seconds(0.4)
	raise.pressed = false
	Input.parse_input_event(raise)
	await frames(2)
	var raised: float = mic.source_height
	await command_tap(KEY_Z)
	var put_back: bool = is_equal_approx(mic.source_height, 0.6) and mic.global_position.is_equal_approx(mic_spot)
	await command_tap(KEY_X)
	check(raised > 0.65 and put_back and is_equal_approx(mic.source_height, raised),
		"R held raises it; Cmd-Z puts it back (moves have an undo of their own, in the room), and Cmd-X raises it again", "%.2f m raised" % raised)
	await command_tap(KEY_Z)
	await command_tap(KEY_L)
	var x_before: float = mic.global_position.x
	mp._x.value = x_before + 0.5
	await frames(2)
	check(mic.locked and mic.lock_shown() and mp.guide_text().begins_with("Locked in place") and not mp._x.editable and
		is_equal_approx(mic.global_position.x, x_before), "Cmd-L locks it in place: a padlock over its name, its place can't be changed, and the view says so",
		mp.guide_text())
	await command_tap(KEY_L)
	check(not mic.locked and not mic.lock_shown() and mp._x.editable, "Cmd-L again unlocks it")
	mp.close()
	main.set_input(mic, true)
	main.set_soloed(mic, true)
	main.set_pre_fader_meters(true)
	mic.peak_hold = 0.0
	main.master_peak_hold = 0.0
	timeline.locate(0.0)
	timeline.start_playing()
	await seconds(0.8)
	timeline.stop()
	check(mic.peak_hold > 0.001 and main.master_peak_hold > 0.001 and main.silenced.has(drums_heard),
		"its input on and soloed, what it hears is heard: the drums through it (a solo takes them out of the mix, not out of the room)",
		"%.0f dBFS" % linear_to_db(maxf(mic.peak_hold, 1e-9)))
	main.set_soloed(mic, false)
	main.set_input(mic, false)
	timeline.set_armed(mic, true)
	timeline.locate(0.0)
	var mic_record: String = timeline.start_recording()
	await seconds(0.8)
	timeline.stop()
	for wait in 20:
		await frames(3)
		if not timeline._taking:
			break
	var mic_clip: Dictionary = mic.clips.back() if not mic.clips.is_empty() else {}
	check(mic_record == "" and mic_clip.get("kind", "") == "audio" and FileAccess.file_exists(timeline.file_path(mic_clip)) and
		absf(float(mic_clip.get("start", -1.0))) < 0.05,
		"armed, it records what it hears to an audio clip, from where it started (no input latency to take off)", mic_record)
	timeline.set_armed(mic, false)
	var mic_entry: Array = main.library.room_data().instruments.filter(func(e): return e.kind == "mic")
	check(mic_entry.size() == 1 and is_equal_approx(float(mic_entry[0].height), 0.6) and is_equal_approx(float(mic_entry[0].tilt), mic.mic_tilt) and
		is_equal_approx(float(mic_entry[0].settings.mic_gain_db), 6.0), "it is kept with the room: where it stands, how high, how it points, and its gain")
	timeline.undo()
	# In the room: locked, an instrument can't be picked up; carried and put down, Cmd-Z puts it back.
	var bells_moved = main.find_instrument("bells")
	main._sit_at("bells")
	await frames(3)
	var bells_spot: Vector3 = bells_moved.global_position
	var faced_bells: bool = player.target == bells_moved
	await command_tap(KEY_L)
	var locked_card: Array = main.hud.hint_lines()
	await tap(KEY_G)
	var lock_refused: bool = player.carried == null
	await command_tap(KEY_L)
	await tap(KEY_G)
	var bells_lifted: bool = player.carried == bells_moved
	player.place(player.global_position + Vector3(1.5, 0.0, 0.0), 0.0)
	await frames(3)
	await tap(KEY_G)
	var moved_to: Vector3 = bells_moved.global_position
	await command_tap(KEY_Z)
	check(faced_bells and locked_card.has("⌘L Unlock") and not locked_card.has("G Carry") and lock_refused and bells_lifted and
		moved_to.distance_to(bells_spot) > 0.5 and bells_moved.global_position.is_equal_approx(bells_spot),
		"facing it, Cmd-L locks it (its card offers to unlock it, not to carry it) and G won't pick it up; unlocked, carried off and put down, Cmd-Z puts it back",
		"%s; refused %s, lifted %s, moved %.2f m, back %s" % [" / ".join(locked_card), lock_refused, bells_lifted, moved_to.distance_to(bells_spot),
		bells_moved.global_position.is_equal_approx(bells_spot)])
	check(main.library.room_data().instruments.all(func(e): return not e.get("locked", false)), "and nothing is kept locked that isn't")

	print("Microphone models, pans and stereo pairs")
	mp.open(mic)
	await frames(2)
	var model_ids: Array = main.mic_models().map(func(m): return m.id)
	mp._model.item_selected.emit(model_ids.find("dynamic"))
	await frames(2)
	var dynamic_patterns: int = mp._pattern.item_count
	var dynamic_disabled: bool = mp._pattern.disabled
	mp._model.item_selected.emit(model_ids.find("condenser"))
	await frames(2)
	var condenser_patterns: int = mp._pattern.item_count
	mp._pattern.item_selected.emit(mp._patterns_shown.find("figure8"))
	await frames(2)
	check(model_ids.size() == 6 and dynamic_patterns == 1 and dynamic_disabled and condenser_patterns == 3 and mic.mic_model == "condenser" and
		main.mic_pattern_of(mic) == "figure8" and mic.display_name.begins_with("Condenser Mic") and mp._graph.model == "condenser",
		"its panel switches its model (a dynamic is cardioid only; a large condenser cardioid, omni or figure-8), its name following, its response and pattern drawn",
		mic.display_name)
	mp.close()
	main.mixer.open()
	await frames(3)
	var panned_strip: Dictionary = main.mixer._strip_for(mic)
	panned_strip.pan.value_changed.emit(-0.5)
	await frames(2)
	check(is_equal_approx(mic.pan, -0.5) and is_equal_approx(panned_strip.pan.value, -0.5) and panned_strip.source.text == "LDC · FIG-8" and
		panned_strip.room.is_empty(), "its track's pan, on its strip (a microphone has no level in the room: it makes no sound there)", panned_strip.source.text)
	main.mixer.close()
	var settings_kept: Dictionary = main.library.instrument_settings(mic)
	check(settings_kept.get("mic_model") == "condenser" and settings_kept.get("mic_pattern") == "figure8" and is_equal_approx(float(settings_kept.get("pan", 0.0)), -0.5),
		"its model, pattern and pan are kept with it")
	main.remove_instrument(mic)
	await frames(2)
	var tracks_before: int = main.track_order().size()
	var stereo = main.add_instrument("mic_pair", Vector3(0.0, 0.0, 1.0))
	main.set_pair_technique(stereo, "xy")
	await frames(3)
	var xy_capsules: Array = stereo.mic_capsules()
	check(stereo != null and stereo.is_stereo_mic and stereo.pair_technique == "xy" and stereo.mic_model == "pencil" and main.mic_pattern_of(stereo) == "cardioid" and
		main.track_order().size() == tracks_before + 1 and xy_capsules[0].at.is_equal_approx(xy_capsules[1].at) and
		is_equal_approx(rad_to_deg(xy_capsules[0].turn - xy_capsules[1].turn), 90.0),
		"a stereo pair is one stereo track: two pencil cardioids at one point, 90° apart (XY)")
	mp.open(stereo)
	await frames(2)
	var pair_row_shown: bool = mp._pair_row.visible
	var pattern_locked: bool = mp._pattern.disabled
	mp._technique.item_selected.emit(main.Catalog.MIC_PAIR_ORDER.find("ab"))
	await frames(2)
	var ab_apart: float = stereo.mic_capsules()[0].at.distance_to(stereo.mic_capsules()[1].at)
	var ab_omni: bool = main.mic_pattern_of(stereo) == "omni"
	mp._spacing.value = 1.0
	await frames(2)
	var spaced: float = stereo.mic_capsules()[0].at.distance_to(stereo.mic_capsules()[1].at)
	check(pair_row_shown and pattern_locked and ab_omni and absf(ab_apart - 0.6) < 0.001 and absf(spaced - 1.0) < 0.001 and
		stereo.mic_capsules()[0].at.x > 0.0, "its panel sets it up as a spaced pair of omnis, as far apart as wanted (the left one on its left)",
		"%.2f m apart" % spaced)
	mp._technique.item_selected.emit(main.Catalog.MIC_PAIR_ORDER.find("blumlein"))
	await frames(2)
	check(stereo.mic_model == "ribbon" and main.mic_pattern_of(stereo) == "figure8", "Blumlein: two figure-8s (ribbons: the pencils have no figure-8)")
	mp._technique.item_selected.emit(main.Catalog.MIC_PAIR_ORDER.find("ms"))
	await frames(2)
	var ms_turns: Array = stereo.mic_capsules().map(func(c): return roundi(rad_to_deg(c.turn)))
	var ms_unlocked: bool = not mp._pattern.disabled and mp._width.visible
	mp._width.value = 50.0
	mp._pattern.item_selected.emit(mp._patterns_shown.find("omni"))
	await frames(2)
	check(ms_turns == [0, 90] and stereo.mic_capsules()[1].model == "condenser" and ms_unlocked and is_equal_approx(stereo.ms_width, 0.5) and
		main.mic_pattern_of(stereo) == "omni", "mid-side: a mid facing ahead (its pattern free: an omni here) and a figure-8 across it, as wide as set",
		str(ms_turns))
	mp.close()
	main.mixer.open()
	await frames(3)
	var stereo_strip: Dictionary = main.mixer._strip_for(stereo)
	check(stereo_strip.small.text == "STEREO MIC" and stereo_strip.source.text.ends_with("· M/S"), "its strip says what it is", stereo_strip.source.text)
	main.mixer.close()
	timeline.set_armed(stereo, true)
	timeline.locate(0.0)
	var stereo_record: String = timeline.start_recording()
	await seconds(0.6)
	timeline.stop()
	for wait in 20:
		await frames(3)
		if not timeline._taking:
			break
	var stereo_clip: Dictionary = stereo.clips.back() if not stereo.clips.is_empty() else {}
	var channels := 0
	if not stereo_clip.is_empty():
		var stereo_file := FileAccess.open(timeline.file_path(stereo_clip), FileAccess.READ)
		if stereo_file != null:
			stereo_file.seek(22)
			channels = stereo_file.get_16()
	check(stereo_record == "" and channels == 2, "armed, it records one stereo file", "%d channels" % channels)
	timeline.set_armed(stereo, false)
	timeline.undo()
	var stereo_entry: Array = main.library.room_data().instruments.filter(func(e): return e.kind == "mic_pair")
	check(stereo_entry.size() == 1 and stereo_entry[0].stereo.technique == "ms" and is_equal_approx(float(stereo_entry[0].stereo.width), 0.5),
		"it is kept with the room, set up as it is")
	stereo.automation["pan"] = [[0.0, -1.0], [16.0, 1.0]]
	stereo.lanes = ["pan"]
	timeline.sync(stereo)
	timeline.locate(12.0)
	await frames(3)
	check(main.automation.params_for(stereo).has("pan") and is_equal_approx(stereo.pan, 0.5) and main.automation.value_text(stereo, "pan", 0.5) == "50>",
		"a mic's pan (a stereo mic's balance) can be automated: stopped, it is where its lane has it", "%.2f" % stereo.pan)
	stereo.automation = {}
	timeline.locate(0.0)
	mp.open(stereo)
	await frames(2)
	check(mp._about.text.contains("self-noise"), "its panel says how much noise it makes (its own, and its preamp's)", mp._about.text.get_slice("  ", 1))
	mp.close()
	main.remove_instrument(stereo)
	await frames(2)

	print("The MIDI editor")
	timeline.grid = 1
	main.edit_window.open()
	await frames(2)
	var clip_for_notes: Dictionary = keys_inst.clips[0]
	var editor_notes_before: int = clip_for_notes.notes.size()
	var double_click := InputEventMouseButton.new()
	double_click.button_index = MOUSE_BUTTON_LEFT
	double_click.pressed = true
	double_click.double_click = true
	double_click.position = Vector2(view.x_of((timeline.clip_steps(clip_for_notes).x + timeline.clip_steps(clip_for_notes).y) / 2.0),
		view.row_top(view.tracks().find(keys_inst)) + 30)
	view._on_button(double_click)
	await frames(4)
	var ed = edit.notes
	check(edit.editing_notes() and ed.inst == keys_inst and edit._notes_bar.visible and not view.visible and ed.zoom > 6.0,
		"double-click a MIDI clip and its notes open in the MIDI editor, the clip across it")
	var note_place := Vector2(ed.x_of(2.0) + 2.0, ed.y_of(72) + 5.0)
	var place_zone: String = ed.zone_at(note_place).get("zone", "")
	ed.press(note_place)
	ed.drag(Vector2(ed.x_of(6.0), ed.y_of(72) + 5.0))
	ed.release(Vector2(ed.x_of(6.0), ed.y_of(72) + 5.0))
	var added_note: Dictionary = ed.clip.notes.back()
	check(place_zone == "grid" and ed.clip.notes.size() == editor_notes_before + 1 and int(added_note.note) == 72 and is_equal_approx(float(added_note.step), 2.0) and
		is_equal_approx(float(added_note.length), 4.0), "click an empty place to add a note there (drag as you add it to make it longer)", str(added_note))
	ed.press(Vector2(ed.x_of(3.0), ed.y_of(72) + 5.0))
	ed.drag(Vector2(ed.x_of(4.0), ed.y_of(74) + 5.0))
	ed.release(Vector2(ed.x_of(4.0), ed.y_of(74) + 5.0))
	check(int(added_note.note) == 74 and is_equal_approx(float(added_note.step), 3.0), "drag a note along and up to move it", str(added_note))
	var note_stalk := Vector2(ed.x_of(3.0), ed.lane_top() + 20.0)
	var stalk_zone: String = ed.zone_at(note_stalk).get("zone", "")
	ed.press(note_stalk)
	ed.drag(note_stalk + Vector2(0, 25))
	ed.release(note_stalk + Vector2(0, 25))
	check(stalk_zone == "velocity" and absf(float(added_note.velocity) - 0.3) < 0.01, "and its stalk along the foot down for a softer note", "%.2f" % float(added_note.velocity))
	var heard_in_track: bool = timeline.engine_clips(keys_inst).is_empty()  # (MIDI: sent as notes)
	await tap(KEY_DELETE)
	check(ed.clip.notes.size() == editor_notes_before and heard_in_track, "Delete takes the chosen note away")
	await tap(KEY_ESCAPE)
	check(edit.is_open() and not edit.editing_notes() and view.visible, "Esc goes back to the tracks")
	for undo in 4:
		timeline.undo()
	check(keys_inst.clips[0].notes.size() == editor_notes_before, "(and the edits undo)")
	timeline.grid = 4
	main.edit_window.close()
	timeline.set_loop(true)

	print("Pre-roll, punching in and out, post-roll")
	var tempo_was: float = main.tempo
	main.set_tempo(200.0)  # (a bar 1.2 seconds, to get through it quickly)
	var punch_loop := Vector2(timeline.loop_start, timeline.loop_end)
	timeline.set_loop(false, 16.0, 20.0)
	main.settings.preroll_bars = 1
	main.settings.postroll_bars = 1
	main.settings.punch = true
	var punch_clips: int = main.speaker.clips.size()
	check(timeline.start_recording() == "" and is_equal_approx(timeline.playhead, 16.0) and is_equal_approx(timeline.punch_out, 20.0),
		"with punching on, recording is from the range on the ruler: in at its start, out at its end")
	await seconds(0.5)
	var preroll_phase: String = timeline.phase()
	var preroll_text: String = main.hud._beat.text
	var preroll_at: float = audio.get_timeline_position()
	await seconds(1.0)
	var punch_phase: String = timeline.phase()
	await seconds(0.6)
	var postroll_phase: String = timeline.phase()
	for wait in 40:
		await frames(3)
		if not timeline.playing and not timeline._taking:
			break
	var punched_take: Dictionary = main.speaker.clips.back() if main.speaker.clips.size() > punch_clips else {}
	var take_end: float = float(punched_take.get("start", 0.0)) + float(punched_take.get("length", 0.0))
	check(preroll_phase == "pre-roll" and preroll_text.contains("PRE-ROLL") and preroll_at < 16.0 and preroll_at > 1.0 and punch_phase == "recording" and
		postroll_phase == "post-roll", "a bar of pre-roll plays first, then it records, then a bar of post-roll", "%s, %s, %s" % [preroll_phase, punch_phase, postroll_phase])
	check(not timeline.recording and not timeline.playing and is_equal_approx(timeline.playhead, 16.0) and not punched_take.is_empty() and
		absf(take_end - 20.0 * timeline.step_seconds()) < 0.02 and absf(float(punched_take.length) - 4.0 * timeline.step_seconds()) < 0.03,
		"after the post-roll it stops of itself, and the take is just the range punched", "%.3f s long" % float(punched_take.get("length", 0.0)))
	timeline.undo()
	main.settings.punch = false
	main.settings.postroll_bars = 0
	timeline.locate(32.0)
	timeline.start_playing()
	await seconds(0.25)
	var played_from_preroll: float = audio.get_timeline_position()
	timeline.stop()
	check(played_from_preroll < 24.0 and played_from_preroll > 16.0 and is_equal_approx(timeline.playhead, 32.0),
		"with a pre-roll, playing starts a bar early too, and stopping goes back to the playhead", "%.1f" % played_from_preroll)
	main.settings.preroll_bars = 0
	main.set_tempo(tempo_was)
	timeline.set_loop(true, punch_loop.x, punch_loop.y)
	timeline.locate(0.0)
	check(main.speaker.clips.size() == punch_clips, "(the punched take undone)")

	print("Tracks and folders")
	main.rename_track(keys_inst, "Rhodes")
	main.set_track_color(keys_inst, main.TRACK_COLORS[8][1])
	await frames(2)
	check(keys_inst.display_name == "Rhodes" and keys_inst.named and keys_inst._label.text.begins_with("Rhodes") and keys_inst.color == main.TRACK_COLORS[8][1] and
		keys_inst.model_color != keys_inst.color, "a track can be renamed and given a colour: its name over it in the room too, its paint left as it was")
	main.edit_window.open()
	await frames(2)
	var folder_drums = main.find_instrument("drums")
	var folder_bass = main.find_instrument("bass")
	view.press(Vector2(40, view.row_top(view.tracks().find(folder_drums)) + 10))
	view.press(Vector2(40, view.row_top(view.tracks().find(folder_bass)) + 10), false, true)  # Shift: those between too
	var chosen_range: Array = main.chosen_tracks.duplicate()
	view.press(Vector2(40, view.row_top(view.tracks().find(folder_bass)) + 10), false, false, true)  # Cmd: one fewer
	check(chosen_range.has(folder_drums) and chosen_range.has(folder_bass) and not main.chosen_tracks.has(folder_bass) and main.chosen_tracks.has(folder_drums),
		"clicking a track's name chooses it, Shift-click those between, Cmd-click one more or one fewer")
	main.chosen_tracks = [folder_drums, folder_bass]
	await command_tap(KEY_G)
	var the_folder = main.folders[0] if not main.folders.is_empty() else null
	check(the_folder != null and the_folder.members == [folder_drums, folder_bass] and main.chosen_tracks == [the_folder] and view.tracks().find(the_folder) == view.tracks().find(folder_drums) - 1 and
		main.instruments.find(folder_bass) == main.instruments.find(folder_drums) + 1, "Cmd-G puts the chosen tracks in a new folder, its row over theirs",
		"%s" % [the_folder.display_name if the_folder != null else "no folder"])
	timeline.start_playing()
	await seconds(0.6)
	var folder_heard: float = the_folder.peak_hold if the_folder != null else 0.0
	main.set_muted(the_folder, true)
	await seconds(0.2)
	var muted_drums: float = audio.get_source_level(folder_drums.source_id)
	main.set_muted(the_folder, false)
	timeline.stop()
	check(folder_heard > 0.001 and muted_drums < 1e-5 and not folder_drums.muted, "its tracks play into it (its meter reads them), and muting it silences them",
		"%.0f dBFS" % linear_to_db(maxf(folder_heard, 1e-9)))
	the_folder.open = false
	var hidden: bool = not view.tracks().has(folder_drums) and view.tracks().has(the_folder)
	view.press(Vector2(14, view.row_top(view.tracks().find(the_folder)) + 10))  # its arrow
	check(hidden and the_folder.open and view.tracks().has(folder_drums), "its arrow hides its tracks in the edit window and shows them again")
	main.mixer.open()
	await frames(3)
	var new_folder_strip: Dictionary = main.mixer._strip_for(the_folder)
	var drums_out_strip: Dictionary = main.mixer._strip_for(folder_drums)
	var folder_frame: Control = new_folder_strip.panel.get_parent().get_parent() if not new_folder_strip.is_empty() else null
	check(not new_folder_strip.is_empty() and new_folder_strip.source.text == "2 tracks" and drums_out_strip.output.selected == 1 and
		drums_out_strip.panel.get_parent() == new_folder_strip.panel.get_parent() and folder_frame is PanelContainer and
		folder_frame.get_theme_stylebox("panel").border_color == the_folder.color,
		"in the mix window the folder has a strip of its own, its tracks' strips beside it in a frame of its colour, and their outputs say they go to it")
	new_folder_strip.pan.value_changed.emit(-0.5)
	TrackMenu.chosen(main, the_folder, TrackMenu.MONO)
	var folder_entry: Dictionary = main.library.room_data().folders[0]
	check(new_folder_strip.pan != null and is_equal_approx(the_folder.pan, -0.5) and the_folder.mono and is_equal_approx(float(folder_entry.pan), -0.5) and
		bool(folder_entry.mono), "a folder has its own pan, and can be stereo (its pan a balance) or mono (its name's menu): kept with the room")
	TrackMenu.chosen(main, the_folder, TrackMenu.STEREO)
	main.set_pan(the_folder, 0.0)
	var problem_on_bus: String = main.set_insert(the_folder, 0, "AU:61756678:64656c79:6170706c")
	check(problem_on_bus == "" and str(the_folder.inserts[0].plugin_name) == "AUDelay", "a folder takes plug-ins on its inserts, as a track does", problem_on_bus)
	main.mixer._strip_for(folder_bass).output.item_selected.emit(0)
	check(the_folder.members == [folder_drums] and main.folder_of(folder_bass) == null, "a track's output set to the master takes it out of the folder")
	main.mixer.close()
	main.edit_window.close()
	main.put_in_folder(folder_bass, the_folder)
	main.rename_track(the_folder, "Rhythm")

	print("Automation")
	var auto = main.automation
	main.edit_window.open()
	await frames(2)
	await tap(KEY_A)
	var keys_row2: int = view.tracks().find(keys_inst)
	view.zoom = 6.0
	view.scroll_x = 0.0
	view.scroll_y = keys_row2 * view.row_height()  # the keys' row at the top, its lane under it
	var lane_top: float = view.lane_top(keys_row2)
	check(view.show_automation and edit._automation.button_pressed and is_equal_approx(view.row_height(), view.ROW + view.LANE) and
		view.zone_at(Vector2(view.x_of(8.0), lane_top + 20)).get("zone", "") == "lane", "A shows an automation lane under each track, as in Logic")
	var at_zero := Vector2(view.x_of(0.0), view._lane_y(0.0, "volume", lane_top))
	var at_minus := Vector2(view.x_of(16.0), view._lane_y(-20.0, "volume", lane_top))
	for spot in [at_zero, at_minus]:
		view.press(spot)
		view.release(spot)
	var keys_volume: Array = auto.points(keys_inst, "volume")
	check(keys_volume.size() == 2 and is_equal_approx(float(keys_volume[0][0]), 0.0) and is_equal_approx(float(keys_volume[1][0]), 16.0) and
		absf(float(keys_volume[0][1])) < 0.6 and absf(float(keys_volume[1][1]) + 20.0) < 0.6, "clicking the lane adds points: the keys' volume from 0 dB down to -20 by bar 2",
		str(keys_volume))
	timeline.locate(8.0)
	main.mixer.open()
	await frames(3)
	var shown_fader: float = main.mixer._strip_for(keys_inst).fader.value
	main.mixer.close()
	main.edit_window.open()
	await frames(2)
	check(absf(auto.shown_level(keys_inst) - (float(keys_volume[0][1]) + float(keys_volume[1][1])) / 2.0) < 0.1 and absf(shown_fader - auto.shown_level(keys_inst)) < 0.1,
		"its fader shows the automation where the playhead is, halfway down at bar 1 beat 3", "%.1f dB" % shown_fader)
	var point_spot := Vector2(view.x_of(16.0), view._lane_y(float(keys_volume[1][1]), "volume", lane_top))
	view.drag_to(point_spot, point_spot + Vector2(view.zoom * 4.0, -10))
	check(keys_volume.size() == 2 and is_equal_approx(float(keys_volume[1][0]), 20.0) and float(keys_volume[1][1]) > -20.0,
		"a point drags along (to the grid) and up", str(keys_volume[1]))
	view.press(point_spot + Vector2(view.zoom * 4.0, -10), true)  # Option-click
	check(keys_volume.size() == 1, "Option-click takes a point away")
	timeline.undo()
	keys_volume = auto.points(keys_inst, "volume")
	check(keys_volume.size() == 2, "and that can be undone, as any edit can")
	view.press(Vector2(view.x_of(float(keys_volume[0][0])), view._lane_y(float(keys_volume[0][1]), "volume", lane_top)))
	await tap(KEY_DELETE)
	check(auto.points(keys_inst, "volume").size() == 1 and keys_inst.clips.size() == 2, "Delete takes the chosen points away (and leaves the clips be)")
	timeline.undo()
	var mode_button: Vector2 = view._lane_buttons(keys_inst, lane_top)[1].rect.get_center()
	view.press(mode_button)
	var mode_items: int = view._lane_menu.item_count
	view._lane_menu.id_pressed.emit(2)
	view._lane_menu.hide()
	var param_button: Vector2 = view._lane_buttons(keys_inst, lane_top)[0].rect.get_center()
	view.press(param_button)
	var params_offered: int = view._lane_menu.item_count
	view._lane_menu.hide()
	check(mode_items == 5 and keys_inst.auto_mode == "touch" and params_offered == 4 and auto.params_for(the_folder).size() == 2,
		"its buttons choose the track's mode (Off, Read, Touch, Latch, Write) and what the lane shows (an instrument's sustain pedal and pan too)")
	keys_inst.auto_mode = "read"

	var drums_auto = main.find_instrument("drums")
	drums_auto.automation.volume = [[0.0, 0.0], [4.0, -80.0]]
	timeline.sync(drums_auto)
	timeline.locate(0.0)
	main.settings.pre_fader_meters = false  # (the meters after the fader, where automation acts)
	timeline.start_playing()
	await seconds(1.0)
	drums_auto.peak_hold = 0.0
	await seconds(0.6)
	var faded_drums: float = drums_auto.peak_hold
	timeline.stop()
	drums_auto.auto_mode = "off"
	timeline.start_playing()
	await seconds(1.0)
	drums_auto.peak_hold = 0.0
	await seconds(0.6)
	var unfaded_drums: float = drums_auto.peak_hold
	timeline.stop()
	main.settings.pre_fader_meters = true
	check(faded_drums < 1e-5 and unfaded_drums > 1e-4, "played, its automation takes the fader's place (the drums faded out by beat 2); in Off, it is ignored",
		"%.0f dBFS, %.0f with it off" % [linear_to_db(maxf(faded_drums, 1e-9)), linear_to_db(maxf(unfaded_drums, 1e-9))])
	drums_auto.automation.volume = []
	drums_auto.auto_mode = "touch"
	timeline.sync(drums_auto)
	timeline.locate(0.0)
	timeline.start_playing()
	await seconds(0.4)
	auto.touch(drums_auto, true)  # its fader taken hold of, and down
	main.set_instrument_level(drums_auto, -12.0)
	await seconds(0.6)
	auto.touch(drums_auto, false)
	main.set_instrument_level(drums_auto, 0.0)
	await seconds(0.3)
	timeline.stop()
	await frames(3)
	var touched: Array = auto.points(drums_auto, "volume")
	var wrote_minus_12: bool = touched.any(func(p): return absf(float(p[1]) + 12.0) < 0.01)
	check(wrote_minus_12 and touched.size() >= 2 and touched.size() < 12 and absf(float(touched.back()[1])) < 0.01,
		"in Touch, the fader held as it plays is written (thinned to a few points), and let go, it goes back", str(touched))
	drums_auto.auto_mode = "latch"
	drums_auto.automation.volume = []
	timeline.sync(drums_auto)
	timeline.locate(0.0)
	timeline.start_playing()
	await seconds(0.3)
	auto.touch(drums_auto, true)
	main.set_instrument_level(drums_auto, -6.0)
	await seconds(0.2)
	auto.touch(drums_auto, false)
	await seconds(0.4)
	var latch_writing: bool = auto.is_writing(drums_auto)
	timeline.stop()
	await frames(3)
	check(latch_writing and auto.points(drums_auto, "volume").any(func(p): return absf(float(p[1]) + 6.0) < 0.01) and not auto.is_writing(drums_auto),
		"in Latch it goes on writing after the fader is let go, until the music stops")
	drums_auto.auto_mode = "write"
	main.set_instrument_level(drums_auto, 0.0)
	timeline.locate(0.0)
	timeline.start_playing()
	await seconds(0.3)
	var write_writing: bool = auto.is_writing(drums_auto)
	timeline.stop()
	await frames(3)
	check(write_writing and drums_auto.auto_mode == "touch", "in Write it writes all the while it plays, and afterwards the track is in Touch")
	drums_auto.auto_mode = "touch"
	timeline.locate(0.0)
	timeline.start_playing()
	await seconds(0.3)
	main.set_muted(drums_auto, true)
	await seconds(0.4)
	main.set_muted(drums_auto, false)
	await seconds(0.2)
	timeline.stop()
	await frames(3)
	var mute_lane: Array = auto.points(drums_auto, "mute")
	check(not drums_auto.muted and mute_lane.size() >= 2 and float(mute_lane[0][1]) == 1.0 and mute_lane.any(func(p): return float(p[1]) == 0.0),
		"a mute pressed as it plays in Touch is written, the button left as it was", str(mute_lane))
	for undo in 4:
		timeline.undo()
	check(auto.points(drums_auto, "volume").is_empty() and auto.points(drums_auto, "mute").is_empty(), "what was written undoes")
	drums_auto.automation = {}
	drums_auto.auto_mode = "read"
	timeline.sync(drums_auto)
	timeline._take_pedal(keys_inst, [[2.0, 1.0], [6.0, 0.0]], 0.0, 16.0)
	check(auto.points(keys_inst, "sustain") == [[0.0, 0.0], [2.0, 1.0], [6.0, 0.0]], "the sustain pedal played as an instrument records goes in its lane",
		str(auto.points(keys_inst, "sustain")))

	print("Automating knobs, plug-ins and the master")
	var amp_auto = main.add_instrument("guitar_combo", Vector3(-2.0, 0.0, 2.0))
	await frames(2)
	var amp_row: int = view.tracks().find(amp_auto)
	view.scroll_y = 0.0
	view.scroll_y = clampf(view.row_top(amp_row) - view.RULER, 0.0, view._most_scroll())
	view.press(view._lane_buttons(amp_auto, view.lane_top(amp_row))[0].rect.get_center())  # what its lane shows
	var offers_knobs: bool = view._lane_choices.has("amp:master") and view._lane_choices.has("amp:gain")
	view._lane_menu.id_pressed.emit(view._lane_choices.find("amp:master"))
	view._lane_menu.hide()
	amp_auto.automation["amp:master"] = [[0.0, 5.0], [16.0, 2.0]]
	timeline.sync(amp_auto)
	timeline.locate(8.0)
	await frames(3)
	check(offers_knobs and amp_auto.lanes[0] == "amp:master" and absf(float(amp_auto.amp_controls.master) - 3.5) < 0.01 and
		absf(auto.shown(amp_auto, "amp:master") - 3.5) < 0.01, "an amp's knobs can be automated: stopped, its Master is where its lane has it at the playhead",
		"%.2f" % float(amp_auto.amp_controls.master))
	view.press(view._lane_buttons(amp_auto, view.lane_top(amp_row))[2].rect.get_center())  # +
	var two_lanes: int = amp_auto.lanes.size()
	view.press(view._lane_buttons(amp_auto, view.lane_top(amp_row, 1), 1)[3].rect.get_center())  # × on the second
	check(two_lanes == 2 and amp_auto.lanes.size() == 1 and is_equal_approx(view.height_of(amp_auto), view.ROW + view.LANE),
		"+ adds another lane under the track, × takes one away")
	var delay_problem: String = main.set_insert(keys_inst, 0, "AU:61756678:64656c79:6170706c")
	var keys_plugins: Array = auto.plugin_params(keys_inst)
	var first_control: Dictionary = keys_plugins[0].params[0] if not keys_plugins.is_empty() and not keys_plugins[0].params.is_empty() else {}
	var control_param: String = first_control.get("param", "")
	view.show_param(keys_inst, 0, control_param)
	keys_inst.automation[control_param] = [[0.0, 0.25]]
	timeline.sync(keys_inst)
	timeline.locate(4.0)
	await frames(3)
	var control_info: Dictionary = auto.plugin_control(keys_inst, control_param)
	var control_now: float = control_info.get("value", -1.0)
	var control_wanted: float = lerpf(control_info.get("min", 0.0), control_info.get("max", 1.0), 0.25)
	check(delay_problem == "" and keys_plugins[0].name.begins_with("AUDelay") and control_param.begins_with("insert:0:") and
		absf(control_now - control_wanted) < 0.01 * maxf(1.0, absf(control_info.get("max", 1.0) - control_info.get("min", 0.0))),
		"a plug-in's controls are offered in its own submenu, and one automated is set where its lane has it", "%s at %.2f" % [first_control.get("name", ""), control_now])
	keys_inst.automation.erase(control_param)
	keys_inst.auto_mode = "latch"
	timeline.locate(0.0)
	timeline.start_playing()
	await seconds(0.3)
	var control_parts: Array = auto.plugin_parts(control_param)
	var turned_to: float = lerpf(control_info.get("min", 0.0), control_info.get("max", 1.0), 0.6)
	audio.set_plugin_parameter(keys_inst.source_id, control_parts[0], control_parts[1], control_parts[2], turned_to)  # as if turned in its window
	await seconds(0.4)
	var plugin_written: bool = auto.is_writing(keys_inst, control_param)
	timeline.stop()
	await frames(3)
	check(plugin_written and auto.has_points(keys_inst, control_param) and auto.points(keys_inst, control_param).any(func(p): return absf(float(p[1]) - 0.6) < 0.01),
		"a plug-in's control turned in its window as it plays (in Latch) is written into its lane")
	keys_inst.auto_mode = "read"
	keys_inst.automation.erase(control_param)
	keys_inst.lanes = ["volume"]
	# A plug-in's automation goes where it goes: to another slot, another track; copied with it, gone with it.
	keys_inst.automation[control_param] = [[0.0, 0.25]]
	keys_inst.lanes = [control_param]
	var moved_param: String = "insert:2:%d" % control_parts[2]
	main.mixer.drop_insert({"inst": keys_inst, "slot": 0}, keys_inst, 2, false)
	timeline.locate(5.0)
	await frames(3)
	var moved_value: float = audio.get_plugin_parameter(keys_inst.source_id, "insert", 2, control_parts[2])
	check(keys_inst.automation.has(moved_param) and not keys_inst.automation.has(control_param) and keys_inst.lanes == [moved_param] and
		absf(moved_value - control_wanted) < 0.01 * maxf(1.0, absf(control_info.get("max", 1.0) - control_info.get("min", 0.0))),
		"a plug-in dragged to another insert slot takes its automation (and its lane) with it", str(keys_inst.lanes))
	main.mixer.drop_insert({"inst": keys_inst, "slot": 2}, amp_auto, 1, false)
	var other_param: String = "insert:1:%d" % control_parts[2]
	var went_across: bool = amp_auto.automation.has(other_param) and amp_auto.lanes.has(other_param) and not keys_inst.automation.has(moved_param) and \
		keys_inst.lanes == ["volume"]
	main.mixer.drop_insert({"inst": amp_auto, "slot": 1}, keys_inst, 0, true)
	var copied_back: bool = keys_inst.automation.get(control_param, []) == [[0.0, 0.25]] and amp_auto.automation.has(other_param) and \
		not is_same(keys_inst.automation[control_param], amp_auto.automation[other_param])
	main.clear_insert(amp_auto, 1)
	check(went_across and copied_back and not amp_auto.automation.has(other_param) and not amp_auto.lanes.has(other_param),
		"to another track too; Option-dropped, a copy takes a copy of it; taken away, the plug-in takes its automation with it")
	keys_inst.automation.erase(control_param)
	var drive_at: int = main.add_pedal(amp_auto, "overdrive")
	var pedal_menu: Array = auto.plugin_params(amp_auto).filter(func(p): return p.name == "Overdrive (pedal %d)" % (drive_at + 1))
	var drive_param := "stomp:%d:0" % drive_at
	amp_auto.automation[drive_param] = [[0.0, 2.0], [16.0, 6.0]]
	amp_auto.lanes = [drive_param]
	timeline.sync(amp_auto)
	timeline.locate(8.0)
	await frames(3)
	check(not pedal_menu.is_empty() and pedal_menu[0].params.any(func(c): return c.param == drive_param and c.name == "Drive") and
		absf(float(amp_auto.pedals[drive_at].controls[0]) - 4.0) < 0.01 and auto.value_text(amp_auto, drive_param, 4.0).begins_with("4.0"),
		"a stock pedal's knobs can be automated (its own submenu): stopped, its Drive is where its lane has it", str(amp_auto.pedals[drive_at].controls))
	main.add_pedal(amp_auto, "fuzz", 0)
	var after_add: bool = amp_auto.automation.has("stomp:%d:0" % (drive_at + 1)) and amp_auto.lanes == ["stomp:%d:0" % (drive_at + 1)]
	main.move_pedal(amp_auto, drive_at + 1, 0)
	var after_move: bool = amp_auto.automation.has("stomp:0:0") and amp_auto.pedals[0].kind == "overdrive"
	main.remove_pedal(amp_auto, 0)
	check(after_add and after_move and not amp_auto.automation.keys().any(func(p): return p.begins_with("stomp:")) and amp_auto.lanes == ["volume"],
		"a pedal's automation follows it about the board, and goes when it is taken off", str(amp_auto.automation.keys()))
	main.clear_insert(keys_inst, 0)
	main.remove_instrument(amp_auto)
	var master_row: int = view.tracks().size() - 1
	check(view.tracks()[master_row] == main.master_track and auto.params_for(main.master_track) == ["volume"],
		"the master has a row at the foot of the edit window, its volume's lane under it")
	main.master_track.automation.volume = [[0.0, 0.0], [16.0, -12.0]]
	timeline.sync(main.master_track)
	timeline.locate(8.0)
	main.mixer.open()
	await frames(3)
	var master_shown: float = main.mixer._master.fader.value
	main.mixer.close()
	main.edit_window.open()
	check(absf(master_shown + 6.0) < 0.1 and is_equal_approx(main.master_volume_db, 0.0), "the master fader shows its automation where the playhead is (the fader itself left as it was)",
		"%.1f dB" % master_shown)

	print("Amps' speakers")
	var stack_amp = main.add_instrument("guitar_stack", Vector3(-2.0, 0.0, 1.0))
	var amp_mic = main.add_instrument("mic_dynamic", Vector3(-2.3, 0.0, 1.6))
	await frames(2)
	var stack_speakers: Dictionary = stack_amp.speakers_in_room()
	main.aim_mic(amp_mic, stack_amp)
	await frames(2)
	var aimed: Dictionary = main.mic_panel.on_axis(amp_mic, main.instruments)
	var nearest_cone: Vector3 = stack_amp.sound_point(amp_mic.global_position)
	check(stack_speakers.cones.size() == 4 and stack_speakers.back == null and aimed.get("name", "") == stack_amp.display_name and
		float(aimed.get("off", 90.0)) < 1.0 and stack_speakers.cones.has(nearest_cone) and stack_speakers.facing.is_equal_approx(stack_amp.global_transform.basis.z),
		"a 4x12's four speakers are where its grille shows them (its back closed); a mic pointed at it points at the nearest cone's dust cap",
		"%.1f degrees off its axis" % float(aimed.get("off", 90.0)))
	var pa = main.find_instrument("live")
	var pa_speakers: Dictionary = pa.speakers_in_room() if pa != null else {}
	check(pa != null and pa.radiates() and pa_speakers.cones.size() == 1 and is_equal_approx(float(pa_speakers.coverage), 45.0),
		"the PA Speaker is heard as a speaker too: its woofer, and the horn over it covering 45 degrees either side")
	main.remove_instrument(amp_mic)
	main.remove_instrument(stack_amp)

	print("Aux tracks and sends")
	var aux = main.add_aux()
	var drums_send = main.find_instrument("drums")
	main.mixer.open()
	await frames(3)
	var drums_send_strip: Dictionary = main.mixer._strip_for(drums_send)
	var aux_strip: Dictionary = main.mixer._strip_for(aux)
	main.mixer.show_send_menu(drums_send, 0, drums_send_strip.sends[0].button)
	var offered_aux: bool = main.mixer._send_menu.get_item_index(100) >= 0
	main.mixer._send_menu.id_pressed.emit(100)
	main.mixer._send_menu.hide()
	await frames(2)
	drums_send_strip = main.mixer._strip_for(drums_send)  # (built again: where the sends go is drawn into them)
	aux_strip = main.mixer._strip_for(aux)
	check(aux != null and not aux_strip.is_empty() and aux_strip.source.text == "1 send in" and offered_aux and drums_send.sends[0].get("aux") == aux and
		drums_send_strip.sends[0].button.text.begins_with(aux.display_name) and drums_send_strip.sends[0].button.get_parent().get_parent().visible,
		"an aux track has a strip of its own; a track's empty send (under its inserts) offers it, and sends to it", drums_send_strip.sends[0].button.text)
	timeline.locate(0.0)
	timeline.start_playing()
	await seconds(0.8)
	var aux_heard: float = aux.peak_hold
	timeline.stop()
	main.mixer.show_send_menu(drums_send, 0, drums_send_strip.sends[0].button)
	main.mixer._send_menu.id_pressed.emit(1)  # before the fader
	main.set_send_level(drums_send, 0, -6.0)
	check(aux_heard > 0.001 and drums_send.sends[0].pre and is_equal_approx(float(drums_send.sends[0].level_db), -6.0) and
		auto.params_for(drums_send).has("send:0"), "it plays into the aux (its meter reads it), before the fader or after, at a level that can be automated too",
		"%.0f dBFS" % linear_to_db(maxf(aux_heard, 1e-9)))
	# A send dragged sideways onto another track's send moves there, its automation with it; with Option, a copy.
	var pad_send = main.find_instrument("pad")
	drums_send.automation["send:0"] = [[0.0, -6.0], [16.0, -12.0]]
	var send_data = main.mixer._send_drag_data(Vector2.ZERO, drums_send, 0, drums_send_strip.sends[0].button)
	var send_can: bool = main.mixer._send_can_drop(Vector2.ZERO, send_data, pad_send, 1)
	main.mixer.drop_send(send_data, pad_send, 1, false)
	await frames(2)
	check(send_data != null and send_can and drums_send.sends[0].is_empty() and pad_send.sends[1].get("aux") == aux and pad_send.sends[1].get("pre", false) and
		pad_send.automation.has("send:1") and not drums_send.automation.has("send:0"),
		"a send dragged sideways onto another track's send moves there (before the fader still), its automation with it")
	main.mixer.drop_send({"send": true, "inst": pad_send, "slot": 1}, drums_send, 0, true)  # with Option held
	await frames(2)
	check(pad_send.sends[1].get("aux") == aux and drums_send.sends[0].get("aux") == aux and drums_send.automation.has("send:0") and
		not main.mixer._send_can_drop(Vector2.ZERO, {"send": true, "inst": pad_send, "slot": 1}, aux, 0),
		"with Option held a second of it goes there instead; and a send can't go to the aux it plays into")
	main.set_send(pad_send, 1, null)
	pad_send.automation.erase("send:1")

	main.mixer.close()
	check(view.tracks().has(aux) and view.tracks().find(aux) == view.tracks().size() - 3, "the aux has a row in the edit window, after the tracks")
	var aux_row: int = view.tracks().find(aux)
	view.scroll_y = clampf(view.row_top(aux_row) + view.scroll_y - view.RULER, 0.0, view._most_scroll())
	var empty_at := Vector2(view.x_of(6.0), view.row_top(aux_row) + view.ROW / 2.0)
	var empty_hint: String = view.hint_at(empty_at)
	view.press(empty_at)
	view.release(empty_at)
	check(view.zone_at(empty_at).get("zone", "") == "track" and empty_hint == "Click to put the playhead here" and absf(timeline.playhead - timeline.snap(6.0)) < 0.01,
		"over an empty part of a row (a folder's, an aux's) the hint line says so, and a click puts the playhead there", "%s, %.2f" % [empty_hint, timeline.playhead])
	await tap(KEY_A)
	check(not view.show_automation, "and A hides the lanes again")
	main.edit_window.close()

	print("Folders in folders; aux tracks in folders; folders' and auxes' own sends")
	var rhythm = main.folder_of(drums_send)
	var band = main.add_folder([], "Band")
	var into_band: bool = main.put_in_folder(rhythm, band)
	var circle_refused: bool = not main.put_in_folder(band, rhythm) and main.folder_of(band) == null
	var nested_order: Array = main.track_order()
	check(into_band and circle_refused and main.folders_around(drums_send) == [rhythm, band] and nested_order.find(rhythm) == nested_order.find(band) + 1 and
		nested_order.find(drums_send) > nested_order.find(rhythm), "a folder goes into another, with its tracks (never into one inside it)",
		str(nested_order.map(func(t): return t.display_name)))
	main.edit_window.open()
	await frames(2)
	var indents: Array = [view._indent(band), view._indent(rhythm), view._indent(drums_send)]
	band.open = false
	var band_closed: bool = not view.tracks().has(rhythm) and not view.tracks().has(drums_send) and view.tracks().has(band)
	band.open = true
	check(indents == [0.0, 10.0, 20.0] and band_closed, "in the edit window each is set in under the one it is in; closing the outer one hides all in it",
		str(indents))
	main.edit_window.close()
	var verb = main.add_aux("Verb")
	main.put_in_folder(aux, band)
	main.mixer.open()
	await frames(3)
	var band_strip: Dictionary = main.mixer._strip_for(band)
	var aux_out: Array = main.mixer._strip_for(aux).output.get_meta("choices")
	var rhythm_out: Array = main.mixer._strip_for(rhythm).output.get_meta("choices")
	main.mixer.show_send_menu(band, 0, band_strip.sends[0].button)
	var offers_verb: bool = main.mixer._send_menu.get_item_index(100 + main.auxes.find(verb)) >= 0
	var offers_own_aux: bool = main.mixer._send_menu.get_item_index(100 + main.auxes.find(aux)) >= 0
	main.mixer._send_menu.id_pressed.emit(100 + main.auxes.find(verb))
	main.mixer._send_menu.hide()
	check(main.folder_of(aux) == band and aux_out.has(band) and not rhythm_out.has(rhythm) and rhythm_out.has(band) and
		offers_verb and not offers_own_aux and band.sends[0].get("aux") == verb and not main.set_send(verb, 0, aux) and
		auto.params_for(band).has("send:0"),
		"an aux track goes in a folder too; a folder's strip has sends (not to an aux in it, nor one whose sound would come back round)")
	main.set_pre_fader_meters(false)
	for track in [band, verb, aux]:
		track.peak_hold = 0.0
	main.set_soloed(drums_send, true)
	var silenced_by_solo: Array = main.silenced.keys()
	timeline.locate(0.0)
	timeline.start_playing()
	await seconds(0.8)
	timeline.stop()
	check(band.peak_hold > 0.001 and verb.peak_hold > 0.001 and not main.silenced.has(band) and not main.silenced.has(rhythm) and
		not main.silenced.has(aux) and not main.silenced.has(verb) and silenced_by_solo.has(main.find_instrument("keys")) and
		silenced_by_solo.has(main.find_instrument("bass")),
		"the drums soloed are heard all the way: through Rhythm and Band, the aux they send to, and Verb that Band sends to; the rest are silent",
		"Band %.0f dBFS, Verb %.0f" % [linear_to_db(maxf(band.peak_hold, 1e-9)), linear_to_db(maxf(verb.peak_hold, 1e-9))])
	main.set_soloed(drums_send, false)
	main.set_pre_fader_meters(true)
	main.chosen_tracks = [rhythm, aux]
	main.group_chosen()
	var grouped = main.chosen_tracks[0] if main.chosen_tracks.size() == 1 else null
	check(grouped != null and main.folder_of(grouped) == band and grouped.members == [rhythm, aux] and main.folder_of(drums_send) == rhythm,
		"Cmd-G puts folders and aux tracks in a new folder too, where the first of them was")
	main.remove_folder(grouped)
	check(main.folder_of(rhythm) == band and main.folder_of(aux) == band and band.members.find(rhythm) < band.members.find(aux),
		"a folder taken away leaves what was in it in the folder it was in")
	timeline.locate(0.0)
	session.save()
	var record_file: String = session.path
	var saved_loop := Vector2(timeline.loop_start, timeline.loop_end)
	main.show_title()
	await frames(3)
	await click(title.buttons.open.get_global_rect().get_center())
	await frames(2)
	var record_index: int = rooms._rooms.map(func(r): return r.path).find(record_file)
	rooms._room_list.get_root().get_child(record_index).select(0)
	await click(rooms._open.get_global_rect().get_center())
	await seconds(1.0)
	var reopened_keys = main.find_instrument("keys")
	check(timeline.is_record() and reopened_keys.clips.size() == 2 and main.speaker.clips.size() == 1 and is_equal_approx(timeline.loop_start, saved_loop.x) and
		is_equal_approx(timeline.loop_end, saved_loop.y), "saved and opened again, the room is a Record room with its clips and loop",
		"%.2f to %.2f" % [timeline.loop_start, timeline.loop_end])
	var reopened_folder = main.folders.filter(func(f): return f.display_name == "Rhythm").front() if main.folders.size() == 2 else null
	var reopened_band = main.folders.filter(func(f): return f.display_name == "Band").front() if main.folders.size() == 2 else null
	check(reopened_keys.display_name == "Rhodes" and reopened_keys.named and reopened_keys.color == main.TRACK_COLORS[8][1] and reopened_folder != null and
		reopened_folder.members.map(func(i): return i.kind) == ["drums", "bass"] and
		str(reopened_folder.inserts[0].plugin_name) == "AUDelay", "and its tracks' names and colours, and its folder with its tracks and inserts")
	var reopened_keys_volume: Array = main.automation.points(reopened_keys, "volume")
	check(reopened_keys_volume.size() == 2 and main.automation.points(reopened_keys, "sustain").size() == 3, "its automation is kept with the room",
		str(reopened_keys_volume))
	var reopened_aux = main.auxes.filter(func(a): return a.display_name == "Aux 1").front() if main.auxes.size() == 2 else null
	var reopened_verb = main.auxes.filter(func(a): return a.display_name == "Verb").front() if main.auxes.size() == 2 else null
	var reopened_drums_send: Dictionary = main.find_instrument("drums").sends[0]
	check(reopened_aux != null and reopened_drums_send.get("aux") == reopened_aux and reopened_drums_send.get("pre", false) and
		main.automation.points(main.master_track, "volume").size() == 2, "and its aux track, the sends to it, and the master's automation")
	check(reopened_band != null and reopened_band.members == [reopened_folder, reopened_aux] and reopened_band.sends[0].get("aux") == reopened_verb and
		main.folders_around(main.find_instrument("drums")) == [reopened_folder, reopened_band], "and its folders in folders, the aux in one, and a folder's send")
	main.remove_aux(reopened_aux)
	check(main.auxes.size() == 1 and main.find_instrument("drums").sends[0].is_empty() and not reopened_band.members.has(reopened_aux),
		"an aux track taken away takes the sends to it with it")
	main.remove_aux(reopened_verb)
	main.master_track.automation = {}
	timeline.sync(main.master_track)
	main.remove_folder(reopened_band)
	main.remove_folder(reopened_folder)
	check(main.folders.is_empty() and main.folder_of(main.find_instrument("drums")) == null,
		"a folder taken away leaves its tracks going to the master")
	main.mixer.open()
	main.audio.note_on(main.find_instrument("drums").source_id, 38, 0.9)  # (something for the room to ring with)
	await seconds(0.6)
	var reverb_heard: float = main.mixer._reverb.meter.held_db()
	main.mixer._reverb.fader.value_changed.emit(-80.0)
	await seconds(1.0)
	main.mixer._reverb.meter.clear_hold()
	await seconds(0.4)
	check(reverb_heard > -60.0 and main.mixer._reverb.meter.held_db() < -59.0 and main.mixer._reverb.value.text == "-inf" and main.reverb_db <= -79.0,
		"the room reverb has a fader of its own beside the master, its return metered, and all the way down there is none",
		"%.0f dB, then %.0f dB" % [reverb_heard, main.mixer._reverb.meter.held_db()])
	main.mixer._reverb.fader.value_changed.emit(-6.0)
	var option := InputEventKey.new()
	option.physical_keycode = KEY_ALT
	option.keycode = KEY_ALT
	option.pressed = true
	Input.parse_input_event(option)
	await frames(2)
	main.mixer._strips[0].mute.toggled.emit(true)
	var option_up: InputEventKey = option.duplicate()
	option_up.pressed = false
	Input.parse_input_event(option_up)
	await frames(2)
	var all_muted: bool = main.instruments.all(func(i): return i.muted)
	main.mixer._strips[0].mute.toggled.emit(false)
	check(all_muted and not main.instruments[0].muted and main.instruments[1].muted, "Option-click a mute in the mix window: every track mutes (a plain click, only its own)")
	main.set_on_all("mute", false)
	main.chosen_tracks = [main.instruments[1], main.instruments[2]]
	var shift_option: InputEventKey = option.duplicate()
	shift_option.physical_keycode = KEY_SHIFT
	shift_option.keycode = KEY_SHIFT
	Input.parse_input_event(option)
	Input.parse_input_event(shift_option)
	await frames(2)
	main.mixer._strip_for(main.instruments[1]).mute.toggled.emit(true)
	var shift_up: InputEventKey = shift_option.duplicate()
	shift_up.pressed = false
	Input.parse_input_event(shift_up)
	Input.parse_input_event(option_up)
	await frames(2)
	check(main.instruments[1].muted and main.instruments[2].muted and not main.instruments[0].muted and not main.instruments[3].muted,
		"Shift-Option-click a mute: only the tracks chosen by their names mute, as Pro Tools' selected-tracks modifier")
	main.set_on_all("mute", false)
	main.chosen_tracks = []
	main.mixer.close()
	check(is_equal_approx(float(library.room_data().reverb_db), -6.0), "and it is kept with the room")
	timeline.set_mode("jam")
	await frames(2)
	await tap(KEY_R)
	var refused: String = timeline.toggle_record()
	check(not edit.is_open() and refused.begins_with("recording is for Record rooms"), "a Jam room has no edit window, and doesn't record", refused)
	timeline.set_mode("record")
	main.show_title()
	await frames(3)
	await click(title.buttons.new.get_global_rect().get_center())
	await frames(2)
	rooms._name.text = "Empty recording room"
	rooms._check_name()
	rooms._record.button_pressed = true
	rooms._template_list.select(1)
	rooms._on_template_chosen()
	await click(rooms._create.get_global_rect().get_center())
	if session.is_asking():
		session._confirm.custom_action.emit(&"discard")
	await seconds(0.8)
	check(session.room_name == "Empty recording room" and timeline.is_record() and not timeline.playing and not timeline.loop_on and
		is_equal_approx(main.tempo, 90.0) and main.instruments.is_empty(), "the empty room in Record mode starts stopped, nothing looping, at 90 BPM",
		"%.0f BPM" % main.tempo)

	print("ALL PASSED" if failures == 0 else "%d FAILED" % failures)
	quit(failures)
