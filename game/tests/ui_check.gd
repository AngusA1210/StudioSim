extends SceneTree
## Drives the real game with pretend key presses and mouse clicks and checks what happens: the title screen,
## walking up to an instrument, its instruction card and input, the amps and their loop pedals, playing it, editing its pattern, the tempo and click, adding and removing instruments, the
## Speaker, the menu, the mixer and meter, the room's size and walls.
## Run: godot --headless --path game --script tests/ui_check.gd -- --silent
## (--silent keeps it from making a sound or touching saved settings; the exit code is the number of failures)

var main
var view: SubViewport  # headless runs only get a 64-pixel window, so the game runs in a full-size off-screen one
var failures := 0


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
	for code in [KEY_E, KEY_TAB, KEY_N, KEY_M, KEY_SPACE]:
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
	check(main.hud._binaural_chip.text == "BINAURAL" and main.hud._reverb_chip.text == "REVERB" and main.hud._modes_panel.visible,
		"the screen shows that binaural and the room reverb are on")
	await tap(KEY_B)
	await tap(KEY_R)
	check(main.hud._binaural_chip.text == "BINAURAL OFF" and main.hud._reverb_chip.text == "REVERB OFF" and not main.settings.binaural,
		"and B and R switch them off, which it shows", "%s, %s" % [main.hud._binaural_chip.text, main.hud._reverb_chip.text])
	await tap(KEY_B)
	await tap(KEY_R)
	check(main.settings.binaural and main.settings.reverb and main.hud._binaural_chip.text == "BINAURAL", "and on again")
	check(not title.is_open() and not title.visible and player.camera.current and main.hud._root.visible, "Enter goes into the room, in the player's view",
		"title open %s, title showing %s, player camera %s, hud %s" % [title.is_open(), title.visible, player.camera.current, main.hud._root.visible])

	print("Walking up to an instrument")
	check(speaker.display_name == "Speaker", "the live input is called the Speaker", speaker.display_name)
	await tap(KEY_ENTER)
	check(not seq.is_open(), "Enter does nothing when you aren't at an instrument")
	await tap(KEY_TAB)
	check(main.mixer.is_open(), "Tab opens the mix window from anywhere")
	await tap(KEY_TAB)
	check(not main.mixer.is_open(), "and closes it again")
	main._sit_at("drums")
	await frames(5)
	check(player.target == drums and player.can_play_target(), "standing at the drums, they are what you're facing")
	var card: Array = main.hud.hint_lines()
	check(card == ["Drums", "E play", "Enter edit its pattern", "I input on", "M loop off", "G carry", "V duplicate", "Backspace remove (press twice)"],
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
	await tap(KEY_ENTER)
	check(seq.is_open() and seq.inst == drums and seq._title.text == "Drums pattern", "Enter opens the drums' pattern", seq._title.text)
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
	await tap(KEY_ENTER)
	check(not seq.is_open() and player.playing == drums, "Enter closes the editor; you are still at the drums")
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
	await tap(KEY_ENTER)
	check(seq.is_open() and seq.inst == bass and player.playing == bass, "Enter opens the bass pattern straight from facing it", seq._title.text)
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
	await tap(KEY_BACKSPACE)
	check(player.target == null and player.remove_pending == null, "Backspace does nothing when you aren't facing an instrument")
	await tap(KEY_N)
	check(im.is_open() and im._cards.size() == 13 and not im._cards[0].disabled, "N opens the instrument menu, with the amps among the live inputs",
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
	await tap(KEY_ENTER)
	check(seq.is_open() and seq._title.text == "Bass 2 pattern", "and it has its own pattern to edit", seq._title.text)
	await tap(KEY_BACKSPACE)
	check(main.instruments.has(bass2), "Backspace is ignored while the pattern editor is open")
	await tap(KEY_ENTER)
	await tap(KEY_BACKSPACE)
	await frames(2)
	check(player.remove_pending == bass2 and main.instruments.has(bass2) and main.hud.hint_lines()[0] == "Remove Bass 2?",
		"one Backspace only asks", " / ".join(main.hud.hint_lines()))
	await tap(KEY_BACKSPACE)
	await frames(3)
	check(not main.instruments.has(bass2) and main.instruments.size() == count_before and audio.get_source_count() == count_before
		and player.playing == null and not is_instance_valid(bass2), "a second one removes it")

	await tap(KEY_N)
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
	await tap(KEY_N)
	check(main.instruments.size() == audio.get_max_sources() and im._cards[0].disabled and im._footer.text.begins_with("The room is full"),
		"a full room says so and offers nothing more", "%d instruments, the last one is %s" % [main.instruments.size(), extras[-1].display_name])
	await tap(KEY_N)
	for extra in extras:
		main.remove_instrument(extra)
	await seconds(0.4)
	var returned = main.add_instrument("pad", Vector3(0.0, 1.6, 0.0))
	check(not im.is_open() and audio.get_source_count() == count_before + 1 and returned != null and returned.display_name == "Pad 2",
		"N closes the menu again, and removing instruments makes space")
	main.remove_instrument(returned)

	print("An amp and its loop pedal")
	main.set_tempo(240.0)  # bars of one second, so the pedal doesn't keep the test waiting
	player.place(Vector3(0.0, 0.0, 3.6), 0.0)
	await frames(3)
	await tap(KEY_N)
	await click(im._card_for.guitar_combo.get_global_rect().get_center())
	var amp = player.carried
	check(amp != null and amp.display_name == "Guitar Combo" and amp.is_amp and not amp.playable and amp.pedals.is_empty(),
		"the instrument menu offers a guitar combo, its pedalboard empty")
	await tap(KEY_G)
	await frames(5)
	var bare_card: Array = main.hud.hint_lines()
	await tap(KEY_L)
	await frames(2)
	check(player.target == amp and bare_card.has("Enter amp and pedals") and not bare_card.has("L record a loop") and not bare_card.has("E play") and
		amp.looper.get("state", "") == "none" and amp._led == null, "without a loop pedal its card offers the amp and pedals, and L does nothing",
		" / ".join(bare_card))
	await tap(KEY_ENTER)
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
	await tap(KEY_ENTER)
	await frames(5)
	var amp_card: Array = main.hud.hint_lines()
	check(not panel.is_open() and amp_card.has("L record a loop") and amp_card.has("1 stamp on a pedal") and amp._led != null and
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
	check(amp.looper.get("state", "") == "playing" and amp.looper.get("can_undo", false) and main.hud.hint_lines().has("U undo the last overdub"),
		"and again goes back to playing, with the overdub ready to undo")
	await tap(KEY_U)
	await frames(3)
	check(amp.looper.get("can_redo", false) and not amp.looper.get("can_undo", false), "U undoes it")
	await tap(KEY_O)
	await frames(3)
	check(amp.looper.get("state", "") == "stopped" and amp._loop_label.text.contains("stopped"), "O stops the loop", amp._loop_label.text)
	await tap(KEY_ENTER)
	await frames(4)
	check(panel.is_open() and panel.inst == amp and panel._display.text == "■ STOPPED" and panel._footswitch.text.begins_with("Play"),
		"Enter opens the amp's panel: its knobs and the loop pedal", panel._display.text)
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
	check(amp.looper.get("state", "") == "playing", "the pedal's footswitch button plays it again", "%s, footswitch at %s, panel %s" % [amp.looper.get("state", ""), panel._footswitch.get_global_rect(), panel._panel.get_global_rect()])
	await tap(KEY_J)
	await tap(KEY_J)
	await frames(3)
	check(amp.looper.get("state", "") == "empty", "J twice clears the loop, from the panel too")
	await tap(KEY_ENTER)
	check(not panel.is_open(), "Enter closes the panel")
	await tap(KEY_L)
	await frames(2)
	await tap(KEY_L)  # cancel the wait
	await frames(2)
	await tap(KEY_J)
	await frames(2)
	check(amp.looper.get("state", "") == "empty" and player.clear_pending == null, "a pedal waiting for the bar can be cancelled, and has nothing to clear")

	print("Effect pedals")
	var order: Array = load("res://scripts/catalog.gd").PEDAL_ORDER
	await tap(KEY_ENTER)
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
	await tap(KEY_ENTER)
	await frames(4)
	var with_pedals: Array = main.hud.hint_lines()
	check(not panel.is_open() and with_pedals.has("1-2 stamp on the pedals") and amp._pedal_row.get_child_count() == 2,
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
	check(player.target == speaker and speaker_card == ["Speaker", "I input on", "Enter volume and input", "M mute", "G carry",
		"V duplicate", "Backspace remove (press twice)"], "the Speaker's card offers input, its panel and mute, but not playing", " / ".join(speaker_card))
	await tap(KEY_M)
	check(speaker.muted, "M mutes it")
	await tap(KEY_E)
	check(player.playing == null and not seq.is_open(), "E does nothing at the Speaker: it isn't played")
	await tap(KEY_M)
	await tap(KEY_ENTER)
	await frames(3)
	var speaker_panel = main.speaker_panel
	check(speaker_panel.is_open() and speaker_panel.inst == speaker and speaker_panel._volume.readout == "+0.0 dB",
		"Enter opens the Speaker's panel, its volume at 0 dB", speaker_panel._volume.readout)
	await turn(speaker_panel._volume, 75.0)  # 5 knob steps: right to the top
	check(absf(speaker.volume_db - 24.0) < 0.6 and speaker_panel._volume.readout == "+24.0 dB",
		"its volume goes up to +24 dB, as a big PA speaker's would", speaker_panel._volume.readout)
	main.set_speaker_volume(speaker, 0.0)
	await tap(KEY_ENTER)
	check(not speaker_panel.is_open(), "Enter closes it")
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
	check(over_mute == "Mute" and over_insert.begins_with("Insert A: click to choose") and mix._hint.text == "",
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
	check(not pad.soloed and drums.muted and drums._label.text.contains("muted") and await average_level(drums.source_id, 0.5) < 0.0005,
		"M on the drums' strip mutes them, and their label says so", drums._label.text)
	await click(mix._strips[0].mute.get_global_rect().get_center())
	audio.note_off(pad.source_id, 57)
	pad.set_loop(true)

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
	check(limiting > 1.0 and still_limiting > 1.0,  # 10 dB down would have ended limiting after the fader
		"the limiter comes before the master fader: bringing the master down 10 dB doesn't ease it", "%.1f dB, then %.1f dB" % [limiting, still_limiting])
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
	await tap(KEY_N)
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
	await tap(KEY_N)
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
	await tap(KEY_N)
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
	check(main.hud.hint_lines().has("P its plug-in's window"), "its card offers its plug-in's window", " / ".join(main.hud.hint_lines()))
	await tap(KEY_P)
	check(player.plugin_open == synth and main.hud._piano.visible and main.hud._piano_title.text.begins_with("Playing the DLSMusicDevice") and
		main.hud.piano_top_fraction() > 0.1, "P opens its plug-in's window over the on-screen keyboard", main.hud._piano_title.text)
	key(KEY_D)
	var window_level: float = await average_level(synth.source_id, 0.3)
	key(KEY_D, false)
	await click(Vector2(640, 300))
	check(window_level > 0.0005 and player.plugin_open == null and not main.hud._piano.visible,
		"with it open the letter keys play it, and a click in the room puts it away", "%.4f" % window_level)
	await tap(KEY_P)
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
	check(session.is_asking() and session._confirm.dialog_text.ends_with("before quitting?"), "quitting with changes asks whether to save them")
	session._confirm.get_cancel_button().pressed.emit()
	await frames(2)
	check(not session.is_asking() and is_equal_approx(main.tempo, 90.0), "and Cancel carries on")

	print("ALL PASSED" if failures == 0 else "%d FAILED" % failures)
	quit(failures)
