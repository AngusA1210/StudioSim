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
	check(title.buttons.enter.has_focus() and title._status.text.begins_with("Playing through"), "Enter the room is ready under the keyboard",
		title._status.text.replace("\n", " / "))
	var stood: Vector3 = player.global_position
	for code in [KEY_E, KEY_TAB, KEY_N, KEY_M, KEY_SPACE]:
		await tap(code)
	check(player.playing == null and not seq.is_open() and not main.instrument_menu.is_open() and main.sequence_running
		and player.global_position.is_equal_approx(stood), "the room's own keys do nothing here")
	await click(title.buttons.audio.get_global_rect().get_center())
	check(main.menu.is_open() and main.menu._tabs.get_tab_title(main.menu._tabs.current_tab) == "Playback Engine"
		and main.menu._resume.text.begins_with("Back") and not main.menu._to_title.visible and not title._ui.visible,
		"Audio setup opens the menu on the Playback Engine page", main.menu._resume.text)
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
	check(title.is_open(), "Enter doesn't slip through the menu to the title's buttons")
	await tap(KEY_ESCAPE)
	await frames(3)
	check(not main.menu.is_open() and title.is_open() and title._ui.visible and title.buttons.enter.has_focus(), "Esc comes back to the title")
	await click(title.buttons.controls.get_global_rect().get_center())
	check(main.menu.is_open() and main.menu._tabs.get_tab_title(main.menu._tabs.current_tab) == "Controls", "Controls opens the key list")
	await tap(KEY_ESCAPE)
	await frames(3)
	await tap(KEY_ENTER)
	await seconds(1.0)
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
	check(card == ["Drums", "E play", "Enter edit its pattern", "I input on", "M loop off", "G carry", "Backspace remove (press twice)"],
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
	check(im.is_open() and im._cards.size() == 10 and not im._cards[0].disabled, "N opens the instrument menu, with the amps among the live inputs",
		im._footer.text)
	await click(im._cards[1].get_global_rect().get_center())
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
	await click(im._cards[5].get_global_rect().get_center())
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
	await click(im._cards[6].get_global_rect().get_center())
	var amp = player.carried
	check(amp != null and amp.display_name == "Guitar Combo" and amp.is_amp and not amp.playable and amp._led != null,
		"the instrument menu offers a guitar combo, with its loop pedal")
	await tap(KEY_G)
	await frames(5)
	var amp_card: Array = main.hud.hint_lines()
	check(player.target == amp and amp_card.has("L record a loop") and amp_card.has("Enter knobs and loop pedal") and not amp_card.has("E play"),
		"its card offers the loop pedal and the knobs", " / ".join(amp_card))
	await tap(KEY_L)
	await frames(3)
	check(amp.input_on and amp.looper.get("state", "") == "waiting", "L arms the pedal: its input goes on, and with Sync it waits for the bar line",
		amp.looper.get("state", ""))
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
	await tap(KEY_K)
	await frames(3)
	check(amp.looper.get("state", "") == "stopped" and amp._loop_label.text.contains("stopped"), "K stops the loop", amp._loop_label.text)
	await tap(KEY_ENTER)
	await frames(4)
	var panel = main.amp_panel
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
	await click(panel._footswitch.get_global_rect().get_center())
	check(amp.looper.get("state", "") == "playing", "the pedal's footswitch button plays it again")
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
	main.set_input(amp, false)
	main.remove_instrument(amp)
	main.set_tempo(100.0)

	print("The Speaker and the menu")
	var from: Vector3 = speaker.position + Vector3(0.0, 0.0, 1.8)
	player.place(Vector3(from.x, 0.0, from.z), 0.0)
	await frames(5)
	var speaker_card: Array = main.hud.hint_lines()
	check(player.target == speaker and speaker_card == ["Speaker", "I input on", "M mute", "G carry", "Backspace remove (press twice)"],
		"the Speaker's card offers input and mute, but not playing", " / ".join(speaker_card))
	await tap(KEY_M)
	check(speaker.muted, "M mutes it")
	await tap(KEY_E)
	check(player.playing == null and not seq.is_open(), "E does nothing at the Speaker: it isn't played")
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
	main.set_muted(drums, true)
	await seconds(0.3)
	await click(drums_strip.peak.get_global_rect().get_center())
	await frames(2)
	check(drums.peak_hold < 0.00001 and drums_strip.peak.text == "-inf", "clicking the peak readout clears it, as in Pro Tools", drums_strip.peak.text)
	main.set_muted(drums, false)
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
	check(main.meter_reduction_db > 1.0 and not main.meter_clipped and mix._status.text.contains("Limiting by"),
		"turned up too far, the limiter holds the output and the window says by how much", mix._status.text)
	var limiting: float = main.meter_reduction_db
	mix._on_master_changed(-10.0)
	await seconds(1.6)
	check(absf(main.meter_reduction_db - limiting) < 2.0 and main.meter_reduction_db > 1.0,
		"the limiter comes before the master fader: bringing the master down doesn't ease it", "%.1f dB, then %.1f dB" % [limiting, main.meter_reduction_db])
	mix._on_master_changed(0.0)
	await click(mix._master.limiter.get_global_rect().get_center())
	await seconds(1.5)
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
	await tap(KEY_TAB)
	check(not mix.is_open(), "Tab closes the mix window")

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
	await click(title.buttons.enter.get_global_rect().get_center())
	await seconds(1.0)
	check(not title.is_open() and player.camera.current and audio.get_pattern(drums.source_id).size() == notes_before
		and is_equal_approx(audio.get_transport().bpm, 100.0), "and the room is as you left it when you come back in")

	print("ALL PASSED" if failures == 0 else "%d FAILED" % failures)
	quit(failures)
