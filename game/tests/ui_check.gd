extends SceneTree
## Drives the real game with pretend key presses and mouse clicks and checks what happens: walking up to an
## instrument, playing it, editing its pattern, the tempo and click, the Speaker, the menu.
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
	create_timer(90.0).timeout.connect(_on_timeout)  # a script error would otherwise leave this running for ever
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
	print("Walking up to an instrument")
	check(speaker.display_name == "Speaker", "the live input is called the Speaker", speaker.display_name)
	await tap(KEY_TAB)
	check(not seq.is_open(), "Tab does nothing when you aren't at an instrument")
	main._sit_at("drums")
	await frames(5)
	check(player.target == drums and player.can_play_target(), "standing at the drums, they are what you're facing")
	check(main.hud._hint.text.contains("E play") and main.hud._hint.text.contains("Tab pattern") and main.hud._hint.text.contains("M loop off"),
		"the hint offers play, pattern and loop", main.hud._hint.text)

	print("Playing by hand")
	await tap(KEY_M)
	check(not drums.loop_on and drums._label.text.contains("loop off"), "M switches the drum loop off", drums._label.text)
	await seconds(0.8)
	var quiet: float = audio.get_source_level(drums.source_id)
	await tap(KEY_E)
	check(player.playing == drums and main.hud._piano.visible, "E sits down at the drums and shows the keyboard", main.hud._piano_help.text)
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
	await tap(KEY_TAB)
	check(seq.is_open() and seq.inst == drums and seq._title.text == "Drums pattern", "Tab opens the drums' pattern", seq._title.text)
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
	await tap(KEY_TAB)
	check(not seq.is_open() and player.playing == drums, "Tab closes the editor; you are still at the drums")
	await tap(KEY_C)
	check(not main.settings.click, "C switches the click off")
	check(main.hud._beat.text.contains("120 BPM"), "the beat readout shows the tempo", main.hud._beat.text)
	await tap(KEY_Q)
	check(player.playing == null, "Q stands up")

	print("A melodic instrument")
	main._sit_at("bass")
	await frames(5)
	await tap(KEY_TAB)
	check(seq.is_open() and seq.inst == bass and player.playing == bass, "Tab opens the bass pattern straight from facing it", seq._title.text)
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

	print("The Speaker and the menu")
	var from: Vector3 = speaker.position + Vector3(0.0, 0.0, 1.8)
	player.place(Vector3(from.x, 0.0, from.z), 0.0)
	await frames(5)
	check(player.target == speaker and main.hud._hint.text.contains("M mute") and not main.hud._hint.text.contains("E play"), "the Speaker can be muted but not played", main.hud._hint.text)
	await tap(KEY_M)
	check(speaker.muted, "M mutes it")
	await tap(KEY_E)
	await tap(KEY_TAB)
	check(player.playing == null and not seq.is_open(), "E and Tab do nothing at the Speaker")
	await tap(KEY_ESCAPE)
	check(main.menu.is_open() and main.menu._tabs.get_tab_title(0) == "Metronome", "Esc opens the menu, Metronome page first", main.menu._tabs.get_tab_title(main.menu._tabs.current_tab))
	main.menu._tempo_slider.value = 100
	main.menu._swing_slider.value = 0
	main.menu._click_slider.value = -6
	await frames(2)
	check(is_equal_approx(audio.get_transport().bpm, 100.0) and is_equal_approx(audio.get_transport().swing, 0.0) and absf(audio.get_transport().click_volume - 0.501) < 0.01,
		"its sliders set tempo, swing and click volume", str(audio.get_transport()))
	print("ALL PASSED" if failures == 0 else "%d FAILED" % failures)
	quit(failures)
